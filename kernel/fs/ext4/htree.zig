/// HTree indexed directories for ext4.
///
/// Replaces linear directory scanning with hash-indexed B-tree lookup.
/// Small directories (<1 block) still use linear scan. Large directories
/// get an HTree index for O(1) average-case lookup.
///
/// The HTree is hidden inside the existing directory block format:
///   - Block 0 (root): fake "." and ".." entries, then dx_root header + hash entries
///   - Internal blocks: fake dirent header, then dx_node header + hash entries
///   - Leaf blocks: normal ext2 directory entries (linear within the block)
///
/// Feature: EXT4_INDEX_FL (0x1000) per-inode in i_flags.
///
/// Freestanding — no std, no libc.

/// Inode flag indicating HTree directory index.
pub const INDEX_FL: u32 = 0x00001000;

/// Hash versions.
pub const HASH_LEGACY: u8 = 0;
pub const HASH_HALF_MD4: u8 = 1;
pub const HASH_TEA: u8 = 2;
pub const HASH_HALF_MD4_UNSIGNED: u8 = 3;
pub const HASH_TEA_UNSIGNED: u8 = 4;

/// DxRoot — the root block of an HTree directory (first directory block).
/// Contains fake "." and ".." entries followed by the index header and entries.
pub const DxRoot = extern struct {
    // Fake "." entry (12 bytes)
    dot_inode: u32,
    dot_rec_len: u16,      // = 12
    dot_name_len: u8,      // = 1
    dot_file_type: u8,     // = 2 (directory)
    dot_name: [4]u8,       // ".\x00\x00\x00"

    // Fake ".." entry
    dotdot_inode: u32,
    dotdot_rec_len: u16,   // = block_size - 12
    dotdot_name_len: u8,   // = 2
    dotdot_file_type: u8,  // = 2
    dotdot_name: [4]u8,    // "..\x00\x00"

    // Root info (hidden in ".." entry's padding)
    _reserved: u32,
    hash_version: u8,      // HASH_* constant
    info_length: u8,       // 8
    indirect_levels: u8,   // 0=single level, 1=two levels
    _unused_flags: u8,

    // Root index entries
    limit: u16,            // Max entries in this block
    count: u16,            // Current entries (including sentinel)
    block: u32,            // Block number of first child (sentinel, always 0)
    // Followed by (count-1) DxEntry structs
};

/// DxEntry — (hash, block) pair in the index.
pub const DxEntry = extern struct {
    hash: u32,    // Hash value (entries sorted by hash)
    block: u32,   // Directory block number containing entries with this hash range
};

/// DxNode — internal (non-root) index block.
pub const DxNode = extern struct {
    // Fake dirent header (8 bytes, inode=0)
    fake_inode: u32,
    fake_rec_len: u16,     // = block_size
    fake_name_len: u8,     // = 0
    fake_file_type: u8,    // = 0

    limit: u16,
    count: u16,
    block: u32,
    // Followed by (count-1) DxEntry structs
};

// ── Hash functions ─────────────────────────────────────────────────────

/// Half-MD4 hash — default hash function for ext3/ext4 directories.
/// Produces a 32-bit hash from a filename and seed.
///
/// The algorithm processes the name 32 bytes at a time through
/// modified MD4 rounds. Must produce identical hashes to Linux for compatibility.
pub fn halfMd4Hash(name: [*]const u8, name_len: u32, seed: [4]u32) u32 {
    var a: u32 = seed[0];
    var b: u32 = seed[1];
    var c: u32 = seed[2];
    var d: u32 = seed[3];

    // Process name 32 bytes at a time
    var offset: u32 = 0;
    while (offset + 32 <= name_len) : (offset += 32) {
        var input: [8]u32 = undefined;
        for (0..8) |i| {
            const o = offset + @as(u32, @truncate(i)) * 4;
            input[i] = @as(u32, name[o]) |
                (@as(u32, name[o + 1]) << 8) |
                (@as(u32, name[o + 2]) << 16) |
                (@as(u32, name[o + 3]) << 24);
        }

        halfMd4Transform(&a, &b, &c, &d, &input);
    }

    // Handle remaining bytes
    if (offset < name_len) {
        var input: [8]u32 = [_]u32{0} ** 8;
        var idx: u32 = 0;
        var remaining = name_len - offset;
        while (remaining > 0) {
            const word_idx = idx / 4;
            const byte_idx = idx % 4;
            input[word_idx] |= @as(u32, name[offset + idx]) << @as(u5, @truncate(byte_idx * 8));
            idx += 1;
            remaining -= 1;
        }
        // Pad with length
        input[7] = name_len;
        halfMd4Transform(&a, &b, &c, &d, &input);
    }

    return b; // half-MD4 returns second word as hash
}

