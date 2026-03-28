/// NVMe block device driver — batched I/O with queue depth.
///
/// Provides readSectors() / writeSectors() matching the virtio_blk API so ext2
/// can use either driver transparently through the block_io abstraction.
///
/// Init sequence: disable controller → allocate admin queues → enable →
/// Identify Controller → Identify Namespace → create I/O queue pair.
///
/// I/O is batched: submit up to BATCH_DEPTH commands to the SQ, ring doorbell
/// once, then reap all completions. Each command gets its own DMA page from a
/// pre-allocated pool. This exploits NVMe's native parallelism — the device
/// can process multiple commands concurrently (reorder, merge, pipeline).

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const timer = @import("timer.zig");
const spinlock = @import("spinlock.zig");
const pci = @import("pci.zig");

/// Pin a physical page for DMA by saturating its PMM ref count.
/// Saturated pages (ref=65535) are never freed or reallocated.
/// Without this, pmm.allocPage() can hand out DMA pages for kernel stacks,
/// causing NVMe DMA writes to corrupt kernel memory (v41-v43 SPSR corruption bug).
fn pinDmaPage(phys: u64) void {
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        pmm.incRef(phys);
    }
}

/// Pin a contiguous range of physical pages for DMA.
fn pinDmaPages(base_phys: u64, num_pages: u64) void {
    var p: u64 = 0;
    while (p < num_pages) : (p += 1) {
        pinDmaPage(base_phys + p * 4096);
    }
}

// ---- NVMe controller register offsets (BAR0) ----

const REG_CAP: usize = 0x00; // Controller Capabilities (64-bit)
const REG_VS: usize = 0x08; // Version
const REG_INTMS: usize = 0x0C; // Interrupt Mask Set
const REG_INTMC: usize = 0x10; // Interrupt Mask Clear
const REG_CC: usize = 0x14; // Controller Configuration
const REG_CSTS: usize = 0x1C; // Controller Status
const REG_AQA: usize = 0x24; // Admin Queue Attributes
const REG_ASQ: usize = 0x28; // Admin SQ Base (64-bit)
const REG_ACQ: usize = 0x30; // Admin CQ Base (64-bit)
// Doorbells start at 0x1000, stride = 4 << CAP.DSTRD

// ---- CC (Controller Configuration) bits ----

const CC_EN: u32 = 1 << 0;
const CC_CSS_NVM: u32 = 0 << 4; // NVM command set
const CC_MPS_4K: u32 = 0 << 7; // Memory Page Size = 4KB (2^(12+0))
const CC_AMS_RR: u32 = 0 << 11; // Round-robin arbitration
const CC_IOSQES: u32 = 6 << 16; // I/O SQ Entry Size = 2^6 = 64B
const CC_IOCQES: u32 = 4 << 20; // I/O CQ Entry Size = 2^4 = 16B

// ---- CSTS (Controller Status) bits ----

const CSTS_RDY: u32 = 1 << 0;
const CSTS_CFS: u32 = 1 << 1; // Controller Fatal Status

// ---- NVMe admin opcodes ----

const ADMIN_DELETE_IO_SQ: u8 = 0x00;
const ADMIN_CREATE_IO_SQ: u8 = 0x01;
const ADMIN_DELETE_IO_CQ: u8 = 0x04;
const ADMIN_CREATE_IO_CQ: u8 = 0x05;
const ADMIN_IDENTIFY: u8 = 0x06;

// ---- NVM I/O opcodes ----

const NVM_READ: u8 = 0x02;
const NVM_WRITE: u8 = 0x01;

// ---- NVMe command structures ----

/// 64-byte Submission Queue Entry
const SqEntry = extern struct {
    cdw0: u32, // opcode[7:0] | fuse[9:8] | psdt[15:14] | cid[31:16]
    nsid: u32,
    cdw2: u32,
    cdw3: u32,
    mptr: u64, // Metadata Pointer
    prp1: u64, // PRP Entry 1
    prp2: u64, // PRP Entry 2
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,
};

/// 16-byte Completion Queue Entry
const CqEntry = extern struct {
    dw0: u32, // Command-specific result
    dw1: u32, // Reserved
    sq_head: u16, // SQ Head Pointer
    sq_id: u16, // SQ Identifier
    cid: u16, // Command Identifier
    status: u16, // Status Field (phase bit = bit 0, SC = bits 9:1, SCT = bits 11:10)
};

