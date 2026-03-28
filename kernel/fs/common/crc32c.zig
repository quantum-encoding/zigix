/// CRC32c (Castagnoli) checksum — used throughout ext4 for metadata integrity.
///
/// Polynomial: 0x1EDC6F41 (reflected: 0x82F63B78).
/// Freestanding — no std, no libc.
///
/// Verified against IETF test vectors:
///   CRC32c("") = 0x00000000
///   CRC32c("123456789") = 0xE3069283
///   CRC32c(32 × 0x00) = 0xAA36918A
///   CRC32c(32 × 0xFF) = 0x43ABA862

/// 256-entry lookup table generated at comptime using the reflected Castagnoli polynomial.
const crc32c_table: [256]u32 = blk: {
    @setEvalBranchQuota(5000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ 0x82F63B78;
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Incremental CRC32c update.
/// Pass 0xFFFFFFFF as initial crc, or the previous result for chaining.
pub fn update(crc: u32, data: [*]const u8, len: usize) u32 {
    var c = crc;
    for (0..len) |i| {
        c = crc32c_table[@as(u8, @truncate(c)) ^ data[i]] ^ (c >> 8);
    }
    return c;
}

/// Finalize: XOR with 0xFFFFFFFF.
pub fn finalize(crc: u32) u32 {
    return crc ^ 0xFFFFFFFF;
}

/// Compute CRC32c of a buffer in one call.
pub fn compute(data: [*]const u8, len: usize) u32 {
    return finalize(update(0xFFFFFFFF, data, len));
}

/// Compute CRC32c with a pre-computed seed (e.g. from filesystem UUID).
pub fn updateWithSeed(seed: u32, data: [*]const u8, len: usize) u32 {
    return update(seed, data, len);
}

/// Derive checksum seed from filesystem UUID.
/// seed = crc32c(~0, uuid[0..16])  — NOT finalized (used as running CRC).
pub fn seedFromUuid(uuid: *const [16]u8) u32 {
    return update(0xFFFFFFFF, uuid, 16);
}

/// Compute a full metadata checksum: seed → data → finalize.
pub fn metadataChecksum(uuid: *const [16]u8, data: [*]const u8, len: usize) u32 {
    const seed = seedFromUuid(uuid);
    return finalize(update(seed, data, len));
}
