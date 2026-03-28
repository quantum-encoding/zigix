/// Physical Memory Manager — bitmap allocator.
/// Reads the Limine memory map, places a bitmap in usable memory,
/// and tracks free/used 4 KiB page frames.

const types = @import("../types.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");
const limine = @import("../limine.zig");
const BootMemEntry = @import("../boot_info.zig").BootMemEntry;
const recovery = @import("../safety/recovery.zig");
const spinlock = @import("../arch/x86_64/spinlock.zig");

/// SMP lock protecting bitmap, ref_counts, and free_pages counter.
var pmm_lock: spinlock.IrqSpinlock = .{};

const PAGE_SIZE = types.PAGE_SIZE;

// Linker symbol marking the true end of kernel .bss (and thus the kernel image).
// This is authoritative for the kernel's physical extent, including all .bss.
extern const __kernel_end: u8;

// --- State ---

/// Bitmap: 1 = free, 0 = used/reserved.
/// Stored in physical memory, accessed via HHDM.
var bitmap: [*]u8 = undefined;
var bitmap_size: u64 = 0; // in bytes
var total_pages: u64 = 0;
var free_pages: u64 = 0;
var highest_phys: u64 = 0;

/// Reference counts: one u16 per page for Copy-on-Write support.
/// Stored in physical memory right after the bitmap.
var ref_counts: [*]u16 = undefined;
var ref_counts_size: u64 = 0; // in bytes

/// Minimum physical page index for allocations.
/// Skip first 2 MB (512 pages) — legacy BIOS area, IVT, BDA, EBDA.
/// Firmware SMM handlers and serial port emulation can touch low memory.
/// Also avoids fragile physical pages that UEFI marks "usable" but
/// shouldn't be used for kernel page tables or DMA buffers.
const MIN_ALLOC_PAGE: u64 = 512; // 2 MB / 4096 = 512

// Simple search hint: start scanning from here
var next_free_hint: u64 = 0;

// --- Public API ---

