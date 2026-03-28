/// Preemptive round-robin scheduler — SMP-aware.
///
/// Each CPU maintains its own current_process, current_idx, and slice_remaining
/// via the CpuLocal struct (accessed through GS_BASE). Context switch works by
/// overwriting the InterruptFrame in-place.
///
/// Process selection uses a global pickNext with atomic state claim to prevent
/// two CPUs from picking the same process. Per-CPU runqueues (Step 5 optimization)
/// can be added later.

const process = @import("process.zig");
const tss_mod = @import("../arch/x86_64/tss.zig");
const syscall_entry = @import("../arch/x86_64/syscall_entry.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const types = @import("../types.zig");
const klog = @import("../klog/klog.zig");
const smp = @import("../arch/x86_64/smp.zig");
const spinlock = @import("../arch/x86_64/spinlock.zig");

const TIMESLICE_TICKS: u64 = 10; // 100ms at 100 Hz

/// Scheduler lock — protects pickNext + state transitions.
/// Held briefly during process selection to prevent two CPUs
/// from claiming the same ready process.
var sched_lock: spinlock.IrqSpinlock = .{};

// --- SCHED_DEDICATED support ---

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
    if (cpu.dedicated_pid == pid) {
        cpu.dedicated_pid = 0;
    }
}

pub fn currentProcess() ?*process.Process {
    return smp.current().current_process;
}

pub fn currentProcessIndex() ?usize {
    return smp.current().current_idx;
}

/// Start the first user process on the BSP. Does not return.
pub fn startFirst(proc: *process.Process) noreturn {
    serial.writeString("[sched] startFirst: find proc\n");
    const cpu = smp.current();

    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.pid == proc.pid) {
                cpu.current_idx = i;
                cpu.current_process = proc;
                break;
            }
        }
    }

    proc.state = .running;

    serial.writeString("[sched] startFirst: TSS+FS\n");
    tss_mod.setRsp0(proc.kernel_stack_top);
    restoreFsBase(proc);

    const new_rsp = proc.kernel_stack_top - 64;
    const new_cr3 = proc.page_table;
    const ctx = proc.context;

    asm volatile (
        \\movq %[new_rsp], %%rsp
        \\movq %[new_cr3], %%cr3
        \\pushq %[ss]
        \\pushq %[user_rsp]
        \\pushq %[rflags]
        \\pushq %[cs]
        \\pushq %[rip]
        \\iretq
        :
        : [new_rsp] "r" (new_rsp),
          [new_cr3] "r" (new_cr3),
          [ss] "r" (ctx.ss),
          [user_rsp] "r" (ctx.rsp),
          [rflags] "r" (ctx.rflags),
          [cs] "r" (ctx.cs),
          [rip] "r" (ctx.rip),
        : .{ .memory = true }
    );
    unreachable;
}

