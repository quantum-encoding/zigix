/// VirtIO block device driver — reads/writes disk sectors via legacy I/O port transport.

const io = @import("../arch/x86_64/io.zig");
const serial = @import("../arch/x86_64/serial.zig");
const pic = @import("../arch/x86_64/pic.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const pci = @import("pci.zig");
const virtio = @import("virtio.zig");

const SECTOR_SIZE: u32 = 512;

// VirtIO-blk request types
const VIRTIO_BLK_T_IN: u32 = 0; // read from disk
const VIRTIO_BLK_T_OUT: u32 = 1; // write to disk

// Request header (16 bytes)
const BlkReqHeader = extern struct {
    req_type: u32,
    reserved: u32,
    sector: u64,
};

// --- Static state ---

var io_base: u16 = 0;
var vq: virtio.VirtQueue = undefined;
var initialized: bool = false;

// DMA page for header + status (1 page)
var header_phys: u64 = 0;
var header_virt: u64 = 0;

// DMA page for data buffer (1 page)
var data_phys: u64 = 0;
var data_virt: u64 = 0;

var capacity: u64 = 0;
pub var irq: u8 = 0xFF; // set during init from PCI config

pub fn init(dev: *const pci.PciDevice) bool {
    // Enable PCI bus mastering (required for DMA)
    pci.enableBusMastering(dev);

    // Extract I/O base from BAR0
    const bar0 = dev.bar0;
    if (bar0 & 1 == 0) {
        serial.writeString("[blk]  BAR0 is MMIO, not I/O space — unsupported\n");
        return false;
    }
    io_base = @truncate(bar0 & 0xFFFFFFFC);

    // Read IRQ line
    irq = dev.irq_line;

    serial.writeString("[blk]  virtio-blk at I/O 0x");
    writeHex16(io_base);
    serial.writeString(", IRQ ");
    writeDecimal(irq);
    serial.writeString("\n");

    // Reset and initialize device
    virtio.initDevice(io_base);

    // Feature negotiation — accept nothing for MVP
    _ = virtio.readFeatures(io_base);
    virtio.writeFeatures(io_base, 0);

    // Initialize request queue (queue 0)
    if (virtio.initQueue(io_base, 0)) |q| {
        vq = q;
        serial.writeString("[blk]  Queue size: ");
        writeDecimal(vq.queue_size);
        serial.writeString("\n");
    } else {
        serial.writeString("[blk]  Failed to init queue\n");
        return false;
    }

    // Allocate DMA buffers
    header_phys = pmm.allocPage() orelse {
        serial.writeString("[blk]  Failed to alloc header page\n");
        return false;
    };
    header_virt = hhdm.physToVirt(header_phys);

    data_phys = pmm.allocPage() orelse {
        serial.writeString("[blk]  Failed to alloc data page\n");
        pmm.freePage(header_phys);
        return false;
    };
    data_virt = hhdm.physToVirt(data_phys);

    // Read capacity from device config (BAR0 + 0x14)
    // Legacy VirtIO: device-specific config starts at offset 0x14
    const cap_lo = io.inl(io_base + 0x14);
    const cap_hi = io.inl(io_base + 0x18);
    capacity = @as(u64, cap_hi) << 32 | @as(u64, cap_lo);

    serial.writeString("[blk]  Capacity: ");
    writeDecimal(capacity);
    serial.writeString(" sectors (");
    writeDecimal(capacity / 2); // sectors -> KiB (512 bytes each)
    serial.writeString(" KiB)\n");

    // Mark device as ready
    virtio.finishInit(io_base);

    // Unmask IRQ in PIC
    pic.setIrqMask(irq, false);

    initialized = true;
    return true;
}

pub fn readSectors(sector: u64, count: u32, buf: [*]u8) bool {
    if (!initialized) return false;

    // Fill request header
    const header: *volatile BlkReqHeader = @ptrFromInt(header_virt);
    header.req_type = VIRTIO_BLK_T_IN;
    header.reserved = 0;
    header.sector = sector;

    // Status byte at end of header page (offset 16)
    const status_phys = header_phys + 16;
    const status_ptr: *volatile u8 = @ptrFromInt(header_virt + 16);
    status_ptr.* = 0xFF; // sentinel

    const data_len = count * SECTOR_SIZE;

    // Allocate 3 chained descriptors
    const head = virtio.allocDescs(&vq, 3) orelse return false;
    const d1 = vq.desc[head].next;
    const d2 = vq.desc[d1].next;

    // D0: request header (device reads it)
    vq.desc[head].addr = header_phys;
    vq.desc[head].len = @sizeOf(BlkReqHeader);
    vq.desc[head].flags = virtio.VRING_DESC_F_NEXT;
    vq.desc[head].next = d1;

    // D1: data buffer (device writes into it)
    vq.desc[d1].addr = data_phys;
    vq.desc[d1].len = data_len;
    vq.desc[d1].flags = virtio.VRING_DESC_F_NEXT | virtio.VRING_DESC_F_WRITE;
    vq.desc[d1].next = d2;

    // D2: status byte (device writes it)
    vq.desc[d2].addr = status_phys;
    vq.desc[d2].len = 1;
    vq.desc[d2].flags = virtio.VRING_DESC_F_WRITE;

    // Submit and poll
    virtio.submitChain(&vq, head, io_base);

    if (virtio.pollUsed(&vq)) |_| {
        // Read ISR to clear interrupt
        _ = virtio.readIsrStatus(io_base);

        // Check status
        if (status_ptr.* != 0) {
            serial.writeString("[blk]  Read failed, status=");
            writeDecimal(status_ptr.*);
            serial.writeString("\n");
            virtio.freeDescs(&vq, head, 3);
            return false;
        }

        // Copy DMA data to caller buffer
        const src: [*]const u8 = @ptrFromInt(data_virt);
        for (0..data_len) |i| {
            buf[i] = src[i];
        }

        virtio.freeDescs(&vq, head, 3);
        return true;
    }

    virtio.freeDescs(&vq, head, 3);
    return false;
}

pub fn writeSectors(sector: u64, count: u32, buf: [*]const u8) bool {
    if (!initialized) return false;

    // Copy caller data to DMA buffer
    const data_len = count * SECTOR_SIZE;
    const dst: [*]u8 = @ptrFromInt(data_virt);
    for (0..data_len) |i| {
        dst[i] = buf[i];
    }

    // Fill request header
    const header: *volatile BlkReqHeader = @ptrFromInt(header_virt);
    header.req_type = VIRTIO_BLK_T_OUT;
    header.reserved = 0;
    header.sector = sector;

    // Status byte
    const status_phys = header_phys + 16;
    const status_ptr: *volatile u8 = @ptrFromInt(header_virt + 16);
    status_ptr.* = 0xFF;

    // Allocate 3 chained descriptors
    const head = virtio.allocDescs(&vq, 3) orelse return false;
    const d1 = vq.desc[head].next;
    const d2 = vq.desc[d1].next;

    // D0: request header (device reads)
    vq.desc[head].addr = header_phys;
    vq.desc[head].len = @sizeOf(BlkReqHeader);
    vq.desc[head].flags = virtio.VRING_DESC_F_NEXT;
    vq.desc[head].next = d1;

    // D1: data buffer (device reads — no WRITE flag)
    vq.desc[d1].addr = data_phys;
    vq.desc[d1].len = data_len;
    vq.desc[d1].flags = virtio.VRING_DESC_F_NEXT;
    vq.desc[d1].next = d2;

    // D2: status byte (device writes)
    vq.desc[d2].addr = status_phys;
    vq.desc[d2].len = 1;
    vq.desc[d2].flags = virtio.VRING_DESC_F_WRITE;

    // Submit and poll
    virtio.submitChain(&vq, head, io_base);

    if (virtio.pollUsed(&vq)) |_| {
        _ = virtio.readIsrStatus(io_base);

        if (status_ptr.* != 0) {
            serial.writeString("[blk]  Write failed, status=");
            writeDecimal(status_ptr.*);
            serial.writeString("\n");
            virtio.freeDescs(&vq, head, 3);
            return false;
        }

        virtio.freeDescs(&vq, head, 3);
        return true;
    }

    virtio.freeDescs(&vq, head, 3);
    return false;
}

pub fn handleIrq() void {
    // Read ISR to acknowledge interrupt (required even in polling mode)
    _ = virtio.readIsrStatus(io_base);
}

pub fn getCapacity() u64 {
    return capacity;
}

// --- Output helpers ---

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
