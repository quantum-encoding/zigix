/// PCIe ECAM configuration space scanner with BAR assignment.
///
/// QEMU virt machine PCIe topology:
///   ECAM:      0x3f000000 (16MB, buses 0-15)
///   MMIO:      0x10000000 - 0x3effffff (~750MB)
///   IRQ:       GIC SPI 3-6 (PCI INTA-INTD)
///
/// QEMU with -kernel does NOT assign BARs — this scanner does full
/// enumeration: probe BAR sizes, assign addresses, enable devices.

const uart = @import("uart.zig");
const acpi = @import("acpi");
const exception = @import("exception.zig");

// ---- ECAM / PCI constants ----

/// ECAM base — read from ACPI MCFG at runtime, fallback to QEMU virt default.
var ecam_base: usize = 0x3f000000;

/// MMIO window for BAR assignment (QEMU virt pcie-mmio range)
const PCIE_MMIO_BASE: u64 = 0x10000000;
const PCIE_MMIO_END: u64 = 0x3effffff;

/// PCI configuration space register offsets
const PCI_VENDOR_ID: u12 = 0x00;
const PCI_DEVICE_ID: u12 = 0x02;
const PCI_COMMAND: u12 = 0x04;
const PCI_STATUS: u12 = 0x06;
const PCI_REVISION: u12 = 0x08;
const PCI_PROG_IF: u12 = 0x09;
const PCI_SUBCLASS: u12 = 0x0A;
const PCI_CLASS: u12 = 0x0B;
const PCI_HEADER_TYPE: u12 = 0x0E;
const PCI_BAR0: u12 = 0x10;
const PCI_BAR1: u12 = 0x14;
const PCI_BAR2: u12 = 0x18;
const PCI_BAR3: u12 = 0x1C;
const PCI_IRQ_PIN: u12 = 0x3D;

/// PCI Command register bits
const CMD_IO_SPACE: u16 = 1 << 0;
const CMD_MEMORY_SPACE: u16 = 1 << 1;
const CMD_BUS_MASTER: u16 = 1 << 2;

// ---- PCI device tracking ----

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
    bar2: u64,
    bar2_size: u64,
    irq_pin: u8,
    in_use: bool,
};

const MAX_DEVICES: usize = 32;
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
    .bar2 = 0,
    .bar2_size = 0,
    .irq_pin = 0,
    .in_use = false,
}} ** MAX_DEVICES;

var device_count: u8 = 0;

/// Next available MMIO address for BAR assignment
var mmio_alloc: u64 = PCIE_MMIO_BASE;

// ---- ECAM config space access ----

/// Initialize ECAM base from ACPI MCFG table (call before scanBus).
pub fn initFromAcpi() void {
    const cfg = &acpi.parser.config;
    if (cfg.ecam_valid and cfg.ecam_base != 0) {
        ecam_base = @truncate(cfg.ecam_base);
        uart.print("[pci]  ECAM base from ACPI MCFG: {x}\n", .{ecam_base});
    } else {
        uart.print("[pci]  ECAM base: {x} (default)\n", .{ecam_base});
    }
}

/// Compute ECAM MMIO address for a BDF + register offset.
fn ecamAddr(bus: u8, dev: u8, func: u8, offset: u12) usize {
    return ecam_base +
        (@as(usize, bus) << 20) |
        (@as(usize, dev & 0x1F) << 15) |
        (@as(usize, func & 0x07) << 12) |
        @as(usize, offset & 0xFFC);
}

pub fn configRead32(bus: u8, dev: u8, func: u8, offset: u12) u32 {
    const addr = ecamAddr(bus, dev, func, offset);
    const ptr: *volatile u32 = @ptrFromInt(addr);
    @as(*volatile bool, @ptrCast(&exception.device_probe_faulted)).* = false;
    asm volatile ("dmb sy" ::: .{ .memory = true });
    const val = ptr.*;
    asm volatile ("dmb sy" ::: .{ .memory = true });
    if (@as(*volatile bool, @ptrCast(&exception.device_probe_faulted)).*) return 0xFFFFFFFF;
    return val;
}

