/// NVMe block device driver — polling-based, single I/O queue.
///
/// Provides readSectors() / writeSectors() matching the virtio_blk API so ext2
/// can use either driver transparently through the block_io abstraction.
///
/// Init sequence: disable controller → allocate admin queues → enable →
/// Identify Controller → Identify Namespace → create I/O queue pair.
///
/// All I/O is synchronous (poll CQ after each command). MVP design — no MSI-X,
/// no multi-queue, no PRP lists (transfers capped at 4KB per command).

const serial = @import("../arch/x86_64/serial.zig");
const idt = @import("../arch/x86_64/idt.zig");
const pmm = @import("../mm/pmm.zig");
const spinlock = @import("../arch/x86_64/spinlock.zig");
const hhdm = @import("../mm/hhdm.zig");
const pci = @import("pci.zig");
const klog = @import("../klog/klog.zig");
const log = klog.scoped(.nvme);

// ---- NVMe controller register offsets (BAR0) ----

const REG_CAP: usize = 0x00; // Controller Capabilities (64-bit)
const REG_VS: usize = 0x08; // Version
const REG_INTMS: usize = 0x0C; // Interrupt Mask Set
const REG_CC: usize = 0x14; // Controller Configuration
const REG_CSTS: usize = 0x1C; // Controller Status
const REG_AQA: usize = 0x24; // Admin Queue Attributes
const REG_ASQ: usize = 0x28; // Admin SQ Base (64-bit)
const REG_ACQ: usize = 0x30; // Admin CQ Base (64-bit)

// ---- CC (Controller Configuration) bits ----

const CC_EN: u32 = 1 << 0;
const CC_CSS_NVM: u32 = 0 << 4;
const CC_MPS_4K: u32 = 0 << 7;
const CC_AMS_RR: u32 = 0 << 11;
const CC_IOSQES: u32 = 6 << 16; // I/O SQ Entry Size = 2^6 = 64B
const CC_IOCQES: u32 = 4 << 20; // I/O CQ Entry Size = 2^4 = 16B

// ---- CSTS (Controller Status) bits ----

const CSTS_RDY: u32 = 1 << 0;
const CSTS_CFS: u32 = 1 << 1;

// ---- NVMe admin opcodes ----

const ADMIN_CREATE_IO_SQ: u8 = 0x01;
const ADMIN_CREATE_IO_CQ: u8 = 0x05;
const ADMIN_IDENTIFY: u8 = 0x06;

// ---- NVM I/O opcodes ----

const NVM_READ: u8 = 0x02;
const NVM_WRITE: u8 = 0x01;

// ---- NVMe command structures ----

/// 64-byte Submission Queue Entry
const SqEntry = extern struct {
    cdw0: u32,
    nsid: u32,
    cdw2: u32,
    cdw3: u32,
    mptr: u64,
    prp1: u64,
    prp2: u64,
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,
};

/// 16-byte Completion Queue Entry
const CqEntry = extern struct {
    dw0: u32,
    dw1: u32,
    sq_head: u16,
    sq_id: u16,
    cid: u16,
    status: u16,
};

// ---- Queue parameters ----

const ADMIN_QUEUE_DEPTH: u16 = 16;
const IO_QUEUE_DEPTH: u16 = 16;

// ---- Static state ----

var bar0_virt: usize = 0; // HHDM-mapped virtual address of BAR0
var initialized: bool = false;
var doorbell_stride: u32 = 4;
var io_lock: spinlock.IrqSpinlock = .{};
var timeout_ms: u32 = 5000;

// Admin queue (QID 0) — physical addresses for device, virtual for CPU
var admin_sq_phys: u64 = 0;
var admin_sq_virt: usize = 0;
var admin_cq_phys: u64 = 0;
var admin_cq_virt: usize = 0;
var admin_sq_tail: u16 = 0;
var admin_cq_head: u16 = 0;
var admin_cq_phase: u1 = 1;
var admin_cid: u16 = 1;

