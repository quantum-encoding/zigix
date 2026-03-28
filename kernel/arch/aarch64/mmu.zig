/// ARM64 MMU (Memory Management Unit)
/// 4-level page tables: L0 -> L1 -> L2 -> L3
/// 4KB pages, 48-bit virtual addresses (256TB)
///
/// This provides the same interface as x86_64 VMM:
/// - mapPage(), unmapPage()
/// - translate()
/// - createAddressSpace(), switchAddressSpace()

const std = @import("std");
const uart = @import("uart.zig");

/// Page size (4KB)
pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;

/// Page table entry count (512 per table, 9 bits per level)
const ENTRIES_PER_TABLE: usize = 512;

/// Virtual address bits per level
const VA_BITS: u6 = 48;
const LEVEL_BITS: u6 = 9;

/// Descriptor types
const DESC_INVALID: u64 = 0b00;
const DESC_BLOCK: u64 = 0b01;   // L1/L2 block (1GB/2MB)
const DESC_TABLE: u64 = 0b11;   // Points to next level table
const DESC_PAGE: u64 = 0b11;    // L3 page (4KB)

/// Attribute bits
const ATTR_AF: u64 = 1 << 10;        // Access Flag (must be 1)
const ATTR_SH_INNER: u64 = 3 << 8;   // Inner Shareable
const ATTR_AP_RW: u64 = 0 << 6;      // Read-Write
const ATTR_AP_RO: u64 = 2 << 6;      // Read-Only
const ATTR_AP_USER: u64 = 1 << 6;    // User accessible
const ATTR_nG: u64 = 1 << 11;        // Non-Global
const ATTR_PXN: u64 = 1 << 53;       // Privileged Execute Never
const ATTR_UXN: u64 = 1 << 54;       // User Execute Never

/// Memory attribute indices (MAIR_EL1)
const ATTR_IDX_DEVICE: u64 = 0 << 2;  // Device memory
const ATTR_IDX_NORMAL: u64 = 1 << 2;  // Normal memory (cacheable)

/// Page table entry
const PageTableEntry = packed struct {
    raw: u64,

    pub fn isValid(self: PageTableEntry) bool {
        return (self.raw & 0b11) != 0;
    }

    pub fn isTable(self: PageTableEntry) bool {
        return (self.raw & 0b11) == DESC_TABLE;
    }

    pub fn getPhysAddr(self: PageTableEntry) u64 {
        return self.raw & 0x0000_FFFF_FFFF_F000;
    }

    pub fn setPhysAddr(self: *PageTableEntry, phys: u64) void {
        self.raw = (self.raw & ~@as(u64, 0x0000_FFFF_FFFF_F000)) | (phys & 0x0000_FFFF_FFFF_F000);
    }
};

/// Page table (512 entries, 4KB aligned)
const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]PageTableEntry,
};

/// Kernel's root page table (L0)
var kernel_l0: *PageTable = undefined;
var mmu_initialized = false;

/// Static page tables for early boot (before PMM is available)
/// Using 1GB block mappings (L1 blocks), we need L0 + L1 tables only
var early_l0 align(PAGE_SIZE) = PageTable{ .entries = [_]PageTableEntry{.{ .raw = 0 }} ** ENTRIES_PER_TABLE };
var early_l1 align(PAGE_SIZE) = PageTable{ .entries = [_]PageTableEntry{.{ .raw = 0 }} ** ENTRIES_PER_TABLE };

