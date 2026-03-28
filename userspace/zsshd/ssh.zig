/// ssh.zig — SSH-2 protocol state machine for zsshd.
/// Handles version exchange, key exchange (curve25519-sha256),
/// encryption (chacha20-poly1305@openssh.com), auth, and channels.

const crypto = @import("crypto.zig");
const sys = @import("sys");

// ============================================================================
// SSH message types
// ============================================================================

pub const SSH_MSG_DISCONNECT: u8 = 1;
pub const SSH_MSG_SERVICE_REQUEST: u8 = 5;
pub const SSH_MSG_SERVICE_ACCEPT: u8 = 6;
pub const SSH_MSG_KEXINIT: u8 = 20;
pub const SSH_MSG_NEWKEYS: u8 = 21;
pub const SSH_MSG_KEX_ECDH_INIT: u8 = 30;
pub const SSH_MSG_KEX_ECDH_REPLY: u8 = 31;
pub const SSH_MSG_USERAUTH_REQUEST: u8 = 50;
pub const SSH_MSG_USERAUTH_FAILURE: u8 = 51;
pub const SSH_MSG_USERAUTH_SUCCESS: u8 = 52;
pub const SSH_MSG_CHANNEL_OPEN: u8 = 90;
pub const SSH_MSG_CHANNEL_OPEN_CONFIRMATION: u8 = 91;
pub const SSH_MSG_CHANNEL_DATA: u8 = 94;
pub const SSH_MSG_CHANNEL_EOF: u8 = 96;
pub const SSH_MSG_CHANNEL_CLOSE: u8 = 97;
pub const SSH_MSG_CHANNEL_REQUEST: u8 = 98;
pub const SSH_MSG_CHANNEL_SUCCESS: u8 = 99;

pub const SSH_DISCONNECT_BY_APPLICATION: u32 = 11;

// ============================================================================
// SSH Session state
// ============================================================================

pub const SshSession = struct {
    socket_fd: u64,
    session_id: [32]u8,
    send_seq: u32,
    recv_seq: u32,
    // ChaCha20-Poly1305 uses 64-byte keys: main(32) + header(32)
    send_key_main: [32]u8,
    send_key_header: [32]u8,
    recv_key_main: [32]u8,
    recv_key_header: [32]u8,
    encrypted: bool,
    channel_id: u32,
    remote_channel: u32,
    remote_window: u32,
    username: [64]u8,
    username_len: u8,
    auth_uid: u32,
    auth_gid: u32,
    // Saved for exchange hash
    client_version: [256]u8,
    client_version_len: u16,
    server_version: [256]u8,
    server_version_len: u16,
    client_kexinit: [1024]u8,
    client_kexinit_len: u16,
    server_kexinit: [1024]u8,
    server_kexinit_len: u16,
};

pub fn initSession(fd: u64) SshSession {
    var sess: SshSession = undefined;
    sess.socket_fd = fd;
    sess.send_seq = 0;
    sess.recv_seq = 0;
    sess.encrypted = false;
    sess.channel_id = 0;
    sess.remote_channel = 0;
    sess.remote_window = 0;
    sess.username_len = 0;
    sess.auth_uid = 0;
    sess.auth_gid = 0;
    sess.client_version_len = 0;
    sess.server_version_len = 0;
    sess.client_kexinit_len = 0;
    sess.server_kexinit_len = 0;
    @memset(&sess.session_id, 0);
    @memset(&sess.username, 0);
    return sess;
}

// ============================================================================
// Low-level I/O
// ============================================================================

