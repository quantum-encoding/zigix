/// ACPI core parser — RSDP validation, XSDT/RSDT walk, MADT and MCFG extraction.
///
/// Architecture-independent: uses acpi_io.physToVirt() for memory access.
/// Call acpi_io.init() before using this module.

const tables = @import("acpi_tables.zig");
const io = @import("acpi_io.zig");

/// Parsed ACPI configuration — populated by init().
pub const AcpiConfig = struct {
    valid: bool = false,

    // MADT — GIC topology (ARM64)
    gicd_base: u64 = 0,
    gicc_base: u64 = 0,
    gicr_base: u64 = 0,
    gicr_length: u32 = 0,
    gic_version: u8 = 0, // from GICD entry: 1=v1, 2=v2, 3=v3, 4=v4
    gic_its_base: u64 = 0,
    cpu_count: u8 = 0, // from GICC entry count

    // MADT — APIC topology (x86_64)
    lapic_addr: u32 = 0, // Local APIC base from MADT header
    ioapic_addr: u32 = 0,
    ioapic_gsi_base: u32 = 0,
    apic_ids: [16]u8 = [_]u8{0} ** 16, // up to 16 Local APIC IDs
    apic_count: u8 = 0,

    // MCFG — PCIe ECAM configuration
    ecam_base: u64 = 0,
    ecam_segment: u16 = 0,
    ecam_start_bus: u8 = 0,
    ecam_end_bus: u8 = 0,
    ecam_valid: bool = false,

    // GTDT — SBSA Generic Watchdog (ARM64)
    wdog_refresh_base: u64 = 0,
    wdog_control_base: u64 = 0,
    wdog_gsiv: u32 = 0,
    wdog_valid: bool = false,

    // Table directory — for future lookups by signature
    table_count: u8 = 0,
    table_sigs: [MAX_TABLES][4]u8 = [_][4]u8{[_]u8{0} ** 4} ** MAX_TABLES,
    table_addrs: [MAX_TABLES]u64 = [_]u64{0} ** MAX_TABLES,
};

const MAX_TABLES = 16;

pub var config: AcpiConfig = .{};

