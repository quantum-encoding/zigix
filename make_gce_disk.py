#!/usr/bin/env python3
"""Create a GCE-compatible GPT disk image with ESP + ext4 root partition.

Usage:
    make_gce_disk.py <output.raw> <bootloader.efi> <kernel> [ext4_root.img]

Creates a raw disk image with:
  - Protective MBR + GPT partition table
  - Partition 1: EFI System Partition (FAT32, 100MB)
    Contains /EFI/BOOT/BOOTAA64.EFI and /zigix/zigix-aarch64
  - Partition 2: ext4 root (remaining space, from ext4_root.img or blank)

The output is suitable for GCE import:
    tar -czf zigix-arm64.tar.gz disk.raw
    gcloud compute images create zigix-arm64 \\
        --source-uri=gs://bucket/zigix-arm64.tar.gz \\
        --guest-os-features=UEFI_COMPATIBLE \\
        --architecture=ARM64
"""

import struct
import sys
import os
import uuid
import zlib
import math

SECTOR_SIZE = 512
BLOCK_SIZE = 4096

# Partition sizes
ESP_SIZE_MB = 100
ESP_SECTORS = ESP_SIZE_MB * 1024 * 1024 // SECTOR_SIZE  # 204800

# GCE requires disk size to be a multiple of 1 GB
# 2 GB disk: ESP (100MB) + root (~1.9GB)
DISK_SIZE_GB = 2
DISK_SIZE = DISK_SIZE_GB * 1024 * 1024 * 1024
TOTAL_SECTORS = DISK_SIZE // SECTOR_SIZE

# GPT layout
GPT_HEADER_LBA = 1
GPT_ENTRIES_START_LBA = 2
GPT_ENTRY_SIZE = 128
GPT_NUM_ENTRIES = 128
GPT_ENTRIES_SECTORS = (GPT_NUM_ENTRIES * GPT_ENTRY_SIZE + SECTOR_SIZE - 1) // SECTOR_SIZE  # 32

# Partition LBAs
ESP_START_LBA = GPT_ENTRIES_START_LBA + GPT_ENTRIES_SECTORS  # 34
ESP_END_LBA = ESP_START_LBA + ESP_SECTORS - 1
ROOT_START_LBA = ESP_END_LBA + 1
ROOT_END_LBA = TOTAL_SECTORS - GPT_ENTRIES_SECTORS - 2  # Leave room for backup GPT

# GPT type GUIDs
EFI_SYSTEM_GUID = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B")
LINUX_FS_GUID = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4")


def guid_to_mixed_endian(u):
    """Convert UUID to GPT mixed-endian byte format."""
    b = u.bytes
    # GPT stores first 3 components as little-endian, last 2 as big-endian
    return (b[3::-1] + b[5:3:-1] + b[7:5:-1] + b[8:16])


def crc32(data):
    """CRC32 for GPT (same as zlib crc32, unsigned)."""
    return zlib.crc32(data) & 0xFFFFFFFF


