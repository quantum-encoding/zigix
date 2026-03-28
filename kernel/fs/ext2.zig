/// ext2 filesystem driver — read-write (write-through).
/// Parses superblock, reads/writes inodes, follows block pointers, traverses directories.
/// Integrates with VFS via FileOperations vtable: read, write, create, unlink, truncate.

const vfs = @import("vfs.zig");
const serial = @import("../arch/x86_64/serial.zig");
const scheduler = @import("../proc/scheduler.zig");
const ext3_mount = @import("ext3/ext3_mount.zig");
const journal_mod = @import("ext3/journal.zig");
const block_io = @import("ext3/block_io.zig");
const extents = @import("ext4/extents.zig");
const htree = @import("ext4/htree.zig");
const inode_ext4 = @import("ext4/inode_ext4.zig");
const mballoc = @import("ext4/mballoc.zig");
const block_group_64 = @import("ext4/block_group_64.zig");
const page_cache = @import("../mm/page_cache.zig");
const hhdm = @import("../mm/hhdm.zig");
const pmm = @import("../mm/pmm.zig");

// ---- ext2 on-disk structures ----

const Ext2Superblock = extern struct {
    s_inodes_count: u32,
    s_blocks_count: u32,
    s_r_blocks_count: u32,
    s_free_blocks_count: u32,
    s_free_inodes_count: u32,
    s_first_data_block: u32,
    s_log_block_size: u32, // block_size = 1024 << this
    s_log_frag_size: u32,
    s_blocks_per_group: u32,
    s_frags_per_group: u32,
    s_inodes_per_group: u32,
    s_mtime: u32,
    s_wtime: u32,
    s_mnt_count: u16,
    s_max_mnt_count: u16,
    s_magic: u16, // 0xEF53
    s_state: u16,
    s_errors: u16,
    s_minor_rev_level: u16,
    s_lastcheck: u32,
    s_checkinterval: u32,
    s_creator_os: u32,
    s_rev_level: u32,
    s_def_resuid: u16,
    s_def_resgid: u16,
    // Rev 1 fields
    s_first_ino: u32,
    s_inode_size: u16,
    s_block_group_nr: u16,
    s_feature_compat: u32,
    s_feature_incompat: u32,
    s_feature_ro_compat: u32,
    s_uuid: [16]u8,
    s_volume_name: [16]u8,
    s_last_mounted: [64]u8,
    s_algo_bitmap: u32,
    // Padding to fill rest of superblock (up to 1024 bytes)
    _padding: [820 - 204]u8,
};

const Ext2BlockGroupDesc = extern struct {
    bg_block_bitmap: u32,
    bg_inode_bitmap: u32,
    bg_inode_table: u32,
    bg_free_blocks_count: u16,
    bg_free_inodes_count: u16,
    bg_used_dirs_count: u16,
    bg_pad: u16,
    bg_reserved: [12]u8,
};

const Ext2DiskInode = extern struct {
    i_mode: u16,
    i_uid: u16,
    i_size: u32,
    i_atime: u32,
    i_ctime: u32,
    i_mtime: u32,
    i_dtime: u32,
    i_gid: u16,
    i_links_count: u16,
    i_blocks: u32, // count of 512-byte sectors
    i_flags: u32,
    i_osd1: u32,
    i_block: [15]u32, // 0-11 direct, 12 indirect, 13 double, 14 triple
    i_generation: u32,
    i_file_acl: u32,
    i_dir_acl: u32,
    i_faddr: u32,
    i_osd2: [12]u8,
};

// Directory entry header (name follows immediately after, variable length)
const EXT2_DIR_HEADER_SIZE: usize = 8;

const EXT2_SUPER_MAGIC: u16 = 0xEF53;
const EXT2_ROOT_INO: u32 = 2;

// ext2 file type constants (in directory entries)
const EXT2_FT_REG_FILE: u8 = 1;
const EXT2_FT_DIR: u8 = 2;
const EXT2_FT_SYMLINK: u8 = 7;

// ---- Block cache ----

const BLOCK_CACHE_SIZE: usize = 512;
const MAX_BLOCK_SIZE: usize = 4096;

const BlockCacheEntry = struct {
    block_num: u64,
    data: [MAX_BLOCK_SIZE]u8,
    valid: bool,
    dirty: bool,
    lru_prev: u16, // index into block_cache, 0xFFFF = none
    lru_next: u16, // index into block_cache, 0xFFFF = none
};

const LRU_NONE: u16 = 0xFFFF;

var block_cache: [BLOCK_CACHE_SIZE]BlockCacheEntry = init_block_cache();

// LRU doubly-linked list: head = MRU, tail = LRU
var lru_head: u16 = LRU_NONE;
var lru_tail: u16 = LRU_NONE;

fn init_block_cache() [BLOCK_CACHE_SIZE]BlockCacheEntry {
    var cache: [BLOCK_CACHE_SIZE]BlockCacheEntry = undefined;
    for (0..BLOCK_CACHE_SIZE) |i| {
        cache[i].valid = false;
        cache[i].dirty = false;
        cache[i].block_num = 0;
        cache[i].data = [_]u8{0} ** MAX_BLOCK_SIZE;
        cache[i].lru_prev = LRU_NONE;
        cache[i].lru_next = LRU_NONE;
    }
    return cache;
}

/// Remove entry from LRU list (internal helper).
fn lruRemove(idx: u16) void {
    const e = &block_cache[idx];
    if (e.lru_prev != LRU_NONE) {
        block_cache[e.lru_prev].lru_next = e.lru_next;
    } else if (lru_head == idx) {
        lru_head = e.lru_next;
    }
    if (e.lru_next != LRU_NONE) {
        block_cache[e.lru_next].lru_prev = e.lru_prev;
    } else if (lru_tail == idx) {
        lru_tail = e.lru_prev;
    }
    e.lru_prev = LRU_NONE;
    e.lru_next = LRU_NONE;
}

/// Move entry to MRU position (head of LRU list).
fn lruTouch(idx: u16) void {
    if (lru_head == idx) return; // already MRU
    lruRemove(idx);
    // Insert at head
    block_cache[idx].lru_prev = LRU_NONE;
    block_cache[idx].lru_next = lru_head;
    if (lru_head != LRU_NONE) {
        block_cache[lru_head].lru_prev = idx;
    }
    lru_head = idx;
    if (lru_tail == LRU_NONE) lru_tail = idx;
}

/// Flush a dirty cache entry to disk.
fn flushEntry(idx: usize) void {
    if (!block_cache[idx].valid or !block_cache[idx].dirty) return;
    const sectors_per_block = block_size / 512;
    const sector_start = block_cache[idx].block_num * sectors_per_block;
    _ = block_io.writeSectors(sector_start, @truncate(sectors_per_block), &block_cache[idx].data);
    block_cache[idx].dirty = false;
}

fn invalidateCache() void {
    // Flush dirty entries before invalidating
    for (0..BLOCK_CACHE_SIZE) |i| {
        flushEntry(i);
        block_cache[i].valid = false;
    }
    lru_head = LRU_NONE;
    lru_tail = LRU_NONE;
}

fn readBlock(block_num: u64) ?[*]u8 {
    const idx = @as(usize, @truncate(block_num % BLOCK_CACHE_SIZE));

    // Cache hit
    if (block_cache[idx].valid and block_cache[idx].block_num == block_num) {
        lruTouch(@truncate(idx));
        return &block_cache[idx].data;
    }

    // Cache miss — flush evicted entry if dirty
    if (block_cache[idx].valid and block_cache[idx].dirty) {
        flushEntry(idx);
    }

    // Read from disk
    const sectors_per_block = block_size / 512;
    const sector_start = block_num * sectors_per_block;

    if (!block_io.readSectors(sector_start, @truncate(sectors_per_block), &block_cache[idx].data)) {
        return null;
    }

    block_cache[idx].block_num = block_num;
    block_cache[idx].valid = true;
    block_cache[idx].dirty = false;
    lruTouch(@truncate(idx));
    return &block_cache[idx].data;
}

// ---- Block write ----

fn writeBlock(block_num: u64, data: [*]const u8) bool {
    if (journal_tx_active) {
        // Queue to journal — actual disk write happens at journal commit
        _ = journal_mod.writeBlock(data, @truncate(block_num));
    } else {
        // Direct disk write
        const sectors_per_block = block_size / 512;
        const sector_start = block_num * sectors_per_block;
        if (!block_io.writeSectors(sector_start, @truncate(sectors_per_block), data)) {
            return false;
        }
    }

    // Update cache entry (both paths)
    const idx = @as(usize, @truncate(block_num % BLOCK_CACHE_SIZE));
    for (0..block_size) |i| {
        block_cache[idx].data[i] = data[i];
    }
    block_cache[idx].block_num = block_num;
    block_cache[idx].valid = true;
    block_cache[idx].dirty = true;
    lruTouch(@truncate(idx));
    return true;
}

fn writeU32ToBlock(data: [*]u8, offset: u32, val: u32) void {
    const o = @as(usize, offset);
    data[o] = @truncate(val);
    data[o + 1] = @truncate(val >> 8);
    data[o + 2] = @truncate(val >> 16);
    data[o + 3] = @truncate(val >> 24);
}

fn writeU16ToBlock(data: [*]u8, offset: u32, val: u16) void {
    const o = @as(usize, offset);
    data[o] = @truncate(val);
    data[o + 1] = @truncate(val >> 8);
}

fn writeSuperblock() bool {
    // Superblock lives at byte offset 1024 in block 1 (for 1024-byte blocks)
    // or at offset 1024 within block 0 (for 4096-byte blocks)
    const sb_block: u64 = if (block_size == 1024) 1 else 0;
    const sb_offset: usize = if (block_size == 1024) 0 else 1024;

    const blk = readBlock(sb_block) orelse return false;

    // Copy superblock struct into block data at correct offset
    const src: *const [@sizeOf(Ext2Superblock)]u8 = @ptrCast(&superblock);
    for (0..@sizeOf(Ext2Superblock)) |i| {
        blk[sb_offset + i] = src[i];
    }

    return writeBlock(sb_block, blk);
}

