/// RISC-V Sv39 Virtual Memory Manager.
///
/// Sv39: 3-level page table, 39-bit virtual address space.
///   VPN[2] (bits 38:30) → L2 page table (root, pointed to by satp)
///   VPN[1] (bits 29:21) → L1 page table
///   VPN[0] (bits 20:12) → L0 page table (leaf)
///   Offset (bits 11:0)  → byte offset within page
///
/// PTE format (64-bit):
///   Bits 63:54 — Reserved
///   Bits 53:10 — PPN (Physical Page Number)
///   Bits 9:8   — RSW (reserved for software)
///   Bit 7 — D (Dirty)
///   Bit 6 — A (Accessed)
///   Bit 5 — G (Global)
///   Bit 4 — U (User accessible)
///   Bit 3 — X (Executable)
///   Bit 2 — W (Writable)
///   Bit 1 — R (Readable)
///   Bit 0 — V (Valid)
///
/// Identity mapping: phys == virt (like ARM64 port).

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");

const PAGE_SIZE: u64 = 4096;

// PTE flags
const PTE_V: u64 = 1 << 0; // Valid
const PTE_R: u64 = 1 << 1; // Read
const PTE_W: u64 = 1 << 2; // Write
const PTE_X: u64 = 1 << 3; // Execute
const PTE_U: u64 = 1 << 4; // User
const PTE_G: u64 = 1 << 5; // Global
const PTE_A: u64 = 1 << 6; // Accessed
const PTE_D: u64 = 1 << 7; // Dirty
// RSW bits (reserved for software, bits 9:8)
pub const PTE_COW: u64 = 1 << 8; // Copy-on-Write (software bit)

/// Sv39 mode value for satp CSR (bits 63:60)
const SATP_SV39: u64 = 8 << 60;

/// Page table entry
const PTE = u64;

/// Extract physical page number from PTE
inline fn ptePPN(pte: PTE) u64 {
    return ((pte >> 10) & 0xFFFFFFFFFFF) << 12;
}

/// Create a PTE from physical address and flags
inline fn makePTE(phys: u64, flags: u64) PTE {
    return ((phys >> 12) << 10) | flags;
}

/// Extract VPN indices from virtual address
inline fn vpn2(va: u64) usize {
    return @truncate((va >> 30) & 0x1FF);
}
inline fn vpn1(va: u64) usize {
    return @truncate((va >> 21) & 0x1FF);
}
inline fn vpn0(va: u64) usize {
    return @truncate((va >> 12) & 0x1FF);
}

// ---- State ----

var kernel_root_pt: u64 = 0; // Physical address of kernel's L2 page table
var mmu_initialized: bool = false;

/// Initialize MMU with identity mapping.
/// Maps all RAM as RWX with gigapage entries (1 GB pages at L2 level).
pub fn init() !void {
    // Allocate root page table (L2)
    const root_phys = pmm.allocPage() orelse return error.OutOfMemory;
    zeroPage(root_phys);

    const root: [*]volatile PTE = @ptrFromInt(root_phys);

    // Identity map RAM region using 1GB superpages (L2 leaf entries).
    // QEMU virt: RAM at 0x80000000. Map 0x80000000-0xBFFFFFFF (1 GB).
    // VPN[2] for 0x80000000 = (0x80000000 >> 30) & 0x1FF = 2
    const ram_vpn2 = vpn2(0x80000000);
    root[ram_vpn2] = makePTE(0x80000000, PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D | PTE_G);

    // Also map 0x00000000-0x3FFFFFFF for MMIO (UART at 0x10000000, PLIC at 0x0C000000)
    root[0] = makePTE(0x00000000, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_G);

    kernel_root_pt = root_phys;

    // Enable Sv39 paging: write satp = (mode=8 << 60) | (PPN of root table)
    const satp_val = SATP_SV39 | (root_phys >> 12);
    asm volatile ("csrw satp, %[val]" :: [val] "r" (satp_val));
    // Fence to ensure TLB sees new page tables
    asm volatile ("sfence.vma zero, zero");

    mmu_initialized = true;
    uart.writeString("[vmm]  Sv39 MMU enabled (identity mapping)\n");
    uart.print("[vmm]  Root PT at {x}, satp={x}\n", .{ root_phys, satp_val });
}

