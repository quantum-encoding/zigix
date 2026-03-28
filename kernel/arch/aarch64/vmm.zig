/// ARM64 Virtual Memory Manager — 4-level page tables.
/// L0 → L1 → L2 → L3, 512 entries per table, 4 KiB pages.
///
/// Virtual address layout (48-bit):
///   [63:48] must be all 0s or all 1s (canonical)
///   [47:39] L0 index  (9 bits)
///   [38:30] L1 index  (9 bits)
///   [29:21] L2 index  (9 bits)
///   [20:12] L3 index  (9 bits)
///   [11:0]  page offset (12 bits)
///
/// ARM64 uses identity mapping (phys == virt for kernel) for simplicity.
/// User processes get their own L0 page table.

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const mmu = @import("mmu.zig");
const vma = @import("vma.zig");

/// Typed address system (Chaos Rocket safety) — available for incremental adoption.
/// PhysAddr and VirtAddr are distinct types. On ARM64 (identity mapping), the
/// conversion is a no-op, but the type distinction catches confusion at compile time.
pub const typed_addr = @import("addr");
pub const PhysAddr = typed_addr.Phys;
pub const VirtAddr = typed_addr.Virt;

pub const PAGE_SIZE: u64 = 4096;
const ENTRIES_PER_TABLE: usize = 512;

/// Descriptor types (bits [1:0])
const DESC_INVALID: u64 = 0b00;
const DESC_BLOCK: u64 = 0b01;   // L1/L2 block (1GB/2MB)
const DESC_TABLE: u64 = 0b11;   // Points to next level table
const DESC_PAGE: u64 = 0b11;    // L3 page (4KB)

/// Attribute bits
const ATTR_AF: u64 = 1 << 10;        // Access Flag (must be 1)
const ATTR_SH_INNER: u64 = 3 << 8;   // Inner Shareable
const ATTR_AP_RW: u64 = 0 << 6;      // Read-Write (EL1)
pub const ATTR_AP_RO: u64 = 2 << 6;      // Read-Only
const ATTR_AP_USER: u64 = 1 << 6;    // User accessible (EL0)
const ATTR_nG: u64 = 1 << 11;        // Non-Global
const ATTR_PXN: u64 = 1 << 53;       // Privileged Execute Never
pub const ATTR_UXN: u64 = 1 << 54;   // User Execute Never

/// Memory attribute indices (MAIR_EL1)
const ATTR_IDX_DEVICE: u64 = 0 << 2;
const ATTR_IDX_NORMAL: u64 = 1 << 2;

/// OS-defined bits for CoW tracking (using bits [58:55] which are software-defined)
pub const PTE_COW: u64 = 1 << 55;

/// Page Table Entry
pub const PTE = packed struct(u64) {
    raw: u64,

    pub fn isValid(self: PTE) bool {
        return (self.raw & 0b11) != 0;
    }

    pub fn isTable(self: PTE) bool {
        return (self.raw & 0b11) == DESC_TABLE;
    }

    pub fn isPage(self: PTE) bool {
        return (self.raw & 0b11) == DESC_PAGE;
    }

    pub fn getPhysAddr(self: PTE) u64 {
        return self.raw & 0x0000_FFFF_FFFF_F000;
    }

    pub fn setPhysAddr(self: *PTE, phys: u64) void {
        self.raw = (self.raw & ~@as(u64, 0x0000_FFFF_FFFF_F000)) |
            (phys & 0x0000_FFFF_FFFF_F000);
    }

    pub fn isCow(self: PTE) bool {
        return (self.raw & PTE_COW) != 0;
    }

    pub fn isWritable(self: PTE) bool {
        // AP[2] = 0 means writable at EL1
        return (self.raw & ATTR_AP_RO) == 0;
    }

    pub fn isUser(self: PTE) bool {
        return (self.raw & ATTR_AP_USER) != 0;
    }

    pub fn isBlock(self: PTE) bool {
        return (self.raw & 0b11) == 0b01; // DESC_BLOCK
    }
};

pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]PTE,
};

/// Mapping flags
pub const MapFlags = struct {
    writable: bool = false,
    user: bool = false,
    executable: bool = true,
    device: bool = false,  // Device memory (no caching)
    global: bool = false,
    cow: bool = false,     // Copy-on-Write
};

/// Kernel's root page table (L0)
var kernel_l0_phys: PhysAddr = PhysAddr.zero();
var initialized = false;

/// Initialize VMM with a new kernel page table
pub fn init() !void {
    // Allocate a new L0 for full page table management
    const l0_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const l0: *PageTable = @ptrFromInt(l0_phys);

    // Zero out the table
    for (0..ENTRIES_PER_TABLE) |i| {
        l0.entries[i].raw = 0;
    }

    // Identity map the first 4GB for kernel (device + RAM)
    // This matches what earlyInit did with 1GB blocks, but we'll
    // use the same approach for compatibility

    // Allocate L1 table
    const l1_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const l1: *PageTable = @ptrFromInt(l1_phys);

    for (0..ENTRIES_PER_TABLE) |i| {
        l1.entries[i].raw = 0;
    }

    // L0[0] points to L1
    l0.entries[0].raw = l1_phys | DESC_TABLE;

    // Map first 64GB using 1GB blocks in L1 (matches earlyInit)
    // L1[0]: Device memory (GIC, UART, PCI ECAM)
    l1.entries[0].raw = (0x00000000) | DESC_BLOCK | ATTR_AF | ATTR_IDX_DEVICE | ATTR_PXN | ATTR_UXN;

    // L1[1..63]: RAM + ACPI tables (covers up to 64GB for large GCE instances)
    // GCE places ACPI RSDP above RAM (e.g., ~33GB on c4a-standard-8 with 32GB).
    {
        var i: usize = 1;
        while (i < 64) : (i += 1) {
            l1.entries[i].raw = (@as(u64, i) << 30) | DESC_BLOCK | ATTR_AF | ATTR_SH_INNER | ATTR_IDX_NORMAL;
        }
    }

    kernel_l0_phys = PhysAddr.from(l0_phys);
    initialized = true;

    uart.writeString("[vmm]  Kernel L0 at ");
    uart.writeHex(l0_phys);
    uart.writeString("\n");
}