// I/O queue (QID 1)
var io_sq_phys: u64 = 0;
var io_sq_virt: usize = 0;
var io_cq_phys: u64 = 0;
var io_cq_virt: usize = 0;
var io_sq_tail: u16 = 0;
var io_cq_head: u16 = 0;
var io_cq_phase: u1 = 1;
var io_cid: u16 = 1;

// DMA staging buffer (1 page)
var dma_buf_phys: u64 = 0;
var dma_buf_virt: usize = 0;

// Identify data page
var identify_phys: u64 = 0;
var identify_virt: usize = 0;

// Namespace info
var namespace_id: u32 = 1;
var total_sectors: u64 = 0;
var sector_size: u32 = 512;

// ---- Register access (MMIO via HHDM) ----

fn readReg32(offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(bar0_virt + offset);
    asm volatile ("mfence" ::: .{ .memory = true });
    const val = ptr.*;
    asm volatile ("mfence" ::: .{ .memory = true });
    return val;
}

fn writeReg32(offset: usize, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(bar0_virt + offset);
    asm volatile ("mfence" ::: .{ .memory = true });
    ptr.* = val;
    asm volatile ("mfence" ::: .{ .memory = true });
}

fn readReg64(offset: usize) u64 {
    const lo = readReg32(offset);
    const hi = readReg32(offset + 4);
    return (@as(u64, hi) << 32) | lo;
}

fn writeReg64(offset: usize, val: u64) void {
    writeReg32(offset, @truncate(val));
    writeReg32(offset + 4, @truncate(val >> 32));
}

// ---- Doorbell access ----

fn sqDoorbell(qid: u16) usize {
    return 0x1000 + @as(usize, 2 * qid) * doorbell_stride;
}

fn cqDoorbell(qid: u16) usize {
    return 0x1000 + @as(usize, 2 * qid + 1) * doorbell_stride;
}

// ---- Completion queue polling ----

fn pollCompletion(
    cq_virt_addr: usize,
    cq_head: *u16,
    cq_phase: *u1,
    queue_depth: u16,
    expected_cid: u16,
) ?CqEntry {
    const cq: [*]volatile CqEntry = @ptrFromInt(cq_virt_addr);
    var spins: u32 = 0;
    const max_spins: u32 = 50_000_000;

    while (spins < max_spins) : (spins += 1) {
        asm volatile ("mfence" ::: .{ .memory = true });
        const entry = cq[cq_head.*];
        const phase_bit: u1 = @truncate(entry.status & 1);

        if (phase_bit == cq_phase.*) {
            cq_head.* += 1;
            if (cq_head.* >= queue_depth) {
                cq_head.* = 0;
                cq_phase.* ^= 1;
            }

            if (entry.cid != expected_cid) {
                log.warn("cid_mismatch", .{ .got = @as(u64, entry.cid), .expected = @as(u64, expected_cid) });
            }

            return entry;
        }

        asm volatile ("pause" ::: .{ .memory = true });
    }

    log.err("poll_timeout", .{ .cq_head = @as(u64, cq_head.*), .phase = @as(u64, cq_phase.*) });
    return null;
}

fn statusOk(status: u16) bool {
    const sc = (status >> 1) & 0xFF;
    const sct = (status >> 9) & 0x7;
    return sc == 0 and sct == 0;
}

// ---- Admin command submission ----

fn submitAdmin(cmd: *const SqEntry) bool {
    const sq: [*]volatile SqEntry = @ptrFromInt(admin_sq_virt);
    sq[admin_sq_tail] = cmd.*;

    admin_sq_tail += 1;
    if (admin_sq_tail >= ADMIN_QUEUE_DEPTH) admin_sq_tail = 0;

    writeReg32(sqDoorbell(0), admin_sq_tail);

    const completion = pollCompletion(
        admin_cq_virt,
        &admin_cq_head,
        &admin_cq_phase,
        ADMIN_QUEUE_DEPTH,
        @truncate(cmd.cdw0 >> 16),
    ) orelse return false;

    writeReg32(cqDoorbell(0), admin_cq_head);

    if (!statusOk(completion.status)) {
        log.err("admin_cmd_failed", .{ .status = @as(u64, completion.status) });
        return false;
    }

    return true;
}

