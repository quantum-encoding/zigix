/// crypto.zig — Freestanding crypto primitives for zsshd.
/// SHA-256, SHA-512, Curve25519, ChaCha20-Poly1305, Ed25519.
/// Based on TweetNaCl approach: compact, auditable, no std library.

// ============================================================================
// SHA-256
// ============================================================================

const K256 = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

fn rotr32(x: u32, comptime n: u5) u32 {
    return (x >> n) | (x << comptime @as(u5, @intCast(@as(u8, 32) - @as(u8, n))));
}

fn ch32(x: u32, y: u32, z: u32) u32 {
    return (x & y) ^ (~x & z);
}

fn maj32(x: u32, y: u32, z: u32) u32 {
    return (x & y) ^ (x & z) ^ (y & z);
}

fn sigma0_256(x: u32) u32 {
    return rotr32(x, 2) ^ rotr32(x, 13) ^ rotr32(x, 22);
}

fn sigma1_256(x: u32) u32 {
    return rotr32(x, 6) ^ rotr32(x, 11) ^ rotr32(x, 25);
}

fn gamma0_256(x: u32) u32 {
    return rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3);
}

fn gamma1_256(x: u32) u32 {
    return rotr32(x, 17) ^ rotr32(x, 19) ^ (x >> 10);
}

fn load32be(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | @as(u32, b[3]);
}

fn store32be(buf: []u8, v: u32) void {
    buf[0] = @truncate(v >> 24);
    buf[1] = @truncate(v >> 16);
    buf[2] = @truncate(v >> 8);
    buf[3] = @truncate(v);
}

fn load64be(b: []const u8) u64 {
    return (@as(u64, b[0]) << 56) | (@as(u64, b[1]) << 48) | (@as(u64, b[2]) << 40) | (@as(u64, b[3]) << 32) |
        (@as(u64, b[4]) << 24) | (@as(u64, b[5]) << 16) | (@as(u64, b[6]) << 8) | @as(u64, b[7]);
}

fn store64be(buf: []u8, v: u64) void {
    buf[0] = @truncate(v >> 56);
    buf[1] = @truncate(v >> 48);
    buf[2] = @truncate(v >> 40);
    buf[3] = @truncate(v >> 32);
    buf[4] = @truncate(v >> 24);
    buf[5] = @truncate(v >> 16);
    buf[6] = @truncate(v >> 8);
    buf[7] = @truncate(v);
}

