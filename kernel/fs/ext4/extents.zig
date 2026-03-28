/// ext4 extent tree — B-tree mapping of logical blocks to physical blocks.
///
/// Replaces ext2/ext3's indirect block map (inode.i_block[15]) with a compact
/// tree of extents. Each extent maps a contiguous range of logical blocks to
/// contiguous physical blocks.
///
/// Tree structure:
///   - Root: stored in inode i_block (60 bytes) → 1 header + 4 entries
///   - Internal nodes: full disk blocks → 1 header + 340 entries
///   - Leaf nodes: extents (12 bytes each) mapping logical→physical
///
/// Feature flag: INCOMPAT_EXTENTS (0x0040) in superblock,
///               EXTENTS_FL (0x00080000) per-inode in i_flags.
///
/// Freestanding — no std, no libc.

/// Extent tree magic number.
pub const EXTENT_MAGIC: u16 = 0xF30A;

/// Feature flags.
pub const INCOMPAT_EXTENTS: u32 = 0x0040;
pub const EXTENTS_FL: u32 = 0x00080000;

/// Maximum entries in root node (60 bytes: 1 header + 4 entries).
pub const ROOT_MAX_ENTRIES: u16 = 4;

/// Extent tree header — at the start of every tree node (12 bytes).
pub const ExtentHeader = extern struct {
    magic: u16,       // Must be EXTENT_MAGIC (0xF30A)
    entries: u16,     // Number of valid entries following this header
    max: u16,         // Maximum entries that fit in this node
    depth: u16,       // Tree depth: 0=leaf, >0=internal
    generation: u32,  // Tree generation (for checksums)

    pub fn isValid(self: *const @This()) bool {
        return self.magic == EXTENT_MAGIC and self.entries <= self.max;
    }

    pub fn isLeaf(self: *const @This()) bool {
        return self.depth == 0;
    }
};

/// Extent — leaf node entry (12 bytes).
/// Maps a contiguous range of logical blocks to physical blocks.
pub const Extent = extern struct {
    block: u32,       // First logical block number
    len: u16,         // Number of blocks (bit 15 = uninitialized/prealloc)
    start_hi: u16,    // Physical block high 16 bits
    start_lo: u32,    // Physical block low 32 bits

    /// Full 48-bit physical start block.
    pub fn physicalBlock(self: *const @This()) u64 {
        return (@as(u64, self.start_hi) << 32) | @as(u64, self.start_lo);
    }

    /// Set the 48-bit physical start block.
    pub fn setPhysicalBlock(self: *@This(), phys: u64) void {
        self.start_lo = @truncate(phys);
        self.start_hi = @truncate(phys >> 32);
    }

    /// Actual length — matches Linux ext4_ext_get_actual_len().
    /// Initialized extents: len = 1..32768 (stored directly).
    /// Uninitialized extents: len = 32769..65535 (actual = len - 32768).
    /// Note: 0x7FFF masking is WRONG — it turns len=32768 (0x8000) into 0.
    pub fn blockCount(self: *const @This()) u32 {
        return if (self.len <= 32768) @as(u32, self.len) else @as(u32, self.len - 32768);
    }

    /// Whether this extent is uninitialized (preallocated but not written).
    /// Linux: ee_len > EXT_MAX_BLOCKS (32768) means unwritten.
    pub fn isUninitialized(self: *const @This()) bool {
        return self.len > 32768;
    }

    /// Check if extent covers this logical block.
    pub fn contains(self: *const @This(), logical: u32) bool {
        return logical >= self.block and logical < self.block + self.blockCount();
    }

    /// Get physical block for a given logical block within this extent.
    pub fn translate(self: *const @This(), logical: u32) ?u64 {
        if (!self.contains(logical)) return null;
        return self.physicalBlock() + @as(u64, logical - self.block);
    }

    /// End logical block (exclusive).
    pub fn endBlock(self: *const @This()) u32 {
        return self.block + self.blockCount();
    }
};

/// Index entry — internal node (12 bytes).
/// Points to a child block in the tree.
pub const ExtentIndex = extern struct {
    block: u32,       // First logical block this subtree covers
    leaf_lo: u32,     // Physical block of child node (low 32 bits)
    leaf_hi: u16,     // Physical block of child node (high 16 bits)
    _unused: u16,

    /// Physical block of child node.
    pub fn childBlock(self: *const @This()) u64 {
        return (@as(u64, self.leaf_hi) << 32) | @as(u64, self.leaf_lo);
    }

    /// Set child block address.
    pub fn setChildBlock(self: *@This(), phys: u64) void {
        self.leaf_lo = @truncate(phys);
        self.leaf_hi = @truncate(phys >> 32);
    }
};

// ── Tree navigation ────────────────────────────────────────────────────

/// Get extent header from a node buffer.
pub fn getHeader(buf: [*]const u8) *const ExtentHeader {
    return @ptrCast(@alignCast(buf));
}

/// Get mutable extent header.
pub fn getHeaderMut(buf: [*]u8) *ExtentHeader {
    return @ptrCast(@alignCast(buf));
}

/// Get extent entries from a leaf node (after the header).
pub fn getExtents(buf: [*]const u8) [*]const Extent {
    return @ptrCast(@alignCast(buf + @sizeOf(ExtentHeader)));
}

