/// RISC-V Preemptive scheduler with per-CPU runqueues.
///
/// Each CPU/hart has its own runqueue (singly-linked list of ready processes).
/// Local scheduling decisions only touch the local runqueue -- no global
/// lock contention. Cross-CPU operations (wake, load balance) acquire
/// the target CPU's runqueue lock.
///
/// Context switch works by modifying the TrapFrame on the kernel stack:
/// the trap return (sret) will restore the new process's state.

const process = @import("process.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const uart = @import("uart.zig");
const trap = @import("trap.zig");
const timer = @import("timer.zig");
const spinlock = @import("spinlock.zig");
const smp = @import("smp.zig");
const rq = @import("runqueue.zig");

pub const TIMESLICE_TICKS: u64 = 10; // 100ms at 100 Hz timer

// Deadlock detector
var all_idle_ticks: u32 = 0;
var deadlock_dumped: bool = false;

/// Global lock -- only for diagnostics and cross-CPU process table scans.
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
    const idx = smp.current().current_idx;
    if (idx == smp.PerCpu.NO_PROCESS) return null;
    return idx;
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

    uart.print("[sched] Hart {} starting PID {} at {x}\n", .{ cpu.cpu_id, proc.pid, proc.context.sepc });

    // Disable interrupts before address space switch + sret.
    // Interrupts are re-enabled by SPIE on sret.
    asm volatile ("csrc sstatus, %[sie]" :: [sie] "r" (@as(u64, 1 << 1)));

    vmm.switchAddressSpace(proc.page_table);
    jumpToUserMode(&proc.context, proc.kernel_stack_top);
}

/// Jump to user mode via sret.
fn jumpToUserMode(ctx: *const process.Context, kernel_stack_top: u64) noreturn {
    // Use explicit register constraints to ensure a0/a1 are set correctly
    asm volatile (
        // sscratch = kernel stack (for trap entry from U-mode)
        \\csrw sscratch, a1

        // Load sepc from ctx (offset 256 = 32*8)
        \\ld t0, 256(a0)
        \\csrw sepc, t0

        // Load sstatus from ctx (offset 264 = 33*8)
        \\ld t0, 264(a0)
        \\csrw sstatus, t0

        // Now restore GP regs from ctx.x[] (a0 = base of x[0])
        // Use a0 as base pointer, load it last
        \\ld x1, 8(a0)
        \\ld x3, 24(a0)
        \\ld x4, 32(a0)
        \\ld x5, 40(a0)
        \\ld x6, 48(a0)
        \\ld x7, 56(a0)
        \\ld x8, 64(a0)
        \\ld x9, 72(a0)
        // skip x10 (a0) — it's our base pointer
        \\ld x11, 88(a0)
        \\ld x12, 96(a0)
        \\ld x13, 104(a0)
        \\ld x14, 112(a0)
        \\ld x15, 120(a0)
        \\ld x16, 128(a0)
        \\ld x17, 136(a0)
        \\ld x18, 144(a0)
        \\ld x19, 152(a0)
        \\ld x20, 160(a0)
        \\ld x21, 168(a0)
        \\ld x22, 176(a0)
        \\ld x23, 184(a0)
        \\ld x24, 192(a0)
        \\ld x25, 200(a0)
        \\ld x26, 208(a0)
        \\ld x27, 216(a0)
        \\ld x28, 224(a0)
        \\ld x29, 232(a0)
        \\ld x30, 240(a0)
        \\ld x31, 248(a0)
        // Load sp (x2)
        \\ld x2, 16(a0)
        // Load a0 (x10) last — clobbers base pointer
        \\ld x10, 80(a0)
        \\sret
        :
        : [_ctx] "{a0}" (@intFromPtr(ctx)),
          [_ksp] "{a1}" (kernel_stack_top),
    );
    unreachable;
}

// ============================================================================
// Timer tick -- per-CPU, no global lock on hot path
// ============================================================================

