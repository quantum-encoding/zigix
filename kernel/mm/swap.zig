/// Swap subsystem — page eviction and swap-backed demand paging.
///
/// Uses a pre-created 16 MiB /swapfile on the ext2 filesystem (4096 pages).
/// The swap bitmap tracks free/used slots. The clock algorithm evicts pages
/// by sweeping PTEs and checking the accessed bit.
///
/// Swap PTE encoding (when page is not present):
///   Bit 0 = 0 (not present)
///   Bit 1 = 1 (swap marker — distinguishes from never-mapped)
///   Bits 12-51 = swap slot number (in phys_frame field)

const types = @import("../types.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const hhdm = @import("hhdm.zig");
const vfs = @import("../fs/vfs.zig");
const serial = @import("../arch/x86_64/serial.zig");

const PAGE_SIZE = types.PAGE_SIZE;

/// Maximum swap slots (16 MiB / 4 KiB = 4096 pages)
const MAX_SWAP_SLOTS: usize = 4096;

/// Swap bitmap: 1 = free, 0 = used. 512 bytes for 4096 slots.
var swap_bitmap: [MAX_SWAP_SLOTS / 8]u8 = [_]u8{0xFF} ** (MAX_SWAP_SLOTS / 8);
var swap_active: bool = false;
var swap_inode: ?*vfs.Inode = null;
var swap_used: u32 = 0;

/// Clock hand for eviction algorithm
var clock_hand: u64 = 0;

/// Initialize swap by opening /swapfile
pub fn init() void {
    const inode = vfs.resolve("/swapfile") orelse {
        serial.writeString("[swap] No /swapfile found, swap disabled\n");
        return;
    };

    swap_inode = inode;
    swap_active = true;
    swap_used = 0;

    // Mark slot 0 as used (reserved)
    swap_bitmap[0] &= ~@as(u8, 1);

    serial.writeString("[swap] Initialized: ");
    writeDecimal(MAX_SWAP_SLOTS - 1);
    serial.writeString(" slots available (");
    writeDecimal((MAX_SWAP_SLOTS - 1) * PAGE_SIZE / 1024 / 1024);
    serial.writeString(" MiB)\n");
}

/// Check if swap is available
pub fn isActive() bool {
    return swap_active;
}

/// Allocate a swap slot. Returns slot number or null if full.
fn allocSwapSlot() ?u32 {
    var i: u32 = 1; // skip slot 0
    while (i < MAX_SWAP_SLOTS) : (i += 1) {
        const byte_idx = i / 8;
        const bit_idx: u3 = @truncate(i & 7);
        if (swap_bitmap[byte_idx] & (@as(u8, 1) << bit_idx) != 0) {
            // Found free slot
            swap_bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
            swap_used += 1;
            return i;
        }
    }
    return null;
}

/// Free a swap slot.
pub fn freeSwapSlot(slot: u32) void {
    if (slot == 0 or slot >= MAX_SWAP_SLOTS) return;
    const byte_idx = slot / 8;
    const bit_idx: u3 = @truncate(slot & 7);
    swap_bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
    if (swap_used > 0) swap_used -= 1;
}

/// Write a physical page to a swap slot. Returns true on success.
fn writeSwapPage(slot: u32, phys: types.PhysAddr) bool {
    const inode = swap_inode orelse return false;
    const write_fn = inode.ops.write orelse return false;

    const offset: u64 = @as(u64, slot) * PAGE_SIZE;
    var desc = vfs.FileDescription{
        .inode = inode,
        .offset = offset,
        .flags = vfs.O_WRONLY,
        .ref_count = 1,
        .in_use = true,
    };

    const buf: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
    const written = write_fn(&desc, @constCast(buf), PAGE_SIZE);
    return written == @as(i64, @intCast(PAGE_SIZE));
}

/// Read a page from a swap slot into a physical page. Returns true on success.
pub fn readSwapPage(slot: u32, phys: types.PhysAddr) bool {
    const inode = swap_inode orelse return false;
    const read_fn = inode.ops.read orelse return false;

    const offset: u64 = @as(u64, slot) * PAGE_SIZE;
    var desc = vfs.FileDescription{
        .inode = inode,
        .offset = offset,
        .flags = vfs.O_RDONLY,
        .ref_count = 1,
        .in_use = true,
    };

    const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    const bytes_read = read_fn(&desc, buf, PAGE_SIZE);
    return bytes_read == @as(i64, @intCast(PAGE_SIZE));
}

/// Evict one page using the clock algorithm.
/// Sweeps user PTEs, checks accessed bit. Evicts the first unaccessed page.
/// Returns true if a page was successfully evicted (caller should retry alloc).
pub fn evictOnePage() bool {
    if (!swap_active) return false;

    const process = @import("../proc/process.zig");
    const scheduler = @import("../proc/scheduler.zig");

    // We need to find a page to evict by scanning process page tables.
    // Use a simple clock sweep over all user PTEs.
    var attempts: u32 = 0;
    const max_attempts: u32 = 2 * process.MAX_PROCESSES * 512; // generous limit

    while (attempts < max_attempts) : (attempts += 1) {
        // Advance clock hand through process slots
        const proc_idx = clock_hand / 512;
        const page_within = clock_hand % 512;
        clock_hand = (clock_hand + 1) % (@as(u64, process.MAX_PROCESSES) * 512);

        if (proc_idx >= process.MAX_PROCESSES) continue;

        const proc = process.getProcess(@truncate(proc_idx)) orelse continue;
        if (proc.state == .zombie) continue;

        // Don't evict from the currently running process
        if (scheduler.currentProcess()) |current| {
            if (current.pid == proc.pid) continue;
        }

        // Try to find an evictable PTE in this process's user space
        // We scan a PML4 entry's worth of pages at a time
        const pml4_idx = page_within;
        if (pml4_idx >= 256) continue; // user half only

        const pml4: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, proc.page_table);
        if (!pml4.entries[pml4_idx].isPresent()) continue;

        const pdpt_phys = pml4.entries[pml4_idx].getPhysAddr();
        if (pdpt_phys == 0) continue;
        const pdpt: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, pdpt_phys);

        // Scan first present PDPT entry
        for (0..512) |pdpt_i| {
            if (!pdpt.entries[pdpt_i].isPresent()) continue;
            const pd_phys = pdpt.entries[pdpt_i].getPhysAddr();
            if (pd_phys == 0) continue;
            const pd: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, pd_phys);

            for (0..512) |pd_i| {
                if (!pd.entries[pd_i].isPresent()) continue;
                if (pd.entries[pd_i].huge_page) continue; // skip huge pages
                const pt_phys = pd.entries[pd_i].getPhysAddr();
                if (pt_phys == 0) continue;
                const pt: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, pt_phys);

                for (0..512) |pt_i| {
                    const pte = &pt.entries[pt_i];
                    if (!pte.isPresent()) continue;

                    // Check accessed bit
                    if (pte.accessed) {
                        // Clear accessed bit — give it another chance
                        pte.accessed = false;
                        continue;
                    }

                    // This page hasn't been accessed — evict it
                    const old_phys = pte.getPhysAddr();
                    if (old_phys == 0) continue;

                    // Don't evict shared pages (ref > 1) — CoW pages
                    if (pmm.getRef(old_phys) > 1) continue;

                    // Allocate a swap slot
                    const slot = allocSwapSlot() orelse return false;

                    // Write page to swap
                    if (!writeSwapPage(slot, old_phys)) {
                        freeSwapSlot(slot);
                        return false;
                    }

                    // Replace PTE with swap marker
                    // Bit 0 = 0 (not present), os_bits bit 1 (PTE bit 10) = swap marker
                    // phys_frame field = swap slot number
                    // Using os_bits avoids collision with writable bit used by CoW
                    pte.* = .{};
                    pte.os_bits = 2; // bit 1 of os_bits = swap marker (PTE bit 10)
                    pte.phys_frame = @intCast(slot);

                    // Free the physical page
                    pmm.freePage(old_phys);

                    // Invalidate TLB for this virtual address
                    const virt = (@as(u64, pml4_idx) << 39) |
                        (@as(u64, pdpt_i) << 30) |
                        (@as(u64, pd_i) << 21) |
                        (@as(u64, pt_i) << 12);
                    vmm.invlpg(virt);

                    return true;
                }
            }
            break; // Only scan first present PDPT entry per clock tick
        }
    }

    return false;
}

