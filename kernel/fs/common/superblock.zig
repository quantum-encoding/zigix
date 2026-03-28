/// Unified superblock parser — handles ext2, ext3, and ext4.
///
/// The ext2/3/4 superblock format is backward compatible: ext4 extends ext2
/// without changing existing field positions. This parser reads from raw bytes
/// and determines the filesystem type from feature flags.
///
/// Superblock lives at byte offset 1024 on disk (in block 0 for block_size >= 2048,
/// or in block 1 for block_size == 1024).
///
/// Freestanding — no std, no libc.

/// ext2/3/4 superblock magic number.
pub const EXT_SUPER_MAGIC: u16 = 0xEF53;

/// Filesystem type detected from feature flags.
pub const FsType = enum(u8) {
    ext2 = 2,
    ext3 = 3,
    ext4 = 4,
};

// ── Feature flags ──────────────────────────────────────────────────────

pub const COMPAT_HAS_JOURNAL: u32 = 0x0004;
pub const COMPAT_DIR_PREALLOC: u32 = 0x0020;

pub const INCOMPAT_FILETYPE: u32 = 0x0002;
pub const INCOMPAT_RECOVER: u32 = 0x0004;
pub const INCOMPAT_JOURNAL_DEV: u32 = 0x0008;
pub const INCOMPAT_EXTENTS: u32 = 0x0040;
pub const INCOMPAT_64BIT: u32 = 0x0080;
pub const INCOMPAT_FLEX_BG: u32 = 0x0200;

pub const RO_COMPAT_SPARSE_SUPER: u32 = 0x0001;
pub const RO_COMPAT_LARGE_FILE: u32 = 0x0002;
pub const RO_COMPAT_HUGE_FILE: u32 = 0x0008;
pub const RO_COMPAT_GDT_CSUM: u32 = 0x0010;
pub const RO_COMPAT_EXTRA_ISIZE: u32 = 0x0040;
pub const RO_COMPAT_METADATA_CSUM: u32 = 0x0400;

// ── Field offsets within the 1024-byte superblock ──────────────────────

pub const OFF_INODES_COUNT: usize = 0x00;
pub const OFF_BLOCKS_COUNT_LO: usize = 0x04;
pub const OFF_R_BLOCKS_COUNT: usize = 0x08;
pub const OFF_FREE_BLOCKS_LO: usize = 0x0C;
pub const OFF_FREE_INODES: usize = 0x10;
pub const OFF_FIRST_DATA_BLOCK: usize = 0x14;
pub const OFF_LOG_BLOCK_SIZE: usize = 0x18;
pub const OFF_BLOCKS_PER_GROUP: usize = 0x20;
pub const OFF_INODES_PER_GROUP: usize = 0x28;
pub const OFF_MAGIC: usize = 0x38;
pub const OFF_STATE: usize = 0x3A;
pub const OFF_REV_LEVEL: usize = 0x4C;
pub const OFF_FIRST_INO: usize = 0x54;
pub const OFF_INODE_SIZE: usize = 0x58;
pub const OFF_FEATURE_COMPAT: usize = 0x5C;
pub const OFF_FEATURE_INCOMPAT: usize = 0x60;
pub const OFF_FEATURE_RO_COMPAT: usize = 0x64;
pub const OFF_UUID: usize = 0x68;
pub const OFF_JOURNAL_INUM: usize = 0xE0;
pub const OFF_JOURNAL_UUID: usize = 0xD0;
pub const OFF_HASH_SEED: usize = 0xEC;
pub const OFF_DEF_HASH_VERSION: usize = 0xFC;
pub const OFF_DESC_SIZE: usize = 0xFE;
pub const OFF_MIN_EXTRA_ISIZE: usize = 0x104;
pub const OFF_WANT_EXTRA_ISIZE: usize = 0x108;
pub const OFF_BLOCKS_COUNT_HI: usize = 0x150;
pub const OFF_FREE_BLOCKS_HI: usize = 0x158;
pub const OFF_LOG_GROUPS_PER_FLEX: usize = 0x174;

/// Parsed superblock information.
pub const SuperblockInfo = struct {
    fs_type: FsType,
    magic: u16,
    uuid: [16]u8,

    // Geometry
    block_size: u32,
    blocks_count: u64,
    inodes_count: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    inode_size: u16,
    desc_size: u16,
    block_group_count: u32,
    first_data_block: u32,

    // Free space
    free_blocks: u64,
    free_inodes: u32,

    // Features
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,

    // Journal (ext3+)
    has_journal: bool,
    journal_inum: u32,

    // ext4 specific
    has_extents: bool,
    is_64bit: bool,
    has_flex_bg: bool,
    has_metadata_csum: bool,
    log_groups_per_flex: u8,
    hash_seed: [4]u32,
    default_hash_version: u8,
};

// ── Helpers for reading little-endian fields from raw bytes ────────────

fn readU16(raw: [*]const u8, offset: usize) u16 {
    return @as(u16, raw[offset]) | (@as(u16, raw[offset + 1]) << 8);
}

