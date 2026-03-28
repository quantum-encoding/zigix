/// NIC abstraction layer — runtime dispatch between network backends.
///
/// Same pattern as block_io.zig for block devices. Boot code calls
/// registerVirtio(), registerRtl8126(), or registerGvnic() after the
/// winning driver inits.  All network stack files (net.zig, arp.zig,
/// ipv4.zig, etc.) import this module instead of a specific driver.

const virtio_net = @import("virtio_net.zig");
const rtl8126 = @import("rtl8126.zig");
const gvnic = @import("gvnic.zig");

const Backend = enum { none, virtio, rtl8126, gvnic };
var backend: Backend = .none;

pub var mac: [6]u8 = .{0} ** 6;
pub var irq: u32 = 0;

/// Register virtio-net as the active NIC (QEMU path).
pub fn registerVirtio() void {
    backend = .virtio;
    mac = virtio_net.mac;
    irq = virtio_net.irq;
}

/// Register RTL8126 as the active NIC (real hardware path).
pub fn registerRtl8126() void {
    backend = .rtl8126;
    mac = rtl8126.mac;
    irq = rtl8126.irq;
}

/// Register gVNIC as the active NIC (GCE path).
pub fn registerGvnic() void {
    backend = .gvnic;
    mac = gvnic.mac;
    irq = gvnic.irq;
}

pub fn isInitialized() bool {
    return backend != .none;
}

/// Transmit a raw Ethernet frame.
pub fn transmit(data: []const u8) bool {
    return switch (backend) {
        .virtio => virtio_net.transmit(data),
        .rtl8126 => rtl8126.transmit(data),
        .gvnic => gvnic.transmit(data),
        .none => false,
    };
}

/// Dequeue a received packet. Returns null if no packets available.
pub fn receive() ?struct { data: []const u8 } {
    // Unwrap and re-wrap to unify anonymous struct types from different drivers.
    switch (backend) {
        .virtio => {
            const r = virtio_net.receive() orelse return null;
            return .{ .data = r.data };
        },
        .rtl8126 => {
            const r = rtl8126.receive() orelse return null;
            return .{ .data = r.data };
        },
        .gvnic => {
            const r = gvnic.receive() orelse return null;
            return .{ .data = r.data };
        },
        .none => return null,
    }
}

/// Advance the RX ring tail after processing a received packet.
pub fn receiveConsume() void {
    switch (backend) {
        .virtio => virtio_net.receiveConsume(),
        .rtl8126 => rtl8126.receiveConsume(),
        .gvnic => gvnic.receiveConsume(),
        .none => {},
    }
}

/// IRQ handler — dispatch to active backend.
pub fn handleIrq() void {
    switch (backend) {
        .virtio => virtio_net.handleIrq(),
        .rtl8126 => rtl8126.handleIrq(),
        .gvnic => gvnic.handleIrq(),
        .none => {},
    }
}
