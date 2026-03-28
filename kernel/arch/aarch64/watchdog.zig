/// SBSA Generic Watchdog driver for ARM64
///
/// The ARM Server Base System Architecture (SBSA) defines a standard
/// two-stage watchdog exposed via ACPI GTDT (Generic Timer Description Table).
///
/// Stage 1 (WS0): First timeout fires WS0 interrupt — kernel can recover.
/// Stage 2 (WS1): Second timeout fires system reset — hardware reboot.
///
/// On UEFI/ACPI systems (Orange Pi 6 Plus), the firmware enables the
/// watchdog before handing off to the OS. We take over petting from
/// the scheduler timer tick.
///
/// If no watchdog is discovered, all functions are safe no-ops.

const uart = @import("uart.zig");

/// SBSA Generic Watchdog register offsets (Refresh frame)
const WRR: usize = 0x000; // Watchdog Refresh Register (write to pet)

/// SBSA Generic Watchdog register offsets (Control frame)
const WCS: usize = 0x000; // Watchdog Control and Status
const WOR: usize = 0x008; // Watchdog Offset Register (timeout in clock ticks)
const WCV_LO: usize = 0x010; // Watchdog Compare Value (low 32)
const WCV_HI: usize = 0x014; // Watchdog Compare Value (high 32)
const W_IIDR: usize = 0xFCC; // Watchdog Interface ID

/// WCS bits
const WCS_EN: u32 = 1 << 0; // Watchdog enable
const WCS_WS0: u32 = 1 << 1; // WS0 status (first stage fired)
const WCS_WS1: u32 = 1 << 2; // WS1 status (second stage fired)

/// Watchdog state
var refresh_base: usize = 0;
var control_base: usize = 0;
var active: bool = false;
var pet_count: u64 = 0;

/// How often to pet (every N timer ticks). At 100Hz timer, 500 = every 5 seconds.
const PET_INTERVAL: u64 = 500;

// MMIO helpers
inline fn writeReg(base: usize, offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    ptr.* = value;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

inline fn readReg(base: usize, offset: usize) u32 {
    asm volatile ("dmb sy" ::: .{ .memory = true });
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    return ptr.*;
}

/// Initialize watchdog with SBSA Generic Watchdog base addresses.
/// Call from boot.zig after ACPI parsing.
///
/// refresh_frame: base address of the refresh frame (from ACPI GTDT)
/// control_frame: base address of the control frame (from ACPI GTDT)
pub fn init(refresh_frame: usize, control_frame: usize) void {
    if (refresh_frame == 0 or control_frame == 0) {
        uart.writeString("[wdog] No watchdog base addresses — disabled\n");
        return;
    }

    refresh_base = refresh_frame;
    control_base = control_frame;

    // Read control status to check if watchdog is already running
    const wcs = readReg(control_base, WCS);
    const iidr = readReg(control_base, W_IIDR);

    uart.print("[wdog] SBSA watchdog: ctrl={x} refresh={x}\n", .{ control_base, refresh_base });
    uart.print("[wdog] WCS={x} IIDR={x}\n", .{ wcs, iidr });

    if (wcs & WCS_EN != 0) {
        uart.writeString("[wdog] Watchdog already enabled by firmware — taking over\n");
    } else {
        uart.writeString("[wdog] Watchdog not enabled — enabling\n");
        // Set a generous timeout (~30 seconds at typical CNTFRQ)
        // WOR is in clock ticks; use generic timer frequency
        const freq = asm volatile ("mrs %[ret], CNTFRQ_EL0"
            : [ret] "=r" (-> u64),
        );
        const timeout_ticks: u32 = @truncate(freq * 30); // 30 seconds
        writeReg(control_base, WOR, timeout_ticks);

        // Enable watchdog
        writeReg(control_base, WCS, WCS_EN);
    }

    // Pet immediately to reset the countdown
    pet();

    active = true;
    uart.writeString("[wdog] Watchdog active — petting from scheduler tick\n");
}

/// Initialize without ACPI — try probing known addresses.
/// For Orange Pi 6 Plus, the SBSA watchdog address will come from ACPI GTDT.
/// This is a fallback if ACPI GTDT parsing isn't available yet.
pub fn initProbe() void {
    // No-op until we have ACPI GTDT parsing or known addresses from TRM.
    // The BIOS has the watchdog enabled, so worst case we'll reset after timeout
    // and can read the serial log to find the GTDT addresses.
    uart.writeString("[wdog] No watchdog addresses known — skipping\n");
}

/// Pet the watchdog (reset countdown). Called from timer tick.
pub fn pet() void {
    if (!active) return;
    // Any write to WRR refreshes the watchdog
    writeReg(refresh_base, WRR, 1);
}

/// Called from timer interrupt handler. Pets watchdog every PET_INTERVAL ticks.
pub fn tick() void {
    if (!active) return;
    pet_count += 1;
    if (pet_count >= PET_INTERVAL) {
        pet_count = 0;
        pet();
    }
}

/// Disable watchdog (for clean shutdown).
pub fn disable() void {
    if (!active) return;
    writeReg(control_base, WCS, 0); // Clear EN bit
    active = false;
    uart.writeString("[wdog] Watchdog disabled\n");
}

/// Force immediate system reset via watchdog.
/// Set WOR to 0 (immediate timeout) — WS1 fires system reset.
pub fn forceReset() noreturn {
    if (control_base != 0) {
        writeReg(control_base, WOR, 0);
        writeReg(control_base, WCS, WCS_EN);
    }
    // If watchdog doesn't reset us, spin forever
    while (true) {
        asm volatile ("wfi");
    }
}

/// Check if watchdog is active.
pub fn isActive() bool {
    return active;
}
