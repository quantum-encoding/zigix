/// NIC abstraction — dispatches to whichever network driver initialized.
/// Supports virtio-net and gVNIC (Google Virtual NIC).

const virtio_net = @import("virtio_net.zig");
const gvnic = @import("gvnic.zig");

var use_gvnic: bool = false;

pub var mac: [6]u8 = .{0} ** 6;

pub fn registerVirtio() void {
    use_gvnic = false;
    mac = virtio_net.mac;
}

pub fn registerGvnic() void {
    use_gvnic = true;
    mac = gvnic.mac;
}

pub fn isInitialized() bool {
    if (use_gvnic) return gvnic.isInitialized();
    return virtio_net.isInitialized();
}

pub fn transmit(data: []const u8) bool {
    if (use_gvnic) return gvnic.transmit(data);
    return virtio_net.transmit(data);
}

pub const Packet = struct { data: []const u8 };

pub fn receive() ?Packet {
    if (use_gvnic) {
        if (gvnic.receive()) |pkt| return Packet{ .data = pkt.data };
        return null;
    }
    if (virtio_net.receive()) |pkt| return Packet{ .data = pkt.data };
    return null;
}

pub fn receiveConsume() void {
    if (use_gvnic) return gvnic.receiveConsume();
    return virtio_net.receiveConsume();
}

pub fn handleIrq() void {
    if (use_gvnic) return gvnic.handleIrq();
    return virtio_net.handleIrq();
}

// --- Zero-copy stubs (only supported on virtio-net) ---

pub fn switchToZeroCopy(buf_base_phys: u64, buf_size: usize, num_bufs: u32) void {
    if (!use_gvnic) virtio_net.switchToZeroCopy(buf_base_phys, buf_size, num_bufs);
}

pub fn switchToCopyMode() void {
    if (!use_gvnic) virtio_net.switchToCopyMode();
}

pub fn transmitFromPhys(phys: u64, len: usize) bool {
    if (!use_gvnic) return virtio_net.transmitFromPhys(phys, len);
    return false;
}

pub fn postRxBufferPhys(phys: u64) void {
    if (!use_gvnic) virtio_net.postRxBufferPhys(phys);
}