fn readFull(fd: u64, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = sys.read(fd, buf[off..].ptr, buf.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn writeAll(fd: u64, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = sys.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

// ============================================================================
// SSH Binary Packet I/O
// ============================================================================

/// Read one SSH binary packet. Returns payload length, or 0 on error.
/// Payload is written starting at buf[0].
pub fn readPacket(sess: *SshSession, buf: []u8) u32 {
    if (!sess.encrypted) {
        // Unencrypted: 4-byte length + 1-byte padding_length + payload + padding
        var hdr: [4]u8 = undefined;
        if (!readFull(sess.socket_fd, &hdr)) return 0;
        const pkt_len = crypto.Sha256.init().state[0]; // dummy — use load32be
        _ = pkt_len;
        const total_len = (@as(u32, hdr[0]) << 24) | (@as(u32, hdr[1]) << 16) | (@as(u32, hdr[2]) << 8) | @as(u32, hdr[3]);
        if (total_len < 2 or total_len > 4096) return 0;
        // Read entire packet body
        var body: [4096]u8 = undefined;
        if (!readFull(sess.socket_fd, body[0..total_len])) return 0;
        const pad_len = body[0];
        const payload_len = total_len - 1 - @as(u32, pad_len);
        if (payload_len > buf.len) return 0;
        @memcpy(buf[0..payload_len], body[1..][0..payload_len]);
        sess.recv_seq +%= 1;
        return payload_len;
    } else {
        // Encrypted (chacha20-poly1305@openssh.com):
        // Read 4-byte encrypted length
        var enc_len: [4]u8 = undefined;
        if (!readFull(sess.socket_fd, &enc_len)) return 0;
        const pkt_len = crypto.decrypt_length(&enc_len, &sess.recv_key_header, sess.recv_seq);
        if (pkt_len < 2 or pkt_len > 4096) return 0;
        // Read encrypted body + 16-byte tag
        var body: [4096 + 16]u8 = undefined;
        if (!readFull(sess.socket_fd, body[0 .. pkt_len + 16])) return 0;
        // Verify and decrypt
        var plaintext: [4096]u8 = undefined;
        const tag = body[pkt_len..][0..16];
        if (!crypto.aead_decrypt(plaintext[0..pkt_len], body[0..pkt_len], tag, &enc_len, &sess.recv_key_main, sess.recv_seq)) {
            return 0; // MAC failure
        }
        const pad_len = plaintext[0];
        const payload_len = pkt_len - 1 - @as(u32, pad_len);
        if (payload_len > buf.len) return 0;
        @memcpy(buf[0..payload_len], plaintext[1..][0..payload_len]);
        sess.recv_seq +%= 1;
        return payload_len;
    }
}

/// Write one SSH binary packet.
pub fn writePacket(sess: *SshSession, payload: []const u8) bool {
    if (!sess.encrypted) {
        // Build: [4-byte length][1-byte pad_len][payload][padding]
        const block_size: u32 = 8;
        const min_pad: u32 = 4;
        var pad_len: u32 = block_size - @as(u32, @truncate((5 + payload.len) % block_size));
        if (pad_len < min_pad) pad_len += block_size;
        const total_len: u32 = @truncate(1 + payload.len + pad_len);

        var pkt: [4096 + 32]u8 = undefined;
        // Length
        pkt[0] = @truncate(total_len >> 24);
        pkt[1] = @truncate(total_len >> 16);
        pkt[2] = @truncate(total_len >> 8);
        pkt[3] = @truncate(total_len);
        // Padding length
        pkt[4] = @truncate(pad_len);
        // Payload
        @memcpy(pkt[5..][0..payload.len], payload);
        // Padding (zeros is fine for unencrypted)
        @memset(pkt[5 + payload.len ..][0..pad_len], 0);

        const pkt_size = 4 + total_len;
        if (!writeAll(sess.socket_fd, pkt[0..pkt_size])) return false;
        sess.send_seq +%= 1;
        return true;
    } else {
        // Encrypted (chacha20-poly1305@openssh.com)
        const block_size: u32 = 8;
        const min_pad: u32 = 4;
        var pad_len: u32 = block_size - @as(u32, @truncate((1 + payload.len) % block_size));
        if (pad_len < min_pad) pad_len += block_size;
        const total_len: u32 = @truncate(1 + payload.len + pad_len);

        // Build plaintext body: [pad_len][payload][padding]
        var body: [4096]u8 = undefined;
        body[0] = @truncate(pad_len);
        @memcpy(body[1..][0..payload.len], payload);
        @memset(body[1 + payload.len ..][0..pad_len], 0);

        // Encrypt length
        var enc_len: [4]u8 = undefined;
        crypto.encrypt_length(&enc_len, total_len, &sess.send_key_header, sess.send_seq);

        // Encrypt body and get tag
        var ciphertext: [4096]u8 = undefined;
        var tag: [16]u8 = undefined;
        crypto.aead_encrypt(ciphertext[0..total_len], &tag, body[0..total_len], &enc_len, &sess.send_key_main, sess.send_seq);

        // Send: enc_len || ciphertext || tag
        if (!writeAll(sess.socket_fd, &enc_len)) return false;
        if (!writeAll(sess.socket_fd, ciphertext[0..total_len])) return false;
        if (!writeAll(sess.socket_fd, &tag)) return false;
        sess.send_seq +%= 1;
        return true;
    }
}

// ============================================================================
// Version exchange
// ============================================================================

const SERVER_VERSION = "SSH-2.0-zsshd_1.0";

pub fn versionExchange(sess: *SshSession) bool {
    // Send our version
    const ver_line = SERVER_VERSION ++ "\r\n";
    if (!writeAll(sess.socket_fd, ver_line)) return false;
    @memcpy(sess.server_version[0..SERVER_VERSION.len], SERVER_VERSION);
    sess.server_version_len = SERVER_VERSION.len;

    // Read client version (up to CR LF)
    var buf: [256]u8 = undefined;
    var len: u16 = 0;
    while (len < 255) {
        var ch: [1]u8 = undefined;
        if (!readFull(sess.socket_fd, &ch)) return false;
        buf[len] = ch[0];
        len += 1;
        if (len >= 2 and buf[len - 2] == '\r' and buf[len - 1] == '\n') {
            // Strip CR LF for storage
            const vlen = len - 2;
            @memcpy(sess.client_version[0..vlen], buf[0..vlen]);
            sess.client_version_len = vlen;
            return true;
        }
    }
    return false;
}

// ============================================================================
// KEXINIT
// ============================================================================

// SSH name-lists for our single cipher suite
const KEX_ALGORITHMS = "curve25519-sha256";
const HOST_KEY_ALGORITHMS = "ssh-ed25519";
const ENCRYPTION = "chacha20-poly1305@openssh.com";
const MAC = ""; // implicit in AEAD
const COMPRESSION = "none";

fn putU32(buf: []u8, v: u32) void {
    buf[0] = @truncate(v >> 24);
    buf[1] = @truncate(v >> 16);
    buf[2] = @truncate(v >> 8);
    buf[3] = @truncate(v);
}

fn getU32(buf: []const u8) u32 {
    return (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) | (@as(u32, buf[2]) << 8) | @as(u32, buf[3]);
}

fn appendNameList(buf: []u8, pos: *usize, name: []const u8) void {
    putU32(buf[pos.*..], @truncate(name.len));
    pos.* += 4;
    @memcpy(buf[pos.*..][0..name.len], name);
    pos.* += name.len;
}

pub fn sendKexInit(sess: *SshSession) bool {
    var payload: [512]u8 = undefined;
    var pos: usize = 0;

    // Message type
    payload[pos] = SSH_MSG_KEXINIT;
    pos += 1;

    // 16-byte cookie (use zeros — no security needed for cookie in kex)
    @memset(payload[pos..][0..16], 0);
    // Try to read random bytes for cookie
    readRandom(payload[pos..][0..16]);
    pos += 16;

    // 10 name-lists
    appendNameList(&payload, &pos, KEX_ALGORITHMS);
    appendNameList(&payload, &pos, HOST_KEY_ALGORITHMS);
    appendNameList(&payload, &pos, ENCRYPTION); // encryption_c2s
    appendNameList(&payload, &pos, ENCRYPTION); // encryption_s2c
    appendNameList(&payload, &pos, MAC); // mac_c2s
    appendNameList(&payload, &pos, MAC); // mac_s2c
    appendNameList(&payload, &pos, COMPRESSION); // compression_c2s
    appendNameList(&payload, &pos, COMPRESSION); // compression_s2c
    appendNameList(&payload, &pos, ""); // languages_c2s
    appendNameList(&payload, &pos, ""); // languages_s2c

    // first_kex_packet_follows = false
    payload[pos] = 0;
    pos += 1;
    // reserved uint32
    putU32(payload[pos..], 0);
    pos += 4;

    // Save for exchange hash
    @memcpy(sess.server_kexinit[0..pos], payload[0..pos]);
    sess.server_kexinit_len = @truncate(pos);

    return writePacket(sess, payload[0..pos]);
}

pub fn recvKexInit(sess: *SshSession, buf: []u8) u32 {
    const plen = readPacket(sess, buf);
    if (plen == 0) return 0;
    if (buf[0] != SSH_MSG_KEXINIT) return 0;
    // Save raw payload for exchange hash
    @memcpy(sess.client_kexinit[0..plen], buf[0..plen]);
    sess.client_kexinit_len = @truncate(plen);
    return plen;
}

// ============================================================================
// Key Exchange — curve25519-sha256
// ============================================================================

fn readRandom(buf: []u8) void {
    // Read from /dev/urandom
    const fd = sys.open("/dev/urandom", 0, 0);
    if (fd >= 0) {
        _ = sys.read(@intCast(fd), buf.ptr, buf.len);
        _ = sys.close(@intCast(fd));
    } else {
        // Fallback: use a simple PRNG seeded from the PID
        var state: u64 = sys.getpid() *% 6364136223846793005 +% 1442695040888963407;
        for (buf) |*b| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            b.* = @truncate(state >> 33);
        }
    }
}

/// Build the SSH host key blob for ssh-ed25519
fn buildHostKeyBlob(blob: []u8) usize {
    var pos: usize = 0;
    // string "ssh-ed25519"
    putU32(blob[pos..], 11);
    pos += 4;
    @memcpy(blob[pos..][0..11], "ssh-ed25519");
    pos += 11;
    // string public_key (32 bytes)
    putU32(blob[pos..], 32);
    pos += 4;
    @memcpy(blob[pos..][0..32], &crypto.host_public_key);
    pos += 32;
    return pos; // 51 bytes total
}

/// Build SSH signature blob for Ed25519
fn buildSignatureBlob(blob: []u8, sig: *const [64]u8) usize {
    var pos: usize = 0;
    // string "ssh-ed25519"
    putU32(blob[pos..], 11);
    pos += 4;
    @memcpy(blob[pos..][0..11], "ssh-ed25519");
    pos += 11;
    // string signature (64 bytes)
    putU32(blob[pos..], 64);
    pos += 4;
    @memcpy(blob[pos..][0..64], sig);
    pos += 64;
    return pos; // 83 bytes total
}

/// Append an SSH string (length-prefixed) to the hash state
fn hashString(h: *crypto.Sha256, data: []const u8) void {
    var len_buf: [4]u8 = undefined;
    putU32(&len_buf, @truncate(data.len));
    h.update(&len_buf);
    h.update(data);
}

/// Append an SSH mpint to the hash state (for shared secret K)
fn hashMpint(h: *crypto.Sha256, data: *const [32]u8) void {
    // mpint: if high bit set, prepend 0x00
    var len_buf: [4]u8 = undefined;
    if (data[0] & 0x80 != 0) {
        putU32(&len_buf, 33);
        h.update(&len_buf);
        var zero: [1]u8 = .{0};
        h.update(&zero);
        h.update(data);
    } else {
        // Skip leading zeros (but keep at least 1 byte)
        var start: usize = 0;
        while (start < 31 and data[start] == 0) start += 1;
        const mlen: u32 = @truncate(32 - start);
        putU32(&len_buf, mlen);
        h.update(&len_buf);
        h.update(data[start..32]);
    }
}

pub fn doKeyExchange(sess: *SshSession) bool {
    // 1. Read SSH_MSG_KEX_ECDH_INIT from client
    var buf: [4096]u8 = undefined;
    const plen = readPacket(sess, &buf);
    if (plen == 0 or buf[0] != SSH_MSG_KEX_ECDH_INIT) return false;

    // Parse client's ephemeral public key Q_C (string)
    if (plen < 37) return false; // 1 + 4 + 32
    const qc_len = getU32(buf[1..]);
    if (qc_len != 32) return false;
    var Q_C: [32]u8 = undefined;
    @memcpy(&Q_C, buf[5..][0..32]);

    // 2. Generate server ephemeral keypair
    var server_secret: [32]u8 = undefined;
    readRandom(&server_secret);
    // Clamp
    server_secret[0] &= 248;
    server_secret[31] &= 127;
    server_secret[31] |= 64;
    var Q_S: [32]u8 = undefined;
    crypto.scalarmult_base(&Q_S, &server_secret);

    // 3. Compute shared secret K = curve25519(server_secret, Q_C)
    var K: [32]u8 = undefined;
    crypto.scalarmult(&K, &server_secret, &Q_C);

    // 4. Compute exchange hash H
    var h = crypto.Sha256.init();
    // V_C (client version string)
    hashString(&h, sess.client_version[0..sess.client_version_len]);
    // V_S (server version string)
    hashString(&h, sess.server_version[0..sess.server_version_len]);
    // I_C (client KEXINIT payload)
    hashString(&h, sess.client_kexinit[0..sess.client_kexinit_len]);
    // I_S (server KEXINIT payload)
    hashString(&h, sess.server_kexinit[0..sess.server_kexinit_len]);
    // K_S (host key blob)
    var host_key_blob: [64]u8 = undefined;
    const hk_len = buildHostKeyBlob(&host_key_blob);
    hashString(&h, host_key_blob[0..hk_len]);
    // Q_C (client ephemeral)
    hashString(&h, &Q_C);
    // Q_S (server ephemeral)
    hashString(&h, &Q_S);
    // K (shared secret as mpint)
    hashMpint(&h, &K);

    const H = h.final();

    // First exchange hash becomes session_id
    @memcpy(&sess.session_id, &H);

    // 5. Sign H with host key
    var signature: [64]u8 = undefined;
    crypto.ed25519_sign(&signature, &H, &crypto.host_secret_key, &crypto.host_public_key);

    // 6. Send SSH_MSG_KEX_ECDH_REPLY
    var reply: [512]u8 = undefined;
    var rpos: usize = 0;
    reply[rpos] = SSH_MSG_KEX_ECDH_REPLY;
    rpos += 1;
    // K_S (host key blob as string)
    putU32(reply[rpos..], @truncate(hk_len));
    rpos += 4;
    @memcpy(reply[rpos..][0..hk_len], host_key_blob[0..hk_len]);
    rpos += hk_len;
    // Q_S (server ephemeral as string)
    putU32(reply[rpos..], 32);
    rpos += 4;
    @memcpy(reply[rpos..][0..32], &Q_S);
    rpos += 32;
    // Signature blob as string
    var sig_blob: [96]u8 = undefined;
    const sig_len = buildSignatureBlob(&sig_blob, &signature);
    putU32(reply[rpos..], @truncate(sig_len));
    rpos += 4;
    @memcpy(reply[rpos..][0..sig_len], sig_blob[0..sig_len]);
    rpos += sig_len;

    if (!writePacket(sess, reply[0..rpos])) return false;

    // 7. Derive keys
    deriveKeys(sess, &K, &H);

    // 8. Send NEWKEYS
    var newkeys: [1]u8 = .{SSH_MSG_NEWKEYS};
    if (!writePacket(sess, &newkeys)) return false;

    // 9. Receive client's NEWKEYS
    const nk_len = readPacket(sess, &buf);
    if (nk_len == 0 or buf[0] != SSH_MSG_NEWKEYS) return false;

    // 10. Activate encryption
    sess.encrypted = true;
    return true;
}

fn deriveKey(K: *const [32]u8, H: *const [32]u8, letter: u8, session_id: *const [32]u8) [32]u8 {
    var h = crypto.Sha256.init();
    hashMpint(&h, K);
    h.update(H);
    var l: [1]u8 = .{letter};
    h.update(&l);
    h.update(session_id);
    return h.final();
}

fn deriveKeys(sess: *SshSession, K: *const [32]u8, H: *const [32]u8) void {
    // ChaCha20-Poly1305 uses 64-byte keys per direction:
    //   K_main = derive('C'/'D' for c2s/s2c) — first 32 bytes
    //   K_header = derive('C'/'D') with extra hash round — but actually
    //   OpenSSH derives the full 64-byte key by extending with additional hash rounds.
    //
    // For simplicity (and matching OpenSSH behavior):
    //   key_c2s = SHA-256(K || H || 'C' || session_id) => 32 bytes (main)
    //   key_c2s_header uses letter 'A' (IV, repurposed as header key)
    //   key_s2c = SHA-256(K || H || 'D' || session_id) => 32 bytes (main)
    //   key_s2c_header uses letter 'B'
    //
    // Actually, OpenSSH chacha20-poly1305 derives a single 64-byte key by:
    //   K1 = HASH(K || H || letter || session_id) — first 32 bytes
    //   K2 = HASH(K || H || K1) — next 32 bytes
    // The first 32 bytes = K_main, next 32 bytes = K_header.

    // c2s encryption key (recv for server)
    const k1_c2s = deriveKey(K, H, 'C', &sess.session_id);
    // Extend to 64 bytes
    var h1 = crypto.Sha256.init();
    hashMpint(&h1, K);
    h1.update(H);
    h1.update(&k1_c2s);
    const k2_c2s = h1.final();

    sess.recv_key_main = k1_c2s;
    sess.recv_key_header = k2_c2s;

    // s2c encryption key (send for server)
    const k1_s2c = deriveKey(K, H, 'D', &sess.session_id);
    var h2 = crypto.Sha256.init();
    hashMpint(&h2, K);
    h2.update(H);
    h2.update(&k1_s2c);
    const k2_s2c = h2.final();

    sess.send_key_main = k1_s2c;
    sess.send_key_header = k2_s2c;
}

// ============================================================================
// Service Request + Authentication
// ============================================================================

pub fn handleServiceRequest(sess: *SshSession) bool {
    var buf: [4096]u8 = undefined;
    const plen = readPacket(sess, &buf);
    if (plen == 0 or buf[0] != SSH_MSG_SERVICE_REQUEST) return false;

    // Parse service name
    if (plen < 5) return false;
    const svc_len = getU32(buf[1..]);
    if (1 + 4 + svc_len > plen) return false;

    // Check for "ssh-userauth"
    if (svc_len == 12 and eql(buf[5..][0..12], "ssh-userauth")) {
        // Send SERVICE_ACCEPT
        var resp: [32]u8 = undefined;
        resp[0] = SSH_MSG_SERVICE_ACCEPT;
        putU32(resp[1..], 12);
        @memcpy(resp[5..][0..12], "ssh-userauth");
        return writePacket(sess, resp[0..17]);
    }
    return false;
}

pub fn handleAuth(sess: *SshSession) bool {
    while (true) {
        var buf: [4096]u8 = undefined;
        const plen = readPacket(sess, &buf);
        if (plen == 0) return false;
        if (buf[0] != SSH_MSG_USERAUTH_REQUEST) return false;

        var pos: u32 = 1;
        // username (string)
        if (pos + 4 > plen) return false;
        const uname_len = getU32(buf[pos..]);
        pos += 4;
        if (pos + uname_len > plen) return false;
        const uname = buf[pos..][0..uname_len];
        pos += uname_len;

        // service name (string) — skip
        if (pos + 4 > plen) return false;
        const svc_len = getU32(buf[pos..]);
        pos += 4;
        pos += svc_len;

        // method name (string)
        if (pos + 4 > plen) return false;
        const method_len = getU32(buf[pos..]);
        pos += 4;
        if (pos + method_len > plen) return false;
        const method = buf[pos..][0..method_len];
        pos += method_len;

        if (method_len == 4 and eql(method, "none")) {
            // Send failure with password method
            sendAuthFailure(sess);
            continue;
        }

        if (method_len == 8 and eql(method, "password")) {
            // boolean: FALSE (not changing password)
            if (pos >= plen) return false;
            pos += 1;
            // password (string)
            if (pos + 4 > plen) return false;
            const pass_len = getU32(buf[pos..]);
            pos += 4;
            if (pos + pass_len > plen) return false;
            const password = buf[pos..][0..pass_len];
            _ = password;

            // Validate against /etc/passwd
            // For Zigix, we accept any password for valid users (simple auth)
            if (validateUser(uname, &sess.auth_uid, &sess.auth_gid)) {
                // Save username
                const copy_len = if (uname_len > 63) 63 else uname_len;
                @memcpy(sess.username[0..copy_len], uname[0..copy_len]);
                sess.username_len = @truncate(copy_len);

                // Send USERAUTH_SUCCESS
                var resp: [1]u8 = .{SSH_MSG_USERAUTH_SUCCESS};
                return writePacket(sess, &resp);
            }
            sendAuthFailure(sess);
            continue;
        }

        // Unknown method
        sendAuthFailure(sess);
    }
}

fn sendAuthFailure(sess: *SshSession) void {
    var resp: [32]u8 = undefined;
    resp[0] = SSH_MSG_USERAUTH_FAILURE;
    // name-list of methods
    putU32(resp[1..], 8); // "password"
    @memcpy(resp[5..][0..8], "password");
    resp[13] = 0; // partial success = false
    _ = writePacket(sess, resp[0..14]);
}

fn validateUser(username: []const u8, uid: *u32, gid: *u32) bool {
    // Read /etc/passwd
    const fd = sys.open("/etc/passwd", 0, 0);
    if (fd < 0) {
        // No passwd file — accept root
        if (username.len == 4 and eql(username, "root")) {
            uid.* = 0;
            gid.* = 0;
            return true;
        }
        return false;
    }
    defer _ = sys.close(@intCast(fd));

    var file_buf: [1024]u8 = undefined;
    const n = sys.read(@intCast(fd), &file_buf, file_buf.len);
    if (n <= 0) return false;
    const content = file_buf[0..@intCast(n)];

    // Parse lines: username:x:uid:gid:...
    var line_start: usize = 0;
    for (content, 0..) |ch, i| {
        if (ch == '\n' or i == content.len - 1) {
            const line_end = if (ch == '\n') i else i + 1;
            const line = content[line_start..line_end];
            if (matchPasswdLine(line, username, uid, gid)) return true;
            line_start = i + 1;
        }
    }
    return false;
}

fn matchPasswdLine(line: []const u8, username: []const u8, uid: *u32, gid: *u32) bool {
    // Format: username:x:uid:gid:gecos:home:shell
    var field_start: usize = 0;
    var field_num: u8 = 0;
    var parsed_uid: u32 = 0;
    var parsed_gid: u32 = 0;
    var name_match = false;

    for (line, 0..) |ch, i| {
        if (ch == ':' or i == line.len - 1) {
            const field_end = if (ch == ':') i else i + 1;
            const field = line[field_start..field_end];
            switch (field_num) {
                0 => {
                    // username
                    if (field.len == username.len and eql(field, username)) {
                        name_match = true;
                    }
                },
                2 => {
                    // uid
                    parsed_uid = parseU32(field);
                },
                3 => {
                    // gid
                    parsed_gid = parseU32(field);
                },
                else => {},
            }
            field_start = i + 1;
            field_num += 1;
        }
    }
    if (name_match and field_num >= 4) {
        uid.* = parsed_uid;
        gid.* = parsed_gid;
        return true;
    }
    return false;
}

fn parseU32(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            v = v * 10 + (ch - '0');
        }
    }
    return v;
}

