/// ELF64 Loader for x86_64 UEFI Bootloader
///
/// Two-phase loading for higher-half kernels:
///   Phase 1 (during Boot Services): Parse and validate ELF headers from a
///     memory buffer. Compute virtual-to-physical mapping. No allocation.
///   Phase 2 (after ExitBootServices): Copy PT_LOAD segments from the buffer
///     to their computed physical addresses. The kernel's virtual addresses
///     (e.g., 0xFFFFFFFF80000000) are mapped to physical addresses by the
///     bootloader's page table setup.
///
/// Physical base address is chosen by the bootloader (default: 2MB).

const PAGE_SIZE: u64 = 4096;

// ELF constants
const ELFMAG0: u8 = 0x7F;
const ELFMAG1: u8 = 'E';
const ELFMAG2: u8 = 'L';
const ELFMAG3: u8 = 'F';
const ELFCLASS64: u8 = 2;
const ELFDATA2LSB: u8 = 1;
const ET_EXEC: u16 = 2;
const EM_X86_64: u16 = 62;
const PT_LOAD: u32 = 1;

/// Where we load the kernel in physical memory.
/// 2MB is safely above the legacy BIOS area and identity-mapped in our page tables.
pub const KERNEL_PHYS_BASE: u64 = 0x200000;

// ELF64 structures
const Elf64Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

const MAX_SEGMENTS = 8;

pub const SegmentInfo = struct {
    file_offset: u64,
    vaddr: u64, // Virtual address from ELF (higher-half)
    filesz: u64,
    memsz: u64,
};

pub const ParseResult = struct {
    entry_virt: u64, // Virtual entry point (higher-half)
    virt_base: u64, // Page-aligned start of virtual range
    virt_end: u64, // Page-aligned end of virtual range
    phys_base: u64, // Chosen physical base address
    phys_end: u64, // Physical end = phys_base + (virt_end - virt_base)
    segments: [MAX_SEGMENTS]SegmentInfo,
    segment_count: u32,
};

pub const LoadError = error{
    InvalidElf,
    WrongMachine,
    WrongType,
    NoSegments,
    TooManySegments,
    SegmentOutOfBounds,
};

/// Phase 1: Parse ELF headers and extract segment information.
/// No memory allocation — just reads from the loaded file buffer.
pub fn parseKernel(data: []const u8) LoadError!ParseResult {
    const header = try validateHeader(data);

    var result: ParseResult = .{
        .entry_virt = header.e_entry,
        .virt_base = ~@as(u64, 0),
        .virt_end = 0,
        .phys_base = KERNEL_PHYS_BASE,
        .phys_end = 0,
        .segments = undefined,
        .segment_count = 0,
    };

    var i: u16 = 0;
    while (i < header.e_phnum) : (i += 1) {
        const phdr = try getPhdr(data, header, i);

        if (phdr.p_type != PT_LOAD) continue;
        if (phdr.p_memsz == 0) continue;

        if (result.segment_count >= MAX_SEGMENTS) return error.TooManySegments;

        if (phdr.p_filesz > 0 and phdr.p_offset + phdr.p_filesz > data.len) {
            return error.SegmentOutOfBounds;
        }

        const seg_start = pageAlignDown(phdr.p_vaddr);
        const seg_end = pageAlignUp(phdr.p_vaddr + phdr.p_memsz);

        if (seg_start < result.virt_base) result.virt_base = seg_start;
        if (seg_end > result.virt_end) result.virt_end = seg_end;

        result.segments[result.segment_count] = .{
            .file_offset = phdr.p_offset,
            .vaddr = phdr.p_vaddr,
            .filesz = phdr.p_filesz,
            .memsz = phdr.p_memsz,
        };
        result.segment_count += 1;
    }

    if (result.segment_count == 0) return error.NoSegments;

    // Compute physical range from virtual range
    const kernel_size = result.virt_end - result.virt_base;
    result.phys_end = pageAlignUp(KERNEL_PHYS_BASE + kernel_size);

    return result;
}

/// Phase 2: Copy PT_LOAD segments to their physical addresses.
/// Call this AFTER ExitBootServices when all RAM is available.
///
/// Each segment's virtual address is translated to a physical address:
///   phys = phys_base + (vaddr - virt_base)
pub fn placeSegments(data: [*]const u8, parse: *const ParseResult) void {
    // Zero the entire kernel physical region first (covers BSS)
    const region_size = parse.phys_end - parse.phys_base;
    const dest_base: [*]u8 = @ptrFromInt(parse.phys_base);
    var j: u64 = 0;
    while (j < region_size) : (j += 1) {
        dest_base[j] = 0;
    }

    // Copy file data for each segment
    var i: u32 = 0;
    while (i < parse.segment_count) : (i += 1) {
        const seg = parse.segments[i];
        if (seg.filesz == 0) continue;

        // Map virtual address to physical address
        const phys_addr = parse.phys_base + (seg.vaddr - parse.virt_base);
        const src = data + seg.file_offset;
        const dest: [*]u8 = @ptrFromInt(phys_addr);

        var k: u64 = 0;
        while (k < seg.filesz) : (k += 1) {
            dest[k] = src[k];
        }
    }
}

// --- Internal helpers ---

fn validateHeader(data: []const u8) LoadError!*const Elf64Header {
    if (data.len < @sizeOf(Elf64Header)) return error.InvalidElf;

    const header: *const Elf64Header = @ptrCast(@alignCast(data.ptr));

    if (header.e_ident[0] != ELFMAG0 or header.e_ident[1] != ELFMAG1 or
        header.e_ident[2] != ELFMAG2 or header.e_ident[3] != ELFMAG3)
    {
        return error.InvalidElf;
    }

    if (header.e_ident[4] != ELFCLASS64) return error.InvalidElf;
    if (header.e_ident[5] != ELFDATA2LSB) return error.InvalidElf;

    if (header.e_machine != EM_X86_64) return error.WrongMachine;
    if (header.e_type != ET_EXEC) return error.WrongType;

    if (header.e_phnum == 0) return error.NoSegments;

    return header;
}

fn getPhdr(data: []const u8, header: *const Elf64Header, index: u16) LoadError!*const Elf64Phdr {
    const offset = header.e_phoff + @as(u64, index) * @as(u64, header.e_phentsize);
    if (offset + @sizeOf(Elf64Phdr) > data.len) return error.InvalidElf;
    return @ptrCast(@alignCast(data.ptr + offset));
}

fn pageAlignDown(addr: u64) u64 {
    return addr & ~@as(u64, PAGE_SIZE - 1);
}

fn pageAlignUp(addr: u64) u64 {
    return (addr + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);
}
