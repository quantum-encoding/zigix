/// Zigix Boot Information Structure (kernel side)
///
/// Identical layout to bootloader/boot_info.zig — this is the contract
/// between the UEFI bootloader and the kernel. The bootloader places this
/// struct in memory and passes its address in X0.
///
/// The kernel detects the boot source by examining X0:
///   - BootInfo magic (0x5A49474958424F4F) -> UEFI boot
///   - FDT magic (0xD00DFEED big-endian at [0..4]) -> U-Boot/DTB
///   - Zero -> QEMU virt defaults

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
};

/// Check if a memory address contains a valid BootInfo structure.
pub fn isBootInfo(addr: u64) bool {
    if (addr == 0) return false;
    if (addr & 0x7 != 0) return false; // Must be 8-byte aligned
    const ptr: *const u64 = @ptrFromInt(addr);
    return ptr.* == ZIGIX_BOOT_MAGIC;
}

/// Check if a memory address contains an FDT header (magic = 0xD00DFEED big-endian).
pub fn isFdt(addr: u64) bool {
    if (addr == 0) return false;
    const ptr: *const [4]u8 = @ptrFromInt(addr);
    return ptr[0] == 0xD0 and ptr[1] == 0x0D and ptr[2] == 0xFE and ptr[3] == 0xED;
}
