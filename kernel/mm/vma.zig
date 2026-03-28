/// Virtual Memory Area tracking — per-process VMA list.
/// Each VMA describes a contiguous range of valid virtual addresses
/// with associated permissions. Used by the page fault handler to
/// determine if a fault is valid (demand page) or invalid (SIGSEGV).

pub const VMA_READ: u32 = 1;
pub const VMA_WRITE: u32 = 2;
pub const VMA_EXEC: u32 = 4;
pub const VMA_USER: u32 = 8;
pub const VMA_ANON: u32 = 16; // Anonymous mapping (no file backing)
pub const VMA_HUGEPAGE: u32 = 32; // 2MB hugepage backing (DMA/DPDK)
pub const VMA_GIGAPAGE: u32 = 64; // 1GB gigapage backing

/// Page size constants for VMA-aware mapping
pub const PAGE_SIZE_4K: u64 = 4096;
pub const PAGE_SIZE_2M: u64 = 2 * 1024 * 1024;
pub const PAGE_SIZE_1G: u64 = 1024 * 1024 * 1024;

pub const Vma = struct {
    start: u64, // page-aligned, inclusive
    end: u64, // page-aligned, exclusive
    flags: u32, // VMA_READ | VMA_WRITE | ...
    in_use: bool,
    guard_pages: u16 = 0, // Guard pages at bottom of VMA (stack overflow detection)
    page_size: u64 = PAGE_SIZE_4K, // Backing page size: 4K, 2M, or 1G
    phys_base: u64 = 0, // Hugepage: contiguous physical base (0 for demand-paged 4K)
    inode: ?*anyopaque, // File-backed: inode for reading pages (null for anon)
    file_offset: u64, // File-backed: offset into file for this VMA's start
    file_size: u64, // File-backed: bytes of file data in this VMA (rest is BSS/zero)
};

pub const MAX_VMAS = 1024; // zig cc needs 200+ VMAs for LLVM allocations; 1024 for headroom
pub const VmaList = [MAX_VMAS]Vma;

/// Initialize all VMA slots to empty.
pub fn initVmaList(list: *VmaList) void {
    for (0..MAX_VMAS) |i| {
        list[i] = .{
            .start = 0,
            .end = 0,
            .flags = 0,
            .in_use = false,
            .inode = null,
            .file_offset = 0,
            .file_size = 0,
        };
    }
}

/// Get the backing page size for a VMA.
pub fn vmaPageSize(v: *const Vma) u64 {
    return v.page_size;
}

/// Find the VMA containing addr (start <= addr < end).
/// Returns null if no VMA covers the address.
pub fn findVma(list: *VmaList, addr: u64) ?*Vma {
    for (0..MAX_VMAS) |i| {
        if (list[i].in_use and list[i].start <= addr and addr < list[i].end) {
            return &list[i];
        }
    }
    return null;
}

/// Add a new VMA. Returns null if no free slot.
pub fn addVma(list: *VmaList, start: u64, end: u64, flags: u32) ?*Vma {
    for (0..MAX_VMAS) |i| {
        if (!list[i].in_use) {
            list[i] = .{
                .start = start,
                .end = end,
                .flags = flags,
                .in_use = true,
                .inode = null,
                .file_offset = 0,
                .file_size = 0,
            };
            return &list[i];
        }
    }
    return null;
}

/// Add a VMA for mmap with inode and file offset support.
pub fn addMmapVma(list: *VmaList, start: u64, end: u64, flags: u32, inode: ?*anyopaque, file_offset: u64) ?*Vma {
    for (0..MAX_VMAS) |i| {
        if (!list[i].in_use) {
            list[i] = .{
                .start = start,
                .end = end,
                .flags = flags,
                .in_use = true,
                .inode = inode,
                .file_offset = file_offset,
                .file_size = 0,
            };
            return &list[i];
        }
    }
    return null;
}

/// Add a VMA for hugepage mappings (2MB or 1GB pages).
/// Records the contiguous physical base address for virt-to-phys translation.
pub fn addMmapVmaHuge(list: *VmaList, start: u64, end: u64, flags: u32, phys_base: u64) ?*Vma {
    for (0..MAX_VMAS) |i| {
        if (!list[i].in_use) {
            list[i] = .{
                .start = start,
                .end = end,
                .flags = flags,
                .in_use = true,
                .page_size = if (flags & VMA_GIGAPAGE != 0) PAGE_SIZE_1G else PAGE_SIZE_2M,
                .phys_base = phys_base,
                .inode = null,
                .file_offset = 0,
                .file_size = 0,
            };
            return &list[i];
        }
    }
    return null;
}

/// Add a VMA for ELF LOAD segments with file_size (BSS boundary awareness).
pub fn addElfVma(list: *VmaList, start: u64, end: u64, flags: u32, inode: ?*anyopaque, file_offset: u64, file_size: u64) ?*Vma {
    for (0..MAX_VMAS) |i| {
        if (!list[i].in_use) {
            list[i] = .{
                .start = start,
                .end = end,
                .flags = flags,
                .in_use = true,
                .inode = inode,
                .file_offset = file_offset,
                .file_size = file_size,
            };
            return &list[i];
        }
    }
    return null;
}

