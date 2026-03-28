/// RISC-V S-mode trap handling with full context save/restore.
///
/// TrapFrame layout on kernel stack saves all 31 GP registers + sepc + sstatus.
/// The frame pointer is passed to the Zig handler, enabling context switches.

const uart = @import("uart.zig");
const plic = @import("plic.zig");
const timer_mod = @import("timer.zig");
const syscall = @import("syscall.zig");
const vmm = @import("vmm.zig");
const scheduler = @import("scheduler.zig");

/// Trap frame — saved on kernel stack on every trap entry.
/// 34 u64 fields = 272 bytes.
pub const TrapFrame = extern struct {
    x: [32]u64, // x0 is always 0 but we reserve the slot for indexing
    sepc: u64, // Saved program counter
    sstatus: u64, // Saved status register
};

/// Global kernel stack pointer — set at boot, used by trap entry when
/// coming from U-mode (the user's sp is in sscratch).
pub var kernel_sp: u64 = 0;

/// Install the trap vector.
pub fn init() void {
    const handler_addr = @intFromPtr(&trapEntry);
    asm volatile ("csrw stvec, %[addr]" :: [addr] "r" (handler_addr));
}

/// Trap entry — saves full context, calls Zig handler, restores, sret.
///
/// On trap from U-mode: swap sp↔sscratch to get kernel stack.
/// On trap from S-mode (timer IRQ during kernel): sp is already kernel stack.
export fn trapEntry() callconv(.naked) void {
    asm volatile (
        // Check if we came from U-mode or S-mode by reading sstatus.SPP
        \\csrr t0, sstatus
        \\andi t0, t0, 0x100       // SPP bit (bit 8)
        \\bnez t0, .Lfrom_kernel

        // From U-mode: swap sp with sscratch (kernel sp)
        \\csrrw sp, sscratch, sp
        \\j .Lsave_context

        \\.Lfrom_kernel:
        // From S-mode: sp is already kernel stack, don't swap

        \\.Lsave_context:
        // Allocate trap frame (272 bytes = 34 * 8)
        \\addi sp, sp, -272

        // Save x1-x31 (x0 is hardwired to 0)
        \\sd x1, 8(sp)
        \\sd x2, 16(sp)          // This is the user's sp (or kernel sp if from S-mode)
        \\sd x3, 24(sp)
        \\sd x4, 32(sp)
        \\sd x5, 40(sp)
        \\sd x6, 48(sp)
        \\sd x7, 56(sp)
        \\sd x8, 64(sp)
        \\sd x9, 72(sp)
        \\sd x10, 80(sp)
        \\sd x11, 88(sp)
        \\sd x12, 96(sp)
        \\sd x13, 104(sp)
        \\sd x14, 112(sp)
        \\sd x15, 120(sp)
        \\sd x16, 128(sp)
        \\sd x17, 136(sp)
        \\sd x18, 144(sp)
        \\sd x19, 152(sp)
        \\sd x20, 160(sp)
        \\sd x21, 168(sp)
        \\sd x22, 176(sp)
        \\sd x23, 184(sp)
        \\sd x24, 192(sp)
        \\sd x25, 200(sp)
        \\sd x26, 208(sp)
        \\sd x27, 216(sp)
        \\sd x28, 224(sp)
        \\sd x29, 232(sp)
        \\sd x30, 240(sp)
        \\sd x31, 248(sp)

        // Save sepc and sstatus
        \\csrr t0, sepc
        \\sd t0, 256(sp)
        \\csrr t0, sstatus
        \\sd t0, 264(sp)

        // If we came from U-mode, save the user sp (now in sscratch)
        \\andi t1, t0, 0x100       // Check SPP again from saved sstatus
        \\bnez t1, .Lskip_save_usp
        \\csrr t0, sscratch        // User sp was swapped into sscratch
        \\sd t0, 16(sp)            // Save it as x2 (sp) in the frame
        \\.Lskip_save_usp:

        // Call Zig handler with frame pointer in a0
        \\mv a0, sp
        \\call trapHandler

        // Restore sepc and sstatus
        \\ld t0, 256(sp)
        \\csrw sepc, t0
        \\ld t0, 264(sp)
        \\csrw sstatus, t0

        // Check if returning to U-mode
        \\andi t1, t0, 0x100       // SPP bit
        \\bnez t1, .Lrestore_kernel

        // Returning to U-mode: restore user sp via sscratch
        \\ld t0, 16(sp)            // User sp
        \\csrw sscratch, t0

        \\.Lrestore_kernel:
        // Restore x1, x3-x31 (skip x2/sp — restored separately)
        \\ld x1, 8(sp)
        \\ld x3, 24(sp)
        \\ld x4, 32(sp)
        \\ld x5, 40(sp)
        \\ld x6, 48(sp)
        \\ld x7, 56(sp)
        \\ld x8, 64(sp)
        \\ld x9, 72(sp)
        \\ld x10, 80(sp)
        \\ld x11, 88(sp)
        \\ld x12, 96(sp)
        \\ld x13, 104(sp)
        \\ld x14, 112(sp)
        \\ld x15, 120(sp)
        \\ld x16, 128(sp)
        \\ld x17, 136(sp)
        \\ld x18, 144(sp)
        \\ld x19, 152(sp)
        \\ld x20, 160(sp)
        \\ld x21, 168(sp)
        \\ld x22, 176(sp)
        \\ld x23, 184(sp)
        \\ld x24, 192(sp)
        \\ld x25, 200(sp)
        \\ld x26, 208(sp)
        \\ld x27, 216(sp)
        \\ld x28, 224(sp)
        \\ld x29, 232(sp)
        \\ld x30, 240(sp)
        \\ld x31, 248(sp)

        // Deallocate trap frame
        \\addi sp, sp, 272

        // If returning to U-mode, swap sp back from sscratch
        \\csrr t0, sstatus
        \\andi t0, t0, 0x100
        \\bnez t0, .Lsret
        \\csrrw sp, sscratch, sp

        \\.Lsret:
        \\sret
    );
}

