/// VirtIO block device driver — reads/writes disk sectors via MMIO transport.
///
/// QEMU virt machine: `qemu-system-aarch64 -M virt -drive file=disk.img,format=raw,if=virtio`
/// The drive appears as a virtio-mmio device with DeviceID=2.

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const virtio = @import("virtio_mmio.zig");
const spinlock = @import("spinlock.zig");

const SECTOR_SIZE: u32 = 512;

// VirtIO-blk request types
const VIRTIO_BLK_T_IN: u32 = 0; // read from disk
const VIRTIO_BLK_T_OUT: u32 = 1; // write to disk

// Request header (16 bytes, matches VirtIO spec)
const BlkReqHeader = extern struct {
    req_type: u32,
    reserved: u32,
    sector: u64,
};

// --- Static state ---

pub var mmio_base: usize = 0;
var vq: virtio.VirtQueue = undefined;
var initialized: bool = false;
var device_broken: bool = false; // Set after virtio timeout — prevents cascading corruption

// DMA page for header + status
var header_phys: u64 = 0;

// DMA page for data buffer
var data_phys: u64 = 0;

// Snapshot of vq pointer fields from init — used to detect BSS corruption.
var init_used_idx_ptr: u64 = 0;
var init_desc_ptr: u64 = 0;
var init_base_phys: u64 = 0;

var capacity: u64 = 0;
pub var irq: u32 = 0;

// SMP lock: protects shared DMA buffers + virtqueue during I/O.
var blk_lock: spinlock.IrqSpinlock = .{};

pub fn init() bool {
    // Probe for a virtio-blk device
    const dev = virtio.findDevice(virtio.DEVICE_BLK) orelse {
        uart.writeString("[blk]  No virtio-blk device found\n");
        return false;
    };

    mmio_base = dev.base;
    irq = dev.irq;

    uart.print("[blk]  virtio-blk at {x}, IRQ {}\n", .{ mmio_base, irq });

    // Initialize device
    virtio.initDevice(mmio_base);

    // Feature negotiation — accept nothing for MVP
    _ = virtio.readFeatures(mmio_base);
    virtio.writeFeatures(mmio_base, 0);

    // Initialize request queue (queue 0)
    if (virtio.initQueue(mmio_base, 0)) |q| {
        vq = q;
        uart.print("[blk]  Queue size: {}\n", .{vq.queue_size});
    } else {
        uart.writeString("[blk]  Failed to init queue\n");
        return false;
    }

    // Allocate DMA buffers (identity mapped on ARM64)
    header_phys = pmm.allocPage() orelse {
        uart.writeString("[blk]  Failed to alloc header page\n");
        return false;
    };
    zeroPage(header_phys);

    data_phys = pmm.allocPage() orelse {
        uart.writeString("[blk]  Failed to alloc data page\n");
        pmm.freePage(header_phys);
        return false;
    };
    zeroPage(data_phys);

    // Read capacity from device config space (offset 0x100)
    // struct virtio_blk_config { u64 capacity; ... }
    const cap_lo: u64 = readConfig32(0);
    const cap_hi: u64 = readConfig32(4);
    capacity = (cap_hi << 32) | cap_lo;

    uart.print("[blk]  Capacity: {} sectors ({} KiB)\n", .{ capacity, capacity / 2 });

    // Mark device as ready
    virtio.finishInit(mmio_base);

    // Note: we use polled I/O (readSectors/writeSectors busy-wait on used ring),
    // so we intentionally do NOT enable this IRQ in the GIC. Enabling it would
    // cause IRQ floods because the device asserts the interrupt line on every
    // completed request, but nothing services it asynchronously.

    // Pin all DMA pages so they can NEVER be freed by a buggy freePage call.
    // Saturate ref_count to 65535 — permanently pinned, immune to double-free.
    pinDmaPages(vq.base_phys, vq.queue_size);
    pinDmaPage(header_phys);
    pinDmaPage(data_phys);

    // Snapshot critical pointer fields for corruption detection
    init_used_idx_ptr = @intFromPtr(vq.used_idx);
    init_desc_ptr = @intFromPtr(vq.desc);
    init_base_phys = vq.base_phys;

    uart.print("[blk]  vq at {x}, used_idx={x}, desc={x}, base_phys={x}\n", .{
        @intFromPtr(&vq), init_used_idx_ptr, init_desc_ptr, init_base_phys,
    });

    initialized = true;
    return true;
}

