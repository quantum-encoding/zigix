/// ARM64 SMP (Symmetric Multi-Processing) support.
///
/// Per-CPU state management, secondary CPU boot via PSCI,
/// and CPU-local data accessed through TPIDR_EL1.
///
/// QEMU virt uses PSCI with HVC conduit for CPU_ON.

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const gic = @import("gic.zig");
const timer = @import("timer.zig");
const exception = @import("exception.zig");
const scheduler = @import("scheduler.zig");
const fdt = @import("fdt.zig");
const boot = @import("boot.zig");

pub const MAX_CPUS: u32 = 4;
pub const SMP_CPUS: u32 = 2; // Default for QEMU virt; override from FDT

/// Boot context passed to secondary CPUs through PSCI context_id.
/// Stored at a known address readable by secondary before MMU is on.
/// All addresses are physical (identity-mapped after MMU enable).
const SecondaryBootContext = struct {
    ttbr0: u64,         // offset 0:  kernel L0 page table physical address
    stack_top: u64,     // offset 8:  kernel stack top for this CPU
    percpu_ptr: u64,    // offset 16: pointer to PerCpu struct
    vbar: u64,          // offset 24: VBAR_EL1 value (exception vector table)
};

/// One boot context per secondary CPU (CPU 1-3).
var boot_contexts: [MAX_CPUS]SecondaryBootContext = [_]SecondaryBootContext{.{
    .ttbr0 = 0,
    .stack_top = 0,
    .percpu_ptr = 0,
    .vbar = 0,
}} ** MAX_CPUS;

/// Per-CPU data structure. One instance per physical CPU.
/// Accessed via TPIDR_EL1 for O(1) current-CPU lookup.
pub const PerCpu = extern struct {
    cpu_id: u32 = 0,
    _pad0: u32 = 0,
    kernel_stack_top: u64 = 0, // offset 8
    scratch_x0: u64 = 0, // offset 16 — exception vector scratch
    scratch_x1: u64 = 0, // offset 24 — exception vector scratch
    current_process: ?*@import("process.zig").Process = null,
    current_idx: usize = NO_PROCESS, // NO_PROCESS = no current process
    slice_remaining: u64 = 10, // TIMESLICE_TICKS default
    timer_ticks: u64 = 0,
    online: bool = false,
    idle: bool = true,
    _pad1: [6]u8 = .{0} ** 6,
    dedicated_pid: u64 = 0,

    pub const NO_PROCESS: usize = @import("std").math.maxInt(usize);
};

// Exception vector uses x18 as PerCpu pointer and hardcoded offsets.
comptime {
    if (@offsetOf(PerCpu, "kernel_stack_top") != 8)
        @compileError("PerCpu.kernel_stack_top must be at offset 8");
    if (@offsetOf(PerCpu, "scratch_x0") != 16)
        @compileError("PerCpu.scratch_x0 must be at offset 16");
    if (@offsetOf(PerCpu, "scratch_x1") != 24)
        @compileError("PerCpu.scratch_x1 must be at offset 24");
}

pub var per_cpu_data: [MAX_CPUS]PerCpu = [_]PerCpu{.{}} ** MAX_CPUS;
pub var online_cpus: u32 = 1;

/// BSP stores kernel TTBR0 here; used to populate boot contexts.
pub var kernel_ttbr0_for_smp: u64 = 0;

/// Atomic flag: secondary sets to 1 when ready, BSP polls for it.
var secondary_ready: u32 = 0;

/// Initialize BSP (CPU 0) per-CPU data. Call once from boot.zig after VMM init.
pub fn initBsp() void {
    per_cpu_data[0].cpu_id = 0;
    per_cpu_data[0].online = true;

    // Set kernel_stack_top to the current BSP boot stack so the exception
    // vector's SP reload is safe even before the scheduler starts a process.
    // Without this, kernel_stack_top=0 and the first timer IRQ would load
    // SP=0 → immediate fault.
    per_cpu_data[0].kernel_stack_top = asm volatile ("mov %[sp], sp"
        : [sp] "=r" (-> u64),
    );

    // Store pointer to CPU 0's PerCpu in TPIDR_EL1.
    const ptr = @intFromPtr(&per_cpu_data[0]);
    asm volatile ("msr TPIDR_EL1, %[val]"
        :
        : [val] "r" (ptr),
    );

    uart.writeString("[smp]  BSP (CPU 0) per-CPU state initialized\n");
}

