#!/bin/bash
# GPT partition table smoke test for Zigix ARM64 kernel.
#
# Creates a minimal 256MB disk image with:
#   - Protective MBR + GPT partition table
#   - One Linux root partition (type 0FC63DAF) containing ext2
# Boots QEMU with -kernel and the disk as virtio-blk, then checks
# that the kernel detects and parses the GPT table correctly.
#
# Expected kernel output:
#   [gpt]  GPT signature valid
#   [gpt]  Linux root partition: LBA ...
#   [boot] GPT: root partition at LBA ...
#   [ext2] block_size=...
#
# Usage: ./test_gpt_boot.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL=zig-out/bin/zigix-aarch64
DISK=test-gpt-smoke.img
QEMU=/opt/homebrew/bin/qemu-system-aarch64
TIMEOUT_SEC=15

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: Kernel not found at $KERNEL"
    echo "       Run: zig build -Darch=aarch64"
    exit 1
fi

if [ ! -x "$QEMU" ]; then
    echo "ERROR: QEMU not found at $QEMU"
    exit 1
fi

echo "=== Zigix ARM64 GPT Smoke Test ==="
echo ""

# ---- Step 1: Create GPT disk image with ext2 partition ----
echo "[1/3] Creating 256MB GPT disk image with ext2 partition..."

python3 - "$DISK" <<'PYEOF'
"""Create a minimal 256MB GPT disk image with one ext2 Linux root partition."""
import struct, sys, os, uuid, zlib

SECTOR = 512
DISK_SIZE = 256 * 1024 * 1024  # 256 MB
TOTAL_SECTORS = DISK_SIZE // SECTOR
BLOCK_SIZE = 4096

# GPT layout constants
GPT_HEADER_LBA = 1
GPT_ENTRIES_START = 2
GPT_ENTRY_SIZE = 128
GPT_NUM_ENTRIES = 128
GPT_ENTRIES_SECTORS = (GPT_NUM_ENTRIES * GPT_ENTRY_SIZE + SECTOR - 1) // SECTOR  # 32

# Partition starts right after primary GPT entries
PART_START_LBA = GPT_ENTRIES_START + GPT_ENTRIES_SECTORS  # LBA 34
PART_END_LBA = TOTAL_SECTORS - GPT_ENTRIES_SECTORS - 2    # leave room for backup GPT

# Linux filesystem GUID: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
LINUX_FS_GUID = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4")

def guid_to_mixed_endian(u):
    b = u.bytes
    return b[3::-1] + b[5:3:-1] + b[7:5:-1] + b[8:16]

def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF

