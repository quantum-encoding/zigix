/// Google gVNIC (Virtual NIC) driver — DQO RDA queue format.
///
/// PCI vendor 0x1AE0, device 0x0042.
/// BAR0: registers (big-endian), BAR2: doorbells (little-endian for DQO).
///
/// Initialization:
///   1. Admin Queue setup (DMA buffer, doorbell at BAR0+0x14)
///   2. DESCRIBE_DEVICE → MAC, MTU, queue sizes
///   3. CONFIGURE_DEVICE_RESOURCES → counters, IRQ doorbells, queue format
///   4. CREATE_TX_QUEUE + CREATE_RX_QUEUE
///   5. Post RX buffers, enable interrupts
///
/// Data path:
///   TX: Write packet descriptor to TX ring, ring doorbell
///   RX: Poll completion ring (generation bit), copy to rx_ring
///
/// All register accesses to BAR0 are big-endian (read/write with byte swap).
/// All descriptor and doorbell accesses (BAR2/DMA) are little-endian (native).

const uart = @import("uart.zig");
const pci = @import("pci.zig");
const pmm = @import("pmm.zig");
const gicv3 = @import("gicv3.zig");

// ---- gVNIC register offsets (BAR0, big-endian) ----

const REG_DEVICE_STATUS: usize = 0x00;
const REG_DRIVER_STATUS: usize = 0x04;
const REG_MAX_TX_QUEUES: usize = 0x08;
const REG_MAX_RX_QUEUES: usize = 0x0C;
const REG_ADMINQ_PFN: usize = 0x10;
const REG_ADMINQ_DOORBELL: usize = 0x14;
const REG_ADMINQ_EVENT_COUNTER: usize = 0x18;
const REG_DRIVER_VERSION: usize = 0x1F; // u8, written before AQ setup
const REG_ADMINQ_BASE_HI: usize = 0x20;
const REG_ADMINQ_BASE_LO: usize = 0x24;
const REG_ADMINQ_LENGTH: usize = 0x28;

// Shared memory region for DQO admin queue sequence numbers (BAR0 + 0x400)
// Linux: GVE_SHM_ADDR_OFFSET = 0x400, GVE_SHM_SIZE = 0x2000
const SHM_OFFSET: usize = 0x400;

// Device status bits
const STATUS_RESET: u32 = 1 << 1;
const STATUS_LINK_UP: u32 = 1 << 2;
const STATUS_DEVICE_IS_RESET: u32 = 1 << 4;

// Driver status bits
const DRIVER_RUN: u32 = 1 << 0;
const DRIVER_RESET: u32 = 1 << 1;

// Admin queue opcodes (big-endian in command)
const AQ_DESCRIBE_DEVICE: u32 = 0x01;
const AQ_CONFIGURE_RESOURCES: u32 = 0x02;
const AQ_CREATE_TX_QUEUE: u32 = 0x05;
const AQ_CREATE_RX_QUEUE: u32 = 0x06;
const AQ_VERIFY_DRIVER: u32 = 0x0F;

// Queue format: DQO RDA
const QUEUE_FORMAT_DQO_RDA: u8 = 0x3;

// DQO TX descriptor type for packet
const TX_DESC_DTYPE_PKT: u8 = 0x0C;

// Page size for DMA allocations
const PAGE_SIZE: usize = 4096;

// Queue sizes (power of 2, typical gVNIC)
const TX_RING_SIZE: u16 = 256;
const TX_COMP_RING_SIZE: u16 = 256;
const RX_BUF_RING_SIZE: u16 = 256;
const RX_COMP_RING_SIZE: u16 = 256;

// RX buffer size
const RX_BUF_SIZE: u16 = 2048;

// Number of RX buffers to pre-post
const NUM_RX_BUFS: u16 = 128;

// Kernel-side packet ring (same as virtio-net)
const RX_RING_SLOTS: usize = 32;
const MAX_PKT_SIZE: usize = 1524;

// ---- DQO Descriptor structures (little-endian, packed) ----

/// TX packet descriptor (16 bytes)
const TxPktDesc = extern struct {
    buf_addr: u64, // DMA address of packet data
    dtype_flags: u16, // bits[4:0]=dtype, bit5=eop, bit6=csum, bit7=report_event
    reserved: u16,
    compl_tag: u16, // echoed in completion
    buf_size: u16, // bits[13:0]=size
};

/// TX completion descriptor (8 bytes)
const TxCompDesc = extern struct {
    id_type_gen: u16, // bits[10:0]=id, [13:11]=type, bit14=rsvd, bit15=generation
    compl_tag: u16,
    reserved: u32,
};

/// RX buffer descriptor (32 bytes)
const RxBufDesc = extern struct {
    buf_id: u16,
    reserved0: u16,
    reserved1: u32,
    buf_addr: u64, // DMA address
    header_buf_addr: u64,
    reserved2: u64,
};

/// RX completion descriptor (32 bytes) — GCE gVNIC DQO format.
/// Raw byte dump confirms: pktlen_gen at offset 4, buf_id at offset 12.
const RxCompDesc = extern struct {
    rxdid_flags: u16, // offset 0
    ptype_flags: u16, // offset 2
    pktlen_gen: u16, // offset 4: bits[13:0]=packet_len, bit14=generation
    hdrlen_flags: u16, // offset 6
    desc_done_flags: u8, // offset 8
    status1: u8, // offset 9
    reserved0: u8, // offset 10
    ts_sub_nsecs: u8, // offset 11
    buf_id: u16, // offset 12: matches posted buf_id
    rsc_seg_len: u16, // offset 14
    hash: u32, // offset 16
    reserved1: u32, // offset 20
    reserved2: u32, // offset 24
    timestamp: u32, // offset 28
};

// --- Comptime struct layout assertions (Chaos Rocket safety) ---
// The buf_id offset bug (v50e) took 20+ deploy iterations to find.
// These assertions make layout assumptions compile errors, not runtime mysteries.
comptime {
    // RxCompDesc: 32 bytes, buf_id at offset 12 (confirmed by raw byte dump)
    if (@offsetOf(RxCompDesc, "rxdid_flags") != 0) @compileError("RxCompDesc.rxdid_flags must be at offset 0");
    if (@offsetOf(RxCompDesc, "pktlen_gen") != 4) @compileError("RxCompDesc.pktlen_gen must be at offset 4");
    if (@offsetOf(RxCompDesc, "buf_id") != 12) @compileError("RxCompDesc.buf_id must be at offset 12");
    if (@sizeOf(RxCompDesc) != 32) @compileError("RxCompDesc must be 32 bytes");

    // TxPktDesc: 16 bytes
    if (@offsetOf(TxPktDesc, "buf_addr") != 0) @compileError("TxPktDesc.buf_addr must be at offset 0");
    if (@offsetOf(TxPktDesc, "dtype_flags") != 8) @compileError("TxPktDesc.dtype_flags must be at offset 8");
    if (@offsetOf(TxPktDesc, "compl_tag") != 12) @compileError("TxPktDesc.compl_tag must be at offset 12");
    if (@offsetOf(TxPktDesc, "buf_size") != 14) @compileError("TxPktDesc.buf_size must be at offset 14");
    if (@sizeOf(TxPktDesc) != 16) @compileError("TxPktDesc must be 16 bytes");

    // TxCompDesc: 8 bytes
    if (@offsetOf(TxCompDesc, "id_type_gen") != 0) @compileError("TxCompDesc.id_type_gen must be at offset 0");
    if (@offsetOf(TxCompDesc, "compl_tag") != 2) @compileError("TxCompDesc.compl_tag must be at offset 2");
    if (@sizeOf(TxCompDesc) != 8) @compileError("TxCompDesc must be 8 bytes");

    // RxBufDesc: 32 bytes
    if (@offsetOf(RxBufDesc, "buf_id") != 0) @compileError("RxBufDesc.buf_id must be at offset 0");
    if (@offsetOf(RxBufDesc, "buf_addr") != 8) @compileError("RxBufDesc.buf_addr must be at offset 8");
    if (@sizeOf(RxBufDesc) != 32) @compileError("RxBufDesc must be 32 bytes");

    // AdminCmd: 64 bytes
    if (@offsetOf(AdminCmd, "opcode") != 0) @compileError("AdminCmd.opcode must be at offset 0");
    if (@offsetOf(AdminCmd, "status") != 4) @compileError("AdminCmd.status must be at offset 4");
    if (@offsetOf(AdminCmd, "payload") != 8) @compileError("AdminCmd.payload must be at offset 8");
    if (@sizeOf(AdminCmd) != 64) @compileError("AdminCmd must be 64 bytes");
}

