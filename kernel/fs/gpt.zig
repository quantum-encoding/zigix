/// GPT (GUID Partition Table) parser.
///
/// Reads the GPT header and partition entries from a block device to find
/// the root filesystem partition. Used during boot to determine the sector
/// offset for block_io so ext2/ext3/ext4 can mount transparently from a
/// partitioned disk (GCE NVMe, GPT disk images, etc.).
///
/// GPT layout:
///   LBA 0: Protective MBR
///   LBA 1: GPT Header (signature "EFI PART")
///   LBA 2-33: Partition entries (128 bytes each, 128 entries)
///   LBA N..M: Partitions
///   LBA last-33..last-1: Backup partition entries
///   LBA last: Backup GPT header

const uart = @import("../arch/x86_64/serial.zig");

/// GPT header signature: "EFI PART"
const GPT_SIGNATURE: u64 = 0x5452415020494645;

/// Linux filesystem GUID: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
/// Stored in mixed-endian GPT format (first 3 components LE, last 2 BE).
const LINUX_FS_GUID = [16]u8{
    0xAF, 0x3D, 0xC6, 0x0F, // LE u32
    0x83, 0x84, // LE u16
    0x72, 0x47, // LE u16
    0x8E, 0x79, // BE
    0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4, // BE
};

/// EFI System Partition GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
const ESP_GUID = [16]u8{
    0x28, 0x73, 0x2A, 0xC1,
    0x1F, 0xF8,
    0xD2, 0x11,
    0xBA, 0x4B,
    0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
};

/// Result of GPT scan.
pub const GptPartition = struct {
    start_lba: u64,
    end_lba: u64,
    type_guid: [16]u8,
    found: bool,
};

/// Scan GPT partition table and find the first Linux filesystem partition.
/// Returns the partition's start LBA, or null if no GPT or no Linux partition found.
///
/// `readSectorsRaw` must read raw 512-byte sectors (no partition offset).
pub fn findLinuxRootPartition(
    readSectorsRaw: *const fn (sector: u64, count: u32, buf: [*]u8) bool,
) ?GptPartition {
    // Read LBA 1 (GPT header)
    var hdr_buf: [512]u8 = undefined;
    if (!readSectorsRaw(1, 1, &hdr_buf)) {
        uart.writeString("[gpt]  Failed to read GPT header (LBA 1)\n");
        return null;
    }

    // Check signature
    const sig = readU64LE(&hdr_buf, 0);
    if (sig != GPT_SIGNATURE) {
        uart.writeString("[gpt]  No GPT signature found\n");
        return null;
    }

    uart.writeString("[gpt]  GPT signature valid\n");

    // Parse header fields
    const entries_lba = readU64LE(&hdr_buf, 72); // partition entry start LBA
    const num_entries = readU32LE(&hdr_buf, 80); // number of partition entries
    const entry_size = readU32LE(&hdr_buf, 84); // size of each entry (usually 128)

    uart.print("[gpt]  {} entries at LBA {}, {} bytes each\n", .{
        num_entries, entries_lba, entry_size,
    });

    if (entry_size < 128 or entry_size > 512) {
        uart.writeString("[gpt]  Invalid entry size\n");
        return null;
    }

    // Read partition entries — they may span multiple sectors.
    // Process one sector at a time to avoid large buffers.
    const entries_per_sector = 512 / entry_size;
    const total_sectors = (num_entries + entries_per_sector - 1) / entries_per_sector;

    // Cap to reasonable limit
    const max_sectors: u64 = if (total_sectors > 64) 64 else total_sectors;

    var entry_buf: [512]u8 = undefined;
    var sector: u64 = 0;
    while (sector < max_sectors) : (sector += 1) {
        if (!readSectorsRaw(entries_lba + sector, 1, &entry_buf)) {
            break;
        }

        var off: usize = 0;
        while (off + entry_size <= 512) : (off += entry_size) {
            // Check if this entry's type GUID matches Linux filesystem
            const type_guid = entry_buf[off..][0..16];

            // Skip empty entries (all zeros)
            if (isZeroGuid(type_guid)) continue;

            const start_lba = readU64LE(&entry_buf, off + 32);
            const end_lba = readU64LE(&entry_buf, off + 40);

            if (guidEql(type_guid, &LINUX_FS_GUID)) {
                uart.print("[gpt]  Linux root partition: LBA {}-{} ({} MB)\n", .{
                    start_lba,
                    end_lba,
                    (end_lba - start_lba + 1) * 512 / (1024 * 1024),
                });
                return GptPartition{
                    .start_lba = start_lba,
                    .end_lba = end_lba,
                    .type_guid = type_guid[0..16].*,
                    .found = true,
                };
            }

            if (guidEql(type_guid, &ESP_GUID)) {
                uart.print("[gpt]  ESP partition: LBA {}-{}\n", .{ start_lba, end_lba });
            }
        }
    }

    uart.writeString("[gpt]  No Linux filesystem partition found\n");
    return null;
}

/// Find the EFI System Partition (FAT32).
pub fn findEspPartition(
    readSectorsRaw: *const fn (sector: u64, count: u32, buf: [*]u8) bool,
) ?GptPartition {
    var hdr_buf: [512]u8 = undefined;
    if (!readSectorsRaw(1, 1, &hdr_buf)) return null;
    if (readU64LE(&hdr_buf, 0) != GPT_SIGNATURE) return null;

    const entries_lba = readU64LE(&hdr_buf, 72);
    const num_entries = readU32LE(&hdr_buf, 80);
    const entry_size = readU32LE(&hdr_buf, 84);
    if (entry_size < 128 or entry_size > 512) return null;

    var entry_buf: [512]u8 = undefined;
    const entries_per_sector: u32 = 512 / @as(u32, @truncate(entry_size));
    var current_lba: u64 = entries_lba;

    var i: u32 = 0;
    while (i < num_entries) {
        if (i % entries_per_sector == 0) {
            if (!readSectorsRaw(current_lba, 1, &entry_buf)) break;
            current_lba += 1;
        }
        const off = (i % entries_per_sector) * @as(u32, @truncate(entry_size));
        const type_guid = entry_buf[off..][0..16];

        if (guidEql(type_guid, &ESP_GUID)) {
            const start_lba = readU64LE(entry_buf[off..], 32);
            return .{
                .start_lba = start_lba,
                .end_lba = readU64LE(entry_buf[off..], 40),
                .type_guid = type_guid[0..16].*,
                .found = true,
            };
        }
        i += 1;
    }
    return null;
}

// ---- helpers ----

fn readU32LE(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

fn readU64LE(buf: []const u8, off: usize) u64 {
    return @as(u64, readU32LE(buf, off)) |
        (@as(u64, readU32LE(buf, off + 4)) << 32);
}

fn isZeroGuid(guid: []const u8) bool {
    for (guid) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn guidEql(a: []const u8, b: *const [16]u8) bool {
    for (0..16) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    uart.print(fmt, args);
}