pub fn timerTick(frame: *trap.TrapFrame) void {
    const cpu = smp.current();
    cpu.slice_remaining -|= 1;
    if (cpu.slice_remaining > 0) return;

    cpu.slice_remaining = TIMESLICE_TICKS;

    // Check if we're in S-mode (sstatus.SPP = bit 8)
    const in_kernel = (frame.sstatus & (1 << 8)) != 0;

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

    // Idle CPU in S-mode: try local runqueue, then steal from others
    if (in_kernel and cpu.idle) {
        deadlockCheck();

        if (rq.dequeueLocal()) |new_proc| {
            switchTo(frame, cpu, new_proc);
        } else if (rq.trySteal(cpu.cpu_id)) |stolen| {
            switchTo(frame, cpu, stolen);
        }
        return;
    }

    // Non-idle CPU in S-mode: cannot preempt kernel code
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

    // CPU has no process -- try to pick one up
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
    saveContext(frame, &old_proc.context);
    if (old_proc.state == .running) {
        old_proc.state = .ready;
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
    vmm.switchAddressSpace(new_proc.page_table);
}

// ============================================================================
// Schedule -- called from sysExit (process is done)
// ============================================================================

pub fn schedule(frame: *trap.TrapFrame) void {
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
// Block and schedule -- process is blocking (pipe, futex, wait, etc.)
// ============================================================================

pub fn blockAndSchedule(frame: *trap.TrapFrame) void {
    const cpu = smp.current();
    if (cpu.current_idx == smp.PerCpu.NO_PROCESS) return;
    const cur_idx = cpu.current_idx;
    const old_proc = process.getProcess(cur_idx) orelse return;

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
        vmm.switchAddressSpace(new_proc.page_table);
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
        vmm.switchAddressSpace(stolen.page_table);
        return;
    }

    // Nothing to run -- idle and wait
    cpu.current_idx = smp.PerCpu.NO_PROCESS;
    cpu.current_process = null;
    cpu.idle = true;

    while (true) {
        // Enable interrupts, wait for interrupt, disable interrupts
        asm volatile ("csrs sstatus, %[sie]" :: [sie] "r" (@as(u64, 1 << 1)));
        asm volatile ("wfi");
        asm volatile ("csrc sstatus, %[sie]" :: [sie] "r" (@as(u64, 1 << 1)));

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
            vmm.switchAddressSpace(new_proc.page_table);
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
            vmm.switchAddressSpace(stolen.page_table);
            return;
        }
    }
}

// ============================================================================
// Wake a blocked process -- enqueue on its home CPU's runqueue
// ============================================================================

pub fn wakeProcess(pid: u64) void {
    if (process.findByPid(pid)) |p| {
        switch (p.state) {
            .blocked, .blocked_on_pipe, .blocked_on_wait, .blocked_on_futex, .blocked_on_net => {
                p.state = .ready;
                rq.enqueue(p.home_cpu, p);
                // No IPI for single-hart yet
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
    // No IPI for single-hart yet
}

// ============================================================================
// Internal helpers
// ============================================================================

fn switchTo(frame: *trap.TrapFrame, cpu: *smp.PerCpu, new_proc: *process.Process) void {
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
    vmm.switchAddressSpace(new_proc.page_table);
}

fn findIdx(proc: *process.Process) usize {
    return process.findIndexByPid(proc.pid) orelse smp.PerCpu.NO_PROCESS;
}

/// Restore TLS base -- RISC-V uses the tp (x4) register for TLS.
/// For now this is a no-op; the tp register is saved/restored as part of
/// the full GP register set in the TrapFrame.
fn restoreTlsBase(_: *process.Process) void {
    // tp (x4) is already part of the context save/restore in TrapFrame.
    // No separate CSR to write like ARM64's TPIDR_EL0.
}

/// Save TrapFrame -> Process.Context. Same layout so this is a direct copy.
fn saveContext(frame: *const trap.TrapFrame, ctx: *process.Context) void {
    for (0..32) |i| ctx.x[i] = frame.x[i];
    ctx.sepc = frame.sepc;
    ctx.sstatus = frame.sstatus;
}

/// Restore Process.Context -> TrapFrame.
fn restoreContext(frame: *trap.TrapFrame, ctx: *const process.Context) void {
    for (0..32) |i| frame.x[i] = ctx.x[i];
    frame.sepc = ctx.sepc;
    // Clear SPP bit (return to U-mode) and set SPIE (enable interrupts on sret)
    frame.sstatus = (ctx.sstatus & ~@as(u64, 1 << 8)) | (1 << 5);
}

fn halt() noreturn {
    // Enable S-mode interrupts and enter idle loop
    asm volatile ("csrs sstatus, %[sie]" :: [sie] "r" (@as(u64, 1 << 1)));
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

fn stuckKernelCheck(cpu: *smp.PerCpu, frame: *trap.TrapFrame) void {
    const stuck_detect = struct {
        var kernel_ticks: [smp.MAX_CPUS]u32 = .{ 0, 0, 0, 0 };
    };
    const ci = cpu.cpu_id;
    if (ci < smp.MAX_CPUS) {
        stuck_detect.kernel_ticks[ci] += 1;
        if (stuck_detect.kernel_ticks[ci] == 30) {
            if (cpu.current_process) |proc| {
                uart.print("[sched] Hart {} stuck in kernel for P{} SEPC={x} RA={x} A7={} SP={x}\n", .{
                    ci, proc.pid, frame.sepc, frame.x[1], frame.x[17], frame.x[2],
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
            uart.writeString("[sched] DEADLOCK? All harts idle. Process states:\n");
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