fn writeBlockGroupDesc(group: u32, bgd: *const Ext2BlockGroupDesc) bool {
    const bgdt_block: u64 = if (block_size == 1024) 2 else 1;
    const ds: u32 = @as(u32, desc_size);
    const bgd_per_block = block_size / ds;

    const target_block = bgdt_block + @as(u64, group / bgd_per_block);
    const blk = readBlock(target_block) orelse return false;

    const offset = (group % bgd_per_block) * ds;

    // Copy first 32 bytes of BGD struct into block data
    // (extended fields at 32-63 are preserved from the read for 64-bit descriptors)
    const src: *const [32]u8 = @ptrCast(bgd);
    for (0..32) |i| {
        blk[offset + i] = src[i];
    }

    return writeBlock(target_block, blk);
}

// ---- Journal transaction helpers ----

fn beginJournalTx(max_blocks: u32) void {
    if (journal_mod.isActive() and !journal_tx_active) {
        if (journal_mod.start(max_blocks)) {
            journal_tx_active = true;
        }
    }
}

fn commitJournalTx() void {
    if (journal_tx_active) {
        _ = journal_mod.stop();
        journal_tx_active = false;
    }
}

// ---- Bitmap allocation ----

/// Allocate `count` contiguous blocks using mballoc when available.
/// Returns the first block number, or null on failure.
/// The `count_out` parameter receives the number actually allocated.
fn allocBlockContiguous(count: u32, goal: u32, count_out: *u32) ?u32 {
    const bgd = readBlockGroup(0) orelse return null;
    const bitmap_block: u64 = bgd.bg_block_bitmap;
    const bitmap = readBlock(bitmap_block) orelse return null;

    const bg_state = mballoc.BlockGroupState{
        .bg_number = 0,
        .bitmap_block = bitmap_block,
        .free_blocks = bgd.bg_free_blocks_count,
        .blocks_per_group = blocks_per_group,
        .first_data_block = 0,
    };

    const req = mballoc.AllocRequest{
        .count = count,
        .goal = goal,
        .preferred_bg = 0,
        .min_count = 1,
    };

    var result = mballoc.AllocResult{};
    if (!mballoc.allocFromBitmap(bitmap, blocks_per_group, &req, &bg_state, &result)) {
        return null;
    }

    // Update metadata
    superblock.s_free_blocks_count -= @truncate(result.count);
    var bgd_copy = bgd;
    bgd_copy.bg_free_blocks_count -= @truncate(result.count);

    // Atomic journal transaction: bitmap + superblock + BGD
    beginJournalTx(3);
    if (!writeBlock(bitmap_block, bitmap)) { commitJournalTx(); return null; }
    if (!writeSuperblock()) { commitJournalTx(); return null; }
    if (!writeBlockGroupDesc(0, &bgd_copy)) { commitJournalTx(); return null; }
    commitJournalTx();

    // Zero all allocated blocks (data write, outside transaction)
    const start: u32 = @truncate(result.start);
    for (0..result.count) |i| {
        const blk_num: u32 = start + @as(u32, @truncate(i));
        const new_blk = readBlock(blk_num) orelse return null;
        for (0..block_size) |j| {
            new_blk[j] = 0;
        }
        if (!writeBlock(blk_num, new_blk)) return null;
    }

    count_out.* = result.count;
    return start;
}

fn allocBlock() ?u32 {
    var count_out: u32 = 0;
    return allocBlockContiguous(1, 20, &count_out);
}

fn freeBlock(blk: u32) bool {
    if (blk == 0) return true; // Block 0 is not a real block

    const bgd = readBlockGroup(0) orelse return false;
    const bitmap_block: u64 = bgd.bg_block_bitmap;
    const bitmap = readBlock(bitmap_block) orelse return false;

    // Prepare all metadata updates
    const byte_idx = blk / 8;
    const bit_idx: u3 = @truncate(blk % 8);
    bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    superblock.s_free_blocks_count += 1;
    var bgd_copy = bgd;
    bgd_copy.bg_free_blocks_count += 1;

    // Atomic journal transaction: bitmap + superblock + BGD
    beginJournalTx(3);
    if (!writeBlock(bitmap_block, bitmap)) { commitJournalTx(); return false; }
    if (!writeSuperblock()) { commitJournalTx(); return false; }
    if (!writeBlockGroupDesc(0, &bgd_copy)) { commitJournalTx(); return false; }
    commitJournalTx();

    // Revoke: prevent stale journal entries for this block from replaying
    _ = journal_mod.revoke(blk);

    return true;
}

fn allocInode() ?u32 {
    const bgd = readBlockGroup(0) orelse return null;
    const bitmap_block: u64 = bgd.bg_inode_bitmap;
    const bitmap = readBlock(bitmap_block) orelse return null;

    // Scan from inode 12 onward (1-11 are reserved)
    const start_bit: u32 = 11; // bit 11 = inode 12 (0-indexed bitmap, 1-indexed inodes)
    const max_bits: u32 = inodes_per_group;

    var bit: u32 = start_bit;
    while (bit < max_bits) : (bit += 1) {
        const byte_idx = bit / 8;
        const bit_idx: u3 = @truncate(bit % 8);
        if (bitmap[byte_idx] & (@as(u8, 1) << bit_idx) == 0) {
            // Found free inode — prepare all metadata updates
            bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
            superblock.s_free_inodes_count -= 1;
            var bgd_copy = bgd;
            bgd_copy.bg_free_inodes_count -= 1;

            // Atomic journal transaction: bitmap + superblock + BGD
            beginJournalTx(3);
            if (!writeBlock(bitmap_block, bitmap)) { commitJournalTx(); return null; }
            if (!writeSuperblock()) { commitJournalTx(); return null; }
            if (!writeBlockGroupDesc(0, &bgd_copy)) { commitJournalTx(); return null; }
            commitJournalTx();

            return bit + 1; // Inodes are 1-indexed
        }
    }
    return null; // No free inodes
}

fn freeInode(ino: u32) bool {
    if (ino == 0) return true;

    const bgd = readBlockGroup(0) orelse return false;
    const bitmap_block: u64 = bgd.bg_inode_bitmap;
    const bitmap = readBlock(bitmap_block) orelse return false;

    // Prepare all metadata updates
    const bit = ino - 1; // Inodes are 1-indexed
    const byte_idx = bit / 8;
    const bit_idx: u3 = @truncate(bit % 8);
    bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    superblock.s_free_inodes_count += 1;
    var bgd_copy = bgd;
    bgd_copy.bg_free_inodes_count += 1;

    // Atomic journal transaction: bitmap + superblock + BGD
    beginJournalTx(3);
    if (!writeBlock(bitmap_block, bitmap)) { commitJournalTx(); return false; }
    if (!writeSuperblock()) { commitJournalTx(); return false; }
    if (!writeBlockGroupDesc(0, &bgd_copy)) { commitJournalTx(); return false; }
    commitJournalTx();

    return true;
}

// ---- Inode cache ----

const INODE_CACHE_SIZE: usize = 256;

const Ext2InodeCache = struct {
    vfs_inode: vfs.Inode,
    disk_inode: Ext2DiskInode,
    ino: u32,
    in_use: bool,
    pin_count: u16,
};

var inode_cache: [INODE_CACHE_SIZE]Ext2InodeCache = init_inode_cache();
var next_evict: usize = 0;

fn init_inode_cache() [INODE_CACHE_SIZE]Ext2InodeCache {
    var cache: [INODE_CACHE_SIZE]Ext2InodeCache = undefined;
    for (0..INODE_CACHE_SIZE) |i| {
        cache[i].in_use = false;
        cache[i].ino = 0;
        cache[i].pin_count = 0;
    }
    return cache;
}

fn resetInodeCache() void {
    for (0..INODE_CACHE_SIZE) |i| {
        inode_cache[i].in_use = false;
    }
    next_evict = 0;
}

// ---- Filesystem state ----

var superblock: Ext2Superblock = undefined;
var block_size: u32 = 0;
var inode_size: u32 = 128;
var inodes_per_group: u32 = 0;
var blocks_per_group: u32 = 0;
var num_groups: u32 = 0;
var initialized: bool = false;

// ext4: 64-bit block group descriptor support
var desc_size: u16 = 32; // 32 for ext2/ext3, 64+ for ext4 with INCOMPAT_64BIT
var is_64bit_mode: bool = false;

// Journal transaction state — when active, writeBlock() queues to journal
var journal_tx_active: bool = false;

// ---- VFS operation tables ----

const ext2_file_ops = vfs.FileOperations{
    .read = ext2Read,
    .write = ext2Write,
    .close = null,
    .readdir = null,
    .truncate = ext2TruncateVfs,
};

const ext2_dir_ops = vfs.FileOperations{
    .read = null,
    .write = null,
    .close = null,
    .readdir = ext2Readdir,
    .lookup = lookup,
    .create = ext2Create,
    .unlink = ext2Unlink,
    .rmdir = ext2Rmdir,
    .rename = ext2Rename,
    .symlink = ext2SymlinkOp,
    .link = ext2LinkOp,
};

const ext2_symlink_ops = vfs.FileOperations{
    .readlink = ext2Readlink,
};

// ---- Public API ----