fn readU32(raw: [*]const u8, offset: usize) u32 {
    return @as(u32, raw[offset]) |
        (@as(u32, raw[offset + 1]) << 8) |
        (@as(u32, raw[offset + 2]) << 16) |
        (@as(u32, raw[offset + 3]) << 24);
}

fn readU8(raw: [*]const u8, offset: usize) u8 {
    return raw[offset];
}

/// Parse superblock from raw 1024 bytes.
/// Returns null if magic doesn't match.
pub fn parse(raw: [*]const u8) ?SuperblockInfo {
    const magic = readU16(raw, OFF_MAGIC);
    if (magic != EXT_SUPER_MAGIC) return null;

    const feature_compat = readU32(raw, OFF_FEATURE_COMPAT);
    const feature_incompat = readU32(raw, OFF_FEATURE_INCOMPAT);
    const feature_ro_compat = readU32(raw, OFF_FEATURE_RO_COMPAT);

    // Geometry
    const log_block_size = readU32(raw, OFF_LOG_BLOCK_SIZE);
    const block_size: u32 = @as(u32, 1024) << @as(u5, @truncate(log_block_size));
    const blocks_per_group = readU32(raw, OFF_BLOCKS_PER_GROUP);
    const inodes_count = readU32(raw, OFF_INODES_COUNT);
    const inodes_per_group = readU32(raw, OFF_INODES_PER_GROUP);

    // Blocks count: combine lo + hi if 64-bit
    var blocks_count: u64 = readU32(raw, OFF_BLOCKS_COUNT_LO);
    if (feature_incompat & INCOMPAT_64BIT != 0) {
        blocks_count |= @as(u64, readU32(raw, OFF_BLOCKS_COUNT_HI)) << 32;
    }

    // Free blocks
    var free_blocks: u64 = readU32(raw, OFF_FREE_BLOCKS_LO);
    if (feature_incompat & INCOMPAT_64BIT != 0) {
        free_blocks |= @as(u64, readU32(raw, OFF_FREE_BLOCKS_HI)) << 32;
    }

    // Inode size (128 default for rev 0, otherwise from field)
    const rev_level = readU32(raw, OFF_REV_LEVEL);
    const inode_size: u16 = if (rev_level >= 1) readU16(raw, OFF_INODE_SIZE) else 128;

    // Descriptor size
    const raw_desc_size = readU16(raw, OFF_DESC_SIZE);
    const desc_size: u16 = if (feature_incompat & INCOMPAT_64BIT != 0 and raw_desc_size >= 64)
        raw_desc_size
    else
        32;

    // Block group count
    const bg_count = if (blocks_per_group > 0)
        @as(u32, @truncate((blocks_count + blocks_per_group - 1) / blocks_per_group))
    else
        0;

    // UUID
    var uuid: [16]u8 = undefined;
    for (0..16) |i| {
        uuid[i] = raw[OFF_UUID + i];
    }

    // Feature detection
    const has_journal = feature_compat & COMPAT_HAS_JOURNAL != 0;
    const has_extents = feature_incompat & INCOMPAT_EXTENTS != 0;
    const is_64bit = feature_incompat & INCOMPAT_64BIT != 0;
    const has_flex_bg = feature_incompat & INCOMPAT_FLEX_BG != 0;
    const has_metadata_csum = feature_ro_compat & RO_COMPAT_METADATA_CSUM != 0;

    // Determine filesystem type
    const fs_type: FsType = if (has_extents or is_64bit or has_flex_bg or has_metadata_csum)
        .ext4
    else if (has_journal)
        .ext3
    else
        .ext2;

    // Hash seed (for HTree directories)
    var hash_seed: [4]u32 = undefined;
    for (0..4) |i| {
        hash_seed[i] = readU32(raw, OFF_HASH_SEED + i * 4);
    }

    return .{
        .fs_type = fs_type,
        .magic = magic,
        .uuid = uuid,
        .block_size = block_size,
        .blocks_count = blocks_count,
        .inodes_count = inodes_count,
        .blocks_per_group = blocks_per_group,
        .inodes_per_group = inodes_per_group,
        .inode_size = inode_size,
        .desc_size = desc_size,
        .block_group_count = bg_count,
        .first_data_block = readU32(raw, OFF_FIRST_DATA_BLOCK),
        .free_blocks = free_blocks,
        .free_inodes = readU32(raw, OFF_FREE_INODES),
        .feature_compat = feature_compat,
        .feature_incompat = feature_incompat,
        .feature_ro_compat = feature_ro_compat,
        .has_journal = has_journal,
        .journal_inum = readU32(raw, OFF_JOURNAL_INUM),
        .has_extents = has_extents,
        .is_64bit = is_64bit,
        .has_flex_bg = has_flex_bg,
        .has_metadata_csum = has_metadata_csum,
        .log_groups_per_flex = readU8(raw, OFF_LOG_GROUPS_PER_FLEX),
        .hash_seed = hash_seed,
        .default_hash_version = readU8(raw, OFF_DEF_HASH_VERSION),
    };
}