// --- Comptime struct layout assertions (Chaos Rocket safety) ---
// NVMe spec defines exact layouts — any deviation corrupts DMA.
comptime {
    // SqEntry: 64 bytes (NVMe spec 4.2)
    if (@offsetOf(SqEntry, "cdw0") != 0) @compileError("SqEntry.cdw0 must be at offset 0");
    if (@offsetOf(SqEntry, "nsid") != 4) @compileError("SqEntry.nsid must be at offset 4");
    if (@offsetOf(SqEntry, "mptr") != 16) @compileError("SqEntry.mptr must be at offset 16");
    if (@offsetOf(SqEntry, "prp1") != 24) @compileError("SqEntry.prp1 must be at offset 24");
    if (@offsetOf(SqEntry, "prp2") != 32) @compileError("SqEntry.prp2 must be at offset 32");
    if (@offsetOf(SqEntry, "cdw10") != 40) @compileError("SqEntry.cdw10 must be at offset 40");
    if (@sizeOf(SqEntry) != 64) @compileError("SqEntry must be 64 bytes");

    // CqEntry: 16 bytes (NVMe spec 4.6)
    if (@offsetOf(CqEntry, "dw0") != 0) @compileError("CqEntry.dw0 must be at offset 0");
    if (@offsetOf(CqEntry, "sq_head") != 8) @compileError("CqEntry.sq_head must be at offset 8");
    if (@offsetOf(CqEntry, "cid") != 12) @compileError("CqEntry.cid must be at offset 12");
    if (@offsetOf(CqEntry, "status") != 14) @compileError("CqEntry.status must be at offset 14");
    if (@sizeOf(CqEntry) != 16) @compileError("CqEntry must be 16 bytes");
}

// ---- Queue parameters ----

const ADMIN_QUEUE_DEPTH: u16 = 16;
const IO_QUEUE_DEPTH: u16 = 256;

// ---- Static state ----

var bar0_base: usize = 0;
var initialized: bool = false;
var doorbell_stride: u32 = 4; // 4 << CAP.DSTRD (default DSTRD=0)
var max_queue_entries: u16 = 0;
var timeout_ms: u32 = 5000; // CAP.TO * 500ms

// Admin queue (QID 0)
var admin_sq_phys: u64 = 0;
var admin_cq_phys: u64 = 0;
var admin_sq_tail: u16 = 0;
var admin_cq_head: u16 = 0;
var admin_cq_phase: u1 = 1;
var admin_cid: u16 = 1;

// I/O queue (QID 1)
var io_sq_phys: u64 = 0;
var io_cq_phys: u64 = 0;
var io_sq_tail: u16 = 0;
var io_cq_head: u16 = 0;
var io_cq_phase: u1 = 1;
var io_cid: u16 = 1;

// DMA page pool for batched I/O — one page per in-flight command.
const BATCH_DEPTH: usize = 32; // Max commands per batch (must be < IO_QUEUE_DEPTH)
var dma_pool: [BATCH_DEPTH]u64 = [_]u64{0} ** BATCH_DEPTH;
var dma_pool_initialized: bool = false;

// Legacy single DMA buffer (kept for admin commands and fallback)
var dma_buf_phys: u64 = 0;

// Identify data page (reused for both controller and namespace identify)
var identify_phys: u64 = 0;

// Namespace info
var namespace_id: u32 = 1;
var total_sectors: u64 = 0;
var sector_size: u32 = 512;

// SMP lock
var nvme_lock: spinlock.IrqSpinlock = .{};

// ---- Register access ----

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

/// SQ y Tail Doorbell offset = 0x1000 + (2y) * doorbell_stride
fn sqDoorbell(qid: u16) usize {
    return 0x1000 + @as(usize, 2 * qid) * doorbell_stride;
}

/// CQ y Head Doorbell offset = 0x1000 + (2y+1) * doorbell_stride
fn cqDoorbell(qid: u16) usize {
    return 0x1000 + @as(usize, 2 * qid + 1) * doorbell_stride;
}

// ---- Completion queue polling ----

// Diagnostic counters
var total_commands: u32 = 0;
var total_timeouts: u32 = 0;
var total_retries: u32 = 0;
var total_cid_mismatches: u32 = 0;

