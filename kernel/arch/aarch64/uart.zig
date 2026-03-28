/// PL011 UART driver for ARM64
/// QEMU virt machine places PL011 at 0x09000000
///
/// This provides the same interface as x86_64/serial.zig:
/// - init(), writeByte(), writeString(), print()
/// - readByte(), hasData(), rxInterrupt()

const std = @import("std");
const spinlock = @import("spinlock.zig");
const fdt = @import("fdt.zig");

// UART base address — dynamic, updated from FDT or ACPI
var uart_base: usize = 0x09000000; // Default: QEMU virt PL011
const QEMU_UART_BASE: usize = 0x09000000;
const REAL_HW_UART_BASE: usize = 0x040D0000; // Orange Pi 6 Plus debug UART2

// PL011 register offsets
const UARTDR: usize = 0x00;    // Data Register
const UARTFR: usize = 0x18;    // Flag Register
const UARTIBRD: usize = 0x24;  // Integer Baud Rate Divisor
const UARTFBRD: usize = 0x28;  // Fractional Baud Rate Divisor
const UARTLCR_H: usize = 0x2C; // Line Control Register
const UARTCR: usize = 0x30;    // Control Register
const UARTIMSC: usize = 0x38;  // Interrupt Mask Set/Clear
const UARTRIS: usize = 0x3C;   // Raw Interrupt Status
const UARTICR: usize = 0x44;   // Interrupt Clear Register

// Flag register bits
const UARTFR_TXFF: u32 = 1 << 5;  // TX FIFO full
const UARTFR_RXFE: u32 = 1 << 4;  // RX FIFO empty
const UARTFR_BUSY: u32 = 1 << 3;  // UART busy

// Interrupt bits
const UARTIMSC_RXIM: u32 = 1 << 4;  // RX interrupt mask

var initialized = false;

/// SMP locks — prevent interleaved output and RX buffer corruption.
var uart_tx_lock: spinlock.IrqSpinlock = .{};
var uart_rx_lock: spinlock.IrqSpinlock = .{};

// RX ring buffer (filled by IRQ handler)
const RX_BUF_SIZE: usize = 256;
var rx_buf: [RX_BUF_SIZE]u8 = undefined;
var rx_head: usize = 0;
var rx_tail: usize = 0;
var rx_count: usize = 0;

/// PID of process blocked waiting for serial input (0 = none)
pub var waiting_pid: u64 = 0;
pub var fg_pgid: u32 = 0;

// NS16550 register offsets
const NS16550_THR: usize = 0x00;    // Transmit Holding Register
const NS16550_RBR: usize = 0x00;    // Receive Buffer Register
const NS16550_IER: usize = 0x01;    // Interrupt Enable Register
const NS16550_FCR: usize = 0x02;    // FIFO Control Register
const NS16550_LCR: usize = 0x03;    // Line Control Register
const NS16550_MCR: usize = 0x04;    // Modem Control Register
const NS16550_LSR: usize = 0x05;    // Line Status Register
const NS16550_LSR_THRE: u8 = 1 << 5; // TX Holding Register Empty
const NS16550_LSR_DR: u8 = 1 << 0;   // Data Ready

/// UART type — determines which driver functions to use
var is_ns16550: bool = false;

