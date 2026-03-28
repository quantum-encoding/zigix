/// UEFI Console Output Utilities
///
/// Provides ASCII-friendly print functions over UEFI SimpleTextOutput,
/// which requires UCS-2 (UTF-16LE) strings.

const std = @import("std");
const uefi = std.os.uefi;

pub const Console = struct {
    con_out: *uefi.protocol.SimpleTextOutput,

    pub fn init(system_table: *uefi.tables.SystemTable) ?Console {
        const con_out = system_table.con_out orelse return null;
        return .{ .con_out = con_out };
    }

    /// Print an ASCII string to the UEFI console.
    /// Converts each byte to UCS-2 on the fly.
    pub fn puts(self: Console, msg: []const u8) void {
        for (msg) |c| {
            if (c == '\n') {
                // UEFI console needs \r\n for newline
                var cr: [1:0]u16 = .{'\r'};
                _ = self.con_out.outputString(&cr) catch {};
            }
            var buf: [1:0]u16 = .{@as(u16, c)};
            _ = self.con_out.outputString(&buf) catch {};
        }
    }

    /// Print a hexadecimal value (e.g., "0x40080000").
    pub fn putHex(self: Console, value: u64) void {
        self.puts("0x");
        const hex_chars = "0123456789abcdef";

        // Find first non-zero nibble (or print "0" for value 0)
        var started = false;
        var i: u6 = 60;
        while (true) : (i -= 4) {
            const nibble: u4 = @truncate((value >> i) & 0xF);
            if (nibble != 0) started = true;
            if (started) {
                var buf: [1:0]u16 = .{@as(u16, hex_chars[nibble])};
                _ = self.con_out.outputString(&buf) catch {};
            }
            if (i == 0) break;
        }
        if (!started) {
            var buf: [1:0]u16 = .{'0'};
            _ = self.con_out.outputString(&buf) catch {};
        }
    }

    /// Print a decimal value.
    pub fn putDec(self: Console, value: u64) void {
        if (value == 0) {
            self.puts("0");
            return;
        }

        var buf: [20]u8 = undefined;
        var len: usize = 0;
        var v = value;
        while (v > 0) {
            buf[len] = @truncate((v % 10) + '0');
            v /= 10;
            len += 1;
        }

        // Reverse and print
        var i: usize = len;
        while (i > 0) {
            i -= 1;
            var out: [1:0]u16 = .{@as(u16, buf[i])};
            _ = self.con_out.outputString(&out) catch {};
        }
    }

    /// Clear the screen.
    pub fn clear(self: Console) void {
        self.con_out.clearScreen() catch {};
    }
};
