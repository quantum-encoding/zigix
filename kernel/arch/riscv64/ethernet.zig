/// Ethernet frame parsing and building, plus byte-swap helpers.

const uart = @import("uart.zig");

pub const ETH_HEADER_SIZE: usize = 14;
pub const ETH_P_ARP: u16 = 0x0806;
pub const ETH_P_IP: u16 = 0x0800;

pub const EthHeader = struct {
    dst: [6]u8,
    src: [6]u8,
    ethertype: u16, // big-endian
};

/// Parse an Ethernet frame, returning header and payload slice.
pub fn parse(data: []const u8) ?struct { hdr: EthHeader, payload: []const u8 } {
    if (data.len < ETH_HEADER_SIZE) return null;

    var hdr: EthHeader = undefined;
    for (0..6) |i| {
        hdr.dst[i] = data[i];
        hdr.src[i] = data[6 + i];
    }
    hdr.ethertype = @as(u16, data[12]) << 8 | data[13];

    return .{ .hdr = hdr, .payload = data[ETH_HEADER_SIZE..] };
}

/// Build an Ethernet frame into buf. Returns total length.
pub fn build(buf: []u8, dst: [6]u8, src: [6]u8, ethertype: u16, payload: []const u8) usize {
    if (buf.len < ETH_HEADER_SIZE + payload.len) return 0;

    for (0..6) |i| {
        buf[i] = dst[i];
        buf[6 + i] = src[i];
    }
    buf[12] = @truncate(ethertype >> 8);
    buf[13] = @truncate(ethertype);

    for (0..payload.len) |i| {
        buf[ETH_HEADER_SIZE + i] = payload[i];
    }

    return ETH_HEADER_SIZE + payload.len;
}

// --- Byte-swap helpers (network byte order) ---

pub inline fn htons(val: u16) u16 {
    return @as(u16, @truncate(val >> 8)) | (@as(u16, @truncate(val)) << 8);
}

pub inline fn ntohs(val: u16) u16 {
    return htons(val);
}

pub inline fn htonl(val: u32) u32 {
    return (@as(u32, @truncate(val >> 24))) |
        (@as(u32, @truncate(val >> 16)) << 8) |
        (@as(u32, @truncate(val >> 8)) << 16) |
        (@as(u32, @truncate(val)) << 24);
}

pub inline fn ntohl(val: u32) u32 {
    return htonl(val);
}

/// Write a big-endian u16 into a byte slice.
pub fn putU16BE(buf: []u8, val: u16) void {
    buf[0] = @truncate(val >> 8);
    buf[1] = @truncate(val);
}

/// Read a big-endian u16 from a byte slice.
pub fn getU16BE(buf: []const u8) u16 {
    return @as(u16, buf[0]) << 8 | buf[1];
}

/// Write a big-endian u32 into a byte slice.
pub fn putU32BE(buf: []u8, val: u32) void {
    buf[0] = @truncate(val >> 24);
    buf[1] = @truncate(val >> 16);
    buf[2] = @truncate(val >> 8);
    buf[3] = @truncate(val);
}

/// Read a big-endian u32 from a byte slice.
pub fn getU32BE(buf: []const u8) u32 {
    return @as(u32, buf[0]) << 24 | @as(u32, buf[1]) << 16 | @as(u32, buf[2]) << 8 | buf[3];
}

/// Format an IPv4 address (u32 host byte order) as a.b.c.d to uart.
pub fn writeIpAddr(ip: u32) void {
    writeDecimal((ip >> 24) & 0xFF);
    uart.writeByte('.');
    writeDecimal((ip >> 16) & 0xFF);
    uart.writeByte('.');
    writeDecimal((ip >> 8) & 0xFF);
    uart.writeByte('.');
    writeDecimal(ip & 0xFF);
}

/// Format an IPv4 address (u32 host byte order) into a buffer. Returns length.
pub fn formatIpAddr(buf: []u8, ip: u32) usize {
    var pos: usize = 0;
    inline for ([_]u5{ 24, 16, 8, 0 }) |shift| {
        if (shift != 24) {
            buf[pos] = '.';
            pos += 1;
        }
        const octet: u8 = @truncate((ip >> shift) & 0xFF);
        if (octet >= 100) {
            buf[pos] = '0' + octet / 100;
            pos += 1;
        }
        if (octet >= 10) {
            buf[pos] = '0' + (octet / 10) % 10;
            pos += 1;
        }
        buf[pos] = '0' + octet % 10;
        pos += 1;
    }
    return pos;
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        uart.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    uart.writeString(buf[i..]);
}
