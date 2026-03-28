/// ext2 filesystem driver — read-write (write-through).
/// Parses superblock, reads/writes inodes, follows block pointers, traverses directories.
/// Integrates with VFS via FileOperations vtable: read, write, create, unlink, truncate.

const vfs = @import("vfs.zig");
const serial = @import("uart.zig");
const spinlock = @import("spinlock.zig");
const block_io = @import("block_io.zig");
const page_cache = @import("page_cache.zig");
const pmm = @import("pmm.zig");
const scheduler = @import("scheduler.zig");
const rtc = @import("rtc.zig");

// --- Stubs for ext3/ext4 features not yet ported to RISC-V ---
// These return false/null/no-op so ext2 basic functionality works without
// journal, extents, htree, mballoc, or delayed allocation.
const journal_mod = struct {
    pub fn isJournaling() bool { return false; }
    pub fn isActive() bool { return false; }
    pub fn beginTx(_: u32) void {}
    pub fn commitTx() void {}
    pub fn writeBlock(_: [*]const u8, _: u32) bool { return true; }
    pub fn revoke(_: u64) void {}
    pub fn stop() void {}
    pub fn start(_: u32) bool { return false; }
};
const extents = struct {
    pub const EXTENT_MAGIC: u16 = 0xF30A;
    pub const ExtentHeader = struct {
        magic: u16 = 0,
        entries: u16 = 0,
        max: u16 = 0,
        depth: u16 = 0,
        generation: u32 = 0,
        pub fn isValid(_: *const @This()) bool { return false; }
        pub fn isLeaf(_: *const @This()) bool { return true; }
    };
    pub const ExtentIdx = struct {
        block: u32 = 0,
        pub fn childBlock(_: *const @This()) u64 { return 0; }
        pub fn setChildBlock(_: *@This(), _: u64) void {}
    };
    pub const Extent = struct {
        block: u32 = 0,
        len: u16 = 0,
        start_hi: u16 = 0,
        start_lo: u32 = 0,
        pub fn physicalBlock(_: *const @This()) u64 { return 0; }
        pub fn blockCount(_: *const @This()) u16 { return 0; }
    };
    pub fn lookup(_: anytype, _: u32, _: anytype) ?u64 { return null; }
    pub fn insert(_: anytype, _: Extent) bool { return false; }
    pub fn insertInLeaf(_: anytype, _: Extent) bool { return false; }
    pub fn usesExtents(_: anytype) bool { return false; }
    pub fn getHeader(_: anytype) *const ExtentHeader {
        const static = struct { var h: ExtentHeader = .{}; };
        return &static.h;
    }
    pub fn getHeaderMut(_: anytype) *ExtentHeader {
        const static = struct { var h: ExtentHeader = .{}; };
        return &static.h;
    }
    pub fn getExtents(_: anytype) [*]const Extent {
        const static = struct { var e: [1]Extent = .{.{}}; };
        return &static.e;
    }
    pub fn getExtentsMut(_: anytype) [*]Extent {
        const static = struct { var e: [1]Extent = .{.{}}; };
        return &static.e;
    }
    pub fn getIndices(_: anytype) [*]const ExtentIdx {
        const static = struct { var e: [1]ExtentIdx = .{.{}}; };
        return &static.e;
    }
    pub fn getIndicesMut(_: anytype) [*]ExtentIdx {
        const static = struct { var e: [1]ExtentIdx = .{.{}}; };
        return &static.e;
    }
    pub fn maxEntriesPerBlock(_: u32) u16 { return 340; }
    pub fn initRoot(_: *[60]u8) void {}
};
const inode_ext4 = struct {
    pub fn isExt4Inode(_: anytype) bool { return false; }
    pub fn getExtraIsize(_: anytype) u16 { return 0; }
    pub fn verifyChecksum(_: [*]const u8, _: u16, _: u32, _: *const [16]u8) bool { return true; }
    pub fn storeChecksum(_: [*]u8, _: u16, _: u32, _: *const [16]u8) void {}
};
const block_group_64 = struct {
    pub const BlockGroupDesc64 = extern struct {
        placeholder: u64 = 0,
        checksum: u16 = 0,
        pub fn computeChecksum(_: *const @This(), _: u32, _: *const [16]u8, _: u16) u16 { return 0; }
        pub fn verifyChecksum(_: *const @This(), _: u32, _: *const [16]u8, _: u16) bool { return true; }
    };
    pub fn is64Bit(_: u32) bool { return false; }
    pub fn descSize(_: u32, _: u16) u16 { return 32; }
    pub fn getBlockBitmapBlock(_: anytype) u64 { return 0; }
    pub fn getInodeBitmapBlock(_: anytype) u64 { return 0; }
    pub fn getInodeTableBlock(_: anytype) u64 { return 0; }
};
const htree = struct {
    pub const DxRoot = extern struct {
        hash_version: u8 = 0,
        count: u16 = 0,
        indirect_levels: u8 = 0,
    };
    pub const DxNode = extern struct {
        count: u16 = 0,
    };
    pub fn isHtreeDir(_: anytype) bool { return false; }
    pub fn usesHTree(_: anytype) bool { return false; }
    pub fn computeHash(_: [*]const u8, _: u8, _: [4]u32, _: u8) u32 { return 0; }
    pub fn getRootEntries(_: anytype) [*]const u8 { return @as([*]const u8, @ptrFromInt(0x1000)); }
    pub fn getNodeEntries(_: anytype) [*]const u8 { return @as([*]const u8, @ptrFromInt(0x1000)); }
    pub fn searchEntries(_: anytype, _: u16, _: u32) u32 { return 0; }
};
const mballoc = struct {
    pub const BlockGroupState = struct {
        bg_number: u32 = 0,
        bitmap_block: u64 = 0,
        free_blocks: u32 = 0,
        blocks_per_group: u32 = 0,
        first_data_block: u32 = 0,
    };
    pub const AllocRequest = struct {
        count: u32 = 1,
        goal: u32 = 0,
        preferred_bg: u32 = 0,
        min_count: u32 = 1,
    };
    pub const AllocResult = struct {
        start: u64 = 0,
        count: u64 = 0,
    };
    pub fn isEnabled() bool { return false; }
    pub fn allocBlocks(_: u32, _: u32) ?u32 { return null; }
    pub fn allocFromBitmap(_: anytype, _: u32, _: *const AllocRequest, _: *const BlockGroupState, _: *AllocResult) bool { return false; }
};
const delayed_alloc = struct {
    pub const DirtyRange = struct {
        valid: bool = false,
        logical_start: u32 = 0,
        count: u32 = 0,
    };
    pub const DelayedState = struct {
        reserved_blocks: u32 = 0,
        dirty_ranges: [8]DirtyRange = [_]DirtyRange{.{}} ** 8,
        pub fn reset(_: *@This(), _: *u64) void {}
    };
    pub fn isEnabled() bool { return false; }
    pub fn reserveBlocks(_: u32) bool { return false; }
    pub fn flushReserved() void {}
};
const ext3_mount = struct {
    pub fn isJournalEnabled() bool { return false; }
    pub fn initJournal(_: u32, _: u32, _: u32, _: u32, _: u16, _: u32, _: u64) bool { return false; }
};

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
const EXT2_FT_CHRDEV: u8 = 3;
const EXT2_FT_BLKDEV: u8 = 4;
const EXT2_FT_FIFO: u8 = 5;
const EXT2_FT_SOCK: u8 = 6;
const EXT2_FT_SYMLINK: u8 = 7;

/// Pending rdev for mknod syscall (set before createInode).
pub var pending_mknod_rdev: u32 = 0;

fn currentTimestamp() u32 {
    return @truncate(rtc.getEpochSeconds());
}

fn modeToFt(mode: u32) u8 {
    return switch (mode & vfs.S_IFMT) {
        vfs.S_IFDIR => EXT2_FT_DIR,
        vfs.S_IFCHR => EXT2_FT_CHRDEV,
        vfs.S_IFBLK => EXT2_FT_BLKDEV,
        vfs.S_IFIFO => EXT2_FT_FIFO,
        vfs.S_IFSOCK => EXT2_FT_SOCK,
        vfs.S_IFLNK => EXT2_FT_SYMLINK,
        else => EXT2_FT_REG_FILE,
    };
}

// ---- Block cache ----

