/// ARM64 Physical Memory Manager — bitmap allocator.
/// For QEMU virt machine with known memory layout.
///
/// QEMU virt machine memory map:
/// - 0x00000000 - 0x3FFFFFFF : Device memory (GIC, UART, etc.)
/// - 0x40000000 - onwards    : RAM (size depends on -m flag)
///
/// This is simpler than x86_64 PMM since we don't have Limine.
/// Memory layout is either hardcoded (QEMU virt) or parsed from DTB.

const uart = @import("uart.zig");
const spinlock = @import("spinlock.zig");
const page_cache = @import("page_cache.zig");

pub const PAGE_SIZE: u64 = 4096;
const PAGE_SHIFT: u6 = 12;
pub const HUGE_PAGE_SIZE: u64 = 2 * 1024 * 1024; // 2 MB
pub const HUGE_PAGE_PAGES: u64 = HUGE_PAGE_SIZE / PAGE_SIZE; // 512 pages per hugepage

/// RAM base address for QEMU virt machine
const RAM_BASE: u64 = 0x40000000;

/// Default RAM size (2 GB) — updated by FDT parser if DTB available
var ram_size: u64 = 2 * 1024 * 1024 * 1024;

/// Called by boot.zig after FDT parsing to set actual RAM size
pub fn setRamSize(size: u64) void {
    if (!initialized and size >= 16 * 1024 * 1024) { // minimum 16 MB
        ram_size = size;
    }
}

/// Bitmap: 1 = free, 0 = used/reserved
/// Placed at end of kernel in RAM
var bitmap: [*]u8 = undefined;
var bitmap_size: u64 = 0;
var total_pages: u64 = 0;
var free_pages: u64 = 0;

/// Reference counts for Copy-on-Write support
var ref_counts: [*]u16 = undefined;
var ref_counts_size: u64 = 0;

/// Search hint for faster allocation
var next_free_hint: u64 = 0;

/// SMP lock — protects bitmap, ref_counts, free_pages, next_free_hint.
var pmm_lock: spinlock.IrqSpinlock = .{};

/// Track where kernel ends (linker symbols)
extern const __bss_end: u8;
extern const __stack_top: u8;

var initialized = false;

/// Physical address at which free pages begin (after kernel + metadata).
/// Any allocPage returning below this or freePage called below this is a bug.
var reserved_end: u64 = 0;

/// Initialize PMM with QEMU virt memory layout
pub fn init() void {
    // Calculate where kernel ends (after stack)
    const kernel_end = @intFromPtr(&__stack_top);

    // Align kernel end to page boundary
    const kernel_end_aligned = (kernel_end + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);

    // Calculate total RAM pages
    total_pages = ram_size / PAGE_SIZE;

    // Calculate bitmap and ref_counts sizes
    bitmap_size = (total_pages + 7) / 8;
    ref_counts_size = total_pages * 2; // u16 per page

    const metadata_size = bitmap_size + ref_counts_size;
    const metadata_pages = (metadata_size + PAGE_SIZE - 1) / PAGE_SIZE;

    // Place bitmap right after kernel
    const bitmap_addr = kernel_end_aligned;
    bitmap = @ptrFromInt(bitmap_addr);

    // Place ref_counts after bitmap
    const ref_counts_addr = bitmap_addr + bitmap_size;
    ref_counts = @ptrFromInt(ref_counts_addr);

    uart.writeString("[pmm]  RAM: ");
    uart.writeHex(RAM_BASE);
    uart.writeString(" - ");
    uart.writeHex(RAM_BASE + ram_size);
    uart.writeString(" (");
    uart.writeDec(ram_size / 1024 / 1024);
    uart.writeString(" MB)\n");

    // Clear bitmap (all pages used)
    for (0..bitmap_size) |i| {
        bitmap[i] = 0;
    }

    // Zero ref counts
    for (0..total_pages) |i| {
        ref_counts[i] = 0;
    }

    // Calculate first usable page (after kernel + metadata)
    const metadata_end = bitmap_addr + metadata_size;
    const first_free_page = (metadata_end - RAM_BASE + PAGE_SIZE - 1) / PAGE_SIZE;

    // Mark pages from first_free_page to end as free
    free_pages = 0;
    var page: u64 = first_free_page;
    while (page < total_pages) : (page += 1) {
        setBit(page);
        free_pages += 1;
    }

    next_free_hint = first_free_page;
    reserved_end = RAM_BASE + first_free_page * PAGE_SIZE;
    initialized = true;

    uart.writeString("[pmm]  Kernel ends at ");
    uart.writeHex(kernel_end_aligned);
    uart.writeString("\n");
    uart.writeString("[pmm]  Bitmap at ");
    uart.writeHex(bitmap_addr);
    uart.writeString(" (");
    uart.writeDec(metadata_pages);
    uart.writeString(" pages)\n");
    uart.writeString("[pmm]  Total: ");
    uart.writeDec(total_pages);
    uart.writeString(" pages, Free: ");
    uart.writeDec(free_pages);
    uart.writeString(" pages (");
    uart.writeDec(free_pages * PAGE_SIZE / 1024 / 1024);
    uart.writeString(" MB)\n");
}