/// Map a 4KB virtual page to a physical frame
pub fn mapPage(l0_phys_addr: PhysAddr, virt_addr: VirtAddr, phys_addr: PhysAddr, flags: MapFlags) !void {
    const l0_phys = l0_phys_addr.toInt();
    const virt = virt_addr.toInt();
    const phys = phys_addr.toInt();
    const l0_idx = (virt >> 39) & 0x1FF;
    const l1_idx = (virt >> 30) & 0x1FF;
    const l2_idx = (virt >> 21) & 0x1FF;
    const l3_idx = (virt >> 12) & 0x1FF;

    // Walk L0 → L1
    const l0: *PageTable = @ptrFromInt(l0_phys);
    const l1_phys = try ensureTable(&l0.entries[l0_idx]);

    // Walk L1 → L2
    const l1: *PageTable = @ptrFromInt(l1_phys);

    // Check if this is a 1GB block mapping - need to break it down
    if (l1.entries[l1_idx].isValid() and !l1.entries[l1_idx].isTable()) {
        // This is a block mapping, we need to split it
        try splitL1Block(&l1.entries[l1_idx], l1_idx);
    }

    const l2_phys = try ensureTable(&l1.entries[l1_idx]);

    // Walk L2 → L3
    const l2: *PageTable = @ptrFromInt(l2_phys);

    // Check if this is a 2MB block mapping - need to break it down
    if (l2.entries[l2_idx].isValid() and !l2.entries[l2_idx].isTable()) {
        try splitL2Block(&l2.entries[l2_idx], l1_idx, l2_idx);
    }

    const l3_phys = try ensureTable(&l2.entries[l2_idx]);

    // Set the final L3 entry
    const l3: *PageTable = @ptrFromInt(l3_phys);

    var attrs: u64 = DESC_PAGE | ATTR_AF | ATTR_SH_INNER;

    if (flags.device) {
        attrs |= ATTR_IDX_DEVICE;
    } else {
        attrs |= ATTR_IDX_NORMAL;
    }

    if (!flags.writable) {
        attrs |= ATTR_AP_RO;
    }

    if (flags.user) {
        attrs |= ATTR_AP_USER;
        if (!flags.executable) {
            attrs |= ATTR_UXN;
        }
    } else {
        if (!flags.executable) {
            attrs |= ATTR_PXN;
        }
    }

    if (!flags.global) {
        attrs |= ATTR_nG;
    }

    if (flags.cow) {
        attrs |= PTE_COW;
    }

    l3.entries[l3_idx].raw = (phys & 0x0000_FFFF_FFFF_F000) | attrs;
}

/// Map a 2 MiB huge page via an L2 block descriptor (no L3 needed).
/// Virtual and physical addresses must be 2MB-aligned.
pub fn mapHugePage(l0_phys_addr: PhysAddr, virt_addr: VirtAddr, phys_addr: PhysAddr, flags: MapFlags) !void {
    const l0_phys = l0_phys_addr.toInt();
    const virt = virt_addr.toInt();
    const phys = phys_addr.toInt();
    const l0_idx = (virt >> 39) & 0x1FF;
    const l1_idx = (virt >> 30) & 0x1FF;
    const l2_idx = (virt >> 21) & 0x1FF;

    const l0: *PageTable = @ptrFromInt(l0_phys);
    const l1_phys = try ensureTable(&l0.entries[l0_idx]);

    const l1: *PageTable = @ptrFromInt(l1_phys);

    // If L1 entry is a 1GB block, split it to L2 table first
    if (l1.entries[l1_idx].isValid() and !l1.entries[l1_idx].isTable()) {
        try splitL1Block(&l1.entries[l1_idx], l1_idx);
    }

    const l2_phys = try ensureTable(&l1.entries[l1_idx]);
    const l2: *PageTable = @ptrFromInt(l2_phys);

    // Build L2 block descriptor attributes
    var attrs: u64 = DESC_BLOCK | ATTR_AF | ATTR_SH_INNER | ATTR_IDX_NORMAL;

    if (!flags.writable) {
        attrs |= ATTR_AP_RO;
    }

    if (flags.user) {
        attrs |= ATTR_AP_USER;
        if (!flags.executable) {
            attrs |= ATTR_UXN;
        }
    } else {
        if (!flags.executable) {
            attrs |= ATTR_PXN;
        }
    }

    if (!flags.global) {
        attrs |= ATTR_nG;
    }

    l2.entries[l2_idx].raw = (phys & 0x0000_FFFF_FFE0_0000) | attrs;
}