/// Try to allocate a page, evicting one from swap if PMM is out of memory.
pub fn allocPageOrEvict() ?types.PhysAddr {
    // Fast path: try normal allocation first
    if (pmm.allocPage()) |phys| return phys;

    // Slow path: evict a page and retry
    if (evictOnePage()) {
        return pmm.allocPage();
    }

    return null;
}

/// Check if a PTE is a swap entry (not present, swap marker in os_bits).
/// Uses os_bits bit 1 (PTE bit 10) to avoid collision with writable/CoW bits.
pub fn isSwapPte(pte: vmm.PTE) bool {
    return !pte.present and (pte.os_bits & 2) != 0;
}

/// Get the swap slot number from a swap PTE.
pub fn getSwapSlot(pte: vmm.PTE) u32 {
    return @truncate(pte.phys_frame);
}

/// Swap in: read page from swap, allocate physical page, update PTE.
/// Called from fault handler when it encounters a swap PTE.
pub fn swapIn(pte: *vmm.PTE, virt: u64, writable: bool, user: bool, no_execute: bool) bool {
    const slot = getSwapSlot(pte.*);
    if (slot == 0 or slot >= MAX_SWAP_SLOTS) return false;

    // Allocate a physical page (may trigger another eviction)
    const phys = pmm.allocPage() orelse return false;

    // Read swap data into the page
    if (!readSwapPage(slot, phys)) {
        pmm.freePage(phys);
        return false;
    }

    // Free the swap slot
    freeSwapSlot(slot);

    // Restore the PTE to point to the physical page
    pte.* = .{
        .present = true,
        .writable = writable,
        .user = user,
        .no_execute = no_execute,
    };
    pte.setPhysAddr(phys);

    // Invalidate TLB
    vmm.invlpg(virt);

    return true;
}

// --- Output helpers ---

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
