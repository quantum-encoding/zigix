/// ARP — Address Resolution Protocol.
/// Static ARP table with request/reply handling.

const serial = @import("../arch/x86_64/serial.zig");
const ethernet = @import("ethernet.zig");
const virtio_net = @import("../drivers/nic.zig");

const ARP_HTYPE_ETHER: u16 = 1;
const ARP_PTYPE_IPV4: u16 = 0x0800;
const ARP_OP_REQUEST: u16 = 1;
const ARP_OP_REPLY: u16 = 2;

// ARP packet: 28 bytes for Ethernet+IPv4
const ARP_PKT_SIZE: usize = 28;

const ArpEntry = struct {
    ip: u32,
    mac_addr: [6]u8,
    valid: bool,
};

const ARP_TABLE_SIZE: usize = 16;
var arp_table: [ARP_TABLE_SIZE]ArpEntry = [_]ArpEntry{.{
    .ip = 0,
    .mac_addr = .{ 0, 0, 0, 0, 0, 0 },
    .valid = false,
}} ** ARP_TABLE_SIZE;

/// Our IP address (host byte order)
var our_ip: u32 = 0;

pub fn setOurIp(ip: u32) void {
    our_ip = ip;
}

/// Handle an incoming ARP packet (payload after Ethernet header).
pub fn handleArp(data: []const u8) void {
    if (data.len < ARP_PKT_SIZE) return;

    const htype = ethernet.getU16BE(data[0..2]);
    const ptype = ethernet.getU16BE(data[2..4]);
    const hlen = data[4];
    const plen = data[5];
    const oper = ethernet.getU16BE(data[6..8]);

    if (htype != ARP_HTYPE_ETHER or ptype != ARP_PTYPE_IPV4 or hlen != 6 or plen != 4) return;

    // Extract sender/target
    var sha: [6]u8 = undefined;
    for (0..6) |i| sha[i] = data[8 + i];
    const spa = ethernet.getU32BE(data[14..18]);
    // tha at data[18..24] (not needed for processing)
    const tpa = ethernet.getU32BE(data[24..28]);

    // Update ARP table with sender's info
    updateTable(spa, sha);

    if (oper == ARP_OP_REQUEST and tpa == our_ip) {
        // Reply: swap sender/target, set our MAC
        sendReply(sha, spa);
    }
}

/// Resolve an IP to a MAC address. Returns null if not in table.
pub fn resolve(ip: u32) ?[6]u8 {
    for (0..ARP_TABLE_SIZE) |i| {
        if (arp_table[i].valid and arp_table[i].ip == ip) {
            return arp_table[i].mac_addr;
        }
    }
    return null;
}

/// Send an ARP request for target_ip.
pub fn sendRequest(target_ip: u32) void {
    var arp_pkt: [ARP_PKT_SIZE]u8 = undefined;

    // Build ARP request
    ethernet.putU16BE(arp_pkt[0..2], ARP_HTYPE_ETHER);
    ethernet.putU16BE(arp_pkt[2..4], ARP_PTYPE_IPV4);
    arp_pkt[4] = 6; // hlen
    arp_pkt[5] = 4; // plen
    ethernet.putU16BE(arp_pkt[6..8], ARP_OP_REQUEST);

    // Sender: our MAC + IP
    for (0..6) |i| arp_pkt[8 + i] = virtio_net.mac[i];
    ethernet.putU32BE(arp_pkt[14..18], our_ip);

    // Target: zero MAC + target IP
    for (0..6) |i| arp_pkt[18 + i] = 0;
    ethernet.putU32BE(arp_pkt[24..28], target_ip);

    // Wrap in Ethernet frame (broadcast)
    var frame: [ethernet.ETH_HEADER_SIZE + ARP_PKT_SIZE]u8 = undefined;
    const broadcast = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    _ = ethernet.build(&frame, broadcast, virtio_net.mac, ethernet.ETH_P_ARP, &arp_pkt);

    _ = virtio_net.transmit(&frame);
}

