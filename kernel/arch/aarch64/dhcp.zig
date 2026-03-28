/// Minimal DHCP client — DISCOVER/OFFER only, for boot-time IP configuration.
/// Sends a single DHCP DISCOVER broadcast and parses the OFFER to get:
///   - Assigned IP (yiaddr)
///   - Subnet mask (option 1)
///   - Gateway/router (option 3)
///   - DNS server (option 6)

const uart = @import("uart.zig");
const nic = @import("nic.zig");
const ethernet = @import("ethernet.zig");
const checksum = @import("checksum.zig");
const timer = @import("timer.zig");

/// DHCP result
pub const DhcpResult = struct {
    our_ip: u32,
    gateway_ip: u32,
    subnet_mask: u32,
    dns_ip: u32,
};

// DHCP constants
const DHCP_SERVER_PORT: u16 = 67;
const DHCP_CLIENT_PORT: u16 = 68;
const DHCP_OP_REQUEST: u8 = 1;
const DHCP_OP_REPLY: u8 = 2;
const DHCP_HTYPE_ETHERNET: u8 = 1;
const DHCP_MAGIC: u32 = 0x63825363;

// DHCP option types
const OPT_SUBNET_MASK: u8 = 1;
const OPT_ROUTER: u8 = 3;
const OPT_DNS: u8 = 6;
const OPT_MSG_TYPE: u8 = 53;
const OPT_END: u8 = 255;

// DHCP message types
const DHCP_DISCOVER: u8 = 1;
const DHCP_OFFER: u8 = 2;

const XID: u32 = 0x5A494749; // "ZIGI" as transaction ID

/// Send DHCP DISCOVER and wait for OFFER. Returns IP config or null on timeout.
pub fn discover(timeout_ticks: u32) ?DhcpResult {
    // Build and send DHCP DISCOVER
    var pkt: [590]u8 = .{0} ** 590;
    const pkt_len = buildDiscover(&pkt);

    if (!nic.transmit(pkt[0..pkt_len])) {
        uart.writeString("[dhcp] TX failed\n");
        return null;
    }
    uart.writeString("[dhcp] DISCOVER sent\n");

    // Poll for DHCP OFFER
    const start = timer.getTicks();
    while (timer.getTicks() - start < timeout_ticks) {
        nic.handleIrq();

        while (nic.receive()) |rx_pkt| {
            if (parseOffer(rx_pkt.data)) |result| {
                nic.receiveConsume();
                return result;
            }
            nic.receiveConsume();
        }

        asm volatile ("wfi");
    }

    uart.writeString("[dhcp] timeout\n");
    return null;
}

fn buildDiscover(buf: *[590]u8) usize {
    const mac = nic.mac;
    const broadcast = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

    // DHCP payload (240 fixed + options)
    // Offset 0 in DHCP:
    const dhcp_start: usize = 14 + 20 + 8; // after Eth+IP+UDP headers
    buf[dhcp_start + 0] = DHCP_OP_REQUEST; // op
    buf[dhcp_start + 1] = DHCP_HTYPE_ETHERNET; // htype
    buf[dhcp_start + 2] = 6; // hlen (MAC length)
    buf[dhcp_start + 3] = 0; // hops
    // xid (bytes 4-7)
    buf[dhcp_start + 4] = @truncate(XID >> 24);
    buf[dhcp_start + 5] = @truncate(XID >> 16);
    buf[dhcp_start + 6] = @truncate(XID >> 8);
    buf[dhcp_start + 7] = @truncate(XID);
    // secs, flags = 0 (bytes 8-11)
    // ciaddr, yiaddr, siaddr, giaddr = 0 (bytes 12-27)
    // chaddr (bytes 28-43) — client MAC + padding
    for (0..6) |i| buf[dhcp_start + 28 + i] = mac[i];
    // sname (64 bytes), file (128 bytes) = 0 (bytes 44-235)
    // Magic cookie (bytes 236-239)
    buf[dhcp_start + 236] = 0x63;
    buf[dhcp_start + 237] = 0x82;
    buf[dhcp_start + 238] = 0x53;
    buf[dhcp_start + 239] = 0x63;
    // Options (start at byte 240)
    var opt: usize = dhcp_start + 240;
    // Option 53: DHCP Message Type = DISCOVER
    buf[opt] = OPT_MSG_TYPE;
    buf[opt + 1] = 1;
    buf[opt + 2] = DHCP_DISCOVER;
    opt += 3;
    // Option 255: End
    buf[opt] = OPT_END;
    opt += 1;

    const dhcp_len = opt - dhcp_start;
    const udp_len: u16 = @truncate(8 + dhcp_len);
    const ip_total: u16 = @truncate(20 + @as(usize, udp_len));

    // UDP header (offset 14+20=34)
    const udp_off: usize = 14 + 20;
    ethernet.putU16BE(buf[udp_off .. udp_off + 2], DHCP_CLIENT_PORT); // src port
    ethernet.putU16BE(buf[udp_off + 2 .. udp_off + 4], DHCP_SERVER_PORT); // dst port
    ethernet.putU16BE(buf[udp_off + 4 .. udp_off + 6], udp_len);
    ethernet.putU16BE(buf[udp_off + 6 .. udp_off + 8], 0); // checksum (0 = none)

    // IP header (offset 14)
    const ip_off: usize = 14;
    buf[ip_off + 0] = 0x45; // version=4, IHL=5
    buf[ip_off + 1] = 0; // DSCP/ECN
    ethernet.putU16BE(buf[ip_off + 2 .. ip_off + 4], ip_total);
    ethernet.putU16BE(buf[ip_off + 4 .. ip_off + 6], 0); // identification
    ethernet.putU16BE(buf[ip_off + 6 .. ip_off + 8], 0); // flags+fragment
    buf[ip_off + 8] = 64; // TTL
    buf[ip_off + 9] = 17; // protocol = UDP
    ethernet.putU16BE(buf[ip_off + 10 .. ip_off + 12], 0); // checksum (calc below)
    // src IP = 0.0.0.0
    ethernet.putU32BE(buf[ip_off + 12 .. ip_off + 16], 0x00000000);
    // dst IP = 255.255.255.255
    ethernet.putU32BE(buf[ip_off + 16 .. ip_off + 20], 0xFFFFFFFF);

    // IP checksum
    const ip_csum = checksum.internetChecksum(buf[ip_off .. ip_off + 20]);
    ethernet.putU16BE(buf[ip_off + 10 .. ip_off + 12], ip_csum);

    // Ethernet header
    for (0..6) |i| {
        buf[i] = broadcast[i];
        buf[6 + i] = mac[i];
    }
    buf[12] = 0x08;
    buf[13] = 0x00;

    return 14 + @as(usize, ip_total);
}

