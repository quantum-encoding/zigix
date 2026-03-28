/// Local APIC driver — per-CPU timer and interrupt acknowledgment.
///
/// Each CPU has a Local APIC at physical address 0xFEE00000 (accessed via HHDM).
/// The LAPIC timer provides per-CPU scheduling ticks, replacing the PIT which
/// only fires on the BSP. The LAPIC also handles EOI for local interrupts and
/// will be used for IPI delivery (Step 6).

const hhdm = @import("../../mm/hhdm.zig");
const serial = @import("serial.zig");
const io = @import("io.zig");
const pic = @import("pic.zig");

/// LAPIC timer fires on this vector.
/// Must not conflict with PIC IRQs 32-47, syscall 0x80, or MSI-X vectors (48+).
/// Using 240 to stay well above device MSI-X range.
pub const TIMER_VECTOR: u8 = 240;

/// TLB shootdown IPI vector (Step 6)
pub const TLB_SHOOTDOWN_VECTOR: u8 = 249;

/// LAPIC MMIO base (virtual address via HHDM, set during init)
var lapic_base: u64 = 0;

// LAPIC register offsets
const REG_ID: u32 = 0x020; // Local APIC ID
const REG_EOI: u32 = 0x0B0; // End of Interrupt
const REG_SVR: u32 = 0x0F0; // Spurious Interrupt Vector Register
const REG_ICR_LOW: u32 = 0x300; // Interrupt Command Register (low)
const REG_ICR_HIGH: u32 = 0x310; // Interrupt Command Register (high)
const REG_LVT_TIMER: u32 = 0x320; // LVT Timer
const REG_TIMER_INIT: u32 = 0x380; // Timer Initial Count
const REG_TIMER_CUR: u32 = 0x390; // Timer Current Count
const REG_TIMER_DIV: u32 = 0x3E0; // Timer Divide Configuration

// LVT Timer mode bits
const TIMER_PERIODIC: u32 = 1 << 17; // Periodic mode (vs one-shot)
const TIMER_MASKED: u32 = 1 << 16; // Masked (interrupt disabled)

/// Calibrated tick count for ~100Hz (computed during init)
var ticks_per_100hz: u32 = 0;

/// Read a 32-bit LAPIC register.
fn read(offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(lapic_base + offset);
    return addr.*;
}

/// Write a 32-bit LAPIC register.
fn write(offset: u32, value: u32) void {
    const addr: *volatile u32 = @ptrFromInt(lapic_base + offset);
    addr.* = value;
}

/// Send End-of-Interrupt to the local APIC.
/// Must be called at the end of every LAPIC-sourced interrupt handler.
pub fn eoi() void {
    write(REG_EOI, 0);
}

/// Read this CPU's LAPIC ID (from the APIC ID register, bits 24-27).
pub fn id() u8 {
    return @truncate(read(REG_ID) >> 24);
}

/// Initialize the BSP's Local APIC and start the periodic timer.
/// Must be called after HHDM is initialized.
pub fn init() void {
    // Map LAPIC via HHDM
    lapic_base = hhdm.physToVirt(0xFEE00000);

    // Enable APIC: set bit 8 in SVR, set spurious vector to 0xFF
    write(REG_SVR, 0x100 | 0xFF);

    // Calibrate LAPIC timer using PIT channel 2 as reference
    calibrateTimer();

    // Configure timer: periodic mode, vector TIMER_VECTOR
    write(REG_LVT_TIMER, TIMER_PERIODIC | TIMER_VECTOR);
    write(REG_TIMER_DIV, 0x3); // Divide by 16
    write(REG_TIMER_INIT, ticks_per_100hz);

    // Mask PIT IRQ0 — LAPIC timer replaces it
    pic.setIrqMask(0, true);

    serial.writeString("[lapic] BSP APIC enabled, timer at ~100Hz (ticks=");
    writeDecimal(ticks_per_100hz);
    serial.writeString(")\n");
}

/// Initialize a secondary CPU's LAPIC timer (same calibration as BSP).
/// Called from AP entry point (Step 3).
pub fn initSecondary() void {
    // Each CPU's LAPIC is at the same physical address but is CPU-local hardware
    // Enable APIC
    write(REG_SVR, 0x100 | 0xFF);

    // Use the same calibrated tick count
    write(REG_LVT_TIMER, TIMER_PERIODIC | TIMER_VECTOR);
    write(REG_TIMER_DIV, 0x3); // Divide by 16
    write(REG_TIMER_INIT, ticks_per_100hz);
}

