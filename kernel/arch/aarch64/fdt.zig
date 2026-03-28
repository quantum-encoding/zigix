/// Flattened Device Tree (FDT) parser for ARM64.
///
/// Parses the DTB blob passed by the bootloader in X0 to discover hardware:
/// - Memory regions (RAM base + size)
/// - UART controller address
/// - GIC distributor and CPU interface addresses
/// - Timer interrupt configuration
///
/// The FDT format is defined in the Devicetree Specification.
/// All multi-byte values in the DTB are big-endian.

const uart = @import("uart.zig");

// ============================================================================
// FDT constants
// ============================================================================

const FDT_MAGIC: u32 = 0xd00dfeed;
const FDT_BEGIN_NODE: u32 = 0x00000001;
const FDT_END_NODE: u32 = 0x00000002;
const FDT_PROP: u32 = 0x00000003;
const FDT_NOP: u32 = 0x00000004;
const FDT_END: u32 = 0x00000009;

// ============================================================================
// Hardware configuration — populated by parsing
// ============================================================================

pub const MemRegion = struct {
    base: u64 = 0,
    size: u64 = 0,
};

pub const GicVersion = enum { v2, v3 };
pub const UartType = enum { pl011, ns16550 };
pub const PsciConduit = enum { hvc, smc };

pub const HwConfig = struct {
    /// RAM regions discovered from /memory nodes
    ram: [4]MemRegion = [_]MemRegion{.{}} ** 4,
    ram_count: u8 = 0,

    /// UART base address (PL011 or NS16550)
    uart_base: u64 = 0x09000000, // QEMU virt default
    uart_type: UartType = .pl011,

    /// GIC distributor and CPU interface / redistributor
    gicd_base: u64 = 0x08000000, // QEMU virt default
    gicc_base: u64 = 0x08010000, // QEMU virt default (GICv2 CPU iface)
    gicr_base: u64 = 0,          // GICv3 redistributor (0 = not present)
    gic_version: GicVersion = .v2,

    /// Timer interrupt IDs (PPI numbers from device tree)
    timer_irq_phys: u32 = 30, // default: PPI 14 (30 = 16 + 14)

    /// Number of CPUs
    cpu_count: u8 = 1,

    /// PSCI conduit (HVC for QEMU virt, SMC for real hardware)
    psci_conduit: PsciConduit = .hvc,

    /// PL031 RTC base address
    rtc_base: u64 = 0x09010000, // QEMU virt default

    /// NVMe controller from device tree (non-PCIe, e.g., platform NVMe)
    nvme_base: u64 = 0,

    /// SD/eMMC controller base address (SDHCI)
    sdhci_base: u64 = 0,

    /// Whether DTB was successfully parsed
    valid: bool = false,
};

/// Global hardware config — defaults to QEMU virt values
pub var config = HwConfig{};

// ============================================================================
// FDT header
// ============================================================================

const FdtHeader = struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

fn readHeader(base: [*]const u8) ?FdtHeader {
    const magic = readBE32(base[0..4]);
    if (magic != FDT_MAGIC) return null;

    return FdtHeader{
        .magic = magic,
        .totalsize = readBE32(base[4..8]),
        .off_dt_struct = readBE32(base[8..12]),
        .off_dt_strings = readBE32(base[12..16]),
        .off_mem_rsvmap = readBE32(base[16..20]),
        .version = readBE32(base[20..24]),
        .last_comp_version = readBE32(base[24..28]),
        .boot_cpuid_phys = readBE32(base[28..32]),
        .size_dt_strings = readBE32(base[32..36]),
        .size_dt_struct = readBE32(base[36..40]),
    };
}

// ============================================================================
// Byte-swap helpers (FDT is big-endian, ARM64 is little-endian)
// ============================================================================

fn readBE32(ptr: *const [4]u8) u32 {
    return @as(u32, ptr[0]) << 24 |
        @as(u32, ptr[1]) << 16 |
        @as(u32, ptr[2]) << 8 |
        @as(u32, ptr[3]);
}

fn readBE64(ptr: *const [8]u8) u64 {
    return @as(u64, readBE32(ptr[0..4])) << 32 |
        @as(u64, readBE32(ptr[4..8]));
}

