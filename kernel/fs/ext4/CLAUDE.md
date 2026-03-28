# ext4 Feature Implementation

## Context

You are implementing ext4 features for the Zigix OS kernel. The existing ext2 filesystem is at `zigix/kernel/fs/ext2.zig`. ext3 journaling has already been added (see `ext3/` folder). Your job is to add ext4-specific features that bring the filesystem to Linux parity.

All code is freestanding Zig. No std, no libc. The kernel provides `blockRead()`/`blockWrite()` for disk I/O.

## Files You Create

```
ext4/
├── inode_ext4.zig       ← §E2: 256-byte inode with nanosecond timestamps
├── block_group_64.zig   ← §E3: 64-bit block group descriptors  
├── flex_bg.zig          ← §E4: Flexible block groups
├── mballoc.zig          ← §E5: Multiblock allocator
├── delayed_alloc.zig    ← §E6: Delayed allocation
├── extents.zig          ← §X1: Extent tree (B-tree block mapping)
└── htree.zig            ← §X2: HTree indexed directories
```

---

## §E2: 256-Byte Extended Inodes

**File:** `inode_ext4.zig`  
**Lines:** ~200  
**Dependencies:** E1 (CRC32c from common/crc32c.zig)

### What to implement

ext4 inodes are 256 bytes (vs 128 for ext2/ext3). The extra 128 bytes hold nanosecond timestamps, creation time, and a checksum.

```zig
const crc32c = @import("../common/crc32c.zig");

/// Extended inode fields (bytes 0x80-0xFF of a 256-byte inode)
pub const InodeExtra = extern struct {
    extra_isize: u16,     // 0x80: Actual size of extra fields used
    checksum_hi: u16,     // 0x82: High 16 bits of inode checksum
    ctime_extra: u32,     // 0x84: Extra ctime (nanoseconds + epoch extension)
    mtime_extra: u32,     // 0x88: Extra mtime
    atime_extra: u32,     // 0x8C: Extra atime
    crtime: u32,          // 0x90: Creation time (seconds since epoch)
    crtime_extra: u32,    // 0x94: Creation time nanoseconds
    version_hi: u32,      // 0x98: High 32 bits of inode version
    projid: u32,          // 0x9C: Project ID
    _reserved: [96]u8,    // 0xA0-0xFF: Padding
};

/// Decode nanosecond timestamp from extra field
/// Format: [epoch_bits(2)][nanoseconds(30)]
/// epoch_bits extends the 32-bit seconds past 2038:
///   0 = 1901-2038, 1 = 2038-2174, 2 = 2174-2310, 3 = 2310-2446
pub fn decodeTimestamp(seconds: u32, extra: u32) Timestamp {
    return .{
        .seconds = @as(u64, seconds) + (@as(u64, extra >> 30) * (1 << 32)),
        .nanoseconds = extra & 0x3FFFFFFF,
    };
}

pub fn encodeTimestampExtra(nanoseconds: u32, epoch_bits: u2) u32 {
    return (@as(u32, epoch_bits) << 30) | (nanoseconds & 0x3FFFFFFF);
}

pub const Timestamp = struct {
    seconds: u64,
    nanoseconds: u32,
};

/// Read extended inode fields
/// inode_buf: pointer to the full 256-byte inode on disk
/// Returns null if inode is only 128 bytes
pub fn readExtra(inode_buf: [*]const u8, inode_size: u16) ?*const InodeExtra {
    if (inode_size < 256) return null;
    return @ptrCast(@alignCast(inode_buf + 128));
}

/// Compute inode checksum (CRC32c)
/// Seed: CRC32c(fs_uuid) XOR inode_number
/// Data: entire inode with checksum fields zeroed
pub fn computeChecksum(
    inode_buf: [*]const u8,
    inode_size: u16,
    inode_number: u32,
    fs_uuid: [16]u8,
) u32 {
    // 1. Compute seed = crc32c(0xFFFFFFFF, fs_uuid)
    // 2. Seed = crc32c(seed, &inode_number_le_bytes)
    // 3. Seed = crc32c(seed, &generation_le_bytes) — from offset 0x64 in inode
    // 4. Zero the checksum fields in a copy: offset 0x7C (lo) and 0x82 (hi)
    // 5. Return crc32c(seed, inode_copy[0..inode_size])
}

/// Verify inode checksum
pub fn verifyChecksum(
    inode_buf: [*]const u8,
    inode_size: u16,
    inode_number: u32,
    fs_uuid: [16]u8,
) bool {
    const stored_lo: u16 = // read from offset 0x7C
    const stored_hi: u16 = if (inode_size >= 256)
        // read from offset 0x82
    else 0;
    const stored = (@as(u32, stored_hi) << 16) | @as(u32, stored_lo);
    const computed = computeChecksum(inode_buf, inode_size, inode_number, fs_uuid);
    return stored == computed;
}
```

