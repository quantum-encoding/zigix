/// ICMP — Internet Control Message Protocol.
/// Echo request/reply for ping functionality.

const uart = @import("uart.zig");
const ethernet = @import("ethernet.zig");
const checksum = @import("checksum.zig");
const ipv4 = @import("ipv4.zig");
const scheduler = @import("scheduler.zig");
const sock = @import("socket.zig");

const ICMP_ECHO_REPLY: u8 = 0;
const ICMP_ECHO_REQUEST: u8 = 8;
const ICMP_HEADER_SIZE: usize = 8;

// Pending reply tracking for blocking ping
pub var pending_reply: bool = false;
pub var reply_ttl: u8 = 0;
pub var reply_seq: u16 = 0;
pub var reply_src_ip: u32 = 0;
pub var waiting_pid: u64 = 0;

/// Handle an incoming ICMP packet.
pub fn handleIcmp(src_ip: u32, data: []const u8, ttl: u8) void {
    if (data.len < ICMP_HEADER_SIZE) return;

    const icmp_type = data[0];
    const icmp_code = data[1];
    _ = icmp_code;

    if (icmp_type == ICMP_ECHO_REQUEST) {
        // Reply to ping
        sendEchoReply(src_ip, data);
    } else if (icmp_type == ICMP_ECHO_REPLY) {
        // Store reply info
        const seq = ethernet.getU16BE(data[6..8]);

        reply_ttl = ttl;
        reply_seq = seq;
        reply_src_ip = src_ip;
        pending_reply = true;

        // Deliver to raw ICMP sockets
        sock.deliverIcmpReply(src_ip, data);

        // Wake any blocked process (kernel ping)
        if (waiting_pid != 0) {
            scheduler.wakeProcess(waiting_pid);
            waiting_pid = 0;
        }
    }
}

/// Send an ICMP echo request. Returns true on success.
pub fn sendEchoRequest(dst_ip: u32, id: u16, seq: u16, payload: []const u8) bool {
    var icmp_pkt: [128]u8 = undefined;
    const pkt_len = ICMP_HEADER_SIZE + payload.len;
    if (pkt_len > icmp_pkt.len) return false;

    icmp_pkt[0] = ICMP_ECHO_REQUEST;
    icmp_pkt[1] = 0; // code
    icmp_pkt[2] = 0; // checksum placeholder
    icmp_pkt[3] = 0;
    ethernet.putU16BE(icmp_pkt[4..6], id);
    ethernet.putU16BE(icmp_pkt[6..8], seq);

    // Copy payload
    for (0..payload.len) |i| {
        icmp_pkt[ICMP_HEADER_SIZE + i] = payload[i];
    }

    // Compute checksum
    const cksum = checksum.internetChecksum(icmp_pkt[0..pkt_len]);
    icmp_pkt[2] = @truncate(cksum >> 8);
    icmp_pkt[3] = @truncate(cksum);

    return ipv4.send(ipv4.PROTO_ICMP, dst_ip, icmp_pkt[0..pkt_len]);
}

/// Send a boot-time ping and check for reply.
pub fn bootPing(dst_ip: u32) void {
    const timer = @import("timer.zig");
    const nic_mod = @import("nic.zig");
    const arp = @import("arp.zig");
    const payload = "zigix";
    pending_reply = false;

    if (!sendEchoRequest(dst_ip, 0x5A49, 1, payload)) {
        uart.writeString("[net]  ICMP: failed to send ping\n");
        return;
    }

    // Poll for reply using tick-based timeout (~2 seconds)
    const start = timer.getTicks();
    while (timer.getTicks() - start < 200 and !pending_reply) {
        // Check for incoming packets
        nic_mod.handleIrq();

        while (nic_mod.receive()) |pkt| {
            if (ethernet.parse(pkt.data)) |parsed| {
                switch (parsed.hdr.ethertype) {
                    ethernet.ETH_P_ARP => arp.handleArp(parsed.payload),
                    ethernet.ETH_P_IP => ipv4.handleIpv4(parsed.payload),
                    else => {},
                }
            }
            nic_mod.receiveConsume();
        }

        if (pending_reply) break;

        // Halt until next interrupt — yields to QEMU event loop
        asm volatile ("wfi");
    }

    if (pending_reply) {
        uart.writeString("[net]  ICMP: ping ");
        ethernet.writeIpAddr(dst_ip);
        uart.writeString(" seq=1 -> reply TTL=");
        uart.writeDec(reply_ttl);
        uart.writeString("\n");
    } else {
        uart.writeString("[net]  ICMP: ping ");
        ethernet.writeIpAddr(dst_ip);
        uart.writeString(" -> timeout\n");
    }
}

fn sendEchoReply(dst_ip: u32, request: []const u8) void {
    // Build reply with same ID/seq/payload but type=0
    var reply: [128]u8 = undefined;
    const len = if (request.len > reply.len) reply.len else request.len;

    for (0..len) |i| {
        reply[i] = request[i];
    }

    reply[0] = ICMP_ECHO_REPLY;
    reply[2] = 0; // checksum placeholder
    reply[3] = 0;

    const cksum = checksum.internetChecksum(reply[0..len]);
    reply[2] = @truncate(cksum >> 8);
    reply[3] = @truncate(cksum);

    _ = ipv4.send(ipv4.PROTO_ICMP, dst_ip, reply[0..len]);
}
