/// ACPI I/O and logging abstraction for the shared ACPI parser module.
///
/// Provides architecture-independent access to physical memory and serial output.
/// Function pointers are set during init() by the platform's boot code before
/// any ACPI parsing occurs. This avoids arch-conditional @import which causes
/// cross-contamination in Zig's eager import resolution.

/// Convert a physical address to a kernel-accessible virtual address.
/// ARM64: identity function (phys == virt).
/// x86_64: adds HHDM offset.
pub var physToVirt: *const fn (phys: u64) u64 = &defaultPhysToVirt;

/// Write a string to serial/UART output.
pub var writeString: *const fn (s: []const u8) void = &defaultWriteString;

/// Initialize with platform-specific implementations.
/// Must be called before any ACPI parsing.
pub fn init(
    phys_to_virt_fn: *const fn (phys: u64) u64,
    log_fn: *const fn (s: []const u8) void,
) void {
    physToVirt = phys_to_virt_fn;
    writeString = log_fn;
}

/// Write a string to log output.
pub fn log(s: []const u8) void {
    writeString(s);
}

/// Write an unsigned decimal number to log output.
pub fn logDec(value: u64) void {
    if (value == 0) {
        writeString("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = value;
    while (v > 0) : (len += 1) {
        buf[19 - len] = @as(u8, @truncate(v % 10)) + '0';
        v /= 10;
    }
    writeString(buf[20 - len .. 20]);
}

/// Write an unsigned hex number to log output (no "0x" prefix).
pub fn logHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var v = value;
    if (v == 0) {
        writeString("0");
        return;
    }
    while (v > 0) : (len += 1) {
        buf[15 - len] = hex[@as(usize, @truncate(v & 0xF))];
        v >>= 4;
    }
    writeString(buf[16 - len .. 16]);
}

fn defaultPhysToVirt(phys: u64) u64 {
    return phys;
}

fn defaultWriteString(_: []const u8) void {}
