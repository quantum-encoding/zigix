/// Futex (fast userspace mutex) — hash-based wait queue on physical addresses.
/// Supports FUTEX_WAIT (block if *uaddr == val) and FUTEX_WAKE (wake N waiters).
///
/// ARM64 port: uses identity mapping (phys == virt) instead of HHDM.

const vmm = @import("vmm.zig");
const uart = @import("uart.zig");
const scheduler = @import("scheduler.zig");
const process = @import("process.zig");
const pmm = @import("pmm.zig");
const spinlock = @import("spinlock.zig");

pub const FUTEX_WAIT: u64 = 0;
pub const FUTEX_WAKE: u64 = 1;
pub const FUTEX_REQUEUE: u64 = 3;
pub const FUTEX_CMP_REQUEUE: u64 = 4;
const MAX_WAITERS: usize = 256;
const HASH_BUCKETS: usize = 256;

const WaitEntry = struct {
    pid: u64,
    phys_addr: u64,
    expected_val: u32, // value the waiter expects (blocks while *addr == expected)
    in_use: bool,
    hash_next: u8, // next entry index in this hash bucket chain (0xFF = end)
};

var wait_queue: [MAX_WAITERS]WaitEntry = [_]WaitEntry{.{
    .pid = 0,
    .phys_addr = 0,
    .expected_val = 0,
    .in_use = false,
    .hash_next = 0xFF,
}} ** MAX_WAITERS;

/// Hash bucket heads — each points to the first WaitEntry index in the chain (0xFF = empty).
var hash_buckets: [HASH_BUCKETS]u8 = [_]u8{0xFF} ** HASH_BUCKETS;

/// Hash a physical address to a bucket index.
fn futexHash(phys: u64) usize {
    return @as(usize, @truncate((phys >> 2) % HASH_BUCKETS));
}

/// SMP lock — protects wait_queue and hash_buckets.
var futex_lock: spinlock.IrqSpinlock = .{};

/// Handle futex syscall dispatch.
/// val2 and uaddr2 are used by FUTEX_REQUEUE/FUTEX_CMP_REQUEUE.
pub fn sysFutex(uaddr: u64, futex_op: u64, val: u64, val2: u64, uaddr2: u64, val3: u64, proc: *process.Process) i64 {
    const op = futex_op & 0x7F; // Mask out FUTEX_PRIVATE_FLAG

    switch (op) {
        FUTEX_WAIT => {
            return futexWait(uaddr, val, proc);
        },
        FUTEX_WAKE => {
            return futexWake(uaddr, val, proc);
        },
        FUTEX_REQUEUE => return futexRequeue(uaddr, val, val2, uaddr2, proc),
        FUTEX_CMP_REQUEUE => return futexCmpRequeue(uaddr, val, val2, uaddr2, val3, proc),
        else => {
            uart.print("[futex] P{} unsupported op={} uaddr={x} val={}\n", .{ proc.pid, op, uaddr, val });
            return -38; // -ENOSYS
        },
    }
}

fn futexWait(uaddr: u64, expected_val: u64, proc: *process.Process) i64 {
    // Ensure the futex page is demand-paged and user-accessible
    const exception = @import("exception.zig");
    const pte = vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(uaddr));
    if (pte == null or !pte.?.isValid() or !pte.?.isUser()) {
        // Try demand-paging
        if (!exception.demandPageUser(uaddr)) return -14; // -EFAULT
    }

    // Translate user address to physical
    const phys = (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(uaddr)) orelse return -14).toInt(); // -EFAULT
    if (phys == 0) return -14; // Physical address 0 is not valid RAM

    futex_lock.acquire();

    // Read current u32 at the physical address (identity mapped)
    const ptr: *const u32 = @ptrFromInt(phys);
    const current_val: u32 = ptr.*;

    // If value changed since caller checked, return EAGAIN (race condition)
    if (current_val != @as(u32, @truncate(expected_val))) {
        futex_lock.release();
        return -11; // -EAGAIN
    }

    // Find a free wait queue slot
    var slot: ?usize = null;
    for (0..MAX_WAITERS) |i| {
        if (!wait_queue[i].in_use) {
            slot = i;
            break;
        }
    }

    if (slot == null) {
        futex_lock.release();
        return -12; // -ENOMEM
    }

    // Record this waiter using physical address for cross-address-space matching
    const target_phys = (phys & ~@as(u64, 0xFFF)) | (uaddr & 0xFFF);
    const bucket = futexHash(target_phys);

    wait_queue[slot.?] = .{
        .pid = proc.pid,
        .phys_addr = target_phys,
        .expected_val = @as(u32, @truncate(expected_val)),
        .in_use = true,
        .hash_next = hash_buckets[bucket],
    };
    hash_buckets[bucket] = @truncate(slot.?);

    // Block — caller (syscall handler) will do blockAndSchedule
    proc.state = .blocked_on_futex;

    futex_lock.release();

    return -516; // Special: caller should blockAndSchedule
}