### Superblock fields:
```
s_inode_size (offset 0x58): 128 or 256
s_want_extra_isize (offset 0x108): minimum extra inode size
s_min_extra_isize (offset 0x104): guaranteed extra inode size
```

### Integration:
- On inode read: check `s_inode_size`. If 256, parse extra fields.
- On inode write: if ext4, compute and store checksum.
- Backward compatible: 128-byte inodes work unchanged.

---

## §E3: 64-Bit Block Group Descriptors

**File:** `block_group_64.zig`  
**Lines:** ~150  
**Dependencies:** None (but E1 useful for checksum)

### What to implement

ext4 extends block group descriptors from 32 bytes to 64 bytes, adding high 32 bits for all block pointers. This supports volumes >16TB.

```zig
/// ext4 extended block group descriptor (64 bytes total)
/// First 32 bytes identical to ext2/ext3
pub const BlockGroupDesc64 = extern struct {
    // Standard fields (0x00-0x1F) — same as ext2
    block_bitmap_lo: u32,       // 0x00
    inode_bitmap_lo: u32,       // 0x04
    inode_table_lo: u32,        // 0x08
    free_blocks_count_lo: u16,  // 0x0C
    free_inodes_count_lo: u16,  // 0x0E
    used_dirs_count_lo: u16,    // 0x10
    flags: u16,                 // 0x12
    exclude_bitmap_lo: u32,     // 0x14
    block_bitmap_csum_lo: u16,  // 0x18
    inode_bitmap_csum_lo: u16,  // 0x1A
    itable_unused_lo: u16,      // 0x1C
    checksum: u16,              // 0x1E

    // Extended fields (0x20-0x3F) — ext4 only
    block_bitmap_hi: u32,       // 0x20
    inode_bitmap_hi: u32,       // 0x24
    inode_table_hi: u32,        // 0x28
    free_blocks_count_hi: u16,  // 0x2C
    free_inodes_count_hi: u16,  // 0x2E
    used_dirs_count_hi: u16,    // 0x30
    itable_unused_hi: u16,      // 0x32
    exclude_bitmap_hi: u32,     // 0x34
    block_bitmap_csum_hi: u16,  // 0x38
    inode_bitmap_csum_hi: u16,  // 0x3A
    _reserved: u32,             // 0x3C

    /// Get full 64-bit block bitmap location
    pub fn blockBitmap(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.block_bitmap_hi) << 32) | @as(u64, self.block_bitmap_lo);
        }
        return @as(u64, self.block_bitmap_lo);
    }

    /// Get full 64-bit inode bitmap location
    pub fn inodeBitmap(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.inode_bitmap_hi) << 32) | @as(u64, self.inode_bitmap_lo);
        }
        return @as(u64, self.inode_bitmap_lo);
    }

    /// Get full 64-bit inode table location
    pub fn inodeTable(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.inode_table_hi) << 32) | @as(u64, self.inode_table_lo);
        }
        return @as(u64, self.inode_table_lo);
    }

    /// Get total free blocks count
    pub fn freeBlocksCount(self: *const @This(), is_64bit: bool) u64 {
        if (is_64bit) {
            return (@as(u64, self.free_blocks_count_hi) << 16) | @as(u64, self.free_blocks_count_lo);
        }
        return @as(u64, self.free_blocks_count_lo);
    }

    /// Compute BGD checksum
    pub fn computeChecksum(
        self: *const @This(),
        bg_number: u32,
        fs_uuid: [16]u8,
        desc_size: u16,
    ) u16 {
        // CRC32c(fs_uuid, bg_number, bgd_with_checksum_zeroed)
        // Return lower 16 bits
    }
};

/// Determine descriptor size from superblock
pub fn descSize(s_feature_incompat: u32, s_desc_size: u16) u16 {
    const INCOMPAT_64BIT: u32 = 0x0080;
    if (s_feature_incompat & INCOMPAT_64BIT != 0 and s_desc_size >= 64) {
        return s_desc_size; // Usually 64
    }
    return 32; // Standard ext2/ext3 size
}

/// Check if filesystem uses 64-bit mode
pub fn is64Bit(s_feature_incompat: u32) bool {
    return s_feature_incompat & 0x0080 != 0;
}
```

