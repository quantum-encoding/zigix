/// Task State Segment — required for ring 3 → ring 0 transitions.
/// When an interrupt fires in user mode, the CPU reads RSP0 from the TSS
/// to find the kernel stack pointer for the privilege-level switch.
///
/// SMP: Each CPU has its own TSS (per_cpu_tss in gdt.zig for APs,
/// global tss for BSP). setRsp0 updates the correct TSS based on cpu_id.

const serial = @import("serial.zig");
const types = @import("../../types.zig");
const smp = @import("smp.zig");
const gdt = @import("gdt.zig");

/// x86_64 TSS (104 bytes). Only RSP0 is used.
pub const TSS = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 align(4) = 0,
    rsp1: u64 align(4) = 0,
    rsp2: u64 align(4) = 0,
    reserved1: u64 align(4) = 0,
    ist1: u64 align(4) = 0,
    ist2: u64 align(4) = 0,
    ist3: u64 align(4) = 0,
    ist4: u64 align(4) = 0,
    ist5: u64 align(4) = 0,
    ist6: u64 align(4) = 0,
    ist7: u64 align(4) = 0,
    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    iopb_offset: u16 = @sizeOf(TSS), // Past end = no I/O permission bitmap
};

comptime {
    if (@sizeOf(TSS) != 104) @compileError("TSS must be exactly 104 bytes");
}

/// BSP's TSS (loaded by gdt.loadTss during init)
var tss: TSS = .{};

/// Dedicated stack for IST1 (double fault handler).
/// 4 KiB, separate from any process kernel stack, so #DF always has a valid stack.
var ist1_stack: [4096]u8 align(16) = [_]u8{0} ** 4096;

/// Initialize IST1 in the BSP's TSS. Called after TSS is loaded.
pub fn initIst() void {
    tss.ist1 = @intFromPtr(&ist1_stack) + ist1_stack.len;
    serial.writeString("[tss]  IST1 set for double fault handler\n");
}

/// Set RSP0 for the current CPU's TSS and update CpuLocal.kernel_stack_top.
/// Called on every context switch so the CPU uses the correct kernel stack
/// when transitioning from ring 3 to ring 0.
pub fn setRsp0(rsp0: u64) void {
    const cpu = smp.current();
    // Update CpuLocal so syscall entry (via %gs:16) picks up the right stack
    cpu.kernel_stack_top = rsp0;

    // Update the TSS for this CPU
    if (cpu.cpu_id == 0) {
        tss.rsp0 = rsp0;
    } else {
        gdt.per_cpu_tss[cpu.cpu_id].rsp0 = rsp0;
    }
}

/// Debug: verify CpuLocal.kernel_stack_top hasn't been corrupted.
/// Called from timer tick to catch corruption early.
pub fn checkKstackIntegrity() void {
    const cpu = smp.current();
    if (cpu.cpu_id == 0 and cpu.kernel_stack_top == 0 and tss.rsp0 != 0) {
        serial.writeString("\n!!! KSTACK CORRUPT: gs:16=0 tss.rsp0=0x");
        var hex_buf: [16]u8 = undefined;
        var v = tss.rsp0;
        var i: usize = 16;
        while (i > 0) {
            i -= 1;
            hex_buf[i] = "0123456789abcdef"[@as(usize, @truncate(v & 0xf))];
            v >>= 4;
        }
        serial.writeString(&hex_buf);
        // Fix it immediately to prevent triple fault
        cpu.kernel_stack_top = tss.rsp0;
        serial.writeString(" FIXED!\n");
    }
}

pub fn getRsp0() u64 {
    return tss.rsp0;
}

pub fn getTssPtr() *TSS {
    return &tss;
}