/// Early MMU initialization with identity mapping using 1GB blocks
/// This creates a simple identity map for boot before PMM exists
pub fn earlyInit() void {
    uart.writeString("[mmu]  Setting up early page tables...\n");

    // CRITICAL: Invalidate all TLB entries left by UEFI firmware.
    // UEFI had its own page tables; el_drop disables MMU but does NOT flush TLBs.
    // Stale TLB entries cause translation faults when we enable our new tables.
    asm volatile ("tlbi vmalle1is");
    asm volatile ("dsb ish");
    asm volatile ("isb");

    // Set up L0[0] to point to L1 table
    early_l0.entries[0].raw = @intFromPtr(&early_l1) | DESC_TABLE;

    // Map first 4GB using 1GB blocks in L1
    // L1[0]: 0x00000000 - 0x3FFFFFFF (Device memory: GIC, UART, etc.)
    early_l1.entries[0].raw = (0x00000000) | DESC_BLOCK | ATTR_AF | ATTR_IDX_DEVICE | ATTR_PXN | ATTR_UXN;

    // L1[1]: 0x40000000 - 0x7FFFFFFF (RAM - kernel loaded here)
    early_l1.entries[1].raw = (0x40000000) | DESC_BLOCK | ATTR_AF | ATTR_SH_INNER | ATTR_IDX_NORMAL;

    // L1[2]: 0x80000000 - 0xBFFFFFFF (More RAM if available)
    early_l1.entries[2].raw = (0x80000000) | DESC_BLOCK | ATTR_AF | ATTR_SH_INNER | ATTR_IDX_NORMAL;

    // L1[3]: 0xC0000000 - 0xFFFFFFFF (More RAM if available)
    early_l1.entries[3].raw = (0xC0000000) | DESC_BLOCK | ATTR_AF | ATTR_SH_INNER | ATTR_IDX_NORMAL;

    // L1[4..63]: Map 4-64GB as normal memory. GCE Axion places ACPI tables
    // and UEFI runtime data above RAM (e.g., RSDP at ~33GB on c4a-standard-8
    // with 32GB RAM). Map enough for any C4A instance size.
    {
        var i: usize = 4;
        while (i < 64) : (i += 1) {
            early_l1.entries[i].raw = (@as(u64, i) << 30) | DESC_BLOCK | ATTR_AF | ATTR_SH_INNER | ATTR_IDX_NORMAL;
        }
    }

    // Map high MMIO regions for UEFI/ACPI devices (PCIe ECAM, NVMe BARs)
    // QEMU virt ECAM at 0x4010000000 → L1 index = 0x4010000000 >> 30 = 256
    // NVMe BAR0 at 0x10000000000 (1TB) is beyond L0[0] (512GB), needs L0[1]
    // Map L1[256..271] as device memory for ECAM + nearby devices
    {
        var i: usize = 256;
        while (i < 272) : (i += 1) {
            early_l1.entries[i].raw = (@as(u64, i) << 30) | DESC_BLOCK | ATTR_AF | ATTR_IDX_DEVICE | ATTR_PXN | ATTR_UXN;
        }
    }

    // Set up MAIR_EL1 (Memory Attribute Indirection Register)
    // Index 0: Device-nGnRnE (0x00) - for MMIO
    // Index 1: Normal, Inner/Outer Write-Back (0xFF) - for RAM
    const mair: u64 = 0x00 | (0xFF << 8);
    asm volatile ("msr MAIR_EL1, %[mair]"
        :
        : [mair] "r" (mair),
    );

    // Set up TCR_EL1 (Translation Control Register)
    // T0SZ = 16 (48-bit VA), TG0 = 4KB granule, IPS = 40-bit PA
    // EPD1 = 1: Disable TTBR1 walks (we don't use upper VA range yet)
    const tcr: u64 =
        (16 << 0) |       // T0SZ: 48-bit addresses (64 - 48 = 16)
        (0b00 << 14) |    // TG0: 4KB granule
        (0b10 << 12) |    // SH0: Inner Shareable
        (0b01 << 10) |    // ORGN0: Write-Back
        (0b01 << 8) |     // IRGN0: Write-Back
        (@as(u64, 1) << 23) | // EPD1: Disable TTBR1 translations
        (@as(u64, 0b010) << 32); // IPS: 40-bit physical address
    asm volatile ("msr TCR_EL1, %[tcr]"
        :
        : [tcr] "r" (tcr),
    );

    // Set TTBR0_EL1 to point to our L0 table
    const ttbr0 = @intFromPtr(&early_l0);
    asm volatile ("msr TTBR0_EL1, %[ttbr]"
        :
        : [ttbr] "r" (ttbr0),
    );

    // Invalidate TLBs again after loading new TTBR0, then full barrier
    asm volatile ("tlbi vmalle1is");
    asm volatile ("dsb sy");
    asm volatile ("isb");

    kernel_l0 = &early_l0;
    mmu_initialized = true;

    uart.writeString("[mmu]  Early page tables configured\n");
    uart.writeString("[mmu]  L0 at ");
    uart.writeHex(@intFromPtr(&early_l0));
    uart.writeString("\n");
}