pub fn init() bool {
    // Read superblock from byte offset 1024 (sector 2, 2 sectors = 1024 bytes)
    var sb_buf: [1024]u8 = undefined;
    if (!block_io.readSectors(2, 2, &sb_buf)) {
        serial.writeString("[ext2] Failed to read superblock\n");
        return false;
    }

    // Copy superblock — use byte-by-byte copy to avoid alignment issues
    const sb_bytes: *const [1024]u8 = &sb_buf;
    const dest_bytes: *[1024]u8 = @ptrCast(&superblock);
    for (0..@sizeOf(Ext2Superblock)) |i| {
        dest_bytes[i] = sb_bytes[i];
    }

    // Validate magic
    if (superblock.s_magic != EXT2_SUPER_MAGIC) {
        serial.writeString("[ext2] Bad magic: 0x");
        writeHex16(superblock.s_magic);
        serial.writeString(" (expected 0xEF53)\n");
        return false;
    }

    // Calculate parameters
    const shift: u5 = @truncate(superblock.s_log_block_size);
    block_size = @as(u32, 1024) << shift;
    inodes_per_group = superblock.s_inodes_per_group;
    blocks_per_group = superblock.s_blocks_per_group;

    // Inode size: 128 for rev0, s_inode_size for rev1+
    if (superblock.s_rev_level >= 1) {
        inode_size = superblock.s_inode_size;
    } else {
        inode_size = 128;
    }

    // Number of block groups
    num_groups = (superblock.s_blocks_count + blocks_per_group - 1) / blocks_per_group;

    // ext4: detect 64-bit mode and descriptor size
    // s_desc_size is at superblock offset 254 (0xFE), within the padding area
    const sb_raw: [*]const u8 = @ptrCast(&superblock);
    const s_desc_size_raw: u16 = @as(u16, sb_raw[254]) | (@as(u16, sb_raw[255]) << 8);
    is_64bit_mode = block_group_64.is64Bit(superblock.s_feature_incompat);
    desc_size = block_group_64.descSize(superblock.s_feature_incompat, s_desc_size_raw);

    // Reset caches
    invalidateCache();
    resetInodeCache();

    initialized = true;

    serial.writeString("[ext2] block_size=");
    writeDecimal(block_size);
    serial.writeString(", inodes=");
    writeDecimal(superblock.s_inodes_count);
    serial.writeString(", groups=");
    writeDecimal(num_groups);
    if (is_64bit_mode) {
        serial.writeString(", ext4-64bit desc_size=");
        writeDecimal(desc_size);
    }
    serial.writeString("\n");

    // ext3 journal detection and initialization
    // Read s_journal_inum from superblock offset 0xE0 (little-endian)
    const s_journal_inum: u32 = @as(u32, sb_raw[0xE0]) |
        (@as(u32, sb_raw[0xE1]) << 8) |
        (@as(u32, sb_raw[0xE2]) << 16) |
        (@as(u32, sb_raw[0xE3]) << 24);

    // Read block group 0 to find inode table location (journal inode 8 is in BG 0)
    if (blockGroupInodeTable64(0)) |inode_table_addr| {
        _ = ext3_mount.initJournal(
            superblock.s_feature_compat,
            superblock.s_feature_incompat,
            s_journal_inum,
            block_size,
            @as(u16, @truncate(inode_size)),
            inodes_per_group,
            inode_table_addr,
        );
    }

    return true;
}

pub fn getRootInode() ?*vfs.Inode {
    if (!initialized) return null;
    const inode = loadInode(EXT2_ROOT_INO) orelse return null;
    // Pin the root inode so it's never evicted from the cache.
    // The VFS mount table holds a pointer into the cache slot — if evicted,
    // the mount table's root_inode becomes a stale pointer to a different inode.
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(inode.fs_data orelse return inode));
    if (cache_entry.pin_count == 0) cache_entry.pin_count = 1;
    return inode;
}

// ---- Block group descriptors ----

fn readBlockGroup(group: u32) ?Ext2BlockGroupDesc {
    // BGDT starts at block 2 for 1024-byte blocks, block 1 for larger blocks
    const bgdt_block: u64 = if (block_size == 1024) 2 else 1;
    const ds: u32 = @as(u32, desc_size); // 32 for ext2/ext3, 64 for ext4
    const bgd_per_block = block_size / ds;

    const target_block = bgdt_block + @as(u64, group / bgd_per_block);
    const block_data = readBlock(target_block) orelse return null;

    const offset = (group % bgd_per_block) * ds;

    // Byte-by-byte copy of first 32 bytes (standard ext2 fields)
    var bgd: Ext2BlockGroupDesc = undefined;
    const dest: *[32]u8 = @ptrCast(&bgd);
    for (0..32) |i| {
        dest[i] = block_data[offset + i];
    }
    return bgd;
}

/// Read the full 64-bit inode table address for a block group.
/// Falls back to 32-bit address when not in 64-bit mode.
fn blockGroupInodeTable64(group: u32) ?u64 {
    const bgdt_block: u64 = if (block_size == 1024) 2 else 1;
    const ds: u32 = @as(u32, desc_size);
    const bgd_per_block = block_size / ds;
    const target_block = bgdt_block + @as(u64, group / bgd_per_block);
    const block_data = readBlock(target_block) orelse return null;
    const offset = (group % bgd_per_block) * ds;

    // inode_table_lo is at descriptor offset 0x08 (4 bytes LE)
    const lo: u32 = @as(u32, block_data[offset + 0x08]) |
        (@as(u32, block_data[offset + 0x09]) << 8) |
        (@as(u32, block_data[offset + 0x0A]) << 16) |
        (@as(u32, block_data[offset + 0x0B]) << 24);

    if (!is_64bit_mode or ds < 64) return @as(u64, lo);

    // inode_table_hi is at descriptor offset 0x28 (4 bytes LE)
    const hi: u32 = @as(u32, block_data[offset + 0x28]) |
        (@as(u32, block_data[offset + 0x29]) << 8) |
        (@as(u32, block_data[offset + 0x2A]) << 16) |
        (@as(u32, block_data[offset + 0x2B]) << 24);

    return (@as(u64, hi) << 32) | @as(u64, lo);
}

// ---- Inode loading ----

fn loadInodeDisk(ino: u32) ?Ext2DiskInode {
    if (ino == 0) return null;

    const group = (ino - 1) / inodes_per_group;
    const index = (ino - 1) % inodes_per_group;

    // Use 64-bit inode table address (combines hi+lo in 64-bit mode)
    const inode_table_base = blockGroupInodeTable64(group) orelse return null;

    // Calculate which block in the inode table contains this inode
    const inodes_per_block = block_size / inode_size;
    const block_in_table = index / inodes_per_block;
    const offset_in_block = (index % inodes_per_block) * inode_size;

    const block_num = inode_table_base + block_in_table;
    const block_data = readBlock(block_num) orelse return null;

    // Byte-by-byte copy (128 bytes regardless of on-disk inode_size)
    var disk_inode: Ext2DiskInode = undefined;
    const dest: *[128]u8 = @ptrCast(&disk_inode);
    for (0..128) |i| {
        dest[i] = block_data[offset_in_block + i];
    }

    // ext4 inode checksum verification (if METADATA_CSUM enabled and inode_size >= 256)
    const RO_COMPAT_METADATA_CSUM: u32 = 0x0400;
    if (superblock.s_feature_ro_compat & RO_COMPAT_METADATA_CSUM != 0 and inode_size >= 256) {
        const inode_raw = block_data + offset_in_block;
        if (!inode_ext4.verifyChecksum(inode_raw, @truncate(inode_size), ino, &superblock.s_uuid)) {
            serial.print("[ext4] inode {d} checksum mismatch (continuing)\n", .{ino});
        }
    }

    return disk_inode;
}

fn writeInodeDisk(ino: u32, disk_inode: *const Ext2DiskInode) bool {
    if (ino == 0) return false;

    const group = (ino - 1) / inodes_per_group;
    const index = (ino - 1) % inodes_per_group;

    // Use 64-bit inode table address (combines hi+lo in 64-bit mode)
    const inode_table_base = blockGroupInodeTable64(group) orelse return false;

    const inodes_per_block = block_size / inode_size;
    const block_in_table = index / inodes_per_block;
    const offset_in_block = (index % inodes_per_block) * inode_size;

    const block_num = inode_table_base + block_in_table;
    const blk = readBlock(block_num) orelse return false;

    // Copy 128 bytes from struct into block data
    const src: *const [128]u8 = @ptrCast(disk_inode);
    for (0..128) |i| {
        blk[offset_in_block + i] = src[i];
    }

    // ext4: store inode checksum when METADATA_CSUM enabled and inode_size >= 256
    const RO_COMPAT_METADATA_CSUM_W: u32 = 0x0400;
    if (superblock.s_feature_ro_compat & RO_COMPAT_METADATA_CSUM_W != 0 and inode_size >= 256) {
        inode_ext4.storeChecksum(blk + offset_in_block, @truncate(inode_size), ino, &superblock.s_uuid);
    }

    // Journal transaction for inode table block
    beginJournalTx(1);
    const result = writeBlock(block_num, blk);
    commitJournalTx();
    return result;
}

fn loadInode(ino: u32) ?*vfs.Inode {
    // Check cache first
    for (0..INODE_CACHE_SIZE) |i| {
        if (inode_cache[i].in_use and inode_cache[i].ino == ino) {
            return &inode_cache[i].vfs_inode;
        }
    }

    // Load from disk
    const disk_inode = loadInodeDisk(ino) orelse return null;

    // Find free slot or evict
    var slot: usize = INODE_CACHE_SIZE; // sentinel
    for (0..INODE_CACHE_SIZE) |i| {
        if (!inode_cache[i].in_use) {
            slot = i;
            break;
        }
    }
    if (slot == INODE_CACHE_SIZE) {
        // FIFO eviction — skip pinned entries
        var attempts: usize = 0;
        while (attempts < INODE_CACHE_SIZE) : (attempts += 1) {
            if (inode_cache[next_evict].pin_count == 0) {
                slot = next_evict;
                next_evict = (next_evict + 1) % INODE_CACHE_SIZE;
                break;
            }
            next_evict = (next_evict + 1) % INODE_CACHE_SIZE;
        }
        if (slot == INODE_CACHE_SIZE) {
            // All slots pinned — forcefully evict next_evict
            slot = next_evict;
            next_evict = (next_evict + 1) % INODE_CACHE_SIZE;
        }
    }

    // Populate cache entry
    inode_cache[slot].ino = ino;
    inode_cache[slot].disk_inode = disk_inode;
    inode_cache[slot].in_use = true;
    inode_cache[slot].pin_count = 0;

    // Determine file type
    const mode_type = disk_inode.i_mode & 0xF000;
    const is_dir = mode_type == 0x4000;
    const is_symlink = mode_type == 0xA000;

    // Use actual permission bits from disk inode (lower 12 bits of i_mode)
    const perm_bits = @as(u32, disk_inode.i_mode) & 0o7777;
    const type_bits: u32 = if (is_dir) vfs.S_IFDIR else if (is_symlink) vfs.S_IFLNK else vfs.S_IFREG;
    const ops_table = if (is_dir) &ext2_dir_ops else if (is_symlink) &ext2_symlink_ops else &ext2_file_ops;

    inode_cache[slot].vfs_inode = .{
        .ino = ino,
        .mode = type_bits | perm_bits,
        .size = disk_inode.i_size,
        .nlink = disk_inode.i_links_count,
        .uid = disk_inode.i_uid,
        .gid = disk_inode.i_gid,
        .ops = ops_table,
        .fs_data = @ptrCast(&inode_cache[slot]),
    };

    return &inode_cache[slot].vfs_inode;
}