/// Get mutable extent entries.
pub fn getExtentsMut(buf: [*]u8) [*]Extent {
    return @ptrCast(@alignCast(buf + @sizeOf(ExtentHeader)));
}

/// Get index entries from an internal node (after the header).
pub fn getIndices(buf: [*]const u8) [*]const ExtentIndex {
    return @ptrCast(@alignCast(buf + @sizeOf(ExtentHeader)));
}

/// Get mutable index entries.
pub fn getIndicesMut(buf: [*]u8) [*]ExtentIndex {
    return @ptrCast(@alignCast(buf + @sizeOf(ExtentHeader)));
}

/// Maximum entries that fit in a disk block.
pub fn maxEntriesPerBlock(block_size: u32) u16 {
    return @truncate((block_size - @sizeOf(ExtentHeader)) / @sizeOf(Extent));
}

/// Binary search for the extent containing `logical` in a leaf node.
/// Returns the index of the extent, or null if no extent covers this block.
pub fn findExtent(buf: [*]const u8, logical: u32) ?u32 {
    const header = getHeader(buf);
    if (!header.isValid() or !header.isLeaf()) return null;

    const extents = getExtents(buf);
    var i: u32 = 0;
    while (i < header.entries) : (i += 1) {
        if (extents[i].contains(logical)) return i;
    }
    return null;
}

/// Binary search for the index entry covering `logical` in an internal node.
/// Returns the index of the correct child, or null.
pub fn findIndex(buf: [*]const u8, logical: u32) ?u32 {
    const header = getHeader(buf);
    if (!header.isValid() or header.isLeaf()) return null;

    const indices = getIndices(buf);
    if (header.entries == 0) return null;

    // Binary search: find the last entry where entry.block <= logical
    var lo: u32 = 0;
    var hi: u32 = header.entries;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (indices[mid].block <= logical) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    // lo is now the first entry where entry.block > logical, so we want lo-1
    return if (lo > 0) lo - 1 else 0;
}

/// Look up the physical block for a logical block, starting from the root
/// stored in inode i_block (60 bytes).
///
/// For depth-0 trees (common: small files), this is a direct extent search.
/// For deeper trees, follows index entries to child blocks.
///
/// Parameters:
///   iblock:     pointer to inode's i_block field (60 bytes, contains root node)
///   logical:    logical block number to look up
///   read_block: function to read a disk block (block_num → buf or null)
///
/// Returns the physical block number, or null for holes (unallocated).
pub fn lookup(
    iblock: *const [60]u8,
    logical: u32,
    read_block: *const fn (u64) ?[*]const u8,
) ?u64 {
    const root: [*]const u8 = iblock;
    const header = getHeader(root);

    if (!header.isValid()) return null;

    if (header.isLeaf()) {
        // Depth 0: search extents directly in inode
        const extents = getExtents(root);
        var i: u16 = 0;
        while (i < header.entries) : (i += 1) {
            if (extents[i].translate(logical)) |phys| return phys;
        }
        return null; // Hole
    }

    // Depth > 0: follow index entries
    var current_buf = root;
    var depth = header.depth;

    while (depth > 0) {
        const idx = findIndex(current_buf, logical) orelse return null;
        const indices = getIndices(current_buf);
        const child_phys = indices[idx].childBlock();

        const child_buf = read_block(child_phys) orelse return null;
        current_buf = child_buf;

        const child_header = getHeader(current_buf);
        if (!child_header.isValid()) return null;
        depth = child_header.depth;
    }

    // Now at leaf level
    const extents = getExtents(current_buf);
    const leaf_header = getHeader(current_buf);
    var i: u16 = 0;
    while (i < leaf_header.entries) : (i += 1) {
        if (extents[i].translate(logical)) |phys| return phys;
    }

    return null; // Hole
}

/// Initialize an empty extent tree root in the inode's i_block field.
pub fn initRoot(iblock: *[60]u8) void {
    // Zero everything first
    for (iblock) |*b| b.* = 0;

    const header = getHeaderMut(iblock);
    header.magic = EXTENT_MAGIC;
    header.entries = 0;
    header.max = ROOT_MAX_ENTRIES;
    header.depth = 0;
    header.generation = 0;
}

/// Insert a new extent into a leaf node (no splitting).
/// Returns true if inserted, false if leaf is full.
pub fn insertInLeaf(buf: [*]u8, ext: Extent) bool {
    const header = getHeaderMut(buf);
    if (!header.isValid() or !header.isLeaf()) return false;
    if (header.entries >= header.max) return false;

    const extents = getExtentsMut(buf);

    // Find insertion point (keep sorted by logical block)
    var pos: u16 = 0;
    while (pos < header.entries) : (pos += 1) {
        if (extents[pos].block > ext.block) break;
    }

    // Shift entries right
    var i: u16 = header.entries;
    while (i > pos) : (i -= 1) {
        extents[i] = extents[i - 1];
    }

    // Insert
    extents[pos] = ext;
    header.entries += 1;
    return true;
}

/// Check if an inode uses extents (check i_flags field).
pub fn usesExtents(i_flags: u32) bool {
    return i_flags & EXTENTS_FL != 0;
}
