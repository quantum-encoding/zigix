# ext3 Journaling Implementation

## Context

You are implementing ext3 journaling for the Zigix OS kernel. The existing ext2 filesystem is at `zigix/kernel/fs/ext2.zig` (~1,200 lines, fully working). ext3 is identical to ext2 on disk except for a journal stored in inode 8. Your job is to add journaling so that metadata operations survive crashes without requiring fsck.

All code must be freestanding Zig (no std, no libc). Use the kernel's `blockRead()`/`blockWrite()` for disk I/O. Follow patterns from the existing ext2.zig.

## Files You Create

```
ext3/
├── journal_types.zig      ← §J1: On-disk structures
├── journal_replay.zig     ← §J2: Recovery (replay on mount)
├── journal.zig            ← §J3: Transaction write path
└── ext3_mount.zig         ← §J4: Mount/unmount integration
```

---

## §J1: Journal Types and Structures

**File:** `journal_types.zig`
**Lines:** ~120
**Dependencies:** None
**Output:** Pure type definitions and constants, no logic

### What to implement

Define all on-disk structures for the JBD2 (Journaling Block Device v2) format:

```zig
pub const JBD2_MAGIC: u32 = 0xC03B3998;

pub const BlockType = enum(u32) {
    descriptor = 1,    // Lists which FS blocks follow in this transaction
    commit = 2,        // Marks end of a transaction
    superblock_v1 = 3, // Journal superblock (version 1)
    superblock_v2 = 4, // Journal superblock (version 2)
    revoke = 5,        // Blocks that should NOT be replayed
};

/// Journal superblock — lives at block 0 of the journal
/// Total: 1024 bytes (rest of first block is padding)
pub const JournalSuperblock = extern struct {
    // Common header
    magic: u32,           // 0x00: Must be JBD2_MAGIC
    blocktype: u32,       // 0x04: 3 (V1) or 4 (V2)
    sequence: u32,        // 0x08: First commit ID expected in log

    // Static fields
    blocksize: u32,       // 0x0C: Journal block size (= fs block size)
    maxlen: u32,          // 0x10: Total blocks in journal
    first: u32,           // 0x14: First usable block (after superblock)

    // Dynamic fields
    errno: i32,           // 0x18: Error value from last recovery
    
    // V2 only fields (offset 0x1C+)
    feature_compat: u32,  // 0x1C
    feature_incompat: u32,// 0x20
    feature_ro_compat: u32,// 0x24
    uuid: [16]u8,         // 0x28: Journal UUID
    nr_users: u32,        // 0x38: Number of FS sharing this journal
    dynsuper: u32,        // 0x3C: Block of dynamic superblock copy
    max_transaction: u32, // 0x40: Max blocks per transaction
    max_trans_data: u32,  // 0x44: Max data blocks per transaction
    
    // Padding to 1024 bytes
    _padding: [936]u8,    // 0x48-0x3FF

    pub fn isValid(self: *const @This()) bool {
        return self.magic == JBD2_MAGIC and
               (self.blocktype == @intFromEnum(BlockType.superblock_v1) or
                self.blocktype == @intFromEnum(BlockType.superblock_v2));
    }

    pub fn isV2(self: *const @This()) bool {
        return self.blocktype == @intFromEnum(BlockType.superblock_v2);
    }
};

/// Block header — first 12 bytes of every journal metadata block
pub const BlockHeader = extern struct {
    magic: u32,      // Must be JBD2_MAGIC
    blocktype: u32,  // BlockType enum value
    sequence: u32,   // Transaction ID this block belongs to

    pub fn isValid(self: *const @This()) bool {
        return self.magic == JBD2_MAGIC;
    }
};

/// Block tag — inside DESCRIPTOR blocks, 8 bytes each (12 if 64-bit)
/// Lists which filesystem blocks are journaled in this transaction
pub const BlockTag = extern struct {
    blocknr: u32,     // Filesystem block number
    flags: u16,       // Tag flags (see below)
    checksum: u16,    // CRC16 of block data (V3 only, else unused)

    pub const FLAG_ESCAPE: u16 = 0x01;     // Block has fake magic, needs unescaping
    pub const FLAG_SAME_UUID: u16 = 0x02;  // Same UUID as previous tag
    pub const FLAG_DELETED: u16 = 0x04;    // Block was deleted (skip replay)
    pub const FLAG_LAST_TAG: u16 = 0x08;   // Last tag in this descriptor

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

/// Revoke header — in REVOKE blocks
pub const RevokeHeader = extern struct {
    header: BlockHeader,
    count: u32,        // Byte count of revoke data following this header
    // Followed by array of u32 filesystem block numbers
};

/// Commit block — marks end of transaction (V2+)
pub const CommitBlock = extern struct {
    header: BlockHeader,
    checksum_type: u8,    // 1 = CRC32, 4 = CRC32c
    checksum_size: u8,    // Size of checksum (4)
    _padding: [2]u8,
    checksum: [4]u32,     // Transaction checksums
    commit_sec: u64,      // Commit timestamp (seconds)
    commit_nsec: u32,     // Commit timestamp (nanoseconds)
};

/// Journal state — runtime bookkeeping (NOT on-disk)
pub const JournalState = struct {
    /// Journal is active and accepting transactions
    active: bool = false,
    /// Current write position in journal (block index)
    write_pos: u32 = 0,
    /// Current transaction sequence number
    sequence: u32 = 0,
    /// First usable block in journal
    first_block: u32 = 0,
    /// Total blocks in journal
    max_blocks: u32 = 0,
    /// Starting block of journal on disk (from inode 8's block map)
    disk_start_block: u32 = 0,
    /// Block size (same as filesystem)
    block_size: u32 = 4096,
    /// Blocks used in current transaction
    current_tx_blocks: u32 = 0,
    /// Max blocks per transaction
    max_tx_blocks: u32 = 0,

    /// Convert journal-relative block index to absolute disk block
    pub fn journalToDisk(self: *const @This(), journal_block: u32) u64 {
        return @as(u64, self.disk_start_block) + @as(u64, journal_block);
    }

    /// Advance write position, wrapping around
    pub fn advance(self: *@This(), count: u32) void {
        self.write_pos = (self.write_pos + count) % self.max_blocks;
        if (self.write_pos < self.first_block) {
            self.write_pos = self.first_block;
        }
    }
};

/// Transaction handle — returned by journal_start(), passed to journal_write_block()
pub const TransactionHandle = struct {
    sequence: u32,
    reserved_blocks: u32,
    used_blocks: u32 = 0,
    /// Filesystem block numbers queued for this transaction
    block_numbers: [64]u32 = [_]u32{0} ** 64,
    /// Number of blocks queued
    block_count: u32 = 0,
    active: bool = false,

    pub fn addBlock(self: *@This(), fs_block: u32) !void {
        if (self.block_count >= 64) return error.TransactionFull;
        self.block_numbers[self.block_count] = fs_block;
        self.block_count += 1;
        self.used_blocks += 1;
    }
};
```

