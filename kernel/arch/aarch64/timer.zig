/// ARM Generic Timer driver
/// Provides periodic timer interrupts for scheduling.
///
/// ARM64 has a much cleaner timer interface than x86:
/// - CNTPCT_EL0: Physical counter (always counting)
/// - CNTFRQ_EL0: Counter frequency in Hz
/// - CNTP_TVAL_EL0: Timer value (countdown)
/// - CNTP_CTL_EL0: Timer control

const uart = @import("uart.zig");
const smp = @import("smp.zig");
const klog = @import("klog");

var timer_frequency: u64 = 0;
var ticks: u64 = 0;

// BSS corruption watchpoint: saved copy of virtio_blk.mmio_base on a different page.
// Set once after virtio_blk.init(), checked every timer tick. If the live value
// changes, we catch it immediately with CPU/PID/ELR context.
var saved_mmio_base: u64 = 0;
var bss_watch_armed: bool = false;

pub fn armBssWatchpoint(mmio_base_val: u64) void {
    saved_mmio_base = mmio_base_val;
    bss_watch_armed = true;
    uart.print("[timer] BSS watchpoint armed: mmio_base={x}\n", .{mmio_base_val});
}

/// Target frequency for timer interrupts (Hz)
const TARGET_HZ: u64 = 100;

pub fn init() void {
    // Read the timer frequency
    timer_frequency = readFrequency();

    // Calculate ticks per interrupt
    const ticks_per_interrupt = timer_frequency / TARGET_HZ;

    // Set the timer value (countdown register)
    setTimerValue(ticks_per_interrupt);

    // Enable the timer, unmask interrupt
    // CNTP_CTL_EL0: bit 0 = ENABLE, bit 1 = IMASK (0 = not masked)
    asm volatile ("msr CNTP_CTL_EL0, %[val]"
        :
        : [val] "r" (@as(u64, 1)),
    );

    uart.writeString("[timer] ARM Generic Timer initialized\n");
}

/// Read the physical counter value
pub inline fn readCounter() u64 {
    return asm volatile ("mrs %[ret], CNTPCT_EL0"
        : [ret] "=r" (-> u64),
    );
}

/// Read the timer frequency (Hz)
pub inline fn readFrequency() u64 {
    return asm volatile ("mrs %[ret], CNTFRQ_EL0"
        : [ret] "=r" (-> u64),
    );
}

/// Set the timer countdown value
pub inline fn setTimerValue(value: u64) void {
    asm volatile ("msr CNTP_TVAL_EL0, %[val]"
        :
        : [val] "r" (value),
    );
}

/// Get current timer value (for debugging)
pub inline fn getTimerValue() u64 {
    return asm volatile ("mrs %[ret], CNTP_TVAL_EL0"
        : [ret] "=r" (-> u64),
    );
}

/// Called from IRQ handler when timer fires (no-frame variant)
pub fn interrupt() void {
    _ = @atomicRmw(u64, &ticks, .Add, 1, .monotonic);
    smp.current().timer_ticks += 1;

    // Reload the timer for next interrupt
    const ticks_per_interrupt = timer_frequency / TARGET_HZ;
    setTimerValue(ticks_per_interrupt);
}

