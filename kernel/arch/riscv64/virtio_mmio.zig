/// VirtIO MMIO transport layer — virtqueue setup and descriptor management.
///
/// QEMU virt machine places virtio-mmio devices at 0x0a000000-0x0a003e00,
/// each device occupying 0x200 bytes. Up to 32 devices, SPI interrupts 16-47
/// (GIC IRQ 48-79).
///
/// Uses the legacy (v1) virtio-mmio protocol for compatibility with QEMU's
/// default `-device virtio-blk-device` transport.

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");

const PAGE_SIZE: u64 = 4096;

// VirtIO MMIO register offsets (legacy, version 1)
pub const REG_MAGIC: usize = 0x000;         // R, 0x74726976 ("virt")
pub const REG_VERSION: usize = 0x004;       // R, device version (1=legacy, 2=modern)
pub const REG_DEVICE_ID: usize = 0x008;     // R, device type (1=net, 2=blk)
pub const REG_VENDOR_ID: usize = 0x00c;     // R, vendor ID
pub const REG_HOST_FEATURES: usize = 0x010; // R, device features
pub const REG_HOST_FEATURES_SEL: usize = 0x014; // W, feature bank select
pub const REG_GUEST_FEATURES: usize = 0x020;    // W, driver features
pub const REG_GUEST_FEATURES_SEL: usize = 0x024; // W, feature bank select
pub const REG_GUEST_PAGE_SIZE: usize = 0x028;    // W, page size (legacy v1)
pub const REG_QUEUE_SEL: usize = 0x030;     // W, select queue
pub const REG_QUEUE_NUM_MAX: usize = 0x034; // R, max queue size
pub const REG_QUEUE_NUM: usize = 0x038;     // W, current queue size
pub const REG_QUEUE_ALIGN: usize = 0x03c;   // W, queue alignment (legacy v1)
pub const REG_QUEUE_PFN: usize = 0x040;     // RW, queue PFN (legacy v1)
pub const REG_QUEUE_NOTIFY: usize = 0x050;  // W, queue notification
pub const REG_INTERRUPT_STATUS: usize = 0x060; // R, interrupt flags
pub const REG_INTERRUPT_ACK: usize = 0x064; // W, interrupt acknowledge
pub const REG_STATUS: usize = 0x070;        // RW, device status
pub const REG_CONFIG: usize = 0x100;        // RW, device-specific config

// VirtIO MMIO v2 (modern) queue setup registers
pub const REG_QUEUE_READY: usize = 0x044;       // RW, queue ready
pub const REG_QUEUE_DESC_LOW: usize = 0x080;     // W, desc table phys (low 32)
pub const REG_QUEUE_DESC_HIGH: usize = 0x084;    // W, desc table phys (high 32)
pub const REG_QUEUE_AVAIL_LOW: usize = 0x090;    // W, avail ring phys (low 32)
pub const REG_QUEUE_AVAIL_HIGH: usize = 0x094;   // W, avail ring phys (high 32)
pub const REG_QUEUE_USED_LOW: usize = 0x0a0;     // W, used ring phys (low 32)
pub const REG_QUEUE_USED_HIGH: usize = 0x0a4;    // W, used ring phys (high 32)

// Magic value
pub const VIRTIO_MMIO_MAGIC: u32 = 0x74726976; // "virt"

// Device IDs
pub const DEVICE_NET: u32 = 1;
pub const DEVICE_BLK: u32 = 2;
pub const DEVICE_CONSOLE: u32 = 3;
pub const DEVICE_RNG: u32 = 4;

// Device status bits
pub const STATUS_ACKNOWLEDGE: u32 = 1;
pub const STATUS_DRIVER: u32 = 2;
pub const STATUS_DRIVER_OK: u32 = 4;
pub const STATUS_FEATURES_OK: u32 = 8;

// Descriptor flags
pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2;

// QEMU RISC-V virt machine virtio-mmio layout
// Different from ARM64: base=0x10001000, stride=0x1000, IRQ starts at 1
pub const VIRTIO_MMIO_BASE: usize = 0x10001000;
pub const VIRTIO_MMIO_STRIDE: usize = 0x1000;
pub const VIRTIO_MMIO_COUNT: usize = 8;
pub const VIRTIO_IRQ_BASE: u32 = 1; // PLIC IRQ 1+

// --- MMIO access ---

