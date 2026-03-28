/// Zigix Boot Information Structure
///
/// Passed from UEFI bootloader to kernel via rdi register (SysV ABI).
/// The kernel detects the boot source by examining the magic field:
///   - BootInfo magic (0x5A49474958424F4F) -> UEFI boot
///   - Otherwise -> Limine boot (existing path)

pub const ZIGIX_BOOT_MAGIC: u64 = 0x5A49474958424F4F; // "ZIGIXBOO" ASCII

pub const BootInfo = extern struct {
    magic: u64, // ZIGIX_BOOT_MAGIC
    version: u32, // 1
    _pad0: u32 = 0,

    // Device tree and ACPI
    dtb_addr: u64, // FDT physical address (0 if not found)
    acpi_rsdp: u64, // ACPI 2.0 RSDP physical address (0 if not found)

    // Memory map (simplified entries, converted from UEFI descriptors)
    mmap_addr: u64, // Physical address of BootMemEntry array
    mmap_count: u32, // Number of entries
    mmap_descriptor_size: u32, // Size of each entry (sizeof(BootMemEntry))
    mmap_descriptor_version: u32, // 1 (our simplified format)
    _pad1: u32 = 0,

    // Framebuffer (from GOP, 0 if not found)
    framebuffer_addr: u64,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_pitch: u32,
    framebuffer_bpp: u32,

    // Kernel load info
    kernel_phys_base: u64, // Where the lowest PT_LOAD was placed
    kernel_phys_end: u64, // Page-aligned end of highest segment

    // HHDM offset (x86_64: 0xFFFF800000000000; ARM64: 0)
    hhdm_offset: u64,
};

/// Simplified memory map entry.
/// The bootloader converts UEFI EFI_MEMORY_DESCRIPTOR entries into this
/// portable format before populating BootInfo.
pub const BootMemEntry = extern struct {
    base: u64,
    length: u64,
    kind: MemoryKind,
    _pad: u32 = 0,
};

pub const MemoryKind = enum(u32) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    kernel_and_modules = 3,
    bootloader_reclaimable = 4,
    framebuffer = 5,
};
