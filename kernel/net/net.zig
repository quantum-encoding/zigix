/// Network stack entry point — init and polling dispatcher.

const serial = @import("../arch/x86_64/serial.zig");
const ethernet = @import("ethernet.zig");
const klog = @import("../klog/klog.zig");
const arp = @import("arp.zig");
const ipv4 = @import("ipv4.zig");
const icmp = @import("icmp.zig");
const tcp = @import("tcp.zig");
const virtio_net = @import("../drivers/nic.zig");
const zcnet = @import("zcnet.zig");

pub fn init() void {
    ipv4.init();

    const log = klog.scoped(.net);
    log.info("ready", .{ .ip = @as(u64, ipv4.our_ip) });
}

/// Called from timer tick — drains virtio-net rx_ring and dispatches by ethertype.
/// Also polls zero-copy ring for TX drain and RX buffer repost.
pub fn poll() void {
    if (!virtio_net.isInitialized()) return;

    // TCP retransmission timer check
    tcp.tcpTimerPoll();

    // Zero-copy ring maintenance (TX drain + RX repost)
    zcnet.poll();

    // Poll NIC for received packets (gVNIC needs explicit poll since
    // MSI-X interrupts may not be routed to the x86_64 PIC/LAPIC yet)
    virtio_net.handleIrq();

    // Process up to 8 packets per poll to avoid spending too long in timer context
    var count: u32 = 0;
    while (count < 8) : (count += 1) {
        const pkt = virtio_net.receive() orelse break;

        if (ethernet.parse(pkt.data)) |parsed| {
            switch (parsed.hdr.ethertype) {
                ethernet.ETH_P_ARP => arp.handleArp(parsed.payload),
                ethernet.ETH_P_IP => ipv4.handleIpv4(parsed.payload),
                else => {},
            }
        }

        virtio_net.receiveConsume();
    }
}
