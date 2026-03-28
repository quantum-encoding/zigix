/// Zee eBPF — Comptime VFS Security Policy (Tier 1)
///
/// Kernel-inline path protection. Every mutating VFS operation calls
/// checkMutate() before dispatching to the filesystem. Unprivileged
/// processes cannot modify files under protected path prefixes.
///
/// Root (euid == 0) bypasses all checks. This is the sudo override.
/// The threat model is unprivileged processes, not root.

const serial = @import("../arch/x86_64/serial.zig");
const process = @import("../proc/process.zig");
const capability = @import("capability.zig");

// --- Policy tables (comptime, lives in kernel .rodata) ---

/// Paths that unprivileged processes cannot modify.
/// Order doesn't matter — all are checked via prefix match.
const protected_paths = [_][]const u8{
    "/etc/",
    "/boot/",
    "/bin/",
    "/sbin/",
    "/usr/",
    "/zigix/",
    "/zig/",
};

/// Paths exempt from protection even if under a protected prefix.
/// Checked before protected_paths — whitelist wins.
const whitelisted_paths = [_][]const u8{
    "/tmp/",
    "/var/tmp/",
    "/proc/",
    "/dev/",
};

// --- Policy evaluation ---

/// Check whether a mutating operation on `path` is allowed for `proc`.
/// Returns true if allowed, false if denied.
///
/// Called from syscall handlers BEFORE the filesystem operation dispatch.
/// If this returns false, the syscall should return -EACCES.
pub fn checkMutate(path: []const u8, proc: *const process.Process) bool {
    // Capability check: CAP_MODIFY_PROTECTED grants access to protected paths.
    // Root (euid==0) implicitly has all capabilities.
    if (capability.hasCap(proc.euid, proc.capabilities, capability.CAP_MODIFY_PROTECTED)) return true;

    // Whitelist takes precedence
    for (whitelisted_paths) |wp| {
        if (startsWith(path, wp)) return true;
    }

    // Check protected paths
    for (protected_paths) |pp| {
        if (startsWith(path, pp)) {
            logDeny(path, proc);
            return false;
        }
    }

    // Default: allow
    return true;
}

// --- Logging ---

fn logDeny(path: []const u8, proc: *const process.Process) void {
    serial.writeString("[SECURITY] DENIED mutate ");
    serial.writeString(path);
    serial.writeString(" by PID ");
    writeDecimal(proc.pid);
    serial.writeString(" (euid=");
    writeDecimal(proc.euid);
    serial.writeString(" caps=0x");
    writeHex(proc.capabilities);
    serial.writeString(")\n");
}

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    if (value == 0) {
        serial.writeByte('0');
        return;
    }
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (v > 0) {
        i -= 1;
        buf[i] = hex[@truncate(v & 0xF)];
        v >>= 4;
    }
    serial.writeString(buf[i..]);
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

// --- String utilities (no allocator, no std.mem in freestanding) ---

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (haystack[i] != c) return false;
    }
    return true;
}