pub fn configWrite32(bus: u8, dev: u8, func: u8, offset: u12, value: u32) void {
    const addr = ecamAddr(bus, dev, func, offset);
    const ptr: *volatile u32 = @ptrFromInt(addr);
    @as(*volatile bool, @ptrCast(&exception.device_probe_faulted)).* = false;
    asm volatile ("dmb sy" ::: .{ .memory = true });
    ptr.* = value;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

pub fn configRead16(bus: u8, dev: u8, func: u8, offset: u12) u16 {
    const dword = configRead32(bus, dev, func, offset & 0xFFC);
    const shift: u5 = @truncate((offset & 2) << 3);
    return @truncate(dword >> shift);
}

pub fn configWrite16(bus: u8, dev: u8, func: u8, offset: u12, value: u16) void {
    const aligned: u12 = offset & 0xFFC;
    var dword = configRead32(bus, dev, func, aligned);
    const shift: u5 = @truncate((offset & 2) << 3);
    const mask: u32 = @as(u32, 0xFFFF) << shift;
    dword = (dword & ~mask) | (@as(u32, value) << shift);
    configWrite32(bus, dev, func, aligned, dword);
}

pub fn configRead8(bus: u8, dev: u8, func: u8, offset: u12) u8 {
    const dword = configRead32(bus, dev, func, offset & 0xFFC);
    const shift: u5 = @truncate((offset & 3) << 3);
    return @truncate(dword >> shift);
}

// ---- BAR probing and assignment ----

const BarInfo = struct {
    addr: u64,
    size: u64,
    is_64bit: bool,
    is_mmio: bool,
};

fn probeBar(bus: u8, dev: u8, func: u8, bar_offset: u12) BarInfo {
    var info = BarInfo{ .addr = 0, .size = 0, .is_64bit = false, .is_mmio = false };

    // Save original
    const orig_lo = configRead32(bus, dev, func, bar_offset);
    if (orig_lo == 0) {
        // Probe anyway — BAR might be unassigned but still implemented
    }

    // Determine type from original value
    const is_io = (orig_lo & 1) != 0;
    if (is_io) return info; // Skip I/O BARs
    info.is_mmio = true;

    // Check 64-bit flag (bits 2:1 of BAR value)
    const bar_type = (orig_lo >> 1) & 3;
    info.is_64bit = (bar_type == 2);

    // Probe lower 32 bits
    configWrite32(bus, dev, func, bar_offset, 0xFFFFFFFF);
    const mask_lo = configRead32(bus, dev, func, bar_offset);
    configWrite32(bus, dev, func, bar_offset, orig_lo);

    if (mask_lo == 0 or mask_lo == 0xFFFFFFFF) return info;

    // Calculate size from lower mask (ignore type bits 3:0)
    const addr_mask_lo: u64 = mask_lo & 0xFFFFFFF0;

    if (info.is_64bit) {
        // Probe upper 32 bits
        const bar_hi_offset: u12 = bar_offset + 4;
        const orig_hi = configRead32(bus, dev, func, bar_hi_offset);
        configWrite32(bus, dev, func, bar_hi_offset, 0xFFFFFFFF);
        const mask_hi = configRead32(bus, dev, func, bar_hi_offset);
        configWrite32(bus, dev, func, bar_hi_offset, orig_hi);

        const full_mask: u64 = (@as(u64, mask_hi) << 32) | addr_mask_lo;
        info.size = (~full_mask) +% 1;
        info.addr = (@as(u64, orig_hi) << 32) | (orig_lo & 0xFFFFFFF0);
    } else {
        info.size = (~addr_mask_lo +% 1) & 0xFFFFFFFF;
        info.addr = orig_lo & 0xFFFFFFF0;
    }

    return info;
}

/// Assign a BAR address from the MMIO pool. Returns assigned address, or 0 on failure.
fn assignBar(bus: u8, dev: u8, func: u8, bar_offset: u12, bar: *const BarInfo) u64 {
    if (bar.size == 0 or !bar.is_mmio) return 0;

    // If BAR already has a valid address in the MMIO window, use it
    if (bar.addr >= PCIE_MMIO_BASE and bar.addr + bar.size <= PCIE_MMIO_END + 1) {
        return bar.addr;
    }

    // Align allocator to BAR size (natural alignment required by PCI spec)
    const alignment = bar.size;
    mmio_alloc = (mmio_alloc + alignment - 1) & ~(alignment - 1);

    // Check fit
    if (mmio_alloc + bar.size > PCIE_MMIO_END + 1) {
        uart.writeString("[pci]  ERROR: MMIO window exhausted\n");
        return 0;
    }

    const assigned = mmio_alloc;
    mmio_alloc += bar.size;

    // Write to BAR register
    configWrite32(bus, dev, func, bar_offset, @truncate(assigned & 0xFFFFFFF0));
    if (bar.is_64bit) {
        configWrite32(bus, dev, func, bar_offset + 4, @truncate(assigned >> 32));
    }

    return assigned;
}

// ---- Device enable ----

pub fn enableDevice(dev: *const PciDevice) void {
    var cmd = configRead16(dev.bus, dev.device, dev.function, PCI_COMMAND);
    cmd |= CMD_MEMORY_SPACE | CMD_BUS_MASTER;
    configWrite16(dev.bus, dev.device, dev.function, PCI_COMMAND, cmd);
}

// ---- Bus scanning ----

pub fn scanBus() void {
    uart.writeString("[pci]  Scanning PCIe bus 0...\n");
    device_count = 0;

    var dev_slot: u8 = 0;
    while (dev_slot < 32) : (dev_slot += 1) {
        scanDevice(0, dev_slot);
    }

    if (device_count == 0) {
        uart.writeString("[pci]  No devices found\n");
    } else {
        uart.print("[pci]  {} device(s) found\n", .{device_count});
    }
}

fn scanDevice(bus: u8, dev_slot: u8) void {
    const vendor = configRead16(bus, dev_slot, 0, PCI_VENDOR_ID);
    if (vendor == 0xFFFF) return;

    addDevice(bus, dev_slot, 0);

    // Check multi-function
    const hdr_type = configRead8(bus, dev_slot, 0, PCI_HEADER_TYPE);
    if (hdr_type & 0x80 != 0) {
        var func: u8 = 1;
        while (func < 8) : (func += 1) {
            const fv = configRead16(bus, dev_slot, func, PCI_VENDOR_ID);
            if (fv != 0xFFFF) {
                addDevice(bus, dev_slot, func);
            }
        }
    }
}

fn addDevice(bus: u8, dev_slot: u8, func: u8) void {
    if (device_count >= MAX_DEVICES) return;

    const vendor = configRead16(bus, dev_slot, func, PCI_VENDOR_ID);
    const device_id = configRead16(bus, dev_slot, func, PCI_DEVICE_ID);
    const class_code = configRead8(bus, dev_slot, func, PCI_CLASS);
    const subclass = configRead8(bus, dev_slot, func, PCI_SUBCLASS);
    const prog_if = configRead8(bus, dev_slot, func, PCI_PROG_IF);
    const hdr_type = configRead8(bus, dev_slot, func, PCI_HEADER_TYPE) & 0x7F;
    const irq_pin = configRead8(bus, dev_slot, func, PCI_IRQ_PIN);

    // Probe and assign BAR0
    var bar_info = probeBar(bus, dev_slot, func, PCI_BAR0);
    var bar0_addr: u64 = 0;
    const bar0_size: u64 = bar_info.size;

    if (bar_info.is_mmio and bar_info.size > 0) {
        bar0_addr = assignBar(bus, dev_slot, func, PCI_BAR0, &bar_info);
    }

    // Probe and assign BAR2 (needed by gVNIC for doorbells, etc.)
    // BAR2 offset depends on whether BAR0 is 64-bit (consumes BAR0+BAR1)
    const bar2_offset: u12 = if (bar_info.is_64bit) PCI_BAR2 else PCI_BAR2;
    var bar2_info = probeBar(bus, dev_slot, func, bar2_offset);
    var bar2_addr: u64 = 0;
    const bar2_size: u64 = bar2_info.size;

    if (bar2_info.is_mmio and bar2_info.size > 0) {
        bar2_addr = assignBar(bus, dev_slot, func, bar2_offset, &bar2_info);
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
        .bar0 = bar0_addr,
        .bar0_size = bar0_size,
        .bar2 = bar2_addr,
        .bar2_size = bar2_size,
        .irq_pin = irq_pin,
        .in_use = true,
    };
    device_count += 1;

    // Log discovery — manual hex because uart.print doesn't support {x:0>N}
    uart.printPci(bus, dev_slot, func, vendor, device_id, class_code, subclass, prog_if);
    if (bar0_addr != 0) {
        uart.print(" BAR0={x}", .{bar0_addr});
        if (bar_info.is_64bit) {
            uart.writeString(" (64-bit)");
        }
    }
    if (bar2_addr != 0) {
        uart.print(" BAR2={x}", .{bar2_addr});
    }
    if (class_code == 0x01 and subclass == 0x08 and prog_if == 0x02) {
        uart.writeString(" [NVMe]");
    }
    if (class_code == 0x02 and subclass == 0x00) {
        uart.writeString(" [Ethernet]");
    }
    uart.writeString("\n");
}

// ---- Device lookup ----

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

/// Find a device by vendor + device ID.
pub fn findByVendorDevice(vendor: u16, device_id: u16) ?*PciDevice {
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