pub fn readSectors(sector: u64, count: u32, buf: [*]u8) bool {
    if (!initialized) return false;

    blk_lock.acquire();
    defer blk_lock.release();

    // After a poll timeout, the device has a pending request and the used ring
    // is out of sync. Any further I/O would see stale completions and return
    // wrong data. Reset the device and reinitialize to restore a clean state.
    if (device_broken) {
        uart.writeString("[blk]  Device broken, attempting reset...\n");
        if (!resetDevice()) return false;
    }

    // Integrity check — catch corruption of the module-level vq struct
    if (vq.queue_size == 0 or vq.queue_size > 256) {
        uart.print("[blk]  BUG: vq.queue_size corrupted! qs={} base_phys={x} sector={}\n", .{ vq.queue_size, vq.base_phys, sector });
        return false;
    }

    // Full pointer validation against init-time snapshot
    const cur_used_idx_ptr = @intFromPtr(vq.used_idx);
    const cur_desc_ptr = @intFromPtr(vq.desc);
    if (cur_used_idx_ptr != init_used_idx_ptr or cur_desc_ptr != init_desc_ptr or vq.base_phys != init_base_phys) {
        uart.print("[blk]  BUG: vq POINTERS corrupted! sector={}\n", .{sector});
        uart.print("  used_idx: init={x} now={x}\n", .{ init_used_idx_ptr, cur_used_idx_ptr });
        uart.print("  desc:     init={x} now={x}\n", .{ init_desc_ptr, cur_desc_ptr });
        uart.print("  base_ph:  init={x} now={x}\n", .{ init_base_phys, vq.base_phys });
        return false;
    }

    // Fill request header
    const header: *volatile BlkReqHeader = @ptrFromInt(header_phys);
    header.req_type = VIRTIO_BLK_T_IN;
    header.reserved = 0;
    header.sector = sector;

    // Status byte at offset 16 in header page
    const status_phys = header_phys + 16;
    const status_ptr: *volatile u8 = @ptrFromInt(header_phys + 16);
    status_ptr.* = 0xFF; // sentinel

    const data_len = count * SECTOR_SIZE;

    // ARM64 DMA coherency: clean header page (CPU writes → device reads),
    // invalidate data+status pages (device writes → CPU reads).
    // Without this, the CPU's D-cache may have stale data for the DMA buffers.
    virtio.dmaCleanRange(header_phys, 4096);
    virtio.dmaInvalidateRange(data_phys, 4096);
    virtio.dmaInvalidateRange(status_phys & ~@as(u64, 0xFFF), 4096);

    // Allocate 3 chained descriptors
    const head = virtio.allocDescs(&vq, 3) orelse return false;
    const d1 = vq.desc[head].next;
    const d2 = vq.desc[d1].next;

    // D0: request header (device reads)
    vq.desc[head].addr = header_phys;
    vq.desc[head].len = @sizeOf(BlkReqHeader);
    vq.desc[head].flags = virtio.VRING_DESC_F_NEXT;
    vq.desc[head].next = d1;

    // D1: data buffer (device writes)
    vq.desc[d1].addr = data_phys;
    vq.desc[d1].len = data_len;
    vq.desc[d1].flags = virtio.VRING_DESC_F_NEXT | virtio.VRING_DESC_F_WRITE;
    vq.desc[d1].next = d2;

    // D2: status byte (device writes)
    vq.desc[d2].addr = status_phys;
    vq.desc[d2].len = 1;
    vq.desc[d2].flags = virtio.VRING_DESC_F_WRITE;

    // Pre-poll integrity check: catch BSS corruption before entering poll loop
    if (vq.queue_size == 0 or mmio_base == 0) {
        uart.print("[blk]  BUG: PRE-POLL corruption! qs={} mmio={x} sector={}\n", .{ vq.queue_size, mmio_base, sector });
        virtio.freeDescs(&vq, head, 3);
        return false;
    }

    // Submit and poll
    virtio.submitChain(&vq, head, mmio_base);

    if (virtio.pollUsed(&vq, mmio_base)) |_| {
        // Memory barrier: ensure we see the device's data+status writes
        // BEFORE reading them. The VirtIO spec requires the device to write
        // data+status before updating used_idx, but under MTTCG the CPU
        // thread may see the used_idx update before the data/status writes
        // propagate through the host memory system.
        asm volatile ("dmb sy" ::: .{ .memory = true });

        // Acknowledge interrupt
        const isr = virtio.readInterruptStatus(mmio_base);
        virtio.ackInterrupt(mmio_base, isr);

        // ARM64 DMA coherency: invalidate data+status pages AFTER DMA completes
        // to ensure CPU sees the device-written data, not stale cache lines.
        virtio.dmaInvalidateRange(data_phys, 4096);
        virtio.dmaInvalidateRange(status_phys & ~@as(u64, 0xFFF), 4096);

        if (status_ptr.* != 0) {
            const S = struct { var err_count: u32 = 0; };
            S.err_count += 1;
            if (S.err_count <= 3 or S.err_count % 1000 == 0) {
                uart.print("[blk]  Read failed, status={} (count={})\n", .{ status_ptr.*, S.err_count });
            }
            virtio.freeDescs(&vq, head, 3);
            return false;
        }

        // Copy DMA data to caller buffer
        const src: [*]const u8 = @ptrFromInt(data_phys);
        for (0..data_len) |i| {
            buf[i] = src[i];
        }

        virtio.freeDescs(&vq, head, 3);
        return true;
    }

    // CRITICAL: Do NOT free descriptors after poll timeout. The device still has
    // the request pending and may complete it asynchronously. Freeing and reusing
    // the descriptors would cause the next request to see stale completions,
    // returning wrong data and cascading into code corruption/crashes.
    uart.print("[blk]  Poll timeout on sector {} — marking device broken\n", .{sector});
    device_broken = true;
    return false;
}