### Integration:
- On mount: check `s_feature_incompat & INCOMPAT_64BIT`
- If set: use 64-byte descriptors, combine hi+lo fields
- If not: use 32-byte descriptors, existing code path (unchanged)

---

## §E4: Flexible Block Groups

**File:** `flex_bg.zig`  
**Lines:** ~150  
**Dependencies:** None

### What to implement

Flex_bg packs metadata (bitmaps + inode tables) of several block groups into the first group of a "flex group." This improves I/O locality.

```zig
/// Flex group configuration
pub const FlexGroupConfig = struct {
    enabled: bool,
    groups_per_flex: u32,  // Power of 2, from s_log_groups_per_flex

    pub fn fromSuperblock(s_feature_incompat: u32, s_log_groups_per_flex: u8) @This() {
        const INCOMPAT_FLEX_BG: u32 = 0x0200;
        if (s_feature_incompat & INCOMPAT_FLEX_BG == 0 or s_log_groups_per_flex == 0) {
            return .{ .enabled = false, .groups_per_flex = 1 };
        }
        return .{
            .enabled = true,
            .groups_per_flex = @as(u32, 1) << @intCast(s_log_groups_per_flex),
        };
    }

    /// Get flex group number for a given block group
    pub fn flexGroup(self: *const @This(), bg_number: u32) u32 {
        return bg_number / self.groups_per_flex;
    }

    /// Get the first block group in this flex group
    pub fn flexGroupStart(self: *const @This(), bg_number: u32) u32 {
        return self.flexGroup(bg_number) * self.groups_per_flex;
    }

    /// Check if this block group is the flex group leader
    pub fn isFlexLeader(self: *const @This(), bg_number: u32) bool {
        return bg_number % self.groups_per_flex == 0;
    }
};

/// With flex_bg, you DON'T compute bitmap/inode table positions from block group number.
/// Instead, you ALWAYS read them from the block group descriptor.
/// The descriptors already point to the right physical blocks.
/// 
/// This means: if your ext2 code reads bitmap positions from BGD (not computed),
/// flex_bg works automatically. If it computes positions, it needs to be changed.
///
/// The main change is in ALLOCATION: when allocating blocks or inodes,
/// prefer block groups within the same flex group for better locality.
pub fn preferredBlockGroup(
    flex: *const FlexGroupConfig,
    current_bg: u32,
    total_bg: u32,
    // ... free block counts per BG
) u32 {
    if (!flex.enabled) return current_bg;
    
    // Prefer allocating within the same flex group
    const start = flex.flexGroupStart(current_bg);
    const end = @min(start + flex.groups_per_flex, total_bg);
    
    // Find BG with most free blocks within flex group
    // Fall back to any BG if flex group is full
    _ = start;
    _ = end;
    return current_bg; // Placeholder
}
```

### Key insight:
If your existing ext2 code reads bitmap/inode table locations from the block group descriptor (which it should), flex_bg mostly "just works." The physical layout is different but the descriptors tell you where everything is. The main change is making the allocator prefer same-flex-group allocation.

---

## §E5: Multiblock Allocator

**File:** `mballoc.zig`  
**Lines:** ~300  
**Dependencies:** Soft dependency on E4 (flex_bg for locality)

### What to implement

Allocate multiple contiguous blocks in a single operation. ext2 allocates one block at a time from the bitmap, which fragments large files. mballoc finds contiguous runs.

