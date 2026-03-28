/// ARM GICv3 (Generic Interrupt Controller v3) driver — system register interface.
///
/// GICv3 uses system registers (ICC_*_EL1) instead of the MMIO CPU interface
/// used by GICv2. The Distributor (GICD) is still MMIO but at dynamic base.
/// The Redistributor (GICR) handles per-CPU configuration.
///
/// Used when FDT reports compatible = "arm,gic-v3".

const uart = @import("uart.zig");
const fdt = @import("fdt.zig");
const acpi = @import("acpi");
const pmm = @import("pmm.zig");

/// Pin a physical page for DMA/hardware table use by saturating its PMM ref count.
fn pinDmaPage(phys: u64) void {
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        pmm.incRef(phys);
    }
}

/// Pin a contiguous range of physical pages.
fn pinDmaPages(base_phys: u64, num_pages: u64) void {
    var p: u64 = 0;
    while (p < num_pages) : (p += 1) {
        pinDmaPage(base_phys + p * 4096);
    }
}

/// Per-CPU redistributor SGI base addresses (indexed by MPIDR Aff0).
/// Needed because SGI/PPI registers (IRQs 0-31) live in the redistributor,
/// not the distributor. GICv3 distributor bank 0 is RAZ/WI.
const MAX_CPUS = 4;
var cpu_sgi_base: [MAX_CPUS]usize = .{ 0, 0, 0, 0 };

// System register accessors via inline assembly.
// ICC = Interrupt Controller CPU interface, EL1 = Exception Level 1.

/// Enable system register interface (ICC_SRE_EL1.SRE = 1)
fn enableSre() void {
    var sre: u64 = asm volatile ("mrs %[ret], S3_0_C12_C12_5"
        : [ret] "=r" (-> u64),
    );
    sre |= 1; // SRE bit
    asm volatile ("msr S3_0_C12_C12_5, %[val]"
        :
        : [val] "r" (sre),
    );
    asm volatile ("isb");
}

/// Set priority mask (ICC_PMR_EL1) — 0xFF allows all priorities
fn setPriorityMask(mask: u64) void {
    asm volatile ("msr S3_0_C4_C6_0, %[val]"
        :
        : [val] "r" (mask),
    );
}

/// Enable Group 1 interrupts (ICC_IGRPEN1_EL1)
fn enableGroup1() void {
    asm volatile ("msr S3_0_C12_C12_7, %[val]"
        :
        : [val] "r" (@as(u64, 1)),
    );
    asm volatile ("isb");
}

/// Acknowledge interrupt (ICC_IAR1_EL1) — returns interrupt ID
pub fn acknowledge() u32 {
    const val: u64 = asm volatile ("mrs %[ret], S3_0_C12_C12_0"
        : [ret] "=r" (-> u64),
    );
    return @truncate(val & 0xFFFFFF);
}

/// End of interrupt (ICC_EOIR1_EL1)
pub fn endOfInterrupt(irq: u32) void {
    asm volatile ("msr S3_0_C12_C12_1, %[val]"
        :
        : [val] "r" (@as(u64, irq)),
    );
}

/// Initialize GICv3 Distributor (MMIO). Call once from BSP.
pub fn initDistributor() void {
    const gicd_base: usize = @truncate(fdt.config.gicd_base);

    // Disable distributor
    const ctlr_ptr: *volatile u32 = @ptrFromInt(gicd_base);
    ctlr_ptr.* = 0;
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // Read number of interrupt lines
    const typer_ptr: *volatile u32 = @ptrFromInt(gicd_base + 0x004);
    const typer = typer_ptr.*;
    const num_irqs = ((typer & 0x1F) + 1) * 32;

    // Disable all SPIs
    var i: usize = 1; // Skip SGIs/PPIs (bank 0)
    while (i < num_irqs / 32) : (i += 1) {
        const ptr: *volatile u32 = @ptrFromInt(gicd_base + 0x180 + i * 4);
        ptr.* = 0xFFFFFFFF;
    }

    // Set all SPIs to lowest priority
    i = 8;
    while (i < num_irqs / 4) : (i += 1) {
        const ptr: *volatile u32 = @ptrFromInt(gicd_base + 0x400 + i * 4);
        ptr.* = 0xFFFFFFFF;
    }

    // Set all SPIs to Group 1 NS
    i = 1;
    while (i < num_irqs / 32) : (i += 1) {
        const ptr: *volatile u32 = @ptrFromInt(gicd_base + 0x080 + i * 4);
        ptr.* = 0xFFFFFFFF;
    }

    // Enable distributor with ARE (Affinity Routing Enable)
    // Bit 0 = EnableGrp0, Bit 1 = EnableGrp1NS, Bit 4 = ARE_NS
    ctlr_ptr.* = 0x13;
    asm volatile ("dsb sy" ::: .{ .memory = true });

    uart.writeString("[gicv3] Distributor initialized\n");
}

