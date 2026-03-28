/// Flexible block groups (flex_bg) for ext4.
///
/// Packs metadata (bitmaps + inode tables) of multiple block groups into
/// the first block group of a "flex group." Improves I/O locality.
///
/// Controlled by INCOMPAT_FLEX_BG (0x0200) and s_log_groups_per_flex.
///
/// Freestanding — no std, no libc.

/// Feature flag for flexible block groups.
pub const INCOMPAT_FLEX_BG: u32 = 0x0200;

/// Flex group configuration — derived from superblock at mount time.
pub const FlexGroupConfig = struct {
    /// Whether flex_bg is enabled.
    enabled: bool = false,
    /// Number of block groups per flex group (power of 2).
    groups_per_flex: u32 = 1,

    /// Initialize from superblock fields.
    pub fn fromSuperblock(s_feature_incompat: u32, s_log_groups_per_flex: u8) FlexGroupConfig {
        if (s_feature_incompat & INCOMPAT_FLEX_BG == 0 or s_log_groups_per_flex == 0) {
            return .{ .enabled = false, .groups_per_flex = 1 };
        }
        return .{
            .enabled = true,
            .groups_per_flex = @as(u32, 1) << @as(u5, @truncate(s_log_groups_per_flex)),
        };
    }

    /// Get the flex group number for a given block group.
    pub fn flexGroup(self: *const FlexGroupConfig, bg_number: u32) u32 {
        return bg_number / self.groups_per_flex;
    }

    /// Get the first block group in the same flex group.
    pub fn flexGroupStart(self: *const FlexGroupConfig, bg_number: u32) u32 {
        return self.flexGroup(bg_number) * self.groups_per_flex;
    }

    /// Check if this block group is the flex group leader.
    pub fn isFlexLeader(self: *const FlexGroupConfig, bg_number: u32) bool {
        return bg_number % self.groups_per_flex == 0;
    }

    /// Get the last block group in the same flex group (clamped to total_bg).
    pub fn flexGroupEnd(self: *const FlexGroupConfig, bg_number: u32, total_bg: u32) u32 {
        const end = self.flexGroupStart(bg_number) + self.groups_per_flex;
        return if (end > total_bg) total_bg else end;
    }
};

/// Find a preferred block group for allocation within the same flex group.
/// Prefers block groups with the most free blocks for better contiguity.
///
/// Parameters:
///   flex:       flex group config
///   current_bg: block group hint (e.g. from file's inode group)
///   total_bg:   total number of block groups
///   free_counts: per-BG free block counts (pointer to array)
///
/// Returns: recommended block group index for allocation.
pub fn preferredBlockGroup(
    flex: *const FlexGroupConfig,
    current_bg: u32,
    total_bg: u32,
    free_counts: [*]const u32,
) u32 {
    if (!flex.enabled) return current_bg;

    const start = flex.flexGroupStart(current_bg);
    const end = flex.flexGroupEnd(current_bg, total_bg);

    var best_bg: u32 = current_bg;
    var best_free: u32 = 0;

    var bg: u32 = start;
    while (bg < end) : (bg += 1) {
        if (free_counts[bg] > best_free) {
            best_free = free_counts[bg];
            best_bg = bg;
        }
    }

    // Fall back to any BG with free blocks if flex group is full
    if (best_free == 0) {
        bg = 0;
        while (bg < total_bg) : (bg += 1) {
            if (free_counts[bg] > best_free) {
                best_free = free_counts[bg];
                best_bg = bg;
            }
        }
    }

    return best_bg;
}
