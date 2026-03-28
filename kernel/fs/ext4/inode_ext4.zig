/// ext4 extended inode support (256 bytes).
///
/// ext2/ext3 inodes are 128 bytes. ext4 extends them to 256 bytes with:
/// - Nanosecond timestamp precision
/// - Creation time (crtime)
/// - Inode checksum (CRC32c)
/// - Extended epoch bits (dates past 2038)
///
/// Freestanding — no std, no libc.

const crc32c = @import("../common/crc32c.zig");

/// Standard inode size (ext2/ext3).
pub const INODE_SIZE_128: u16 = 128;
/// Extended inode size (ext4).
pub const INODE_SIZE_256: u16 = 256;

/// Offset of i_checksum_lo within the standard 128-byte inode.
/// This is repurposed from i_osd2 bytes [0..2] (offset 0x7C from inode start).
pub const CHECKSUM_LO_OFFSET: usize = 0x7C;

/// Offset of i_generation within the standard 128-byte inode (offset 0x64).
pub const GENERATION_OFFSET: usize = 0x64;

/// Extended inode fields — bytes 0x80–0xFF of a 256-byte inode.
pub const InodeExtra = extern struct {
    extra_isize: u16,     // 0x80: Actual size of extra fields used
    checksum_hi: u16,     // 0x82: High 16 bits of inode checksum
    ctime_extra: u32,     // 0x84: Extra ctime (nanoseconds + epoch extension)
    mtime_extra: u32,     // 0x88: Extra mtime
    atime_extra: u32,     // 0x8C: Extra atime
    crtime: u32,          // 0x90: Creation time (seconds since epoch)
    crtime_extra: u32,    // 0x94: Creation time nanoseconds + epoch
    version_hi: u32,      // 0x98: High 32 bits of inode version
    projid: u32,          // 0x9C: Project ID
    _reserved: [96]u8,    // 0xA0–0xFF: Padding to fill 256 bytes
};

/// Decoded timestamp with nanosecond precision and extended epoch.
pub const Timestamp = struct {
    seconds: u64,
    nanoseconds: u32,
};

/// Decode a timestamp from seconds (32-bit) and extra field (32-bit).
///
/// Extra field format: [epoch_bits(2)][nanoseconds(30)]
///   epoch_bits extends the 32-bit seconds past 2038:
///     0 = 1901–2038, 1 = 2038–2174, 2 = 2174–2310, 3 = 2310–2446
pub fn decodeTimestamp(seconds: u32, extra: u32) Timestamp {
    const epoch_bits: u64 = extra >> 30;
    return .{
        .seconds = @as(u64, seconds) + (epoch_bits << 32),
        .nanoseconds = extra & 0x3FFFFFFF,
    };
}

/// Encode extra timestamp field from nanoseconds and epoch bits.
pub fn encodeTimestampExtra(nanoseconds: u32, epoch_bits: u2) u32 {
    return (@as(u32, epoch_bits) << 30) | (nanoseconds & 0x3FFFFFFF);
}

/// Read extended inode fields from a raw inode buffer.
/// Returns null if inode_size < 256.
pub fn readExtra(inode_buf: [*]const u8, inode_size: u16) ?*const InodeExtra {
    if (inode_size < INODE_SIZE_256) return null;
    return @ptrCast(@alignCast(inode_buf + INODE_SIZE_128));
}

/// Read the mutable extra fields (for writes).
pub fn readExtraMut(inode_buf: [*]u8, inode_size: u16) ?*InodeExtra {
    if (inode_size < INODE_SIZE_256) return null;
    return @ptrCast(@alignCast(inode_buf + INODE_SIZE_128));
}

// ── Little-endian helpers ──────────────────────────────────────────────

