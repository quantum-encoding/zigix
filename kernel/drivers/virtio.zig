/// VirtIO legacy (I/O port) transport layer — virtqueue setup and descriptor management.

const io = @import("../arch/x86_64/io.zig");
const serial = @import("../arch/x86_64/serial.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const types = @import("../types.zig");

const PAGE_SIZE = types.PAGE_SIZE;

// Legacy VirtIO register offsets from BAR0
pub const REG_DEVICE_FEATURES: u16 = 0x00; // 4 bytes, R
pub const REG_GUEST_FEATURES: u16 = 0x04; // 4 bytes, W
pub const REG_QUEUE_PFN: u16 = 0x08; // 4 bytes, RW
pub const REG_QUEUE_SIZE: u16 = 0x0C; // 2 bytes, R
pub const REG_QUEUE_SELECT: u16 = 0x0E; // 2 bytes, W
pub const REG_QUEUE_NOTIFY: u16 = 0x10; // 2 bytes, W
pub const REG_DEVICE_STATUS: u16 = 0x12; // 1 byte, RW
pub const REG_ISR_STATUS: u16 = 0x13; // 1 byte, R

// Device status bits
pub const STATUS_ACKNOWLEDGE: u8 = 1;
pub const STATUS_DRIVER: u8 = 2;
pub const STATUS_DRIVER_OK: u8 = 4;
pub const STATUS_FEATURES_OK: u8 = 8;

// Descriptor flags
pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2; // device writes (buffer is writable by device)

// --- Virtqueue structures ---

pub const VRingDesc = extern struct {
    addr: u64, // physical address of buffer
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

    // Descriptor table
    desc: [*]VRingDesc,

    // Available ring (written by driver, read by device)
    avail_flags: *volatile u16,
    avail_idx: *volatile u16,
    avail_ring: [*]volatile u16,

    // Used ring (written by device, read by driver)
    used_flags: *volatile u16,
    used_idx: *volatile u16,
    used_ring: [*]volatile VRingUsedElem,

    // Free descriptor tracking
    free_head: u16,
    num_free: u16,
    last_used_idx: u16,
};

fn alignUp(val: u64, alignment: u64) u64 {
    return (val + alignment - 1) & ~(alignment - 1);
}

// --- Device initialization ---

pub fn initDevice(io_base: u16) void {
    // Reset device
    io.outb(io_base + REG_DEVICE_STATUS, 0);

    // Set ACKNOWLEDGE
    io.outb(io_base + REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE);

    // Set DRIVER
    io.outb(io_base + REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);
}

pub fn readFeatures(io_base: u16) u32 {
    return io.inl(io_base + REG_DEVICE_FEATURES);
}

pub fn writeFeatures(io_base: u16, features: u32) void {
    io.outl(io_base + REG_GUEST_FEATURES, features);
}

pub fn readIsrStatus(io_base: u16) u8 {
    return io.inb(io_base + REG_ISR_STATUS);
}

pub fn finishInit(io_base: u16) void {
    io.outb(io_base + REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);
}

// --- Queue setup ---

pub fn initQueue(io_base: u16, queue_idx: u16) ?VirtQueue {
    // Select queue
    io.outw(io_base + REG_QUEUE_SELECT, queue_idx);

    // Read queue size
    const size = io.inw(io_base + REG_QUEUE_SIZE);
    if (size == 0) return null;

    // Layout calculation (legacy VirtIO spec):
    // Descriptors: size * 16 bytes
    // Available ring: 2 (flags) + 2 (idx) + size * 2 (ring entries) + 2 (used_event, optional)
    // Used ring starts at next page boundary
    // Used ring: 2 (flags) + 2 (idx) + size * 8 (used elements) + 2 (avail_event, optional)
    const desc_avail_size = @as(u64, size) * 16 + 6 + @as(u64, size) * 2;
    const used_offset = alignUp(desc_avail_size, PAGE_SIZE);
    const used_size: u64 = 6 + @as(u64, size) * 8;
    const total = used_offset + alignUp(used_size, PAGE_SIZE);
    const num_pages = total / PAGE_SIZE;

    // Allocate contiguous physical pages
    const phys = pmm.allocPages(num_pages) orelse return null;
    const virt = hhdm.physToVirt(phys);

    // Zero the entire allocation
    const ptr: [*]volatile u8 = @ptrFromInt(virt);
    for (0..total) |i| {
        ptr[i] = 0;
    }

    // Set up descriptor table at base
    const desc: [*]VRingDesc = @ptrFromInt(virt);

    // Build free descriptor chain
    for (0..size) |i| {
        const idx: u16 = @intCast(i);
        desc[i].next = idx + 1;
        desc[i].flags = 0;
    }
    // Last descriptor has no next
    desc[size - 1].next = 0;

    // Available ring: right after descriptors
    const avail_base = virt + @as(u64, size) * 16;
    const avail_flags: *volatile u16 = @ptrFromInt(avail_base);
    const avail_idx: *volatile u16 = @ptrFromInt(avail_base + 2);
    const avail_ring: [*]volatile u16 = @ptrFromInt(avail_base + 4);

    // Used ring: at page-aligned offset
    const used_base = virt + used_offset;
    const used_flags: *volatile u16 = @ptrFromInt(used_base);
    const used_idx: *volatile u16 = @ptrFromInt(used_base + 2);
    const used_ring: [*]volatile VRingUsedElem = @ptrFromInt(used_base + 4);

    // Tell device the queue PFN (physical page frame number)
    io.outl(io_base + REG_QUEUE_PFN, @truncate(phys >> 12));

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
    var idx = head;
    var i: u16 = 0;
    while (i < count - 1) : (i += 1) {
        idx = vq.desc[idx].next;
    }
    // idx is now the last descriptor in the chain we're allocating
    vq.free_head = vq.desc[idx].next;
    vq.num_free -= count;

    return head;
}

pub fn freeDescs(vq: *VirtQueue, head: u16, count: u16) void {
    var idx = head;
    var i: u16 = 0;
    while (i < count - 1) : (i += 1) {
        idx = vq.desc[idx].next;
    }
    // Link last freed descriptor to current free head
    vq.desc[idx].next = vq.free_head;
    vq.free_head = head;
    vq.num_free += count;
}

// --- Submit and poll ---

pub fn submitChain(vq: *VirtQueue, head: u16, io_base: u16) void {
    // Write descriptor head index to available ring
    const avail_slot = vq.avail_idx.* % vq.queue_size;
    vq.avail_ring[avail_slot] = head;

    // Memory barrier before updating avail_idx
    asm volatile ("mfence" ::: .{ .memory = true });

    // Bump available index
    vq.avail_idx.* +%= 1;

    // Memory barrier before notification
    asm volatile ("mfence" ::: .{ .memory = true });

    // Notify device
    io.outw(io_base + REG_QUEUE_NOTIFY, 0);
}

/// Submit a descriptor chain and notify a specific queue index.
/// Same as submitChain but writes queue_idx to QUEUE_NOTIFY instead of 0.
pub fn submitChainToQueue(vq: *VirtQueue, head: u16, io_base: u16, queue_idx: u16) void {
    // Write descriptor head index to available ring
    const avail_slot = vq.avail_idx.* % vq.queue_size;
    vq.avail_ring[avail_slot] = head;

    // Memory barrier before updating avail_idx
    asm volatile ("mfence" ::: .{ .memory = true });

    // Bump available index
    vq.avail_idx.* +%= 1;

    // Memory barrier before notification
    asm volatile ("mfence" ::: .{ .memory = true });

    // Notify device with specific queue index
    io.outw(io_base + REG_QUEUE_NOTIFY, queue_idx);
}

pub fn pollUsed(vq: *VirtQueue) ?VRingUsedElem {
    // Spin until device increments used_idx
    var spins: u32 = 0;
    while (vq.used_idx.* == vq.last_used_idx) {
        asm volatile ("pause");
        spins += 1;
        if (spins > 100_000_000) {
            serial.writeString("[virtio] poll timeout!\n");
            return null;
        }
    }

    // Read used element
    const slot = vq.last_used_idx % vq.queue_size;
    const elem = vq.used_ring[slot];
    vq.last_used_idx +%= 1;

    return elem;
}