/// Read this CPU's MPIDR affinity value (Aff3:Aff2:Aff1:Aff0).
fn readMpidr() u64 {
    return asm volatile ("mrs %[ret], MPIDR_EL1"
        : [ret] "=r" (-> u64),
    );
}

/// Extract the affinity fields from MPIDR for comparison with GICR_TYPER.
/// MPIDR: Aff3[39:32], Aff2[23:16], Aff1[15:8], Aff0[7:0]
/// GICR_TYPER[63:32] uses the same bit layout as MPIDR[31:0] with Aff3 in [55:48].
fn mpidrAffinity(mpidr: u64) u64 {
    // GICR_TYPER Affinity_Value = Aff3[31:24]:Aff2[23:16]:Aff1[15:8]:Aff0[7:0]
    // MPIDR has Aff3 at [39:32] and Aff2:Aff1:Aff0 at [23:0]
    const aff012: u64 = mpidr & 0x00FFFFFF;
    const aff3: u64 = (mpidr >> 32) & 0xFF;
    return (aff3 << 24) | aff012;
}

/// Walk GICv3 Redistributor frames to find the one matching this CPU's affinity.
/// Each frame is 128KB (64KB RD_base + 64KB SGI_base). Returns RD_base or null.
fn findRedistributor(gicr_region_base: usize) usize {
    const mpidr = readMpidr();
    const cpu_aff = mpidrAffinity(mpidr);

    var frame = gicr_region_base;
    var count: u32 = 0;
    while (count < 64) : (count += 1) { // Safety limit
        // Read GICR_TYPER at offset 0x08 (64-bit, read as two 32-bit halves)
        const typer_lo_ptr: *volatile u32 = @ptrFromInt(frame + 0x08);
        const typer_hi_ptr: *volatile u32 = @ptrFromInt(frame + 0x0C);
        const typer: u64 = (@as(u64, typer_hi_ptr.*) << 32) | @as(u64, typer_lo_ptr.*);

        const gicr_aff: u64 = typer >> 32;
        if (gicr_aff == cpu_aff) return frame;

        // Bit 4 = Last: no more redistributor frames after this one
        if (typer & (1 << 4) != 0) break;

        frame += 0x20000; // Next frame (128KB stride)
    }
    return 0;
}

/// Initialize GICv3 Redistributor for this CPU.
/// Walks redistributor frames to find the correct one via MPIDR affinity matching.
pub fn initRedistributor() void {
    const gicr_region: usize = @truncate(fdt.config.gicr_base);
    if (gicr_region == 0) return;

    const rd_base = findRedistributor(gicr_region);
    if (rd_base == 0) {
        uart.writeString("[gicv3] WARNING: no redistributor found for this CPU\n");
        return;
    }

    // Log which frame we found
    uart.writeString("[gicv3] CPU ");
    uart.writeDec(readMpidr() & 0xFF);
    uart.writeString(" redistributor at 0x");
    uart.writeHex(rd_base);
    uart.writeString("\n");

    // GICR_WAKER: clear ProcessorSleep bit to wake redistributor
    const waker_ptr: *volatile u32 = @ptrFromInt(rd_base + 0x14);
    waker_ptr.* = waker_ptr.* & ~@as(u32, 1 << 1); // Clear ProcessorSleep
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // Wait for ChildrenAsleep to clear
    var timeout: u32 = 0;
    while ((waker_ptr.* & (1 << 2)) != 0 and timeout < 1000000) : (timeout += 1) {
        asm volatile ("yield");
    }

    // SGI base is at RD_base + 0x10000
    const sgi_base: usize = rd_base + 0x10000;

    // Save SGI base for this CPU (used by setPriority/enableIrq for PPIs)
    const cpu_id: usize = @truncate(readMpidr() & 0xFF);
    if (cpu_id < MAX_CPUS) cpu_sgi_base[cpu_id] = sgi_base;

    // Enable all SGIs and PPIs (bank 0)
    const isenabler_ptr: *volatile u32 = @ptrFromInt(sgi_base + 0x100);
    isenabler_ptr.* = 0xFFFFFFFF;

    // Set all SGI/PPI to Group 1
    const igroupr_ptr: *volatile u32 = @ptrFromInt(sgi_base + 0x080);
    igroupr_ptr.* = 0xFFFFFFFF;

    // Set all SGI/PPI to priority 0xA0 (below PMR=0xFF so interrupts are delivered).
    // Priority 0xFF with PMR 0xFF causes 0xFF < 0xFF = false → IRQs silently dropped.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const ptr: *volatile u32 = @ptrFromInt(sgi_base + 0x400 + i * 4);
        ptr.* = 0xA0A0A0A0;
    }

    asm volatile ("dsb sy" ::: .{ .memory = true });
}