/// Get current CPU's PerCpu data (read TPIDR_EL1).
pub inline fn current() *PerCpu {
    return @ptrFromInt(asm volatile ("mrs %[ret], TPIDR_EL1"
        : [ret] "=r" (-> usize),
    ));
}

/// Get current CPU ID.
pub inline fn cpuId() u32 {
    return current().cpu_id;
}

/// Boot a secondary CPU using PSCI CPU_ON (HVC conduit).
/// Returns true on success.
pub fn bootSecondary(cpu_id: u32) bool {
    if (cpu_id == 0 or cpu_id >= MAX_CPUS) return false;

    // Allocate 64KB kernel stack for secondary with rowhammer guard pages
    const stack_pages: u64 = 16;
    const stack_phys = pmm.allocPagesGuarded(stack_pages, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        uart.print("[smp]  ERROR: cannot alloc stack for CPU {}\n", .{cpu_id});
        return false;
    };
    const stack_top = stack_phys + stack_pages * pmm.PAGE_SIZE;

    // Write stack canary at the bottom of the per-CPU stack
    const canary_ptr: *u64 = @ptrFromInt(stack_phys);
    canary_ptr.* = pmm.STACK_CANARY;

    // Initialize per-CPU data for this secondary
    per_cpu_data[cpu_id] = .{
        .cpu_id = cpu_id,
        .kernel_stack_top = stack_top,
        .online = false,
        .idle = true,
    };

    // Populate boot context (all physical addresses, readable pre-MMU)
    boot_contexts[cpu_id] = .{
        .ttbr0 = kernel_ttbr0_for_smp,
        .stack_top = stack_top,
        .percpu_ptr = @intFromPtr(&per_cpu_data[cpu_id]),
        .vbar = @intFromPtr(&exception.vector_table),
    };

    uart.print("[smp]  Booting CPU {} (stack at {x})...\n", .{ cpu_id, stack_top });

    // Clear ready flag
    @atomicStore(u32, &secondary_ready, 0, .seq_cst);
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // PSCI CPU_ON
    //   X0 = 0xC4000003 (CPU_ON, SMC64/HVC64)
    //   X1 = target MPIDR (for QEMU virt, MPIDR = cpu_id)
    //   X2 = entry point (physical address of secondary_entry)
    //   X3 = context (pointer to SecondaryBootContext for this CPU)
    const func_id: u64 = 0xC4000003;
    const target_cpu: u64 = cpu_id;
    const entry_addr: u64 = @intFromPtr(&secondary_entry);
    const context: u64 = @intFromPtr(&boot_contexts[cpu_id]);

    const result = psciCall(func_id, target_cpu, entry_addr, context);

    if (result != 0) {
        uart.print("[smp]  PSCI CPU_ON failed for CPU {}: {}\n", .{ cpu_id, result });
        pmm.freePages(stack_phys, stack_pages);
        return false;
    }

    // Wait for secondary to signal ready (with timeout)
    var timeout: u32 = 0;
    while (@atomicLoad(u32, &secondary_ready, .seq_cst) == 0 and timeout < 100_000_000) : (timeout += 1) {
        asm volatile ("yield");
    }

    if (@atomicLoad(u32, &secondary_ready, .seq_cst) == 0) {
        uart.print("[smp]  TIMEOUT waiting for CPU {}\n", .{cpu_id});
        return false;
    }

    online_cpus += 1;
    uart.print("[smp]  CPU {} online ({} CPUs total)\n", .{ cpu_id, online_cpus });
    return true;
}

/// Unified PSCI call — dispatches to HVC or SMC based on FDT config.
/// SMC #0 is encoded as raw .word because the assembler rejects it at EL1.
/// On real hardware (e.g. U-Boot), the kernel runs at EL1 but firmware (EL3)
/// handles the SMC trap. The assembler doesn't know this, so we emit raw bytes.
fn psciCall(func_id: u64, arg1: u64, arg2: u64, arg3: u64) i64 {
    if (fdt.config.psci_conduit == .smc) {
        return asm volatile (
            // SMC #0 = 0xD4000003 (raw encoding to bypass assembler EL check)
            \\.word 0xD4000003
            : [ret] "={x0}" (-> i64),
            : [x0] "{x0}" (func_id),
              [x1] "{x1}" (arg1),
              [x2] "{x2}" (arg2),
              [x3] "{x3}" (arg3),
            : .{ .memory = true }
        );
    } else {
        return asm volatile (
            \\hvc #0
            : [ret] "={x0}" (-> i64),
            : [x0] "{x0}" (func_id),
              [x1] "{x1}" (arg1),
              [x2] "{x2}" (arg2),
              [x3] "{x3}" (arg3),
            : .{ .memory = true }
        );
    }
}

