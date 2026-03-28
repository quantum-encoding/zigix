/// x86_64 Page Table Setup for UEFI Bootloader
///
/// After ExitBootServices, UEFI's page tables are still active but don't
/// include the kernel's higher-half mapping. This module builds new 4-level
/// page tables with:
///
///   1. Identity map: 0-4GB using 1GB pages (PML4[0])
///      Allows the bootloader code to continue executing after CR3 switch.
///
///   2. HHDM: 0xFFFF800000000000+ maps physical 0+ using 1GB pages (PML4[256])
///      Provides kernel access to all physical memory via Higher Half Direct Map.
///
///   3. Kernel: 0xFFFFFFFF80000000+ maps kernel physical base using 2MB pages (PML4[511])
///      Maps the kernel ELF segments at their link addresses.
///
/// Page table memory is pre-allocated during Boot Services via UEFI AllocatePages.

const std = @import("std");
const uefi = std.os.uefi;

const PAGE_SIZE: u64 = 4096;

// Page table entry flags
const PTE_PRESENT: u64 = 1 << 0;
const PTE_WRITE: u64 = 1 << 1;
const PTE_HUGE: u64 = 1 << 7; // 1GB (L3) or 2MB (L2) page

/// Fixed HHDM base address — matches Linux convention.
/// The kernel uses this to convert physical addresses to virtual: virt = phys + HHDM_BASE.
pub const HHDM_BASE: u64 = 0xFFFF_8000_0000_0000;

/// Number of 4KB pages to allocate for page table structures.
/// 1 PML4 + 1 PDPT(identity) + 1 PDPT(hhdm) + 1 PDPT(kernel) + 1 PD(kernel) = 5
/// Allocate 8 for headroom.
const PT_PAGES: usize = 8;

/// Page table memory (allocated during Boot Services).
var pt_mem: [*]align(4096) u8 = undefined;
var pt_allocated = false;

/// PML4 physical address (for loading into CR3).
var pml4_phys: u64 = 0;

/// Allocate page table memory during Boot Services.
/// Must be called before ExitBootServices.
pub fn allocate(boot_services: *uefi.tables.BootServices) bool {
    const mem = boot_services.allocatePages(
        .any,
        .loader_data,
        PT_PAGES,
    ) catch return false;

    pt_mem = @alignCast(@as([*]u8, @ptrCast(mem.ptr)));
    pt_allocated = true;
    return true;
}