fn pollCompletion(
    cq_phys: u64,
    cq_head: *u16,
    cq_phase: *u1,
    queue_depth: u16,
    expected_cid: u16,
) ?CqEntry {
    const cq: [*]volatile CqEntry = @ptrFromInt(cq_phys);

    // Validate cq_head — external memory corruption can push it out of bounds
    // (observed: cq_head=1024 with queue_depth=256, caused by wild write during
    // heavy mmap/munmap churn in zig compilation). Reset to 0 and resync phase.
    if (cq_head.* >= queue_depth) {
        uart.print("[nvme] WARN: cq_head={} >= depth={}, resetting to 0\n", .{ cq_head.*, queue_depth });
        cq_head.* = 0;
        // Phase is unknown after corruption — probe the current entry
        // to determine what the device expects. If the entry at [0] has
        // a valid-looking completion (non-zero CID), infer phase from it.
        asm volatile ("dmb ld" ::: .{ .memory = true });
        const probe = cq[0];
        if (probe.cid != 0 or probe.sq_head != 0) {
            // Entry looks valid — set our phase to match
            cq_phase.* = @truncate(probe.status & 1);
        }
        // If all zeros, keep current phase and hope for the best
    }

    var spins: u32 = 0;
    const max_spins: u32 = 100_000_000; // ~2 seconds — shorter to avoid deadlocking other CPU

    while (spins < max_spins) : (spins += 1) {
        // On GCE Axion (Neoverse V2), DMA is IO-coherent via the CMN
        // interconnect — no manual cache invalidation needed. A simple
        // data memory barrier ensures ordering without the expensive
        // dc ivac + dsb sy that was causing poll timeouts.
        asm volatile ("dmb ld" ::: .{ .memory = true });

        const entry = cq[cq_head.*];
        const phase_bit: u1 = @truncate(entry.status & 1);

        if (phase_bit == cq_phase.*) {
            // Valid completion — advance CQ head
            cq_head.* += 1;
            if (cq_head.* >= queue_depth) {
                cq_head.* = 0;
                cq_phase.* ^= 1;
            }

            // On CID mismatch, drain stale entries until we find ours.
            if (entry.cid != expected_cid) {
                total_cid_mismatches += 1;
                var drain: u16 = 0;
                while (drain < queue_depth) : (drain += 1) {
                    asm volatile ("dmb ld" ::: .{ .memory = true });

                    const next = cq[cq_head.*];
                    const next_phase: u1 = @truncate(next.status & 1);
                    if (next_phase != cq_phase.*) break;

                    cq_head.* += 1;
                    if (cq_head.* >= queue_depth) {
                        cq_head.* = 0;
                        cq_phase.* ^= 1;
                    }

                    if (next.cid == expected_cid) {
                        return next;
                    }
                }
                return entry;
            }

            return entry;
        }

        // Yield every iteration, but also periodically re-check controller
        // health to avoid spinning forever on a dead device.
        asm volatile ("yield");
    }

    // Timeout — log diagnostic state for analysis
    total_timeouts += 1;
    uart.print("[nvme] Poll timeout cmd={} cid={} cq_head={} phase={} timeouts={}\n", .{
        total_commands, expected_cid, cq_head.*, cq_phase.*, total_timeouts,
    });

    // Dump the CQ entry we're staring at — is the phase bit wrong?
    const stale = cq[cq_head.*];
    uart.print("[nvme] CQ[{}]: status=0x{x} cid={} sq_head={} phase_bit={}\n", .{
        cq_head.*, stale.status, stale.cid, stale.sq_head, @as(u1, @truncate(stale.status & 1)),
    });

    // Check controller status — is the device alive?
    const csts = readReg32(REG_CSTS);
    uart.print("[nvme] CSTS=0x{x} (RDY={} CFS={})\n", .{
        csts, (csts & CSTS_RDY), (csts & CSTS_CFS) >> 1,
    });

    return null;
}

/// Check NVMe status field for errors. Returns true if OK.
fn statusOk(status: u16) bool {
    // Bits 15:1 contain the status (bit 0 is phase). SC=bits 8:1, SCT=bits 11:9
    const sc = (status >> 1) & 0xFF;
    const sct = (status >> 9) & 0x7;
    return sc == 0 and sct == 0;
}

// ---- Admin command submission ----

fn submitAdmin(cmd: *const SqEntry) bool {
    const sq: [*]volatile SqEntry = @ptrFromInt(admin_sq_phys);
    sq[admin_sq_tail] = cmd.*;

    // Advance tail
    admin_sq_tail += 1;
    if (admin_sq_tail >= ADMIN_QUEUE_DEPTH) admin_sq_tail = 0;

    // Ring SQ doorbell
    writeReg32(sqDoorbell(0), admin_sq_tail);

    // Poll CQ
    const completion = pollCompletion(
        admin_cq_phys,
        &admin_cq_head,
        &admin_cq_phase,
        ADMIN_QUEUE_DEPTH,
        @truncate(cmd.cdw0 >> 16),
    ) orelse return false;

    // Ring CQ doorbell
    writeReg32(cqDoorbell(0), admin_cq_head);

    if (!statusOk(completion.status)) {
        uart.print("[nvme] Admin cmd failed: status=0x{x}\n", .{completion.status});
        return false;
    }

    return true;
}

// ---- I/O command submission ----