fn futexWake(uaddr: u64, max_wake: u64, proc: *process.Process) i64 {
    const phys = (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(uaddr)) orelse return -14).toInt(); // -EFAULT
    if (phys == 0) return -14; // Physical address 0 is not valid RAM

    const target_phys = (phys & ~@as(u64, 0xFFF)) | (uaddr & 0xFFF);
    var woken: u64 = 0;

    // Collect PIDs to wake under lock via hash bucket chain, then wake outside lock
    var wake_pids: [MAX_WAITERS]u64 = undefined;
    var wake_count: usize = 0;
    const bucket = futexHash(target_phys);

    futex_lock.acquire();
    var prev_idx: ?u8 = null;
    var cur_idx: u8 = hash_buckets[bucket];
    while (cur_idx != 0xFF and woken < max_wake) {
        const next = wait_queue[cur_idx].hash_next;
        if (wait_queue[cur_idx].in_use and wait_queue[cur_idx].phys_addr == target_phys) {
            wake_pids[wake_count] = wait_queue[cur_idx].pid;
            wake_count += 1;
            wait_queue[cur_idx].in_use = false;
            // Remove from chain
            if (prev_idx) |p| {
                wait_queue[p].hash_next = next;
            } else {
                hash_buckets[bucket] = next;
            }
            wait_queue[cur_idx].hash_next = 0xFF;
            woken += 1;
        } else {
            prev_idx = cur_idx;
        }
        cur_idx = next;
    }
    futex_lock.release();

    // Wake processes outside the futex lock
    for (0..wake_count) |i| {
        scheduler.wakeProcess(wake_pids[i]);
    }

    return @intCast(woken);
}

/// FUTEX_REQUEUE: wake `max_wake` waiters on uaddr, then move up to `max_requeue`
/// waiters from uaddr to uaddr2. Used by musl's pthread_cond_signal/broadcast.
fn futexRequeue(uaddr: u64, max_wake: u64, max_requeue: u64, uaddr2: u64, proc: *process.Process) i64 {
    const phys1 = (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(uaddr)) orelse return -14).toInt();
    if (phys1 == 0) return -14;
    const phys2 = (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(uaddr2)) orelse return -14).toInt();
    if (phys2 == 0) return -14;

    const target_phys1 = (phys1 & ~@as(u64, 0xFFF)) | (uaddr & 0xFFF);
    const target_phys2 = (phys2 & ~@as(u64, 0xFFF)) | (uaddr2 & 0xFFF);

    var woken: u64 = 0;
    var requeued: u64 = 0;

    var wake_pids: [MAX_WAITERS]u64 = undefined;
    var wake_count: usize = 0;
    const bucket1 = futexHash(target_phys1);
    const bucket2 = futexHash(target_phys2);

    futex_lock.acquire();
    // Walk bucket1 chain, wake or requeue matching entries
    var prev_idx: ?u8 = null;
    var cur_idx: u8 = hash_buckets[bucket1];
    while (cur_idx != 0xFF) {
        const next = wait_queue[cur_idx].hash_next;
        if (!wait_queue[cur_idx].in_use or wait_queue[cur_idx].phys_addr != target_phys1) {
            prev_idx = cur_idx;
            cur_idx = next;
            continue;
        }

        if (woken < max_wake) {
            wake_pids[wake_count] = wait_queue[cur_idx].pid;
            wake_count += 1;
            wait_queue[cur_idx].in_use = false;
            // Remove from chain
            if (prev_idx) |p| {
                wait_queue[p].hash_next = next;
            } else {
                hash_buckets[bucket1] = next;
            }
            wait_queue[cur_idx].hash_next = 0xFF;
            woken += 1;
        } else if (requeued < max_requeue) {
            // Move waiter to uaddr2 — update phys_addr and rehash
            wait_queue[cur_idx].phys_addr = target_phys2;
            // Remove from bucket1 chain
            if (prev_idx) |p| {
                wait_queue[p].hash_next = next;
            } else {
                hash_buckets[bucket1] = next;
            }
            // Insert into bucket2 chain
            wait_queue[cur_idx].hash_next = hash_buckets[bucket2];
            hash_buckets[bucket2] = cur_idx;
            requeued += 1;
        } else {
            prev_idx = cur_idx;
        }
        cur_idx = next;
    }
    futex_lock.release();

    for (0..wake_count) |i| {
        scheduler.wakeProcess(wake_pids[i]);
    }

    return @intCast(woken + requeued);
}