// ---- Extent tree read callback ----

fn readBlockConst(block_num: u64) ?[*]const u8 {
    return readBlock(block_num);
}

// ---- Block address translation ----

fn getFileBlock(cache_entry: *Ext2InodeCache, file_block: u32) ?u32 {
    const inode = &cache_entry.disk_inode;

    // ext4 extent tree path — check EXTENTS_FL (0x00080000)
    if (extents.usesExtents(inode.i_flags)) {
        const iblock: *const [60]u8 = @ptrCast(&inode.i_block);
        const phys = extents.lookup(iblock, file_block, &readBlockConst) orelse return null;
        return @truncate(phys);
    }

    const addrs_per_block = block_size / 4;

    // Direct blocks (0-11)
    if (file_block < 12) {
        const blk = inode.i_block[file_block];
        return if (blk == 0) null else blk;
    }

    // Singly indirect (12 .. 12+addrs_per_block-1)
    const single_limit = 12 + addrs_per_block;
    if (file_block < single_limit) {
        const indirect_block = inode.i_block[12];
        if (indirect_block == 0) return null;

        const data = readBlock(indirect_block) orelse return null;
        const index = file_block - 12;
        const addr = readU32FromBlock(data, index * 4);
        return if (addr == 0) null else addr;
    }

    // Doubly indirect
    const double_limit = single_limit + addrs_per_block * addrs_per_block;
    if (file_block < double_limit) {
        const di_block = inode.i_block[13];
        if (di_block == 0) return null;

        const di_data = readBlock(di_block) orelse return null;
        const adjusted = file_block - single_limit;
        const di_index = adjusted / addrs_per_block;
        const indirect_block = readU32FromBlock(di_data, di_index * 4);
        if (indirect_block == 0) return null;

        const ind_data = readBlock(indirect_block) orelse return null;
        const ind_index = adjusted % addrs_per_block;
        const addr = readU32FromBlock(ind_data, ind_index * 4);
        return if (addr == 0) null else addr;
    }

    // Triple indirect not supported in Phase A
    return null;
}

fn readU32FromBlock(data: [*]const u8, offset: u32) u32 {
    const o = @as(usize, offset);
    return @as(u32, data[o]) |
        (@as(u32, data[o + 1]) << 8) |
        (@as(u32, data[o + 2]) << 16) |
        (@as(u32, data[o + 3]) << 24);
}

// ---- File read ----

fn ext2Read(desc: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        desc.inode.fs_data orelse return -1,
    ));

    const file_size = cache_entry.disk_inode.i_size;
    if (desc.offset >= file_size) return 0; // EOF

    const available = file_size - @as(u32, @truncate(desc.offset));
    const to_read: usize = if (count < available) count else @intCast(available);

    var bytes_read: usize = 0;
    var offset = desc.offset;

    while (bytes_read < to_read) {
        const file_block: u32 = @truncate(offset / block_size);
        const block_offset: usize = @truncate(offset % block_size);
        const remaining = to_read - bytes_read;
        const chunk_max = @as(usize, block_size) - block_offset;
        const chunk = if (remaining < chunk_max) remaining else chunk_max;

        const phys_block = getFileBlock(cache_entry, file_block) orelse {
            // Sparse block — return zeros
            for (0..chunk) |i| {
                buf[bytes_read + i] = 0;
            }
            bytes_read += chunk;
            offset += chunk;
            continue;
        };

        // Check page cache first (indexed by inode + file block)
        if (page_cache.lookup(cache_entry.ino, file_block)) |cached_phys| {
            const cached_data: [*]const u8 = @ptrFromInt(hhdm.physToVirt(cached_phys));
            for (0..chunk) |i| {
                buf[bytes_read + i] = cached_data[block_offset + i];
            }
            bytes_read += chunk;
            offset += chunk;
            continue;
        }

        const block_data = readBlock(phys_block) orelse break;

        // Insert into page cache for future reads
        if (pmm.allocPage()) |pg| {
            const pg_ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(pg));
            for (0..block_size) |i| {
                pg_ptr[i] = block_data[i];
            }
            page_cache.insert(cache_entry.ino, file_block, pg);
        }

        for (0..chunk) |i| {
            buf[bytes_read + i] = block_data[block_offset + i];
        }

        bytes_read += chunk;
        offset += chunk;
    }

    desc.offset = offset;
    return @intCast(bytes_read);
}

// ---- File write ----

fn getOrAllocFileBlock(cache_entry: *Ext2InodeCache, file_block: u32) ?u32 {
    const inode = &cache_entry.disk_inode;

    // ext4 extent tree path — allocate via extent insert
    if (extents.usesExtents(inode.i_flags)) {
        const iblock: *const [60]u8 = @ptrCast(&inode.i_block);
        // Check if already mapped
        if (extents.lookup(iblock, file_block, &readBlockConst)) |phys| {
            return @truncate(phys);
        }
        // Not mapped — allocate a new block and insert extent
        const new_blk = allocBlock() orelse return null;
        const iblock_mut: *[60]u8 = @ptrCast(&inode.i_block);
        const ext = extents.Extent{
            .block = file_block,
            .len = 1,
            .start_hi = 0,
            .start_lo = new_blk,
        };
        if (!extents.insertInLeaf(iblock_mut, ext)) {
            // Leaf is full — for now fall back to failure
            // (full split support would require allocating tree blocks)
            _ = freeBlock(new_blk);
            return null;
        }
        return new_blk;
    }

    const addrs_per_block = block_size / 4;

    // Direct blocks (0-11)
    if (file_block < 12) {
        if (inode.i_block[file_block] != 0) return inode.i_block[file_block];
        // Allocate new block
        const new_blk = allocBlock() orelse return null;
        inode.i_block[file_block] = new_blk;
        return new_blk;
    }

    // Singly indirect (12 .. 12+addrs_per_block-1)
    const single_limit = 12 + addrs_per_block;
    if (file_block < single_limit) {
        // Ensure indirect block exists
        if (inode.i_block[12] == 0) {
            const ind_blk = allocBlock() orelse return null;
            inode.i_block[12] = ind_blk;
        }

        const ind_data = readBlock(inode.i_block[12]) orelse return null;
        const index = file_block - 12;
        const addr = readU32FromBlock(ind_data, index * 4);
        if (addr != 0) return addr;

        // Allocate new data block
        const new_blk = allocBlock() orelse return null;
        // Re-read indirect block (cache may have been evicted by allocBlock)
        const ind_data2 = readBlock(inode.i_block[12]) orelse return null;
        writeU32ToBlock(ind_data2, index * 4, new_blk);
        beginJournalTx(1);
        if (!writeBlock(inode.i_block[12], ind_data2)) { commitJournalTx(); return null; }
        commitJournalTx();
        return new_blk;
    }

    // Doubly indirect (single_limit .. single_limit + addrs_per_block^2 - 1)
    const double_limit = single_limit + addrs_per_block * addrs_per_block;
    if (file_block < double_limit) {
        // Ensure doubly indirect block exists
        if (inode.i_block[13] == 0) {
            const di_blk = allocBlock() orelse return null;
            inode.i_block[13] = di_blk;
        }

        const adjusted = file_block - single_limit;
        const di_index = adjusted / addrs_per_block;

        // Read doubly indirect block
        const di_data = readBlock(inode.i_block[13]) orelse return null;
        var indirect_block = readU32FromBlock(di_data, di_index * 4);

        // Ensure singly indirect block at this index exists
        if (indirect_block == 0) {
            const new_ind = allocBlock() orelse return null;
            // Re-read DI block (cache may have been evicted by allocBlock)
            const di_data2 = readBlock(inode.i_block[13]) orelse return null;
            writeU32ToBlock(di_data2, di_index * 4, new_ind);
            beginJournalTx(1);
            if (!writeBlock(inode.i_block[13], di_data2)) { commitJournalTx(); return null; }
            commitJournalTx();
            indirect_block = new_ind;
        }

        // Read singly indirect block
        const ind_data = readBlock(indirect_block) orelse return null;
        const ind_index = adjusted % addrs_per_block;
        const addr = readU32FromBlock(ind_data, ind_index * 4);
        if (addr != 0) return addr;

        // Allocate new data block
        const new_blk = allocBlock() orelse return null;
        // Re-read indirect block (cache may have been evicted)
        const ind_data2 = readBlock(indirect_block) orelse return null;
        writeU32ToBlock(ind_data2, ind_index * 4, new_blk);
        beginJournalTx(1);
        if (!writeBlock(indirect_block, ind_data2)) { commitJournalTx(); return null; }
        commitJournalTx();
        return new_blk;
    }

    return null; // Beyond doubly indirect not supported
}