// ============================================================================
// Channel management
// ============================================================================

pub fn handleChannelOpen(sess: *SshSession) bool {
    var buf: [4096]u8 = undefined;
    const plen = readPacket(sess, &buf);
    if (plen == 0 or buf[0] != SSH_MSG_CHANNEL_OPEN) return false;

    var pos: u32 = 1;
    // Channel type (string)
    if (pos + 4 > plen) return false;
    const type_len = getU32(buf[pos..]);
    pos += 4;
    if (pos + type_len > plen) return false;
    // We accept "session"
    pos += type_len;

    // sender channel
    if (pos + 4 > plen) return false;
    sess.remote_channel = getU32(buf[pos..]);
    pos += 4;

    // initial window size
    if (pos + 4 > plen) return false;
    sess.remote_window = getU32(buf[pos..]);
    pos += 4;

    // max packet size — skip
    // pos += 4;

    // Assign local channel
    sess.channel_id = 0;

    // Send CHANNEL_OPEN_CONFIRMATION
    var resp: [32]u8 = undefined;
    var rpos: usize = 0;
    resp[rpos] = SSH_MSG_CHANNEL_OPEN_CONFIRMATION;
    rpos += 1;
    putU32(resp[rpos..], sess.remote_channel);
    rpos += 4;
    putU32(resp[rpos..], sess.channel_id);
    rpos += 4;
    putU32(resp[rpos..], 0x200000); // window size (2MB)
    rpos += 4;
    putU32(resp[rpos..], 0x8000); // max packet size (32KB)
    rpos += 4;
    return writePacket(sess, resp[0..rpos]);
}

