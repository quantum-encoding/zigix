/// ARM64 Exception Vectors
/// Equivalent to x86_64/idt.zig but using ARM64's exception model.
///
/// ARM64 has 4 exception types at each of 4 levels:
/// - Synchronous (syscalls, faults)
/// - IRQ (normal interrupts)
/// - FIQ (fast interrupts)
/// - SError (system error)

const std = @import("std");
const uart = @import("uart.zig");
const gic = @import("gic.zig");
const klog = @import("klog");
const syscall = @import("syscall.zig");
const scheduler = @import("scheduler.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const vma = @import("vma.zig");
const process = @import("process.zig");
const signal = @import("signal.zig");
const vfs = @import("vfs.zig");
const page_cache = @import("page_cache.zig");
const smp = @import("smp.zig");

// Page fault counter for PID >= 4 heartbeat (diagnostic)

// Per-CPU re-entrancy guard for data_abort_same handling.
// Prevents infinite recursion if handlePageFault itself triggers a kernel fault.
var kernel_fault_depth: [4]u8 = .{ 0, 0, 0, 0 };

// ============================================================================
// Exception Ring Buffer — per-CPU diagnostic trace of every exception entry/exit.
// When a crash occurs, dump the last N entries to see exactly which context
// switch or exception path wrote corrupted SPSR/ELR.
// ============================================================================

const EXC_RING_SIZE: usize = 64;

/// Ring buffer entry: 40 bytes, records one exception entry or return.
const ExcRingEntry = extern struct {
    elr: u64, // ELR at this point (may differ entry vs return after ctx switch)
    spsr: u64, // SPSR at this point
    far_or_sp: u64, // FAR at entry, kernel SP at return
    pid: u32, // current PID (0 = no process)
    cpu: u8, // CPU ID
    ec: u8, // exception class (entry), 0xFF (return)
    kind: u8, // 0=sync_entry, 1=irq_entry, 2=return
    _pad: u8,
};

/// Per-CPU ring buffers (static, in .bss — 64 entries × 40 bytes × 4 CPUs = 10 KiB)
var exc_ring: [smp.MAX_CPUS][EXC_RING_SIZE]ExcRingEntry = @import("std").mem.zeroes([smp.MAX_CPUS][EXC_RING_SIZE]ExcRingEntry);
var exc_ring_idx: [smp.MAX_CPUS]u32 = .{ 0, 0, 0, 0 };

fn ringRecord(cpu_id: u32, entry: ExcRingEntry) void {
    if (cpu_id >= smp.MAX_CPUS) return;
    const idx = exc_ring_idx[cpu_id] % EXC_RING_SIZE;
    exc_ring[cpu_id][idx] = entry;
    exc_ring_idx[cpu_id] +%= 1;
}

fn currentPidSafe() u32 {
    const tpidr = asm volatile ("mrs %[ret], TPIDR_EL1"
        : [ret] "=r" (-> usize),
    );
    if (tpidr == 0) return 0;
    const cpu = @as(*smp.PerCpu, @ptrFromInt(tpidr));
    if (cpu.current_process) |p| return @truncate(p.pid);
    return 0;
}

fn currentCpuIdSafe() u8 {
    const tpidr = asm volatile ("mrs %[ret], TPIDR_EL1"
        : [ret] "=r" (-> usize),
    );
    if (tpidr == 0) return 0;
    return @truncate(@as(*smp.PerCpu, @ptrFromInt(tpidr)).cpu_id);
}

/// Record exception entry (called from Zig handlers)
fn ringRecordEntry(frame: *const TrapFrame, kind: u8) void {
    const cpu_id = currentCpuIdSafe();
    const ec_val: u8 = @truncate(getEsr() >> 26);
    ringRecord(cpu_id, .{
        .elr = frame.elr,
        .spsr = frame.spsr,
        .far_or_sp = getFaultAddress(),
        .pid = currentPidSafe(),
        .cpu = cpu_id,
        .ec = ec_val,
        .kind = kind,
        ._pad = 0,
    });
}

/// Record exception return (called from exc_return assembly via bl).
/// Also performs SPSR validation: if a user process is current and SPSR
/// has EL1 mode bits, that's corruption — trap immediately.
export fn excRingRecordReturn(frame: *TrapFrame) void {
    const cpu_id = currentCpuIdSafe();
    const kernel_sp = asm volatile ("mov %[ret], sp" : [ret] "=r" (-> u64));
    ringRecord(cpu_id, .{
        .elr = frame.elr,
        .spsr = frame.spsr,
        .far_or_sp = kernel_sp,
        .pid = currentPidSafe(),
        .cpu = cpu_id,
        .ec = 0xFF,
        .kind = 2, // return
        ._pad = 0,
    });

    // --- SPSR validation ---
    // Only fire if SPSR says EL1 AND ELR is in user address space (< 0x40000000).
    // Nested exception returns (data_abort_same during SVC handler, IRQ during
    // kernel code) legitimately have EL1 SPSR and kernel ELR — these are NOT
    // corruption. The trap should only fire when we're about to eret to a USER
    // address with kernel SPSR, which would cause an illegal execution state.
    if ((frame.spsr & 0xF) != 0 and frame.elr < 0x40000000) {
        const tpidr = asm volatile ("mrs %[ret], TPIDR_EL1"
            : [ret] "=r" (-> usize),
        );
        if (tpidr != 0) {
            const cpu = @as(*smp.PerCpu, @ptrFromInt(tpidr));
            if (cpu.current_process) |proc| {
                if ((proc.context.spsr & 0xF) == 0) {
                    handleSpsrTrap(frame);
                }
            }
        }
    }
}

/// SPSR corruption trap — called from exc_return assembly when SPSR has EL1
/// mode bits but ELR is in user address range. This is the smoking gun.
/// SPSR corruption trap — uses ONLY raw UART writes (no Zig fmt) to survive
/// corrupted state without triggering double-panic.
export fn handleSpsrTrap(frame: *TrapFrame) noreturn {
    // Use lock-free crash output — the other CPU may hold the UART lock,
    // causing locked writes to deadlock and produce no output at all.
    uart.crashString("\n\n!!! SPSR CORRUPTION DETECTED at exc_return !!!\n");
    uart.crashString("  SPSR=");
    uart.crashHex(frame.spsr);
    uart.crashString(" ELR=");
    uart.crashHex(frame.elr);
    uart.crashString(" SP_EL0=");
    uart.crashHex(frame.sp);
    uart.crashByte('\n');
    const ksp = asm volatile ("mov %[ret], sp" : [ret] "=r" (-> u64));
    uart.crashString("  kernel_SP=");
    uart.crashHex(ksp);
    uart.crashByte('\n');
    uart.crashString("  X0=");
    uart.crashHex(frame.x[0]);
    uart.crashString(" X1=");
    uart.crashHex(frame.x[1]);
    uart.crashString(" X2=");
    uart.crashHex(frame.x[2]);
    uart.crashString(" X3=");
    uart.crashHex(frame.x[3]);
    uart.crashByte('\n');
    uart.crashString("  X8=");
    uart.crashHex(frame.x[8]);
    uart.crashString(" X19=");
    uart.crashHex(frame.x[19]);
    uart.crashString(" X20=");
    uart.crashHex(frame.x[20]);
    uart.crashString(" X29=");
    uart.crashHex(frame.x[29]);
    uart.crashString(" X30=");
    uart.crashHex(frame.x[30]);
    uart.crashByte('\n');
    const tpidr = asm volatile ("mrs %[ret], TPIDR_EL1" : [ret] "=r" (-> usize));
    if (tpidr != 0) {
        const cpu = @as(*smp.PerCpu, @ptrFromInt(tpidr));
        if (cpu.current_process) |p| {
            uart.crashString("  PID=");
            uart.crashDec(p.pid);
            uart.crashString(" tgid=");
            uart.crashDec(p.tgid);
            uart.crashString(" state=");
            uart.crashDec(@intFromEnum(p.state));
            uart.crashString(" kstack=");
            uart.crashHex(p.kernel_stack_phys);
            uart.crashByte('-');
            uart.crashHex(p.kernel_stack_top);
            uart.crashByte('\n');
            uart.crashString("  ctx.spsr=");
            uart.crashHex(p.context.spsr);
            uart.crashString(" ctx.elr=");
            uart.crashHex(p.context.elr);
            uart.crashByte('\n');

            // --- Stack canary check: disambiguates stack overflow vs DMA aliasing ---
            // If canary intact → DMA aliasing. If canary corrupted → stack overflow.
            if (p.kernel_stack_phys != 0) {
                const canary_ptr: *const u64 = @ptrFromInt(p.kernel_stack_phys);
                const canary_val = canary_ptr.*;
                uart.crashString("  CANARY=");
                uart.crashHex(canary_val);
                if (canary_val == pmm.STACK_CANARY) {
                    uart.crashString(" (INTACT)\n");
                } else {
                    uart.crashString(" (CORRUPTED!)\n");
                }
            }

            const frame_addr = @intFromPtr(frame);
            uart.crashString("  frame_at=");
            uart.crashHex(frame_addr);
            uart.crashString(" depth=");
            uart.crashDec(p.kernel_stack_top -| frame_addr);
            uart.crashString("/");
            uart.crashDec(p.kernel_stack_top -| p.kernel_stack_phys);
            uart.crashByte('\n');
        }
    }

    // Mask interrupts on this CPU before dump
    asm volatile ("msr DAIFSet, #2");

    // Dump the ring buffer — this is why we built it
    dumpExcRing();
    syscall.dumpTrace(64);
    uart.writeString("!!! Halting — SPSR corruption caught at source !!!\n");
    while (true) asm volatile ("wfi");
}

/// Re-entrancy guard for dumpExcRing — prevents double-panic from crashing the dump.
var dump_in_progress: bool = false;

/// Dump the exception ring buffer for all CPUs (most recent entries first).
/// Uses ONLY raw UART writes (no Zig fmt/print) to avoid safety-check panics
/// during crash diagnostics. A double panic in fmt silently halts the CPU.
pub fn dumpExcRing() void {
    if (dump_in_progress) {
        uart.crashString("[ring] re-entrant dump skipped\n");
        return;
    }
    dump_in_progress = true;

    uart.crashString("\n--- Exception Ring Buffer ---\n");
    var cpu_i: u32 = 0;
    while (cpu_i < smp.MAX_CPUS) : (cpu_i += 1) {
        const total = exc_ring_idx[cpu_i];
        if (total == 0) {
            uart.crashString("CPU ");
            uart.crashDec(cpu_i);
            uart.crashString(": (empty)\n");
            continue;
        }
        uart.crashString("CPU ");
        uart.crashDec(cpu_i);
        uart.crashString(" (");
        uart.crashDec(total);
        uart.crashString(" entries, last 32):\n");
        const show: u32 = if (total < 32) total else 32;
        var i: u32 = 0;
        while (i < show) : (i += 1) {
            const ring_i = (total -% 1 -% i) % EXC_RING_SIZE;
            const e = &exc_ring[cpu_i][ring_i];
            const kind_ch: u8 = switch (e.kind) {
                0 => 'S',
                1 => 'I',
                2 => 'R',
                else => '?',
            };
            uart.crashString("  [");
            uart.crashByte(kind_ch);
            uart.crashString("] P");
            uart.crashDec(e.pid);
            uart.crashString(" ec=");
            uart.crashHex(e.ec);
            uart.crashString(" ELR=");
            uart.crashHex(e.elr);
            uart.crashString(" SPSR=");
            uart.crashHex(e.spsr);
            uart.crashString(" far/sp=");
            uart.crashHex(e.far_or_sp);
            uart.crashByte('\n');
        }
    }
    uart.crashString("--- End Ring Buffer ---\n");
    dump_in_progress = false;
}

/// Device probe fault flag — set by data_abort_same when an MMIO read to
/// device memory (< 0x40000000) triggers an external abort. Used by PCI
/// config space reads to detect non-existent devices (Linux fixup_exception pattern).
pub var device_probe_faulted: bool = false;

/// Saved register state during exception (800 bytes total)
/// Layout matches the assembly save/restore in vector_table.
pub const TrapFrame = extern struct {
    // General purpose registers (offsets 0-247)
    x: [31]u64, // X0-X30
    sp: u64, // Stack pointer (offset 248)
    elr: u64, // Exception Link Register (return address, offset 256)
    spsr: u64, // Saved Program Status Register (offset 264)
    // SIMD/FP registers (offsets 272-783)
    simd: [32][2]u64, // q0-q31, each 128-bit stored as pair of u64
    fpcr: u64, // Floating-point Control Register (offset 784)
    fpsr: u64, // Floating-point Status Register (offset 792)

    // Helper accessors for syscall ABI
    pub fn syscallNum(self: *const TrapFrame) u64 {
        return self.x[8]; // X8 = syscall number
    }

    pub fn arg0(self: *const TrapFrame) u64 {
        return self.x[0];
    }
    pub fn arg1(self: *const TrapFrame) u64 {
        return self.x[1];
    }
    pub fn arg2(self: *const TrapFrame) u64 {
        return self.x[2];
    }
    pub fn arg3(self: *const TrapFrame) u64 {
        return self.x[3];
    }
    pub fn arg4(self: *const TrapFrame) u64 {
        return self.x[4];
    }
    pub fn arg5(self: *const TrapFrame) u64 {
        return self.x[5];
    }

    pub fn setReturn(self: *TrapFrame, value: u64) void {
        self.x[0] = value; // X0 = return value
    }
};

/// Exception Syndrome Register (ESR_EL1) decoding
const ExceptionClass = enum(u6) {
    unknown = 0b000000,
    wf_trapped = 0b000001,
    svc_aarch64 = 0b010101, // SVC instruction (syscall)
    instruction_abort_lower = 0b100000,
    instruction_abort_same = 0b100001,
    pc_alignment = 0b100010,
    data_abort_lower = 0b100100,
    data_abort_same = 0b100101,
    sp_alignment = 0b100110,
    _,
};

fn getExceptionClass() ExceptionClass {
    const esr = asm volatile ("mrs %[ret], ESR_EL1"
        : [ret] "=r" (-> u64),
    );
    return @enumFromInt(@as(u6, @truncate(esr >> 26)));
}

fn getFaultAddress() u64 {
    return asm volatile ("mrs %[ret], FAR_EL1"
        : [ret] "=r" (-> u64),
    );
}

/// Initialize exception handling
pub fn init() void {
    // Set the vector base address register (must be 2KB aligned)
    const vbar = @intFromPtr(&vector_table);
    asm volatile ("msr VBAR_EL1, %[vbar]"
        :
        : [vbar] "r" (vbar),
    );
    asm volatile ("isb");

    uart.writeString("[exc]  Exception vectors installed\n");
}

// ============================================================================
// Exception Vector Table (pure assembly)
// ============================================================================
// Each vector entry must be 128 bytes (32 instructions) aligned.
// There are 16 entries total (4 exception types x 4 source levels).

pub export fn vector_table() align(0x800) callconv(.naked) void {
    asm volatile (
        // -----------------------------------------------------------------
        // Current EL with SP_EL0 (offset 0x000)
        // -----------------------------------------------------------------
        \\b exc_sync_sp0         // 0x000: Sync
        \\.balign 0x80
        \\b exc_irq_sp0          // 0x080: IRQ
        \\.balign 0x80
        \\b exc_fiq_halt
        \\.balign 0x80
        \\b exc_serror_halt

        // -----------------------------------------------------------------
        // Current EL with SP_ELx (kernel mode, normal case)
        // -----------------------------------------------------------------
        \\.balign 0x80
        \\b exc_sync_spx
        \\.balign 0x80
        \\b exc_irq_spx
        \\.balign 0x80
        \\b exc_fiq_halt
        \\.balign 0x80
        \\b exc_serror_halt

        // -----------------------------------------------------------------
        // Lower EL using AArch64 (user mode)
        // -----------------------------------------------------------------
        \\.balign 0x80
        \\b exc_sync_lower64
        \\.balign 0x80
        \\b exc_irq_lower64
        \\.balign 0x80
        \\b exc_fiq_halt
        \\.balign 0x80
        \\b exc_serror_halt

        // -----------------------------------------------------------------
        // Lower EL using AArch32 (not supported)
        // -----------------------------------------------------------------
        \\.balign 0x80
        \\b exc_halt
        \\.balign 0x80
        \\b exc_halt
        \\.balign 0x80
        \\b exc_halt
        \\.balign 0x80
        \\b exc_halt

        // =================================================================
        // Exception Entry Points
        // =================================================================

        // --- Sync exceptions (all ELs share one entry) ---
        // SP_EL1 is ALWAYS the correct kernel stack top because exc_return
        // explicitly sets it before every eret (see below). No SP reload
        // needed at entry — just push the TrapFrame.
        \\exc_sync_sp0:
        \\exc_sync_spx:
        \\exc_sync_lower64:
        \\    sub sp, sp, #800
        \\    stp x0, x1, [sp, #(0 * 8)]
        \\    stp x2, x3, [sp, #(2 * 8)]
        \\    stp x4, x5, [sp, #(4 * 8)]
        \\    stp x6, x7, [sp, #(6 * 8)]
        \\    stp x8, x9, [sp, #(8 * 8)]
        \\    stp x10, x11, [sp, #(10 * 8)]
        \\    stp x12, x13, [sp, #(12 * 8)]
        \\    stp x14, x15, [sp, #(14 * 8)]
        \\    stp x16, x17, [sp, #(16 * 8)]
        \\    stp x18, x19, [sp, #(18 * 8)]
        \\    stp x20, x21, [sp, #(20 * 8)]
        \\    stp x22, x23, [sp, #(22 * 8)]
        \\    stp x24, x25, [sp, #(24 * 8)]
        \\    stp x26, x27, [sp, #(26 * 8)]
        \\    stp x28, x29, [sp, #(28 * 8)]
        \\    str x30, [sp, #(30 * 8)]
        \\    mrs x0, SP_EL0
        \\    str x0, [sp, #(31 * 8)]
        \\    mrs x0, ELR_EL1
        \\    str x0, [sp, #(32 * 8)]
        \\    mrs x0, SPSR_EL1
        \\    str x0, [sp, #(33 * 8)]
        \\    stp q0, q1, [sp, #272]
        \\    stp q2, q3, [sp, #304]
        \\    stp q4, q5, [sp, #336]
        \\    stp q6, q7, [sp, #368]
        \\    stp q8, q9, [sp, #400]
        \\    stp q10, q11, [sp, #432]
        \\    stp q12, q13, [sp, #464]
        \\    stp q14, q15, [sp, #496]
        \\    stp q16, q17, [sp, #528]
        \\    stp q18, q19, [sp, #560]
        \\    stp q20, q21, [sp, #592]
        \\    stp q22, q23, [sp, #624]
        \\    stp q24, q25, [sp, #656]
        \\    stp q26, q27, [sp, #688]
        \\    stp q28, q29, [sp, #720]
        \\    stp q30, q31, [sp, #752]
        \\    mrs x0, FPCR
        \\    mrs x1, FPSR
        \\    str x0, [sp, #784]
        \\    str x1, [sp, #792]
        \\    mov x0, sp
        \\    bl handleSyncException
        \\    b exc_return

        // --- IRQ exceptions (all ELs share one entry) ---
        \\exc_irq_sp0:
        \\exc_irq_spx:
        \\exc_irq_lower64:
        \\    sub sp, sp, #800
        \\    stp x0, x1, [sp, #(0 * 8)]
        \\    stp x2, x3, [sp, #(2 * 8)]
        \\    stp x4, x5, [sp, #(4 * 8)]
        \\    stp x6, x7, [sp, #(6 * 8)]
        \\    stp x8, x9, [sp, #(8 * 8)]
        \\    stp x10, x11, [sp, #(10 * 8)]
        \\    stp x12, x13, [sp, #(12 * 8)]
        \\    stp x14, x15, [sp, #(14 * 8)]
        \\    stp x16, x17, [sp, #(16 * 8)]
        \\    stp x18, x19, [sp, #(18 * 8)]
        \\    stp x20, x21, [sp, #(20 * 8)]
        \\    stp x22, x23, [sp, #(22 * 8)]
        \\    stp x24, x25, [sp, #(24 * 8)]
        \\    stp x26, x27, [sp, #(26 * 8)]
        \\    stp x28, x29, [sp, #(28 * 8)]
        \\    str x30, [sp, #(30 * 8)]
        \\    mrs x0, SP_EL0
        \\    str x0, [sp, #(31 * 8)]
        \\    mrs x0, ELR_EL1
        \\    str x0, [sp, #(32 * 8)]
        \\    mrs x0, SPSR_EL1
        \\    str x0, [sp, #(33 * 8)]
        \\    stp q0, q1, [sp, #272]
        \\    stp q2, q3, [sp, #304]
        \\    stp q4, q5, [sp, #336]
        \\    stp q6, q7, [sp, #368]
        \\    stp q8, q9, [sp, #400]
        \\    stp q10, q11, [sp, #432]
        \\    stp q12, q13, [sp, #464]
        \\    stp q14, q15, [sp, #496]
        \\    stp q16, q17, [sp, #528]
        \\    stp q18, q19, [sp, #560]
        \\    stp q20, q21, [sp, #592]
        \\    stp q22, q23, [sp, #624]
        \\    stp q24, q25, [sp, #656]
        \\    stp q26, q27, [sp, #688]
        \\    stp q28, q29, [sp, #720]
        \\    stp q30, q31, [sp, #752]
        \\    mrs x0, FPCR
        \\    mrs x1, FPSR
        \\    str x0, [sp, #784]
        \\    str x1, [sp, #792]
        \\    mov x0, sp
        \\    bl handleIrqException
        \\    b exc_return

        // --- Exception return (shared) ---
        \\exc_return:
        //
        // Record ring buffer entry BEFORE restoring registers.
        // At this point all regs are caller-saved scratch from the Zig handler.
        \\    mov x0, sp
        \\    bl excRingRecordReturn
        //
        \\    ldr x0, [sp, #784]
        \\    ldr x1, [sp, #792]
        \\    msr FPCR, x0
        \\    msr FPSR, x1
        \\    ldp q0, q1, [sp, #272]
        \\    ldp q2, q3, [sp, #304]
        \\    ldp q4, q5, [sp, #336]
        \\    ldp q6, q7, [sp, #368]
        \\    ldp q8, q9, [sp, #400]
        \\    ldp q10, q11, [sp, #432]
        \\    ldp q12, q13, [sp, #464]
        \\    ldp q14, q15, [sp, #496]
        \\    ldp q16, q17, [sp, #528]
        \\    ldp q18, q19, [sp, #560]
        \\    ldp q20, q21, [sp, #592]
        \\    ldp q22, q23, [sp, #624]
        \\    ldp q24, q25, [sp, #656]
        \\    ldp q26, q27, [sp, #688]
        \\    ldp q28, q29, [sp, #720]
        \\    ldp q30, q31, [sp, #752]
        // Restore system registers (SPSR, ELR, SP_EL0) using x0 as scratch
        // NOTE: SPSR validation moved to excRingRecordReturn (Zig level)
        // where we can check process state, not just address ranges.
        \\    ldr x0, [sp, #(33 * 8)]
        \\    msr SPSR_EL1, x0
        \\    ldr x0, [sp, #(32 * 8)]
        \\    msr ELR_EL1, x0
        \\    ldr x0, [sp, #(31 * 8)]
        \\    msr SP_EL0, x0
        //
        // Load kernel_stack_top for EL0 returns (process context switches).
        // For EL1 returns (kernel fault handlers, early boot), keep current SP.
        // Check SPSR.M[3:0]: 0 = EL0 (need SP fix), non-zero = EL1 (SP is fine).
        \\    mrs x0, SPSR_EL1
        \\    and x0, x0, #0xF
        \\    cbnz x0, 1f                  // If returning to EL1, skip SP override
        \\    mrs x0, TPIDR_EL1
        \\    ldr x0, [x0, #8]            // x0 = kernel_stack_top
        \\    b 2f
        \\1:  mov x0, sp
        \\    add x0, x0, #800             // x0 = current SP after TrapFrame pop
        \\2:
        //
        // Restore x2-x30 from TrapFrame (sp still points at TrapFrame)
        \\    ldp x2, x3, [sp, #(2 * 8)]
        \\    ldp x4, x5, [sp, #(4 * 8)]
        \\    ldp x6, x7, [sp, #(6 * 8)]
        \\    ldp x8, x9, [sp, #(8 * 8)]
        \\    ldp x10, x11, [sp, #(10 * 8)]
        \\    ldp x12, x13, [sp, #(12 * 8)]
        \\    ldp x14, x15, [sp, #(14 * 8)]
        \\    ldp x16, x17, [sp, #(16 * 8)]
        \\    ldp x18, x19, [sp, #(18 * 8)]
        \\    ldp x20, x21, [sp, #(20 * 8)]
        \\    ldp x22, x23, [sp, #(22 * 8)]
        \\    ldp x24, x25, [sp, #(24 * 8)]
        \\    ldp x26, x27, [sp, #(26 * 8)]
        \\    ldp x28, x29, [sp, #(28 * 8)]
        \\    ldr x30, [sp, #(30 * 8)]
        //
        // Switch SP to kernel_stack_top BEFORE eret.
        // Save TrapFrame addr in x1, then restore x0,x1 via x1.
        \\    mov x1, sp                  // x1 = &TrapFrame
        \\    mov sp, x0                  // SP = kernel_stack_top (CORRECT for next exception)
        \\    ldp x0, x1, [x1]            // x0 = user x0, x1 = user x1
        \\    eret

        // --- FIQ/SError/Unhandled halt loops ---
        \\exc_fiq_halt:
        \\exc_serror_halt:
        \\exc_halt:
        \\1:  wfi
        \\    b 1b
    );
}

// ============================================================================
// Exception Handlers (called from assembly, regular calling convention)
// ============================================================================

export fn handleSyncException(frame: *TrapFrame) void {
    ringRecordEntry(frame, 0); // 0 = sync entry
    const ec = getExceptionClass();

    switch (ec) {
        .svc_aarch64 => {
            // System call from user space
            syscall.handle(frame);
        },
        .data_abort_lower => {
            handlePageFault(frame, false);
        },
        .instruction_abort_lower => {
            handlePageFault(frame, true);
        },
        .data_abort_same => {
            // Kernel-mode data abort — can happen when the kernel accesses user
            // memory via identity mapping during a syscall and the user page is
            // CoW or not yet demand-paged. If the faulting address is in a valid
            // user VMA, handle it like a normal page fault. Otherwise halt.
            const far = getFaultAddress();

            // Device memory probe fault (ECAM/MMIO external abort).
            // QEMU raises SError/data abort for reads to non-existent PCI devices.
            // Skip the faulting load and set a flag so the caller returns 0xFFFFFFFF.
            if (far < 0x40000000) {
                @as(*volatile bool, @ptrCast(&device_probe_faulted)).* = true;
                frame.elr += 4;
                return;
            }

            // Read TPIDR_EL1 directly — smp.current() panics if TPIDR_EL1 is 0
            // (not yet initialized during early boot before smp.initBsp()).
            const tpidr = asm volatile ("mrs %[ret], TPIDR_EL1"
                : [ret] "=r" (-> usize),
            );
            const cpu_id: u32 = if (tpidr != 0)
                @as(*smp.PerCpu, @ptrFromInt(tpidr)).cpu_id
            else
                0;

            // Re-entrancy guard: if handlePageFault itself triggers another
            // data_abort_same, we must not recurse — just halt.
            if (cpu_id < 4 and kernel_fault_depth[cpu_id] == 0 and
                far >= 0x400000 and far < 0x0001_0000_0000_0000)
            {
                kernel_fault_depth[cpu_id] = 1;
                handlePageFault(frame, false);
                kernel_fault_depth[cpu_id] = 0;
                return;
            }

            // Cannot recover via demand paging — kill user process if possible
            const esr_val = asm volatile ("mrs %[ret], ESR_EL1"
                : [ret] "=r" (-> u64),
            );
            // Read actual kernel stack pointer (SP_EL1) for stack diagnosis
            const kernel_sp = asm volatile ("mov %[ret], sp"
                : [ret] "=r" (-> u64),
            );
            if (scheduler.currentProcess()) |proc| {
                if (proc.pid > 0) {
                    uart.print("[exc] KERNEL DATA ABORT FAR={x} ELR={x} ESR={x} PID={} LR={x} SP_EL0={x}\n", .{
                        far, frame.elr, esr_val, proc.pid, frame.x[30], frame.sp,
                    });
                    uart.print("  SP_EL1={x} cpu={} SPSR={x}\n", .{ kernel_sp, cpu_id, frame.spsr });
                    uart.print("  X0={x} X1={x} X2={x} X19={x} X20={x}\n", .{
                        frame.x[0], frame.x[1], frame.x[2], frame.x[19], frame.x[20],
                    });
                    syscall.dumpTrace(64);
                    dumpExcRing();
                    syscall.killThreadGroup(proc, 128 + @as(u64, signal.SIGSEGV));
                    scheduler.schedule(frame);
                    return;
                }
            }
            // No user process — genuine kernel fault, halt (raw UART only)
            uart.writeString("[exc] KERNEL FAULT FAR=");
            uart.writeHex(far);
            uart.writeString(" ELR=");
            uart.writeHex(frame.elr);
            uart.writeString(" ESR=");
            uart.writeHex(esr_val);
            uart.writeString(" LR=");
            uart.writeHex(frame.x[30]);
            uart.writeString("\n  SP_EL0=");
            uart.writeHex(frame.sp);
            uart.writeString(" SP_EL1=");
            uart.writeHex(kernel_sp);
            uart.writeString(" SPSR=");
            uart.writeHex(frame.spsr);
            uart.writeString(" cpu=");
            uart.writeDec(cpu_id);
            uart.writeString("\n  X0=");
            uart.writeHex(frame.x[0]);
            uart.writeString(" X1=");
            uart.writeHex(frame.x[1]);
            uart.writeString(" X8=");
            uart.writeHex(frame.x[8]);
            uart.writeString(" X29=");
            uart.writeHex(frame.x[29]);
            uart.writeByte('\n');
            dumpExcRing();
            syscall.dumpTrace(64);
            while (true) {
                asm volatile ("wfi");
            }
        },
        .instruction_abort_same => {
            // Instruction abort from kernel (same EL).
            // If we're in a user process context, kill it gracefully (close FDs,
            // zombie, wake parent) so parent doesn't hang forever on wait/pipe.
            // This typically happens when execve fails after point-of-no-return
            // and the process ends up jumping to address 0.
            const far = getFaultAddress();
            const esr_val = asm volatile ("mrs %[ret], ESR_EL1"
                : [ret] "=r" (-> u64),
            );
            if (scheduler.currentProcess()) |proc| {
                if (proc.pid > 0) {
                    uart.print("[exc] KERNEL INST ABORT FAR={x} ELR={x} ESR={x} PID={} LR={x} SP={x}\n", .{
                        far, frame.elr, esr_val, proc.pid, frame.x[30], frame.sp,
                    });
                    uart.print("  SPSR={x} X0={x} X1={x} X2={x} X3={x}\n", .{ frame.spsr, frame.x[0], frame.x[1], frame.x[2], frame.x[3] });
                    uart.print("  X8={x} X19={x} X20={x} X29={x}\n", .{ frame.x[8], frame.x[19], frame.x[20], frame.x[29] });
                    // Dump kernel stack (frame is on kernel stack)
                    const frame_addr = @intFromPtr(frame);
                    uart.print("  frame_at={x} kstack={x} kstop={x}\n", .{ frame_addr, proc.kernel_stack_phys, proc.kernel_stack_top });
                    // Dump a few words above the frame on kernel stack for mini-backtrace
                    const stack_top = proc.kernel_stack_top;
                    if (frame_addr > 0x40000000 and frame_addr < stack_top) {
                        const fp = frame.x[29]; // frame pointer
                        uart.print("  FP chain: {x}", .{fp});
                        if (fp > 0x40000000 and fp < stack_top) {
                            const fp_ptr: *const [2]u64 = @ptrFromInt(fp);
                            uart.print(" -> LR={x} prev_FP={x}", .{ fp_ptr.*[1], fp_ptr.*[0] });
                            if (fp_ptr.*[0] > 0x40000000 and fp_ptr.*[0] < stack_top) {
                                const fp2: *const [2]u64 = @ptrFromInt(fp_ptr.*[0]);
                                uart.print(" -> LR={x}", .{fp2.*[1]});
                            }
                        }
                        uart.writeByte('\n');
                    }
                    syscall.dumpTrace(64);
                    syscall.killThreadGroup(proc, 128 + @as(u64, signal.SIGSEGV));
                    scheduler.schedule(frame);
                    return;
                }
            }
            // No user process or PID 0 — genuine kernel fault, halt (raw UART only)
            const ksp2 = asm volatile ("mov %[ret], sp" : [ret] "=r" (-> u64));
            uart.writeString("[exc] KERNEL FAULT(ia) FAR=");
            uart.writeHex(far);
            uart.writeString(" ELR=");
            uart.writeHex(frame.elr);
            uart.writeString(" ESR=");
            uart.writeHex(esr_val);
            uart.writeString(" LR=");
            uart.writeHex(frame.x[30]);
            uart.writeString("\n  SP_EL0=");
            uart.writeHex(frame.sp);
            uart.writeString(" kernel_SP=");
            uart.writeHex(ksp2);
            uart.writeString(" SPSR=");
            uart.writeHex(frame.spsr);
            uart.writeByte('\n');
            dumpExcRing();
            syscall.dumpTrace(64);
            while (true) {
                asm volatile ("wfi");
            }
        },
        .pc_alignment, .sp_alignment => {
            // User-mode alignment fault — deliver SIGBUS
            if (scheduler.currentProcess()) |proc| {
                signal.postSignal(proc, signal.SIGBUS);
                signal.checkAndDeliver(frame);
            }
        },
        else => {
            // If BRK from kernel mode (e.g. Zig safety check / panic),
            // halt instead of returning to the same BRK instruction.
            if (@intFromEnum(ec) == 60 and (frame.spsr & 0xF) != 0) {
                uart.writeString("[exc]  Kernel BRK (Zig panic) — LR=");
                uart.writeHex(frame.x[30]);
                uart.writeString(" ELR=");
                uart.writeHex(frame.elr);
                uart.writeString(" SPSR=");
                uart.writeHex(frame.spsr);
                uart.writeString("\n");
                uart.writeString("  X0=");
                uart.writeHex(frame.x[0]);
                uart.writeString(" X1=");
                uart.writeHex(frame.x[1]);
                uart.writeString(" X8=");
                uart.writeHex(frame.x[8]);
                uart.writeString(" X29=");
                uart.writeHex(frame.x[29]);
                uart.writeByte('\n');
                dumpExcRing();
                syscall.dumpTrace(64);
                while (true) {
                    asm volatile ("wfi");
                }
            }

            // For unhandled exceptions from EL0, try MRS emulation first
            // (Linux emulates EL1 system register reads for userspace CPU feature detection).
            if ((frame.spsr & 0xF) == 0) {
                if (emulateMrs(frame)) return;

                if (scheduler.currentProcess()) |p| {
                    const esr_val = getEsr();
                    uart.print("[exc] P{} EC={} ELR={x} ESR={x} LR={x}\n", .{ p.pid, @intFromEnum(ec), frame.elr, esr_val, frame.x[30] });
                    signal.postSignal(p, signal.SIGILL);
                    signal.checkAndDeliver(frame);
                    return;
                }
            }

            // EL1 (kernel mode) unhandled exception — halt to prevent infinite loop.
            uart.writeString("[exc]  FATAL: EL1 unhandled EC=");
            uart.writeDec(@intFromEnum(ec));
            uart.writeString(" ELR=");
            uart.writeHex(frame.elr);
            uart.writeString(" SPSR=");
            uart.writeHex(frame.spsr);
            uart.writeString(" LR=");
            uart.writeHex(frame.x[30]);
            uart.writeString("\n");
            // Read actual kernel SP (SP_EL1) — all raw UART, no fmt
            const kernel_sp2 = asm volatile ("mov %[sp], sp" : [sp] "=r" (-> u64));
            uart.writeString("  kernel_SP=");
            uart.writeHex(kernel_sp2);
            uart.writeString(" SP_EL0=");
            uart.writeHex(frame.sp);
            uart.writeString("\n  X0=");
            uart.writeHex(frame.x[0]);
            uart.writeString(" X1=");
            uart.writeHex(frame.x[1]);
            uart.writeString(" X8=");
            uart.writeHex(frame.x[8]);
            uart.writeString(" X29=");
            uart.writeHex(frame.x[29]);
            uart.writeByte('\n');
            syscall.dumpTrace(64);
            dumpExcRing();
            uart.writeString("[exc]  Halting CPU.\n");
            while (true) {
                asm volatile ("wfi");
            }
        },
    }
}

/// Emulate EL1 system register reads from userspace (MRS emulation).
/// ARM64 traps MRS of EL1 registers from EL0 as EC=0 (Unknown).
/// Linux emulates these for CPU feature detection (MIDR_EL1, ID_AA64*).
/// Returns true if emulated successfully, false otherwise.
fn emulateMrs(frame: *TrapFrame) bool {
    // Read the faulting instruction from user memory
    const insn_addr = frame.elr;
    const phys = (vmm.translate(
        vmm.PhysAddr.from(if (scheduler.currentProcess()) |p| p.page_table else return false),
        vmm.VirtAddr.from(insn_addr),
    ) orelse return false).toInt();
    const insn_ptr: *const u32 = @ptrFromInt(phys);
    const insn = insn_ptr.*;

    // MRS instruction encoding: 1101 0101 0011 .... .... .... .... ....
    // Bits [31:20] = 0xD53 identifies MRS
    if ((insn >> 20) != 0xD53) return false;

    const rt: u5 = @truncate(insn); // destination register (bits 4:0)
    // Extract system register encoding: op0(2):op1(3):CRn(4):CRm(4):op2(3)
    const sysreg = (insn >> 5) & 0x7FFF;

    // Read the system register value from EL1
    const value: u64 = switch (sysreg) {
        // MIDR_EL1 (op0=3, op1=0, CRn=0, CRm=0, op2=0)
        0x4000 => asm volatile ("mrs %[ret], MIDR_EL1" : [ret] "=r" (-> u64)),
        // REVIDR_EL1 (op0=3, op1=0, CRn=0, CRm=0, op2=6)
        0x4006 => asm volatile ("mrs %[ret], REVIDR_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64PFR0_EL1 (op0=3, op1=0, CRn=0, CRm=4, op2=0)
        0x4020 => asm volatile ("mrs %[ret], ID_AA64PFR0_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64PFR1_EL1 (op0=3, op1=0, CRn=0, CRm=4, op2=1)
        0x4021 => asm volatile ("mrs %[ret], ID_AA64PFR1_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64DFR0_EL1 (op0=3, op1=0, CRn=0, CRm=5, op2=0)
        0x4028 => asm volatile ("mrs %[ret], ID_AA64DFR0_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64DFR1_EL1 (op0=3, op1=0, CRn=0, CRm=5, op2=1)
        0x4029 => asm volatile ("mrs %[ret], ID_AA64DFR1_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64ISAR0_EL1 (op0=3, op1=0, CRn=0, CRm=6, op2=0)
        0x4030 => asm volatile ("mrs %[ret], ID_AA64ISAR0_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64ISAR1_EL1 (op0=3, op1=0, CRn=0, CRm=6, op2=1)
        0x4031 => asm volatile ("mrs %[ret], ID_AA64ISAR1_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64MMFR0_EL1 (op0=3, op1=0, CRn=0, CRm=7, op2=0)
        0x4038 => asm volatile ("mrs %[ret], ID_AA64MMFR0_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64MMFR1_EL1 (op0=3, op1=0, CRn=0, CRm=7, op2=1)
        0x4039 => asm volatile ("mrs %[ret], ID_AA64MMFR1_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64MMFR2_EL1 (op0=3, op1=0, CRn=0, CRm=7, op2=2)
        0x403A => asm volatile ("mrs %[ret], ID_AA64MMFR2_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64ISAR2_EL1 (op0=3, op1=0, CRn=0, CRm=6, op2=2)
        0x4032 => asm volatile ("mrs %[ret], ID_AA64ISAR2_EL1" : [ret] "=r" (-> u64)),
        // ID_AA64ZFR0_EL1 (SVE features) — return 0 if SVE not supported
        0x4024 => 0,
        // CLIDR_EL1 (Cache Level ID Register) (op0=3, op1=1, CRn=0, CRm=0, op2=1)
        0x6001 => asm volatile ("mrs %[ret], CLIDR_EL1" : [ret] "=r" (-> u64)),
        // CTR_EL0 — usually readable from EL0, but handle it anyway
        0x6801 => asm volatile ("mrs %[ret], CTR_EL0" : [ret] "=r" (-> u64)),
        // DCZID_EL0
        0x6807 => asm volatile ("mrs %[ret], DCZID_EL0" : [ret] "=r" (-> u64)),
        // Unknown register — return 0 (safe default)
        else => 0,
    };

    // Write value to destination register (XZR write is discarded)
    if (rt < 31) {
        frame.x[rt] = value;
    }

    // Advance past the MRS instruction
    frame.elr += 4;
    return true;
}

export fn handleIrqException(frame: *TrapFrame) void {
    ringRecordEntry(frame, 1); // 1 = irq entry
    gic.handleIrqWithFrame(frame);

    // If the current process was killed while in kernel mode (e.g., by
    // killThreadGroup on another CPU), the SGI handler's timerTick call
    // cannot preempt kernel code. Catch it here: before returning from
    // the IRQ, if our process has the `killed` flag set, force a context
    // switch. We check `killed` rather than `.zombie` state because a
    // mid-syscall thread may have overwritten zombie with a blocked state.
    const cpu = @import("smp.zig").current();
    if (cpu.current_process) |proc| {
        if (proc.killed or proc.state == .zombie) {
            proc.state = .zombie;
            scheduler.schedule(frame);
            return;
        }
    }

    // Check for pending signals when returning to userspace from IRQ
    signal.checkAndDeliver(frame);
}

/// Handle page fault from lower EL (user mode).
/// Checks VMA list to decide: allocate demand page, or kill process.
fn handlePageFault(frame: *TrapFrame, is_instruction: bool) void {
    const far = getFaultAddress();
    const esr = getEsr();

    // Extract ISS (Instruction Specific Syndrome) bits
    const iss = esr & 0x1FFFFFF;
    const dfsc = iss & 0x3F; // Data Fault Status Code

    // Permission fault codes: level 0-3 = 0b001100 to 0b001111
    const is_permission_fault = (dfsc >= 12 and dfsc <= 15);

    const proc = scheduler.currentProcess() orelse {
        uart.print("[fault] FATAL: Page fault with no process! FAR={x} ESR={x} ELR={x} DFSC={x}\n", .{ far, esr, asm volatile ("mrs %[ret], ELR_EL1" : [ret] "=r" (-> u64)), dfsc });
        uart.print("  SP={x} LR={x}\n", .{ frame.sp, frame.x[30] });
        while (true) asm volatile ("wfi");
    };

    // Page-align the faulting address
    const page_addr = far & ~@as(u64, 0xFFF);

    // Look up VMA
    const vp = process.getVmaOwner(proc);
    const found_vma = vma.findVma(&vp.vmas, far);
    if (found_vma == null) {
        // No VMA covers this address — fatal: kill the process directly.
        // Cannot rely on signal delivery because sig_mask may block SIGSEGV
        // (inherited from parent via fork, e.g. Zig compiler thread pool).
        var vma_count: usize = 0;
        for (0..vma.MAX_VMAS) |vi| {
            if (vp.vmas[vi].in_use) vma_count += 1;
        }
        uart.print("[fault] no-VMA P{} addr={x} ELR={x} LR={x} DFSC={} vmas={} SP={x}\n", .{ proc.pid, far, frame.elr, frame.x[30], dfsc, vma_count, frame.sp });
        uart.print("  X0={x} X1={x} X2={x} X3={x} X8={x} SPSR={x}\n", .{ frame.x[0], frame.x[1], frame.x[2], frame.x[3], frame.x[8], frame.spsr });
        // Dump first 5 VMAs for context
        var dumped: usize = 0;
        for (0..vma.MAX_VMAS) |vi| {
            if (vp.vmas[vi].in_use and dumped < 5) {
                const vf = vp.vmas[vi].flags;
                const r: u8 = if (vf.readable) 'R' else '-';
                const w: u8 = if (vf.writable) 'W' else '-';
                const x: u8 = if (vf.executable) 'X' else '-';
                const fb: u8 = if (vf.file_backed) 'F' else 'A';
                uart.print("  VMA[{}]: {x}-{x} ", .{ vi, vp.vmas[vi].start, vp.vmas[vi].end });
                uart.writeByte(r);
                uart.writeByte(w);
                uart.writeByte(x);
                uart.writeByte(fb);
                uart.writeByte('\n');
                dumped += 1;
            }
        }
        // Dump last 32 syscalls for debugging
        syscall.dumpTrace(64);
        // Kill process AND its entire thread group (threads may hold pipe FDs
        // that block the parent forever if not closed).
        syscall.killThreadGroup(proc, 128 + @as(u64, signal.SIGSEGV));
        scheduler.schedule(frame);
        return;
    }

    const v = found_vma.?;

    // --- Guard page check: bottom page(s) of stack VMA are reserved ---
    // Fault in guard region → SIGSEGV (stack overflow)
    if (v.guard_pages > 0) {
        const guard_limit = v.start + @as(u64, v.guard_pages) * pmm.PAGE_SIZE;
        if (far < guard_limit) {
            uart.print("[guard] Stack overflow P{} addr=0x{x} guard=0x{x}-0x{x}\n", .{ proc.pid, far, v.start, guard_limit });
            signal.postSignal(proc, signal.SIGSEGV);
            signal.checkAndDeliver(frame);
            return;
        }
    }

    // --- PROT_NONE enforcement: if VMA has no permissions, SIGSEGV ---
    if (!v.flags.readable and !v.flags.writable and !v.flags.executable) {
        uart.print("[fault] PROT_NONE P{} addr={x} ELR={x} vma={x}-{x} heap={x}-{x}\n", .{ proc.pid, far, frame.elr, v.start, v.end, vp.heap_start, vp.heap_current });
        signal.postSignal(proc, signal.SIGSEGV);
        signal.checkAndDeliver(frame);
        return;
    }

    // --- CoW fault: permission fault on a user page with PTE_COW ---
    if (is_permission_fault) {
        const pte = vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page_addr));
        if (pte != null and pte.?.isCow()) {
            vmm.handleCowFault(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page_addr)) catch {
                uart.writeString("[fault] CoW OOM PID ");
                uart.writeDec(proc.pid);
                uart.writeString("\n");
                proc.state = .zombie;
                proc.exit_status = 137;
                scheduler.schedule(frame);
                return;
            };
            // ICache coherency: if this was an instruction fetch on a CoW page
            // that was copied (ref > 1 path in handleCowFault), the new physical
            // page's data may not be in the ICache. syncCodePage ensures
            // DCache→memory and ICache invalidation for the user VA.
            if (is_instruction) {
                if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page_addr))) |resolved_pte| {
                    vmm.syncCodePage(vmm.PhysAddr.from(resolved_pte.getPhysAddr()), vmm.VirtAddr.from(page_addr));
                }
            }
            return;
        }

        // Permission fault on a non-user PTE or block descriptor overlapping a user VMA:
        // stale kernel mapping from splitL2Block or unsplit L1 block descriptor.
        // pte == null means a block descriptor at L1/L2 level (getPTE only returns L3 entries).
        // pte != null && !isUser() means a stale kernel L3 entry from splitL2Block.
        // Both cases fall through to demand paging below.
        if (pte != null and pte.?.isUser()) {
            // PTE is user but CPU faulted — check if PTE actually forbids this access.
            // On ARM64, stale TLB entries (from break-before-make races or delayed
            // invalidation) can cause spurious permission faults. If the PTE allows
            // the access, flush TLB and retry instead of killing the process.
            const raw = pte.?.raw;
            const pte_has_uxn = (raw & vmm.ATTR_UXN) != 0;
            const pte_is_readonly = (raw & vmm.ATTR_AP_RO) != 0;
            const is_write = !is_instruction and ((iss >> 6) & 1) != 0;

            const genuine_violation =
                (is_instruction and pte_has_uxn) or // exec on non-exec page
                (is_write and pte_is_readonly); // write on read-only page

            if (genuine_violation) {
                uart.writeString("[fault] Permission fault PID ");
                uart.writeDec(proc.pid);
                uart.writeString(" at ");
                uart.writeHex(far);
                uart.writeString(" (");
                if (is_instruction) {
                    uart.writeString("ifetch, UXN=1");
                } else if (is_write) {
                    uart.writeString("write, RO");
                } else {
                    uart.writeString("read?");
                }
                uart.writeString(")\n");
                proc.state = .zombie;
                proc.exit_status = 139;
                scheduler.schedule(frame);
                return;
            }

            // PTE allows this access — spurious fault from stale TLB.
            // Flush and retry.
            vmm.invalidatePage(vmm.VirtAddr.from(page_addr));
            return;
        }
    }

    // Alignment fault (DFSC=33) on a valid user page is a genuine hardware fault,
    // not a demand paging request. Deliver SIGBUS. Only fall through to demand paging
    // if the PTE is stale (non-user or block descriptor that needs splitting).
    const is_alignment_fault = (dfsc == 33);
    if (is_alignment_fault) {
        if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page_addr))) |pte| {
            if (pte.isUser()) {
                signal.postSignal(proc, signal.SIGBUS);
                signal.checkAndDeliver(frame);
                return;
            }
        }
    }

    // --- Demand paging ---
    // Any fault on a valid VMA that wasn't a genuine user-page permission violation
    // or CoW fault needs demand paging. This covers:
    //   - Translation faults (4-7): unmapped page
    //   - Permission faults (12-15): non-user PTE from stale kernel block descriptors
    //   - Alignment faults (33): stale kernel L2 block descriptors (hardware may report
    //     alignment instead of permission when the L2 block has wrong attributes)
    //   - Access flag faults (8-11): PTE without AF bit
    // The mapPage() call will split block descriptors and create proper user L3 entries.
    //
    // SMP safety: The vma_lock serializes demand paging per-address-space. Without this,
    // CLONE_VM siblings can race on the same fault, corrupt page tables, and leak pages.
    {
        // Diagnostic: trace first few demand page faults for PID >= 6
        const dp_trace = struct {
            var count: u32 = 0;
        };
        if (proc.pid >= 6 and dp_trace.count < 20) {
            dp_trace.count += 1;
            uart.print("[dp] P{} fault #{} addr={x} ELR={x} ifetch={}\n", .{ proc.pid, dp_trace.count, far, frame.elr, @as(u8, if (is_instruction) 1 else 0) });
        }

        // --- Phase 1: Read VMA info under lock, then release ---
        // We must NOT hold vma_lock during file I/O (ext2 read acquires ext2_lock).
        // Holding vma_lock + ext2_lock causes ABBA deadlock when another CPU does
        // ext2 write (holds ext2_lock) and then page faults (needs vma_lock).
        vp.vma_lock.acquire();

        // Under lock: check if another CPU already mapped this page
        if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page_addr))) |pte| {
            if (pte.isUser()) {
                vp.vma_lock.release();
                vmm.invalidatePage(vmm.VirtAddr.from(page_addr));
                return;
            }
        }

        // Re-lookup VMA under lock to get stable VMA data.
        const vl = vma.findVma(&vp.vmas, far) orelse {
            vp.vma_lock.release();
            proc.state = .zombie;
            proc.exit_status = 128 + @as(u64, signal.SIGSEGV);
            if (proc.parent_pid != 0) {
                if (process.findByPid(proc.parent_pid)) |parent| {
                    if (parent.state == .blocked_on_wait) {
                        scheduler.wakeProcess(parent.pid);
                    }
                }
            }
            scheduler.schedule(frame);
            return;
        };

        // Snapshot VMA fields we need — VMA may change after we release the lock.
        const vma_file = vl.file;
        const vma_start = vl.start;
        const vma_file_offset = vl.file_offset;
        const vma_file_size = vl.file_size;
        const vma_file_ino = vl.file_ino; // Stable inode number for re-resolution
        const map_user = vl.flags.user;
        const map_writable = vl.flags.writable;
        const map_executable = vl.flags.executable;

        // Release vma_lock BEFORE file I/O to prevent ext2_lock deadlock.
        vp.vma_lock.release();

        // --- Phase 2: Allocate page and read file data (NO vma_lock held) ---
        const page = pmm.allocPage() orelse {
            uart.writeString("[fault] OOM during demand page\n");
            proc.state = .zombie;
            proc.exit_status = 137;
            scheduler.schedule(frame);
            return;
        };

        // Zero the page first (covers anonymous VMAs and BSS regions)
        const ptr: [*]u8 = @ptrFromInt(page);
        for (0..4096) |zi| {
            ptr[zi] = 0;
        }

        // If file-backed VMA, read file data into the page
        if (vma_file) |_| {
            // Handle non-page-aligned VMA start. When vma_start is e.g. 0x1800,
            // a fault on that address gives page_addr=0x1000 (page-aligned down).
            // The first page needs: bytes 0x000-0x7FF zeroed, bytes 0x800-0xFFF
            // filled from file at vma_file_offset. Subsequent pages use the normal
            // (page_addr - vma_start) offset calculation.
            const skip: usize = if (page_addr < vma_start)
                @truncate(vma_start - page_addr) // bytes to skip (stay zeroed)
            else
                0;
            const page_offset_in_vma = if (page_addr >= vma_start)
                page_addr - vma_start
            else
                0; // first partial page: file data starts at vma_file_offset

            // BSS awareness: only read if within file_size range
            const should_read = if (vma_file_size > 0)
                page_offset_in_vma < vma_file_size
            else
                true;

            if (should_read) {
                // Recovery handler pattern (Chaos Rocket / Ariane 5 safety):
                // On ANY file I/O failure during demand paging, map a zero page
                // instead of killing the process. The page is already zeroed.
                // The process may crash on its own terms (SIGBUS/SIGSEGV from
                // bad data), but the kernel stays stable and other processes
                // keep running. This is what Linux does for I/O errors.
                const ext2_mod = @import("ext2.zig");
                const ino: u32 = vma_file_ino;

                // Validate-before-use: ALWAYS re-resolve via loadInode().
                // Recovery: if inode can't be resolved, map zero page.
                const maybe_inode = if (ino > 0) ext2_mod.loadInode(ino) else null;
                if (maybe_inode == null and ino > 0) {
                    uart.writeString("[fault] RECOVER: inode re-resolve failed ino=");
                    uart.writeDec(ino);
                    uart.writeString(" — mapping zero page\n");
                }

                if (maybe_inode) |inode| {
                    const file_pos = vma_file_offset + page_offset_in_vma;
                    const pg_index: u32 = @truncate(file_pos / 4096);

                    // Check page cache first (lookup pins the page via incRef).
                    // Skip cache for partial first page (skip>0) — the file offset
                    // may not be page-aligned, so pg_index wouldn't match correctly.
                    const cached = if (skip == 0) page_cache.lookup(ino, pg_index) else null;
                    if (cached) |cached_phys| {
                        const src: [*]const u8 = @ptrFromInt(cached_phys);
                        for (0..4096) |i| {
                            ptr[i] = src[i];
                        }
                        page_cache.release(cached_phys);
                    } else if (inode.ops.read) |read_fn| {
                        // Max bytes to read: full page minus skip (partial first page).
                        const max_read: usize = 4096 - skip;

                        // For BSS-aware VMAs, limit read to file_size boundary
                        const read_len: usize = if (vma_file_size > 0) blk: {
                            const remaining_file = if (vma_file_size > page_offset_in_vma) vma_file_size - page_offset_in_vma else 0;
                            break :blk if (remaining_file < max_read) @as(usize, @truncate(remaining_file)) else max_read;
                        } else max_read;

                        var tmp_desc = vfs.FileDescription{
                            .inode = inode,
                            .offset = file_pos,
                            .flags = vfs.O_RDONLY,
                            .ref_count = 1,
                            .in_use = true,
                        };

                        // Retry reads on virtio/NVMe timeout.
                        var read_ok = false;
                        var bytes_read: usize = 0;
                        var retries: u32 = 0;
                        while (retries < 3) : (retries += 1) {
                            tmp_desc.offset = file_pos;
                            const n = read_fn(&tmp_desc, ptr + skip, read_len);
                            if (n > 0) {
                                read_ok = true;
                                bytes_read = @intCast(n);
                                break;
                            }
                            uart.print("[fault] read retry {}/3 ino={} pg={} P{}\n", .{ retries + 1, ino, pg_index, proc.pid });
                        }
                        if (!read_ok) {
                            // Recovery: map zero page instead of killing.
                            // Process gets zeroed data — may SIGBUS on its own terms.
                            uart.print("[fault] RECOVER: read failed ino={} pg={} P{} — zero page\n", .{ ino, pg_index, proc.pid });
                        }

                        // Only cache full, successful reads.
                        if (read_ok and skip == 0 and bytes_read >= read_len) {
                            page_cache.insert(ino, pg_index, page);
                        }
                    }
                    // No read function → zero page is already correct (BSS-like)
                }
                // Inode resolution failed → zero page mapped (recovery above)
            }
        }

        // --- Phase 3: Re-acquire vma_lock and install PTE ---
        vp.vma_lock.acquire();

        // Re-check: another CPU may have mapped this page while we were reading
        if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page_addr))) |pte| {
            if (pte.isUser()) {
                vp.vma_lock.release();
                pmm.freePage(page);
                vmm.invalidatePage(vmm.VirtAddr.from(page_addr));
                return;
            }
        }

        // Map with VMA permissions (overwrites any stale kernel L3 entry)
        vmm.mapPage(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page_addr), vmm.PhysAddr.from(page), .{
            .user = map_user,
            .writable = map_writable,
            .executable = map_executable,
        }) catch {
            pmm.freePage(page);
            vp.vma_lock.release();
            uart.writeString("[fault] Failed to map demand page\n");
            proc.state = .zombie;
            proc.exit_status = 137;
            scheduler.schedule(frame);
            return;
        };

        vp.vma_lock.release();

        // Invalidate any stale TLB entry for this VA (needed when overwriting
        // a valid kernel L3 entry with a user page)
        vmm.invalidatePage(vmm.VirtAddr.from(page_addr));

        // ARM64 ICache is NOT coherent with DCache. After writing code data
        // to a page, we must clean DCache and invalidate ICache so all CPUs
        // fetch correct instructions. Without this, SMP causes wild branches.
        if (map_executable) {
            vmm.syncCodePage(vmm.PhysAddr.from(page), vmm.VirtAddr.from(page_addr));
        }

        // Fault resolved — return to user and retry the instruction
        return;
    }
}

/// Kernel-callable demand paging for user addresses.
/// Called from sysWrite/sysRead when vmm.translate fails for a user buffer page.
/// Checks VMAs and maps the page if it's a valid demand-page address.
/// Returns true if the page was successfully mapped.
pub fn demandPageUser(addr: u64) bool {
    const proc = scheduler.currentProcess() orelse return false;
    const vp = process.getVmaOwner(proc);

    vp.vma_lock.acquire();
    defer vp.vma_lock.release();

    const page_addr = addr & ~@as(u64, 0xFFF);
    const v = vma.findVma(&vp.vmas, addr) orelse return false;

    // Check if another thread already mapped this page while we waited for the lock
    if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page_addr))) |pte| {
        if (pte.isValid() and pte.isUser()) return true;
    }

    const page = pmm.allocPage() orelse return false;

    // Zero the page (covers anonymous VMAs and BSS regions)
    const ptr: [*]u8 = @ptrFromInt(page);
    for (0..4096) |i| {
        ptr[i] = 0;
    }

    // If file-backed VMA, read file data into the page
    if (v.file) |_| {
        const page_offset_in_vma = page_addr - v.start;

        // BSS awareness: only read if within file_size range
        const should_read = if (v.file_size > 0)
            page_offset_in_vma < v.file_size
        else
            true;

        if (should_read) {
            const ino: u32 = v.file_ino;
            const file_pos = v.file_offset + page_offset_in_vma;
            const pg_index: u32 = @truncate(file_pos / 4096);

            // Check page cache first (lookup pins the page via incRef)
            if (page_cache.lookup(ino, pg_index)) |cached_phys| {
                const src: [*]const u8 = @ptrFromInt(cached_phys);
                for (0..4096) |i| {
                    ptr[i] = src[i];
                }
                page_cache.release(cached_phys);
            } else {
                // Validate-before-use (Chaos Rocket safety): always re-resolve
                // via loadInode to ensure cache entry is fresh.
                const ext2_mod = @import("ext2.zig");
                const inode = if (ino > 0) ext2_mod.loadInode(ino) orelse {
                    pmm.freePage(page);
                    return false;
                } else {
                    pmm.freePage(page);
                    return false;
                };
                const read_fn = inode.ops.read orelse {
                    pmm.freePage(page);
                    return false;
                };

                const read_len: usize = if (v.file_size > 0) blk: {
                    const remaining_file = if (v.file_size > page_offset_in_vma) v.file_size - page_offset_in_vma else 0;
                    break :blk if (remaining_file < 4096) @as(usize, @truncate(remaining_file)) else 4096;
                } else 4096;

                var tmp_desc = vfs.FileDescription{
                    .inode = inode,
                    .offset = file_pos,
                    .flags = vfs.O_RDONLY,
                    .ref_count = 1,
                    .in_use = true,
                };
                _ = read_fn(&tmp_desc, ptr, read_len);

                // Insert into page cache for future faults
                page_cache.insert(ino, pg_index, page);
            }
        }
    }

    // Map with VMA permissions (overwrites any stale kernel L3 entry)
    vmm.mapPage(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page_addr), vmm.PhysAddr.from(page), .{
        .user = v.flags.user,
        .writable = v.flags.writable,
        .executable = v.flags.executable,
    }) catch {
        pmm.freePage(page);
        return false;
    };

    vmm.invalidatePage(vmm.VirtAddr.from(page_addr));

    // ICache coherency for executable demand-paged pages (SMP safety)
    if (v.flags.executable) {
        vmm.syncCodePage(vmm.PhysAddr.from(page), vmm.VirtAddr.from(page_addr));
    }

    return true;
}

fn getEsr() u64 {
    return asm volatile ("mrs %[ret], ESR_EL1"
        : [ret] "=r" (-> u64),
    );
}