/// Queue resources (device-written, 64 bytes)
const QueueResources = extern struct {
    db_index: u32, // big-endian! doorbell index into BAR2
    counter_index: u32, // big-endian
    reserved: [56]u8,
};

/// Admin queue command (64 bytes)
const AdminCmd = extern struct {
    opcode: u32, // big-endian
    status: u32, // big-endian (device writes result)
    payload: [56]u8,
};

// ---- Module state ----

var bar0: usize = 0; // Register BAR (big-endian MMIO)
var bar2: usize = 0; // Doorbell BAR (little-endian for DQO)

// Admin queue
var aq_buf: [*]align(PAGE_SIZE) u8 = undefined; // 4096-byte DMA buffer
var aq_phys: u64 = 0;
var aq_prod: u32 = 0; // Producer counter

// Device descriptor (from DESCRIBE_DEVICE)
pub var mac: [6]u8 = .{0} ** 6;
var mtu: u16 = 1500;
var default_num_queues: u16 = 1;
var tx_queue_entries: u16 = 256;
var rx_queue_entries: u16 = 256;
var num_counters: u16 = 0;
var queue_format: u8 = QUEUE_FORMAT_DQO_RDA; // Negotiated from device options

// TX state
var tx_ring: [*]TxPktDesc = undefined;
var tx_ring_phys: u64 = 0;
var tx_comp_ring: [*]TxCompDesc = undefined;
var tx_comp_phys: u64 = 0;
var tx_res: *QueueResources = undefined;
var tx_res_phys: u64 = 0;
var tx_tail: u16 = 0;
var tx_comp_head: u16 = 0;
var tx_comp_gen: u1 = 0;
var tx_buf_phys: u64 = 0; // Single TX bounce buffer
var tx_buf_virt: [*]u8 = undefined;

// RX state
var rx_buf_ring: [*]RxBufDesc = undefined;
var rx_buf_ring_phys: u64 = 0;
var rx_comp_ring: [*]RxCompDesc = undefined;
var rx_comp_phys: u64 = 0;
var rx_res: *QueueResources = undefined;
var rx_res_phys: u64 = 0;
var rx_buf_tail: u16 = 0;
pub var rx_comp_head: u16 = 0;
pub var rx_comp_gen: u1 = 0;

// RX packet buffers (DMA)
var rx_bufs_phys: [NUM_RX_BUFS]u64 = .{0} ** NUM_RX_BUFS;
var rx_bufs_virt: [NUM_RX_BUFS][*]u8 = undefined;

// Doorbell indices (from queue resources, converted from BE)
var tx_db_index: u32 = 0;
var rx_db_index: u32 = 0;

// Actual ring sizes (set from device-reported values at queue creation)
var actual_tx_ring_size: u16 = TX_RING_SIZE;
var actual_tx_comp_size: u16 = TX_COMP_RING_SIZE;
var actual_rx_buf_size: u16 = RX_BUF_RING_SIZE;
var actual_rx_comp_size: u16 = RX_COMP_RING_SIZE;

// Counter and IRQ arrays
var counter_array: [*]u32 = undefined;
var counter_array_phys: u64 = 0;
var irq_db_indices: [*]u32 = undefined;
var irq_db_phys: u64 = 0;

// MSI-X state
var msix_table_bar: usize = 0; // Virtual address of MSI-X table
var msix_num_vectors: u16 = 0;
var pci_bus: u8 = 0;
var pci_dev: u8 = 0;
var pci_func: u8 = 0;

// Kernel-side receive ring (same pattern as virtio-net)
var rx_ring: [RX_RING_SLOTS][MAX_PKT_SIZE]u8 = undefined;
var rx_ring_len: [RX_RING_SLOTS]u16 = .{0} ** RX_RING_SLOTS;
pub var rx_ring_head: u32 = 0;
pub var rx_ring_tail: u32 = 0;

var initialized = false;
pub var irq: u32 = 0;

// ---- Big-endian MMIO helpers ----

fn readBe32(addr: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    const val = ptr.*;
    asm volatile ("dmb sy" ::: .{ .memory = true });
    return @byteSwap(val);
}

