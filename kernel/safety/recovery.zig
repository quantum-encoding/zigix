// recovery.zig — Comptime-defined failure recovery registry
//
// Every kernel subsystem declares its failure modes and recovery chains.
// When a failure occurs, the registry executes predetermined recovery
// actions — not "return error and hope the caller handles it."
//
// Linux pattern (bad):
//   allocPage() returns NULL → caller returns -ENOMEM → propagates up
//   → userspace prints "out of memory" → nobody recovered
//
// Zigix pattern (this):
//   allocPage() returns null → recovery.execute(.pmm_oom) →
//   tier 1: evict page cache (recovered 48 KiB) → retry succeeds
//   All defined at build time. All logged. All auditable.
//
// Architecture from zig_chaos_rocket/src/chaos/scenarios.zig:
//   - Each failure has a Severity and Subsystem (compile-time metadata)
//   - Recovery actions are a chain, tried in order until one succeeds
//   - Every action is observable (logged via klog)

const serial = @import("../arch/x86_64/serial.zig");

// ============================================================
// Core types
// ============================================================

pub const Subsystem = enum(u8) {
    pmm, // Physical memory manager
    vmm, // Virtual memory manager
    vfs, // Virtual filesystem
    ext2, // ext2 filesystem
    net, // Network stack
    sched, // Scheduler
    proc, // Process management
    nvme, // NVMe driver
    gvnic, // gVNIC driver
};

pub const Severity = enum(u8) {
    recoverable, // Normal — recovery chain should handle it
    degraded, // Service degraded but functional
    critical, // System stability at risk
};

/// Result of a recovery action.
pub const ActionResult = struct {
    succeeded: bool,
    recovered_bytes: u64 = 0,
    detail: Detail = .none,

    pub const Detail = enum(u8) {
        none,
        pages_evicted,
        pages_swapped,
        zombies_reaped,
        process_killed,
        buffers_reposted,
        io_retried,
        packets_dropped,
    };
};

/// A recovery action — a function that attempts to fix the failure.
/// Returns what it recovered (or failure).
pub const Action = *const fn () ActionResult;

/// A failure mode with its comptime-defined recovery chain.
pub const FailureMode = struct {
    /// Human-readable name for logging.
    name: []const u8,
    /// Which subsystem owns this failure.
    subsystem: Subsystem,
    /// Expected severity — how bad is this if recovery fails?
    severity: Severity,
    /// Ordered recovery chain. Each action is tried in sequence.
    /// First success short-circuits the chain.
    chain: []const Action,
};

// ============================================================
// Runtime state
// ============================================================

/// Statistics tracked per failure mode.
const Stats = struct {
    triggered: u32 = 0,
    recovered: u32 = 0,
    failed: u32 = 0,
    bytes_recovered: u64 = 0,
};

var stats: [MAX_MODES]Stats = [_]Stats{.{}} ** MAX_MODES;

// ============================================================
// Registry — comptime-defined, runtime-executed
// ============================================================

const MAX_MODES = 16;
var registry: [MAX_MODES]?FailureMode = [_]?FailureMode{null} ** MAX_MODES;
var mode_count: u8 = 0;

/// Register a failure mode. Called during kernel init by each subsystem.
pub fn register(mode: FailureMode) u8 {
    if (mode_count >= MAX_MODES) return 0;
    const id = mode_count;
    registry[id] = mode;
    mode_count += 1;
    return id;
}

/// Execute the recovery chain for a failure mode.
/// Tries each action in order. Returns true if ANY action succeeded.
/// Logs every attempt and result to serial (visible in boot log).
pub fn execute(mode_id: u8) bool {
    if (mode_id >= mode_count) return false;
    const mode = registry[mode_id] orelse return false;

    stats[mode_id].triggered += 1;

    // Log: [recovery] PMM: OOM triggered
    serial.writeString("[recovery] ");
    serial.writeString(subsystemName(mode.subsystem));
    serial.writeString(": ");
    serial.writeString(mode.name);
    serial.writeString(" triggered");

    var total_recovered: u64 = 0;
    var any_succeeded = false;

    for (mode.chain, 0..) |action, tier| {
        const result = action();
        if (result.succeeded) {
            total_recovered += result.recovered_bytes;
            any_succeeded = true;

            // Log: — evicted 12 page cache entries, recovered 48 KiB
            serial.writeString(" — ");
            serial.writeString(detailName(result.detail));
            if (result.recovered_bytes > 0) {
                serial.writeString(", recovered ");
                writeDecimal(result.recovered_bytes / 1024);
                serial.writeString(" KiB");
            }
            break; // First success short-circuits
        } else {
            // Log tier failure only if there are more tiers to try
            if (tier + 1 < mode.chain.len) {
                serial.writeString(" — ");
                serial.writeString(detailName(result.detail));
                serial.writeString(" failed, escalating");
            }
        }
    }

    if (any_succeeded) {
        stats[mode_id].recovered += 1;
        stats[mode_id].bytes_recovered += total_recovered;
        serial.writeString("\n");
    } else {
        stats[mode_id].failed += 1;
        serial.writeString(" — all recovery failed (");
        serial.writeString(severityName(mode.severity));
        serial.writeString(")\n");
    }

    return any_succeeded;
}

/// Get stats for a failure mode (for /proc/recovery or klog).
pub fn getStats(mode_id: u8) Stats {
    if (mode_id >= MAX_MODES) return .{};
    return stats[mode_id];
}

/// Print summary of all registered modes and their stats.
pub fn dumpStats() void {
    serial.writeString("[recovery] === Recovery Registry Stats ===\n");
    var i: u8 = 0;
    while (i < mode_count) : (i += 1) {
        if (registry[i]) |mode| {
            serial.writeString("[recovery] ");
            serial.writeString(subsystemName(mode.subsystem));
            serial.writeString("/");
            serial.writeString(mode.name);
            serial.writeString(": triggered=");
            writeDecimal(stats[i].triggered);
            serial.writeString(" recovered=");
            writeDecimal(stats[i].recovered);
            serial.writeString(" failed=");
            writeDecimal(stats[i].failed);
            if (stats[i].bytes_recovered > 0) {
                serial.writeString(" total_recovered=");
                writeDecimal(stats[i].bytes_recovered / 1024);
                serial.writeString("KiB");
            }
            serial.writeString("\n");
        }
    }
}

// ============================================================
// Name tables
// ============================================================

fn subsystemName(s: Subsystem) []const u8 {
    return switch (s) {
        .pmm => "PMM",
        .vmm => "VMM",
        .vfs => "VFS",
        .ext2 => "EXT2",
        .net => "NET",
        .sched => "SCHED",
        .proc => "PROC",
        .nvme => "NVMe",
        .gvnic => "gVNIC",
    };
}

fn severityName(s: Severity) []const u8 {
    return switch (s) {
        .recoverable => "recoverable",
        .degraded => "degraded",
        .critical => "CRITICAL",
    };
}

fn detailName(d: ActionResult.Detail) []const u8 {
    return switch (d) {
        .none => "action completed",
        .pages_evicted => "evicted page cache entries",
        .pages_swapped => "swapped pages to disk",
        .zombies_reaped => "reaped zombie processes",
        .process_killed => "killed lowest-priority process",
        .buffers_reposted => "reposted RX buffers",
        .io_retried => "retried I/O",
        .packets_dropped => "dropped packets",
    };
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        serial.writeByte('0');
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
    serial.writeString(buf[i..]);
}