pub fn writeSectors(sector: u64, count: u32, buf: [*]const u8) bool {
    if (!initialized) return false;

    blk_lock.acquire();
    defer blk_lock.release();

    if (device_broken) {
        if (!resetDevice()) return false;
    }

    // Integrity check
    if (vq.queue_size == 0 or vq.queue_size > 256) {
        uart.print("[blk]  BUG: vq.queue_size corrupted! qs={} base_phys={x} sector={}\n", .{ vq.queue_size, vq.base_phys, sector });
        return false;
    }
    const cur_used_idx_ptr = @intFromPtr(vq.used_idx);
    if (cur_used_idx_ptr != init_used_idx_ptr or vq.base_phys != init_base_phys) {
        uart.print("[blk]  BUG: vq POINTERS corrupted (write)! sector={}\n", .{sector});
        return false;
    }

    // Copy caller data to DMA buffer
    const data_len = count * SECTOR_SIZE;
    const dst: [*]u8 = @ptrFromInt(data_phys);
    for (0..data_len) |i| {
        dst[i] = buf[i];
    }

    // Fill request header
    const header: *volatile BlkReqHeader = @ptrFromInt(header_phys);
    header.req_type = VIRTIO_BLK_T_OUT;
    header.reserved = 0;
    header.sector = sector;

    // Status byte
    const status_phys = header_phys + 16;
    const status_ptr: *volatile u8 = @ptrFromInt(header_phys + 16);
    status_ptr.* = 0xFF;

    // ARM64 DMA coherency: clean header+data pages (CPU writes → device reads),
    // invalidate status page (device writes → CPU reads).
    virtio.dmaCleanRange(header_phys, 4096);
    virtio.dmaCleanRange(data_phys, 4096);
    virtio.dmaInvalidateRange(status_phys & ~@as(u64, 0xFFF), 4096);

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
    virtio.submitChain(&vq, head, mmio_base);

    if (virtio.pollUsed(&vq, mmio_base)) |_| {
        asm volatile ("dmb sy" ::: .{ .memory = true });

        const isr = virtio.readInterruptStatus(mmio_base);
        virtio.ackInterrupt(mmio_base, isr);

        // Invalidate status after DMA completes
        virtio.dmaInvalidateRange(status_phys & ~@as(u64, 0xFFF), 4096);

        if (status_ptr.* != 0) {
            uart.print("[blk]  Write failed, status={}\n", .{status_ptr.*});
            virtio.freeDescs(&vq, head, 3);
            return false;
        }

        virtio.freeDescs(&vq, head, 3);
        return true;
    }

    uart.print("[blk]  Write poll timeout on sector {} — marking device broken\n", .{sector});
    device_broken = true;
    return false;
}