/// Enable the MMU (call after earlyInit or init)
pub fn enable() void {
    if (!mmu_initialized) {
        uart.writeString("[mmu]  ERROR: Page tables not configured!\n");
        return;
    }

    // Debug: print L0[0] and L1[1] descriptor values for verification
    uart.writeString("[mmu]  L0[0]=");
    uart.writeHex(early_l0.entries[0].raw);
    uart.writeString(" L1[1]=");
    uart.writeHex(early_l1.entries[1].raw);
    uart.writeString("\n");

    uart.writeString("[mmu]  Enabling MMU...\n");

    // Final TLB invalidation + barrier right before enabling MMU
    asm volatile ("tlbi vmalle1is");
    asm volatile ("dsb sy");
    asm volatile ("isb");

    // Read SCTLR_EL1
    var sctlr: u64 = undefined;
    asm volatile ("mrs %[ret], SCTLR_EL1"
        : [ret] "=r" (sctlr),
    );

    // Set M bit (MMU enable), C bit (data cache), I bit (instruction cache)
    sctlr |= (1 << 0) | (1 << 2) | (1 << 12);
    // Clear A bit (alignment checking) — Linux binaries assume unaligned access is allowed
    sctlr &= ~@as(u64, 1 << 1);

    // Write back and synchronize
    asm volatile (
        \\msr SCTLR_EL1, %[sctlr]
        \\isb
        :
        : [sctlr] "r" (sctlr),
    );

    uart.writeString("[mmu]  MMU enabled with identity mapping\n");
}

/// Initialize MMU with identity mapping for kernel (requires PMM)
pub fn init(pmm_alloc: *const fn () ?u64) !void {
    // Allocate L0 table
    const l0_phys = pmm_alloc() orelse return error.OutOfMemory;
    kernel_l0 = @ptrFromInt(l0_phys);  // Direct mapping initially

    // Zero out the table
    @memset(std.mem.asBytes(&kernel_l0.entries), 0);

    // Set up MAIR_EL1 (Memory Attribute Indirection Register)
    // Index 0: Device-nGnRnE (0x00)
    // Index 1: Normal, Inner/Outer Write-Back (0xFF)
    const mair: u64 = 0x00 | (0xFF << 8);
    asm volatile ("msr MAIR_EL1, %[mair]"
        :
        : [mair] "r" (mair),
    );

    // Set up TCR_EL1 (Translation Control Register)
    // T0SZ = 16 (48-bit VA), TG0 = 4KB granule
    const tcr: u64 =
        (16 << 0) |  // T0SZ: 48-bit addresses
        (0b00 << 14) |  // TG0: 4KB granule
        (0b10 << 12) |  // SH0: Inner Shareable
        (0b01 << 10) |  // ORGN0: Write-Back
        (0b01 << 8);    // IRGN0: Write-Back
    asm volatile ("msr TCR_EL1, %[tcr]"
        :
        : [tcr] "r" (tcr),
    );

    // Set TTBR0_EL1 to point to our page table
    asm volatile ("msr TTBR0_EL1, %[ttbr]"
        :
        : [ttbr] "r" (l0_phys),
    );

    // Ensure all writes complete before enabling MMU
    asm volatile ("dsb sy");
    asm volatile ("isb");

    mmu_initialized = true;
    uart.writeString("[mmu]  Page tables configured\n");
}