/// Unmap a 2 MiB huge page (clear L2 block descriptor).
pub fn unmapHugePage(l0_phys_addr: PhysAddr, virt_addr: VirtAddr) void {
    const l0_phys = l0_phys_addr.toInt();
    const virt = virt_addr.toInt();
    const l0_idx = (virt >> 39) & 0x1FF;
    const l1_idx = (virt >> 30) & 0x1FF;
    const l2_idx = (virt >> 21) & 0x1FF;

    const l0: *PageTable = @ptrFromInt(l0_phys);
    if (!l0.entries[l0_idx].isValid()) return;
    if (!l0.entries[l0_idx].isTable()) return;

    const l1: *PageTable = @ptrFromInt(l0.entries[l0_idx].getPhysAddr());
    if (!l1.entries[l1_idx].isValid()) return;
    if (!l1.entries[l1_idx].isTable()) return;

    const l2: *PageTable = @ptrFromInt(l1.entries[l1_idx].getPhysAddr());
    l2.entries[l2_idx].raw = 0;

    invalidatePage(virt_addr);
}

/// Split a 1GB block mapping into 512 x 2MB block mappings.
/// Uses ARM64 break-before-make: invalidate old entry → TLB flush → install new.
fn splitL1Block(entry: *PTE, l1_idx: usize) !void {
    const block_base = entry.getPhysAddr();
    const block_attrs = entry.raw & 0xFFFF_0000_0000_0FFC; // Keep attributes except address and type

    // Allocate L2 table
    const l2_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const l2: *PageTable = @ptrFromInt(l2_phys);

    // Fill with 2MB block mappings
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const block_addr = block_base + (i * 2 * 1024 * 1024);
        l2.entries[i].raw = block_addr | DESC_BLOCK | (block_attrs & ~@as(u64, 0b11));
    }

    // ARM64 break-before-make: must invalidate old mapping before installing new.
    // Directly overwriting a valid block with a valid table descriptor is
    // architecturally UNPREDICTABLE — CPUs may use stale TLB entries from the
    // old 1GB block, causing spurious permission faults on demand-paged pages.

    // Step 1: Break — invalidate old entry
    entry.raw = 0;
    asm volatile ("dsb ishst");

    // Step 2: TLB invalidate all VAs covered by the old 1GB block
    const base_va = @as(u64, l1_idx) << 30;
    var va: u64 = base_va;
    while (va < base_va + (1 << 30)) : (va += 1 << 21) {
        asm volatile ("tlbi vale1is, %[va]"
            :
            : [va] "r" (va >> 12),
        );
    }
    asm volatile ("dsb sy");
    asm volatile ("isb");

    // Step 3: Make — install new table descriptor
    entry.raw = l2_phys | DESC_TABLE;
}

/// Split a 2MB block mapping into 512 x 4KB page mappings.
/// Uses ARM64 break-before-make: invalidate old entry → TLB flush → install new.
fn splitL2Block(entry: *PTE, l1_idx: usize, l2_idx: usize) !void {
    const block_base = entry.getPhysAddr();
    const block_attrs = entry.raw & 0xFFFF_0000_0000_0FFC;

    // Allocate L3 table
    const l3_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const l3: *PageTable = @ptrFromInt(l3_phys);

    // Fill with 4KB page mappings
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const page_addr = block_base + (i * 4096);
        l3.entries[i].raw = page_addr | DESC_PAGE | (block_attrs & ~@as(u64, 0b11));
    }

    // ARM64 break-before-make: must invalidate old mapping before installing new.
    // Directly overwriting a valid 2MB block with a valid table descriptor is
    // architecturally UNPREDICTABLE — stale 2MB TLB entries cause permission
    // faults when demand-paged user L3 entries have different attributes.

    // Step 1: Break — invalidate old entry
    entry.raw = 0;
    asm volatile ("dsb ishst");

    // Step 2: TLB invalidate the old 2MB block's VA range
    const base_va = (@as(u64, l1_idx) << 30) | (@as(u64, l2_idx) << 21);
    var va: u64 = base_va;
    while (va < base_va + (1 << 21)) : (va += PAGE_SIZE) {
        asm volatile ("tlbi vale1is, %[va]"
            :
            : [va] "r" (va >> 12),
        );
    }
    asm volatile ("dsb sy");
    asm volatile ("isb");

    // Step 3: Make — install new table descriptor
    entry.raw = l3_phys | DESC_TABLE;
}

/// Unmap a 4KB virtual page
pub fn unmapPage(l0_phys_addr: PhysAddr, virt_addr: VirtAddr) void {
    const l0_phys = l0_phys_addr.toInt();
    const virt = virt_addr.toInt();
    const l0_idx = (virt >> 39) & 0x1FF;
    const l1_idx = (virt >> 30) & 0x1FF;
    const l2_idx = (virt >> 21) & 0x1FF;
    const l3_idx = (virt >> 12) & 0x1FF;

    const l0: *PageTable = @ptrFromInt(l0_phys);
    if (!l0.entries[l0_idx].isValid()) return;
    if (!l0.entries[l0_idx].isTable()) return; // Block mapping

    const l1: *PageTable = @ptrFromInt(l0.entries[l0_idx].getPhysAddr());
    if (!l1.entries[l1_idx].isValid()) return;
    if (!l1.entries[l1_idx].isTable()) return; // Block mapping

    const l2: *PageTable = @ptrFromInt(l1.entries[l1_idx].getPhysAddr());
    if (!l2.entries[l2_idx].isValid()) return;
    if (!l2.entries[l2_idx].isTable()) return; // Block mapping

    const l3: *PageTable = @ptrFromInt(l2.entries[l2_idx].getPhysAddr());
    l3.entries[l3_idx].raw = 0;

    invalidatePage(virt_addr);
}