const BLOCK_CACHE_SIZE: usize = 2048;
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
    @memset(&cache, BlockCacheEntry{
        .valid = false,
        .dirty = false,
        .block_num = 0,
        .data = [_]u8{0} ** MAX_BLOCK_SIZE,
        .lru_prev = LRU_NONE,
        .lru_next = LRU_NONE,
    });
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
    var i: usize = 0;
    while (i < BLOCK_CACHE_SIZE) : (i += 1) {
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

    // Read from disk with retry for transient virtio failures under TCG
    const sectors_per_block = block_size / 512;
    const sector_start = block_num * sectors_per_block;

    var attempts: u32 = 0;
    while (attempts < 3) : (attempts += 1) {
        if (block_io.readSectors(sector_start, @truncate(sectors_per_block), &block_cache[idx].data))
            break;
        // Brief spin delay before retry
        for (0..10000) |_| asm volatile ("nop");
    }
    if (attempts >= 3) {
        serial.print("[ext2] readBlock FAILED blk={} sector={} after 3 retries\n", .{ block_num, sector_start });
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
        // Direct disk write with retry
        const sectors_per_block = block_size / 512;
        const sector_start = block_num * sectors_per_block;
        var w_attempts: u32 = 0;
        while (w_attempts < 3) : (w_attempts += 1) {
            if (block_io.writeSectors(sector_start, @truncate(sectors_per_block), data))
                break;
            for (0..10000) |_| asm volatile ("nop");
        }
        if (w_attempts >= 3) return false;
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
    const ds: u32 = @as(u32, desc_size); // 64 for ext4, 32 for ext2/ext3
    const bgd_per_block = block_size / ds;

    const target_block = bgdt_block + @as(u64, group / bgd_per_block);
    const blk = readBlock(target_block) orelse return false;

    const offset = (group % bgd_per_block) * ds;

    // Copy first 32 bytes (standard ext2 fields) from the struct
    const src: *const [32]u8 = @ptrCast(bgd);
    for (0..32) |i| {
        blk[offset + i] = src[i];
    }

    // Recompute BGD checksum if metadata_csum enabled
    if (superblock.s_feature_ro_compat & 0x0400 != 0 and ds >= 64) {
        const bgd64: *const block_group_64.BlockGroupDesc64 = @ptrCast(@alignCast(blk + offset));
        const csum = bgd64.computeChecksum(group, &superblock.s_uuid, @truncate(ds));
        // Write checksum at offset 0x1E within the descriptor
        blk[offset + 0x1E] = @truncate(csum);
        blk[offset + 0x1F] = @truncate(csum >> 8);
    }

    return writeBlock(target_block, blk);
}

// ---- Bitmap allocation ----

fn allocBlock() ?u32 {
    return allocBlockNear(0);
}

/// Convert a block number to its block group.
fn blockToGroup(blk: u64) u32 {
    return @truncate(blk / blocks_per_group);
}

/// Convert a block group + local offset to a global block number.
fn groupToBlock(group: u32, local_bit: u32) u64 {
    return @as(u64, group) * blocks_per_group + local_bit;
}

/// Try to allocate a single block from a specific block group.
fn allocBlockFromGroup(group: u32, goal_local: u32) ?u64 {
    const bgd = readBlockGroup(group) orelse return null;
    if (bgd.bg_free_blocks_count == 0) return null;

    const bitmap_block: u64 = bgd.bg_block_bitmap;
    const bmap = readBlock(bitmap_block) orelse return null;

    const bitmap_capacity: u32 = block_size * 8;
    const max_bits: u32 = @min(blocks_per_group, bitmap_capacity);

    const bg_state = mballoc.BlockGroupState{
        .bg_number = group,
        .bitmap_block = bitmap_block,
        .free_blocks = bgd.bg_free_blocks_count,
        .blocks_per_group = blocks_per_group,
        .first_data_block = superblock.s_first_data_block,
    };
    const req = mballoc.AllocRequest{
        .count = 1,
        .goal = if (goal_local > 0) goal_local else 20,
        .preferred_bg = group,
        .min_count = 1,
    };
    var result: mballoc.AllocResult = .{};

    if (mballoc.allocFromBitmap(bmap, max_bits, &req, &bg_state, &result)) {
        const local_bit: u32 = @truncate(result.start);
        const global_blk: u64 = groupToBlock(group, local_bit);

        superblock.s_free_blocks_count -= 1;
        var bgd_copy = bgd;
        bgd_copy.bg_free_blocks_count -= 1;

        beginJournalTx(3);
        if (!writeBlock(bitmap_block, bmap)) { commitJournalTx(); return null; }
        if (!writeSuperblock()) { commitJournalTx(); return null; }
        if (!writeBlockGroupDesc(group, &bgd_copy)) { commitJournalTx(); return null; }
        commitJournalTx();

        // Zero the new block
        const new_blk = readBlock(global_blk) orelse return null;
        for (0..block_size) |i| new_blk[i] = 0;
        if (!writeBlock(global_blk, new_blk)) return null;

        return global_blk;
    }
    return null;
}

/// Allocate a single block, preferring allocation near `goal` block for locality.
/// Scans all block groups starting from the preferred group.
fn allocBlockNear(goal: u64) ?u32 {
    const preferred_group = if (goal > 0) blockToGroup(goal) else 0;
    const goal_local: u32 = if (goal > 0) @truncate(goal % blocks_per_group) else 20;

    // Try preferred group first
    if (allocBlockFromGroup(preferred_group, goal_local)) |blk|
        return @truncate(blk);

    // Scan remaining groups
    var g: u32 = 0;
    while (g < num_groups) : (g += 1) {
        if (g == preferred_group) continue;
        if (allocBlockFromGroup(g, 0)) |blk|
            return @truncate(blk);
    }
    return null;
}

/// Allocate N contiguous blocks for extent-based files.
/// Scans all block groups for the best fit.
fn allocBlocksContiguous(count: u32, goal: u64) ?struct { start: u32, count: u32 } {
    const preferred_group = if (goal > 0) blockToGroup(goal) else 0;
    const goal_local: u32 = if (goal > 0) @truncate(goal % blocks_per_group) else 20;

    // Try each block group starting from preferred
    var attempts: u32 = 0;
    while (attempts < num_groups) : (attempts += 1) {
        const g = (preferred_group + attempts) % num_groups;
        const bgd = readBlockGroup(g) orelse continue;
        if (bgd.bg_free_blocks_count < 1) continue; // min_count=1

        const bitmap_block: u64 = bgd.bg_block_bitmap;
        const bmap = readBlock(bitmap_block) orelse continue;
        const bitmap_capacity: u32 = block_size * 8;
        const max_bits: u32 = @min(blocks_per_group, bitmap_capacity);

        const bg_state = mballoc.BlockGroupState{
            .bg_number = g,
            .bitmap_block = bitmap_block,
            .free_blocks = bgd.bg_free_blocks_count,
            .blocks_per_group = blocks_per_group,
            .first_data_block = superblock.s_first_data_block,
        };
        const req = mballoc.AllocRequest{
            .count = count,
            .goal = if (attempts == 0) goal_local else 0,
            .preferred_bg = g,
            .min_count = 1,
        };
        var result: mballoc.AllocResult = .{};

        if (mballoc.allocFromBitmap(bmap, max_bits, &req, &bg_state, &result)) {
            superblock.s_free_blocks_count -= @as(u32, @truncate(result.count));
            var bgd_copy = bgd;
            bgd_copy.bg_free_blocks_count -= @truncate(result.count);

            beginJournalTx(3);
            if (!writeBlock(bitmap_block, bmap)) { commitJournalTx(); continue; }
            if (!writeSuperblock()) { commitJournalTx(); continue; }
            if (!writeBlockGroupDesc(g, &bgd_copy)) { commitJournalTx(); continue; }
            commitJournalTx();

            // Zero allocated blocks — convert local bit to global block
            const local_start: u32 = @truncate(result.start);
            const global_start: u32 = @truncate(groupToBlock(g, local_start));
            var i: u32 = 0;
            while (i < result.count) : (i += 1) {
                const blk = readBlock(global_start + i) orelse return null;
                for (0..block_size) |j| blk[j] = 0;
                _ = writeBlock(global_start + i, blk);
            }

            return .{ .start = global_start, .count = result.count };
        }
    }
    return null;
}

/// Free a block, determining the correct block group from the block number.
fn freeBlock(blk: u32) bool {
    if (blk == 0) return true;

    const group = @as(u32, blk) / blocks_per_group;
    const local_bit = @as(u32, blk) % blocks_per_group;

    if (group >= num_groups) return true; // Out of range

    const bgd = readBlockGroup(group) orelse return false;
    const bitmap_block: u64 = bgd.bg_block_bitmap;
    const bitmap = readBlock(bitmap_block) orelse return false;

    // Check if bit is within bitmap capacity
    const bitmap_capacity: u32 = block_size * 8;
    if (local_bit >= bitmap_capacity) return true; // Overflow zone

    const byte_idx = local_bit / 8;
    const bit_idx: u3 = @truncate(local_bit % 8);
    bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);

    superblock.s_free_blocks_count += 1;
    var bgd_copy = bgd;
    bgd_copy.bg_free_blocks_count += 1;

    beginJournalTx(3);
    if (!writeBlock(bitmap_block, bitmap)) { commitJournalTx(); return false; }
    if (!writeSuperblock()) { commitJournalTx(); return false; }
    if (!writeBlockGroupDesc(group, &bgd_copy)) { commitJournalTx(); return false; }
    commitJournalTx();

    _ = journal_mod.revoke(blk);
    return true;
}

/// Allocate an inode, scanning all block groups.
fn allocInode() ?u32 {
    var g: u32 = 0;
    while (g < num_groups) : (g += 1) {
        const bgd = readBlockGroup(g) orelse continue;
        if (bgd.bg_free_inodes_count == 0) continue;

        const bitmap_block: u64 = bgd.bg_inode_bitmap;
        const bitmap = readBlock(bitmap_block) orelse continue;

        // First group: skip reserved inodes (1-11); other groups start at 0
        const start_bit: u32 = if (g == 0) 11 else 0;
        const max_bits: u32 = inodes_per_group;

        var bit: u32 = start_bit;
        while (bit < max_bits) : (bit += 1) {
            const byte_idx = bit / 8;
            const bit_idx: u3 = @truncate(bit % 8);
            if (bitmap[byte_idx] & (@as(u8, 1) << bit_idx) == 0) {
                bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
                superblock.s_free_inodes_count -= 1;
                var bgd_copy = bgd;
                bgd_copy.bg_free_inodes_count -= 1;

                beginJournalTx(3);
                if (!writeBlock(bitmap_block, bitmap)) { commitJournalTx(); return null; }
                if (!writeSuperblock()) { commitJournalTx(); return null; }
                if (!writeBlockGroupDesc(g, &bgd_copy)) { commitJournalTx(); return null; }
                commitJournalTx();

                return g * inodes_per_group + bit + 1; // Global inode number (1-indexed)
            }
        }
    }
    return null;
}

/// Free an inode, determining the correct block group.
fn freeInode(ino: u32) bool {
    if (ino == 0) return true;

    const group = (ino - 1) / inodes_per_group;
    const local_bit = (ino - 1) % inodes_per_group;

    if (group >= num_groups) return false;

    const bgd = readBlockGroup(group) orelse return false;
    const bitmap_block: u64 = bgd.bg_inode_bitmap;
    const bitmap = readBlock(bitmap_block) orelse return false;

    const byte_idx = local_bit / 8;
    const bit_idx: u3 = @truncate(local_bit % 8);
    bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);

    superblock.s_free_inodes_count += 1;
    var bgd_copy = bgd;
    bgd_copy.bg_free_inodes_count += 1;

    beginJournalTx(3);
    if (!writeBlock(bitmap_block, bitmap)) { commitJournalTx(); return false; }
    if (!writeSuperblock()) { commitJournalTx(); return false; }
    if (!writeBlockGroupDesc(group, &bgd_copy)) { commitJournalTx(); return false; }
    commitJournalTx();

    return true;
}

// ---- Inode cache ----
//
// Two-level design:
//   1. inode_cache[] — ext2 disk inode cache (LRU/FIFO, entries may be evicted).
//   2. vfs_inodes[]  — stable VFS inode array, indexed by ext2 inode number.
//      Pointers into vfs_inodes[] are NEVER invalidated by cache eviction,
//      which lets revalidateCache() reliably detect stale fs_data pointers.

const INODE_CACHE_SIZE: usize = 2048;

const Ext2InodeCache = struct {
    disk_inode: Ext2DiskInode,
    ino: u32,
    in_use: bool,
    pinned: bool,
};

var inode_cache: [INODE_CACHE_SIZE]Ext2InodeCache = undefined;
var inode_cache_initialized: bool = false;
var next_evict: usize = 0;

// Stable VFS inode array — direct-indexed by (ino - 1).
// 32768 entries × 48 bytes ≈ 1.5 MB. Each ext2 inode gets a permanent slot
// so VFS inode pointers survive disk-cache eviction.
const MAX_EXT2_INODES: usize = 32768;
var vfs_inodes: [MAX_EXT2_INODES]vfs.Inode = undefined;
var vfs_inode_valid: [MAX_EXT2_INODES]bool = undefined;

fn initVfsInodes() void {
    for (0..MAX_EXT2_INODES) |i| {
        vfs_inode_valid[i] = false;
    }
}

fn initInodeCache() void {
    for (0..INODE_CACHE_SIZE) |i| {
        inode_cache[i].in_use = false;
        inode_cache[i].ino = 0;
        inode_cache[i].pinned = false;
    }
    inode_cache_initialized = true;
    initVfsInodes();
}

fn resetInodeCache() void {
    for (0..INODE_CACHE_SIZE) |i| {
        inode_cache[i].in_use = false;
    }
    next_evict = 0;
    initVfsInodes();
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

// ext4 HTree directory hash seed (from superblock s_hash_seed at offset 0xEC)
var hash_seed: [4]u32 = [_]u32{0} ** 4;
var hash_version: u8 = 0;

// ext4 delayed allocation — per-inode dirty range tracking
const DELALLOC_CACHE_SIZE = 32;
var delalloc_states: [DELALLOC_CACHE_SIZE]struct {
    ino: u32 = 0,
    state: delayed_alloc.DelayedState = .{},
} = [_]@TypeOf(delalloc_states[0]){.{}} ** DELALLOC_CACHE_SIZE;
var delalloc_enabled: bool = false;

// Journal transaction state — when active, writeBlock() queues to journal
var journal_tx_active: bool = false;

// ---- SMP locks ----
// Global lock: protects metadata (inode_cache, block bitmaps, superblock,
// directory operations). Acquired for create/unlink/rename/readdir/lookup.
// Per-inode lock: protects file data I/O (read/write). Two processes can
// read/write different files concurrently without contention.
var ext2_lock: spinlock.IrqSpinlock = .{};

// Per-inode locks — parallel array indexed by (ino - 1), same as vfs_inodes[].
// Avoids changing the VFS Inode struct (shared across ramfs, tmpfs, ext2).
var inode_locks: [MAX_EXT2_INODES]spinlock.IrqSpinlock = [_]spinlock.IrqSpinlock{.{}} ** MAX_EXT2_INODES;

fn acquireInodeLock(ino: u32) void {
    if (ino > 0 and ino <= MAX_EXT2_INODES) {
        inode_locks[ino - 1].acquire();
    }
}

fn releaseInodeLock(ino: u32) void {
    if (ino > 0 and ino <= MAX_EXT2_INODES) {
        inode_locks[ino - 1].release();
    }
}

// ---- VFS operation tables ----

const ext2_file_ops = vfs.FileOperations{
    .read = ext2Read,
    .write = ext2Write,
    .close = null,
    .readdir = null,
    .truncate = ext2TruncateVfs,
    .setsize = ext2Setsize,
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
    .link = ext2Link,
    .setsize = ext2Setsize,
};

const ext2_symlink_ops = vfs.FileOperations{
    .readlink = ext2Readlink,
};

// ---- Locked VFS wrappers ----
// These acquire ext2_lock and delegate to the unlocked implementations.
// Functions that are only called via VFS (ext2Read, ext2Write, ext2Readdir,
// ext2TruncateVfs, ext2Create, ext2Rename) lock inline in their body.
// Functions that are ALSO called internally (lookup, ext2Unlink, ext2Rmdir)
// have separate locked wrappers here to avoid re-entrancy deadlocks.

fn lookup(parent: *vfs.Inode, name: []const u8) ?*vfs.Inode {
    ext2_lock.acquire();
    defer ext2_lock.release();
    return lookupUnlocked(parent, name);
}

fn ext2Unlink(parent: *vfs.Inode, name: []const u8) bool {
    ext2_lock.acquire();
    defer ext2_lock.release();
    return ext2UnlinkUnlocked(parent, name);
}

fn ext2Rmdir(parent: *vfs.Inode, name: []const u8) bool {
    ext2_lock.acquire();
    defer ext2_lock.release();
    return ext2RmdirUnlocked(parent, name);
}

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
    const sb_raw: [*]const u8 = @ptrCast(&superblock);
    const s_desc_size_raw: u16 = @as(u16, sb_raw[254]) | (@as(u16, sb_raw[255]) << 8);
    is_64bit_mode = block_group_64.is64Bit(superblock.s_feature_incompat);
    desc_size = block_group_64.descSize(superblock.s_feature_incompat, s_desc_size_raw);

    // ext4: extract HTree hash seed (offset 0xEC = 4 x u32) and default hash version (0xFC)
    for (0..4) |i| {
        const off = 0xEC + i * 4;
        hash_seed[i] = @as(u32, sb_raw[off]) |
            (@as(u32, sb_raw[off + 1]) << 8) |
            (@as(u32, sb_raw[off + 2]) << 16) |
            (@as(u32, sb_raw[off + 3]) << 24);
    }
    hash_version = sb_raw[0xFC];

    // ext4: enable delayed allocation for extent-based filesystems
    // Check INCOMPAT_EXTENTS (0x0040) — delalloc only makes sense with extents
    delalloc_enabled = (superblock.s_feature_incompat & 0x0040) != 0;

    // Reset caches
    invalidateCache();
    if (!inode_cache_initialized) initInodeCache();
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

    // Log detected ext4 features
    serial.writeString("[ext4] features:");
    if (superblock.s_feature_incompat & 0x0040 != 0) serial.writeString(" extents");
    if (is_64bit_mode) serial.writeString(" 64bit");
    if (superblock.s_feature_incompat & 0x0200 != 0) serial.writeString(" flex_bg");
    if (superblock.s_feature_compat & 0x0020 != 0) serial.writeString(" dir_index");
    if (superblock.s_feature_ro_compat & 0x0400 != 0) serial.writeString(" metadata_csum");
    if (delalloc_enabled) serial.writeString(" delalloc");
    if (hash_version > 0) {
        serial.writeString(" htree_hash=");
        writeDecimal(hash_version);
    }
    serial.writeString("\n");

    // ext3 journal detection and initialization (block_io already initialized by boot.zig)
    const s_journal_inum: u32 = @as(u32, sb_raw[0xE0]) |
        (@as(u32, sb_raw[0xE1]) << 8) |
        (@as(u32, sb_raw[0xE2]) << 16) |
        (@as(u32, sb_raw[0xE3]) << 24);

    // Use 64-bit inode table address for ext4 compatibility
    serial.print("[ext2] inode_table_base={} inode_size={} block_size={}\n", .{ blockGroupInodeTable64(0) orelse 0, inode_size, block_size });
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

    // BGD checksum validation at mount (ext4 with metadata_csum)
    if (superblock.s_feature_ro_compat & 0x0400 != 0) {
        var bgd_ok: u32 = 0;
        var bgd_fail: u32 = 0;
        var g: u32 = 0;
        while (g < num_groups) : (g += 1) {
            // Read raw 64-byte descriptor for checksum verification
            const bgdt_block: u64 = if (block_size == 1024) 2 else 1;
            const ds: u32 = @as(u32, desc_size);
            const bgd_per_block = block_size / ds;
            const target_block = bgdt_block + @as(u64, g / bgd_per_block);
            const blk_data = readBlockConst(target_block) orelse continue;
            const offset_in_blk = (g % bgd_per_block) * ds;

            // Cast to BlockGroupDesc64 for checksum verification
            const bgd64: *const block_group_64.BlockGroupDesc64 = @ptrCast(@alignCast(blk_data + offset_in_blk));
            if (bgd64.verifyChecksum(g, &superblock.s_uuid, @truncate(desc_size))) {
                bgd_ok += 1;
            } else {
                bgd_fail += 1;
                if (bgd_fail <= 3) {
                    serial.print("[ext4] BGD checksum FAIL group={} stored=0x{x} computed=0x{x}\n", .{
                        g,
                        bgd64.checksum,
                        bgd64.computeChecksum(g, &superblock.s_uuid, @truncate(desc_size)),
                    });
                }
            }
        }
        serial.print("[ext4] BGD checksums: {}/{} OK", .{ bgd_ok, num_groups });
        if (bgd_fail > 0) {
            serial.print(", {} FAILED", .{bgd_fail});
        }
        serial.writeString("\n");
    }

    return true;
}

