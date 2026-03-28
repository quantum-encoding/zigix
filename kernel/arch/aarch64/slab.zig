/// Slab allocator — fixed-size object caches backed by PMM pages.
///
/// Sits between the PMM (4K pages) and kernel subsystems (small objects).
/// Each Cache manages objects of one size. Each slab is one or more pages
/// divided into fixed-size slots with an intrusive free list.
///
/// ARM64 identity mapping: phys == virt, so PMM addresses are usable directly.
/// x86_64 version would add HHDM offset in physToVirt().

const pmm = @import("pmm.zig");
const uart = @import("uart.zig");

const PAGE_SIZE: u64 = 4096;

/// Convert PMM physical address to kernel virtual address.
/// ARM64 identity map: phys == virt.
inline fn physToVirt(phys: u64) u64 {
    return phys;
}

// ============================================================================
// Slab — one or more contiguous pages divided into fixed-size slots
// ============================================================================

/// Slab metadata. Stored in a static pool to avoid wasting object slots.
const Slab = struct {
    page_phys: u64,
    page_virt: u64,
    next_free: u64, // Head of intrusive free list (virt addr, 0 = empty)
    in_use: u16,
    capacity: u16,
    active: bool,
    cache_idx: u8,
    next: u16, // Linked list next (index into slab_pool, NULL_SLAB = end)
    prev: u16,
};

const MAX_SLABS: usize = 512;
var slab_pool: [MAX_SLABS]Slab = undefined;
var slab_pool_initialized: bool = false;

const NULL_SLAB: u16 = 0xFFFF;

fn initSlabPool() void {
    for (0..MAX_SLABS) |i| {
        slab_pool[i].active = false;
        slab_pool[i].next = NULL_SLAB;
        slab_pool[i].prev = NULL_SLAB;
    }
    slab_pool_initialized = true;
}

fn allocSlabMeta() ?u16 {
    if (!slab_pool_initialized) initSlabPool();
    for (0..MAX_SLABS) |i| {
        if (!slab_pool[i].active) {
            slab_pool[i].active = true;
            slab_pool[i].next = NULL_SLAB;
            slab_pool[i].prev = NULL_SLAB;
            return @intCast(i);
        }
    }
    return null;
}

fn freeSlabMeta(idx: u16) void {
    if (idx < MAX_SLABS) {
        slab_pool[idx].active = false;
    }
}

// ============================================================================
// Cache — manages all slabs for one object size
// ============================================================================

