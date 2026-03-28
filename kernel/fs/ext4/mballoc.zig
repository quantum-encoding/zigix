/// Multiblock allocator (mballoc) for ext4.
///
/// Allocates multiple contiguous blocks in a single operation, reducing
/// fragmentation for large file writes. Uses bitmap scanning with
/// configurable search strategies.
///
/// Freestanding — no std, no libc.

const bitmap = @import("../common/bitmap.zig");

/// Allocation request — describes what the caller wants.
pub const AllocRequest = struct {
    /// Desired number of contiguous blocks.
    count: u32,
    /// Goal block number (allocate near this if possible).
    goal: u64,
    /// Preferred block group (e.g. from file's inode group or flex_bg).
    preferred_bg: u32,
    /// Minimum acceptable allocation (1 = any size ok, partial allocation).
    min_count: u32 = 1,
};

/// Allocation result — what was actually allocated.
pub const AllocResult = struct {
    /// First block number allocated.
    start: u64 = 0,
    /// Number of contiguous blocks actually allocated.
    count: u32 = 0,
    /// Block group the allocation came from.
    bg: u32 = 0,
};

/// Per-block-group allocation state (read from block group descriptor).
pub const BlockGroupState = struct {
    /// Block group number.
    bg_number: u32,
    /// Block bitmap disk block number.
    bitmap_block: u64,
    /// Free blocks in this group.
    free_blocks: u32,
    /// Blocks per group (from superblock).
    blocks_per_group: u32,
    /// First data block (from superblock, usually 0 or 1).
    first_data_block: u32,
};

/// Find contiguous free blocks in a bitmap.
/// Returns the bit index of the first free bit in a run of `count`, or null.
pub fn findContiguousInBitmap(
    bmap: [*]const u8,
    total_bits: u32,
    count: u32,
    hint: u32,
) ?u32 {
    return bitmap.findContiguousZeros(bmap, total_bits, count, hint);
}

/// Allocate blocks from a bitmap.
/// Marks the allocated bits as used (set to 1).
/// Returns the number of blocks actually allocated (may be less than requested
/// if min_count < count and we couldn't find a full run).
///
/// Parameters:
///   bmap:       block bitmap (mutable)
///   total_bits: total bits in bitmap (blocks_per_group)
///   req:        allocation request
///   bg:         block group state
///   result:     output result
///
/// Returns true if any blocks were allocated.
pub fn allocFromBitmap(
    bmap: [*]u8,
    total_bits: u32,
    req: *const AllocRequest,
    bg: *const BlockGroupState,
    result: *AllocResult,
) bool {
    // Calculate hint within this block group
    const bg_start_block: u64 = @as(u64, bg.first_data_block) +
        @as(u64, bg.bg_number) * @as(u64, bg.blocks_per_group);
    var hint: u32 = 0;
    if (req.goal >= bg_start_block) {
        const offset = req.goal - bg_start_block;
        if (offset < total_bits) {
            hint = @truncate(offset);
        }
    }

    // Try to find the full requested count
    if (findContiguousInBitmap(bmap, total_bits, req.count, hint)) |start_bit| {
        bitmap.setRange(bmap, start_bit, req.count);
        result.start = bg_start_block + @as(u64, start_bit);
        result.count = req.count;
        result.bg = bg.bg_number;
        return true;
    }

    // If partial allocation is acceptable, try smaller runs
    if (req.min_count < req.count) {
        var try_count = req.count;
        while (try_count >= req.min_count) : (try_count /= 2) {
            if (findContiguousInBitmap(bmap, total_bits, try_count, hint)) |start_bit| {
                bitmap.setRange(bmap, start_bit, try_count);
                result.start = bg_start_block + @as(u64, start_bit);
                result.count = try_count;
                result.bg = bg.bg_number;
                return true;
            }
        }

        // Last resort: allocate minimum count
        if (req.min_count > 0) {
            if (findContiguousInBitmap(bmap, total_bits, req.min_count, hint)) |start_bit| {
                bitmap.setRange(bmap, start_bit, req.min_count);
                result.start = bg_start_block + @as(u64, start_bit);
                result.count = req.min_count;
                result.bg = bg.bg_number;
                return true;
            }
        }
    }

    return false;
}

/// Free a contiguous range of blocks in a bitmap.
/// Clears the bits and returns the count freed.
pub fn freeInBitmap(
    bmap: [*]u8,
    total_bits: u32,
    start_bit: u32,
    count: u32,
) u32 {
    var freed: u32 = 0;
    var bit = start_bit;
    while (bit < start_bit + count and bit < total_bits) : (bit += 1) {
        if (bitmap.testBit(bmap, bit)) {
            bitmap.clearBit(bmap, bit);
            freed += 1;
        }
    }
    return freed;
}

/// Compute the block group and offset for a given absolute block number.
pub fn blockToGroup(
    block: u64,
    blocks_per_group: u32,
    first_data_block: u32,
) struct { bg: u32, offset: u32 } {
    const relative = block - @as(u64, first_data_block);
    return .{
        .bg = @truncate(relative / blocks_per_group),
        .offset = @truncate(relative % blocks_per_group),
    };
}
