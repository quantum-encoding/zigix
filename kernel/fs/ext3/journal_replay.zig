/// Journal replay (recovery) — runs at mount time when journal is dirty.
///
/// Four-pass algorithm:
///   PASS 1 (SCAN):   Walk journal, find descriptors/commits/revokes, build transaction list.
///   PASS 2 (FILTER): Apply revoke table — remove superseded block writes.
///   PASS 3 (REPLAY): Write surviving journal blocks to their filesystem locations.
///   PASS 4 (CLEAR):  Zero journal superblock sequence to mark clean.
///
/// JBD2 on-disk format is BIG-ENDIAN for all journal metadata structures.
///
/// Freestanding — no std, no libc. Uses block_io abstraction for disk I/O.

const types = @import("journal_types.zig");
const bio = @import("block_io.zig");

/// Result of journal replay.
pub const ReplayResult = struct {
    transactions_found: u32 = 0,
    transactions_replayed: u32 = 0,
    blocks_replayed: u32 = 0,
    revoke_entries: u32 = 0,
    errors: u32 = 0,
};

// ── Internal data structures for replay ────────────────────────────────

/// A single block write recorded from the journal.
const ReplayEntry = struct {
    sequence: u32,       // Transaction sequence that wrote this block
    fs_block: u32,       // Filesystem block number to write to
    journal_block: u32,  // Where the data lives in the journal
    escaped: bool,       // Needs JBD2_MAGIC restored at offset 0
    valid: bool,         // Not revoked
};

/// Revoke table entry.
const RevokeEntry = struct {
    fs_block: u32,
    sequence: u32,  // Transaction that revoked this block
    used: bool,
};

const MAX_REPLAY_ENTRIES: usize = 512;
const MAX_REVOKE_ENTRIES: usize = 128;

var replay_entries: [MAX_REPLAY_ENTRIES]ReplayEntry = undefined;
var replay_count: u32 = 0;

var revoke_table: [MAX_REVOKE_ENTRIES]RevokeEntry = undefined;
var revoke_count: u32 = 0;

/// Temporary block buffer for reading journal blocks.
var block_buf: [4096]u8 = undefined;

// ── Block I/O wrappers ─────────────────────────────────────────────────

fn readDiskBlock(block_num: u64, block_size: u32, buf: [*]u8) bool {
    const sectors_per_block = block_size / 512;
    const sector = block_num * sectors_per_block;
    return bio.readSectors(sector, sectors_per_block, buf);
}

fn writeDiskBlock(block_num: u64, block_size: u32, buf: [*]const u8) bool {
    const sectors_per_block = block_size / 512;
    const sector = block_num * sectors_per_block;
    return bio.writeSectors(sector, sectors_per_block, buf);
}

/// Read a big-endian u32 from a byte buffer (JBD2 on-disk format).
fn readU32BE(buf: [*]const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) |
        (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) |
        @as(u32, buf[off + 3]);
}

/// Read a big-endian u16 from a byte buffer.
fn readU16BE(buf: [*]const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | @as(u16, buf[off + 1]);
}

// ── Replay implementation ──────────────────────────────────────────────

/// Main entry point: replay the journal.
/// Called from ext3_mount.zig when the journal superblock indicates dirty state.
pub fn replayJournal(state: *const types.JournalState) ReplayResult {
    var result = ReplayResult{};
    replay_count = 0;
    revoke_count = 0;

    bio.log("[ext3] Journal replay starting (first_block=");
    bio.logDec(state.first_block);
    bio.log(", max_blocks=");
    bio.logDec(state.max_blocks);
    bio.log(")\n");

    // PASS 1: SCAN — walk journal, build transaction list
    pass1_scan(state, &result);

    bio.log("[ext3]   Pass 1: found ");
    bio.logDec(result.transactions_found);
    bio.log(" transactions, ");
    bio.logDec(replay_count);
    bio.log(" blocks, ");
    bio.logDec(revoke_count);
    bio.log(" revokes\n");

    // PASS 2: FILTER — apply revoke table
    pass2_filter(&result);

    // Count surviving entries
    var surviving: u32 = 0;
    for (0..replay_count) |i| {
        if (replay_entries[i].valid) surviving += 1;
    }

    bio.log("[ext3]   Pass 2: ");
    bio.logDec(surviving);
    bio.log(" blocks surviving after revoke filter\n");

    // PASS 3: REPLAY — write blocks to filesystem
    pass3_replay(state, &result);

    bio.log("[ext3]   Pass 3: replayed ");
    bio.logDec(result.blocks_replayed);
    bio.log(" blocks\n");

    // PASS 4: CLEAR — mark journal clean
    pass4_clear(state, &result);

    bio.log("[ext3] Journal replay complete (");
    bio.logDec(result.transactions_replayed);
    bio.log(" transactions, ");
    bio.logDec(result.blocks_replayed);
    bio.log(" blocks)\n");

    return result;
}

