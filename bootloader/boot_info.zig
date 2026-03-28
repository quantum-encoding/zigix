/// Zigix Boot Information Structure
///
/// Passed from UEFI bootloader to kernel via X0 register.
/// The kernel detects the boot source by examining X0:
///   - BootInfo magic (0x5A49474958424F4F) -> UEFI boot
///   - FDT magic (0xD00DFEED big-endian at [0..4]) -> U-Boot/DTB
///   - Zero -> QEMU virt defaults

pub const ZIGIX_BOOT_MAGIC: u64 = 0x5A49474958424F4F; // "ZIGIXBOO" ASCII

pub const BootInfo = extern struct {
    magic: u64, // ZIGIX_BOOT_MAGIC
    version: u32, // 1
    _pad0: u32 = 0,

    // Device tree and ACPI
    dtb_addr: u64, // FDT physical address (0 if not found)
    acpi_rsdp: u64, // ACPI 2.0 RSDP physical address (0 if not found)

    // UEFI memory map (copied before ExitBootServices)
    mmap_addr: u64, // Physical address of memory map array
    mmap_count: u32, // Number of entries
    mmap_descriptor_size: u32, // Size of each descriptor (may differ from sizeof)
    mmap_descriptor_version: u32, // UEFI descriptor version
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
};