/// Create a new user address space with kernel mappings.
/// Each process gets its own L1 table for L0[0] so that user page mappings
/// at low VAs (e.g., 0x400000) don't leak between address spaces via shared
/// page tables. Kernel 1GB block descriptors are copied into the new L1.
pub fn createAddressSpace() !PhysAddr {
    const new_l0_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const new_l0: *PageTable = @ptrFromInt(new_l0_phys);
    const kernel_l0: *PageTable = @ptrFromInt(kernel_l0_phys.toInt());

    for (0..ENTRIES_PER_TABLE) |i| {
        new_l0.entries[i].raw = 0;
    }

    // Allocate a per-process L1 for L0[0] and copy kernel block descriptors.
    if (kernel_l0.entries[0].isValid() and kernel_l0.entries[0].isTable()) {
        const kernel_l1: *PageTable = @ptrFromInt(kernel_l0.entries[0].getPhysAddr());
        const new_l1_phys = pmm.allocPage() orelse return error.OutOfMemory;
        const new_l1: *PageTable = @ptrFromInt(new_l1_phys);

        for (0..ENTRIES_PER_TABLE) |i| {
            new_l1.entries[i] = kernel_l1.entries[i];
        }

        new_l0.entries[0].raw = new_l1_phys | DESC_TABLE;
    }

    return PhysAddr.from(new_l0_phys);
}

/// Destroy all user pages in an address space.
/// L0[0] contains a per-process L1 with kernel block descriptors and split
/// sub-tables for user pages at low VAs (0x400000). We free user page frames
/// and clear their L3 entries (set to 0) so subsequent accesses trigger
/// translation faults for demand paging. The split L2/L3 table pages are
/// kept because they still contain kernel identity-map entries needed for
/// device/RAM access. L0[1..511] are pure user pages — freed entirely.
pub fn destroyUserPages(l0_phys_addr: PhysAddr) void {
    const l0_phys = l0_phys_addr.toInt();
    if (l0_phys == 0) return; // No page table to destroy
    const l0: *PageTable = @ptrFromInt(l0_phys);

    // --- Handle L0[0]: per-process L1 with kernel identity map + user pages ---
    // Only clear user page entries; keep L1/L2/L3 table structure intact
    // so kernel identity-map access (UART, device MMIO, RAM) keeps working.
    if (l0.entries[0].isValid() and l0.entries[0].isTable()) {
        const l1_phys = l0.entries[0].getPhysAddr();
        const l1: *PageTable = @ptrFromInt(l1_phys);

        for (0..ENTRIES_PER_TABLE) |l1_idx| {
            if (!l1.entries[l1_idx].isValid()) continue;
            if (!l1.entries[l1_idx].isTable()) continue;

            const l2_phys = l1.entries[l1_idx].getPhysAddr();
            const l2: *PageTable = @ptrFromInt(l2_phys);

            for (0..ENTRIES_PER_TABLE) |l2_idx| {
                if (!l2.entries[l2_idx].isValid()) continue;

                if (!l2.entries[l2_idx].isTable()) {
                    // L2 block (2MB): user hugepages have ATTR_AP_USER
                    if (l2.entries[l2_idx].isBlock() and l2.entries[l2_idx].isUser()) {
                        pmm.freeHugePage(l2.entries[l2_idx].getPhysAddr());
                        l2.entries[l2_idx].raw = 0;
                    }
                    continue;
                }

                // L3 table — free user pages, skip kernel split pages
                const l3_phys = l2.entries[l2_idx].getPhysAddr();
                const l3: *PageTable = @ptrFromInt(l3_phys);

                for (0..ENTRIES_PER_TABLE) |l3_idx| {
                    if (!l3.entries[l3_idx].isValid()) continue;
                    if (!l3.entries[l3_idx].isUser()) continue;

                    const page_phys = l3.entries[l3_idx].getPhysAddr();
                    // freePage handles refcounting internally: if ref > 1
                    // it decrements and returns; if ref == 1 it frees.
                    // Do NOT use decRef + freePage — that's a double-free
                    // race (decRef frees in bitmap, another CPU allocates,
                    // then freePage frees the new owner's page).
                    pmm.freePage(page_phys);
                    l3.entries[l3_idx].raw = 0;
                }
                // Keep L3 table page — kernel split entries remain valid
            }
            // Keep L2 table page — kernel 2MB block entries remain valid
            // Keep L1 entry — still a table descriptor pointing to L2
        }
    }

    // --- Handle L0[1..511]: pure user pages, free everything ---
    for (1..ENTRIES_PER_TABLE) |l0_idx| {
        if (!l0.entries[l0_idx].isValid()) continue;
        if (!l0.entries[l0_idx].isTable()) continue;

        const l1_phys = l0.entries[l0_idx].getPhysAddr();
        const l1: *PageTable = @ptrFromInt(l1_phys);

        for (0..ENTRIES_PER_TABLE) |l1_idx| {
            if (!l1.entries[l1_idx].isValid()) continue;
            if (!l1.entries[l1_idx].isTable()) continue;

            const l2_phys = l1.entries[l1_idx].getPhysAddr();
            const l2: *PageTable = @ptrFromInt(l2_phys);

            for (0..ENTRIES_PER_TABLE) |l2_idx| {
                if (!l2.entries[l2_idx].isValid()) continue;
                if (!l2.entries[l2_idx].isTable()) {
                    if (l2.entries[l2_idx].isBlock()) {
                        pmm.freeHugePage(l2.entries[l2_idx].getPhysAddr());
                        l2.entries[l2_idx].raw = 0;
                    }
                    continue;
                }

                const l3_phys = l2.entries[l2_idx].getPhysAddr();
                const l3: *PageTable = @ptrFromInt(l3_phys);

                for (0..ENTRIES_PER_TABLE) |l3_idx| {
                    if (!l3.entries[l3_idx].isValid()) continue;

                    const page_phys = l3.entries[l3_idx].getPhysAddr();
                    pmm.freePage(page_phys);
                    l3.entries[l3_idx].raw = 0;
                }
                pmm.freePage(l3_phys);
                l2.entries[l2_idx].raw = 0;
            }
            pmm.freePage(l2_phys);
            l1.entries[l1_idx].raw = 0;
        }
        pmm.freePage(l1_phys);
        l0.entries[l0_idx].raw = 0;
    }
}

