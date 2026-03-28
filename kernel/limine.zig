/// Limine Boot Protocol definitions.
/// Reference: https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md

// --- Base Revision ---

/// The kernel places this marker in a loadable segment.
/// If the bootloader supports our requested revision, it sets `revision` to 0.
pub const BaseRevision = extern struct {
    magic: [2]u64 = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },
    revision: u64 = 3,

    pub fn isSupported(self: *const @This()) bool {
        // Volatile read — the bootloader modifies this value before we run
        const ptr: *const volatile u64 = @ptrCast(&self.revision);
        return ptr.* == 0;
    }
};

// Common magic prefix for all Limine requests
const COMMON = [2]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// --- Framebuffer ---

pub const FramebufferRequest = extern struct {
    id: [4]u64 = COMMON ++ .{ 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,
    response: ?*FramebufferResponse = null,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]*Framebuffer,
};

pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?[*]u8,
};

// --- Memory Map ---

pub const MemmapRequest = extern struct {
    id: [4]u64 = COMMON ++ .{ 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,
    response: ?*MemmapResponse = null,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]*MemmapEntry,
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    kind: MemmapKind,
};

pub const MemmapKind = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
};

// --- Higher Half Direct Map ---

pub const HhdmRequest = extern struct {
    id: [4]u64 = COMMON ++ .{ 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

// --- SMP ---

pub const SmpRequest = extern struct {
    id: [4]u64 = COMMON ++ .{ 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    revision: u64 = 0,
    response: ?*volatile SmpResponse = null,
    flags: u64 = 0, // bit 0: request x2APIC
};

pub const SmpResponse = extern struct {
    revision: u64,
    flags: u64, // bit 0: x2APIC enabled
    bsp_lapic_id: u32,
    _pad: u32 = 0,
    cpu_count: u64,
    cpus: [*]*volatile SmpInfo,
};

pub const SmpInfo = extern struct {
    processor_id: u32,
    lapic_id: u32,
    reserved: u64,
    goto_address: ?*const fn (*volatile SmpInfo) callconv(.c) noreturn = null,
    extra_argument: u64 = 0,
};
