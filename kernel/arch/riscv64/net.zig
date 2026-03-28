/// Network stack entry point — init and polling dispatcher.

const uart = @import("uart.zig");
const ethernet = @import("ethernet.zig");
const arp = @import("arp.zig");
const ipv4 = @import("ipv4.zig");
const icmp = @import("icmp.zig");
const tcp = @import("tcp.zig");
const nic = @import("nic.zig");
const net_ring = @import("net_ring.zig");

/// Network boot phase state machine (Chaos Rocket safety).
/// Replaces the boolean dhcp_complete flag with typed states.
/// Each state owns the rx_ring exclusively — no consumer races.
///
/// Transitions:
///   .uninitialized → .dhcp     (NIC probe complete, DHCP starts)
///   .dhcp          → .running  (DHCP complete, hand off to net.poll)
///
/// Atomic: CPU 0 advances state during boot, CPU 1 reads from timer tick.
pub const NetPhase = enum(u32) {
    /// NIC not yet probed. net.poll is a no-op.
    uninitialized = 0,
    /// DHCP owns the rx_ring. net.poll must not touch it.
    dhcp = 1,
    /// Normal operation. net.poll owns the rx_ring.
    running = 2,
};

var net_phase: u32 = @intFromEnum(NetPhase.uninitialized);

/// Transition to a new network phase. Caller must be on boot CPU.
pub fn setPhase(phase: NetPhase) void {
    @atomicStore(u32, &net_phase, @intFromEnum(phase), .release);
}

/// Read current phase (safe from any CPU).
pub fn getPhase() NetPhase {
    return @enumFromInt(@atomicLoad(u32, &net_phase, .acquire));
}

/// Legacy compatibility — returns true when phase is .running.
/// Used by code that previously checked dhcp_complete.
pub fn isRunning() bool {
    return getPhase() == .running;
}

pub fn init() void {
    ipv4.init();

    uart.writeString("[net]  Network ready (");
    ethernet.writeIpAddr(ipv4.our_ip);
    uart.writeString(")\n");
}

/// Called from timer tick — drains virtio-net rx_ring and dispatches by ethertype.
/// When a shared ring is active, raw frames are also delivered there for zero-copy access.
pub fn poll() void {
    if (!nic.isInitialized()) return;
    if (getPhase() != .running) return;

    // TCP retransmission timer check
    tcp.tcpTimerPoll();

    // Poll gVNIC/virtio completion ring for new packets
    nic.handleIrq();

    // Process up to 8 packets per poll
    var count: u32 = 0;
    while (count < 8) : (count += 1) {
        const pkt = nic.receive() orelse break;

        // Deliver raw frame to shared ring if active (zero-copy path)
        if (net_ring.isActive()) {
            _ = net_ring.deliverRx(pkt.data);
        }

        // Also process through kernel stack (ARP, ICMP, TCP, etc.)
        if (ethernet.parse(pkt.data)) |parsed| {
            switch (parsed.hdr.ethertype) {
                ethernet.ETH_P_ARP => arp.handleArp(parsed.payload),
                ethernet.ETH_P_IP => ipv4.handleIpv4(parsed.payload),
                else => {},
            }
        }

        nic.receiveConsume();
    }

    // Poll shared ring: reclaim consumed RX buffers, process TX submissions
    net_ring.poll();
}