```zig
/// Allocation request
pub const AllocRequest = struct {
    /// Desired number of contiguous blocks
    count: u32,
    /// Goal block number (allocate near this if possible)
    goal: u64,
    /// Block group preference (from file's inode group or flex_bg)
    preferred_bg: u32,
    /// Minimum acceptable allocation (1 = any size ok)
    min_count: u32 = 1,
};

/// Allocation result
pub const AllocResult = struct {
    /// First block number allocated
    start: u64,
    /// Number of contiguous blocks actually allocated
    count: u32,
    /// Block group the allocation came from
    bg: u32,
};

/// Find and allocate N contiguous blocks
/// Strategy (in preference order):
///   1. Near goal_block in preferred BG: scan bitmap for run of N free bits
///   2. Anywhere in preferred BG: scan from start of bitmap
///   3. In neighboring BGs (same flex group if flex_bg enabled)
///   4. In any BG with enough free blocks
///   5. Fragmented: allocate min_count from any BG (partial allocation)
pub fn allocBlocks(req: AllocRequest) !AllocResult {
    // Implementation:
    // For each candidate block group:
    //   1. Read bitmap
    //   2. Scan for contiguous run of N zero bits
    //   3. If found near goal: allocate immediately
    //   4. If found anywhere: remember as fallback
    //   5. Continue to next BG if not found
    
    // Bitmap scanning:
    //   Process 64 bits at a time for speed
    //   @clz and @ctz to find runs of zeros
    //   Track longest run in each BG
}

/// Free a contiguous range of blocks
pub fn freeBlocks(start: u64, count: u32) !void {
    // 1. Determine block group from start block
    // 2. Read bitmap
    // 3. Clear count bits starting at (start % blocks_per_group)
    // 4. Write bitmap
    // 5. Update block group descriptor free count
    // 6. Update superblock free count
}

/// Scan a bitmap for a contiguous run of N zero bits
/// Returns bit offset of first zero, or null if not found
fn findContiguousRun(
    bitmap: [*]const u8,
    bitmap_bits: u32,
    count: u32,
    start_hint: u32,
) ?u32 {
    // Start scanning from start_hint, wrap around
    // Use word-at-a-time scanning for speed:
    //   Read u64, if all ones (0xFFFF_FFFF_FFFF_FFFF) skip 64 bits
    //   If has zeros: count consecutive zeros using bit tricks
    //   Track current run length across word boundaries
    // Return first run of >= count consecutive zeros
}
```

### Why this matters:
A 1MB file write with ext2's single-block allocator might scatter 256 blocks across the disk. With mballoc, those 256 blocks are contiguous — one extent, one disk seek, sequential I/O.

---

## §E6: Delayed Allocation

**File:** `delayed_alloc.zig`  
**Lines:** ~200  
**Dependencies:** E5 (mballoc)

### What to implement

Delay block allocation until data is flushed to disk. This lets mballoc see the full write size and allocate contiguously.

```zig
/// Per-inode delayed allocation state
pub const DelayedState = struct {
    /// Number of blocks reserved but not yet allocated
    reserved_blocks: u32 = 0,
    /// Dirty data ranges (logical block start, count)
    dirty_ranges: [16]DirtyRange = [_]DirtyRange{.{}} ** 16,
    dirty_count: u32 = 0,
};

pub const DirtyRange = struct {
    logical_start: u32 = 0,
    count: u32 = 0,
    valid: bool = false,
};

/// Reserve blocks without allocating
/// Called from write() syscall
pub fn reserveBlocks(state: *DelayedState, logical_start: u32, count: u32) !void {
    // 1. Check global free block counter has enough
    // 2. Decrement global reserved counter
    // 3. Record dirty range
    // 4. Merge adjacent/overlapping ranges
    // The data is written to page cache (buffer) but blocks aren't allocated yet
}

/// Flush delayed allocations — actually allocate and write
/// Called from fsync() or periodic writeback
pub fn flushDelayed(
    state: *DelayedState,
    inode_number: u32,
    // allocator function, write function, etc.
) !void {
    // For each dirty range:
    //   1. Call mballoc.allocBlocks() for the full range
    //      (mballoc sees the full size → contiguous allocation)
    //   2. Write data blocks to allocated physical blocks
    //   3. Update inode's block map / extent tree
    //   4. Clear dirty range
    //   5. Update reserved block counter
}

/// Cancel delayed allocation (truncate/delete)
pub fn cancelReservation(state: *DelayedState, from_logical: u32) void {
    // Release reserved blocks back to global counter
    // Clear affected dirty ranges
}
```

### Integration with write path:
```
write(fd, data):
  Without delalloc (ext2/ext3):
    allocate blocks immediately → write data → update inode

  With delalloc (ext4):
    reserveBlocks() → buffer data in memory → return to user

fsync(fd) / writeback timer:
    flushDelayed() → allocate all blocks at once → write all data → update inode
```

---

## §X1: Extent Tree

**File:** `extents.zig`  
**Lines:** ~600-800  
**Dependencies:** E3 (64-bit blocks), E5 (mballoc for allocation)