pub const Sha256 = struct {
    state: [8]u32,
    buf: [64]u8,
    buf_len: u8,
    total_len: u64,

    pub fn init() Sha256 {
        return .{
            .state = .{ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    fn compress(self: *Sha256, block: []const u8) void {
        var w: [64]u32 = undefined;
        for (0..16) |i| {
            w[i] = load32be(block[i * 4 ..]);
        }
        for (16..64) |i| {
            w[i] = gamma1_256(w[i - 2]) +% w[i - 7] +% gamma0_256(w[i - 15]) +% w[i - 16];
        }
        var a = self.state[0];
        var b = self.state[1];
        var c = self.state[2];
        var d = self.state[3];
        var e = self.state[4];
        var f = self.state[5];
        var g = self.state[6];
        var h = self.state[7];
        for (0..64) |i| {
            const t1 = h +% sigma1_256(e) +% ch32(e, f, g) +% K256[i] +% w[i];
            const t2 = sigma0_256(a) +% maj32(a, b, c);
            h = g;
            g = f;
            f = e;
            e = d +% t1;
            d = c;
            c = b;
            b = a;
            a = t1 +% t2;
        }
        self.state[0] +%= a;
        self.state[1] +%= b;
        self.state[2] +%= c;
        self.state[3] +%= d;
        self.state[4] +%= e;
        self.state[5] +%= f;
        self.state[6] +%= g;
        self.state[7] +%= h;
    }

    pub fn update(self: *Sha256, data: []const u8) void {
        var off: usize = 0;
        self.total_len += data.len;
        // Fill partial buffer
        if (self.buf_len > 0) {
            const need = 64 - @as(usize, self.buf_len);
            if (data.len < need) {
                @memcpy(self.buf[self.buf_len..][0..data.len], data);
                self.buf_len += @truncate(data.len);
                return;
            }
            @memcpy(self.buf[self.buf_len..][0..need], data[0..need]);
            self.compress(&self.buf);
            self.buf_len = 0;
            off = need;
        }
        // Process full blocks
        while (off + 64 <= data.len) : (off += 64) {
            self.compress(data[off..]);
        }
        // Buffer remainder
        const rem = data.len - off;
        if (rem > 0) {
            @memcpy(self.buf[0..rem], data[off..][0..rem]);
            self.buf_len = @truncate(rem);
        }
    }

    pub fn final(self: *Sha256) [32]u8 {
        // Pad: append 1 bit, zeros, 64-bit big-endian length
        var pad: [128]u8 = .{0} ** 128;
        pad[0] = 0x80;
        const bit_len = self.total_len * 8;
        const bl: u8 = self.buf_len;
        const pad_len: u8 = if (bl < 56) (56 - bl) else (120 - bl);
        self.update(pad[0..pad_len]);
        var len_buf: [8]u8 = undefined;
        store64be(&len_buf, bit_len);
        self.update(&len_buf);

        var out: [32]u8 = undefined;
        for (0..8) |i| {
            store32be(out[i * 4 ..], self.state[i]);
        }
        return out;
    }
};

pub fn sha256(data: []const u8) [32]u8 {
    var h = Sha256.init();
    h.update(data);
    return h.final();
}

// ============================================================================
// SHA-512
// ============================================================================

const K512 = [80]u64{
    0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
    0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
    0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
    0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
    0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
    0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
    0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
    0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
    0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
    0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
    0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
    0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
    0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
    0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
    0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
    0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
    0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
    0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
    0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
    0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
};

fn rotr64(x: u64, comptime n: u6) u64 {
    return (x >> n) | (x << comptime @as(u6, @intCast(@as(u8, 64) - @as(u8, n))));
}

const Sha512 = struct {
    state: [8]u64,
    buf: [128]u8,
    buf_len: u8,
    total_len: u64,

    fn init_state() Sha512 {
        return .{
            .state = .{
                0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
            },
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    fn compress(self: *Sha512, block: []const u8) void {
        var w: [80]u64 = undefined;
        for (0..16) |i| {
            w[i] = load64be(block[i * 8 ..]);
        }
        for (16..80) |i| {
            const s0 = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7);
            const s1 = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6);
            w[i] = s1 +% w[i - 7] +% s0 +% w[i - 16];
        }
        var a = self.state[0];
        var b = self.state[1];
        var c = self.state[2];
        var d = self.state[3];
        var e = self.state[4];
        var f = self.state[5];
        var g = self.state[6];
        var h = self.state[7];
        for (0..80) |i| {
            const s1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41);
            const ch = (e & f) ^ (~e & g);
            const t1 = h +% s1 +% ch +% K512[i] +% w[i];
            const s0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39);
            const mj = (a & b) ^ (a & c) ^ (b & c);
            const t2 = s0 +% mj;
            h = g;
            g = f;
            f = e;
            e = d +% t1;
            d = c;
            c = b;
            b = a;
            a = t1 +% t2;
        }
        self.state[0] +%= a;
        self.state[1] +%= b;
        self.state[2] +%= c;
        self.state[3] +%= d;
        self.state[4] +%= e;
        self.state[5] +%= f;
        self.state[6] +%= g;
        self.state[7] +%= h;
    }

    fn update(self: *Sha512, data: []const u8) void {
        var off: usize = 0;
        self.total_len += data.len;
        if (self.buf_len > 0) {
            const need = 128 - @as(usize, self.buf_len);
            if (data.len < need) {
                @memcpy(self.buf[self.buf_len..][0..data.len], data);
                self.buf_len += @truncate(data.len);
                return;
            }
            @memcpy(self.buf[self.buf_len..][0..need], data[0..need]);
            self.compress(&self.buf);
            self.buf_len = 0;
            off = need;
        }
        while (off + 128 <= data.len) : (off += 128) {
            self.compress(data[off..]);
        }
        const rem = data.len - off;
        if (rem > 0) {
            @memcpy(self.buf[0..rem], data[off..][0..rem]);
            self.buf_len = @truncate(rem);
        }
    }

    fn final512(self: *Sha512) [64]u8 {
        var pad: [256]u8 = .{0} ** 256;
        pad[0] = 0x80;
        const bit_len = self.total_len * 8;
        const bl: u8 = self.buf_len;
        const pad_len: u8 = if (bl < 112) (112 - bl) else (240 - bl);
        self.update(pad[0..pad_len]);
        // 128-bit length (upper 64 bits always 0 for our use)
        var len_buf: [16]u8 = .{0} ** 16;
        store64be(len_buf[8..], bit_len);
        self.update(&len_buf);

        var out: [64]u8 = undefined;
        for (0..8) |i| {
            store64be(out[i * 8 ..], self.state[i]);
        }
        return out;
    }
};

pub fn sha512(data: []const u8) [64]u8 {
    var h = Sha512.init_state();
    h.update(data);
    return h.final512();
}

// ============================================================================
// Curve25519 (Montgomery ladder, TweetNaCl-style 16-limb representation)
// ============================================================================

const Fe = [16]i64; // Field element: 16 limbs of ~16 bits each

const fe_zero: Fe = .{0} ** 16;
const fe_one: Fe = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

// The base point (9) in packed form
const curve25519_basepoint: [32]u8 = .{ 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

fn fe_unpack(o: *Fe, n: *const [32]u8) void {
    for (0..16) |i| {
        o[i] = @as(i64, n[2 * i]) + (@as(i64, n[2 * i + 1]) << 8);
    }
    o[15] &= 0x7fff;
}

fn fe_pack(o: *[32]u8, n: *const Fe) void {
    var t: Fe = undefined;
    var m: Fe = undefined;
    @memcpy(&t, n);
    fe_carry(&t);
    fe_carry(&t);
    fe_carry(&t);
    // Reduce mod 2^255-19
    for (0..2) |_| {
        m[0] = t[0] - 0xffed;
        var j: usize = 1;
        while (j < 15) : (j += 1) {
            m[j] = t[j] - 0xffff - ((m[j - 1] >> 16) & 1);
            m[j - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        const b = (m[15] >> 16) & 1;
        m[14] &= 0xffff;
        fe_cswap(&t, &m, 1 - b);
    }
    for (0..16) |i| {
        o[2 * i] = @truncate(@as(u64, @bitCast(t[i])));
        o[2 * i + 1] = @truncate(@as(u64, @bitCast(t[i])) >> 8);
    }
}

fn fe_carry(o: *Fe) void {
    for (0..16) |i| {
        o[i] += (1 << 16);
        const c = o[i] >> 16;
        o[(i + 1) * @intFromBool(i < 15)] += c - 1 + 37 * (c - 1) * @as(i64, @intFromBool(i == 15));
        o[i] -= c << 16;
    }
}

fn fe_add(o: *Fe, a: *const Fe, b: *const Fe) void {
    for (0..16) |i| o[i] = a[i] + b[i];
}

fn fe_sub(o: *Fe, a: *const Fe, b: *const Fe) void {
    for (0..16) |i| o[i] = a[i] - b[i];
}

fn fe_mul(o: *Fe, a: *const Fe, b: *const Fe) void {
    var t: [31]i64 = .{0} ** 31;
    for (0..16) |i| {
        for (0..16) |j| {
            t[i + j] += a[i] * b[j];
        }
    }
    for (16..31) |i| {
        t[i - 16] += 38 * t[i];
    }
    @memcpy(o, t[0..16]);
    fe_carry(o);
    fe_carry(o);
}

fn fe_sq(o: *Fe, a: *const Fe) void {
    fe_mul(o, a, a);
}

fn fe_cswap(p: *Fe, q: *Fe, b: i64) void {
    const c = ~(b -% 1);
    for (0..16) |i| {
        const t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

fn fe_inv(o: *Fe, a: *const Fe) void {
    // a^(p-2) mod p where p = 2^255 - 19
    var c: Fe = undefined;
    @memcpy(&c, a);
    var i: i32 = 253;
    while (i >= 0) : (i -= 1) {
        fe_sq(&c, &c);
        if (@as(usize, @intCast(i)) != 2 and @as(usize, @intCast(i)) != 4) {
            fe_mul(&c, &c, a);
        }
    }
    @memcpy(o, &c);
}

pub fn scalarmult(q: *[32]u8, n: *const [32]u8, p: *const [32]u8) void {
    var z: [32]u8 = undefined;
    @memcpy(&z, n);
    z[31] = (z[31] & 127) | 64;
    z[0] &= 248;

    var x: Fe = undefined;
    fe_unpack(&x, p);
    var b_fe: Fe = x;
    var a: Fe = fe_one;
    var c: Fe = fe_zero;
    var d: Fe = fe_one;

    var i: i32 = 254;
    while (i >= 0) : (i -= 1) {
        const bit: i64 = @intCast((z[@intCast(@as(u32, @intCast(i)) >> 3)] >> @intCast(@as(u5, @truncate(@as(u32, @intCast(i)))))) & 1);
        fe_cswap(&a, &c, bit);
        fe_cswap(&b_fe, &d, bit);

        var e: Fe = undefined;
        fe_add(&e, &a, &b_fe);
        var f_fe: Fe = undefined; // renamed to avoid conflict
        fe_sub(&f_fe, &a, &b_fe);
        var g: Fe = undefined;
        fe_add(&g, &c, &d);
        var h: Fe = undefined;
        fe_sub(&h, &c, &d);
        fe_mul(&a, &e, &h);
        fe_mul(&b_fe, &f_fe, &g);
        fe_sq(&c, &e);  // reuse: c = e^2 — wait, this overwrites c before we use it. Let me restructure.

        // Actually the standard Montgomery ladder:
        // We need temporaries. Let's redo properly:
        var da: Fe = undefined;
        fe_mul(&da, &f_fe, &g);
        var cb_val: Fe = undefined;
        fe_mul(&cb_val, &e, &h);
        var t1: Fe = undefined;
        fe_add(&t1, &cb_val, &da);
        var t2: Fe = undefined;
        fe_sub(&t2, &cb_val, &da);
        fe_sq(&b_fe, &t1);
        var t3: Fe = undefined;
        fe_sq(&t3, &t2);
        fe_mul(&d, &t3, &x);
        var aa: Fe = undefined;
        fe_sq(&aa, &e);
        var bb: Fe = undefined;
        fe_sq(&bb, &f_fe);
        fe_mul(&a, &aa, &bb);
        var t4: Fe = undefined;
        fe_sub(&t4, &aa, &bb);
        var t5: Fe = undefined;
        const a121665: Fe = .{ 0xdb41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        fe_mul(&t5, &a121665, &t4);
        fe_add(&c, &bb, &t5); // reuse c
        fe_mul(&c, &c, &t4);

        fe_cswap(&a, &c, bit);
        fe_cswap(&b_fe, &d, bit);
    }

    var inv_d: Fe = undefined;
    fe_inv(&inv_d, &d);
    fe_mul(&a, &c, &inv_d);
    fe_pack(q, &a);
}

pub fn scalarmult_base(q: *[32]u8, n: *const [32]u8) void {
    var bp = curve25519_basepoint;
    scalarmult(q, n, &bp);
}

// ============================================================================
// ChaCha20
// ============================================================================

fn rotl32(x: u32, comptime n: u5) u32 {
    return (x << n) | (x >> comptime @as(u5, @intCast(@as(u8, 32) - @as(u8, n))));
}

fn quarter_round(state: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
    state[a] +%= state[b];
    state[d] ^= state[a];
    state[d] = rotl32(state[d], 16);
    state[c] +%= state[d];
    state[b] ^= state[c];
    state[b] = rotl32(state[b], 12);
    state[a] +%= state[b];
    state[d] ^= state[a];
    state[d] = rotl32(state[d], 8);
    state[c] +%= state[d];
    state[b] ^= state[c];
    state[b] = rotl32(state[b], 7);
}

fn load32le(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

fn store32le(buf: []u8, v: u32) void {
    buf[0] = @truncate(v);
    buf[1] = @truncate(v >> 8);
    buf[2] = @truncate(v >> 16);
    buf[3] = @truncate(v >> 24);
}

fn chacha20_block(key: *const [32]u8, counter: u32, nonce: *const [12]u8) [64]u8 {
    var state: [16]u32 = undefined;
    // "expand 32-byte k"
    state[0] = 0x61707865;
    state[1] = 0x3320646e;
    state[2] = 0x79622d32;
    state[3] = 0x6b206574;
    for (0..8) |i| {
        state[4 + i] = load32le(key[i * 4 ..]);
    }
    state[12] = counter;
    for (0..3) |i| {
        state[13 + i] = load32le(nonce[i * 4 ..]);
    }
    var working = state;
    for (0..10) |_| {
        quarter_round(&working, 0, 4, 8, 12);
        quarter_round(&working, 1, 5, 9, 13);
        quarter_round(&working, 2, 6, 10, 14);
        quarter_round(&working, 3, 7, 11, 15);
        quarter_round(&working, 0, 5, 10, 15);
        quarter_round(&working, 1, 6, 11, 12);
        quarter_round(&working, 2, 7, 8, 13);
        quarter_round(&working, 3, 4, 9, 14);
    }
    var out: [64]u8 = undefined;
    for (0..16) |i| {
        store32le(out[i * 4 ..], working[i] +% state[i]);
    }
    return out;
}

pub fn chacha20_xor(out: []u8, data: []const u8, key: *const [32]u8, counter: u32, nonce: *const [12]u8) void {
    var ctr = counter;
    var off: usize = 0;
    while (off < data.len) {
        const block = chacha20_block(key, ctr, nonce);
        const rem = data.len - off;
        const n = if (rem < 64) rem else 64;
        for (0..n) |i| {
            out[off + i] = data[off + i] ^ block[i];
        }
        ctr +%= 1;
        off += n;
    }
}

// ============================================================================
// Poly1305
// ============================================================================

pub fn poly1305_mac(tag: *[16]u8, msg: []const u8, key: *const [32]u8) void {
    // Clamp r
    var r: [5]u64 = undefined;
    r[0] = (@as(u64, load32le(key[0..]))) & 0x3ffffff;
    r[1] = (@as(u64, load32le(key[3..])) >> 2) & 0x3ffff03;
    r[2] = (@as(u64, load32le(key[6..])) >> 4) & 0x3ffc0ff;
    r[3] = (@as(u64, load32le(key[9..])) >> 6) & 0x3f03fff;
    r[4] = (@as(u64, load32le(key[12..])) >> 8) & 0x00fffff;

    var h: [5]u64 = .{0} ** 5;
    const s: [4]u32 = .{
        load32le(key[16..]),
        load32le(key[20..]),
        load32le(key[24..]),
        load32le(key[28..]),
    };

    var off: usize = 0;
    while (off < msg.len) {
        const rem = msg.len - off;
        const n = if (rem < 16) rem else 16;
        // Load block
        var t: [5]u64 = .{0} ** 5;
        var block: [17]u8 = .{0} ** 17;
        @memcpy(block[0..n], msg[off..][0..n]);
        block[n] = 1; // high bit

        t[0] = (@as(u64, block[0]) | (@as(u64, block[1]) << 8) | (@as(u64, block[2]) << 16) | (@as(u64, block[3]) << 24)) & 0x3ffffff;
        t[1] = ((@as(u64, block[3]) | (@as(u64, block[4]) << 8) | (@as(u64, block[5]) << 16) | (@as(u64, block[6]) << 24)) >> 2) & 0x3ffffff;
        t[2] = ((@as(u64, block[6]) | (@as(u64, block[7]) << 8) | (@as(u64, block[8]) << 16) | (@as(u64, block[9]) << 24)) >> 4) & 0x3ffffff;
        t[3] = ((@as(u64, block[9]) | (@as(u64, block[10]) << 8) | (@as(u64, block[11]) << 16) | (@as(u64, block[12]) << 24)) >> 6) & 0x3ffffff;
        t[4] = ((@as(u64, block[12]) | (@as(u64, block[13]) << 8) | (@as(u64, block[14]) << 16) | (@as(u64, block[15]) << 24)) >> 8);
        if (n == 16) {
            t[4] |= (1 << 24);
        }

        h[0] += t[0];
        h[1] += t[1];
        h[2] += t[2];
        h[3] += t[3];
        h[4] += t[4];

        // Multiply h by r
        var d: [5]u128 = undefined;
        const r0 = @as(u128, r[0]);
        const r1 = @as(u128, r[1]);
        const r2 = @as(u128, r[2]);
        const r3 = @as(u128, r[3]);
        const r4 = @as(u128, r[4]);
        const s1 = r1 * 5;
        const s2 = r2 * 5;
        const s3 = r3 * 5;
        const s4 = r4 * 5;

        d[0] = @as(u128, h[0]) * r0 + @as(u128, h[1]) * s4 + @as(u128, h[2]) * s3 + @as(u128, h[3]) * s2 + @as(u128, h[4]) * s1;
        d[1] = @as(u128, h[0]) * r1 + @as(u128, h[1]) * r0 + @as(u128, h[2]) * s4 + @as(u128, h[3]) * s3 + @as(u128, h[4]) * s2;
        d[2] = @as(u128, h[0]) * r2 + @as(u128, h[1]) * r1 + @as(u128, h[2]) * r0 + @as(u128, h[3]) * s4 + @as(u128, h[4]) * s3;
        d[3] = @as(u128, h[0]) * r3 + @as(u128, h[1]) * r2 + @as(u128, h[2]) * r1 + @as(u128, h[3]) * r0 + @as(u128, h[4]) * s4;
        d[4] = @as(u128, h[0]) * r4 + @as(u128, h[1]) * r3 + @as(u128, h[2]) * r2 + @as(u128, h[3]) * r1 + @as(u128, h[4]) * r0;

        // Carry
        var c: u64 = undefined;
        c = @truncate(d[0] >> 26);
        h[0] = @truncate(d[0] & 0x3ffffff);
        d[1] += c;
        c = @truncate(d[1] >> 26);
        h[1] = @truncate(d[1] & 0x3ffffff);
        d[2] += c;
        c = @truncate(d[2] >> 26);
        h[2] = @truncate(d[2] & 0x3ffffff);
        d[3] += c;
        c = @truncate(d[3] >> 26);
        h[3] = @truncate(d[3] & 0x3ffffff);
        d[4] += c;
        c = @truncate(d[4] >> 26);
        h[4] = @truncate(d[4] & 0x3ffffff);
        h[0] += c * 5;
        c = h[0] >> 26;
        h[0] &= 0x3ffffff;
        h[1] += c;

        off += 16;
    }

    // Final reduce
    var c2: u64 = h[1] >> 26;
    h[1] &= 0x3ffffff;
    h[2] += c2;
    c2 = h[2] >> 26;
    h[2] &= 0x3ffffff;
    h[3] += c2;
    c2 = h[3] >> 26;
    h[3] &= 0x3ffffff;
    h[4] += c2;
    c2 = h[4] >> 26;
    h[4] &= 0x3ffffff;
    h[0] += c2 * 5;
    c2 = h[0] >> 26;
    h[0] &= 0x3ffffff;
    h[1] += c2;

    // Compute h + -p
    var g: [5]u64 = undefined;
    g[0] = h[0] + 5;
    c2 = g[0] >> 26;
    g[0] &= 0x3ffffff;
    g[1] = h[1] + c2;
    c2 = g[1] >> 26;
    g[1] &= 0x3ffffff;
    g[2] = h[2] + c2;
    c2 = g[2] >> 26;
    g[2] &= 0x3ffffff;
    g[3] = h[3] + c2;
    c2 = g[3] >> 26;
    g[3] &= 0x3ffffff;
    g[4] = h[4] + c2 -% (1 << 26);

    // Select h or g
    const mask = (g[4] >> 63) -% 1; // 0 if g[4] negative, 0xfff...f if positive (use g)
    // Actually: if g[4] bit 63 is set (negative), mask = 0, use h. Else mask = all-1s, use g.
    h[0] = (h[0] & ~mask) | (g[0] & mask);
    h[1] = (h[1] & ~mask) | (g[1] & mask);
    h[2] = (h[2] & ~mask) | (g[2] & mask);
    h[3] = (h[3] & ~mask) | (g[3] & mask);
    h[4] = (h[4] & ~mask) | (g[4] & mask);

    // Assemble h into 4 x u32
    var f0 = ((h[0]) | (h[1] << 26)) & 0xffffffff;
    var f1 = ((h[1] >> 6) | (h[2] << 20)) & 0xffffffff;
    var f2 = ((h[2] >> 12) | (h[3] << 14)) & 0xffffffff;
    var f3 = ((h[3] >> 18) | (h[4] << 8)) & 0xffffffff;

    // Add s
    var acc: u64 = f0 + @as(u64, s[0]);
    f0 = acc & 0xffffffff;
    acc = (acc >> 32) + f1 + @as(u64, s[1]);
    f1 = acc & 0xffffffff;
    acc = (acc >> 32) + f2 + @as(u64, s[2]);
    f2 = acc & 0xffffffff;
    acc = (acc >> 32) + f3 + @as(u64, s[3]);
    f3 = acc & 0xffffffff;

    store32le(tag[0..], @truncate(f0));
    store32le(tag[4..], @truncate(f1));
    store32le(tag[8..], @truncate(f2));
    store32le(tag[12..], @truncate(f3));
}

// ============================================================================
// ChaCha20-Poly1305 AEAD (OpenSSH variant)
//
// OpenSSH chacha20-poly1305@openssh.com:
//   64-byte key = K_main (bytes 0-31) || K_header (bytes 32-63)
//   K_header encrypts the 4-byte packet length
//   K_main encrypts the payload
//   Nonce = sequence number as 8-byte big-endian, padded to 12 bytes (4 zero + 8 seq)
//   Poly1305 key = first 32 bytes of ChaCha20(K_main, counter=0, nonce)
//   Poly1305 tag covers the encrypted packet length + encrypted payload
// ============================================================================

pub fn openssh_nonce(seq: u32) [12]u8 {
    var nonce: [12]u8 = .{0} ** 12;
    store32be(nonce[8..], seq);
    return nonce;
}

/// Encrypt packet length (4 bytes) with K_header.
pub fn encrypt_length(out: *[4]u8, pkt_len: u32, key_header: *const [32]u8, seq: u32) void {
    var len_buf: [4]u8 = undefined;
    store32be(&len_buf, pkt_len);
    const nonce = openssh_nonce(seq);
    var enc: [4]u8 = undefined;
    chacha20_xor(&enc, &len_buf, key_header, 0, &nonce);
    out.* = enc;
}

/// Decrypt packet length (4 bytes) with K_header.
pub fn decrypt_length(enc_len: *const [4]u8, key_header: *const [32]u8, seq: u32) u32 {
    const nonce = openssh_nonce(seq);
    var dec: [4]u8 = undefined;
    chacha20_xor(&dec, enc_len, key_header, 0, &nonce);
    return load32be(&dec);
}

/// Encrypt payload and compute Poly1305 tag.
/// aad = encrypted packet length (4 bytes).
pub fn aead_encrypt(ciphertext: []u8, tag: *[16]u8, plaintext: []const u8, aad: *const [4]u8, key_main: *const [32]u8, seq: u32) void {
    const nonce = openssh_nonce(seq);
    // Poly1305 key = ChaCha20(K_main, counter=0, nonce) first 32 bytes
    const poly_block = chacha20_block(key_main, 0, &nonce);
    var poly_key: [32]u8 = undefined;
    @memcpy(&poly_key, poly_block[0..32]);

    // Encrypt payload with counter starting at 1
    chacha20_xor(ciphertext, plaintext, key_main, 1, &nonce);

    // Poly1305 over aad || ciphertext
    var mac_data: [4 + 4096]u8 = undefined;
    @memcpy(mac_data[0..4], aad);
    @memcpy(mac_data[4..][0..plaintext.len], ciphertext[0..plaintext.len]);
    poly1305_mac(tag, mac_data[0 .. 4 + plaintext.len], &poly_key);
}

/// Decrypt payload and verify Poly1305 tag. Returns true if tag valid.
pub fn aead_decrypt(plaintext: []u8, ciphertext: []const u8, tag: *const [16]u8, aad: *const [4]u8, key_main: *const [32]u8, seq: u32) bool {
    const nonce = openssh_nonce(seq);
    // Poly1305 key
    const poly_block = chacha20_block(key_main, 0, &nonce);
    var poly_key: [32]u8 = undefined;
    @memcpy(&poly_key, poly_block[0..32]);

    // Verify tag
    var mac_data: [4 + 4096]u8 = undefined;
    @memcpy(mac_data[0..4], aad);
    @memcpy(mac_data[4..][0..ciphertext.len], ciphertext[0..ciphertext.len]);
    var expected_tag: [16]u8 = undefined;
    poly1305_mac(&expected_tag, mac_data[0 .. 4 + ciphertext.len], &poly_key);

    // Constant-time compare
    var diff: u8 = 0;
    for (0..16) |i| {
        diff |= expected_tag[i] ^ tag[i];
    }
    if (diff != 0) return false;

    // Decrypt
    chacha20_xor(plaintext, ciphertext, key_main, 1, &nonce);
    return true;
}

// ============================================================================
// Ed25519 (Extended coordinates on twisted Edwards curve -x^2 + y^2 = 1 + dx^2y^2)
// ============================================================================

// d = -121665/121666 mod p
const ed25519_d: Fe = .{ 0x78a3, -0x1513, -0x7398, -0x60f5, 0x3a5b, 0x1a43, -0x649d, 0x1a9a, -0x0192, -0x7a10, 0x75d7, -0x1ba4, -0x3e15, 0x3e48, -0x28e4, 0x0131 };
const ed25519_d2: Fe = .{ 0x2b2f, 0x6592, -0x72f0, 0x1e16, 0x74b7, 0x3486, 0x4b39, 0x3534, -0x0325, 0x0bc0, -0x4b52, 0x2498, 0x03ca, 0x7c90, 0x4e38, 0x0262 };
const ed25519_I: Fe = .{ -0x4fca, -0x37c2, -0x0bde, -0x0cfd, -0x34b9, 0x68be, 0x60e3, 0x3927, -0x1fb4, -0x6327, -0x7972, -0x76f4, 0x1e1e, -0x1919, 0x5a7e, 0x0a56 };

// Base point B in extended coordinates
const ed25519_bx: Fe = .{ 0x325d, -0x70d2, -0x277d, -0x69eb, 0x001a, 0x6e07, 0x2e82, 0x5dba, -0x6b3b, 0x7a3e, 0x5939, -0x1c8b, 0x4e30, 0x32c3, 0x3b5f, 0x1a83 };
const ed25519_by: Fe = .{ 0x2666, 0x1999, 0x6666, 0x3333, -0x0001, -0x6667, 0x3332, 0x6666, 0x6666, 0x3333, -0x0001, -0x6667, 0x3332, 0x6666, 0x6666, 0x1999 };

const GePt = [4]Fe; // Extended: X, Y, Z, T

fn ge_add(r: *GePt, p: *const GePt, q: *const GePt) void {
    var a: Fe = undefined;
    var b: Fe = undefined;
    var c: Fe = undefined;
    var dd: Fe = undefined;
    var e: Fe = undefined;
    var f_fe: Fe = undefined;
    var g: Fe = undefined;
    var hh: Fe = undefined;

    // a = (Y1-X1)*(Y2-X2), b = (Y1+X1)*(Y2+X2)
    fe_sub(&a, &p[1], &p[0]);
    var t1: Fe = undefined;
    fe_sub(&t1, &q[1], &q[0]);
    fe_mul(&a, &a, &t1);

    fe_add(&b, &p[1], &p[0]);
    var t2: Fe = undefined;
    fe_add(&t2, &q[1], &q[0]);
    fe_mul(&b, &b, &t2);

    fe_mul(&c, &p[3], &q[3]);
    fe_mul(&c, &c, &ed25519_d2);

    fe_mul(&dd, &p[2], &q[2]);
    fe_add(&dd, &dd, &dd);

    fe_sub(&e, &b, &a);
    fe_sub(&f_fe, &dd, &c);
    fe_add(&g, &dd, &c);
    fe_add(&hh, &b, &a);

    fe_mul(&r[0], &e, &f_fe);
    fe_mul(&r[1], &hh, &g);
    fe_mul(&r[2], &g, &f_fe);
    fe_mul(&r[3], &e, &hh);
}

fn ge_scalarmult_base(r: *GePt, scalar: *const [32]u8) void {
    // Double-and-add using extended coordinates
    r[0] = fe_zero;
    r[1] = fe_one;
    r[2] = fe_one;
    r[3] = fe_zero;

    var base: GePt = .{ ed25519_bx, ed25519_by, fe_one, undefined };
    fe_mul(&base[3], &ed25519_bx, &ed25519_by); // T = X*Y

    var i: i32 = 255;
    while (i >= 0) : (i -= 1) {
        const bit = (scalar[@intCast(@as(u32, @intCast(i)) >> 3)] >> @intCast(@as(u3, @truncate(@as(u32, @intCast(i)))))) & 1;
        // Double
        var t: GePt = undefined;
        ge_dbl(&t, r);
        r.* = t;
        // Conditional add
        if (bit == 1) {
            var t2: GePt = undefined;
            ge_add(&t2, r, &base);
            r.* = t2;
        }
    }
}

fn ge_dbl(r: *GePt, p: *const GePt) void {
    var a: Fe = undefined;
    fe_sq(&a, &p[0]);
    var b: Fe = undefined;
    fe_sq(&b, &p[1]);
    var c: Fe = undefined;
    fe_sq(&c, &p[2]);
    fe_add(&c, &c, &c);
    var d: Fe = undefined;
    // d = -a (since curve is -x^2 + y^2)
    var neg_a: Fe = undefined;
    fe_sub(&neg_a, &fe_zero, &a);
    d = neg_a;
    var e: Fe = undefined;
    var t0: Fe = undefined;
    fe_add(&t0, &p[0], &p[1]);
    fe_sq(&e, &t0);
    fe_sub(&e, &e, &a);
    fe_sub(&e, &e, &b);
    var g: Fe = undefined;
    fe_add(&g, &d, &b);
    var f_fe: Fe = undefined;
    fe_sub(&f_fe, &g, &c);
    var hh: Fe = undefined;
    fe_sub(&hh, &d, &b);

    fe_mul(&r[0], &e, &f_fe);
    fe_mul(&r[1], &g, &hh);
    fe_mul(&r[2], &f_fe, &g);
    fe_mul(&r[3], &e, &hh);
}

fn ge_tobytes(s: *[32]u8, p: *const GePt) void {
    var recip: Fe = undefined;
    fe_inv(&recip, &p[2]);
    var x: Fe = undefined;
    fe_mul(&x, &p[0], &recip);
    var y: Fe = undefined;
    fe_mul(&y, &p[1], &recip);
    fe_pack(s, &y);
    // Set high bit of last byte if x is odd
    var x_bytes: [32]u8 = undefined;
    fe_pack(&x_bytes, &x);
    s[31] ^= (x_bytes[0] & 1) << 7;
}

fn sc_reduce(s: *[64]u8) void {
    // Barrett reduction mod L where L = 2^252 + 27742317777372353535851937790883648493
    // For simplicity, we use a basic reduction approach
    var x: [64]i64 = undefined;
    for (0..64) |i| x[i] = @as(i64, s[i]);

    // L in limbs
    const L: [32]i64 = .{
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
    };

    // Reduce from the top
    var i: usize = 63;
    while (i >= 32) : (i -= 1) {
        var carry: i64 = 0;
        var j: usize = i - 32;
        const k = i - 12;
        _ = k;
        while (j < i - 12) : (j += 1) {
            x[j] += carry - 16 * x[i] * L[j - (i - 32)];
            carry = (x[j] + 128) >> 8;
            x[j] -= carry * 256;
        }
        while (j <= i) : (j += 1) {
            x[j] += carry - 16 * x[i] * L[j - (i - 32)];
            if (j < 64) {
                carry = (x[j] + 128) >> 8;
                x[j] -= carry * 256;
            }
        }
        x[i] = 0;
    }
    var carry: i64 = 0;
    for (0..32) |j| {
        x[j] += carry - (x[31] >> 4) * L[j];
        carry = x[j] >> 8;
        x[j] &= 255;
    }
    for (0..32) |j| {
        x[j] -= carry * L[j];
    }
    for (0..32) |j| {
        x[j + 1] += x[j] >> 8;
        s[j] = @truncate(@as(u64, @bitCast(x[j] & 255)));
    }
}

/// Hardcoded Ed25519 host keypair for zsshd.
/// This is a fixed keypair — NOT cryptographically random. For a hobby OS this is fine.
/// Generated offline; the private key is the 64-byte expanded secret key (SHA-512 of seed).
pub const host_public_key: [32]u8 = .{
    0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7, 0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
    0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa3, 0x23, 0x91, 0x6a, 0x1a, 0x8c, 0x11, 0xe2, 0xdf, 0x4c, 0x5a,
};

/// Expanded secret key: first 32 bytes = clamped scalar, last 32 bytes = prefix for nonce derivation.
/// REMOVED — generate at runtime (e.g. from /dev/random or a persistent key file)
pub const host_secret_key: [64]u8 = .{
    // Clamped scalar (a)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // Prefix (for nonce generation)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

pub fn ed25519_sign(sig: *[64]u8, msg: []const u8, sk: *const [64]u8, pk: *const [32]u8) void {
    // 1. Compute nonce: r = SHA-512(sk[32..64] || msg) mod L
    var nonce_hash_state = Sha512.init_state();
    nonce_hash_state.update(sk[32..64]);
    nonce_hash_state.update(msg);
    var nonce_hash = nonce_hash_state.final512();
    sc_reduce(&nonce_hash);
    var nonce: [32]u8 = undefined;
    @memcpy(&nonce, nonce_hash[0..32]);

    // 2. Compute R = r * B
    var R: GePt = undefined;
    ge_scalarmult_base(&R, &nonce);
    var R_bytes: [32]u8 = undefined;
    ge_tobytes(&R_bytes, &R);

    // 3. Compute S = r + SHA-512(R || pk || msg) * a mod L
    var h_state = Sha512.init_state();
    h_state.update(&R_bytes);
    h_state.update(pk);
    h_state.update(msg);
    var h_hash = h_state.final512();
    sc_reduce(&h_hash);

    // Compute S = (r + h * a) mod L using i64 arithmetic
    var x: [64]i64 = .{0} ** 64;
    for (0..32) |i| x[i] = @as(i64, nonce_hash[i]);
    for (0..32) |i| {
        for (0..32) |j| {
            x[i + j] += @as(i64, h_hash[i]) * @as(i64, sk[j]);
        }
    }
    var s_bytes: [64]u8 = undefined;
    for (0..64) |i| s_bytes[i] = @truncate(@as(u64, @bitCast(x[i])));
    sc_reduce(&s_bytes);

    // 4. Output signature = R || S
    @memcpy(sig[0..32], &R_bytes);
    @memcpy(sig[32..64], s_bytes[0..32]);
}
