/// ARM GICv2 (Generic Interrupt Controller) driver
/// QEMU virt machine uses GICv2:
/// - Distributor at 0x08000000
/// - CPU interface at 0x08010000
///
/// Equivalent to x86_64/pic.zig but for ARM64.

const uart = @import("uart.zig");
const smp = @import("smp.zig");
const fdt = @import("fdt.zig");
const gicv3 = @import("gicv3.zig");
const acpi = @import("acpi");

// Dynamic GICv2 MMIO bases — initialized from FDT config
var GICD_BASE: usize = 0x08000000;  // Distributor (default: QEMU virt)
var GICC_BASE: usize = 0x08010000;  // CPU Interface (default: QEMU virt)

// Distributor registers
const GICD_CTLR: usize = 0x000;       // Distributor Control
const GICD_TYPER: usize = 0x004;      // Interrupt Controller Type
const GICD_ISENABLER: usize = 0x100;  // Interrupt Set-Enable (array)
const GICD_ICENABLER: usize = 0x180;  // Interrupt Clear-Enable (array)
const GICD_ISPENDR: usize = 0x200;    // Interrupt Set-Pending (array)
const GICD_ICPENDR: usize = 0x280;    // Interrupt Clear-Pending (array)
const GICD_IPRIORITYR: usize = 0x400; // Interrupt Priority (array)
const GICD_ITARGETSR: usize = 0x800;  // Interrupt Processor Targets (array)
const GICD_ICFGR: usize = 0xC00;      // Interrupt Configuration (array)
const GICD_SGIR: usize = 0xF00;       // Software Generated Interrupt Register

// CPU Interface registers
const GICC_CTLR: usize = 0x000;       // CPU Interface Control
const GICC_PMR: usize = 0x004;        // Interrupt Priority Mask
const GICC_IAR: usize = 0x00C;        // Interrupt Acknowledge
const GICC_EOIR: usize = 0x010;       // End of Interrupt
const GICC_RPR: usize = 0x014;        // Running Priority
const GICC_HPPIR: usize = 0x018;      // Highest Priority Pending Interrupt

// Interrupt IDs
pub const IRQ_TIMER: u32 = 30;        // Physical timer (PPI)
pub const IRQ_UART: u32 = 33;         // PL011 UART (SPI, typically IRQ 1 + 32)
pub const IRQ_VIRTIO_NET: u32 = 48;   // virtio-net (SPI)
pub const IRQ_VIRTIO_BLK: u32 = 49;   // virtio-blk (SPI)

// SGI (Software Generated Interrupt) IDs — 0-15
pub const SGI_RESCHEDULE: u32 = 1;    // IPI: trigger reschedule on target CPU

// Special interrupt IDs
const SPURIOUS_IRQ: u32 = 1023;

