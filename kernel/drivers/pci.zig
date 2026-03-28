/// PCI bus scanner — legacy configuration space access via I/O ports 0xCF8/0xCFC.
///
/// Supports class/subclass detection, 64-bit BARs, multi-function devices,
/// and device enable (memory space + bus mastering).

const io = @import("../arch/x86_64/io.zig");
const serial = @import("../arch/x86_64/serial.zig");
const klog = @import("../klog/klog.zig");
const log = klog.scoped(.pci);

pub const PciDevice = struct {
    bus: u8,
    device: u8,
    function: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    header_type: u8,
    bar0: u64,
    bar0_size: u64,
    irq_line: u8,
    irq_pin: u8,
    in_use: bool,
};

/// PCI Command register bits
const CMD_IO_SPACE: u16 = 1 << 0;
const CMD_MEMORY_SPACE: u16 = 1 << 1;
const CMD_BUS_MASTER: u16 = 1 << 2;

const CONFIG_ADDRESS: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

const MAX_DEVICES: usize = 64;
var devices: [MAX_DEVICES]PciDevice = [_]PciDevice{.{
    .bus = 0,
    .device = 0,
    .function = 0,
    .vendor_id = 0,
    .device_id = 0,
    .class_code = 0,
    .subclass = 0,
    .prog_if = 0,
    .header_type = 0,
    .bar0 = 0,
    .bar0_size = 0,
    .irq_line = 0,
    .irq_pin = 0,
    .in_use = false,
}} ** MAX_DEVICES;
var device_count: u8 = 0;

// ---- Config space access ----

/// Build a PCI config address: enable | bus | device | function | register
fn configAddress(bus: u8, device: u8, function: u8, offset: u8) u32 {
    return @as(u32, 1) << 31 | // enable bit
        @as(u32, bus) << 16 |
        @as(u32, device) << 11 |
        @as(u32, function) << 8 |
        (@as(u32, offset) & 0xFC); // align to dword
}

pub fn pciRead32(bus: u8, device: u8, function: u8, offset: u8) u32 {
    io.outl(CONFIG_ADDRESS, configAddress(bus, device, function, offset));
    return io.inl(CONFIG_DATA);
}

pub fn pciWrite32(bus: u8, device: u8, function: u8, offset: u8, value: u32) void {
    io.outl(CONFIG_ADDRESS, configAddress(bus, device, function, offset));
    io.outl(CONFIG_DATA, value);
}

pub fn pciRead16(bus: u8, device: u8, function: u8, offset: u8) u16 {
    const dword = pciRead32(bus, device, function, offset & 0xFC);
    const shift: u5 = @truncate((offset & 2) * 8);
    return @truncate(dword >> shift);
}

pub fn pciWrite16(bus: u8, device: u8, function: u8, offset: u8, value: u16) void {
    const aligned = offset & 0xFC;
    var dword = pciRead32(bus, device, function, aligned);
    const shift: u5 = @truncate((offset & 2) * 8);
    const mask = @as(u32, 0xFFFF) << shift;
    dword = (dword & ~mask) | (@as(u32, value) << shift);
    pciWrite32(bus, device, function, aligned, dword);
}

pub fn pciRead8(bus: u8, device: u8, function: u8, offset: u8) u8 {
    const dword = pciRead32(bus, device, function, offset & 0xFC);
    const shift: u5 = @truncate((offset & 3) * 8);
    return @truncate(dword >> shift);
}

// ---- Bus scanning ----

pub fn scanBus() void {
    log.info("scan_start", .{});
    device_count = 0;

    scanBusN(0);

    log.info("scan_done", .{ .count = @as(u64, device_count) });
}

/// Scan a specific PCI bus. Called recursively for bridges.
fn scanBusN(bus: u8) void {
    var dev_slot: u8 = 0;
    while (dev_slot < 32) : (dev_slot += 1) {
        scanDevice(bus, dev_slot);
    }
}

fn scanDevice(bus: u8, dev_slot: u8) void {
    const vendor = pciRead16(bus, dev_slot, 0, 0x00);
    if (vendor == 0xFFFF) return;

    addDevice(bus, dev_slot, 0);

    // Check multi-function
    const hdr_type = pciRead8(bus, dev_slot, 0, 0x0E);
    if (hdr_type & 0x80 != 0) {
        var func: u8 = 1;
        while (func < 8) : (func += 1) {
            const fv = pciRead16(bus, dev_slot, func, 0x00);
            if (fv != 0xFFFF) {
                addDevice(bus, dev_slot, func);
            }
        }
    }
}

