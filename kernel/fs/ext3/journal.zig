/// Journal write path — transactional metadata writes for ext3/ext4.
///
/// Every metadata operation (alloc block, write inode, add dir entry) goes
/// through a transaction: start → writeBlock (×N) → stop.
///
/// Implements "ordered" journaling mode (default):
///   1. Write data blocks to final locations first
///   2. Write metadata to journal (descriptor + data + commit)
///   3. Sync journal
///   4. Write metadata to final locations
///   5. Sync filesystem
///
/// JBD2 on-disk format is BIG-ENDIAN for all journal metadata structures.
/// Filesystem metadata blocks (bitmap, BGD, inode table) remain little-endian.
///
/// Freestanding — no std, no libc. Uses block_io abstraction for disk I/O.

const types = @import("journal_types.zig");
const bio = @import("block_io.zig");

/// Global journal state.
var state: types.JournalState = .{};

/// Transaction buffer pool — stores metadata block copies during a transaction.
var tx_buffers: [types.MAX_TX_ENTRIES][4096]u8 = undefined;

/// Current active transaction handle (one at a time in our single-threaded kernel).
var current_handle: types.TransactionHandle = .{};

/// Temporary buffer for building journal descriptor/commit blocks.
var journal_build_buf: [4096]u8 = undefined;

// ── Block I/O ──────────────────────────────────────────────────────────

fn readDiskBlock(block_num: u64, buf: [*]u8) bool {
    const sectors_per_block = state.block_size / 512;
    const sector = block_num * sectors_per_block;
    return bio.readSectors(sector, sectors_per_block, buf);
}

fn writeDiskBlock(block_num: u64, buf: [*]const u8) bool {
    const sectors_per_block = state.block_size / 512;
    const sector = block_num * sectors_per_block;
    return bio.writeSectors(sector, sectors_per_block, buf);
}

// ── Public API ─────────────────────────────────────────────────────────

/// Initialize journal (called from ext3_mount after replay).
pub fn init(
    disk_start: u64,
    max_blocks: u32,
    first_block: u32,
    sequence: u32,
    block_size: u32,
) void {
    state = .{
        .active = true,
        .write_pos = first_block,
        .sequence = sequence,
        .first_block = first_block,
        .max_blocks = max_blocks,
        .disk_start_block = disk_start,
        .block_size = block_size,
        .max_tx_blocks = @min(max_blocks / 4, types.MAX_TX_ENTRIES),
    };

    bio.log("[ext3] Journal initialized: start=");
    bio.logDec(disk_start);
    bio.log(", max=");
    bio.logDec(max_blocks);
    bio.log(", seq=");
    bio.logDec(sequence);
    bio.log(", bs=");
    bio.logDec(block_size);
    bio.log("\n");
}

/// Start a new transaction.
/// nblocks: maximum metadata blocks this transaction will journal.
/// Returns true if transaction started successfully.
pub fn start(nblocks: u32) bool {
    if (!state.active) return false;
    if (current_handle.active) return false; // Only one transaction at a time
    if (nblocks > state.max_tx_blocks) return false;

    // Check journal has enough free space (nblocks + 2 for descriptor + commit)
    const needed = nblocks + 2;
    if (needed > state.freeSpace()) return false;

    current_handle = .{
        .sequence = state.sequence,
        .reserved_blocks = nblocks,
        .block_count = 0,
        .block_numbers = [_]u32{0} ** types.MAX_TX_ENTRIES,
        .active = true,
    };

    state.sequence += 1;
    return true;
}

/// Queue a metadata block for journaling.
/// The block data is COPIED into the journal buffer — caller can modify their copy freely.
/// Does NOT write to disk yet.
pub fn writeBlock(data: [*]const u8, fs_block_number: u32) bool {
    if (!current_handle.active) return false;
    if (current_handle.block_count >= types.MAX_TX_ENTRIES) return false;

    // Copy block data into transaction buffer
    const idx = current_handle.block_count;
    for (0..state.block_size) |i| {
        tx_buffers[idx][i] = data[i];
    }

    if (!current_handle.addBlock(fs_block_number)) return false;
    return true;
}

