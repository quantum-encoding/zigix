/// Signal delivery — per-process pending bitmap, mask, action table.
/// ARM64 port: signal frame saves X0-X30 + SP + ELR + SPSR + v0-v31 + FPCR + FPSR,
/// trampoline uses SVC #0 with X8=139 (rt_sigreturn on AArch64).
///
/// Default action: terminate for most signals, ignore for SIGCHLD/SIGCONT.
/// SIGKILL/SIGSTOP cannot be caught, blocked, or ignored.

const uart = @import("uart.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const trap = @import("trap.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");

const TrapFrame = trap.TrapFrame;
const Process = process.Process;

// --- Signal numbers (same as Linux) ---

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

pub const MAX_SIGNALS: usize = 32;

/// Per-signal action configuration
pub const SignalAction = struct {
    handler: u64 = SIG_DFL,
    flags: u64 = 0,
    mask: u64 = 0,
};

/// ARM64 signal frame layout (832 bytes, 16-byte aligned):
///   [0x000] trampoline_addr (X30/LR for handler return)
///   [0x008] X0-X30 (31 * 8 = 248 bytes)
///   [0x100] SP_EL0
///   [0x108] ELR_EL1 (saved PC)
///   [0x110] SPSR_EL1
///   [0x118] v0-v31 SIMD/FP (32 * 16 = 512 bytes)
///   [0x318] FPCR
///   [0x320] FPSR
///   [0x328] sig_mask (saved signal mask for rt_sigreturn restore)
///   [0x330] trampoline code (8 bytes: MOV X8, #139; SVC #0)
///   [0x338] padding (8 bytes for 16-byte alignment)
const SIGNAL_FRAME_SIZE: u64 = 0x340; // 832 bytes (16-byte aligned)

// --- Core functions ---

/// Post a signal to a process (set pending bit). Does not deliver.
pub fn postSignal(proc: *Process, sig: u6) void {
    if (sig == 0) return;
    proc.sig_pending |= @as(u64, 1) << sig;

    if (sig == SIGCONT) {
        proc.sig_pending &= ~(@as(u64, 1) << SIGSTOP);
        proc.sig_pending &= ~(@as(u64, 1) << SIGTSTP);
        switch (proc.state) {
            .stopped, .blocked, .blocked_on_pipe, .blocked_on_wait, .blocked_on_futex, .blocked_on_net => {
                scheduler.wakeProcess(proc.pid);
            },
            else => {},
        }
    }
    if (sig == SIGKILL) {
        switch (proc.state) {
            .stopped, .blocked, .blocked_on_pipe, .blocked_on_wait, .blocked_on_futex, .blocked_on_net => {
                scheduler.wakeProcess(proc.pid);
            },
            else => {},
        }
    }
}

/// Check and deliver pending signals. Called before returning to userspace.
pub fn checkAndDeliver(frame: *TrapFrame) void {
    const proc = scheduler.currentProcess() orelse return;

    // Only deliver signals when returning to EL0 (user mode)
    // SPSR_EL1 bits [3:0] encode the exception level: 0b0000 = EL0
    if (frame.spsr & 0xF != 0) return;

    const deliverable = proc.sig_pending & ~proc.sig_mask;
    if (deliverable == 0) return;

    const sig: u6 = @truncate(@ctz(deliverable));
    proc.sig_pending &= ~(@as(u64, 1) << sig);

    // SIGKILL/SIGSTOP: always default action
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

    // User handler
    deliverToHandler(frame, proc, sig, &proc.sig_actions[@as(usize, sig)]);
}

/// Terminate the current process due to a signal.
pub fn terminateBySignal(frame: *TrapFrame, sig: u6) void {
    const current = scheduler.currentProcess() orelse return;

    uart.writeString("[signal] ");
    writeSignalName(sig);
    uart.writeString(" PID ");
    uart.writeDec(current.pid);
    uart.writeString(" (terminate)\n");

    current.state = .zombie;
    current.exit_status = 128 + @as(u64, sig);

    // Wake parent if blocked on wait
    if (current.parent_pid != 0) {
        if (process.findByPid(current.parent_pid)) |parent| {
            postSignal(parent, SIGCHLD);
            if (parent.state == .blocked_on_wait) {
                scheduler.wakeProcess(parent.pid);
            }
        }
    }

    scheduler.schedule(frame);
}

/// Stop the current process (SIGSTOP/SIGTSTP).
fn stopProcess(frame: *TrapFrame, sig: u6) void {
    const current = scheduler.currentProcess() orelse return;

    current.state = .stopped;
    current.exit_status = (@as(u64, sig) << 8) | 0x7F;

    if (current.parent_pid != 0) {
        if (process.findByPid(current.parent_pid)) |parent| {
            postSignal(parent, SIGCHLD);
            if (parent.state == .blocked_on_wait) {
                scheduler.wakeProcess(parent.pid);
            }
        }
    }

    scheduler.blockAndSchedule(frame);
}

/// Push signal frame on user stack, redirect to handler.
/// ARM64 signal frame layout:
///   SP -> [trampoline_addr]  (X30 will point here for ret)
///         [X0..X30]          (31 registers)
///         [SP_EL0]
///         [ELR_EL1]
///         [SPSR_EL1]
///         [v0..v31]          (32 SIMD/FP registers, 128-bit each)
///         [FPCR]
///         [FPSR]
///         [sig_mask]         (saved signal mask for restore)
///         [trampoline code]  (MOV X8, #139; SVC #0)
fn deliverToHandler(frame: *TrapFrame, proc: *Process, sig: u6, action: *const SignalAction) void {
    // 16-byte align the stack
    var new_sp = frame.sp & ~@as(u64, 0xF);
    new_sp -= SIGNAL_FRAME_SIZE;

    const trampoline_addr = new_sp + 0x330;

    // Build signal frame
    // We write directly to user memory (identity mapped after vmm.translate)
    const phys = vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(new_sp)) orelse {
        terminateBySignal(frame, sig);
        return;
    };
    _ = phys;

    // Write frame data to user stack (page by page for safety)
    // [0x000] trampoline addr (LR for handler return)
    if (!writeToUser(proc.page_table, new_sp + 0x000, trampoline_addr)) {
        terminateBySignal(frame, sig);
        return;
    }

    // [0x008..0x100] X0-X30
    for (0..31) |i| {
        if (!writeToUser(proc.page_table, new_sp + 0x008 + i * 8, frame.x[i])) {
            terminateBySignal(frame, sig);
            return;
        }
    }

    // [0x100] SP_EL0
    if (!writeToUser(proc.page_table, new_sp + 0x100, frame.sp)) {
        terminateBySignal(frame, sig);
        return;
    }
    // [0x108] ELR_EL1
    if (!writeToUser(proc.page_table, new_sp + 0x108, frame.elr)) {
        terminateBySignal(frame, sig);
        return;
    }
    // [0x110] SPSR_EL1
    if (!writeToUser(proc.page_table, new_sp + 0x110, frame.spsr)) {
        terminateBySignal(frame, sig);
        return;
    }

    // [0x118..0x318] v0-v31 SIMD/FP registers (32 * 16 = 512 bytes)
    for (0..32) |i| {
        if (!writeToUser(proc.page_table, new_sp + 0x118 + i * 16, frame.simd[i][0])) {
            terminateBySignal(frame, sig);
            return;
        }
        if (!writeToUser(proc.page_table, new_sp + 0x118 + i * 16 + 8, frame.simd[i][1])) {
            terminateBySignal(frame, sig);
            return;
        }
    }

    // [0x318] FPCR
    if (!writeToUser(proc.page_table, new_sp + 0x318, frame.fpcr)) {
        terminateBySignal(frame, sig);
        return;
    }
    // [0x320] FPSR
    if (!writeToUser(proc.page_table, new_sp + 0x320, frame.fpsr)) {
        terminateBySignal(frame, sig);
        return;
    }

    // [0x328] Save signal mask (restored by rt_sigreturn)
    if (!writeToUser(proc.page_table, new_sp + 0x328, proc.sig_mask)) {
        terminateBySignal(frame, sig);
        return;
    }

    // [0x330] Trampoline: MOV X8, #139; SVC #0
    // AArch64 instructions (little-endian):
    //   MOV X8, #139  = 0xD2801168 (MOVZ X8, #0x8B)
    //   SVC #0        = 0xD4000001
    if (!writeU32ToUser(proc.page_table, new_sp + 0x330, 0xD2801168)) {
        terminateBySignal(frame, sig);
        return;
    }
    if (!writeU32ToUser(proc.page_table, new_sp + 0x334, 0xD4000001)) {
        terminateBySignal(frame, sig);
        return;
    }

    // Block handled signal during handler execution
    proc.sig_mask |= @as(u64, 1) << sig;
    proc.sig_mask |= action.mask;

    // Redirect execution to handler
    frame.sp = new_sp;
    frame.elr = action.handler;
    frame.x[0] = @as(u64, sig); // First argument: signal number
    frame.x[30] = trampoline_addr; // LR: return to trampoline
}

