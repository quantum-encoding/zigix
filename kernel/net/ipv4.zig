/// IPv4 — parsing, sending, and protocol dispatch.

const serial = @import("../arch/x86_64/serial.zig");
const ethernet = @import("ethernet.zig");
const checksum = @import("checksum.zig");
const arp = @import("arp.zig");
const icmp = @import("icmp.zig");
const udp = @import("udp.zig");
const tcp = @import("tcp.zig");
const virtio_net = @import("../drivers/nic.zig");

const IP_HEADER_SIZE: usize = 20;

pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

// Static network config (QEMU SLIRP defaults)
pub var our_ip: u32 = 0x0A00020F; // 10.0.2.15
pub var gateway_ip: u32 = 0x0A000202; // 10.0.2.2
pub var subnet_mask: u32 = 0xFFFFFF00; // 255.255.255.0
pub var dns_ip: u32 = 0x0A000203; // 10.0.2.3

var ip_id_counter: u16 = 1;

pub fn init() void {
    arp.setOurIp(our_ip);
}

/// Parse an IPv4 packet. Returns header info and payload.
pub fn parse(data: []const u8) ?struct { src_ip: u32, dst_ip: u32, proto: u8, ttl: u8, payload: []const u8 } {
    if (data.len < IP_HEADER_SIZE) return null;

    // Version + IHL
    const version = data[0] >> 4;
    const ihl = data[0] & 0x0F;
    if (version != 4 or ihl < 5) return null;

    const header_len: usize = @as(usize, ihl) * 4;
    const total_len = ethernet.getU16BE(data[2..4]);
    if (data.len < total_len) return null;

    // Verify header checksum
    const hdr_cksum = checksum.internetChecksum(data[0..header_len]);
    if (hdr_cksum != 0) return null;

    const proto = data[9];
    const ttl = data[8];
    const src_ip = ethernet.getU32BE(data[12..16]);
    const dst_ip = ethernet.getU32BE(data[16..20]);

    const payload_start = header_len;
    const payload_end: usize = total_len;

    return .{
        .src_ip = src_ip,
        .dst_ip = dst_ip,
        .proto = proto,
        .ttl = ttl,
        .payload = data[payload_start..payload_end],
    };
}

/// Handle an incoming IPv4 packet (dispatches to ICMP/UDP/TCP).
pub fn handleIpv4(data: []const u8) void {
    const parsed = parse(data) orelse return;

    // Only accept packets addressed to us (or broadcast)
    if (parsed.dst_ip != our_ip and parsed.dst_ip != 0xFFFFFFFF) return;

    switch (parsed.proto) {
        PROTO_ICMP => icmp.handleIcmp(parsed.src_ip, parsed.payload, parsed.ttl),
        PROTO_UDP => udp.handleUdp(parsed.src_ip, parsed.payload),
        PROTO_TCP => tcp.handleTcp(parsed.src_ip, parsed.payload),
        else => {},
    }
}

/// Send an IPv4 packet. Returns true on success.
pub fn send(proto: u8, dst_ip: u32, payload: []const u8) bool {
    if (payload.len > 1480) return false; // MTU 1500 - 20 byte IP header

    // Build IPv4 header
    var ip_pkt: [1500]u8 = undefined;
    const total_len: u16 = @truncate(IP_HEADER_SIZE + payload.len);

    ip_pkt[0] = 0x45; // version=4, IHL=5
    ip_pkt[1] = 0; // DSCP/ECN
    ethernet.putU16BE(ip_pkt[2..4], total_len);
    ethernet.putU16BE(ip_pkt[4..6], ip_id_counter);
    ip_id_counter +%= 1;
    ip_pkt[6] = 0x40; // Don't Fragment
    ip_pkt[7] = 0;
    ip_pkt[8] = 64; // TTL
    ip_pkt[9] = proto;
    ip_pkt[10] = 0; // checksum (placeholder)
    ip_pkt[11] = 0;
    ethernet.putU32BE(ip_pkt[12..16], our_ip);
    ethernet.putU32BE(ip_pkt[16..20], dst_ip);

    // Compute header checksum
    const cksum = checksum.internetChecksum(ip_pkt[0..IP_HEADER_SIZE]);
    ip_pkt[10] = @truncate(cksum >> 8);
    ip_pkt[11] = @truncate(cksum);

    // Copy payload
    for (0..payload.len) |i| {
        ip_pkt[IP_HEADER_SIZE + i] = payload[i];
    }

    // Resolve next-hop MAC via ARP
    const next_hop = if ((dst_ip & subnet_mask) == (our_ip & subnet_mask))
        dst_ip // Same subnet — send directly
    else
        gateway_ip; // Different subnet — send to gateway

    const dst_mac = arp.resolve(next_hop) orelse {
        // Try a quick ARP resolve
        const mac_result = arp.resolveBlocking(next_hop, 500);
        if (mac_result) |m| {
            return sendFrame(m, ip_pkt[0..total_len]);
        }
        return false;
    };

    return sendFrame(dst_mac, ip_pkt[0..total_len]);
}

fn sendFrame(dst_mac: [6]u8, ip_pkt: []const u8) bool {
    var frame: [1514]u8 = undefined;
    const len = ethernet.build(&frame, dst_mac, virtio_net.mac, ethernet.ETH_P_IP, ip_pkt);
    if (len == 0) return false;
    return virtio_net.transmit(frame[0..len]);
}