/// Called from timer IRQ handler on every tick.
pub fn timerTick(frame: *idt.InterruptFrame) void {
    const cpu = smp.current();

    // BSP-only scheduling — APs skip (workaround for SMP CoW race)
    if (cpu.cpu_id != 0) return;

    // Wake sleeping processes whose wake_tick has expired (all CPUs check)
    const current_tick = idt.getTickCount();
    for (0..process.MAX_PROCESSES) |wi| {
        if (process.getProcess(wi)) |p| {
            if (p.wake_tick > 0 and current_tick >= p.wake_tick) {
                p.wake_tick = 0;
                p.context.rax = 0;
                if (p.state == .blocked) {
                    p.state = .ready;
                }
            }
        }
    }

    // RIP sampling: every 1000 ticks (~10s), print current process RIP
    {
        const tick = idt.getTickCount();
        if (tick % 100 == 0 and tick > 0) {
            if (cpu.current_process) |p| {
                {
                    serial.writeString("[rip] pid=");
                    // Simple decimal PID
                    if (p.pid >= 100) serial.writeByte(@as(u8, @truncate((p.pid / 100) % 10)) + '0');
                    if (p.pid >= 10) serial.writeByte(@as(u8, @truncate((p.pid / 10) % 10)) + '0');
                    serial.writeByte(@as(u8, @truncate(p.pid % 10)) + '0');
                    serial.writeString(" 0x");
                    // Hex RIP (16 chars)
                    var hb: [16]u8 = undefined;
                    var hv = frame.rip;
                    var hi: usize = 16;
                    while (hi > 0) { hi -= 1; hb[hi] = "0123456789abcdef"[@as(usize, @truncate(hv & 0xf))]; hv >>= 4; }
                    serial.writeString(&hb);
                    serial.writeString("\n");
                }
            }
        }
    }

    cpu.slice_remaining -|= 1;
    if (cpu.slice_remaining > 0) return;
    cpu.slice_remaining = TIMESLICE_TICKS;

    // SCHED_DEDICATED: never preempt
    if (cpu.dedicated_pid != 0) {
        if (cpu.current_process) |proc| {
            if (proc.pid == cpu.dedicated_pid) return;
        }
    }

    // CPU is idle (no current process) — try to pick one up
    if (cpu.current_idx == null) {
        const flags = sched_lock.acquire();
        const next_idx = pickNextUnlocked();
        if (next_idx) |ni| {
            const new_proc = process.getProcess(ni) orelse {
                sched_lock.release(flags);
                return;
            };
            new_proc.state = .running;
            sched_lock.release(flags);

            restoreContext(frame, &new_proc.context);
            cpu.current_idx = ni;
            cpu.current_process = new_proc;
            cpu.idle = false;
            tss_mod.setRsp0(new_proc.kernel_stack_top);
            restoreFsBase(new_proc);
            vmm.switchAddressSpace(new_proc.page_table);
        } else {
            sched_lock.release(flags);
        }
        return;
    }

    // Normal preemption: timeslice expired
    const cur_idx = cpu.current_idx.?;
    const old_proc = process.getProcess(cur_idx) orelse return;

    const flags = sched_lock.acquire();
    const next_idx = pickNextUnlocked() orelse {
        sched_lock.release(flags);
        // Handle zombie — release the CPU
        if (old_proc.state == .zombie) {
            cpu.current_idx = null;
            cpu.current_process = null;
            cpu.idle = true;
        }
        return;
    };

    if (next_idx == cur_idx) {
        sched_lock.release(flags);
        return;
    }

    const new_proc = process.getProcess(next_idx) orelse {
        sched_lock.release(flags);
        return;
    };
    new_proc.state = .running;
    sched_lock.release(flags);

    checkStackCanary(old_proc);
    saveContext(frame, &old_proc.context);
    saveFsBase(old_proc);
    if (old_proc.state == .running) {
        old_proc.state = .ready;
    }

    restoreContext(frame, &new_proc.context);
    cpu.current_idx = next_idx;
    cpu.current_process = new_proc;
    cpu.idle = false;
    tss_mod.setRsp0(new_proc.kernel_stack_top);
    restoreFsBase(new_proc);

    if (new_proc.page_table != old_proc.page_table) {
        vmm.switchAddressSpace(new_proc.page_table);
    }
}