fn writeBe32(addr: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    ptr.* = @byteSwap(value);
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

fn writeBe16(addr: usize, value: u16) void {
    // Direct 16-bit write with byte swap (iowrite16be equivalent)
    const ptr: *volatile u16 = @ptrFromInt(addr);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    ptr.* = @byteSwap(value);
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

/// Write LE32 to doorbell BAR (DQO mode = native little-endian)
fn writeDb32(offset: u32, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(bar2 + offset * 4);
    asm volatile ("dmb sy" ::: .{ .memory = true });
    ptr.* = value;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

// ---- DMA cache maintenance ----

/// Cache maintenance no-ops: Neoverse-V2 on GCE is DMA-coherent (PCIe AMBA ACE).
/// Explicit dc civac/cvac BREAKS coherent DMA by evicting cache lines that the
/// device is about to update, causing the CPU to read stale completion entries.
/// This was the root cause of "deaf after boot" — initial packets arrived before
/// cache ops ran, but subsequent polls read invalidated (stale) completion data.
fn dmaCleanRange(addr: usize, len: usize) void {
    _ = addr;
    _ = len;
}

fn dmaInvalidateRange(addr: usize, len: usize) void {
    _ = addr;
    _ = len;
}

fn dmaFlushRange(addr: usize, len: usize) void {
    _ = addr;
    _ = len;
}

// ---- DMA allocation ----

fn allocDmaPage() struct { phys: u64, virt: [*]u8 } {
    const phys = pmm.allocPage() orelse @panic("gvnic: OOM");
    const virt: [*]u8 = @ptrFromInt(phys);
    for (0..PAGE_SIZE) |i| virt[i] = 0;
    // Pin for DMA safety — saturate ref count so PMM never reallocates this page.
    pinDmaPage(phys);
    return .{ .phys = phys, .virt = virt };
}

fn allocDmaPages(n: usize) struct { phys: u64, virt: [*]u8 } {
    const first = pmm.allocPages(n) orelse @panic("gvnic: OOM");
    const virt: [*]u8 = @ptrFromInt(first);
    for (0..n * PAGE_SIZE) |i| virt[i] = 0;
    // Pin all pages for DMA safety.
    var p: usize = 0;
    while (p < n) : (p += 1) {
        pinDmaPage(first + p * PAGE_SIZE);
    }
    return .{ .phys = first, .virt = virt };
}

/// Pin a physical page for DMA by saturating its PMM ref count.
fn printMac(m: *const [6]u8) void {
    const hex = "0123456789abcdef";
    for (0..6) |i| {
        if (i > 0) uart.writeByte(':');
        uart.writeByte(hex[m[i] >> 4]);
        uart.writeByte(hex[m[i] & 0xF]);
    }
}

fn pinDmaPage(phys: u64) void {
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        pmm.incRef(phys);
    }
}

// ---- PCI MSI-X setup ----

/// Find MSI-X capability and enable it. Returns number of vectors, 0 on failure.
fn setupMsix(dev: *const pci.PciDevice) u16 {
    pci_bus = dev.bus;
    pci_dev = dev.device;
    pci_func = dev.function;

    // Walk PCI capability list to find MSI-X (cap ID = 0x11)
    const status = pci.configRead16(pci_bus, pci_dev, pci_func, 0x06);
    if (status & (1 << 4) == 0) {
        uart.writeString("[gvnic] No PCI capabilities list\n");
        return 0;
    }

    var cap_off: u12 = @as(u12, pci.configRead8(pci_bus, pci_dev, pci_func, 0x34)) & 0xFC;
    var msix_cap_offset: u12 = 0;
    var iterations: u32 = 0;
    while (cap_off != 0 and iterations < 48) : (iterations += 1) {
        const cap_id = pci.configRead8(pci_bus, pci_dev, pci_func, cap_off);
        uart.print("[gvnic] PCI cap at {x}: id={x}\n", .{ cap_off, cap_id });
        if (cap_id == 0x11) { // MSI-X
            msix_cap_offset = cap_off;
            break;
        }
        cap_off = @as(u12, pci.configRead8(pci_bus, pci_dev, pci_func, cap_off + 1)) & 0xFC;
    }

    if (msix_cap_offset == 0) {
        uart.writeString("[gvnic] MSI-X capability not found\n");
        return 0;
    }

    // MSI-X capability structure:
    //   +0: cap_id (8) + next (8) + message_control (16)
    //   +4: table_offset_bir (32) — bits[2:0]=BAR, bits[31:3]=offset
    //   +8: pba_offset_bir (32)
    const msg_ctrl = pci.configRead16(pci_bus, pci_dev, pci_func, msix_cap_offset + 2);
    const table_size = (msg_ctrl & 0x7FF) + 1; // bits[10:0] = N-1
    uart.print("[gvnic] MSI-X: {} vectors, msg_ctrl={x}\n", .{ table_size, msg_ctrl });

    const table_info = pci.configRead32(pci_bus, pci_dev, pci_func, msix_cap_offset + 4);
    const table_bir = table_info & 0x7; // BAR index
    const table_offset = table_info & ~@as(u32, 0x7); // Offset within BAR
    uart.print("[gvnic] MSI-X table: BAR{} offset={x}\n", .{ table_bir, table_offset });

    // Get BAR address for the MSI-X table
    var table_bar_base: usize = switch (table_bir) {
        0 => @truncate(dev.bar0),
        2 => @truncate(dev.bar2),
        else => 0,
    };

    // If MSI-X table is in BAR1 (common on gVNIC where BAR0 is 32-bit),
    // probe and read BAR1 directly from PCI config space
    if (table_bir == 1) {
        const bar1_offset: u12 = 0x14; // BAR1 config register
        const bar1_val = pci.configRead32(pci_bus, pci_dev, pci_func, bar1_offset);
        const bar1_addr: usize = @as(usize, bar1_val & 0xFFFFFFF0);
        uart.print("[gvnic] BAR1 raw={x} addr={x}\n", .{ bar1_val, bar1_addr });
        if (bar1_addr != 0) {
            table_bar_base = bar1_addr;
        } else {
            uart.writeString("[gvnic] BAR1 not assigned, cannot access MSI-X table\n");
            return 0;
        }
    }
    if (table_bar_base == 0) {
        uart.print("[gvnic] MSI-X table BAR{} not mapped\n", .{table_bir});
        return 0;
    }

    msix_table_bar = table_bar_base + table_offset;
    msix_num_vectors = table_size;

    // Set up MSI-X table entries.
    // If ITS is available, point to GITS_TRANSLATER for proper LPI delivery.
    // Otherwise, use a dummy DMA page (hypervisor may intercept).
    // Each entry: addr_lo(32) + addr_hi(32) + data(32) + vector_ctrl(32)
    const msix_target: u64 = if (gicv3.translater_addr != 0)
        gicv3.translater_addr
    else
        allocDmaPage().phys;

    uart.print("[gvnic] MSI-X target addr={x} (ITS={})\n", .{ msix_target, @as(u8, if (gicv3.translater_addr != 0) 1 else 0) });

    var vec: u16 = 0;
    while (vec < table_size and vec < 8) : (vec += 1) {
        const entry_addr = msix_table_bar + @as(usize, vec) * 16;
        const entry_lo: *volatile u32 = @ptrFromInt(entry_addr);
        const entry_hi: *volatile u32 = @ptrFromInt(entry_addr + 4);
        const entry_data: *volatile u32 = @ptrFromInt(entry_addr + 8);
        const entry_ctrl: *volatile u32 = @ptrFromInt(entry_addr + 12);

        entry_lo.* = @truncate(msix_target); // Address low
        entry_hi.* = @truncate(msix_target >> 32); // Address high
        entry_data.* = vec; // Data = vector/EventID number
        entry_ctrl.* = 0; // Unmask (bit 0 = 0 means unmasked)
    }

    // Enable MSI-X: set bit 15 of message control, clear function mask (bit 14)
    const new_ctrl = (msg_ctrl | (1 << 15)) & ~@as(u16, 1 << 14);
    pci.configWrite16(pci_bus, pci_dev, pci_func, msix_cap_offset + 2, new_ctrl);

    const verify = pci.configRead16(pci_bus, pci_dev, pci_func, msix_cap_offset + 2);
    uart.print("[gvnic] MSI-X enabled: msg_ctrl={x}\n", .{verify});

    return table_size;
}

// ---- Admin Queue ----

fn aqSubmit(cmd: *AdminCmd) bool {
    // Copy command to next slot in AQ buffer
    const slot = aq_prod % (PAGE_SIZE / @sizeOf(AdminCmd));
    const offset = slot * @sizeOf(AdminCmd);
    const dst: [*]u8 = aq_buf + offset;
    const src: [*]const u8 = @ptrCast(cmd);
    for (0..@sizeOf(AdminCmd)) |i| dst[i] = src[i];

    // Debug: dump command as u32 words
    uart.writeString("[gvnic] AQ cmd: ");
    var wi: usize = 0;
    while (wi < 40) : (wi += 4) {
        const word = @as(u32, dst[wi]) << 24 | @as(u32, dst[wi + 1]) << 16 |
            @as(u32, dst[wi + 2]) << 8 | @as(u32, dst[wi + 3]);
        uart.writeHex(word);
        uart.writeString(" ");
    }
    uart.writeString("\n");

    // Clean cache so device sees our command via DMA
    dmaCleanRange(@intFromPtr(aq_buf) + offset, @sizeOf(AdminCmd));

    // DQO shared memory sequence: write slot index to BAR0 + SHM_OFFSET + slot*4
    // Linux: put_shm_seq(priv, tail) — device checks this before processing command.
    // Without it, device skips commands for slot > 0 (slot 0 works because initial
    // value is 0, coincidentally matching the expected sequence number).
    writeBe32(bar0 + SHM_OFFSET + slot * 4, @truncate(slot));

    // Print event counter before doorbell
    const event_before = readBe32(bar0 + REG_ADMINQ_EVENT_COUNTER);

    // Increment producer and ring doorbell
    aq_prod += 1;
    writeBe32(bar0 + REG_ADMINQ_DOORBELL, aq_prod);

    uart.print("[gvnic] AQ slot={} prod={} event_before={}\n", .{ slot, aq_prod, event_before });

    // Poll for completion (timeout ~100ms at ~1GHz)
    var spin: u32 = 0;
    while (spin < 10_000_000) : (spin += 1) {
        const event = readBe32(bar0 + REG_ADMINQ_EVENT_COUNTER);
        if (event >= aq_prod) {
            uart.print("[gvnic] AQ complete: event={} spins={}\n", .{ event, spin });

            // Invalidate cache for DMA-written response
            dmaInvalidateRange(@intFromPtr(aq_buf) + offset, @sizeOf(AdminCmd));

            // Dump full 64-byte slot as 16 x u32 words
            uart.writeString("[gvnic] AQ slot: ");
            const slot_base = @intFromPtr(aq_buf) + offset;
            var si: usize = 0;
            while (si < 64) : (si += 4) {
                const wp: *volatile u32 = @ptrFromInt(slot_base + si);
                uart.writeHex(@byteSwap(wp.*));
                uart.writeString(" ");
            }
            uart.writeString("\n");

            // Read status from the slot via volatile (big-endian u32 at offset 4)
            const status_ptr: *volatile u32 = @ptrFromInt(@intFromPtr(aq_buf) + offset + 4);
            const status = @byteSwap(status_ptr.*);
            if (status == 1) {
                return true;
            }
            uart.print("[gvnic] AQ cmd {x} failed: status={x}\n", .{ @byteSwap(cmd.opcode), status });
            return false;
        }
        asm volatile ("yield");
    }
    uart.print("[gvnic] AQ cmd {x} timeout (event={} wanted={})\n", .{
        @byteSwap(cmd.opcode),
        readBe32(bar0 + REG_ADMINQ_EVENT_COUNTER),
        aq_prod,
    });
    return false;
}

fn aqVerifyDriver() bool {
    // Allocate DMA buffer for gve_driver_info struct
    const info_dma = allocDmaPage();
    const d = info_dma.virt;

    // gve_driver_info layout (newer GCE firmware uses GVE_VERSION_STR_LEN=128):
    //   0: os_type (u8) — 1=Linux
    //   1: driver_major (u8)
    //   2: driver_minor (u8)
    //   3: driver_sub (u8)
    //   4: os_version_major1 (be32)
    //   8: os_version_major2 (be32)
    //  12: os_version_minor (be32)
    //  16: driver_capability_flags[4] (4 x be64, 32 bytes)
    //  48: os_type_str[128]
    // 176: driver_version_str[128]
    // Total: 304 bytes
    d[0] = 1; // os_type = Linux
    d[1] = 1; // driver_major
    d[2] = 4; // driver_minor (match recent Linux gVNIC driver ~1.4.x)
    d[3] = 0; // driver_sub
    // os_version = 6.8.0 (recent Linux kernel)
    d[4] = 0; d[5] = 0; d[6] = 0; d[7] = 6; // os_version_major1 = 6
    d[8] = 0; d[9] = 0; d[10] = 0; d[11] = 8; // os_version_major2 = 8
    // driver_capability_flags[0] at offset 16 (be64):
    // Linux enum gve_driver_capability:
    //   bit 0 = GQI_QPL, bit 1 = GQI_RDA, bit 2 = DQO_QPL, bit 3 = DQO_RDA
    //   bit 4 = ALT_MISS_COMPL, bit 5 = FLEXIBLE_BUFFER_SIZE
    const cap_flags: u64 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5);
    d[16] = @truncate(cap_flags >> 56);
    d[17] = @truncate(cap_flags >> 48);
    d[18] = @truncate(cap_flags >> 40);
    d[19] = @truncate(cap_flags >> 32);
    d[20] = @truncate(cap_flags >> 24);
    d[21] = @truncate(cap_flags >> 16);
    d[22] = @truncate(cap_flags >> 8);
    d[23] = @truncate(cap_flags);
    // os_type_str at offset 48 (128 bytes): "Linux"
    d[48] = 'L'; d[49] = 'i'; d[50] = 'n'; d[51] = 'u'; d[52] = 'x';
    // driver_version_str at offset 176 (128 bytes): "1.4.0"
    d[176] = '1'; d[177] = '.'; d[178] = '4'; d[179] = '.'; d[180] = '0';

    // Clean cache so device can read driver_info via DMA
    dmaCleanRange(@intFromPtr(d), 304);

    // Debug: dump first 24 bytes of driver_info
    uart.writeString("[gvnic] driver_info: ");
    var di: usize = 0;
    while (di < 24) : (di += 1) {
        uart.writeHex(@as(u32, d[di]));
        uart.writeString(" ");
    }
    uart.writeString("\n");

    var cmd: AdminCmd = .{ .opcode = @byteSwap(@as(u32, AQ_VERIFY_DRIVER)), .status = 0, .payload = .{0} ** 56 };
    // Linux: struct gve_adminq_verify_driver_compatibility {
    //   __be64 driver_info_len;   // offset 0
    //   __be64 driver_info_addr;  // offset 8
    // };
    writeBe64InPayload(&cmd.payload, 0, 304); // driver_info_len = sizeof(gve_driver_info) with 128-byte strings
    writeBe64InPayload(&cmd.payload, 8, info_dma.phys); // driver_info_addr
    return aqSubmit(&cmd);
}

fn aqDescribeDevice() bool {
    // Allocate DMA buffer for device descriptor
    const desc_dma = allocDmaPage();

    var cmd: AdminCmd = .{ .opcode = @byteSwap(@as(u32, AQ_DESCRIBE_DEVICE)), .status = 0, .payload = .{0} ** 56 };
    // payload[0:8] = device_descriptor_addr (be64)
    const addr = desc_dma.phys;
    cmd.payload[0] = @truncate(addr >> 56);
    cmd.payload[1] = @truncate(addr >> 48);
    cmd.payload[2] = @truncate(addr >> 40);
    cmd.payload[3] = @truncate(addr >> 32);
    cmd.payload[4] = @truncate(addr >> 24);
    cmd.payload[5] = @truncate(addr >> 16);
    cmd.payload[6] = @truncate(addr >> 8);
    cmd.payload[7] = @truncate(addr);
    // payload[8:12] = version (be32) = 1
    cmd.payload[11] = 1;
    // payload[12:16] = available_length (be32) = 4096
    cmd.payload[14] = @truncate(PAGE_SIZE >> 8);
    cmd.payload[15] = @truncate(PAGE_SIZE);

    if (!aqSubmit(&cmd)) {
        // Even on "failure" (status=0), check if device wrote descriptor data
        dmaInvalidateRange(@intFromPtr(desc_dma.virt), PAGE_SIZE);
        const d0 = desc_dma.virt;
        uart.writeString("[gvnic] Desc buf check: ");
        var ci: usize = 0;
        while (ci < 32) : (ci += 1) {
            uart.writeHex(@as(u32, d0[ci]));
            uart.writeString(" ");
        }
        uart.writeString("\n");
        // If descriptor has data (non-zero), the device DID process it
        // Check for tx_queue_entries at offset 10 (should be non-zero)
        const check_tx = @as(u16, d0[10]) << 8 | d0[11];
        if (check_tx > 0) {
            uart.writeString("[gvnic] Descriptor has data despite status=0, continuing\n");
        } else {
            return false;
        }
    } else {
        // Invalidate cache for device-written descriptor buffer
        dmaInvalidateRange(@intFromPtr(desc_dma.virt), PAGE_SIZE);
    }

    // Parse device descriptor (gve_device_descriptor layout):
    //   0: max_registered_pages (be64)
    //   8: reserved (be16)
    //  10: tx_queue_entries (be16)
    //  12: rx_queue_entries (be16)
    //  14: default_num_queues (be16)
    //  16: mtu (be16)
    //  18: counters (be16)
    //  20: tx_pages_per_qpl (be16)
    //  22: rx_pages_per_qpl (be16)
    //  24: mac[6]
    //  30: num_device_options (be16)
    //  32: total_length (be16)
    //  34: reserved2[6]
    //  40: device options start
    const d = desc_dma.virt;

    tx_queue_entries = @as(u16, d[10]) << 8 | d[11];
    rx_queue_entries = @as(u16, d[12]) << 8 | d[13];
    default_num_queues = @as(u16, d[14]) << 8 | d[15];
    mtu = @as(u16, d[16]) << 8 | d[17];
    num_counters = @as(u16, d[18]) << 8 | d[19];

    mac[0] = d[24];
    mac[1] = d[25];
    mac[2] = d[26];
    mac[3] = d[27];
    mac[4] = d[28];
    mac[5] = d[29];

    const num_options = @as(u16, d[30]) << 8 | d[31];

    uart.writeString("[gvnic] MAC: ");
    printMac(&mac);
    uart.writeByte('\n');
    uart.print("[gvnic] MTU={} queues={} tx_entries={} rx_entries={} counters={}\n", .{
        mtu, default_num_queues, tx_queue_entries, rx_queue_entries, num_counters,
    });

    // Parse device options to negotiate queue format
    // Each option: option_id(be16) + option_length(be16) + required_features_mask(be32) + data
    // GVE_DEV_OPT_ID_DQO_RDA = 0x0004 (from Linux gve_adminq.h)
    const DEV_OPT_DQO_RDA: u16 = 0x0004;
    queue_format = 0; // Default: GQI (legacy)
    var opt_offset: usize = 40; // Device options start after fixed descriptor
    var opts_parsed: u16 = 0;
    while (opts_parsed < num_options and opt_offset + 8 <= PAGE_SIZE) : (opts_parsed += 1) {
        const opt_id = @as(u16, d[opt_offset]) << 8 | d[opt_offset + 1];
        const opt_len = @as(u16, d[opt_offset + 2]) << 8 | d[opt_offset + 3];
        uart.print("[gvnic] Device option: id={x} len={}\n", .{ opt_id, opt_len });
        if (opt_id == DEV_OPT_DQO_RDA) {
            queue_format = QUEUE_FORMAT_DQO_RDA;
            uart.writeString("[gvnic] DQO RDA queue format supported\n");
        }
        // Advance past option header (8 bytes) + option data (opt_len bytes)
        opt_offset += 8 + @as(usize, opt_len);
    }
    if (queue_format == 0) {
        uart.writeString("[gvnic] WARNING: DQO RDA not in device options, trying anyway\n");
        queue_format = QUEUE_FORMAT_DQO_RDA;
    }

    return true;
}

fn aqConfigureResources() bool {
    const actual_counters: u32 = if (num_counters > 0) @as(u32, num_counters) else 2;

    // CONFIGURE_RESOURCES passes with 0 ntfy_blks. The issue is in the
    // notification block parameters. Try both msix_base_idx values.
    const num_ntfy_blks: u32 = if (msix_num_vectors >= 3) 2 else 0;

    uart.print("[gvnic] Configuring: counters={} ntfy_blks={} msix_vecs={} format={x}\n", .{ actual_counters, num_ntfy_blks, msix_num_vectors, queue_format });

    // Allocate counter array (4 bytes per counter)
    const counter_dma = allocDmaPage();
    counter_array = @ptrCast(@alignCast(counter_dma.virt));
    counter_array_phys = counter_dma.phys;

    // Allocate IRQ doorbell index array — cacheline-aligned entries.
    // Linux: struct gve_irq_db { __be32 index; } ____cacheline_aligned;
    // sizeof(struct gve_irq_db) = 64 bytes (one cache line), NOT 4.
    // The device writes doorbell indices into this host DMA memory.
    const irq_db_dma = allocDmaPage();
    irq_db_indices = @ptrCast(@alignCast(irq_db_dma.virt));
    irq_db_phys = irq_db_dma.phys;

    // Linux struct gve_adminq_configure_device_resources:
    //   0: counter_array (be64) - DMA addr of counter array
    //   8: irq_db_addr (be64) - DMA addr of IRQ doorbell index array
    //  16: num_counters (be32)
    //  20: num_irq_dbs (be32) — number of notification blocks
    //  24: irq_db_stride (be32) - sizeof(struct gve_irq_db) = 64 (cacheline)
    //  28: ntfy_blk_msix_base_idx (be32) - 0 (ntfy blocks at vectors 0..N-1, mgmt at N)
    //  32: queue_format (u8)
    const irq_db_stride: u32 = 64; // cacheline-aligned struct gve_irq_db
    var cmd: AdminCmd = .{ .opcode = @byteSwap(@as(u32, AQ_CONFIGURE_RESOURCES)), .status = 0, .payload = .{0} ** 56 };
    writeBe64InPayload(&cmd.payload, 0, counter_array_phys);
    if (num_ntfy_blks > 0) {
        writeBe64InPayload(&cmd.payload, 8, irq_db_phys);
        writeBe32InPayload(&cmd.payload, 20, num_ntfy_blks);
        writeBe32InPayload(&cmd.payload, 24, irq_db_stride);
        writeBe32InPayload(&cmd.payload, 28, 0); // GVE_NTFY_BLK_BASE_MSIX_IDX = 0
        uart.print("[gvnic] irq_db_addr={x} stride={} num={} msix_base=0\n", .{ irq_db_phys, irq_db_stride, num_ntfy_blks });
    }
    writeBe32InPayload(&cmd.payload, 16, actual_counters);
    cmd.payload[32] = queue_format;

    return aqSubmit(&cmd);
}

fn aqCreateTxQueue() bool {
    // Use device-reported queue size (from DESCRIBE_DEVICE)
    const ring_size = tx_queue_entries;
    uart.print("[gvnic] Creating TX queue: ring_size={}\n", .{ring_size});

    // Allocate TX descriptor ring (16 bytes per descriptor)
    const ring_bytes = @as(usize, ring_size) * @sizeOf(TxPktDesc);
    const ring_pages = (ring_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    const ring_dma = allocDmaPages(ring_pages);
    tx_ring = @ptrCast(@alignCast(ring_dma.virt));
    tx_ring_phys = ring_dma.phys;

    // Allocate TX completion ring (8 bytes per descriptor)
    const comp_bytes = @as(usize, ring_size) * @sizeOf(TxCompDesc);
    const comp_pages = (comp_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    const comp_dma = allocDmaPages(comp_pages);
    tx_comp_ring = @ptrCast(@alignCast(comp_dma.virt));
    tx_comp_phys = comp_dma.phys;

    // Allocate queue resources (device writes doorbell index here)
    const res_dma = allocDmaPage();
    tx_res = @ptrCast(@alignCast(res_dma.virt));
    tx_res_phys = res_dma.phys;

    // TX bounce buffer (single packet)
    const buf_dma = allocDmaPage();
    tx_buf_virt = buf_dma.virt;
    tx_buf_phys = buf_dma.phys;

    var cmd: AdminCmd = .{ .opcode = @byteSwap(@as(u32, AQ_CREATE_TX_QUEUE)), .status = 0, .payload = .{0} ** 56 };
    // payload[0:4] = queue_id (be32) = 0
    writeBe32InPayload(&cmd.payload, 0, 0);
    // payload[4:8] = reserved = 0
    // payload[8:16] = queue_resources_addr (be64)
    writeBe64InPayload(&cmd.payload, 8, tx_res_phys);
    // payload[16:24] = tx_ring_addr (be64)
    writeBe64InPayload(&cmd.payload, 16, tx_ring_phys);
    // payload[24:28] = queue_page_list_id (be32) = 0xFFFFFFFF (RDA mode)
    writeBe32InPayload(&cmd.payload, 24, 0xFFFFFFFF);
    // payload[28:32] = ntfy_id (be32) = 0
    writeBe32InPayload(&cmd.payload, 28, 0);
    // payload[32:40] = tx_comp_ring_addr (be64)
    writeBe64InPayload(&cmd.payload, 32, tx_comp_phys);
    // payload[40:42] = tx_ring_size (be16) — use device-reported size
    cmd.payload[40] = @truncate(ring_size >> 8);
    cmd.payload[41] = @truncate(ring_size);
    // payload[42:44] = tx_comp_ring_size (be16) — same as ring_size
    cmd.payload[42] = @truncate(ring_size >> 8);
    cmd.payload[43] = @truncate(ring_size);

    if (!aqSubmit(&cmd)) return false;

    // Read doorbell index (big-endian from device)
    dmaInvalidateRange(@intFromPtr(tx_res), @sizeOf(QueueResources));
    tx_db_index = @byteSwap(tx_res.db_index);
    actual_tx_ring_size = tx_queue_entries;
    actual_tx_comp_size = tx_queue_entries;
    uart.print("[gvnic] TX queue created, doorbell={}\n", .{tx_db_index});
    return true;
}

fn aqCreateRxQueue() bool {
    // Use device-reported queue size
    const ring_size = rx_queue_entries;
    uart.print("[gvnic] Creating RX queue: ring_size={}\n", .{ring_size});

    // Allocate RX buffer descriptor ring (32 bytes per descriptor)
    const buf_bytes = @as(usize, ring_size) * @sizeOf(RxBufDesc);
    const buf_pages = (buf_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    const buf_dma = allocDmaPages(buf_pages);
    rx_buf_ring = @ptrCast(@alignCast(buf_dma.virt));
    rx_buf_ring_phys = buf_dma.phys;

    // Allocate RX completion ring (32 bytes per descriptor, GCE DQO format)
    const comp_bytes = @as(usize, ring_size) * @sizeOf(RxCompDesc);
    const comp_pages = (comp_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    const comp_dma = allocDmaPages(comp_pages);
    rx_comp_ring = @ptrCast(@alignCast(comp_dma.virt));
    rx_comp_phys = comp_dma.phys;

    // Queue resources
    const res_dma = allocDmaPage();
    rx_res = @ptrCast(@alignCast(res_dma.virt));
    rx_res_phys = res_dma.phys;

    // Linux struct gve_adminq_create_rx_queue:
    //   0: queue_id (be32)
    //   4: index (be32)
    //   8: reserved (be32)
    //  12: ntfy_id (be32)
    //  16: queue_resources_addr (be64)
    //  24: rx_desc_ring_addr (be64) — DQO: COMPLETION ring (complq.bus)
    //  32: rx_data_ring_addr (be64) — DQO: BUFFER POSTING ring (bufq.bus)
    //  40: queue_page_list_id (be32)
    //  44: rx_ring_size (be16) — DQO: completion ring size
    //  46: packet_buffer_size (be16)
    //  48: rx_buff_ring_size (be16) — DQO: buffer posting ring size (rx_desc_cnt)
    //  50: enable_rsc (u8)
    //
    // CRITICAL: In DQO mode, the field semantics are SWAPPED from their GQI names!
    //   rx_desc_ring_addr = completion queue (NOT descriptors)
    //   rx_data_ring_addr = buffer queue (NOT data ring)
    var cmd: AdminCmd = .{ .opcode = @byteSwap(@as(u32, AQ_CREATE_RX_QUEUE)), .status = 0, .payload = .{0} ** 56 };
    writeBe32InPayload(&cmd.payload, 0, 0); // queue_id = 0
    // index = 0 (payload[4:8])
    // ntfy_id = 1 (RX gets second notification block; TX gets 0)
    writeBe32InPayload(&cmd.payload, 12, 1);
    writeBe64InPayload(&cmd.payload, 16, rx_res_phys);
    writeBe64InPayload(&cmd.payload, 24, rx_comp_phys); // DQO: completion ring
    writeBe64InPayload(&cmd.payload, 32, rx_buf_ring_phys); // DQO: buffer posting ring
    writeBe32InPayload(&cmd.payload, 40, 0xFFFFFFFF); // RDA mode
    // rx_ring_size = completion ring size (DQO)
    cmd.payload[44] = @truncate(ring_size >> 8);
    cmd.payload[45] = @truncate(ring_size);
    // packet_buffer_size = 2048
    cmd.payload[46] = @truncate(RX_BUF_SIZE >> 8);
    cmd.payload[47] = @truncate(RX_BUF_SIZE);
    // rx_buff_ring_size = buffer posting ring size (DQO: priv->rx_desc_cnt)
    cmd.payload[48] = @truncate(ring_size >> 8);
    cmd.payload[49] = @truncate(ring_size);

    if (!aqSubmit(&cmd)) return false;

    dmaInvalidateRange(@intFromPtr(rx_res), @sizeOf(QueueResources));
    rx_db_index = @byteSwap(rx_res.db_index);
    actual_rx_buf_size = rx_queue_entries;
    actual_rx_comp_size = rx_queue_entries;
    uart.print("[gvnic] RX queue created, doorbell={}\n", .{rx_db_index});
    return true;
}

fn postRxBuffers() void {
    // Allocate DMA buffers and post to RX buffer descriptor ring
    var i: u16 = 0;
    while (i < NUM_RX_BUFS) : (i += 1) {
        const buf = allocDmaPage();
        rx_bufs_phys[i] = buf.phys;
        rx_bufs_virt[i] = buf.virt;

        rx_buf_ring[rx_buf_tail].buf_id = i;
        rx_buf_ring[rx_buf_tail].buf_addr = buf.phys;
        rx_buf_ring[rx_buf_tail].header_buf_addr = 0;
        rx_buf_ring[rx_buf_tail].reserved0 = 0;
        rx_buf_ring[rx_buf_tail].reserved1 = 0;
        rx_buf_ring[rx_buf_tail].reserved2 = 0;

        rx_buf_tail = (rx_buf_tail + 1) % actual_rx_buf_size;
    }

    // Dump first RX buffer descriptor for debugging
    uart.print("[gvnic] RX buf[0]: id={} addr={x} hdr={x}\n", .{
        rx_buf_ring[0].buf_id, rx_buf_ring[0].buf_addr, rx_buf_ring[0].header_buf_addr,
    });

    // Flush buffer ring to make descriptors visible to device
    dmaFlushRange(@intFromPtr(rx_buf_ring), @as(usize, rx_buf_tail) * @sizeOf(RxBufDesc));

    // Ring RX doorbell
    writeDb32(rx_db_index, rx_buf_tail);
    uart.print("[gvnic] {} RX buffers posted, tail={} db={x}\n", .{ NUM_RX_BUFS, rx_buf_tail, rx_db_index });
}

// ---- Notification block interrupt enable ----

// DQO IRQ doorbell register bits
const GVE_ITR_ENABLE_BIT_DQO: u32 = 1 << 0;
const GVE_ITR_CLEAR_PBA_BIT_DQO: u32 = 1 << 1;
const GVE_ITR_NO_UPDATE_DQO: u32 = 3 << 3;

fn enableNotifyBlockIrqs() void {
    const num_ntfy_blks: u32 = if (msix_num_vectors >= 3) 2 else 0;

    // Invalidate the irq_db_indices DMA buffer — device wrote indices here
    dmaInvalidateRange(@intFromPtr(irq_db_indices), num_ntfy_blks * 64);

    var i: u32 = 0;
    while (i < num_ntfy_blks) : (i += 1) {
        // Each entry is 64 bytes (cacheline-aligned); first 4 bytes = __be32 index
        const entry_ptr: [*]const u8 = @ptrCast(irq_db_indices);
        const byte_off = i * 64;
        const db_idx_be = @as(u32, entry_ptr[byte_off]) << 24 |
            @as(u32, entry_ptr[byte_off + 1]) << 16 |
            @as(u32, entry_ptr[byte_off + 2]) << 8 |
            @as(u32, entry_ptr[byte_off + 3]);

        // Write ITR enable with 20us coalesce interval for RX, 50us for TX
        // Interval in 2us units, shifted left by 5
        const interval_us: u32 = if (i == 0) 50 / 2 else 20 / 2; // TX=0, RX=1
        const itr_val = GVE_ITR_ENABLE_BIT_DQO | GVE_ITR_CLEAR_PBA_BIT_DQO |
            ((interval_us & 0xFFF) << 5);

        uart.print("[gvnic] Ntfy blk {}: irq_db_idx={} itr_val={x}\n", .{ i, db_idx_be, itr_val });

        // Write to BAR2 doorbell
        writeDb32(db_idx_be, itr_val);
    }
}

/// Re-arm notification block interrupt after handling (call from IRQ handler)
fn rearmNotifyBlock(ntfy_id: u32) void {
    const entry_ptr: [*]const u8 = @ptrCast(irq_db_indices);
    const byte_off = ntfy_id * 64;
    const db_idx_be = @as(u32, entry_ptr[byte_off]) << 24 |
        @as(u32, entry_ptr[byte_off + 1]) << 16 |
        @as(u32, entry_ptr[byte_off + 2]) << 8 |
        @as(u32, entry_ptr[byte_off + 3]);
    writeDb32(db_idx_be, GVE_ITR_NO_UPDATE_DQO | GVE_ITR_ENABLE_BIT_DQO);
}

// ---- Payload helpers (big-endian writes into byte arrays) ----

fn writeBe32InPayload(payload: *[56]u8, offset: usize, value: u32) void {
    payload[offset] = @truncate(value >> 24);
    payload[offset + 1] = @truncate(value >> 16);
    payload[offset + 2] = @truncate(value >> 8);
    payload[offset + 3] = @truncate(value);
}

fn writeBe64InPayload(payload: *[56]u8, offset: usize, value: u64) void {
    payload[offset] = @truncate(value >> 56);
    payload[offset + 1] = @truncate(value >> 48);
    payload[offset + 2] = @truncate(value >> 40);
    payload[offset + 3] = @truncate(value >> 32);
    payload[offset + 4] = @truncate(value >> 24);
    payload[offset + 5] = @truncate(value >> 16);
    payload[offset + 6] = @truncate(value >> 8);
    payload[offset + 7] = @truncate(value);
}

// ---- Public interface (same as virtio-net / rtl8126) ----

/// Initialize gVNIC from PCI device. Returns true on success.
pub fn init(dev: *const pci.PciDevice, bar2_addr: u64) bool {
    bar0 = @truncate(dev.bar0);
    bar2 = @truncate(bar2_addr);

    if (bar0 == 0 or bar2 == 0) {
        uart.writeString("[gvnic] Missing BAR0 or BAR2\n");
        return false;
    }

    uart.print("[gvnic] BAR0={x} BAR2={x}\n", .{ bar0, bar2 });

    // Check device status
    const status = readBe32(bar0 + REG_DEVICE_STATUS);
    uart.print("[gvnic] Device status: {x}\n", .{status});

    // Read max queues
    const max_tx = readBe32(bar0 + REG_MAX_TX_QUEUES);
    const max_rx = readBe32(bar0 + REG_MAX_RX_QUEUES);
    uart.print("[gvnic] Max queues: TX={} RX={}\n", .{ max_tx, max_rx });

    // Setup admin queue
    const aq_dma = allocDmaPage();
    aq_buf = @ptrCast(@alignCast(aq_dma.virt));
    aq_phys = aq_dma.phys;
    aq_prod = 0;

    // Write driver version byte (Linux: gve_write_version, required before AQ setup)
    const ver_ptr: *volatile u8 = @ptrFromInt(bar0 + REG_DRIVER_VERSION);
    ver_ptr.* = 1; // GVE_DRIVER_VERSION_BYTE = 1
    asm volatile ("dmb sy" ::: .{ .memory = true });

    // Check PCI revision to choose AQ setup path
    const pci_rev = pci.configRead8(dev.bus, dev.device, dev.function, 0x08);
    uart.print("[gvnic] PCI revision: {x}\n", .{pci_rev});

    // Admin queue entry count (not byte size!)
    // Linux: num_entries = PAGE_SIZE / sizeof(union gve_adminq_command) = 4096/64 = 64
    const aq_num_entries: u16 = @truncate(PAGE_SIZE / @sizeOf(AdminCmd));

    // Try PFN-only path first — signals device to use the AQ at this PFN.
    // Modern path (base+length) may not work on all firmware revisions.
    uart.print("[gvnic] AQ phys={x} PFN={x}\n", .{ aq_phys, aq_phys / PAGE_SIZE });
    writeBe32(bar0 + REG_ADMINQ_PFN, @truncate(aq_phys / PAGE_SIZE));

    // Also write modern registers in case firmware uses them
    writeBe32(bar0 + REG_ADMINQ_BASE_HI, @truncate(aq_phys >> 32));
    writeBe32(bar0 + REG_ADMINQ_BASE_LO, @truncate(aq_phys));
    writeBe32(bar0 + REG_ADMINQ_LENGTH, @as(u32, aq_num_entries) << 16);

    // Signal driver running AFTER all AQ registers are set
    writeBe32(bar0 + REG_DRIVER_STATUS, DRIVER_RUN);

    // Read back registers to verify
    const aq_pfn_rb = readBe32(bar0 + REG_ADMINQ_PFN);
    const aq_len_rb = readBe32(bar0 + REG_ADMINQ_LENGTH);
    uart.print("[gvnic] AQ readback: PFN={x} len_reg={x}\n", .{ aq_pfn_rb, aq_len_rb });

    // Verify driver compatibility (required before DESCRIBE_DEVICE on GCE firmware)
    if (!aqVerifyDriver()) {
        uart.writeString("[gvnic] VERIFY_DRIVER failed\n");
        return false;
    }

    // Describe device (get MAC, MTU, queue sizes)
    if (!aqDescribeDevice()) {
        uart.writeString("[gvnic] DESCRIBE_DEVICE failed\n");
        return false;
    }

    // Initialize GICv3 ITS for MSI-X interrupt delivery (before MSI-X setup)
    if (!gicv3.initIts()) {
        uart.writeString("[gvnic] WARNING: ITS init failed, MSI-X may not deliver interrupts\n");
    }

    // Enable PCI MSI-X (required for notification blocks → queue creation)
    const nvecs = setupMsix(dev);
    if (nvecs == 0) {
        uart.writeString("[gvnic] WARNING: MSI-X setup failed, queue creation may fail\n");
    }

    // Map MSI-X vectors to LPIs via ITS
    if (nvecs > 0 and gicv3.translater_addr != 0) {
        const pci_rid = (@as(u32, dev.bus) << 8) | (@as(u32, dev.device) << 3) | @as(u32, dev.function);
        const first_lpi = gicv3.mapDevice(pci_rid, nvecs);
        if (first_lpi != 0) {
            irq = first_lpi; // Use first LPI as the IRQ for this device
            uart.print("[gvnic] IRQ set to LPI {}\n", .{irq});
        }
    }

    // Configure resources (counters, IRQ doorbells, queue format)
    if (!aqConfigureResources()) {
        uart.writeString("[gvnic] CONFIGURE_RESOURCES failed\n");
        return false;
    }

    // Create TX queue
    if (!aqCreateTxQueue()) {
        uart.writeString("[gvnic] CREATE_TX_QUEUE failed\n");
        return false;
    }

    // Create RX queue
    if (!aqCreateRxQueue()) {
        uart.writeString("[gvnic] CREATE_RX_QUEUE failed\n");
        return false;
    }

    // Post initial RX buffers
    postRxBuffers();

    // Enable notification block interrupts (CRITICAL — without this, no RX)
    // The device wrote IRQ doorbell indices into irq_db_indices DMA buffer
    // during CONFIGURE_RESOURCES. We need to read those indices and write
    // to BAR2[index] with GVE_ITR_ENABLE_BIT_DQO (bit 0) set.
    enableNotifyBlockIrqs();

    // Check link
    const link_status = readBe32(bar0 + REG_DEVICE_STATUS);
    if (link_status & STATUS_LINK_UP != 0) {
        uart.writeString("[gvnic] Link is UP\n");
    } else {
        uart.writeString("[gvnic] Link is DOWN (will poll)\n");
    }

    // IRQ: if ITS mapped LPIs, use those (set in line above).
    // Otherwise fall back to legacy PCI INTA SPI mapping.
    if (irq == 0) {
        irq = 32 + 3; // SPI 3 for INTA, base offset 32 for SPI numbering
    }
    uart.print("[gvnic] Using IRQ {} (LPI={})\n", .{ irq, @as(u8, if (irq >= 8192) 1 else 0) });

    initialized = true;
    uart.writeString("[gvnic] Initialized (MAC ");
    printMac(&mac);
    uart.writeString(")\n");

    return true;
}

pub fn isInitialized() bool {
    return initialized;
}

/// Transmit a raw Ethernet frame (no virtio header needed).
var tx_log_count: u32 = 0;
pub fn transmit(data: []const u8) bool {
    if (!initialized) return false;
    if (data.len > PAGE_SIZE or data.len == 0) return false;

    // Copy frame to TX DMA bounce buffer
    for (0..data.len) |i| tx_buf_virt[i] = data[i];

    // Build TX packet descriptor
    const idx = tx_tail;
    tx_ring[idx] = .{
        .buf_addr = tx_buf_phys,
        .dtype_flags = TX_DESC_DTYPE_PKT | (1 << 5) | (1 << 7), // dtype=0x0C, eop=1, report=1
        .reserved = 0,
        .compl_tag = idx,
        .buf_size = @truncate(data.len),
    };

    tx_tail = (tx_tail + 1) % actual_tx_ring_size;

    // Flush TX descriptor and bounce buffer to make visible to device
    dmaFlushRange(@intFromPtr(&tx_ring[idx]), @sizeOf(TxPktDesc));
    dmaFlushRange(@intFromPtr(tx_buf_virt), data.len);

    // Ring TX doorbell
    writeDb32(tx_db_index, tx_tail);

    if (tx_log_count < 3) {
        uart.print("[gvnic] TX: len={}\n", .{data.len});
    }

    // Poll for TX completion (synchronous for simplicity)
    var spin: u32 = 0;
    while (spin < 1_000_000) : (spin += 1) {
        dmaInvalidateRange(@intFromPtr(&tx_comp_ring[tx_comp_head]), @sizeOf(TxCompDesc));
        const comp = tx_comp_ring[tx_comp_head];
        const gen: u1 = @truncate((comp.id_type_gen >> 15) & 1);
        if (gen != tx_comp_gen) {
            // New completion
            tx_comp_head = (tx_comp_head + 1) % actual_tx_comp_size;
            if (tx_comp_head == 0) tx_comp_gen ^= 1;
            if (tx_log_count < 3) {
                tx_log_count += 1;
            }
            return true;
        }
        asm volatile ("yield");
    }

    if (tx_log_count < 3) {
        uart.writeString("[gvnic] TX TIMEOUT\n");
        tx_log_count += 1;
    }
    return false; // TX timeout
}

/// Dequeue a received packet from the kernel ring.
pub fn receive() ?struct { data: []const u8 } {
    if (rx_ring_head == rx_ring_tail) return null;
    const idx = rx_ring_tail % RX_RING_SLOTS;
    return .{ .data = rx_ring[idx][0..rx_ring_len[idx]] };
}

/// Advance RX ring tail after processing.
pub fn receiveConsume() void {
    rx_ring_tail +%= 1;
}

/// Check and log RX queue state (call from polling loop for debugging)
pub fn logRxState() void {}

/// IRQ handler — process RX completions from DQO completion ring.
pub fn handleIrq() void {
    var processed: u32 = 0;
    while (processed < 32) : (processed += 1) {
        dmaInvalidateRange(@intFromPtr(&rx_comp_ring[rx_comp_head]), @sizeOf(RxCompDesc));
        const comp = rx_comp_ring[rx_comp_head];
        const gen: u1 = @truncate((comp.pktlen_gen >> 14) & 1);

        if (gen == rx_comp_gen) break; // No new completion

        const pkt_len: u16 = comp.pktlen_gen & 0x3FFF;
        const buf_id = comp.buf_id;

        if (pkt_len > 0 and pkt_len <= MAX_PKT_SIZE and buf_id < NUM_RX_BUFS) {
            // Copy packet to kernel ring
            const ring_idx = rx_ring_head % RX_RING_SLOTS;
            const src = rx_bufs_virt[buf_id];
            for (0..pkt_len) |i| rx_ring[ring_idx][i] = src[i];
            rx_ring_len[ring_idx] = pkt_len;
            rx_ring_head +%= 1;

            // Repost the buffer to the RX buffer ring
            rx_buf_ring[rx_buf_tail].buf_id = buf_id;
            rx_buf_ring[rx_buf_tail].buf_addr = rx_bufs_phys[buf_id];
            rx_buf_ring[rx_buf_tail].header_buf_addr = 0;
            rx_buf_ring[rx_buf_tail].reserved0 = 0;
            rx_buf_ring[rx_buf_tail].reserved1 = 0;
            rx_buf_ring[rx_buf_tail].reserved2 = 0;
            rx_buf_tail = (rx_buf_tail + 1) % actual_rx_buf_size;
        }

        // Advance completion head
        rx_comp_head = (rx_comp_head + 1) % actual_rx_comp_size;
        if (rx_comp_head == 0) rx_comp_gen ^= 1;
    }

    // Flush and ring RX buffer doorbell to repost buffers
    if (processed > 0) {
        dmaFlushRange(@intFromPtr(rx_buf_ring), @as(usize, actual_rx_buf_size) * @sizeOf(RxBufDesc));
        writeDb32(rx_db_index, rx_buf_tail);
    }

    // Re-arm notification blocks (unconditional, as in original working code)
    rearmNotifyBlock(1); // RX
    rearmNotifyBlock(0); // TX
}
