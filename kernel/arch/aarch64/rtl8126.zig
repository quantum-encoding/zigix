/// RTL8126 5GbE Ethernet NIC driver — bare-metal, polling + IRQ hybrid.
///
/// Realtek RTL8126 (PCI ID 10EC:8126) is register-compatible with RTL8125B.
/// Same MAC register map 0x00-0xFF, same descriptor format, same init sequence.
/// Without firmware blobs the PHY negotiates up to 1GbE (5GbE requires rtl8126a-*.fw).
///
/// Uses legacy 16-byte RX descriptors and 32-byte TX descriptors (RTL8125 mode).
/// Single TX queue + single RX queue. Synchronous TX (poll for completion).
/// RX via IRQ handler + timer polling into a kernel rx_ring circular buffer.
///
/// References:
///   - OpenWrt r8126.h (register definitions)
///   - Linux r8169_main.c (shared RTL8125/8126 code path)
///   - RTL8125B datasheet (register-compatible reference)

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const gic = @import("gic.zig");
const timer = @import("timer.zig");
const pci = @import("pci.zig");
const spinlock = @import("spinlock.zig");

// ---- BAR0 register offsets ----

const REG_MAC0: usize = 0x00; // MAC address bytes 0-5
const REG_MAR0: usize = 0x08; // Multicast filter (64-bit hash)
const REG_TX_DESC_LO: usize = 0x20; // TX descriptor ring base (low 32)
const REG_TX_DESC_HI: usize = 0x24; // TX descriptor ring base (high 32)
const REG_CHIPCMD: usize = 0x37; // Command register
const REG_IMR: usize = 0x38; // Interrupt mask (8125 mode, 32-bit)
const REG_ISR: usize = 0x3C; // Interrupt status (8125 mode, 32-bit)
const REG_TXCONFIG: usize = 0x40; // Transmit configuration
const REG_RXCONFIG: usize = 0x44; // Receive configuration
const REG_CFG9346: usize = 0x50; // EEPROM command / config lock
const REG_PHYAR: usize = 0x60; // PHY access register (MDIO)
const REG_PHYSTATUS: usize = 0x6C; // PHY link status
const REG_TPPOLL: usize = 0x90; // TX poll (8125 mode)
const REG_RXMAXSIZE: usize = 0xDA; // Max RX packet size
const REG_CPLUSCMD: usize = 0xE0; // C+ command register
const REG_RX_DESC_LO: usize = 0xE4; // RX descriptor ring base (low 32)
const REG_RX_DESC_HI: usize = 0xE8; // RX descriptor ring base (high 32)
const REG_MTPS: usize = 0xEC; // Max TX packet size

// ---- ChipCmd bits ----

const CMD_RESET: u8 = 1 << 4; // Software reset (self-clearing)
const CMD_RX_ENB: u8 = 1 << 3; // Enable receiver
const CMD_TX_ENB: u8 = 1 << 2; // Enable transmitter

// ---- Cfg9346 values ----

const CFG_UNLOCK: u8 = 0xC0; // Unlock configuration registers
const CFG_LOCK: u8 = 0x00; // Lock configuration registers

// ---- Interrupt bits (8125 mode, offset 0x3C) ----

const ISR_RX_OK: u32 = 1 << 0;
const ISR_TX_OK: u32 = 1 << 2;
const ISR_RX_DESC_UNAVAIL: u32 = 1 << 4;
const ISR_LINK_CHG: u32 = 1 << 5;
const ISR_SYS_ERR: u32 = 1 << 15;

// ---- PHY status bits (offset 0x6C) ----

const PHY_LINK_STATUS: u32 = 1 << 1;
const PHY_FULL_DUP: u32 = 1 << 0;
const PHY_10M: u32 = 1 << 2;
const PHY_100M: u32 = 1 << 3;
const PHY_1000M: u32 = 1 << 4;
const PHY_2500M: u32 = 1 << 10;
const PHY_5000M: u32 = 1 << 12;

// ---- TX poll (offset 0x90) ----

const TPPOLL_NPQ: u8 = 1 << 0; // Normal Priority Queue poll

// ---- Descriptor bit flags ----

const DESC_OWN: u32 = 1 << 31; // Descriptor owned by NIC
const DESC_EOR: u32 = 1 << 30; // End Of Ring — wrap to start

// TX-specific
const TX_FS: u32 = 1 << 29; // First Segment
const TX_LS: u32 = 1 << 28; // Last Segment

// ---- Descriptor structures ----

