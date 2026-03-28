/// Virtual Memory Area (VMA) tracking for demand paging and mmap.
///
/// Each process has a list of VMAs describing its virtual address layout.
/// On page fault, the fault handler looks up the VMA to decide:
/// - Allocate a zero page (anonymous mapping)
/// - Load from file (file-backed mapping)
/// - Kill the process (segfault — no VMA covers the address)

const vfs = @import("vfs.zig");
const uart = @import("uart.zig");

pub const MAX_VMAS: usize = 512;

pub const VmaFlags = packed struct {
    readable: bool = true,
    writable: bool = false,
    executable: bool = false,
    user: bool = true,
    shared: bool = false,    // Shared mapping (vs private/CoW)
    file_backed: bool = false,
    stack: bool = false,     // Stack VMA (grows downward)
    _pad: u1 = 0,
};

pub const Vma = struct {
    start: u64 = 0,         // Inclusive start address (page-aligned)
    end: u64 = 0,           // Exclusive end address (page-aligned)
    flags: VmaFlags = .{},
    guard_pages: u16 = 0,   // Guard pages at bottom of VMA (stack overflow detection)
    file: ?*vfs.FileDescription = null,
    file_offset: u64 = 0,   // Offset into file for file-backed mappings
    file_size: u64 = 0,     // Size of file-backed data in this VMA (for BSS boundary awareness)
    file_ino: u32 = 0,      // Inode number at VMA creation — for re-resolving stale inode pointers
    in_use: bool = false,
};

pub const VmaList = [MAX_VMAS]Vma;

pub fn initVmaList(list: *VmaList) void {
    for (0..MAX_VMAS) |i| {
        list[i] = .{
            .start = 0,
            .end = 0,
            .flags = .{},
            .file = null,
            .file_offset = 0,
            .file_size = 0,
            .in_use = false,
        };
    }
}

/// Copy VMAs from parent to child (for fork).
pub fn copyVmas(dst: *VmaList, src: *const VmaList) void {
    for (0..MAX_VMAS) |i| {
        dst[i] = src[i];
    }
}

/// Add a VMA to the process's VMA list.
/// If all slots are full, runs a compaction pass to merge adjacent anonymous VMAs
/// with identical flags, freeing slots for reuse. This handles the Zig compiler's
/// arena allocator pattern (thousands of small consecutive mmap calls).
pub fn addVma(list: *VmaList, start: u64, end: u64, flags: VmaFlags) ?*Vma {
    if (end <= start) return null; // Reject zero-size or inverted VMAs
    // Fast path: find a free slot directly
    for (0..MAX_VMAS) |i| {
        if (!list[i].in_use) {
            list[i] = .{
                .start = start,
                .end = end,
                .flags = flags,
                .file = null,
                .file_offset = 0,
                .file_size = 0,
                .in_use = true,
            };
            return &list[i];
        }
    }

    // All slots full — compact by merging adjacent anonymous VMAs with same flags.
    // This is safe because merged VMAs cover the same total range — no address
    // becomes unmapped, so concurrent page fault lookups still succeed.
    _ = compactVmas(list);

    // Retry after compaction
    for (0..MAX_VMAS) |i| {
        if (!list[i].in_use) {
            list[i] = .{
                .start = start,
                .end = end,
                .flags = flags,
                .file = null,
                .file_offset = 0,
                .file_size = 0,
                .in_use = true,
            };
            return &list[i];
        }
    }
    return null;
}

/// Merge adjacent anonymous VMAs with identical flags to free VMA slots.
/// Returns the number of VMAs freed. Only merges non-file-backed VMAs.
/// Safe for concurrent page fault lookups: merged VMAs cover strictly
/// MORE addresses than the originals, so no findVma call can miss.
pub fn compactVmas(list: *VmaList) usize {
    var freed: usize = 0;
    var changed = true;

    // Repeat until no more merges found (multi-pass for chains)
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < MAX_VMAS) : (i += 1) {
            if (!list[i].in_use or list[i].file != null) continue;

            // Look for an adjacent VMA to the right (list[j].start == list[i].end)
            var j: usize = 0;
            while (j < MAX_VMAS) : (j += 1) {
                if (j == i or !list[j].in_use or list[j].file != null) continue;
                if (list[j].start != list[i].end) continue;
                if (!flagsEqual(list[i].flags, list[j].flags)) continue;

                // Merge: extend i to cover j, then free j.
                // Order matters for concurrent safety:
                // 1. Extend i first (now both i and j cover j's range — findVma sees either)
                // 2. Then mark j as unused (findVma now only sees i)
                list[i].end = list[j].end;
                // Memory barrier: ensure the extended .end is visible before we
                // mark j as free, so no concurrent findVma sees a gap.
                asm volatile ("fence rw, rw" ::: .{ .memory = true });
                list[j].in_use = false;
                freed += 1;
                changed = true;
                break; // restart scan for i since it grew
            }
        }
    }
    return freed;
}

