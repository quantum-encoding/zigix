/// Zero-copy shared ring for userspace packet processing.
///
/// Architecture:
///   Kernel allocates contiguous physical pages for a shared ring region.
///   These pages are mapped into both kernel (identity map) and userspace.
///   The hot path has zero kernel involvement — userspace polls ring indices
///   directly, reads packet data from the shared buffer pool, and advances
///   the consumer pointer. No syscall, no interrupt, no copy on RX consume.
///
/// Memory layout (contiguous physical region):
///   Page 0:     RingHeader (control metadata, 64-byte aligned indices)
///   Page 1:     RX descriptor ring (256 entries × 16 bytes = 4096 bytes)
///   Page 2:     TX descriptor ring (256 entries × 16 bytes = 4096 bytes)
///   Pages 3-66: Packet buffer pool (64 buffers × 4096 bytes each)
///
/// RX path (kernel → userspace):
///   1. Virtio IRQ fires, packet lands in virtio DMA buffer
///   2. Kernel copies frame into next free shared pool buffer (one copy)
///   3. Kernel writes RX descriptor and advances rx_prod (store-release)
///   4. Userspace polls rx_prod, reads packet from buffer pool (zero copy)
///   5. Userspace advances rx_cons — kernel reclaims buffer
///
/// TX path (userspace → kernel):
///   1. Userspace writes packet into shared pool buffer
///   2. Userspace writes TX descriptor and advances tx_prod
///   3. Kernel polls tx_prod, submits buffer to virtio (zero copy from pool)
///   4. Kernel advances tx_cons — userspace can reuse buffer
///
/// Synchronization: ARM64 DMB barriers (no locks needed for SPSC ring)

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const process_mod = @import("process.zig");
const nic = @import("nic.zig");

/// Ring and buffer configuration
pub const RING_SIZE: u32 = 256;
pub const BUF_COUNT: u32 = 64;
pub const BUF_SIZE: u32 = 4096;

const HEADER_PAGES: u32 = 1;
const RX_RING_PAGES: u32 = 1;
const TX_RING_PAGES: u32 = 1;
const BUF_PAGES: u32 = BUF_COUNT;
pub const TOTAL_PAGES: u32 = HEADER_PAGES + RX_RING_PAGES + TX_RING_PAGES + BUF_PAGES;

/// Magic number: "ZNT0" — Zigix Net Transport v0
const MAGIC: u32 = 0x5A4E5430;
const VERSION: u32 = 1;

/// Packet descriptor in shared ring (16 bytes, 256 per page)
pub const PacketDesc = extern struct {
    buf_idx: u32,
    length: u32,
    flags: u32,
    _pad: u32,
};

/// Shared ring header — first 64 bytes of page 0, visible to userspace.
/// Indices are 64-byte aligned to avoid false sharing across cache lines.
pub const RingHeader = extern struct {
    magic: u32,
    version: u32,
    ring_size: u32,
    buf_count: u32,
    buf_size: u32,
    _reserved0: [3]u32,        // pad to 32 bytes

    rx_prod: u32 align(64),    // kernel writes
    _pad_rx_prod: [15]u32,

    rx_cons: u32 align(64),    // userspace writes
    _pad_rx_cons: [15]u32,

    tx_prod: u32 align(64),    // userspace writes
    _pad_tx_prod: [15]u32,

    tx_cons: u32 align(64),    // kernel writes
    _pad_tx_cons: [15]u32,
};

/// Kernel-side shared ring state
pub const NetRing = struct {
    phys_base: u64,
    header: *volatile RingHeader,
    rx_ring: [*]volatile PacketDesc,
    tx_ring: [*]volatile PacketDesc,
    buf_base: u64,

    /// Track which buffers are allocated
    buf_in_use: [BUF_COUNT]bool,
    free_stack: [BUF_COUNT]u32,
    free_count: u32,

    /// Kernel-side tracking of last-reclaimed rx_cons
    kernel_rx_cons: u32,

    owner_pid: u64,
    user_base: u64,
    active: bool,
};

var ring: NetRing = undefined;
var ring_initialized: bool = false;

