/// RISC-V SMP (Symmetric Multi-Processing) support.
///
/// Minimal single-hart implementation for now. Per-CPU state management
/// with a static array indexed by hart ID. On RISC-V, the hart ID is
/// obtained from sscratch or a dedicated CSR; for single-hart we always
/// return hart 0.

const std = @import("std");
const uart = @import("uart.zig");
const process = @import("process.zig");

pub const MAX_CPUS: u32 = 4;

/// Per-CPU data structure. One instance per hart.
pub const PerCpu = struct {
    cpu_id: u32 = 0,
    current_process: ?*process.Process = null,
    current_idx: usize = NO_PROCESS,
    slice_remaining: u64 = 10, // TIMESLICE_TICKS default
    idle: bool = true,
    dedicated_pid: u64 = 0,
    kernel_stack_top: u64 = 0,

    pub const NO_PROCESS: usize = std.math.maxInt(usize);
};

pub var per_cpu_data: [MAX_CPUS]PerCpu = [_]PerCpu{.{}} ** MAX_CPUS;
pub var online_cpus: u32 = 1;

/// Initialize BSP (hart 0) per-CPU data. Call once from boot.zig.
pub fn initBsp() void {
    per_cpu_data[0].cpu_id = 0;
    per_cpu_data[0].idle = true;

    // Set kernel_stack_top to current stack pointer so timer IRQ
    // has a valid kernel SP before the scheduler starts a process.
    per_cpu_data[0].kernel_stack_top = asm volatile ("mv %[sp], sp"
        : [sp] "=r" (-> u64),
    );

    uart.writeString("[smp]  BSP (hart 0) per-CPU state initialized\n");
}

/// Get current hart's PerCpu data.
/// Single-hart for now: always returns hart 0.
pub inline fn current() *PerCpu {
    return &per_cpu_data[0];
}

/// Get current hart ID.
pub inline fn cpuId() u32 {
    return current().cpu_id;
}