/// Initialize ACPI from RSDP physical address.
/// Returns true on success, false if RSDP is invalid or no tables found.
pub fn init(rsdp_phys: u64) bool {
    if (rsdp_phys == 0) return false;

    config = .{};

    // Step 1: Validate RSDP
    const rsdp_virt = io.physToVirt(rsdp_phys);
    const rsdp: *align(1) const tables.Rsdp = @ptrFromInt(rsdp_virt);

    if (!sigEql(&rsdp.signature, "RSD PTR ")) {
        io.log("[acpi] RSDP signature mismatch\n");
        return false;
    }

    // Checksum: sum of first 20 bytes must be 0 (ACPI 1.0 portion)
    const rsdp_bytes: [*]const u8 = @ptrFromInt(rsdp_virt);
    if (!checksumValid(rsdp_bytes, 20)) {
        io.log("[acpi] RSDP checksum FAILED\n");
        return false;
    }

    io.log("[acpi] RSDP valid (rev ");
    io.logDec(rsdp.revision);
    io.log(", OEM ");
    io.writeString(rsdp.oem_id[0..6]);
    io.log(")\n");

    // Step 2: Get XSDT or RSDT address
    var use_xsdt = false;
    var sdt_phys: u64 = 0;

    // Read XSDT address manually (unaligned-safe)
    const xsdt_addr = readU64(rsdp_virt + 0x18);
    if (rsdp.revision >= 2 and xsdt_addr != 0) {
        // ACPI 2.0+: verify extended checksum (all 36 bytes)
        if (!checksumValid(rsdp_bytes, 36)) {
            io.log("[acpi] RSDP extended checksum FAILED, falling back to RSDT\n");
        } else {
            use_xsdt = true;
            sdt_phys = xsdt_addr;
        }
    }

    if (!use_xsdt) {
        sdt_phys = rsdp.rsdt_address;
    }

    if (sdt_phys == 0) {
        io.log("[acpi] No XSDT or RSDT address\n");
        return false;
    }

    // Step 3: Walk XSDT/RSDT entries
    const sdt_virt = io.physToVirt(sdt_phys);
    const sdt_header: *align(1) const tables.SdtHeader = @ptrFromInt(sdt_virt);

    // Validate SDT checksum
    const sdt_bytes: [*]const u8 = @ptrFromInt(sdt_virt);
    if (!checksumValid(sdt_bytes, sdt_header.length)) {
        io.log("[acpi] ");
        io.writeString(sdt_header.signature[0..4]);
        io.log(" checksum FAILED\n");
        return false;
    }

    if (use_xsdt) {
        io.log("[acpi] XSDT at 0x");
    } else {
        io.log("[acpi] RSDT at 0x");
    }
    io.logHex(sdt_phys);
    io.log("\n");

    // Entry size: 8 bytes for XSDT (u64), 4 bytes for RSDT (u32)
    const entry_size: u32 = if (use_xsdt) 8 else 4;
    const header_size: u32 = @sizeOf(tables.SdtHeader);

    if (sdt_header.length < header_size) return false;
    const payload_len = sdt_header.length - header_size;
    const entry_count = payload_len / entry_size;

    var i: u32 = 0;
    while (i < entry_count and config.table_count < MAX_TABLES) : (i += 1) {
        const entry_offset = sdt_virt + header_size + @as(u64, i) * entry_size;

        const table_phys: u64 = if (use_xsdt)
            readU64(entry_offset)
        else
            @as(u64, readU32(entry_offset));

        if (table_phys == 0) continue;

        const table_virt = io.physToVirt(table_phys);
        const table_hdr: *align(1) const tables.SdtHeader = @ptrFromInt(table_virt);

        // Store in directory
        const idx = config.table_count;
        config.table_sigs[idx] = table_hdr.signature;
        config.table_addrs[idx] = table_phys;
        config.table_count += 1;

        io.log("[acpi] Table: ");
        io.writeString(table_hdr.signature[0..4]);
        io.log(" at 0x");
        io.logHex(table_phys);
        io.log(" (");
        io.logDec(table_hdr.length);
        io.log(" bytes)\n");
    }

    // Step 4: Parse MADT if present
    if (findTable("APIC")) |madt_phys| {
        parseMadt(madt_phys);
    }

    // Step 5: Parse MCFG if present
    if (findTable("MCFG")) |mcfg_phys| {
        parseMcfg(mcfg_phys);
    }

    // Step 6: Parse GTDT if present (ARM64 watchdog + timer info)
    if (findTable("GTDT")) |gtdt_phys| {
        parseGtdt(gtdt_phys);
    }

    config.valid = true;
    return true;
}

/// Find a table by its 4-byte signature. Returns physical address or null.
pub fn findTable(sig: *const [4]u8) ?u64 {
    for (0..config.table_count) |i| {
        if (config.table_sigs[i][0] == sig[0] and
            config.table_sigs[i][1] == sig[1] and
            config.table_sigs[i][2] == sig[2] and
            config.table_sigs[i][3] == sig[3])
        {
            return config.table_addrs[i];
        }
    }
    return null;
}

// --- MADT parser ---

