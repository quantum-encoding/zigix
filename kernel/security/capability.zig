/// Zigix Capability Model
///
/// Single u64 bitmask per process. No ambient/inheritable/permitted/effective
/// distinction — you have it or you don't.
///
/// Rules:
///   - Root (euid == 0) implicitly has all capabilities (not stored in bitmask)
///   - Fork: child inherits parent's capabilities
///   - Execve: capabilities dropped unless binary is in comptime whitelist
///   - Policy checks: security.checkMutate uses CAP_MODIFY_PROTECTED

/// Capability bits — each is a single bit in a u64 bitmask.
pub const CAP_MODIFY_PROTECTED: u64 = 1 << 0; // Write to protected paths (/etc, /bin, etc.)
pub const CAP_LOAD_POLICY: u64 = 1 << 1; // Load runtime BPF policies (Tier 2, future)
pub const CAP_NET_ADMIN: u64 = 1 << 2; // Modify network configuration
pub const CAP_PROC_ADMIN: u64 = 1 << 3; // Signal/ptrace other processes
pub const CAP_MOUNT: u64 = 1 << 4; // Mount/unmount filesystems
pub const CAP_RAW_IO: u64 = 1 << 5; // Direct port/memory I/O
pub const CAP_SETUID: u64 = 1 << 6; // Change uid/gid
pub const CAP_CHOWN: u64 = 1 << 7; // Change file ownership

/// All capabilities — granted to root processes.
pub const CAP_ALL: u64 = 0xFFFFFFFFFFFFFFFF;

/// Binaries that retain capabilities across execve.
/// Everything else drops to zero capabilities on exec.
/// Root processes always retain all caps regardless of this list.
const cap_whitelist = [_][]const u8{
    "/bin/zsh",
    "/bin/sh",
    "/bin/bash",
    "/sbin/zinit",
    "/usr/bin/sudo",
    "/usr/bin/su",
    "/zig/zig", // Zig compiler needs protected path access for builds
};

/// Check if a binary path retains capabilities across execve.
pub fn retainsCapsOnExec(path: []const u8) bool {
    for (cap_whitelist) |entry| {
        if (eql(path, entry)) return true;
    }
    return false;
}

/// Check if process has a specific capability.
/// Root (euid == 0) always returns true.
pub fn hasCap(euid: u16, caps: u64, cap: u64) bool {
    if (euid == 0) return true;
    return (caps & cap) != 0;
}

// --- String utilities (freestanding, no std.mem) ---

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |c, i| {
        if (c != b[i]) return false;
    }
    return true;
}