/// FUTEX_CMP_REQUEUE: like REQUEUE but first checks *uaddr == val3.
fn futexCmpRequeue(uaddr: u64, max_wake: u64, max_requeue: u64, uaddr2: u64, val3: u64, proc: *process.Process) i64 {
    // Ensure the page is accessible
    const exception = @import("exception.zig");
    const pte = vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(uaddr));
    if (pte == null or !pte.?.isValid() or !pte.?.isUser()) {
        if (!exception.demandPageUser(uaddr)) return -14;
    }

    const phys1 = (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(uaddr)) orelse return -14).toInt();
    if (phys1 == 0) return -14;

    // Check current value before proceeding
    const ptr: *const u32 = @ptrFromInt(phys1);
    const current_val: u32 = ptr.*;
    if (current_val != @as(u32, @truncate(val3))) {
        return -11; // -EAGAIN
    }

    // Delegate to requeue logic
    return futexRequeue(uaddr, max_wake, max_requeue, uaddr2, proc);
}

/// Wake waiters on a physical address — used by sysExit for clear_child_tid.
pub fn wakeAddress(page_table: u64, uaddr: u64, max_wake: u64) u64 {
    const phys = (vmm.translate(vmm.PhysAddr.from(page_table), vmm.VirtAddr.from(uaddr)) orelse return 0).toInt();
    const target_phys = (phys & ~@as(u64, 0xFFF)) | (uaddr & 0xFFF);
    var woken: u64 = 0;
    const bucket = futexHash(target_phys);

    var wake_pids: [MAX_WAITERS]u64 = undefined;
    var wake_count: usize = 0;

    futex_lock.acquire();
    var prev_idx: ?u8 = null;
    var cur_idx: u8 = hash_buckets[bucket];
    while (cur_idx != 0xFF and woken < max_wake) {
        const next = wait_queue[cur_idx].hash_next;
        if (wait_queue[cur_idx].in_use and wait_queue[cur_idx].phys_addr == target_phys) {
            wake_pids[wake_count] = wait_queue[cur_idx].pid;
            wake_count += 1;
            wait_queue[cur_idx].in_use = false;
            if (prev_idx) |p| {
                wait_queue[p].hash_next = next;
            } else {
                hash_buckets[bucket] = next;
            }
            wait_queue[cur_idx].hash_next = 0xFF;
            woken += 1;
        } else {
            prev_idx = cur_idx;
        }
        cur_idx = next;
    }
    futex_lock.release();

    for (0..wake_count) |i| {
        scheduler.wakeProcess(wake_pids[i]);
    }

    return woken;
}

/// Poll all futex waiters — wake any whose futex word has changed OR
/// who have been blocked too long (spurious wakeup).
/// Called from timer interrupt. The futex protocol explicitly allows
/// spurious wakeups — waiters re-check the condition and re-wait.
/// This handles the case where a producer atomically stores work
/// but doesn't call FUTEX_WAKE (e.g., Zig thread pool Condition var race).
var poll_tick: u64 = 0;

pub fn pollWaiters() void {
    poll_tick += 1;
    var wake_pids: [MAX_WAITERS]u64 = undefined;
    var wake_count: usize = 0;

    futex_lock.acquire();
    for (0..MAX_WAITERS) |i| {
        if (!wait_queue[i].in_use) continue;
        const phys = wait_queue[i].phys_addr;
        const expected = wait_queue[i].expected_val;
        const ptr: *const u32 = @ptrFromInt(phys);
        const current: u32 = ptr.*;

        // Wake if value changed OR every 100 polls (~1s) as fallback spurious wakeup
        const value_changed = (current != expected);
        const spurious = (poll_tick % 100 == 0);

        if (value_changed or spurious) {
            wake_pids[wake_count] = wait_queue[i].pid;
            wake_count += 1;
            wait_queue[i].in_use = false;
            // Remove from hash chain
            const bucket = futexHash(phys);
            var prev: ?u8 = null;
            var cur: u8 = hash_buckets[bucket];
            while (cur != 0xFF) {
                if (cur == @as(u8, @truncate(i))) {
                    if (prev) |p| {
                        wait_queue[p].hash_next = wait_queue[cur].hash_next;
                    } else {
                        hash_buckets[bucket] = wait_queue[cur].hash_next;
                    }
                    wait_queue[cur].hash_next = 0xFF;
                    break;
                }
                prev = cur;
                cur = wait_queue[cur].hash_next;
            }
        }
    }
    futex_lock.release();

    for (0..wake_count) |j| {
        scheduler.wakeProcess(wake_pids[j]);
    }
}