/// Allocate a single physical page. Returns physical address or null.
/// If memory is exhausted, tries shrinking the page cache before giving up.
pub fn allocPage() ?u64 {
    if (!initialized) return null;

    return allocPageInner() orelse {
        // Memory exhausted — try shrinking page cache to reclaim pages.
        // Must NOT hold pmm_lock here (page_cache.shrink → evictEntry → freePage
        // acquires pmm_lock internally).
        const freed = page_cache.shrink(256);
        if (freed > 0) {
            return allocPageInner();
        }
        return null;
    };
}

fn allocPageInner() ?u64 {
    pmm_lock.acquire();
    defer pmm_lock.release();

    if (free_pages == 0) return null;

    // Scan from hint
    var page = next_free_hint;
    while (page < total_pages) : (page += 1) {
        if (testBit(page)) {
            clearBit(page);
            free_pages -= 1;
            next_free_hint = page + 1;
            ref_counts[page] = 1;
            const phys = RAM_BASE + page * PAGE_SIZE;
            if (phys < reserved_end) {
                uart.print("[PMM-BUG] allocPage returned kernel page {x}! reserved_end={x}\n", .{ phys, reserved_end });
            }
            return phys;
        }
    }

    // Wrap around from beginning
    page = 1;
    while (page < next_free_hint) : (page += 1) {
        if (testBit(page)) {
            clearBit(page);
            free_pages -= 1;
            next_free_hint = page + 1;
            ref_counts[page] = 1;
            const phys = RAM_BASE + page * PAGE_SIZE;
            if (phys < reserved_end) {
                uart.print("[PMM-BUG] allocPage returned kernel page {x}! reserved_end={x}\n", .{ phys, reserved_end });
            }
            return phys;
        }
    }

    return null;
}

/// Free a physical page (uses reference counting)
pub fn freePage(phys: u64) void {
    if (!initialized) return;
    if (phys < RAM_BASE) return;
    if (phys < reserved_end) {
        uart.print("[PMM-BUG] freePage on kernel page {x}! reserved_end={x}\n", .{ phys, reserved_end });
        return; // Refuse to free kernel memory
    }

    const page = (phys - RAM_BASE) / PAGE_SIZE;
    if (page >= total_pages) return;
    if (page == 0) return;

    pmm_lock.acquire();
    defer pmm_lock.release();

    // Decrement ref count
    if (ref_counts[page] > 1) {
        ref_counts[page] -= 1;
        return;
    }
    ref_counts[page] = 0;

    if (!testBit(page)) {
        setBit(page);
        free_pages += 1;
        if (page < next_free_hint) {
            next_free_hint = page;
        }
    }
}

/// Increment reference count (for CoW).
/// Saturates at 65535 — a saturated page is permanently pinned (leak > UAF).
pub fn incRef(phys: u64) void {
    if (!initialized) return;
    if (phys < RAM_BASE) return;
    const page = (phys - RAM_BASE) / PAGE_SIZE;
    if (page >= total_pages) return;

    pmm_lock.acquire();
    defer pmm_lock.release();
    if (ref_counts[page] < 65535) {
        ref_counts[page] += 1;
    }
}

