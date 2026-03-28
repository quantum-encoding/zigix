/// JBD2 (Journaling Block Device v2) on-disk structures.
///
/// These structures define the journal format used by ext3 and ext4.
/// The journal lives in inode 8 and uses the same block size as the filesystem.
///
/// Freestanding — no std, no libc.

/// JBD2 magic number — present in every journal metadata block.
pub const JBD2_MAGIC: u32 = 0xC03B3998;

/// Journal block types.
pub const BLOCKTYPE_DESCRIPTOR: u32 = 1;
pub const BLOCKTYPE_COMMIT: u32 = 2;
pub const BLOCKTYPE_SUPERBLOCK_V1: u32 = 3;
pub const BLOCKTYPE_SUPERBLOCK_V2: u32 = 4;
pub const BLOCKTYPE_REVOKE: u32 = 5;

/// Journal inode number in the filesystem.
pub const JOURNAL_INO: u32 = 8;

/// Block tag flags.
pub const FLAG_ESCAPE: u16 = 0x01;
pub const FLAG_SAME_UUID: u16 = 0x02;
pub const FLAG_DELETED: u16 = 0x04;
pub const FLAG_LAST_TAG: u16 = 0x08;

/// Journal superblock — lives at block 0 of the journal.
/// Total size: 1024 bytes (rest of first block is filesystem-block-size padding).
pub const JournalSuperblock = extern struct {
    // Common header (same as BlockHeader)
    magic: u32,            // 0x00: Must be JBD2_MAGIC
    blocktype: u32,        // 0x04: SUPERBLOCK_V1 (3) or SUPERBLOCK_V2 (4)
    sequence: u32,         // 0x08: First commit ID expected in log

    // Static fields
    blocksize: u32,        // 0x0C: Journal block size (= fs block size)
    maxlen: u32,           // 0x10: Total blocks in journal
    first: u32,            // 0x14: First usable block (after superblock)

    // Dynamic fields
    errno: i32,            // 0x18: Error value from last recovery

    // V2 fields (offset 0x1C+)
    feature_compat: u32,   // 0x1C
    feature_incompat: u32, // 0x20
    feature_ro_compat: u32,// 0x24
    uuid: [16]u8,          // 0x28: Journal UUID
    nr_users: u32,         // 0x38: Number of FS sharing this journal
    dynsuper: u32,         // 0x3C: Block of dynamic superblock copy
    max_transaction: u32,  // 0x40: Max blocks per transaction
    max_trans_data: u32,   // 0x44: Max data blocks per transaction

    _padding: [936]u8,     // 0x48–0x3FF: Padding to 1024 bytes

    pub fn isValid(self: *const @This()) bool {
        return self.magic == JBD2_MAGIC and
            (self.blocktype == BLOCKTYPE_SUPERBLOCK_V1 or
            self.blocktype == BLOCKTYPE_SUPERBLOCK_V2);
    }

    pub fn isV2(self: *const @This()) bool {
        return self.blocktype == BLOCKTYPE_SUPERBLOCK_V2;
    }

    /// Check if journal is dirty (needs replay).
    /// A clean journal has sequence == 0 after a proper unmount.
    pub fn isDirty(self: *const @This()) bool {
        return self.sequence != 0;
    }
};

/// Block header — first 12 bytes of every journal metadata block.
pub const BlockHeader = extern struct {
    magic: u32,      // Must be JBD2_MAGIC
    blocktype: u32,  // BLOCKTYPE_* value
    sequence: u32,   // Transaction ID this block belongs to

    pub fn isValid(self: *const @This()) bool {
        return self.magic == JBD2_MAGIC;
    }

    pub fn isDescriptor(self: *const @This()) bool {
        return self.blocktype == BLOCKTYPE_DESCRIPTOR;
    }

    pub fn isCommit(self: *const @This()) bool {
        return self.blocktype == BLOCKTYPE_COMMIT;
    }

    pub fn isRevoke(self: *const @This()) bool {
        return self.blocktype == BLOCKTYPE_REVOKE;
    }
};