/// rt_sigreturn — restore context from signal frame on user stack.
/// Called via SVC from trampoline: X8=139 (SYS_rt_sigreturn on AArch64).
pub fn sysRtSigreturn(frame: *TrapFrame) void {
    const proc = scheduler.currentProcess() orelse return;

    // After handler returned via LR to trampoline, SP is at signal frame start
    // The trampoline does SVC with SP pointing at the original frame
    const sig_frame_addr = frame.sp;

    // Restore X0-X30
    for (0..31) |i| {
        frame.x[i] = readFromUser(proc.page_table, sig_frame_addr + 0x008 + i * 8) orelse return;
    }

    // Restore SP, ELR, SPSR
    frame.sp = readFromUser(proc.page_table, sig_frame_addr + 0x100) orelse return;
    frame.elr = readFromUser(proc.page_table, sig_frame_addr + 0x108) orelse return;
    frame.spsr = readFromUser(proc.page_table, sig_frame_addr + 0x110) orelse return;

    // Restore v0-v31 SIMD/FP registers
    for (0..32) |i| {
        frame.simd[i][0] = readFromUser(proc.page_table, sig_frame_addr + 0x118 + i * 16) orelse return;
        frame.simd[i][1] = readFromUser(proc.page_table, sig_frame_addr + 0x118 + i * 16 + 8) orelse return;
    }

    // Restore FPCR, FPSR
    frame.fpcr = readFromUser(proc.page_table, sig_frame_addr + 0x318) orelse return;
    frame.fpsr = readFromUser(proc.page_table, sig_frame_addr + 0x320) orelse return;

    // Restore signal mask (saved at offset 0x328 by deliverToHandler)
    const saved_mask = readFromUser(proc.page_table, sig_frame_addr + 0x328) orelse return;
    proc.sig_mask = saved_mask;
    // Cannot block SIGKILL or SIGSTOP
    proc.sig_mask &= ~(@as(u64, 1) << SIGKILL);
    proc.sig_mask &= ~(@as(u64, 1) << SIGSTOP);
}

