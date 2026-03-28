/// Signal delivery — per-process pending bitmap, mask, action table.
/// Default action: terminate for most signals, ignore for SIGCHLD.
/// SIGKILL/SIGSTOP cannot be caught, blocked, or ignored.

const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const vmm = @import("../mm/vmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const types = @import("../types.zig");
const process_mod = @import("process.zig");
const scheduler = @import("scheduler.zig");
const errno = @import("errno.zig");

const InterruptFrame = idt.InterruptFrame;
const Process = process_mod.Process;

// --- Signal numbers ---

pub const SIGHUP: u6 = 1;
pub const SIGINT: u6 = 2;
pub const SIGQUIT: u6 = 3;
pub const SIGILL: u6 = 4;
pub const SIGTRAP: u6 = 5;
pub const SIGABRT: u6 = 6;
pub const SIGBUS: u6 = 7;
pub const SIGFPE: u6 = 8;
pub const SIGKILL: u6 = 9;
pub const SIGUSR1: u6 = 10;
pub const SIGSEGV: u6 = 11;
pub const SIGUSR2: u6 = 12;
pub const SIGPIPE: u6 = 13;
pub const SIGALRM: u6 = 14;
pub const SIGTERM: u6 = 15;
pub const SIGCHLD: u6 = 17;
pub const SIGCONT: u6 = 18;
pub const SIGSTOP: u6 = 19;
pub const SIGTSTP: u6 = 20;

pub const SIG_DFL: u64 = 0;
pub const SIG_IGN: u64 = 1;

const USER_SPACE_END: u64 = 0x0000_8000_0000_0000;
const SIGNAL_FRAME_SIZE: u64 = 0xA8; // 168 bytes

// --- Core functions ---

/// Post a signal to a process (set pending bit). Does not deliver.
/// SIGCONT wakes stopped processes. SIGKILL wakes stopped processes so they can be terminated.
pub fn postSignal(proc: *Process, sig: u6) void {
    if (sig == 0) return;
    proc.sig_pending |= @as(u64, 1) << sig;

    // SIGCONT wakes stopped processes and clears pending stop signals
    if (sig == SIGCONT and proc.state == .stopped) {
        proc.state = .ready;
        proc.sig_pending &= ~(@as(u64, 1) << SIGSTOP);
        proc.sig_pending &= ~(@as(u64, 1) << SIGTSTP);
    }
    // SIGKILL must wake stopped processes so they can be scheduled and terminated
    if (sig == SIGKILL and proc.state == .stopped) {
        proc.state = .ready;
    }
}

/// Check and deliver pending signals. Called before returning to userspace.
pub fn checkAndDeliver(frame: *InterruptFrame) void {
    const proc = scheduler.currentProcess() orelse return;

    if (frame.cs & 3 == 0) return;

    // Force-deliver fatal signals even if masked (prevents infinite SIGSEGV loop).
    // When a signal handler causes the SAME signal (e.g., SIGSEGV handler segfaults),
    // the signal is masked by deliverToHandler. Without this, checkAndDeliver skips
    // the masked signal, iretq re-executes the faulting instruction → infinite loop.
    const fatal_signals: u64 = (@as(u64, 1) << SIGSEGV) | (@as(u64, 1) << SIGBUS) |
        (@as(u64, 1) << SIGFPE) | (@as(u64, 1) << SIGILL);
    const force_fatal = proc.sig_pending & proc.sig_mask & fatal_signals;
    if (force_fatal != 0) {
        const fatal_sig: u6 = @truncate(@ctz(force_fatal));
        proc.sig_pending &= ~(@as(u64, 1) << fatal_sig);
        proc.sig_mask &= ~(@as(u64, 1) << fatal_sig);
        terminateBySignal(frame, fatal_sig);
        return;
    }

    const deliverable = proc.sig_pending & ~proc.sig_mask;
    if (deliverable == 0) return;

    // Lowest set bit = signal number
    const sig: u6 = @truncate(@ctz(deliverable));
    proc.sig_pending &= ~(@as(u64, 1) << sig);

    // SIGKILL/SIGSTOP: always default action, cannot be caught/blocked/ignored
    if (sig == SIGKILL) {
        terminateBySignal(frame, sig);
        return;
    }
    if (sig == SIGSTOP) {
        stopProcess(frame, sig);
        return;
    }

    const action = proc.sig_actions[@as(usize, sig)];

    if (action.handler == SIG_IGN) return;

    if (action.handler == SIG_DFL) {
        if (isDefaultIgnore(sig)) return;
        if (isDefaultStop(sig)) {
            stopProcess(frame, sig);
            return;
        }
        terminateBySignal(frame, sig);
        return;
    }

    // User handler — but for fatal signals (SIGSEGV, SIGBUS, SIGFPE, SIGILL),
    // if we're ALREADY delivering a signal (recursive fault during signal frame
    // setup), force-terminate to prevent infinite loop.
    if (sig == SIGSEGV or sig == SIGBUS or sig == SIGFPE or sig == SIGILL) {
        if (proc.in_signal_handler) {
            // Recursive fatal signal — force terminate
            serial.writeString("[signal] recursive ");
            writeSignalName(sig);
            serial.writeString(" PID ");
            writeDecimal(proc.pid);
            serial.writeString(" — force terminate\n");
            terminateBySignal(frame, sig);
            return;
        }
        proc.in_signal_handler = true;
    }

    // User handler
    deliverToHandler(frame, proc, sig, &proc.sig_actions[@as(usize, sig)]);
}

/// Terminate the current process due to a signal.
pub fn terminateBySignal(frame: *InterruptFrame, sig: u6) void {
    const current = scheduler.currentProcess() orelse return;

    serial.writeString("[signal] ");
    writeSignalName(sig);
    serial.writeString(" PID ");
    writeDecimal(current.pid);
    serial.writeString(" (terminate)\n");

    current.state = .zombie;
    current.in_signal_handler = false;
    current.exit_status = 128 + @as(u64, sig);

    // Wake vfork parent if this was a vfork child
    if (current.parent_pid != 0) {
        for (0..process_mod.MAX_PROCESSES) |vi| {
            if (process_mod.getProcess(vi)) |vp| {
                if (vp.pid == current.parent_pid and vp.vfork_blocked) {
                    vp.vfork_blocked = false;
                    vp.state = .ready;
                    break;
                }
            }
        }
    }

    // Close all file descriptors (pipe EOF, etc.)
    const fd_table = @import("../fs/fd_table.zig");
    for (0..fd_table.MAX_FDS) |i| {
        if (current.fds[i] != null) {
            _ = fd_table.fdClose(&current.fds, @truncate(i));
        }
    }

    // Clear per-CPU reference to this process — prevents rescheduling zombie
    const smp = @import("../arch/x86_64/smp.zig");
    const cpu = smp.current();
    cpu.current_idx = null;
    cpu.current_process = null;

    // Release dedicated core if held
    scheduler.clearDedicatedIfOwner(current.pid);

    // Wake parent (group leaders only)
    if (current.parent_pid != 0 and current.tgid == current.pid) {
        for (0..process_mod.MAX_PROCESSES) |i| {
            if (process_mod.getProcess(i)) |p| {
                if (p.pid == current.parent_pid) {
                    postSignal(p, SIGCHLD);
                    if (p.state == .blocked_on_wait) {
                        scheduler.wakeProcess(current.parent_pid);
                    }
                    break;
                }
            }
        }
    }

    scheduler.schedule(frame);
}

/// Stop the current process (SIGSTOP/SIGTSTP).
/// Sets state to .stopped, encodes stopped status, notifies parent, then deschedules.
fn stopProcess(frame: *InterruptFrame, sig: u6) void {
    const current = scheduler.currentProcess() orelse return;

    current.state = .stopped;
    // Encode stopped status: (sig << 8) | 0x7F — matches Linux WIFSTOPPED
    current.exit_status = (@as(u64, sig) << 8) | 0x7F;

    // Notify parent: post SIGCHLD and wake if blocked on wait
    if (current.parent_pid != 0) {
        for (0..process_mod.MAX_PROCESSES) |i| {
            if (process_mod.getProcess(i)) |p| {
                if (p.pid == current.parent_pid) {
                    postSignal(p, SIGCHLD);
                    if (p.state == .blocked_on_wait) {
                        scheduler.wakeProcess(current.parent_pid);
                    }
                    break;
                }
            }
        }
    }

    // Deschedule — frame is pre-iret state, no rip rewind needed
    scheduler.blockAndSchedule(frame);
}

/// Push signal frame on user stack, redirect to handler.
fn deliverToHandler(frame: *InterruptFrame, proc: *Process, sig: u6, action: *const process_mod.SignalAction) void {
    const SA_RESTORER: u64 = 0x04000000;

    var new_rsp = frame.rsp & ~@as(u64, 0xF); // 16-byte align
    new_rsp -= SIGNAL_FRAME_SIZE;

    // Determine return address: prefer SA_RESTORER (musl provides its own
    // signal return trampoline in executable .text — no NX stack issues).
    // Fall back to stack trampoline only if SA_RESTORER is not set.
    const return_addr = if (action.flags & SA_RESTORER != 0 and action.restorer != 0)
        action.restorer
    else
        new_rsp + 0x98; // Legacy: trampoline on stack (requires executable stack)

    // Build signal frame in kernel buffer
    var sig_frame: [0xA8]u8 = [_]u8{0} ** 0xA8;
    writeU64LE(sig_frame[0x00..0x08], return_addr);
    writeU64LE(sig_frame[0x08..0x10], frame.rax);
    writeU64LE(sig_frame[0x10..0x18], frame.rbx);
    writeU64LE(sig_frame[0x18..0x20], frame.rcx);
    writeU64LE(sig_frame[0x20..0x28], frame.rdx);
    writeU64LE(sig_frame[0x28..0x30], frame.rsi);
    writeU64LE(sig_frame[0x30..0x38], frame.rdi);
    writeU64LE(sig_frame[0x38..0x40], frame.rbp);
    writeU64LE(sig_frame[0x40..0x48], frame.r8);
    writeU64LE(sig_frame[0x48..0x50], frame.r9);
    writeU64LE(sig_frame[0x50..0x58], frame.r10);
    writeU64LE(sig_frame[0x58..0x60], frame.r11);
    writeU64LE(sig_frame[0x60..0x68], frame.r12);
    writeU64LE(sig_frame[0x68..0x70], frame.r13);
    writeU64LE(sig_frame[0x70..0x78], frame.r14);
    writeU64LE(sig_frame[0x78..0x80], frame.r15);
    writeU64LE(sig_frame[0x80..0x88], frame.rip);
    writeU64LE(sig_frame[0x88..0x90], frame.rflags);
    writeU64LE(sig_frame[0x90..0x98], frame.rsp);

    // Trampoline: mov rax, 15; int 0x80 (rt_sigreturn)
    sig_frame[0x98] = 0x48;
    sig_frame[0x99] = 0xc7;
    sig_frame[0x9A] = 0xc0;
    sig_frame[0x9B] = 0x0f;
    sig_frame[0x9C] = 0x00;
    sig_frame[0x9D] = 0x00;
    sig_frame[0x9E] = 0x00;
    sig_frame[0x9F] = 0xcd;
    sig_frame[0xA0] = 0x80;

    if (!writeToUserStack(proc.page_table, new_rsp, &sig_frame)) {
        terminateBySignal(frame, sig);
        return;
    }

    // Block handled signal during handler
    proc.sig_mask |= @as(u64, 1) << sig;
    proc.sig_mask |= action.mask;

    // Redirect to handler
    frame.rsp = new_rsp;
    frame.rip = action.handler;
    frame.rdi = @as(u64, sig);
}

// --- Syscall handlers ---

/// kill(pid, sig) — nr 62
/// Positive pid: send to specific process.
/// Negative pid: send to all processes in process group |pid|.
pub fn sysKill(frame: *InterruptFrame) void {
    const target_pid = frame.rdi;
    const sig_num = frame.rsi;

    if (sig_num >= process_mod.MAX_SIGNALS) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const target_signed: i64 = @bitCast(target_pid);

    if (sig_num == 0) {
        // Signal 0: check if process exists
        if (target_signed >= 0) {
            for (0..process_mod.MAX_PROCESSES) |i| {
                if (process_mod.getProcess(i)) |p| {
                    if (p.pid == target_pid) {
                        frame.rax = 0;
                        return;
                    }
                }
            }
        }
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    }

    if (target_signed < 0) {
        // Negative pid: send to process group
        const pgid: u64 = @bitCast(-target_signed);
        var found = false;
        for (0..process_mod.MAX_PROCESSES) |i| {
            if (process_mod.getProcess(i)) |p| {
                if (p.pgid == pgid and p.state != .zombie) {
                    postSignal(p, @truncate(sig_num));
                    found = true;
                }
            }
        }
        frame.rax = if (found) 0 else @as(u64, @bitCast(@as(i64, -errno.ESRCH)));
        return;
    }

    // Positive pid: send to specific process
    for (0..process_mod.MAX_PROCESSES) |i| {
        if (process_mod.getProcess(i)) |p| {
            if (p.pid == target_pid) {
                postSignal(p, @truncate(sig_num));
                frame.rax = 0;
                return;
            }
        }
    }

    frame.rax = @bitCast(@as(i64, -errno.ESRCH));
}

/// rt_sigaction(signum, act, oldact, sigsetsize) — nr 13
pub fn sysRtSigaction(frame: *InterruptFrame) void {
    const sig_num = frame.rdi;
    const act_addr = frame.rsi;
    const oldact_addr = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (sig_num == 0 or sig_num >= process_mod.MAX_SIGNALS) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    if (sig_num == SIGKILL or sig_num == SIGSTOP) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const idx: usize = @truncate(sig_num);

    // Linux x86_64 struct sigaction: handler(8) + flags(8) + restorer(8) + mask(8) = 32 bytes
    if (oldact_addr != 0) {
        var buf: [32]u8 = [_]u8{0} ** 32;
        writeU64LE(buf[0..8], current.sig_actions[idx].handler);
        writeU64LE(buf[8..16], current.sig_actions[idx].flags);
        writeU64LE(buf[16..24], current.sig_actions[idx].restorer);
        writeU64LE(buf[24..32], current.sig_actions[idx].mask);
        if (!writeToUserStack(current.page_table, oldact_addr, &buf)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
    }

    if (act_addr != 0) {
        var buf: [32]u8 = undefined;
        if (!readFromUserStack(current.page_table, act_addr, &buf)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
        current.sig_actions[idx].handler = readU64LE(buf[0..8]);
        current.sig_actions[idx].flags = readU64LE(buf[8..16]);
        current.sig_actions[idx].restorer = readU64LE(buf[16..24]);
        current.sig_actions[idx].mask = readU64LE(buf[24..32]);
    }

    frame.rax = 0;
}

/// rt_sigprocmask(how, set, oldset, sigsetsize) — nr 14
pub fn sysRtSigprocmask(frame: *InterruptFrame) void {
    const how = frame.rdi;
    const set_addr = frame.rsi;
    const oldset_addr = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (oldset_addr != 0) {
        var buf: [8]u8 = undefined;
        writeU64LE(&buf, current.sig_mask);
        if (!writeToUserStack(current.page_table, oldset_addr, &buf)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
    }

    if (set_addr != 0) {
        var buf: [8]u8 = undefined;
        if (!readFromUserStack(current.page_table, set_addr, &buf)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
        const new_set = readU64LE(&buf);

        switch (how) {
            0 => current.sig_mask |= new_set, // SIG_BLOCK
            1 => current.sig_mask &= ~new_set, // SIG_UNBLOCK
            2 => current.sig_mask = new_set, // SIG_SETMASK
            else => {
                frame.rax = @bitCast(@as(i64, -errno.EINVAL));
                return;
            },
        }

        // Cannot block SIGKILL or SIGSTOP
        current.sig_mask &= ~(@as(u64, 1) << SIGKILL);
        current.sig_mask &= ~(@as(u64, 1) << SIGSTOP);
    }

    frame.rax = 0;
}

/// rt_sigreturn() — nr 15
/// Restores context from signal frame on user stack.
pub fn sysRtSigreturn(frame: *InterruptFrame) void {
    const current = scheduler.currentProcess() orelse return;

    // After handler's `ret` popped trampoline addr, RSP = frame_start + 8
    const sig_frame_addr = frame.rsp - 8;

    if (sig_frame_addr >= USER_SPACE_END) return;

    var sig_frame: [0xA8]u8 = undefined;
    if (!readFromUserStack(current.page_table, sig_frame_addr, &sig_frame)) return;

    frame.rax = readU64LE(sig_frame[0x08..0x10]);
    frame.rbx = readU64LE(sig_frame[0x10..0x18]);
    frame.rcx = readU64LE(sig_frame[0x18..0x20]);
    frame.rdx = readU64LE(sig_frame[0x20..0x28]);
    frame.rsi = readU64LE(sig_frame[0x28..0x30]);
    frame.rdi = readU64LE(sig_frame[0x30..0x38]);
    frame.rbp = readU64LE(sig_frame[0x38..0x40]);
    frame.r8 = readU64LE(sig_frame[0x40..0x48]);
    frame.r9 = readU64LE(sig_frame[0x48..0x50]);
    frame.r10 = readU64LE(sig_frame[0x50..0x58]);
    frame.r11 = readU64LE(sig_frame[0x58..0x60]);
    frame.r12 = readU64LE(sig_frame[0x60..0x68]);
    frame.r13 = readU64LE(sig_frame[0x68..0x70]);
    frame.r14 = readU64LE(sig_frame[0x70..0x78]);
    frame.r15 = readU64LE(sig_frame[0x78..0x80]);
    frame.rip = readU64LE(sig_frame[0x80..0x88]);
    frame.rflags = readU64LE(sig_frame[0x88..0x90]);
    frame.rsp = readU64LE(sig_frame[0x90..0x98]);

    const gdt = @import("../arch/x86_64/gdt.zig");
    frame.cs = gdt.USER_CS;
    frame.ss = gdt.USER_DS;
}

// --- Default action table ---

fn isDefaultIgnore(sig: u6) bool {
    return sig == SIGCHLD or sig == SIGCONT;
}

fn isDefaultStop(sig: u6) bool {
    return sig == SIGTSTP;
}

// --- User memory helpers ---

fn writeToUserStack(page_table: u64, user_addr: u64, data: []const u8) bool {
    var remaining = data.len;
    var addr = user_addr;
    var offset: usize = 0;

    while (remaining > 0) {
        const page_off: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, types.PAGE_SIZE - page_off);

        if (vmm.translate(page_table, addr)) |phys| {
            const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
            for (0..chunk) |i| {
                ptr[i] = data[offset + i];
            }
        } else {
            return false;
        }

        addr += chunk;
        offset += chunk;
        remaining -= chunk;
    }
    return true;
}

fn readFromUserStack(page_table: u64, user_addr: u64, buf: []u8) bool {
    var remaining = buf.len;
    var addr = user_addr;
    var offset: usize = 0;

    while (remaining > 0) {
        const page_off: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, types.PAGE_SIZE - page_off);

        if (vmm.translate(page_table, addr)) |phys| {
            const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
            for (0..chunk) |i| {
                buf[offset + i] = ptr[i];
            }
        } else {
            return false;
        }

        addr += chunk;
        offset += chunk;
        remaining -= chunk;
    }
    return true;
}

// --- Byte helpers ---

fn writeU64LE(buf: *[8]u8, val: u64) void {
    var v = val;
    for (0..8) |i| {
        buf[i] = @truncate(v);
        v >>= 8;
    }
}

fn readU64LE(buf: *const [8]u8) u64 {
    var val: u64 = 0;
    for (0..8) |i| {
        val |= @as(u64, buf[i]) << @as(u6, @intCast(i * 8));
    }
    return val;
}

// --- Output helpers ---

pub fn writeSignalName(sig: u6) void {
    switch (sig) {
        1 => serial.writeString("SIGHUP"),
        2 => serial.writeString("SIGINT"),
        3 => serial.writeString("SIGQUIT"),
        4 => serial.writeString("SIGILL"),
        5 => serial.writeString("SIGTRAP"),
        6 => serial.writeString("SIGABRT"),
        7 => serial.writeString("SIGBUS"),
        8 => serial.writeString("SIGFPE"),
        9 => serial.writeString("SIGKILL"),
        10 => serial.writeString("SIGUSR1"),
        11 => serial.writeString("SIGSEGV"),
        12 => serial.writeString("SIGUSR2"),
        13 => serial.writeString("SIGPIPE"),
        14 => serial.writeString("SIGALRM"),
        15 => serial.writeString("SIGTERM"),
        17 => serial.writeString("SIGCHLD"),
        18 => serial.writeString("SIGCONT"),
        19 => serial.writeString("SIGSTOP"),
        20 => serial.writeString("SIGTSTP"),
        else => {
            serial.writeString("SIG");
            writeDecimal(@as(u64, sig));
        },
    }
}

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