// ---- I/O command submission ----

fn submitIo(cmd: *const SqEntry) bool {
    // Serialize all I/O queue access — prevents two concurrent readers from
    // consuming each other's CQ completions (CID mismatch → infinite poll).
    const flags = io_lock.acquire();

    const sq: [*]volatile SqEntry = @ptrFromInt(io_sq_virt);
    sq[io_sq_tail] = cmd.*;

    io_sq_tail += 1;
    if (io_sq_tail >= IO_QUEUE_DEPTH) io_sq_tail = 0;

    writeReg32(sqDoorbell(1), io_sq_tail);

    const completion = pollCompletion(
        io_cq_virt,
        &io_cq_head,
        &io_cq_phase,
        IO_QUEUE_DEPTH,
        @truncate(cmd.cdw0 >> 16),
    ) orelse {
        io_lock.release(flags);
        return false;
    };

    writeReg32(cqDoorbell(1), io_cq_head);
    io_lock.release(flags);

    if (!statusOk(completion.status)) {
        log.err("io_cmd_failed", .{ .status = @as(u64, completion.status) });
        return false;
    }

    return true;
}

// ---- Helper: allocate a page, return phys + virt ----

fn allocDmaPage() ?struct { phys: u64, virt: usize } {
    const phys = pmm.allocPage() orelse return null;
    const virt = hhdm.physToVirt(phys);
    // Zero the page
    const ptr: [*]u8 = @ptrFromInt(virt);
    for (0..4096) |i| ptr[i] = 0;
    return .{ .phys = phys, .virt = virt };
}

fn makeSqEntry() SqEntry {
    return SqEntry{
        .cdw0 = 0, .nsid = 0, .cdw2 = 0, .cdw3 = 0,
        .mptr = 0, .prp1 = 0, .prp2 = 0,
        .cdw10 = 0, .cdw11 = 0, .cdw12 = 0,
        .cdw13 = 0, .cdw14 = 0, .cdw15 = 0,
    };
}

// ---- Wait for CSTS condition ----

fn spinDelay(ms: u32) void {
    // PIT ticks at 100 Hz = 10ms per tick
    const ticks_to_wait = (ms + 9) / 10; // Round up
    const start = idt.getTickCount();
    while (idt.getTickCount() - start < ticks_to_wait) {
        asm volatile ("pause");
    }
}

fn waitReady(expected: bool) bool {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 10) {
        const csts = readReg32(REG_CSTS);
        if (csts & CSTS_CFS != 0) {
            log.fatal("ctrl_fatal_status", .{ .csts = @as(u64, csts) });
            return false;
        }
        const rdy = (csts & CSTS_RDY) != 0;
        if (rdy == expected) return true;
        spinDelay(10);
    }
    log.err("wait_rdy_timeout", .{ .expected = @as(u64, @intFromBool(expected)) });
    return false;
}

// ---- Public init ----

