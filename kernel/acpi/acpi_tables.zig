/// ACPI table structure definitions — matches ACPI 6.5 spec byte-for-byte.
///
/// Structs that are naturally C-aligned use `extern struct` with comptime size checks.
/// Structs with unaligned u64 fields (e.g., GICC at offset 0x3C) use offset constants
/// with manual field reads — ACPI tables are flat byte arrays, not C structs.

// --- RSDP ---
// RSDP has u64 xsdt_address at offset 0x18. In extern struct, the u64 forces
// 8-byte struct alignment → trailing padding to 40 bytes instead of 36.
// Solution: split into two u32 halves.

/// RSDP — Root System Description Pointer (ACPI 2.0+, 36 bytes).
pub const Rsdp = extern struct {
    signature: [8]u8, // 0x00: "RSD PTR "
    checksum: u8, // 0x08: sum of bytes 0-19 must be 0
    oem_id: [6]u8, // 0x09
    revision: u8, // 0x0F: 0 = ACPI 1.0, 2 = ACPI 2.0+
    rsdt_address: u32, // 0x10: 32-bit RSDT physical address
    length: u32, // 0x14: total structure length
    xsdt_address_lo: u32, // 0x18: lower 32 bits of XSDT address
    xsdt_address_hi: u32, // 0x1C: upper 32 bits of XSDT address
    extended_checksum: u8, // 0x20: sum of all 36 bytes must be 0
    reserved: [3]u8, // 0x21

    pub fn xsdtAddress(self: *const Rsdp) u64 {
        return @as(u64, self.xsdt_address_hi) << 32 | @as(u64, self.xsdt_address_lo);
    }
};

// --- SDT Header ---

/// SDT Header — common 36-byte header for all ACPI System Description Tables.
/// All fields are naturally u32-aligned → extern struct is correct.
pub const SdtHeader = extern struct {
    signature: [4]u8, // 0x00: e.g., "XSDT", "APIC", "MCFG"
    length: u32, // 0x04: total table length including header
    revision: u8, // 0x08
    checksum: u8, // 0x09: sum of all bytes in table must be 0
    oem_id: [6]u8, // 0x0A
    oem_table_id: [8]u8, // 0x10
    oem_revision: u32, // 0x18
    creator_id: u32, // 0x1C
    creator_revision: u32, // 0x20
};

// --- MADT entry type constants ---

pub const MADT_LOCAL_APIC: u8 = 0x00;
pub const MADT_IO_APIC: u8 = 0x01;
pub const MADT_INT_SRC_OVERRIDE: u8 = 0x02;
pub const MADT_GICC: u8 = 0x0B;
pub const MADT_GICD: u8 = 0x0C;
pub const MADT_GIC_MSI: u8 = 0x0D;
pub const MADT_GIC_REDIST: u8 = 0x0E;
pub const MADT_GIC_ITS: u8 = 0x0F;

/// MADT entry header — first 2 bytes of every variable-length MADT entry.
pub const MadtEntryHeader = extern struct {
    entry_type: u8,
    length: u8,
};

// --- MADT entries with clean C layout (no u64 alignment issues) ---

/// Processor Local APIC (Type 0, 8 bytes) — one per logical x86_64 CPU.
pub const MadtLocalApic = extern struct {
    header: MadtEntryHeader,
    acpi_processor_id: u8,
    apic_id: u8,
    flags: u32, // bit 0 = enabled, bit 1 = online capable
};

/// I/O APIC (Type 1, 12 bytes) — one per I/O APIC in the system.
pub const MadtIoApic = extern struct {
    header: MadtEntryHeader,
    ioapic_id: u8,
    reserved: u8,
    ioapic_address: u32, // MMIO base address
    gsi_base: u32, // Global System Interrupt base
};

// --- MADT entries with unaligned u64 fields — use offset constants ---
// These ACPI structures have u64 fields at non-8-byte-aligned offsets,
// which makes extern struct produce incorrect sizes due to C padding rules.

/// GICC field offsets (Type 0x0B, 80 bytes total) — GIC CPU Interface.
pub const GICC_FLAGS: u64 = 0x0C; // u32
pub const GICC_BASE_ADDRESS: u64 = 0x20; // u64
pub const GICC_GICR_BASE: u64 = 0x3C; // u64 (unaligned in C!)
pub const GICC_MPIDR: u64 = 0x44; // u64 (unaligned in C!)
pub const GICC_SIZE: u8 = 80;

