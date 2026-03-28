/// Zigix UEFI Bootloader for ARM64
///
/// Loads the Zigix kernel ELF from the ESP filesystem, sets up BootInfo,
/// calls ExitBootServices, drops from EL2 to EL1 (if needed), and
/// transfers control to the kernel entry point.
///
/// Build: `cd zigix/bootloader && zig build`
/// Output: zig-out/bin/BOOTAA64.EFI (PE32+ for AARCH64)
/// Place at: /EFI/BOOT/BOOTAA64.EFI on a FAT32 ESP

const std = @import("std");
const uefi = std.os.uefi;
const BootServices = uefi.tables.BootServices;
const ConfigurationTable = uefi.tables.ConfigurationTable;
const console_mod = @import("console.zig");
const Console = console_mod.Console;
const elf_loader = @import("elf_loader.zig");
const boot_info_mod = @import("boot_info.zig");
const BootInfo = boot_info_mod.BootInfo;
const el_drop = @import("el_drop.zig");

const KERNEL_PATH = std.unicode.utf8ToUtf16LeStringLiteral("\\zigix\\zigix-aarch64");

// EFI_DTB_TABLE_GUID: {b1b621d5-f19c-41a5-830b-d9152c69aae0}
const dtb_table_guid: uefi.Guid = .{
    .time_low = 0xb1b621d5,
    .time_mid = 0xf19c,
    .time_high_and_version = 0x41a5,
    .clock_seq_high_and_reserved = 0x83,
    .clock_seq_low = 0x0b,
    .node = [_]u8{ 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0 },
};

/// UEFI application entry point.
pub fn main() void {
    const system_table = uefi.system_table;
    const boot_services = system_table.boot_services orelse return;
    const con = Console.init(system_table) orelse return;

    // Banner
    con.clear();
    con.puts("========================================\n");
    con.puts("  Zigix UEFI Bootloader v0.1\n");
    con.puts("  aarch64 PE32+ application\n");
    con.puts("========================================\n\n");

    // Disable UEFI 5-minute watchdog timer (it would reset us during slow loads)
    boot_services.setWatchdogTimer(0, 0, null) catch {};

    // Report exception level
    const el = el_drop.getCurrentEl();
    con.puts("[boot] Running at EL");
    con.putDec(@as(u64, el));
    con.puts("\n");

    // Step 1: Load kernel ELF from ESP
    con.puts("[boot] Loading kernel from ");
    con.puts("\\zigix\\zigix-aarch64");
    con.puts("...\n");

    const kernel_data = loadKernelFile(boot_services, con) orelse {
        con.puts("[boot] FATAL: Failed to load kernel file\n");
        halt();
    };

    con.puts("[boot] Kernel loaded: ");
    con.putDec(kernel_data.len);
    con.puts(" bytes\n");

    // Step 2: Parse ELF headers (Phase 1 — no allocation, just validation)
    const parse_result = elf_loader.parseKernel(kernel_data) catch |err| {
        con.puts("[boot] FATAL: ELF parse failed: ");
        con.puts(switch (err) {
            error.InvalidElf => "invalid ELF header",
            error.WrongMachine => "wrong machine (not AArch64)",
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
    con.putHex(parse_result.entry);
    con.puts("\n");
    con.puts("[boot] Kernel at ");
    con.putHex(parse_result.phys_base);
    con.puts(" - ");
    con.putHex(parse_result.phys_end);
    con.puts("\n");

    // Step 3: Find DTB and ACPI RSDP from UEFI configuration tables
    const dtb_addr = findConfigTable(system_table, dtb_table_guid);
    const acpi_rsdp = findConfigTable(system_table, ConfigurationTable.acpi_20_table_guid);

    if (dtb_addr != 0) {
        con.puts("[boot] DTB at ");
        con.putHex(dtb_addr);
        con.puts("\n");
    } else {
        con.puts("[boot] No DTB found in UEFI config tables\n");
    }

    if (acpi_rsdp != 0) {
        con.puts("[boot] ACPI RSDP at ");
        con.putHex(acpi_rsdp);
        con.puts("\n");
    }

    // Step 4: Allocate pages for BootInfo + memory map copy
    // We need space for BootInfo struct + memory map data (up to 16KB)
    const boot_info_pages = 5; // 20KB: BootInfo + memory map
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

    // Memory map storage starts right after BootInfo
    const mmap_storage_addr = boot_info_addr + @sizeOf(BootInfo);
    const mmap_storage_size = (boot_info_pages * 4096) - @sizeOf(BootInfo);

    // Step 5: GetMemoryMap + ExitBootServices (retry loop)
    con.puts("[boot] Calling ExitBootServices...\n");

    // Retry loop: GetMemoryMap/ExitBootServices must be back-to-back.
    // Any allocation between them invalidates the MapKey.
    var attempts: u32 = 0;
    var mmap_count: u32 = 0;
    var mmap_desc_size: u32 = 0;
    var mmap_desc_version: u32 = 0;

    while (attempts < 5) : (attempts += 1) {
        // Use the pre-allocated storage for the memory map
        var mmap_buf: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = undefined;
        mmap_buf.ptr = @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(mmap_storage_addr))));
        mmap_buf.len = mmap_storage_size;

        const mmap_slice = boot_services.getMemoryMap(mmap_buf) catch |err| {
            if (err == error.BufferTooSmall) {
                // Buffer too small — unlikely with 16KB+ but retry anyway
                continue;
            }
            con.puts("[boot] FATAL: GetMemoryMap failed\n");
            halt();
        };

        mmap_count = @truncate(mmap_slice.info.len);
        mmap_desc_size = @truncate(mmap_slice.info.descriptor_size);
        mmap_desc_version = mmap_slice.info.descriptor_version;

        // Immediately call ExitBootServices — no allocations between!
        boot_services.exitBootServices(uefi.handle, mmap_slice.info.key) catch {
            // MapKey stale — retry
            continue;
        };

        // Success! UEFI services are gone — all RAM is ours now.

        // Phase 2: Copy PT_LOAD segments to their final physical addresses.
        // This must happen after ExitBootServices because UEFI firmware
        // may have reserved memory at the kernel's load address (0x40080000).
        elf_loader.placeSegments(kernel_data.ptr, &parse_result);

        // Populate BootInfo struct for the kernel.
        boot_info.* = .{
            .magic = boot_info_mod.ZIGIX_BOOT_MAGIC,
            .version = 1,
            .dtb_addr = dtb_addr,
            .acpi_rsdp = acpi_rsdp,
            .mmap_addr = mmap_storage_addr,
            .mmap_count = mmap_count,
            .mmap_descriptor_size = mmap_desc_size,
            .mmap_descriptor_version = mmap_desc_version,
            .framebuffer_addr = 0, // TODO: GOP framebuffer
            .framebuffer_width = 0,
            .framebuffer_height = 0,
            .framebuffer_pitch = 0,
            .framebuffer_bpp = 0,
            .kernel_phys_base = parse_result.phys_base,
            .kernel_phys_end = parse_result.phys_end,
        };

        // Jump to kernel (with EL drop if needed).
        el_drop.jumpToKernel(parse_result.entry, boot_info_addr);
        // Does not return.
    }

    // If we get here, all attempts failed
    con.puts("[boot] FATAL: ExitBootServices failed after 5 attempts\n");
    halt();
}