/// Map a virtual page to a physical page
pub fn mapPage(
    l0: *PageTable,
    virt: u64,
    phys: u64,
    flags: u64,
    pmm_alloc: *const fn () ?u64,
) !void {
    const indices = getIndices(virt);

    // Walk/create L0 -> L1 -> L2 -> L3
    var table = l0;

    // L0 -> L1
    table = try getOrCreateTable(&table.entries[indices[0]], pmm_alloc);

    // L1 -> L2
    table = try getOrCreateTable(&table.entries[indices[1]], pmm_alloc);

    // L2 -> L3
    table = try getOrCreateTable(&table.entries[indices[2]], pmm_alloc);

    // L3 entry (4KB page)
    table.entries[indices[3]].raw = (phys & 0x0000_FFFF_FFFF_F000) |
        DESC_PAGE |
        ATTR_AF |
        ATTR_SH_INNER |
        ATTR_IDX_NORMAL |
        flags;
}

/// Unmap a virtual page
pub fn unmapPage(l0: *PageTable, virt: u64) void {
    const indices = getIndices(virt);

    var table = l0;

    // Walk L0 -> L1 -> L2 -> L3
    inline for (0..3) |level| {
        const entry = &table.entries[indices[level]];
        if (!entry.isValid() or !entry.isTable()) {
            return;  // Not mapped
        }
        table = @ptrFromInt(entry.getPhysAddr());
    }

    // Clear L3 entry
    table.entries[indices[3]].raw = 0;

    // Invalidate TLB for this address
    invalidatePage(virt);
}

/// Translate virtual address to physical
pub fn translate(l0: *PageTable, virt: u64) ?u64 {
    const indices = getIndices(virt);

    var table = l0;

    // Walk L0 -> L1 -> L2 -> L3
    inline for (0..3) |level| {
        const entry = &table.entries[indices[level]];
        if (!entry.isValid()) {
            return null;
        }
        if (!entry.isTable()) {
            // Block mapping: L1 = 1GB, L2 = 2MB
            const block_addr = entry.getPhysAddr();
            const block_shift: u6 = if (level == 0) 39 else if (level == 1) 30 else 21;
            const block_mask = (@as(u64, 1) << block_shift) - 1;
            return block_addr | (virt & block_mask);
        }
        table = @ptrFromInt(entry.getPhysAddr());
    }

    const entry = &table.entries[indices[3]];
    if (!entry.isValid()) {
        return null;
    }

    return entry.getPhysAddr() | (virt & 0xFFF);
}

/// Invalidate TLB entry for a virtual address
pub fn invalidatePage(virt: u64) void {
    asm volatile ("tlbi vale1is, %[virt]"
        :
        : [virt] "r" (virt >> 12),
    );
    asm volatile ("dsb sy");
    asm volatile ("isb");
}

/// Invalidate entire TLB
pub fn invalidateAll() void {
    asm volatile ("tlbi vmalle1is");
    asm volatile ("dsb sy");
    asm volatile ("isb");
}

/// Get L0/L1/L2/L3 indices from virtual address
fn getIndices(virt: u64) [4]u9 {
    return .{
        @truncate((virt >> 39) & 0x1FF),  // L0
        @truncate((virt >> 30) & 0x1FF),  // L1
        @truncate((virt >> 21) & 0x1FF),  // L2
        @truncate((virt >> 12) & 0x1FF),  // L3
    };
}

/// Get or create a page table at the given entry
fn getOrCreateTable(entry: *PageTableEntry, pmm_alloc: *const fn () ?u64) !*PageTable {
    if (entry.isValid() and entry.isTable()) {
        return @ptrFromInt(entry.getPhysAddr());
    }

    // Allocate new table
    const new_table_phys = pmm_alloc() orelse return error.OutOfMemory;
    const new_table: *PageTable = @ptrFromInt(new_table_phys);

    // Zero it out
    @memset(std.mem.asBytes(&new_table.entries), 0);

    // Update entry to point to new table
    entry.raw = new_table_phys | DESC_TABLE;

    return new_table;
}
