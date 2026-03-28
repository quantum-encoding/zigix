/// Bloom filter for O(1) probabilistic set membership testing.
/// Ported from programs/zig_bloom for kernel use.
///
/// Zero-allocation: operates on a caller-provided static bit array.
/// No false negatives; false positive rate depends on fill ratio.
///
/// Primary use: page cache "is block X cached?" check.
/// Replaces O(n) linear scan with O(k) hash lookups (k = num_hashes).
///
/// Usage:
///   var bits: [512]u64 = .{0} ** 512; // 32768 bits
///   var bf = BloomFilter.initStatic(&bits, 7); // 7 hash functions
///   bf.add(block_number);
///   if (bf.contains(block_number)) { ... } // true = maybe cached
///                                          // false = definitely not cached

pub const BloomFilter = struct {
    bits: [*]u64,
    num_words: usize,
    num_bits: usize,
    num_hashes: u8,

    /// Initialize from a static u64 array.
    pub fn initStatic(bit_array: []u64, num_hashes: u8) BloomFilter {
        // Zero the array
        for (bit_array) |*w| w.* = 0;
        return .{
            .bits = bit_array.ptr,
            .num_words = bit_array.len,
            .num_bits = bit_array.len * 64,
            .num_hashes = if (num_hashes == 0) 1 else num_hashes,
        };
    }

    /// Add a u64 key to the filter.
    pub fn add(self: *BloomFilter, key: u64) void {
        var h1 = wyhash(key, 0);
        var h2 = wyhash(key, 0x517cc1b727220a95);
        var i: u8 = 0;
        while (i < self.num_hashes) : (i += 1) {
            const combined = h1 +% @as(u64, i) *% h2;
            const bit_idx = combined % self.num_bits;
            const word_idx = bit_idx / 64;
            const bit_off: u6 = @truncate(bit_idx % 64);
            self.bits[word_idx] |= @as(u64, 1) << bit_off;
        }
    }

    /// Test if a key might be in the filter.
    /// Returns false = definitely not present; true = probably present.
    pub fn contains(self: *const BloomFilter, key: u64) bool {
        var h1 = wyhash(key, 0);
        var h2 = wyhash(key, 0x517cc1b727220a95);
        var i: u8 = 0;
        while (i < self.num_hashes) : (i += 1) {
            const combined = h1 +% @as(u64, i) *% h2;
            const bit_idx = combined % self.num_bits;
            const word_idx = bit_idx / 64;
            const bit_off: u6 = @truncate(bit_idx % 64);
            if (self.bits[word_idx] & (@as(u64, 1) << bit_off) == 0) return false;
        }
        return true;
    }

    /// Remove a key (clear its bits). WARNING: may cause false negatives
    /// for other keys that share the same bit positions. Use only when
    /// the filter is periodically rebuilt (e.g., page cache eviction).
    pub fn remove(self: *BloomFilter, key: u64) void {
        var h1 = wyhash(key, 0);
        var h2 = wyhash(key, 0x517cc1b727220a95);
        var i: u8 = 0;
        while (i < self.num_hashes) : (i += 1) {
            const combined = h1 +% @as(u64, i) *% h2;
            const bit_idx = combined % self.num_bits;
            const word_idx = bit_idx / 64;
            const bit_off: u6 = @truncate(bit_idx % 64);
            self.bits[word_idx] &= ~(@as(u64, 1) << bit_off);
        }
    }

    /// Clear all bits.
    pub fn clear(self: *BloomFilter) void {
        for (0..self.num_words) |i| self.bits[i] = 0;
    }

    /// Approximate fill ratio (fraction of bits set).
    pub fn fillRatio(self: *const BloomFilter) u32 {
        var set: u64 = 0;
        for (0..self.num_words) |i| {
            set += @popCount(self.bits[i]);
        }
        // Return permille (0-1000)
        return @truncate((set * 1000) / self.num_bits);
    }
};

/// Wyhash-inspired fast hash for u64 keys (no std dependency).
/// Based on wyhash v4 finalizer — good distribution for integer keys.
fn wyhash(key: u64, seed: u64) u64 {
    var v = key ^ seed;
    v = (v ^ (v >> 30)) *% 0xbf58476d1ce4e5b9;
    v = (v ^ (v >> 27)) *% 0x94d049bb133111eb;
    v = v ^ (v >> 31);
    return v;
}