/// Create a new user address space. Returns physical address of root page table.
/// The kernel half (VPN[2] >= 2) is shared from the kernel root table.
pub fn createAddressSpace() !u64 {
    const root_phys = pmm.allocPage() orelse return error.OutOfMemory;
    zeroPage(root_phys);

    // Copy kernel mappings (top entries) from kernel root PT
    const new_root: [*]volatile PTE = @ptrFromInt(root_phys);
    const kern_root: [*]volatile PTE = @ptrFromInt(kernel_root_pt);

    // Copy entries for VPN[2] >= 2 (kernel space: 0x80000000+)
    for (2..512) |i| {
        new_root[i] = kern_root[i];
    }
    // Copy MMIO mapping (entry 0)
    new_root[0] = kern_root[0];

    return root_phys;
}

/// Map a single 4KB page in an address space.
pub const MapFlags = struct {
    user: bool = false,
    writable: bool = false,
    executable: bool = false,
};

pub fn mapPage(root_phys: u64, virt: u64, phys: u64, flags: MapFlags) !void {
    const root: [*]volatile PTE = @ptrFromInt(root_phys);

    // Walk/allocate L2 → L1
    var l1_phys: u64 = undefined;
    const l2_entry = root[vpn2(virt)];
    if (l2_entry & PTE_V != 0 and l2_entry & (PTE_R | PTE_W | PTE_X) == 0) {
        // Valid non-leaf entry — points to L1 table
        l1_phys = ptePPN(l2_entry);
    } else if (l2_entry & PTE_V == 0) {
        // No entry — allocate L1 table
        l1_phys = pmm.allocPage() orelse return error.OutOfMemory;
        zeroPage(l1_phys);
        root[vpn2(virt)] = makePTE(l1_phys, PTE_V);
    } else {
        // Superpage entry at L2 — can't map 4KB page here
        return error.OutOfMemory;
    }

    // Walk/allocate L1 → L0
    const l1: [*]volatile PTE = @ptrFromInt(l1_phys);
    var l0_phys: u64 = undefined;
    const l1_entry = l1[vpn1(virt)];
    if (l1_entry & PTE_V != 0 and l1_entry & (PTE_R | PTE_W | PTE_X) == 0) {
        l0_phys = ptePPN(l1_entry);
    } else if (l1_entry & PTE_V == 0) {
        l0_phys = pmm.allocPage() orelse return error.OutOfMemory;
        zeroPage(l0_phys);
        l1[vpn1(virt)] = makePTE(l0_phys, PTE_V);
    } else {
        return error.OutOfMemory;
    }

    // Set L0 leaf entry
    const l0: [*]volatile PTE = @ptrFromInt(l0_phys);
    var pte_flags: u64 = PTE_V | PTE_A | PTE_D;
    if (flags.user) pte_flags |= PTE_U;
    if (flags.writable) pte_flags |= PTE_W;
    if (flags.executable) pte_flags |= PTE_X;
    // At least one of R/W/X must be set for a leaf entry
    pte_flags |= PTE_R; // Always readable
    l0[vpn0(virt)] = makePTE(phys, pte_flags);
}

/// Translate a virtual address to physical using a page table.
pub fn translate(root_phys: u64, virt: u64) ?u64 {
    const root: [*]volatile PTE = @ptrFromInt(root_phys);

    const l2_entry = root[vpn2(virt)];
    if (l2_entry & PTE_V == 0) return null;
    if (l2_entry & (PTE_R | PTE_W | PTE_X) != 0) {
        // L2 superpage (1 GB)
        return ptePPN(l2_entry) | (virt & 0x3FFFFFFF);
    }

    const l1: [*]volatile PTE = @ptrFromInt(ptePPN(l2_entry));
    const l1_entry = l1[vpn1(virt)];
    if (l1_entry & PTE_V == 0) return null;
    if (l1_entry & (PTE_R | PTE_W | PTE_X) != 0) {
        // L1 superpage (2 MB)
        return ptePPN(l1_entry) | (virt & 0x1FFFFF);
    }

    const l0: [*]volatile PTE = @ptrFromInt(ptePPN(l1_entry));
    const l0_entry = l0[vpn0(virt)];
    if (l0_entry & PTE_V == 0) return null;
    return ptePPN(l0_entry) | (virt & 0xFFF);
}