// --- Syscall handlers ---

/// kill(pid, sig) — AArch64 syscall 129
pub fn sysKill(target_pid_raw: u64, sig_num: u64) i64 {
    if (sig_num >= MAX_SIGNALS) return -22; // -EINVAL

    const target_signed: i64 = @bitCast(target_pid_raw);

    if (sig_num == 0) {
        // Signal 0: check if process exists
        if (target_signed >= 0) {
            if (process.findByPid(target_pid_raw) != null) return 0;
        }
        return -3; // -ESRCH
    }

    if (target_signed > 0) {
        const target = process.findByPid(target_pid_raw) orelse return -3;
        postSignal(target, @truncate(sig_num));
        return 0;
    }

    // Negative pid: process group (simplified — send to all matching)
    if (target_signed < 0) {
        var found = false;
        for (0..process.MAX_PROCESSES) |i| {
            if (process.getProcess(i)) |p| {
                if (p.state != .zombie) {
                    postSignal(p, @truncate(sig_num));
                    found = true;
                }
            }
        }
        return if (found) 0 else -3;
    }

    return -3; // -ESRCH
}

/// rt_sigaction(signum, act, oldact, sigsetsize) — AArch64 syscall 134
pub fn sysRtSigaction(sig_num: u64, act_addr: u64, oldact_addr: u64, proc: *Process) i64 {
    if (sig_num == 0 or sig_num >= MAX_SIGNALS) return -22;
    if (sig_num == SIGKILL or sig_num == SIGSTOP) return -22;

    const idx: usize = @truncate(sig_num);

    // Write old action if requested
    if (oldact_addr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(oldact_addr)) == null) return -14;
        const old = &proc.sig_actions[idx];
        if (!writeToUser(proc.page_table, oldact_addr + 0, old.handler)) return -14;
        if (!writeToUser(proc.page_table, oldact_addr + 8, old.flags)) return -14;
        if (!writeToUser(proc.page_table, oldact_addr + 16, 0)) return -14; // restorer (unused)
        if (!writeToUser(proc.page_table, oldact_addr + 24, old.mask)) return -14;
    }

    // Read new action if provided
    // Layout of kernel sigaction struct (from musl k_sigaction):
    //   offset 0:  handler  (8 bytes)
    //   offset 8:  flags    (8 bytes)
    //   offset 16: restorer (8 bytes) — unused on ARM64
    //   offset 24: mask     (8+ bytes)
    if (act_addr != 0) {
        proc.sig_actions[idx].handler = readFromUser(proc.page_table, act_addr + 0) orelse return -14;
        proc.sig_actions[idx].flags = readFromUser(proc.page_table, act_addr + 8) orelse return -14;
        proc.sig_actions[idx].mask = readFromUser(proc.page_table, act_addr + 24) orelse return -14;
    }

    return 0;
}