pub fn init(memmap_response: *const limine.MemmapResponse) void {
    const entry_count = memmap_response.entry_count;
    const entries = memmap_response.entries;

    // Pass 1: find the highest usable physical address to size the bitmap.
    // Only consider regions that could contain allocatable pages —
    // reserved regions at high addresses (MMIO, etc.) shouldn't bloat the bitmap.
    highest_phys = 0;
    var total_usable: u64 = 0;
    for (0..entry_count) |i| {
        const entry = entries[i];
        const top = entry.base + entry.length;
        switch (entry.kind) {
            .usable, .bootloader_reclaimable, .kernel_and_modules, .acpi_reclaimable => {
                if (top > highest_phys) {
                    highest_phys = top;
                }
            },
            else => {},
        }
        if (entry.kind == .usable) {
            total_usable += entry.length;
        }
    }

    total_pages = highest_phys / PAGE_SIZE;
    bitmap_size = (total_pages + 7) / 8; // 1 bit per page, rounded up

    serial.writeString("[mem]  Physical memory map:\n");
    for (0..entry_count) |i| {
        const entry = entries[i];
        serial.writeString("       0x");
        writeHex(entry.base);
        serial.writeString(" - 0x");
        writeHex(entry.base + entry.length);
        serial.writeString(" ");
        serial.writeString(kindName(entry.kind));
        serial.writeString("\n");
    }

    // Ref counts: one u16 per page
    ref_counts_size = total_pages * 2;

    // Total metadata = bitmap + alignment padding + ref_counts
    const metadata_size = ((bitmap_size + 7) & ~@as(u64, 7)) + ref_counts_size;

    // Pass 2: find a usable region large enough for bitmap + ref_counts
    var bitmap_phys: u64 = 0;
    var found = false;
    for (0..entry_count) |i| {
        const entry = entries[i];
        if (entry.kind == .usable and entry.length >= metadata_size) {
            bitmap_phys = entry.base;
            found = true;
            break;
        }
    }

    if (!found) {
        serial.writeString("[mem]  FATAL: no region large enough for bitmap\n");
        return;
    }

    // Place bitmap at bitmap_phys, accessed via HHDM
    bitmap = @ptrFromInt(hhdm.physToVirt(bitmap_phys));

    // Place ref_counts right after bitmap (aligned to 8 bytes for u16 array safety)
    const ref_counts_phys = (bitmap_phys + bitmap_size + 7) & ~@as(u64, 7);
    ref_counts = @ptrFromInt(@as(usize, @truncate(hhdm.physToVirt(ref_counts_phys))));

    // Clear bitmap: mark all pages as used (0)
    for (0..bitmap_size) |i| {
        bitmap[i] = 0;
    }

    // Zero ref counts
    for (0..total_pages) |i| {
        ref_counts[i] = 0;
    }

    // Pass 3: mark usable regions as free (1) in the bitmap
    free_pages = 0;
    for (0..entry_count) |i| {
        const entry = entries[i];
        if (entry.kind == .usable) {
            const start_page = entry.base / PAGE_SIZE;
            const page_count = entry.length / PAGE_SIZE;
            var p: u64 = start_page;
            while (p < start_page + page_count) : (p += 1) {
                setBit(p);
                free_pages += 1;
            }
        }
    }

    // Mark bitmap + ref_counts pages as used
    const metadata_pages = (metadata_size + PAGE_SIZE - 1) / PAGE_SIZE;
    const bitmap_start_page = bitmap_phys / PAGE_SIZE;
    var p: u64 = bitmap_start_page;
    while (p < bitmap_start_page + metadata_pages) : (p += 1) {
        if (testBit(p)) {
            clearBit(p);
            free_pages -= 1;
        }
    }

    // Also reserve page 0 (null page) if it's marked free
    if (total_pages > 0 and testBit(0)) {
        clearBit(0);
        free_pages -= 1;
    }

    next_free_hint = 1; // skip page 0 — physToVirt(0) may not be mapped

    // Print summary
    serial.writeString("[mem]  Bitmap at phys 0x");
    writeHex(bitmap_phys);
    serial.writeString(" (");
    writeDecimal(metadata_size);
    serial.writeString(" bytes, ");
    writeDecimal(metadata_pages);
    serial.writeString(" pages)\n");

    serial.writeString("[mem]  Total: ");
    writeDecimal(total_pages);
    serial.writeString(" pages (");
    writeDecimal(total_pages * PAGE_SIZE / 1024 / 1024);
    serial.writeString(" MiB)\n");

    serial.writeString("[mem]  Usable: ");
    writeDecimal(total_usable / 1024 / 1024);
    serial.writeString(" MiB, Free: ");
    writeDecimal(free_pages);
    serial.writeString(" pages (");
    writeDecimal(free_pages * PAGE_SIZE / 1024 / 1024);
    serial.writeString(" MiB)\n");
}

