/// Fixed-size slab allocator for kernel objects.
/// Ported from programs/memory_pool for kernel use.
///
/// O(1) allocation and deallocation via intrusive free list.
/// Zero fragmentation — all objects are the same size.
/// Zero external dependencies — operates on a caller-provided buffer.
///
/// Usage (e.g., for VFS file descriptions):
///   var pool_buf: [512 * @sizeOf(FileDescription)]u8 align(8) = undefined;
///   var pool = SlabPool(FileDescription).initFromBuffer(&pool_buf, 512);
///   const desc = pool.alloc() orelse return error.OutOfMemory;
///   defer pool.free(desc);

pub fn SlabPool(comptime T: type) type {
    const Node = struct { next: ?*@This() };
    const OBJ_SIZE = if (@sizeOf(T) >= @sizeOf(Node)) @sizeOf(T) else @sizeOf(Node);
    const OBJ_ALIGN = if (@alignOf(T) >= @alignOf(Node)) @alignOf(T) else @alignOf(Node);

    return struct {
        const Self = @This();

        free_list: ?*Node,
        base: [*]u8,
        capacity: usize,
        allocated: usize,

        /// Initialize from a pre-allocated static buffer.
        /// `capacity` = number of objects the buffer can hold.
        /// Buffer must be at least `capacity * OBJ_SIZE` bytes.
        pub fn initFromBuffer(buffer: []align(OBJ_ALIGN) u8, capacity: usize) Self {
            var self = Self{
                .free_list = null,
                .base = buffer.ptr,
                .capacity = capacity,
                .allocated = 0,
            };

            // Build free list in reverse (most recently freed = first allocated)
            var i: usize = capacity;
            while (i > 0) {
                i -= 1;
                const ptr: *Node = @ptrCast(@alignCast(buffer.ptr + i * OBJ_SIZE));
                ptr.next = self.free_list;
                self.free_list = ptr;
            }
            return self;
        }

        /// Allocate one object from the pool. Returns null if exhausted.
        pub fn alloc(self: *Self) ?*T {
            const node = self.free_list orelse return null;
            self.free_list = node.next;
            self.allocated += 1;
            // Zero the object before returning
            const bytes: *[OBJ_SIZE]u8 = @ptrCast(node);
            for (bytes) |*b| b.* = 0;
            return @ptrCast(@alignCast(node));
        }

        /// Return an object to the pool.
        pub fn free(self: *Self, ptr: *T) void {
            const node: *Node = @ptrCast(@alignCast(ptr));
            node.next = self.free_list;
            self.free_list = node;
            if (self.allocated > 0) self.allocated -= 1;
        }

        /// Number of objects currently allocated.
        pub fn inUse(self: *const Self) usize {
            return self.allocated;
        }

        /// Number of objects available for allocation.
        pub fn available(self: *const Self) usize {
            return self.capacity - self.allocated;
        }

        /// Reset the pool — all objects returned to free list.
        /// WARNING: invalidates all previously returned pointers.
        pub fn reset(self: *Self) void {
            self.free_list = null;
            self.allocated = 0;
            var i: usize = self.capacity;
            while (i > 0) {
                i -= 1;
                const ptr: *Node = @ptrCast(@alignCast(self.base + i * OBJ_SIZE));
                ptr.next = self.free_list;
                self.free_list = ptr;
            }
        }
    };
}

/// Multi-size slab allocator with power-of-2 size classes.
/// Routes allocations to the smallest class that fits.
/// Size classes: 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 bytes.
pub const MultiSlab = struct {
    const NUM_CLASSES = 9;
    const SIZE_CLASSES = [NUM_CLASSES]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };

    // Per-class state (just free list head + count)
    classes: [NUM_CLASSES]ClassState,

    const ClassState = struct {
        free_list: ?*FreeNode,
        capacity: usize,
        allocated: usize,
        obj_size: usize,
    };

    const FreeNode = struct { next: ?*FreeNode };

    /// Initialize from a buffer, dividing it among size classes.
    /// Each class gets `per_class_capacity` objects.
    pub fn init(buffer: []u8, per_class_capacity: usize) MultiSlab {
        var ms: MultiSlab = undefined;
        var offset: usize = 0;

        for (0..NUM_CLASSES) |ci| {
            const obj_size = SIZE_CLASSES[ci];
            const needed = obj_size * per_class_capacity;
            ms.classes[ci] = .{
                .free_list = null,
                .capacity = if (offset + needed <= buffer.len) per_class_capacity else 0,
                .allocated = 0,
                .obj_size = obj_size,
            };

            if (offset + needed <= buffer.len) {
                // Build free list for this class
                var i: usize = per_class_capacity;
                while (i > 0) {
                    i -= 1;
                    const ptr: *FreeNode = @ptrCast(@alignCast(buffer.ptr + offset + i * obj_size));
                    ptr.next = ms.classes[ci].free_list;
                    ms.classes[ci].free_list = ptr;
                }
                offset += needed;
            }
        }
        return ms;
    }

    /// Find the size class index for a given size.
    pub fn classIndex(size: usize) ?usize {
        for (0..NUM_CLASSES) |i| {
            if (SIZE_CLASSES[i] >= size) return i;
        }
        return null; // too large
    }

    /// Allocate from the smallest fitting class.
    pub fn alloc(self: *MultiSlab, size: usize) ?[*]u8 {
        const ci = classIndex(size) orelse return null;
        const node = self.classes[ci].free_list orelse return null;
        self.classes[ci].free_list = node.next;
        self.classes[ci].allocated += 1;
        return @ptrCast(node);
    }

    /// Free back to the appropriate class.
    pub fn free(self: *MultiSlab, ptr: [*]u8, size: usize) void {
        const ci = classIndex(size) orelse return;
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        node.next = self.classes[ci].free_list;
        self.classes[ci].free_list = node;
        if (self.classes[ci].allocated > 0) self.classes[ci].allocated -= 1;
    }
};