/// TX descriptor: 32 bytes (RTL8125/8126 mode).
const TxDesc = extern struct {
    opts1: u32, // OWN | EOR | FS | LS | length[15:0]
    opts2: u32, // VLAN tag, checksum offload
    addr_lo: u32, // DMA buffer address low 32
    addr_hi: u32, // DMA buffer address high 32
    reserved: [16]u8, // Padding to 32 bytes
};

/// RX descriptor: 16 bytes (legacy mode).
const RxDesc = extern struct {
    opts1: u32, // OWN | EOR | length[13:0]
    opts2: u32, // VLAN tag, protocol ID
    addr_lo: u32, // DMA buffer address low 32
    addr_hi: u32, // DMA buffer address high 32
};

// Compile-time layout checks
comptime {
    if (@sizeOf(TxDesc) != 32) @compileError("TxDesc must be 32 bytes");
    if (@sizeOf(RxDesc) != 16) @compileError("RxDesc must be 16 bytes");
}

// ---- Ring configuration ----

const TX_RING_SIZE: usize = 32;
const RX_RING_SIZE: usize = 32;
const RX_BUF_COUNT: usize = 16; // Pre-posted RX DMA buffers
const RX_BUF_SIZE: usize = 4096; // One PMM page per buffer
const MAX_FRAME_SIZE: usize = 1514; // Ethernet MTU (1500) + header (14)
const KERNEL_RX_RING_SIZE: usize = 32; // Kernel-side circular buffer

// ---- Static state ----

var bar0_base: usize = 0;
var initialized: bool = false;

// TX ring (one PMM page holds 32 × 32B = 1KB)
var tx_ring_phys: u64 = 0;
var tx_next: usize = 0; // Next TX descriptor to use

// TX DMA buffer (driver copies frame here, NIC DMAs out)
var tx_buf_phys: u64 = 0;

// RX ring (one PMM page holds 32 × 16B = 512B)
var rx_ring_phys: u64 = 0;
var rx_next: usize = 0; // Next RX descriptor to check

// RX DMA buffers (NIC DMAs received packets here)
var rx_buf_phys: [RX_BUF_COUNT]u64 = [_]u64{0} ** RX_BUF_COUNT;

// Kernel rx_ring: circular buffer of received packets (same pattern as virtio_net)
const RxPacket = struct {
    data: [1524]u8,
    len: u16,
    valid: bool,
};
var rx_ring: [KERNEL_RX_RING_SIZE]RxPacket = undefined;
var rx_ring_head: usize = 0; // IRQ/poll writes here
var rx_ring_tail: usize = 0; // receive() reads here

// Public state
pub var mac: [6]u8 = .{0} ** 6;
pub var irq: u32 = 0;

// SMP lock for TX path
var tx_lock: spinlock.IrqSpinlock = .{};

// ---- MMIO register access (with ARM64 memory barriers) ----

fn readReg8(offset: usize) u8 {
    const ptr: *volatile u8 = @ptrFromInt(bar0_base + offset);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    return ptr.*;
}

