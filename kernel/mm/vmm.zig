/// Virtual Memory Manager — 4-level x86_64 page tables.
/// PML4 → PDPT → PD → PT, 512 entries per table, 4 KiB pages.
///
/// Virtual address layout (48-bit canonical):
///   [63:48] sign-extend of bit 47
///   [47:39] PML4 index  (9 bits)
///   [38:30] PDPT index  (9 bits)
///   [29:21] PD index    (9 bits)
///   [20:12] PT index    (9 bits)
///   [11:0]  page offset (12 bits)

const types = @import("../types.zig");
const pmm = @import("pmm.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");
const lapic = @import("../arch/x86_64/lapic.zig");
const smp = @import("../arch/x86_64/smp.zig");

const PAGE_SIZE = types.PAGE_SIZE;

// --- Page Table Entry ---

pub const PTE = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    huge_page: bool = false, // 2 MiB (PD level) or 1 GiB (PDPT level)
    global: bool = false,
    os_bits: u3 = 0, // Available for OS use (capability bits)
    phys_frame: u40 = 0, // Physical page frame number (bits [51:12] of phys addr)
    reserved: u11 = 0,
    no_execute: bool = false,

    pub fn getPhysAddr(self: PTE) types.PhysAddr {
        return @as(u64, self.phys_frame) << 12;
    }

    pub fn setPhysAddr(self: *PTE, phys: types.PhysAddr) void {
        self.phys_frame = @truncate(phys >> 12);
    }

    pub fn isPresent(self: PTE) bool {
        return self.present;
    }
};

pub const PageTable = struct {
    entries: [512]PTE,
};

// --- CoW / OS PTE bits ---

/// PTE os_bits bit 0: page is copy-on-write (present + read-only + this bit = CoW)
pub const PTE_COW: u3 = 1;

// --- Mapping flags ---

pub const MapFlags = struct {
    writable: bool = false,
    user: bool = false,
    no_execute: bool = false,
    global: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
};

// --- State ---

var kernel_pml4_phys: types.PhysAddr = 0;

// --- Public API ---

pub fn init() void {
    // Keep the bootloader's page tables. The PDPTs (with 1GB huge pages for
    // HHDM and 2MB pages for kernel) live in bootloader_reclaimable memory.
    // The bootloader memory map marks loader_data as reserved so the PMM
    // won't reclaim those pages. Cost: ~6MB unreclaimable. Zero complexity.
    kernel_pml4_phys = readCR3();

    serial.writeString("[vmm]  Kernel PML4 at phys 0x");
    writeHex(kernel_pml4_phys);
    serial.writeString("\n");
}

/// Map a 4 KiB virtual page to a physical frame in the given PML4.
/// Allocates intermediate tables as needed.
pub fn mapPage(pml4_phys: types.PhysAddr, virt: types.VirtAddr, phys: types.PhysAddr, flags: MapFlags) !void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    // Walk PML4 → PDPT
    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    const pdpt_phys = try ensureTable(&pml4.entries[pml4_idx]);

    // Walk PDPT → PD
    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pdpt_phys);
    const pd_phys = try ensureTable(&pdpt.entries[pdpt_idx]);

    // Walk PD → PT
    const pd: *PageTable = hhdm.physToPtr(PageTable, pd_phys);
    const pt_phys = try ensureTable(&pd.entries[pd_idx]);

    // Set the final PT entry
    const pt: *PageTable = hhdm.physToPtr(PageTable, pt_phys);
    var pte = &pt.entries[pt_idx];

    pte.* = .{
        .present = true,
        .writable = flags.writable,
        .user = flags.user,
        .no_execute = flags.no_execute,
        .global = flags.global,
        .write_through = flags.write_through,
        .cache_disable = flags.cache_disable,
    };
    pte.setPhysAddr(phys);
}

/// Map a 2 MiB huge page via a PD entry (no PT needed).
/// Virtual and physical addresses must be 2MB-aligned.
pub fn mapHugePage(pml4_phys: types.PhysAddr, virt: types.VirtAddr, phys: types.PhysAddr, flags: MapFlags) !void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    const pdpt_phys = try ensureTable(&pml4.entries[pml4_idx]);

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pdpt_phys);
    const pd_phys = try ensureTable(&pdpt.entries[pdpt_idx]);

    const pd: *PageTable = hhdm.physToPtr(PageTable, pd_phys);

    var pde = &pd.entries[pd_idx];
    pde.* = .{
        .present = true,
        .writable = flags.writable,
        .user = flags.user,
        .no_execute = flags.no_execute,
        .global = flags.global,
        .write_through = flags.write_through,
        .cache_disable = flags.cache_disable,
        .huge_page = true, // PS bit — this PDE maps 2 MiB directly
    };
    pde.setPhysAddr(phys);
}