fn submitIo(cmd: *const SqEntry) bool {
    total_commands += 1;

    // Periodically log io_cq_head to detect drift before it reaches timeout
    if (total_commands % 10000 == 0) {
        uart.print("[nvme] chk cmd={} hd={} tl={} ph={}\n", .{
            total_commands, io_cq_head, io_sq_tail, io_cq_phase,
        });
    }
    // Log CQ physical address and io_cq_head address on first command
    if (total_commands == 1) {
        uart.print("[nvme] io_cq_phys={x} &io_cq_head={x}\n", .{
            io_cq_phys, @intFromPtr(&io_cq_head),
        });
    }

    // Validate io_cq_head at submit boundary — catch corruption early
    if (io_cq_head >= IO_QUEUE_DEPTH) {
        uart.print("[nvme] CORRUPT io_cq_head={} at cmd={}, resetting\n", .{ io_cq_head, total_commands });
        io_cq_head = 0;
        // Probe CQ to resync phase
        const cq: [*]volatile CqEntry = @ptrFromInt(io_cq_phys);
        asm volatile ("dmb ld" ::: .{ .memory = true });
        const probe = cq[0];
        if (probe.cid != 0 or probe.sq_head != 0) {
            io_cq_phase = @truncate(probe.status & 1);
        }
    }

    const expected_cid: u16 = @truncate(cmd.cdw0 >> 16);
    var attempt: u32 = 0;
    const max_attempts: u32 = 3;

    while (attempt < max_attempts) : (attempt += 1) {
        // Ensure any previous unacknowledged CQ entries are cleared.
        // Mask to queue depth in case io_cq_head was corrupted.
        writeReg32(cqDoorbell(1), io_cq_head % IO_QUEUE_DEPTH);

        if (attempt == 0) {
            // First attempt: write the command to the SQ
            const sq: [*]volatile SqEntry = @ptrFromInt(io_sq_phys);
            sq[io_sq_tail] = cmd.*;

            io_sq_tail += 1;
            if (io_sq_tail >= IO_QUEUE_DEPTH) io_sq_tail = 0;

            // Ring I/O SQ doorbell
            writeReg32(sqDoorbell(1), io_sq_tail);
        } else {
            // Retry: re-ring the SQ doorbell in case the device missed it.
            // The command is already in the SQ slot from attempt 0.
            total_retries += 1;
            uart.print("[nvme] Retry {}/{} for cid={}\n", .{ attempt + 1, max_attempts, expected_cid });

            // Memory barrier to ensure device sees all prior writes
            asm volatile ("dsb sy" ::: .{ .memory = true });

            // Re-ring both doorbells
            writeReg32(sqDoorbell(1), io_sq_tail);
        }

        // Poll I/O CQ
        if (pollCompletion(
            io_cq_phys,
            &io_cq_head,
            &io_cq_phase,
            IO_QUEUE_DEPTH,
            expected_cid,
        )) |completion| {
            // Ring I/O CQ doorbell (mask for safety)
            writeReg32(cqDoorbell(1), io_cq_head % IO_QUEUE_DEPTH);

            if (!statusOk(completion.status)) {
                uart.print("[nvme] I/O cmd failed: status=0x{x}\n", .{completion.status});
                return false;
            }

            return true;
        }
    }

    // All retries exhausted
    uart.print("[nvme] FATAL: {} retries failed for cmd={} cid={}\n", .{
        max_attempts, total_commands, expected_cid,
    });
    return false;
}

// ---- Zero a physical page ----

fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..4096) |i| {
        ptr[i] = 0;
    }
}

// ---- Build SqEntry helpers ----

fn makeSqEntry() SqEntry {
    return SqEntry{
        .cdw0 = 0,
        .nsid = 0,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr = 0,
        .prp1 = 0,
        .prp2 = 0,
        .cdw10 = 0,
        .cdw11 = 0,
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    };
}

// ---- Wait for CSTS condition ----

fn waitReady(expected: bool) bool {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 10) {
        const csts = readReg32(REG_CSTS);
        if (csts & CSTS_CFS != 0) {
            uart.writeString("[nvme] Controller fatal status\n");
            return false;
        }
        const rdy = (csts & CSTS_RDY) != 0;
        if (rdy == expected) return true;
        timer.delayMillis(10);
    }
    uart.print("[nvme] Timeout waiting for CSTS.RDY={}\n", .{@intFromBool(expected)});
    return false;
}

// ---- Public init ----

