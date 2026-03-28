/// Unified page cache — caches file data in physical pages indexed by (inode, page_index).
///
/// Sits between VFS and the ext2 block layer. On file read, check the page cache
/// first; only go to disk on a miss. On write, mark the page dirty for later flush.
/// File-backed mmap faults also read through the page cache.
///
/// LRU eviction when cache exceeds limit. Readahead prefetches next pages on
/// sequential access patterns.

const types = @import("../types.zig");
const pmm = @import("pmm.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");

const PAGE_SIZE = types.PAGE_SIZE;

/// Maximum number of cached pages (configurable — ~25% of 256 MB = 16K pages).
/// Start conservative since each entry is small (metadata only; data is in physical pages).
const MAX_CACHED_PAGES: usize = 16384; // 64MB cache — zig cc is 165MB, cache most of it

/// Hash table size — power of 2 for fast modulo.
const HASH_SIZE: usize = 2048;

const CacheEntry = struct {
    inode_num: u32, // ext2 inode number
    page_index: u32, // page offset within file (file_offset / PAGE_SIZE)
    phys: types.PhysAddr, // physical page containing the data
    dirty: bool,
    in_use: bool,
    /// LRU doubly-linked list
    lru_prev: u16, // index into cache_entries, 0xFFFF = none
    lru_next: u16,
    /// Hash chain
    hash_next: u16, // 0xFFFF = end of chain
};

const NONE: u16 = 0xFFFF;

var cache_entries: [MAX_CACHED_PAGES]CacheEntry = init_cache();
var hash_table: [HASH_SIZE]u16 = [_]u16{NONE} ** HASH_SIZE;

// LRU list: head = MRU, tail = LRU
var lru_head: u16 = NONE;
var lru_tail: u16 = NONE;
var cache_used: u16 = 0;

// Readahead tracking
var last_inode: u32 = 0;
var last_page_index: u32 = 0;
var sequential_count: u8 = 0;

fn init_cache() [MAX_CACHED_PAGES]CacheEntry {
    @setEvalBranchQuota(100000);
    var c: [MAX_CACHED_PAGES]CacheEntry = undefined;
    for (0..MAX_CACHED_PAGES) |i| {
        c[i] = .{
            .inode_num = 0,
            .page_index = 0,
            .phys = 0,
            .dirty = false,
            .in_use = false,
            .lru_prev = NONE,
            .lru_next = NONE,
            .hash_next = NONE,
        };
    }
    return c;
}

fn cacheHash(inode_num: u32, page_index: u32) usize {
    // Simple hash combining inode and page index
    const combined = @as(u64, inode_num) * 2654435761 + @as(u64, page_index);
    return @as(usize, @truncate(combined % HASH_SIZE));
}

/// Look up a page in the cache. Returns physical address or null.
pub fn lookup(inode_num: u32, page_index: u32) ?types.PhysAddr {
    const bucket = cacheHash(inode_num, page_index);
    var idx = hash_table[bucket];
    while (idx != NONE) {
        const e = &cache_entries[idx];
        if (e.in_use and e.inode_num == inode_num and e.page_index == page_index) {
            // Cache hit — move to MRU
            lruTouch(idx);
            return e.phys;
        }
        idx = e.hash_next;
    }
    return null;
}

/// Insert a page into the cache. Caller has already populated the physical page.
/// If cache is full, evicts the LRU entry (flushing if dirty).
pub fn insert(inode_num: u32, page_index: u32, phys: types.PhysAddr) void {
    // Check if already cached
    if (lookup(inode_num, page_index) != null) return;

    // Find a free slot or evict LRU
    var slot: u16 = NONE;
    if (cache_used < MAX_CACHED_PAGES) {
        // Find first free slot
        for (0..MAX_CACHED_PAGES) |i| {
            if (!cache_entries[i].in_use) {
                slot = @truncate(i);
                cache_used += 1;
                break;
            }
        }
    }
    if (slot == NONE) {
        // Evict LRU entry
        slot = lru_tail;
        if (slot == NONE) return; // shouldn't happen
        evictEntry(slot);
    }

    // Insert into hash chain
    const bucket = cacheHash(inode_num, page_index);
    cache_entries[slot] = .{
        .inode_num = inode_num,
        .page_index = page_index,
        .phys = phys,
        .dirty = false,
        .in_use = true,
        .lru_prev = NONE,
        .lru_next = NONE,
        .hash_next = hash_table[bucket],
    };
    hash_table[bucket] = slot;

    // Add to MRU position
    lruTouch(slot);

    // Increment ref count so PMM doesn't free this page
    pmm.incRef(phys);

    // Track readahead pattern
    trackSequential(inode_num, page_index);
}

/// Mark a cached page as dirty (for write-back).
pub fn markDirty(inode_num: u32, page_index: u32) void {
    const bucket = cacheHash(inode_num, page_index);
    var idx = hash_table[bucket];
    while (idx != NONE) {
        const e = &cache_entries[idx];
        if (e.in_use and e.inode_num == inode_num and e.page_index == page_index) {
            e.dirty = true;
            return;
        }
        idx = e.hash_next;
    }
}

