/// Interrupt Descriptor Table — 256 entries with comptime-generated stubs.
/// Exceptions 0-31, IRQs 32-47, remaining reserved.

const std = @import("std");
const serial = @import("serial.zig");
const gdt = @import("gdt.zig");
const pic = @import("pic.zig");
const vmm = @import("../../mm/vmm.zig");
const klog = @import("../../klog/klog.zig");

// --- IDT gate descriptor (16 bytes on x86_64) ---

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8, // bits [2:0] = IST index, rest zero
    type_attr: u8, // P | DPL(2) | 0 | GateType(4)
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

var idt_entries: [256]IdtEntry = undefined;
var idt_ptr: IdtPtr = undefined;

// Static XSAVE buffer for SSE/AVX state save/restore in interrupt handler.
// TODO(SMP Step 3): Replace with per-CPU fxsave via GS_BASE + CpuLocal.fxsave_area
// when swapgs is added to commonStub. Safe for single-CPU (Step 1-2).
export var fxsave_area: [512]u8 align(64) = [_]u8{0} ** 512;

fn makeGate(handler: u64, ist: u3) IdtEntry {
    return .{
        .offset_low = @truncate(handler),
        .selector = gdt.KERNEL_CS & 0xF8, // strip RPL bits
        .ist = ist,
        .type_attr = 0x8E, // P=1, DPL=0, interrupt gate (0xE)
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
    };
}

// --- Interrupt frame passed to Zig handlers ---