### Verification

- All structs must be `extern struct` for correct memory layout
- `@sizeOf(JournalSuperblock)` must equal 1024
- `@sizeOf(BlockHeader)` must equal 12
- `@sizeOf(BlockTag)` must equal 8
- Field offsets must match the JBD2 spec exactly

---

## §J2: Journal Replay (Recovery)

**File:** `journal_replay.zig`  
**Lines:** ~250  
**Dependencies:** J1 (journal_types.zig)

### What to implement

Journal recovery runs at mount time when the journal is dirty (system wasn't cleanly unmounted). It replays committed transactions to bring the filesystem to a consistent state.

```zig
const types = @import("journal_types.zig");

/// Revoke table entry — tracks blocks that should NOT be replayed
const RevokeEntry = struct {
    fs_block: u32,
    sequence: u32,  // Transaction that revoked this block
};

/// Replay result
pub const ReplayResult = struct {
    transactions_found: u32,
    transactions_replayed: u32,
    blocks_replayed: u32,
    revoke_entries: u32,
    errors: u32,
};

/// Main entry point: replay the journal
/// Called from ext3_mount.zig when journal is dirty
///
/// Parameters:
///   journal_state: initialized JournalState with disk_start_block set
///   blockRead: kernel's block read function
///   blockWrite: kernel's block write function  
///   block_buf: temporary buffer (at least block_size bytes)
///   
pub fn replayJournal(
    state: *const types.JournalState,
    // ... kernel I/O function pointers
) ReplayResult {
    var result = ReplayResult{};
    
    // PASS 1: SCAN
    // Walk journal from first_block, read each block header
    // Build list of committed transactions and revoke table
    //
    // For each block:
    //   Read header → check magic == JBD2_MAGIC
    //   If DESCRIPTOR: parse tags, record (sequence, fs_block) pairs
    //                  Each tag is followed by the actual data block
    //   If COMMIT: mark that sequence as committed
    //   If REVOKE: parse block numbers, add to revoke table
    //   Stop when: magic doesn't match, or sequence goes backward,
    //              or we've wrapped back to start
    
    // PASS 2: FILTER REVOKES
    // For each recorded (sequence, fs_block) pair:
    //   If revoke_table contains fs_block with revoke_seq >= write_seq:
    //     Remove from replay list (this write was superseded)
    
    // PASS 3: REPLAY
    // For each surviving entry (oldest transaction first):
    //   Read data block from journal position
    //   If tag has FLAG_ESCAPE: restore magic byte at offset 0
    //   Write data block to its filesystem block number
    //   Increment blocks_replayed
    
    // PASS 4: CLEAR JOURNAL
    // Write journal superblock with sequence = 0 (marks clean)
    // Sync to disk
    
    return result;
}
```

### Key Details

1. **Journal wraps around.** Block positions are modular: `pos = (pos + 1) % max_blocks`. When pos reaches max_blocks, wrap to first_block (not 0, because block 0 is the journal superblock).

2. **Descriptor + data interleaving.** A DESCRIPTOR block contains tags, each tag describes one filesystem block. The actual data blocks follow immediately after the descriptor:
   ```
   [DESCRIPTOR: tag1=block100, tag2=block200, tag3=block300]
   [DATA for block100]
   [DATA for block200]  
   [DATA for block300]
   [COMMIT]
   ```

3. **Escaped blocks.** If a data block's first 4 bytes happen to be JBD2_MAGIC (0xC03B3998), the journal sets FLAG_ESCAPE on the tag and zeros those 4 bytes. On replay, you must restore them.

4. **Revoke semantics.** A revoke says "block N should not be replayed from any transaction with sequence <= this revoke's sequence." This handles the case where: tx1 writes block 100, tx2 deletes the file (frees block 100), tx3 allocates block 100 for a different file. Without revoke, replaying tx1 would corrupt the new file.

5. **Transaction ordering.** Replay oldest committed transactions first. A transaction is committed only if you found both its DESCRIPTOR and COMMIT blocks. Incomplete transactions (descriptor without commit) are skipped — they represent in-progress operations at crash time.

### Test Strategy

Create a test ext3 image on Linux:
```bash
dd if=/dev/zero of=test.img bs=1M count=64
mkfs.ext3 -b 4096 -J size=4 test.img
mount test.img /mnt
echo "hello" > /mnt/test.txt
# Kill without umount to leave journal dirty
```

Boot Zigix with this image → verify journal replays → verify test.txt is readable.

---

## §J3: Journal Write Path (Transactions)

**File:** `journal.zig`  
**Lines:** ~300  
**Dependencies:** J1 (types)

### What to implement

This is the runtime transaction system. Every metadata operation (allocate block, create directory entry, write inode) goes through a transaction.

```zig
const types = @import("journal_types.zig");

/// Global journal state
var journal_state: types.JournalState = .{};

/// Buffer for building transactions
/// Each entry: (fs_block_number, data[block_size])
const MAX_TX_ENTRIES = 64;
var tx_buffers: [MAX_TX_ENTRIES][4096]u8 = undefined;

/// Initialize journal (called from ext3_mount after replay)
pub fn init(
    disk_start: u32,
    max_blocks: u32,
    first_block: u32,
    sequence: u32,
    block_size: u32,
) void {
    journal_state = .{
        .active = true,
        .write_pos = first_block,
        .sequence = sequence,
        .first_block = first_block,
        .max_blocks = max_blocks,
        .disk_start_block = disk_start,
        .block_size = block_size,
        .max_tx_blocks = @min(max_blocks / 4, MAX_TX_ENTRIES),
    };
}

/// Start a new transaction
/// nblocks: maximum metadata blocks this transaction will journal
/// Returns a handle to pass to writeBlock() and stop()
pub fn start(nblocks: u32) !*types.TransactionHandle {
    // Check journal has enough space
    // Initialize handle with current sequence
    // Increment sequence
    // Return handle
}

/// Queue a metadata block for journaling
/// The block data is COPIED into the journal buffer — caller can modify their copy freely
/// Does NOT write to disk yet
pub fn writeBlock(
    handle: *types.TransactionHandle,
    data: [*]const u8,
    fs_block_number: u32,
) !void {
    // Copy data into tx_buffers[handle.block_count]
    // Record fs_block_number in handle.block_numbers
    // Increment handle.block_count
}

/// Commit the transaction
/// This is the critical section — after this returns, the metadata is recoverable
///
/// Steps:
/// 1. Write DESCRIPTOR block to journal (lists all fs_block_numbers as tags)
/// 2. Write each data block to journal (in order, after descriptor)
/// 3. Write COMMIT block to journal
/// 4. fsync/flush journal to disk
/// 5. Write actual metadata blocks to their real filesystem locations
/// 6. fsync/flush filesystem blocks
///
/// Ordering guarantee (ordered mode):
///   Journal write → journal flush → fs write → fs flush
///   If crash after journal flush but before fs flush:
///     Replay will write the blocks from journal → filesystem (correct)
///   If crash before journal flush:
///     Transaction is incomplete → skip on replay (also correct, operation "didn't happen")
///
pub fn stop(handle: *types.TransactionHandle) !void {
    if (handle.block_count == 0) {
        handle.active = false;
        return; // Nothing to journal
    }
    
    // 1. Build and write DESCRIPTOR block
    //    - Block header: magic, type=DESCRIPTOR, sequence=handle.sequence
    //    - Tags: one BlockTag per queued block
    //    - Last tag has FLAG_LAST_TAG set
    //    - If any data block starts with JBD2_MAGIC: set FLAG_ESCAPE, zero the magic in copy
    
    // 2. Write data blocks to journal
    //    - One journal block per queued metadata block
    //    - Order must match tag order in descriptor
    
    // 3. Write COMMIT block
    //    - Block header: magic, type=COMMIT, sequence=handle.sequence
    
    // 4. Sync journal (ensure all journal blocks on disk)
    
    // 5. Write metadata to real filesystem locations
    //    - For each (fs_block_number, data) pair: blockWrite(fs_block_number, data)
    
    // 6. Sync filesystem
    
    // 7. Advance journal write position
    journal_state.advance(handle.block_count + 2); // +2 for descriptor + commit
    
    handle.active = false;
}

/// Write a REVOKE record
/// Used when freeing a block — ensures stale journal entries for this block aren't replayed
pub fn revoke(fs_block_number: u32) !void {
    // Write a REVOKE block to the journal containing this block number
    // This prevents old transaction entries from overwriting the freed block
    // if it gets reallocated to a different file
}

/// Flush journal and mark clean (for unmount)
pub fn shutdown() void {
    // If any pending transaction: commit it
    // Write journal superblock with sequence = 0 (clean marker)
    // Sync to disk
    journal_state.active = false;
}

/// Check if journal is active
pub fn isActive() bool {
    return journal_state.active;
}
```

### Integration with ext2.zig

The existing ext2.zig has write functions that call `blockWrite()` directly. With journaling, these calls need to be wrapped:

**Before (ext2 — no journaling):**
```zig
fn ext2AllocBlock(bg: u32) !u32 {
    // ... find free bit in bitmap ...
    bitmap[byte] |= mask;
    blockWrite(bitmap_block, &bitmap_buf);  // Direct write
    // ... update block group descriptor ...
    blockWrite(bgd_block, &bgd_buf);        // Direct write
    return block_number;
}
```

**After (ext3 — journaled):**
```zig
fn ext2AllocBlock(bg: u32) !u32 {
    // ... find free bit in bitmap ...
    bitmap[byte] |= mask;
    
    if (journal.isActive()) {
        var handle = try journal.start(2);  // 2 metadata blocks
        try journal.writeBlock(handle, &bitmap_buf, bitmap_block);
        try journal.writeBlock(handle, &bgd_buf, bgd_block);
        try journal.stop(handle);
    } else {
        blockWrite(bitmap_block, &bitmap_buf);
        blockWrite(bgd_block, &bgd_buf);
    }
    return block_number;
}
```

The `isActive()` check means ext2 images (no journal) still work with zero overhead.

### Functions that need journal wrapping in ext2.zig:
- `ext2AllocBlock()` — 2 blocks (bitmap + BGD)
- `ext2FreeBlock()` — 2 blocks (bitmap + BGD) + revoke
- `ext2AllocInode()` — 2 blocks (bitmap + BGD)
- `ext2FreeInode()` — 2 blocks (bitmap + BGD)
- `ext2WriteInode()` — 1 block (inode table block)
- `ext2AddDirEntry()` — 1-2 blocks (directory block + possibly new block)
- `ext2RemoveDirEntry()` — 1 block (directory block)

---

## §J4: ext3 Mount Integration

**File:** `ext3_mount.zig`  
**Lines:** ~120  
**Dependencies:** J2 (replay), J3 (journal write path)

### What to implement

Wire journaling into the kernel's mount/unmount path.

```zig
const types = @import("journal_types.zig");
const journal = @import("journal.zig");
const replay = @import("journal_replay.zig");

/// Feature flag for ext3 journal
const HAS_JOURNAL: u32 = 0x0004;
const JOURNAL_INO: u32 = 8;

/// Check if filesystem has journal and initialize it
/// Called from the main ext2 mount path after superblock is read
pub fn initJournal(superblock: *const Ext2Superblock) !void {
    // 1. Check s_feature_compat & HAS_JOURNAL
    //    If not set: return (mount as plain ext2)
    
    // 2. Read inode 8 (JOURNAL_INO)
    //    The journal lives in this inode's data blocks
    //    Walk the inode's block map to find where the journal is on disk
    //    Set disk_start_block = first block of inode 8's data
    
    // 3. Read journal superblock (first block of journal)
    //    Verify magic == JBD2_MAGIC
    //    Get: maxlen, first, sequence, blocksize
    
    // 4. Check if journal is dirty (sequence != 0)
    //    If dirty: call replay.replayJournal()
    //    Log: "ext3: replaying journal (N transactions)"
    
    // 5. Initialize journal write path
    //    journal.init(disk_start, maxlen, first, next_sequence, block_size)
    
    // 6. Log: "ext3: journal initialized (M blocks)"
}

/// Clean shutdown — called on unmount
pub fn shutdownJournal() void {
    if (journal.isActive()) {
        journal.shutdown();
        // Log: "ext3: journal flushed, clean unmount"
    }
}

/// Integration point: called from ext2.zig mount function
/// Add to the end of the existing ext2Mount():
///   try ext3_mount.initJournal(&superblock);
///
/// Integration point: called from ext2.zig unmount function  
/// Add at the start of ext2Unmount():
///   ext3_mount.shutdownJournal();
```

### Superblock fields used:
```
s_feature_compat (offset 0x5C): check bit 0x0004 (HAS_JOURNAL)
s_journal_inum (offset 0xE0): should be 8
s_journal_uuid (offset 0xD0): 16-byte UUID (for multi-device journals, usually zero)
s_last_orphan (offset 0xE8): linked list of orphan inodes (deleted files with open handles)
```

### Verification

1. Create ext3 image: `mkfs.ext3 -b 4096 test.img`
2. Mount in Zigix → verify "ext3: journal initialized" message
3. Create ext3 image, write files, simulate crash → verify replay message on next mount
4. Create ext2 image (no journal) → verify it mounts without journal messages (backward compat)