pub fn init(dev: *const pci.PciDevice) bool {
    if (dev.bar0 == 0) {
        log.err("bar0_unassigned", .{});
        return false;
    }

    // Map BAR0 physical MMIO address to kernel virtual via HHDM
    bar0_virt = hhdm.physToVirt(dev.bar0);
    log.info("bar0_mapped", .{ .phys = dev.bar0, .virt = @as(u64, bar0_virt) });

    // Read CAP register
    const cap = readReg64(REG_CAP);
    const mqes: u16 = @truncate(cap & 0xFFFF);
    const dstrd: u32 = @truncate((cap >> 32) & 0xF);
    const to: u32 = @truncate((cap >> 24) & 0xFF);

    doorbell_stride = @as(u32, 4) << @truncate(dstrd);
    timeout_ms = if (to == 0) 5000 else to * 500;

    log.info("cap", .{ .mqes = @as(u64, mqes), .dstrd = @as(u64, dstrd), .timeout = @as(u64, timeout_ms) });

    // Read version
    const vs = readReg32(REG_VS);
    log.info("version", .{ .major = @as(u64, (vs >> 16) & 0xFF), .minor = @as(u64, (vs >> 8) & 0xFF) });

    // Step 1: Disable controller
    var cc = readReg32(REG_CC);
    if (cc & CC_EN != 0) {
        cc &= ~CC_EN;
        writeReg32(REG_CC, cc);
        if (!waitReady(false)) return false;
    }
    log.info("ctrl_disabled", .{});

    // Step 2: Allocate admin queues
    const admin_sq = allocDmaPage() orelse {
        log.err("alloc_admin_sq", .{});
        return false;
    };
    admin_sq_phys = admin_sq.phys;
    admin_sq_virt = admin_sq.virt;

    const admin_cq = allocDmaPage() orelse {
        log.err("alloc_admin_cq", .{});
        return false;
    };
    admin_cq_phys = admin_cq.phys;
    admin_cq_virt = admin_cq.virt;

    admin_sq_tail = 0;
    admin_cq_head = 0;
    admin_cq_phase = 1;
    admin_cid = 1;

    log.debug("admin_queues", .{ .sq = admin_sq_phys, .cq = admin_cq_phys });

    // Step 3: Configure admin queue attributes
    const aqa: u32 = (@as(u32, ADMIN_QUEUE_DEPTH - 1) << 16) | (ADMIN_QUEUE_DEPTH - 1);
    writeReg32(REG_AQA, aqa);
    writeReg64(REG_ASQ, admin_sq_phys);
    writeReg64(REG_ACQ, admin_cq_phys);

    // Step 4: Enable controller
    cc = CC_EN | CC_CSS_NVM | CC_MPS_4K | CC_AMS_RR | CC_IOSQES | CC_IOCQES;
    writeReg32(REG_CC, cc);
    if (!waitReady(true)) return false;
    log.info("ctrl_enabled", .{});

    // Step 5: Mask all interrupts (polling mode)
    writeReg32(REG_INTMS, 0xFFFFFFFF);

    // Step 6: Allocate identify page
    const id_page = allocDmaPage() orelse {
        log.err("alloc_identify", .{});
        return false;
    };
    identify_phys = id_page.phys;
    identify_virt = id_page.virt;

    // Step 7: Identify Controller (CNS=1)
    if (!identifyController()) return false;

    // Step 8: Identify Namespace 1 (CNS=0)
    if (!identifyNamespace()) return false;

    // Step 9: Create I/O Completion Queue (QID=1)
    if (!createIoCq()) return false;

    // Step 10: Create I/O Submission Queue (QID=1)
    if (!createIoSq()) return false;

    // Step 11: Allocate DMA staging buffer
    const dma_page = allocDmaPage() orelse {
        log.err("alloc_dma_buf", .{});
        return false;
    };
    dma_buf_phys = dma_page.phys;
    dma_buf_virt = dma_page.virt;

    initialized = true;
    log.info("init_complete", .{ .sectors = total_sectors, .secsize = @as(u64, sector_size) });
    return true;
}

// ---- Identify Controller ----

fn identifyController() bool {
    // Zero identify page
    const z: [*]u8 = @ptrFromInt(identify_virt);
    for (0..4096) |i| z[i] = 0;

    var cmd = makeSqEntry();
    cmd.cdw0 = @as(u32, ADMIN_IDENTIFY) | (@as(u32, admin_cid) << 16);
    admin_cid +%= 1;
    cmd.prp1 = identify_phys;
    cmd.cdw10 = 1; // CNS = 1

    if (!submitAdmin(&cmd)) {
        log.err("identify_ctrl_fail", .{});
        return false;
    }

    // Log model/SN/FW to serial directly (variable-length strings)
    const data: [*]const u8 = @ptrFromInt(identify_virt);
    serial.writeString("[nvme] SN: ");
    printTrimmed(data[4..24]);
    serial.writeString("\n[nvme] Model: ");
    printTrimmed(data[24..64]);
    serial.writeString("\n[nvme] FW: ");
    printTrimmed(data[64..72]);
    serial.writeString("\n");

    log.info("identify_ctrl_ok", .{});
    return true;
}