// MMIO helpers with proper memory barriers
inline fn mmioWrite(offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(uart_base + offset);
    ptr.* = value;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

inline fn mmioRead(offset: usize) u32 {
    asm volatile ("dmb sy" ::: .{ .memory = true });
    const ptr: *volatile u32 = @ptrFromInt(uart_base + offset);
    return ptr.*;
}

// NS16550 MMIO helpers (byte-wide registers)
inline fn ns16550Write(offset: usize, value: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(uart_base + offset);
    ptr.* = value;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

inline fn ns16550Read(offset: usize) u8 {
    asm volatile ("dmb sy" ::: .{ .memory = true });
    const ptr: *volatile u8 = @ptrFromInt(uart_base + offset);
    return ptr.*;
}

/// Check RX state integrity. Call from boot.zig to track down corruption.
pub fn checkRxState(label: []const u8) void {
    if (rx_head >= RX_BUF_SIZE or rx_tail >= RX_BUF_SIZE or rx_count > RX_BUF_SIZE) {
        writeString("[uart] CORRUPT ");
        writeString(label);
        writeString(" head=");
        writeHex(rx_head);
        writeString(" tail=");
        writeHex(rx_tail);
        writeString(" count=");
        writeHex(rx_count);
        writeString("\n");
    }
}

/// Parse ACPI SPCR table to find the real serial console UART.
/// GCE Axion (c4a) provides SPCR with the correct UART base and type.
/// Must be called before init() if booting via UEFI (no FDT).
pub fn initFromSpcr(spcr_addr: u64) void {
    const spcr: [*]const u8 = @ptrFromInt(spcr_addr);
    // Offset 36: Interface Type (1 byte)
    const iface_type = spcr[36];
    // Offset 40-51: Base Address GAS (12 bytes: space_id, bit_width, bit_offset, access_size, address[8])
    const base_addr = @as(*align(1) const u64, @ptrCast(spcr + 44)).*;

    if (base_addr != 0 and base_addr < 0x100000000) {
        uart_base = @truncate(base_addr);
        // Interface types: 0=full 16550, 1=16550 subset, 3=ARM PL011, 0x0E=ARM SBSA
        is_ns16550 = (iface_type == 0 or iface_type == 1 or iface_type == 0x12);
    }
}

pub fn init() void {
    // Explicitly initialize RX state — BSS clear should handle this,
    // but Zig Debug mode may rewrite undefined globals after BSS clear.
    rx_head = 0;
    rx_tail = 0;
    rx_count = 0;

    // Apply dynamic UART base from FDT (if parsed before UART init)
    if (fdt.config.valid) {
        uart_base = @truncate(fdt.config.uart_base);
        is_ns16550 = (fdt.config.uart_type == .ns16550);
    }

    if (is_ns16550) {
        initNs16550();
    } else {
        initPl011();
    }

    initialized = true;
    writeString("[boot] UART initialized (");
    if (is_ns16550) {
        writeString("NS16550");
    } else {
        writeString("PL011");
    }
    writeString(") base=");
    writeHex(uart_base);
    writeString("\n");
}

fn initPl011() void {
    // Disable UART while configuring
    mmioWrite(UARTCR, 0);

    // Clear pending interrupts
    mmioWrite(UARTICR, 0x7FF);

    // Set baud rate to 115200 based on clock source:
    //   QEMU virt: 24MHz UARTCLK → IBRD=13, FBRD=1
    //   Orange Pi 6 Plus: 100MHz UARTCLK → IBRD=54, FBRD=17
    if (uart_base == REAL_HW_UART_BASE) {
        // 100MHz / (16 * 115200) = 54.253 → IBRD=54, FBRD=round(0.253*64)=16
        mmioWrite(UARTIBRD, 54);
        mmioWrite(UARTFBRD, 16);
    } else {
        // 24MHz / (16 * 115200) = 13.02 → IBRD=13, FBRD=1
        mmioWrite(UARTIBRD, 13);
        mmioWrite(UARTFBRD, 1);
    }

    // 8 bits, no parity, 1 stop bit, enable FIFOs
    mmioWrite(UARTLCR_H, (3 << 5) | (1 << 4)); // WLEN=8, FEN=1

    // Enable UART, TX, and RX
    mmioWrite(UARTCR, (1 << 0) | (1 << 8) | (1 << 9)); // UARTEN, TXE, RXE

    // Enable RX interrupt
    mmioWrite(UARTIMSC, UARTIMSC_RXIM);
}

fn initNs16550() void {
    // Disable all interrupts
    ns16550Write(NS16550_IER, 0x00);

    // Enable FIFO, clear TX/RX, 14-byte trigger
    ns16550Write(NS16550_FCR, 0xC7);

    // 8 bits, no parity, 1 stop bit
    ns16550Write(NS16550_LCR, 0x03);

    // DTR + RTS + OUT2 (enables interrupt delivery)
    ns16550Write(NS16550_MCR, 0x0B);

    // Enable RX interrupt (bit 0 = received data available)
    ns16550Write(NS16550_IER, 0x01);
}

fn isTxFifoFull() bool {
    if (is_ns16550) {
        return (ns16550Read(NS16550_LSR) & NS16550_LSR_THRE) == 0;
    }
    return (mmioRead(UARTFR) & UARTFR_TXFF) != 0;
}

fn isRxFifoEmpty() bool {
    if (is_ns16550) {
        return (ns16550Read(NS16550_LSR) & NS16550_LSR_DR) == 0;
    }
    return (mmioRead(UARTFR) & UARTFR_RXFE) != 0;
}

/// Write a single byte (acquires TX lock).
pub fn writeByte(byte: u8) void {
    uart_tx_lock.acquire();
    defer uart_tx_lock.release();
    writeByteRaw(byte);
}

/// Write a string atomically (acquires TX lock).
pub fn writeString(s: []const u8) void {
    uart_tx_lock.acquire();
    defer uart_tx_lock.release();
    writeStringRaw(s);
}

/// Write a hex number atomically (acquires TX lock).
pub fn writeHex(val: u64) void {
    uart_tx_lock.acquire();
    defer uart_tx_lock.release();
    writeHexRaw(val);
}

/// Write a decimal number atomically (acquires TX lock).
pub fn writeDec(val: u64) void {
    uart_tx_lock.acquire();
    defer uart_tx_lock.release();
    writeDecRaw(val);
}

/// Write a byte as 2-digit zero-padded hex (acquires TX lock).
pub fn writeHexByte(val: u8) void {
    uart_tx_lock.acquire();
    defer uart_tx_lock.release();
    writeHexPadRaw(val, 2);
}

/// PCI device discovery log line with zero-padded hex fields.
/// Produces: [pci]  BB:DD.F vendor=VVVV device=DDDD class=CC:SS:PP
pub fn printPci(bus: u8, dev: u8, func: u8, vendor: u16, device: u16, class: u8, subclass: u8, prog_if: u8) void {
    uart_tx_lock.acquire();
    defer uart_tx_lock.release();
    writeStringRaw("[pci]  ");
    writeHexPadRaw(bus, 2);
    writeByteRaw(':');
    writeHexPadRaw(dev, 2);
    writeByteRaw('.');
    writeDecRaw(func);
    writeStringRaw(" vendor=");
    writeHexPadRaw(vendor, 4);
    writeStringRaw(" device=");
    writeHexPadRaw(device, 4);
    writeStringRaw(" class=");
    writeHexPadRaw(class, 2);
    writeByteRaw(':');
    writeHexPadRaw(subclass, 2);
    writeByteRaw(':');
    writeHexPadRaw(prog_if, 2);
}

/// Formatted print — holds TX lock for entire output (no interleaving).
pub fn print(comptime fmt: []const u8, args: anytype) void {
    uart_tx_lock.acquire();
    defer uart_tx_lock.release();

    const ArgsType = @TypeOf(args);
    const fields = @typeInfo(ArgsType).@"struct".fields;

    comptime var arg_idx: usize = 0;
    comptime var i: usize = 0;

    inline while (i < fmt.len) {
        if (fmt[i] == '{') {
            if (i + 1 < fmt.len and fmt[i + 1] == '}') {
                if (arg_idx < fields.len) {
                    const val = @field(args, fields[arg_idx].name);
                    const T = @TypeOf(val);
                    const info = @typeInfo(T);
                    if (info == .int and info.int.signedness == .signed) {
                        if (val < 0) {
                            writeByteRaw('-');
                            writeDecRaw(@as(u64, @intCast(-%val)));
                        } else {
                            writeDecRaw(@as(u64, @intCast(val)));
                        }
                    } else {
                        writeDecRaw(@as(u64, @intCast(val)));
                    }
                    arg_idx += 1;
                }
                i += 2;
            } else if (i + 2 < fmt.len and fmt[i + 1] == 'x' and fmt[i + 2] == '}') {
                if (arg_idx < fields.len) {
                    const val = @field(args, fields[arg_idx].name);
                    const Tx = @TypeOf(val);
                    const infox = @typeInfo(Tx);
                    writeStringRaw("0x");
                    if (infox == .int and infox.int.signedness == .signed) {
                        writeHexRaw(@bitCast(@as(i64, @intCast(val))));
                    } else {
                        writeHexRaw(@as(u64, @intCast(val)));
                    }
                    arg_idx += 1;
                }
                i += 3;
            } else {
                writeByteRaw(fmt[i]);
                i += 1;
            }
        } else {
            writeByteRaw(fmt[i]);
            i += 1;
        }
    }
}

// --- Internal raw TX functions (no lock, caller must hold uart_tx_lock) ---

/// Lock-free crash output — bypasses UART TX lock for use in panic/trap
/// handlers where the other CPU may hold the lock indefinitely.
/// Output may interleave with the other CPU, but at least it prints.
pub fn crashString(s: []const u8) void {
    writeStringRaw(s);
}
pub fn crashHex(val: u64) void {
    writeHexRaw(val);
}
pub fn crashDec(val: u64) void {
    writeDecRaw(val);
}
pub fn crashByte(byte: u8) void {
    writeByteRaw(byte);
}

fn writeByteRaw(byte: u8) void {
    if (!initialized) return;
    while (isTxFifoFull()) {
        asm volatile ("yield");
    }
    if (is_ns16550) {
        ns16550Write(NS16550_THR, byte);
    } else {
        mmioWrite(UARTDR, byte);
    }
}

fn writeStringRaw(s: []const u8) void {
    for (s) |byte| {
        if (byte == '\n') {
            writeByteRaw('\r');
        }
        writeByteRaw(byte);
    }
}

fn writeHexRaw(val: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = val;
    var idx: usize = 16;
    while (idx > 0) {
        idx -= 1;
        buf[idx] = hex[@as(usize, @truncate(v & 0xF))];
        v >>= 4;
    }
    var start: usize = 0;
    while (start < 15 and buf[start] == '0') start += 1;
    writeStringRaw(buf[start..]);
}

/// Write a hex value zero-padded to exactly `width` nibbles (no 0x prefix).
fn writeHexPadRaw(val: u64, comptime width: u8) void {
    const hex = "0123456789abcdef";
    comptime var i: u8 = width;
    inline while (i > 0) {
        i -= 1;
        writeByteRaw(hex[@as(usize, @truncate((val >> (i * 4)) & 0xF))]);
    }
}

fn writeDecRaw(val: u64) void {
    if (val == 0) {
        writeByteRaw('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var v = val;
    var idx: usize = 20;
    while (v > 0) {
        idx -= 1;
        buf[idx] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
    }
    writeStringRaw(buf[idx..]);
}

// --- RX input functions ---

/// Called from IRQ handler. Reads all available bytes into ring buffer.
/// Bytes starting with '>' are routed to the klog command parser.
pub fn rxInterrupt() void {
    uart_rx_lock.acquire();

    // Read while RX FIFO has data
    while (!isRxFifoEmpty()) {
        const byte: u8 = if (is_ns16550)
            ns16550Read(NS16550_RBR)
        else
            @truncate(mmioRead(UARTDR) & 0xFF);

        // klog command parser disabled: testing NVMe fix in isolation
        // if (klog.feedCommandByte(byte)) continue;

        if (rx_count < RX_BUF_SIZE) {
            rx_buf[rx_head] = byte;
            rx_head = (rx_head + 1) % RX_BUF_SIZE;
            rx_count += 1;
        }
    }

    // Clear RX interrupt (PL011 only; NS16550 auto-clears on read)
    if (!is_ns16550) {
        mmioWrite(UARTICR, UARTIMSC_RXIM);
    }

    const should_wake = waiting_pid != 0 and rx_count > 0;
    const pid = waiting_pid;
    if (should_wake) waiting_pid = 0;

    uart_rx_lock.release();

    // Wake outside of lock to avoid lock ordering issues with scheduler
    if (should_wake) {
        const sched = @import("scheduler.zig");
        sched.wakeProcess(pid);
    }
}

/// Read one byte from RX buffer. Returns null if empty.
pub fn readByte() ?u8 {
    uart_rx_lock.acquire();
    defer uart_rx_lock.release();

    if (rx_count == 0) return null;
    const byte = rx_buf[rx_tail];
    rx_tail = (rx_tail + 1) % RX_BUF_SIZE;
    rx_count -= 1;
    return byte;
}

/// Check if RX buffer has data available.
pub fn hasData() bool {
    return rx_count > 0;
}

/// Poll UART RX — called from timer tick as fallback when RX interrupt
/// doesn't fire (GCE serial console may not trigger PL011 IRQ).
pub fn pollRx() void {
    if (is_ns16550) {
        if ((ns16550Read(NS16550_LSR) & NS16550_LSR_DR) != 0) {
            rxInterrupt();
        }
    } else {
        if (!isRxFifoEmpty()) {
            rxInterrupt();
        }
    }
}

/// Parse ACPI DBG2 table to find alternate debug UART.
/// GCE may route serial console input through a debug port at a different address.
pub fn initFromDbg2(dbg2_addr: u64) void {
    const dbg2: [*]const u8 = @ptrFromInt(dbg2_addr);
    // DBG2 header: 36 bytes standard + 4 bytes offset to device info + 4 bytes num_entries
    const info_offset = @as(*align(1) const u32, @ptrCast(dbg2 + 36)).*;
    if (info_offset == 0 or info_offset > 200) return;

    // Device info at offset: revision(1), length(2), num_regs(1), str_len(2), str_off(2),
    //   namespace_len(2), namespace_off(2), port_type(2), port_subtype(2), reserved(2),
    //   base_addr_off(2), addr_size_off(2)
    const info: [*]const u8 = @ptrFromInt(dbg2_addr + info_offset);
    const port_type = @as(*align(1) const u16, @ptrCast(info + 12)).*;
    const port_subtype = @as(*align(1) const u16, @ptrCast(info + 14)).*;
    const base_off = @as(*align(1) const u16, @ptrCast(info + 18)).*;

    if (base_off == 0) return;
    // GAS at info + base_off: space_id(1), bit_width(1), bit_offset(1), access_size(1), address(8)
    const gas: [*]const u8 = @ptrFromInt(dbg2_addr + info_offset + base_off);
    const base = @as(*align(1) const u64, @ptrCast(gas + 4)).*;

    if (base != 0 and base < 0x100000000 and base != uart_base) {
        writeString("[uart] DBG2: port_type=");
        writeHex(port_type);
        writeString(" subtype=");
        writeHex(port_subtype);
        writeString(" base=");
        writeHex(base);
        writeString("\n");
    }
}
