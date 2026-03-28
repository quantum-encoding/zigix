/// ext3 mount integration — wires journaling into the mount/unmount path.
///
/// Called from the main ext2 mount function after superblock is read.
/// Detects journal feature flag, reads inode 8, initializes journal state,
/// and triggers replay if needed.
///
/// Freestanding — no std, no libc. Uses block_io abstraction for disk I/O.

const types = @import("journal_types.zig");
const journal = @import("journal.zig");
const replay = @import("journal_replay.zig");
const bio = @import("block_io.zig");

/// ext3 feature flag: has journal.
const HAS_JOURNAL: u32 = 0x0004;

/// ext3 incompat flag: journal needs recovery.
const INCOMPAT_RECOVER: u32 = 0x0004;

/// Block buffer for reading journal superblock and inode 8.
var mount_buf: [4096]u8 = undefined;

// ── Block I/O ──────────────────────────────────────────────────────────

fn readDiskBlock(block_num: u64, block_size: u32, buf: [*]u8) bool {
    const sectors_per_block = block_size / 512;
    const sector = block_num * sectors_per_block;
    return bio.readSectors(sector, sectors_per_block, buf);
}

fn readU32LE(buf: [*]const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

/// Read a big-endian u32 from a byte buffer (JBD2 on-disk format).
fn readU32BE(buf: [*]const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) |
        (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) |
        @as(u32, buf[off + 3]);
}

// ── Public API ─────────────────────────────────────────────────────────

/// Check if filesystem has journal and initialize it.
/// Called from the main ext2 mount path after superblock is read.
///
/// Parameters:
///   feature_compat:    superblock s_feature_compat field
///   feature_incompat:  superblock s_feature_incompat field
///   journal_inum:      superblock s_journal_inum (should be 8)
///   block_size:        filesystem block size
///   inode_size:        on-disk inode size (128 or 256)
///   inodes_per_group:  from superblock
///   inode_table_block: inode table start block from BGD containing inode 8
///
/// Returns true if journal was initialized (or not needed), false on error.
pub fn initJournal(
    feature_compat: u32,
    feature_incompat: u32,
    journal_inum: u32,
    block_size: u32,
    inode_size: u16,
    inodes_per_group: u32,
    inode_table_block: u64,
) bool {
    // 1. Check if filesystem has journal
    if (feature_compat & HAS_JOURNAL == 0) {
        bio.log("[ext2] No journal (plain ext2)\n");
        return true; // Mount as plain ext2
    }

    const inum = if (journal_inum != 0) journal_inum else types.JOURNAL_INO;
    bio.log("[ext3] Journal detected (inode ");
    bio.logDec(inum);
    bio.log(")\n");

    // 2. Read inode to find where the journal lives on disk.
    //    Inode 8 is in block group 0 (inode numbers 1-based, group 0).
    //    Offset within inode table: (inum - 1) * inode_size
    _ = inodes_per_group;
    const inode_offset_in_table = @as(u64, inum - 1) * @as(u64, inode_size);
    const inode_block = inode_table_block + inode_offset_in_table / block_size;
    const inode_offset_in_block = @as(usize, @truncate(inode_offset_in_table % block_size));

    if (!readDiskBlock(inode_block, block_size, &mount_buf)) {
        bio.log("[ext3] Failed to read journal inode\n");
        return false;
    }

    // Read first direct block pointer from inode (offset 0x28 = i_block[0], little-endian)
    const inode_ptr = @as([*]const u8, &mount_buf) + inode_offset_in_block;
    const journal_start_block = readU32LE(inode_ptr, 0x28); // i_block[0]

    if (journal_start_block == 0) {
        bio.log("[ext3] Journal inode has no blocks\n");
        return false;
    }

    // Read journal size from inode (i_blocks at offset 0x1C, little-endian ext2 field)
    const journal_i_blocks = readU32LE(inode_ptr, 0x1C); // i_blocks (512-byte sectors)
    const journal_blocks = journal_i_blocks / (block_size / 512);

    bio.log("[ext3] Journal at block ");
    bio.logDec(journal_start_block);
    bio.log(", ");
    bio.logDec(journal_blocks);
    bio.log(" blocks\n");

    // 3. Read journal superblock (first block of journal)
    //    JBD2 on-disk format is BIG-ENDIAN
    if (!readDiskBlock(@as(u64, journal_start_block), block_size, &mount_buf)) {
        bio.log("[ext3] Failed to read journal superblock\n");
        return false;
    }

    // Read JBD2 fields as big-endian
    const jsb_magic = readU32BE(&mount_buf, 0x00);
    const jsb_blocktype = readU32BE(&mount_buf, 0x04);
    const jsb_sequence = readU32BE(&mount_buf, 0x08);
    const jsb_blocksize = readU32BE(&mount_buf, 0x0C);
    const jsb_maxlen = readU32BE(&mount_buf, 0x10);
    const jsb_first = readU32BE(&mount_buf, 0x14);

    _ = jsb_blocksize;

    // Validate magic
    if (jsb_magic != types.JBD2_MAGIC) {
        bio.log("[ext3] Invalid journal superblock (magic=0x");
        bio.logHex(jsb_magic);
        bio.log(", expected=0x");
        bio.logHex(types.JBD2_MAGIC);
        bio.log(")\n");
        return false;
    }

    // Validate type (V1 or V2)
    if (jsb_blocktype != types.BLOCKTYPE_SUPERBLOCK_V1 and jsb_blocktype != types.BLOCKTYPE_SUPERBLOCK_V2) {
        bio.log("[ext3] Invalid journal superblock type (");
        bio.logDec(jsb_blocktype);
        bio.log(")\n");
        return false;
    }

    bio.log("[ext3] Journal superblock: maxlen=");
    bio.logDec(jsb_maxlen);
    bio.log(", first=");
    bio.logDec(jsb_first);
    bio.log(", seq=");
    bio.logDec(jsb_sequence);
    bio.log("\n");

    // 4. Check if journal is dirty and needs replay
    //    Clean journal has sequence == 0 after proper unmount
    const is_dirty = jsb_sequence != 0;
    if (is_dirty or (feature_incompat & INCOMPAT_RECOVER != 0)) {
        bio.log("[ext3] Journal is dirty — replaying...\n");

        var replay_state = types.JournalState{
            .active = false,
            .write_pos = jsb_first,
            .sequence = jsb_sequence,
            .first_block = jsb_first,
            .max_blocks = jsb_maxlen,
            .disk_start_block = @as(u64, journal_start_block),
            .block_size = block_size,
        };

        const result = replay.replayJournal(&replay_state);
        bio.log("[ext3] Replay complete: ");
        bio.logDec(result.transactions_replayed);
        bio.log(" tx, ");
        bio.logDec(result.blocks_replayed);
        bio.log(" blocks, ");
        bio.logDec(result.errors);
        bio.log(" errors\n");
    }

    // 5. Initialize journal write path
    const next_seq = if (is_dirty) jsb_sequence + 1 else 1;
    journal.init(
        @as(u64, journal_start_block),
        jsb_maxlen,
        jsb_first,
        next_seq,
        block_size,
    );

    bio.log("[ext3] Journal ready\n");
    return true;
}

/// Clean shutdown — called on unmount.
pub fn shutdownJournal() void {
    if (journal.isActive()) {
        journal.shutdown();
    }
}
