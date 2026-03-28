/// Internet checksum — RFC 1071 one's complement sum.

/// Compute the Internet checksum over a byte slice.
pub fn internetChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    // Sum 16-bit words
    while (i + 1 < data.len) : (i += 2) {
        const word = @as(u32, data[i]) << 8 | @as(u32, data[i + 1]);
        sum += word;
    }

    // Handle odd byte
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @truncate(~sum);
}

/// Compute pseudo-header partial sum for TCP/UDP checksums.
/// src and dst are in host byte order. proto is IP protocol number. len is payload length.
pub fn pseudoHeaderSum(src: u32, dst: u32, proto: u8, len: u16) u32 {
    var sum: u32 = 0;

    // Source IP (big-endian)
    sum += (src >> 16) & 0xFFFF;
    sum += src & 0xFFFF;

    // Dest IP (big-endian)
    sum += (dst >> 16) & 0xFFFF;
    sum += dst & 0xFFFF;

    // Protocol
    sum += @as(u32, proto);

    // Length
    sum += @as(u32, len);

    return sum;
}

/// Compute checksum with a pre-seeded sum (from pseudoHeaderSum).
pub fn checksumWithSeed(seed: u32, data: []const u8) u16 {
    var sum: u32 = seed;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        const word = @as(u32, data[i]) << 8 | @as(u32, data[i + 1]);
        sum += word;
    }

    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @truncate(~sum);
}
