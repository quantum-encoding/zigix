/// COM1 UART serial driver — 115200 baud, 8N1.
/// Provides the earliest possible debug output channel.
/// RX: IRQ 4-driven ring buffer for interactive input.

const io = @import("io.zig");
const spinlock_mod = @import("spinlock.zig");

/// SMP lock for serial output — prevents interleaved messages from different CPUs.
pub var serial_lock: spinlock_mod.IrqSpinlock = .{};

const COM1: u16 = 0x3F8;

// Register offsets from base
const DATA: u16 = 0; // Data / Divisor Latch Low (DLAB=1)
const IER: u16 = 1; // Interrupt Enable / Divisor Latch High (DLAB=1)
const FCR: u16 = 2; // FIFO Control
const LCR: u16 = 3; // Line Control (bit 7 = DLAB)
const MCR: u16 = 4; // Modem Control
const LSR: u16 = 5; // Line Status

var initialized = false;

// Console output hook — set by framebuffer console after init
pub var console_hook: ?*const fn ([*]const u8, usize) void = null;

// --- RX ring buffer (filled by IRQ 4 handler) ---
const RX_BUF_SIZE: usize = 256;
var rx_buf: [RX_BUF_SIZE]u8 = undefined;
var rx_head: usize = 0; // Next write position
var rx_tail: usize = 0; // Next read position
var rx_count: usize = 0; // Bytes available

/// PID of a process blocked waiting for serial input (0 = none).
pub var waiting_pid: u64 = 0;

/// Process group ID of the foreground group (0 = none).
/// Ctrl-C/Ctrl-Z send signals to all processes in this group.
pub var fg_pgid: u64 = 0;

pub fn init() void {
    // Skip loopback self-test — GCE virtual COM1 may not support it,
    // and we already confirmed the port works via earlySerialStr.
    // Just configure the port and mark it initialized.

    // Disable all interrupts
    io.outb(COM1 + IER, 0x00);

    // Enable DLAB to set baud rate divisor
    io.outb(COM1 + LCR, 0x80);

    // Set divisor to 1 → 115200 baud
    io.outb(COM1 + DATA, 0x01); // Low byte
    io.outb(COM1 + IER, 0x00); // High byte

    // 8 bits, no parity, one stop bit (8N1), clear DLAB
    io.outb(COM1 + LCR, 0x03);

    // Enable FIFO, clear TX/RX queues, 14-byte threshold
    io.outb(COM1 + FCR, 0xC7);

    // Normal operation mode: OUT1+OUT2+RTS+DTR
    io.outb(COM1 + MCR, 0x0F);
    initialized = true;

    // Enable receive data available interrupt (bit 0 of IER)
    // This fires IRQ 4 when a byte arrives on COM1
    io.outb(COM1 + IER, 0x01);
}

fn isTransmitEmpty() bool {
    return (io.inb(COM1 + LSR) & 0x20) != 0;
}

pub fn writeByte(byte: u8) void {
    if (!initialized) return;

    // Wait for transmit holding register to be empty
    while (!isTransmitEmpty()) {
        asm volatile ("pause");
    }
    io.outb(COM1 + DATA, byte);
}

pub fn writeString(s: []const u8) void {
    const flags = serial_lock.acquire();
    defer serial_lock.release(flags);
    writeStringUnlocked(s);
}

/// Write string without acquiring serial_lock — caller must hold it.
pub fn writeStringUnlocked(s: []const u8) void {
    for (s) |byte| {
        if (byte == '\n') {
            writeByte('\r');
        }
        writeByte(byte);
    }
    // Mirror to framebuffer console if available
    if (console_hook) |hook| {
        hook(s.ptr, s.len);
    }
}

/// Write a formatted string (uses a fixed stack buffer)
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = @import("std").fmt.bufPrint(&buf, fmt, args) catch {
        writeString("(fmt overflow)");
        return;
    };
    writeString(s);
}

// --- RX input functions ---

/// Called from IRQ 4 handler. Reads all available bytes from COM1 into the ring buffer.
/// Ctrl-C (0x03) and Ctrl-Z (0x1A) are intercepted and converted to signals.
/// Bytes starting with '>' are routed to the klog command parser.
pub fn rxInterrupt() void {
    const signal = @import("../../proc/signal.zig");
    const klog = @import("../../klog/klog.zig");

    // Read while data is available (LSR bit 0 = data ready)
    while ((io.inb(COM1 + LSR) & 0x01) != 0) {
        const byte = io.inb(COM1 + DATA);

        // Route to klog command parser (handles '>' prefix internally)
        if (klog.feedCommandByte(byte)) continue;

        // Ctrl-C → SIGINT to foreground process group
        if (byte == 0x03) {
            if (fg_pgid != 0) {
                sendSignalToForeground(signal.SIGINT);
            }
            continue; // Don't queue the byte
        }

        // Ctrl-Z → SIGTSTP to foreground process group
        if (byte == 0x1A) {
            if (fg_pgid != 0) {
                sendSignalToForeground(signal.SIGTSTP);
            }
            continue; // Don't queue the byte
        }

        if (rx_count < RX_BUF_SIZE) {
            rx_buf[rx_head] = byte;
            rx_head = (rx_head + 1) % RX_BUF_SIZE;
            rx_count += 1;
        }
        // If buffer full, drop the byte (overrun)
    }

    // Wake process waiting for input
    if (waiting_pid != 0 and rx_count > 0) {
        const sched = @import("../../proc/scheduler.zig");
        const pid = waiting_pid;
        waiting_pid = 0;
        sched.wakeProcess(pid);
    }
}

/// Send a signal to all processes in the foreground process group.
fn sendSignalToForeground(sig: u6) void {
    const process_mod = @import("../../proc/process.zig");
    const signal = @import("../../proc/signal.zig");

    for (0..process_mod.MAX_PROCESSES) |i| {
        if (process_mod.getProcess(i)) |p| {
            if (p.pgid == fg_pgid and p.state != .zombie) {
                signal.postSignal(p, sig);
            }
        }
    }
}

/// Push a byte into the input ring buffer (used by PS/2 keyboard driver).
/// Also handles Ctrl-C/Ctrl-Z signal dispatch and wakes blocked reader.
pub fn pushInputByte(byte: u8) void {
    const signal = @import("../../proc/signal.zig");

    // Ctrl-C → SIGINT
    if (byte == 0x03) {
        if (fg_pgid != 0) sendSignalToForeground(signal.SIGINT);
        return;
    }
    // Ctrl-Z → SIGTSTP
    if (byte == 0x1A) {
        if (fg_pgid != 0) sendSignalToForeground(signal.SIGTSTP);
        return;
    }

    if (rx_count < RX_BUF_SIZE) {
        rx_buf[rx_head] = byte;
        rx_head = (rx_head + 1) % RX_BUF_SIZE;
        rx_count += 1;
    }

    // Wake process waiting for input
    if (waiting_pid != 0 and rx_count > 0) {
        const sched = @import("../../proc/scheduler.zig");
        const pid = waiting_pid;
        waiting_pid = 0;
        sched.wakeProcess(pid);
    }
}

/// Read one byte from the RX ring buffer. Returns null if empty.
pub fn readByte() ?u8 {
    if (rx_count == 0) return null;
    const byte = rx_buf[rx_tail];
    rx_tail = (rx_tail + 1) % RX_BUF_SIZE;
    rx_count -= 1;
    return byte;
}

/// Check if the RX buffer has data available.
pub fn hasData() bool {
    return rx_count > 0;
}