pub fn handleChannelRequest(sess: *SshSession) bool {
    var buf: [4096]u8 = undefined;
    const plen = readPacket(sess, &buf);
    if (plen == 0 or buf[0] != SSH_MSG_CHANNEL_REQUEST) return false;

    var pos: u32 = 1;
    // recipient channel
    pos += 4;
    // request type (string)
    if (pos + 4 > plen) return false;
    const req_len = getU32(buf[pos..]);
    pos += 4;
    if (pos + req_len > plen) return false;
    const req_type = buf[pos..][0..req_len];
    pos += req_len;

    // want_reply
    if (pos >= plen) return false;
    const want_reply = buf[pos] != 0;
    pos += 1;

    // Handle pty-req by just acknowledging (we don't implement PTY)
    if (eql_len(req_type, "pty-req")) {
        if (want_reply) {
            var resp: [8]u8 = undefined;
            resp[0] = SSH_MSG_CHANNEL_SUCCESS;
            putU32(resp[1..], sess.remote_channel);
            _ = writePacket(sess, resp[0..5]);
        }
        // Read the actual shell request that follows
        return handleChannelRequest(sess);
    }

    if (eql_len(req_type, "shell") or eql_len(req_type, "exec")) {
        if (want_reply) {
            var resp: [8]u8 = undefined;
            resp[0] = SSH_MSG_CHANNEL_SUCCESS;
            putU32(resp[1..], sess.remote_channel);
            return writePacket(sess, resp[0..5]);
        }
        return true;
    }

    // Unknown request — fail silently
    if (want_reply) {
        // Send channel failure (100)
        var resp: [8]u8 = undefined;
        resp[0] = 100; // SSH_MSG_CHANNEL_FAILURE
        putU32(resp[1..], sess.remote_channel);
        _ = writePacket(sess, resp[0..5]);
    }
    // Try next request
    return handleChannelRequest(sess);
}