/// Invalidate a single cached page (used after write to prevent stale reads).
pub fn invalidatePage(inode_num: u32, page_index: u32) void {
    const bucket = cacheHash(inode_num, page_index);
    var idx = hash_table[bucket];
    while (idx != NONE) {
        const e = &cache_entries[idx];
        if (e.in_use and e.inode_num == inode_num and e.page_index == page_index) {
            removeEntry(idx);
            return;
        }
        idx = e.hash_next;
    }
}

/// Invalidate all cached pages for an inode (used on truncate/unlink).
pub fn invalidateInode(inode_num: u32) void {
    for (0..MAX_CACHED_PAGES) |i| {
        if (cache_entries[i].in_use and cache_entries[i].inode_num == inode_num) {
            removeEntry(@truncate(i));
        }
    }
}

/// Check if readahead should be triggered. Returns number of pages to prefetch (0-8).
pub fn readaheadCount(inode_num: u32, page_index: u32) u8 {
    if (inode_num == last_inode and page_index == last_page_index + 1) {
        // Sequential access pattern detected
        if (sequential_count < 8) return sequential_count + 1;
        return 8;
    }
    return 0;
}

// --- Internal helpers ---

fn trackSequential(inode_num: u32, page_index: u32) void {
    if (inode_num == last_inode and page_index == last_page_index + 1) {
        if (sequential_count < 255) sequential_count += 1;
    } else {
        sequential_count = 0;
    }
    last_inode = inode_num;
    last_page_index = page_index;
}

fn evictEntry(idx: u16) void {
    const e = &cache_entries[idx];
    if (!e.in_use) return;

    // If dirty, the caller should have flushed first (we don't have VFS access here).
    // Just drop the dirty flag — data is lost if not flushed. In practice, write()
    // calls writeBlock() directly so cache dirty pages are rare.

    // Remove from hash chain
    const bucket = cacheHash(e.inode_num, e.page_index);
    var prev: u16 = NONE;
    var cur = hash_table[bucket];
    while (cur != NONE) {
        if (cur == idx) {
            if (prev == NONE) {
                hash_table[bucket] = cache_entries[cur].hash_next;
            } else {
                cache_entries[prev].hash_next = cache_entries[cur].hash_next;
            }
            break;
        }
        prev = cur;
        cur = cache_entries[cur].hash_next;
    }

    // Remove from LRU
    lruRemove(idx);

    // Release physical page ref
    if (e.phys != 0) {
        pmm.freePage(e.phys);
    }

    e.in_use = false;
    e.hash_next = NONE;
    if (cache_used > 0) cache_used -= 1;
}

fn removeEntry(idx: u16) void {
    evictEntry(idx);
}

/// Evict the least-recently-used clean cache entry.
/// Returns the freed physical page address, or null if nothing to evict.
/// Called by the PMM recovery chain on OOM.
pub fn evictOne() ?u64 {
    // Walk LRU from tail (oldest) to find a clean entry to evict
    var idx = lru_tail;
    while (idx != NONE) {
        const e = &cache_entries[idx];
        if (e.in_use and !e.dirty) {
            const phys = e.phys;
            // Don't call evictEntry — it calls pmm.freePage, creating a cycle.
            // Just remove from hash + LRU and mark unused, return phys to caller.
            const bucket = cacheHash(e.inode_num, e.page_index);
            var prev: u16 = NONE;
            var cur = hash_table[bucket];
            while (cur != NONE) {
                if (cur == idx) {
                    if (prev == NONE) {
                        hash_table[bucket] = cache_entries[cur].hash_next;
                    } else {
                        cache_entries[prev].hash_next = cache_entries[cur].hash_next;
                    }
                    break;
                }
                prev = cur;
                cur = cache_entries[cur].hash_next;
            }
            lruRemove(idx);
            e.in_use = false;
            e.hash_next = NONE;
            if (cache_used > 0) cache_used -= 1;
            return phys;
        }
        idx = cache_entries[idx].lru_prev;
    }
    return null;
}

fn lruRemove(idx: u16) void {
    const e = &cache_entries[idx];
    if (e.lru_prev != NONE) {
        cache_entries[e.lru_prev].lru_next = e.lru_next;
    } else if (lru_head == idx) {
        lru_head = e.lru_next;
    }
    if (e.lru_next != NONE) {
        cache_entries[e.lru_next].lru_prev = e.lru_prev;
    } else if (lru_tail == idx) {
        lru_tail = e.lru_prev;
    }
    e.lru_prev = NONE;
    e.lru_next = NONE;
}

fn lruTouch(idx: u16) void {
    if (lru_head == idx) return; // already MRU
    lruRemove(idx);
    // Insert at head (MRU)
    cache_entries[idx].lru_prev = NONE;
    cache_entries[idx].lru_next = lru_head;
    if (lru_head != NONE) {
        cache_entries[lru_head].lru_prev = idx;
    }
    lru_head = idx;
    if (lru_tail == NONE) lru_tail = idx;
}

// --- Output helpers ---

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