/// Initialize GICv3 CPU interface (system registers). Call on each CPU.
pub fn initCpuInterface() void {
    enableSre();
    setPriorityMask(0xFF);
    enableGroup1();
}

/// Full GICv3 init — distributor + redistributor + CPU interface.
pub fn init() void {
    initDistributor();
    initRedistributor();
    initCpuInterface();
    uart.writeString("[gicv3] Initialized (system register interface)\n");
}

/// Enable a specific interrupt. Routes SGIs/PPIs (< 32) through the
/// redistributor and SPIs (>= 32) through the distributor.
pub fn enableIrq(irq: u32) void {
    const reg_index = irq / 32;
    const bit_index: u5 = @intCast(irq % 32);

    if (irq < 32) {
        // SGI/PPI: use redistributor SGI base (GICR_ISENABLER0)
        const cpu_id: usize = @truncate(readMpidr() & 0xFF);
        const sgi_base = if (cpu_id < MAX_CPUS) cpu_sgi_base[cpu_id] else 0;
        if (sgi_base == 0) return;
        const ptr: *volatile u32 = @ptrFromInt(sgi_base + 0x100);
        ptr.* = @as(u32, 1) << bit_index;
    } else {
        // SPI: use distributor (GICD_ISENABLER)
        const gicd_base: usize = @truncate(fdt.config.gicd_base);
        const ptr: *volatile u32 = @ptrFromInt(gicd_base + 0x100 + reg_index * 4);
        ptr.* = @as(u32, 1) << bit_index;
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

/// Set interrupt priority. Routes SGIs/PPIs (< 32) through the
/// redistributor and SPIs (>= 32) through the distributor.
pub fn setPriority(irq: u32, priority: u8) void {
    const reg_index = irq / 4;
    const byte_offset: u5 = @intCast((irq % 4) * 8);

    const base: usize = if (irq < 32) blk: {
        // SGI/PPI: use redistributor SGI base (GICR_IPRIORITYR)
        const cpu_id: usize = @truncate(readMpidr() & 0xFF);
        const sgi_base = if (cpu_id < MAX_CPUS) cpu_sgi_base[cpu_id] else 0;
        if (sgi_base == 0) return;
        break :blk sgi_base;
    } else blk: {
        // SPI: use distributor (GICD_IPRIORITYR)
        break :blk @as(usize, @truncate(fdt.config.gicd_base));
    };

    const ptr: *volatile u32 = @ptrFromInt(base + 0x400 + reg_index * 4);
    const current = ptr.*;
    const mask = ~(@as(u32, 0xFF) << byte_offset);
    ptr.* = (current & mask) | (@as(u32, priority) << byte_offset);
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

/// Send SGI (IPI) to a specific CPU using ICC_SGI1R_EL1.
pub fn sendSGI(target_cpu: u32, sgi_id: u32) void {
    // ICC_SGI1R_EL1 format for GICv3:
    // [3:0]   = Target list (bitmap of PEs in same cluster)
    // [23:16] = INTID (SGI number)
    // [39:32] = Aff1, [47:40] = Aff2, [55:48] = Aff3
    // For simple QEMU virt: Aff1=Aff2=Aff3=0, target in bits[3:0]
    const target_list: u64 = @as(u64, 1) << @as(u6, @truncate(target_cpu));
    const val: u64 = target_list | (@as(u64, sgi_id) << 24);
    asm volatile ("msr S3_0_C12_C11_5, %[val]"
        :
        : [val] "r" (val),
    );
    asm volatile ("isb");
}

// ---- GICv3 ITS (Interrupt Translation Service) for MSI-X ----

// ITS register offsets from ITS base
const GITS_CTLR: usize = 0x0000;
const GITS_TYPER: usize = 0x0008;
const GITS_CBASER: usize = 0x0080;
const GITS_CWRITER: usize = 0x0088;
const GITS_CREADR: usize = 0x0090;
const GITS_BASER0: usize = 0x0100; // Device table BASER
const GITS_TRANSLATER: usize = 0x10040;

// ITS command opcodes (bits [7:0] of command DWORD 0)
const ITS_CMD_MAPD: u8 = 0x08;
const ITS_CMD_MAPC: u8 = 0x09;
const ITS_CMD_MAPTI: u8 = 0x0A;
const ITS_CMD_INV: u8 = 0x0B;
const ITS_CMD_SYNC: u8 = 0x05;

// LPI base interrupt ID
const LPI_BASE: u32 = 8192;

// State
var its_base: usize = 0;
var cmd_queue: usize = 0; // Physical address of 64KB command queue
var cmd_queue_virt: [*]u8 = undefined;
var cmd_write_offset: usize = 0;
var lpi_config_table: usize = 0; // Physical address
var lpi_pending_table: usize = 0; // Physical address
var itt_page: usize = 0; // ITT for device 0
var its_initialized: bool = false;

/// Physical address of GITS_TRANSLATER — MSI-X table entries target this.
pub var translater_addr: u64 = 0;

fn itsWrite32(offset: usize, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(its_base + offset);
    ptr.* = val;
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn itsRead32(offset: usize) u32 {
    asm volatile ("dsb sy" ::: .{ .memory = true });
    const ptr: *volatile u32 = @ptrFromInt(its_base + offset);
    return ptr.*;
}

fn itsWrite64(offset: usize, val: u64) void {
    // Write as two 32-bit halves (some ITS implementations need this)
    const lo_ptr: *volatile u32 = @ptrFromInt(its_base + offset);
    const hi_ptr: *volatile u32 = @ptrFromInt(its_base + offset + 4);
    lo_ptr.* = @truncate(val);
    hi_ptr.* = @truncate(val >> 32);
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn itsRead64(offset: usize) u64 {
    asm volatile ("dsb sy" ::: .{ .memory = true });
    const lo_ptr: *volatile u32 = @ptrFromInt(its_base + offset);
    const hi_ptr: *volatile u32 = @ptrFromInt(its_base + offset + 4);
    return @as(u64, hi_ptr.*) << 32 | @as(u64, lo_ptr.*);
}

/// Issue a 32-byte ITS command. Writes to command queue and advances CWRITER.
fn itsCommand(cmd: [32]u8) void {
    // Write command to queue at current write offset
    const dst: [*]u8 = @ptrFromInt(@as(usize, @intFromPtr(cmd_queue_virt)) + cmd_write_offset);
    for (0..32) |i| dst[i] = cmd[i];

    // Clean cache for the command
    const clean_addr = @as(usize, @intFromPtr(cmd_queue_virt)) + cmd_write_offset;
    var a = clean_addr & ~@as(usize, 63);
    const end = clean_addr + 32;
    while (a < end) : (a += 64) {
        asm volatile ("dc cvac, %[addr]" :: [addr] "r" (a) : .{ .memory = true });
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // Advance write offset (64KB queue, 32-byte commands)
    cmd_write_offset = (cmd_write_offset + 32) % (64 * 1024);

    // Write CWRITER
    itsWrite64(GITS_CWRITER, cmd_write_offset);

    // Poll CREADR until it catches up (timeout ~10ms)
    var spin: u32 = 0;
    while (spin < 1_000_000) : (spin += 1) {
        const read_off = itsRead64(GITS_CREADR);
        if (read_off == cmd_write_offset) return;
        asm volatile ("yield");
    }
    uart.writeString("[gicv3-its] Command timeout\n");
}

/// Initialize GICv3 ITS. Call once before any MSI-X device setup.
pub fn initIts() bool {
    const cfg = &acpi.parser.config;
    if (cfg.gic_its_base == 0) {
        uart.writeString("[gicv3-its] No ITS base from ACPI\n");
        return false;
    }

    its_base = @truncate(cfg.gic_its_base);
    translater_addr = cfg.gic_its_base + GITS_TRANSLATER;
    uart.print("[gicv3-its] ITS base={x} translater={x}\n", .{ its_base, translater_addr });

    // Disable ITS first
    itsWrite32(GITS_CTLR, 0);

    // Read TYPER for capabilities
    const typer = itsRead64(GITS_TYPER);
    const id_bits = (typer >> 8) & 0x1F; // DeviceID bits
    const itte_size = ((typer >> 4) & 0xF) + 1; // ITT entry size
    uart.print("[gicv3-its] TYPER={x} devid_bits={} itte_size={}\n", .{ typer, id_bits, itte_size });

    // 1. Allocate LPI configuration table (1 byte per LPI, min 8192 entries)
    // Table covers LPIs 8192..8192+N. We allocate 1 page = 4096 LPIs.
    const lpi_cfg_page = pmm.allocPage() orelse {
        uart.writeString("[gicv3-its] OOM lpi_config\n");
        return false;
    };
    lpi_config_table = lpi_cfg_page;
    pinDmaPage(lpi_cfg_page);
    const lpi_cfg_virt: [*]u8 = @ptrFromInt(lpi_cfg_page);
    // Set all LPIs to priority 0xA0, enabled (bit 0 = 1)
    for (0..4096) |i| {
        lpi_cfg_virt[i] = 0xA0 | 0x01; // priority=0xA0, enable=1
    }
    // Clean cache
    var ca = lpi_cfg_page & ~@as(usize, 63);
    while (ca < lpi_cfg_page + 4096) : (ca += 64) {
        asm volatile ("dc cvac, %[addr]" :: [addr] "r" (ca) : .{ .memory = true });
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // 2. Allocate LPI pending table (1 bit per LPI, min 8192/8 = 1024 bytes)
    const lpi_pend_page = pmm.allocPage() orelse {
        uart.writeString("[gicv3-its] OOM lpi_pending\n");
        return false;
    };
    lpi_pending_table = lpi_pend_page;
    pinDmaPage(lpi_pend_page);
    const lpi_pend_virt: [*]u8 = @ptrFromInt(lpi_pend_page);
    for (0..4096) |i| lpi_pend_virt[i] = 0;
    ca = lpi_pend_page & ~@as(usize, 63);
    while (ca < lpi_pend_page + 4096) : (ca += 64) {
        asm volatile ("dc cvac, %[addr]" :: [addr] "r" (ca) : .{ .memory = true });
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // 3. Program redistributor PROPBASER and PENDBASER for LPIs
    const gicr_region: usize = @truncate(fdt.config.gicr_base);
    if (gicr_region == 0) {
        uart.writeString("[gicv3-its] No GICR base\n");
        return false;
    }
    const rd_base = findRedistributor(gicr_region);
    if (rd_base == 0) {
        uart.writeString("[gicv3-its] No redistributor\n");
        return false;
    }

    // GICR_PROPBASER (offset 0x70): address of LPI config table
    // Bits: [51:12]=phys_addr, [4:0]=ID_bits (log2(num_lpis)-1)
    // Inner shareable, write-back cacheable
    const propbaser: u64 = @as(u64, lpi_config_table & 0x000FFFFFFFFFF000) |
        (0x07 << 7) | // Inner Write-Back, Read-Allocate, Write-Allocate
        (0x01 << 10) | // Inner Shareable
        11; // ID bits: 2^(11+1) = 4096 LPIs
    const propbaser_lo: *volatile u32 = @ptrFromInt(rd_base + 0x70);
    const propbaser_hi: *volatile u32 = @ptrFromInt(rd_base + 0x74);
    propbaser_lo.* = @truncate(propbaser);
    propbaser_hi.* = @truncate(propbaser >> 32);
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // GICR_PENDBASER (offset 0x78): address of LPI pending table
    const pendbaser: u64 = @as(u64, lpi_pending_table & 0x000FFFFFFFFFF000) |
        (0x07 << 7) | // Inner Write-Back
        (0x01 << 10); // Inner Shareable
    const pendbaser_lo: *volatile u32 = @ptrFromInt(rd_base + 0x78);
    const pendbaser_hi: *volatile u32 = @ptrFromInt(rd_base + 0x7C);
    pendbaser_lo.* = @truncate(pendbaser);
    pendbaser_hi.* = @truncate(pendbaser >> 32);
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // Enable LPIs in GICR_CTLR (bit 0)
    const gicr_ctlr: *volatile u32 = @ptrFromInt(rd_base);
    gicr_ctlr.* = gicr_ctlr.* | 1;
    asm volatile ("dsb sy" ::: .{ .memory = true });
    uart.writeString("[gicv3-its] LPIs enabled in redistributor\n");

    // 4. Scan all 8 BASER registers to find table types and probe page size.
    // GCE's ITS requires 64KB pages and needs both Device and Collection tables.
    var its_page_size_bits: u2 = 0; // Will be probed
    var its_page_bytes: usize = 4096;

    // Read all BASERs, find Device table (type=1) and Collection table (type=4)
    var dev_baser_idx: ?usize = null;
    var coll_baser_idx: ?usize = null;
    for (0..8) |bi| {
        const baser = itsRead64(GITS_BASER0 + bi * 8);
        const btype: u3 = @truncate((baser >> 56) & 0x7);
        const esize = ((baser >> 48) & 0x1F) + 1;
        if (btype != 0) {
            uart.print("[gicv3-its] BASER{}: type={} entry_size={} raw={x}\n", .{ bi, btype, esize, baser });
        }
        if (btype == 1) dev_baser_idx = bi; // Devices
        if (btype == 4) coll_baser_idx = bi; // Collections
    }

    if (dev_baser_idx == null) {
        uart.writeString("[gicv3-its] No device table BASER found\n");
        return false;
    }

    // Probe page size by writing BASER0 with 4KB, checking readback
    const dev_bi = dev_baser_idx.?;
    const dev_baser_orig = itsRead64(GITS_BASER0 + dev_bi * 8);
    const probe_val: u64 = (@as(u64, 1) << 63) | // Valid
        (dev_baser_orig & (@as(u64, 0x7FF) << 48)) | // Keep type+entry_size from hw
        (@as(u64, 7) << 59) | // Inner WB cache
        (@as(u64, 1) << 10); // Inner Shareable, Page_Size=4KB(00)
    itsWrite64(GITS_BASER0 + dev_bi * 8, probe_val);
    const probe_rb = itsRead64(GITS_BASER0 + dev_bi * 8);
    its_page_size_bits = @truncate((probe_rb >> 8) & 3);
    its_page_bytes = switch (its_page_size_bits) {
        0 => 4096,
        1 => 16384,
        2 => 65536,
        3 => 65536,
    };
    const its_page_4k_count = its_page_bytes / 4096;
    uart.print("[gicv3-its] ITS page size: {}KB (bits={x})\n", .{ its_page_bytes / 1024, its_page_size_bits });

    const addr_mask: u64 = switch (its_page_size_bits) {
        0 => 0x000FFFFFFFFFF000,
        1 => 0x000FFFFFFFFFC000,
        2, 3 => 0x000FFFFFFFF0000,
    };

    // 5. Allocate ITS command queue (64KB, aligned to ITS page size)
    const cmd_total_pages = 16 + its_page_4k_count;
    const cmd_raw = pmm.allocPages(cmd_total_pages) orelse {
        uart.writeString("[gicv3-its] OOM cmd_queue\n");
        return false;
    };
    cmd_queue = (cmd_raw + its_page_bytes - 1) & ~(its_page_bytes - 1);
    pinDmaPages(cmd_raw, cmd_total_pages);
    cmd_queue_virt = @ptrFromInt(cmd_queue);
    cmd_write_offset = 0;
    const cq_virt: [*]u8 = @ptrFromInt(cmd_queue);
    for (0..16 * 4096) |i| cq_virt[i] = 0;
    uart.print("[gicv3-its] Cmd queue at {x}\n", .{cmd_queue});

    // 6. Allocate and program Device table
    const dev_total_pages = its_page_4k_count * 2;
    const dev_raw = pmm.allocPages(dev_total_pages) orelse {
        uart.writeString("[gicv3-its] OOM dev_table\n");
        return false;
    };
    const dev_table_addr = (dev_raw + its_page_bytes - 1) & ~(its_page_bytes - 1);
    pinDmaPages(dev_raw, dev_total_pages);
    const dev_table_virt: [*]u8 = @ptrFromInt(dev_table_addr);
    for (0..its_page_bytes) |i| dev_table_virt[i] = 0;
    ca = dev_table_addr & ~@as(usize, 63);
    while (ca < dev_table_addr + its_page_bytes) : (ca += 64) {
        asm volatile ("dc cvac, %[addr]" :: [addr] "r" (ca) : .{ .memory = true });
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });

    const dev_baser_val: u64 = (@as(u64, 1) << 63) | // Valid
        (@as(u64, 7) << 59) | // Inner WB cache
        (dev_baser_orig & (@as(u64, 0x7FF) << 48)) | // Keep type+entry_size from hw
        (@as(u64, dev_table_addr) & addr_mask) |
        (@as(u64, 1) << 10) | // Inner Shareable
        (@as(u64, its_page_size_bits) << 8) |
        0; // 1 ITS page
    itsWrite64(GITS_BASER0 + dev_bi * 8, dev_baser_val);
    const dev_rb = itsRead64(GITS_BASER0 + dev_bi * 8);
    uart.print("[gicv3-its] BASER{} (dev): written={x} readback={x}\n", .{ dev_bi, dev_baser_val, dev_rb });

    // 7. Allocate and program Collection table (if present)
    if (coll_baser_idx) |coll_bi| {
        const coll_baser_orig = itsRead64(GITS_BASER0 + coll_bi * 8);
        const coll_total_pages = its_page_4k_count * 2;
        const coll_raw = pmm.allocPages(coll_total_pages) orelse {
            uart.writeString("[gicv3-its] OOM coll_table\n");
            return false;
        };
        const coll_table_addr = (coll_raw + its_page_bytes - 1) & ~(its_page_bytes - 1);
        pinDmaPages(coll_raw, coll_total_pages);
        const coll_virt: [*]u8 = @ptrFromInt(coll_table_addr);
        for (0..its_page_bytes) |i| coll_virt[i] = 0;
        ca = coll_table_addr & ~@as(usize, 63);
        while (ca < coll_table_addr + its_page_bytes) : (ca += 64) {
            asm volatile ("dc cvac, %[addr]" :: [addr] "r" (ca) : .{ .memory = true });
        }
        asm volatile ("dsb sy" ::: .{ .memory = true });

        const coll_baser_val: u64 = (@as(u64, 1) << 63) | // Valid
            (@as(u64, 7) << 59) | // Inner WB cache
            (coll_baser_orig & (@as(u64, 0x7FF) << 48)) | // Keep type+entry_size from hw
            (@as(u64, coll_table_addr) & addr_mask) |
            (@as(u64, 1) << 10) | // Inner Shareable
            (@as(u64, its_page_size_bits) << 8) |
            0; // 1 ITS page
        itsWrite64(GITS_BASER0 + coll_bi * 8, coll_baser_val);
        const coll_rb = itsRead64(GITS_BASER0 + coll_bi * 8);
        uart.print("[gicv3-its] BASER{} (coll): written={x} readback={x}\n", .{ coll_bi, coll_baser_val, coll_rb });
    } else {
        uart.writeString("[gicv3-its] No collection table BASER (using flat collections)\n");
    }

    // 8. Program GITS_CBASER: command queue base address
    const cbaser_val: u64 = (@as(u64, 1) << 63) | // Valid
        (@as(u64, 7) << 59) | // Inner WB cache
        (@as(u64, cmd_queue) & 0x000FFFFFFFFFF000) | // Address
        (@as(u64, 1) << 10) | // Inner Shareable
        15; // 16 pages (64KB)
    itsWrite64(GITS_CBASER, cbaser_val);
    const cbaser_rb = itsRead64(GITS_CBASER);
    uart.print("[gicv3-its] CBASER written={x} readback={x}\n", .{ cbaser_val, cbaser_rb });

    // Reset CWRITER to 0
    itsWrite64(GITS_CWRITER, 0);

    // 8. Enable ITS
    itsWrite32(GITS_CTLR, 1); // Enabled bit
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // Verify ITS enabled
    const ctlr_rb = itsRead32(GITS_CTLR);
    uart.print("[gicv3-its] CTLR readback={x}\n", .{ctlr_rb});

    // Allocate ITT for device 0 (used by gVNIC)
    // Size: num_vectors * itte_size, 256-byte aligned minimum
    // Use a full page for simplicity
    const itt = pmm.allocPage() orelse {
        uart.writeString("[gicv3-its] OOM itt\n");
        return false;
    };
    itt_page = itt;
    pinDmaPage(itt);
    const itt_virt: [*]u8 = @ptrFromInt(itt);
    for (0..4096) |i| itt_virt[i] = 0;
    ca = itt & ~@as(usize, 63);
    while (ca < itt + 4096) : (ca += 64) {
        asm volatile ("dc cvac, %[addr]" :: [addr] "r" (ca) : .{ .memory = true });
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });

    its_initialized = true;
    uart.writeString("[gicv3-its] ITS initialized\n");
    return true;
}

/// Map a PCI device's MSI-X vectors to LPIs via ITS.
/// device_id: PCI RID (bus<<8 | dev<<3 | func)
/// num_vectors: number of MSI-X vectors to map
/// Returns the first LPI number assigned, or 0 on failure.
pub fn mapDevice(device_id: u32, num_vectors: u16) u32 {
    if (!its_initialized) return 0;

    const first_lpi = LPI_BASE; // Start at 8192
    const mpidr = readMpidr();
    const cpu_aff = mpidrAffinity(mpidr);

    uart.print("[gicv3-its] Mapping device {x} with {} vectors, target_aff={x}\n", .{ device_id, num_vectors, cpu_aff });

    // MAPC: Map Collection (route to this CPU)
    // DW0: [7:0]=opcode
    // DW2: [15:0]=ICID (collection ID, use 0)
    // DW2 bits [63:32] of full 64-bit = target PE affinity
    // Format: cmd[0..3]=opcode, cmd[8..11]=unused, cmd[16..19]=target_aff|valid, cmd[20..23]=ICID
    {
        var cmd: [32]u8 = .{0} ** 32;
        cmd[0] = ITS_CMD_MAPC;
        // DWORD 2 (bytes 16-23): RDbase (target PE) in bits [47:16] of DW2, Valid in bit 63
        // GICv3 ITS MAPC: DW2[63]=Valid, DW2[51:16]=RDbase (redistributor number or affinity)
        // For affinity routing: DW2[47:32]=Aff3:Aff2:Aff1:Aff0
        const dw2: u64 = (@as(u64, 1) << 63) | // Valid
            (@as(u64, cpu_aff) << 16); // Target PE affinity
        cmd[16] = @truncate(dw2);
        cmd[17] = @truncate(dw2 >> 8);
        cmd[18] = @truncate(dw2 >> 16);
        cmd[19] = @truncate(dw2 >> 24);
        cmd[20] = @truncate(dw2 >> 32);
        cmd[21] = @truncate(dw2 >> 40);
        cmd[22] = @truncate(dw2 >> 48);
        cmd[23] = @truncate(dw2 >> 56);
        // ICID = 0 in DW2 bytes [1:0] — already 0
        itsCommand(cmd);
    }

    // MAPD: Map Device (assign ITT to device)
    // DW0: [7:0]=opcode, [31:0] DeviceID
    // DW1: [4:0]=size (log2(num_entries))
    // DW2: [51:8]=ITT_addr (physical >> 8), [63]=Valid
    {
        var cmd: [32]u8 = .{0} ** 32;
        cmd[0] = ITS_CMD_MAPD;
        // DeviceID in DW0 bits [31:0] — little-endian
        cmd[4] = @truncate(device_id);
        cmd[5] = @truncate(device_id >> 8);
        cmd[6] = @truncate(device_id >> 16);
        cmd[7] = @truncate(device_id >> 24);
        // DW1: ITT size (log2) in bits [4:0]
        cmd[8] = 4; // 2^4 = 16 entries (enough for gVNIC's 3 vectors)
        // DW2: ITT address (bits [51:8]) and Valid bit [63]
        const dw2: u64 = (@as(u64, 1) << 63) | // Valid
            (@as(u64, itt_page) & 0x000FFFFFFFFFF000);
        cmd[16] = @truncate(dw2);
        cmd[17] = @truncate(dw2 >> 8);
        cmd[18] = @truncate(dw2 >> 16);
        cmd[19] = @truncate(dw2 >> 24);
        cmd[20] = @truncate(dw2 >> 32);
        cmd[21] = @truncate(dw2 >> 40);
        cmd[22] = @truncate(dw2 >> 48);
        cmd[23] = @truncate(dw2 >> 56);
        itsCommand(cmd);
    }

    // MAPTI: Map each MSI-X vector to an LPI
    var vec: u16 = 0;
    while (vec < num_vectors and vec < 16) : (vec += 1) {
        var cmd: [32]u8 = .{0} ** 32;
        cmd[0] = ITS_CMD_MAPTI;
        // DW0: DeviceID [31:0]
        cmd[4] = @truncate(device_id);
        cmd[5] = @truncate(device_id >> 8);
        cmd[6] = @truncate(device_id >> 16);
        cmd[7] = @truncate(device_id >> 24);
        // DW1: EventID (= MSI-X vector index) [31:0]
        cmd[8] = @truncate(vec);
        cmd[9] = @truncate(vec >> 8);
        // DW1: pINTID (= LPI number) [63:32] — upper 32 bits of DW1
        const lpi = first_lpi + @as(u32, vec);
        cmd[12] = @truncate(lpi);
        cmd[13] = @truncate(lpi >> 8);
        cmd[14] = @truncate(lpi >> 16);
        cmd[15] = @truncate(lpi >> 24);
        // DW2: ICID [15:0] = 0 (collection 0)
        itsCommand(cmd);
    }

    // INV: Invalidate LPI config cache for each mapped vector
    vec = 0;
    while (vec < num_vectors and vec < 16) : (vec += 1) {
        var cmd: [32]u8 = .{0} ** 32;
        cmd[0] = ITS_CMD_INV;
        cmd[4] = @truncate(device_id);
        cmd[5] = @truncate(device_id >> 8);
        cmd[6] = @truncate(device_id >> 16);
        cmd[7] = @truncate(device_id >> 24);
        // EventID
        cmd[8] = @truncate(vec);
        cmd[9] = @truncate(vec >> 8);
        itsCommand(cmd);
    }

    // SYNC: Ensure all commands complete
    {
        var cmd: [32]u8 = .{0} ** 32;
        cmd[0] = ITS_CMD_SYNC;
        // DW2: target RDbase (same affinity as MAPC)
        const dw2: u64 = @as(u64, cpu_aff) << 16;
        cmd[16] = @truncate(dw2);
        cmd[17] = @truncate(dw2 >> 8);
        cmd[18] = @truncate(dw2 >> 16);
        cmd[19] = @truncate(dw2 >> 24);
        cmd[20] = @truncate(dw2 >> 32);
        cmd[21] = @truncate(dw2 >> 40);
        cmd[22] = @truncate(dw2 >> 48);
        cmd[23] = @truncate(dw2 >> 56);
        itsCommand(cmd);
    }

    uart.print("[gicv3-its] Device mapped: LPIs {}-{}\n", .{ first_lpi, first_lpi + num_vectors - 1 });
    return first_lpi;
}