pub const InterruptFrame = extern struct {
    // Pushed by common stub (reverse order of push)
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    // Pushed by stub
    vector: u64,
    error_code: u64,

    // Pushed by CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// --- Exception names ---

const exception_names = [32][]const u8{
    "Division Error",
    "Debug",
    "NMI",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection Fault",
    "Page Fault",
    "Reserved",
    "x87 FP Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD FP Exception",
    "Virtualization Exception",
    "Control Protection",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Hypervisor Injection",
    "VMM Communication",
    "Security Exception",
    "Reserved",
};

// Vectors that push an error code
fn hasErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

// --- Comptime stub generation ---
// Each vector gets a tiny naked function that pushes a dummy error code
// (if CPU doesn't push one), pushes the vector number, then jumps to commonStub.
// CRITICAL: naked functions must have exactly ONE asm block — multiple blocks
// are not guaranteed contiguous.

fn makeStub(comptime vector: u8) *const fn () callconv(.naked) void {
    return &struct {
        fn stub() callconv(.naked) void {
            asm volatile (
                (if (!hasErrorCode(vector)) "pushq $0\n" else "") ++
                    "pushq $" ++ std.fmt.comptimePrint("{d}", .{vector}) ++ "\n" ++
                    "jmp commonStub\n"
            );
        }
    }.stub;
}

// Generate all 256 stubs at comptime
const stubs = blk: {
    var s: [256]*const fn () callconv(.naked) void = undefined;
    for (0..256) |i| {
        s[i] = makeStub(i);
    }
    break :blk s;
};

// --- Common stub: save registers, call Zig handler, restore, iretq ---
//
// CRITICAL: Must save SSE/AVX state to prevent kernel handlers from clobbering
// user-mode XMM/YMM registers. Uses static XSAVE buffer (not reentrant for
// nested interrupts, but sufficient since kernel code path is short).

export fn commonStub() callconv(.naked) void {
    const smp_mod = @import("smp.zig");
    const fxoff = comptime smp_mod.FXSAVE_OFFSET;
    asm volatile (
        // Save all general-purpose registers
        \\pushq %%rax
        \\pushq %%rbx
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%rbp
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        // Save SSE state to per-CPU fxsave area.
        // Read GS_BASE via rdmsr (regs already saved), add fxsave offset.
        \\movl $0xC0000101, %%ecx
        \\rdmsr
        \\shlq $32, %%rdx
        \\orq %%rdx, %%rax
        \\addq %[fxoff], %%rax
        \\fxsave (%%rax)
        \\
        \\// Pass pointer to InterruptFrame as first arg
        \\movq %%rsp, %%rdi
        \\
        \\// Align stack to 16 bytes (ABI requirement for call)
        \\movq %%rsp, %%rbp
        \\andq $-16, %%rsp
        \\
        \\callq interruptDispatch
        \\
        // Restore SSE state from per-CPU fxsave area
        \\movl $0xC0000101, %%ecx
        \\rdmsr
        \\shlq $32, %%rdx
        \\orq %%rdx, %%rax
        \\addq %[fxoff], %%rax
        \\fxrstor (%%rax)
        \\
        \\// Restore stack
        \\movq %%rbp, %%rsp
        \\
        \\// Restore all registers
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rbp
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rbx
        \\popq %%rax
        \\
        \\// Remove vector and error_code from stack
        \\addq $16, %%rsp
        \\
        \\iretq
        :
        : [fxoff] "i" (@as(u32, fxoff)),
    );
}

/// Convert a comptime integer to a decimal string for inline assembly embedding.
fn comptimeDecimal(comptime val: usize) *const [decLen(val)]u8 {
    comptime {
        var buf: [decLen(val)]u8 = undefined;
        var v = val;
        var i: usize = buf.len;
        while (i > 0) {
            i -= 1;
            buf[i] = @truncate((v % 10) + '0');
            v /= 10;
        }
        const result = buf;
        return &result;
    }
}

fn decLen(comptime val: usize) usize {
    if (val == 0) return 1;
    var v = val;
    var len: usize = 0;
    while (v > 0) {
        v /= 10;
        len += 1;
    }
    return len;
}

// --- Zig-level interrupt dispatcher ---

export fn interruptDispatch(frame: *InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);

    if (vector < 32) {
        // Double fault (#DF) — now runs on IST1 dedicated stack, always reachable.
        // Dump everything to serial for post-mortem analysis.
        if (vector == 8) {
            // Acquire serial lock to prevent garbled output from APs
            const sflags = serial.serial_lock.acquire();
            const w = serial.writeStringUnlocked;
            w("\n\n=== DOUBLE FAULT (#DF) on IST1 ===\n");
            w("RIP="); writeHexL(frame.rip); w(" CS="); writeHexL(frame.cs); w("\n");
            w("RSP="); writeHexL(frame.rsp); w(" SS="); writeHexL(frame.ss); w("\n");
            w("RFLAGS="); writeHexL(frame.rflags); w(" ERR="); writeHexL(frame.error_code); w("\n");
            w("RAX="); writeHexL(frame.rax); w(" RBX="); writeHexL(frame.rbx); w("\n");
            w("RCX="); writeHexL(frame.rcx); w(" RDX="); writeHexL(frame.rdx); w("\n");
            w("RSI="); writeHexL(frame.rsi); w(" RDI="); writeHexL(frame.rdi); w("\n");
            w("RBP="); writeHexL(frame.rbp); w(" R8="); writeHexL(frame.r8); w("\n");
            w("R9="); writeHexL(frame.r9); w(" R10="); writeHexL(frame.r10); w("\n");
            w("R11="); writeHexL(frame.r11); w(" R12="); writeHexL(frame.r12); w("\n");
            const cr2_df = asm volatile ("movq %%cr2, %[cr2]" : [cr2] "=r" (-> u64));
            const cr3_df = asm volatile ("movq %%cr3, %[cr3]" : [cr3] "=r" (-> u64));
            w("CR2="); writeHexL(cr2_df); w(" CR3="); writeHexL(cr3_df); w("\n");
            const tss_mod = @import("tss.zig");
            w("TSS.RSP0="); writeHexL(tss_mod.getRsp0()); w("\n");
            w("=== END #DF ===\n");
            serial.serial_lock.release(sflags);
            const main = @import("../../main.zig");
            main.halt();
        }

        // Page fault — try to resolve via demand paging or CoW before treating as fatal
        if (vector == 14) {
            const cr2 = asm volatile ("movq %%cr2, %[cr2]"
                : [cr2] "=r" (-> u64),
            );

            const fault = @import("../../mm/fault.zig");
            if (fault.resolve(cr2, frame.error_code)) {
                return; // Resolved — resume faulting instruction
            }

            // User-mode page fault → SIGSEGV (don't halt the kernel)
            if (frame.cs & 3 != 0) {
                // Print one-time SIGSEGV diagnostic (not klog — avoids serial flood)
                const sched = @import("../../proc/scheduler.zig");
                const pid: u64 = if (sched.currentProcess()) |p| p.pid else 0;
                serial.writeString("[segv] pid=");
                writeDecimal(pid);
                serial.writeString(" rip=0x");
                writeHex(frame.rip);
                serial.writeString(" cr2=0x");
                writeHex(cr2);
                serial.writeString(" rsp=0x");
                writeHex(frame.rsp);
                serial.writeString(" err=0x");
                writeHex(frame.error_code);
                serial.writeString("\n");
                const sig = @import("../../proc/signal.zig");
                if (sched.currentProcess()) |proc| {
                    sig.postSignal(proc, sig.SIGSEGV);
                    sig.checkAndDeliver(frame);
                }
                return;
            }
        }

        // User-mode exception (non-PF) → deliver appropriate signal
        if (frame.cs & 3 != 0) {
            const sig = @import("../../proc/signal.zig");
            const sched = @import("../../proc/scheduler.zig");
            const sig_num: u6 = switch (vector) {
                0, 16, 19 => sig.SIGFPE, // Division Error, x87 FP, SIMD FP
                6 => sig.SIGILL, // Invalid Opcode
                17 => sig.SIGBUS, // Alignment Check
                else => sig.SIGSEGV, // General Protection, etc.
            };
            // Detailed dump for #GP to find the non-canonical address
            if (vector == 13) {
                const pid2: u64 = if (sched.currentProcess()) |p| p.pid else 0;
                serial.writeString("[#GP] pid=");
                writeDecimal(pid2);
                serial.writeString(" rip=0x");
                writeHex(frame.rip);
                serial.writeString(" rax=0x");
                writeHex(frame.rax);
                serial.writeString(" rbx=0x");
                writeHex(frame.rbx);
                serial.writeString(" rcx=0x");
                writeHex(frame.rcx);
                serial.writeString(" rsi=0x");
                writeHex(frame.rsi);
                serial.writeString(" rdi=0x");
                writeHex(frame.rdi);
                serial.writeString(" rsp=0x");
                writeHex(frame.rsp);
                serial.writeString(" err=0x");
                writeHex(frame.error_code);
                serial.writeString("\n");
            }
            const exc_log = klog.scoped(.exc);
            const pid: u64 = if (sched.currentProcess()) |p| p.pid else 0;
            exc_log.warn("user_exception", .{ .vector = @as(u64, vector), .rip = frame.rip, .pid = pid, .sig = @as(u64, sig_num) });
            if (sched.currentProcess()) |proc| {
                sig.postSignal(proc, sig_num);
                sig.checkAndDeliver(frame);
            }
            return;
        }

        // Kernel exception — fatal, dump info and halt.
        // Flush klog ring buffer first for post-mortem analysis.
        klog.panicDump(64);

        // Print CR2 and key info FIRST (before exception_names access)
        // to avoid cascading faults hiding the real info.
        serial.writeString("\n!!! EXCEPTION #");
        writeDecimal(vector);
        serial.writeString(" RIP=0x");
        writeHex(frame.rip);
        serial.writeString(" ERR=0x");
        writeHex(frame.error_code);
        serial.writeString(" CS=0x");
        writeHex(frame.cs);
        serial.writeString(" RSP=0x");
        writeHex(frame.rsp);
        if (vector == 14) {
            const cr2_dump = asm volatile ("movq %%cr2, %[cr2]"
                : [cr2] "=r" (-> u64),
            );
            serial.writeString(" CR2=0x");
            writeHex(cr2_dump);
        }
        serial.writeString("\n");

        const main = @import("../../main.zig");
        main.halt();
    } else if (vector == 0x80) {
        // Syscall from userspace (int 0x80)
        const syscall = @import("../../proc/syscall.zig");
        syscall.dispatch(frame);
    } else if (vector >= 32 and vector < 48) {
        // Hardware IRQ (PIC)
        const irq = vector - 32;
        irqHandler(irq, frame);
        pic.sendEoi(irq);
    } else if (vector == 249) {
        // TLB shootdown IPI
        const lapic = @import("lapic.zig");
        lapic.eoi();
        vmm.handleTlbShootdown();
    } else if (vector == 240) {
        // LAPIC timer — per-CPU scheduling tick (vector 240)
        const lapic = @import("lapic.zig");
        lapic.eoi();
        tick_count += 1;
        // Debug: check for CpuLocal.kernel_stack_top corruption
        const tss_mod2 = @import("tss.zig");
        tss_mod2.checkKstackIntegrity();
        klog.drain();
        const net = @import("../../net/net.zig");
        net.poll();
        const scheduler = @import("../../proc/scheduler.zig");
        scheduler.timerTick(frame);
    }
    // Other vectors: silently ignore

    // Check for pending signals before returning to userspace
    if (frame.cs & 3 != 0) {
        const sig = @import("../../proc/signal.zig");
        sig.checkAndDeliver(frame);
    }
}