/// Compare VMA flags for merge eligibility.
fn flagsEqual(a: VmaFlags, b: VmaFlags) bool {
    return a.readable == b.readable and
        a.writable == b.writable and
        a.executable == b.executable and
        a.user == b.user and
        a.shared == b.shared and
        a.file_backed == b.file_backed and
        a.stack == b.stack;
}

/// Add a file-backed VMA. Increments the FileDescription ref_count so the
/// file stays alive as long as this VMA exists (even after fd close).
pub fn addFileVma(
    list: *VmaList,
    start: u64,
    end: u64,
    flags: VmaFlags,
    file: *vfs.FileDescription,
    offset: u64,
) ?*Vma {
    for (0..MAX_VMAS) |i| {
        if (!list[i].in_use) {
            _ = @atomicRmw(u32, &file.ref_count, .Add, 1, .acq_rel);
            list[i] = .{
                .start = start,
                .end = end,
                .flags = flags,
                .file = file,
                .file_offset = offset,
                .file_size = 0,
                .file_ino = @truncate(file.inode.ino),
                .in_use = true,
            };
            return &list[i];
        }
    }
    return null;
}

/// Add a VMA for ELF LOAD segments with file_size (BSS boundary awareness).
/// file_size tracks how many bytes in this VMA are backed by file data vs.
/// zero-fill (BSS). When a page fault occurs within [start, start+file_size),
/// the page is loaded from disk. Pages beyond file_size are zero-filled.
/// Increments FileDescription ref_count if file is non-null.
pub fn addElfVma(list: *VmaList, start: u64, end: u64, flags: VmaFlags, file: ?*vfs.FileDescription, file_offset: u64, file_size: u64) ?*Vma {
    for (0..MAX_VMAS) |i| {
        if (!list[i].in_use) {
            if (file) |f| _ = @atomicRmw(u32, &f.ref_count, .Add, 1, .acq_rel);
            list[i] = .{
                .start = start,
                .end = end,
                .flags = flags,
                .file = file,
                .file_offset = file_offset,
                .file_size = file_size,
                .file_ino = if (file) |f| @truncate(f.inode.ino) else 0,
                .in_use = true,
            };
            return &list[i];
        }
    }
    return null;
}

/// Find the VMA that contains the given address.
pub fn findVma(list: *const VmaList, addr: u64) ?*const Vma {
    for (0..MAX_VMAS) |i| {
        if (list[i].in_use and addr >= list[i].start and addr < list[i].end) {
            return &list[i];
        }
    }
    return null;
}

/// Remove a VMA by address range. Releases file ref if file-backed.
pub fn removeVma(list: *VmaList, start: u64, end: u64) bool {
    for (0..MAX_VMAS) |i| {
        if (list[i].in_use and list[i].start == start and list[i].end == end) {
            if (list[i].file) |f| vfs.releaseFileDescription(f);
            list[i].in_use = false;
            return true;
        }
    }
    return false;
}