/// TEA (Tiny Encryption Algorithm) hash — alternative.
pub fn teaHash(name: [*]const u8, name_len: u32, seed: [4]u32) u32 {
    var a: u32 = seed[0];
    var b: u32 = seed[1];
    var c: u32 = seed[2];
    var d: u32 = seed[3];

    var offset: u32 = 0;
    while (offset + 16 <= name_len) : (offset += 16) {
        var k: [4]u32 = undefined;
        for (0..4) |i| {
            const o = offset + @as(u32, @truncate(i)) * 4;
            k[i] = @as(u32, name[o]) |
                (@as(u32, name[o + 1]) << 8) |
                (@as(u32, name[o + 2]) << 16) |
                (@as(u32, name[o + 3]) << 24);
        }
        teaTransform(&a, &b, &c, &d, &k);
    }

    // Handle remaining
    if (offset < name_len) {
        var k: [4]u32 = [_]u32{0} ** 4;
        var idx: u32 = 0;
        while (offset + idx < name_len) : (idx += 1) {
            const word_idx = idx / 4;
            const byte_idx = idx % 4;
            k[word_idx] |= @as(u32, name[offset + idx]) << @as(u5, @truncate(byte_idx * 8));
        }
        teaTransform(&a, &b, &c, &d, &k);
    }

    return a ^ b;
}

/// Select hash function by version.
pub fn computeHash(
    name: [*]const u8,
    name_len: u32,
    seed: [4]u32,
    hash_version: u8,
) u32 {
    return switch (hash_version) {
        HASH_HALF_MD4, HASH_HALF_MD4_UNSIGNED => halfMd4Hash(name, name_len, seed),
        HASH_TEA, HASH_TEA_UNSIGNED => teaHash(name, name_len, seed),
        else => halfMd4Hash(name, name_len, seed), // Legacy uses half_md4
    };
}

// ── Index navigation ───────────────────────────────────────────────────

/// Get DxEntry array from a root block (after the DxRoot header).
pub fn getRootEntries(buf: [*]const u8) [*]const DxEntry {
    // Entries start after DxRoot header + the sentinel entry (block field)
    const offset = @sizeOf(DxRoot);
    return @ptrCast(@alignCast(buf + offset));
}

/// Get DxEntry array from an internal node (after the DxNode header).
pub fn getNodeEntries(buf: [*]const u8) [*]const DxEntry {
    const offset = @sizeOf(DxNode);
    return @ptrCast(@alignCast(buf + offset));
}

/// Binary search for the index entry covering a given hash.
/// Returns the block number of the leaf block containing entries with this hash.
pub fn searchEntries(entries: [*]const DxEntry, count: u16, hash: u32) u32 {
    if (count <= 1) return entries[0].block;

    // Binary search: find last entry where entry.hash <= hash
    var lo: u16 = 0;
    var hi: u16 = count - 1; // -1 because count includes sentinel
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        if (entries[mid].hash <= hash) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }

    return entries[lo].block;
}

/// Check if an inode uses HTree indexing.
pub fn usesHTree(i_flags: u32) bool {
    return i_flags & INDEX_FL != 0;
}