/// Remove a VMA by start address. Returns true if found and removed.
pub fn removeVma(list: *VmaList, start: u64) bool {
    for (0..MAX_VMAS) |i| {
        if (list[i].in_use and list[i].start == start) {
            list[i].in_use = false;
            return true;
        }
    }
    return false;
}

/// Extend a VMA's end address (used by brk expansion).
pub fn extendVma(v: *Vma, new_end: u64) void {
    v.end = new_end;
}

/// Shrink a VMA's end address (used by brk shrink).
pub fn shrinkVma(v: *Vma, new_end: u64) void {
    v.end = new_end;
}

/// Find the heap VMA by matching start address == heap_start.
pub fn findHeapVma(list: *VmaList, heap_start: u64) ?*Vma {
    for (0..MAX_VMAS) |i| {
        if (list[i].in_use and list[i].start == heap_start) {
            return &list[i];
        }
    }
    return null;
}

/// Handle MAP_FIXED overlap: remove, trim, or split existing VMAs that overlap
/// with the range [map_start, map_end). Returns false if a split is needed but
/// no free VMA slot is available.
/// Delegates to the shared handleRangeRemoval implementation.
pub fn handleMapFixedOverlap(list: *VmaList, map_start: u64, map_end: u64) bool {
    return handleRangeRemoval(list, map_start, map_end);
}

/// Handle range removal: remove, trim, or split existing VMAs that overlap
/// with the range [rm_start, rm_end). Used by both munmap and mmap(MAP_FIXED).
/// Returns false if a split is needed but no free VMA slot is available.
pub fn handleRangeRemoval(list: *VmaList, rm_start: u64, rm_end: u64) bool {
    var i: usize = 0;
    while (i < MAX_VMAS) : (i += 1) {
        if (!list[i].in_use) continue;

        const vs = list[i].start;
        const ve = list[i].end;

        // No overlap — skip
        if (ve <= rm_start or vs >= rm_end) continue;

        if (vs >= rm_start and ve <= rm_end) {
            // VMA completely inside the removal range — remove it
            list[i].in_use = false;
        } else if (vs < rm_start and ve > rm_end) {
            // VMA contains the entire removal range — split into two
            const saved_flags = list[i].flags;
            const saved_inode = list[i].inode;
            const saved_file_offset = list[i].file_offset;
            const saved_file_size = list[i].file_size;

            // Trim existing VMA to [vs, rm_start)
            list[i].end = rm_start;
            if (saved_file_size > (rm_start - vs)) {
                list[i].file_size = rm_start - vs;
            }

            // Compute file offset adjustment for the right half
            const right_file_offset = if (saved_inode != null)
                saved_file_offset + (rm_end - vs)
            else
                0;
            const right_file_size = if (saved_file_size > (rm_end - vs))
                saved_file_size - (rm_end - vs)
            else
                0;

            // Find a free slot for the right half [rm_end, ve)
            var found_slot = false;
            for (0..MAX_VMAS) |j| {
                if (!list[j].in_use) {
                    list[j] = .{
                        .start = rm_end,
                        .end = ve,
                        .flags = saved_flags,
                        .in_use = true,
                        .inode = saved_inode,
                        .file_offset = right_file_offset,
                        .file_size = right_file_size,
                    };
                    found_slot = true;
                    break;
                }
            }
            if (!found_slot) return false;
        } else if (vs < rm_start) {
            // VMA overlaps from left — trim end
            list[i].end = rm_start;
            if (list[i].file_size > (rm_start - vs)) {
                list[i].file_size = rm_start - vs;
            }
        } else {
            // VMA overlaps from right — trim start
            if (list[i].inode != null) {
                list[i].file_offset += (rm_end - vs);
            }
            if (list[i].file_size > (rm_end - vs)) {
                list[i].file_size -= (rm_end - vs);
            } else {
                list[i].file_size = 0;
            }
            list[i].start = rm_end;
        }
    }
    return true;
}

