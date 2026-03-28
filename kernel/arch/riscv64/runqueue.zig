/// Per-CPU runqueues — O(1) enqueue/dequeue with per-CPU locking.
///
/// Each CPU has its own runqueue (singly-linked list of ready processes).
/// Local operations (pick next, preempt) only acquire the local lock.
/// Cross-CPU operations (wake, load balance) acquire the target CPU's lock.
///
/// Eliminates the global scheduler lock bottleneck: CPUs no longer contend
/// on every timer tick. The global sched_lock is kept only for diagnostics
/// and process table iteration (not on the hot path).

const process = @import("process.zig");
const spinlock = @import("spinlock.zig");
const smp = @import("smp.zig");
const uart = @import("uart.zig");
const timer = @import("timer.zig");

/// Per-CPU runqueue data. Separate from PerCpu to avoid touching the
/// extern struct layout (exception vector uses hardcoded offsets).
pub const RunQueue = struct {
    head: ?*process.Process = null, // First ready process (dequeue here)
    tail: ?*process.Process = null, // Last ready process (enqueue here)
    len: u32 = 0,
    lock: spinlock.IrqSpinlock = .{},
};

/// One runqueue per CPU.
var rqs: [smp.MAX_CPUS]RunQueue = [_]RunQueue{.{}} ** smp.MAX_CPUS;

/// Enqueue a process on a specific CPU's runqueue.
/// Acquires the target CPU's rq_lock.
pub fn enqueue(cpu_id: u32, proc: *process.Process) void {
    if (cpu_id >= smp.MAX_CPUS) return;
    const rq = &rqs[cpu_id];
    rq.lock.acquire();
    defer rq.lock.release();
    enqueueUnlocked(rq, proc);
}

/// Enqueue without acquiring lock (caller must hold rq.lock).
fn enqueueUnlocked(rq: *RunQueue, proc: *process.Process) void {
    proc.rq_next = null;
    if (rq.tail) |t| {
        t.rq_next = proc;
    } else {
        rq.head = proc;
    }
    rq.tail = proc;
    rq.len += 1;
}

/// Dequeue the first ready process from a CPU's runqueue.
/// Acquires the target CPU's rq_lock. Returns null if empty.
pub fn dequeue(cpu_id: u32) ?*process.Process {
    if (cpu_id >= smp.MAX_CPUS) return null;
    const rq = &rqs[cpu_id];
    rq.lock.acquire();
    defer rq.lock.release();
    return dequeueUnlocked(rq);
}

/// Dequeue without acquiring lock (caller must hold rq.lock).
fn dequeueUnlocked(rq: *RunQueue) ?*process.Process {
    const proc = rq.head orelse return null;
    rq.head = proc.rq_next;
    if (rq.head == null) {
        rq.tail = null;
    }
    proc.rq_next = null;
    rq.len -= 1;
    return proc;
}

/// Dequeue the first ready process from the local CPU's runqueue.
/// Acquires local rq_lock.
pub fn dequeueLocal() ?*process.Process {
    return dequeue(smp.current().cpu_id);
}

/// Enqueue a process on the local CPU's runqueue.
pub fn enqueueLocal(proc: *process.Process) void {
    enqueue(smp.current().cpu_id, proc);
}

/// Remove a specific process from its CPU's runqueue.
/// Used when a running process blocks or exits (it's not on any rq,
/// but might be if state was set to .ready before we could dequeue).
pub fn removeFromQueue(cpu_id: u32, proc: *process.Process) void {
    if (cpu_id >= smp.MAX_CPUS) return;
    const rq = &rqs[cpu_id];
    rq.lock.acquire();
    defer rq.lock.release();

    // Walk the list to find and remove
    var prev: ?*process.Process = null;
    var cur = rq.head;
    while (cur) |c| {
        if (c == proc) {
            // Found it — unlink
            if (prev) |p| {
                p.rq_next = c.rq_next;
            } else {
                rq.head = c.rq_next;
            }
            if (rq.tail == c) {
                rq.tail = prev;
            }
            c.rq_next = null;
            rq.len -= 1;
            return;
        }
        prev = c;
        cur = c.rq_next;
    }
    // Not found — process wasn't on this queue (already dequeued or never enqueued)
}

/// Get the runqueue length for a CPU (lock-free read, approximate).
pub fn getLen(cpu_id: u32) u32 {
    if (cpu_id >= smp.MAX_CPUS) return 0;
    return @atomicLoad(u32, &rqs[cpu_id].len, .acquire);
}

/// Find the least-loaded CPU. Used for fork/exec placement.
pub fn leastLoadedCpu() u32 {
    var best_cpu: u32 = 0;
    var best_len: u32 = getLen(0);
    var i: u32 = 1;
    while (i < smp.online_cpus) : (i += 1) {
        const len = getLen(i);
        if (len < best_len) {
            best_len = len;
            best_cpu = i;
        }
    }
    return best_cpu;
}

/// Try to steal a process from the busiest other CPU's runqueue.
/// Called by an idle CPU. Returns the stolen process or null.
pub fn trySteal(my_cpu: u32) ?*process.Process {
    var busiest: u32 = my_cpu;
    var busiest_len: u32 = 0;

    // Find busiest CPU (must have >= 2 processes to be worth stealing from)
    var i: u32 = 0;
    while (i < smp.online_cpus) : (i += 1) {
        if (i == my_cpu) continue;
        const len = getLen(i);
        if (len > busiest_len) {
            busiest_len = len;
            busiest = i;
        }
    }

    if (busiest == my_cpu or busiest_len < 2) return null;

    // Steal from busiest — acquire their lock
    const rq = &rqs[busiest];
    rq.lock.acquire();
    defer rq.lock.release();

    // Double-check under lock
    if (rq.len < 2) return null;

    const stolen = dequeueUnlocked(rq);
    if (stolen) |p| {
        p.home_cpu = my_cpu;
    }
    return stolen;
}

/// Check wake_ticks for processes on a specific CPU's runqueue.
/// Also checks blocked processes in the process table that are assigned to this CPU.
/// Called from timerTick — only scans this CPU's processes, not all 256.
pub fn checkWakeTicks(cpu_id: u32) void {
    const now = timer.getTicks();
    // Scan the process table for blocked processes assigned to this CPU
    // with expired wake ticks. This is still O(MAX_PROCESSES) but only
    // one CPU does this work at a time (its own processes).
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.home_cpu == cpu_id and p.wake_tick != 0) {
                if (p.state == .blocked or p.state == .blocked_on_net) {
                    if (now >= p.wake_tick) {
                        p.wake_tick = 0;
                        p.state = .ready;
                        enqueue(cpu_id, p);
                    }
                }
            }
        }
    }
}

/// Print runqueue stats for all CPUs.
pub fn printStats() void {
    uart.writeString("[rq] Per-CPU runqueue lengths:");
    var i: u32 = 0;
    while (i < smp.online_cpus) : (i += 1) {
        uart.print(" CPU{}={}", .{ i, getLen(i) });
    }
    uart.writeString("\n");
}