// ============================================================================
// String comparison
// ============================================================================

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn strStartsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (0..prefix.len) |i| {
        if (haystack[i] != prefix[i]) return false;
    }
    return true;
}

/// Get a null-terminated string length
fn strlen(ptr: [*]const u8) usize {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {
        if (len > 256) break; // safety limit
    }
    return len;
}

/// Get a string from the strings block
fn getString(base: [*]const u8, strings_off: u32, name_off: u32) []const u8 {
    const ptr = base + strings_off + name_off;
    const len = strlen(ptr);
    return ptr[0..len];
}

// ============================================================================
// FDT walker — state machine that walks the structure block
// ============================================================================

/// Parse the FDT and populate config
pub fn parse(dtb: ?*anyopaque) void {
    const ptr = dtb orelse return;
    const base: [*]const u8 = @ptrCast(ptr);

    const hdr = readHeader(base) orelse {
        uart.writeString("[fdt] Invalid DTB magic\n");
        return;
    };

    if (hdr.version < 17) {
        uart.writeString("[fdt] DTB version too old\n");
        return;
    }

    uart.print("[fdt] DTB v{}, size {} bytes\n", .{ hdr.version, hdr.totalsize });

    // Walk the structure block
    const struct_base = base + hdr.off_dt_struct;
    const strings_off = hdr.off_dt_strings;
    var offset: u32 = 0;
    const struct_size = hdr.size_dt_struct;

    // Node path tracking (depth-based)
    var depth: u32 = 0;
    var node_name_buf: [64]u8 = undefined;
    var node_name_len: u8 = 0;

    // Track current node's "compatible" and "reg" for device matching
    var cur_compatible: [64]u8 = undefined;
    var cur_compatible_len: u8 = 0;
    var cur_reg: [32]u8 = undefined;
    var cur_reg_len: u8 = 0;
    var in_memory_node = false;
    var in_cpus_node = false;
    var in_psci_node = false;
    var cpu_count: u8 = 0;
    // Address/size cells for current context
    var address_cells: u32 = 2;
    var size_cells: u32 = 1;

    while (offset + 4 <= struct_size) {
        const token = readBE32((struct_base + offset)[0..4]);
        offset += 4;

        switch (token) {
            FDT_BEGIN_NODE => {
                // Node name is a null-terminated string
                const name_ptr = struct_base + offset;
                const name_len = strlen(name_ptr);

                // Save node name for property matching
                const copy_len: u8 = if (name_len > 63) 63 else @truncate(name_len);
                for (0..copy_len) |i| {
                    node_name_buf[i] = name_ptr[i];
                }
                node_name_len = copy_len;

                // Check for specific nodes
                const name = name_ptr[0..name_len];
                in_memory_node = strStartsWith(name, "memory");
                in_cpus_node = (depth == 0 and strEql(name, "cpus")) or
                    (in_cpus_node and depth > 0);
                if (depth == 0 and strEql(name, "psci")) in_psci_node = true;

                // Count CPU nodes (children of /cpus with name starting "cpu@")
                if (in_cpus_node and strStartsWith(name, "cpu@")) {
                    cpu_count += 1;
                }

                // Reset per-node state
                cur_compatible_len = 0;
                cur_reg_len = 0;

                // Advance past null-terminated name, aligned to 4 bytes
                offset += @truncate((name_len + 1 + 3) & ~@as(u32, 3));
                depth += 1;
            },

            FDT_END_NODE => {
                // Before leaving this node, process any accumulated properties
                if (in_memory_node and cur_reg_len >= 16 and depth == 1) {
                    // /memory node: reg = <base(8) size(8)>
                    processMemoryReg(cur_reg[0..cur_reg_len], address_cells, size_cells);
                }

                if (cur_compatible_len > 0) {
                    const compat = cur_compatible[0..cur_compatible_len];
                    if (cur_reg_len > 0) {
                        processDeviceNode(compat, cur_reg[0..cur_reg_len], address_cells);
                    }
                }

                if (depth > 0) depth -= 1;
                if (depth == 0) {
                    in_cpus_node = false;
                    in_psci_node = false;
                }
                in_memory_node = false;
            },

            FDT_PROP => {
                if (offset + 8 > struct_size) break;

                const prop_len = readBE32((struct_base + offset)[0..4]);
                const name_off = readBE32((struct_base + offset + 4)[0..4]);
                offset += 8;

                const prop_name = getString(base, strings_off, name_off);
                const prop_data = (struct_base + offset)[0..prop_len];

                // Capture relevant properties
                if (strEql(prop_name, "compatible") and prop_len > 0) {
                    const copy_len: u8 = if (prop_len > 63) 63 else @truncate(prop_len);
                    for (0..copy_len) |i| {
                        cur_compatible[i] = prop_data[i];
                    }
                    cur_compatible_len = copy_len;
                } else if (strEql(prop_name, "reg") and prop_len > 0) {
                    const copy_len: u8 = if (prop_len > 31) 31 else @truncate(prop_len);
                    for (0..copy_len) |i| {
                        cur_reg[i] = prop_data[i];
                    }
                    cur_reg_len = copy_len;
                } else if (strEql(prop_name, "#address-cells") and prop_len == 4) {
                    address_cells = readBE32(prop_data[0..4]);
                } else if (strEql(prop_name, "#size-cells") and prop_len == 4) {
                    size_cells = readBE32(prop_data[0..4]);
                } else if (in_psci_node and strEql(prop_name, "method") and prop_len > 0) {
                    // PSCI method: "hvc" or "smc"
                    if (prop_len >= 3 and prop_data[0] == 's' and prop_data[1] == 'm' and prop_data[2] == 'c') {
                        config.psci_conduit = .smc;
                    } else {
                        config.psci_conduit = .hvc;
                    }
                }

                // Advance past property data, aligned to 4 bytes
                offset += (prop_len + 3) & ~@as(u32, 3);
            },

            FDT_NOP => {},

            FDT_END => break,

            else => {
                // Unknown token — skip
                break;
            },
        }
    }

    // Store CPU count
    if (cpu_count > 0) {
        config.cpu_count = cpu_count;
    }

    config.valid = true;

    // Log what we found
    logConfig();
}