/// Map a 1 GiB gigapage via a PDPT entry (no PD or PT needed).
/// Virtual and physical addresses must be 1GB-aligned.
/// Used for DPDK-style DMA regions: single TLB entry covers 1 GB.
pub fn mapGigaPage(pml4_phys: types.PhysAddr, virt: types.VirtAddr, phys: types.PhysAddr, flags: MapFlags) !void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    const pdpt_phys = try ensureTable(&pml4.entries[pml4_idx]);

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pdpt_phys);

    var pde = &pdpt.entries[pdpt_idx];
    pde.* = .{
        .present = true,
        .writable = flags.writable,
        .user = flags.user,
        .no_execute = flags.no_execute,
        .global = flags.global,
        .write_through = flags.write_through,
        .cache_disable = flags.cache_disable,
        .huge_page = true, // PS bit at PDPT level — maps 1 GiB directly
    };
    pde.setPhysAddr(phys);
}

/// Unmap a 1 GiB gigapage.
pub fn unmapGigaPage(pml4_phys: types.PhysAddr, virt: types.VirtAddr) void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    if (!pml4.entries[pml4_idx].isPresent()) return;

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pml4.entries[pml4_idx].getPhysAddr());
    pdpt.entries[pdpt_idx] = .{};

    invlpg(virt);
}

/// Unmap a 2 MiB huge page.
pub fn unmapHugePage(pml4_phys: types.PhysAddr, virt: types.VirtAddr) void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    if (!pml4.entries[pml4_idx].isPresent()) return;

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pml4.entries[pml4_idx].getPhysAddr());
    if (!pdpt.entries[pdpt_idx].isPresent()) return;

    const pd: *PageTable = hhdm.physToPtr(PageTable, pdpt.entries[pdpt_idx].getPhysAddr());
    pd.entries[pd_idx] = .{};

    invlpg(virt);
}

/// Unmap a 4 KiB virtual page. Does NOT free intermediate tables.
pub fn unmapPage(pml4_phys: types.PhysAddr, virt: types.VirtAddr) void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    if (!pml4.entries[pml4_idx].isPresent()) return;
    const pdpt_phys = pml4.entries[pml4_idx].getPhysAddr();

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pdpt_phys);
    if (!pdpt.entries[pdpt_idx].isPresent()) return;
    const pd_phys = pdpt.entries[pdpt_idx].getPhysAddr();

    const pd: *PageTable = hhdm.physToPtr(PageTable, pd_phys);
    if (!pd.entries[pd_idx].isPresent()) return;
    const pt_phys = pd.entries[pd_idx].getPhysAddr();

    const pt: *PageTable = hhdm.physToPtr(PageTable, pt_phys);
    pt.entries[pt_idx] = .{}; // Zero = not present

    invlpg(virt);
    tlbShootdown(); // Flush stale TLB entries on other CPUs
}

/// Create a new address space with the kernel half (upper 256 PML4 entries) shared.
pub fn createAddressSpace() !types.PhysAddr {
    const new_pml4_phys = pmm.allocPage() orelse return error.OutOfMemory;
    pmm.incRef(new_pml4_phys); // Double-ref page table pages
    const new_pml4: *PageTable = hhdm.physToPtr(PageTable, new_pml4_phys);
    const kernel_pml4: *PageTable = hhdm.physToPtr(PageTable, kernel_pml4_phys);

    // Clear user half (entries 0-255)
    for (0..256) |i| {
        new_pml4.entries[i] = .{};
    }

    // Share kernel half (entries 256-511) — same physical PDPT/PD/PT
    for (256..512) |i| {
        new_pml4.entries[i] = kernel_pml4.entries[i];
    }
    return new_pml4_phys;
}