/// Load the kernel ELF binary from the ESP filesystem.
/// Returns a slice of the file data in allocated memory, or null on failure.
fn loadKernelFile(bs: *BootServices, con: Console) ?[]const u8 {
    // Get LoadedImage protocol to find the ESP device handle
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

    // Get SimpleFileSystem protocol from the ESP device
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

    // Open the root volume
    const root = fs.openVolume() catch {
        con.puts("  ERROR: Cannot open root volume\n");
        return null;
    };

    // Open the kernel file
    const kernel_file = root.open(KERNEL_PATH, .read, .{}) catch {
        con.puts("  ERROR: Cannot open kernel file\n");
        return null;
    };

    // Get file size via getEndPosition: seek to end, get position, seek back
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

    // Seek back to start
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

    // Read the file into the buffer
    const buf: [*]u8 = @ptrCast(file_mem.ptr);
    var total_read: u64 = 0;
    while (total_read < file_size) {
        const remaining = file_size - total_read;
        const chunk_size: usize = @min(remaining, 65536); // Read in 64KB chunks
        const bytes_read = kernel_file.read(buf[total_read..][0..chunk_size]) catch {
            con.puts("  ERROR: Read failed\n");
            return null;
        };
        if (bytes_read == 0) break; // EOF
        total_read += bytes_read;
    }

    kernel_file.close() catch {};

    return buf[0..@as(usize, @truncate(total_read))];
}

/// Search UEFI configuration tables for a specific GUID.
/// Returns the physical address of the table, or 0 if not found.
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
        asm volatile ("wfi");
    }
}