/// GICD (Type 0x0C, 24 bytes) — GIC Distributor.
/// u64 at offset 0x08 is 8-byte aligned → extern struct works.
pub const MadtGicd = extern struct {
    header: MadtEntryHeader, // 0x00
    reserved: u16, // 0x02
    gic_id: u32, // 0x04
    base_address: u64, // 0x08
    system_vector_base: u32, // 0x10
    gic_version: u8, // 0x14: 1=v1, 2=v2, 3=v3, 4=v4
    reserved2: [3]u8, // 0x15
};

/// GIC Redistributor field offsets (Type 0x0E, 16 bytes total).
/// u64 at offset 0x04 is NOT 8-byte aligned → use manual reads.
pub const GICR_BASE_ADDRESS: u64 = 0x04; // u64 (unaligned!)
pub const GICR_LENGTH: u64 = 0x0C; // u32
pub const GICR_SIZE: u8 = 16;

/// GIC ITS field offsets (Type 0x0F, 20 bytes total).
/// u64 at offset 0x08 is aligned, but trailing padding would make extern struct 24 bytes.
pub const ITS_ID: u64 = 0x04; // u32
pub const ITS_BASE_ADDRESS: u64 = 0x08; // u64
pub const ITS_SIZE: u8 = 20;

// --- MCFG ---

/// MCFG allocation entry (16 bytes) — one per PCIe segment.
/// u64 at offset 0 → 8-byte alignment, total 16 = multiple of 8. extern struct works.
pub const McfgEntry = extern struct {
    base_address: u64, // 0x00: ECAM physical base address
    segment: u16, // 0x08: PCI segment group number
    start_bus: u8, // 0x0A
    end_bus: u8, // 0x0B
    reserved: u32, // 0x0C
};

// --- GTDT (Generic Timer Description Table) ---

/// GTDT fixed header fields after SDT Header (36 bytes).
/// CntReadBase at offset 80 is NOT 8-byte aligned — use offset constants.
pub const GTDT_CNT_CONTROL_BASE: u64 = 36; // u64
pub const GTDT_SECURE_PL1_GSIV: u64 = 48; // u32
pub const GTDT_NONSECURE_PL1_GSIV: u64 = 56; // u32
pub const GTDT_VIRTUAL_TIMER_GSIV: u64 = 64; // u32
pub const GTDT_NONSECURE_PL2_GSIV: u64 = 72; // u32
pub const GTDT_CNT_READ_BASE: u64 = 80; // u64 (unaligned!)
pub const GTDT_PLATFORM_TIMER_COUNT: u64 = 88; // u32
pub const GTDT_PLATFORM_TIMER_OFFSET: u64 = 92; // u32
pub const GTDT_FIXED_SIZE: u64 = 96;

/// GTDT Platform Timer types
pub const GTDT_TIMER_GT_BLOCK: u8 = 0;
pub const GTDT_TIMER_SBSA_WATCHDOG: u8 = 1;

/// SBSA Generic Watchdog structure field offsets (Type 1, 28 bytes).
/// u64 fields at offsets 4 and 12 are NOT 8-byte aligned — use manual reads.
pub const SBSA_WDT_TYPE: u64 = 0; // u8
pub const SBSA_WDT_LENGTH: u64 = 1; // u16 (unaligned)
pub const SBSA_WDT_REFRESH_FRAME: u64 = 4; // u64 (unaligned!)
pub const SBSA_WDT_CONTROL_FRAME: u64 = 12; // u64 (unaligned!)
pub const SBSA_WDT_GSIV: u64 = 20; // u32
pub const SBSA_WDT_FLAGS: u64 = 24; // u32
pub const SBSA_WDT_SIZE: u64 = 28;

// --- Compile-time layout verification ---

comptime {
    if (@sizeOf(Rsdp) != 36) @compileError("RSDP must be 36 bytes");
    if (@sizeOf(SdtHeader) != 36) @compileError("SDT header must be 36 bytes");
    if (@sizeOf(MadtEntryHeader) != 2) @compileError("MADT entry header must be 2 bytes");
    if (@sizeOf(MadtLocalApic) != 8) @compileError("Local APIC entry must be 8 bytes");
    if (@sizeOf(MadtIoApic) != 12) @compileError("I/O APIC entry must be 12 bytes");
    if (@sizeOf(MadtGicd) != 24) @compileError("GICD entry must be 24 bytes");
    if (@sizeOf(McfgEntry) != 16) @compileError("MCFG entry must be 16 bytes");
}