/// Create the shared ring region: allocate contiguous physical pages.
pub fn create() ?*NetRing {
    if (ring_initialized) return &ring;

    // Allocate first page
    const base = pmm.allocPage() orelse {
        uart.writeString("[net-ring] Failed to alloc header page\n");
        return null;
    };

    // Allocate remaining pages, verify contiguity
    var i: u32 = 1;
    while (i < TOTAL_PAGES) : (i += 1) {
        const page = pmm.allocPage() orelse {
            uart.print("[net-ring] Failed to alloc page {}\n", .{i});
            freePages(base, i);
            return null;
        };
        if (page != base + @as(u64, i) * 4096) {
            uart.writeString("[net-ring] Pages not contiguous\n");
            pmm.freePage(page);
            freePages(base, i);
            return null;
        }
    }

    // Identity mapping: phys == virt
    ring.phys_base = base;
    ring.header = @ptrFromInt(base);
    ring.rx_ring = @ptrFromInt(base + HEADER_PAGES * 4096);
    ring.tx_ring = @ptrFromInt(base + (HEADER_PAGES + RX_RING_PAGES) * 4096);
    ring.buf_base = base + (HEADER_PAGES + RX_RING_PAGES + TX_RING_PAGES) * 4096;

    // Initialize header
    ring.header.magic = MAGIC;
    ring.header.version = VERSION;
    ring.header.ring_size = RING_SIZE;
    ring.header.buf_count = BUF_COUNT;
    ring.header.buf_size = BUF_SIZE;
    ring.header.rx_prod = 0;
    ring.header.rx_cons = 0;
    ring.header.tx_prod = 0;
    ring.header.tx_cons = 0;

    // Initialize descriptor rings to zero
    for (0..RING_SIZE) |idx| {
        ring.rx_ring[idx] = .{ .buf_idx = 0, .length = 0, .flags = 0, ._pad = 0 };
        ring.tx_ring[idx] = .{ .buf_idx = 0, .length = 0, .flags = 0, ._pad = 0 };
    }

    // Initialize free buffer pool (stack-based allocator)
    ring.free_count = BUF_COUNT;
    for (0..BUF_COUNT) |idx| {
        ring.free_stack[idx] = @intCast(idx);
        ring.buf_in_use[idx] = false;
    }

    // Zero all buffer pages
    const pool_ptr: [*]u8 = @ptrFromInt(ring.buf_base);
    for (0..BUF_COUNT * BUF_SIZE) |offset| {
        pool_ptr[offset] = 0;
    }

    ring.kernel_rx_cons = 0;
    ring.owner_pid = 0;
    ring.user_base = 0;
    ring.active = false;
    ring_initialized = true;

    uart.print("[net-ring] Created: 0x{x}, {} pages ({} KB)\n", .{
        base, TOTAL_PAGES, TOTAL_PAGES * 4,
    });

    return &ring;
}

/// Attach ring to a process: map shared pages into the process address space.
/// Returns the userspace virtual address of the mapped region.
pub fn attach(proc: *process_mod.Process) ?u64 {
    if (!ring_initialized) {
        _ = create() orelse return null;
    }

    if (ring.active) {
        uart.writeString("[net-ring] Already attached\n");
        return null;
    }

    // Map into userspace at a fixed address above the code segment
    const user_base: u64 = 0x300000;
    const page_table = proc.page_table;
    if (page_table == 0) return null;

    var i: u32 = 0;
    while (i < TOTAL_PAGES) : (i += 1) {
        const phys = ring.phys_base + @as(u64, i) * 4096;
        const virt = user_base + @as(u64, i) * 4096;
        vmm.mapPage(vmm.PhysAddr.from(page_table), vmm.VirtAddr.from(virt), vmm.PhysAddr.from(phys), .{
            .writable = true,
            .user = true,
            .executable = false,
        }) catch {
            uart.print("[net-ring] Map failed: page {} at 0x{x}\n", .{ i, virt });
            return null;
        };
    }

    ring.owner_pid = proc.pid;
    ring.user_base = user_base;
    ring.active = true;

    uart.print("[net-ring] Attached PID {}, user 0x{x}, {} pages\n", .{
        proc.pid, user_base, TOTAL_PAGES,
    });

    return user_base;
}

/// Detach ring from process (called on process exit)
pub fn detach(pid: u64) void {
    if (!ring_initialized or !ring.active) return;
    if (ring.owner_pid != pid) return;

    ring.active = false;
    ring.owner_pid = 0;
    ring.user_base = 0;

    // Reset ring indices
    ring.header.rx_prod = 0;
    ring.header.rx_cons = 0;
    ring.header.tx_prod = 0;
    ring.header.tx_cons = 0;
    ring.kernel_rx_cons = 0;

    // Return all buffers to free pool
    ring.free_count = BUF_COUNT;
    for (0..BUF_COUNT) |idx| {
        ring.free_stack[idx] = @intCast(idx);
        ring.buf_in_use[idx] = false;
    }

    uart.print("[net-ring] Detached PID {}\n", .{pid});
}

