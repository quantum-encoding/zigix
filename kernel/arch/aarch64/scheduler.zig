/// ARM64 Preemptive scheduler with per-CPU runqueues.
///
/// Each CPU has its own runqueue (singly-linked list of ready processes).
/// Local scheduling decisions only touch the local runqueue — no global
/// lock contention. Cross-CPU operations (wake, load balance) acquire
/// the target CPU's runqueue lock.
///
/// Context switch works by modifying the TrapFrame on the stack:
/// the exception return (eret) will restore the new process's state.

const process = @import("process.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const uart = @import("uart.zig");
const exception = @import("exception.zig");
const timer = @import("timer.zig");
const spinlock = @import("spinlock.zig");
const smp = @import("smp.zig");
const gic = @import("gic.zig");
const rq = @import("runqueue.zig");

pub const TIMESLICE_TICKS: u64 = 10; // 100ms at 100 Hz timer

// Deadlock detector
var all_idle_ticks: u32 = 0;
var deadlock_dumped: bool = false;

/// Global lock — only for diagnostics and cross-CPU process table scans.
/// NOT on the hot scheduling path (timerTick, blockAndSchedule use per-CPU rq locks).
pub var sched_lock: spinlock.IrqSpinlock = .{};

// --- SCHED_DEDICATED ---
pub fn isDedicated() bool {
    return smp.current().dedicated_pid != 0;
}
pub fn setDedicated(pid: u64) void {
    smp.current().dedicated_pid = pid;
}
pub fn clearDedicated() void {
    smp.current().dedicated_pid = 0;
}
pub fn clearDedicatedIfOwner(pid: u64) void {
    const cpu = smp.current();
    if (cpu.dedicated_pid == pid) cpu.dedicated_pid = 0;
}

pub fn currentProcess() ?*process.Process {
    return smp.current().current_process;
}
pub fn currentProcessIndex() ?usize {
    return smp.current().current_idx;
}

/// Start the first user process. Does not return.
pub fn startFirst(proc: *process.Process) noreturn {
    const cpu = smp.current();

    // Find this process in the table
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.pid == proc.pid) {
                cpu.current_idx = i;
                break;
            }
        }
    }

    proc.state = .running;
    proc.cpu_id = @intCast(cpu.cpu_id);
    proc.home_cpu = cpu.cpu_id;
    cpu.current_process = proc;
    cpu.kernel_stack_top = proc.kernel_stack_top;
    cpu.slice_remaining = TIMESLICE_TICKS;
    cpu.idle = false;

    restoreTlsBase(proc);
    vmm.switchAddressSpace(vmm.PhysAddr.from(proc.page_table));

    uart.print("[sched] CPU {} starting PID {} at {x}\n", .{ cpu.cpu_id, proc.pid, proc.context.elr });
    jumpToUserMode(&proc.context);
}

