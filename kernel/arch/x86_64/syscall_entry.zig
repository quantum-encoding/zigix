/// syscall instruction support — MSR configuration and entry point.
///
/// The `syscall` instruction (used by musl/glibc on x86_64) transfers to
/// kernel mode via LSTAR instead of the IDT. We push a fake int 0x80 frame
/// and jump to commonStub to reuse all existing infrastructure.
///
/// SMP: User RSP and kernel RSP are stored per-CPU in CpuLocal via GS_BASE.
/// CpuLocal.kernel_stack_top (offset 16): current process's kernel stack
/// CpuLocal.scratch_rsp (offset 24): scratch space for saving user RSP
///
/// GS_BASE always points to CpuLocal (user processes use FS for TLS, not GS).

const idt = @import("idt.zig");
const serial = @import("serial.zig");
const smp = @import("smp.zig");

// MSR addresses
const IA32_EFER: u32 = 0xC0000080;
const IA32_STAR: u32 = 0xC0000081;
const IA32_LSTAR: u32 = 0xC0000082;
const IA32_SFMASK: u32 = 0xC0000084;

fn wrmsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [_] "{ecx}" (msr),
          [_] "{eax}" (low),
          [_] "{edx}" (high),
    );
}

fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
        : [_] "{ecx}" (msr),
    );
    return @as(u64, high) << 32 | low;
}

pub fn wrmsrPub(msr: u32, value: u64) void {
    wrmsr(msr, value);
}

/// Naked entry point for the `syscall` instruction.
/// CPU state on entry: RCX = user RIP, R11 = user RFLAGS, RIP = LSTAR.
/// GS_BASE = CpuLocal pointer (never swapped — user doesn't use GS).
export fn syscallEntry() callconv(.naked) void {
    // CpuLocal offsets computed from @offsetOf — Zig reorders struct fields!
    // Use comptime string building to embed the numeric offsets into the asm.
    const smp_mod = @import("smp.zig");
    comptime {
        // Verify offsets are within GS segment displacement range
        if (smp_mod.KSTACK_OFFSET > 65535) @compileError("KSTACK_OFFSET too large for GS displacement");
        if (smp_mod.SCRATCH_OFFSET > 65535) @compileError("SCRATCH_OFFSET too large for GS displacement");
    }
    const kstack_str = comptime std.fmt.comptimePrint("{d}", .{smp_mod.KSTACK_OFFSET});
    const scratch_str = comptime std.fmt.comptimePrint("{d}", .{smp_mod.SCRATCH_OFFSET});

    asm volatile (
        // Save user RSP to per-CPU scratch, load kernel RSP from per-CPU data
        "movq %%rsp, %%gs:" ++ scratch_str ++ "\n" ++
        "movq %%gs:" ++ kstack_str ++ ", %%rsp\n" ++
        // Push iretq frame: SS, RSP, RFLAGS, CS, RIP
        "pushq $0x23\n" ++
        "pushq %%gs:" ++ scratch_str ++ "\n" ++
        "pushq %%r11\n" ++
        "pushq $0x1b\n" ++
        "pushq %%rcx\n" ++
        // Push vector=0x80 and error_code=0 (matches int 0x80 stub format)
        "pushq $0\n" ++
        "pushq $0x80\n" ++
        // Jump to common register save + dispatch + iretq
        "jmp commonStub\n"
    );
}

const std = @import("std");

/// Get the LSTAR value (syscallEntry address) for AP MSR configuration.
pub fn getLstarAddr() u64 {
    return @intFromPtr(&syscallEntry);
}

pub fn init() void {
    // Enable SCE (System Call Extensions) in EFER
    const efer = rdmsr(IA32_EFER);
    wrmsr(IA32_EFER, efer | 1); // Set bit 0 (SCE)

    // STAR: kernel CS/SS in bits [47:32], user CS/SS in bits [63:48]
    const star: u64 = (@as(u64, 0x08) << 32) | (@as(u64, 0x10) << 48);
    wrmsr(IA32_STAR, star);

    // LSTAR: target RIP for syscall instruction
    const entry_addr: u64 = @intFromPtr(&syscallEntry);
    wrmsr(IA32_LSTAR, entry_addr);

    // SFMASK: bits to clear in RFLAGS on syscall entry
    // Clear IF (bit 9) so interrupts are disabled on entry
    wrmsr(IA32_SFMASK, 0x200);

    serial.writeString("[cpu]  syscall MSRs configured (LSTAR set)\n");
}