fn ext2Write(desc: *vfs.FileDescription, buf: [*]const u8, count: usize) isize {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        desc.inode.fs_data orelse return -1,
    ));

    // Handle O_APPEND
    if (desc.flags & vfs.O_APPEND != 0) {
        desc.offset = cache_entry.disk_inode.i_size;
    }

    var bytes_written: usize = 0;
    var offset = desc.offset;

    while (bytes_written < count) {
        const file_block: u32 = @truncate(offset / block_size);
        const block_offset: usize = @truncate(offset % block_size);
        const remaining = count - bytes_written;
        const chunk_max = @as(usize, block_size) - block_offset;
        const chunk = if (remaining < chunk_max) remaining else chunk_max;

        const phys_block = getOrAllocFileBlock(cache_entry, file_block) orelse break;

        // Read-modify-write
        const blk = readBlock(phys_block) orelse break;
        for (0..chunk) |i| {
            blk[block_offset + i] = buf[bytes_written + i];
        }
        if (!writeBlock(phys_block, blk)) break;

        // Invalidate stale page cache entry for this block
        page_cache.invalidatePage(cache_entry.ino, file_block);

        bytes_written += chunk;
        offset += chunk;
    }

    if (bytes_written == 0) return -1;

    // Update file size if we extended the file
    if (offset > cache_entry.disk_inode.i_size) {
        cache_entry.disk_inode.i_size = @truncate(offset);
    }

    // Update i_blocks (count of 512-byte sectors)
    // Count allocated blocks: direct + indirect
    var block_count: u32 = 0;
    for (0..12) |i| {
        if (cache_entry.disk_inode.i_block[i] != 0) block_count += 1;
    }
    if (cache_entry.disk_inode.i_block[12] != 0) {
        block_count += 1; // The indirect block itself
        const ind_data = readBlock(cache_entry.disk_inode.i_block[12]);
        if (ind_data) |data| {
            const addrs_per_block = block_size / 4;
            for (0..addrs_per_block) |i| {
                if (readU32FromBlock(data, @truncate(i * 4)) != 0) block_count += 1;
            }
        }
    }
    cache_entry.disk_inode.i_blocks = block_count * (block_size / 512);

    // Write inode to disk
    _ = writeInodeDisk(cache_entry.ino, &cache_entry.disk_inode);

    // Update VFS inode size
    desc.inode.size = cache_entry.disk_inode.i_size;
    desc.offset = offset;

    return @intCast(bytes_written);
}

// ---- Truncate ----

fn freeFileBlocks(disk_inode: *Ext2DiskInode) void {
    // Free direct blocks (0-11)
    for (0..12) |i| {
        if (disk_inode.i_block[i] != 0) {
            _ = freeBlock(disk_inode.i_block[i]);
            disk_inode.i_block[i] = 0;
        }
    }

    // Free singly indirect
    if (disk_inode.i_block[12] != 0) {
        const ind_data = readBlock(disk_inode.i_block[12]);
        if (ind_data) |data| {
            const addrs_per_block = block_size / 4;
            for (0..addrs_per_block) |i| {
                const addr = readU32FromBlock(data, @truncate(i * 4));
                if (addr != 0) {
                    _ = freeBlock(addr);
                }
            }
        }
        _ = freeBlock(disk_inode.i_block[12]);
        disk_inode.i_block[12] = 0;
    }

    // Free doubly indirect
    if (disk_inode.i_block[13] != 0) {
        const di_data = readBlock(disk_inode.i_block[13]);
        if (di_data) |data| {
            const addrs_per_block = block_size / 4;
            for (0..addrs_per_block) |i| {
                const ind_blk = readU32FromBlock(data, @truncate(i * 4));
                if (ind_blk != 0) {
                    const ind_data = readBlock(ind_blk);
                    if (ind_data) |idata| {
                        for (0..addrs_per_block) |j| {
                            const addr = readU32FromBlock(idata, @truncate(j * 4));
                            if (addr != 0) {
                                _ = freeBlock(addr);
                            }
                        }
                    }
                    _ = freeBlock(ind_blk);
                }
            }
        }
        _ = freeBlock(disk_inode.i_block[13]);
        disk_inode.i_block[13] = 0;
    }

    disk_inode.i_size = 0;
    disk_inode.i_blocks = 0;
}

fn ext2TruncateVfs(inode: *vfs.Inode) bool {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        inode.fs_data orelse return false,
    ));

    freeFileBlocks(&cache_entry.disk_inode);
    _ = writeInodeDisk(cache_entry.ino, &cache_entry.disk_inode);
    inode.size = 0;
    return true;
}

// ---- Directory readdir ----

fn ext2Readdir(desc: *vfs.FileDescription, entry: *vfs.DirEntry) bool {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        desc.inode.fs_data orelse return false,
    ));

    const dir_size: u64 = cache_entry.disk_inode.i_size;

    while (desc.offset < dir_size) {
        const file_block: u32 = @truncate(desc.offset / block_size);
        const block_offset: usize = @truncate(desc.offset % block_size);

        const phys_block = getFileBlock(cache_entry, file_block) orelse return false;
        const block_data = readBlock(phys_block) orelse return false;

        // Bounds check: need at least 8 bytes for dir entry header
        if (block_offset + EXT2_DIR_HEADER_SIZE > block_size) return false;

        // Parse directory entry fields manually (little-endian)
        const de_inode = readU32FromBlock(block_data, @truncate(block_offset));
        const de_rec_len = @as(u16, block_data[block_offset + 4]) |
            (@as(u16, block_data[block_offset + 5]) << 8);
        const de_name_len = block_data[block_offset + 6];
        const de_file_type = block_data[block_offset + 7];

        // Sanity check rec_len
        if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) return false;

        // Skip deleted entries
        if (de_inode == 0) {
            desc.offset += de_rec_len;
            continue;
        }

        // Fill VFS DirEntry
        entry.name = [_]u8{0} ** 256;
        const name_start = block_offset + EXT2_DIR_HEADER_SIZE;
        const name_len: usize = @min(de_name_len, 255);
        for (0..name_len) |i| {
            entry.name[i] = block_data[name_start + i];
        }
        entry.name_len = @truncate(name_len);
        entry.ino = de_inode;
        entry.d_type = switch (de_file_type) {
            EXT2_FT_DIR => vfs.DT_DIR,
            EXT2_FT_REG_FILE => vfs.DT_REG,
            EXT2_FT_SYMLINK => vfs.DT_LNK,
            else => vfs.DT_REG,
        };

        // Advance offset
        desc.offset += de_rec_len;
        return true;
    }

    return false; // End of directory
}

// ---- HTree lookup helper ----

fn htreeLookup(cache_entry: *Ext2InodeCache, name: []const u8) ?u32 {
    // Read the root block (first directory block, contains DxRoot)
    const root_phys = getFileBlock(cache_entry, 0) orelse return null;
    const root_data = readBlock(root_phys) orelse return null;

    // Parse DxRoot to get hash seed and hash version
    const root: *const htree.DxRoot = @ptrCast(@alignCast(root_data));
    const hash_seed = superblock.s_uuid; // Hash seed from superblock UUID
    var seed: [4]u32 = undefined;
    // Parse UUID as 4 little-endian u32s
    for (0..4) |i| {
        seed[i] = @as(u32, hash_seed[i * 4]) |
            (@as(u32, hash_seed[i * 4 + 1]) << 8) |
            (@as(u32, hash_seed[i * 4 + 2]) << 16) |
            (@as(u32, hash_seed[i * 4 + 3]) << 24);
    }

    // Compute hash of the target name
    const hash = htree.computeHash(name.ptr, @truncate(name.len), seed, root.hash_version);

    // Get root entries and search for the leaf block
    const root_entries = htree.getRootEntries(root_data);
    const leaf_block_idx = htree.searchEntries(root_entries, root.count, hash);

    // Read the leaf block (directory block with actual entries)
    const leaf_phys = getFileBlock(cache_entry, leaf_block_idx) orelse return null;
    const leaf_data = readBlock(leaf_phys) orelse return null;

    // Linear scan within the leaf block for exact name match
    var block_off: usize = 0;
    while (block_off + EXT2_DIR_HEADER_SIZE <= block_size) {
        const de_inode = readU32FromBlock(leaf_data, @truncate(block_off));
        const de_rec_len = @as(u16, leaf_data[block_off + 4]) |
            (@as(u16, leaf_data[block_off + 5]) << 8);
        const de_name_len = leaf_data[block_off + 6];

        if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

        if (de_inode != 0 and de_name_len == name.len) {
            const name_start = block_off + EXT2_DIR_HEADER_SIZE;
            var match = true;
            for (0..name.len) |i| {
                if (leaf_data[name_start + i] != name[i]) {
                    match = false;
                    break;
                }
            }
            if (match) return de_inode;
        }

        block_off += de_rec_len;
    }

    return null;
}

// ---- Lookup ----