fn addDevice(bus: u8, dev_slot: u8, func: u8) void {
    if (device_count >= MAX_DEVICES) return;

    const vendor = pciRead16(bus, dev_slot, func, 0x00);
    const device_id = pciRead16(bus, dev_slot, func, 0x02);
    const class_code = pciRead8(bus, dev_slot, func, 0x0B);
    const subclass = pciRead8(bus, dev_slot, func, 0x0A);
    const prog_if = pciRead8(bus, dev_slot, func, 0x09);
    const hdr_type = pciRead8(bus, dev_slot, func, 0x0E) & 0x7F;
    const irq_line: u8 = @truncate(pciRead32(bus, dev_slot, func, 0x3C));
    const irq_pin = pciRead8(bus, dev_slot, func, 0x3D);

    // Read BAR0, detect 64-bit type
    const bar0_lo = pciRead32(bus, dev_slot, func, 0x10);
    var bar0: u64 = 0;
    const is_io = (bar0_lo & 1) != 0;
    const bar_type = (bar0_lo >> 1) & 3;
    const is_64bit = (!is_io and bar_type == 2);

    if (is_io) {
        bar0 = bar0_lo & 0xFFFFFFFC;
    } else {
        bar0 = bar0_lo & 0xFFFFFFF0;
        if (is_64bit) {
            const bar0_hi = pciRead32(bus, dev_slot, func, 0x14);
            bar0 |= @as(u64, bar0_hi) << 32;
        }
    }

    const idx: usize = device_count;
    devices[idx] = .{
        .bus = bus,
        .device = dev_slot,
        .function = func,
        .vendor_id = vendor,
        .device_id = device_id,
        .class_code = class_code,
        .subclass = subclass,
        .prog_if = prog_if,
        .header_type = hdr_type,
        .bar0 = bar0,
        .bar0_size = 0, // firmware-assigned, no probing needed
        .irq_line = irq_line,
        .irq_pin = irq_pin,
        .in_use = true,
    };
    device_count += 1;

    // Log discovery — vendor+device packed into one u64 for compact output
    const vid_did = (@as(u64, vendor) << 16) | @as(u64, device_id);
    const class_packed = (@as(u64, class_code) << 16) | (@as(u64, subclass) << 8) | @as(u64, prog_if);
    log.info("device", .{ .vid_did = vid_did, .class = class_packed, .bar0 = bar0 });

    // PCIe bridge (class 06:04) — scan secondary bus recursively.
    // Offset 0x19 in a Type 1 (bridge) header = secondary bus number.
    if (class_code == 0x06 and subclass == 0x04) {
        const secondary_bus = pciRead8(bus, dev_slot, func, 0x19);
        if (secondary_bus != 0) {
            log.info("bridge", .{
                .bus = @as(u64, bus),
                .secondary = @as(u64, secondary_bus),
            });
            scanBusN(secondary_bus);
        }
    }
}

// ---- Device lookup ----

pub fn findDevice(vendor: u16, device_id: u16) ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].in_use and
            devices[i].vendor_id == vendor and
            devices[i].device_id == device_id)
        {
            return &devices[i];
        }
    }
    return null;
}

/// Find a device by PCI class/subclass/prog_if triple.
pub fn findByClass(class: u8, subclass: u8, prog_if: u8) ?*PciDevice {
    for (0..device_count) |i| {
        if (devices[i].in_use and
            devices[i].class_code == class and
            devices[i].subclass == subclass and
            devices[i].prog_if == prog_if)
        {
            return &devices[i];
        }
    }
    return null;
}

// ---- Device enable ----

pub fn enableBusMastering(dev: *const PciDevice) void {
    var cmd = pciRead16(dev.bus, dev.device, dev.function, 0x04);
    cmd |= CMD_BUS_MASTER | CMD_IO_SPACE;
    pciWrite16(dev.bus, dev.device, dev.function, 0x04, cmd);
}

pub fn enableDevice(dev: *const PciDevice) void {
    var cmd = pciRead16(dev.bus, dev.device, dev.function, 0x04);
    cmd |= CMD_MEMORY_SPACE | CMD_BUS_MASTER;
    pciWrite16(dev.bus, dev.device, dev.function, 0x04, cmd);
}

// --- Output helpers ---

fn writeHex8(val: u8) void {
    const hex = "0123456789abcdef";
    serial.writeByte(hex[@as(usize, val >> 4)]);
    serial.writeByte(hex[@as(usize, val & 0x0f)]);
}

fn writeHex16(val: u16) void {
    writeHex8(@truncate(val >> 8));
    writeHex8(@truncate(val));
}

fn writeHex32(val: u32) void {
    writeHex16(@truncate(val >> 16));
    writeHex16(@truncate(val));
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        serial.writeByte('0');
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
    serial.writeString(buf[i..]);
}