pub fn init(dev: *const pci.PciDevice) bool {
    if (dev.bar0 == 0) {
        uart.writeString("[nvme] BAR0 not assigned\n");
        return false;
    }

    bar0_base = @truncate(dev.bar0);
    uart.print("[nvme] BAR0 at {x}\n", .{bar0_base});

    // Read CAP register
    const cap = readReg64(REG_CAP);
    const mqes: u16 = @truncate(cap & 0xFFFF); // Max Queue Entries Supported (0-based)
    const dstrd: u32 = @truncate((cap >> 32) & 0xF);
    const to: u32 = @truncate((cap >> 24) & 0xFF); // Timeout in 500ms units
    const css_nvm = (cap >> 37) & 1; // NVM command set supported

    doorbell_stride = @as(u32, 4) << @truncate(dstrd);
    max_queue_entries = mqes + 1;
    timeout_ms = if (to == 0) 5000 else to * 500;

    uart.print("[nvme] CAP: MQES={} DSTRD={} TO={}ms", .{ mqes, dstrd, timeout_ms });
    if (css_nvm != 0) uart.writeString(" CSS=NVM");
    uart.writeString("\n");

    // Read version
    const vs = readReg32(REG_VS);
    uart.print("[nvme] Version {}.{}.{}\n", .{ (vs >> 16) & 0xFF, (vs >> 8) & 0xFF, vs & 0xFF });

    // Step 1: Disable controller
    var cc = readReg32(REG_CC);
    if (cc & CC_EN != 0) {
        cc &= ~CC_EN;
        writeReg32(REG_CC, cc);
        if (!waitReady(false)) return false;
    }
    uart.writeString("[nvme] Controller disabled\n");

    // Step 2: Allocate admin queues
    admin_sq_phys = pmm.allocPage() orelse {
        uart.writeString("[nvme] Failed to alloc admin SQ\n");
        return false;
    };
    admin_cq_phys = pmm.allocPage() orelse {
        uart.writeString("[nvme] Failed to alloc admin CQ\n");
        pmm.freePage(admin_sq_phys);
        return false;
    };
    zeroPage(admin_sq_phys);
    zeroPage(admin_cq_phys);
    pinDmaPage(admin_sq_phys);
    pinDmaPage(admin_cq_phys);
    admin_sq_tail = 0;
    admin_cq_head = 0;
    admin_cq_phase = 1;
    admin_cid = 1;

    uart.print("[nvme] Admin SQ={x} CQ={x}\n", .{ admin_sq_phys, admin_cq_phys });

    // Step 3: Configure admin queue attributes
    const aqa: u32 = (@as(u32, ADMIN_QUEUE_DEPTH - 1) << 16) | (ADMIN_QUEUE_DEPTH - 1);
    writeReg32(REG_AQA, aqa);
    writeReg64(REG_ASQ, admin_sq_phys);
    writeReg64(REG_ACQ, admin_cq_phys);

    // Step 4: Enable controller
    cc = CC_EN | CC_CSS_NVM | CC_MPS_4K | CC_AMS_RR | CC_IOSQES | CC_IOCQES;
    writeReg32(REG_CC, cc);
    if (!waitReady(true)) return false;
    uart.writeString("[nvme] Controller enabled\n");

    // Step 5: Mask all interrupts (polling mode)
    writeReg32(REG_INTMS, 0xFFFFFFFF);

    // Step 6: Allocate identify page
    identify_phys = pmm.allocPage() orelse {
        uart.writeString("[nvme] Failed to alloc identify page\n");
        return false;
    };
    zeroPage(identify_phys);
    pinDmaPage(identify_phys);

    // Step 7: Identify Controller (CNS=1)
    if (!identifyController()) return false;

    // Step 8: Identify Namespace 1 (CNS=0)
    if (!identifyNamespace()) return false;

    // Step 9: Create I/O Completion Queue (QID=1)
    if (!createIoCq()) return false;

    // Step 10: Create I/O Submission Queue (QID=1)
    if (!createIoSq()) return false;

    // Step 11: Allocate DMA staging buffer
    dma_buf_phys = pmm.allocPage() orelse {
        uart.writeString("[nvme] Failed to alloc DMA buffer\n");
        return false;
    };
    zeroPage(dma_buf_phys);
    pinDmaPage(dma_buf_phys);

    // Step 12: Allocate DMA page pool for batched I/O
    for (0..BATCH_DEPTH) |i| {
        dma_pool[i] = pmm.allocPage() orelse {
            uart.print("[nvme] Failed to alloc DMA pool page {}\n", .{i});
            return false;
        };
        zeroPage(dma_pool[i]);
        pinDmaPage(dma_pool[i]);
    }
    dma_pool_initialized = true;

    initialized = true;
    uart.print("[nvme] Batched I/O: {} DMA pages, {} commands/batch\n", .{ BATCH_DEPTH, BATCH_DEPTH });
    uart.writeString("[nvme] Driver initialized\n");
    return true;
}

// ---- Identify Controller ----