/// Calibrate LAPIC timer using PIT channel 2 one-shot as reference.
/// Measures how many LAPIC ticks occur in ~10ms (PIT at 1193182 Hz).
fn calibrateTimer() void {
    const PIT_CH2_DATA: u16 = 0x42;
    const PIT_CMD: u16 = 0x43;
    const PIT_GATE: u16 = 0x61;

    // 10ms worth of PIT ticks: 1193182 / 100 = 11932
    const PIT_10MS: u16 = 11932;

    // Set LAPIC timer divide to 16
    write(REG_TIMER_DIV, 0x3);

    // Program PIT channel 2 for one-shot mode
    // Gate off first
    var gate = io.inb(PIT_GATE);
    gate &= 0xFD; // Clear bit 1 (gate off)
    gate |= 0x01; // Set bit 0 (speaker data, needed for gate control)
    io.outb(PIT_GATE, gate);

    // Channel 2, lobyte/hibyte, mode 0 (one-shot)
    io.outb(PIT_CMD, 0xB0);
    io.outb(PIT_CH2_DATA, @truncate(PIT_10MS & 0xFF));
    io.outb(PIT_CH2_DATA, @truncate(PIT_10MS >> 8));

    // Start LAPIC timer with max count
    write(REG_TIMER_INIT, 0xFFFFFFFF);

    // Gate on — start PIT countdown
    gate = io.inb(PIT_GATE);
    gate |= 0x01;
    io.outb(PIT_GATE, gate);

    // Wait for PIT to expire (bit 5 of port 0x61 goes high when channel 2 output is high)
    while (io.inb(PIT_GATE) & 0x20 == 0) {
        asm volatile ("pause");
    }

    // Read LAPIC timer current count
    const elapsed = 0xFFFFFFFF - read(REG_TIMER_CUR);

    // Stop LAPIC timer
    write(REG_LVT_TIMER, TIMER_MASKED);

    // elapsed ticks in ~10ms → multiply by 10 for 100ms, divide by 10 for 10ms period
    // We want 100Hz = 10ms period, so ticks_per_100hz = elapsed (already ~10ms worth)
    ticks_per_100hz = elapsed;

    // Sanity: if calibration failed (very fast or broken), use a reasonable default
    if (ticks_per_100hz < 1000) {
        ticks_per_100hz = 100000; // Fallback: ~100K ticks per 10ms
    }
}

/// Send INIT IPI to a specific AP (by APIC ID).
/// This puts the AP into a known init state (waiting for SIPI).
pub fn sendInitIpi(target_apic_id: u8) void {
    waitIcrReady();
    write(REG_ICR_HIGH, @as(u32, target_apic_id) << 24);
    // INIT delivery mode = 0b101 (bits 10:8), level assert (bit 14), edge (bit 15 clear)
    write(REG_ICR_LOW, 0x00004500);
    waitIcrReady();
}

/// Send STARTUP IPI (SIPI) to a specific AP (by APIC ID).
/// The vector field specifies the 4K-aligned physical page of the trampoline code.
/// e.g., trampoline at 0x8000 → vector = 0x08.
pub fn sendSipi(target_apic_id: u8, trampoline_page: u8) void {
    waitIcrReady();
    write(REG_ICR_HIGH, @as(u32, target_apic_id) << 24);
    // STARTUP delivery mode = 0b110 (bits 10:8), vector = trampoline page
    write(REG_ICR_LOW, 0x00004600 | @as(u32, trampoline_page));
    waitIcrReady();
}

fn waitIcrReady() void {
    while (read(REG_ICR_LOW) & (1 << 12) != 0) {
        asm volatile ("pause");
    }
}

/// Send an IPI to a specific CPU (by APIC ID).
pub fn sendIpi(target_apic_id: u8, vector: u8) void {
    waitIcrReady();
    write(REG_ICR_HIGH, @as(u32, target_apic_id) << 24);
    write(REG_ICR_LOW, @as(u32, vector));
}

/// Broadcast an IPI to all CPUs except self.
pub fn broadcastIpi(vector: u8) void {
    waitIcrReady();
    // All-excluding-self shorthand (bits 18:19 = 11), fixed delivery, vector
    write(REG_ICR_LOW, @as(u32, vector) | (0b11 << 18));
}

fn writeDecimal(value: u32) void {
    var buf: [10]u8 = undefined;
    var v = value;
    var i: usize = 10;
    if (v == 0) {
        serial.writeString("0");
        return;
    }
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    serial.writeString(buf[i..]);
}
