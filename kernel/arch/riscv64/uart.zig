/// RISC-V UART driver — 16550 compatible (QEMU virt).
///
/// QEMU virt machine maps a 16550 UART at 0x10000000.
/// Same interface as ARM64 uart.zig and x86_64 serial.zig.

const UART_BASE: usize = 0x10000000;

// 16550 register offsets
const THR: usize = 0; // Transmit Holding Register (write)
const RBR: usize = 0; // Receive Buffer Register (read)
const IER: usize = 1; // Interrupt Enable Register
const FCR: usize = 2; // FIFO Control Register (write)
const LCR: usize = 3; // Line Control Register
const LSR: usize = 5; // Line Status Register

// LSR bits
const LSR_THRE: u8 = 1 << 5; // Transmit Holding Register Empty
const LSR_DR: u8 = 1 << 0; // Data Ready

var uart_initialized: bool = false;

pub fn init() void {
    const ier: *volatile u8 = @ptrFromInt(UART_BASE + IER);
    const fcr: *volatile u8 = @ptrFromInt(UART_BASE + FCR);
    const lcr: *volatile u8 = @ptrFromInt(UART_BASE + LCR);

    // Disable interrupts
    ier.* = 0x00;
    // Enable FIFO, clear TX/RX, 14-byte trigger
    fcr.* = 0xC7;
    // 8 bits, no parity, 1 stop bit (8N1)
    lcr.* = 0x03;

    uart_initialized = true;
}

/// Write a single byte to the UART. Spins until TX holding register is empty.
pub fn writeByte(byte: u8) void {
    const thr: *volatile u8 = @ptrFromInt(UART_BASE + THR);
    const lsr: *volatile u8 = @ptrFromInt(UART_BASE + LSR);

    // Wait for transmit holding register to be empty
    while ((lsr.* & LSR_THRE) == 0) {}
    thr.* = byte;
}

/// Write a string to the UART.
pub fn writeString(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

/// Read a byte from UART (non-blocking). Returns null if no data.
pub fn readByte() ?u8 {
    const rbr: *volatile u8 = @ptrFromInt(UART_BASE + RBR);
    const lsr: *volatile u8 = @ptrFromInt(UART_BASE + LSR);

    if ((lsr.* & LSR_DR) != 0) {
        return rbr.*;
    }
    return null;
}

/// Write a 64-bit hex value.
pub fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    writeString(&buf);
}

/// Write a decimal value.
pub fn writeDec(value: u64) void {
    if (value == 0) {
        writeByte('0');
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
    writeString(buf[i..]);
}

/// Formatted print (simplified — supports {} for decimal and {x} for hex).
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const ArgsType = @TypeOf(args);
    const fields = @typeInfo(ArgsType).@"struct".fields;
    comptime var arg_idx: usize = 0;
    comptime var i: usize = 0;

    inline while (i < fmt.len) {
        if (fmt[i] == '{') {
            if (i + 1 < fmt.len and fmt[i + 1] == '}') {
                // {} — decimal
                if (arg_idx < fields.len) {
                    writeDec(@as(u64, @intCast(@field(args, fields[arg_idx].name))));
                    arg_idx += 1;
                }
                i += 2;
            } else if (i + 2 < fmt.len and fmt[i + 1] == 'x' and fmt[i + 2] == '}') {
                // {x} — hex
                if (arg_idx < fields.len) {
                    writeHex(@as(u64, @intCast(@field(args, fields[arg_idx].name))));
                    arg_idx += 1;
                }
                i += 3;
            } else {
                writeByte(fmt[i]);
                i += 1;
            }
        } else {
            if (fmt[i] == '\n') writeByte('\r');
            writeByte(fmt[i]);
            i += 1;
        }
    }
}
