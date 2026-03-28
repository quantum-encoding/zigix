# Common Filesystem Utilities

## Context

Shared code used by ext2, ext3, and ext4 implementations. These are standalone, pure-function modules with no kernel dependencies beyond basic types.

All code is freestanding Zig. No std, no libc.

## Files You Create

```
common/
├── crc32c.zig       ← §E1: CRC32c checksum implementation
├── superblock.zig   ← Unified superblock parsing (all ext versions)
└── bitmap.zig       ← Block/inode bitmap operations
```

---

## §E1: CRC32c Checksum Implementation

**File:** `crc32c.zig`  
**Lines:** ~150  
**Dependencies:** None (pure function, no kernel deps)

### What to implement

CRC32c (Castagnoli polynomial) is used throughout ext4 for metadata integrity: block group descriptor checksums, inode checksums, extent tree checksums, directory block checksums, and journal V3 checksums.

**Polynomial:** 0x1EDC6F41 (Castagnoli), NOT the standard CRC32 polynomial 0x04C11DB7.

```zig
/// CRC32c lookup table — generated at comptime
/// Using the Castagnoli polynomial (0x1EDC6F41)
const crc32c_table: [256]u32 = comptime blk: {
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ 0x82F63B78; // Reflected polynomial
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Compute CRC32c of data
/// Initial CRC should be 0xFFFFFFFF for first call
/// For incremental: pass previous result as crc parameter
pub fn crc32c(crc: u32, data: []const u8) u32 {
    var c = crc;
    for (data) |byte| {
        c = crc32c_table[@as(u8, @truncate(c)) ^ byte] ^ (c >> 8);
    }
    return c;
}

/// Finalize CRC32c (XOR with 0xFFFFFFFF)
pub fn finalize(crc: u32) u32 {
    return crc ^ 0xFFFFFFFF;
}

/// Convenience: compute CRC32c of data in one call
pub fn compute(data: []const u8) u32 {
    return finalize(crc32c(0xFFFFFFFF, data));
}

/// Compute CRC32c with a seed derived from filesystem UUID
/// Used for ext4 metadata checksums
pub fn computeWithSeed(seed: u32, data: []const u8) u32 {
    return crc32c(seed, data);
}

/// Compute seed from filesystem UUID
/// seed = crc32c(~0, uuid[0..16])
pub fn seedFromUuid(uuid: [16]u8) u32 {
    return crc32c(0xFFFFFFFF, &uuid);
}
```

### IETF Test Vectors

Your implementation MUST pass these:

```
CRC32c("") = 0x00000000
CRC32c("123456789") = 0xE3069283
CRC32c(32 bytes of zeros) = 0xAA36918A
CRC32c(32 bytes of 0xFF) = 0x43ABA862
```

The reflected polynomial 0x82F63B78 is used (not the unreflected 0x1EDC6F41) because CRC32c processes bits LSB-first.

### Optional: SIMD Acceleration

On x86_64 with SSE4.2, the `crc32` instruction computes CRC32c in hardware. On ARM64, the CRC extension provides similar instructions. These can be added later for performance but are not required — the table-based implementation is fast enough for metadata checksums.

```zig
// Future: hardware CRC32c
// x86_64: asm volatile ("crc32b %1, %0" : "+r" (crc) : "rm" (byte));
// ARM64: asm volatile ("crc32cb %w0, %w0, %w1" : "+r" (crc) : "r" (byte));
```

### Verification

1. Compile standalone: `zig build-obj common/crc32c.zig`
2. Run test vectors: all 4 IETF vectors must match
3. Cross-check: compute CRC32c of a real ext4 block group descriptor, compare against Linux's stored checksum

---

## Superblock Parsing (unified)

**File:** `superblock.zig`  
**Lines:** ~200  
**Dependencies:** None

This is a unified superblock parser that handles ext2, ext3, and ext4 superblocks. The superblock format is backward compatible — ext4 extends ext2 without changing existing fields.