/// Build the page tables and load them into CR3.
/// Call after ExitBootServices and placeSegments.
///
/// Parameters:
///   ram_size: total physical RAM in bytes (for HHDM mapping extent)
///   kernel_virt_base: kernel's link address (e.g., 0xFFFFFFFF80000000)
///   kernel_phys_base: where kernel was loaded in physical memory
///   kernel_size: total size of kernel in physical memory (page-aligned)
pub fn setupAndSwitch(
    ram_size: u64,
    kernel_virt_base: u64,
    kernel_phys_base: u64,
    kernel_size: u64,
) void {
    if (!pt_allocated) return;

    // Zero all page table memory
    var i: usize = 0;
    while (i < PT_PAGES * PAGE_SIZE) : (i += 1) {
        pt_mem[i] = 0;
    }

    // Page table layout in our allocated memory:
    //   Page 0: PML4 (level 4)
    //   Page 1: PDPT for identity map (level 3)
    //   Page 2: PDPT for HHDM (level 3)
    //   Page 3: PDPT for kernel higher-half (level 3)
    //   Page 4: PD for kernel (level 2)
    const pml4: [*]u64 = @ptrCast(@alignCast(pt_mem));
    const pdpt_identity: [*]u64 = @ptrCast(@alignCast(pt_mem + PAGE_SIZE));
    const pdpt_hhdm: [*]u64 = @ptrCast(@alignCast(pt_mem + 2 * PAGE_SIZE));
    const pdpt_kernel: [*]u64 = @ptrCast(@alignCast(pt_mem + 3 * PAGE_SIZE));
    const pd_kernel: [*]u64 = @ptrCast(@alignCast(pt_mem + 4 * PAGE_SIZE));

    pml4_phys = @intFromPtr(pt_mem);
    const pdpt_identity_phys = pml4_phys + PAGE_SIZE;
    const pdpt_hhdm_phys = pml4_phys + 2 * PAGE_SIZE;
    const pdpt_kernel_phys = pml4_phys + 3 * PAGE_SIZE;
    const pd_kernel_phys = pml4_phys + 4 * PAGE_SIZE;

    // --- 1. Identity map: PML4[0] → PDPT_identity ---
    // Map first 4GB using 1GB pages
    pml4[0] = pdpt_identity_phys | PTE_PRESENT | PTE_WRITE;
    pdpt_identity[0] = (0 * 0x40000000) | PTE_PRESENT | PTE_WRITE | PTE_HUGE; // 0-1GB
    pdpt_identity[1] = (1 * 0x40000000) | PTE_PRESENT | PTE_WRITE | PTE_HUGE; // 1-2GB
    pdpt_identity[2] = (2 * 0x40000000) | PTE_PRESENT | PTE_WRITE | PTE_HUGE; // 2-3GB
    pdpt_identity[3] = (3 * 0x40000000) | PTE_PRESENT | PTE_WRITE | PTE_HUGE; // 3-4GB

    // --- 2. HHDM: PML4[256] → PDPT_hhdm ---
    // HHDM_BASE = 0xFFFF800000000000
    // PML4 index for HHDM_BASE: (0xFFFF800000000000 >> 39) & 0x1FF = 256
    pml4[256] = pdpt_hhdm_phys | PTE_PRESENT | PTE_WRITE;

    // Map physical address space using 1GB pages.
    // Always map at least 4 GiB to cover the PCI MMIO window (3-4 GiB range)
    // where device BARs (gVNIC, NVMe, etc.) are mapped by firmware.
    const gb: u64 = 0x40000000; // 1 GiB
    const ram_gbs = (ram_size + gb - 1) / gb;
    const map_gbs = if (ram_gbs < 4) @as(u64, 4) else ram_gbs;
    var g: u64 = 0;
    while (g < map_gbs and g < 512) : (g += 1) {
        pdpt_hhdm[g] = (g * gb) | PTE_PRESENT | PTE_WRITE | PTE_HUGE;
    }

    // --- 3. Kernel higher-half: PML4[511] → PDPT_kernel → PD_kernel ---
    // Kernel virt base = 0xFFFFFFFF80000000
    // PML4 index: (0xFFFFFFFF80000000 >> 39) & 0x1FF = 511
    // PDPT index: (0xFFFFFFFF80000000 >> 30) & 0x1FF = 510
    // PD index:   (0xFFFFFFFF80000000 >> 21) & 0x1FF = 0
    pml4[511] = pdpt_kernel_phys | PTE_PRESENT | PTE_WRITE;

    const pdpt_idx = (kernel_virt_base >> 30) & 0x1FF;
    pdpt_kernel[pdpt_idx] = pd_kernel_phys | PTE_PRESENT | PTE_WRITE;

    // Map kernel using 2MB pages
    const mb2: u64 = 0x200000; // 2 MiB
    const kernel_pages_2m = (kernel_size + mb2 - 1) / mb2;
    var p: u64 = 0;
    while (p < kernel_pages_2m and p < 512) : (p += 1) {
        pd_kernel[p] = (kernel_phys_base + p * mb2) | PTE_PRESENT | PTE_WRITE | PTE_HUGE;
    }

    // --- Load new page tables ---
    loadCr3(pml4_phys);
}

/// Load a new PML4 physical address into CR3.
fn loadCr3(addr: u64) void {
    asm volatile ("mov %[addr], %%cr3"
        :
        : [addr] "r" (addr),
        : "memory"
    );
}

/// Jump to the kernel entry point with rdi = boot_info_addr.
/// This function never returns.
///
/// After CR3 has been loaded with our page tables, the kernel's
/// virtual entry point is valid. We use `call` (not `jmp`) to
/// maintain SysV ABI stack alignment: the `call` pushes a return
/// address, leaving RSP = 8 mod 16 as the callee expects.
pub fn jumpToKernel(entry_virt: u64, boot_info_phys: u64) noreturn {
    asm volatile (
        \\mov %[info], %%rdi
        // Align stack for SysV ABI: RSP must be 16-byte aligned
        // before CALL (CALL then pushes 8 bytes → RSP = 8 mod 16)
        \\and $-16, %%rsp
        \\call *%[entry]
        :
        : [entry] "r" (entry_virt),
          [info] "r" (boot_info_phys),
    );
    unreachable;
}