/// Destroy an address space completely (including per-process L1 and split tables)
pub fn destroyAddressSpace(l0_phys_addr: PhysAddr) void {
    const l0_phys = l0_phys_addr.toInt();
    destroyUserPages(l0_phys_addr);

    // Free page table pages for L0[0]: the per-process L1 and any split L2/L3
    // tables that destroyUserPages kept intact for kernel identity-map access.
    const l0: *PageTable = @ptrFromInt(l0_phys);
    if (l0.entries[0].isValid() and l0.entries[0].isTable()) {
        const l1_phys = l0.entries[0].getPhysAddr();
        const l1: *PageTable = @ptrFromInt(l1_phys);

        for (0..ENTRIES_PER_TABLE) |l1_idx| {
            if (!l1.entries[l1_idx].isValid()) continue;
            if (!l1.entries[l1_idx].isTable()) continue;

            const l2_phys = l1.entries[l1_idx].getPhysAddr();
            const l2: *PageTable = @ptrFromInt(l2_phys);

            for (0..ENTRIES_PER_TABLE) |l2_idx| {
                if (!l2.entries[l2_idx].isValid()) continue;
                if (!l2.entries[l2_idx].isTable()) continue;
                pmm.freePage(l2.entries[l2_idx].getPhysAddr()); // Free L3
            }
            pmm.freePage(l2_phys); // Free L2
        }
        pmm.freePage(l1_phys); // Free L1
    }

    pmm.freePage(l0_phys);
}

/// Switch to a different address space
pub fn switchAddressSpace(l0_phys: PhysAddr) void {
    const raw = l0_phys.toInt();
    asm volatile (
        \\msr TTBR0_EL1, %[ttbr]
        \\isb
        \\tlbi vmalle1is
        \\dsb sy
        \\isb
        :
        : [ttbr] "r" (raw),
    );
}

/// Translate virtual address to physical
pub fn translate(l0_phys: PhysAddr, virt: VirtAddr) ?PhysAddr {
    const l0_raw = l0_phys.toInt();
    const virt_raw = virt.toInt();
    const l0_idx = (virt_raw >> 39) & 0x1FF;
    const l1_idx = (virt_raw >> 30) & 0x1FF;
    const l2_idx = (virt_raw >> 21) & 0x1FF;
    const l3_idx = (virt_raw >> 12) & 0x1FF;
    const offset = virt_raw & 0xFFF;

    const l0: *PageTable = @ptrFromInt(l0_raw);
    if (!l0.entries[l0_idx].isValid()) return null;

    // Check for table vs block at L0 (shouldn't have blocks at L0)
    if (!l0.entries[l0_idx].isTable()) return null;

    const l1: *PageTable = @ptrFromInt(l0.entries[l0_idx].getPhysAddr());
    if (!l1.entries[l1_idx].isValid()) return null;

    // Check for 1GB block
    if (!l1.entries[l1_idx].isTable()) {
        return PhysAddr.from(l1.entries[l1_idx].getPhysAddr() + (virt_raw & 0x3FFFFFFF));
    }

    const l2: *PageTable = @ptrFromInt(l1.entries[l1_idx].getPhysAddr());
    if (!l2.entries[l2_idx].isValid()) return null;

    // Check for 2MB block
    if (!l2.entries[l2_idx].isTable()) {
        return PhysAddr.from(l2.entries[l2_idx].getPhysAddr() + (virt_raw & 0x1FFFFF));
    }

    const l3: *PageTable = @ptrFromInt(l2.entries[l2_idx].getPhysAddr());
    if (!l3.entries[l3_idx].isValid()) return null;

    return PhysAddr.from(l3.entries[l3_idx].getPhysAddr() + offset);
}

/// Get the kernel L0 physical address
pub fn getKernelL0() PhysAddr {
    return kernel_l0_phys;
}

