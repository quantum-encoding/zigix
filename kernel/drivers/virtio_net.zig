/// VirtIO network device driver — legacy I/O port transport.
/// Two virtqueues: RX (queue 0), TX (queue 1).
/// 16 pre-posted RX buffers, 1 TX buffer, kernel rx_ring for IRQ→poll handoff.

const io = @import("../arch/x86_64/io.zig");
const serial = @import("../arch/x86_64/serial.zig");
const pic = @import("../arch/x86_64/pic.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const pci = @import("pci.zig");
const virtio = @import("virtio.zig");

// VirtIO net header (legacy, no MRG_RXBUF) — 10 bytes
const NetHeader = extern struct {
    flags: u8,
    gso_type: u8,
    hdr_len: u16,
    gso_size: u16,
    csum_start: u16,
    csum_offset: u16,
};

const NET_HDR_SIZE: usize = @sizeOf(NetHeader); // 10
const RX_BUF_COUNT: usize = 16;
const RX_RING_SIZE: usize = 32;

// Feature bits
const VIRTIO_NET_F_MAC: u32 = 1 << 5;
const VIRTIO_NET_F_MRG_RXBUF: u32 = 1 << 15;

// Static state
var io_base: u16 = 0;
var rx_vq: virtio.VirtQueue = undefined;
var tx_vq: virtio.VirtQueue = undefined;
var initialized: bool = false;
pub var irq: u8 = 0xFF;
pub var mac: [6]u8 = undefined;

// Zero-copy mode state
var zc_mode: bool = false;
var zc_buf_base_phys: u64 = 0;
var zc_buf_size: usize = 0;

// RX buffer pages (one PMM page per buffer, 4096 bytes each)
var rx_buf_phys: [RX_BUF_COUNT]u64 = [_]u64{0} ** RX_BUF_COUNT;

// TX buffer page
var tx_buf_phys: u64 = 0;
var tx_buf_virt: u64 = 0;

// Kernel rx_ring: circular buffer of received packets
const RxPacket = struct {
    data: [1524]u8,
    len: u16,
    valid: bool,
};
var rx_ring: [RX_RING_SIZE]RxPacket = undefined;
var rx_ring_head: usize = 0; // IRQ writes here
var rx_ring_tail: usize = 0; // poll reads here

pub fn init(dev: *const pci.PciDevice) bool {
    pci.enableBusMastering(dev);

    const bar0 = dev.bar0;
    if (bar0 & 1 == 0) {
        serial.writeString("[net]  BAR0 is MMIO — unsupported\n");
        return false;
    }
    io_base = @truncate(bar0 & 0xFFFFFFFC);
    irq = dev.irq_line;

    serial.writeString("[net]  virtio-net at I/O 0x");
    writeHex16(io_base);
    serial.writeString(", IRQ ");
    writeDecimal(irq);
    serial.writeString("\n");

    // Reset and init device
    virtio.initDevice(io_base);

    // Feature negotiation: accept MAC feature only
    const features = virtio.readFeatures(io_base);
    const accepted = features & VIRTIO_NET_F_MAC & ~VIRTIO_NET_F_MRG_RXBUF;
    virtio.writeFeatures(io_base, accepted);

    // Init RX queue (queue 0)
    if (virtio.initQueue(io_base, 0)) |q| {
        rx_vq = q;
    } else {
        serial.writeString("[net]  Failed to init RX queue\n");
        return false;
    }

    // Init TX queue (queue 1)
    if (virtio.initQueue(io_base, 1)) |q| {
        tx_vq = q;
    } else {
        serial.writeString("[net]  Failed to init TX queue\n");
        return false;
    }

    // Allocate RX buffers and pre-post them
    for (0..RX_BUF_COUNT) |i| {
        rx_buf_phys[i] = pmm.allocPage() orelse {
            serial.writeString("[net]  Failed to alloc RX buffer\n");
            return false;
        };
        postRxBuffer(i);
    }

    // Allocate TX buffer
    tx_buf_phys = pmm.allocPage() orelse {
        serial.writeString("[net]  Failed to alloc TX buffer\n");
        return false;
    };
    tx_buf_virt = hhdm.physToVirt(tx_buf_phys);

    // Init rx_ring
    for (0..RX_RING_SIZE) |i| {
        rx_ring[i].valid = false;
        rx_ring[i].len = 0;
    }
    rx_ring_head = 0;
    rx_ring_tail = 0;

    // Read MAC address from device config (BAR0 + 0x14 for legacy)
    if (features & VIRTIO_NET_F_MAC != 0) {
        for (0..6) |i| {
            mac[i] = io.inb(io_base + 0x14 + @as(u16, @truncate(i)));
        }
    } else {
        // Default MAC
        mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    }

    serial.writeString("[net]  MAC: ");
    for (0..6) |i| {
        if (i > 0) serial.writeByte(':');
        writeHex8(mac[i]);
    }
    serial.writeString("\n");

    // Mark device as ready (BEFORE this, RX buffers must be posted)
    virtio.finishInit(io_base);

    // Unmask IRQ
    pic.setIrqMask(irq, false);

    serial.writeString("[net]  ");
    writeDecimal(RX_BUF_COUNT);
    serial.writeString(" RX buffers posted\n");

    initialized = true;
    return true;
}

fn postRxBuffer(buf_idx: usize) void {
    // Each RX buffer is a single descriptor: device writes net header + frame
    const head = virtio.allocDescs(&rx_vq, 1) orelse return;
    rx_vq.desc[head].addr = rx_buf_phys[buf_idx];
    rx_vq.desc[head].len = 4096;
    rx_vq.desc[head].flags = virtio.VRING_DESC_F_WRITE;

    // Add to available ring
    const avail_slot = rx_vq.avail_idx.* % rx_vq.queue_size;
    rx_vq.avail_ring[avail_slot] = head;
    asm volatile ("mfence" ::: .{ .memory = true });
    rx_vq.avail_idx.* +%= 1;
    asm volatile ("mfence" ::: .{ .memory = true });
    io.outw(io_base + virtio.REG_QUEUE_NOTIFY, 0);
}

/// Transmit a raw Ethernet frame. Synchronous (polls for completion).
pub fn transmit(data: []const u8) bool {
    if (!initialized) return false;
    if (data.len > 1514) return false; // Max Ethernet frame

    // Fill TX buffer: net header (zeroed) + frame data
    const buf_ptr: [*]u8 = @ptrFromInt(tx_buf_virt);

    // Zero net header
    for (0..NET_HDR_SIZE) |i| {
        buf_ptr[i] = 0;
    }
    // Copy frame data after header
    for (0..data.len) |i| {
        buf_ptr[NET_HDR_SIZE + i] = data[i];
    }

    const total_len: u32 = @truncate(NET_HDR_SIZE + data.len);

    // Allocate 1 descriptor
    const head = virtio.allocDescs(&tx_vq, 1) orelse return false;
    tx_vq.desc[head].addr = tx_buf_phys;
    tx_vq.desc[head].len = total_len;
    tx_vq.desc[head].flags = 0; // Device reads (no WRITE flag)

    // Submit to TX queue (queue 1)
    virtio.submitChainToQueue(&tx_vq, head, io_base, 1);

    // Poll for completion
    if (virtio.pollUsed(&tx_vq)) |_| {
        virtio.freeDescs(&tx_vq, head, 1);
        return true;
    }

    virtio.freeDescs(&tx_vq, head, 1);
    return false;
}

/// Dequeue a packet from the rx_ring. Returns null if empty.
pub fn receive() ?struct { data: []const u8 } {
    if (rx_ring_tail == rx_ring_head) return null;
    if (!rx_ring[rx_ring_tail].valid) return null;

    const pkt = &rx_ring[rx_ring_tail];
    return .{ .data = pkt.data[0..pkt.len] };
}

/// Advance the rx_ring tail after processing a received packet.
pub fn receiveConsume() void {
    rx_ring[rx_ring_tail].valid = false;
    rx_ring_tail = (rx_ring_tail + 1) % RX_RING_SIZE;
}

/// IRQ handler — process used RX descriptors, copy to rx_ring, repost buffers.
pub fn handleIrq() void {
    if (!initialized) return;

    // Read ISR to acknowledge
    _ = virtio.readIsrStatus(io_base);

    // Process completed RX descriptors
    while (rx_vq.used_idx.* != rx_vq.last_used_idx) {
        const slot = rx_vq.last_used_idx % rx_vq.queue_size;
        const elem = rx_vq.used_ring[slot];
        rx_vq.last_used_idx +%= 1;

        const desc_idx = @as(u16, @truncate(elem.id));
        const total_len = elem.len;

        const buf_phys = rx_vq.desc[desc_idx].addr;

        // Guard: skip descriptors with phys addr 0 (physToVirt(0) = HHDM_base, may fault)
        if (buf_phys == 0) {
            virtio.freeDescs(&rx_vq, desc_idx, 1);
            continue;
        }

        if (zc_mode) {
            // Zero-copy path: deliver to shared ring, do NOT repost buffer
            const zcnet = @import("../net/zcnet.zig");
            const buf_idx: u16 = @truncate((buf_phys - zc_buf_base_phys) / zc_buf_size);
            zcnet.deliverRxPacket(buf_idx, total_len);
            virtio.freeDescs(&rx_vq, desc_idx, 1);
            // Buffer ownership transferred to userspace — repost handled by zcnet.poll()
        } else {
            // Copy-mode path: copy to rx_ring and repost immediately
            const buf_virt = hhdm.physToVirt(buf_phys);
            const src: [*]const u8 = @ptrFromInt(buf_virt);

            if (total_len > NET_HDR_SIZE) {
                const frame_len = total_len - @as(u32, @truncate(NET_HDR_SIZE));
                const next = rx_ring_head;

                if (frame_len <= 1524) {
                    const fl: usize = @intCast(frame_len);
                    for (0..fl) |i| {
                        rx_ring[next].data[i] = src[NET_HDR_SIZE + i];
                    }
                    rx_ring[next].len = @truncate(frame_len);
                    rx_ring[next].valid = true;
                    rx_ring_head = (rx_ring_head + 1) % RX_RING_SIZE;
                }
            }

            virtio.freeDescs(&rx_vq, desc_idx, 1);

            for (0..RX_BUF_COUNT) |i| {
                if (rx_buf_phys[i] == buf_phys) {
                    postRxBuffer(i);
                    break;
                }
            }
        }
    }
}

pub fn isInitialized() bool {
    return initialized;
}

// --- Zero-copy support ---

/// Switch to zero-copy mode: post shared-memory buffers to the RX queue.
pub fn switchToZeroCopy(buf_base_phys: u64, buf_size: usize, count: usize) void {
    zc_mode = true;
    zc_buf_base_phys = buf_base_phys;
    zc_buf_size = buf_size;

    // Post first `count` shared buffers to the RX queue
    for (0..count) |i| {
        postRxBufferPhys(buf_base_phys + i * buf_size);
    }
}

/// Switch back to copy mode: repost original kernel RX buffers.
pub fn switchToCopyMode() void {
    zc_mode = false;
    zc_buf_base_phys = 0;
    zc_buf_size = 0;

    // Repost original kernel buffers
    for (0..RX_BUF_COUNT) |i| {
        postRxBuffer(i);
    }
}

/// Post an arbitrary physical buffer to the RX queue (for zero-copy shared buffers).
pub fn postRxBufferPhys(phys: u64) void {
    const head = virtio.allocDescs(&rx_vq, 1) orelse return;
    rx_vq.desc[head].addr = phys;
    rx_vq.desc[head].len = @truncate(if (zc_buf_size > 0) zc_buf_size else 4096);
    rx_vq.desc[head].flags = virtio.VRING_DESC_F_WRITE;

    const avail_slot = rx_vq.avail_idx.* % rx_vq.queue_size;
    rx_vq.avail_ring[avail_slot] = head;
    asm volatile ("mfence" ::: .{ .memory = true });
    rx_vq.avail_idx.* +%= 1;
    asm volatile ("mfence" ::: .{ .memory = true });
    io.outw(io_base + virtio.REG_QUEUE_NOTIFY, 0);
}

/// Transmit from a physical address (for zero-copy TX).
/// The buffer must contain [10-byte net header][frame data].
/// Returns true on success.
pub fn transmitFromPhys(phys: u64, len: usize) bool {
    if (!initialized) return false;
    if (len > BUF_SIZE) return false;

    const head = virtio.allocDescs(&tx_vq, 1) orelse return false;
    tx_vq.desc[head].addr = phys;
    tx_vq.desc[head].len = @truncate(len);
    tx_vq.desc[head].flags = 0; // Device reads

    virtio.submitChainToQueue(&tx_vq, head, io_base, 1);

    if (virtio.pollUsed(&tx_vq)) |_| {
        virtio.freeDescs(&tx_vq, head, 1);
        return true;
    }

    virtio.freeDescs(&tx_vq, head, 1);
    return false;
}

// Need BUF_SIZE constant for transmitFromPhys validation
const BUF_SIZE: usize = 2048;

// --- Output helpers ---

fn writeHex8(val: u8) void {
    const hex = "0123456789abcdef";
    serial.writeByte(hex[@as(usize, val >> 4)]);
    serial.writeByte(hex[@as(usize, val & 0xf)]);
}

fn writeHex16(val: u16) void {
    const hex = "0123456789abcdef";
    var buf: [4]u8 = undefined;
    buf[0] = hex[@as(usize, val >> 12)];
    buf[1] = hex[@as(usize, (val >> 8) & 0xf)];
    buf[2] = hex[@as(usize, (val >> 4) & 0xf)];
    buf[3] = hex[@as(usize, val & 0xf)];
    serial.writeString(&buf);
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        serial.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    serial.writeString(buf[i..]);
}