fn writeReg8(offset: usize, val: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(bar0_base + offset);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    ptr.* = val;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

fn readReg32(offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(bar0_base + offset);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    const val = ptr.*;
    asm volatile ("dmb sy" ::: .{ .memory = true });
    return val;
}

fn writeReg32(offset: usize, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(bar0_base + offset);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    ptr.* = val;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

fn readReg16(offset: usize) u16 {
    const ptr: *volatile u16 = @ptrFromInt(bar0_base + offset);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    return ptr.*;
}

fn writeReg16(offset: usize, val: u16) void {
    const ptr: *volatile u16 = @ptrFromInt(bar0_base + offset);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    ptr.* = val;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

// ---- Helper: zero a physical page ----

fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..4096) |i| {
        ptr[i] = 0;
    }
}

// ---- Software reset ----

fn chipReset() bool {
    writeReg8(REG_CHIPCMD, CMD_RESET);

    // Poll until reset bit self-clears (100ms timeout)
    var elapsed: u32 = 0;
    while (elapsed < 100) : (elapsed += 1) {
        if (readReg8(REG_CHIPCMD) & CMD_RESET == 0) {
            return true;
        }
        timer.delayMillis(1);
    }

    uart.writeString("[rtl8126] Reset timeout\n");
    return false;
}

// ---- Read MAC address from register space ----

fn readMac() void {
    for (0..6) |i| {
        mac[i] = readReg8(REG_MAC0 + i);
    }
}

// ---- Descriptor ring initialization ----

fn initTxRing() void {
    const ring: [*]volatile TxDesc = @ptrFromInt(tx_ring_phys);

    for (0..TX_RING_SIZE) |i| {
        ring[i].opts1 = 0; // Driver owns all TX descriptors
        ring[i].opts2 = 0;
        ring[i].addr_lo = 0;
        ring[i].addr_hi = 0;
        for (0..16) |j| ring[i].reserved[j] = 0;
    }

    // Set End-Of-Ring on last descriptor
    ring[TX_RING_SIZE - 1].opts1 = DESC_EOR;
    tx_next = 0;
}

fn initRxRing() void {
    const ring: [*]volatile RxDesc = @ptrFromInt(rx_ring_phys);

    for (0..RX_RING_SIZE) |i| {
        // Map RX descriptors to DMA buffers (round-robin: desc i uses buf i % RX_BUF_COUNT)
        const buf_idx = i % RX_BUF_COUNT;
        const buf_addr = rx_buf_phys[buf_idx];

        var flags: u32 = DESC_OWN | @as(u32, @truncate(RX_BUF_SIZE & 0x3FFF));
        if (i == RX_RING_SIZE - 1) flags |= DESC_EOR;

        ring[i].opts1 = flags;
        ring[i].opts2 = 0;
        ring[i].addr_lo = @truncate(buf_addr);
        ring[i].addr_hi = @truncate(buf_addr >> 32);
    }

    rx_next = 0;
}

// ---- PHY link status ----

fn checkLink() void {
    const status = readReg32(REG_PHYSTATUS);

    if (status & PHY_LINK_STATUS == 0) {
        uart.writeString("[rtl8126] Link: DOWN\n");
        return;
    }

    uart.writeString("[rtl8126] Link: UP ");
    if (status & PHY_5000M != 0) {
        uart.writeString("5000Mbps");
    } else if (status & PHY_2500M != 0) {
        uart.writeString("2500Mbps");
    } else if (status & PHY_1000M != 0) {
        uart.writeString("1000Mbps");
    } else if (status & PHY_100M != 0) {
        uart.writeString("100Mbps");
    } else if (status & PHY_10M != 0) {
        uart.writeString("10Mbps");
    }
    if (status & PHY_FULL_DUP != 0) {
        uart.writeString(" Full-Duplex");
    } else {
        uart.writeString(" Half-Duplex");
    }
    uart.writeString("\n");
}

// ---- PCI IRQ pin to GIC SPI mapping ----
// QEMU virt: PCI INTA-INTD → GIC SPI 3-6 (IRQ 35-38 with SPI offset 32)
// Real HW: depends on ACPI routing; SPI base may differ.

fn pciIrqToGic(irq_pin: u8) u32 {
    if (irq_pin >= 1 and irq_pin <= 4) {
        return @as(u32, irq_pin) - 1 + 35; // SPI 3 = IRQ 35
    }
    return 0; // No interrupt
}

// ---- Public init ----

pub fn init(dev: *const pci.PciDevice) bool {
    if (dev.bar0 == 0) {
        uart.writeString("[rtl8126] BAR0 not assigned\n");
        return false;
    }

    bar0_base = @truncate(dev.bar0);
    uart.print("[rtl8126] BAR0 at {x} (size {x})\n", .{ bar0_base, dev.bar0_size });

    // Step 1: Software reset
    if (!chipReset()) return false;
    uart.writeString("[rtl8126] Reset OK\n");

    // Step 2: Unlock configuration registers
    writeReg8(REG_CFG9346, CFG_UNLOCK);

    // Step 3: Read MAC address
    readMac();
    uart.writeString("[rtl8126] MAC: ");
    for (0..6) |i| {
        if (i > 0) uart.writeByte(':');
        writeHex8(mac[i]);
    }
    uart.writeString("\n");

    // Step 4: Allocate descriptor rings
    tx_ring_phys = pmm.allocPage() orelse {
        uart.writeString("[rtl8126] Failed to alloc TX ring\n");
        return false;
    };
    rx_ring_phys = pmm.allocPage() orelse {
        uart.writeString("[rtl8126] Failed to alloc RX ring\n");
        pmm.freePage(tx_ring_phys);
        return false;
    };
    zeroPage(tx_ring_phys);
    zeroPage(rx_ring_phys);

    // Step 5: Allocate TX DMA buffer
    tx_buf_phys = pmm.allocPage() orelse {
        uart.writeString("[rtl8126] Failed to alloc TX buffer\n");
        pmm.freePage(tx_ring_phys);
        pmm.freePage(rx_ring_phys);
        return false;
    };

    // Step 6: Allocate RX DMA buffers
    for (0..RX_BUF_COUNT) |i| {
        rx_buf_phys[i] = pmm.allocPage() orelse {
            uart.writeString("[rtl8126] Failed to alloc RX buffer\n");
            // Free already allocated buffers
            for (0..i) |j| pmm.freePage(rx_buf_phys[j]);
            pmm.freePage(tx_buf_phys);
            pmm.freePage(tx_ring_phys);
            pmm.freePage(rx_ring_phys);
            return false;
        };
    }

    uart.print("[rtl8126] Allocated {} RX buffers + 1 TX buffer\n", .{RX_BUF_COUNT});

    // Step 7: Initialize descriptor rings
    initTxRing();
    initRxRing();

    // Step 8: Program ring base addresses
    writeReg32(REG_TX_DESC_LO, @truncate(tx_ring_phys));
    writeReg32(REG_TX_DESC_HI, @truncate(tx_ring_phys >> 32));
    writeReg32(REG_RX_DESC_LO, @truncate(rx_ring_phys));
    writeReg32(REG_RX_DESC_HI, @truncate(rx_ring_phys >> 32));

    // Step 9: Configure RX
    // AcceptBroadcast (bit 3) | AcceptMulticast (bit 2) | AcceptMyPhys (bit 1)
    // + RX FIFO threshold and DMA burst size bits for performance
    writeReg32(REG_RXCONFIG, 0x0000E70E);
    writeReg16(REG_RXMAXSIZE, 0x05F3); // Max packet: 1523 bytes (MTU 1500 + Ethernet header + FCS)

    // Step 10: Configure TX
    // Standard Inter-Frame Gap (bits 25:24 = 11) | DMA burst
    writeReg32(REG_TXCONFIG, 0x03000700);
    writeReg8(REG_MTPS, 0x3B); // Max TX packet size (8KB)

    // Step 11: Enable C+ mode (required for descriptor-based operation)
    var cplus = readReg16(REG_CPLUSCMD);
    cplus |= (1 << 3); // PCI Multiple RW Enable
    writeReg16(REG_CPLUSCMD, cplus);

    // Step 12: Accept all multicast (set MAR0/MAR4 to all 1s)
    writeReg32(REG_MAR0, 0xFFFFFFFF);
    writeReg32(REG_MAR0 + 4, 0xFFFFFFFF);

    // Step 13: Set interrupt mask
    writeReg32(REG_IMR, ISR_RX_OK | ISR_TX_OK | ISR_LINK_CHG | ISR_RX_DESC_UNAVAIL);

    // Step 14: Enable transmitter and receiver
    writeReg8(REG_CHIPCMD, CMD_RX_ENB | CMD_TX_ENB);

    // Step 15: Lock configuration registers
    writeReg8(REG_CFG9346, CFG_LOCK);

    // Step 16: Initialize kernel rx_ring
    for (0..KERNEL_RX_RING_SIZE) |i| {
        rx_ring[i].valid = false;
        rx_ring[i].len = 0;
    }
    rx_ring_head = 0;
    rx_ring_tail = 0;

    // Step 17: Map PCI interrupt
    irq = pciIrqToGic(dev.irq_pin);
    if (irq != 0) {
        gic.enableIrq(irq);
        gic.setPriority(irq, 0);
        uart.print("[rtl8126] IRQ {} (PCI pin {})\n", .{ irq, dev.irq_pin });
    }

    // Step 18: Check link status
    checkLink();

    initialized = true;
    uart.writeString("[rtl8126] Driver initialized\n");
    return true;
}

// ---- Transmit a raw Ethernet frame ----

pub fn transmit(data: []const u8) bool {
    if (!initialized) return false;
    if (data.len > MAX_FRAME_SIZE) return false;

    tx_lock.acquire();
    defer tx_lock.release();

    const ring: [*]volatile TxDesc = @ptrFromInt(tx_ring_phys);

    // Check if descriptor is available (OWN must be 0 = driver owns)
    if (ring[tx_next].opts1 & DESC_OWN != 0) {
        return false; // NIC still processing previous TX
    }

    // Copy frame to TX DMA buffer
    const buf: [*]u8 = @ptrFromInt(tx_buf_phys);
    for (0..data.len) |i| {
        buf[i] = data[i];
    }

    // Set TX descriptor
    var flags: u32 = DESC_OWN | TX_FS | TX_LS | @as(u32, @truncate(data.len));
    if (tx_next == TX_RING_SIZE - 1) flags |= DESC_EOR;

    ring[tx_next].addr_lo = @truncate(tx_buf_phys);
    ring[tx_next].addr_hi = @truncate(tx_buf_phys >> 32);
    ring[tx_next].opts2 = 0;

    // Write opts1 last (it has the OWN bit that triggers DMA)
    asm volatile ("dmb sy" ::: .{ .memory = true });
    ring[tx_next].opts1 = flags;
    asm volatile ("dmb sy" ::: .{ .memory = true });

    // Kick TX — write to TPPOLL to notify NIC
    writeReg8(REG_TPPOLL, TPPOLL_NPQ);

    // Advance to next descriptor
    tx_next = (tx_next + 1) % TX_RING_SIZE;

    // Poll for TX completion (synchronous — wait for NIC to clear OWN)
    const prev = if (tx_next == 0) TX_RING_SIZE - 1 else tx_next - 1;
    var spins: u32 = 0;
    while (spins < 1_000_000) : (spins += 1) {
        asm volatile ("dmb sy" ::: .{ .memory = true });
        if (ring[prev].opts1 & DESC_OWN == 0) {
            return true;
        }
        asm volatile ("yield");
    }

    uart.writeString("[rtl8126] TX timeout\n");
    return false;
}

// ---- Process completed RX descriptors ----

fn processRx() void {
    const ring: [*]volatile RxDesc = @ptrFromInt(rx_ring_phys);

    var processed: u32 = 0;
    while (processed < RX_RING_SIZE) : (processed += 1) {
        asm volatile ("dmb sy" ::: .{ .memory = true });
        const opts1 = ring[rx_next].opts1;

        // Stop if NIC still owns this descriptor
        if (opts1 & DESC_OWN != 0) break;

        // Extract frame length from bits 13:0
        const frame_len = opts1 & 0x3FFF;

        if (frame_len > 0 and frame_len <= 1524) {
            // Read DMA buffer
            const buf_idx = rx_next % RX_BUF_COUNT;
            const src: [*]const u8 = @ptrFromInt(rx_buf_phys[buf_idx]);
            const fl: usize = @intCast(frame_len);

            // Copy to kernel rx_ring
            const next = rx_ring_head;
            for (0..fl) |i| {
                rx_ring[next].data[i] = src[i];
            }
            rx_ring[next].len = @truncate(frame_len);
            rx_ring[next].valid = true;
            rx_ring_head = (rx_ring_head + 1) % KERNEL_RX_RING_SIZE;
        }

        // Give descriptor back to NIC
        var new_opts: u32 = DESC_OWN | @as(u32, @truncate(RX_BUF_SIZE & 0x3FFF));
        if (rx_next == RX_RING_SIZE - 1) new_opts |= DESC_EOR;
        ring[rx_next].opts1 = new_opts;
        asm volatile ("dmb sy" ::: .{ .memory = true });

        rx_next = (rx_next + 1) % RX_RING_SIZE;
    }
}

// ---- IRQ handler ----

pub fn handleIrq() void {
    if (!initialized) return;

    // Read and acknowledge interrupt status
    const isr = readReg32(REG_ISR);
    if (isr == 0) return;
    writeReg32(REG_ISR, isr); // Write-to-clear

    if (isr & ISR_RX_OK != 0 or isr & ISR_RX_DESC_UNAVAIL != 0) {
        processRx();
    }

    if (isr & ISR_LINK_CHG != 0) {
        checkLink();
    }

    if (isr & ISR_SYS_ERR != 0) {
        uart.writeString("[rtl8126] System error!\n");
    }
}

// ---- Receive from kernel rx_ring ----

pub fn receive() ?struct { data: []const u8 } {
    if (rx_ring_tail == rx_ring_head) return null;
    if (!rx_ring[rx_ring_tail].valid) return null;

    const pkt = &rx_ring[rx_ring_tail];
    return .{ .data = pkt.data[0..pkt.len] };
}

pub fn receiveConsume() void {
    rx_ring[rx_ring_tail].valid = false;
    rx_ring_tail = (rx_ring_tail + 1) % KERNEL_RX_RING_SIZE;
}

pub fn isInitialized() bool {
    return initialized;
}

// ---- Output helpers ----

fn writeHex8(val: u8) void {
    const hex = "0123456789abcdef";
    uart.writeByte(hex[@as(usize, val >> 4)]);
    uart.writeByte(hex[@as(usize, val & 0xf)]);
}