fn printTrimmed(s: []const u8) void {
    var end: usize = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == 0)) {
        end -= 1;
    }
    if (end > 0) {
        serial.writeString(s[0..end]);
    }
}

// ---- Identify Namespace ----

fn identifyNamespace() bool {
    const z: [*]u8 = @ptrFromInt(identify_virt);
    for (0..4096) |i| z[i] = 0;

    var cmd = makeSqEntry();
    cmd.cdw0 = @as(u32, ADMIN_IDENTIFY) | (@as(u32, admin_cid) << 16);
    admin_cid +%= 1;
    cmd.nsid = namespace_id;
    cmd.prp1 = identify_phys;
    cmd.cdw10 = 0; // CNS = 0

    if (!submitAdmin(&cmd)) {
        log.err("identify_ns_fail", .{});
        return false;
    }

    const data: [*]const u8 = @ptrFromInt(identify_virt);

    // NSZE: bytes 0-7 (u64 LE)
    total_sectors = @as(u64, data[0]) |
        (@as(u64, data[1]) << 8) |
        (@as(u64, data[2]) << 16) |
        (@as(u64, data[3]) << 24) |
        (@as(u64, data[4]) << 32) |
        (@as(u64, data[5]) << 40) |
        (@as(u64, data[6]) << 48) |
        (@as(u64, data[7]) << 56);

    // FLBAS: byte 26
    const flbas = data[26];
    const lba_fmt_idx: usize = flbas & 0x0F;

    // LBA Format: offset 128, 4 bytes each. Byte 2 = LBADS
    const lbaf_offset = 128 + lba_fmt_idx * 4;
    const lbads = data[lbaf_offset + 2];
    if (lbads >= 9 and lbads <= 12) {
        sector_size = @as(u32, 1) << @truncate(lbads);
    }

    const total_mib = (total_sectors * sector_size) / (1024 * 1024);

    log.info("namespace", .{ .nsid = @as(u64, namespace_id), .sectors = total_sectors, .secsize = @as(u64, sector_size), .mib = total_mib });

    return total_sectors > 0;
}

// ---- Create I/O Completion Queue ----

fn createIoCq() bool {
    const cq_page = allocDmaPage() orelse {
        log.err("alloc_io_cq", .{});
        return false;
    };
    io_cq_phys = cq_page.phys;
    io_cq_virt = cq_page.virt;
    io_cq_head = 0;
    io_cq_phase = 1;

    var cmd = makeSqEntry();
    cmd.cdw0 = @as(u32, ADMIN_CREATE_IO_CQ) | (@as(u32, admin_cid) << 16);
    admin_cid +%= 1;
    cmd.prp1 = io_cq_phys;
    cmd.cdw10 = (@as(u32, IO_QUEUE_DEPTH - 1) << 16) | 1;
    cmd.cdw11 = 1; // PC=1

    if (!submitAdmin(&cmd)) {
        log.err("create_io_cq_fail", .{});
        return false;
    }

    log.info("io_cq_created", .{ .depth = @as(u64, IO_QUEUE_DEPTH) });
    return true;
}

// ---- Create I/O Submission Queue ----

fn createIoSq() bool {
    const sq_page = allocDmaPage() orelse {
        log.err("alloc_io_sq", .{});
        return false;
    };
    io_sq_phys = sq_page.phys;
    io_sq_virt = sq_page.virt;
    io_sq_tail = 0;
    io_cid = 1;

    var cmd = makeSqEntry();
    cmd.cdw0 = @as(u32, ADMIN_CREATE_IO_SQ) | (@as(u32, admin_cid) << 16);
    admin_cid +%= 1;
    cmd.prp1 = io_sq_phys;
    cmd.cdw10 = (@as(u32, IO_QUEUE_DEPTH - 1) << 16) | 1;
    cmd.cdw11 = (1 << 16) | 1; // CQID=1, PC=1

    if (!submitAdmin(&cmd)) {
        log.err("create_io_sq_fail", .{});
        return false;
    }

    log.info("io_sq_created", .{ .depth = @as(u64, IO_QUEUE_DEPTH) });
    return true;
}

