/// ELF64 loader — parses ELF headers and maps PT_LOAD segments into a process address space.
///
/// Supports static (ET_EXEC) non-PIE executables only for MVP.
/// Each PT_LOAD segment is allocated via PMM, mapped via VMM, and file data
/// is copied through HHDM. BSS (p_memsz > p_filesz) is zero-filled.

const types = @import("../types.zig");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");

// --- ELF constants ---

const ELFMAG0: u8 = 0x7F;
const ELFMAG1: u8 = 'E';
const ELFMAG2: u8 = 'L';
const ELFMAG3: u8 = 'F';
const ELFCLASS64: u8 = 2;
const ELFDATA2LSB: u8 = 1;

const ET_EXEC: u16 = 2;
const EM_X86_64: u16 = 62;
const PT_LOAD: u32 = 1;

const PF_X: u32 = 1;
const PF_W: u32 = 2;
const PF_R: u32 = 4;

const USER_SPACE_END: u64 = 0x0000_8000_0000_0000;

// --- ELF structures (match spec exactly, little-endian) ---

pub const Elf64Header = extern struct {
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

pub const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

// --- Loader result ---

pub const ElfInfo = struct {
    entry: u64,
    highest_addr: u64, // Page-aligned end of highest segment
    segments_loaded: u32,
};

// --- Public API ---

/// Load an ELF64 binary into the given address space.
/// Validates the ELF header, iterates PT_LOAD segments, allocates and maps pages,
/// copies file data, and zeros BSS. Returns entry point and memory layout info.
pub fn loadElf(page_table: u64, data: []const u8) !ElfInfo {
    if (data.len < @sizeOf(Elf64Header)) return error.InvalidElf;

    // Validate header
    const header = getHeader(data) orelse return error.InvalidElf;

    // Iterate program headers and load PT_LOAD segments
    var info = ElfInfo{
        .entry = header.e_entry,
        .highest_addr = 0,
        .segments_loaded = 0,
    };

    var i: u16 = 0;
    while (i < header.e_phnum) : (i += 1) {
        const phdr_off = header.e_phoff + @as(u64, i) * @as(u64, header.e_phentsize);
        if (phdr_off + @sizeOf(Elf64Phdr) > data.len) return error.InvalidElf;

        const phdr: *align(1) const Elf64Phdr = @ptrCast(&data[@as(usize, @truncate(phdr_off))]);
        if (phdr.p_type != PT_LOAD) continue;

        // Validate segment is in userspace
        if (phdr.p_vaddr >= USER_SPACE_END) return error.InvalidElf;
        if (phdr.p_vaddr + phdr.p_memsz > USER_SPACE_END) return error.InvalidElf;
        if (phdr.p_filesz > phdr.p_memsz) return error.InvalidElf;
        if (phdr.p_offset + phdr.p_filesz > data.len) return error.InvalidElf;

        try loadSegment(page_table, data, phdr);
        info.segments_loaded += 1;

        // Track highest mapped address
        const seg_end = pageAlignUp(phdr.p_vaddr + phdr.p_memsz);
        if (seg_end > info.highest_addr) {
            info.highest_addr = seg_end;
        }
    }

    if (info.segments_loaded == 0) return error.InvalidElf;

    return info;
}

// --- Internal ---

pub fn getHeader(data: []const u8) ?*align(1) const Elf64Header {
    if (data.len < @sizeOf(Elf64Header)) return null;

    const header: *align(1) const Elf64Header = @ptrCast(data.ptr);

    // Magic
    if (header.e_ident[0] != ELFMAG0 or
        header.e_ident[1] != ELFMAG1 or
        header.e_ident[2] != ELFMAG2 or
        header.e_ident[3] != ELFMAG3) return null;

    // Class (64-bit)
    if (header.e_ident[4] != ELFCLASS64) return null;

    // Data encoding (little-endian)
    if (header.e_ident[5] != ELFDATA2LSB) return null;

    // Type (static executable)
    if (header.e_type != ET_EXEC) return null;

    // Machine (x86_64)
    if (header.e_machine != EM_X86_64) return null;

    // Program header sanity
    if (header.e_phentsize < @sizeOf(Elf64Phdr)) return null;
    if (header.e_phnum == 0) return null;

    return header;
}

fn loadSegment(page_table: u64, data: []const u8, phdr: *align(1) const Elf64Phdr) !void {
    // Page-aligned boundaries
    const seg_start = phdr.p_vaddr & ~@as(u64, 0xFFF);
    const seg_end = pageAlignUp(phdr.p_vaddr + phdr.p_memsz);

    // Map flags from ELF flags
    const writable = (phdr.p_flags & PF_W) != 0;
    const executable = (phdr.p_flags & PF_X) != 0;

    // Allocate and map pages (zeroed)
    var addr = seg_start;
    while (addr < seg_end) : (addr += types.PAGE_SIZE) {
        const page = pmm.allocPage() orelse return error.OutOfMemory;
        zeroPage(page);
        vmm.mapPage(page_table, addr, page, .{
            .user = true,
            .writable = writable,
            .no_execute = !executable,
        }) catch return error.OutOfMemory;
    }

    // Copy file data into mapped pages
    const file_off_start: usize = @truncate(phdr.p_offset);
    var vaddr = phdr.p_vaddr;
    var remaining: usize = @truncate(phdr.p_filesz);
    var src_off = file_off_start;

    while (remaining > 0) {
        const page_off: usize = @truncate(vaddr & 0xFFF);
        const chunk = @min(remaining, types.PAGE_SIZE - page_off);

        // translate() returns page_base + page_offset, so the HHDM pointer
        // already points to the exact target byte — no additional page_off needed.
        if (vmm.translate(page_table, vaddr)) |phys| {
            const dst: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
            for (0..chunk) |j| {
                dst[j] = data[src_off + j];
            }
        } else {
            return error.OutOfMemory;
        }

        vaddr += chunk;
        src_off += chunk;
        remaining -= chunk;
    }

    // BSS (p_memsz - p_filesz) is already zeroed by zeroPage

}

fn pageAlignUp(addr: u64) u64 {
    return (addr + types.PAGE_SIZE - 1) & ~(types.PAGE_SIZE - 1);
}

fn zeroPage(phys: types.PhysAddr) void {
    const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    for (0..types.PAGE_SIZE) |i| {
        ptr[i] = 0;
    }
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