fn parseMadt(madt_phys: u64) void {
    const madt_virt = io.physToVirt(madt_phys);
    const header: *align(1) const tables.SdtHeader = @ptrFromInt(madt_virt);

    // MADT-specific fields at offset 36: lapic_addr (u32), flags (u32)
    const header_size: u64 = @sizeOf(tables.SdtHeader);
    config.lapic_addr = readU32(madt_virt + header_size);

    // Walk variable-length entries starting at offset 44
    const entries_start = madt_virt + header_size + 8; // +8 for lapic_addr + flags
    const entries_end = madt_virt + header.length;

    var offset = entries_start;
    while (offset + 2 <= entries_end) {
        const entry_hdr: *align(1) const tables.MadtEntryHeader = @ptrFromInt(offset);

        // Safety: zero-length entry would infinite-loop
        if (entry_hdr.length < 2) {
            io.log("[acpi] MADT: zero-length entry, stopping walk\n");
            break;
        }

        // Don't read past table boundary
        if (offset + entry_hdr.length > entries_end) break;

        switch (entry_hdr.entry_type) {
            tables.MADT_LOCAL_APIC => {
                if (entry_hdr.length >= @sizeOf(tables.MadtLocalApic)) {
                    const entry: *align(1) const tables.MadtLocalApic = @ptrFromInt(offset);
                    // bit 0 = enabled, bit 1 = online capable
                    if (entry.flags & 0x3 != 0 and config.apic_count < 16) {
                        config.apic_ids[config.apic_count] = entry.apic_id;
                        config.apic_count += 1;
                    }
                }
            },
            tables.MADT_IO_APIC => {
                if (entry_hdr.length >= @sizeOf(tables.MadtIoApic)) {
                    const entry: *align(1) const tables.MadtIoApic = @ptrFromInt(offset);
                    if (config.ioapic_addr == 0) {
                        config.ioapic_addr = entry.ioapic_address;
                        config.ioapic_gsi_base = entry.gsi_base;
                    }
                }
            },
            tables.MADT_GICC => {
                // GICC has u64 fields at non-8-byte-aligned offsets — read manually
                if (entry_hdr.length >= tables.GICC_SIZE) {
                    const flags = readU32(offset + tables.GICC_FLAGS);
                    if (flags & 1 != 0) {
                        config.cpu_count +|= 1; // saturating add
                        const base = readU64(offset + tables.GICC_BASE_ADDRESS);
                        if (config.gicc_base == 0 and base != 0) {
                            config.gicc_base = base;
                        }
                        const gicr = readU64(offset + tables.GICC_GICR_BASE);
                        if (config.gicr_base == 0 and gicr != 0) {
                            config.gicr_base = gicr;
                        }
                    }
                }
            },
            tables.MADT_GICD => {
                if (entry_hdr.length >= @sizeOf(tables.MadtGicd)) {
                    const entry: *align(1) const tables.MadtGicd = @ptrFromInt(offset);
                    config.gicd_base = entry.base_address;
                    config.gic_version = entry.gic_version;
                }
            },
            tables.MADT_GIC_REDIST => {
                // GIC Redistributor has u64 at offset 0x04 (unaligned) — read manually
                if (entry_hdr.length >= tables.GICR_SIZE) {
                    if (config.gicr_base == 0) {
                        config.gicr_base = readU64(offset + tables.GICR_BASE_ADDRESS);
                        config.gicr_length = readU32(offset + tables.GICR_LENGTH);
                    }
                }
            },
            tables.MADT_GIC_ITS => {
                // GIC ITS — read base address at offset
                if (entry_hdr.length >= tables.ITS_SIZE) {
                    if (config.gic_its_base == 0) {
                        config.gic_its_base = readU64(offset + tables.ITS_BASE_ADDRESS);
                    }
                }
            },
            else => {},
        }

        offset += entry_hdr.length;
    }

    // Log summary
    if (config.gicd_base != 0) {
        io.log("[acpi] MADT: GICv");
        io.logDec(config.gic_version);
        io.log(" GICD=0x");
        io.logHex(config.gicd_base);
        if (config.gicr_base != 0) {
            io.log(" GICR=0x");
            io.logHex(config.gicr_base);
        }
        io.log(" CPUs=");
        io.logDec(config.cpu_count);
        io.log("\n");
    }
    if (config.lapic_addr != 0) {
        io.log("[acpi] MADT: LAPIC=0x");
        io.logHex(config.lapic_addr);
        if (config.ioapic_addr != 0) {
            io.log(" IOAPIC=0x");
            io.logHex(config.ioapic_addr);
        }
        io.log(" CPUs=");
        io.logDec(config.apic_count);
        io.log("\n");
    }
}

// --- MCFG parser ---

