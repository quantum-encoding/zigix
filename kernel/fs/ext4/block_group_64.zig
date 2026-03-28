/// 64-bit block group descriptors for ext4.
///
/// ext2/ext3 use 32-byte block group descriptors. ext4 extends them to 64 bytes,
/// adding high 32 bits for all block pointers to support volumes >16TB.
///
/// The INCOMPAT_64BIT feature flag (0x0080) in the superblock indicates 64-bit mode.
/// When set, s_desc_size is 64 and both lo and hi fields are used.
///
/// Freestanding — no std, no libc.

const crc32c = @import("../common/crc32c.zig");

/// Feature flag: 64-bit block addresses.
pub const INCOMPAT_64BIT: u32 = 0x0080;

/// ext4 block group descriptor — 64 bytes.
/// First 32 bytes are identical to the ext2 Ext2BlockGroupDesc layout.
pub const BlockGroupDesc64 = extern struct {
    // Standard fields (0x00–0x1F) — same as ext2
    block_bitmap_lo: u32,        // 0x00
    inode_bitmap_lo: u32,        // 0x04
    inode_table_lo: u32,         // 0x08
    free_blocks_count_lo: u16,   // 0x0C
    free_inodes_count_lo: u16,   // 0x0E
    used_dirs_count_lo: u16,     // 0x10
    flags: u16,                  // 0x12
    exclude_bitmap_lo: u32,      // 0x14
    block_bitmap_csum_lo: u16,   // 0x18
    inode_bitmap_csum_lo: u16,   // 0x1A
    itable_unused_lo: u16,       // 0x1C
    checksum: u16,               // 0x1E: CRC16 or CRC32c lower 16 bits

    // Extended fields (0x20–0x3F) — ext4 only, present when desc_size >= 64
    block_bitmap_hi: u32,        // 0x20
    inode_bitmap_hi: u32,        // 0x24
    inode_table_hi: u32,         // 0x28
    free_blocks_count_hi: u16,   // 0x2C
    free_inodes_count_hi: u16,   // 0x2E
    used_dirs_count_hi: u16,     // 0x30
    itable_unused_hi: u16,       // 0x32
    exclude_bitmap_hi: u32,      // 0x34
    block_bitmap_csum_hi: u16,   // 0x38
    inode_bitmap_csum_hi: u16,   // 0x3A
    _reserved: u32,              // 0x3C

    /// Full 64-bit block bitmap location.
    pub fn blockBitmap(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.block_bitmap_hi) << 32) | @as(u64, self.block_bitmap_lo);
        }
        return @as(u64, self.block_bitmap_lo);
    }

    /// Full 64-bit inode bitmap location.
    pub fn inodeBitmap(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.inode_bitmap_hi) << 32) | @as(u64, self.inode_bitmap_lo);
        }
        return @as(u64, self.inode_bitmap_lo);
    }

    /// Full 64-bit inode table location.
    pub fn inodeTable(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.inode_table_hi) << 32) | @as(u64, self.inode_table_lo);
        }
        return @as(u64, self.inode_table_lo);
    }

    /// Total free blocks count (32-bit or 48-bit).
    pub fn freeBlocksCount(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.free_blocks_count_hi) << 16) | @as(u64, self.free_blocks_count_lo);
        }
        return @as(u64, self.free_blocks_count_lo);
    }

    /// Total free inodes count (32-bit or 48-bit).
    pub fn freeInodesCount(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.free_inodes_count_hi) << 16) | @as(u64, self.free_inodes_count_lo);
        }
        return @as(u64, self.free_inodes_count_lo);
    }

    /// Total used directories count.
    pub fn usedDirsCount(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.used_dirs_count_hi) << 16) | @as(u64, self.used_dirs_count_lo);
        }
        return @as(u64, self.used_dirs_count_lo);
    }

    /// Set free blocks count (splits into lo/hi).
    pub fn setFreeBlocksCount(self: *@This(), count: u64, is_64bit: bool) void {
        self.free_blocks_count_lo = @truncate(count);
        if (is_64bit) {
            self.free_blocks_count_hi = @truncate(count >> 16);
        }
    }

    /// Set free inodes count.
    pub fn setFreeInodesCount(self: *@This(), count: u64, is_64bit: bool) void {
        self.free_inodes_count_lo = @truncate(count);
        if (is_64bit) {
            self.free_inodes_count_hi = @truncate(count >> 16);
        }
    }

    /// Compute block group descriptor checksum using CRC32c.
    /// Seed: crc32c(fs_uuid) → crc32c(bg_number) → crc32c(bgd with checksum zeroed).
    /// Returns lower 16 bits.
    pub fn computeChecksum(
        self: *const @This(),
        bg_number: u32,
        fs_uuid: *const [16]u8,
        desc_size: u16,
    ) u16 {
        var crc = crc32c.seedFromUuid(fs_uuid);

        // Feed block group number (little-endian)
        const bg_le: [4]u8 = .{
            @truncate(bg_number),
            @truncate(bg_number >> 8),
            @truncate(bg_number >> 16),
            @truncate(bg_number >> 24),
        };
        crc = crc32c.update(crc, &bg_le, 4);

        // Feed descriptor contents with checksum field zeroed.
        // Checksum lives at offset 0x1E (2 bytes).
        const raw: [*]const u8 = @ptrCast(self);
        // Before checksum field (0x00–0x1D)
        crc = crc32c.update(crc, raw, 0x1E);
        // Zero bytes for the checksum field itself
        const zero2: [2]u8 = .{ 0, 0 };
        crc = crc32c.update(crc, &zero2, 2);
        // After checksum field (0x20 onwards) if 64-bit descriptor
        if (desc_size > 32) {
            crc = crc32c.update(crc, raw + 0x20, desc_size - 0x20);
        }

        return @truncate(crc32c.finalize(crc));
    }

    /// Verify stored checksum against computed.
    pub fn verifyChecksum(
        self: *const @This(),
        bg_number: u32,
        fs_uuid: *const [16]u8,
        desc_size: u16,
    ) bool {
        return self.checksum == self.computeChecksum(bg_number, fs_uuid, desc_size);
    }
};

/// Determine descriptor size from superblock fields.
pub fn descSize(s_feature_incompat: u32, s_desc_size: u16) u16 {
    if (s_feature_incompat & INCOMPAT_64BIT != 0 and s_desc_size >= 64) {
        return s_desc_size;
    }
    return 32;
}

/// Check if filesystem uses 64-bit mode.
pub fn is64Bit(s_feature_incompat: u32) bool {
    return s_feature_incompat & INCOMPAT_64BIT != 0;
}

/// Read a block group descriptor from a raw block buffer.
/// Handles both 32-byte and 64-byte descriptors.
pub fn readDescriptor(
    block_data: [*]const u8,
    bg_index_in_block: u32,
    desc_sz: u16,
) *const BlockGroupDesc64 {
    const offset = @as(usize, bg_index_in_block) * @as(usize, desc_sz);
    return @ptrCast(@alignCast(block_data + offset));
}
