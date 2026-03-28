/// RISC-V Physical Memory Manager — bitmap allocator.
///
/// QEMU virt machine memory map:
///   0x80000000 - 0x801FFFFF : OpenSBI firmware (2 MB)
///   0x80200000 - kernel_end : Kernel image
///   kernel_end - RAM_END    : Free pages
///
/// Same design as ARM64 PMM: bitmap + ref counts, identity mapping.

const uart = @import("uart.zig");

pub const PAGE_SIZE: u64 = 4096;
const PAGE_SHIFT: u6 = 12;

/// RAM base for QEMU virt
const RAM_BASE: u64 = 0x80000000;

/// Default RAM size (256 MB) — can be overridden by DTB parser
var ram_size: u64 = 256 * 1024 * 1024;

/// Bitmap: 1 = free, 0 = used/reserved
var bitmap: [*]u8 = undefined;
var bitmap_size: u64 = 0;
var total_pages: u64 = 0;
var free_pages: u64 = 0;

/// Reference counts for CoW
var ref_counts: [*]u16 = undefined;
var ref_counts_size: u64 = 0;

var next_free_hint: u64 = 0;
var initialized: bool = false;
var reserved_end: u64 = 0;

/// Linker symbols
extern const __bss_end: u8;
extern const __stack_top: u8;

pub fn setRamSize(size: u64) void {
    if (!initialized and size >= 16 * 1024 * 1024) {
        ram_size = size;
    }
}

pub fn init() void {
    const kernel_end = @intFromPtr(&__stack_top);
    const kernel_end_aligned = (kernel_end + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);

    total_pages = ram_size / PAGE_SIZE;
    bitmap_size = (total_pages + 7) / 8;
    ref_counts_size = total_pages * 2;

    const metadata_size = bitmap_size + ref_counts_size;
    const metadata_pages = (metadata_size + PAGE_SIZE - 1) / PAGE_SIZE;

    const bitmap_addr = kernel_end_aligned;
    bitmap = @ptrFromInt(bitmap_addr);

    const ref_counts_addr = bitmap_addr + bitmap_size;
    ref_counts = @ptrFromInt(ref_counts_addr);

    // Clear bitmap (all pages used)
    for (0..bitmap_size) |i| bitmap[i] = 0;

    // Zero ref counts
    for (0..total_pages) |i| ref_counts[i] = 0;

    // First free page after kernel + metadata
    const metadata_end = bitmap_addr + metadata_size;
    const first_free_page = (metadata_end - RAM_BASE + PAGE_SIZE - 1) / PAGE_SIZE;

    free_pages = 0;
    var page: u64 = first_free_page;
    while (page < total_pages) : (page += 1) {
        setBit(page);
        free_pages += 1;
    }

    next_free_hint = first_free_page;
    reserved_end = RAM_BASE + first_free_page * PAGE_SIZE;
    initialized = true;

    uart.print("[pmm]  RAM: {x} - {x} ({} MB)\n", .{ RAM_BASE, RAM_BASE + ram_size, ram_size / 1024 / 1024 });
    uart.print("[pmm]  Kernel ends at {x}\n", .{kernel_end_aligned});
    uart.print("[pmm]  Bitmap at {x} ({} pages metadata)\n", .{ bitmap_addr, metadata_pages });
    uart.print("[pmm]  Total: {} pages, Free: {} pages ({} MB)\n", .{
        total_pages, free_pages, free_pages * PAGE_SIZE / 1024 / 1024,
    });
}

pub fn allocPage() ?u64 {
    if (!initialized) return null;

    var page = next_free_hint;
    while (page < total_pages) : (page += 1) {
        if (testBit(page)) {
            clearBit(page);
            free_pages -= 1;
            next_free_hint = page + 1;
            ref_counts[page] = 1;
            return RAM_BASE + page * PAGE_SIZE;
        }
    }
    // Wrap around
    page = 1;
    while (page < next_free_hint) : (page += 1) {
        if (testBit(page)) {
            clearBit(page);
            free_pages -= 1;
            next_free_hint = page + 1;
            ref_counts[page] = 1;
            return RAM_BASE + page * PAGE_SIZE;
        }
    }
    return null;
}

pub fn freePage(phys: u64) void {
    if (!initialized) return;
    if (phys < RAM_BASE or phys < reserved_end) return;
    const page = (phys - RAM_BASE) / PAGE_SIZE;
    if (page >= total_pages or page == 0) return;

    if (ref_counts[page] > 1) {
        ref_counts[page] -= 1;
        return;
    }
    ref_counts[page] = 0;
    if (!testBit(page)) {
        setBit(page);
        free_pages += 1;
        if (page < next_free_hint) next_free_hint = page;
    }
}

pub fn allocPages(count: u64) ?u64 {
    if (!initialized or count == 0) return null;
    if (free_pages < count) return null;

    var run_start: u64 = next_free_hint;
    var run_len: u64 = 0;
    var page: u64 = next_free_hint;
    while (page < total_pages) : (page += 1) {
        if (testBit(page)) {
            if (run_len == 0) run_start = page;
            run_len += 1;
            if (run_len == count) {
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

pub fn freePages(phys: u64, count: u64) void {
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        freePage(phys + i * PAGE_SIZE);
    }
}

pub fn incRef(phys: u64) void {
    if (!initialized or phys < RAM_BASE) return;
    const page = (phys - RAM_BASE) / PAGE_SIZE;
    if (page >= total_pages) return;
    if (ref_counts[page] < 65535) ref_counts[page] += 1;
}

pub fn decRef(phys: u64) void {
    if (!initialized or phys < RAM_BASE) return;
    const page = (phys - RAM_BASE) / PAGE_SIZE;
    if (page >= total_pages) return;
    if (ref_counts[page] > 0) ref_counts[page] -= 1;
}

pub fn getRef(phys: u64) u16 {
    if (!initialized or phys < RAM_BASE) return 0;
    const page = (phys - RAM_BASE) / PAGE_SIZE;
    if (page >= total_pages) return 0;
    return ref_counts[page];
}

pub fn getFreePages() u64 { return free_pages; }
pub fn getTotalPages() u64 { return total_pages; }

pub const STACK_CANARY: u64 = 0xDEAD_BEEF_CAFE_BABE;
pub const ROWHAMMER_GUARD_PAGES: u64 = 1;

pub fn allocPagesGuarded(count: u64, guard: u64) ?u64 {
    const total = count + 2 * guard;
    const base_phys = allocPages(total) orelse return null;
    var i: u64 = 0;
    while (i < guard) : (i += 1) {
        incRef(base_phys + i * PAGE_SIZE);
        incRef(base_phys + (count + guard + i) * PAGE_SIZE);
    }
    return base_phys + guard * PAGE_SIZE;
}

// Bitmap operations
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