def make_minimal_ext2(size_bytes):
    """Create a minimal ext2 filesystem with just a valid superblock and root dir."""
    img = bytearray(size_bytes)
    block_size = 4096
    total_blocks = size_bytes // block_size
    inodes_per_group = 256
    blocks_per_group = 8192
    num_groups = max(1, (total_blocks + blocks_per_group - 1) // blocks_per_group)

    # ---- Superblock at byte offset 1024 ----
    sb_off = 1024
    # s_inodes_count
    struct.pack_into('<I', img, sb_off + 0, inodes_per_group * num_groups)
    # s_blocks_count
    struct.pack_into('<I', img, sb_off + 4, total_blocks)
    # s_r_blocks_count (reserved)
    struct.pack_into('<I', img, sb_off + 8, 0)
    # s_free_blocks_count
    struct.pack_into('<I', img, sb_off + 12, total_blocks - 20)
    # s_free_inodes_count
    struct.pack_into('<I', img, sb_off + 16, inodes_per_group * num_groups - 11)
    # s_first_data_block (0 for 4K blocks)
    struct.pack_into('<I', img, sb_off + 20, 0)
    # s_log_block_size (log2(block_size) - 10 = 2 for 4096)
    struct.pack_into('<I', img, sb_off + 24, 2)
    # s_log_frag_size
    struct.pack_into('<I', img, sb_off + 28, 2)
    # s_blocks_per_group
    struct.pack_into('<I', img, sb_off + 32, blocks_per_group)
    # s_frags_per_group
    struct.pack_into('<I', img, sb_off + 36, blocks_per_group)
    # s_inodes_per_group
    struct.pack_into('<I', img, sb_off + 40, inodes_per_group)
    # s_mtime, s_wtime
    struct.pack_into('<I', img, sb_off + 44, 0)
    struct.pack_into('<I', img, sb_off + 48, 0)
    # s_mnt_count
    struct.pack_into('<H', img, sb_off + 52, 0)
    # s_max_mnt_count
    struct.pack_into('<H', img, sb_off + 54, 20)
    # s_magic = 0xEF53
    struct.pack_into('<H', img, sb_off + 56, 0xEF53)
    # s_state = EXT2_VALID_FS
    struct.pack_into('<H', img, sb_off + 58, 1)
    # s_errors = EXT2_ERRORS_CONTINUE
    struct.pack_into('<H', img, sb_off + 60, 1)
    # s_minor_rev_level
    struct.pack_into('<H', img, sb_off + 62, 0)
    # s_lastcheck
    struct.pack_into('<I', img, sb_off + 64, 0)
    # s_checkinterval
    struct.pack_into('<I', img, sb_off + 68, 0)
    # s_creator_os = EXT2_OS_LINUX
    struct.pack_into('<I', img, sb_off + 72, 0)
    # s_rev_level = EXT2_DYNAMIC_REV (1) for variable inode size
    struct.pack_into('<I', img, sb_off + 76, 1)
    # s_def_resuid, s_def_resgid
    struct.pack_into('<H', img, sb_off + 80, 0)
    struct.pack_into('<H', img, sb_off + 82, 0)
    # s_first_ino (EXT2_GOOD_OLD_FIRST_INO = 11)
    struct.pack_into('<I', img, sb_off + 84, 11)
    # s_inode_size = 128
    struct.pack_into('<H', img, sb_off + 88, 128)
    # s_block_group_nr
    struct.pack_into('<H', img, sb_off + 90, 0)

    # ---- Block Group Descriptor Table at block 1 (byte 4096) ----
    bgd_off = block_size  # block 1
    # bg_block_bitmap = block 2
    struct.pack_into('<I', img, bgd_off + 0, 2)
    # bg_inode_bitmap = block 3
    struct.pack_into('<I', img, bgd_off + 4, 3)
    # bg_inode_table = block 4
    struct.pack_into('<I', img, bgd_off + 8, 4)
    # bg_free_blocks_count
    struct.pack_into('<H', img, bgd_off + 12, blocks_per_group - 20)
    # bg_free_inodes_count
    struct.pack_into('<H', img, bgd_off + 14, inodes_per_group - 11)
    # bg_used_dirs_count
    struct.pack_into('<H', img, bgd_off + 16, 1)

    # ---- Block bitmap at block 2 (mark first 12 blocks used) ----
    bb_off = 2 * block_size
    img[bb_off] = 0xFF  # blocks 0-7 used
    img[bb_off + 1] = 0x0F  # blocks 8-11 used

    # ---- Inode bitmap at block 3 (mark first 11 inodes used) ----
    ib_off = 3 * block_size
    img[ib_off] = 0xFF  # inodes 1-8
    img[ib_off + 1] = 0x07  # inodes 9-11

    # ---- Inode table at block 4 ----
    # Inode 2 = root directory (128 bytes per inode, inode 1 is at offset 0)
    inode_table_off = 4 * block_size
    root_inode_off = inode_table_off + 128  # inode 2 (0-indexed: slot 1)

    # i_mode = S_IFDIR | 0755
    struct.pack_into('<H', img, root_inode_off + 0, 0o40755)
    # i_uid
    struct.pack_into('<H', img, root_inode_off + 2, 0)
    # i_size (size of directory data = one block)
    struct.pack_into('<I', img, root_inode_off + 4, block_size)
    # i_atime, i_ctime, i_mtime
    struct.pack_into('<I', img, root_inode_off + 8, 1710000000)
    struct.pack_into('<I', img, root_inode_off + 12, 1710000000)
    struct.pack_into('<I', img, root_inode_off + 16, 1710000000)
    # i_links_count = 2 (. and ..)
    struct.pack_into('<H', img, root_inode_off + 26, 2)
    # i_blocks (in 512-byte units, 4096/512 = 8)
    struct.pack_into('<I', img, root_inode_off + 28, 8)
    # i_block[0] = block 12 (first data block for root dir)
    struct.pack_into('<I', img, root_inode_off + 40, 12)

    # ---- Root directory data at block 12 ----
    dir_off = 12 * block_size
    # Entry: "." -> inode 2
    struct.pack_into('<I', img, dir_off + 0, 2)       # inode
    struct.pack_into('<H', img, dir_off + 4, 12)      # rec_len
    img[dir_off + 6] = 1                               # name_len
    img[dir_off + 7] = 2                               # file_type = EXT2_FT_DIR
    img[dir_off + 8] = ord('.')
    # Entry: ".." -> inode 2
    struct.pack_into('<I', img, dir_off + 12, 2)      # inode
    struct.pack_into('<H', img, dir_off + 16, block_size - 12)  # rec_len (rest of block)
    img[dir_off + 18] = 2                              # name_len
    img[dir_off + 19] = 2                              # file_type = EXT2_FT_DIR
    img[dir_off + 20] = ord('.')
    img[dir_off + 21] = ord('.')

    return img

# ---- Build disk image ----
output = sys.argv[1]

disk_uuid = uuid.uuid4()
part_uuid = uuid.uuid4()

# Build partition entries
entries = bytearray(GPT_NUM_ENTRIES * GPT_ENTRY_SIZE)
off = 0
entries[off:off+16] = guid_to_mixed_endian(LINUX_FS_GUID)
entries[off+16:off+32] = guid_to_mixed_endian(part_uuid)
struct.pack_into('<Q', entries, off+32, PART_START_LBA)
struct.pack_into('<Q', entries, off+40, PART_END_LBA)
struct.pack_into('<Q', entries, off+48, 0)  # attributes
name = "Zigix Root".encode('utf-16-le')
entries[off+56:off+56+len(name)] = name

entries_crc = crc32(bytes(entries))

# Primary GPT header
primary = bytearray(SECTOR)
primary[0:8] = b'EFI PART'
struct.pack_into('<I', primary, 8, 0x00010000)   # revision
struct.pack_into('<I', primary, 12, 92)          # header size
struct.pack_into('<I', primary, 16, 0)           # CRC (filled below)
struct.pack_into('<I', primary, 20, 0)           # reserved
struct.pack_into('<Q', primary, 24, GPT_HEADER_LBA)
struct.pack_into('<Q', primary, 32, TOTAL_SECTORS - 1)     # alternate
struct.pack_into('<Q', primary, 40, PART_START_LBA)        # first usable
struct.pack_into('<Q', primary, 48, PART_END_LBA)          # last usable
primary[56:72] = guid_to_mixed_endian(disk_uuid)
struct.pack_into('<Q', primary, 72, GPT_ENTRIES_START)
struct.pack_into('<I', primary, 80, GPT_NUM_ENTRIES)
struct.pack_into('<I', primary, 84, GPT_ENTRY_SIZE)
struct.pack_into('<I', primary, 88, entries_crc)
hdr_crc = crc32(bytes(primary[:92]))
struct.pack_into('<I', primary, 16, hdr_crc)

# Backup GPT header
backup = bytearray(primary)
struct.pack_into('<I', backup, 16, 0)
struct.pack_into('<Q', backup, 24, TOTAL_SECTORS - 1)
struct.pack_into('<Q', backup, 32, GPT_HEADER_LBA)
backup_entries_lba = TOTAL_SECTORS - GPT_ENTRIES_SECTORS - 1
struct.pack_into('<Q', backup, 72, backup_entries_lba)
backup_crc = crc32(bytes(backup[:92]))
struct.pack_into('<I', backup, 16, backup_crc)

# Protective MBR
mbr = bytearray(SECTOR)
mbr[446] = 0x00
mbr[447:450] = b'\x00\x02\x00'
mbr[450] = 0xEE
mbr[451:454] = b'\xFE\xFF\xFF'
struct.pack_into('<I', mbr, 454, 1)
struct.pack_into('<I', mbr, 458, min(TOTAL_SECTORS - 1, 0xFFFFFFFF))
struct.pack_into('<H', mbr, 510, 0xAA55)

# ext2 filesystem for the partition
part_size = (PART_END_LBA - PART_START_LBA + 1) * SECTOR
ext2_data = make_minimal_ext2(part_size)

# Write disk
with open(output, 'wb') as f:
    f.write(mbr)                      # LBA 0
    f.write(primary)                  # LBA 1
    f.write(entries)                  # LBA 2-33
    pad = GPT_ENTRIES_SECTORS * SECTOR - len(entries)
    if pad > 0:
        f.write(b'\x00' * pad)
    assert f.tell() == PART_START_LBA * SECTOR
    f.write(ext2_data)                # partition data
    # Pad to backup entries
    cur = f.tell()
    backup_start = backup_entries_lba * SECTOR
    if cur < backup_start:
        f.write(b'\x00' * (backup_start - cur))
    f.write(entries)
    pad = GPT_ENTRIES_SECTORS * SECTOR - len(entries)
    if pad > 0:
        f.write(b'\x00' * pad)
    f.write(backup)                   # last LBA

actual = os.path.getsize(output)
print(f"  Created {output}: {actual // (1024*1024)} MB")
print(f"  Partition: LBA {PART_START_LBA}-{PART_END_LBA} ({part_size // (1024*1024)} MB ext2)")
print(f"  Disk UUID: {disk_uuid}")
PYEOF

echo ""

# ---- Step 2: Boot QEMU ----
echo "[2/3] Booting QEMU with GPT disk..."
echo "       Kernel: $KERNEL"
echo "       Disk:   $DISK"
echo "       Timeout: ${TIMEOUT_SEC}s"
echo ""

# Run QEMU with timeout, capture serial output
LOGFILE=$(mktemp /tmp/zigix-gpt-test-XXXXXX)
mv "$LOGFILE" "${LOGFILE}.log"
LOGFILE="${LOGFILE}.log"

# QEMU flags match run_aarch64.sh but minimal (no network, shorter timeout)
timeout "$TIMEOUT_SEC" "$QEMU" \
    -M virt,gic-version=3 \
    -accel tcg \
    -cpu cortex-a57 \
    -m 256M \
    -smp 1 \
    -kernel "$KERNEL" \
    -drive file="$DISK",format=raw,if=none,id=disk0 \
    -device virtio-blk-device,drive=disk0 \
    -serial stdio \
    -display none \
    -no-reboot \
    2>&1 | tee "$LOGFILE" || true

echo ""

# ---- Step 3: Check results ----
echo "[3/3] Checking kernel output..."
echo ""

PASS=0
FAIL=0

check() {
    local desc="$1"
    local pattern="$2"
    if grep -q "$pattern" "$LOGFILE"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (pattern: $pattern)"
        FAIL=$((FAIL + 1))
    fi
}

check "GPT signature detected"        '\[gpt\].*GPT signature valid'
check "Linux root partition found"     '\[gpt\].*Linux root partition'
check "Boot sets partition offset"     '\[boot\] GPT: root partition at LBA'
check "ext2 superblock parsed"         '\[ext2\] block_size='
check "ext2 mounted at /"             'ext2 mounted'

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "  Log: $LOGFILE"
echo "========================================"

# Cleanup disk image
rm -f "$DISK"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "  Some checks failed. Relevant log lines:"
    grep -E '\[(gpt|boot|ext2|fs)\]' "$LOGFILE" | head -20 || echo "  (no matching lines found)"
    exit 1
fi

exit 0