/// Handle MAP_FIXED overlap: remove, trim, or split existing VMAs that overlap
/// with the range [map_start, map_end). Returns false if a split is needed but
/// no free VMA slot is available.
pub fn handleMapFixedOverlap(list: *VmaList, map_start: u64, map_end: u64) bool {
    var i: usize = 0;
    while (i < MAX_VMAS) : (i += 1) {
        if (!list[i].in_use) continue;

        const vs = list[i].start;
        const ve = list[i].end;

        // No overlap — skip
        if (ve <= map_start or vs >= map_end) continue;

        if (vs >= map_start and ve <= map_end) {
            // Case 1: VMA completely inside the MAP_FIXED range — remove it
            if (list[i].file) |f| vfs.releaseFileDescription(f);
            list[i].in_use = false;
        } else if (vs < map_start and ve > map_end) {
            // Case 4: VMA contains the entire MAP_FIXED range — split into two
            // Keep [vs, map_start) in this slot, create [map_end, ve) in a new slot
            const saved_flags = list[i].flags;
            const saved_file = list[i].file;
            const saved_file_offset = list[i].file_offset;
            const saved_file_size = list[i].file_size;

            // Trim existing VMA to [vs, map_start)
            list[i].end = map_start;

            // Compute file offset adjustment for the right half
            const right_file_offset = if (saved_file != null)
                saved_file_offset + (map_end - vs)
            else
                0;
            const right_file_size = if (saved_file_size > (map_end - vs))
                saved_file_size - (map_end - vs)
            else
                0;

            // Find a free slot for the right half [map_end, ve)
            var found_slot = false;
            for (0..MAX_VMAS) |j| {
                if (!list[j].in_use) {
                    if (saved_file) |f| _ = @atomicRmw(u32, &f.ref_count, .Add, 1, .acq_rel);
                    list[j] = .{
                        .start = map_end,
                        .end = ve,
                        .flags = saved_flags,
                        .file = saved_file,
                        .file_offset = right_file_offset,
                        .file_size = right_file_size,
                        .in_use = true,
                    };
                    found_slot = true;
                    break;
                }
            }
            if (!found_slot) {
                // Try compacting to free slots, then retry
                _ = compactVmas(list);
                for (0..MAX_VMAS) |j| {
                    if (!list[j].in_use) {
                        if (saved_file) |f| _ = @atomicRmw(u32, &f.ref_count, .Add, 1, .acq_rel);
                        list[j] = .{
                            .start = map_end,
                            .end = ve,
                            .flags = saved_flags,
                            .file = saved_file,
                            .file_offset = right_file_offset,
                            .file_size = right_file_size,
                            .in_use = true,
                        };
                        found_slot = true;
                        break;
                    }
                }
                if (!found_slot) {
                    // Revert the trim so the VMA isn't partially destroyed
                    list[i].end = ve;
                    return false;
                }
            }
        } else if (vs < map_start) {
            // Case 2: VMA overlaps from left — trim end
            list[i].end = map_start;
        } else {
            // Case 3: VMA overlaps from right — trim start
            // Adjust file offset if file-backed
            if (list[i].file != null) {
                list[i].file_offset += (map_end - vs);
            }
            if (list[i].file_size > (map_end - vs)) {
                list[i].file_size -= (map_end - vs);
            } else {
                list[i].file_size = 0;
            }
            list[i].start = map_end;
        }
    }
    return true;
}

/// Find a mutable VMA that contains the given address.
pub fn findVmaMut(list: *VmaList, addr: u64) ?*Vma {
    for (0..MAX_VMAS) |i| {
        if (list[i].in_use and addr >= list[i].start and addr < list[i].end) {
            return &list[i];
        }
    }
    return null;
}

/// Count active VMAs.
pub fn countVmas(list: *const VmaList) usize {
    var count: usize = 0;
    for (0..MAX_VMAS) |i| {
        if (list[i].in_use) count += 1;
    }
    return count;
}