```zig
/// Filesystem type detected from superblock
pub const FsType = enum {
    ext2,    // No journal, no extents
    ext3,    // Has journal, no extents
    ext4,    // Has extents and/or 64-bit and/or other ext4 features
};

/// Key superblock fields used across all ext versions
pub const SuperblockInfo = struct {
    // Identification
    fs_type: FsType,
    magic: u16,                  // Must be 0xEF53
    uuid: [16]u8,                // Filesystem UUID

    // Geometry
    block_size: u32,             // Computed from s_log_block_size
    blocks_count: u64,           // Total blocks (64-bit for ext4)
    inodes_count: u32,           // Total inodes
    blocks_per_group: u32,
    inodes_per_group: u32,
    inode_size: u16,             // 128 or 256
    desc_size: u16,              // 32 or 64
    block_group_count: u32,      // Computed

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
    journal_uuid: [16]u8,

    // ext4 specific
    has_extents: bool,
    is_64bit: bool,
    has_flex_bg: bool,
    has_metadata_csum: bool,
    log_groups_per_flex: u8,
    hash_seed: [4]u32,           // For HTree
    default_hash_version: u8,

    // Timestamps
    mount_time: u32,
    write_time: u32,
    last_check: u32,
};

/// Parse superblock from raw bytes (1024 bytes starting at disk offset 1024)
pub fn parse(raw: *const [1024]u8) !SuperblockInfo {
    // Read magic at offset 0x38 — must be 0xEF53
    // Read all fields from known offsets
    // Determine FsType from feature flags
    // Compute derived fields (block_size, block_group_count, etc.)
}

/// Key offsets in the superblock (for reference)
pub const Offsets = struct {
    pub const inodes_count = 0x00;        // u32
    pub const blocks_count_lo = 0x04;     // u32
    pub const free_blocks_count_lo = 0x0C;// u32
    pub const free_inodes_count = 0x10;   // u32
    pub const log_block_size = 0x18;      // u32 (block_size = 1024 << this)
    pub const blocks_per_group = 0x20;    // u32
    pub const inodes_per_group = 0x28;    // u32
    pub const magic = 0x38;               // u16 (must be 0xEF53)
    pub const state = 0x3A;               // u16 (1=clean, 2=has_errors)
    pub const inode_size = 0x58;          // u16
    pub const feature_compat = 0x5C;      // u32
    pub const feature_incompat = 0x60;    // u32
    pub const feature_ro_compat = 0x64;   // u32
    pub const uuid = 0x68;                // [16]u8
    pub const journal_inum = 0xE0;        // u32
    pub const desc_size = 0xFE;           // u16 (ext4)
    pub const blocks_count_hi = 0x150;    // u32 (ext4 64-bit)
    pub const hash_seed = 0xEC;           // [4]u32 (ext4 HTree)
    pub const def_hash_version = 0xFC;    // u8
    pub const log_groups_per_flex = 0x174;// u8
};
```

---

## Bitmap Operations

**File:** `bitmap.zig`  
**Lines:** ~100  
**Dependencies:** None

Shared bitmap manipulation used by block and inode allocators.

```zig
/// Test if bit N is set
pub fn testBit(bitmap: [*]const u8, bit: u32) bool {
    return bitmap[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0;
}

/// Set bit N
pub fn setBit(bitmap: [*]u8, bit: u32) void {
    bitmap[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
}

/// Clear bit N
pub fn clearBit(bitmap: [*]u8, bit: u32) void {
    bitmap[bit / 8] &= ~(@as(u8, 1) << @intCast(bit % 8));
}

/// Find first zero bit starting from hint
pub fn findFirstZero(bitmap: [*]const u8, total_bits: u32, hint: u32) ?u32 {
    // Start from hint, wrap around
    // Process 64 bits at a time for speed
}

/// Find N contiguous zero bits starting from hint
pub fn findContiguousZeros(
    bitmap: [*]const u8,
    total_bits: u32,
    count: u32,
    hint: u32,
) ?u32 {
    // Scan for run of count consecutive zeros
    // Used by mballoc
}

/// Count total zero bits in bitmap
pub fn countZeros(bitmap: [*]const u8, total_bits: u32) u32 {
    // Use @popCount on u64 chunks for speed
}

/// Set range of bits [start, start+count)
pub fn setRange(bitmap: [*]u8, start: u32, count: u32) void {
    for (start..start + count) |bit| {
        setBit(bitmap, @intCast(bit));
    }
}

/// Clear range of bits [start, start+count)
pub fn clearRange(bitmap: [*]u8, start: u32, count: u32) void {
    for (start..start + count) |bit| {
        clearBit(bitmap, @intCast(bit));
    }
}
```
