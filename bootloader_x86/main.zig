/// Zigix UEFI Bootloader for x86_64
///
/// Loads the Zigix kernel ELF from the ESP filesystem, sets up BootInfo,
/// calls ExitBootServices, copies kernel segments to physical memory,
/// builds 4-level page tables (identity + HHDM + higher-half kernel),
/// and transfers control to the kernel entry point.
///
/// Build: `cd zigix/bootloader_x86 && zig build`
/// Output: zig-out/bin/BOOTX64.EFI (PE32+ for x86_64)
/// Place at: /EFI/BOOT/BOOTX64.EFI on a FAT32 ESP

const std = @import("std");
const uefi = std.os.uefi;
const BootServices = uefi.tables.BootServices;
const ConfigurationTable = uefi.tables.ConfigurationTable;
const console_mod = @import("console.zig");
const Console = console_mod.Console;
const elf_loader = @import("elf_loader.zig");
const boot_info_mod = @import("boot_info.zig");
const BootInfo = boot_info_mod.BootInfo;
const BootMemEntry = boot_info_mod.BootMemEntry;
const paging = @import("paging.zig");

const KERNEL_PATH = std.unicode.utf8ToUtf16LeStringLiteral("\\zigix\\zigix");

/// UEFI application entry point.
pub fn main() void {
    const system_table = uefi.system_table;
    const boot_services = system_table.boot_services orelse return;
    const con = Console.init(system_table) orelse return;

    // Banner
    con.clear();
    con.puts("========================================\n");
    con.puts("  Zigix OS - UEFI Bootloader\n");
    con.puts("  x86_64 PE32+ application\n");
    con.puts("  Written in Zig by QUANTUM ENCODING\n");
    con.puts("========================================\n\n");

    // Disable UEFI watchdog timer
    boot_services.setWatchdogTimer(0, 0, null) catch {};

    // Step 1: Load kernel ELF from ESP
    con.puts("[boot] Loading kernel from ");
    con.puts("\\zigix\\zigix");
    con.puts("...\n");

    const kernel_data = loadKernelFile(boot_services, con) orelse {
        con.puts("[boot] FATAL: Failed to load kernel file\n");
        halt();
    };

    con.puts("[boot] Kernel loaded: ");
    con.putDec(kernel_data.len);
    con.puts(" bytes\n");

    // Step 2: Parse ELF headers (Phase 1 — validation only, no allocation)
    const parse_result = elf_loader.parseKernel(kernel_data) catch |err| {
        con.puts("[boot] FATAL: ELF parse failed: ");
        con.puts(switch (err) {
            error.InvalidElf => "invalid ELF header",
            error.WrongMachine => "wrong machine (not x86_64)",
            error.WrongType => "wrong type (not ET_EXEC)",
            error.NoSegments => "no PT_LOAD segments",
            error.TooManySegments => "too many PT_LOAD segments",
            error.SegmentOutOfBounds => "segment data out of bounds",
        });
        con.puts("\n");
        halt();
    };

    con.puts("[boot] ELF: ");
    con.putDec(@as(u64, parse_result.segment_count));
    con.puts(" segments, entry=");
    con.putHex(parse_result.entry_virt);
    con.puts("\n");
    con.puts("[boot] Kernel virt ");
    con.putHex(parse_result.virt_base);
    con.puts(" - ");
    con.putHex(parse_result.virt_end);
    con.puts("\n");
    con.puts("[boot] Kernel phys ");
    con.putHex(parse_result.phys_base);
    con.puts(" - ");
    con.putHex(parse_result.phys_end);
    con.puts("\n");

    // Step 3: Pre-allocate page table memory (must happen during Boot Services)
    if (!paging.allocate(boot_services)) {
        con.puts("[boot] FATAL: Cannot allocate page table memory\n");
        halt();
    }

    // Step 4: Find ACPI RSDP from UEFI configuration tables
    const acpi_rsdp = findConfigTable(system_table, ConfigurationTable.acpi_20_table_guid);

    if (acpi_rsdp != 0) {
        con.puts("[boot] ACPI RSDP at ");
        con.putHex(acpi_rsdp);
        con.puts("\n");
    }

    // Step 5: Allocate pages for BootInfo + memory map entries
    const boot_info_pages = 5; // 20KB: BootInfo + BootMemEntry array
    const boot_info_mem = boot_services.allocatePages(
        .any,
        .loader_data,
        boot_info_pages,
    ) catch {
        con.puts("[boot] FATAL: Cannot allocate BootInfo pages\n");
        halt();
    };
    const boot_info_addr = @intFromPtr(boot_info_mem.ptr);
    const boot_info: *BootInfo = @ptrCast(@alignCast(boot_info_mem.ptr));

    // Memory map entry storage starts after BootInfo struct
    const mmap_storage_addr = boot_info_addr + @sizeOf(BootInfo);
    const mmap_storage_size = (boot_info_pages * 4096) - @sizeOf(BootInfo);
    const max_entries = mmap_storage_size / @sizeOf(BootMemEntry);

    // Step 6: GetMemoryMap + ExitBootServices (retry loop)
    con.puts("[boot] Calling ExitBootServices...\n");

    var attempts: u32 = 0;
    var mmap_count: u32 = 0;

    // Temporary buffer for raw UEFI memory descriptors (on stack — ~16KB)
    var raw_mmap_buf: [16384]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;

    while (attempts < 5) : (attempts += 1) {
        var mmap_buf: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = &raw_mmap_buf;

        const mmap_slice = boot_services.getMemoryMap(mmap_buf) catch |err| {
            if (err == error.BufferTooSmall) continue;
            con.puts("[boot] FATAL: GetMemoryMap failed\n");
            halt();
        };

        // Convert UEFI descriptors to our simplified BootMemEntry format
        // before ExitBootServices (we still have access to the data)
        mmap_count = convertMemoryMap(
            mmap_buf[0 .. mmap_slice.info.len * mmap_slice.info.descriptor_size],
            mmap_slice.info.descriptor_size,
            mmap_storage_addr,
            max_entries,
            parse_result.phys_base,
            parse_result.phys_end,
        );

        // Immediately call ExitBootServices — no allocations between!
        boot_services.exitBootServices(uefi.handle, mmap_slice.info.key) catch {
            continue; // MapKey stale, retry
        };

        // Success! UEFI services are gone — all RAM is ours now.
        // From here, use raw COM1 I/O for diagnostics (no UEFI console).

        // Initialize COM1 for post-ExitBootServices output
        serialInit();
        serialStr("\r\n[post-ebs] ExitBootServices OK\r\n");

        // Phase 2: Copy kernel ELF segments to physical memory.
        serialStr("[post-ebs] Copying ELF segments...\r\n");
        elf_loader.placeSegments(kernel_data.ptr, &parse_result);
        serialStr("[post-ebs] Segments copied\r\n");

        // Set up page tables: identity + HHDM + kernel higher-half
        const ram_size = computeRamSize(mmap_storage_addr, mmap_count);
        const kernel_size = parse_result.phys_end - parse_result.phys_base;
        serialStr("[post-ebs] RAM size: ");
        serialHex(ram_size);
        serialStr(" kernel size: ");
        serialHex(kernel_size);
        serialStr("\r\n");

        serialStr("[post-ebs] Building page tables...\r\n");
        paging.setupAndSwitch(
            ram_size,
            parse_result.virt_base,
            parse_result.phys_base,
            kernel_size,
        );
        serialStr("[post-ebs] CR3 loaded, paging active\r\n");

        // Populate BootInfo struct
        boot_info.* = .{
            .magic = boot_info_mod.ZIGIX_BOOT_MAGIC,
            .version = 1,
            .dtb_addr = 0, // No DTB on x86_64
            .acpi_rsdp = acpi_rsdp,
            .mmap_addr = mmap_storage_addr,
            .mmap_count = mmap_count,
            .mmap_descriptor_size = @sizeOf(BootMemEntry),
            .mmap_descriptor_version = 1,
            .framebuffer_addr = 0, // TODO: GOP framebuffer
            .framebuffer_width = 0,
            .framebuffer_height = 0,
            .framebuffer_pitch = 0,
            .framebuffer_bpp = 0,
            .kernel_phys_base = parse_result.phys_base,
            .kernel_phys_end = parse_result.phys_end,
            .hhdm_offset = paging.HHDM_BASE,
        };

        serialStr("[post-ebs] BootInfo populated\r\n");
        serialStr("[post-ebs] Jumping to kernel entry: ");
        serialHex(parse_result.entry_virt);
        serialStr(" info: ");
        serialHex(boot_info_addr);
        serialStr("\r\n");

        // Jump to kernel (virtual entry point, page tables already loaded)
        paging.jumpToKernel(parse_result.entry_virt, boot_info_addr);
    }

    con.puts("[boot] FATAL: ExitBootServices failed after 5 attempts\n");
    halt();
}