def make_fat32_esp(bootloader_data, kernel_data):
    """Create a FAT32 filesystem image for the ESP.

    Uses 1 sector/cluster (512 bytes) to match mkfs.fat defaults,
    which is required for EDK2 UEFI firmware compatibility.

    Directory structure:
      /EFI/BOOT/BOOTAA64.EFI
      /zigix/zigix-aarch64
    """
    esp_size = ESP_SECTORS * SECTOR_SIZE
    fat = bytearray(esp_size)

    # FAT32 BPB — match mkfs.fat 4.2 output exactly
    bytes_per_sector = 512
    sectors_per_cluster = 1  # 512 bytes — EDK2 compatible
    reserved_sectors = 32
    num_fats = 2
    total_sectors_32 = ESP_SECTORS
    cluster_size = bytes_per_sector * sectors_per_cluster

    # FAT size calculation (matching mkfs.fat algorithm)
    # Each FAT entry is 4 bytes; total entries = total_clusters + 2
    # Iterate to converge on fat_size_sectors
    data_sectors = total_sectors_32 - reserved_sectors
    fat_size_sectors = (data_sectors * 4 // bytes_per_sector + num_fats * 4) // (num_fats * bytes_per_sector + 4) + 1
    # Round up to match mkfs.fat
    while True:
        data_start = reserved_sectors + num_fats * fat_size_sectors
        usable = total_sectors_32 - data_start
        max_clusters = usable // sectors_per_cluster
        needed_fat = (max_clusters + 2) * 4
        needed_sectors = (needed_fat + bytes_per_sector - 1) // bytes_per_sector
        if needed_sectors <= fat_size_sectors:
            break
        fat_size_sectors += 1

    data_start_sector = reserved_sectors + num_fats * fat_size_sectors
    data_clusters = (total_sectors_32 - data_start_sector) // sectors_per_cluster

    # Jump boot code
    fat[0:3] = b'\xEB\x58\x90'
    # OEM name
    fat[3:11] = b'mkfs.fat'
    # BPB
    struct.pack_into('<H', fat, 11, bytes_per_sector)
    fat[13] = sectors_per_cluster
    struct.pack_into('<H', fat, 14, reserved_sectors)
    fat[16] = num_fats
    struct.pack_into('<H', fat, 17, 0)  # root entry count (0 for FAT32)
    struct.pack_into('<H', fat, 19, 0)  # total sectors 16 (0 for FAT32)
    fat[21] = 0xF8  # media type (fixed disk)
    struct.pack_into('<H', fat, 22, 0)  # FAT size 16 (0 for FAT32)
    struct.pack_into('<H', fat, 24, 32)  # sectors per track
    struct.pack_into('<H', fat, 26, 8)   # number of heads
    struct.pack_into('<I', fat, 28, 0)   # hidden sectors
    struct.pack_into('<I', fat, 32, total_sectors_32)
    # FAT32 extended BPB
    struct.pack_into('<I', fat, 36, fat_size_sectors)
    struct.pack_into('<H', fat, 40, 0)  # ext flags
    struct.pack_into('<H', fat, 42, 0)  # FS version
    struct.pack_into('<I', fat, 44, 2)  # root cluster = 2
    struct.pack_into('<H', fat, 48, 1)  # FS info sector
    struct.pack_into('<H', fat, 50, 6)  # backup boot sector
    fat[66] = 0x29  # boot signature
    struct.pack_into('<I', fat, 67, 0x5A494749)  # volume serial
    fat[71:82] = b'ZIGIX ESP  '  # volume label
    fat[82:90] = b'FAT32   '  # FS type
    # Boot sector signature
    struct.pack_into('<H', fat, 510, 0xAA55)

    # FSInfo sector (sector 1)
    fsinfo_off = bytes_per_sector
    struct.pack_into('<I', fat, fsinfo_off, 0x41615252)  # lead signature
    struct.pack_into('<I', fat, fsinfo_off + 484, 0x61417272)  # struct signature
    struct.pack_into('<I', fat, fsinfo_off + 488, data_clusters - 10)  # free cluster count (approx)
    struct.pack_into('<I', fat, fsinfo_off + 492, 3)  # next free cluster hint
    struct.pack_into('<I', fat, fsinfo_off + 508, 0xAA550000)  # trail signature

    # Backup boot sector at sector 6
    fat[6 * bytes_per_sector:7 * bytes_per_sector] = fat[:bytes_per_sector]

    # FAT tables
    next_cluster = 2  # first data cluster

    def alloc_cluster():
        nonlocal next_cluster
        c = next_cluster
        next_cluster += 1
        return c

    def cluster_offset(cluster):
        return data_start_sector * bytes_per_sector + (cluster - 2) * cluster_size

    def set_fat_entry(cluster, value):
        for f in range(num_fats):
            off = (reserved_sectors + f * fat_size_sectors) * bytes_per_sector + cluster * 4
            struct.pack_into('<I', fat, off, value)

    # FAT[0] and FAT[1] are reserved
    set_fat_entry(0, 0x0FFFFFF8)  # media type
    set_fat_entry(1, 0x0FFFFFFF)  # end of chain marker

    def write_file_to_clusters(data):
        """Write file data to contiguous clusters. Returns first cluster."""
        num_clusters = max(1, math.ceil(len(data) / cluster_size))
        first = alloc_cluster()
        for i in range(num_clusters):
            c = first + i if i == 0 else alloc_cluster()
            # Write data
            off = cluster_offset(c)
            chunk_start = i * cluster_size
            chunk_end = min(chunk_start + cluster_size, len(data))
            if chunk_start < len(data):
                fat[off:off + (chunk_end - chunk_start)] = data[chunk_start:chunk_end]
            # FAT chain
            if i < num_clusters - 1:
                set_fat_entry(c, c + 1)
            else:
                set_fat_entry(c, 0x0FFFFFFF)
        return first

    def make_dir_entry(name, attr, cluster, size=0):
        """Create an 8.3 FAT directory entry (32 bytes)."""
        entry = bytearray(32)
        name_bytes = name.encode('ascii')
        if len(name_bytes) < 11:
            name_bytes += b' ' * (11 - len(name_bytes))
        entry[0:11] = name_bytes[:11]
        entry[11] = attr
        struct.pack_into('<H', entry, 20, (cluster >> 16) & 0xFFFF)
        struct.pack_into('<H', entry, 26, cluster & 0xFFFF)
        struct.pack_into('<I', entry, 28, size)
        return bytes(entry)

    def make_lfn_entries(long_name, short_name, attr, cluster, size=0):
        """Create LFN + short name entries."""
        entries = []
        chars_per_entry = 13
        num_lfn = math.ceil(len(long_name) / chars_per_entry)

        short_bytes = short_name.encode('ascii')
        if len(short_bytes) < 11:
            short_bytes += b' ' * (11 - len(short_bytes))
        cksum = 0
        for b in short_bytes[:11]:
            cksum = ((cksum >> 1) + ((cksum & 1) << 7) + b) & 0xFF

        for seq in range(num_lfn, 0, -1):
            lfn = bytearray(32)
            ordinal = seq | (0x40 if seq == num_lfn else 0)
            lfn[0] = ordinal
            lfn[11] = 0x0F
            lfn[13] = cksum

            start = (seq - 1) * chars_per_entry
            chars = long_name[start:start + chars_per_entry]
            padded = chars + '\x00'
            while len(padded) < chars_per_entry:
                padded += '\xFF'

            ucs2 = bytearray()
            for ch in padded[:chars_per_entry]:
                if ch == '\xFF':
                    ucs2 += b'\xFF\xFF'
                else:
                    ucs2 += ch.encode('utf-16-le')

            lfn[1:11] = ucs2[0:10]
            lfn[14:26] = ucs2[10:22]
            lfn[28:32] = ucs2[22:26]
            entries.append(bytes(lfn))

        entries.append(make_dir_entry(short_name, attr, cluster, size))
        return entries

    # Root directory (cluster 2)
    root_cluster = alloc_cluster()
    assert root_cluster == 2
    set_fat_entry(root_cluster, 0x0FFFFFFF)

    # Directory clusters
    efi_cluster = alloc_cluster()
    set_fat_entry(efi_cluster, 0x0FFFFFFF)
    boot_cluster = alloc_cluster()
    set_fat_entry(boot_cluster, 0x0FFFFFFF)
    zigix_cluster = alloc_cluster()
    set_fat_entry(zigix_cluster, 0x0FFFFFFF)

    # File clusters
    bootloader_cluster = write_file_to_clusters(bootloader_data)
    kernel_cluster = write_file_to_clusters(kernel_data)

    # Root directory
    pos = cluster_offset(root_cluster)
    fat[pos:pos + 32] = make_dir_entry("ZIGIX ESP  ", 0x08, 0)
    pos += 32
    fat[pos:pos + 32] = make_dir_entry("EFI        ", 0x10, efi_cluster)
    pos += 32
    fat[pos:pos + 32] = make_dir_entry("ZIGIX      ", 0x10, zigix_cluster)
    pos += 32

    # /EFI
    pos = cluster_offset(efi_cluster)
    fat[pos:pos + 32] = make_dir_entry(".          ", 0x10, efi_cluster)
    pos += 32
    fat[pos:pos + 32] = make_dir_entry("..         ", 0x10, root_cluster)
    pos += 32
    fat[pos:pos + 32] = make_dir_entry("BOOT       ", 0x10, boot_cluster)
    pos += 32

    # /EFI/BOOT — BOOTAA64.EFI fits 8.3 natively
    pos = cluster_offset(boot_cluster)
    fat[pos:pos + 32] = make_dir_entry(".          ", 0x10, boot_cluster)
    pos += 32
    fat[pos:pos + 32] = make_dir_entry("..         ", 0x10, efi_cluster)
    pos += 32
    fat[pos:pos + 32] = make_dir_entry("BOOTAA64EFI", 0x20, bootloader_cluster, len(bootloader_data))
    pos += 32

    # /zigix — zigix-aarch64 needs LFN
    pos = cluster_offset(zigix_cluster)
    fat[pos:pos + 32] = make_dir_entry(".          ", 0x10, zigix_cluster)
    pos += 32
    fat[pos:pos + 32] = make_dir_entry("..         ", 0x10, root_cluster)
    pos += 32
    lfn_entries = make_lfn_entries("zigix-aarch64", "ZIGIX-~1   ", 0x20, kernel_cluster, len(kernel_data))
    for entry in lfn_entries:
        fat[pos:pos + 32] = entry
        pos += 32

    return fat


def make_protective_mbr(disk_guid_bytes):
    """Create a protective MBR for GPT."""
    mbr = bytearray(SECTOR_SIZE)

    # Protective MBR partition entry at offset 446
    # Type 0xEE = GPT protective
    mbr[446] = 0x00  # status
    # CHS of first sector (0/0/2)
    mbr[447] = 0x00
    mbr[448] = 0x02
    mbr[449] = 0x00
    mbr[450] = 0xEE  # type = GPT protective
    # CHS of last sector (0xFE/0xFF/0xFF)
    mbr[451] = 0xFE
    mbr[452] = 0xFF
    mbr[453] = 0xFF
    # LBA of first sector
    struct.pack_into('<I', mbr, 454, 1)
    # Number of sectors
    sectors = min(TOTAL_SECTORS - 1, 0xFFFFFFFF)
    struct.pack_into('<I', mbr, 458, sectors)

    # Boot signature
    struct.pack_into('<H', mbr, 510, 0xAA55)
    return mbr


def make_gpt(disk_uuid, esp_uuid, root_uuid):
    """Create primary and backup GPT header + partition entries."""

    # Partition entries (128 bytes each, 128 entries)
    entries = bytearray(GPT_NUM_ENTRIES * GPT_ENTRY_SIZE)

    # Entry 0: EFI System Partition
    off = 0
    entries[off:off + 16] = guid_to_mixed_endian(EFI_SYSTEM_GUID)
    entries[off + 16:off + 32] = guid_to_mixed_endian(esp_uuid)
    struct.pack_into('<Q', entries, off + 32, ESP_START_LBA)
    struct.pack_into('<Q', entries, off + 40, ESP_END_LBA)
    struct.pack_into('<Q', entries, off + 48, 0)  # attributes
    # Partition name: "EFI System" in UTF-16LE
    name = "EFI System".encode('utf-16-le')
    entries[off + 56:off + 56 + len(name)] = name

    # Entry 1: Linux root partition
    off = GPT_ENTRY_SIZE
    entries[off:off + 16] = guid_to_mixed_endian(LINUX_FS_GUID)
    entries[off + 16:off + 32] = guid_to_mixed_endian(root_uuid)
    struct.pack_into('<Q', entries, off + 32, ROOT_START_LBA)
    struct.pack_into('<Q', entries, off + 40, ROOT_END_LBA)
    struct.pack_into('<Q', entries, off + 48, 0)
    name = "Zigix Root".encode('utf-16-le')
    entries[off + 56:off + 56 + len(name)] = name

    entries_crc = crc32(bytes(entries))

    # Primary GPT header (LBA 1)
    primary = bytearray(SECTOR_SIZE)
    primary[0:8] = b'EFI PART'  # signature
    struct.pack_into('<I', primary, 8, 0x00010000)  # revision 1.0
    struct.pack_into('<I', primary, 12, 92)  # header size
    struct.pack_into('<I', primary, 16, 0)  # header CRC32 (filled later)
    struct.pack_into('<I', primary, 20, 0)  # reserved
    struct.pack_into('<Q', primary, 24, GPT_HEADER_LBA)  # my LBA
    struct.pack_into('<Q', primary, 32, TOTAL_SECTORS - 1)  # alternate LBA
    struct.pack_into('<Q', primary, 40, ESP_START_LBA)  # first usable LBA
    struct.pack_into('<Q', primary, 48, ROOT_END_LBA)  # last usable LBA
    primary[56:72] = guid_to_mixed_endian(disk_uuid)
    struct.pack_into('<Q', primary, 72, GPT_ENTRIES_START_LBA)  # partition entries LBA
    struct.pack_into('<I', primary, 80, GPT_NUM_ENTRIES)
    struct.pack_into('<I', primary, 84, GPT_ENTRY_SIZE)
    struct.pack_into('<I', primary, 88, entries_crc)
    # Compute header CRC32
    header_crc = crc32(bytes(primary[:92]))
    struct.pack_into('<I', primary, 16, header_crc)

    # Backup GPT header (last LBA)
    backup = bytearray(SECTOR_SIZE)
    backup[:] = primary[:]
    struct.pack_into('<I', backup, 16, 0)  # clear CRC for recalculation
    struct.pack_into('<Q', backup, 24, TOTAL_SECTORS - 1)  # my LBA
    struct.pack_into('<Q', backup, 32, GPT_HEADER_LBA)  # alternate LBA
    backup_entries_lba = TOTAL_SECTORS - GPT_ENTRIES_SECTORS - 1
    struct.pack_into('<Q', backup, 72, backup_entries_lba)
    backup_crc = crc32(bytes(backup[:92]))
    struct.pack_into('<I', backup, 16, backup_crc)

    return primary, entries, backup, backup_entries_lba


def main():
    if len(sys.argv) < 4:
        print("Usage: make_gce_disk.py <output.raw> <bootloader.efi> <kernel> [ext4_root.img]")
        sys.exit(1)

    output_path = sys.argv[1]
    bootloader_path = sys.argv[2]
    kernel_path = sys.argv[3]
    ext4_path = sys.argv[4] if len(sys.argv) > 4 else None

    with open(bootloader_path, 'rb') as f:
        bootloader_data = f.read()
    print(f"  Bootloader: {bootloader_path} ({len(bootloader_data)} bytes)")

    with open(kernel_path, 'rb') as f:
        kernel_data = f.read()
    print(f"  Kernel: {kernel_path} ({len(kernel_data)} bytes)")

    ext4_data = None
    if ext4_path:
        with open(ext4_path, 'rb') as f:
            ext4_data = f.read()
        print(f"  Root FS: {ext4_path} ({len(ext4_data) // (1024*1024)} MB)")

    # Generate UUIDs
    disk_uuid = uuid.uuid4()
    esp_uuid = uuid.uuid4()
    root_uuid = uuid.uuid4()

    print(f"\n  Disk UUID: {disk_uuid}")
    print(f"  ESP UUID:  {esp_uuid}")
    print(f"  Root UUID: {root_uuid}")

    # Build FAT32 ESP
    print("\n  Building FAT32 ESP...")
    esp_image = make_fat32_esp(bootloader_data, kernel_data)

    # Build GPT
    print("  Building GPT partition table...")
    primary_header, entries, backup_header, backup_entries_lba = make_gpt(
        disk_uuid, esp_uuid, root_uuid)
    mbr = make_protective_mbr(guid_to_mixed_endian(disk_uuid))

    # Write disk image
    print(f"  Writing {DISK_SIZE_GB} GB disk image...")
    with open(output_path, 'wb') as f:
        # Protective MBR (LBA 0)
        f.write(mbr)

        # Primary GPT header (LBA 1)
        f.write(primary_header)

        # Primary partition entries (LBA 2-33)
        f.write(entries)
        padding = GPT_ENTRIES_SECTORS * SECTOR_SIZE - len(entries)
        if padding > 0:
            f.write(b'\x00' * padding)

        # ESP partition
        assert f.tell() == ESP_START_LBA * SECTOR_SIZE
        f.write(esp_image)

        # Root partition
        root_start_byte = ROOT_START_LBA * SECTOR_SIZE
        assert f.tell() == root_start_byte, f"Expected {root_start_byte}, at {f.tell()}"
        root_size = (ROOT_END_LBA - ROOT_START_LBA + 1) * SECTOR_SIZE
        if ext4_data:
            # Write ext4 image, pad or truncate to partition size
            if len(ext4_data) <= root_size:
                f.write(ext4_data)
                f.write(b'\x00' * (root_size - len(ext4_data)))
            else:
                print(f"  WARNING: ext4 image ({len(ext4_data)}) larger than partition ({root_size}), truncating")
                f.write(ext4_data[:root_size])
        else:
            # Empty root partition
            f.write(b'\x00' * root_size)

        # Backup partition entries
        backup_start = backup_entries_lba * SECTOR_SIZE
        assert f.tell() == backup_start, f"Expected backup entries at {backup_start}, at {f.tell()}"
        f.write(entries)
        padding = GPT_ENTRIES_SECTORS * SECTOR_SIZE - len(entries)
        if padding > 0:
            f.write(b'\x00' * padding)

        # Backup GPT header (last LBA)
        f.write(backup_header)

    actual_size = os.path.getsize(output_path)
    print(f"\nCreated GCE disk image: {output_path}")
    print(f"  Size: {actual_size // (1024*1024*1024)} GB ({actual_size} bytes)")
    print(f"  Partitions:")
    print(f"    1: ESP  (FAT32)  LBA {ESP_START_LBA}-{ESP_END_LBA}  ({ESP_SIZE_MB} MB)")
    print(f"    2: Root (ext4)   LBA {ROOT_START_LBA}-{ROOT_END_LBA}  ({(ROOT_END_LBA - ROOT_START_LBA + 1) * SECTOR_SIZE // (1024*1024)} MB)")
    print(f"\n  Next steps:")
    print(f"    mv {output_path} disk.raw")
    print(f"    tar -czf zigix-arm64.tar.gz disk.raw")
    print(f"    gsutil cp zigix-arm64.tar.gz gs://your-bucket/")
    print(f"    gcloud compute images create zigix-arm64 \\")
    print(f"        --source-uri=gs://your-bucket/zigix-arm64.tar.gz \\")
    print(f"        --guest-os-features=UEFI_COMPATIBLE \\")
    print(f"        --architecture=ARM64")


if __name__ == '__main__':
    main()