pub const Cache = struct {
    name: [16]u8,
    name_len: u8,
    object_size: u32,
    slab_pages: u8,
    partial: u16,
    full: u16,
    empty: u16,
    total_alloc: u64,
    total_free: u64,
    active_slabs: u32,
    active: bool,

    /// Allocate one object from this cache. Returns null on OOM.
    pub fn alloc(self: *Cache) ?[*]u8 {
        // 1. Try partial list (has free slots)
        if (self.partial != NULL_SLAB) {
            return self.allocFromSlab(self.partial);
        }
        // 2. Reuse an empty slab
        if (self.empty != NULL_SLAB) {
            const idx = self.empty;
            removeFromList(&self.empty, idx);
            addToList(&self.partial, idx);
            return self.allocFromSlab(idx);
        }
        // 3. Grow: allocate new pages from PMM
        const new_idx = self.growCache() orelse return null;
        return self.allocFromSlab(new_idx);
    }

    /// Free one object back to this cache.
    pub fn free(self: *Cache, ptr: [*]u8) void {
        const addr = @intFromPtr(ptr);
        const slab_idx = self.findSlab(addr) orelse return;
        self.freeToSlab(slab_idx, addr);
    }

    fn allocFromSlab(self: *Cache, slab_idx: u16) ?[*]u8 {
        const slab = &slab_pool[slab_idx];
        if (slab.next_free == 0) return null;

        // Pop from intrusive free list
        const obj_addr = slab.next_free;
        const next_ptr: *u64 = @ptrFromInt(obj_addr);
        slab.next_free = next_ptr.*;
        slab.in_use += 1;
        self.total_alloc += 1;

        // If slab is now full, move partial → full
        if (slab.in_use == slab.capacity) {
            removeFromList(&self.partial, slab_idx);
            addToList(&self.full, slab_idx);
        }

        return @ptrFromInt(obj_addr);
    }

    fn freeToSlab(self: *Cache, slab_idx: u16, addr: u64) void {
        const slab = &slab_pool[slab_idx];
        const was_full = (slab.in_use == slab.capacity);

        // Push onto intrusive free list
        const obj_ptr: *u64 = @ptrFromInt(addr);
        obj_ptr.* = slab.next_free;
        slab.next_free = addr;
        slab.in_use -= 1;
        self.total_free += 1;

        if (was_full) {
            removeFromList(&self.full, slab_idx);
            addToList(&self.partial, slab_idx);
        } else if (slab.in_use == 0) {
            removeFromList(&self.partial, slab_idx);
            addToList(&self.empty, slab_idx);
            self.maybeReclaim();
        }
    }

    fn growCache(self: *Cache) ?u16 {
        const page_phys = if (self.slab_pages == 1)
            pmm.allocPage()
        else
            pmm.allocPages(self.slab_pages);
        const phys = page_phys orelse return null;

        const slab_idx = allocSlabMeta() orelse {
            if (self.slab_pages == 1)
                pmm.freePage(phys)
            else
                pmm.freePages(phys, self.slab_pages);
            return null;
        };

        const virt = physToVirt(phys);
        const slab_size: u64 = @as(u64, self.slab_pages) * PAGE_SIZE;
        const obj_size: u64 = self.object_size;
        const capacity: u16 = @intCast(slab_size / obj_size);

        // Zero the slab pages
        const page_ptr: [*]u8 = @ptrFromInt(virt);
        for (0..slab_size) |i| {
            page_ptr[i] = 0;
        }

        // Build intrusive free list (reverse order so first slot is allocated first)
        var free_head: u64 = 0;
        var i: u16 = capacity;
        while (i > 0) {
            i -= 1;
            const slot_addr = virt + @as(u64, i) * obj_size;
            const slot_ptr: *u64 = @ptrFromInt(slot_addr);
            slot_ptr.* = free_head;
            free_head = slot_addr;
        }

        const ci = self.cacheIndex();
        slab_pool[slab_idx] = .{
            .page_phys = phys,
            .page_virt = virt,
            .next_free = free_head,
            .in_use = 0,
            .capacity = capacity,
            .active = true,
            .cache_idx = ci,
            .next = NULL_SLAB,
            .prev = NULL_SLAB,
        };

        addToList(&self.partial, slab_idx);
        self.active_slabs += 1;
        return slab_idx;
    }

    fn findSlab(self: *const Cache, addr: u64) ?u16 {
        const slab_size: u64 = @as(u64, self.slab_pages) * PAGE_SIZE;
        const lists = [_]u16{ self.partial, self.full, self.empty };
        for (lists) |list_head| {
            var idx = list_head;
            while (idx != NULL_SLAB) {
                const slab = &slab_pool[idx];
                if (addr >= slab.page_virt and addr < slab.page_virt + slab_size) {
                    return idx;
                }
                idx = slab.next;
            }
        }
        return null;
    }

    fn maybeReclaim(self: *Cache) void {
        var count: u32 = 0;
        var idx = self.empty;
        while (idx != NULL_SLAB) : (idx = slab_pool[idx].next) {
            count += 1;
        }
        while (count > 1) {
            const victim = self.empty;
            if (victim == NULL_SLAB) break;
            removeFromList(&self.empty, victim);
            if (self.slab_pages == 1)
                pmm.freePage(slab_pool[victim].page_phys)
            else
                pmm.freePages(slab_pool[victim].page_phys, self.slab_pages);
            freeSlabMeta(victim);
            self.active_slabs -= 1;
            count -= 1;
        }
    }

    fn cacheIndex(self: *const Cache) u8 {
        const base = @intFromPtr(&cache_pool[0]);
        const this = @intFromPtr(self);
        return @intCast((this - base) / @sizeOf(Cache));
    }
};