/// Free all user-space pages in an address space (PML4 entries 0-255).
/// Walks the 4-level page table hierarchy, freeing leaf pages (with CoW
/// ref counting) and intermediate table pages. Does NOT free the PML4 itself.
pub fn destroyUserPages(pml4_phys: types.PhysAddr) void {
    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    const max_phys = pmm.getHighestPhys();

    // Walk user half only (entries 0-255)
    for (0..256) |pml4_idx| {
        if (!pml4.entries[pml4_idx].isPresent()) continue;
        const pdpt_phys = pml4.entries[pml4_idx].getPhysAddr();
        if (pdpt_phys == 0 or pdpt_phys >= max_phys) { pml4.entries[pml4_idx] = .{}; continue; }
        const pdpt: *PageTable = hhdm.physToPtr(PageTable, pdpt_phys);

        for (0..512) |pdpt_idx| {
            if (!pdpt.entries[pdpt_idx].isPresent()) continue;
            if (pdpt.entries[pdpt_idx].huge_page) continue; // Skip 1GiB pages
            const pd_phys = pdpt.entries[pdpt_idx].getPhysAddr();
            if (pd_phys == 0 or pd_phys >= max_phys) { pdpt.entries[pdpt_idx] = .{}; continue; }
            const pd: *PageTable = hhdm.physToPtr(PageTable, pd_phys);

            for (0..512) |pd_idx| {
                if (!pd.entries[pd_idx].isPresent()) continue;
                if (pd.entries[pd_idx].huge_page) {
                    const hp = pd.entries[pd_idx].getPhysAddr();
                    if (hp > 0 and hp < max_phys) pmm.freeHugePage(hp);
                    pd.entries[pd_idx] = .{};
                    continue;
                }
                const pt_phys = pd.entries[pd_idx].getPhysAddr();
                if (pt_phys == 0 or pt_phys >= max_phys) { pd.entries[pd_idx] = .{}; continue; }
                const pt: *PageTable = hhdm.physToPtr(PageTable, pt_phys);

                for (0..512) |pt_idx| {
                    if (!pt.entries[pt_idx].isPresent()) continue;
                    const page_phys = pt.entries[pt_idx].getPhysAddr();
                    if (page_phys == 0 or page_phys >= max_phys) { pt.entries[pt_idx] = .{}; continue; }

                    // Handle CoW pages via ref counting.
                    // decRef already frees the page when count reaches 0.
                    if (pt.entries[pt_idx].os_bits & PTE_COW != 0) {
                        _ = pmm.decRef(page_phys);
                    } else {
                        pmm.freePage(page_phys);
                    }
                    pt.entries[pt_idx] = .{};
                }
                // Free the PT page (double-ref: 2→1→0)
                // Guard: skip if already freed (ref=0) to prevent over-free
                if (pmm.getRef(pt_phys) > 0) {
                    pmm.freePage(pt_phys);
                    if (pmm.getRef(pt_phys) > 0) pmm.freePage(pt_phys);
                }
                pd.entries[pd_idx] = .{};
            }
            // Free the PD page (double-ref: 2→1→0)
            if (pmm.getRef(pd_phys) > 0) {
                pmm.freePage(pd_phys);
                if (pmm.getRef(pd_phys) > 0) pmm.freePage(pd_phys);
            }
            pdpt.entries[pdpt_idx] = .{};
        }
        // Free the PDPT page (double-ref: 2→1→0)
        if (pmm.getRef(pdpt_phys) > 0) {
            pmm.freePage(pdpt_phys);
            if (pmm.getRef(pdpt_phys) > 0) pmm.freePage(pdpt_phys);
        }
        pml4.entries[pml4_idx] = .{};
    }
}

/// Destroy an address space. Frees user pages and the PML4 page.
pub fn destroyAddressSpace(pml4_phys: types.PhysAddr) void {
    destroyUserPages(pml4_phys);
    // PML4 was allocated by createAddressSpace with double-ref
    if (pmm.getRef(pml4_phys) > 0) {
        pmm.freePage(pml4_phys);
        if (pmm.getRef(pml4_phys) > 0) pmm.freePage(pml4_phys);
    }
}

/// Switch to a different address space.
pub fn switchAddressSpace(pml4_phys: types.PhysAddr) void {
    writeCR3(pml4_phys);
}

/// Get the physical address mapped at a virtual address, or null if not mapped.
pub fn translate(pml4_phys: types.PhysAddr, virt: types.VirtAddr) ?types.PhysAddr {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;
    const offset = virt & 0xFFF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    if (!pml4.entries[pml4_idx].isPresent()) return null;

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pml4.entries[pml4_idx].getPhysAddr());
    if (!pdpt.entries[pdpt_idx].isPresent()) return null;

    // Check for 1 GiB huge page
    if (pdpt.entries[pdpt_idx].huge_page) {
        return pdpt.entries[pdpt_idx].getPhysAddr() + (virt & 0x3FFFFFFF);
    }

    const pd: *PageTable = hhdm.physToPtr(PageTable, pdpt.entries[pdpt_idx].getPhysAddr());
    if (!pd.entries[pd_idx].isPresent()) return null;

    // Check for 2 MiB huge page
    if (pd.entries[pd_idx].huge_page) {
        return pd.entries[pd_idx].getPhysAddr() + (virt & 0x1FFFFF);
    }

    const pt: *PageTable = hhdm.physToPtr(PageTable, pd.entries[pd_idx].getPhysAddr());
    if (!pt.entries[pt_idx].isPresent()) return null;

    return pt.entries[pt_idx].getPhysAddr() + offset;
}

/// Get the kernel PML4 physical address.
pub fn getKernelPML4() types.PhysAddr {
    return kernel_pml4_phys;
}