pub fn lookup(parent: *vfs.Inode, name: []const u8) ?*vfs.Inode {
    // Only directories can be looked up in
    if (parent.mode & vfs.S_IFMT != vfs.S_IFDIR) return null;

    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        parent.fs_data orelse return null,
    ));

    // HTree indexed directory — use hash-based lookup for large directories
    if (htree.usesHTree(cache_entry.disk_inode.i_flags)) {
        if (htreeLookup(cache_entry, name)) |ino| {
            return loadInode(ino);
        }
        return null;
    }

    // Linear scan for small directories (no HTree index)
    const dir_size: u64 = cache_entry.disk_inode.i_size;
    var offset: u64 = 0;

    while (offset < dir_size) {
        const file_block: u32 = @truncate(offset / block_size);
        const block_offset: usize = @truncate(offset % block_size);

        const phys_block = getFileBlock(cache_entry, file_block) orelse break;
        const block_data = readBlock(phys_block) orelse break;

        if (block_offset + EXT2_DIR_HEADER_SIZE > block_size) break;

        const de_inode = readU32FromBlock(block_data, @truncate(block_offset));
        const de_rec_len = @as(u16, block_data[block_offset + 4]) |
            (@as(u16, block_data[block_offset + 5]) << 8);
        const de_name_len = block_data[block_offset + 6];

        if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

        if (de_inode != 0 and de_name_len == name.len) {
            const name_start = block_offset + EXT2_DIR_HEADER_SIZE;
            var match = true;
            for (0..name.len) |i| {
                if (block_data[name_start + i] != name[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                return loadInode(de_inode);
            }
        }

        offset += de_rec_len;
    }

    return null;
}

// ---- Create / Unlink ----

fn addDirEntry(parent_cache: *Ext2InodeCache, new_ino: u32, name: []const u8, file_type: u8) bool {
    const name_len: u8 = @truncate(name.len);
    const needed_size: u16 = @truncate(((EXT2_DIR_HEADER_SIZE + name_len) + 3) & ~@as(usize, 3)); // align to 4

    const dir_size: u64 = parent_cache.disk_inode.i_size;
    var offset: u64 = 0;

    // Walk existing directory blocks looking for space
    while (offset < dir_size) {
        const file_block: u32 = @truncate(offset / block_size);

        const phys_block = getFileBlock(parent_cache, file_block) orelse break;
        const blk = readBlock(phys_block) orelse break;

        var block_off: usize = 0;
        while (block_off + EXT2_DIR_HEADER_SIZE <= block_size) {
            const de_inode = readU32FromBlock(blk, @truncate(block_off));
            const de_rec_len = @as(u16, blk[block_off + 4]) |
                (@as(u16, blk[block_off + 5]) << 8);
            const de_name_len = blk[block_off + 6];

            if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

            if (de_inode != 0) {
                // Existing entry — check if there's slack space after the actual data
                const actual_size: u16 = @truncate(((EXT2_DIR_HEADER_SIZE + @as(usize, de_name_len)) + 3) & ~@as(usize, 3));
                const gap = de_rec_len - actual_size;

                if (gap >= needed_size) {
                    // Split: shrink existing entry, insert new entry in freed space
                    // Shrink existing
                    blk[block_off + 4] = @truncate(actual_size);
                    blk[block_off + 5] = @truncate(actual_size >> 8);

                    // Write new entry
                    const new_off = block_off + actual_size;
                    const new_rec_len = de_rec_len - actual_size;
                    writeU32ToBlock(blk, @truncate(new_off), new_ino);
                    blk[new_off + 4] = @truncate(new_rec_len);
                    blk[new_off + 5] = @truncate(new_rec_len >> 8);
                    blk[new_off + 6] = name_len;
                    blk[new_off + 7] = file_type;
                    for (0..name.len) |i| {
                        blk[new_off + EXT2_DIR_HEADER_SIZE + i] = name[i];
                    }

                    beginJournalTx(1);
                    const ok = writeBlock(phys_block, blk);
                    commitJournalTx();
                    return ok;
                }
            } else {
                // Deleted entry — can we reuse it?
                if (de_rec_len >= needed_size) {
                    writeU32ToBlock(blk, @truncate(block_off), new_ino);
                    // Keep rec_len as-is (absorbs remaining space)
                    blk[block_off + 6] = name_len;
                    blk[block_off + 7] = file_type;
                    for (0..name.len) |i| {
                        blk[block_off + EXT2_DIR_HEADER_SIZE + i] = name[i];
                    }

                    beginJournalTx(1);
                    const ok2 = writeBlock(phys_block, blk);
                    commitJournalTx();
                    return ok2;
                }
            }

            block_off += de_rec_len;
        }

        offset = (@as(u64, file_block) + 1) * block_size;
    }

    // No space in existing blocks — allocate a new directory block
    const new_file_block: u32 = @truncate(dir_size / block_size);
    const new_phys = getOrAllocFileBlock(parent_cache, new_file_block) orelse return false;

    // Re-read block (allocBlock may have evicted cache)
    const new_blk = readBlock(new_phys) orelse return false;

    // Zero the block first
    for (0..block_size) |i| {
        new_blk[i] = 0;
    }

    // Write single entry filling the entire block
    writeU32ToBlock(new_blk, 0, new_ino);
    const full_rec_len: u16 = @truncate(block_size);
    new_blk[4] = @truncate(full_rec_len);
    new_blk[5] = @truncate(full_rec_len >> 8);
    new_blk[6] = name_len;
    new_blk[7] = file_type;
    for (0..name.len) |i| {
        new_blk[EXT2_DIR_HEADER_SIZE + i] = name[i];
    }

    // Journal: dir block + inode table block in one transaction
    beginJournalTx(2);
    if (!writeBlock(new_phys, new_blk)) { commitJournalTx(); return false; }

    // Update parent size and blocks
    parent_cache.disk_inode.i_size += block_size;
    parent_cache.disk_inode.i_blocks += block_size / 512;
    _ = writeInodeDisk(parent_cache.ino, &parent_cache.disk_inode);
    // writeInodeDisk's internal commitJournalTx commits both blocks

    return true;
}

fn ext2Create(parent: *vfs.Inode, name: []const u8, mode: u32) ?*vfs.Inode {
    if (name.len == 0 or name.len > 255) return null;

    // Check name doesn't already exist
    if (lookup(parent, name) != null) return null;

    const parent_cache: *Ext2InodeCache = @alignCast(@ptrCast(
        parent.fs_data orelse return null,
    ));

    // Allocate new inode
    const new_ino = allocInode() orelse return null;

    // Initialize disk inode
    var disk_inode: Ext2DiskInode = undefined;
    const zero: *[128]u8 = @ptrCast(&disk_inode);
    for (0..128) |i| {
        zero[i] = 0;
    }

    const is_dir = (mode & vfs.S_IFMT) == vfs.S_IFDIR;
    disk_inode.i_mode = @truncate(mode);
    disk_inode.i_links_count = if (is_dir) 2 else 1; // dirs have . and parent link

    // Set ownership from current process
    if (scheduler.currentProcess()) |proc| {
        disk_inode.i_uid = proc.euid;
        disk_inode.i_gid = proc.egid;
    }

    if (is_dir) {
        // Allocate block for . and .. entries
        const dir_blk = allocBlock() orelse {
            _ = freeInode(new_ino);
            return null;
        };

        disk_inode.i_block[0] = dir_blk;
        disk_inode.i_size = block_size;
        disk_inode.i_blocks = block_size / 512;

        // Write . and .. entries
        const blk = readBlock(dir_blk) orelse {
            _ = freeBlock(dir_blk);
            _ = freeInode(new_ino);
            return null;
        };

        // Zero
        for (0..block_size) |i| {
            blk[i] = 0;
        }

        // "." entry: inode=new_ino, rec_len=12, name_len=1, type=dir
        writeU32ToBlock(blk, 0, new_ino);
        blk[4] = 12; // rec_len low byte
        blk[5] = 0; // rec_len high byte
        blk[6] = 1; // name_len
        blk[7] = EXT2_FT_DIR; // file_type
        blk[8] = '.';

        // ".." entry: inode=parent_ino, rec_len=rest_of_block, name_len=2, type=dir
        const dotdot_rec_len: u16 = @truncate(block_size - 12);
        writeU32ToBlock(blk, 12, parent_cache.ino);
        blk[16] = @truncate(dotdot_rec_len);
        blk[17] = @truncate(dotdot_rec_len >> 8);
        blk[18] = 2; // name_len
        blk[19] = EXT2_FT_DIR; // file_type
        blk[20] = '.';
        blk[21] = '.';

        beginJournalTx(1);
        if (!writeBlock(dir_blk, blk)) {
            commitJournalTx();
            _ = freeBlock(dir_blk);
            _ = freeInode(new_ino);
            return null;
        }
        commitJournalTx();

        // Increment parent nlink (for .. reference)
        parent_cache.disk_inode.i_links_count += 1;
        parent.nlink = parent_cache.disk_inode.i_links_count;
        _ = writeInodeDisk(parent_cache.ino, &parent_cache.disk_inode);

        // Update BGD used_dirs_count
        const bgd = readBlockGroup(0);
        if (bgd) |b| {
            var bgd_copy = b;
            bgd_copy.bg_used_dirs_count += 1;
            beginJournalTx(1);
            _ = writeBlockGroupDesc(0, &bgd_copy);
            commitJournalTx();
        }
    }

    // Write new inode to disk
    if (!writeInodeDisk(new_ino, &disk_inode)) {
        _ = freeInode(new_ino);
        return null;
    }

    // Add directory entry to parent
    const file_type: u8 = if (is_dir) EXT2_FT_DIR else EXT2_FT_REG_FILE;
    if (!addDirEntry(parent_cache, new_ino, name, file_type)) {
        _ = freeInode(new_ino);
        return null;
    }

    // Load and return VFS inode
    return loadInode(new_ino);
}

fn ext2Unlink(parent: *vfs.Inode, name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;

    const parent_cache: *Ext2InodeCache = @alignCast(@ptrCast(
        parent.fs_data orelse return false,
    ));

    const dir_size: u64 = parent_cache.disk_inode.i_size;
    var offset: u64 = 0;

    while (offset < dir_size) {
        const file_block: u32 = @truncate(offset / block_size);
        const phys_block = getFileBlock(parent_cache, file_block) orelse break;
        const blk = readBlock(phys_block) orelse break;

        var block_off: usize = 0;
        var prev_off: ?usize = null;

        while (block_off + EXT2_DIR_HEADER_SIZE <= block_size) {
            const de_inode = readU32FromBlock(blk, @truncate(block_off));
            const de_rec_len = @as(u16, blk[block_off + 4]) |
                (@as(u16, blk[block_off + 5]) << 8);
            const de_name_len = blk[block_off + 6];
            const de_file_type = blk[block_off + 7];

            if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

            if (de_inode != 0 and de_name_len == name.len) {
                const name_start = block_off + EXT2_DIR_HEADER_SIZE;
                var match = true;
                for (0..name.len) |i| {
                    if (blk[name_start + i] != name[i]) {
                        match = false;
                        break;
                    }
                }

                if (match) {
                    // Reject if target is a directory
                    if (de_file_type == EXT2_FT_DIR) return false;

                    // Remove entry: merge with previous or zero inode
                    if (prev_off) |po| {
                        // Merge rec_len with previous entry
                        const prev_rec_len = @as(u16, blk[po + 4]) |
                            (@as(u16, blk[po + 5]) << 8);
                        const merged = prev_rec_len + de_rec_len;
                        blk[po + 4] = @truncate(merged);
                        blk[po + 5] = @truncate(merged >> 8);
                    } else {
                        // First entry in block — zero the inode field
                        writeU32ToBlock(blk, @truncate(block_off), 0);
                    }

                    beginJournalTx(1);
                    if (!writeBlock(phys_block, blk)) { commitJournalTx(); return false; }
                    commitJournalTx();

                    // Decrement nlink — only free blocks/inode when it reaches 0
                    const target_disk = loadInodeDisk(de_inode);
                    if (target_disk) |tdi| {
                        var td = tdi;
                        if (td.i_links_count > 0) {
                            td.i_links_count -= 1;
                        }
                        if (td.i_links_count == 0) {
                            freeFileBlocks(&td);
                            _ = writeInodeDisk(de_inode, &td);
                            _ = freeInode(de_inode);
                        } else {
                            _ = writeInodeDisk(de_inode, &td);
                        }
                    }

                    // Invalidate cached VFS inode so nlink is re-read
                    invalidateInodeCache(de_inode);

                    return true;
                }
            }

            prev_off = block_off;
            block_off += de_rec_len;
        }

        offset = (@as(u64, file_block) + 1) * block_size;
    }

    return false; // Entry not found
}

fn isDirEmpty(cache_entry: *Ext2InodeCache) bool {
    const dir_size: u64 = cache_entry.disk_inode.i_size;
    var offset: u64 = 0;

    while (offset < dir_size) {
        const file_block: u32 = @truncate(offset / block_size);
        const block_offset: usize = @truncate(offset % block_size);

        const phys_block = getFileBlock(cache_entry, file_block) orelse return true;
        const block_data = readBlock(phys_block) orelse return true;

        if (block_offset + EXT2_DIR_HEADER_SIZE > block_size) break;

        const de_inode = readU32FromBlock(block_data, @truncate(block_offset));
        const de_rec_len = @as(u16, block_data[block_offset + 4]) |
            (@as(u16, block_data[block_offset + 5]) << 8);
        const de_name_len = block_data[block_offset + 6];

        if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

        if (de_inode != 0) {
            const name_start = block_offset + EXT2_DIR_HEADER_SIZE;
            if (de_name_len == 1 and block_data[name_start] == '.') {
                // "." — skip
            } else if (de_name_len == 2 and block_data[name_start] == '.' and block_data[name_start + 1] == '.') {
                // ".." — skip
            } else {
                return false; // Found a real entry
            }
        }

        offset += de_rec_len;
    }

    return true;
}

fn ext2Rmdir(parent: *vfs.Inode, name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;

    const parent_cache: *Ext2InodeCache = @alignCast(@ptrCast(
        parent.fs_data orelse return false,
    ));

    const dir_size: u64 = parent_cache.disk_inode.i_size;
    var offset: u64 = 0;

    while (offset < dir_size) {
        const file_block: u32 = @truncate(offset / block_size);
        const phys_block = getFileBlock(parent_cache, file_block) orelse break;
        const blk = readBlock(phys_block) orelse break;

        var block_off: usize = 0;
        var prev_off: ?usize = null;

        while (block_off + EXT2_DIR_HEADER_SIZE <= block_size) {
            const de_inode = readU32FromBlock(blk, @truncate(block_off));
            const de_rec_len = @as(u16, blk[block_off + 4]) |
                (@as(u16, blk[block_off + 5]) << 8);
            const de_name_len = blk[block_off + 6];
            const de_file_type = blk[block_off + 7];

            if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

            if (de_inode != 0 and de_name_len == name.len) {
                const name_start = block_off + EXT2_DIR_HEADER_SIZE;
                var match = true;
                for (0..name.len) |i| {
                    if (blk[name_start + i] != name[i]) {
                        match = false;
                        break;
                    }
                }

                if (match) {
                    // Must be a directory
                    if (de_file_type != EXT2_FT_DIR) return false;

                    // Load and check if empty
                    const target_inode = loadInode(de_inode) orelse return false;
                    const target_cache: *Ext2InodeCache = @alignCast(@ptrCast(
                        target_inode.fs_data orelse return false,
                    ));
                    if (!isDirEmpty(target_cache)) return false;

                    // Remove directory entry from parent
                    if (prev_off) |po| {
                        const prev_rec_len = @as(u16, blk[po + 4]) |
                            (@as(u16, blk[po + 5]) << 8);
                        const merged = prev_rec_len + de_rec_len;
                        blk[po + 4] = @truncate(merged);
                        blk[po + 5] = @truncate(merged >> 8);
                    } else {
                        writeU32ToBlock(blk, @truncate(block_off), 0);
                    }
                    beginJournalTx(1);
                    if (!writeBlock(phys_block, blk)) { commitJournalTx(); return false; }
                    commitJournalTx();

                    // Free directory blocks and inode
                    freeFileBlocks(&target_cache.disk_inode);
                    target_cache.disk_inode.i_links_count = 0;
                    _ = writeInodeDisk(de_inode, &target_cache.disk_inode);
                    _ = freeInode(de_inode);
                    invalidateInodeCache(de_inode);

                    // Decrement parent nlink (for .. reference removal)
                    if (parent_cache.disk_inode.i_links_count > 0) {
                        parent_cache.disk_inode.i_links_count -= 1;
                        parent.nlink = parent_cache.disk_inode.i_links_count;
                        _ = writeInodeDisk(parent_cache.ino, &parent_cache.disk_inode);
                    }

                    // Update BGD used_dirs_count
                    const bgd = readBlockGroup(0);
                    if (bgd) |b| {
                        var bgd_copy = b;
                        if (bgd_copy.bg_used_dirs_count > 0) {
                            bgd_copy.bg_used_dirs_count -= 1;
                        }
                        beginJournalTx(1);
                        _ = writeBlockGroupDesc(0, &bgd_copy);
                        commitJournalTx();
                    }

                    return true;
                }
            }

            prev_off = block_off;
            block_off += de_rec_len;
        }

        offset = (@as(u64, file_block) + 1) * block_size;
    }

    return false;
}

/// Rename: move a directory entry from old_parent/old_name to new_parent/new_name.
/// Handles same-dir and cross-dir renames. If dest exists, unlinks it first.
fn ext2Rename(old_parent: *vfs.Inode, old_name: []const u8, new_parent: *vfs.Inode, new_name: []const u8) bool {
    if (old_name.len == 0 or old_name.len > 255 or new_name.len == 0 or new_name.len > 255) return false;

    const old_parent_cache: *Ext2InodeCache = @alignCast(@ptrCast(
        old_parent.fs_data orelse return false,
    ));

    // Find the source entry: walk old_parent directory to get inode number and file_type
    var src_ino: u32 = 0;
    var src_file_type: u8 = 0;
    {
        const dir_size: u64 = old_parent_cache.disk_inode.i_size;
        var offset: u64 = 0;
        while (offset < dir_size) {
            const file_block: u32 = @truncate(offset / block_size);
            const phys_block = getFileBlock(old_parent_cache, file_block) orelse break;
            const blk = readBlock(phys_block) orelse break;

            var block_off: usize = @truncate(offset % block_size);
            while (block_off + EXT2_DIR_HEADER_SIZE <= block_size) {
                const de_inode = readU32FromBlock(blk, @truncate(block_off));
                const de_rec_len = @as(u16, blk[block_off + 4]) |
                    (@as(u16, blk[block_off + 5]) << 8);
                const de_name_len = blk[block_off + 6];
                const de_file_type = blk[block_off + 7];

                if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

                if (de_inode != 0 and de_name_len == old_name.len) {
                    const name_start = block_off + EXT2_DIR_HEADER_SIZE;
                    var match = true;
                    for (0..old_name.len) |i| {
                        if (blk[name_start + i] != old_name[i]) {
                            match = false;
                            break;
                        }
                    }
                    if (match) {
                        src_ino = de_inode;
                        src_file_type = de_file_type;
                        break;
                    }
                }

                block_off += de_rec_len;
            }
            if (src_ino != 0) break;
            offset = (@as(u64, @truncate(offset / block_size)) + 1) * block_size;
        }
    }

    if (src_ino == 0) return false; // Source not found

    // If dest exists, unlink it first
    if (lookup(new_parent, new_name) != null) {
        // Check if it's a directory or file and call appropriate unlink
        const new_parent_cache: *Ext2InodeCache = @alignCast(@ptrCast(
            new_parent.fs_data orelse return false,
        ));
        _ = new_parent_cache;

        // Try file unlink first, then dir rmdir
        if (!ext2Unlink(new_parent, new_name)) {
            // Might be a directory — try rmdir
            if (!ext2Rmdir(new_parent, new_name)) return false;
        }
    }

    // Add entry in new_parent
    const new_parent_cache2: *Ext2InodeCache = @alignCast(@ptrCast(
        new_parent.fs_data orelse return false,
    ));
    if (!addDirEntry(new_parent_cache2, src_ino, new_name, src_file_type)) return false;

    // Remove entry from old_parent (zero the inode field or merge with prev)
    {
        const dir_size: u64 = old_parent_cache.disk_inode.i_size;
        var offset: u64 = 0;
        while (offset < dir_size) {
            const file_block: u32 = @truncate(offset / block_size);
            const phys_block = getFileBlock(old_parent_cache, file_block) orelse break;
            const blk = readBlock(phys_block) orelse break;

            var block_off: usize = @truncate(offset % block_size);
            var prev_off: ?usize = null;

            while (block_off + EXT2_DIR_HEADER_SIZE <= block_size) {
                const de_inode = readU32FromBlock(blk, @truncate(block_off));
                const de_rec_len = @as(u16, blk[block_off + 4]) |
                    (@as(u16, blk[block_off + 5]) << 8);
                const de_name_len = blk[block_off + 6];

                if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

                if (de_inode != 0 and de_name_len == old_name.len) {
                    const name_start = block_off + EXT2_DIR_HEADER_SIZE;
                    var match = true;
                    for (0..old_name.len) |i| {
                        if (blk[name_start + i] != old_name[i]) {
                            match = false;
                            break;
                        }
                    }

                    if (match) {
                        if (prev_off) |po| {
                            const prev_rec_len = @as(u16, blk[po + 4]) |
                                (@as(u16, blk[po + 5]) << 8);
                            const merged = prev_rec_len + de_rec_len;
                            blk[po + 4] = @truncate(merged);
                            blk[po + 5] = @truncate(merged >> 8);
                        } else {
                            writeU32ToBlock(blk, @truncate(block_off), 0);
                        }
                        beginJournalTx(1);
                        _ = writeBlock(phys_block, blk);
                        commitJournalTx();

                        // If renaming a directory across parents, update ".." entry
                        if (src_file_type == EXT2_FT_DIR and old_parent.ino != new_parent.ino) {
                            const child_inode = loadInode(src_ino);
                            if (child_inode) |ci| {
                                const child_cache: *Ext2InodeCache = @alignCast(@ptrCast(
                                    ci.fs_data orelse return true,
                                ));
                                // Update ".." to point to new parent
                                if (child_cache.disk_inode.i_block[0] != 0) {
                                    const dir_blk = readBlock(child_cache.disk_inode.i_block[0]);
                                    if (dir_blk) |db| {
                                        // ".." is at offset 12 (after "." entry)
                                        writeU32ToBlock(db, 12, new_parent_cache2.ino);
                                        beginJournalTx(1);
                                        _ = writeBlock(child_cache.disk_inode.i_block[0], db);
                                        commitJournalTx();
                                    }
                                }
                                // Adjust link counts
                                if (old_parent_cache.disk_inode.i_links_count > 0) {
                                    old_parent_cache.disk_inode.i_links_count -= 1;
                                    old_parent.nlink = old_parent_cache.disk_inode.i_links_count;
                                    _ = writeInodeDisk(old_parent_cache.ino, &old_parent_cache.disk_inode);
                                }
                                new_parent_cache2.disk_inode.i_links_count += 1;
                                new_parent.nlink = new_parent_cache2.disk_inode.i_links_count;
                                _ = writeInodeDisk(new_parent_cache2.ino, &new_parent_cache2.disk_inode);
                            }
                        }
                        return true;
                    }
                }

                prev_off = block_off;
                block_off += de_rec_len;
            }
            offset = (@as(u64, @truncate(offset / block_size)) + 1) * block_size;
        }
    }

    return false; // Could not remove old entry (shouldn't happen)
}

fn invalidateInodeCache(ino: u32) void {
    for (0..INODE_CACHE_SIZE) |i| {
        if (inode_cache[i].in_use and inode_cache[i].ino == ino) {
            inode_cache[i].in_use = false;
            return;
        }
    }
}

// ---- Inode pinning (prevents cache eviction during demand paging) ----

/// Pin a VFS inode to prevent its cache entry from being evicted.
pub fn pinInode(inode: *vfs.Inode) void {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        inode.fs_data orelse return,
    ));
    cache_entry.pin_count += 1;
}