fn jumpToUserMode(ctx: *const process.Context) noreturn {
    asm volatile ("msr SP_EL0, %[sp]" :: [sp] "r" (ctx.sp));
    asm volatile ("msr ELR_EL1, %[elr]" :: [elr] "r" (ctx.elr));
    asm volatile ("msr SPSR_EL1, %[spsr]" :: [spsr] "r" (ctx.spsr));
    asm volatile (
        \\ldp x0, x1, [%[ctx], #0]
        \\ldp x2, x3, [%[ctx], #16]
        \\ldp x4, x5, [%[ctx], #32]
        \\ldp x6, x7, [%[ctx], #48]
        \\ldp x8, x9, [%[ctx], #64]
        \\ldp x10, x11, [%[ctx], #80]
        \\ldp x12, x13, [%[ctx], #96]
        \\ldp x14, x15, [%[ctx], #112]
        \\ldp x16, x17, [%[ctx], #128]
        \\ldp x18, x19, [%[ctx], #144]
        \\ldp x20, x21, [%[ctx], #160]
        \\ldp x22, x23, [%[ctx], #176]
        \\ldp x24, x25, [%[ctx], #192]
        \\ldp x26, x27, [%[ctx], #208]
        \\ldp x28, x29, [%[ctx], #224]
        \\ldr x30, [%[ctx], #240]
        \\eret
        :
        : [ctx] "r" (&ctx.x),
    );
    unreachable;
}

// ============================================================================
// Timer tick — per-CPU, no global lock on hot path
// ============================================================================

pub fn timerTick(frame: *exception.TrapFrame) void {
    const cpu = smp.current();
    cpu.slice_remaining -|= 1;
    if (cpu.slice_remaining > 0) return;

    cpu.slice_remaining = TIMESLICE_TICKS;

    const in_kernel = (frame.spsr & 0xF) != 0;

    // Check wake ticks for processes assigned to this CPU
    rq.checkWakeTicks(cpu.cpu_id);

    // Fix orphaned processes (running state but no CPU)
    for (0..process.MAX_PROCESSES) |fix_i| {
        if (process.getProcess(fix_i)) |fix_p| {
            if (fix_p.state == .running and fix_p.cpu_id < 0) {
                fix_p.state = .ready;
                rq.enqueue(fix_p.home_cpu, fix_p);
            }
        }
    }

    // Idle CPU in EL1: try local runqueue, then steal from others
    if (in_kernel and cpu.idle) {
        deadlockCheck();

        if (rq.dequeueLocal()) |new_proc| {
            switchTo(frame, cpu, new_proc);
        } else if (rq.trySteal(cpu.cpu_id)) |stolen| {
            switchTo(frame, cpu, stolen);
        }
        return;
    }

    // Non-idle CPU in EL1: cannot preempt kernel code
    if (in_kernel) {
        stuckKernelCheck(cpu, frame);
        return;
    }

    // SCHED_DEDICATED: never preempt the dedicated process
    if (cpu.dedicated_pid != 0) {
        if (cpu.current_process) |proc| {
            if (proc.pid == cpu.dedicated_pid) return;
        }
    }

    // CPU has no process — try to pick one up
    if (cpu.current_idx == smp.PerCpu.NO_PROCESS) {
        if (rq.dequeueLocal()) |new_proc| {
            switchTo(frame, cpu, new_proc);
        } else if (rq.trySteal(cpu.cpu_id)) |stolen| {
            switchTo(frame, cpu, stolen);
        }
        return;
    }

    // Normal preemption: current process's timeslice expired
    const cur_idx = cpu.current_idx;
    const old_proc = process.getProcess(cur_idx) orelse return;

    // Try to get next process from local runqueue
    const new_proc = rq.dequeueLocal() orelse {
        // No other ready process on this CPU
        if (old_proc.state == .zombie) {
            old_proc.cpu_id = -1;
            cpu.current_process = null;
            cpu.current_idx = smp.PerCpu.NO_PROCESS;
            cpu.idle = true;
            halt();
        }
        return; // Keep running current process
    };

    checkStackCanary(old_proc);

    // Save old context
    old_proc.tls_base = asm volatile ("mrs %[tls], TPIDR_EL0"
        : [tls] "=r" (-> u64),
    );
    saveContext(frame, &old_proc.context);
    if (old_proc.state == .running) {
        old_proc.state = .ready;
        // Re-enqueue the preempted process on this CPU's runqueue
        rq.enqueueLocal(old_proc);
    }
    old_proc.cpu_id = -1;

    // Switch to new process
    const new_idx = findIdx(new_proc);
    restoreContext(frame, &new_proc.context);
    new_proc.state = .running;
    new_proc.cpu_id = @intCast(cpu.cpu_id);
    cpu.current_idx = new_idx;
    cpu.current_process = new_proc;
    cpu.kernel_stack_top = new_proc.kernel_stack_top;

    restoreTlsBase(new_proc);
    vmm.switchAddressSpace(vmm.PhysAddr.from(new_proc.page_table));
}

// ============================================================================
// Schedule — called from sysExit (process is done)
// ============================================================================

pub fn schedule(frame: *exception.TrapFrame) void {
    const cpu = smp.current();

    if (cpu.current_process) |old_proc| {
        old_proc.cpu_id = -1;
    }
    cpu.current_process = null;
    cpu.current_idx = smp.PerCpu.NO_PROCESS;

    if (rq.dequeueLocal()) |new_proc| {
        switchTo(frame, cpu, new_proc);
        return;
    }

    if (rq.trySteal(cpu.cpu_id)) |stolen| {
        switchTo(frame, cpu, stolen);
        return;
    }

    cpu.idle = true;
    halt();
}

// ============================================================================
// Block and schedule — process is blocking (pipe, futex, wait, etc.)
// ============================================================================

pub fn blockAndSchedule(frame: *exception.TrapFrame) void {
    const cpu = smp.current();
    if (cpu.current_idx == smp.PerCpu.NO_PROCESS) return;
    const cur_idx = cpu.current_idx;
    const old_proc = process.getProcess(cur_idx) orelse return;

    old_proc.tls_base = asm volatile ("mrs %[tls], TPIDR_EL0"
        : [tls] "=r" (-> u64),
    );
    saveContext(frame, &old_proc.context);
    old_proc.cpu_id = -1;

    if (old_proc.killed and old_proc.state != .zombie) {
        old_proc.state = .zombie;
    }

    // Try local runqueue
    if (rq.dequeueLocal()) |new_proc| {
        const new_idx = findIdx(new_proc);
        restoreContext(frame, &new_proc.context);
        new_proc.state = .running;
        new_proc.cpu_id = @intCast(cpu.cpu_id);
        cpu.current_idx = new_idx;
        cpu.current_process = new_proc;
        cpu.slice_remaining = TIMESLICE_TICKS;
        cpu.kernel_stack_top = new_proc.kernel_stack_top;

        restoreTlsBase(new_proc);
        vmm.switchAddressSpace(vmm.PhysAddr.from(new_proc.page_table));
        return;
    }

    // Try stealing
    if (rq.trySteal(cpu.cpu_id)) |stolen| {
        const new_idx = findIdx(stolen);
        restoreContext(frame, &stolen.context);
        stolen.state = .running;
        stolen.cpu_id = @intCast(cpu.cpu_id);
        cpu.current_idx = new_idx;
        cpu.current_process = stolen;
        cpu.slice_remaining = TIMESLICE_TICKS;
        cpu.kernel_stack_top = stolen.kernel_stack_top;

        restoreTlsBase(stolen);
        vmm.switchAddressSpace(vmm.PhysAddr.from(stolen.page_table));
        return;
    }

    // Nothing to run — idle and wait
    cpu.current_idx = smp.PerCpu.NO_PROCESS;
    cpu.current_process = null;
    cpu.idle = true;

    while (true) {
        asm volatile ("msr DAIFClr, #2");
        asm volatile ("wfi");
        asm volatile ("msr DAIFSet, #2");

        // Check if our process was woken
        if (old_proc.state == .ready and old_proc.cpu_id < 0) {
            rq.removeFromQueue(old_proc.home_cpu, old_proc);

            restoreContext(frame, &old_proc.context);
            old_proc.state = .running;
            old_proc.cpu_id = @intCast(cpu.cpu_id);
            cpu.current_idx = cur_idx;
            cpu.current_process = old_proc;
            cpu.kernel_stack_top = old_proc.kernel_stack_top;
            cpu.slice_remaining = TIMESLICE_TICKS;
            cpu.idle = false;

            restoreTlsBase(old_proc);
            return;
        }

        if (rq.dequeueLocal()) |new_proc| {
            const new_idx = findIdx(new_proc);
            restoreContext(frame, &new_proc.context);
            new_proc.state = .running;
            new_proc.cpu_id = @intCast(cpu.cpu_id);
            cpu.current_idx = new_idx;
            cpu.current_process = new_proc;
            cpu.slice_remaining = TIMESLICE_TICKS;
            cpu.idle = false;
            cpu.kernel_stack_top = new_proc.kernel_stack_top;

            restoreTlsBase(new_proc);
            vmm.switchAddressSpace(vmm.PhysAddr.from(new_proc.page_table));
            return;
        }

        if (rq.trySteal(cpu.cpu_id)) |stolen| {
            const new_idx = findIdx(stolen);
            restoreContext(frame, &stolen.context);
            stolen.state = .running;
            stolen.cpu_id = @intCast(cpu.cpu_id);
            cpu.current_idx = new_idx;
            cpu.current_process = stolen;
            cpu.slice_remaining = TIMESLICE_TICKS;
            cpu.idle = false;
            cpu.kernel_stack_top = stolen.kernel_stack_top;

            restoreTlsBase(stolen);
            vmm.switchAddressSpace(vmm.PhysAddr.from(stolen.page_table));
            return;
        }
    }
}

// ============================================================================
// Wake a blocked process — enqueue on its home CPU's runqueue
// ============================================================================

pub fn wakeProcess(pid: u64) void {
    if (process.findByPid(pid)) |p| {
        switch (p.state) {
            .blocked, .blocked_on_pipe, .blocked_on_wait, .blocked_on_futex, .blocked_on_net => {
                p.state = .ready;
                rq.enqueue(p.home_cpu, p);

                // IPI to wake idle CPU
                const my_cpu = smp.current().cpu_id;
                const target = p.home_cpu;
                if (target < smp.online_cpus and target != my_cpu) {
                    if (smp.per_cpu_data[target].idle) {
                        gic.sendSGI(target, gic.SGI_RESCHEDULE);
                    }
                }
            },
            else => {},
        }
    }
}

/// Enqueue a newly created/forked process on the least-loaded CPU.
pub fn makeRunnable(proc: *process.Process) void {
    const target = rq.leastLoadedCpu();
    proc.home_cpu = target;
    proc.state = .ready;
    rq.enqueue(target, proc);

    const my_cpu = smp.current().cpu_id;
    if (target != my_cpu and target < smp.online_cpus) {
        if (smp.per_cpu_data[target].idle) {
            gic.sendSGI(target, gic.SGI_RESCHEDULE);
        }
    }
}

// ============================================================================
// Internal helpers
// ============================================================================

fn switchTo(frame: *exception.TrapFrame, cpu: *smp.PerCpu, new_proc: *process.Process) void {
    const idx = findIdx(new_proc);
    restoreContext(frame, &new_proc.context);
    new_proc.state = .running;
    new_proc.cpu_id = @intCast(cpu.cpu_id);
    cpu.current_idx = idx;
    cpu.current_process = new_proc;
    cpu.kernel_stack_top = new_proc.kernel_stack_top;
    cpu.slice_remaining = TIMESLICE_TICKS;
    cpu.idle = false;

    restoreTlsBase(new_proc);
    vmm.switchAddressSpace(vmm.PhysAddr.from(new_proc.page_table));
}

fn findIdx(proc: *process.Process) usize {
    return process.findIndexByPid(proc.pid) orelse smp.PerCpu.NO_PROCESS;
}

fn restoreTlsBase(proc: *process.Process) void {
    if (proc.tls_base != 0) {
        asm volatile ("msr TPIDR_EL0, %[tls]" :: [tls] "r" (proc.tls_base));
    }
}

fn saveContext(frame: *const exception.TrapFrame, ctx: *process.Context) void {
    for (0..31) |i| ctx.x[i] = frame.x[i];
    ctx.sp = frame.sp;
    ctx.elr = frame.elr;
    ctx.spsr = frame.spsr & ~@as(u64, 0xF | (1 << 20));
    for (0..32) |i| ctx.simd[i] = frame.simd[i];
    ctx.fpcr = frame.fpcr;
    ctx.fpsr = frame.fpsr;
}

fn restoreContext(frame: *exception.TrapFrame, ctx: *const process.Context) void {
    for (0..31) |i| frame.x[i] = ctx.x[i];
    frame.sp = ctx.sp;
    frame.elr = ctx.elr;
    frame.spsr = ctx.spsr & ~@as(u64, 0xF | (1 << 20));
    for (0..32) |i| frame.simd[i] = ctx.simd[i];
    frame.fpcr = ctx.fpcr;
    frame.fpsr = ctx.fpsr;
}

fn halt() noreturn {
    asm volatile ("msr DAIFClr, #2");
    while (true) {
        asm volatile ("wfi");
    }
}

fn checkStackCanary(proc: *process.Process) void {
    if (proc.kernel_stack_phys == 0) return;
    const canary_ptr: *const u64 = @ptrFromInt(proc.kernel_stack_phys);
    if (canary_ptr.* != pmm.STACK_CANARY) {
        uart.writeString("\n!!! KERNEL STACK OVERFLOW DETECTED !!!\n");
        uart.print("[canary] PID={} kstack_phys=0x{x}\n", .{ proc.pid, proc.kernel_stack_phys });
        uart.print("[canary] Expected 0x{x} found 0x{x}\n", .{ pmm.STACK_CANARY, canary_ptr.* });
        @panic("kernel stack overflow");
    }
}

fn stuckKernelCheck(cpu: *smp.PerCpu, frame: *exception.TrapFrame) void {
    const stuck_detect = struct {
        var kernel_ticks: [smp.MAX_CPUS]u32 = .{ 0, 0, 0, 0 };
    };
    const ci = cpu.cpu_id;
    if (ci < smp.MAX_CPUS) {
        stuck_detect.kernel_ticks[ci] += 1;
        if (stuck_detect.kernel_ticks[ci] == 30) {
            if (cpu.current_process) |proc| {
                uart.print("[sched] CPU {} stuck in kernel for P{} ELR={x} LR={x} X8={} SP={x}\n", .{
                    ci, proc.pid, frame.elr, frame.x[30], frame.x[8], frame.sp,
                });
            }
        }
    }
}

fn deadlockCheck() void {
    var any_running = false;
    for (0..smp.MAX_CPUS) |ci| {
        if (ci < smp.online_cpus and !smp.per_cpu_data[ci].idle) {
            any_running = true;
            break;
        }
    }
    if (!any_running) {
        all_idle_ticks += 1;
        if (all_idle_ticks >= 100 and !deadlock_dumped) {
            deadlock_dumped = true;
            uart.writeString("[sched] DEADLOCK? All CPUs idle. Process states:\n");
            dumpProcessStates();
            rq.printStats();
        }
    } else {
        all_idle_ticks = 0;
        deadlock_dumped = false;
    }
}

fn dumpProcessStates() void {
    for (0..process.MAX_PROCESSES) |pi| {
        if (process.getProcess(pi)) |p| {
            if (p.pid != 0) {
                const state_str: []const u8 = switch (p.state) {
                    .ready => "ready",
                    .running => "running",
                    .zombie => "zombie",
                    .blocked => "blocked",
                    .blocked_on_wait => "wait4",
                    .blocked_on_pipe => "pipe",
                    .blocked_on_futex => "futex",
                    .blocked_on_net => "net",
                    .stopped => "stopped",
                };
                uart.print("  P{} tgid={} state=", .{ p.pid, p.tgid });
                uart.writeString(state_str);
                uart.print(" parent={} cpu={} home={} killed={}\n", .{
                    p.parent_pid, p.cpu_id, p.home_cpu, @intFromBool(p.killed),
                });
            }
        }
    }
}
