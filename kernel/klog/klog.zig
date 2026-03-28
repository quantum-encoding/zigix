/// Structured kernel logger — the public API.
///
/// Usage in subsystem code:
///
///     const klog = @import("../klog/klog.zig");
///     const log = klog.scoped(.nvme);
///
///     log.debug("poll_timeout", .{ .cid = cid, .sq_tail = sq_tail });
///     log.err("submit_failed", .{ .lba = lba, .count = count });
///     log.info("init_complete", .{});
///
/// Comptime filtering: if .nvme minimum level is .warn, the debug/info calls
/// compile to nothing — zero cost, no branch, no function call.
///
/// Runtime filtering: the drain path checks a bitmask + per-subsystem level.
/// Entries still go into the ring buffer (fast), but are suppressed on output.

const ring = @import("ring.zig");
const sub = @import("subsystems.zig");
const serial_sink = @import("serial_sink.zig");
const command = @import("command.zig");

pub const Level = sub.Level;
pub const Subsystem = sub.Subsystem;
pub const Field = ring.Field;
pub const LogEntry = ring.LogEntry;

/// Function pointer for getting monotonic tick count — set by init().
var get_tick_fn: ?*const fn () u64 = null;

/// Get the monotonic tick count from the platform timer.
fn getTick() u64 {
    return if (get_tick_fn) |f| f() else 0;
}

/// Initialize klog with platform-specific serial output and tick source.
/// Call early in boot, after serial/UART init.
pub fn init(
    write_string: *const fn ([]const u8) void,
    write_byte: *const fn (u8) void,
    get_tick: *const fn () u64,
) void {
    serial_sink.initSink(write_string, write_byte);
    get_tick_fn = get_tick;
}

/// Scoped logger for a specific subsystem.
/// All comptime filtering decisions are made here.
pub fn scoped(comptime subsystem: Subsystem) type {
    return struct {
        const min_level = sub.comptimeMinLevel(subsystem);

        pub inline fn trace(comptime msg: []const u8, fields_arg: anytype) void {
            log(.trace, msg, fields_arg);
        }

        pub inline fn debug(comptime msg: []const u8, fields_arg: anytype) void {
            log(.debug, msg, fields_arg);
        }

        pub inline fn info(comptime msg: []const u8, fields_arg: anytype) void {
            log(.info, msg, fields_arg);
        }

        pub inline fn warn(comptime msg: []const u8, fields_arg: anytype) void {
            log(.warn, msg, fields_arg);
        }

        pub inline fn err(comptime msg: []const u8, fields_arg: anytype) void {
            log(.err, msg, fields_arg);
        }

        pub inline fn fatal(comptime msg: []const u8, fields_arg: anytype) void {
            log(.fatal, msg, fields_arg);
        }

        inline fn log(comptime level: Level, comptime msg: []const u8, fields_arg: anytype) void {
            // Comptime gate: calls below min_level are eliminated entirely
            if (comptime @intFromEnum(level) < @intFromEnum(min_level)) return;

            var entry = ring.LogEntry.ZERO;
            entry.tick = getTick();
            entry.level = level;
            entry.subsystem = subsystem;

            // Copy message tag (comptime known, truncated to MSG_LEN)
            const msg_len: usize = comptime if (msg.len < ring.MSG_LEN) msg.len else ring.MSG_LEN;
            inline for (0..msg_len) |i| {
                entry.msg[i] = msg[i];
            }

            // Extract fields from the anonymous struct
            const T = @TypeOf(fields_arg);
            if (T != void and T != @TypeOf(.{})) {
                const fields_info = @typeInfo(T);
                if (fields_info == .@"struct") {
                    const struct_fields = fields_info.@"struct".fields;
                    comptime var field_count: u8 = 0;
                    inline for (struct_fields) |f| {
                        if (field_count < ring.MAX_FIELDS) {
                            entry.fields[field_count] = ring.Field.init(
                                f.name,
                                toU64(@field(fields_arg, f.name)),
                            );
                            field_count += 1;
                        }
                    }
                    entry.field_count = field_count;
                }
            }

            ring.push(entry);
        }
    };
}

/// Convert any integer/bool/pointer type to u64 for storage.
inline fn toU64(value: anytype) u64 {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    return switch (info) {
        .int => |i| blk: {
            if (i.signedness == .signed) {
                // Signed → widen to i64 → bitcast to u64 (preserves negative values)
                break :blk @bitCast(@as(i64, @intCast(value)));
            } else {
                break :blk @intCast(value);
            }
        },
        .comptime_int => @intCast(value),
        .bool => if (value) 1 else 0,
        .pointer => @intFromPtr(value),
        .@"enum" => @intFromEnum(value),
        .optional => if (value) |v| toU64(v) else 0,
        else => 0,
    };
}

// --- System-level API (called from boot, IRQ handler, panic) ---

/// Drain pending log entries to serial output.
/// Call from IRQ0 timer tick handler.
pub fn drain() void {
    serial_sink.drain();
}

/// Force-flush all pending entries to serial. Use sparingly.
pub fn flush() void {
    serial_sink.flushAll();
}

/// Panic dump — write last N entries to serial for post-mortem.
/// Call from exception handler or @panic.
pub fn panicDump(count: usize) void {
    serial_sink.panicDump(count);
}

/// Feed a byte from serial input to the command parser.
/// Returns true if a command was executed.
pub fn feedCommandByte(byte: u8) bool {
    return command.feedByte(byte);
}

/// Print log statistics.
pub fn stats() void {
    serial_sink.printStats();
}

// --- Direct serial write passthrough (for boot messages before ring is draining) ---

/// Write a string directly to serial, bypassing the ring buffer.
/// Use ONLY during early boot before the timer tick is running.
pub fn direct(msg: []const u8) void {
    serial_sink.writeStr(msg);
}