/// PASS 1: Scan journal from first_block forward.
/// Reads each block header, processes descriptors/commits/revokes.
/// All JBD2 fields are read as big-endian.
fn pass1_scan(state: *const types.JournalState, result: *ReplayResult) void {
    var pos: u32 = state.first_block;
    var expected_seq: u32 = state.sequence;
    var blocks_scanned: u32 = 0;

    while (blocks_scanned < state.max_blocks) {
        const disk_block = state.journalToDisk(pos);

        if (!readDiskBlock(disk_block, state.block_size, &block_buf)) {
            result.errors += 1;
            break;
        }

        // Read block header fields as big-endian
        const hdr_magic = readU32BE(&block_buf, 0);
        const hdr_blocktype = readU32BE(&block_buf, 4);
        const hdr_sequence = readU32BE(&block_buf, 8);

        // Stop if magic doesn't match — end of journal
        if (hdr_magic != types.JBD2_MAGIC) break;

        if (hdr_blocktype == types.BLOCKTYPE_DESCRIPTOR) {
            // Parse tags from descriptor block (big-endian)
            const tag_start: usize = 12; // @sizeOf(BlockHeader)
            var tag_offset: usize = tag_start;
            var data_block_pos: u32 = state.nextBlock(pos);

            while (tag_offset + 8 <= state.block_size) { // 8 = @sizeOf(BlockTag)
                // Read tag fields as big-endian
                const tag_blocknr = readU32BE(&block_buf, tag_offset);
                const tag_flags = readU16BE(&block_buf, tag_offset + 4);

                const is_deleted = tag_flags & types.FLAG_DELETED != 0;
                const is_escaped = tag_flags & types.FLAG_ESCAPE != 0;
                const is_last = tag_flags & types.FLAG_LAST_TAG != 0;

                if (!is_deleted and replay_count < MAX_REPLAY_ENTRIES) {
                    replay_entries[replay_count] = .{
                        .sequence = hdr_sequence,
                        .fs_block = tag_blocknr,
                        .journal_block = data_block_pos,
                        .escaped = is_escaped,
                        .valid = false, // Marked valid only when commit is found
                    };
                    replay_count += 1;
                }

                data_block_pos = state.nextBlock(data_block_pos);
                blocks_scanned += 1;

                if (is_last) break;
                tag_offset += 8;
            }

            // Skip past data blocks to next journal metadata block
            pos = data_block_pos;
            blocks_scanned += 1;
            continue;
        } else if (hdr_blocktype == types.BLOCKTYPE_COMMIT) {
            // Mark all entries with this sequence as committed (valid)
            if (hdr_sequence == expected_seq) {
                for (0..replay_count) |i| {
                    if (replay_entries[i].sequence == hdr_sequence) {
                        replay_entries[i].valid = true;
                    }
                }
                result.transactions_found += 1;
                expected_seq += 1;
            } else {
                // Sequence mismatch — stop scanning
                break;
            }
        } else if (hdr_blocktype == types.BLOCKTYPE_REVOKE) {
            // Parse revoked block numbers (big-endian)
            const revoke_count_field = readU32BE(&block_buf, 12); // count field
            const data_bytes = revoke_count_field - 16; // subtract revoke header size
            const num_entries = data_bytes / 4;

            var off: usize = 16; // after revoke header
            for (0..num_entries) |_| {
                if (off + 4 > state.block_size) break;
                if (revoke_count < MAX_REVOKE_ENTRIES) {
                    const fs_block = readU32BE(&block_buf, off);
                    revoke_table[revoke_count] = .{
                        .fs_block = fs_block,
                        .sequence = hdr_sequence,
                        .used = true,
                    };
                    revoke_count += 1;
                    result.revoke_entries += 1;
                }
                off += 4;
            }
        }

        pos = state.nextBlock(pos);
        blocks_scanned += 1;
    }
}

/// PASS 2: Apply revoke table — invalidate replay entries superseded by revokes.
fn pass2_filter(result: *ReplayResult) void {
    _ = result;
    for (0..replay_count) |i| {
        if (!replay_entries[i].valid) continue;

        for (0..revoke_count) |r| {
            if (!revoke_table[r].used) continue;

            if (revoke_table[r].fs_block == replay_entries[i].fs_block and
                revoke_table[r].sequence >= replay_entries[i].sequence)
            {
                replay_entries[i].valid = false;
                break;
            }
        }
    }
}

/// PASS 3: Replay surviving entries — read journal data, write to FS.
fn pass3_replay(state: *const types.JournalState, result: *ReplayResult) void {
    // Replay oldest transactions first (they're already in order from scan)
    for (0..replay_count) |i| {
        if (!replay_entries[i].valid) continue;

        const entry = &replay_entries[i];
        const journal_disk = state.journalToDisk(entry.journal_block);

        // Read data block from journal
        var data_buf: [4096]u8 = undefined;
        if (!readDiskBlock(journal_disk, state.block_size, &data_buf)) {
            result.errors += 1;
            continue;
        }

        // Restore escaped magic if needed (big-endian byte order: C0 3B 39 98)
        if (entry.escaped) {
            data_buf[0] = @truncate(types.JBD2_MAGIC >> 24);
            data_buf[1] = @truncate(types.JBD2_MAGIC >> 16);
            data_buf[2] = @truncate(types.JBD2_MAGIC >> 8);
            data_buf[3] = @truncate(types.JBD2_MAGIC);
        }

        // Write to filesystem block
        if (writeDiskBlock(@as(u64, entry.fs_block), state.block_size, &data_buf)) {
            result.blocks_replayed += 1;
        } else {
            result.errors += 1;
        }
    }

    result.transactions_replayed = result.transactions_found;
}

/// PASS 4: Clear journal — write superblock with sequence=0.
fn pass4_clear(state: *const types.JournalState, result: *ReplayResult) void {
    const jsb_disk = state.journalToDisk(0);

    if (!readDiskBlock(jsb_disk, state.block_size, &block_buf)) {
        result.errors += 1;
        return;
    }

    // Zero the sequence field (offset 0x08) to mark clean
    // (zeroing works regardless of endianness)
    block_buf[0x08] = 0;
    block_buf[0x09] = 0;
    block_buf[0x0A] = 0;
    block_buf[0x0B] = 0;

    // Also clear errno (offset 0x18)
    block_buf[0x18] = 0;
    block_buf[0x19] = 0;
    block_buf[0x1A] = 0;
    block_buf[0x1B] = 0;

    if (!writeDiskBlock(jsb_disk, state.block_size, &block_buf)) {
        result.errors += 1;
    }
}
