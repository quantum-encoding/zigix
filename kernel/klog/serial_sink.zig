/// Serial sink — writes formatted log text to the platform UART.
/// Uses function pointers for arch-independent serial I/O.
/// Handles the drain loop and panic dump.

const ring = @import("ring.zig");
const format = @import("format.zig");
const sub = @import("subsystems.zig");

/// Function pointers for serial output — set by klog.init().
var write_string_fn: ?*const fn ([]const u8) void = null;
var write_byte_fn: ?*const fn (u8) void = null;

/// Initialize the serial sink with platform-specific output functions.
pub fn initSink(
    write_string: *const fn ([]const u8) void,
    write_byte: *const fn (u8) void,
) void {
    write_string_fn = write_string;
    write_byte_fn = write_byte;
}

/// Write a string via the registered serial output.
/// Falls back to nothing if not yet initialized (early boot safety).
pub fn writeStr(s: []const u8) void {
    if (write_string_fn) |f| f(s);
}

pub fn writeCh(byte: u8) void {
    if (write_byte_fn) |f| f(byte);
}

/// Runtime filter bitmask — one bit per subsystem.
/// 1 = enabled, 0 = suppressed.
/// Initialized with all bits set (everything enabled).
var runtime_mask: u64 = 0xFFFFFFFFFFFFFFFF;

/// Runtime minimum level (applies on top of comptime filter).
/// Entries below this level are suppressed even if the subsystem bit is set.
var runtime_min_level: sub.Level = .trace;

/// Per-subsystem runtime level overrides.
/// Set to .trace by default (no override — defer to runtime_min_level).
var runtime_sub_levels: [sub.Subsystem.COUNT]sub.Level = .{sub.Level.trace} ** sub.Subsystem.COUNT;

/// Maximum entries to drain per tick (prevent serial from monopolizing IRQ context).
const MAX_DRAIN_PER_TICK: usize = 8;

/// Format buffer — shared, only used from drain path (IRQ context, interrupts off).
var fmt_buf: [512]u8 = undefined;

/// Drain pending entries to serial.
/// Called from the timer tick handler. Interrupts are off, safe to use shared buffer.
/// Drains up to MAX_DRAIN_PER_TICK entries per call to bound serial time.
pub fn drain() void {
    if (write_string_fn == null) return;
    var count: usize = 0;
    while (count < MAX_DRAIN_PER_TICK) : (count += 1) {
        const entry = ring.pop() orelse break;
        if (!passesRuntimeFilter(entry)) continue;
        const len = format.formatEntry(entry, &fmt_buf);
        writeStr(fmt_buf[0..len]);
    }
}

/// Force-flush ALL pending entries to serial immediately.
/// Used during panic/fatal — ignores MAX_DRAIN_PER_TICK limit.
pub fn flushAll() void {
    if (write_string_fn == null) return;
    while (ring.pop()) |entry| {
        const len = format.formatEntry(entry, &fmt_buf);
        writeStr(fmt_buf[0..len]);
    }
}

/// Panic dump — write the last N entries from the ring buffer to serial.
/// Does NOT consume entries (uses peekBack). Prefixed with "!" for visibility.
/// Call this from the exception handler / panic path.
pub fn panicDump(count: usize) void {
    if (write_string_fn == null) return;
    writeStr("\n=== KLOG PANIC DUMP (last ");
    writeDecimal(count);
    writeStr(" entries) ===\n");

    // Dump in chronological order (oldest first)
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        if (ring.peekBack(i)) |entry| {
            const len = format.formatPanicEntry(entry, &fmt_buf);
            writeStr(fmt_buf[0..len]);
        }
    }

    writeStr("=== END PANIC DUMP (");
    writeDecimal(ring.total_written);
    writeStr(" total, ");
    writeDecimal(ring.total_dropped);
    writeStr(" dropped) ===\n\n");
}

/// Dump the last N entries (for `>dump N` command).
pub fn dumpLast(count: usize) void {
    if (write_string_fn == null) return;
    const avail = ring.available();
    const n = if (count > avail) avail else count;

    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (ring.peekBack(i)) |entry| {
            if (!passesRuntimeFilter(entry)) continue;
            const len = format.formatEntry(entry, &fmt_buf);
            writeStr(fmt_buf[0..len]);
        }
    }
}

/// Print per-subsystem entry counts and stats.
pub fn printStats() void {
    writeStr("[klog] total_written=");
    writeDecimal(ring.total_written);
    writeStr(" total_dropped=");
    writeDecimal(ring.total_dropped);
    writeStr(" pending=");
    writeDecimal(ring.available());
    writeStr("\n");
}

// --- Runtime filter control ---

/// Set the runtime minimum level for all subsystems.
pub fn setMinLevel(level: sub.Level) void {
    runtime_min_level = level;
}

/// Set the runtime level for a specific subsystem.
pub fn setSubLevel(subsystem: sub.Subsystem, level: sub.Level) void {
    runtime_sub_levels[@intFromEnum(subsystem)] = level;
}

/// Enable/disable a specific subsystem at runtime.
pub fn setSubEnabled(subsystem: sub.Subsystem, enabled: bool) void {
    const bit: u64 = @as(u64, 1) << @as(u6, @truncate(@intFromEnum(subsystem)));
    if (enabled) {
        runtime_mask |= bit;
    } else {
        runtime_mask &= ~bit;
    }
}

/// Enable all subsystems.
pub fn enableAll() void {
    runtime_mask = 0xFFFFFFFFFFFFFFFF;
}

/// Disable all subsystems.
pub fn disableAll() void {
    runtime_mask = 0;
}

// --- Internal helpers ---

fn passesRuntimeFilter(entry: *const ring.LogEntry) bool {
    // Check subsystem bitmask
    const bit: u64 = @as(u64, 1) << @as(u6, @truncate(@intFromEnum(entry.subsystem)));
    if (runtime_mask & bit == 0) return false;

    // Check runtime minimum level (global)
    if (@intFromEnum(entry.level) < @intFromEnum(runtime_min_level)) return false;

    // Check per-subsystem runtime level
    const sub_min = runtime_sub_levels[@intFromEnum(entry.subsystem)];
    if (@intFromEnum(entry.level) < @intFromEnum(sub_min)) return false;

    return true;
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        writeCh('0');
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
    writeStr(tmp[i..]);
}