pub fn getRootInode() ?*vfs.Inode {
    if (!initialized) return null;
    ext2_lock.acquire();
    defer ext2_lock.release();
    return loadInode(EXT2_ROOT_INO);
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
    const inode_table_base = blockGroupInodeTable64(group) orelse {
        serial.print("[ext2] loadInodeDisk: bgd lookup failed ino={} group={}\n", .{ ino, group });
        return null;
    };

    // Calculate which block in the inode table contains this inode
    const inodes_per_block = block_size / inode_size;
    const block_in_table = index / inodes_per_block;
    const offset_in_block = (index % inodes_per_block) * inode_size;

    const block_num = inode_table_base + block_in_table;
    const block_data = readBlock(block_num) orelse {
        serial.print("[ext2] loadInodeDisk: readBlock failed ino={} blk={} tbl_base={} group={}\n", .{ ino, block_num, inode_table_base, group });
        return null;
    };

    // Byte-by-byte copy (128 bytes regardless of on-disk inode_size)
    var disk_inode: Ext2DiskInode = undefined;
    const dest: *[128]u8 = @ptrCast(&disk_inode);
    for (0..128) |i| {
        dest[i] = block_data[offset_in_block + i];
    }

    // Debug: log when high-numbered inodes have zero size
    if (ino >= 7000 and disk_inode.i_size == 0 and disk_inode.i_mode != 0) {
        serial.print("[ext2] loadIno: ino={} sz=0 mode={x} blk={} off={} isz={} ipb={}\n", .{
            ino, @as(u32, disk_inode.i_mode), block_num, offset_in_block,
            inode_size, block_size / inode_size,
        });
        // Dump raw bytes at the inode's offset (first 16 bytes)
        serial.print("  raw:", .{});
        for (0..16) |ri| {
            serial.print(" {x}", .{block_data[offset_in_block + ri]});
        }
        serial.writeString("\n");
    }

    // ext4 inode checksum verification (if METADATA_CSUM enabled and inode_size >= 256)
    // Skip unallocated inodes (mode=0) — their checksum is all-zeros which won't match
    const RO_COMPAT_METADATA_CSUM: u32 = 0x0400;
    if (superblock.s_feature_ro_compat & RO_COMPAT_METADATA_CSUM != 0 and inode_size >= 256 and disk_inode.i_mode != 0) {
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

/// Populate a stable VFS inode entry from an ext2 disk inode + cache slot.
/// The returned pointer is into vfs_inodes[] (indexed by ino), which survives
/// cache eviction — the key property that makes revalidateCache() correct.
fn populateVfsInode(ino: u32, disk_inode: *const Ext2DiskInode, cache_slot: *Ext2InodeCache) ?*vfs.Inode {
    if (ino == 0 or ino > MAX_EXT2_INODES) return null;
    const idx = ino - 1;
    const mode_type = disk_inode.i_mode & 0xF000;
    const is_dir = mode_type == 0x4000;
    const is_symlink = mode_type == 0xA000;

    const is_fifo = mode_type == 0x1000;
    const is_chrdev = mode_type == 0x2000;
    const is_blkdev = mode_type == 0x6000;
    const is_sock = mode_type == 0xC000;

    const perm_bits = @as(u32, disk_inode.i_mode) & 0o7777;
    const type_bits: u32 = if (is_dir) vfs.S_IFDIR else if (is_symlink) vfs.S_IFLNK else if (is_fifo) vfs.S_IFIFO else if (is_chrdev) vfs.S_IFCHR else if (is_blkdev) vfs.S_IFBLK else if (is_sock) vfs.S_IFSOCK else vfs.S_IFREG;
    const ops_table = if (is_dir) &ext2_dir_ops else if (is_symlink) &ext2_symlink_ops else &ext2_file_ops;

    vfs_inodes[idx] = .{
        .ino = ino,
        .mode = type_bits | perm_bits,
        .size = getInodeFileSize(disk_inode),
        .nlink = disk_inode.i_links_count,
        .uid = disk_inode.i_uid,
        .gid = disk_inode.i_gid,
        .ops = ops_table,
        .fs_data = @ptrCast(cache_slot),
    };
    vfs_inode_valid[idx] = true;
    return &vfs_inodes[idx];
}

pub fn loadInode(ino: u32) ?*vfs.Inode {
    if (ino == 0 or ino > MAX_EXT2_INODES) return null;

    // Check cache first
    for (0..INODE_CACHE_SIZE) |i| {
        if (inode_cache[i].in_use and inode_cache[i].ino == ino) {
            return populateVfsInode(ino, &inode_cache[i].disk_inode, &inode_cache[i]);
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
            if (!inode_cache[next_evict].pinned) {
                slot = next_evict;
                next_evict = (next_evict + 1) % INODE_CACHE_SIZE;
                break;
            }
            next_evict = (next_evict + 1) % INODE_CACHE_SIZE;
        }
        if (slot == INODE_CACHE_SIZE) {
            // All slots pinned — forcefully evict next_evict as last resort
            slot = next_evict;
            next_evict = (next_evict + 1) % INODE_CACHE_SIZE;
        }
    }

    // Populate cache entry; pin directories to prevent eviction during path resolution
    const mode_type = disk_inode.i_mode & 0xF000;
    inode_cache[slot].ino = ino;
    inode_cache[slot].disk_inode = disk_inode;
    inode_cache[slot].in_use = true;
    inode_cache[slot].pinned = (mode_type == 0x4000);

    return populateVfsInode(ino, &disk_inode, &inode_cache[slot]);
}

/// Revalidate a VFS inode's cache entry. If the inode cache slot was evicted
/// and reused by a different inode (stale pointer), reload the original inode
/// from disk into a new slot and update the VFS inode's fs_data pointer.
/// Returns the (possibly new) cache entry, or null if reload fails.
///
/// Correctness relies on vfs_inodes[] being a *separate* array from inode_cache[].
/// inode.ino lives in vfs_inodes[] and is never overwritten by cache eviction,
/// so cache_entry.ino != inode.ino reliably detects stale fs_data pointers.
/// Caller must hold ext2_lock.
fn revalidateCache(inode: *vfs.Inode) ?*Ext2InodeCache {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        inode.fs_data orelse {
            serial.print("[ext2] revalidate: fs_data=null ino={}\n", .{inode.ino});
            return null;
        },
    ));

    // Fast path: cache entry still belongs to this inode
    if (cache_entry.ino == @as(u32, @truncate(inode.ino))) return cache_entry;

    // Stale: the slot was evicted and reused. Reload via loadInode which
    // either finds the inode in another slot or loads from disk into a new one.
    // loadInode also updates this inode's fs_data (via populateVfsInode).
    _ = loadInode(@truncate(inode.ino)) orelse {
        serial.print("[ext2] revalidate: loadInode failed ino={}\n", .{inode.ino});
        return null;
    };

    return @alignCast(@ptrCast(inode.fs_data));
}

// ---- Extent tree read callback ----

fn readBlockConst(block_num: u64) ?[*]const u8 {
    return readBlock(block_num);
}

/// Compute a goal block for extent allocation based on the last extent in the root.
/// Returns the physical block just past the last extent's range for locality,
/// or 0 if the tree is empty.
fn extentGoalBlock(iblock: *const [60]u8) u64 {
    const root: [*]const u8 = iblock;
    const header = extents.getHeader(root);
    if (!header.isValid() or header.entries == 0) return 0;

    if (header.isLeaf()) {
        // Depth 0: last extent in root gives us the goal
        const exts = extents.getExtents(root);
        const last = &exts[header.entries - 1];
        return last.physicalBlock() + @as(u64, last.blockCount());
    }

    // Depth > 0: follow the last index entry to the last leaf
    const indices = extents.getIndices(root);
    const child_phys = indices[header.entries - 1].childBlock();
    const child_buf = readBlock(child_phys) orelse return 0;
    const child_header = extents.getHeader(child_buf);
    if (!child_header.isValid() or child_header.entries == 0) return 0;

    if (child_header.isLeaf()) {
        const exts = extents.getExtents(child_buf);
        const last = &exts[child_header.entries - 1];
        return last.physicalBlock() + @as(u64, last.blockCount());
    }

    // Depth 2 — follow one more level
    const idx2 = extents.getIndices(child_buf);
    const leaf_phys = idx2[child_header.entries - 1].childBlock();
    const leaf_buf = readBlock(leaf_phys) orelse return 0;
    const leaf_hdr = extents.getHeader(leaf_buf);
    if (!leaf_hdr.isValid() or leaf_hdr.entries == 0) return 0;
    const leaf_exts = extents.getExtents(leaf_buf);
    const last = &leaf_exts[leaf_hdr.entries - 1];
    return last.physicalBlock() + @as(u64, last.blockCount());
}