/// Zig trap handler — receives TrapFrame pointer, dispatches on scause.
export fn trapHandler(frame: *TrapFrame) callconv(.c) void {
    const scause = asm volatile ("csrr %[ret], scause"
        : [ret] "=r" (-> u64),
    );
    const stval = asm volatile ("csrr %[ret], stval"
        : [ret] "=r" (-> u64),
    );

    const is_interrupt = (scause >> 63) != 0;
    const code = scause & 0x7FFFFFFFFFFFFFFF;

    if (is_interrupt) {
        switch (code) {
            1 => {
                // S-mode software interrupt (IPI)
                asm volatile ("csrc sip, %[val]" :: [val] "r" (@as(u64, 1 << 1)));
            },
            5 => {
                // S-mode timer interrupt
                timer_mod.handleInterrupt();
            },
            9 => {
                // S-mode external interrupt (PLIC)
                plic.handleInterrupt();
            },
            else => {
                uart.print("[trap] Unknown interrupt: cause={} stval={x}\n", .{ code, stval });
            },
        }
    } else {
        switch (code) {
            8 => {
                // Environment call from U-mode (syscall)
                // Advance sepc past ecall (4 bytes)
                frame.sepc += 4;
                syscall.handleSyscall(frame);
            },
            2 => uart.print("[trap] Illegal instruction at {x} stval={x}\n", .{ frame.sepc, stval }),
            5 => uart.print("[trap] Load access fault at {x} addr={x}\n", .{ frame.sepc, stval }),
            7 => uart.print("[trap] Store access fault at {x} addr={x}\n", .{ frame.sepc, stval }),
            12 => uart.print("[trap] Instruction page fault at {x} addr={x}\n", .{ frame.sepc, stval }),
            13 => {
                // Load page fault — try CoW resolution
                if (scheduler.currentProcess()) |proc| {
                    if (vmm.handleCow(proc.page_table, stval)) return;
                }
                uart.print("[trap] Load page fault at {x} addr={x}\n", .{ frame.sepc, stval });
            },
            15 => {
                // Store page fault — try CoW resolution
                if (scheduler.currentProcess()) |proc| {
                    if (vmm.handleCow(proc.page_table, stval)) return;
                }
                uart.print("[trap] Store page fault at {x} addr={x}\n", .{ frame.sepc, stval });
            },
            else => uart.print("[trap] Exception: cause={} sepc={x} stval={x}\n", .{ code, frame.sepc, stval }),
        }
    }
}