/// Split a VMA for mprotect: change flags on [prot_start, prot_end) while
/// preserving the rest of the VMA with original flags. The VMA containing
/// prot_start must already exist.
/// Returns false if no free VMA slots for the split.
pub fn splitForProtect(list: *VmaList, prot_start: u64, prot_end: u64, new_flags: u32) bool {
    // Find the VMA covering prot_start
    var vi: usize = 0;
    while (vi < MAX_VMAS) : (vi += 1) {
        if (!list[vi].in_use) continue;
        if (list[vi].start <= prot_start and prot_start < list[vi].end) break;
    }
    if (vi >= MAX_VMAS) return false;

    const vs = list[vi].start;
    const ve = list[vi].end;

    // Clamp prot_end to the VMA's end
    const clamped_end = if (prot_end > ve) ve else prot_end;

    // Case 1: Exact match — just change flags
    if (prot_start == vs and clamped_end == ve) {
        list[vi].flags = new_flags;
        return true;
    }

    // Case 2: mprotect covers the start of the VMA [vs, clamped_end)
    // Split into: [vs, clamped_end) with new_flags, [clamped_end, ve) with old_flags
    if (prot_start == vs) {
        const saved_flags = list[vi].flags;
        const saved_inode = list[vi].inode;
        const saved_file_offset = list[vi].file_offset;
        const saved_file_size = list[vi].file_size;

        // Change existing VMA to [vs, clamped_end) with new flags
        list[vi].end = clamped_end;
        list[vi].flags = new_flags;
        if (saved_file_size > (clamped_end - vs)) {
            list[vi].file_size = clamped_end - vs;
        }

        // Create right half [clamped_end, ve) with old flags
        const right_file_offset = if (saved_inode != null)
            saved_file_offset + (clamped_end - vs)
        else
            0;
        const right_file_size = if (saved_file_size > (clamped_end - vs))
            saved_file_size - (clamped_end - vs)
        else
            0;

        for (0..MAX_VMAS) |j| {
            if (!list[j].in_use) {
                list[j] = .{
                    .start = clamped_end,
                    .end = ve,
                    .flags = saved_flags,
                    .in_use = true,
                    .inode = saved_inode,
                    .file_offset = right_file_offset,
                    .file_size = right_file_size,
                };
                return true;
            }
        }
        // Failed to allocate — undo
        list[vi].end = ve;
        list[vi].flags = saved_flags;
        list[vi].file_size = saved_file_size;
        return false;
    }

    // Case 3: mprotect covers the end of the VMA [prot_start, ve)
    if (clamped_end == ve) {
        const saved_inode = list[vi].inode;
        const saved_file_offset = list[vi].file_offset;
        const saved_file_size = list[vi].file_size;

        // Trim existing VMA to [vs, prot_start) with old flags
        list[vi].end = prot_start;
        if (saved_file_size > (prot_start - vs)) {
            list[vi].file_size = prot_start - vs;
        }

        // Create right part [prot_start, ve) with new flags
        const right_file_offset = if (saved_inode != null)
            saved_file_offset + (prot_start - vs)
        else
            0;
        const right_file_size = if (saved_file_size > (prot_start - vs))
            saved_file_size - (prot_start - vs)
        else
            0;

        for (0..MAX_VMAS) |j| {
            if (!list[j].in_use) {
                list[j] = .{
                    .start = prot_start,
                    .end = ve,
                    .flags = new_flags,
                    .in_use = true,
                    .inode = saved_inode,
                    .file_offset = right_file_offset,
                    .file_size = right_file_size,
                };
                return true;
            }
        }
        // Failed to allocate — undo
        list[vi].end = ve;
        list[vi].file_size = saved_file_size;
        return false;
    }

    // Case 4: mprotect is in the middle — split into 3
    // [vs, prot_start) old flags, [prot_start, clamped_end) new flags, [clamped_end, ve) old flags
    const saved_flags = list[vi].flags;
    const saved_inode = list[vi].inode;
    const saved_file_offset = list[vi].file_offset;
    const saved_file_size = list[vi].file_size;

    // Trim existing VMA to left part [vs, prot_start)
    list[vi].end = prot_start;
    if (saved_file_size > (prot_start - vs)) {
        list[vi].file_size = prot_start - vs;
    }

    // Compute file offsets for middle and right
    const mid_file_offset = if (saved_inode != null)
        saved_file_offset + (prot_start - vs)
    else
        0;
    const mid_file_size = if (saved_file_size > (prot_start - vs))
        @min(saved_file_size - (prot_start - vs), clamped_end - prot_start)
    else
        0;
    const right_file_offset = if (saved_inode != null)
        saved_file_offset + (clamped_end - vs)
    else
        0;
    const right_file_size = if (saved_file_size > (clamped_end - vs))
        saved_file_size - (clamped_end - vs)
    else
        0;

    // Allocate two free slots for middle and right
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

    if (mid_slot == null or right_slot == null) {
        // Undo — restore original VMA
        list[vi].end = ve;
        list[vi].file_size = saved_file_size;
        return false;
    }

    // Middle VMA [prot_start, clamped_end) with new flags
    list[mid_slot.?] = .{
        .start = prot_start,
        .end = clamped_end,
        .flags = new_flags,
        .in_use = true,
        .inode = saved_inode,
        .file_offset = mid_file_offset,
        .file_size = mid_file_size,
    };

    // Right VMA [clamped_end, ve) with old flags
    list[right_slot.?] = .{
        .start = clamped_end,
        .end = ve,
        .flags = saved_flags,
        .in_use = true,
        .inode = saved_inode,
        .file_offset = right_file_offset,
        .file_size = right_file_size,
    };

    return true;
}

/// Return an empty VmaList suitable for struct initialization.
pub fn emptyVmaList() VmaList {
    @setEvalBranchQuota(10000);
    var list: VmaList = undefined;
    for (0..MAX_VMAS) |i| {
        list[i] = .{
            .start = 0,
            .end = 0,
            .flags = 0,
            .in_use = false,
            .inode = null,
            .file_offset = 0,
            .file_size = 0,
        };
    }
    return list;
}