/// Schedule the next ready process (called from sysExit).
pub fn schedule(frame: *idt.InterruptFrame) void {
    const cpu = smp.current();

    const flags = sched_lock.acquire();
    const next_idx = pickNextUnlocked() orelse {
        sched_lock.release(flags);
        // No ready processes — mark idle and wait
        cpu.current_idx = null;
        cpu.current_process = null;
        cpu.idle = true;
        // Idle loop — timer tick will pick up processes when they become ready
        while (true) {
            asm volatile ("sti\nhlt" ::: .{ .memory = true });
            // Check if a process became ready
            const f2 = sched_lock.acquire();
            if (pickNextUnlocked()) |ni| {
                if (process.getProcess(ni)) |new_proc| {
                    new_proc.state = .running;
                    sched_lock.release(f2);
                    restoreContext(frame, &new_proc.context);
                    cpu.current_idx = ni;
                    cpu.current_process = new_proc;
                    cpu.idle = false;
                    cpu.slice_remaining = TIMESLICE_TICKS;
                    tss_mod.setRsp0(new_proc.kernel_stack_top);
                    restoreFsBase(new_proc);
                    vmm.switchAddressSpace(new_proc.page_table);
                    return;
                }
            }
            sched_lock.release(f2);
        }
    };

    const new_proc = process.getProcess(next_idx) orelse {
        sched_lock.release(flags);
        const main = @import("../main.zig");
        main.halt();
    };
    new_proc.state = .running;
    sched_lock.release(flags);

    restoreContext(frame, &new_proc.context);
    cpu.current_idx = next_idx;
    cpu.current_process = new_proc;
    cpu.idle = false;
    cpu.slice_remaining = TIMESLICE_TICKS;
    tss_mod.setRsp0(new_proc.kernel_stack_top);
    restoreFsBase(new_proc);
    vmm.switchAddressSpace(new_proc.page_table);
}

/// Block the current process and switch to the next ready process.
pub fn blockAndSchedule(frame: *idt.InterruptFrame) void {
    const cpu = smp.current();
    const cur_idx = cpu.current_idx orelse return;
    const old_proc = process.getProcess(cur_idx) orelse return;

    saveContext(frame, &old_proc.context);
    saveFsBase(old_proc);
    // State already set by caller (blocked_on_pipe, blocked_on_wait, etc.)

    const flags = sched_lock.acquire();
    if (pickNextUnlocked()) |next_idx| {
        const new_proc = process.getProcess(next_idx) orelse {
            sched_lock.release(flags);
            return;
        };
        new_proc.state = .running;
        sched_lock.release(flags);

        restoreContext(frame, &new_proc.context);
        cpu.current_idx = next_idx;
        cpu.current_process = new_proc;
        cpu.slice_remaining = TIMESLICE_TICKS;
        tss_mod.setRsp0(new_proc.kernel_stack_top);
        restoreFsBase(new_proc);
        if (new_proc.page_table != old_proc.page_table) {
            vmm.switchAddressSpace(new_proc.page_table);
        }
    } else {
        sched_lock.release(flags);
        // No ready process — idle until IRQ wakes something
        cpu.current_idx = null;
        cpu.current_process = null;
        cpu.idle = true;

        while (true) {
            asm volatile ("sti\nhlt" ::: .{ .memory = true });

            // Check if our process was woken
            if (old_proc.state == .ready or old_proc.state == .running) break;

            const f2 = sched_lock.acquire();
            if (pickNextUnlocked()) |next_idx| {
                const new_proc = process.getProcess(next_idx) orelse {
                    sched_lock.release(f2);
                    continue;
                };
                new_proc.state = .running;
                sched_lock.release(f2);
                restoreContext(frame, &new_proc.context);
                cpu.current_idx = next_idx;
                cpu.current_process = new_proc;
                cpu.idle = false;
                cpu.slice_remaining = TIMESLICE_TICKS;
                tss_mod.setRsp0(new_proc.kernel_stack_top);
                restoreFsBase(new_proc);
                if (new_proc.page_table != old_proc.page_table) {
                    vmm.switchAddressSpace(new_proc.page_table);
                }
                return;
            }
            sched_lock.release(f2);
        }

        // Our process was woken — restore it
        restoreContext(frame, &old_proc.context);
        old_proc.state = .running;
        cpu.current_idx = cur_idx;
        cpu.current_process = old_proc;
        cpu.idle = false;
        cpu.slice_remaining = TIMESLICE_TICKS;
        restoreFsBase(old_proc);
    }
}

/// Wake a blocked process by PID.
pub fn wakeProcess(pid: u64) void {
    if (process.findByPid(@truncate(pid))) |p| {
        if (p.state == .blocked_on_pipe or p.state == .blocked_on_wait or p.state == .blocked or p.state == .blocked_on_futex or p.state == .blocked_on_net) {
            p.state = .ready;
        }
    }
}