fn readU16LE(buf: [*]const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

fn readU32LE(buf: [*]const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

fn writeU16LE(buf: [*]u8, off: usize, val: u16) void {
    buf[off] = @truncate(val);
    buf[off + 1] = @truncate(val >> 8);
}

/// Compute inode checksum using CRC32c.
///
/// Algorithm:
///   1. seed = crc32c(~0, fs_uuid[0..16])
///   2. seed = crc32c(seed, inode_number_le[0..4])
///   3. seed = crc32c(seed, generation_le[0..4])  — from offset 0x64 in inode
///   4. Zero the checksum fields (offset 0x7C lo, offset 0x82 hi)
///   5. checksum = crc32c(seed, inode_buf[0..inode_size])
pub fn computeChecksum(
    inode_buf: [*]const u8,
    inode_size: u16,
    inode_number: u32,
    fs_uuid: *const [16]u8,
) u32 {
    // Step 1: seed from UUID
    var crc = crc32c.seedFromUuid(fs_uuid);

    // Step 2: feed inode number (LE)
    const ino_le: [4]u8 = .{
        @truncate(inode_number),
        @truncate(inode_number >> 8),
        @truncate(inode_number >> 16),
        @truncate(inode_number >> 24),
    };
    crc = crc32c.update(crc, &ino_le, 4);

    // Step 3: feed generation (LE) from offset 0x64
    const gen = readU32LE(inode_buf, GENERATION_OFFSET);
    const gen_le: [4]u8 = .{
        @truncate(gen),
        @truncate(gen >> 8),
        @truncate(gen >> 16),
        @truncate(gen >> 24),
    };
    crc = crc32c.update(crc, &gen_le, 4);

    // Step 4+5: feed inode data with checksum fields zeroed.
    // We process in segments to zero out the checksum fields.
    const size: usize = @as(usize, inode_size);

    // Bytes before checksum_lo (0x00–0x7B)
    crc = crc32c.update(crc, inode_buf, CHECKSUM_LO_OFFSET);

    // Zero for checksum_lo (2 bytes at 0x7C)
    const zero2: [2]u8 = .{ 0, 0 };
    crc = crc32c.update(crc, &zero2, 2);

    // Bytes 0x7E–0x7F (rest of standard 128-byte inode)
    if (size > CHECKSUM_LO_OFFSET + 2) {
        const after_lo = CHECKSUM_LO_OFFSET + 2;

        if (size >= INODE_SIZE_256) {
            // Has extra fields — zero checksum_hi at offset 0x82
            const hi_off: usize = 0x82;
            // 0x7E–0x81
            crc = crc32c.update(crc, inode_buf + after_lo, hi_off - after_lo);
            // Zero for checksum_hi (2 bytes at 0x82)
            crc = crc32c.update(crc, &zero2, 2);
            // 0x84–end
            if (size > hi_off + 2) {
                crc = crc32c.update(crc, inode_buf + hi_off + 2, size - (hi_off + 2));
            }
        } else {
            // 128-byte inode, no checksum_hi
            crc = crc32c.update(crc, inode_buf + after_lo, size - after_lo);
        }
    }

    return crc32c.finalize(crc);
}

/// Verify stored inode checksum.
pub fn verifyChecksum(
    inode_buf: [*]const u8,
    inode_size: u16,
    inode_number: u32,
    fs_uuid: *const [16]u8,
) bool {
    const stored_lo: u32 = readU16LE(inode_buf, CHECKSUM_LO_OFFSET);
    const stored_hi: u32 = if (inode_size >= INODE_SIZE_256)
        readU16LE(inode_buf, 0x82)
    else
        0;
    const stored = (stored_hi << 16) | stored_lo;
    const computed = computeChecksum(inode_buf, inode_size, inode_number, fs_uuid);
    return stored == computed;
}

/// Store computed checksum into inode buffer.
pub fn storeChecksum(
    inode_buf: [*]u8,
    inode_size: u16,
    inode_number: u32,
    fs_uuid: *const [16]u8,
) void {
    const csum = computeChecksum(inode_buf, inode_size, inode_number, fs_uuid);
    writeU16LE(inode_buf, CHECKSUM_LO_OFFSET, @truncate(csum));
    if (inode_size >= INODE_SIZE_256) {
        writeU16LE(inode_buf, 0x82, @truncate(csum >> 16));
    }
}