/// Convert UEFI memory descriptors to simplified BootMemEntry format.
/// Returns the number of entries written.
fn convertMemoryMap(
    raw_data: []const u8,
    descriptor_size: usize,
    out_addr: u64,
    max_entries: u64,
    kernel_phys_base: u64,
    kernel_phys_end: u64,
) u32 {
    const entries: [*]BootMemEntry = @ptrFromInt(out_addr);
    var count: u32 = 0;
    var offset: usize = 0;

    while (offset + @sizeOf(uefi.tables.MemoryDescriptor) <= raw_data.len and count < max_entries) {
        const desc: *const uefi.tables.MemoryDescriptor = @ptrCast(@alignCast(raw_data.ptr + offset));
        offset += descriptor_size;

        const base = desc.physical_start;
        const length = desc.number_of_pages * 4096;

        // Convert UEFI memory type to our simplified kind.
        // loader_code/loader_data contain the bootloader's page tables
        // (PDPTs with 1GB huge pages). The kernel reuses them via
        // readCR3() so they must stay reserved.
        const kind: boot_info_mod.MemoryKind = switch (desc.type) {
            .conventional_memory,
            .boot_services_code,
            .boot_services_data,
            => .usable,
            .loader_code, .loader_data => .reserved,
            .acpi_reclaim_memory => .acpi_reclaimable,
            else => .reserved,
        };

        entries[count] = .{
            .base = base,
            .length = length,
            .kind = kind,
        };
        count += 1;
    }

    // Mark the kernel region explicitly
    if (count < max_entries) {
        entries[count] = .{
            .base = kernel_phys_base,
            .length = kernel_phys_end - kernel_phys_base,
            .kind = .kernel_and_modules,
        };
        count += 1;
    }

    return count;
}

