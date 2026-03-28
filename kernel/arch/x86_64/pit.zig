/// PIT (Programmable Interval Timer) — Channel 0 at ~100 Hz.
/// Uses IRQ0 (vector 32 after PIC remapping).

const io = @import("io.zig");
const klog = @import("../../klog/klog.zig");

const PIT_CH0_DATA: u16 = 0x40;
const PIT_CMD: u16 = 0x43;

// PIT input frequency: 1,193,182 Hz
// Divisor for 100 Hz: 1193182 / 100 = 11931.82 ≈ 11932
const DIVISOR: u16 = 11932; // 0x2E9C → actual freq ≈ 100.006 Hz

pub fn init() void {
    // Channel 0, lobyte/hibyte, mode 2 (rate generator)
    // Command: 0b00_11_010_0 = 0x34
    io.outb(PIT_CMD, 0x34);

    // Send divisor (low byte first, then high)
    io.outb(PIT_CH0_DATA, @truncate(DIVISOR & 0xFF));
    io.outb(PIT_CH0_DATA, @truncate(DIVISOR >> 8));

    const log = klog.scoped(.cpu);
    log.info("pit_100hz", .{});
}
