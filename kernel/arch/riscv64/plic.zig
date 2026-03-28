/// RISC-V Platform-Level Interrupt Controller (PLIC).
///
/// QEMU virt machine PLIC at 0x0C000000.
/// Much simpler than ARM64 GIC — flat priority + enable registers.
///
/// Layout:
///   0x000000: Priority registers (4 bytes per source, sources 1-1023)
///   0x002000: Pending bits (1 bit per source)
///   0x200000: Hart 0 S-mode enable bits (1 bit per source)
///   0x200004: Hart 0 S-mode priority threshold
///   0x201000: Hart 0 S-mode claim/complete register

const uart = @import("uart.zig");

const PLIC_BASE: usize = 0x0C000000;

// Register offsets
const PRIORITY_BASE: usize = PLIC_BASE + 0x000000;
const PENDING_BASE: usize = PLIC_BASE + 0x001000;
// S-mode context for hart 0 = context 1 (M-mode = context 0)
const ENABLE_BASE: usize = PLIC_BASE + 0x002080; // Context 1 enable
const THRESHOLD: usize = PLIC_BASE + 0x201000; // Context 1 threshold
const CLAIM: usize = PLIC_BASE + 0x201004; // Context 1 claim/complete

// QEMU virt IRQ numbers
pub const IRQ_UART0: u32 = 10;
pub const IRQ_VIRTIO0: u32 = 1; // virtio MMIO devices start at IRQ 1

pub fn init() void {
    // Set priority threshold to 0 (accept all priorities > 0)
    const threshold_ptr: *volatile u32 = @ptrFromInt(THRESHOLD);
    threshold_ptr.* = 0;
}

/// Enable an interrupt source.
pub fn enable(irq: u32) void {
    if (irq == 0 or irq >= 1024) return;
    const reg_offset = (irq / 32) * 4;
    const bit: u5 = @truncate(irq % 32);
    const enable_ptr: *volatile u32 = @ptrFromInt(ENABLE_BASE + reg_offset);
    enable_ptr.* |= @as(u32, 1) << bit;
}

/// Set priority for an interrupt source (1-7, higher = higher priority).
pub fn setPriority(irq: u32, priority: u32) void {
    if (irq == 0 or irq >= 1024) return;
    const prio_ptr: *volatile u32 = @ptrFromInt(PRIORITY_BASE + irq * 4);
    prio_ptr.* = priority;
}

/// Handle an external interrupt: claim, dispatch, complete.
pub fn handleInterrupt() void {
    const claim_ptr: *volatile u32 = @ptrFromInt(CLAIM);
    const irq = claim_ptr.*;

    if (irq == 0) return; // Spurious

    switch (irq) {
        IRQ_UART0 => {
            // UART input — read and discard for now
            while (uart.readByte()) |_| {}
        },
        else => {
            uart.print("[plic] Unhandled IRQ {}\n", .{irq});
        },
    }

    // Complete the interrupt
    claim_ptr.* = irq;
}