pub fn sendChannelData(sess: *SshSession, data: []const u8) bool {
    var payload: [4096]u8 = undefined;
    // Limit to reasonable chunk size
    const max_chunk = 4000;
    var off: usize = 0;
    while (off < data.len) {
        const chunk = if (data.len - off > max_chunk) max_chunk else data.len - off;
        payload[0] = SSH_MSG_CHANNEL_DATA;
        putU32(payload[1..], sess.remote_channel);
        putU32(payload[5..], @truncate(chunk));
        @memcpy(payload[9..][0..chunk], data[off..][0..chunk]);
        if (!writePacket(sess, payload[0 .. 9 + chunk])) return false;
        off += chunk;
    }
    return true;
}

pub fn sendChannelEof(sess: *SshSession) bool {
    var payload: [8]u8 = undefined;
    payload[0] = SSH_MSG_CHANNEL_EOF;
    putU32(payload[1..], sess.remote_channel);
    return writePacket(sess, payload[0..5]);
}

pub fn sendChannelClose(sess: *SshSession) bool {
    var payload: [8]u8 = undefined;
    payload[0] = SSH_MSG_CHANNEL_CLOSE;
    putU32(payload[1..], sess.remote_channel);
    return writePacket(sess, payload[0..5]);
}

pub fn sendDisconnect(sess: *SshSession) bool {
    var payload: [64]u8 = undefined;
    payload[0] = SSH_MSG_DISCONNECT;
    putU32(payload[1..], SSH_DISCONNECT_BY_APPLICATION);
    putU32(payload[5..], 7); // "closing"
    @memcpy(payload[9..][0..7], "closing");
    putU32(payload[16..], 0); // language tag
    return writePacket(sess, payload[0..20]);
}