/// Split a full extent tree root: allocate a new disk block, copy all leaf entries
/// from the root into it, then convert the root into a depth-1 node with a single
/// index entry pointing to the new leaf block. Finally insert `ext` into the
/// appropriate leaf.
///
/// This handles the transition from depth-0 (max 4 extents in inode) to depth-1
/// (340 extents per leaf block).
fn extentSplitRoot(iblock_mut: *[60]u8, ext: extents.Extent) bool {
    const root: [*]u8 = iblock_mut;
    const header = extents.getHeaderMut(root);
    if (!header.isValid()) return false;

    // Only handle depth-0 → depth-1 split (most common case).
    // Deeper splits would need recursive handling but are rare —
    // depth-1 supports 340 extents × 32768 blocks = ~5.2 TB per file.
    if (header.depth != 0) return false;

    // Allocate a new disk block for the leaf node
    const tree_blk = allocBlock() orelse return false;
    const tree_buf = readBlock(tree_blk) orelse return false;

    // Zero the new block first
    for (0..block_size) |i| {
        tree_buf[i] = 0;
    }

    // Copy all extent entries from root to new leaf block
    const max_per_block = extents.maxEntriesPerBlock(block_size);
    const new_header = extents.getHeaderMut(tree_buf);
    new_header.magic = extents.EXTENT_MAGIC;
    new_header.entries = header.entries;
    new_header.max = max_per_block;
    new_header.depth = 0;
    new_header.generation = header.generation;

    const src_exts = extents.getExtents(root);
    const dst_exts = extents.getExtentsMut(tree_buf);
    var i: u16 = 0;
    while (i < header.entries) : (i += 1) {
        dst_exts[i] = src_exts[i];
    }

    // Insert the new extent into the leaf block (it has plenty of space now)
    if (!extents.insertInLeaf(tree_buf, ext)) {
        // Should not happen — new leaf has max_per_block (340) slots
        _ = freeBlock(tree_blk);
        return false;
    }

    // Write the new leaf block to disk
    if (!writeBlock(tree_blk, tree_buf)) {
        _ = freeBlock(tree_blk);
        return false;
    }

    // Convert root to depth-1 with a single index entry pointing to the new leaf.
    // The first logical block covered by the index = minimum block in the leaf.
    const first_logical = dst_exts[0].block;

    // Clear root extent area (entries start at offset 12)
    for (@sizeOf(extents.ExtentHeader)..60) |j| {
        iblock_mut[j] = 0;
    }

    header.depth = 1;
    header.entries = 1;
    // max stays at 4 (root can hold 4 index entries = 4 leaf blocks = 1360 extents)

    const root_indices = extents.getIndicesMut(root);
    root_indices[0].block = first_logical;
    root_indices[0].setChildBlock(@as(u64, tree_blk));

    return true;
}

// ---- ext4 delayed allocation helpers ----

/// Get or create delayed allocation state for an inode.
fn getDelayedState(ino: u32) ?*delayed_alloc.DelayedState {
    // Find existing
    for (&delalloc_states) |*entry| {
        if (entry.ino == ino and entry.state.active) return &entry.state;
    }
    // Allocate new slot
    for (&delalloc_states) |*entry| {
        if (!entry.state.active) {
            entry.ino = ino;
            entry.state = .{ .active = true };
            return &entry.state;
        }
    }
    return null; // All slots full — fall back to immediate allocation
}

/// Flush delayed allocations for an inode — allocate blocks contiguously and write.
fn flushDelayedInode(cache_entry: *Ext2InodeCache) void {
    const ds = blk: {
        for (&delalloc_states) |*entry| {
            if (entry.ino == cache_entry.ino and entry.state.active) break :blk &entry.state;
        }
        return; // No delayed state for this inode
    };

    if (ds.reserved_blocks == 0) return;

    const inode = &cache_entry.disk_inode;
    if (!extents.usesExtents(inode.i_flags)) {
        // Delayed alloc only for extent-based inodes; shouldn't happen but be safe
        var free64: u64 = superblock.s_free_blocks_count;
        ds.reset(&free64);
        superblock.s_free_blocks_count = @truncate(free64);
        return;
    }

    // For each dirty range, do a contiguous allocation
    for (&ds.dirty_ranges) |*r| {
        if (!r.valid) continue;

        const iblock: *const [60]u8 = @ptrCast(&inode.i_block);
        const goal = extentGoalBlock(iblock);

        const result = allocBlocksContiguous(r.count, goal) orelse continue;

        // Insert a single extent covering the whole allocation
        const iblock_mut: *[60]u8 = @ptrCast(&inode.i_block);
        const ext = extents.Extent{
            .block = r.logical_start,
            .len = @truncate(result.count),
            .start_hi = 0,
            .start_lo = result.start,
        };
        if (!extents.insertInLeaf(iblock_mut, ext)) {
            if (!extentSplitRoot(iblock_mut, ext)) {
                // Failed to insert — free the allocated blocks
                for (0..result.count) |bi| {
                    _ = freeBlock(result.start + @as(u32, @truncate(bi)));
                }
                continue;
            }
        }

        ds.clearRange(r.logical_start, r.count);
    }
}

// ---- ext4 64-bit file size helper ----

/// Get full 64-bit file size from an ext2/ext4 disk inode.
/// In ext4 (and ext2 rev1 with LARGE_FILE), i_dir_acl is repurposed as i_size_high
/// for regular files. For directories, ext4 also uses i_size_high (Linux does this).
/// Safe for ext2: i_dir_acl is 0 for normal files, so the high 32 bits are zero.
fn getInodeFileSize(disk_inode: *const Ext2DiskInode) u64 {
    return (@as(u64, disk_inode.i_dir_acl) << 32) | @as(u64, disk_inode.i_size);
}

// ---- Block address translation ----

fn getFileBlock(cache_entry: *Ext2InodeCache, file_block: u32) ?u64 {
    const inode = &cache_entry.disk_inode;

    // ext4 extent tree path — check EXTENTS_FL (0x00080000)
    if (extents.usesExtents(inode.i_flags)) {
        const iblock: *const [60]u8 = @ptrCast(&inode.i_block);
        return extents.lookup(iblock, file_block, &readBlockConst);
    }

    const addrs_per_block = block_size / 4;

    // Direct blocks (0-11)
    if (file_block < 12) {
        const blk = inode.i_block[file_block];
        return if (blk == 0) null else @as(u64, blk);
    }

    // Singly indirect (12 .. 12+addrs_per_block-1)
    const single_limit = 12 + addrs_per_block;
    if (file_block < single_limit) {
        const indirect_block = inode.i_block[12];
        if (indirect_block == 0) return null;

        const data = readBlock(indirect_block) orelse return null;
        const index = file_block - 12;
        const addr = readU32FromBlock(data, index * 4);
        return if (addr == 0) null else @as(u64, addr);
    }

    // Doubly indirect (single_limit .. single_limit + addrs_per_block^2 - 1)
    const double_limit = single_limit + addrs_per_block * addrs_per_block;
    if (file_block < double_limit) {
        const di_block = inode.i_block[13];
        if (di_block == 0) return null;

        // Read the double-indirect block: contains pointers to indirect blocks
        const di_data = readBlock(di_block) orelse return null;
        const adjusted = file_block - single_limit;
        const l1_index = adjusted / addrs_per_block;
        const indirect_block = readU32FromBlock(di_data, l1_index * 4);
        if (indirect_block == 0) return null;

        // Read the indirect block: contains pointers to data blocks
        const ind_data = readBlock(indirect_block) orelse return null;
        const l2_index = adjusted % addrs_per_block;
        const addr = readU32FromBlock(ind_data, l2_index * 4);
        return if (addr == 0) null else @as(u64, addr);
    }

    // Triple indirect not supported
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
    // Resolve inode cache entry under global lock (brief)
    ext2_lock.acquire();
    const cache_entry = revalidateCache(desc.inode) orelse {
        ext2_lock.release();
        return -1;
    };
    const ino = cache_entry.ino;
    ext2_lock.release();

    // Per-inode lock: protects file offset and data read for this inode.
    // Two processes reading different files proceed concurrently.
    acquireInodeLock(ino);

    const file_size = getInodeFileSize(&cache_entry.disk_inode);
    if (desc.offset >= file_size) {
        releaseInodeLock(ino);
        return 0; // EOF
    }

    const available: u64 = file_size - desc.offset;
    const to_read: usize = if (count < available) count else @intCast(available);

    var bytes_read: usize = 0;
    var offset = desc.offset;

    while (bytes_read < to_read) {
        const file_block: u32 = @truncate(offset / block_size);
        const block_offset: usize = @truncate(offset % block_size);
        const remaining = to_read - bytes_read;
        const chunk_max = @as(usize, block_size) - block_offset;
        const chunk = if (remaining < chunk_max) remaining else chunk_max;

        // Page cache check (lock-free read — page_cache is thread-safe)
        if (page_cache.lookup(ino, file_block)) |cached_phys| {
            const cached_data: [*]const u8 = @ptrFromInt(cached_phys);
            for (0..chunk) |i| {
                buf[bytes_read + i] = cached_data[block_offset + i];
            }
            bytes_read += chunk;
            offset += chunk;
            continue;
        }

        // Cache miss — need global lock for block I/O (shared block cache)
        ext2_lock.acquire();
        const phys_block = getFileBlock(cache_entry, file_block) orelse {
            ext2_lock.release();
            // Sparse block — return zeros
            for (0..chunk) |i| {
                buf[bytes_read + i] = 0;
            }
            bytes_read += chunk;
            offset += chunk;
            continue;
        };

        const block_data = readBlock(phys_block) orelse {
            ext2_lock.release();
            break;
        };

        // Copy block data out while holding global lock (block cache is volatile)
        var block_copy: [4096]u8 = undefined;
        for (0..block_size) |i| {
            block_copy[i] = block_data[i];
        }
        ext2_lock.release();

        // Insert into page cache for future reads (avoids global lock next time)
        if (pmm.allocPage()) |pg| {
            const pg_ptr: [*]u8 = @ptrFromInt(pg);
            for (0..block_size) |i| {
                pg_ptr[i] = block_copy[i];
            }
            page_cache.insert(ino, file_block, pg);
        }

        for (0..chunk) |i| {
            buf[bytes_read + i] = block_copy[block_offset + i];
        }

        bytes_read += chunk;
        offset += chunk;
    }

    desc.offset = offset;
    releaseInodeLock(ino);
    return @intCast(bytes_read);
}

// ---- File write ----

fn getOrAllocFileBlock(cache_entry: *Ext2InodeCache, file_block: u32) ?u64 {
    const inode = &cache_entry.disk_inode;

    // ext4 extent tree path — allocate via extent insert
    if (extents.usesExtents(inode.i_flags)) {
        const iblock: *const [60]u8 = @ptrCast(&inode.i_block);
        // Check if already mapped
        if (extents.lookup(iblock, file_block, &readBlockConst)) |phys| {
            return phys;
        }
        // Not mapped — allocate a new block near the previous extent for locality
        const goal = extentGoalBlock(iblock);
        const new_blk = allocBlockNear(goal) orelse return null;
        const iblock_mut: *[60]u8 = @ptrCast(&inode.i_block);
        const ext = extents.Extent{
            .block = file_block,
            .len = 1,
            .start_hi = 0,
            .start_lo = new_blk,
        };
        if (!extents.insertInLeaf(iblock_mut, ext)) {
            // Leaf is full — split: allocate a new tree block, move half the
            // entries there, increase depth. This handles files with >4 extents.
            if (!extentSplitRoot(iblock_mut, ext)) {
                _ = freeBlock(new_blk);
                return null;
            }
        }
        return @as(u64, new_blk);
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
        // Ensure double-indirect block exists
        if (inode.i_block[13] == 0) {
            const di_blk = allocBlock() orelse return null;
            inode.i_block[13] = di_blk;
        }

        const adjusted = file_block - single_limit;
        const l1_index = adjusted / addrs_per_block;
        const l2_index = adjusted % addrs_per_block;

        // Read double-indirect block to find the L1 indirect block
        const di_data = readBlock(inode.i_block[13]) orelse return null;
        var indirect_block = readU32FromBlock(di_data, l1_index * 4);

        // Allocate L1 indirect block if needed
        if (indirect_block == 0) {
            const new_ind = allocBlock() orelse return null;
            // Re-read double-indirect block (cache may have been evicted by allocBlock)
            const di_data2 = readBlock(inode.i_block[13]) orelse return null;
            writeU32ToBlock(di_data2, l1_index * 4, new_ind);
            beginJournalTx(1);
            if (!writeBlock(inode.i_block[13], di_data2)) { commitJournalTx(); return null; }
            commitJournalTx();
            indirect_block = new_ind;
        }

        // Read L1 indirect block to find the data block
        const ind_data = readBlock(indirect_block) orelse return null;
        const addr = readU32FromBlock(ind_data, l2_index * 4);
        if (addr != 0) return addr;

        // Allocate new data block
        const new_blk = allocBlock() orelse return null;
        // Re-read L1 indirect block (cache may have been evicted by allocBlock)
        const ind_data2 = readBlock(indirect_block) orelse return null;
        writeU32ToBlock(ind_data2, l2_index * 4, new_blk);
        beginJournalTx(1);
        if (!writeBlock(indirect_block, ind_data2)) { commitJournalTx(); return null; }
        commitJournalTx();
        return new_blk;
    }

    return null; // Beyond doubly indirect not supported
}

