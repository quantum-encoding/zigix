/// Zigix Boot Information Structure (x86_64 kernel side)
///
/// Identical layout to bootloader_x86/boot_info.zig — this is the contract
/// between the UEFI bootloader and the kernel. The bootloader places this
/// struct in memory and passes its physical address in rdi.
///
/// The kernel detects the boot source by examining the first argument:
///   - Valid pointer to BootInfo magic → UEFI boot
///   - Otherwise → Limine boot (existing path)

pub const ZIGIX_BOOT_MAGIC: u64 = 0x5A49474958424F4F; // "ZIGIXBOO" ASCII

pub const BootInfo = extern struct {
    magic: u64,
    version: u32,
    _pad0: u32,

    dtb_addr: u64,
    acpi_rsdp: u64,

    mmap_addr: u64,
    mmap_count: u32,
    mmap_descriptor_size: u32,
    mmap_descriptor_version: u32,
    _pad1: u32,

    framebuffer_addr: u64,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_pitch: u32,
    framebuffer_bpp: u32,

    kernel_phys_base: u64,
    kernel_phys_end: u64,

    hhdm_offset: u64,
};

/// Simplified memory map entry (matches bootloader format).
pub const BootMemEntry = extern struct {
    base: u64,
    length: u64,
    kind: MemoryKind,
    _pad: u32,
};

pub const MemoryKind = enum(u32) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    kernel_and_modules = 3,
    bootloader_reclaimable = 4,
    framebuffer = 5,
};

/// Check if a value looks like a valid BootInfo pointer.
/// Safe to call with garbage values — validates range before dereferencing.
pub fn isBootInfo(addr: u64) bool {
    // Must be non-zero, 8-byte aligned, and in low 4GB (identity-mapped range)
    if (addr == 0) return false;
    if (addr & 0x7 != 0) return false;
    if (addr >= 0x100000000) return false;
    const ptr: *const u64 = @ptrFromInt(addr);
    return ptr.* == ZIGIX_BOOT_MAGIC;
}