// MMIO helpers
inline fn distWrite(offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(GICD_BASE + offset);
    ptr.* = value;
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

inline fn distRead(offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(GICD_BASE + offset);
    const val = ptr.*;
    asm volatile ("dsb sy" ::: .{ .memory = true });
    return val;
}

inline fn cpuWrite(offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(GICC_BASE + offset);
    ptr.* = value;
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

inline fn cpuRead(offset: usize) u32 {
    asm volatile ("dsb sy" ::: .{ .memory = true });
    const ptr: *volatile u32 = @ptrFromInt(GICC_BASE + offset);
    return ptr.*;
}

/// Probe GIC architecture version from GICD_PIDR2 register.
/// Returns ArchRev field: 1=GICv1, 2=GICv2, 3=GICv3, 4=GICv4.
/// Uses the default QEMU virt GICD address (0x08000000).
fn probeGicVersion() u8 {
    const pidr2_ptr: *volatile u32 = @ptrFromInt(GICD_BASE + 0xFFE8);
    const pidr2 = pidr2_ptr.*;
    return @truncate((pidr2 >> 4) & 0xF);
}

/// Full GIC init — dispatches to GICv2 (MMIO) or GICv3 (system registers).
/// Prefers ACPI MADT over FDT for hardware discovery (real hardware uses ACPI).
pub fn init() void {
    const acpi_cfg = &acpi.parser.config;

    if (acpi_cfg.valid and acpi_cfg.gicd_base != 0) {
        // ACPI path — real hardware with UEFI
        GICD_BASE = @truncate(acpi_cfg.gicd_base);
        if (acpi_cfg.gicc_base != 0) GICC_BASE = @truncate(acpi_cfg.gicc_base);

        if (acpi_cfg.gic_version >= 3) {
            // Bridge: inject ACPI values into fdt.config for gicv3.init()
            fdt.config.gicd_base = acpi_cfg.gicd_base;
            fdt.config.gicr_base = acpi_cfg.gicr_base;
            fdt.config.gic_version = .v3;
            gicv3.init();
        } else {
            initDistributor();
            initCpuInterface();
            uart.writeString("[gic]  GICv2 initialized (ACPI MADT)\n");
        }
    } else if (fdt.config.valid) {
        // FDT path — QEMU virt with DTB or U-Boot
        GICD_BASE = @truncate(fdt.config.gicd_base);
        GICC_BASE = @truncate(fdt.config.gicc_base);

        if (fdt.config.gic_version == .v3) {
            gicv3.init();
        } else {
            initDistributor();
            initCpuInterface();
            uart.writeString("[gic]  GICv2 initialized\n");
        }
    } else {
        // No ACPI, no FDT — probe hardware directly (bare -kernel on QEMU virt)
        const arch_rev = probeGicVersion();
        if (arch_rev >= 3) {
            // GICv3 detected — set QEMU virt defaults for redistributor
            fdt.config.gicd_base = 0x08000000;
            fdt.config.gicr_base = 0x080A0000;
            fdt.config.gic_version = .v3;
            uart.writeString("[gic]  GICv3 detected via GICD_PIDR2 probe\n");
            gicv3.init();
        } else {
            initDistributor();
            initCpuInterface();
            uart.writeString("[gic]  GICv2 initialized\n");
        }
    }
}

/// Initialize GIC distributor — call once from BSP only.
pub fn initDistributor() void {
    // Disable distributor while configuring
    distWrite(GICD_CTLR, 0);

    // Read number of interrupt lines
    const typer = distRead(GICD_TYPER);
    const num_irqs = ((typer & 0x1F) + 1) * 32;

    // Disable all interrupts
    var i: usize = 0;
    while (i < num_irqs / 32) : (i += 1) {
        distWrite(GICD_ICENABLER + i * 4, 0xFFFFFFFF);
    }

    // Set all interrupts to lowest priority (0xFF)
    i = 0;
    while (i < num_irqs / 4) : (i += 1) {
        distWrite(GICD_IPRIORITYR + i * 4, 0xFFFFFFFF);
    }

    // Target all SPIs to CPU 0
    i = 8; // Skip SGIs and PPIs (first 32 interrupts)
    while (i < num_irqs / 4) : (i += 1) {
        distWrite(GICD_ITARGETSR + i * 4, 0x01010101);
    }

    // Configure all SPIs as level-triggered
    i = 2; // Skip SGIs (first 16 interrupts)
    while (i < num_irqs / 16) : (i += 1) {
        distWrite(GICD_ICFGR + i * 4, 0);
    }

    // Enable distributor (group 0 and group 1)
    distWrite(GICD_CTLR, 0x3);
}

/// Initialize GIC CPU interface — call on each CPU (BSP and secondaries).
pub fn initCpuInterface() void {
    if (fdt.config.gic_version == .v3) {
        gicv3.initRedistributor();
        gicv3.initCpuInterface();
        return;
    }
    // GICv2 MMIO CPU interface
    // Set priority mask to allow all priorities
    cpuWrite(GICC_PMR, 0xFF);

    // Enable CPU interface (group 0 and group 1)
    cpuWrite(GICC_CTLR, 0x3);
}

/// Send a Software Generated Interrupt to a specific CPU.
pub fn sendSGI(target_cpu: u32, sgi_id: u32) void {
    if (fdt.config.gic_version == .v3) {
        gicv3.sendSGI(target_cpu, sgi_id);
        return;
    }
    // GICv2 GICD_SGIR format:
    //   [3:0]   = SGI ID (0-15)
    //   [23:16] = target list (bitmask of CPUs)
    //   [25:24] = target filter (0b00 = use target list)
    const target_mask: u32 = @as(u32, 1) << @as(u5, @truncate(target_cpu));
    distWrite(GICD_SGIR, (sgi_id & 0xF) | (target_mask << 16));
}

/// Send a Software Generated Interrupt to all CPUs except self.
pub fn sendSGIAllOther(sgi_id: u32) void {
    // Target filter 0b01 = all except self
    distWrite(GICD_SGIR, (sgi_id & 0xF) | (1 << 24));
}

/// Enable a specific interrupt
pub fn enableIrq(irq: u32) void {
    if (fdt.config.gic_version == .v3) {
        gicv3.enableIrq(irq);
        return;
    }
    const reg_index = irq / 32;
    const bit_index: u5 = @intCast(irq % 32);
    distWrite(GICD_ISENABLER + reg_index * 4, @as(u32, 1) << bit_index);
}

/// Disable a specific interrupt
pub fn disableIrq(irq: u32) void {
    const reg_index = irq / 32;
    const bit_index: u5 = @intCast(irq % 32);
    distWrite(GICD_ICENABLER + reg_index * 4, @as(u32, 1) << bit_index);
}

/// Set interrupt priority (lower value = higher priority)
pub fn setPriority(irq: u32, priority: u8) void {
    if (fdt.config.gic_version == .v3) {
        gicv3.setPriority(irq, priority);
        return;
    }
    const reg_index = irq / 4;
    const byte_offset: u5 = @intCast((irq % 4) * 8);
    const current = distRead(GICD_IPRIORITYR + reg_index * 4);
    const mask = ~(@as(u32, 0xFF) << byte_offset);
    const new_value = (current & mask) | (@as(u32, priority) << byte_offset);
    distWrite(GICD_IPRIORITYR + reg_index * 4, new_value);
}

/// Acknowledge an interrupt (returns IRQ number)
pub fn acknowledge() u32 {
    if (fdt.config.gic_version == .v3) return gicv3.acknowledge();
    return cpuRead(GICC_IAR) & 0x3FF;
}

/// Signal end of interrupt
pub fn endOfInterrupt(irq: u32) void {
    if (fdt.config.gic_version == .v3) {
        gicv3.endOfInterrupt(irq);
        return;
    }
    cpuWrite(GICC_EOIR, irq);
}

var lpi_log_count: u32 = 0;

/// Dispatch an IRQ to the correct handler
fn dispatchIrq(irq: u32) void {
    const virtio_blk = @import("virtio_blk.zig");
    const nic_mod = @import("nic.zig");

    if (irq == IRQ_TIMER) {
        const timer = @import("timer.zig");
        timer.interrupt();
    } else if (irq == IRQ_UART) {
        uart.rxInterrupt();
    } else if (virtio_blk.irq != 0 and irq == virtio_blk.irq) {
        virtio_blk.handleIrq();
    } else if (irq >= 8192) {
        // LPI (from GICv3 ITS, MSI-X) — check if it matches a NIC LPI
        if (nic_mod.irq != 0 and irq >= nic_mod.irq and irq < nic_mod.irq + 16) {
            // Log which vector fired (0=TX ntfy, 1=RX ntfy, 2=mgmt)
            if (lpi_log_count < 10) {
                uart.print("[gic]  LPI {} (vec={})\n", .{ irq, irq - nic_mod.irq });
                lpi_log_count += 1;
            }
            nic_mod.handleIrq();
        } else {
            uart.print("[gic]  Unhandled LPI {}\n", .{irq});
        }
    } else if (nic_mod.irq != 0 and irq == nic_mod.irq) {
        nic_mod.handleIrq();
    } else {
        uart.print("[gic]  Unhandled IRQ {} (blk_irq={}, net_irq={})\n", .{ irq, virtio_blk.irq, nic_mod.irq });
    }
}

/// Main IRQ handler - called from exception vector (no frame)
pub fn handleIrq() void {
    const irq = acknowledge();
    if (irq == SPURIOUS_IRQ) return;
    dispatchIrq(irq);
    endOfInterrupt(irq);
}

/// IRQ handler with TrapFrame access - for scheduler preemption
pub fn handleIrqWithFrame(frame: *@import("exception.zig").TrapFrame) void {
    const irq = acknowledge();
    if (irq == SPURIOUS_IRQ) return;

    // Timer needs the frame for preemptive scheduling
    if (irq == IRQ_TIMER) {
        const timer = @import("timer.zig");
        timer.interruptWithFrame(frame);
    } else if (irq == SGI_RESCHEDULE) {
        // IPI reschedule: force context switch on this CPU.
        // Needed when: (a) CPU is idle and a process became ready, or
        // (b) current process was marked zombie by exit_group on another CPU.
        const scheduler = @import("scheduler.zig");
        const cpu = smp.current();
        const is_killed = if (cpu.current_process) |p| (p.state == .zombie or p.killed) else false;
        if (is_killed or cpu.idle) {
            // Ensure killed processes have zombie state restored (may have been
            // overwritten by a concurrent syscall handler setting blocked state)
            if (cpu.current_process) |p| {
                if (p.killed and p.state != .zombie) {
                    p.state = .zombie;
                }
            }
            // Force immediate context switch — expire the timeslice so timerTick
            // performs a full save+switch instead of returning early.
            // Without this, idle CPUs retain a positive slice_remaining from before
            // they went idle, causing timerTick to return at the slice_remaining > 0
            // check before reaching the idle pickup path.
            cpu.slice_remaining = 0;
        }
        if (cpu.idle or is_killed) {
            scheduler.timerTick(frame);
        }
    } else {
        dispatchIrq(irq);
    }

    endOfInterrupt(irq);
}