fn ext2Write(desc: *vfs.FileDescription, buf: [*]const u8, count: usize) isize {
    ext2_lock.acquire();

    const cache_entry = revalidateCache(desc.inode) orelse {
        ext2_lock.release();
        return -1;
    };

    // Handle O_APPEND
    if (desc.flags & vfs.O_APPEND != 0) {
        desc.offset = getInodeFileSize(&cache_entry.disk_inode);
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

    if (bytes_written == 0) {
        ext2_lock.release();
        return -1;
    }

    // Update file size if we extended the file
    if (offset > getInodeFileSize(&cache_entry.disk_inode)) {
        cache_entry.disk_inode.i_size = @truncate(offset);
        cache_entry.disk_inode.i_dir_acl = @truncate(offset >> 32);
    }

    // Update i_blocks (count of 512-byte sectors)
    // Count allocated blocks: direct + indirect + double-indirect
    var block_count: u32 = 0;
    const addrs_per_block = block_size / 4;
    for (0..12) |i| {
        if (cache_entry.disk_inode.i_block[i] != 0) block_count += 1;
    }
    if (cache_entry.disk_inode.i_block[12] != 0) {
        block_count += 1; // The indirect block itself
        const ind_data = readBlock(cache_entry.disk_inode.i_block[12]);
        if (ind_data) |data| {
            for (0..addrs_per_block) |i| {
                if (readU32FromBlock(data, @truncate(i * 4)) != 0) block_count += 1;
            }
        }
    }
    if (cache_entry.disk_inode.i_block[13] != 0) {
        block_count += 1; // The double-indirect block itself
        const di_data = readBlock(cache_entry.disk_inode.i_block[13]);
        if (di_data) |data| {
            for (0..addrs_per_block) |i| {
                const ind_blk = readU32FromBlock(data, @truncate(i * 4));
                if (ind_blk != 0) {
                    block_count += 1; // The L1 indirect block itself
                    const l1_data = readBlock(ind_blk);
                    if (l1_data) |idata| {
                        for (0..addrs_per_block) |j| {
                            if (readU32FromBlock(idata, @truncate(j * 4)) != 0) block_count += 1;
                        }
                    }
                }
            }
        }
    }
    cache_entry.disk_inode.i_blocks = block_count * (block_size / 512);

    // Write inode to disk
    const write_ok = writeInodeDisk(cache_entry.ino, &cache_entry.disk_inode);

    // Trace newly created files (ino >= 6600)
    if (cache_entry.ino >= 6600) {
        serial.print("[ext2-wr] ino={} wrote={} new_sz={} wdisk={}\n", .{
            cache_entry.ino, bytes_written, cache_entry.disk_inode.i_size,
            @as(u8, if (write_ok) 1 else 0),
        });
    }

    // Update VFS inode size
    desc.inode.size = getInodeFileSize(&cache_entry.disk_inode);
    desc.offset = offset;

    ext2_lock.release();
    return @intCast(bytes_written);
}

// ---- Truncate ----

/// Free all blocks referenced by an extent tree (depth 0, 1, or 2).
/// Traverses the tree, frees all physical data blocks, then frees internal nodes.
fn freeExtentBlocks(iblock: *[60]u8) void {
    const root: [*]const u8 = iblock;
    const header = extents.getHeader(root);
    if (!header.isValid() or header.entries == 0) return;

    if (header.isLeaf()) {
        // Depth 0: extents stored directly in inode root
        const exts = extents.getExtents(root);
        var i: u16 = 0;
        while (i < header.entries) : (i += 1) {
            const phys = exts[i].physicalBlock();
            const count = exts[i].blockCount();
            var b: u32 = 0;
            while (b < count) : (b += 1) {
                _ = freeBlock(@truncate(phys + b));
            }
        }
    } else {
        // Depth > 0: follow index entries to child nodes
        const indices = extents.getIndices(root);
        var idx: u16 = 0;
        while (idx < header.entries) : (idx += 1) {
            const child_phys = indices[idx].childBlock();
            const child_buf = readBlockConst(child_phys) orelse continue;
            const child_header = extents.getHeader(child_buf);
            if (!child_header.isValid()) continue;

            if (child_header.isLeaf()) {
                // Leaf: free all data blocks
                const exts = extents.getExtents(child_buf);
                var i: u16 = 0;
                while (i < child_header.entries) : (i += 1) {
                    const phys = exts[i].physicalBlock();
                    const count = exts[i].blockCount();
                    var b: u32 = 0;
                    while (b < count) : (b += 1) {
                        _ = freeBlock(@truncate(phys + b));
                    }
                }
            } else {
                // Depth 2: another level of indices
                const l2_indices = extents.getIndices(child_buf);
                var l2_idx: u16 = 0;
                while (l2_idx < child_header.entries) : (l2_idx += 1) {
                    const l2_phys = l2_indices[l2_idx].childBlock();
                    const l2_buf = readBlockConst(l2_phys) orelse continue;
                    const l2_header = extents.getHeader(l2_buf);
                    if (!l2_header.isValid()) continue;

                    // Free leaf extents at depth 2
                    const l2_exts = extents.getExtents(l2_buf);
                    var i: u16 = 0;
                    while (i < l2_header.entries) : (i += 1) {
                        const phys = l2_exts[i].physicalBlock();
                        const count = l2_exts[i].blockCount();
                        var b: u32 = 0;
                        while (b < count) : (b += 1) {
                            _ = freeBlock(@truncate(phys + b));
                        }
                    }
                    // Free the depth-1 leaf block itself
                    _ = freeBlock(@truncate(l2_phys));
                }
            }
            // Free the child block (index or leaf at depth 1)
            _ = freeBlock(@truncate(child_phys));
        }
    }
}

fn freeFileBlocks(disk_inode: *Ext2DiskInode) void {
    // ext4 extent tree path
    if (extents.usesExtents(disk_inode.i_flags)) {
        const iblock: *[60]u8 = @ptrCast(&disk_inode.i_block);
        freeExtentBlocks(iblock);
        // Clear extent tree — reinitialize empty root
        extents.initRoot(iblock);
        disk_inode.i_size = 0;
        disk_inode.i_blocks = 0;
        return;
    }

    // Legacy indirect block path
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
    ext2_lock.acquire();

    const cache_entry = revalidateCache(inode) orelse {
        ext2_lock.release();
        return false;
    };

    freeFileBlocks(&cache_entry.disk_inode);
    _ = writeInodeDisk(cache_entry.ino, &cache_entry.disk_inode);
    inode.size = 0;
    ext2_lock.release();
    return true;
}

/// Set file size (for ftruncate to non-zero length).
/// Updates ext2 disk inode i_size and writes to disk.
/// Does NOT allocate blocks — they'll be allocated on demand during write.
fn ext2Setsize(inode: *vfs.Inode, new_size: u64) bool {
    ext2_lock.acquire();

    const cache_entry = revalidateCache(inode) orelse {
        ext2_lock.release();
        return false;
    };

    cache_entry.disk_inode.i_size = @truncate(new_size);
    inode.size = new_size;
    const ok = writeInodeDisk(cache_entry.ino, &cache_entry.disk_inode);

    ext2_lock.release();
    return ok;
}

// ---- Directory readdir ----

fn ext2Readdir(desc: *vfs.FileDescription, entry: *vfs.DirEntry) bool {
    ext2_lock.acquire();

    const cache_entry = revalidateCache(desc.inode) orelse {
        ext2_lock.release();
        return false;
    };

    const dir_size: u64 = getInodeFileSize(&cache_entry.disk_inode);

    while (desc.offset < dir_size) {
        const file_block: u32 = @truncate(desc.offset / block_size);
        const block_offset: usize = @truncate(desc.offset % block_size);

        const phys_block = getFileBlock(cache_entry, file_block) orelse {
            ext2_lock.release();
            return false;
        };
        const block_data = readBlock(phys_block) orelse {
            ext2_lock.release();
            return false;
        };

        // Bounds check: need at least 8 bytes for dir entry header
        if (block_offset + EXT2_DIR_HEADER_SIZE > block_size) {
            ext2_lock.release();
            return false;
        }

        // Parse directory entry fields manually (little-endian)
        const de_inode = readU32FromBlock(block_data, @truncate(block_offset));
        const de_rec_len = @as(u16, block_data[block_offset + 4]) |
            (@as(u16, block_data[block_offset + 5]) << 8);
        const de_name_len = block_data[block_offset + 6];
        const de_file_type = block_data[block_offset + 7];

        // Sanity check rec_len
        if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) {
            ext2_lock.release();
            return false;
        }

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
        ext2_lock.release();
        return true;
    }

    ext2_lock.release();
    return false; // End of directory
}

// ---- HTree directory lookup (ext4) ----

/// Hash-indexed directory lookup. Computes the name's hash, navigates the
/// HTree index to find the leaf directory block, then does a linear scan
/// within that single block for the exact name match.
fn htreeLookup(cache_entry: *Ext2InodeCache, name: []const u8) ?u32 {
    // Read the first directory block (contains DxRoot)
    const root_phys = getFileBlock(cache_entry, 0) orelse return null;
    const root_buf = readBlock(root_phys) orelse return null;

    // Parse DxRoot to get hash version and entry count
    const dx_root: *const htree.DxRoot = @ptrCast(@alignCast(root_buf));
    const hv = if (dx_root.hash_version != 0) dx_root.hash_version else hash_version;
    const name_hash = htree.computeHash(name.ptr, @truncate(name.len), hash_seed, hv);

    // Get root index entries and search for the leaf block
    const root_entries = htree.getRootEntries(root_buf);
    var leaf_block_num = htree.searchEntries(root_entries, dx_root.count, name_hash);

    // If indirect_levels > 0, follow one level of internal index nodes
    if (dx_root.indirect_levels > 0) {
        const node_phys = getFileBlock(cache_entry, leaf_block_num) orelse return null;
        const node_buf = readBlock(node_phys) orelse return null;
        const dx_node: *const htree.DxNode = @ptrCast(@alignCast(node_buf));
        const node_entries = htree.getNodeEntries(node_buf);
        leaf_block_num = htree.searchEntries(node_entries, dx_node.count, name_hash);
    }

    // Read the leaf directory block and do linear scan for exact name match
    const leaf_phys = getFileBlock(cache_entry, leaf_block_num) orelse return null;
    const leaf_buf = readBlock(leaf_phys) orelse return null;

    return scanDirBlockForName(leaf_buf, name);
}

/// Scan a single directory block for a name match. Returns inode number or null.
fn scanDirBlockForName(block_data: [*]const u8, name: []const u8) ?u32 {
    var off: usize = 0;
    while (off + EXT2_DIR_HEADER_SIZE <= block_size) {
        const de_inode = readU32FromBlock(block_data, @truncate(off));
        const de_rec_len = @as(u16, block_data[off + 4]) |
            (@as(u16, block_data[off + 5]) << 8);
        const de_name_len = block_data[off + 6];

        if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

        if (de_inode != 0 and de_name_len == name.len) {
            const name_start = off + EXT2_DIR_HEADER_SIZE;
            var match = true;
            for (0..name.len) |i| {
                if (block_data[name_start + i] != name[i]) {
                    match = false;
                    break;
                }
            }
            if (match) return de_inode;
        }

        off += de_rec_len;
    }
    return null;
}