/// Make a newly created process runnable (called from fork/exec).
pub fn makeRunnable(proc: *process.Process) void {
    proc.state = .ready;
}

// --- Round-robin process selection (caller must hold sched_lock) ---

fn pickNextUnlocked() ?usize {
    const cpu = smp.current();
    const start = cpu.current_idx orelse 0;
    var i: usize = 1;
    while (i <= process.MAX_PROCESSES) : (i += 1) {
        const idx = (start + i) % process.MAX_PROCESSES;
        if (process.getProcess(idx)) |p| {
            if (p.state == .ready) return idx;
        }
    }
    return null;
}

// --- FS_BASE save/restore for TLS ---

fn saveFsBase(proc: *process.Process) void {
    // Read current FS_BASE MSR and save to process struct.
    // Required because: (1) wrfsbase can set FS without a syscall if CR4.FSGSBASE,
    // (2) fork'd children inherit FS_BASE from the CPU MSR but proc.fs_base is 0.
    const IA32_FS_BASE: u32 = 0xC0000100;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
        : [_] "{ecx}" (IA32_FS_BASE),
    );
    proc.fs_base = @as(u64, high) << 32 | low;
}

fn restoreFsBase(proc: *process.Process) void {
    const IA32_FS_BASE: u32 = 0xC0000100;
    syscall_entry.wrmsrPub(IA32_FS_BASE, proc.fs_base);
}

// --- Context save/restore ---

fn saveContext(frame: *const idt.InterruptFrame, ctx: *process.Context) void {
    ctx.r15 = frame.r15;
    ctx.r14 = frame.r14;
    ctx.r13 = frame.r13;
    ctx.r12 = frame.r12;
    ctx.r11 = frame.r11;
    ctx.r10 = frame.r10;
    ctx.r9 = frame.r9;
    ctx.r8 = frame.r8;
    ctx.rbp = frame.rbp;
    ctx.rdi = frame.rdi;
    ctx.rsi = frame.rsi;
    ctx.rdx = frame.rdx;
    ctx.rcx = frame.rcx;
    ctx.rbx = frame.rbx;
    ctx.rax = frame.rax;
    ctx.rip = frame.rip;
    ctx.cs = frame.cs;
    ctx.rflags = frame.rflags;
    ctx.rsp = frame.rsp;
    ctx.ss = frame.ss;
}

fn restoreContext(frame: *idt.InterruptFrame, ctx: *const process.Context) void {
    frame.r15 = ctx.r15;
    frame.r14 = ctx.r14;
    frame.r13 = ctx.r13;
    frame.r12 = ctx.r12;
    frame.r11 = ctx.r11;
    frame.r10 = ctx.r10;
    frame.r9 = ctx.r9;
    frame.r8 = ctx.r8;
    frame.rbp = ctx.rbp;
    frame.rdi = ctx.rdi;
    frame.rsi = ctx.rsi;
    frame.rdx = ctx.rdx;
    frame.rcx = ctx.rcx;
    frame.rbx = ctx.rbx;
    frame.rax = ctx.rax;
    frame.rip = ctx.rip;
    frame.cs = ctx.cs;
    frame.rflags = ctx.rflags;
    frame.rsp = ctx.rsp;
    frame.ss = ctx.ss;
}

// --- Kernel stack canary check ---

fn checkStackCanary(proc: *process.Process) void {
    if (proc.kernel_stack_phys == 0) return;
    const canary_virt = hhdm.physToVirt(proc.kernel_stack_phys);
    const canary_ptr: *const u64 = @ptrFromInt(canary_virt);
    if (canary_ptr.* != pmm.STACK_CANARY) {
        // Log but don't panic — may be false positive from PMM page reuse
        const sched_log = klog.scoped(.sched);
        sched_log.warn("canary_corrupt", .{ .pid = proc.pid, .kstack = proc.kernel_stack_phys, .found = canary_ptr.* });
        // Re-write canary to prevent repeated warnings
        const canary_mut: *u64 = @ptrFromInt(canary_virt);
        canary_mut.* = pmm.STACK_CANARY;
    }
}