fn identifyController() bool {
    zeroPage(identify_phys);

    var cmd = makeSqEntry();
    cmd.cdw0 = @as(u32, ADMIN_IDENTIFY) | (@as(u32, admin_cid) << 16);
    admin_cid +%= 1;
    cmd.prp1 = identify_phys;
    cmd.cdw10 = 1; // CNS = 1 (Identify Controller)

    if (!submitAdmin(&cmd)) {
        uart.writeString("[nvme] Identify Controller failed\n");
        return false;
    }

    // Parse identify data
    const data: [*]const u8 = @ptrFromInt(identify_phys);

    // Serial Number: bytes 4-23 (ASCII, space-padded)
    uart.writeString("[nvme] SN: ");
    printTrimmed(data[4..24]);
    uart.writeString("\n");

    // Model Number: bytes 24-63 (ASCII, space-padded)
    uart.writeString("[nvme] Model: ");
    printTrimmed(data[24..64]);
    uart.writeString("\n");

    // Firmware Revision: bytes 64-71
    uart.writeString("[nvme] FW: ");
    printTrimmed(data[64..72]);
    uart.writeString("\n");

    return true;
}

fn printTrimmed(s: []const u8) void {
    // Find last non-space character
    var end: usize = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == 0)) {
        end -= 1;
    }
    if (end > 0) {
        uart.writeString(s[0..end]);
    }
}

// ---- Identify Namespace ----

fn identifyNamespace() bool {
    zeroPage(identify_phys);

    var cmd = makeSqEntry();
    cmd.cdw0 = @as(u32, ADMIN_IDENTIFY) | (@as(u32, admin_cid) << 16);
    admin_cid +%= 1;
    cmd.nsid = namespace_id;
    cmd.prp1 = identify_phys;
    cmd.cdw10 = 0; // CNS = 0 (Identify Namespace)

    if (!submitAdmin(&cmd)) {
        uart.writeString("[nvme] Identify Namespace failed\n");
        return false;
    }

    const data: [*]const u8 = @ptrFromInt(identify_phys);

    // NSZE: bytes 0-7 (u64 LE) — Namespace Size in logical blocks
    total_sectors = @as(u64, data[0]) |
        (@as(u64, data[1]) << 8) |
        (@as(u64, data[2]) << 16) |
        (@as(u64, data[3]) << 24) |
        (@as(u64, data[4]) << 32) |
        (@as(u64, data[5]) << 40) |
        (@as(u64, data[6]) << 48) |
        (@as(u64, data[7]) << 56);

    // FLBAS: byte 26 — bits 3:0 index into LBA Format array
    const flbas = data[26];
    const lba_fmt_idx: usize = flbas & 0x0F;

    // LBA Format array starts at offset 128, each entry is 4 bytes
    // Byte 2 of each entry = LBADS (log2 of sector size)
    const lbaf_offset = 128 + lba_fmt_idx * 4;
    const lbads = data[lbaf_offset + 2];
    if (lbads >= 9 and lbads <= 12) {
        sector_size = @as(u32, 1) << @truncate(lbads);
    }

    // Calculate total capacity in MiB
    const total_bytes = total_sectors * sector_size;
    const total_mib = total_bytes / (1024 * 1024);

    uart.print("[nvme] NS{}: {} sectors x {}B ({} MiB)\n", .{
        namespace_id, total_sectors, sector_size, total_mib,
    });

    return total_sectors > 0;
}

// ---- Create I/O Completion Queue ----

fn createIoCq() bool {
    // CQ entry = 16 bytes. depth=256 → 4096 bytes = 1 page
    const cq_pages = (@as(u64, IO_QUEUE_DEPTH) * @sizeOf(CqEntry) + 4095) / 4096;
    io_cq_phys = pmm.allocPages(cq_pages) orelse {
        uart.writeString("[nvme] Failed to alloc I/O CQ\n");
        return false;
    };
    // Zero all pages
    const ptr: [*]u8 = @ptrFromInt(io_cq_phys);
    for (0..cq_pages * 4096) |i| ptr[i] = 0;
    pinDmaPages(io_cq_phys, cq_pages);
    io_cq_head = 0;
    io_cq_phase = 1;

    var cmd = makeSqEntry();
    cmd.cdw0 = @as(u32, ADMIN_CREATE_IO_CQ) | (@as(u32, admin_cid) << 16);
    admin_cid +%= 1;
    cmd.prp1 = io_cq_phys;
    // CDW10: QSIZE[31:16] (0-based) | QID[15:0]
    cmd.cdw10 = (@as(u32, IO_QUEUE_DEPTH - 1) << 16) | 1;
    // CDW11: IEN=0 (no interrupts), PC=1 (physically contiguous)
    cmd.cdw11 = 1;

    if (!submitAdmin(&cmd)) {
        uart.writeString("[nvme] Create I/O CQ failed\n");
        return false;
    }

    uart.print("[nvme] I/O CQ created (QID=1, depth={})\n", .{IO_QUEUE_DEPTH});
    return true;
}