/// Unpin a VFS inode.
pub fn unpinInode(inode: *vfs.Inode) void {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        inode.fs_data orelse return,
    ));
    if (cache_entry.pin_count > 0) {
        cache_entry.pin_count -= 1;
    }
}

/// Unpin all inodes (called on execve to release previous executable's pin).
pub fn unpinAllInodes() void {
    for (0..INODE_CACHE_SIZE) |i| {
        inode_cache[i].pin_count = 0;
    }
}

// ---- Sync / Shutdown ----

pub fn sync() void {
    _ = writeSuperblock();
    const bgd = readBlockGroup(0);
    if (bgd) |b| {
        _ = writeBlockGroupDesc(0, &b);
    }
}

/// Flush a specific file's data and metadata to disk.
/// Commits any pending journal transaction, then writes superblock + BGD.
pub fn syncFile() void {
    if (journal_tx_active) commitJournalTx();
    sync();
}

/// Clean unmount — flush journal and mark clean.
pub fn deinit() void {
    ext3_mount.shutdownJournal();
    initialized = false;
}

// ---- Public helpers for syscall layer ----

/// Update inode mode (permission bits) on disk. Called by chmod syscall.
/// Flush inode metadata (size, mode, nlink) to disk. Called by fsync.
pub fn writeInodeMetadata(inode: *vfs.Inode) void {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        inode.fs_data orelse return,
    ));
    cache_entry.disk_inode.i_size = @truncate(inode.size);
    cache_entry.disk_inode.i_mode = @truncate(inode.mode);
    cache_entry.disk_inode.i_links_count = @truncate(inode.nlink);
    _ = writeInodeDisk(cache_entry.ino, &cache_entry.disk_inode);
}

