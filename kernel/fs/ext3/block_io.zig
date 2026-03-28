/// Block I/O and logging abstraction for ext3 journal modules.
///
/// Provides architecture-independent access to disk I/O and serial output.
/// Function pointers are set during init() by the platform's ext2 driver
/// before any journal operations occur. This avoids arch-conditional @import
/// which causes cross-contamination in Zig's eager import resolution.

/// Read sectors from disk. Returns true on success.
/// When a partition offset is set, all sector numbers are transparently adjusted.
pub var readSectors: *const fn (sector: u64, count: u32, buf: [*]u8) bool = &defaultReadSectors;

/// Write sectors to disk. Returns true on success.
pub var writeSectors: *const fn (sector: u64, count: u32, buf: [*]const u8) bool = &defaultWriteSectors;

/// Read raw sectors from disk WITHOUT partition offset (for GPT parsing, etc.).
pub var readSectorsRaw: *const fn (sector: u64, count: u32, buf: [*]u8) bool = &defaultReadSectors;

/// Write a string to serial/UART output.
pub var writeString: *const fn (s: []const u8) void = &defaultWriteString;

/// Partition start offset in 512-byte sectors. All readSectors/writeSectors
/// calls have this added transparently so filesystems don't need to know.
var partition_offset: u64 = 0;

/// Underlying driver functions (before offset wrapping).
var raw_readSectors: *const fn (sector: u64, count: u32, buf: [*]u8) bool = &defaultReadSectors;
var raw_writeSectors: *const fn (sector: u64, count: u32, buf: [*]const u8) bool = &defaultWriteSectors;

fn offsetReadSectors(sector: u64, count: u32, buf: [*]u8) bool {
    return raw_readSectors(sector + partition_offset, count, buf);
}

fn offsetWriteSectors(sector: u64, count: u32, buf: [*]const u8) bool {
    return raw_writeSectors(sector + partition_offset, count, buf);
}

/// Initialize block I/O with platform-specific implementations.
/// Must be called before any journal operations.
pub fn init(
    read_fn: *const fn (sector: u64, count: u32, buf: [*]u8) bool,
    write_fn: *const fn (sector: u64, count: u32, buf: [*]const u8) bool,
    log_fn: *const fn (s: []const u8) void,
) void {
    raw_readSectors = read_fn;
    raw_writeSectors = write_fn;
    readSectorsRaw = read_fn;
    readSectors = &offsetReadSectors;
    writeSectors = &offsetWriteSectors;
    writeString = log_fn;
    partition_offset = 0;
}

/// Set partition offset (in 512-byte sectors). Call after init() but before
/// mounting a filesystem. All subsequent readSectors/writeSectors calls will
/// have this offset added automatically.
pub fn setPartitionOffset(offset_sectors: u64) void {
    partition_offset = offset_sectors;
}

/// Get current partition offset.
pub fn getPartitionOffset() u64 {
    return partition_offset;
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

/// Write an unsigned hex number to log output.
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

fn defaultReadSectors(_: u64, _: u32, _: [*]u8) bool {
    return false;
}

fn defaultWriteSectors(_: u64, _: u32, _: [*]const u8) bool {
    return false;
}

fn defaultWriteString(_: []const u8) void {}