// -- Doubly-linked list operations (on slab_pool indices) --

fn addToList(head: *u16, idx: u16) void {
    slab_pool[idx].prev = NULL_SLAB;
    slab_pool[idx].next = head.*;
    if (head.* != NULL_SLAB) {
        slab_pool[head.*].prev = idx;
    }
    head.* = idx;
}

fn removeFromList(head: *u16, idx: u16) void {
    const prev = slab_pool[idx].prev;
    const next = slab_pool[idx].next;
    if (prev != NULL_SLAB) {
        slab_pool[prev].next = next;
    } else {
        head.* = next;
    }
    if (next != NULL_SLAB) {
        slab_pool[next].prev = prev;
    }
    slab_pool[idx].prev = NULL_SLAB;
    slab_pool[idx].next = NULL_SLAB;
}

// ============================================================================
// Global cache pool
// ============================================================================

const MAX_CACHES: usize = 16;
var cache_pool: [MAX_CACHES]Cache = undefined;
var cache_pool_initialized: bool = false;
var initialized: bool = false;

fn initCachePool() void {
    for (0..MAX_CACHES) |i| {
        cache_pool[i].active = false;
    }
    cache_pool_initialized = true;
}

/// Create a named cache for fixed-size objects.
pub fn createCache(name: []const u8, object_size: u32, slab_pages: u8) ?*Cache {
    if (!cache_pool_initialized) initCachePool();
    const size = if (object_size < 8) 8 else object_size;
    for (0..MAX_CACHES) |i| {
        if (!cache_pool[i].active) {
            cache_pool[i] = .{
                .name = [_]u8{0} ** 16,
                .name_len = 0,
                .object_size = size,
                .slab_pages = if (slab_pages == 0) 1 else slab_pages,
                .partial = NULL_SLAB,
                .full = NULL_SLAB,
                .empty = NULL_SLAB,
                .total_alloc = 0,
                .total_free = 0,
                .active_slabs = 0,
                .active = true,
            };
            const len = @min(name.len, 16);
            for (0..len) |j| {
                cache_pool[i].name[j] = name[j];
            }
            cache_pool[i].name_len = @intCast(len);
            return &cache_pool[i];
        }
    }
    return null;
}

// ============================================================================
// Generic kmalloc / kfree
// ============================================================================