/// Get a mutable pointer to the leaf PTE for a virtual address.
/// Returns null if any intermediate table is not present.
pub fn getPTE(pml4_phys: types.PhysAddr, virt: types.VirtAddr) ?*PTE {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    if (!pml4.entries[pml4_idx].isPresent()) return null;

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pml4.entries[pml4_idx].getPhysAddr());
    if (!pdpt.entries[pdpt_idx].isPresent()) return null;
    if (pdpt.entries[pdpt_idx].huge_page) return null; // 1GiB pages not supported

    const pd: *PageTable = hhdm.physToPtr(PageTable, pdpt.entries[pdpt_idx].getPhysAddr());
    if (!pd.entries[pd_idx].isPresent()) return null;
    if (pd.entries[pd_idx].huge_page) return null; // 2MiB pages not supported

    const pt: *PageTable = hhdm.physToPtr(PageTable, pd.entries[pd_idx].getPhysAddr());
    if (!pt.entries[pt_idx].isPresent()) return null;

    return &pt.entries[pt_idx];
}

// --- Page fault handling ---

/// Page fault error code bits
pub const PageFaultError = packed struct(u64) {
    present: bool, // 0=not-present, 1=protection violation
    write: bool, // 0=read, 1=write
    user: bool, // 0=kernel, 1=user
    reserved_write: bool, // 1=fault from reserved bit set in PTE
    instruction_fetch: bool, // 1=instruction fetch (NX violation)
    protection_key: bool, // 1=protection key violation
    shadow_stack: bool, // 1=shadow stack access
    _pad: u57 = 0,
};

/// Log a fatal page fault (called when fault.resolve returns false).
pub fn logPageFault(fault_addr: u64, error_code: u64) void {
    const err: PageFaultError = @bitCast(error_code);

    serial.writeString("[vmm]  Page fault at 0x");
    writeHex(fault_addr);
    serial.writeString(" (");
    if (err.user) serial.writeString("user ") else serial.writeString("kernel ");
    if (err.write) serial.writeString("write") else if (err.instruction_fetch) serial.writeString("exec") else serial.writeString("read");
    if (!err.present) serial.writeString(", not present") else serial.writeString(", protection");
    serial.writeString(")\n");
}

// --- Internal helpers ---

/// Ensure a page table entry points to a valid next-level table.
/// If not present, allocate a new page, zero it, and install it.
fn ensureTable(entry: *PTE) !types.PhysAddr {
    if (entry.isPresent()) {
        return entry.getPhysAddr();
    }

    // Allocate a new page table page
    const new_phys = pmm.allocPage() orelse return error.OutOfMemory;

    // Double-ref page table pages: ref_count=2 protects against an erroneous
    // single freePage (drops 2→1 instead of actually freeing the page).
    pmm.incRef(new_phys);

    // Zero the new table via HHDM
    const table: *PageTable = hhdm.physToPtr(PageTable, new_phys);
    for (0..512) |i| {
        table.entries[i] = .{};
    }

    // Install in parent with permissive flags (leaf PTEs control actual access).
    // Two-step memory write: write flags to memory first (phys_frame=0),
    // then call setPhysAddr through the memory pointer. Avoids Zig 0.16
    // packed struct codegen bug where setPhysAddr on a stack-local PTE
    // may not properly persist the phys_frame field.
    entry.* = .{
        .present = true,
        .writable = true,
        .user = true,
    };
    entry.setPhysAddr(new_phys);

    return new_phys;
}

pub fn invlpg(virt: types.VirtAddr) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true }
    );
}

// --- TLB Shootdown (SMP Step 6) ---

/// Atomic acknowledgment counter for TLB shootdown.
var shootdown_ack: u32 = 0;

/// Broadcast TLB flush to all other CPUs.
/// Non-blocking: sends IPI and returns immediately. APs handle it when
/// they next service interrupts. This avoids deadlock when called from
/// interrupt context (where APs may have IRQs disabled).
pub fn tlbShootdown() void {
    if (smp.online_cpus <= 1) return;
    lapic.broadcastIpi(lapic.TLB_SHOOTDOWN_VECTOR);
}

/// Handle a TLB shootdown IPI — flush entire TLB by reloading CR3.
/// Called from IDT vector handler.
pub fn handleTlbShootdown() void {
    // Full TLB flush: reload CR3
    const cr3 = readCR3();
    writeCR3(cr3);
    // Signal completion
    _ = @atomicRmw(u32, &shootdown_ack, .Add, 1, .release);
}

fn readCR3() u64 {
    return asm volatile ("movq %%cr3, %[cr3]"
        : [cr3] "=r" (-> u64),
    );
}

fn writeCR3(val: u64) void {
    asm volatile ("movq %[cr3], %%cr3"
        :
        : [cr3] "r" (val),
        : .{ .memory = true }
    );
}

// --- Output helpers ---

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        serial.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    serial.writeString(buf[i..]);
}