/// Blocking ARP resolve — send request, poll for reply.
/// timeout_ticks: number of PIT ticks to wait (~10ms each at 100Hz).
/// NOTE: This function may be called from timer IRQ context (IF=0).
/// Uses spin-polling with pause, not hlt, to avoid hanging when
/// interrupts are disabled.
pub fn resolveBlocking(ip: u32, timeout_ticks: u32) ?[6]u8 {
    _ = timeout_ticks;

    // Check table first
    if (resolve(ip)) |m| return m;

    // Send request
    sendRequest(ip);

    // Spin-poll for reply. We use pause + processRxPackets to poll the
    // virtio used ring directly (works even with IF=0 since the device
    // updates the ring via DMA). Spin count ~50M ≈ ~500ms on modern CPUs.
    var spins: u32 = 0;
    while (spins < 50_000_000) : (spins += 1) {
        if (spins % 10_000 == 0) {
            // Poll virtio RX ring for the ARP reply
            processRxPackets();
            if (resolve(ip)) |m| return m;
        }
        asm volatile ("pause");
    }

    return null;
}

fn processRxPackets() void {
    // Check virtio-net for received packets and process them
    virtio_net.handleIrq();

    while (virtio_net.receive()) |pkt| {
        if (ethernet.parse(pkt.data)) |parsed| {
            if (parsed.hdr.ethertype == ethernet.ETH_P_ARP) {
                handleArp(parsed.payload);
            }
        }
        virtio_net.receiveConsume();
    }
}

fn sendReply(dst_mac: [6]u8, dst_ip: u32) void {
    var arp_pkt: [ARP_PKT_SIZE]u8 = undefined;

    ethernet.putU16BE(arp_pkt[0..2], ARP_HTYPE_ETHER);
    ethernet.putU16BE(arp_pkt[2..4], ARP_PTYPE_IPV4);
    arp_pkt[4] = 6;
    arp_pkt[5] = 4;
    ethernet.putU16BE(arp_pkt[6..8], ARP_OP_REPLY);

    // Sender: us
    for (0..6) |i| arp_pkt[8 + i] = virtio_net.mac[i];
    ethernet.putU32BE(arp_pkt[14..18], our_ip);

    // Target: requester
    for (0..6) |i| arp_pkt[18 + i] = dst_mac[i];
    ethernet.putU32BE(arp_pkt[24..28], dst_ip);

    var frame: [ethernet.ETH_HEADER_SIZE + ARP_PKT_SIZE]u8 = undefined;
    _ = ethernet.build(&frame, dst_mac, virtio_net.mac, ethernet.ETH_P_ARP, &arp_pkt);
    _ = virtio_net.transmit(&frame);
}

fn updateTable(ip: u32, mac_addr: [6]u8) void {
    // Update existing entry
    for (0..ARP_TABLE_SIZE) |i| {
        if (arp_table[i].valid and arp_table[i].ip == ip) {
            arp_table[i].mac_addr = mac_addr;
            return;
        }
    }
    // Add new entry
    for (0..ARP_TABLE_SIZE) |i| {
        if (!arp_table[i].valid) {
            arp_table[i].ip = ip;
            arp_table[i].mac_addr = mac_addr;
            arp_table[i].valid = true;

            serial.writeString("[net]  ARP: ");
            ethernet.writeIpAddr(ip);
            serial.writeString(" -> ");
            for (0..6) |j| {
                if (j > 0) serial.writeByte(':');
                writeHex8(mac_addr[j]);
            }
            serial.writeString("\n");
            return;
        }
    }
}

fn writeHex8(val: u8) void {
    const hex = "0123456789abcdef";
    serial.writeByte(hex[@as(usize, val >> 4)]);
    serial.writeByte(hex[@as(usize, val & 0xf)]);
}