/// Entry point for secondary CPUs (naked — runs with MMU off).
/// X0 = pointer to SecondaryBootContext (from PSCI context_id).
///
/// Boot context layout (all u64):
///   [X0 + 0]  = ttbr0 (kernel page table)
///   [X0 + 8]  = stack_top
///   [X0 + 16] = percpu_ptr
///   [X0 + 24] = vbar
export fn secondary_entry() callconv(.naked) noreturn {
    asm volatile (
        // X0 = pointer to SecondaryBootContext (physical addr, pre-MMU)
        // Save context pointer in x19
        \\mov x19, x0

        // Enable FP/SIMD (CPACR_EL1.FPEN = 0b11)
        \\mov x1, #(3 << 20)
        \\msr CPACR_EL1, x1
        \\isb

        // Set MAIR_EL1: index 0 = Device (0x00), index 1 = Normal WB (0xFF)
        \\mov x1, #0xFF00
        \\msr MAIR_EL1, x1

        // Set TCR_EL1: T0SZ=16, TG0=4KB, SH0=IS, ORGN0=WB, IRGN0=WB, IPS=40-bit
        // Value = 16 | (0b00<<14) | (0b10<<12) | (0b01<<10) | (0b01<<8) | (0b010<<32)
        //       = 0x0000_0002_0000_2510
        \\mov x1, #0x2510
        \\movk x1, #0x2, lsl #32
        \\msr TCR_EL1, x1

        // Load TTBR0 from boot context [x19 + 0]
        \\ldr x1, [x19, #0]
        \\msr TTBR0_EL1, x1

        // Barriers before enabling MMU
        \\dsb sy
        \\isb

        // Enable MMU: set M + C + I bits, clear A bit (alignment checking)
        // Clear SPAN (bit 23) for PAN auto-set on EL0→EL1 exception entry
        \\mrs x1, SCTLR_EL1
        \\orr x1, x1, #(1 << 0)
        \\bic x1, x1, #(1 << 1)
        \\orr x1, x1, #(1 << 2)
        \\orr x1, x1, #(1 << 12)
        \\bic x1, x1, #(1 << 23)
        \\msr SCTLR_EL1, x1
        \\isb

        // Set stack from boot context [x19 + 8]
        \\ldr x1, [x19, #8]
        \\mov sp, x1

        // Load PerCpu pointer from boot context [x19 + 16]
        \\ldr x20, [x19, #16]

        // Set TPIDR_EL1 = PerCpu pointer
        \\msr TPIDR_EL1, x20

        // Install exception vectors from boot context [x19 + 24]
        \\ldr x1, [x19, #24]
        \\msr VBAR_EL1, x1
        \\isb

        // Call secondary_main(PerCpu pointer)
        \\mov x0, x20
        \\bl secondary_main

        // Should not return; halt if it does
        \\1: wfi
        \\b 1b
    );
}

/// High-level secondary CPU initialization (called from secondary_entry after MMU is on).
export fn secondary_main(percpu_ptr: *PerCpu) callconv(.c) void {
    const cpu_features = @import("cpu_features.zig");
    const sve_mod = @import("sve.zig");

    // Verify secondary CPU is compatible with BSP
    cpu_features.probeSecondary(percpu_ptr.cpu_id);

    // Enable PAN on this CPU if BSP detected support
    if (boot.pan_enabled) {
        asm volatile (".inst 0xD500419F"); // MSR PAN, #1
        asm volatile ("isb");
    }

    // Enable SVE on this CPU if BSP detected support
    sve_mod.enableSecondary();

    // Initialize this CPU's GIC interface
    gic.initCpuInterface();

    // Enable timer IRQ on this CPU (PPIs are per-CPU)
    gic.enableIrq(gic.IRQ_TIMER);
    gic.setPriority(gic.IRQ_TIMER, 0);

    // Start this CPU's timer
    timer.initSecondary();

    // Mark online
    percpu_ptr.online = true;

    // Signal BSP that we're ready
    asm volatile ("dsb sy" ::: .{ .memory = true });
    @atomicStore(u32, &secondary_ready, 1, .seq_cst);
    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("sev");

    uart.print("[smp]  CPU {} entering scheduler\n", .{percpu_ptr.cpu_id});

    // Enable interrupts and enter idle loop.
    // Timer ticks will preempt us into ready processes via timerTick.
    asm volatile ("msr DAIFClr, #2");

    while (true) {
        asm volatile ("wfi");
    }
}