/// rt_sigprocmask(how, set, oldset, sigsetsize) — AArch64 syscall 135
pub fn sysRtSigprocmask(how: u64, set_addr: u64, oldset_addr: u64, proc: *Process) i64 {
    if (oldset_addr != 0) {
        if (!writeToUser(proc.page_table, oldset_addr, proc.sig_mask)) return -14;
    }

    if (set_addr != 0) {
        const new_set = readFromUser(proc.page_table, set_addr) orelse return -14;

        switch (how) {
            0 => proc.sig_mask |= new_set, // SIG_BLOCK
            1 => proc.sig_mask &= ~new_set, // SIG_UNBLOCK
            2 => proc.sig_mask = new_set, // SIG_SETMASK
            else => return -22,
        }

        // Cannot block SIGKILL or SIGSTOP
        proc.sig_mask &= ~(@as(u64, 1) << SIGKILL);
        proc.sig_mask &= ~(@as(u64, 1) << SIGSTOP);
    }

    return 0;
}

// --- Default action table ---

fn isDefaultIgnore(sig: u6) bool {
    return sig == SIGCHLD or sig == SIGCONT;
}

fn isDefaultStop(sig: u6) bool {
    return sig == SIGTSTP;
}

// --- User memory helpers (identity mapped) ---

fn writeToUser(page_table: u64, user_addr: u64, value: u64) bool {
    const phys = (vmm.translate(vmm.PhysAddr.from(page_table), vmm.VirtAddr.from(user_addr)) orelse return false).toInt();
    const ptr: *align(1) u64 = @ptrFromInt(phys);
    ptr.* = value;
    return true;
}

fn writeU32ToUser(page_table: u64, user_addr: u64, value: u32) bool {
    const phys = (vmm.translate(vmm.PhysAddr.from(page_table), vmm.VirtAddr.from(user_addr)) orelse return false).toInt();
    const ptr: *align(1) u32 = @ptrFromInt(phys);
    ptr.* = value;
    return true;
}

fn readFromUser(page_table: u64, user_addr: u64) ?u64 {
    const phys = (vmm.translate(vmm.PhysAddr.from(page_table), vmm.VirtAddr.from(user_addr)) orelse return null).toInt();
    const ptr: *align(1) const u64 = @ptrFromInt(phys);
    return ptr.*;
}

// --- Output helpers ---

fn writeSignalName(sig: u6) void {
    switch (sig) {
        1 => uart.writeString("SIGHUP"),
        2 => uart.writeString("SIGINT"),
        3 => uart.writeString("SIGQUIT"),
        4 => uart.writeString("SIGILL"),
        5 => uart.writeString("SIGTRAP"),
        6 => uart.writeString("SIGABRT"),
        7 => uart.writeString("SIGBUS"),
        8 => uart.writeString("SIGFPE"),
        9 => uart.writeString("SIGKILL"),
        10 => uart.writeString("SIGUSR1"),
        11 => uart.writeString("SIGSEGV"),
        12 => uart.writeString("SIGUSR2"),
        13 => uart.writeString("SIGPIPE"),
        14 => uart.writeString("SIGALRM"),
        15 => uart.writeString("SIGTERM"),
        17 => uart.writeString("SIGCHLD"),
        18 => uart.writeString("SIGCONT"),
        19 => uart.writeString("SIGSTOP"),
        20 => uart.writeString("SIGTSTP"),
        else => {
            uart.writeString("SIG");
            uart.writeDec(@as(u64, sig));
        },
    }
}