// ── Internal MD4/TEA transforms ────────────────────────────────────────

inline fn F(x: u32, y: u32, z: u32) u32 {
    return (x & y) | (~x & z);
}

inline fn G(x: u32, y: u32, z: u32) u32 {
    return (x & y) | (x & z) | (y & z);
}

inline fn H(x: u32, y: u32, z: u32) u32 {
    return x ^ y ^ z;
}

inline fn rotl(val: u32, comptime n: comptime_int) u32 {
    return (val << @as(u5, n)) | (val >> @as(u5, 32 - n));
}

fn halfMd4Transform(a: *u32, b: *u32, c: *u32, d: *u32, input: *const [8]u32) void {
    var aa = a.*;
    var bb = b.*;
    var cc = c.*;
    var dd = d.*;

    // Round 1
    aa = rotl(aa +% F(bb, cc, dd) +% input[0], 3);
    dd = rotl(dd +% F(aa, bb, cc) +% input[1], 7);
    cc = rotl(cc +% F(dd, aa, bb) +% input[2], 11);
    bb = rotl(bb +% F(cc, dd, aa) +% input[3], 19);
    aa = rotl(aa +% F(bb, cc, dd) +% input[4], 3);
    dd = rotl(dd +% F(aa, bb, cc) +% input[5], 7);
    cc = rotl(cc +% F(dd, aa, bb) +% input[6], 11);
    bb = rotl(bb +% F(cc, dd, aa) +% input[7], 19);

    // Round 2
    const k2: u32 = 0x5A827999;
    aa = rotl(aa +% G(bb, cc, dd) +% input[1] +% k2, 3);
    dd = rotl(dd +% G(aa, bb, cc) +% input[3] +% k2, 5);
    cc = rotl(cc +% G(dd, aa, bb) +% input[5] +% k2, 9);
    bb = rotl(bb +% G(cc, dd, aa) +% input[7] +% k2, 13);
    aa = rotl(aa +% G(bb, cc, dd) +% input[0] +% k2, 3);
    dd = rotl(dd +% G(aa, bb, cc) +% input[2] +% k2, 5);
    cc = rotl(cc +% G(dd, aa, bb) +% input[4] +% k2, 9);
    bb = rotl(bb +% G(cc, dd, aa) +% input[6] +% k2, 13);

    // Round 3
    const k3: u32 = 0x6ED9EBA1;
    aa = rotl(aa +% H(bb, cc, dd) +% input[3] +% k3, 3);
    dd = rotl(dd +% H(aa, bb, cc) +% input[7] +% k3, 9);
    cc = rotl(cc +% H(dd, aa, bb) +% input[2] +% k3, 11);
    bb = rotl(bb +% H(cc, dd, aa) +% input[6] +% k3, 15);
    aa = rotl(aa +% H(bb, cc, dd) +% input[1] +% k3, 3);
    dd = rotl(dd +% H(aa, bb, cc) +% input[5] +% k3, 9);
    cc = rotl(cc +% H(dd, aa, bb) +% input[0] +% k3, 11);
    bb = rotl(bb +% H(cc, dd, aa) +% input[4] +% k3, 15);

    a.* +%= aa;
    b.* +%= bb;
    c.* +%= cc;
    d.* +%= dd;
}

fn teaTransform(a: *u32, b: *u32, c: *u32, d: *u32, k: *const [4]u32) void {
    var sum: u32 = 0;
    const delta: u32 = 0x9E3779B9;
    var aa = a.*;
    var bb = b.*;

    // 16 rounds of TEA
    for (0..16) |_| {
        sum +%= delta;
        aa +%= ((bb << 4) +% k[0]) ^ (bb +% sum) ^ ((bb >> 5) +% k[1]);
        bb +%= ((aa << 4) +% k[2]) ^ (aa +% sum) ^ ((aa >> 5) +% k[3]);
    }

    _ = c;
    _ = d;
    a.* = aa;
    b.* = bb;
}