// --- Hex printing without std.fmt (safe in exception context) ---

/// Write a byte directly to COM1 via port I/O — zero stack usage.
fn serialRawByte(ch: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [data] "{al}" (ch),
          [port] "N{dx}" (@as(u16, 0x3F8)),
    );
}

/// Write a string directly to COM1 — minimal stack.
fn serialRawStr(s: []const u8) void {
    for (s) |ch| {
        serialRawByte(ch);
    }
}

/// Write a 64-bit hex value directly to COM1 — no buffer, no function calls.
fn serialRawHex(value: u64) void {
    var shift: u6 = 60;
    while (true) {
        const nibble: u8 = @truncate((value >> shift) & 0xf);
        const ch: u8 = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
        serialRawByte(ch);
        if (shift == 0) break;
        shift -= 4;
    }
}

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}

/// writeHex using writeStringUnlocked — caller must hold serial_lock
fn writeHexL(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeStringUnlocked(&buf);
}

// --- IRQ handlers ---

var tick_count: u64 = 0;

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

fn irqHandler(irq: u8, frame: *InterruptFrame) void {
    switch (irq) {
        0 => {
            // PIT timer
            tick_count += 1;

            // Drain structured log ring buffer to serial
            klog.drain();
            // Poll network stack (process packets from rx_ring)
            const net = @import("../../net/net.zig");
            net.poll();
            // Preemptive scheduling
            const scheduler = @import("../../proc/scheduler.zig");
            scheduler.timerTick(frame);
        },
        1 => {
            // PS/2 keyboard
            const ps2 = @import("../../drivers/ps2_keyboard.zig");
            ps2.irqHandler();
        },
        4 => {
            // COM1 serial receive
            serial.rxInterrupt();
        },
        else => {
            const virtio_blk = @import("../../drivers/virtio_blk.zig");
            const virtio_net = @import("../../drivers/virtio_net.zig");
            var handled = false;
            if (irq == virtio_blk.irq) {
                virtio_blk.handleIrq();
                handled = true;
            }
            if (irq == virtio_net.irq) {
                virtio_net.handleIrq();
                handled = true;
            }
            if (!handled and irq != 15) {
                // IRQ 15 = spurious IDE interrupt, silently ignored
                const log = klog.scoped(.irq);
                log.warn("unhandled", .{ .irq = @as(u64, irq) });
            }
        },
    }
}