### What to implement

The extent tree replaces ext2/ext3's indirect block map (inode.i_block[15]) with a B-tree of extents. Each extent maps a contiguous range of logical blocks to physical blocks.

### On-disk structures

```zig
pub const EXTENT_MAGIC: u16 = 0xF30A;

/// Extent tree header — at the start of every tree node
pub const ExtentHeader = extern struct {
    magic: u16,         // Must be EXTENT_MAGIC
    entries: u16,       // Number of valid entries following this header
    max: u16,           // Maximum entries that fit in this node
    depth: u16,         // Tree depth: 0=leaf node, >0=internal node
    generation: u32,    // Tree generation (for checksums)

    pub fn isValid(self: *const @This()) bool {
        return self.magic == EXTENT_MAGIC and self.entries <= self.max;
    }

    pub fn isLeaf(self: *const @This()) bool {
        return self.depth == 0;
    }
};

/// Extent (leaf node entry) — maps logical blocks to physical blocks
/// 12 bytes each
pub const Extent = extern struct {
    block: u32,          // First logical block number
    len: u16,            // Number of blocks (max 32768, bit 15 = uninitialized)
    start_hi: u16,       // Physical block high 16 bits
    start_lo: u32,       // Physical block low 32 bits

    /// Full 48-bit physical block number
    pub fn physicalBlock(self: *const @This()) u64 {
        return (@as(u64, self.start_hi) << 32) | @as(u64, self.start_lo);
    }

    pub fn setPhysicalBlock(self: *@This(), block: u64) void {
        self.start_lo = @truncate(block);
        self.start_hi = @truncate(block >> 32);
    }

    /// Actual length (mask off uninitialized bit)
    pub fn blockCount(self: *const @This()) u32 {
        return @as(u32, self.len & 0x7FFF);
    }

    /// Check if extent covers this logical block
    pub fn contains(self: *const @This(), logical: u32) bool {
        return logical >= self.block and logical < self.block + self.blockCount();
    }
};

/// Index entry (internal node) — points to child node
/// 12 bytes each
pub const ExtentIndex = extern struct {
    block: u32,          // Logical block this subtree covers
    leaf_lo: u32,        // Physical block of child node (low 32 bits)
    leaf_hi: u16,        // Physical block of child node (high 16 bits)
    _unused: u16,

    pub fn childBlock(self: *const @This()) u64 {
        return (@as(u64, self.leaf_hi) << 32) | @as(u64, self.leaf_lo);
    }

    pub fn setChildBlock(self: *@This(), block: u64) void {
        self.leaf_lo = @truncate(block);
        self.leaf_hi = @truncate(block >> 32);
    }
};
```

### Tree layout

```
Inode i_block (60 bytes):
  [ExtentHeader(12)] [entry(12)] [entry(12)] [entry(12)] [entry(12)]
  Max entries in inode: 4 (at any depth)

Tree block (4096 bytes):
  [ExtentHeader(12)] [entry(12)] × 340
  Max entries per block: (4096 - 12) / 12 = 340
```

### Operations to implement