/// Compute total RAM size from memory map entries (for HHDM extent).
fn computeRamSize(mmap_addr: u64, mmap_count: u32) u64 {
    const entries: [*]const BootMemEntry = @ptrFromInt(mmap_addr);
    var highest: u64 = 0;
    var i: u32 = 0;
    while (i < mmap_count) : (i += 1) {
        const top = entries[i].base + entries[i].length;
        if (top > highest) highest = top;
    }
    // Round up to 1GB boundary for clean HHDM mapping
    const gb: u64 = 0x40000000;
    return ((highest + gb - 1) / gb) * gb;
}

/// Load the kernel ELF binary from the ESP filesystem.
fn loadKernelFile(bs: *BootServices, con: Console) ?[]const u8 {
    const loaded_image = bs.openProtocol(
        uefi.protocol.LoadedImage,
        uefi.handle,
        .{ .by_handle_protocol = .{} },
    ) catch {
        con.puts("  ERROR: Cannot open LoadedImage protocol\n");
        return null;
    };

    const li = loaded_image orelse {
        con.puts("  ERROR: LoadedImage protocol is null\n");
        return null;
    };

    const device_handle = li.device_handle orelse {
        con.puts("  ERROR: No device handle on LoadedImage\n");
        return null;
    };

    const sfs = bs.openProtocol(
        uefi.protocol.SimpleFileSystem,
        device_handle,
        .{ .by_handle_protocol = .{} },
    ) catch {
        con.puts("  ERROR: Cannot open SimpleFileSystem protocol\n");
        return null;
    };

    const fs = sfs orelse {
        con.puts("  ERROR: SimpleFileSystem protocol is null\n");
        return null;
    };

    const root = fs.openVolume() catch {
        con.puts("  ERROR: Cannot open root volume\n");
        return null;
    };

    const kernel_file = root.open(KERNEL_PATH, .read, .{}) catch {
        con.puts("  ERROR: Cannot open kernel file\n");
        return null;
    };

    // Get file size
    kernel_file.setPosition(0xFFFFFFFFFFFFFFFF) catch {
        con.puts("  ERROR: Cannot seek to end\n");
        return null;
    };

    const file_size = kernel_file.getPosition() catch {
        con.puts("  ERROR: Cannot get file size\n");
        return null;
    };

    if (file_size == 0) {
        con.puts("  ERROR: Kernel file is empty\n");
        return null;
    }

    kernel_file.setPosition(0) catch {
        con.puts("  ERROR: Cannot seek to start\n");
        return null;
    };

    // Allocate buffer for file data
    const pages_needed = (file_size + 4095) / 4096;
    const file_mem = bs.allocatePages(
        .any,
        .loader_data,
        pages_needed,
    ) catch {
        con.puts("  ERROR: Cannot allocate memory for kernel\n");
        return null;
    };

    const buf: [*]u8 = @ptrCast(file_mem.ptr);
    var total_read: u64 = 0;
    while (total_read < file_size) {
        const remaining = file_size - total_read;
        const chunk_size: usize = @min(remaining, 65536);
        const bytes_read = kernel_file.read(buf[total_read..][0..chunk_size]) catch {
            con.puts("  ERROR: Read failed\n");
            return null;
        };
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }

    kernel_file.close() catch {};

    return buf[0..@as(usize, @truncate(total_read))];
}

