/// UDP — User Datagram Protocol.
/// Stateless, connectionless datagram send/receive.

const serial = @import("../arch/x86_64/serial.zig");
const ethernet = @import("ethernet.zig");
const checksum = @import("checksum.zig");
const ipv4 = @import("ipv4.zig");
const scheduler = @import("../proc/scheduler.zig");

const UDP_HEADER_SIZE: usize = 8;

// Socket rx buffer callback — set by socket layer
pub var socket_deliver: ?*const fn (dst_port: u16, src_ip: u32, src_port: u16, data: []const u8) void = null;

/// Handle an incoming UDP packet (payload after IPv4 header).
pub fn handleUdp(src_ip: u32, data: []const u8) void {
    if (data.len < UDP_HEADER_SIZE) return;

    const src_port = ethernet.getU16BE(data[0..2]);
    const dst_port = ethernet.getU16BE(data[2..4]);
    const udp_len = ethernet.getU16BE(data[4..6]);
    // checksum at data[6..8] — skip verification for MVP

    if (udp_len < UDP_HEADER_SIZE) return;
    const payload_len: usize = udp_len - UDP_HEADER_SIZE;
    if (data.len < UDP_HEADER_SIZE + payload_len) return;

    const payload = data[UDP_HEADER_SIZE .. UDP_HEADER_SIZE + payload_len];

    // Deliver to socket layer
    if (socket_deliver) |deliver| {
        deliver(dst_port, src_ip, src_port, payload);
    }
}

/// Send a UDP datagram. Returns true on success.
pub fn send(src_port: u16, dst_ip: u32, dst_port: u16, payload: []const u8) bool {
    if (payload.len > 1472) return false; // 1500 - 20 (IP) - 8 (UDP)

    var udp_pkt: [1480]u8 = undefined;
    const udp_len: u16 = @truncate(UDP_HEADER_SIZE + payload.len);

    ethernet.putU16BE(udp_pkt[0..2], src_port);
    ethernet.putU16BE(udp_pkt[2..4], dst_port);
    ethernet.putU16BE(udp_pkt[4..6], udp_len);
    udp_pkt[6] = 0; // checksum placeholder
    udp_pkt[7] = 0;

    // Copy payload
    for (0..payload.len) |i| {
        udp_pkt[UDP_HEADER_SIZE + i] = payload[i];
    }

    // Compute UDP checksum with pseudo-header
    const pseudo_sum = checksum.pseudoHeaderSum(ipv4.our_ip, dst_ip, ipv4.PROTO_UDP, udp_len);
    const cksum = checksum.checksumWithSeed(pseudo_sum, udp_pkt[0..udp_len]);
    // UDP checksum of 0 means "no checksum" per RFC — use 0xFFFF instead
    const final_cksum: u16 = if (cksum == 0) 0xFFFF else cksum;
    ethernet.putU16BE(udp_pkt[6..8], final_cksum);

    return ipv4.send(ipv4.PROTO_UDP, dst_ip, udp_pkt[0..udp_len]);
}