const SIZE_CLASSES = [_]u32{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
const NUM_SIZE_CLASSES = SIZE_CLASSES.len;
var kmalloc_caches: [NUM_SIZE_CLASSES]?*Cache = [_]?*Cache{null} ** NUM_SIZE_CLASSES;

fn sizeClassIndex(size: u32) ?usize {
    for (SIZE_CLASSES, 0..) |class, i| {
        if (size <= class) return i;
    }
    return null;
}

/// Allocate `size` bytes. For sizes > 4096, falls back to PMM pages.
pub fn kmalloc(size: u32) ?[*]u8 {
    if (!initialized) return null;
    if (size == 0) return null;

    if (sizeClassIndex(size)) |idx| {
        if (kmalloc_caches[idx]) |cache| {
            return cache.alloc();
        }
    }

    // Large allocation: direct PMM
    const pages = (@as(u64, size) + PAGE_SIZE - 1) / PAGE_SIZE;
    const phys = pmm.allocPages(pages) orelse return null;
    return @ptrFromInt(physToVirt(phys));
}

/// Free `size` bytes. Caller must pass the same size used at allocation.
pub fn kfree(ptr: [*]u8, size: u32) void {
    if (!initialized) return;

    if (sizeClassIndex(size)) |idx| {
        if (kmalloc_caches[idx]) |cache| {
            cache.free(ptr);
            return;
        }
    }

    // Large: return pages to PMM (on ARM64 identity map, virt == phys)
    pmm.freePages(@intFromPtr(ptr), (@as(u64, size) + PAGE_SIZE - 1) / PAGE_SIZE);
}

// ============================================================================
// Initialization
// ============================================================================

/// Initialize the slab allocator. Call after PMM init, before subsystem init.
pub fn init() void {
    if (!slab_pool_initialized) initSlabPool();
    if (!cache_pool_initialized) initCachePool();

    // Create generic kmalloc caches
    const names = [_][]const u8{
        "km-16", "km-32", "km-64", "km-128", "km-256",
        "km-512", "km-1024", "km-2048", "km-4096",
    };
    for (SIZE_CLASSES, 0..) |size, i| {
        kmalloc_caches[i] = createCache(names[i], size, 1);
    }
    initialized = true;

    uart.writeString("[slab] Slab allocator initialized (");
    uart.writeDec(NUM_SIZE_CLASSES);
    uart.writeString(" size classes: 16-4096)\n");
}

// ============================================================================
// Stats / Diagnostics
// ============================================================================

pub fn totalActiveObjects() u64 {
    var total: u64 = 0;
    for (0..MAX_CACHES) |i| {
        if (cache_pool[i].active) {
            total += cache_pool[i].total_alloc - cache_pool[i].total_free;
        }
    }
    return total;
}

pub fn totalSlabPages() u64 {
    var total: u64 = 0;
    for (0..MAX_CACHES) |i| {
        if (cache_pool[i].active) {
            total += @as(u64, cache_pool[i].active_slabs) * @as(u64, cache_pool[i].slab_pages);
        }
    }
    return total;
}

/// Reclaim all empty slabs. Returns number of pages freed.
pub fn shrink() u64 {
    var freed: u64 = 0;
    for (0..MAX_CACHES) |i| {
        if (!cache_pool[i].active) continue;
        var idx = cache_pool[i].empty;
        while (idx != NULL_SLAB) {
            const next = slab_pool[idx].next;
            removeFromList(&cache_pool[i].empty, idx);
            const pages = cache_pool[i].slab_pages;
            if (pages == 1)
                pmm.freePage(slab_pool[idx].page_phys)
            else
                pmm.freePages(slab_pool[idx].page_phys, pages);
            freeSlabMeta(idx);
            cache_pool[i].active_slabs -= 1;
            freed += pages;
            idx = next;
        }
    }
    return freed;
}

/// Print slab statistics to UART.
pub fn printStats() void {
    uart.writeString("[slab] Cache statistics:\n");
    for (0..MAX_CACHES) |i| {
        if (!cache_pool[i].active) continue;
        uart.writeString("[slab]   ");
        for (0..cache_pool[i].name_len) |j| {
            uart.writeByte(cache_pool[i].name[j]);
        }
        uart.writeString(": obj=");
        uart.writeDec(cache_pool[i].object_size);
        uart.writeString(" alloc=");
        uart.writeDec(cache_pool[i].total_alloc);
        uart.writeString(" free=");
        uart.writeDec(cache_pool[i].total_free);
        uart.writeString(" active=");
        uart.writeDec(cache_pool[i].total_alloc - cache_pool[i].total_free);
        uart.writeString(" slabs=");
        uart.writeDec(cache_pool[i].active_slabs);
        uart.writeString("\n");
    }
}

/// Get a cache by index (for diagnostics).
pub fn getCache(idx: usize) ?*Cache {
    if (idx >= MAX_CACHES) return null;
    if (!cache_pool[idx].active) return null;
    return &cache_pool[idx];
}

pub fn activeCacheCount() usize {
    var count: usize = 0;
    for (0..MAX_CACHES) |i| {
        if (cache_pool[i].active) count += 1;
    }
    return count;
}