pub fn getTickCount() u64 {
    return tick_count;
}

// --- Init ---

pub fn init() void {
    // Fill all 256 IDT entries with our stubs
    for (0..256) |i| {
        const addr = @intFromPtr(stubs[i]);
        idt_entries[i] = makeGate(addr, 0);
    }

    idt_ptr = .{
        .limit = @sizeOf(@TypeOf(idt_entries)) - 1,
        .base = @intFromPtr(&idt_entries),
    };

    // Vector 8 (#DF) uses IST=1 — dedicated stack so it runs even with corrupt main stack
    idt_entries[8].ist = 1;

    // Allow ring 3 to use int 0x80 for syscalls (DPL=3)
    // 0xEE = P=1, DPL=3, 0, interrupt gate (0xE)
    idt_entries[0x80].type_attr = 0xEE;

    idt_ptr = .{
        .limit = @sizeOf(@TypeOf(idt_entries)) - 1,
        .base = @intFromPtr(&idt_entries),
    };

    asm volatile ("lidt (%[idt_ptr])"
        :
        : [idt_ptr] "r" (&idt_ptr),
    );

    const log = klog.scoped(.cpu);
    log.info("idt_loaded", .{});
}

/// Load the shared IDT on an AP (secondary CPU).
/// IDT entries are the same for all CPUs — just need to run lidt.
pub fn loadForAp() void {
    asm volatile ("lidt (%[idt_ptr])"
        :
        : [idt_ptr] "r" (&idt_ptr),
    );
}