/// Split a VMA for mprotect: change permissions on the sub-range [prot_start, prot_end)
/// while preserving the rest of the VMA with its original permissions. Handles 4 cases:
/// - Exact match: just update flags
/// - Start trim: split into [changed, remainder)
/// - End trim: split into [remainder, changed)
/// - Middle (3-way): split into [left_old, middle_new, right_old)
/// Returns true on success. On failure (no free VMA slots), the list is unchanged.
pub fn splitForProtect(list: *VmaList, prot_start: u64, prot_end: u64, new_flags: VmaFlags) bool {
    // Find the VMA covering prot_start
    var vi: usize = 0;
    while (vi < MAX_VMAS) : (vi += 1) {
        if (!list[vi].in_use) continue;
        if (list[vi].start <= prot_start and prot_start < list[vi].end) break;
    }
    if (vi >= MAX_VMAS) return false;

    const vs = list[vi].start;
    const ve = list[vi].end;
    const clamped_end = if (prot_end > ve) ve else prot_end;

    // Case 1: Exact match — just change flags
    if (prot_start == vs and clamped_end == ve) {
        list[vi].flags = new_flags;
        return true;
    }

    // Case 2: mprotect covers the start [vs, clamped_end) — split off the right remainder
    if (prot_start == vs) {
        const saved_flags = list[vi].flags;
        const saved_file = list[vi].file;
        const saved_foff = list[vi].file_offset;
        const saved_fsz = list[vi].file_size;
        const delta = clamped_end - vs;

        // Modify existing to [vs, clamped_end) with new flags
        list[vi].end = clamped_end;
        list[vi].flags = new_flags;
        if (saved_fsz > delta) list[vi].file_size = delta;

        // Create right remainder [clamped_end, ve) with old flags
        const right_foff = if (saved_file != null) saved_foff + delta else 0;
        const right_fsz = if (saved_fsz > delta) saved_fsz - delta else 0;
        for (0..MAX_VMAS) |j| {
            if (!list[j].in_use) {
                if (saved_file) |f| _ = @atomicRmw(u32, &f.ref_count, .Add, 1, .acq_rel);
                list[j] = .{
                    .start = clamped_end,
                    .end = ve,
                    .flags = saved_flags,
                    .file = saved_file,
                    .file_offset = right_foff,
                    .file_size = right_fsz,
                    .in_use = true,
                };
                return true;
            }
        }
        // Failed — undo
        list[vi].end = ve;
        list[vi].flags = saved_flags;
        list[vi].file_size = saved_fsz;
        return false;
    }

    // Case 3: mprotect covers the end [prot_start, ve) — split off the left remainder
    if (clamped_end == ve) {
        const saved_file = list[vi].file;
        const saved_foff = list[vi].file_offset;
        const saved_fsz = list[vi].file_size;
        const delta = prot_start - vs;

        // Trim existing to left remainder [vs, prot_start)
        list[vi].end = prot_start;
        if (saved_fsz > delta) list[vi].file_size = delta;

        // Create right part [prot_start, ve) with new flags
        const right_foff = if (saved_file != null) saved_foff + delta else 0;
        const right_fsz = if (saved_fsz > delta) saved_fsz - delta else 0;
        for (0..MAX_VMAS) |j| {
            if (!list[j].in_use) {
                if (saved_file) |f| _ = @atomicRmw(u32, &f.ref_count, .Add, 1, .acq_rel);
                list[j] = .{
                    .start = prot_start,
                    .end = ve,
                    .flags = new_flags,
                    .file = saved_file,
                    .file_offset = right_foff,
                    .file_size = right_fsz,
                    .in_use = true,
                };
                return true;
            }
        }
        // Failed — undo
        list[vi].end = ve;
        list[vi].file_size = saved_fsz;
        return false;
    }

    // Case 4: mprotect is in the middle — 3-way split
    const saved_flags = list[vi].flags;
    const saved_file = list[vi].file;
    const saved_foff = list[vi].file_offset;
    const saved_fsz = list[vi].file_size;
    const left_delta = prot_start - vs;
    const mid_delta = clamped_end - vs;

    // Pre-allocate two free slots before mutating
    var mid_slot: ?usize = null;
    var right_slot: ?usize = null;
    for (0..MAX_VMAS) |j| {
        if (!list[j].in_use) {
            if (mid_slot == null) {
                mid_slot = j;
            } else if (right_slot == null) {
                right_slot = j;
                break;
            }
        }
    }
    if (mid_slot == null or right_slot == null) return false;

    // Trim existing to left part [vs, prot_start)
    list[vi].end = prot_start;
    if (saved_fsz > left_delta) list[vi].file_size = left_delta;

    // Middle VMA [prot_start, clamped_end) with new flags
    const mid_foff = if (saved_file != null) saved_foff + left_delta else 0;
    const mid_fsz = if (saved_fsz > left_delta)
        @min(saved_fsz - left_delta, clamped_end - prot_start)
    else
        0;
    if (saved_file) |f| _ = @atomicRmw(u32, &f.ref_count, .Add, 1, .acq_rel);
    list[mid_slot.?] = .{
        .start = prot_start,
        .end = clamped_end,
        .flags = new_flags,
        .file = saved_file,
        .file_offset = mid_foff,
        .file_size = mid_fsz,
        .in_use = true,
    };

    // Right VMA [clamped_end, ve) with old flags
    const right_foff = if (saved_file != null) saved_foff + mid_delta else 0;
    const right_fsz = if (saved_fsz > mid_delta) saved_fsz - mid_delta else 0;
    if (saved_file) |f| _ = @atomicRmw(u32, &f.ref_count, .Add, 1, .acq_rel);
    list[right_slot.?] = .{
        .start = clamped_end,
        .end = ve,
        .flags = saved_flags,
        .file = saved_file,
        .file_offset = right_foff,
        .file_size = right_fsz,
        .in_use = true,
    };

    return true;
}

/// Release FileDescription refs for all file-backed VMAs in the list.
/// Call before initVmaList (execve) or before destroying an address space (exit).
pub fn releaseAllFileRefs(list: *VmaList) void {
    for (0..MAX_VMAS) |i| {
        if (list[i].in_use) {
            if (list[i].file) |f| vfs.releaseFileDescription(f);
            list[i].file = null;
        }
    }
}