/// Decrement reference count, returns new count.
/// Saturated pages (ref == 65535) are never freed — prevents UAF from overflow.
pub fn decRef(phys: u64) u16 {
    if (!initialized) return 0;
    if (phys < RAM_BASE) return 0;
    const page = (phys - RAM_BASE) / PAGE_SIZE;
    if (page >= total_pages) return 0;

    pmm_lock.acquire();
    defer pmm_lock.release();

    if (ref_counts[page] == 65535) return 65535; // saturated — permanently pinned
    if (ref_counts[page] == 0) return 0;

    ref_counts[page] -= 1;
    const new_count = ref_counts[page];

    if (new_count == 0) {
        if (!testBit(page)) {
            setBit(page);
            free_pages += 1;
            if (page < next_free_hint) {
                next_free_hint = page;
            }
        }
    }
    return new_count;
}

/// Get reference count for a page
pub fn getRef(phys: u64) u16 {
    if (!initialized) return 0;
    if (phys < RAM_BASE) return 0;
    const page = (phys - RAM_BASE) / PAGE_SIZE;
    if (page >= total_pages) return 0;
    return ref_counts[page];
}

/// Allocate n contiguous pages
pub fn allocPages(count: u64) ?u64 {
    if (!initialized) return null;
    if (count == 0) return null;

    pmm_lock.acquire();
    defer pmm_lock.release();

    if (free_pages < count) return null;

    var run_start: u64 = next_free_hint;
    var run_len: u64 = 0;

    var page: u64 = next_free_hint;
    while (page < total_pages) : (page += 1) {
        if (testBit(page)) {
            if (run_len == 0) run_start = page;
            run_len += 1;
            if (run_len == count) {
                // Mark all as used
                var p: u64 = run_start;
                while (p < run_start + count) : (p += 1) {
                    clearBit(p);
                    free_pages -= 1;
                    ref_counts[p] = 1;
                }
                return RAM_BASE + run_start * PAGE_SIZE;
            }
        } else {
            run_len = 0;
        }
    }

    return null;
}

/// Free n contiguous pages
pub fn freePages(phys: u64, count: u64) void {
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        freePage(phys + i * PAGE_SIZE);
    }
}

// --- Anti-rowhammer guarded allocation ---

/// Default number of buffer pages on each side of sensitive allocations.
pub const ROWHAMMER_GUARD_PAGES: u64 = 1;

/// Kernel stack canary value — written at the bottom of every kernel stack.
pub const STACK_CANARY: u64 = 0xDEAD_BEEF_CAFE_BABE;

/// Allocate `count` contiguous pages with `guard` buffer pages on each side.
/// Returns the physical address of the first usable page (guard pages precede it).
/// Guard pages are pinned via incRef to prevent accidental freeing.
pub fn allocPagesGuarded(count: u64, guard: u64) ?u64 {
    const total = count + 2 * guard;
    const base_phys = allocPages(total) orelse return null;

    // Pin guard pages (incRef raises ref from 1→2, preventing accidental free)
    var i: u64 = 0;
    while (i < guard) : (i += 1) {
        incRef(base_phys + i * PAGE_SIZE);
        incRef(base_phys + (count + guard + i) * PAGE_SIZE);
    }

    return base_phys + guard * PAGE_SIZE;
}

/// Free a guarded allocation. Must pass the same guard count used at allocation.
/// `phys` is the address returned by allocPagesGuarded (first usable page).
pub fn freePagesGuarded(phys: u64, count: u64, guard: u64) void {
    const base_phys = phys - guard * PAGE_SIZE;

    // Unpin guard pages (decRef 2→1, then freePage drops 1→0)
    var i: u64 = 0;
    while (i < guard) : (i += 1) {
        _ = decRef(base_phys + i * PAGE_SIZE);
        freePage(base_phys + i * PAGE_SIZE);
        _ = decRef(base_phys + (count + guard + i) * PAGE_SIZE);
        freePage(base_phys + (count + guard + i) * PAGE_SIZE);
    }

    // Free the usable pages
    freePages(phys, count);
}

/// Get number of free pages
pub fn getFreePages() u64 {
    return free_pages;
}

/// Get total number of pages
pub fn getTotalPages() u64 {
    return total_pages;
}