/// Get a mutable pointer to the leaf PTE for a virtual address
pub fn getPTE(l0_phys_addr: PhysAddr, virt_addr: VirtAddr) ?*PTE {
    const l0_phys = l0_phys_addr.toInt();
    const virt = virt_addr.toInt();
    const l0_idx = (virt >> 39) & 0x1FF;
    const l1_idx = (virt >> 30) & 0x1FF;
    const l2_idx = (virt >> 21) & 0x1FF;
    const l3_idx = (virt >> 12) & 0x1FF;

    const l0: *PageTable = @ptrFromInt(l0_phys);
    if (!l0.entries[l0_idx].isValid()) return null;
    if (!l0.entries[l0_idx].isTable()) return null;

    const l1: *PageTable = @ptrFromInt(l0.entries[l0_idx].getPhysAddr());
    if (!l1.entries[l1_idx].isValid()) return null;
    if (!l1.entries[l1_idx].isTable()) return null;

    const l2: *PageTable = @ptrFromInt(l1.entries[l1_idx].getPhysAddr());
    if (!l2.entries[l2_idx].isValid()) return null;
    if (!l2.entries[l2_idx].isTable()) return null;

    const l3: *PageTable = @ptrFromInt(l2.entries[l2_idx].getPhysAddr());
    if (!l3.entries[l3_idx].isValid()) return null;

    return &l3.entries[l3_idx];
}

/// Invalidate TLB entry for a virtual address
pub fn invalidatePage(virt_addr: VirtAddr) void {
    const virt = virt_addr.toInt();
    asm volatile ("tlbi vale1is, %[virt]"
        :
        : [virt] "r" (virt >> 12),
    );
    asm volatile ("dsb sy");
    asm volatile ("isb");
}

/// Ensure instruction cache coherency after writing code to a demand-paged page.
/// ARM64 ICache is NOT coherent with DCache — after kernel writes code data
/// to a physical page (via identity mapping), other CPUs' ICaches may have
/// stale entries. Without this, SMP demand paging of executable pages causes
/// wild branches from stale instruction fetches.
///
/// data_va: identity-mapped address where kernel wrote the page data (= phys addr)
/// exec_va: user virtual address where instructions will be fetched from
pub fn syncCodePage(data_va_addr: PhysAddr, exec_va_addr: VirtAddr) void {
    const data_va = data_va_addr.toInt();
    const exec_va = exec_va_addr.toInt();
    const cache_line: u64 = 64;

    // Step 1: Clean DCache to Point of Unification for the data address
    // This ensures the written code data is visible beyond L1D cache
    var addr = data_va & ~@as(u64, 0xFFF);
    const data_end = addr + PAGE_SIZE;
    while (addr < data_end) : (addr += cache_line) {
        asm volatile ("dc cvau, %[addr]"
            :
            : [addr] "r" (addr),
            : .{ .memory = true }
        );
    }
    // Barrier: ensure all DCache cleans complete across Inner Shareable domain
    asm volatile ("dsb ish");

    // Step 2: Invalidate ICache for the user VA where code will execute.
    // IC IVAU invalidates ICache entries by VA. On QEMU TCG this
    // invalidates translation blocks for the specific page, which is
    // much more efficient than IC IALLUIS (which flushes ALL TBs).
    addr = exec_va & ~@as(u64, 0xFFF);
    const exec_end = addr + PAGE_SIZE;
    while (addr < exec_end) : (addr += cache_line) {
        asm volatile ("ic ivau, %[addr]"
            :
            : [addr] "r" (addr),
            : .{ .memory = true }
        );
    }
    // Barrier: ensure IC invalidations complete, then synchronize instruction stream
    asm volatile ("dsb ish");
    asm volatile ("isb");
}

/// Invalidate entire TLB
pub fn invalidateAll() void {
    asm volatile ("tlbi vmalle1is");
    asm volatile ("dsb sy");
    asm volatile ("isb");
}

/// Ensure a page table entry points to a valid next-level table
fn ensureTable(entry: *PTE) !u64 {
    if (entry.isValid() and entry.isTable()) {
        return entry.getPhysAddr();
    }

    // Allocate a new page table
    const new_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const table: *PageTable = @ptrFromInt(new_phys);

    // Zero the new table
    for (0..ENTRIES_PER_TABLE) |i| {
        table.entries[i].raw = 0;
    }

    // Ensure zeroing is visible to all CPUs' MMU walkers before installing
    // the descriptor. Without this barrier, another CPU's page table walker
    // can follow the new descriptor and read stale data from the recycled page.
    asm volatile ("dsb ishst");

    // Install as table descriptor
    entry.raw = new_phys | DESC_TABLE;

    return new_phys;
}