/// Alternative init for UEFI boot path.
/// Takes an array of simplified memory map entries from BootInfo.
pub fn initFromBootEntries(
    entries_ptr: [*]const BootMemEntry,
    entry_count: u32,
    kernel_phys_base: u64,
    kernel_phys_end: u64,
) void {
    const boot_info = @import("../boot_info.zig");
    _ = boot_info; // Imported for BootMemEntry type used in parameter

    // Pass 1: find highest usable physical address
    highest_phys = 0;
    var total_usable: u64 = 0;
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const entry = entries_ptr[i];
        const top = entry.base + entry.length;
        if (entry.kind == .usable or entry.kind == .bootloader_reclaimable or
            entry.kind == .acpi_reclaimable)
        {
            if (top > highest_phys) highest_phys = top;
        }
        if (entry.kind == .usable or entry.kind == .bootloader_reclaimable) {
            total_usable += entry.length;
        }
    }

    total_pages = highest_phys / PAGE_SIZE;
    bitmap_size = (total_pages + 7) / 8;

    serial.writeString("[mem]  Physical memory map (UEFI, ");
    writeDecimal(entry_count);
    serial.writeString(" entries):\n");
    i = 0;
    while (i < entry_count) : (i += 1) {
        const entry = entries_ptr[i];
        serial.writeString("       0x");
        writeHex(entry.base);
        serial.writeString(" - 0x");
        writeHex(entry.base + entry.length);
        serial.writeString(" ");
        serial.writeString(switch (entry.kind) {
            .usable => "usable",
            .reserved => "reserved",
            .acpi_reclaimable => "acpi_reclaimable",
            .kernel_and_modules => "kernel",
            .bootloader_reclaimable => "bootloader_reclaimable",
            .framebuffer => "framebuffer",
        });
        serial.writeString("\n");
    }

    // Ref counts
    ref_counts_size = total_pages * 2;
    const metadata_size = ((bitmap_size + 7) & ~@as(u64, 7)) + ref_counts_size;

    // Pass 2: find a usable region large enough for bitmap + ref_counts
    // Skip regions below 1MB (legacy area), prefer regions away from kernel
    var bitmap_phys: u64 = 0;
    var found = false;
    i = 0;
    while (i < entry_count) : (i += 1) {
        const entry = entries_ptr[i];
        if ((entry.kind == .usable or entry.kind == .bootloader_reclaimable) and
            entry.length >= metadata_size and entry.base >= 0x100000)
        {
            // Don't place bitmap in the kernel region
            if (entry.base >= kernel_phys_end or entry.base + metadata_size <= kernel_phys_base) {
                bitmap_phys = entry.base;
                found = true;
                break;
            }
        }
    }

    if (!found) {
        serial.writeString("[mem]  FATAL: no region large enough for bitmap\n");
        return;
    }

    // Place bitmap and ref_counts via HHDM (align ref_counts to 8 bytes for u16 array safety)
    bitmap = @ptrFromInt(hhdm.physToVirt(bitmap_phys));
    const ref_counts_phys = (bitmap_phys + bitmap_size + 7) & ~@as(u64, 7);
    ref_counts = @ptrFromInt(@as(usize, @truncate(hhdm.physToVirt(ref_counts_phys))));

    // Clear bitmap: all used
    for (0..bitmap_size) |j| {
        bitmap[j] = 0;
    }
    for (0..total_pages) |j| {
        ref_counts[j] = 0;
    }

    // Pass 3: mark usable regions as free
    free_pages = 0;
    i = 0;
    while (i < entry_count) : (i += 1) {
        const entry = entries_ptr[i];
        if (entry.kind == .usable or entry.kind == .bootloader_reclaimable) {
            const start_page = entry.base / PAGE_SIZE;
            const page_count = entry.length / PAGE_SIZE;
            var p: u64 = start_page;
            while (p < start_page + page_count and p < total_pages) : (p += 1) {
                setBit(p);
                free_pages += 1;
            }
        }
    }

    // Mark bitmap + ref_counts pages as used
    const metadata_pages = (metadata_size + PAGE_SIZE - 1) / PAGE_SIZE;
    const bitmap_start_page = bitmap_phys / PAGE_SIZE;
    {
        var p: u64 = bitmap_start_page;
        while (p < bitmap_start_page + metadata_pages) : (p += 1) {
            if (testBit(p)) {
                clearBit(p);
                free_pages -= 1;
            }
        }
    }

    // Mark kernel region as used.
    // Use linker symbol __kernel_end for the true extent including .bss.
    // The bootloader's kernel_phys_end is derived from ELF p_memsz which
    // should match, but the linker symbol is authoritative.
    // Mark kernel region as used — authoritative from linker symbol.
    const KERNEL_VIRT_BASE: u64 = 0xFFFFFFFF80000000;
    const kernel_end_virt: u64 = @intFromPtr(&__kernel_end);
    const true_kernel_phys_end = kernel_phys_base + (kernel_end_virt - KERNEL_VIRT_BASE);
    // Use the larger of bootloader and linker values — covers all of .bss
    const effective_end = if (true_kernel_phys_end > kernel_phys_end) true_kernel_phys_end else kernel_phys_end;

    // Debug: print kernel physical range for PMM overlap check
    serial.writeString("[pmm]  Kernel phys: 0x");
    writeHex(kernel_phys_base);
    serial.writeString(" - 0x");
    writeHex(effective_end);
    serial.writeString(" (linker __kernel_end virt=0x");
    writeHex(kernel_end_virt);
    serial.writeString(")\n");

    const kernel_start_page = kernel_phys_base / PAGE_SIZE;
    const kernel_end_page = (effective_end + PAGE_SIZE - 1) / PAGE_SIZE;
    {
        var p: u64 = kernel_start_page;
        while (p < kernel_end_page and p < total_pages) : (p += 1) {
            if (testBit(p)) {
                clearBit(p);
                free_pages -= 1;
            }
        }
    }

    // Reserve page 0
    if (total_pages > 0 and testBit(0)) {
        clearBit(0);
        free_pages -= 1;
    }

    // Start allocation AFTER the bitmap+refcounts region.
    // This ensures we never accidentally allocate kernel, bitmap, or any
    // low-memory page even if the above reservations have an off-by-one.
    const bitmap_end_page = (bitmap_phys + metadata_size + PAGE_SIZE - 1) / PAGE_SIZE;
    next_free_hint = if (bitmap_end_page > kernel_end_page) bitmap_end_page else kernel_end_page;

    serial.writeString("[mem]  Bitmap at phys 0x");
    writeHex(bitmap_phys);
    serial.writeString(" (");
    writeDecimal(metadata_size);
    serial.writeString(" bytes)\n");
    serial.writeString("[mem]  Total: ");
    writeDecimal(total_pages);
    serial.writeString(" pages (");
    writeDecimal(total_pages * PAGE_SIZE / 1024 / 1024);
    serial.writeString(" MiB)\n");
    serial.writeString("[mem]  Usable: ");
    writeDecimal(total_usable / 1024 / 1024);
    serial.writeString(" MiB, Free: ");
    writeDecimal(free_pages);
    serial.writeString(" pages (");
    writeDecimal(free_pages * PAGE_SIZE / 1024 / 1024);
    serial.writeString(" MiB)\n");
}