/// Switch to a different address space.
pub fn switchAddressSpace(root_phys: u64) void {
    const satp_val = SATP_SV39 | (root_phys >> 12);
    asm volatile ("csrw satp, %[val]" :: [val] "r" (satp_val));
    asm volatile ("sfence.vma zero, zero");
}

/// Invalidate a single TLB entry.
pub fn invalidatePage(virt: u64) void {
    asm volatile ("sfence.vma %[addr], zero" :: [addr] "r" (virt));
}

/// Destroy an address space (free all user page tables, not kernel mappings).
pub fn destroyAddressSpace(root_phys: u64) void {
    const root: [*]volatile PTE = @ptrFromInt(root_phys);
    // Only free user entries (VPN[2] < 2)
    for (0..2) |i| {
        const l2_entry = root[i];
        if (l2_entry & PTE_V != 0 and l2_entry & (PTE_R | PTE_W | PTE_X) == 0) {
            freePageTableRecursive(ptePPN(l2_entry), 1);
        }
    }
    pmm.freePage(root_phys);
}

fn freePageTableRecursive(pt_phys: u64, level: u8) void {
    const pt: [*]volatile PTE = @ptrFromInt(pt_phys);
    if (level == 0) {
        // L0 — leaf entries, free mapped pages
        for (0..512) |i| {
            const entry = pt[i];
            if (entry & PTE_V != 0) {
                pmm.freePage(ptePPN(entry));
            }
        }
    } else {
        // Non-leaf — recurse into sub-tables
        for (0..512) |i| {
            const entry = pt[i];
            if (entry & PTE_V != 0 and entry & (PTE_R | PTE_W | PTE_X) == 0) {
                freePageTableRecursive(ptePPN(entry), level - 1);
            }
        }
    }
    pmm.freePage(pt_phys);
}

/// Copy user page tables from parent to child with CoW semantics.
/// Marks all writable user pages as read-only + CoW in both parent and child.
/// Increments ref count on shared physical pages.
pub fn cowCopyUserPages(parent_root: u64, child_root: u64) void {
    const parent: [*]volatile PTE = @ptrFromInt(parent_root);
    const child: [*]volatile PTE = @ptrFromInt(child_root);

    // Walk user space entries. VPN[2]=1 is our user space (0x40000000-0x7FFFFFFF).
    // Also check VPN[2]=0 in case mmap put pages there (skip MMIO superpage).
    for (0..2) |idx2| {
        const l2_entry = parent[idx2];
        if (l2_entry & PTE_V == 0) continue;
        if (l2_entry & (PTE_R | PTE_W | PTE_X) != 0) continue; // Skip superpages (MMIO)

        const parent_l1_phys = ptePPN(l2_entry);
        const parent_l1: [*]volatile PTE = @ptrFromInt(parent_l1_phys);

        // Allocate L1 table for child
        const child_l1_phys = pmm.allocPage() orelse continue;
        zeroPage(child_l1_phys);
        child[idx2] = makePTE(child_l1_phys, PTE_V);
        const child_l1: [*]volatile PTE = @ptrFromInt(child_l1_phys);

        for (0..512) |idx1| {
            const l1_entry = parent_l1[idx1];
            if (l1_entry & PTE_V == 0) continue;
            if (l1_entry & (PTE_R | PTE_W | PTE_X) != 0) continue; // Skip megapages

            const parent_l0_phys = ptePPN(l1_entry);
            const parent_l0: [*]volatile PTE = @ptrFromInt(parent_l0_phys);

            // Allocate L0 table for child
            const child_l0_phys = pmm.allocPage() orelse continue;
            zeroPage(child_l0_phys);
            child_l1[idx1] = makePTE(child_l0_phys, PTE_V);
            const child_l0: [*]volatile PTE = @ptrFromInt(child_l0_phys);

            for (0..512) |idx0| {
                const l0_entry = parent_l0[idx0];
                if (l0_entry & PTE_V == 0) continue;

                const phys = ptePPN(l0_entry);

                if (l0_entry & PTE_W != 0) {
                    // Writable page → mark CoW in both parent and child
                    const cow_entry = (l0_entry & ~PTE_W) | PTE_COW;
                    parent_l0[idx0] = cow_entry;
                    child_l0[idx0] = cow_entry;
                } else {
                    // Read-only/executable — share directly
                    child_l0[idx0] = l0_entry;
                }
                pmm.incRef(phys);
            }
        }
    }
    // Flush parent TLB since we changed parent PTEs
    asm volatile ("sfence.vma zero, zero");
}

