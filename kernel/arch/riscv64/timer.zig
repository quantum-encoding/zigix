/// RISC-V timer — uses SBI legacy set_timer.
///
/// The RISC-V timer is accessed via the time CSR (read-only in S-mode).
/// To set the next timer interrupt, we call SBI's set_timer ecall which
/// writes to M-mode's mtimecmp register and clears STIP.
///
/// QEMU virt runs the timer at 10 MHz (timebase-frequency in DTB).

const uart = @import("uart.zig");

const TIMER_FREQ: u64 = 10_000_000; // 10 MHz (QEMU virt default)
const TARGET_HZ: u64 = 100; // 100 Hz tick rate
const TICKS_PER_INTERRUPT: u64 = TIMER_FREQ / TARGET_HZ;

var ticks: u64 = 0;
var initialized: bool = false;

pub fn init() void {
    const now = readTime();
    uart.print("[timer] time CSR = {}\n", .{now});
    sbiSetTimer(now + TICKS_PER_INTERRUPT);
    initialized = true;
    uart.print("[timer] {} Hz clock, {} Hz tick, next at {}\n", .{
        TIMER_FREQ, TARGET_HZ, now + TICKS_PER_INTERRUPT,
    });
}

/// Called from trap handler on S-mode timer interrupt (scause = 5).
pub fn handleInterrupt() void {
    ticks += 1;

    // Schedule next timer interrupt (also clears STIP)
    const now = readTime();
    sbiSetTimer(now + TICKS_PER_INTERRUPT);

    // Print on first tick and every second
    if (ticks <= 3 or ticks % TARGET_HZ == 0) {
        uart.print("[tick] t={} uptime={}s\n", .{ ticks, ticks / TARGET_HZ });
    }
}

pub fn getTicks() u64 {
    return ticks;
}

/// Read the raw RISC-V time CSR value (monotonic counter).
pub fn readCounter() u64 {
    return readTime();
}

/// Return the timer frequency in Hz (QEMU virt = 10 MHz).
pub fn readFrequency() u64 {
    return TIMER_FREQ;
}

pub fn delayMillis(ms: u32) void {
    const target = readTime() + @as(u64, ms) * (TIMER_FREQ / 1000);
    while (readTime() < target) {
        asm volatile ("" ::: .{ .memory = true });
    }
}

inline fn readTime() u64 {
    return asm volatile ("csrr %[ret], time"
        : [ret] "=r" (-> u64),
    );
}

/// SBI legacy set_timer: a7 = 0, a0 = stime_value.
fn sbiSetTimer(stime_value: u64) void {
    asm volatile ("ecall"
        :
        : [a7] "{a7}" (@as(u64, 0)),
          [a0] "{a0}" (stime_value),
        : .{ .memory = true }
    );
}