/// Insert a directory entry into an HTree-indexed directory.
/// Uses the hash to find the correct leaf block, then inserts into that block.
fn htreeAddDirEntry(
    parent_cache: *Ext2InodeCache,
    new_ino: u32,
    name: []const u8,
    file_type: u8,
    name_len: u8,
    needed_size: u16,
) bool {
    // Read root block (block 0 of directory)
    const root_phys = getFileBlock(parent_cache, 0) orelse return false;
    const root_buf = readBlock(root_phys) orelse return false;

    const dx_root: *const htree.DxRoot = @ptrCast(@alignCast(root_buf));
    const hv = if (dx_root.hash_version != 0) dx_root.hash_version else hash_version;
    const name_hash = htree.computeHash(name.ptr, @truncate(name.len), hash_seed, hv);

    // Navigate hash tree to find target leaf block number
    const root_entries = htree.getRootEntries(root_buf);
    var leaf_block_num = htree.searchEntries(root_entries, dx_root.count, name_hash);

    if (dx_root.indirect_levels > 0) {
        const node_phys = getFileBlock(parent_cache, leaf_block_num) orelse return false;
        const node_buf = readBlock(node_phys) orelse return false;
        const dx_node: *const htree.DxNode = @ptrCast(@alignCast(node_buf));
        const node_entries = htree.getNodeEntries(node_buf);
        leaf_block_num = htree.searchEntries(node_entries, dx_node.count, name_hash);
    }

    // Read the target leaf block
    const leaf_phys = getFileBlock(parent_cache, leaf_block_num) orelse return false;
    const leaf_buf = readBlock(leaf_phys) orelse return false;

    // Try to insert into this leaf block by finding space (same logic as linear scan)
    var block_off: usize = 0;
    while (block_off + EXT2_DIR_HEADER_SIZE <= block_size) {
        const de_inode = readU32FromBlock(leaf_buf, @truncate(block_off));
        const de_rec_len = @as(u16, leaf_buf[block_off + 4]) |
            (@as(u16, leaf_buf[block_off + 5]) << 8);
        const de_name_len_existing = leaf_buf[block_off + 6];

        if (de_rec_len < EXT2_DIR_HEADER_SIZE or de_rec_len > block_size) break;

        if (de_inode != 0) {
            const actual_size: u16 = @truncate(((EXT2_DIR_HEADER_SIZE + @as(usize, de_name_len_existing)) + 3) & ~@as(usize, 3));
            const gap = de_rec_len - actual_size;

            if (gap >= needed_size) {
                // Split existing entry, insert new one
                leaf_buf[block_off + 4] = @truncate(actual_size);
                leaf_buf[block_off + 5] = @truncate(actual_size >> 8);

                const new_off = block_off + actual_size;
                const new_rec_len = de_rec_len - actual_size;
                writeU32ToBlock(leaf_buf, @truncate(new_off), new_ino);
                leaf_buf[new_off + 4] = @truncate(new_rec_len);
                leaf_buf[new_off + 5] = @truncate(new_rec_len >> 8);
                leaf_buf[new_off + 6] = name_len;
                leaf_buf[new_off + 7] = file_type;
                for (0..name.len) |i| {
                    leaf_buf[new_off + EXT2_DIR_HEADER_SIZE + i] = name[i];
                }

                beginJournalTx(1);
                const ok = writeBlock(leaf_phys, leaf_buf);
                commitJournalTx();
                return ok;
            }
        } else {
            // Deleted entry — reuse
            if (de_rec_len >= needed_size) {
                writeU32ToBlock(leaf_buf, @truncate(block_off), new_ino);
                leaf_buf[block_off + 6] = name_len;
                leaf_buf[block_off + 7] = file_type;
                for (0..name.len) |i| {
                    leaf_buf[block_off + EXT2_DIR_HEADER_SIZE + i] = name[i];
                }

                beginJournalTx(1);
                const ok2 = writeBlock(leaf_phys, leaf_buf);
                commitJournalTx();
                return ok2;
            }
        }

        block_off += de_rec_len;
    }

    // Leaf block is full — fall through to let the linear path allocate a new block.
    // A full HTree implementation would split the leaf and update the index here,
    // but for now the linear fallback handles new block allocation correctly.
    return false;
}

// ---- Lookup ----

