/// Futex (fast userspace mutex) — hash-based wait queue on physical addresses.
/// Supports FUTEX_WAIT (block if *uaddr == val) and FUTEX_WAKE (wake N waiters).

const types = @import("../types.zig");
const vmm = @import("../mm/vmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const scheduler = @import("scheduler.zig");
const process = @import("process.zig");
const errno = @import("errno.zig");

const FUTEX_WAIT: u64 = 0;
const FUTEX_WAKE: u64 = 1;
const FUTEX_PRIVATE_FLAG: u64 = 128;
const MAX_WAITERS: usize = 128;
const HASH_BUCKETS: usize = 64;

const WaitEntry = struct {
    pid: types.ProcessId,
    phys_addr: types.PhysAddr, // Physical address of futex word
    in_use: bool,
    hash_next: u8, // next entry index in this hash bucket chain (0xFF = end)
};

var wait_queue: [MAX_WAITERS]WaitEntry = [_]WaitEntry{.{
    .pid = 0,
    .phys_addr = 0,
    .in_use = false,
    .hash_next = 0xFF,
}} ** MAX_WAITERS;

/// Hash bucket heads — each points to the first WaitEntry index in the chain (0xFF = empty).
var hash_buckets: [HASH_BUCKETS]u8 = [_]u8{0xFF} ** HASH_BUCKETS;

/// Hash a physical address to a bucket index.
fn futexHash(phys: types.PhysAddr) usize {
    return @as(usize, @truncate((phys >> 2) % HASH_BUCKETS));
}

/// Syscall 202: futex(uaddr, futex_op, val)
pub fn sysFutex(frame: *idt.InterruptFrame) void {
    const uaddr = frame.rdi;
    const futex_op = frame.rsi;
    const val = frame.rdx;

    // Strip FUTEX_PRIVATE_FLAG — we're single address space per process
    const op = futex_op & ~FUTEX_PRIVATE_FLAG;
    switch (op) {
        FUTEX_WAIT => futexWait(frame, uaddr, val),
        FUTEX_WAKE => futexWake(frame, uaddr, val),
        else => {
            frame.rax = @bitCast(@as(i64, -errno.ENOSYS));
        },
    }
}

fn futexWait(frame: *idt.InterruptFrame, uaddr: u64, expected_val: u64) void {
    const proc = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Translate user address to physical
    const phys = vmm.translate(proc.page_table, uaddr) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    };

    // Read current u32 value at the physical address via HHDM
    const ptr: *const u32 = @ptrFromInt(hhdm.physToVirt(phys));
    const current_val: u32 = ptr.*;

    // If value changed since caller checked, return EAGAIN (race)
    if (current_val != @as(u32, @truncate(expected_val))) {
        frame.rax = @bitCast(@as(i64, -errno.EAGAIN));
        return;
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
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    }

    // Record this waiter and insert into hash bucket chain
    const target_phys = phys & ~@as(u64, 0xFFF) | (uaddr & 0xFFF);
    const bucket = futexHash(target_phys);
    wait_queue[slot.?] = .{
        .pid = proc.pid,
        .phys_addr = target_phys,
        .in_use = true,
        .hash_next = hash_buckets[bucket],
    };
    hash_buckets[bucket] = @truncate(slot.?);

    serial.writeString("[futex] wait PID ");
    writeDecimal(proc.pid);
    serial.writeString(" on 0x");
    writeHex(uaddr);
    serial.writeString(" (blocked)\n");

    // Block this process — save context and switch away
    // Rewind RIP past `int 0x80` (2 bytes) for syscall restart when woken
    frame.rip -= 2;
    proc.state = .blocked_on_futex;
    scheduler.blockAndSchedule(frame);
}

fn futexWake(frame: *idt.InterruptFrame, uaddr: u64, max_wake: u64) void {
    const proc = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Translate user address to physical
    const phys = vmm.translate(proc.page_table, uaddr) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    };

    const target_phys = phys & ~@as(u64, 0xFFF) | (uaddr & 0xFFF);
    var woken: u64 = 0;
    const bucket = futexHash(target_phys);

    // Walk the hash bucket chain instead of scanning all 128 entries
    var prev_idx: ?u8 = null;
    var cur_idx: u8 = hash_buckets[bucket];
    while (cur_idx != 0xFF and woken < max_wake) {
        const next = wait_queue[cur_idx].hash_next;
        if (wait_queue[cur_idx].in_use and wait_queue[cur_idx].phys_addr == target_phys) {
            const wake_pid = wait_queue[cur_idx].pid;
            wait_queue[cur_idx].in_use = false;
            // Remove from chain
            if (prev_idx) |p| {
                wait_queue[p].hash_next = next;
            } else {
                hash_buckets[bucket] = next;
            }
            wait_queue[cur_idx].hash_next = 0xFF;
            scheduler.wakeProcess(wake_pid);
            woken += 1;
            // Don't advance prev_idx since we removed cur
        } else {
            prev_idx = cur_idx;
        }
        cur_idx = next;
    }

    if (woken > 0) {
        serial.writeString("[futex] wake ");
        writeDecimal(woken);
        serial.writeString(" on 0x");
        writeHex(uaddr);
        serial.writeString("\n");
    }

    frame.rax = woken;
}

/// Wake waiters on a physical address — used by sysExit for clear_child_tid.
pub fn wakeAddress(page_table: types.PhysAddr, uaddr: u64, max_wake: u64) u64 {
    const phys = vmm.translate(page_table, uaddr) orelse return 0;
    const target_phys = phys & ~@as(u64, 0xFFF) | (uaddr & 0xFFF);
    var woken: u64 = 0;
    const bucket = futexHash(target_phys);

    // Walk the hash bucket chain
    var prev_idx: ?u8 = null;
    var cur_idx: u8 = hash_buckets[bucket];
    while (cur_idx != 0xFF and woken < max_wake) {
        const next = wait_queue[cur_idx].hash_next;
        if (wait_queue[cur_idx].in_use and wait_queue[cur_idx].phys_addr == target_phys) {
            const wake_pid = wait_queue[cur_idx].pid;
            wait_queue[cur_idx].in_use = false;
            // Remove from chain
            if (prev_idx) |p| {
                wait_queue[p].hash_next = next;
            } else {
                hash_buckets[bucket] = next;
            }
            wait_queue[cur_idx].hash_next = 0xFF;
            scheduler.wakeProcess(wake_pid);
            woken += 1;
        } else {
            prev_idx = cur_idx;
        }
        cur_idx = next;
    }

    return woken;
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

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}