pub fn setInodeMode(inode: *vfs.Inode) void {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        inode.fs_data orelse return,
    ));
    cache_entry.disk_inode.i_mode = @truncate(inode.mode);
    _ = writeInodeDisk(cache_entry.ino, &cache_entry.disk_inode);
}

/// Update inode uid/gid on disk. Called by chown syscall.
pub fn setInodeOwner(inode: *vfs.Inode) void {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        inode.fs_data orelse return,
    ));
    cache_entry.disk_inode.i_uid = inode.uid;
    cache_entry.disk_inode.i_gid = inode.gid;
    _ = writeInodeDisk(cache_entry.ino, &cache_entry.disk_inode);
}

/// Read symlink target. ext2 fast symlinks store target in i_block[] if size <= 60 bytes.
fn ext2Readlink(inode: *vfs.Inode, buf: [*]u8, bufsiz: usize) isize {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        inode.fs_data orelse return -1,
    ));

    const target_len: usize = @truncate(inode.size);
    const copy_len = @min(target_len, bufsiz);

    if (target_len <= 60) {
        // Fast symlink: target stored in i_block[0..14] (60 bytes)
        const block_ptr: *const [60]u8 = @ptrCast(&cache_entry.disk_inode.i_block);
        for (0..copy_len) |i| {
            buf[i] = block_ptr[i];
        }
    } else {
        // Slow symlink: target stored in data block
        const blk_num = cache_entry.disk_inode.i_block[0];
        const blk_data = readBlock(blk_num) orelse return -1;
        for (0..copy_len) |i| {
            buf[i] = blk_data[i];
        }
    }

    return @intCast(copy_len);
}

/// Create a symbolic link. VFS op: parent.ops.symlink(parent, name, target).
fn ext2SymlinkOp(parent: *vfs.Inode, name: []const u8, target: []const u8) ?*vfs.Inode {
    if (name.len == 0 or name.len > 255 or target.len == 0 or target.len > 255) return null;
    if (lookup(parent, name) != null) return null;

    const parent_cache: *Ext2InodeCache = @alignCast(@ptrCast(
        parent.fs_data orelse return null,
    ));

    const new_ino = allocInode() orelse return null;

    var disk_inode: Ext2DiskInode = undefined;
    const zero: *[128]u8 = @ptrCast(&disk_inode);
    for (0..128) |i| zero[i] = 0;

    // S_IFLNK | 0o777 = 0xA000 | 0o777
    disk_inode.i_mode = 0xA000 | 0o777;
    disk_inode.i_links_count = 1;
    disk_inode.i_size = @truncate(target.len);

    if (scheduler.currentProcess()) |proc| {
        disk_inode.i_uid = proc.euid;
        disk_inode.i_gid = proc.egid;
    }

    if (target.len <= 60) {
        // Fast symlink: store target in i_block[]
        const block_ptr: *[60]u8 = @ptrCast(&disk_inode.i_block);
        for (0..target.len) |i| {
            block_ptr[i] = target[i];
        }
    } else {
        // Slow symlink: allocate a data block
        const data_blk = allocBlock() orelse {
            _ = freeInode(new_ino);
            return null;
        };
        const blk = readBlock(data_blk) orelse {
            _ = freeBlock(data_blk);
            _ = freeInode(new_ino);
            return null;
        };
        for (0..block_size) |i| blk[i] = 0;
        for (0..target.len) |i| blk[i] = target[i];

        beginJournalTx(1);
        if (!writeBlock(data_blk, blk)) {
            commitJournalTx();
            _ = freeBlock(data_blk);
            _ = freeInode(new_ino);
            return null;
        }
        commitJournalTx();

        disk_inode.i_block[0] = data_blk;
        disk_inode.i_blocks = block_size / 512;
    }

    if (!writeInodeDisk(new_ino, &disk_inode)) {
        _ = freeInode(new_ino);
        return null;
    }

    if (!addDirEntry(parent_cache, new_ino, name, EXT2_FT_SYMLINK)) {
        _ = freeInode(new_ino);
        return null;
    }

    return loadInode(new_ino);
}

/// Create a hard link. VFS op: parent.ops.link(parent, name, target_inode).
fn ext2LinkOp(parent: *vfs.Inode, name: []const u8, target: *vfs.Inode) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (lookup(parent, name) != null) return false;

    const parent_cache: *Ext2InodeCache = @alignCast(@ptrCast(
        parent.fs_data orelse return false,
    ));

    const target_cache: *Ext2InodeCache = @alignCast(@ptrCast(
        target.fs_data orelse return false,
    ));

    // Determine file type for directory entry
    const mode_type = target_cache.disk_inode.i_mode & 0xF000;
    const file_type: u8 = if (mode_type == 0x4000) EXT2_FT_DIR else if (mode_type == 0xA000) EXT2_FT_SYMLINK else EXT2_FT_REG_FILE;

    // Add directory entry pointing to existing inode
    if (!addDirEntry(parent_cache, target_cache.ino, name, file_type)) return false;

    // Increment nlink
    target_cache.disk_inode.i_links_count += 1;
    target.nlink = target_cache.disk_inode.i_links_count;
    _ = writeInodeDisk(target_cache.ino, &target_cache.disk_inode);

    return true;
}

// ---- Output helpers ----

fn writeDecimal(value: u64) void {
    if (value == 0) {
        serial.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    serial.writeString(buf[i..]);
}

fn writeHex16(val: u16) void {
    const hex = "0123456789abcdef";
    var buf: [4]u8 = undefined;
    buf[0] = hex[@as(usize, val >> 12)];
    buf[1] = hex[@as(usize, (val >> 8) & 0xf)];
    buf[2] = hex[@as(usize, (val >> 4) & 0xf)];
    buf[3] = hex[@as(usize, val & 0xf)];
    serial.writeString(&buf);
}