/// Process /memory node reg property
fn processMemoryReg(data: []const u8, addr_cells: u32, size_cells: u32) void {
    if (config.ram_count >= 4) return;

    const addr_bytes: usize = @as(usize, addr_cells) * 4;
    const size_bytes: usize = @as(usize, size_cells) * 4;

    if (data.len < addr_bytes + size_bytes) return;

    const base = if (addr_cells == 2 and data.len >= 8)
        readBE64(data[0..8])
    else if (addr_cells == 1 and data.len >= 4)
        @as(u64, readBE32(data[0..4]))
    else
        return;

    const size = if (size_cells == 2 and data.len >= addr_bytes + 8)
        readBE64(data[addr_bytes..][0..8])
    else if (size_cells == 1 and data.len >= addr_bytes + 4)
        @as(u64, readBE32(data[addr_bytes..][0..4]))
    else
        return;

    const idx = config.ram_count;
    config.ram[idx] = .{ .base = base, .size = size };
    config.ram_count += 1;
}

/// Process a device node by matching its compatible string
fn processDeviceNode(compat: []const u8, reg: []const u8, addr_cells: u32) void {
    // compatible is a null-separated string list — match first entry
    var first_compat_len: usize = 0;
    while (first_compat_len < compat.len and compat[first_compat_len] != 0) {
        first_compat_len += 1;
    }
    const first_compat = compat[0..first_compat_len];

    // Read base address from reg property
    const base_addr: u64 = if (addr_cells == 2 and reg.len >= 8)
        readBE64(reg[0..8])
    else if (reg.len >= 4)
        @as(u64, readBE32(reg[0..4]))
    else
        return;

    // Match known devices
    if (strStartsWith(first_compat, "arm,pl011")) {
        config.uart_base = base_addr;
        config.uart_type = .pl011;
    } else if (strStartsWith(first_compat, "ns16550") or
        strStartsWith(first_compat, "snps,dw-apb-uart"))
    {
        config.uart_base = base_addr;
        config.uart_type = .ns16550;
    } else if (strStartsWith(first_compat, "arm,gic-v3")) {
        // GICv3: reg[0] = distributor, reg[1] = redistributor
        config.gicd_base = base_addr;
        config.gic_version = .v3;
        const addr_bytes: usize = @as(usize, addr_cells) * 4;
        const skip = addr_bytes + addr_bytes; // base + size of first range
        if (reg.len >= skip + addr_bytes) {
            if (addr_cells == 2 and reg.len >= skip + 8) {
                config.gicr_base = readBE64(reg[skip..][0..8]);
            } else if (reg.len >= skip + 4) {
                config.gicr_base = @as(u64, readBE32(reg[skip..][0..4]));
            }
        }
    } else if (strStartsWith(first_compat, "arm,pl031")) {
        config.rtc_base = base_addr;
    } else if (strStartsWith(first_compat, "arm,cortex-a15-gic") or
        strStartsWith(first_compat, "arm,gic-400"))
    {
        // GICv2: reg[0] = distributor, reg[1] = CPU interface
        config.gicd_base = base_addr;
        config.gic_version = .v2;
        const addr_bytes: usize = @as(usize, addr_cells) * 4;
        const skip = addr_bytes + addr_bytes; // base + size of first range
        if (reg.len >= skip + addr_bytes) {
            if (addr_cells == 2 and reg.len >= skip + 8) {
                config.gicc_base = readBE64(reg[skip..][0..8]);
            } else if (reg.len >= skip + 4) {
                config.gicc_base = @as(u64, readBE32(reg[skip..][0..4]));
            }
        }
    } else if (strStartsWith(first_compat, "arasan,sdhci") or
        strStartsWith(first_compat, "brcm,bcm2711-emmc2") or
        strStartsWith(first_compat, "brcm,bcm2835-sdhci") or
        strStartsWith(first_compat, "samsung,exynos4210-sdhci") or
        strStartsWith(first_compat, "ti,omap-hsmmc") or
        strStartsWith(first_compat, "generic-sdhci"))
    {
        config.sdhci_base = base_addr;
    } else if (strStartsWith(first_compat, "nvme")) {
        // Platform NVMe (non-PCIe) — rare but possible in some SoCs
        config.nvme_base = base_addr;
    }
}

