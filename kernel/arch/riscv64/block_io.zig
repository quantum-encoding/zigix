/// Block I/O abstraction — dispatches to virtio_blk or other drivers.
/// Same interface as ARM64 ext3.block_io module.

const uart = @import("uart.zig");

var read_fn: ?*const fn (u64, u32, [*]u8) bool = null;
var write_fn: ?*const fn (u64, u32, [*]const u8) bool = null;

pub fn init(
    reader: *const fn (u64, u32, [*]u8) bool,
    writer: *const fn (u64, u32, [*]const u8) bool,
    _: *const fn ([]const u8) void,
) void {
    read_fn = reader;
    write_fn = writer;
}

pub fn readSectors(sector: u64, count: u32, buf: [*]u8) bool {
    if (read_fn) |f| return f(sector, count, buf);
    return false;
}

pub fn writeSectors(sector: u64, count: u32, buf: [*]const u8) bool {
    if (write_fn) |f| return f(sector, count, buf);
    return false;
}

/// GPT partition offset — added to all sector addresses.
pub var gpt_partition_offset: u64 = 0;

pub fn setPartitionOffset(offset: u64) void {
    gpt_partition_offset = offset;
}