fn parseMcfg(mcfg_phys: u64) void {
    const mcfg_virt = io.physToVirt(mcfg_phys);
    const header: *align(1) const tables.SdtHeader = @ptrFromInt(mcfg_virt);

    // MCFG: SDT header (36 bytes) + 8 reserved bytes = 44 byte header
    const entries_start = mcfg_virt + 44;
    const entry_size: u64 = @sizeOf(tables.McfgEntry);

    if (header.length < 44 + entry_size) return;

    const entry_count = (header.length - 44) / @as(u32, @truncate(entry_size));
    if (entry_count == 0) return;

    // Use first entry (primary PCI segment)
    const entry: *align(1) const tables.McfgEntry = @ptrFromInt(entries_start);
    config.ecam_base = entry.base_address;
    config.ecam_segment = entry.segment;
    config.ecam_start_bus = entry.start_bus;
    config.ecam_end_bus = entry.end_bus;
    config.ecam_valid = true;

    io.log("[acpi] MCFG: ECAM=0x");
    io.logHex(config.ecam_base);
    io.log(" seg=");
    io.logDec(config.ecam_segment);
    io.log(" bus=");
    io.logDec(config.ecam_start_bus);
    io.log("-");
    io.logDec(config.ecam_end_bus);
    if (entry_count > 1) {
        io.log(" (+");
        io.logDec(entry_count - 1);
        io.log(" more segments)");
    }
    io.log("\n");
}

// --- GTDT parser ---

fn parseGtdt(gtdt_phys: u64) void {
    const gtdt_virt = io.physToVirt(gtdt_phys);
    const header: *align(1) const tables.SdtHeader = @ptrFromInt(gtdt_virt);

    if (header.length < tables.GTDT_FIXED_SIZE) return;

    const timer_count = readU32(gtdt_virt + tables.GTDT_PLATFORM_TIMER_COUNT);
    const timer_offset = readU32(gtdt_virt + tables.GTDT_PLATFORM_TIMER_OFFSET);

    if (timer_count == 0 or timer_offset == 0) {
        io.log("[acpi] GTDT: no platform timers\n");
        return;
    }

    io.log("[acpi] GTDT: ");
    io.logDec(timer_count);
    io.log(" platform timer(s)\n");

    // Walk platform timer entries
    var offset: u64 = gtdt_virt + timer_offset;
    const table_end: u64 = gtdt_virt + header.length;
    var i: u32 = 0;

    while (i < timer_count and offset + 4 <= table_end) : (i += 1) {
        const entry_type: *const u8 = @ptrFromInt(offset + tables.SBSA_WDT_TYPE);
        const entry_length = readU16(offset + tables.SBSA_WDT_LENGTH);

        if (entry_length < 4) break; // safety: prevent infinite loop
        if (offset + entry_length > table_end) break;

        if (entry_type.* == tables.GTDT_TIMER_SBSA_WATCHDOG) {
            if (entry_length >= tables.SBSA_WDT_SIZE and !config.wdog_valid) {
                config.wdog_refresh_base = readU64(offset + tables.SBSA_WDT_REFRESH_FRAME);
                config.wdog_control_base = readU64(offset + tables.SBSA_WDT_CONTROL_FRAME);
                config.wdog_gsiv = readU32(offset + tables.SBSA_WDT_GSIV);
                config.wdog_valid = true;

                io.log("[acpi] GTDT: SBSA Watchdog refresh=0x");
                io.logHex(config.wdog_refresh_base);
                io.log(" ctrl=0x");
                io.logHex(config.wdog_control_base);
                io.log(" GSIV=");
                io.logDec(config.wdog_gsiv);
                io.log("\n");
            }
        }

        offset += entry_length;
    }
}

// --- Helpers ---

fn checksumValid(data: [*]const u8, length: u32) bool {
    var sum: u8 = 0;
    for (0..length) |i| {
        sum +%= data[i];
    }
    return sum == 0;
}

fn sigEql(a: *const [8]u8, b: *const [8]u8) bool {
    inline for (0..8) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

/// Read a u64 from a potentially unaligned address.
fn readU64(addr: u64) u64 {
    const ptr: *align(1) const u64 = @ptrFromInt(addr);
    return ptr.*;
}

/// Read a u32 from a potentially unaligned address.
fn readU32(addr: u64) u32 {
    const ptr: *align(1) const u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Read a u16 from a potentially unaligned address.
fn readU16(addr: u64) u16 {
    const ptr: *align(1) const u16 = @ptrFromInt(addr);
    return ptr.*;
}
