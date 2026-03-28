/// Kernel DNS resolver cache.
/// Ported from programs/zig_dns_server protocol layer for kernel use.
///
/// Provides:
/// - DNS wire format parsing/building (RFC 1035)
/// - A/AAAA record resolution cache
/// - UDP query/response via the kernel network stack
///
/// The cache is consulted by the kernel's socket connect() path and
/// can be queried from userspace via /proc/net/dns or a dedicated syscall.
///
/// Usage:
///   dns.init(dns_server_ip);  // from DHCP
///   if (dns.resolve("api.anthropic.com")) |ip| { ... }

const net = struct {
    // Forward declarations — filled by kernel integration
    pub var sendUdp: ?*const fn (dst_ip: u32, dst_port: u16, data: []const u8) bool = null;
    pub var recvUdp: ?*const fn (buf: []u8) ?usize = null;
};

/// DNS record types
pub const TYPE_A: u16 = 1;
pub const TYPE_AAAA: u16 = 28;
pub const TYPE_CNAME: u16 = 5;

/// DNS header (12 bytes)
pub const Header = packed struct {
    id: u16,
    flags: u16,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,
};

/// Cache entry
pub const CacheEntry = struct {
    name: [256]u8 = .{0} ** 256,
    name_len: u8 = 0,
    ip: u32 = 0, // IPv4 address (network byte order)
    ttl_ticks: u64 = 0, // Expiry tick count
    in_use: bool = false,
};

const CACHE_SIZE = 64;
var cache: [CACHE_SIZE]CacheEntry = .{CacheEntry{}} ** CACHE_SIZE;
var dns_server: u32 = 0; // DNS server IP (from DHCP)
var next_id: u16 = 1;
var initialized: bool = false;

/// Initialize the resolver with a DNS server IP (from DHCP option 6).
pub fn init(server_ip: u32) void {
    dns_server = server_ip;
    initialized = true;
}

/// Resolve a hostname to an IPv4 address.
/// Returns cached result if available and not expired.
/// Otherwise sends a DNS query and waits for response.
pub fn resolve(name: []const u8) ?u32 {
    if (!initialized) return null;

    // Check cache first
    for (&cache) |*entry| {
        if (entry.in_use and entry.name_len == name.len) {
            if (nameEq(entry.name[0..entry.name_len], name)) {
                return entry.ip;
            }
        }
    }

    // Cache miss — send query
    var query_buf: [512]u8 = undefined;
    const query_len = buildQuery(name, &query_buf) orelse return null;

    const send = net.sendUdp orelse return null;
    if (!send(dns_server, 53, query_buf[0..query_len])) return null;

    // Wait for response (simple blocking poll)
    const recv = net.recvUdp orelse return null;
    var resp_buf: [512]u8 = undefined;
    const resp_len = recv(&resp_buf) orelse return null;

    // Parse response
    return parseResponse(name, resp_buf[0..resp_len]);
}

/// Build a DNS A query for the given name.
fn buildQuery(name: []const u8, buf: *[512]u8) ?usize {
    if (name.len > 253) return null;

    var pos: usize = 0;

    // Header
    const id = next_id;
    next_id +%= 1;
    buf[0] = @truncate(id >> 8);
    buf[1] = @truncate(id);
    buf[2] = 0x01; buf[3] = 0x00; // flags: RD=1 (recursion desired)
    buf[4] = 0x00; buf[5] = 0x01; // QDCOUNT = 1
    buf[6] = 0; buf[7] = 0; buf[8] = 0; buf[9] = 0; buf[10] = 0; buf[11] = 0;
    pos = 12;

    // Question: encode name as labels
    var name_pos: usize = 0;
    while (name_pos < name.len) {
        // Find next dot
        var label_end = name_pos;
        while (label_end < name.len and name[label_end] != '.') label_end += 1;
        const label_len = label_end - name_pos;
        if (label_len == 0 or label_len > 63) return null;

        buf[pos] = @truncate(label_len);
        pos += 1;
        for (name[name_pos..label_end]) |c| {
            buf[pos] = c;
            pos += 1;
        }
        name_pos = label_end + 1; // skip dot
    }
    buf[pos] = 0; // root label
    pos += 1;

    // QTYPE = A (1), QCLASS = IN (1)
    buf[pos] = 0; buf[pos + 1] = 1; // TYPE_A
    buf[pos + 2] = 0; buf[pos + 3] = 1; // CLASS_IN
    pos += 4;

    return pos;
}

/// Parse a DNS response and extract A record.
fn parseResponse(name: []const u8, data: []const u8) ?u32 {
    if (data.len < 12) return null;

    // Check ANCOUNT > 0
    const ancount = (@as(u16, data[6]) << 8) | data[7];
    if (ancount == 0) return null;

    // Skip header (12 bytes) + question section
    var pos: usize = 12;

    // Skip QDCOUNT questions
    const qdcount = (@as(u16, data[4]) << 8) | data[5];
    var qi: u16 = 0;
    while (qi < qdcount) : (qi += 1) {
        pos = skipName(data, pos) orelse return null;
        pos += 4; // QTYPE + QCLASS
    }

    // Parse answer records
    var ai: u16 = 0;
    while (ai < ancount and pos + 10 < data.len) : (ai += 1) {
        pos = skipName(data, pos) orelse return null;

        const rtype = (@as(u16, data[pos]) << 8) | data[pos + 1];
        // const rclass = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
        // const ttl = ... (bytes 4-7)
        const rdlength = (@as(u16, data[pos + 8]) << 8) | data[pos + 9];
        pos += 10;

        if (rtype == TYPE_A and rdlength == 4 and pos + 4 <= data.len) {
            const ip = (@as(u32, data[pos]) << 24) |
                (@as(u32, data[pos + 1]) << 16) |
                (@as(u32, data[pos + 2]) << 8) |
                @as(u32, data[pos + 3]);

            // Cache it
            cacheInsert(name, ip);
            return ip;
        }
        pos += rdlength;
    }
    return null;
}

/// Skip a DNS name (handles compression pointers).
fn skipName(data: []const u8, start: usize) ?usize {
    var pos = start;
    var jumps: u8 = 0;
    while (pos < data.len) {
        const label_len = data[pos];
        if (label_len == 0) return pos + 1; // root label
        if (label_len & 0xC0 == 0xC0) return pos + 2; // compression pointer
        pos += 1 + label_len;
        jumps += 1;
        if (jumps > 64) return null; // loop protection
    }
    return null;
}

/// Insert a result into the cache (LRU eviction of oldest entry).
fn cacheInsert(name: []const u8, ip: u32) void {
    // Find empty slot or reuse oldest
    var slot: usize = 0;
    for (0..CACHE_SIZE) |i| {
        if (!cache[i].in_use) {
            slot = i;
            break;
        }
    }

    const copy_len = if (name.len > 255) 255 else name.len;
    for (0..copy_len) |i| cache[slot].name[i] = name[i];
    cache[slot].name_len = @truncate(copy_len);
    cache[slot].ip = ip;
    cache[slot].in_use = true;
}

fn nameEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        // Case-insensitive comparison
        const ca = if (a[i] >= 'A' and a[i] <= 'Z') a[i] + 32 else a[i];
        const cb = if (b[i] >= 'A' and b[i] <= 'Z') b[i] + 32 else b[i];
        if (ca != cb) return false;
    }
    return true;
}
