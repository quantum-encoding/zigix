/// Serial command parser for runtime log control.
/// Processes commands received on serial input (prefixed with '>').
///
/// Commands:
///   >filter nvme=debug ext2=info *=warn   — set per-subsystem runtime levels
///   >dump 100                              — dump last 100 entries
///   >stats                                 — show per-subsystem entry counts
///   >clear                                 — reset ring buffer
///   >on nvme                               — enable subsystem
///   >off nvme                              — disable subsystem
///   >level debug                           — set global minimum level

const serial_sink = @import("serial_sink.zig");
const ring = @import("ring.zig");
const sub = @import("subsystems.zig");

/// Thin wrappers that delegate to serial_sink's registered output functions.
const serial = struct {
    pub fn writeString(s: []const u8) void {
        serial_sink.writeStr(s);
    }
    pub fn writeByte(byte: u8) void {
        serial_sink.writeCh(byte);
    }
};

/// Command input buffer — accumulated from serial byte-by-byte.
var cmd_buf: [256]u8 = .{0} ** 256;
var cmd_len: usize = 0;
var in_command: bool = false;

/// Feed a single byte from serial input.
/// Returns true if a command was fully parsed and executed.
pub fn feedByte(byte: u8) bool {
    // '>' starts a command
    if (byte == '>' and !in_command) {
        in_command = true;
        cmd_len = 0;
        return false;
    }

    if (!in_command) return false;

    // Newline or carriage return = execute
    if (byte == '\n' or byte == '\r') {
        if (cmd_len > 0) {
            execute(cmd_buf[0..cmd_len]);
        }
        in_command = false;
        cmd_len = 0;
        return true;
    }

    // Backspace
    if (byte == 0x7F or byte == 0x08) {
        if (cmd_len > 0) cmd_len -= 1;
        return false;
    }

    // Accumulate
    if (cmd_len < cmd_buf.len - 1) {
        cmd_buf[cmd_len] = byte;
        cmd_len += 1;
    }

    return false;
}

fn execute(cmd: []const u8) void {
    // Skip leading whitespace
    var s = cmd;
    while (s.len > 0 and s[0] == ' ') s = s[1..];

    if (startsWith(s, "dump")) {
        const arg = skipWord(s);
        const n = parseDecimal(arg) orelse 50;
        serial_sink.dumpLast(n);
    } else if (startsWith(s, "stats")) {
        serial_sink.printStats();
    } else if (startsWith(s, "clear")) {
        ring.clear();
        serial.writeString("[klog] ring buffer cleared\n");
    } else if (startsWith(s, "level")) {
        const arg = skipWord(s);
        if (parseLevel(arg)) |level| {
            serial_sink.setMinLevel(level);
            serial.writeString("[klog] global level set to ");
            serial.writeString(level.label());
            serial.writeString("\n");
        } else {
            serial.writeString("[klog] unknown level (trace/debug/info/warn/err/fatal)\n");
        }
    } else if (startsWith(s, "on")) {
        const arg = skipWord(s);
        if (parseSubsystem(arg)) |subsys| {
            serial_sink.setSubEnabled(subsys, true);
            serial.writeString("[klog] enabled ");
            serial.writeString(subsys.tag());
            serial.writeString("\n");
        } else {
            serial_sink.enableAll();
            serial.writeString("[klog] all subsystems enabled\n");
        }
    } else if (startsWith(s, "off")) {
        const arg = skipWord(s);
        if (parseSubsystem(arg)) |subsys| {
            serial_sink.setSubEnabled(subsys, false);
            serial.writeString("[klog] disabled ");
            serial.writeString(subsys.tag());
            serial.writeString("\n");
        } else {
            serial.writeString("[klog] usage: >off <subsystem>\n");
        }
    } else if (startsWith(s, "filter")) {
        parseFilterCommand(s);
    } else if (startsWith(s, "help")) {
        serial.writeString("[klog] commands: dump [N], stats, clear, level <lvl>, on/off <sub>, filter <sub>=<lvl>...\n");
    } else {
        serial.writeString("[klog] unknown command: ");
        serial.writeString(s);
        serial.writeString(" (try >help)\n");
    }
}

fn parseFilterCommand(cmd: []const u8) void {
    // Skip "filter" word
    var s = skipWord(cmd);

    var count: usize = 0;
    // Parse space-separated sub=level pairs
    while (s.len > 0) {
        // Skip whitespace
        while (s.len > 0 and s[0] == ' ') s = s[1..];
        if (s.len == 0) break;

        // Find '='
        var eq_pos: usize = 0;
        while (eq_pos < s.len and s[eq_pos] != '=') : (eq_pos += 1) {}
        if (eq_pos >= s.len) break;

        const name = s[0..eq_pos];
        s = s[eq_pos + 1 ..];

        // Find end of level (space or end)
        var end: usize = 0;
        while (end < s.len and s[end] != ' ') : (end += 1) {}
        const level_str = s[0..end];
        s = s[end..];

        if (parseLevel(level_str)) |level| {
            if (name.len == 1 and name[0] == '*') {
                // Wildcard: set all subsystems
                serial_sink.setMinLevel(level);
            } else if (parseSubsystem(name)) |subsys| {
                serial_sink.setSubLevel(subsys, level);
            }
            count += 1;
        }
    }

    serial.writeString("[klog] filter: set ");
    writeDecimal(count);
    serial.writeString(" rules\n");
}

// --- String helpers ---

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (0..prefix.len) |i| {
        if (s[i] != prefix[i]) return false;
    }
    // Must be followed by space or end-of-string
    return s.len == prefix.len or s[prefix.len] == ' ';
}

fn skipWord(s: []const u8) []const u8 {
    var i: usize = 0;
    // Skip non-space
    while (i < s.len and s[i] != ' ') : (i += 1) {}
    // Skip space
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    return s[i..];
}

fn parseDecimal(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        result = result * 10 + (c - '0');
    }
    return result;
}

fn parseLevel(s: []const u8) ?sub.Level {
    if (s.len == 0) return null;
    if (eql(s, "trace") or eql(s, "trc")) return .trace;
    if (eql(s, "debug") or eql(s, "dbg")) return .debug;
    if (eql(s, "info") or eql(s, "inf")) return .info;
    if (eql(s, "warn") or eql(s, "wrn")) return .warn;
    if (eql(s, "err")) return .err;
    if (eql(s, "fatal") or eql(s, "fat")) return .fatal;
    return null;
}

fn parseSubsystem(s: []const u8) ?sub.Subsystem {
    if (s.len == 0) return null;
    inline for (0..sub.Subsystem.COUNT) |i| {
        const subsys: sub.Subsystem = @enumFromInt(i);
        if (eql(s, subsys.tag())) return subsys;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    // Trim trailing whitespace/nulls from a for comparison
    var a_len = a.len;
    while (a_len > 0 and (a[a_len - 1] == ' ' or a[a_len - 1] == 0)) : (a_len -= 1) {}
    var b_len = b.len;
    while (b_len > 0 and (b[b_len - 1] == ' ' or b[b_len - 1] == 0)) : (b_len -= 1) {}
    if (a_len != b_len) return false;
    for (0..a_len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        serial.writeByte('0');
        return;
    }
    var tmp: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        tmp[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    serial.writeString(tmp[i..]);
}