inline fn mmioRead32(base: usize, offset: usize) u32 {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    return ptr.*;
}

inline fn mmioWrite32(base: usize, offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    ptr.* = value;
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

// --- Virtqueue structures ---

pub const VRingDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const VRingUsedElem = extern struct {
    id: u32,
    len: u32,
};

pub const VirtQueue = struct {
    queue_size: u16,
    base_phys: u64,
    base_virt: u64,
    desc: [*]VRingDesc,
    avail_flags: *volatile u16,
    avail_idx: *volatile u16,
    avail_ring: [*]volatile u16,
    used_flags: *volatile u16,
    used_idx: *volatile u16,
    used_ring: [*]volatile VRingUsedElem,
    free_head: u16,
    num_free: u16,
    last_used_idx: u16,
};

fn alignUp(val: u64, alignment: u64) u64 {
    return (val + alignment - 1) & ~(alignment - 1);
}

// --- ARM64 DMA cache maintenance ---
//
// ARM64 caches are NOT DMA-coherent: device DMA writes go to physical memory
// but the CPU D-cache may hold stale data (e.g., zeros from zeroPage()).
// Cache maintenance is required around every DMA transaction:
//   - CPU→device: clean (flush dirty cache lines to memory so device reads current data)
//   - device→CPU: invalidate (discard cache lines so CPU re-reads from memory)
//
// We use `dc civac` (clean+invalidate to Point of Coherency) for both directions
// because plain `dc ivac` can lose data if a dirty line exists. `dc civac` is safe
// in all cases: it writes back any dirty data first, then invalidates.

const CACHE_LINE_SIZE: u64 = 64;

/// Clean and invalidate a range of physical memory from the D-cache.
/// RISC-V is cache-coherent for DMA (no explicit cache maintenance needed).
/// A fence ensures ordering of memory accesses.
pub fn dmaCleanRange(_: u64, _: u64) void {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

/// Invalidate a range of physical memory from the D-cache.
/// RISC-V is cache-coherent for DMA (no explicit cache maintenance needed).
/// A fence ensures ordering of memory accesses.
pub fn dmaInvalidateRange(_: u64, _: u64) void {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

// --- Device discovery ---

pub const DeviceInfo = struct {
    base: usize,
    device_id: u32,
    irq: u32,
};

/// Probe a specific virtio-mmio slot. Returns device info if a valid device is found.
pub fn probeSlot(index: usize) ?DeviceInfo {
    if (index >= VIRTIO_MMIO_COUNT) return null;

    const base = VIRTIO_MMIO_BASE + index * VIRTIO_MMIO_STRIDE;
    const magic = mmioRead32(base, REG_MAGIC);
    if (magic != VIRTIO_MMIO_MAGIC) return null;

    const version = mmioRead32(base, REG_VERSION);
    if (version != 1 and version != 2) return null;

    const device_id = mmioRead32(base, REG_DEVICE_ID);
    if (device_id == 0) return null; // Empty slot

    return .{
        .base = base,
        .device_id = device_id,
        .irq = VIRTIO_IRQ_BASE + @as(u32, @truncate(index)),
    };
}

/// Scan all virtio-mmio slots and find a device by type.
pub fn findDevice(device_type: u32) ?DeviceInfo {
    for (0..VIRTIO_MMIO_COUNT) |i| {
        if (probeSlot(i)) |info| {
            if (info.device_id == device_type) return info;
        }
    }
    return null;
}

// --- Device initialization ---

pub fn initDevice(base: usize) void {
    // Reset device
    mmioWrite32(base, REG_STATUS, 0);

    // Set ACKNOWLEDGE
    mmioWrite32(base, REG_STATUS, STATUS_ACKNOWLEDGE);

    // Set DRIVER
    mmioWrite32(base, REG_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);
}

pub fn readFeatures(base: usize) u32 {
    mmioWrite32(base, REG_HOST_FEATURES_SEL, 0);
    return mmioRead32(base, REG_HOST_FEATURES);
}

pub fn writeFeatures(base: usize, features: u32) void {
    mmioWrite32(base, REG_GUEST_FEATURES_SEL, 0);
    mmioWrite32(base, REG_GUEST_FEATURES, features);
}

pub fn finishInit(base: usize) void {
    // For v2: set FEATURES_OK before DRIVER_OK
    const version = mmioRead32(base, REG_VERSION);
    if (version >= 2) {
        mmioWrite32(base, REG_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);
        // Verify FEATURES_OK was accepted
        const status = mmioRead32(base, REG_STATUS);
        if (status & STATUS_FEATURES_OK == 0) {
            uart.writeString("[virtio] FEATURES_OK not accepted!\n");
        }
    }
    mmioWrite32(base, REG_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
}

pub fn readInterruptStatus(base: usize) u32 {
    return mmioRead32(base, REG_INTERRUPT_STATUS);
}

pub fn ackInterrupt(base: usize, flags: u32) void {
    mmioWrite32(base, REG_INTERRUPT_ACK, flags);
}

// --- Queue setup ---

pub fn initQueue(base: usize, queue_idx: u16) ?VirtQueue {
    // Select queue
    mmioWrite32(base, REG_QUEUE_SEL, queue_idx);

    // Read max queue size
    const max_size = mmioRead32(base, REG_QUEUE_NUM_MAX);
    if (max_size == 0) return null;

    // Use max size (typically 128 or 256)
    const size: u16 = if (max_size > 256) 256 else @truncate(max_size);
    mmioWrite32(base, REG_QUEUE_NUM, size);

    // Calculate memory layout
    const desc_avail_size = @as(u64, size) * 16 + 6 + @as(u64, size) * 2;
    const used_offset = alignUp(desc_avail_size, PAGE_SIZE);
    const used_size: u64 = 6 + @as(u64, size) * 8;
    const total = used_offset + alignUp(used_size, PAGE_SIZE);
    const num_pages = total / PAGE_SIZE;

    // Allocate contiguous physical pages
    const phys = pmm.allocPages(num_pages) orelse return null;
    // Pin DMA pages — saturate ref count so PMM never reallocates them.
    {
        var pi: u64 = 0;
        while (pi < num_pages) : (pi += 1) {
            var j: u32 = 0;
            while (j < 100) : (j += 1) {
                pmm.incRef(phys + pi * PAGE_SIZE);
            }
        }
    }
    // ARM64 identity mapping: phys == virt
    const virt = phys;

    // Zero the allocation
    const ptr: [*]volatile u8 = @ptrFromInt(virt);
    for (0..total) |i| {
        ptr[i] = 0;
    }

    // Descriptor table at base
    const desc: [*]VRingDesc = @ptrFromInt(virt);

    // Build free descriptor chain — linear, NOT circular.
    // Last descriptor's next = 0xFFFF (sentinel, never a valid index).
    for (0..size) |i| {
        const idx: u16 = @intCast(i);
        desc[i].next = idx + 1;
        desc[i].flags = 0;
    }
    desc[size - 1].next = 0xFFFF; // sentinel — end of free list

    // Available ring: right after descriptors
    const avail_base = virt + @as(u64, size) * 16;
    const avail_flags: *volatile u16 = @ptrFromInt(avail_base);
    const avail_idx: *volatile u16 = @ptrFromInt(avail_base + 2);
    const avail_ring: [*]volatile u16 = @ptrFromInt(avail_base + 4);

    // Used ring at page-aligned offset
    const used_base = virt + used_offset;
    const used_flags: *volatile u16 = @ptrFromInt(used_base);
    const used_idx: *volatile u16 = @ptrFromInt(used_base + 2);
    const used_ring: [*]volatile VRingUsedElem = @ptrFromInt(used_base + 4);

    // Detect device version to use correct queue setup
    const version = mmioRead32(base, REG_VERSION);
    if (version >= 2) {
        // Modern (v2): write individual ring addresses + mark ready
        const avail_phys = phys + @as(u64, size) * 16; // desc table = size*16 bytes, avail follows
        const used_phys = phys + used_offset;
        mmioWrite32(base, REG_QUEUE_DESC_LOW, @truncate(phys));
        mmioWrite32(base, REG_QUEUE_DESC_HIGH, @truncate(phys >> 32));
        mmioWrite32(base, REG_QUEUE_AVAIL_LOW, @truncate(avail_phys));
        mmioWrite32(base, REG_QUEUE_AVAIL_HIGH, @truncate(avail_phys >> 32));
        mmioWrite32(base, REG_QUEUE_USED_LOW, @truncate(used_phys));
        mmioWrite32(base, REG_QUEUE_USED_HIGH, @truncate(used_phys >> 32));
        mmioWrite32(base, REG_QUEUE_READY, 1);
    } else {
        // Legacy (v1): page-granularity PFN
        mmioWrite32(base, REG_GUEST_PAGE_SIZE, @truncate(PAGE_SIZE));
        mmioWrite32(base, REG_QUEUE_ALIGN, @truncate(PAGE_SIZE));
        mmioWrite32(base, REG_QUEUE_PFN, @truncate(phys >> 12));
    }

    return VirtQueue{
        .queue_size = size,
        .base_phys = phys,
        .base_virt = virt,
        .desc = desc,
        .avail_flags = avail_flags,
        .avail_idx = avail_idx,
        .avail_ring = avail_ring,
        .used_flags = used_flags,
        .used_idx = used_idx,
        .used_ring = used_ring,
        .free_head = 0,
        .num_free = size,
        .last_used_idx = 0,
    };
}

// --- Descriptor allocation ---

pub fn allocDescs(vq: *VirtQueue, count: u16) ?u16 {
    if (vq.num_free < count) return null;

    const head = vq.free_head;
    // Validate head is within bounds
    if (head >= vq.queue_size) {
        uart.print("[virtio] BUG: allocDescs free_head={} >= queue_size={}\n", .{ head, vq.queue_size });
        return null;
    }

    var idx = head;
    var i: u16 = 0;
    while (i < count - 1) : (i += 1) {
        const next = vq.desc[idx].next;
        // Validate every index in the chain
        if (next >= vq.queue_size) {
            uart.print("[virtio] BUG: allocDescs chain broken at desc[{}].next={} (qs={})\n", .{ idx, next, vq.queue_size });
            return null;
        }
        idx = next;
    }
    vq.free_head = vq.desc[idx].next;
    vq.num_free -= count;

    return head;
}

pub fn freeDescs(vq: *VirtQueue, head: u16, count: u16) void {
    if (head >= vq.queue_size) {
        uart.print("[virtio] BUG: freeDescs head={} >= queue_size={}\n", .{ head, vq.queue_size });
        return;
    }
    var idx = head;
    var i: u16 = 0;
    while (i < count - 1) : (i += 1) {
        const next = vq.desc[idx].next;
        if (next >= vq.queue_size) {
            uart.print("[virtio] BUG: freeDescs chain broken at desc[{}].next={}\n", .{ idx, next });
            return;
        }
        idx = next;
    }
    vq.desc[idx].next = vq.free_head;
    vq.free_head = head;
    vq.num_free += count;
}

// --- Submit and poll ---

pub fn submitChain(vq: *VirtQueue, head: u16, base: usize) void {
    submitToQueue(vq, head, base, 0);
}

/// Submit a descriptor chain and notify a specific queue by index.
pub fn submitToQueue(vq: *VirtQueue, head: u16, base: usize, queue_idx: u32) void {
    if (vq.queue_size == 0 or base < VIRTIO_MMIO_BASE or base >= VIRTIO_MMIO_BASE + VIRTIO_MMIO_STRIDE * VIRTIO_MMIO_COUNT) {
        uart.print("[virtio] BUG: submitToQueue queue_size={} base={x} head={}\n", .{ vq.queue_size, base, head });
        return;
    }

    // Validate head index before publishing to device
    if (head >= vq.queue_size) {
        uart.print("[virtio] BUG: submitToQueue head={} >= qs={}\n", .{ head, vq.queue_size });
        return;
    }

    // Write descriptor head index to available ring
    const avail_slot = vq.avail_idx.* % vq.queue_size;
    vq.avail_ring[avail_slot] = head;

    // Memory barrier before updating avail_idx
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    // Bump available index
    vq.avail_idx.* +%= 1;

    // ARM64 DMA coherency: clean descriptor table and avail ring so the device
    // sees our writes (descriptor chain + avail_idx update).
    const desc_avail_bytes = @as(u64, vq.queue_size) * 16 + 6 + @as(u64, vq.queue_size) * 2;
    dmaCleanRange(vq.base_phys, desc_avail_bytes);

    // Notify device
    mmioWrite32(base, REG_QUEUE_NOTIFY, queue_idx);
}

pub fn pollUsed(vq: *VirtQueue, base: usize) ?VRingUsedElem {
    // Cache queue_size locally — the compiler may re-read from the struct
    // pointer after the WFE loop, and a concurrent BSS corruption could
    // cause a division-by-zero panic if it becomes 0 between check and use.
    const qs = vq.queue_size;
    if (qs == 0) {
        uart.print("[virtio] BUG: pollUsed queue_size=0 base={x} last_used={} free={}\n", .{ base, vq.last_used_idx, vq.num_free });
        return null;
    }

    // Validate MMIO base address (QEMU virt: 0x0a000000-0x0a004000)
    if (base < VIRTIO_MMIO_BASE or base >= VIRTIO_MMIO_BASE + VIRTIO_MMIO_STRIDE * VIRTIO_MMIO_COUNT) {
        uart.print("[virtio] BUG: pollUsed bad base={x}\n", .{base});
        return null;
    }

    // Validate used_idx pointer is in a sane range (PMM-allocated page, >= RAM_BASE)
    const used_ptr = @intFromPtr(vq.used_idx);
    if (used_ptr < 0x40000000 or used_ptr >= 0x140000000) {
        uart.print("[virtio] BUG: pollUsed used_idx={x} (corrupted vq pointer)\n", .{used_ptr});
        uart.print("  vq_addr={x} qs={} base_phys={x} desc={x}\n", .{
            @intFromPtr(vq), qs, vq.base_phys, @intFromPtr(vq.desc),
        });
        return null;
    }

    // Poll loop for QEMU HVF (Apple Silicon):
    //
    // On HVF, WFE is a NOP and WFI degenerates after the first timer IRQ.
    // Pure busy-spinning with ISB/DMB works but starves QEMU's I/O thread.
    //
    // Hybrid strategy: tight DMB spin for the first 100us (fast path for
    // most I/O), then switch to MMIO reads every 1000 iterations. Each
    // MMIO read causes a VMEXIT on HVF, giving QEMU's event loop a
    // chance to process the virtio request. Counter-based timeout.

    const timer = @import("timer.zig");
    const start_count = timer.readCounter();
    const freq = timer.readFrequency();
    const timeout_count = freq * 60; // 60-second timeout
    const fast_spin_count = freq / 10000; // ~100us of fast spinning
    var timed_out = false;
    var spins: u32 = 0;

    // ARM64 DMA coherency: invalidate used ring pages before polling.
    // The device writes to the used ring via DMA — CPU cache may have stale data.
    const desc_avail_size = @as(u64, qs) * 16 + 6 + @as(u64, qs) * 2;
    const used_ring_offset = alignUp(desc_avail_size, PAGE_SIZE);
    const used_ring_size: u64 = 6 + @as(u64, qs) * 8;
    const used_ring_phys = vq.base_phys + used_ring_offset;

    while (vq.used_idx.* == vq.last_used_idx) {
        const elapsed = timer.readCounter() -% start_count;

        // Invalidate used ring so CPU sees device's updated used_idx
        dmaInvalidateRange(used_ring_phys, alignUp(used_ring_size, CACHE_LINE_SIZE));

        // Fast path: tight DMB spin for first ~100us
        if (elapsed < fast_spin_count) {
            asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        } else {
            // Slow path: periodic MMIO read forces VMEXIT on HVF,
            // letting QEMU's I/O thread run on this vCPU's time slice.
            spins += 1;
            if (spins % 1000 == 0) {
                _ = mmioRead32(base, REG_MAGIC);
            } else {
                asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
            }
        }

        // Counter-based timeout
        if (elapsed > timeout_count) {
            uart.print("[virtio] poll timeout! used_idx={} last_used={} qs={} base={x} isr={x}\n", .{
                vq.used_idx.*, vq.last_used_idx, qs, base,
                readInterruptStatus(base),
            });
            timed_out = true;
            break;
        }
    }

    if (timed_out) {
        return null;
    }

    // Detect queue_size corruption during poll wait
    if (vq.queue_size != qs) {
        uart.print("[virtio] BUG: queue_size changed during poll! was={} now={} base={x}\n", .{ qs, vq.queue_size, base });
    }

    // Final invalidation + barrier: ensure we see the device's data/status writes
    // before reading them. The device writes data+status, then updates used_idx.
    // Under MTTCG, the CPU thread may see used_idx before data/status without
    // an explicit barrier.
    dmaInvalidateRange(used_ring_phys, alignUp(used_ring_size, CACHE_LINE_SIZE));
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    const slot = vq.last_used_idx % qs;
    const elem = vq.used_ring[slot];
    vq.last_used_idx +%= 1;

    return elem;
}