fn lookupUnlocked(parent: *vfs.Inode, name: []const u8) ?*vfs.Inode {
    // Only directories can be looked up in
    if (parent.mode & vfs.S_IFMT != vfs.S_IFDIR) return null;

    const cache_entry = revalidateCache(parent) orelse return null;

    // ext4 HTree fast path — hash-indexed O(1) lookup for large directories
    if (htree.usesHTree(cache_entry.disk_inode.i_flags)) {
        if (htreeLookup(cache_entry, name)) |ino| {
            return loadInode(ino);
        }
        return null;
    }

    // Linear scan (ext2/ext3 or small ext4 directories without INDEX_FL)
    const dir_size: u64 = getInodeFileSize(&cache_entry.disk_inode);
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

    // HTree fast path: use hash to find the right leaf block instead of scanning all blocks
    if (htree.usesHTree(parent_cache.disk_inode.i_flags)) {
        if (htreeAddDirEntry(parent_cache, new_ino, name, file_type, name_len, needed_size))
            return true;
        // Fall through to linear scan on failure (e.g., if hash index is corrupt)
    }

    const dir_size: u64 = getInodeFileSize(&parent_cache.disk_inode);
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
    if (name.len == 0 or name.len > 255) {
        serial.writeString("[ext2-create] bad name len\n");
        return null;
    }

    ext2_lock.acquire();

    // Check name doesn't already exist (use unlocked — we hold the lock)
    if (lookupUnlocked(parent, name) != null) {
        ext2_lock.release();
        return null;
    }

    const parent_cache = revalidateCache(parent) orelse {
        ext2_lock.release();
        return null;
    };

    // Allocate new inode
    const new_ino = allocInode() orelse {
        ext2_lock.release();
        return null;
    };

    // Initialize disk inode
    var disk_inode: Ext2DiskInode = undefined;
    const zero: *[128]u8 = @ptrCast(&disk_inode);
    for (0..128) |i| {
        zero[i] = 0;
    }

    const is_dir = (mode & vfs.S_IFMT) == vfs.S_IFDIR;
    disk_inode.i_mode = @truncate(mode);
    disk_inode.i_links_count = if (is_dir) 2 else 1; // dirs have . and parent link

    if (is_dir) {
        // Allocate block for . and .. entries
        const dir_blk = allocBlock() orelse {
            _ = freeInode(new_ino);
            ext2_lock.release();
            return null;
        };

        disk_inode.i_block[0] = dir_blk;
        disk_inode.i_size = block_size;
        disk_inode.i_blocks = block_size / 512;

        // Write . and .. entries
        const blk = readBlock(dir_blk) orelse {
            _ = freeBlock(dir_blk);
            _ = freeInode(new_ino);
            ext2_lock.release();
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
            ext2_lock.release();
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
        ext2_lock.release();
        return null;
    }

    // Add directory entry to parent
    const file_type: u8 = if (is_dir) EXT2_FT_DIR else EXT2_FT_REG_FILE;
    if (!addDirEntry(parent_cache, new_ino, name, file_type)) {
        _ = freeInode(new_ino);
        ext2_lock.release();
        return null;
    }

    // Trace newly created files
    if (new_ino >= 6600) {
        serial.print("[ext2-create] ino={} mode={x} dir={}\n", .{
            new_ino, mode, @as(u8, if (is_dir) 1 else 0),
        });
    }

    // Load and return VFS inode
    const result = loadInode(new_ino);
    ext2_lock.release();
    return result;
}

fn ext2UnlinkUnlocked(parent: *vfs.Inode, name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;

    const parent_cache = revalidateCache(parent) orelse return false;

    const dir_size: u64 = getInodeFileSize(&parent_cache.disk_inode);
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
    const dir_size: u64 = getInodeFileSize(&cache_entry.disk_inode);
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

fn ext2RmdirUnlocked(parent: *vfs.Inode, name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;

    const parent_cache = revalidateCache(parent) orelse return false;

    const dir_size: u64 = getInodeFileSize(&parent_cache.disk_inode);
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

fn invalidateInodeCache(ino: u32) void {
    for (0..INODE_CACHE_SIZE) |i| {
        if (inode_cache[i].in_use and inode_cache[i].ino == ino) {
            inode_cache[i].in_use = false;
            return;
        }
    }
}

// ---- Rename ----

/// Force-remove a directory entry by name, regardless of type or directory emptiness.
/// Does NOT free blocks or inode — caller accepts orphaned data.
/// Must be called with ext2_lock held.
fn forceDirEntryRemove(parent: *vfs.Inode, name: []const u8) bool {
    const parent_cache = revalidateCache(parent) orelse return false;
    const dir_size: u64 = getInodeFileSize(&parent_cache.disk_inode);
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
                    // Remove entry: merge with previous or zero inode
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

                    invalidateInodeCache(de_inode);
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

/// Hard link: add a new directory entry in parent pointing to target_inode.
fn ext2Link(parent: *vfs.Inode, name: []const u8, target_inode: *vfs.Inode) bool {
    if (name.len == 0 or name.len > 255) return false;

    ext2_lock.acquire();

    const parent_cache = revalidateCache(parent) orelse {
        ext2_lock.release();
        return false;
    };

    // Determine file type for directory entry
    const ft: u8 = if (target_inode.mode & vfs.S_IFMT == vfs.S_IFDIR) EXT2_FT_DIR else if (target_inode.mode & vfs.S_IFMT == vfs.S_IFLNK) EXT2_FT_SYMLINK else EXT2_FT_REG_FILE;

    if (!addDirEntry(parent_cache, @truncate(target_inode.ino), name, ft)) {
        ext2_lock.release();
        return false;
    }

    // Increment link count on the target inode
    const target_cache = revalidateCache(target_inode) orelse {
        ext2_lock.release();
        return true; // dir entry added, link count update is best-effort
    };
    target_cache.disk_inode.i_links_count += 1;
    target_inode.nlink = target_cache.disk_inode.i_links_count;
    _ = writeInodeDisk(target_cache.ino, &target_cache.disk_inode);

    ext2_lock.release();
    return true;
}

fn ext2Rename(old_parent: *vfs.Inode, old_name: []const u8, new_parent: *vfs.Inode, new_name: []const u8) bool {
    if (old_name.len == 0 or old_name.len > 255 or new_name.len == 0 or new_name.len > 255) {
        return false;
    }

    ext2_lock.acquire();

    const old_parent_cache = revalidateCache(old_parent) orelse {
        serial.print("[ext2-rename] old-parent-cache-fail ino={}\n", .{old_parent.ino});
        ext2_lock.release();
        return false;
    };

    // Find source entry in old_parent directory
    var src_ino: u32 = 0;
    var src_file_type: u8 = 0;
    {
        const dir_size: u64 = getInodeFileSize(&old_parent_cache.disk_inode);
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

    if (src_ino == 0) {
        ext2_lock.release();
        return false;
    }

    // If dest exists, remove it first
    if (lookupUnlocked(new_parent, new_name) != null) {
        // Try unlink (files) or rmdir (empty dirs) first
        if (!ext2UnlinkUnlocked(new_parent, new_name)) {
            if (!ext2RmdirUnlocked(new_parent, new_name)) {
                // Force-remove the directory entry (handles non-empty dirs, stale cache)
                // Blocks/inode become orphaned — acceptable for robustness
                if (!forceDirEntryRemove(new_parent, new_name)) {
                    ext2_lock.release();
                    return false;
                }
            }
        }
    }

    // Add entry in new_parent
    const new_parent_cache = revalidateCache(new_parent) orelse {
        serial.writeString("[ext2-rename] new_parent cache fail\n");
        ext2_lock.release();
        return false;
    };
    if (!addDirEntry(new_parent_cache, src_ino, new_name, src_file_type)) {
        serial.print("[ext2-rename] addDirEntry fail ino={} name_len={}\n", .{ src_ino, new_name.len });
        ext2_lock.release();
        return false;
    }

    // Remove old entry
    {
        const dir_size: u64 = getInodeFileSize(&old_parent_cache.disk_inode);
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

                        // If renaming a directory across parents, update ".."
                        if (src_file_type == EXT2_FT_DIR and old_parent.ino != new_parent.ino) {
                            const child_inode = loadInode(src_ino);
                            if (child_inode) |ci| {
                                const child_cache: *Ext2InodeCache = @alignCast(@ptrCast(
                                    ci.fs_data orelse {
                                        ext2_lock.release();
                                        return true;
                                    },
                                ));
                                if (child_cache.disk_inode.i_block[0] != 0) {
                                    const dir_blk = readBlock(child_cache.disk_inode.i_block[0]);
                                    if (dir_blk) |db| {
                                        writeU32ToBlock(db, 12, new_parent_cache.ino);
                                        beginJournalTx(1);
                                        _ = writeBlock(child_cache.disk_inode.i_block[0], db);
                                        commitJournalTx();
                                    }
                                }
                                if (old_parent_cache.disk_inode.i_links_count > 0) {
                                    old_parent_cache.disk_inode.i_links_count -= 1;
                                    old_parent.nlink = old_parent_cache.disk_inode.i_links_count;
                                    _ = writeInodeDisk(old_parent_cache.ino, &old_parent_cache.disk_inode);
                                }
                                new_parent_cache.disk_inode.i_links_count += 1;
                                new_parent.nlink = new_parent_cache.disk_inode.i_links_count;
                                _ = writeInodeDisk(new_parent_cache.ino, &new_parent_cache.disk_inode);
                            }
                        }
                        ext2_lock.release();
                        return true;
                    }
                }

                prev_off = block_off;
                block_off += de_rec_len;
            }
            offset = (@as(u64, @truncate(offset / block_size)) + 1) * block_size;
        }
    }

    ext2_lock.release();
    return false;
}

// ---- Inode pinning (prevents cache eviction during demand paging) ----

/// Pin a VFS inode to prevent its cache entry from being evicted.
/// Used by ELF demand paging to keep executable inodes resident while
/// the process is running and pages may still need to be faulted in.
pub fn pinInode(inode: *vfs.Inode) void {
    ext2_lock.acquire();
    const cache_entry = revalidateCache(inode) orelse {
        ext2_lock.release();
        return;
    };
    cache_entry.pinned = true;
    ext2_lock.release();
}

/// Unpin a VFS inode, allowing its cache entry to be evicted.
pub fn unpinInode(inode: *vfs.Inode) void {
    ext2_lock.acquire();
    const cache_entry = revalidateCache(inode) orelse {
        ext2_lock.release();
        return;
    };
    cache_entry.pinned = false;
    ext2_lock.release();
}

/// Unpin all inodes (called on execve to release previous executable's pins).
pub fn unpinAllInodes() void {
    ext2_lock.acquire();
    for (0..INODE_CACHE_SIZE) |i| {
        inode_cache[i].pinned = false;
    }
    ext2_lock.release();
}

// ---- Sync ----

pub fn sync() void {
    ext2_lock.acquire();
    _ = writeSuperblock();
    const bgd = readBlockGroup(0);
    if (bgd) |b| {
        _ = writeBlockGroupDesc(0, &b);
    }
    ext2_lock.release();
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

// ---- Symlink operations ----

/// Read the target of a symbolic link.
fn ext2Readlink(inode: *vfs.Inode, buf: [*]u8, bufsiz: usize) isize {
    ext2_lock.acquire();
    defer ext2_lock.release();

    const cache_entry = revalidateCache(inode) orelse return -1;

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

    ext2_lock.acquire();
    defer ext2_lock.release();

    if (lookupUnlocked(parent, name) != null) return null;

    const parent_cache = revalidateCache(parent) orelse return null;

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

fn writeHex16(val: u16) void {
    const hex = "0123456789abcdef";
    var buf: [4]u8 = undefined;
    buf[0] = hex[@as(usize, val >> 12)];
    buf[1] = hex[@as(usize, (val >> 8) & 0xf)];
    buf[2] = hex[@as(usize, (val >> 4) & 0xf)];
    buf[3] = hex[@as(usize, val & 0xf)];
    serial.writeString(&buf);
}

// ---- Functions added for syscall layer compatibility ----

pub fn flushInode(ino: u64) bool {
    ext2_lock.acquire();
    defer ext2_lock.release();

    const ino32: u32 = @truncate(ino);
    for (&inode_cache) |*entry| {
        if (entry.in_use and entry.ino == ino32) {
            return writeInodeDisk(ino32, &entry.disk_inode);
        }
    }
    return false;
}

/// Superblock info for statfs.
pub const SuperblockInfo = struct {
    block_size: u64,
    blocks_count: u64,
    free_blocks: u64,
    inodes_count: u64,
    free_inodes: u64,
};

pub fn getSuperblockInfo() SuperblockInfo {
    return .{
        .block_size = block_size,
        .blocks_count = superblock.s_blocks_count,
        .free_blocks = superblock.s_free_blocks_count,
        .inodes_count = superblock.s_inodes_count,
        .free_inodes = superblock.s_free_inodes_count,
    };
}

/// Get inode timestamps (atime, mtime, ctime) from disk cache.
pub const Timestamps = struct { atime: u32, mtime: u32, ctime: u32 };
pub fn getTimestamps(inode: *vfs.Inode) Timestamps {
    const cache_entry: *Ext2InodeCache = @alignCast(@ptrCast(
        inode.fs_data orelse return .{ .atime = 0, .mtime = 0, .ctime = 0 },
    ));
    return .{
        .atime = cache_entry.disk_inode.i_atime,
        .mtime = cache_entry.disk_inode.i_mtime,
        .ctime = cache_entry.disk_inode.i_ctime,
    };
}

/// Update inode timestamps on disk. Called by utimensat syscall.
pub fn setTimestamps(inode: *vfs.Inode, atime_sec: i64, atime_nsec: i64, mtime_sec: i64, mtime_nsec: i64) void {
    ext2_lock.acquire();
    defer ext2_lock.release();

    const cache_entry = revalidateCache(inode) orelse return;
    const UTIME_NOW: i64 = 0x3FFFFFFF;
    const UTIME_OMIT: i64 = 0x3FFFFFFE;

    const now = currentTimestamp();

    if (atime_nsec != UTIME_OMIT) {
        cache_entry.disk_inode.i_atime = if (atime_nsec == UTIME_NOW)
            now
        else
            @truncate(@as(u64, @bitCast(atime_sec)));
    }

    if (mtime_nsec != UTIME_OMIT) {
        cache_entry.disk_inode.i_mtime = if (mtime_nsec == UTIME_NOW)
            now
        else
            @truncate(@as(u64, @bitCast(mtime_sec)));
        cache_entry.disk_inode.i_ctime = now;
    }

    _ = writeInodeDisk(cache_entry.ino, &cache_entry.disk_inode);
}

/// Swap a directory entry's inode number and file type in-place.
/// Used by rename syscall.
pub fn swapDirEntryInodes(parent: *vfs.Inode, name: []const u8, new_ino: u32, new_mode: u32) bool {
    ext2_lock.acquire();
    defer ext2_lock.release();

    const parent_cache = revalidateCache(parent) orelse return false;
    const dir_size: u64 = getInodeFileSize(&parent_cache.disk_inode);
    const new_ft = modeToFt(new_mode);

    var offset: u64 = 0;
    while (offset < dir_size) {
        const file_block: u32 = @truncate(offset / block_size);
        const phys_block = getFileBlock(parent_cache, file_block) orelse break;
        const blk = readBlock(phys_block) orelse break;

        var block_off: usize = @truncate(offset % block_size);
        while (block_off + EXT2_DIR_HEADER_SIZE <= block_size) {
            const de_inode = readU32FromBlock(blk, @truncate(block_off));
            const de_rec_len = @as(u16, blk[block_off + 4]) |
                (@as(u16, blk[block_off + 5]) << 8);
            const de_name_len = blk[block_off + 6];

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
                    writeU32ToBlock(blk, @truncate(block_off), new_ino);
                    blk[block_off + 7] = new_ft;
                    beginJournalTx(1);
                    _ = writeBlock(phys_block, blk);
                    commitJournalTx();
                    return true;
                }
            }

            block_off += de_rec_len;
        }
        offset = (@as(u64, @truncate(offset / block_size)) + 1) * block_size;
    }
    return false;
}

// ============================================================================
// Hole punching (fallocate FALLOC_FL_PUNCH_HOLE)
// ============================================================================

/// Punch a hole in a file: zero and free blocks in [offset, offset+len).
/// File size is NOT changed (caller must use KEEP_SIZE).
pub fn ext2PunchHole(ino: u32, offset: u64, len: u64) i64 {
    ext2_lock.acquire();
    defer ext2_lock.release();

    // Load cache entry
    var cache_entry: ?*Ext2InodeCache = null;
    for (0..INODE_CACHE_SIZE) |i| {
        if (inode_cache[i].in_use and inode_cache[i].ino == ino) {
            cache_entry = &inode_cache[i];
            break;
        }
    }
    if (cache_entry == null) {
        // Try loading from disk
        const di = loadInodeDisk(ino) orelse return -5;
        _ = di;
        for (0..INODE_CACHE_SIZE) |i| {
            if (inode_cache[i].in_use and inode_cache[i].ino == ino) {
                cache_entry = &inode_cache[i];
                break;
            }
        }
    }
    const ce = cache_entry orelse return -5;

    const start_block: u32 = @truncate(offset / block_size);
    const end_offset = offset + len;
    const end_block: u32 = @truncate((end_offset + block_size - 1) / block_size);
    var freed: u32 = 0;

    var blk_idx = start_block;
    while (blk_idx < end_block) : (blk_idx += 1) {
        if (getFileBlock(ce, blk_idx)) |phys| {
            const phys32: u32 = @truncate(phys);
            if (phys32 != 0) {
                // Zero the block on disk
                const data = readBlock(phys32);
                if (data) |d| {
                    for (0..block_size) |i| d[i] = 0;
                    beginJournalTx(1);
                    _ = writeBlock(phys32, d);
                    commitJournalTx();
                }
                // Free the block
                _ = freeBlock(phys32);
                freed += 1;

                // Clear the block pointer in the inode
                // For direct blocks, clear i_block[blk_idx]
                if (blk_idx < 12) {
                    ce.disk_inode.i_block[blk_idx] = 0;
                }
                // For indirect/extent blocks, the pointer clearing is more complex
                // and we rely on getFileBlock returning null for freed blocks
            }
        }
    }

    // Update inode's block count
    if (freed > 0) {
        const sectors_freed = freed * @as(u32, @truncate(block_size / 512));
        if (ce.disk_inode.i_blocks >= sectors_freed) {
            ce.disk_inode.i_blocks -= sectors_freed;
        } else {
            ce.disk_inode.i_blocks = 0;
        }
        _ = writeInodeDisk(ino, &ce.disk_inode);
    }

    return 0;
}

// ============================================================================
// Extended Attributes (xattr) support
// ============================================================================

// On-disk xattr block header (at start of i_file_acl block)
const XATTR_MAGIC: u32 = 0xEA020000;
const XATTR_HEADER_SIZE: usize = 32; // magic(4) + refcount(4) + blocks(4) + hash(4) + reserved(16)
const XATTR_ENTRY_ALIGN: usize = 4;

// Name index values (Linux ext2/ext3/ext4 convention)
const XATTR_INDEX_USER: u8 = 1;
const XATTR_INDEX_POSIX_ACL_ACCESS: u8 = 2;
const XATTR_INDEX_POSIX_ACL_DEFAULT: u8 = 3;
const XATTR_INDEX_TRUSTED: u8 = 4;
const XATTR_INDEX_SECURITY: u8 = 6;

// Xattr entry: name_len(1) + name_index(1) + value_offs(2) + value_block(4) + value_size(4) + hash(4) + name(name_len)
const XATTR_ENTRY_HEADER: usize = 16; // before name

fn xattrNameIndex(full_name: []const u8) struct { index: u8, suffix: []const u8 } {
    if (full_name.len > 5 and full_name[0] == 'u' and full_name[1] == 's' and full_name[2] == 'e' and full_name[3] == 'r' and full_name[4] == '.') {
        return .{ .index = XATTR_INDEX_USER, .suffix = full_name[5..] };
    }
    if (full_name.len > 8 and full_name[0] == 's' and full_name[1] == 'e' and full_name[2] == 'c' and full_name[3] == 'u' and full_name[4] == 'r' and full_name[5] == 'i' and full_name[6] == 't' and full_name[7] == 'y' and full_name[8] == '.') {
        return .{ .index = XATTR_INDEX_SECURITY, .suffix = full_name[9..] };
    }
    if (full_name.len > 8 and full_name[0] == 't' and full_name[1] == 'r' and full_name[2] == 'u' and full_name[3] == 's' and full_name[4] == 't' and full_name[5] == 'e' and full_name[6] == 'd' and full_name[7] == '.') {
        return .{ .index = XATTR_INDEX_TRUSTED, .suffix = full_name[8..] };
    }
    return .{ .index = 0, .suffix = full_name }; // unrecognized prefix
}

fn xattrPrefixName(index: u8) []const u8 {
    return switch (index) {
        XATTR_INDEX_USER => "user.",
        XATTR_INDEX_SECURITY => "security.",
        XATTR_INDEX_TRUSTED => "trusted.",
        XATTR_INDEX_POSIX_ACL_ACCESS => "system.posix_acl_access",
        XATTR_INDEX_POSIX_ACL_DEFAULT => "system.posix_acl_default",
        else => "",
    };
}

/// Get xattr value for an inode. Returns value length, or negative error.
pub fn ext2Getxattr(ino: u32, name: []const u8, value_buf: []u8) i64 {
    if (name.len == 0) return -22; // -EINVAL

    const parsed = xattrNameIndex(name);
    if (parsed.index == 0) return -95; // -EOPNOTSUPP (unknown namespace)

    const disk_inode = loadInodeDisk(ino) orelse return -5; // -EIO
    const xattr_block = disk_inode.i_file_acl;
    if (xattr_block == 0) return -61; // -ENODATA

    const blk = readBlock(xattr_block) orelse return -5;
    const magic = readU32FromBlock(blk, 0);
    if (magic != XATTR_MAGIC) return -61; // -ENODATA (corrupt or no xattrs)

    // Scan entries starting after header
    var off: usize = XATTR_HEADER_SIZE;
    while (off + XATTR_ENTRY_HEADER <= block_size) {
        const e_name_len: usize = blk[off];
        const e_name_index = blk[off + 1];
        const e_value_offs: usize = @as(usize, blk[off + 2]) | (@as(usize, blk[off + 3]) << 8);
        const e_value_size: usize = readU32FromBlock(blk, @truncate(off + 8));

        if (e_name_len == 0) break; // end of entries

        // Check match
        if (e_name_index == parsed.index and e_name_len == parsed.suffix.len) {
            var match = true;
            for (0..e_name_len) |i| {
                if (blk[off + XATTR_ENTRY_HEADER + i] != parsed.suffix[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                if (value_buf.len == 0) return @intCast(e_value_size); // size query
                if (e_value_size > value_buf.len) return -34; // -ERANGE
                if (e_value_offs + e_value_size <= block_size) {
                    for (0..e_value_size) |i| {
                        value_buf[i] = blk[e_value_offs + i];
                    }
                }
                return @intCast(e_value_size);
            }
        }

        // Advance to next entry (aligned)
        const entry_size = (XATTR_ENTRY_HEADER + e_name_len + XATTR_ENTRY_ALIGN - 1) & ~(XATTR_ENTRY_ALIGN - 1);
        off += entry_size;
    }
    return -61; // -ENODATA
}

/// Set xattr on an inode. Returns 0 on success, negative error.
pub fn ext2Setxattr(ino: u32, name: []const u8, value: []const u8, flags: u32) i64 {
    if (name.len == 0 or value.len > 4096) return -22; // -EINVAL

    const parsed = xattrNameIndex(name);
    if (parsed.index == 0) return -95; // -EOPNOTSUPP

    const XATTR_CREATE: u32 = 1;
    const XATTR_REPLACE: u32 = 2;

    ext2_lock.acquire();
    defer ext2_lock.release();

    var disk_inode = loadInodeDisk(ino) orelse return -5;
    var xattr_block = disk_inode.i_file_acl;

    // Allocate xattr block if needed
    if (xattr_block == 0) {
        if (flags & XATTR_REPLACE != 0) return -61; // -ENODATA (can't replace nonexistent)
        const new_block = allocBlock() orelse return -28; // -ENOSPC
        xattr_block = new_block;
        disk_inode.i_file_acl = new_block;
        _ = writeInodeDisk(ino, &disk_inode);

        // Initialize block with header
        const blk = readBlock(new_block) orelse {
            _ = freeBlock(new_block);
            return -5;
        };
        writeU32ToBlock(blk, 0, XATTR_MAGIC);
        writeU32ToBlock(blk, 4, 1); // refcount = 1
        writeU32ToBlock(blk, 8, 1); // blocks = 1
        writeU32ToBlock(blk, 12, 0); // hash = 0
        // Zero reserved area
        for (16..XATTR_HEADER_SIZE) |i| blk[i] = 0;
        // Zero rest of block
        for (XATTR_HEADER_SIZE..block_size) |i| blk[i] = 0;

        // Write the first entry + value
        const entry_size = (XATTR_ENTRY_HEADER + parsed.suffix.len + XATTR_ENTRY_ALIGN - 1) & ~(XATTR_ENTRY_ALIGN - 1);
        const value_offs = block_size - value.len;

        blk[XATTR_HEADER_SIZE] = @truncate(parsed.suffix.len); // name_len
        blk[XATTR_HEADER_SIZE + 1] = parsed.index; // name_index
        blk[XATTR_HEADER_SIZE + 2] = @truncate(value_offs); // value_offs low
        blk[XATTR_HEADER_SIZE + 3] = @truncate(value_offs >> 8); // value_offs high
        writeU32ToBlock(blk, @truncate(XATTR_HEADER_SIZE + 4), 0); // value_block
        writeU32ToBlock(blk, @truncate(XATTR_HEADER_SIZE + 8), @truncate(value.len)); // value_size
        writeU32ToBlock(blk, @truncate(XATTR_HEADER_SIZE + 12), 0); // hash
        for (0..parsed.suffix.len) |i| {
            blk[XATTR_HEADER_SIZE + XATTR_ENTRY_HEADER + i] = parsed.suffix[i];
        }
        // Sentinel: zero the next entry's name_len
        if (XATTR_HEADER_SIZE + entry_size < block_size) {
            blk[XATTR_HEADER_SIZE + entry_size] = 0;
        }
        // Write value at end of block
        for (0..value.len) |i| {
            blk[value_offs + i] = value[i];
        }

        beginJournalTx(1);
        _ = writeBlock(new_block, blk);
        commitJournalTx();
        return 0;
    }

    // Block exists — find or add entry
    const blk = readBlock(xattr_block) orelse return -5;
    const magic = readU32FromBlock(blk, 0);
    if (magic != XATTR_MAGIC) return -5; // corrupt

    // Find existing entry and lowest value offset
    var off: usize = XATTR_HEADER_SIZE;
    var found_off: ?usize = null;
    var lowest_value_off: usize = block_size;
    var entries_end: usize = XATTR_HEADER_SIZE;

    while (off + XATTR_ENTRY_HEADER <= block_size) {
        const e_name_len: usize = blk[off];
        const e_name_index = blk[off + 1];
        if (e_name_len == 0) break;

        const e_value_offs: usize = @as(usize, blk[off + 2]) | (@as(usize, blk[off + 3]) << 8);
        const e_value_size: usize = readU32FromBlock(blk, @truncate(off + 8));

        if (e_value_offs > 0 and e_value_offs < lowest_value_off) {
            lowest_value_off = e_value_offs - (e_value_size % XATTR_ENTRY_ALIGN); // account for alignment
            if (e_value_offs < lowest_value_off) lowest_value_off = e_value_offs;
        }

        // Check for match
        if (e_name_index == parsed.index and e_name_len == parsed.suffix.len) {
            var match = true;
            for (0..e_name_len) |i| {
                if (blk[off + XATTR_ENTRY_HEADER + i] != parsed.suffix[i]) {
                    match = false;
                    break;
                }
            }
            if (match) found_off = off;
        }

        const entry_size = (XATTR_ENTRY_HEADER + e_name_len + XATTR_ENTRY_ALIGN - 1) & ~(XATTR_ENTRY_ALIGN - 1);
        off += entry_size;
        entries_end = off;
    }

    if (found_off != null and flags & XATTR_CREATE != 0) return -17; // -EEXIST
    if (found_off == null and flags & XATTR_REPLACE != 0) return -61; // -ENODATA

    if (found_off) |fo| {
        // Update existing entry's value
        const old_value_offs: usize = @as(usize, blk[fo + 2]) | (@as(usize, blk[fo + 3]) << 8);
        const old_value_size: usize = readU32FromBlock(blk, @truncate(fo + 8));

        // Simple case: new value fits in old value's space
        if (value.len <= old_value_size) {
            const new_offs = old_value_offs + old_value_size - value.len;
            // Zero old value area
            for (old_value_offs..old_value_offs + old_value_size) |i| blk[i] = 0;
            // Write new value
            for (0..value.len) |i| blk[new_offs + i] = value[i];
            // Update entry
            blk[fo + 2] = @truncate(new_offs);
            blk[fo + 3] = @truncate(new_offs >> 8);
            writeU32ToBlock(blk, @truncate(fo + 8), @truncate(value.len));

            beginJournalTx(1);
            _ = writeBlock(xattr_block, blk);
            commitJournalTx();
            return 0;
        }

        // New value larger — need space check
        if (lowest_value_off < entries_end + value.len) return -28; // -ENOSPC
        const new_offs = lowest_value_off - value.len;
        // Zero old value
        for (old_value_offs..old_value_offs + old_value_size) |i| blk[i] = 0;
        // Write new value
        for (0..value.len) |i| blk[new_offs + i] = value[i];
        blk[fo + 2] = @truncate(new_offs);
        blk[fo + 3] = @truncate(new_offs >> 8);
        writeU32ToBlock(blk, @truncate(fo + 8), @truncate(value.len));

        beginJournalTx(1);
        _ = writeBlock(xattr_block, blk);
        commitJournalTx();
        return 0;
    }

    // New entry — check space
    const new_entry_size = (XATTR_ENTRY_HEADER + parsed.suffix.len + XATTR_ENTRY_ALIGN - 1) & ~(XATTR_ENTRY_ALIGN - 1);
    const value_space_needed = value.len;
    if (entries_end + new_entry_size + 1 >= lowest_value_off - value_space_needed) return -28; // -ENOSPC

    const new_value_offs = lowest_value_off - value_space_needed;

    // Write entry at entries_end
    blk[entries_end] = @truncate(parsed.suffix.len);
    blk[entries_end + 1] = parsed.index;
    blk[entries_end + 2] = @truncate(new_value_offs);
    blk[entries_end + 3] = @truncate(new_value_offs >> 8);
    writeU32ToBlock(blk, @truncate(entries_end + 4), 0);
    writeU32ToBlock(blk, @truncate(entries_end + 8), @truncate(value.len));
    writeU32ToBlock(blk, @truncate(entries_end + 12), 0);
    for (0..parsed.suffix.len) |i| {
        blk[entries_end + XATTR_ENTRY_HEADER + i] = parsed.suffix[i];
    }
    // Sentinel
    if (entries_end + new_entry_size < block_size) {
        blk[entries_end + new_entry_size] = 0;
    }
    // Write value
    for (0..value.len) |i| blk[new_value_offs + i] = value[i];

    beginJournalTx(1);
    _ = writeBlock(xattr_block, blk);
    commitJournalTx();
    return 0;
}

/// List xattr names for an inode. Returns total bytes needed, or negative error.
pub fn ext2Listxattr(ino: u32, buf: []u8) i64 {
    const disk_inode = loadInodeDisk(ino) orelse return -5;
    const xattr_block = disk_inode.i_file_acl;
    if (xattr_block == 0) return 0; // no xattrs

    const blk = readBlock(xattr_block) orelse return -5;
    const magic = readU32FromBlock(blk, 0);
    if (magic != XATTR_MAGIC) return 0;

    var off: usize = XATTR_HEADER_SIZE;
    var total: usize = 0;

    while (off + XATTR_ENTRY_HEADER <= block_size) {
        const e_name_len: usize = blk[off];
        const e_name_index = blk[off + 1];
        if (e_name_len == 0) break;

        const prefix = xattrPrefixName(e_name_index);
        const full_len = prefix.len + e_name_len + 1; // +1 for null terminator

        if (buf.len > 0) {
            if (total + full_len > buf.len) return -34; // -ERANGE
            for (0..prefix.len) |i| buf[total + i] = prefix[i];
            for (0..e_name_len) |i| buf[total + prefix.len + i] = blk[off + XATTR_ENTRY_HEADER + i];
            buf[total + prefix.len + e_name_len] = 0; // null terminator
        }
        total += full_len;

        const entry_size = (XATTR_ENTRY_HEADER + e_name_len + XATTR_ENTRY_ALIGN - 1) & ~(XATTR_ENTRY_ALIGN - 1);
        off += entry_size;
    }

    return @intCast(total);
}

/// Remove xattr from an inode. Returns 0 on success, negative error.
pub fn ext2Removexattr(ino: u32, name: []const u8) i64 {
    if (name.len == 0) return -22;

    const parsed = xattrNameIndex(name);
    if (parsed.index == 0) return -95;

    ext2_lock.acquire();
    defer ext2_lock.release();

    const disk_inode = loadInodeDisk(ino) orelse return -5;
    const xattr_block = disk_inode.i_file_acl;
    if (xattr_block == 0) return -61; // -ENODATA

    const blk = readBlock(xattr_block) orelse return -5;
    const magic = readU32FromBlock(blk, 0);
    if (magic != XATTR_MAGIC) return -61;

    var off: usize = XATTR_HEADER_SIZE;
    while (off + XATTR_ENTRY_HEADER <= block_size) {
        const e_name_len: usize = blk[off];
        const e_name_index = blk[off + 1];
        if (e_name_len == 0) break;

        if (e_name_index == parsed.index and e_name_len == parsed.suffix.len) {
            var match = true;
            for (0..e_name_len) |i| {
                if (blk[off + XATTR_ENTRY_HEADER + i] != parsed.suffix[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                // Zero out the value
                const e_value_offs: usize = @as(usize, blk[off + 2]) | (@as(usize, blk[off + 3]) << 8);
                const e_value_size: usize = readU32FromBlock(blk, @truncate(off + 8));
                if (e_value_offs > 0 and e_value_offs + e_value_size <= block_size) {
                    for (e_value_offs..e_value_offs + e_value_size) |i| blk[i] = 0;
                }
                // Zero the entry by shifting remaining entries down
                const entry_size = (XATTR_ENTRY_HEADER + e_name_len + XATTR_ENTRY_ALIGN - 1) & ~(XATTR_ENTRY_ALIGN - 1);
                var src = off + entry_size;
                var dst = off;
                while (src + XATTR_ENTRY_HEADER <= block_size and blk[src] != 0) {
                    const sl: usize = blk[src];
                    const se = (XATTR_ENTRY_HEADER + sl + XATTR_ENTRY_ALIGN - 1) & ~(XATTR_ENTRY_ALIGN - 1);
                    for (0..se) |i| blk[dst + i] = blk[src + i];
                    dst += se;
                    src += se;
                }
                // Zero the rest
                while (dst < src) : (dst += 1) blk[dst] = 0;

                beginJournalTx(1);
                _ = writeBlock(xattr_block, blk);
                commitJournalTx();
                return 0;
            }
        }

        const entry_size = (XATTR_ENTRY_HEADER + e_name_len + XATTR_ENTRY_ALIGN - 1) & ~(XATTR_ENTRY_ALIGN - 1);
        off += entry_size;
    }
    return -61; // -ENODATA
}
