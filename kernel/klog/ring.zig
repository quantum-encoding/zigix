/// Lock-free ring buffer for structured log entries.
/// Lives entirely in .bss — no heap, no allocation, available from first instruction.
/// Fixed-size entries for cache-line friendliness and interrupt safety.

const sub = @import("subsystems.zig");

/// Up to 4 key=value fields per log entry.
pub const MAX_FIELDS = 4;
pub const KEY_LEN = 15;
pub const MSG_LEN = 16;

pub const Field = extern struct {
    key: [KEY_LEN]u8,  // null-padded short key
    _pad: u8,
    value: u64,        // all values stored as u64, formatted on output

    pub const ZERO = Field{ .key = .{0} ** KEY_LEN, ._pad = 0, .value = 0 };

    pub fn init(k: []const u8, v: u64) Field {
        var f = ZERO;
        f.value = v;
        const copy_len = if (k.len < KEY_LEN) k.len else KEY_LEN;
        for (0..copy_len) |i| {
            f.key[i] = k[i];
        }
        return f;
    }

    /// Read null-terminated key as slice.
    pub fn keySlice(self: *const Field) []const u8 {
        var len: usize = 0;
        while (len < KEY_LEN and self.key[len] != 0) : (len += 1) {}
        return self.key[0..len];
    }
};

/// 128-byte fixed-size log entry (exactly 2 cache lines).
pub const LogEntry = extern struct {
    tick: u64,                    // monotonic tick from PIT
    level: sub.Level,             // severity
    subsystem: sub.Subsystem,     // source subsystem
    field_count: u8,              // number of valid fields (0-4)
    _pad: [5]u8,
    msg: [MSG_LEN]u8,            // null-padded message tag
    fields: [MAX_FIELDS]Field,   // structured key=value pairs

    pub const ZERO = LogEntry{
        .tick = 0,
        .level = .trace,
        .subsystem = .boot,
        .field_count = 0,
        ._pad = .{0} ** 5,
        .msg = .{0} ** MSG_LEN,
        .fields = .{Field.ZERO} ** MAX_FIELDS,
    };

    pub fn msgSlice(self: *const LogEntry) []const u8 {
        var len: usize = 0;
        while (len < MSG_LEN and self.msg[len] != 0) : (len += 1) {}
        return self.msg[0..len];
    }
};

// Compile-time size assertion
comptime {
    if (@sizeOf(LogEntry) > 128) {
        @compileError("LogEntry too large");
    }
}

/// Ring buffer capacity — 4096 entries.
/// At 128 bytes per entry this is 512 KiB in .bss.
const RING_SIZE: usize = 4096;
const RING_MASK: usize = RING_SIZE - 1;

/// The ring buffer itself — entirely in .bss, zero-initialized.
var ring: [RING_SIZE]LogEntry = .{LogEntry.ZERO} ** RING_SIZE;

/// Write head — only the logger writes here (single-producer).
var head: usize = 0;

/// Read tail — only the drain/flush path reads here.
var tail: usize = 0;

/// Total entries ever written (for stats, wraps at u64 max).
pub var total_written: u64 = 0;

/// Total entries dropped due to ring full.
pub var total_dropped: u64 = 0;

/// Push a log entry into the ring buffer.
/// If the ring is full, the oldest entry is silently overwritten.
/// This is the hot path — must be safe in interrupt/exception context.
pub fn push(entry: LogEntry) void {
    ring[head & RING_MASK] = entry;
    head +%= 1;
    total_written +%= 1;

    // If head caught up to tail, advance tail (lose oldest entry)
    if (head -% tail > RING_SIZE) {
        total_dropped +%= 1;
        tail = head -% RING_SIZE;
    }
}

/// Pop the next unread entry for the drain path.
/// Returns null if the ring is empty (tail == head).
pub fn pop() ?*const LogEntry {
    if (tail == head) return null;
    const entry = &ring[tail & RING_MASK];
    tail +%= 1;
    return entry;
}

/// Number of entries available to read.
pub fn available() usize {
    return head -% tail;
}

/// Peek at an entry relative to the current tail (0 = oldest unread).
/// Does NOT advance the tail. Returns null if offset is out of range.
pub fn peek(offset: usize) ?*const LogEntry {
    if (offset >= available()) return null;
    return &ring[(tail +% offset) & RING_MASK];
}

/// Peek backwards from head (0 = most recent entry, 1 = second most recent, etc.)
/// For panic dump: read the last N entries without consuming them.
pub fn peekBack(offset: usize) ?*const LogEntry {
    if (offset >= available() or head == 0) return null;
    return &ring[(head -% 1 -% offset) & RING_MASK];
}

/// Reset the ring buffer (clear all entries).
pub fn clear() void {
    tail = head;
}