/// Commit the transaction — write journal, then write real blocks.
/// This is the critical section. After this returns, the metadata is recoverable.
pub fn stop() bool {
    if (!current_handle.active) return false;

    if (current_handle.block_count == 0) {
        current_handle.active = false;
        return true; // Nothing to journal
    }

    // 1. Write DESCRIPTOR block to journal
    if (!writeDescriptorBlock()) {
        current_handle.active = false;
        return false;
    }

    // 2. Write data blocks to journal
    // Track which blocks had their magic escaped (need restore for real FS write)
    var escaped: [types.MAX_TX_ENTRIES]bool = [_]bool{false} ** types.MAX_TX_ENTRIES;

    for (0..current_handle.block_count) |i| {
        const journal_pos = state.write_pos;
        const disk_block = state.journalToDisk(journal_pos);

        // Check if block data starts with JBD2_MAGIC in big-endian byte order
        // (the bytes C0 3B 39 98 which would confuse the replay scanner)
        var buf = &tx_buffers[i];
        const first4_be = (@as(u32, buf[0]) << 24) |
            (@as(u32, buf[1]) << 16) |
            (@as(u32, buf[2]) << 8) |
            @as(u32, buf[3]);

        if (first4_be == types.JBD2_MAGIC) {
            // Zero the magic bytes in the journal copy (will be restored on replay)
            buf[0] = 0;
            buf[1] = 0;
            buf[2] = 0;
            buf[3] = 0;
            escaped[i] = true;
        }

        if (!writeDiskBlock(disk_block, buf)) {
            current_handle.active = false;
            return false;
        }

        state.write_pos = state.nextBlock(state.write_pos);
    }

    // 3. Write COMMIT block
    if (!writeCommitBlock()) {
        current_handle.active = false;
        return false;
    }

    // 4. Write metadata to real filesystem locations
    // Note: QEMU polled VirtIO I/O is synchronous — writes complete in order,
    // so no explicit flush/barrier between journal commit and filesystem writes.
    // Real hardware would need VIRTIO_BLK_T_FLUSH here.
    for (0..current_handle.block_count) |i| {
        const fs_block = current_handle.block_numbers[i];

        // Restore magic bytes if they were escaped for the journal copy
        // (restore big-endian byte order: C0 3B 39 98)
        if (escaped[i]) {
            tx_buffers[i][0] = @truncate(types.JBD2_MAGIC >> 24);
            tx_buffers[i][1] = @truncate(types.JBD2_MAGIC >> 16);
            tx_buffers[i][2] = @truncate(types.JBD2_MAGIC >> 8);
            tx_buffers[i][3] = @truncate(types.JBD2_MAGIC);
        }

        _ = writeDiskBlock(@as(u64, fs_block), &tx_buffers[i]);
    }

    current_handle.active = false;
    return true;
}

/// Write a REVOKE record to prevent stale replays of freed blocks.
pub fn revoke(fs_block_number: u32) bool {
    if (!state.active) return false;

    // Build revoke block (JBD2 format = big-endian)
    for (0..state.block_size) |i| {
        journal_build_buf[i] = 0;
    }

    // Block header (big-endian)
    writeU32BE(&journal_build_buf, 0, types.JBD2_MAGIC);
    writeU32BE(&journal_build_buf, 4, types.BLOCKTYPE_REVOKE);
    writeU32BE(&journal_build_buf, 8, state.sequence);

    // Revoke header: count = header_size(16) + 4 bytes per block (big-endian)
    writeU32BE(&journal_build_buf, 12, 16 + 4);

    // The revoked block number (big-endian)
    writeU32BE(&journal_build_buf, 16, fs_block_number);

    // Write to journal
    const disk_block = state.journalToDisk(state.write_pos);
    if (!writeDiskBlock(disk_block, &journal_build_buf)) return false;

    state.write_pos = state.nextBlock(state.write_pos);
    return true;
}