/// Wrapper for mmu.zig compatibility
pub fn allocPageWrapper() ?u64 {
    return allocPage();
}

/// Allocate a 2MB hugepage (512 contiguous 4KB pages, 2MB-aligned).
/// Returns physical address (guaranteed 2MB-aligned) or null if unavailable.
pub fn allocHugePage() ?u64 {
    if (!initialized) return null;

    pmm_lock.acquire();
    defer pmm_lock.release();

    if (free_pages < HUGE_PAGE_PAGES) return null;

    // Scan for a run of 512 free pages starting at a 2MB-aligned boundary
    // Round up search start to next HUGE_PAGE_PAGES-aligned page index
    var start: u64 = (next_free_hint + HUGE_PAGE_PAGES - 1) & ~(HUGE_PAGE_PAGES - 1);

    while (start + HUGE_PAGE_PAGES <= total_pages) {
        // Check if all 512 pages in this 2MB-aligned block are free
        var all_free = true;
        for (0..HUGE_PAGE_PAGES) |offset| {
            if (!testBit(start + offset)) {
                all_free = false;
                break;
            }
        }

        if (all_free) {
            // Mark all 512 pages as used
            for (0..HUGE_PAGE_PAGES) |offset| {
                clearBit(start + offset);
                ref_counts[start + offset] = 1;
            }
            free_pages -= HUGE_PAGE_PAGES;

            const phys = RAM_BASE + start * PAGE_SIZE;
            uart.writeString("[pmm]  Hugepage alloc at 0x");
            uart.writeHex(phys);
            uart.writeString(" (2 MB)\n");
            return phys;
        }

        // Move to next 2MB-aligned boundary
        start += HUGE_PAGE_PAGES;
    }

    // Wrap-around: try from the beginning of RAM
    start = 1; // skip page 0
    start = (start + HUGE_PAGE_PAGES - 1) & ~(HUGE_PAGE_PAGES - 1);
    const limit = (next_free_hint + HUGE_PAGE_PAGES - 1) & ~(HUGE_PAGE_PAGES - 1);

    while (start + HUGE_PAGE_PAGES <= total_pages and start < limit) {
        var all_free = true;
        for (0..HUGE_PAGE_PAGES) |offset| {
            if (!testBit(start + offset)) {
                all_free = false;
                break;
            }
        }

        if (all_free) {
            for (0..HUGE_PAGE_PAGES) |offset| {
                clearBit(start + offset);
                ref_counts[start + offset] = 1;
            }
            free_pages -= HUGE_PAGE_PAGES;

            const phys = RAM_BASE + start * PAGE_SIZE;
            uart.writeString("[pmm]  Hugepage alloc at 0x");
            uart.writeHex(phys);
            uart.writeString(" (2 MB)\n");
            return phys;
        }

        start += HUGE_PAGE_PAGES;
    }

    return null;
}

/// Free a 2MB hugepage (512 contiguous pages).
pub fn freeHugePage(phys: u64) void {
    if (!initialized) return;
    if (phys < RAM_BASE) return;
    if (phys & (HUGE_PAGE_SIZE - 1) != 0) return; // Must be 2MB-aligned

    const start_page = (phys - RAM_BASE) / PAGE_SIZE;
    if (start_page + HUGE_PAGE_PAGES > total_pages) return;

    pmm_lock.acquire();
    defer pmm_lock.release();

    for (0..HUGE_PAGE_PAGES) |offset| {
        const page = start_page + offset;
        if (ref_counts[page] > 1) {
            ref_counts[page] -= 1;
        } else {
            ref_counts[page] = 0;
            if (!testBit(page)) {
                setBit(page);
                free_pages += 1;
                if (page < next_free_hint) {
                    next_free_hint = page;
                }
            }
        }
    }
}

// --- Bitmap operations ---

fn setBit(page: u64) void {
    const byte_idx = page / 8;
    const bit_idx: u3 = @truncate(page & 7);
    bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
}

fn clearBit(page: u64) void {
    const byte_idx = page / 8;
    const bit_idx: u3 = @truncate(page & 7);
    bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
}

fn testBit(page: u64) bool {
    const byte_idx = page / 8;
    const bit_idx: u3 = @truncate(page & 7);
    return (bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}