/// Fork an address space using Copy-on-Write.
/// Creates a new L0 page table for the child, sharing all user pages
/// with the parent via CoW. Both parent and child PTEs for writable
/// pages are marked read-only + PTE_COW, and ref counts are incremented.
/// The VMA list is used to skip stale PTEs (pages whose VMA was removed
/// but whose PTE was not cleaned up). Only PTEs covered by a VMA are
/// copied to the child and marked CoW. Caller must hold vma_lock.
pub fn forkAddressSpace(parent_l0_phys_addr: PhysAddr, vma_list: *const vma.VmaList) !PhysAddr {
    const parent_l0_phys = parent_l0_phys_addr.toInt();
    const child_l0_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const child_l0: *PageTable = @ptrFromInt(child_l0_phys);
    const parent_l0: *PageTable = @ptrFromInt(parent_l0_phys);

    for (0..ENTRIES_PER_TABLE) |i| {
        child_l0.entries[i].raw = 0;
    }

    // Deep-copy L0[0]: per-process L1 with kernel block descriptors + user pages.
    // Kernel blocks are copied as-is; user pages get CoW treatment.
    if (parent_l0.entries[0].isValid() and parent_l0.entries[0].isTable()) {
        const par_l1_phys = parent_l0.entries[0].getPhysAddr();
        const par_l1: *PageTable = @ptrFromInt(par_l1_phys);

        const ch_l1_phys = pmm.allocPage() orelse return error.OutOfMemory;
        const ch_l1: *PageTable = @ptrFromInt(ch_l1_phys);
        for (0..ENTRIES_PER_TABLE) |i| {
            ch_l1.entries[i].raw = 0;
        }
        child_l0.entries[0].raw = ch_l1_phys | DESC_TABLE;

        for (0..ENTRIES_PER_TABLE) |l1_i| {
            if (!par_l1.entries[l1_i].isValid()) continue;

            if (!par_l1.entries[l1_i].isTable()) {
                // Kernel 1GB block descriptor — copy as-is
                ch_l1.entries[l1_i] = par_l1.entries[l1_i];
                continue;
            }

            // Split L1 entry — deep-copy L2
            const par_l2_phys = par_l1.entries[l1_i].getPhysAddr();
            const par_l2: *PageTable = @ptrFromInt(par_l2_phys);

            const ch_l2_phys = pmm.allocPage() orelse return error.OutOfMemory;
            const ch_l2: *PageTable = @ptrFromInt(ch_l2_phys);
            for (0..ENTRIES_PER_TABLE) |i| {
                ch_l2.entries[i].raw = 0;
            }
            ch_l1.entries[l1_i].raw = ch_l2_phys | DESC_TABLE;

            for (0..ENTRIES_PER_TABLE) |l2_i| {
                if (!par_l2.entries[l2_i].isValid()) continue;

                if (!par_l2.entries[l2_i].isTable()) {
                    // L2 block (2MB kernel split or user hugepage) — copy as-is
                    ch_l2.entries[l2_i] = par_l2.entries[l2_i];
                    continue;
                }

                // L3 table — deep-copy with CoW for user pages
                const par_l3_phys = par_l2.entries[l2_i].getPhysAddr();
                const par_l3: *PageTable = @ptrFromInt(par_l3_phys);

                const ch_l3_phys = pmm.allocPage() orelse return error.OutOfMemory;
                const ch_l3: *PageTable = @ptrFromInt(ch_l3_phys);
                for (0..ENTRIES_PER_TABLE) |i| {
                    ch_l3.entries[i].raw = 0;
                }
                ch_l2.entries[l2_i].raw = ch_l3_phys | DESC_TABLE;

                for (0..ENTRIES_PER_TABLE) |l3_i| {
                    if (!par_l3.entries[l3_i].isValid()) continue;

                    const pte_raw = par_l3.entries[l3_i].raw;
                    const page_phys = par_l3.entries[l3_i].getPhysAddr();

                    if ((pte_raw & ATTR_AP_USER) != 0) {
                        // User page — apply CoW
                        if ((pte_raw & ATTR_AP_RO) == 0) {
                            const cow_pte = pte_raw | ATTR_AP_RO | PTE_COW;
                            par_l3.entries[l3_i].raw = cow_pte;
                            ch_l3.entries[l3_i].raw = cow_pte;
                            pmm.incRef(page_phys);
                        } else {
                            ch_l3.entries[l3_i].raw = pte_raw;
                            pmm.incRef(page_phys);
                        }
                    } else {
                        // Kernel split page — copy as-is, no ref counting
                        ch_l3.entries[l3_i] = par_l3.entries[l3_i];
                    }
                }
            }
        }
    }

    // Walk user entries (L0[1..511]) and deep-copy page table structure
    for (1..ENTRIES_PER_TABLE) |l0_idx| {
        if (!parent_l0.entries[l0_idx].isValid()) continue;
        if (!parent_l0.entries[l0_idx].isTable()) continue;

        const parent_l1_phys = parent_l0.entries[l0_idx].getPhysAddr();
        const parent_l1: *PageTable = @ptrFromInt(parent_l1_phys);

        // Allocate child L1
        const child_l1_phys = pmm.allocPage() orelse return error.OutOfMemory;
        const child_l1: *PageTable = @ptrFromInt(child_l1_phys);
        for (0..ENTRIES_PER_TABLE) |i| {
            child_l1.entries[i].raw = 0;
        }
        child_l0.entries[l0_idx].raw = child_l1_phys | DESC_TABLE;

        for (0..ENTRIES_PER_TABLE) |l1_idx| {
            if (!parent_l1.entries[l1_idx].isValid()) continue;
            if (!parent_l1.entries[l1_idx].isTable()) continue;

            const parent_l2_phys = parent_l1.entries[l1_idx].getPhysAddr();
            const parent_l2: *PageTable = @ptrFromInt(parent_l2_phys);

            // Allocate child L2
            const child_l2_phys = pmm.allocPage() orelse return error.OutOfMemory;
            const child_l2: *PageTable = @ptrFromInt(child_l2_phys);
            for (0..ENTRIES_PER_TABLE) |i| {
                child_l2.entries[i].raw = 0;
            }
            child_l1.entries[l1_idx].raw = child_l2_phys | DESC_TABLE;

            for (0..ENTRIES_PER_TABLE) |l2_idx| {
                if (!parent_l2.entries[l2_idx].isValid()) continue;
                if (!parent_l2.entries[l2_idx].isTable()) continue;

                const parent_l3_phys = parent_l2.entries[l2_idx].getPhysAddr();
                const parent_l3: *PageTable = @ptrFromInt(parent_l3_phys);

                // Allocate child L3
                const child_l3_phys = pmm.allocPage() orelse return error.OutOfMemory;
                const child_l3: *PageTable = @ptrFromInt(child_l3_phys);
                for (0..ENTRIES_PER_TABLE) |i| {
                    child_l3.entries[i].raw = 0;
                }
                child_l2.entries[l2_idx].raw = child_l3_phys | DESC_TABLE;

                for (0..ENTRIES_PER_TABLE) |l3_idx| {
                    if (!parent_l3.entries[l3_idx].isValid()) continue;

                    const pte_raw = parent_l3.entries[l3_idx].raw;

                    // Only process user-accessible pages
                    if ((pte_raw & ATTR_AP_USER) == 0) continue;

                    const page_phys = parent_l3.entries[l3_idx].getPhysAddr();

                    // Compute virtual address for this PTE
                    const page_virt = (l0_idx << 39) | (l1_idx << 30) |
                        (l2_idx << 21) | (l3_idx << 12);

                    if (vma.findVma(vma_list, page_virt) == null) {
                        // Stale PTE: no backing VMA (munmap/MAP_FIXED orphan).
                        // Cannot use CoW — marking the parent read-only would
                        // cause a CoW fault with no VMA to resolve it.
                        // Instead, give the child a private copy of the page
                        // data so it can access it between fork and execve.
                        // The parent's PTE remains unchanged (writable).
                        const copy = pmm.allocPage() orelse continue;
                        const src: [*]const u8 = @ptrFromInt(page_phys);
                        const dst: [*]u8 = @ptrFromInt(copy);
                        for (0..PAGE_SIZE) |ci| {
                            dst[ci] = src[ci];
                        }
                        // Child gets a private page with same attributes
                        child_l3.entries[l3_idx].raw =
                            (copy & 0x0000_FFFF_FFFF_F000) | (pte_raw & 0xFFFF_0000_0000_0FFF);
                        continue;
                    }

                    if ((pte_raw & ATTR_AP_RO) == 0) {
                        // Was writable: set read-only and CoW in both parent and child
                        const cow_pte = (pte_raw | ATTR_AP_RO | PTE_COW);
                        parent_l3.entries[l3_idx].raw = cow_pte;
                        child_l3.entries[l3_idx].raw = cow_pte;
                        pmm.incRef(page_phys);
                    } else {
                        // Already read-only (code pages, etc) — share directly
                        child_l3.entries[l3_idx].raw = pte_raw;
                        pmm.incRef(page_phys);
                    }
                }
            }
        }
    }

    // Flush TLB for parent since we modified its PTEs
    invalidateAll();

    return PhysAddr.from(child_l0_phys);
}