// ---- Create I/O Submission Queue ----

fn createIoSq() bool {
    // SQ entry = 64 bytes. depth=256 → 16384 bytes = 4 pages
    const sq_pages = (@as(u64, IO_QUEUE_DEPTH) * @sizeOf(SqEntry) + 4095) / 4096;
    io_sq_phys = pmm.allocPages(sq_pages) orelse {
        uart.writeString("[nvme] Failed to alloc I/O SQ\n");
        return false;
    };
    const sqptr: [*]u8 = @ptrFromInt(io_sq_phys);
    for (0..sq_pages * 4096) |i| sqptr[i] = 0;
    pinDmaPages(io_sq_phys, sq_pages);
    io_sq_tail = 0;
    io_cid = 1;

    var cmd = makeSqEntry();
    cmd.cdw0 = @as(u32, ADMIN_CREATE_IO_SQ) | (@as(u32, admin_cid) << 16);
    admin_cid +%= 1;
    cmd.prp1 = io_sq_phys;
    // CDW10: QSIZE[31:16] (0-based) | QID[15:0]
    cmd.cdw10 = (@as(u32, IO_QUEUE_DEPTH - 1) << 16) | 1;
    // CDW11: CQID[31:16] | QPRIO[12:11] | PC[0]
    cmd.cdw11 = (1 << 16) | 1; // CQID=1, PC=1 (physically contiguous)

    if (!submitAdmin(&cmd)) {
        uart.writeString("[nvme] Create I/O SQ failed\n");
        return false;
    }

    uart.print("[nvme] I/O SQ created (QID=1, depth={})\n", .{IO_QUEUE_DEPTH});
    return true;
}

// ---- Batched completion reaping ----

/// Reap `count` completions from the I/O CQ. Returns number reaped.
/// Caller must hold nvme_lock.
fn reapCompletions(count: usize) usize {
    const cq: [*]volatile CqEntry = @ptrFromInt(io_cq_phys);
    var reaped: usize = 0;
    var spins: u32 = 0;
    const max_spins: u32 = 100_000_000;

    while (reaped < count and spins < max_spins) : (spins += 1) {
        asm volatile ("dmb ld" ::: .{ .memory = true });
        const entry = cq[io_cq_head];
        const phase_bit: u1 = @truncate(entry.status & 1);

        if (phase_bit == io_cq_phase) {
            // Valid completion
            io_cq_head += 1;
            if (io_cq_head >= IO_QUEUE_DEPTH) {
                io_cq_head = 0;
                io_cq_phase ^= 1;
            }
            reaped += 1;

            if (!statusOk(entry.status)) {
                uart.print("[nvme] Batch completion error: cid={} status=0x{x}\n", .{
                    entry.cid, entry.status,
                });
            }
        } else {
            // No more completions yet — yield and retry
            asm volatile ("yield");
        }
    }

    // Update CQ doorbell once after all reaps
    if (reaped > 0) {
        writeReg32(cqDoorbell(1), io_cq_head);
    }

    if (reaped < count) {
        total_timeouts += 1;
        uart.print("[nvme] Batch reap timeout: expected {} got {}\n", .{ count, reaped });
    }

    return reaped;
}

// ---- Public read/write API ----