```zig
/// Look up physical block for a logical block number
/// Walks the tree from root (in inode i_block) to leaf
pub fn lookup(inode_iblock: *[60]u8, logical_block: u32) !?u64 {
    // 1. Parse header from inode_iblock
    // 2. If depth == 0: binary search extents for one containing logical_block
    //    If found: return physical_block + (logical - extent.block)
    //    If not found: return null (hole — unallocated, should be zero-filled)
    // 3. If depth > 0: binary search index entries
    //    Find entry where entry.block <= logical_block < next_entry.block
    //    Read child block from disk
    //    Recurse (decrement depth)
}

/// Insert a new extent (map logical→physical blocks)
pub fn insert(
    inode_iblock: *[60]u8,
    logical_start: u32,
    physical_start: u64,
    block_count: u32,
) !void {
    // 1. Find the leaf node that should contain this extent
    // 2. Try to merge with adjacent extent (extend existing one)
    // 3. If can't merge and leaf has space: insert new entry, shift others right
    // 4. If leaf is full: SPLIT
    //    a. Allocate new block for new leaf
    //    b. Move half the entries to new leaf
    //    c. Add new index entry to parent pointing to new leaf
    //    d. If parent is full: split parent (recursively up the tree)
    //    e. If root (in inode) is full: increase tree depth
    //       - Allocate block for old root contents
    //       - Copy root entries to new block  
    //       - Root becomes single index entry pointing to new block
    //       - depth++
}

/// Remove extents covering a range (for truncate/punch hole)
pub fn remove(
    inode_iblock: *[60]u8,
    logical_start: u32,
    block_count: u32,
) !void {
    // 1. Find extent(s) overlapping [logical_start, logical_start+block_count)
    // 2. For each overlapping extent:
    //    a. Complete overlap: remove entire extent
    //    b. Partial overlap at start: shrink extent (adjust block + start_lo/hi + len)
    //    c. Partial overlap at end: shrink extent (adjust len)
    //    d. Middle overlap: split into two extents (needs insert)
    // 3. Free the physical blocks being removed
    // 4. Merge adjacent entries if possible
    // 5. If tree nodes become empty: remove them, reduce depth if possible
}

/// Read file data using extent tree
pub fn readExtents(
    inode_iblock: *[60]u8,
    offset: u64,
    buf: [*]u8,
    len: u32,
    block_size: u32,
) !u32 {
    // Calculate logical block range from offset+len
    // For each logical block:
    //   lookup() → physical block
    //   If null (hole): zero-fill that portion of buf
    //   If mapped: read from physical block
    //   Batch contiguous physical blocks into single reads
}

/// Write file data using extent tree
pub fn writeExtents(
    inode_iblock: *[60]u8,
    offset: u64,
    data: [*]const u8,
    len: u32,
    block_size: u32,
) !u32 {
    // Calculate logical block range
    // For each unallocated logical block:
    //   Allocate physical blocks via mballoc (prefer contiguous)
    //   insert() extent mapping
    // Write data to physical blocks
    // Update inode size and block count
}
```

### Feature flag:
```
Superblock: s_feature_incompat & 0x0040 (INCOMPAT_EXTENTS)
Per-inode: i_flags & 0x00080000 (EXTENTS_FL)
```

Both flags should be checked. The superblock flag says "this filesystem supports extents." The inode flag says "this specific inode uses extents." New files get EXTENTS_FL by default on ext4. Old files (migrated from ext3) might still use block maps.

### Test:
```bash
# Create ext4 image with large file
mkfs.ext4 test.img
mount test.img /mnt
dd if=/dev/urandom of=/mnt/bigfile bs=1M count=100
sync
umount /mnt
# Boot Zigix → read bigfile → verify data matches → dump extent tree
```

---

## §X2: HTree Indexed Directories

**File:** `htree.zig`  
**Lines:** ~400-500  
**Dependencies:** E1 (CRC32c for checksums)

### What to implement

HTree replaces linear directory scanning with hash-indexed lookup. Small directories (<1 block) continue using linear scan. Large directories get an HTree index.

### On-disk structures

```zig
/// HTree root block structures
/// The root is hidden inside the first directory block,
/// after the fake "." and ".." entries

pub const DxRoot = extern struct {
    /// Fake "." entry (12 bytes)
    dot_inode: u32,
    dot_rec_len: u16,    // = 12
    dot_name_len: u8,    // = 1
    dot_file_type: u8,   // = 2 (directory)
    dot_name: [4]u8,     // ".\x00\x00\x00"

    /// Fake ".." entry (rest of space before dx_root_info)
    dotdot_inode: u32,
    dotdot_rec_len: u16, // = block_size - 12
    dotdot_name_len: u8, // = 2
    dotdot_file_type: u8,// = 2
    dotdot_name: [4]u8,  // "..\x00\x00"

    /// Root info (hidden in ".." entry's padding)
    _reserved: u32,       // 0
    hash_version: u8,     // 0=legacy, 1=half_md4, 2=tea, 3=half_md4_unsigned, 4=tea_unsigned
    info_length: u8,      // 8
    indirect_levels: u8,  // 0=single level, 1=two levels
    _unused_flags: u8,    // 0

    /// Root index entries start here
    limit: u16,          // Max entries in this block
    count: u16,          // Current number of entries
    block: u32,          // Block number of first child leaf (always 0 for root)
    // Followed by (count-1) DxEntry structs
};

/// Index entry — (hash, block) pair
pub const DxEntry = extern struct {
    hash: u32,           // Hash value (entries sorted by hash)
    block: u32,          // Block number containing directory entries with this hash range
};

/// Internal node (non-root)
pub const DxNode = extern struct {
    /// Fake dirent header (makes block look like valid directory block)
    fake_inode: u32,     // 0
    fake_rec_len: u16,   // block_size
    fake_name_len: u8,   // 0
    fake_file_type: u8,  // 0

    limit: u16,
    count: u16,
    block: u32,
    // Followed by (count-1) DxEntry structs
};
```