// ============================================================
// Recovery: OOM handling
// ============================================================

var oom_mode_id: u8 = 0;

/// Register PMM recovery modes. Called once during kernel init.
pub fn initRecovery() void {
    oom_mode_id = recovery.register(.{
        .name = "OOM",
        .subsystem = .pmm,
        .severity = .recoverable,
        .chain = &[_]recovery.Action{
            evictPageCacheAction,
            swapEvictAction,
        },
    });
}

/// Recovery tier 1: evict clean page cache entries to free physical pages.
fn evictPageCacheAction() recovery.ActionResult {
    const page_cache = @import("page_cache.zig");
    var freed: u64 = 0;
    // Evict up to 32 cache entries
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        if (page_cache.evictOne()) |phys| {
            freePage(phys);
            freed += 1;
        } else break;
    }
    return .{
        .succeeded = freed > 0,
        .recovered_bytes = freed * PAGE_SIZE,
        .detail = .pages_evicted,
    };
}

/// Recovery tier 2: swap out pages to make room.
fn swapEvictAction() recovery.ActionResult {
    const swap = @import("swap.zig");
    if (!swap.isActive()) return .{ .succeeded = false, .detail = .pages_swapped };
    var freed: u64 = 0;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        if (swap.evictOnePage()) {
            freed += 1;
        } else break;
    }
    return .{
        .succeeded = freed > 0,
        .recovered_bytes = freed * PAGE_SIZE,
        .detail = .pages_swapped,
    };
}

