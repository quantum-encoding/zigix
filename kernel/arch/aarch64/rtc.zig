/// PL031 Real-Time Clock driver for ARM64 QEMU virt.
///
/// The PL031 provides wall-clock time as a 32-bit Unix epoch counter.
/// On QEMU, this is seeded from the host's system time at VM start.
///
/// Register map (from MMIO base):
///   0x000  RTCDR  — Data Register (read: current time in seconds since epoch)
///   0x004  RTCMR  — Match Register (for alarm, unused)
///   0x008  RTCLR  — Load Register (write: set current time)
///   0x00C  RTCCR  — Control Register (bit 0: enable)
///
/// We read RTCDR once at boot to get the epoch offset, then combine
/// with the monotonic ARM Generic Timer for sub-second precision.

const fdt = @import("fdt.zig");
const timer = @import("timer.zig");

/// MMIO base address (discovered from DTB, or QEMU virt default).
var rtc_base: u64 = 0x09010000;

/// Boot-time epoch offset: Unix seconds at the moment the timer counter was ~0.
/// epoch_at_boot + (timer_ticks / timer_freq) = current Unix time.
var epoch_at_boot: u64 = 0;

/// Whether RTC was successfully initialized.
var initialized: bool = false;

/// Ticks value at the time we read the RTC (for precise offset calculation).
var ticks_at_read: u64 = 0;

// Register offsets
const RTCDR: usize = 0x000;
const RTCLR: usize = 0x008;
const RTCCR: usize = 0x00C;

inline fn mmioRead(offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(rtc_base + offset);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    return ptr.*;
}

inline fn mmioWrite(offset: usize, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(rtc_base + offset);
    ptr.* = val;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

/// Initialize RTC — call after timer.init() so we can compute the offset.
pub fn init() void {
    // Use DTB-discovered base if available
    if (fdt.config.valid) {
        // DTB parsing sets rtc_base if PL031 is found
        // For now use the default QEMU virt address
    }

    // Enable RTC
    mmioWrite(RTCCR, 1);

    // Read current wall-clock time
    const rtc_seconds = mmioRead(RTCDR);

    // Record monotonic ticks at the moment of RTC read
    ticks_at_read = timer.getTicks();
    const boot_seconds = ticks_at_read / 100;

    // epoch_at_boot = rtc_seconds - seconds_since_boot
    // This gives us the Unix epoch time at tick=0
    if (rtc_seconds > boot_seconds) {
        epoch_at_boot = @as(u64, rtc_seconds) - boot_seconds;
    } else {
        epoch_at_boot = @as(u64, rtc_seconds);
    }

    initialized = true;
}

/// Get current Unix time in seconds.
pub fn getEpochSeconds() u64 {
    if (!initialized) return 0;
    const ticks = timer.getTicks();
    return epoch_at_boot + (ticks / 100);
}

/// Get current Unix time with sub-second precision.
/// Returns (seconds, nanoseconds).
pub fn getEpochTime() struct { sec: u64, nsec: u64 } {
    if (!initialized) return .{ .sec = 0, .nsec = 0 };
    const ticks = timer.getTicks();
    const sec = epoch_at_boot + (ticks / 100);
    const nsec = (ticks % 100) * 10_000_000;
    return .{ .sec = sec, .nsec = nsec };
}

/// Get epoch offset (for modules that need raw value).
pub fn getEpochOffset() u64 {
    return epoch_at_boot;
}