/// Handle a CoW page fault. Returns true if resolved, false if not a CoW fault.
pub fn handleCow(root_phys: u64, fault_addr: u64) bool {
    const fault_page = fault_addr & ~@as(u64, 0xFFF);
    const root: [*]volatile PTE = @ptrFromInt(root_phys);

    // Walk to L0 entry
    const l2_entry = root[vpn2(fault_page)];
    if (l2_entry & PTE_V == 0 or l2_entry & (PTE_R | PTE_W | PTE_X) != 0) return false;

    const l1: [*]volatile PTE = @ptrFromInt(ptePPN(l2_entry));
    const l1_entry = l1[vpn1(fault_page)];
    if (l1_entry & PTE_V == 0 or l1_entry & (PTE_R | PTE_W | PTE_X) != 0) return false;

    const l0: [*]volatile PTE = @ptrFromInt(ptePPN(l1_entry));
    const pte = l0[vpn0(fault_page)];
    if (pte & PTE_V == 0 or pte & PTE_COW == 0) return false;

    const old_phys = ptePPN(pte);
    const ref = pmm.getRef(old_phys);

    if (ref <= 1) {
        // Last reference — just make writable and clear CoW
        l0[vpn0(fault_page)] = (pte | PTE_W) & ~PTE_COW;
    } else {
        // Multiple references — copy page
        const new_phys = pmm.allocPage() orelse return false;
        copyPage(new_phys, old_phys);
        pmm.decRef(old_phys);
        l0[vpn0(fault_page)] = makePTE(new_phys, (pte & 0x3FF | PTE_W) & ~PTE_COW);
    }
    invalidatePage(fault_page);
    return true;
}

/// Destroy user pages, respecting CoW ref counts (decRef instead of freePage).
pub fn destroyUserPagesCoW(root_phys: u64) void {
    const root: [*]volatile PTE = @ptrFromInt(root_phys);
    for (0..2) |i| {
        const l2_entry = root[i];
        if (l2_entry & PTE_V != 0 and l2_entry & (PTE_R | PTE_W | PTE_X) == 0) {
            freePageTableCoW(ptePPN(l2_entry), 1);
        }
    }
}

fn freePageTableCoW(pt_phys: u64, level: u8) void {
    const pt: [*]volatile PTE = @ptrFromInt(pt_phys);
    if (level == 0) {
        for (0..512) |i| {
            const entry = pt[i];
            if (entry & PTE_V != 0) {
                const phys = ptePPN(entry);
                if (pmm.getRef(phys) > 1) {
                    pmm.decRef(phys);
                } else {
                    pmm.freePage(phys);
                }
            }
        }
    } else {
        for (0..512) |i| {
            const entry = pt[i];
            if (entry & PTE_V != 0 and entry & (PTE_R | PTE_W | PTE_X) == 0) {
                freePageTableCoW(ptePPN(entry), level - 1);
            }
        }
    }
    pmm.freePage(pt_phys);
}

fn copyPage(dst_phys: u64, src_phys: u64) void {
    const dst: [*]u8 = @ptrFromInt(dst_phys);
    const src: [*]const u8 = @ptrFromInt(src_phys);
    for (0..PAGE_SIZE) |i| dst[i] = src[i];
}

pub fn getKernelRoot() u64 {
    return kernel_root_pt;
}

fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..PAGE_SIZE) |i| ptr[i] = 0;
}
