/// Delayed allocation (delalloc) for ext4.
///
/// Postpones block allocation until data is flushed to disk (at fsync or
/// writeback time). This lets the multiblock allocator see the full write
/// size and allocate contiguous blocks, reducing fragmentation.
///
/// Without delalloc:  write() → allocate blocks immediately → may fragment
/// With delalloc:     write() → reserve blocks → fsync() → allocate contiguously
///
/// Freestanding — no std, no libc.

/// Maximum dirty ranges tracked per inode.
pub const MAX_DIRTY_RANGES: usize = 16;

/// A dirty data range — logically allocated but not yet physically mapped.
pub const DirtyRange = struct {
    /// Starting logical block number.
    logical_start: u32 = 0,
    /// Number of blocks in this range.
    count: u32 = 0,
    /// Whether this range is in use.
    valid: bool = false,
};

/// Per-inode delayed allocation state.
pub const DelayedState = struct {
    /// Number of blocks reserved but not yet allocated.
    reserved_blocks: u32 = 0,
    /// Dirty data ranges (logical block start + count).
    dirty_ranges: [MAX_DIRTY_RANGES]DirtyRange = [_]DirtyRange{.{}} ** MAX_DIRTY_RANGES,
    /// Number of active dirty ranges.
    dirty_count: u32 = 0,
    /// Whether delalloc is active for this inode.
    active: bool = false,

    /// Reserve blocks without allocating.
    /// Called from write() syscall when delalloc is enabled.
    ///
    /// Parameters:
    ///   logical_start: first logical block of the write
    ///   count:         number of blocks to reserve
    ///   global_free:   pointer to global free block counter (decremented)
    ///
    /// Returns true if reservation succeeded.
    pub fn reserve(
        self: *DelayedState,
        logical_start: u32,
        count: u32,
        global_free: *u64,
    ) bool {
        // Check enough free blocks exist
        if (global_free.* < count) return false;

        // Try to merge with existing dirty range
        for (&self.dirty_ranges) |*r| {
            if (!r.valid) continue;

            // Extend at end
            if (r.logical_start + r.count == logical_start) {
                r.count += count;
                self.reserved_blocks += count;
                global_free.* -= count;
                return true;
            }

            // Extend at start
            if (logical_start + count == r.logical_start) {
                r.logical_start = logical_start;
                r.count += count;
                self.reserved_blocks += count;
                global_free.* -= count;
                return true;
            }

            // Overlap — already reserved (adjust count)
            if (logical_start >= r.logical_start and
                logical_start < r.logical_start + r.count)
            {
                const overlap_end = r.logical_start + r.count;
                const write_end = logical_start + count;
                if (write_end > overlap_end) {
                    const extra = write_end - overlap_end;
                    r.count += extra;
                    self.reserved_blocks += extra;
                    global_free.* -= extra;
                }
                return true;
            }
        }

        // No merge — add new dirty range
        if (self.dirty_count >= MAX_DIRTY_RANGES) return false;

        for (&self.dirty_ranges) |*r| {
            if (!r.valid) {
                r.* = .{
                    .logical_start = logical_start,
                    .count = count,
                    .valid = true,
                };
                self.dirty_count += 1;
                self.reserved_blocks += count;
                global_free.* -= count;
                return true;
            }
        }

        return false;
    }

    /// Get total number of dirty blocks across all ranges.
    pub fn totalDirtyBlocks(self: *const DelayedState) u32 {
        var total: u32 = 0;
        for (&self.dirty_ranges) |*r| {
            if (r.valid) total += r.count;
        }
        return total;
    }

    /// Cancel delayed allocation (for truncate/delete).
    /// Releases reserved blocks back to global counter.
    pub fn cancel(self: *DelayedState, from_logical: u32, global_free: *u64) void {
        for (&self.dirty_ranges) |*r| {
            if (!r.valid) continue;

            if (r.logical_start >= from_logical) {
                // Entire range is past truncation point — cancel it
                global_free.* += r.count;
                self.reserved_blocks -= @min(self.reserved_blocks, r.count);
                r.valid = false;
                self.dirty_count -= @min(self.dirty_count, 1);
            } else if (r.logical_start + r.count > from_logical) {
                // Partial overlap — shrink range
                const keep = from_logical - r.logical_start;
                const release = r.count - keep;
                r.count = keep;
                global_free.* += release;
                self.reserved_blocks -= @min(self.reserved_blocks, release);
            }
        }
    }

    /// Clear a specific dirty range after successful flush.
    pub fn clearRange(self: *DelayedState, logical_start: u32, count: u32) void {
        for (&self.dirty_ranges) |*r| {
            if (!r.valid) continue;

            if (r.logical_start == logical_start and r.count == count) {
                r.valid = false;
                self.dirty_count -= @min(self.dirty_count, 1);
                self.reserved_blocks -= @min(self.reserved_blocks, count);
                return;
            }
        }
    }

    /// Reset all delayed state.
    pub fn reset(self: *DelayedState, global_free: *u64) void {
        global_free.* += self.reserved_blocks;
        self.* = .{};
    }
};