/// Try to allocate, using the recovery chain on failure.
fn allocPageWithRecovery() ?types.PhysAddr {
    // First attempt — fast path
    if (allocPageInner()) |p| return p;
    // Recovery path — try to free memory
    if (recovery.execute(oom_mode_id)) {
        // Retry after recovery
        return allocPageInner();
    }
    return null;
}

/// Allocate a single physical page. Returns physical address or null.
/// Sets reference count to 1. On OOM, executes recovery chain before failing.
pub fn allocPage() ?types.PhysAddr {
    // Don't hold lock across recovery (it may call freePage → deadlock).
    // allocPageInner and freePage each acquire the lock independently.
    return allocPageWithRecovery();
}

fn allocPageInner() ?types.PhysAddr {
    const flags = pmm_lock.acquire();
    defer pmm_lock.release(flags);
    if (free_pages == 0) return null;

    // Scan from hint, never below MIN_ALLOC_PAGE (skip legacy BIOS area)
    var page = if (next_free_hint >= MIN_ALLOC_PAGE) next_free_hint else MIN_ALLOC_PAGE;
    while (page < total_pages) : (page += 1) {
        if (testBit(page)) {
            // Diagnostic: catch premature freeing (bitmap says free but ref > 0)
            if (ref_counts[page] != 0) {
                serial.writeString("[pmm] BUG: alloc page 0x");
                writeHex(page * PAGE_SIZE);
                serial.writeString(" has ref=");
                writeDecimal(ref_counts[page]);
                serial.writeString(" but bitmap says free!\n");
            }
            clearBit(page);
            free_pages -= 1;
            next_free_hint = page + 1;
            ref_counts[page] = 1;
            return page * PAGE_SIZE;
        }
    }

    // Wrap around from beginning (still above MIN_ALLOC_PAGE)
    page = MIN_ALLOC_PAGE;
    while (page < next_free_hint) : (page += 1) {
        if (testBit(page)) {
            // Diagnostic: catch premature freeing (bitmap says free but ref > 0)
            if (ref_counts[page] != 0) {
                serial.writeString("[pmm] BUG: alloc page 0x");
                writeHex(page * PAGE_SIZE);
                serial.writeString(" has ref=");
                writeDecimal(ref_counts[page]);
                serial.writeString(" but bitmap says free!\n");
            }
            clearBit(page);
            free_pages -= 1;
            next_free_hint = page + 1;
            ref_counts[page] = 1;
            return page * PAGE_SIZE;
        }
    }

    return null;
}

