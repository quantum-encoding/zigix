/// Lock-free SPSC (Single Producer, Single Consumer) ring buffer.
/// Ported from programs/lockfree_queue for kernel use.
///
/// Zero-allocation: operates on a caller-provided static buffer.
/// Cache-line padded head/tail to prevent false sharing between CPUs.
/// Wait-free: both push and pop are O(1) with no retry loops.
///
/// Usage:
///   var buf: [1024]MyType = undefined;
///   var q = SpscQueue(MyType).initStatic(&buf);
///   q.push(item);
///   if (q.pop()) |item| { ... }

/// Atomic ordering helpers — in freestanding, use volatile + compiler fence.
/// On x86_64, load/store of aligned usize is atomic; we just need compiler
/// barriers to prevent reordering.
fn atomicLoad(ptr: *volatile usize) usize {
    const val = ptr.*;
    asm volatile ("" ::: .{ .memory = true }); // compiler fence (acquire)
    return val;
}

fn atomicStore(ptr: *volatile usize, val: usize) void {
    asm volatile ("" ::: .{ .memory = true }); // compiler fence (release)
    ptr.* = val;
}

pub fn SpscQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: [*]T,
        capacity: usize,
        mask: usize,

        // Cache-line padded to prevent false sharing between producer and consumer
        head: usize align(64) = 0, // consumer reads, producer checks
        _pad1: [56]u8 = undefined,
        tail: usize align(64) = 0, // producer writes, consumer checks
        _pad2: [56]u8 = undefined,

        /// Initialize from a static buffer. Capacity must be power of 2.
        pub fn initStatic(buffer: []T) Self {
            const cap = buffer.len;
            // Caller must ensure power-of-2 size
            return .{
                .buffer = buffer.ptr,
                .capacity = cap,
                .mask = cap - 1,
            };
        }

        /// Push an item (producer side). Returns false if full.
        pub fn push(self: *volatile Self, item: T) bool {
            const tail = atomicLoad(&self.tail);
            const head = atomicLoad(&self.head);

            if (tail -% head >= self.capacity) return false; // full

            self.buffer[tail & self.mask] = item;
            atomicStore(&self.tail, tail +% 1);
            return true;
        }

        /// Pop an item (consumer side). Returns null if empty.
        pub fn pop(self: *volatile Self) ?T {
            const head = atomicLoad(&self.head);
            const tail = atomicLoad(&self.tail);

            if (head == tail) return null; // empty

            const item = self.buffer[head & self.mask];
            atomicStore(&self.head, head +% 1);
            return item;
        }

        /// Number of items in the queue.
        pub fn len(self: *volatile Self) usize {
            return atomicLoad(&self.tail) -% atomicLoad(&self.head);
        }

        pub fn isEmpty(self: *volatile Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *volatile Self) bool {
            return self.len() >= self.capacity;
        }

        /// Drain all items, calling f for each.
        pub fn drain(self: *volatile Self, comptime f: fn (T) void) usize {
            var count: usize = 0;
            while (self.pop()) |item| {
                f(item);
                count += 1;
            }
            return count;
        }
    };
}