/// Remap a CoW page as writable after handling the fault.
/// If ref count > 1: copy the page, decrement old ref, map new page writable.
/// If ref count == 1: just clear CoW and make writable (we're the sole owner).
pub fn handleCowFault(l0_phys: PhysAddr, virt: VirtAddr) !void {
    const pte = getPTE(l0_phys, virt) orelse return error.OutOfMemory;

    if (!pte.isCow()) return error.OutOfMemory;

    const old_phys = pte.getPhysAddr();
    const ref = pmm.getRef(old_phys);

    if (ref > 1) {
        // Multiple references — must copy
        const new_phys = pmm.allocPage() orelse return error.OutOfMemory;

        // Copy page contents
        const src: [*]const u8 = @ptrFromInt(old_phys);
        const dst: [*]u8 = @ptrFromInt(new_phys);
        for (0..PAGE_SIZE) |i| {
            dst[i] = src[i];
        }

        // Decrement old page ref
        _ = pmm.decRef(old_phys);

        // Update PTE: new page, writable, no CoW
        var new_raw = pte.raw;
        new_raw = (new_raw & ~@as(u64, 0x0000_FFFF_FFFF_F000)) | (new_phys & 0x0000_FFFF_FFFF_F000);
        new_raw &= ~ATTR_AP_RO;
        new_raw &= ~PTE_COW;
        pte.raw = new_raw;
    } else {
        // Sole owner — just clear CoW and make writable
        pte.raw = pte.raw & ~ATTR_AP_RO & ~PTE_COW;
    }

    invalidatePage(virt);
}

/// Update page permissions for an already-mapped page.
/// Used by mprotect to change read/write/execute permissions without remapping.
pub fn updatePTEPermissions(l0_phys: PhysAddr, virt: VirtAddr, writable: bool, executable: bool, user: bool) void {
    const pte = getPTE(l0_phys, virt) orelse return;
    if (!pte.isValid()) return;

    var raw = pte.raw;

    // AP[2:1] field: bit 7 = AP[2] (RO at EL0), bit 6 = AP[1] (user access)
    // Clear AP bits first, then set
    raw &= ~@as(u64, ATTR_AP_RO | ATTR_AP_USER);

    if (!writable) {
        raw |= ATTR_AP_RO; // Set read-only
    }
    if (user) {
        raw |= ATTR_AP_USER; // Enable EL0 access
    }

    // UXN (bit 54) — User Execute Never
    if (executable) {
        raw &= ~ATTR_UXN;
    } else {
        raw |= ATTR_UXN;
    }

    // PXN (bit 53) — always set for user pages (no kernel exec of user code)
    if (user) {
        raw |= ATTR_PXN;
    }

    pte.raw = raw;
    invalidatePage(virt);
}

/// Check if VMM is initialized
pub fn isInitialized() bool {
    return initialized;
}