fn parseOffer(data: []const u8) ?DhcpResult {
    // Minimum: Eth(14) + IP(20) + UDP(8) + DHCP(240+4) = 286
    if (data.len < 286) return null;

    // Check Ethernet type = IP
    const ethertype = @as(u16, data[12]) << 8 | data[13];
    if (ethertype != 0x0800) return null;

    // Check IP protocol = UDP
    const ip_off: usize = 14;
    if (data[ip_off] & 0xF0 != 0x40) return null; // not IPv4
    const ihl = @as(usize, data[ip_off] & 0x0F) * 4;
    if (data[ip_off + 9] != 17) return null; // not UDP

    // Check UDP ports
    const udp_off = ip_off + ihl;
    if (udp_off + 8 > data.len) return null;
    const src_port = @as(u16, data[udp_off]) << 8 | data[udp_off + 1];
    const dst_port = @as(u16, data[udp_off + 2]) << 8 | data[udp_off + 3];
    if (src_port != DHCP_SERVER_PORT or dst_port != DHCP_CLIENT_PORT) return null;

    // DHCP payload
    const dhcp_off = udp_off + 8;
    if (dhcp_off + 240 > data.len) return null;

    // Check op = REPLY
    if (data[dhcp_off] != DHCP_OP_REPLY) return null;
    // Check xid matches
    const xid = @as(u32, data[dhcp_off + 4]) << 24 |
        @as(u32, data[dhcp_off + 5]) << 16 |
        @as(u32, data[dhcp_off + 6]) << 8 |
        @as(u32, data[dhcp_off + 7]);
    if (xid != XID) return null;

    // yiaddr (assigned IP) at dhcp+16
    const yiaddr = ethernet.getU32BE(data[dhcp_off + 16 .. dhcp_off + 20]);

    // Check magic cookie
    if (data[dhcp_off + 236] != 0x63 or data[dhcp_off + 237] != 0x82 or
        data[dhcp_off + 238] != 0x53 or data[dhcp_off + 239] != 0x63)
        return null;

    // Parse options
    var result = DhcpResult{
        .our_ip = yiaddr,
        .gateway_ip = 0,
        .subnet_mask = 0xFFFFFF00, // default /24
        .dns_ip = 0,
    };

    var is_offer = false;
    var i: usize = dhcp_off + 240;
    while (i < data.len) {
        const opt_type = data[i];
        if (opt_type == OPT_END) break;
        if (opt_type == 0) { // padding
            i += 1;
            continue;
        }
        if (i + 1 >= data.len) break;
        const opt_len = data[i + 1];
        if (i + 2 + opt_len > data.len) break;

        const opt_data = data[i + 2 .. i + 2 + opt_len];
        switch (opt_type) {
            OPT_MSG_TYPE => {
                if (opt_len >= 1 and opt_data[0] == DHCP_OFFER) is_offer = true;
            },
            OPT_SUBNET_MASK => {
                if (opt_len >= 4) result.subnet_mask = ethernet.getU32BE(opt_data[0..4]);
            },
            OPT_ROUTER => {
                if (opt_len >= 4) result.gateway_ip = ethernet.getU32BE(opt_data[0..4]);
            },
            OPT_DNS => {
                if (opt_len >= 4) result.dns_ip = ethernet.getU32BE(opt_data[0..4]);
            },
            else => {},
        }
        i += 2 + opt_len;
    }

    if (!is_offer) return null;

    uart.writeString("[dhcp] OFFER: ip=");
    ethernet.writeIpAddr(result.our_ip);
    uart.writeString(" gw=");
    ethernet.writeIpAddr(result.gateway_ip);
    uart.writeString(" mask=");
    ethernet.writeIpAddr(result.subnet_mask);
    uart.writeString(" dns=");
    ethernet.writeIpAddr(result.dns_ip);
    uart.writeString("\n");

    return result;
}