/// Search UEFI configuration tables for a specific GUID.
fn findConfigTable(st: *uefi.tables.SystemTable, target_guid: uefi.Guid) u64 {
    const tables = st.configuration_table[0..st.number_of_table_entries];
    for (tables) |entry| {
        if (entry.vendor_guid.eql(target_guid)) {
            return @intFromPtr(entry.vendor_table);
        }
    }
    return 0;
}

/// Halt the CPU in an infinite loop.
fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

// --- Raw COM1 serial I/O (works after ExitBootServices) ---

const COM1: u16 = 0x3F8;

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[val]"
        : [val] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

fn serialInit() void {
    outb(COM1 + 1, 0x00); // Disable interrupts
    outb(COM1 + 3, 0x80); // DLAB on
    outb(COM1 + 0, 0x01); // 115200 baud (divisor 1)
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03); // 8N1, DLAB off
    outb(COM1 + 2, 0xC7); // Enable FIFO
    outb(COM1 + 4, 0x0B); // DTR + RTS + OUT2
}

fn serialByte(b: u8) void {
    // Wait for transmit buffer empty
    while (inb(COM1 + 5) & 0x20 == 0) {
        asm volatile ("pause");
    }
    outb(COM1, b);
}

fn serialStr(s: []const u8) void {
    for (s) |c| serialByte(c);
}

fn serialHex(val: u64) void {
    const hex = "0123456789abcdef";
    serialByte('0');
    serialByte('x');
    var started = false;
    var shift: u6 = 60;
    while (true) {
        const nibble: u4 = @truncate(val >> shift);
        if (nibble != 0) started = true;
        if (started or shift == 0) serialByte(hex[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
}