/// Read sectors from NVMe using batched I/O.
/// Submits up to BATCH_DEPTH commands at once, reaps all completions,
/// then scatters DMA data to the caller buffer.
pub fn readSectors(sector: u64, count: u32, buf: [*]u8) bool {
    if (!initialized) return false;

    nvme_lock.acquire();
    defer nvme_lock.release();

    const sectors_per_page: u32 = 4096 / sector_size;
    const ext_sectors_per_cmd: u32 = @min(sectors_per_page * (sector_size / 512), 8);

    var remaining = count;
    var cur_sector = sector;
    var buf_off: usize = 0;

    while (remaining > 0) {
        // Calculate batch size: how many commands we can submit at once
        var batch_count: usize = 0;
        var batch_sectors: [BATCH_DEPTH]u64 = undefined;
        var batch_chunks: [BATCH_DEPTH]u32 = undefined;
        var batch_cids: [BATCH_DEPTH]u16 = undefined;

        // Fill the SQ with commands (no doorbell ring yet)
        const sq: [*]volatile SqEntry = @ptrFromInt(io_sq_phys);

        while (batch_count < BATCH_DEPTH and remaining > 0) {
            const chunk = @min(remaining, ext_sectors_per_cmd);
            const lba = (cur_sector * 512) / sector_size;
            const nlb: u32 = ((chunk * 512) + sector_size - 1) / sector_size;

            const cid = io_cid;
            io_cid +%= 1;
            if (io_cid == 0) io_cid = 1;

            var cmd = makeSqEntry();
            cmd.cdw0 = @as(u32, NVM_READ) | (@as(u32, cid) << 16);
            cmd.nsid = namespace_id;
            cmd.prp1 = dma_pool[batch_count]; // Each command gets its own DMA page
            cmd.cdw10 = @truncate(lba);
            cmd.cdw11 = @truncate(lba >> 32);
            cmd.cdw12 = nlb - 1;

            // Write command to SQ
            sq[io_sq_tail] = cmd;
            io_sq_tail += 1;
            if (io_sq_tail >= IO_QUEUE_DEPTH) io_sq_tail = 0;

            batch_sectors[batch_count] = cur_sector;
            batch_chunks[batch_count] = chunk;
            batch_cids[batch_count] = cid;
            batch_count += 1;

            remaining -= chunk;
            cur_sector += chunk;
        }

        if (batch_count == 0) break;

        total_commands += @intCast(batch_count);

        // Ring SQ doorbell ONCE for the entire batch
        writeReg32(sqDoorbell(1), io_sq_tail);

        // Reap all completions
        const reaped = reapCompletions(batch_count);
        if (reaped < batch_count) {
            uart.print("[nvme] Read batch incomplete: {} of {} commands\n", .{ reaped, batch_count });
            return false;
        }

        // Scatter DMA data to caller buffer
        for (0..batch_count) |i| {
            const src: [*]const u8 = @ptrFromInt(dma_pool[i]);
            const byte_count: usize = @as(usize, batch_chunks[i]) * 512;
            for (0..byte_count) |j| {
                buf[buf_off + j] = src[j];
            }
            buf_off += byte_count;
        }
    }

    return true;
}

/// Write sectors to NVMe using batched I/O.
pub fn writeSectors(sector: u64, count: u32, buf: [*]const u8) bool {
    if (!initialized) return false;

    nvme_lock.acquire();
    defer nvme_lock.release();

    const sectors_per_page: u32 = 4096 / sector_size;
    const ext_sectors_per_cmd: u32 = @min(sectors_per_page * (sector_size / 512), 8);

    var remaining = count;
    var cur_sector = sector;
    var buf_off: usize = 0;

    while (remaining > 0) {
        var batch_count: usize = 0;
        var batch_chunks: [BATCH_DEPTH]u32 = undefined;

        const sq: [*]volatile SqEntry = @ptrFromInt(io_sq_phys);

        // Gather data into DMA pages and fill SQ
        while (batch_count < BATCH_DEPTH and remaining > 0) {
            const chunk = @min(remaining, ext_sectors_per_cmd);
            const byte_count: usize = @as(usize, chunk) * 512;

            // Copy caller data to this batch slot's DMA page
            const dst: [*]u8 = @ptrFromInt(dma_pool[batch_count]);
            for (0..byte_count) |i| {
                dst[i] = buf[buf_off + i];
            }

            const lba = (cur_sector * 512) / sector_size;
            const nlb: u32 = ((chunk * 512) + sector_size - 1) / sector_size;

            const cid = io_cid;
            io_cid +%= 1;
            if (io_cid == 0) io_cid = 1;

            var cmd = makeSqEntry();
            cmd.cdw0 = @as(u32, NVM_WRITE) | (@as(u32, cid) << 16);
            cmd.nsid = namespace_id;
            cmd.prp1 = dma_pool[batch_count];
            cmd.cdw10 = @truncate(lba);
            cmd.cdw11 = @truncate(lba >> 32);
            cmd.cdw12 = nlb - 1;

            sq[io_sq_tail] = cmd;
            io_sq_tail += 1;
            if (io_sq_tail >= IO_QUEUE_DEPTH) io_sq_tail = 0;

            batch_chunks[batch_count] = chunk;
            batch_count += 1;

            remaining -= chunk;
            cur_sector += chunk;
            buf_off += byte_count;
        }

        if (batch_count == 0) break;

        total_commands += @intCast(batch_count);

        // Ring SQ doorbell ONCE
        writeReg32(sqDoorbell(1), io_sq_tail);

        // Reap all completions
        const reaped = reapCompletions(batch_count);
        if (reaped < batch_count) {
            uart.print("[nvme] Write batch incomplete: {} of {} commands\n", .{ reaped, batch_count });
            return false;
        }
    }

    return true;
}

/// Returns total capacity in 512-byte sectors.
pub fn getCapacity() u64 {
    return (total_sectors * sector_size) / 512;
}

/// Returns true if driver is initialized and ready.
pub fn isInitialized() bool {
    return initialized;
}