/// Block tag — inside DESCRIPTOR blocks, 8 bytes each.
/// Lists which filesystem blocks are journaled in this transaction.
/// The actual data blocks follow immediately after the descriptor block.
pub const BlockTag = extern struct {
    blocknr: u32,    // Filesystem block number
    flags: u16,      // Tag flags (FLAG_*)
    checksum: u16,   // CRC16 of block data (V3 only, else unused)

    pub fn isLast(self: *const @This()) bool {
        return self.flags & FLAG_LAST_TAG != 0;
    }

    pub fn isEscaped(self: *const @This()) bool {
        return self.flags & FLAG_ESCAPE != 0;
    }

    pub fn isDeleted(self: *const @This()) bool {
        return self.flags & FLAG_DELETED != 0;
    }
};

/// Revoke header — in REVOKE blocks.
/// Followed by an array of u32 filesystem block numbers that should NOT be replayed.
pub const RevokeHeader = extern struct {
    header: BlockHeader, // 12 bytes
    count: u32,          // Byte count of revoke data following this header
};

/// Commit block — marks end of transaction.
pub const CommitBlock = extern struct {
    header: BlockHeader,    // 12 bytes
    checksum_type: u8,      // 1 = CRC32, 4 = CRC32c
    checksum_size: u8,      // Size of checksum field (4)
    _padding: [2]u8,
    checksum: [4]u32,       // Transaction checksums
    commit_sec_lo: u32,     // Commit timestamp seconds (low)
    commit_sec_hi: u32,     // Commit timestamp seconds (high)
    commit_nsec: u32,       // Commit timestamp nanoseconds
};

// ── Runtime bookkeeping (NOT on-disk) ──────────────────────────────────

/// Journal runtime state — tracks current position, sequence, and capacity.
pub const JournalState = struct {
    /// Journal is active and accepting transactions.
    active: bool = false,
    /// Current write position in journal (block index).
    write_pos: u32 = 0,
    /// Current transaction sequence number.
    sequence: u32 = 0,
    /// First usable block in journal (after superblock).
    first_block: u32 = 0,
    /// Total blocks in journal.
    max_blocks: u32 = 0,
    /// Starting block of journal on disk (from inode 8's block map).
    disk_start_block: u64 = 0,
    /// Block size (same as filesystem).
    block_size: u32 = 4096,
    /// Max blocks per transaction.
    max_tx_blocks: u32 = 0,

    /// Convert journal-relative block index to absolute disk block.
    pub fn journalToDisk(self: *const @This(), journal_block: u32) u64 {
        return self.disk_start_block + @as(u64, journal_block);
    }

    /// Advance write position, wrapping around.
    pub fn advance(self: *@This(), count: u32) void {
        self.write_pos = self.write_pos + count;
        if (self.write_pos >= self.max_blocks) {
            self.write_pos = self.first_block + (self.write_pos - self.max_blocks);
        }
    }

    /// Next journal block index (with wrap).
    pub fn nextBlock(self: *const @This(), current: u32) u32 {
        const next = current + 1;
        return if (next >= self.max_blocks) self.first_block else next;
    }

    /// Free space in journal (blocks available for writing).
    /// Simplified: returns full capacity, doesn't track checkpoint tail.
    /// Sufficient for Zigix's synchronous write model where all transactions
    /// complete before the next begins.
    pub fn freeSpace(self: *const @This()) u32 {
        return self.max_blocks - self.first_block;
    }
};

/// Transaction handle — returned by journal start, tracks queued blocks.
pub const MAX_TX_ENTRIES: u32 = 64;

pub const TransactionHandle = struct {
    /// Transaction sequence number.
    sequence: u32 = 0,
    /// Number of blocks reserved for this transaction.
    reserved_blocks: u32 = 0,
    /// Filesystem block numbers queued for journaling.
    block_numbers: [MAX_TX_ENTRIES]u32 = [_]u32{0} ** MAX_TX_ENTRIES,
    /// Number of blocks queued.
    block_count: u32 = 0,
    /// Transaction is in progress.
    active: bool = false,

    /// Add a filesystem block to this transaction.
    pub fn addBlock(self: *@This(), fs_block: u32) bool {
        if (self.block_count >= MAX_TX_ENTRIES) return false;
        self.block_numbers[self.block_count] = fs_block;
        self.block_count += 1;
        return true;
    }
};