pub fn handleIrq() void {
    const isr = virtio.readInterruptStatus(mmio_base);
    virtio.ackInterrupt(mmio_base, isr);
}

pub fn getCapacity() u64 {
    return capacity;
}

pub fn isInitialized() bool {
    return initialized;
}

/// Reset the VirtIO device after a poll timeout to restore a clean state.
/// After timeout, the device may have pending requests — resetting clears them.
/// Must be called with blk_lock held.
fn resetDevice() bool {
    uart.writeString("[blk]  Resetting virtio-blk device...\n");

    // Reset device (writes 0 to status register)
    virtio.initDevice(mmio_base);

    // Re-negotiate features
    _ = virtio.readFeatures(mmio_base);
    virtio.writeFeatures(mmio_base, 0);

    // Re-initialize queue (allocates new DMA pages — old ones are leaked but pinned)
    if (virtio.initQueue(mmio_base, 0)) |q| {
        vq = q;
    } else {
        uart.writeString("[blk]  Queue reinit failed!\n");
        return false;
    }

    // Pin new DMA pages
    pinDmaPages(vq.base_phys, vq.queue_size);

    // Update snapshots
    init_used_idx_ptr = @intFromPtr(vq.used_idx);
    init_desc_ptr = @intFromPtr(vq.desc);
    init_base_phys = vq.base_phys;

    // Mark device ready
    virtio.finishInit(mmio_base);

    device_broken = false;
    uart.writeString("[blk]  Device reset complete\n");
    return true;
}

fn readConfig32(offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + virtio.REG_CONFIG + offset);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    return ptr.*;
}

/// Pin a single DMA page by saturating its ref count.
fn pinDmaPage(phys: u64) void {
    // Saturate ref count: incRef 100 times to quickly reach saturation-safe level.
    // At saturation (65535), pmm refuses to free the page.
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        pmm.incRef(phys);
    }
}

/// Pin all pages in a VirtQueue DMA allocation.
fn pinDmaPages(base_phys: u64, queue_size: u16) void {
    // VirtQueue layout: desc+avail pages, then page-aligned used ring pages
    const desc_avail_size = @as(u64, queue_size) * 16 + 6 + @as(u64, queue_size) * 2;
    const used_offset = (desc_avail_size + 4095) & ~@as(u64, 4095);
    const used_size: u64 = 6 + @as(u64, queue_size) * 8;
    const total = used_offset + ((used_size + 4095) & ~@as(u64, 4095));
    const num_pages = total / 4096;

    var p: u64 = 0;
    while (p < num_pages) : (p += 1) {
        pinDmaPage(base_phys + p * 4096);
    }
    uart.print("[blk]  Pinned {} DMA pages at {x}\n", .{ num_pages, base_phys });
}

fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..4096) |i| {
        ptr[i] = 0;
    }
}