/// Called from GIC handler with access to TrapFrame
pub fn interruptWithFrame(frame: *@import("exception.zig").TrapFrame) void {
    _ = @atomicRmw(u64, &ticks, .Add, 1, .monotonic);
    smp.current().timer_ticks += 1;

    // Reload the timer
    const ticks_per_interrupt = timer_frequency / TARGET_HZ;
    setTimerValue(ticks_per_interrupt);

    // Poll UART RX — GCE serial console may not trigger PL011 RX interrupt
    uart.pollRx();

    // Heartbeat: every 100 ticks (~1s), show what's running on CPU 0
    const total_ticks = @atomicLoad(u64, &ticks, .monotonic);
    if (total_ticks % 1000 == 0 and total_ticks > 0) {
        const pid = if (@import("scheduler.zig").currentProcess()) |p| p.pid else 0;
        uart.print("[tick] t={} cpu={} pid={} elr={x}\n", .{ total_ticks, smp.cpuId(), pid, frame.elr });
    }

    // Housekeeping: network poll, watchdog, futex poll.
    // Run on any CPU — CPU 0 may be blocked in a syscall and not receiving ticks.
    if (smp.cpuId() < smp.MAX_CPUS) {
        //klog.drain(); // disabled: testing NVMe fix in isolation
        const watchdog = @import("watchdog.zig");
        watchdog.tick();

        const net = @import("net.zig");
        net.poll();

        // Poll futex waiters every 10 ticks (~100ms) to catch missed wakes
        if (total_ticks % 10 == 0) {
            const futex = @import("futex.zig");
            futex.pollWaiters();
        }
    }

    // BSS corruption detector: check if virtio_blk.mmio_base has been zeroed
    if (bss_watch_armed) {
        const virtio_blk = @import("virtio_blk.zig");
        // Use volatile read to prevent optimization
        const mmio_ptr: *volatile usize = &virtio_blk.mmio_base;
        const live_mmio: u64 = mmio_ptr.*;
        if (live_mmio != saved_mmio_base) {
            uart.print("\n!!! BSS CORRUPTION DETECTED !!!\n", .{});
            uart.print("  CPU={} tick={} ELR={x}\n", .{ smp.cpuId(), total_ticks, frame.elr });
            const pid = if (@import("scheduler.zig").currentProcess()) |p| p.pid else 0;
            uart.print("  PID={} expected mmio_base={x} got={x}\n", .{ pid, saved_mmio_base, live_mmio });
            // Dump surrounding BSS bytes (64 bytes around mmio_base)
            const base_addr = @intFromPtr(&virtio_blk.mmio_base);
            const dump_start = base_addr -| 16; // 16 bytes before
            const dump_ptr: [*]const u8 = @ptrFromInt(dump_start);
            uart.print("  BSS dump at {x}:\n  ", .{dump_start});
            for (0..80) |bi| {
                uart.writeHexByte(dump_ptr[bi]);
                uart.writeByte(' ');
                if (bi % 16 == 15) uart.writeString("\n  ");
            }
            uart.writeString("\n");
            // Check if entire surrounding region is zeroed (page-wide corruption)
            const base_addr2 = @intFromPtr(&virtio_blk.mmio_base);
            var nonzero_count: u32 = 0;
            const scan_ptr: [*]const u8 = @ptrFromInt(base_addr2 & ~@as(usize, 0xFFF)); // page start
            for (0..4096) |si| {
                if (scan_ptr[si] != 0) nonzero_count += 1;
            }
            uart.print("  page nonzero bytes: {}/4096\n", .{nonzero_count});
            // Halt this CPU
            while (true) {
                asm volatile ("wfi");
            }
        }
    }

    // Call scheduler
    const scheduler = @import("scheduler.zig");
    scheduler.timerTick(frame);
}

/// Initialize timer on secondary CPU (same registers, just no log output).
pub fn initSecondary() void {
    const ticks_per_interrupt = readFrequency() / TARGET_HZ;
    setTimerValue(ticks_per_interrupt);

    // Enable the timer, unmask interrupt
    asm volatile ("msr CNTP_CTL_EL0, %[val]"
        :
        : [val] "r" (@as(u64, 1)),
    );
}

/// Get elapsed ticks since boot (atomic — safe from any CPU)
pub fn getTicks() u64 {
    return @atomicLoad(u64, &ticks, .monotonic);
}

/// Get elapsed milliseconds since boot
pub fn getMillis() u64 {
    return (ticks * 1000) / TARGET_HZ;
}

/// Busy-wait for specified number of microseconds
pub fn delayMicros(us: u64) void {
    const start = readCounter();
    const ticks_to_wait = (us * timer_frequency) / 1_000_000;

    while (readCounter() - start < ticks_to_wait) {
        asm volatile ("yield");
    }
}

/// Busy-wait for specified number of milliseconds
pub fn delayMillis(ms: u64) void {
    delayMicros(ms * 1000);
}
