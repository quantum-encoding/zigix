/// Text formatter — converts structured LogEntry to human-readable serial output.
/// Format: [tick][LVL][subsystem] message key=value key=value
///
/// Formatting only happens on output (drain/dump), never in the hot logging path.

const ring = @import("ring.zig");
const sub = @import("subsystems.zig");

/// Format a single log entry into the provided buffer.
/// Returns the number of bytes written.
pub fn formatEntry(entry: *const ring.LogEntry, buf: []u8) usize {
    var pos: usize = 0;

    // [tick]
    pos = appendByte(buf, pos, '[');
    pos = appendDecimal(buf, pos, entry.tick);
    pos = appendByte(buf, pos, ']');

    // [LVL]
    pos = appendByte(buf, pos, '[');
    const lvl = entry.level.label();
    pos = appendSlice(buf, pos, lvl);
    pos = appendByte(buf, pos, ']');

    // [subsystem]
    pos = appendByte(buf, pos, '[');
    const tag = entry.subsystem.tag();
    pos = appendSlice(buf, pos, tag);
    pos = appendByte(buf, pos, ']');

    // space + message
    pos = appendByte(buf, pos, ' ');
    pos = appendSlice(buf, pos, entry.msgSlice());

    // key=value pairs
    for (0..entry.field_count) |i| {
        const field = &entry.fields[i];
        pos = appendByte(buf, pos, ' ');
        pos = appendSlice(buf, pos, field.keySlice());
        pos = appendByte(buf, pos, '=');
        pos = appendHex(buf, pos, field.value);
    }

    // newline
    pos = appendByte(buf, pos, '\n');

    return pos;
}

/// Format an entry for panic output — prefixed with "!" for visibility.
pub fn formatPanicEntry(entry: *const ring.LogEntry, buf: []u8) usize {
    var pos: usize = 0;
    pos = appendByte(buf, pos, '!');
    pos += formatEntry(entry, buf[pos..]);
    return pos;
}

// --- Internal formatting helpers (no std.fmt, no allocation) ---

fn appendByte(buf: []u8, pos: usize, byte: u8) usize {
    if (pos < buf.len) {
        buf[pos] = byte;
        return pos + 1;
    }
    return pos;
}

fn appendSlice(buf: []u8, pos: usize, s: []const u8) usize {
    var p = pos;
    for (s) |byte| {
        if (p >= buf.len) break;
        buf[p] = byte;
        p += 1;
    }
    return p;
}

fn appendDecimal(buf: []u8, pos: usize, value: u64) usize {
    if (value == 0) {
        return appendByte(buf, pos, '0');
    }

    var tmp: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        tmp[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    return appendSlice(buf, pos, tmp[i..]);
}

fn appendHex(buf: []u8, pos: usize, value: u64) usize {
    const hex_chars = "0123456789abcdef";

    // Special case: small values get decimal output for readability
    if (value < 4096) {
        return appendDecimal(buf, pos, value);
    }

    // Large values get 0x prefix + hex
    var p = pos;
    p = appendByte(buf, p, '0');
    p = appendByte(buf, p, 'x');

    // Find first non-zero nibble
    var started = false;
    var shift: u6 = 60;
    while (true) {
        const nibble: u4 = @truncate(value >> shift);
        if (nibble != 0) started = true;
        if (started) {
            p = appendByte(buf, p, hex_chars[nibble]);
        }
        if (shift == 0) break;
        shift -= 4;
    }

    // Edge case: value was 0 but >= 4096 (shouldn't happen, but be safe)
    if (!started) {
        p = appendByte(buf, p, '0');
    }

    return p;
}