/// Log discovered hardware configuration
fn logConfig() void {
    if (config.ram_count > 0) {
        for (0..config.ram_count) |i| {
            uart.print("[fdt] RAM region {}: base={x} size={x} ({} MB)\n", .{
                i,
                config.ram[i].base,
                config.ram[i].size,
                config.ram[i].size / (1024 * 1024),
            });
        }
    } else {
        uart.writeString("[fdt] No memory regions found (using defaults)\n");
    }

    uart.print("[fdt] UART base: {x}\n", .{config.uart_base});
    if (config.uart_type == .ns16550) {
        uart.writeString("[fdt] UART type: NS16550\n");
    } else {
        uart.writeString("[fdt] UART type: PL011\n");
    }
    if (config.gic_version == .v3) {
        uart.print("[fdt] GICv3 dist: {x}, redist: {x}\n", .{ config.gicd_base, config.gicr_base });
    } else {
        uart.print("[fdt] GICv2 dist: {x}, CPU: {x}\n", .{ config.gicd_base, config.gicc_base });
    }
    if (config.psci_conduit == .smc) {
        uart.writeString("[fdt] PSCI conduit: SMC\n");
    } else {
        uart.writeString("[fdt] PSCI conduit: HVC\n");
    }
    uart.print("[fdt] CPUs: {}\n", .{config.cpu_count});
}

/// Get total RAM size (sum of all regions, or default 256MB)
pub fn getTotalRamSize() u64 {
    if (config.ram_count == 0) return 256 * 1024 * 1024;
    var total: u64 = 0;
    for (0..config.ram_count) |i| {
        total += config.ram[i].size;
    }
    return total;
}

/// Get primary RAM base address
pub fn getRamBase() u64 {
    if (config.ram_count > 0) return config.ram[0].base;
    return 0x40000000; // QEMU virt default
}
