/// VirtIO network device driver — MMIO transport.
/// Two virtqueues: RX (queue 0), TX (queue 1).
/// 16 pre-posted RX buffers, 1 TX buffer, kernel rx_ring for IRQ→poll handoff.

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const gic = @import("gic.zig");
const virtio = @import("virtio_mmio.zig");

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
var mmio_base: usize = 0;
var rx_vq: virtio.VirtQueue = undefined;
var tx_vq: virtio.VirtQueue = undefined;
var initialized: bool = false;
pub var irq: u32 = 0;
pub var mac: [6]u8 = undefined;

// RX buffer pages (one PMM page per buffer, 4096 bytes each)
var rx_buf_phys: [RX_BUF_COUNT]u64 = [_]u64{0} ** RX_BUF_COUNT;

// TX buffer page (identity mapped: phys == virt)
var tx_buf_phys: u64 = 0;

// Kernel rx_ring: circular buffer of received packets
const RxPacket = struct {
    data: [1524]u8,
    len: u16,
    valid: bool,
};
var rx_ring: [RX_RING_SIZE]RxPacket = undefined;
pub var rx_ring_head: usize = 0; // IRQ writes here
pub var rx_ring_tail: usize = 0; // poll reads here

pub fn init() bool {
    // Probe for a virtio-net device
    const dev = virtio.findDevice(virtio.DEVICE_NET) orelse {
        uart.writeString("[net]  No virtio-net device found\n");
        return false;
    };

    mmio_base = dev.base;
    irq = dev.irq;

    uart.print("[net]  virtio-net at {x}, IRQ {}\n", .{ mmio_base, irq });

    // Initialize device
    virtio.initDevice(mmio_base);

    // Feature negotiation: accept MAC feature, reject MRG_RXBUF
    const features = virtio.readFeatures(mmio_base);
    const accepted = features & VIRTIO_NET_F_MAC & ~VIRTIO_NET_F_MRG_RXBUF;
    virtio.writeFeatures(mmio_base, accepted);

    // Init RX queue (queue 0)
    if (virtio.initQueue(mmio_base, 0)) |q| {
        rx_vq = q;
    } else {
        uart.writeString("[net]  Failed to init RX queue\n");
        return false;
    }

    // Init TX queue (queue 1)
    if (virtio.initQueue(mmio_base, 1)) |q| {
        tx_vq = q;
    } else {
        uart.writeString("[net]  Failed to init TX queue\n");
        return false;
    }

    // Allocate RX buffers and pre-post them
    for (0..RX_BUF_COUNT) |i| {
        rx_buf_phys[i] = pmm.allocPage() orelse {
            uart.writeString("[net]  Failed to alloc RX buffer\n");
            return false;
        };
        postRxBuffer(i);
    }

    // Allocate TX buffer (identity mapped)
    tx_buf_phys = pmm.allocPage() orelse {
        uart.writeString("[net]  Failed to alloc TX buffer\n");
        return false;
    };

    // Init rx_ring
    for (0..RX_RING_SIZE) |i| {
        rx_ring[i].valid = false;
        rx_ring[i].len = 0;
    }
    rx_ring_head = 0;
    rx_ring_tail = 0;

    // Read MAC address from device config space
    if (features & VIRTIO_NET_F_MAC != 0) {
        for (0..6) |i| {
            mac[i] = readConfig8(i);
        }
    } else {
        mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    }

    uart.writeString("[net]  MAC: ");
    for (0..6) |i| {
        if (i > 0) uart.writeByte(':');
        writeHex8(mac[i]);
    }
    uart.writeString("\n");

    // Mark device as ready
    virtio.finishInit(mmio_base);

    // Enable IRQ in GIC
    gic.enableIrq(irq);
    gic.setPriority(irq, 0);

    uart.print("[net]  {} RX buffers posted\n", .{RX_BUF_COUNT});

    initialized = true;
    return true;
}

fn postRxBuffer(buf_idx: usize) void {
    // Each RX buffer is a single descriptor: device writes net header + frame
    const head = virtio.allocDescs(&rx_vq, 1) orelse return;
    rx_vq.desc[head].addr = rx_buf_phys[buf_idx];
    rx_vq.desc[head].len = 4096;
    rx_vq.desc[head].flags = virtio.VRING_DESC_F_WRITE;

    // Add to available ring and notify RX queue (queue 0)
    virtio.submitToQueue(&rx_vq, head, mmio_base, 0);
}

/// Transmit a raw Ethernet frame. Synchronous (polls for completion).
pub fn transmit(data: []const u8) bool {
    if (!initialized) return false;
    if (data.len > 1514) return false; // Max Ethernet frame

    // Fill TX buffer: net header (zeroed) + frame data
    // Identity mapped: phys == virt
    const buf_ptr: [*]u8 = @ptrFromInt(tx_buf_phys);

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
    virtio.submitToQueue(&tx_vq, head, mmio_base, 1);

    // Poll for completion
    if (virtio.pollUsed(&tx_vq, mmio_base)) |_| {
        virtio.freeDescs(&tx_vq, head, 1);
        return true;
    }

    uart.writeString("[vnet-tx] transmit TIMEOUT\n");
    virtio.freeDescs(&tx_vq, head, 1);
    return false;
}

/// Dequeue a packet from the rx_ring. Returns null if empty.
pub fn receive() ?struct { data: []const u8 } {
    // Force re-read from memory (prevent register caching across poll iterations)
    const tail = @as(*volatile usize, @ptrCast(&rx_ring_tail)).*;
    const head = @as(*volatile usize, @ptrCast(&rx_ring_head)).*;
    if (tail == head) return null;
    const valid = @as(*volatile bool, @ptrCast(&rx_ring[tail].valid)).*;
    if (!valid) return null;

    const pkt = &rx_ring[tail];
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

    // Acknowledge interrupt
    const isr = virtio.readInterruptStatus(mmio_base);
    virtio.ackInterrupt(mmio_base, isr);

    // Process completed RX descriptors
    while (rx_vq.used_idx.* != rx_vq.last_used_idx) {
        const slot = rx_vq.last_used_idx % rx_vq.queue_size;
        const elem = rx_vq.used_ring[slot];
        rx_vq.last_used_idx +%= 1;

        const desc_idx = @as(u16, @truncate(elem.id));
        const total_len = elem.len;

        // Find which RX buffer this descriptor pointed to (identity mapped)
        const buf_phys = rx_vq.desc[desc_idx].addr;
        const src: [*]const u8 = @ptrFromInt(buf_phys);

        // Skip net header, copy frame to rx_ring
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

        // Free descriptor and repost buffer
        virtio.freeDescs(&rx_vq, desc_idx, 1);

        // Find this buffer's index and repost
        for (0..RX_BUF_COUNT) |i| {
            if (rx_buf_phys[i] == buf_phys) {
                postRxBuffer(i);
                break;
            }
        }
    }
}

pub fn isInitialized() bool {
    return initialized;
}

// --- Config space access ---

fn readConfig8(offset: usize) u8 {
    const ptr: *volatile u8 = @ptrFromInt(mmio_base + virtio.REG_CONFIG + offset);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    return ptr.*;
}

// --- Output helpers ---

fn writeHex8(val: u8) void {
    const hex = "0123456789abcdef";
    uart.writeByte(hex[@as(usize, val >> 4)]);
    uart.writeByte(hex[@as(usize, val & 0xf)]);
}