/// Read one packet and extract channel data. Returns data length, or 0 on EOF/close.
/// If the packet is a window adjust message, handles it and reads next packet.
pub fn recvChannelData(sess: *SshSession, out: []u8) u32 {
    while (true) {
        var buf: [4096]u8 = undefined;
        const plen = readPacket(sess, &buf);
        if (plen == 0) return 0;

        switch (buf[0]) {
            SSH_MSG_CHANNEL_DATA => {
                if (plen < 9) return 0;
                // recipient channel (skip)
                const data_len = getU32(buf[5..]);
                if (9 + data_len > plen) return 0;
                if (data_len > out.len) return 0;
                @memcpy(out[0..data_len], buf[9..][0..data_len]);
                return data_len;
            },
            SSH_MSG_CHANNEL_EOF, SSH_MSG_CHANNEL_CLOSE => {
                return 0; // Signal end of stream
            },
            SSH_MSG_CHANNEL_REQUEST => {
                // Ignore keepalive and other channel requests during data transfer
                // Check if want_reply is set
                if (plen > 5) {
                    var pos: u32 = 5;
                    const req_len = getU32(buf[pos..]);
                    pos += 4 + req_len;
                    if (pos < plen and buf[pos] != 0) {
                        // want_reply=true, send failure
                        var resp: [8]u8 = undefined;
                        resp[0] = 100; // CHANNEL_FAILURE
                        putU32(resp[1..], sess.remote_channel);
                        _ = writePacket(sess, resp[0..5]);
                    }
                }
                continue; // Read next packet
            },
            93 => { // SSH_MSG_CHANNEL_WINDOW_ADJUST
                if (plen >= 9) {
                    sess.remote_window += getU32(buf[5..]);
                }
                continue; // Read next packet
            },
            else => {
                continue; // Ignore unknown messages
            },
        }
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn eql_len(a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (0..b.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}
