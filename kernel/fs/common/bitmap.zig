/// Shared bitmap operations for block/inode allocation.
/// Used by ext2, ext3, and ext4 (including mballoc).
/// Freestanding — no std, no libc.

/// Test if bit N is set in bitmap.
pub fn testBit(bitmap: [*]const u8, bit: u32) bool {
    return bitmap[bit / 8] & (@as(u8, 1) << @as(u3, @truncate(bit % 8))) != 0;
}

/// Set bit N.
pub fn setBit(bitmap: [*]u8, bit: u32) void {
    bitmap[bit / 8] |= @as(u8, 1) << @as(u3, @truncate(bit % 8));
}

/// Clear bit N.
pub fn clearBit(bitmap: [*]u8, bit: u32) void {
    bitmap[bit / 8] &= ~(@as(u8, 1) << @as(u3, @truncate(bit % 8)));
}

/// Find first zero bit starting from `hint`, wrapping around.
/// Returns null if no zero bit exists.
pub fn findFirstZero(bitmap: [*]const u8, total_bits: u32, hint: u32) ?u32 {
    var pos: u32 = hint;
    var checked: u32 = 0;
    while (checked < total_bits) : ({
        pos = (pos + 1) % total_bits;
        checked += 1;
    }) {
        // Fast skip: if entire byte is 0xFF, skip 8 bits
        if (pos % 8 == 0 and checked + 8 <= total_bits) {
            const byte_idx = pos / 8;
            if (bitmap[byte_idx] == 0xFF) {
                pos += 7; // +1 from loop increment = skip 8
                checked += 7;
                continue;
            }
        }
        if (!testBit(bitmap, pos)) {
            return pos;
        }
    }
    return null;
}

/// Find N contiguous zero bits starting from `hint`.
/// Returns the index of the first bit in the run, or null.
pub fn findContiguousZeros(
    bitmap: [*]const u8,
    total_bits: u32,
    count: u32,
    hint: u32,
) ?u32 {
    if (count == 0) return hint;
    if (count > total_bits) return null;

    var start: u32 = hint;
    var run: u32 = 0;
    var checked: u32 = 0;

    while (checked < total_bits) {
        const pos = (hint + checked) % total_bits;

        if (!testBit(bitmap, pos)) {
            if (run == 0) start = pos;
            run += 1;
            if (run >= count) return start;
        } else {
            run = 0;
        }

        checked += 1;

        // Wrapped past start of run — can't form contiguous across wrap boundary
        if (pos + 1 == total_bits and run > 0 and run < count) {
            run = 0;
        }
    }
    return null;
}

/// Count total zero bits in bitmap.
pub fn countZeros(bitmap: [*]const u8, total_bits: u32) u32 {
    var zeros: u32 = 0;
    const full_bytes = total_bits / 8;
    const remaining_bits = total_bits % 8;

    for (0..full_bytes) |i| {
        // Count set bits per byte, subtract from 8
        zeros += 8 - @as(u32, @popCount(bitmap[i]));
    }

    // Handle remaining bits
    if (remaining_bits > 0) {
        const last_byte = bitmap[full_bytes];
        for (0..remaining_bits) |b| {
            if (last_byte & (@as(u8, 1) << @as(u3, @truncate(b))) == 0) {
                zeros += 1;
            }
        }
    }

    return zeros;
}

/// Set range of bits [start, start+count).
pub fn setRange(bitmap: [*]u8, start: u32, count: u32) void {
    for (0..count) |i| {
        setBit(bitmap, start + @as(u32, @truncate(i)));
    }
}

/// Clear range of bits [start, start+count).
pub fn clearRange(bitmap: [*]u8, start: u32, count: u32) void {
    for (0..count) |i| {
        clearBit(bitmap, start + @as(u32, @truncate(i)));
    }
}