/// Flush journal and mark clean (for unmount).
pub fn shutdown() void {
    if (!state.active) return;

    // If any pending transaction, commit it
    if (current_handle.active) {
        _ = stop();
    }

    // Write journal superblock with sequence = 0 (clean marker)
    // Sequence is at offset 0x08 in big-endian — zeroing 4 bytes works either way
    var jsb_buf: [4096]u8 = undefined;
    const jsb_disk = state.journalToDisk(0);

    if (readDiskBlock(jsb_disk, &jsb_buf)) {
        // Zero the sequence field at offset 0x08
        jsb_buf[0x08] = 0;
        jsb_buf[0x09] = 0;
        jsb_buf[0x0A] = 0;
        jsb_buf[0x0B] = 0;

        _ = writeDiskBlock(jsb_disk, &jsb_buf);
    }

    state.active = false;
    bio.log("[ext3] Journal flushed, clean unmount\n");
}

/// Check if journal is active.
pub fn isActive() bool {
    return state.active;
}

/// Get current journal state (read-only, for mount integration).
pub fn getState() *const types.JournalState {
    return &state;
}

// ── Internal helpers ───────────────────────────────────────────────────

fn writeDescriptorBlock() bool {
    for (0..state.block_size) |i| {
        journal_build_buf[i] = 0;
    }

    // Block header (big-endian)
    writeU32BE(&journal_build_buf, 0, types.JBD2_MAGIC);
    writeU32BE(&journal_build_buf, 4, types.BLOCKTYPE_DESCRIPTOR);
    writeU32BE(&journal_build_buf, 8, current_handle.sequence);

    // Tags — one per queued block (big-endian)
    var offset: usize = @sizeOf(types.BlockHeader); // 12
    for (0..current_handle.block_count) |i| {
        if (offset + @sizeOf(types.BlockTag) > state.block_size) break;

        // blocknr (big-endian)
        writeU32BE(&journal_build_buf, @truncate(offset), current_handle.block_numbers[i]);

        // flags
        var flags: u16 = 0;
        if (i == current_handle.block_count - 1) {
            flags |= types.FLAG_LAST_TAG;
        }

        // Check if data starts with JBD2_MAGIC (big-endian byte order)
        const first4_be = (@as(u32, tx_buffers[i][0]) << 24) |
            (@as(u32, tx_buffers[i][1]) << 16) |
            (@as(u32, tx_buffers[i][2]) << 8) |
            @as(u32, tx_buffers[i][3]);
        if (first4_be == types.JBD2_MAGIC) {
            flags |= types.FLAG_ESCAPE;
        }

        writeU16BE(&journal_build_buf, @truncate(offset + 4), flags);
        // checksum field (unused for V2)
        writeU16BE(&journal_build_buf, @truncate(offset + 6), 0);

        offset += @sizeOf(types.BlockTag);
    }

    // Write descriptor to journal
    const disk_block = state.journalToDisk(state.write_pos);
    if (!writeDiskBlock(disk_block, &journal_build_buf)) return false;

    state.write_pos = state.nextBlock(state.write_pos);
    return true;
}

fn writeCommitBlock() bool {
    for (0..state.block_size) |i| {
        journal_build_buf[i] = 0;
    }

    // Block header (big-endian)
    writeU32BE(&journal_build_buf, 0, types.JBD2_MAGIC);
    writeU32BE(&journal_build_buf, 4, types.BLOCKTYPE_COMMIT);
    writeU32BE(&journal_build_buf, 8, current_handle.sequence);

    const disk_block = state.journalToDisk(state.write_pos);
    if (!writeDiskBlock(disk_block, &journal_build_buf)) return false;

    state.write_pos = state.nextBlock(state.write_pos);
    return true;
}

/// Write a big-endian u32 to a byte buffer (JBD2 on-disk format).
fn writeU32BE(buf: [*]u8, offset: usize, val: u32) void {
    buf[offset] = @truncate(val >> 24);
    buf[offset + 1] = @truncate(val >> 16);
    buf[offset + 2] = @truncate(val >> 8);
    buf[offset + 3] = @truncate(val);
}

/// Write a big-endian u16 to a byte buffer (JBD2 on-disk format).
fn writeU16BE(buf: [*]u8, offset: usize, val: u16) void {
    buf[offset] = @truncate(val >> 8);
    buf[offset + 1] = @truncate(val);
}
