/// Zero-copy networking — shared-memory packet ring between kernel and userspace.
///
/// Layout (5 contiguous pages = 20 KiB):
///   Page 0: Control page (rx/tx producer/consumer indices + descriptor rings + stats)
///   Pages 1-4: Buffer pool (32 x 2048-byte packet buffers)
///
/// RX: kernel posts buffers to virtio RX; on IRQ, writes descriptor → userspace polls.
/// TX: userspace writes buffer + descriptor → kernel drains on timer (or kick syscall).
/// Hot path has zero syscalls — pure shared-memory polling.

const serial = @import("../arch/x86_64/serial.zig");
const idt = @import("../arch/x86_64/idt.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const vmm = @import("../mm/vmm.zig");
const vma = @import("../mm/vma.zig");
const types = @import("../types.zig");
const process = @import("../proc/process.zig");
const scheduler = @import("../proc/scheduler.zig");
const errno = @import("../proc/errno.zig");
const virtio_net = @import("../drivers/nic.zig");

const PAGE_SIZE = types.PAGE_SIZE;

// Shared region mapped at this fixed user virtual address
pub const ZCNET_USER_BASE: u64 = 0x6F00_0000_0000;
const SHARED_PAGES: u64 = 5; // 1 control + 4 buffer
const RING_SIZE: u32 = 32;
const BUF_SIZE: usize = 2048;
const NET_HDR_SIZE: usize = 10; // virtio net header
const MAX_FRAME: u16 = 1514; // max Ethernet frame

/// Descriptor in the shared ring (8 bytes, matches userspace layout).
const ZcDesc = extern struct {
    buf_idx: u16,
    len: u16,
    flags: u16,
    _pad: u16,
};

const DESC_FLAG_VALID: u16 = 1;

// --- Module state ---

var active: bool = false;
var owner_pid: u32 = 0;
var shared_phys: u64 = 0;

// Volatile pointers into the control page (kernel-side, via HHDM)
var rx_prod: *volatile u32 = undefined;
var rx_cons: *volatile u32 = undefined;
var rx_descs: [*]volatile ZcDesc = undefined;
var tx_prod: *volatile u32 = undefined;
var tx_cons: *volatile u32 = undefined;
var tx_descs: [*]volatile ZcDesc = undefined;
var stats_rx_count: *volatile u32 = undefined;
var stats_tx_count: *volatile u32 = undefined;
var stats_rx_drops: *volatile u32 = undefined;

/// Bitmask: bit N set means buffer N is currently posted to the virtio RX queue.
var posted_mask: u32 = 0;

// --- Syscall handlers ---

/// zcnet_attach(500) — allocate shared region, map into userspace, return base addr.
pub fn sysAttach(frame: *idt.InterruptFrame) void {
    if (active) {
        frame.rax = @bitCast(@as(i64, -errno.EBUSY));
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Allocate 5 contiguous physical pages
    const phys = pmm.allocPages(SHARED_PAGES) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    };

    // Zero the entire region via HHDM
    const base_virt = hhdm.physToVirt(phys);
    const ptr: [*]volatile u8 = @ptrFromInt(base_virt);
    for (0..SHARED_PAGES * PAGE_SIZE) |i| {
        ptr[i] = 0;
    }

    // Set up kernel-side pointers into the control page
    rx_prod = @ptrFromInt(base_virt + 0x000);
    rx_cons = @ptrFromInt(base_virt + 0x004);
    rx_descs = @ptrFromInt(base_virt + 0x008);
    tx_prod = @ptrFromInt(base_virt + 0x108);
    tx_cons = @ptrFromInt(base_virt + 0x10C);
    tx_descs = @ptrFromInt(base_virt + 0x110);
    stats_rx_count = @ptrFromInt(base_virt + 0x210);
    stats_tx_count = @ptrFromInt(base_virt + 0x214);
    stats_rx_drops = @ptrFromInt(base_virt + 0x218);

    // Map all 5 pages into userspace address space
    var i: u64 = 0;
    while (i < SHARED_PAGES) : (i += 1) {
        vmm.mapPage(current.page_table, ZCNET_USER_BASE + i * PAGE_SIZE, phys + i * PAGE_SIZE, .{
            .user = true,
            .writable = true,
            .no_execute = true,
        }) catch {
            // Unmap any already-mapped pages and free
            var j: u64 = 0;
            while (j < i) : (j += 1) {
                vmm.unmapPage(current.page_table, ZCNET_USER_BASE + j * PAGE_SIZE);
            }
            pmm.freePages(phys, SHARED_PAGES);
            frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
            return;
        };
    }

    // Add VMA so the page fault handler knows this region is valid
    _ = vma.addMmapVma(&current.vmas, ZCNET_USER_BASE, ZCNET_USER_BASE + SHARED_PAGES * PAGE_SIZE, vma.VMA_READ | vma.VMA_WRITE | vma.VMA_USER, null, 0);

    // Store state
    shared_phys = phys;
    owner_pid = current.pid;
    active = true;
    posted_mask = 0;

    // Switch virtio-net to zero-copy mode: post first 16 buffers to RX queue
    const buf_base_phys = phys + PAGE_SIZE; // pages 1-4
    virtio_net.switchToZeroCopy(buf_base_phys, BUF_SIZE, 16);

    // Mark first 16 buffers as posted
    posted_mask = 0x0000FFFF;

    serial.writeString("[zcnet] attached, base=0x6f0000000000\n");

    frame.rax = ZCNET_USER_BASE;
}

/// zcnet_detach(501) — tear down shared region.
pub fn sysDetach(frame: *idt.InterruptFrame) void {
    if (!active) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (current.pid != owner_pid) {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }

    doDetach(current.page_table);
    frame.rax = 0;
}

/// zcnet_kick(502) — immediately drain TX ring (low-latency flush).
pub fn sysKick(frame: *idt.InterruptFrame) void {
    if (!active) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    drainTxRing();
    frame.rax = 0;
}

// --- Internal functions ---

/// Called from net.poll() on every timer tick when active.
pub fn poll() void {
    if (!active) return;
    drainTxRing();
    repostRxBuffers();
}

/// Called by virtio_net handleIrq when in zc_mode.
/// Posts an RX descriptor for the received packet.
pub fn deliverRxPacket(buf_idx: u16, total_len: u32) void {
    if (!active) return;

    // total_len includes the 10-byte virtio net header
    if (total_len <= NET_HDR_SIZE) return;
    const frame_len: u16 = @truncate(total_len - NET_HDR_SIZE);

    const prod = rx_prod.*;
    const cons = rx_cons.*;

    // Ring full?
    if (prod -% cons >= RING_SIZE) {
        stats_rx_drops.* +%= 1;
        return;
    }

    const slot = prod % RING_SIZE;
    rx_descs[slot] = .{
        .buf_idx = buf_idx,
        .len = frame_len,
        .flags = DESC_FLAG_VALID,
        ._pad = 0,
    };

    // Memory barrier before incrementing producer index
    asm volatile ("mfence" ::: .{ .memory = true });
    rx_prod.* = prod +% 1;

    // Clear posted_mask bit — userspace now owns this buffer
    posted_mask &= ~(@as(u32, 1) << @as(u5, @truncate(buf_idx)));

    stats_rx_count.* +%= 1;
}

/// Drain pending TX descriptors submitted by userspace.
fn drainTxRing() void {
    const prod = tx_prod.*;
    var cons = tx_cons.*;

    while (cons != prod) {
        const slot = cons % RING_SIZE;
        const desc = tx_descs[slot];

        // Validate
        if (desc.buf_idx >= RING_SIZE or desc.len > MAX_FRAME) {
            cons +%= 1;
            tx_cons.* = cons;
            continue;
        }

        // Compute physical address of this buffer
        const buf_phys = shared_phys + PAGE_SIZE + @as(u64, desc.buf_idx) * BUF_SIZE;

        // Transmit via virtio-net (frame data starts after the net header)
        _ = virtio_net.transmitFromPhys(buf_phys, @as(usize, desc.len) + NET_HDR_SIZE);

        stats_tx_count.* +%= 1;
        cons +%= 1;
        tx_cons.* = cons;
    }
}

/// Repost consumed RX buffers back to the virtio RX queue.
fn repostRxBuffers() void {
    // Scan all 32 buffer indices. If a buffer is not in posted_mask and
    // the consumer has advanced past its descriptor, repost it.
    const cons = rx_cons.*;
    const prod = rx_prod.*;

    // Build set of buffer indices currently in the ring (unconsumed)
    var in_ring_mask: u32 = 0;
    if (prod != cons) {
        var i = cons;
        while (i != prod) : (i +%= 1) {
            const slot = i % RING_SIZE;
            const buf_idx = rx_descs[slot].buf_idx;
            if (buf_idx < RING_SIZE) {
                in_ring_mask |= @as(u32, 1) << @as(u5, @truncate(buf_idx));
            }
        }
    }

    // Repost buffers that are neither posted to virtio nor in the ring
    // (i.e., buffers that userspace has consumed and released)
    const buf_base_phys = shared_phys + PAGE_SIZE;
    var idx: u5 = 0;
    while (idx < 16) : (idx += 1) { // Only first 16 buffers are for RX
        const mask_bit = @as(u32, 1) << idx;
        if ((posted_mask & mask_bit) == 0 and (in_ring_mask & mask_bit) == 0) {
            // This buffer is free — repost to virtio RX
            const buf_phys = buf_base_phys + @as(u64, idx) * BUF_SIZE;
            virtio_net.postRxBufferPhys(buf_phys);
            posted_mask |= mask_bit;
        }
    }
}

/// Force detach — used by explicit detach syscall.
fn doDetach(page_table: u64) void {
    // Switch virtio-net back to copy mode
    virtio_net.switchToCopyMode();

    // Unmap shared pages from userspace
    var i: u64 = 0;
    while (i < SHARED_PAGES) : (i += 1) {
        vmm.unmapPage(page_table, ZCNET_USER_BASE + i * PAGE_SIZE);
    }

    // Remove VMA from the owning process
    for (0..process.MAX_PROCESSES) |idx| {
        if (process.getProcess(idx)) |proc| {
            if (proc.pid == owner_pid) {
                _ = vma.removeVma(&proc.vmas, ZCNET_USER_BASE);
                break;
            }
        }
    }

    // Free physical pages
    pmm.freePages(shared_phys, SHARED_PAGES);

    // Reset state
    active = false;
    owner_pid = 0;
    shared_phys = 0;
    posted_mask = 0;

    serial.writeString("[zcnet] detached\n");
}

/// Cleanup on process exit — force detach if the exiting process owns the ring.
pub fn cleanupForProcess(pid: u32) void {
    if (active and owner_pid == pid) {
        // Switch virtio-net back
        virtio_net.switchToCopyMode();

        // We can't easily get the process's page table at this point during exit,
        // but the address space is about to be destroyed anyway. Just free physical memory.
        pmm.freePages(shared_phys, SHARED_PAGES);

        active = false;
        owner_pid = 0;
        shared_phys = 0;
        posted_mask = 0;

        serial.writeString("[zcnet] cleanup (owner exited)\n");
    }
}