/// Free a physical page. Uses reference counting — only actually frees
/// when the last reference is dropped.
pub fn freePage(phys: types.PhysAddr) void {
    const flags = pmm_lock.acquire();
    defer pmm_lock.release(flags);
    // Catch unaligned addresses — indicates caller passed garbage
    if (phys & 0xFFF != 0) {
        serial.writeString("[pmm] BUG: freePage unaligned 0x");
        writeHex(phys);
        serial.writeString("\n");
        return;
    }

    const page = phys / PAGE_SIZE;
    if (page >= total_pages) return;
    if (page == 0) return; // never free null page

    // Diagnostic: detect freeing a page that's already at ref=0
    if (ref_counts[page] == 0) {
        serial.writeString("[pmm] BUG: freePage on page 0x");
        writeHex(phys);
        serial.writeString(" with ref=0 (already freed)!\n");
        return; // Don't corrupt bitmap
    }

    // Saturated pages are never freed — prevents UAF from overflow
    if (ref_counts[page] == 65535) return;

    // Decrement ref count; only free when it reaches 0
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

/// Increment reference count for a physical page (used by CoW).
/// Saturates at 65535 — a saturated page is permanently pinned (leak > UAF).
pub fn incRef(phys: types.PhysAddr) void {
    const flags = pmm_lock.acquire();
    defer pmm_lock.release(flags);
    const page = phys / PAGE_SIZE;
    if (page >= total_pages) return;
    if (page == 0) return;
    if (ref_counts[page] < 65535) {
        ref_counts[page] += 1;
    }
}

/// Decrement reference count. Returns new count.
/// If count reaches 0, the page is freed to the bitmap.
/// Saturated pages (ref == 65535) are never freed — prevents UAF from overflow.
pub fn decRef(phys: types.PhysAddr) u16 {
    const flags = pmm_lock.acquire();
    defer pmm_lock.release(flags);
    const page = phys / PAGE_SIZE;
    if (page >= total_pages) return 0;
    if (page == 0) return 0;
    if (ref_counts[page] == 65535) return 65535; // saturated — permanently pinned
    if (ref_counts[page] == 0) {
        serial.writeString("[pmm] BUG: decRef on page 0x");
        writeHex(phys);
        serial.writeString(" with ref=0!\n");
        return 0;
    }

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

/// Query the current reference count for a physical page.
pub fn getRef(phys: types.PhysAddr) u16 {
    const page = phys / PAGE_SIZE;
    if (page >= total_pages) return 0;
    return ref_counts[page];
}

/// Allocate n contiguous physical pages. Returns base physical address or null.
pub fn allocPages(count: u64) ?types.PhysAddr {
    const flags = pmm_lock.acquire();
    defer pmm_lock.release(flags);
    if (count == 0) return null;
    if (free_pages < count) return null;

    var run_start: u64 = MIN_ALLOC_PAGE;
    var run_len: u64 = 0;

    var page: u64 = MIN_ALLOC_PAGE;
    while (page < total_pages) : (page += 1) {
        if (testBit(page)) {
            if (run_len == 0) run_start = page;
            run_len += 1;
            if (run_len == count) {
                // Found a run — mark all as used and set ref counts
                var p: u64 = run_start;
                while (p < run_start + count) : (p += 1) {
                    // Diagnostic: catch allocating a page with ref > 0
                    if (ref_counts[p] != 0) {
                        serial.writeString("[pmm] BUG: allocPages page 0x");
                        writeHex(p * PAGE_SIZE);
                        serial.writeString(" has ref=");
                        writeDecimal(ref_counts[p]);
                        serial.writeString(" but bitmap says free!\n");
                    }
                    clearBit(p);
                    free_pages -= 1;
                    ref_counts[p] = 1;
                }
                return run_start * PAGE_SIZE;
            }
        } else {
            run_len = 0;
        }
    }

    return null;
}

// --- Huge page (2 MiB) allocation ---

pub const HUGE_PAGE_SIZE: u64 = 2 * 1024 * 1024; // 2 MiB
pub const GIGA_PAGE_SIZE: u64 = 1024 * 1024 * 1024; // 1 GiB
const PAGES_PER_HUGE: u64 = HUGE_PAGE_SIZE / PAGE_SIZE; // 512
const PAGES_PER_GIGA: u64 = GIGA_PAGE_SIZE / PAGE_SIZE; // 262144

/// Allocate a single 2MB-aligned huge page (512 contiguous 4KB frames).
/// Returns 2MB-aligned physical address or null.
pub fn allocHugePage() ?types.PhysAddr {
    return allocHugePages(1);
}

/// Allocate count contiguous 2MB huge pages. Each must be 2MB-aligned.
pub fn allocHugePages(count: u64) ?types.PhysAddr {
    if (count == 0) return null;
    const total_needed = count * PAGES_PER_HUGE;
    if (free_pages < total_needed) return null;

    // Scan for aligned runs of free pages
    var base: u64 = PAGES_PER_HUGE; // Skip page 0 region
    // Round up to first aligned boundary
    if (base % PAGES_PER_HUGE != 0) {
        base = ((base / PAGES_PER_HUGE) + 1) * PAGES_PER_HUGE;
    }

    outer: while (base + total_needed <= total_pages) : (base += PAGES_PER_HUGE) {
        // Check all pages in this aligned run are free
        var p: u64 = base;
        while (p < base + total_needed) : (p += 1) {
            if (!testBit(p)) continue :outer;
        }

        // Found — mark all as used
        p = base;
        while (p < base + total_needed) : (p += 1) {
            clearBit(p);
            free_pages -= 1;
            ref_counts[p] = 1;
        }
        return base * PAGE_SIZE;
    }

    return null;
}

/// Free a single 2MB huge page (512 contiguous frames).
pub fn freeHugePage(phys: types.PhysAddr) void {
    const start_page = phys / PAGE_SIZE;
    var p: u64 = start_page;
    while (p < start_page + PAGES_PER_HUGE) : (p += 1) {
        freePage(p * PAGE_SIZE);
    }
}

/// Allocate a single 1GB-aligned gigapage (262144 contiguous 4KB frames).
/// Used for DPDK-style DMA regions where a single TLB entry covers 1 GB.
/// Returns 1GB-aligned physical address or null.
pub fn allocGigaPage() ?types.PhysAddr {
    const total_needed = PAGES_PER_GIGA;
    if (free_pages < total_needed) return null;

    // Scan for 1GB-aligned free region
    var base: u64 = PAGES_PER_GIGA; // Start at first 1GB boundary
    if (base % PAGES_PER_GIGA != 0) {
        base = ((base / PAGES_PER_GIGA) + 1) * PAGES_PER_GIGA;
    }

    outer: while (base + total_needed <= total_pages) : (base += PAGES_PER_GIGA) {
        var p: u64 = base;
        while (p < base + total_needed) : (p += 1) {
            if (!testBit(p)) continue :outer;
        }

        // Found — mark all as used
        p = base;
        while (p < base + total_needed) : (p += 1) {
            clearBit(p);
            free_pages -= 1;
            ref_counts[p] = 1;
        }
        return base * PAGE_SIZE;
    }
    return null;
}

/// Free a single 1GB gigapage.
pub fn freeGigaPage(phys: types.PhysAddr) void {
    const start_page = phys / PAGE_SIZE;
    var p: u64 = start_page;
    while (p < start_page + PAGES_PER_GIGA) : (p += 1) {
        freePage(p * PAGE_SIZE);
    }
}

/// Free n contiguous physical pages.
pub fn freePages(phys: types.PhysAddr, count: u64) void {
    // Note: calls freePage which acquires its own lock per page.
    // This is fine — each freePage call is independent.
    const start_page = phys / PAGE_SIZE;
    var p: u64 = start_page;
    while (p < start_page + count) : (p += 1) {
        freePage(p * PAGE_SIZE);
    }
}

// --- Anti-rowhammer guarded allocation ---

/// Default number of buffer pages on each side of sensitive allocations.
/// 1 page = 4KB buffer; use 2 for full 8KB DRAM row coverage.
pub const ROWHAMMER_GUARD_PAGES: u64 = 1;

/// Kernel stack canary value — written at the bottom of every kernel stack.
pub const STACK_CANARY: u64 = 0xDEAD_BEEF_CAFE_BABE;

/// Allocate `count` contiguous pages with `guard` buffer pages on each side.
/// Returns the physical address of the first usable page (guard pages precede it).
/// Guard pages are pinned via incRef to prevent accidental freeing.
pub fn allocPagesGuarded(count: u64, guard: u64) ?types.PhysAddr {
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
pub fn freePagesGuarded(phys: types.PhysAddr, count: u64, guard: u64) void {
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

pub fn getFreePages() u64 {
    return free_pages;
}

pub fn getTotalPages() u64 {
    return total_pages;
}

pub fn getHighestPhys() u64 {
    return highest_phys;
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

// --- Output helpers ---

fn kindName(kind: limine.MemmapKind) []const u8 {
    return switch (kind) {
        .usable => "usable",
        .reserved => "reserved",
        .acpi_reclaimable => "ACPI reclaimable",
        .acpi_nvs => "ACPI NVS",
        .bad_memory => "bad memory",
        .bootloader_reclaimable => "bootloader reclaimable",
        .kernel_and_modules => "kernel",
        .framebuffer => "framebuffer",
    };
}

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
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