### Hash function (half_md4)

```zig
/// Default hash function for ext3/ext4 directories
/// half_md4 is a simplified MD4 that produces a 32-bit hash
///
/// The hash seed comes from the superblock: s_hash_seed[4] (16 bytes at offset 0xEC)
/// If s_hash_seed is all zeros, use a default seed
pub fn halfMd4Hash(name: []const u8, seed: [4]u32) u32 {
    // Process name 32 bytes at a time through modified MD4 rounds
    // Only uses 3 rounds instead of MD4's 4
    // Returns 32-bit hash
    //
    // This is well-documented in Linux: fs/ext4/hash.c
    // The algorithm is stable — must produce identical hashes to Linux
    // for directory compatibility
}

/// TEA (Tiny Encryption Algorithm) hash — alternative
pub fn teaHash(name: []const u8, seed: [4]u32) u32 {
    // TEA-based hash, also from Linux fs/ext4/hash.c
    // Used when hash_version == 2 or 4
}
```

### Operations

```zig
/// Look up a name in an HTree-indexed directory
pub fn htreeLookup(
    dir_inode: *const Inode,
    name: []const u8,
    hash_seed: [4]u32,
    hash_version: u8,
) !?u32 {  // Returns inode number or null
    // 1. Compute hash = hashFunction(name, hash_seed, hash_version)
    // 2. Read first directory block (contains DxRoot)
    // 3. Binary search root entries for hash range
    // 4. If indirect_levels > 0: 
    //    Read internal node block, binary search again
    // 5. Read leaf block (normal directory entries)
    // 6. Linear scan leaf block for exact name match
    // 7. Return inode number if found
}

/// Insert a name into an HTree-indexed directory
pub fn htreeInsert(
    dir_inode: *Inode,
    name: []const u8,
    child_inode: u32,
    file_type: u8,
    hash_seed: [4]u32,
    hash_version: u8,
) !void {
    // 1. Compute hash
    // 2. Find target leaf block via hash lookup
    // 3. Try inserting directory entry in leaf block (standard ext2 dir entry insert)
    // 4. If leaf block is full: SPLIT
    //    a. Allocate new directory block
    //    b. Compute hash of every entry in full block
    //    c. Sort by hash, move upper half to new block
    //    d. Insert new DxEntry (hash_of_first_in_new_block, new_block) into parent
    //    e. If parent is full: split parent, increase depth if needed
    // 5. Retry insert in correct leaf block after split
}

/// Remove a name from an HTree-indexed directory
pub fn htreeRemove(
    dir_inode: *Inode,
    name: []const u8,
    hash_seed: [4]u32,
    hash_version: u8,
) !bool {  // Returns true if removed
    // 1. Find leaf block via hash lookup
    // 2. Linear scan for exact name match
    // 3. Mark entry as deleted (set inode=0, merge rec_len with previous)
    // 4. Don't rebalance tree — space is reclaimed on next split
}

/// Convert a linear directory to HTree (called when directory grows too large)
pub fn convertToHTree(
    dir_inode: *Inode,
    hash_seed: [4]u32,
    hash_version: u8,
) !void {
    // 1. Read all existing directory entries from first block
    // 2. Allocate second block, move all entries there
    // 3. Convert first block to DxRoot format:
    //    - Keep "." and ".." entries
    //    - Add dx_root_info header
    //    - Add single DxEntry pointing to second block with hash=0
    // 4. Set EXT4_INDEX_FL on inode
}
```

### When to use HTree vs linear:
- If `inode.i_flags & EXT4_INDEX_FL` → use HTree functions
- Otherwise → use existing ext2 linear directory code
- On directory growth beyond 1 block → call `convertToHTree()`

### Test:
```bash
# Create directory with many files
mkfs.ext4 test.img
mount test.img /mnt
for i in $(seq 1 10000); do touch /mnt/dir/file_$i; done
umount /mnt
# Boot Zigix → ls /mnt/dir/ → verify all 10000 files found
# Benchmark: lookup time should be constant regardless of directory size
```