// ---- Public read/write API ----

/// Read sectors from NVMe. API matches virtio_blk.readSectors().
pub fn readSectors(sector: u64, count: u32, buf: [*]u8) bool {
    if (!initialized) return false;
    // NOTE: io_lock in submitIo handles interrupt disable/enable

    const sectors_per_page: u32 = 4096 / sector_size;
    const ext_sectors_per_cmd: u32 = @min(sectors_per_page * (sector_size / 512), 8);

    var remaining = count;
    var cur_sector = sector;
    var buf_off: usize = 0;

    while (remaining > 0) {
        const chunk = @min(remaining, ext_sectors_per_cmd);

        const lba = (cur_sector * 512) / sector_size;
        const nlb: u32 = ((chunk * 512) + sector_size - 1) / sector_size;

        var cmd = makeSqEntry();
        cmd.cdw0 = @as(u32, NVM_READ) | (@as(u32, io_cid) << 16);
        io_cid +%= 1;
        if (io_cid == 0) io_cid = 1;
        cmd.nsid = namespace_id;
        cmd.prp1 = dma_buf_phys;
        cmd.cdw10 = @truncate(lba);
        cmd.cdw11 = @truncate(lba >> 32);
        cmd.cdw12 = nlb - 1;

        if (!submitIo(&cmd)) {
            return false;
        }

        // Copy from DMA buffer to caller
        const src: [*]const u8 = @ptrFromInt(dma_buf_virt);
        const byte_count: usize = @as(usize, chunk) * 512;
        for (0..byte_count) |i| {
            buf[buf_off + i] = src[i];
        }

        remaining -= chunk;
        cur_sector += chunk;
        buf_off += byte_count;
    }

    return true;
}

/// Write sectors to NVMe. API matches virtio_blk.writeSectors().
pub fn writeSectors(sector: u64, count: u32, buf: [*]const u8) bool {
    if (!initialized) return false;

    asm volatile ("cli");
    defer asm volatile ("sti");

    const sectors_per_page: u32 = 4096 / sector_size;
    const ext_sectors_per_cmd: u32 = @min(sectors_per_page * (sector_size / 512), 8);

    var remaining = count;
    var cur_sector = sector;
    var buf_off: usize = 0;

    while (remaining > 0) {
        const chunk = @min(remaining, ext_sectors_per_cmd);

        // Copy caller data to DMA buffer
        const dst: [*]u8 = @ptrFromInt(dma_buf_virt);
        const byte_count: usize = @as(usize, chunk) * 512;
        for (0..byte_count) |i| {
            dst[i] = buf[buf_off + i];
        }

        const lba = (cur_sector * 512) / sector_size;
        const nlb: u32 = ((chunk * 512) + sector_size - 1) / sector_size;

        var cmd = makeSqEntry();
        cmd.cdw0 = @as(u32, NVM_WRITE) | (@as(u32, io_cid) << 16);
        io_cid +%= 1;
        if (io_cid == 0) io_cid = 1;
        cmd.nsid = namespace_id;
        cmd.prp1 = dma_buf_phys;
        cmd.cdw10 = @truncate(lba);
        cmd.cdw11 = @truncate(lba >> 32);
        cmd.cdw12 = nlb - 1;

        if (!submitIo(&cmd)) {
            return false;
        }

        remaining -= chunk;
        cur_sector += chunk;
        buf_off += byte_count;
    }

    return true;
}

pub fn getCapacity() u64 {
    return (total_sectors * sector_size) / 512;
}

pub fn isInitialized() bool {
    return initialized;
}