/// Deliver a received packet to the shared RX ring.
/// Called from virtio-net IRQ handler or poll context.
/// Returns true if packet was delivered to userspace ring.
pub fn deliverRx(data: []const u8) bool {
    if (!ring_initialized or !ring.active) return false;

    const prod = ring.header.rx_prod;
    const cons = ring.header.rx_cons;

    // Ring full?
    if (prod -% cons >= RING_SIZE) return false;

    // Allocate a buffer from the pool
    const buf_idx = allocBuf() orelse return false;

    // Copy packet into shared buffer (this is the single copy)
    const dst: [*]u8 = @ptrFromInt(ring.buf_base + @as(u64, buf_idx) * BUF_SIZE);
    const len = @min(data.len, BUF_SIZE);
    @memcpy(dst[0..len], data[0..len]);

    // Write descriptor
    const slot = prod % RING_SIZE;
    ring.rx_ring[slot].buf_idx = buf_idx;
    ring.rx_ring[slot].length = @intCast(len);
    ring.rx_ring[slot].flags = 0;

    // Store-release barrier: descriptor must be visible before prod update
    asm volatile ("dmb ishst" ::: .{ .memory = true });

    ring.header.rx_prod = prod +% 1;
    return true;
}

/// Reclaim buffers that userspace has consumed (rx_cons advanced).
/// Called periodically from timer/poll context.
pub fn reclaimRx() void {
    if (!ring_initialized or !ring.active) return;

    // Load-acquire: read userspace's consumer index
    asm volatile ("dmb ishld" ::: .{ .memory = true });
    const cons = ring.header.rx_cons;

    while (ring.kernel_rx_cons != cons) {
        const slot = ring.kernel_rx_cons % RING_SIZE;
        freeBuf(ring.rx_ring[slot].buf_idx);
        ring.kernel_rx_cons +%= 1;
    }
}

/// Process TX ring: transmit packets that userspace has queued.
/// Called periodically from timer/poll context.
pub fn processTx() void {
    if (!ring_initialized or !ring.active) return;

    // Load-acquire: read userspace's producer index
    asm volatile ("dmb ishld" ::: .{ .memory = true });
    const prod = ring.header.tx_prod;
    var cons = ring.header.tx_cons;

    while (cons != prod) {
        const slot = cons % RING_SIZE;
        const buf_idx = ring.tx_ring[slot].buf_idx;
        const length = ring.tx_ring[slot].length;

        if (buf_idx < BUF_COUNT and length > 0 and length <= BUF_SIZE) {
            const src: [*]const u8 = @ptrFromInt(ring.buf_base + @as(u64, buf_idx) * BUF_SIZE);
            _ = nic.transmit(src[0..length]);
            freeBuf(buf_idx);
        }

        cons +%= 1;
    }

    // Store-release: update consumer index
    asm volatile ("dmb ishst" ::: .{ .memory = true });
    ring.header.tx_cons = cons;
}

/// Periodic poll — called from timer tick or net.poll()
pub fn poll() void {
    if (!ring_initialized or !ring.active) return;
    reclaimRx();
    processTx();
}

pub fn isActive() bool {
    return ring_initialized and ring.active;
}

pub fn getRing() ?*NetRing {
    if (!ring_initialized) return null;
    return &ring;
}

/// Get the user-visible base address (for returning from syscall)
pub fn getUserBase() u64 {
    return ring.user_base;
}

/// Get total size of the shared region in bytes
pub fn getRegionSize() u64 {
    return @as(u64, TOTAL_PAGES) * 4096;
}

// --- Internal helpers ---

fn allocBuf() ?u32 {
    if (ring.free_count == 0) return null;
    ring.free_count -= 1;
    const idx = ring.free_stack[ring.free_count];
    ring.buf_in_use[idx] = true;
    return idx;
}

fn freeBuf(idx: u32) void {
    if (idx >= BUF_COUNT) return;
    if (!ring.buf_in_use[idx]) return;
    ring.buf_in_use[idx] = false;
    ring.free_stack[ring.free_count] = idx;
    ring.free_count += 1;
}

fn freePages(base: u64, count: u32) void {
    var j: u32 = 0;
    while (j < count) : (j += 1) {
        pmm.freePage(base + @as(u64, j) * 4096);
    }
}
