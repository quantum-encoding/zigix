# Filesystem Test Infrastructure

## Context

Test infrastructure for validating the ext3 and ext4 implementations. Tests use real filesystem images created by Linux tools (mkfs.ext3, mkfs.ext4) to verify that Zigix correctly parses and operates on standard filesystem formats.

## Files You Create

```
tests/
├── test_journal.zig         ← Journal write/replay verification
├── test_extents.zig         ← Extent tree CRUD tests
├── test_htree.zig           ← HTree directory tests
├── test_checksums.zig       ← CRC32c checksum verification
└── test_images/
    ├── make_ext3_img.sh     ← §J5: Generate ext3 test images
    ├── make_ext4_img.sh     ← Generate ext4 test images
    └── README.md            ← Image format documentation
```

---

## §J5: ext3 Image Builder

**File:** `test_images/make_ext3_img.sh`  
**Lines:** ~80  
**Dependencies:** None (runs on Linux host, uses standard tools)

### What to implement

Shell script that creates ext3 filesystem images for testing journal replay and ext3 mounting.

```bash
#!/bin/bash
# Generate ext3 test images for Zigix filesystem testing
#
# Creates three images:
# 1. ext3-clean.img    — cleanly unmounted ext3 with files (journal clean)
# 2. ext3-dirty.img    — ext3 with dirty journal (simulated crash)
# 3. ext3-empty.img    — fresh ext3 with no user files
#
# Requirements: mkfs.ext3, mount (root), dd, tune2fs

set -euo pipefail

IMG_SIZE_MB=64
BLOCK_SIZE=4096
JOURNAL_SIZE_MB=4

# === Image 1: Clean ext3 ===
echo "Creating ext3-clean.img..."
dd if=/dev/zero of=ext3-clean.img bs=1M count=$IMG_SIZE_MB 2>/dev/null
mkfs.ext3 -b $BLOCK_SIZE -J size=$JOURNAL_SIZE_MB ext3-clean.img
MOUNT_DIR=$(mktemp -d)
sudo mount ext3-clean.img "$MOUNT_DIR"

# Create test content
sudo mkdir -p "$MOUNT_DIR/www"
echo "<html><body><h1>Zigix ext3 Test</h1></body></html>" | sudo tee "$MOUNT_DIR/www/index.html" > /dev/null
echo "Hello from ext3" | sudo tee "$MOUNT_DIR/test.txt" > /dev/null
sudo mkdir -p "$MOUNT_DIR/bin"
# Copy zhttpd and other binaries if available

# Clean unmount
sudo umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
echo "  → ext3-clean.img ready (clean journal)"

# === Image 2: Dirty ext3 (simulated crash) ===
echo "Creating ext3-dirty.img..."
cp ext3-clean.img ext3-dirty.img

# Mount, write, and DON'T unmount cleanly
MOUNT_DIR=$(mktemp -d)
sudo mount ext3-dirty.img "$MOUNT_DIR"
echo "This file was written before crash" | sudo tee "$MOUNT_DIR/crash-test.txt" > /dev/null
sudo mkdir -p "$MOUNT_DIR/crash-dir"
for i in $(seq 1 10); do
    echo "File $i content" | sudo tee "$MOUNT_DIR/crash-dir/file_$i.txt" > /dev/null
done
# Simulate crash: lazy unmount without syncing journal
# The -l flag detaches the mount but doesn't flush
sudo umount -l "$MOUNT_DIR"
# Corrupt the journal clean flag by writing directly
# (In practice, a crash would leave the journal dirty — this simulates it)
# tune2fs can be used to check/modify journal state
rmdir "$MOUNT_DIR" 2>/dev/null || true
echo "  → ext3-dirty.img ready (dirty journal for replay testing)"

# === Image 3: Empty ext3 ===
echo "Creating ext3-empty.img..."
dd if=/dev/zero of=ext3-empty.img bs=1M count=$IMG_SIZE_MB 2>/dev/null
mkfs.ext3 -b $BLOCK_SIZE -J size=$JOURNAL_SIZE_MB ext3-empty.img
echo "  → ext3-empty.img ready (empty filesystem)"

# === Verification ===
echo ""
echo "Image verification:"
for img in ext3-*.img; do
    echo "  $img: $(du -h "$img" | cut -f1)"
    tune2fs -l "$img" 2>/dev/null | grep -E "(Filesystem features|Journal|Block size)" | sed 's/^/    /'
done

echo ""
echo "Done. Copy images to zigix/kernel/fs/tests/test_images/"
```

### ext4 Image Builder

**File:** `test_images/make_ext4_img.sh`  
**Lines:** ~100

Similar to ext3 but with ext4 features:

```bash
#!/bin/bash
# Generate ext4 test images for Zigix filesystem testing

set -euo pipefail

IMG_SIZE_MB=128
BLOCK_SIZE=4096

# === Image 1: ext4 with extents ===
echo "Creating ext4-extents.img..."
dd if=/dev/zero of=ext4-extents.img bs=1M count=$IMG_SIZE_MB 2>/dev/null
mkfs.ext4 -b $BLOCK_SIZE ext4-extents.img
MOUNT_DIR=$(mktemp -d)
sudo mount ext4-extents.img "$MOUNT_DIR"

# Create large file to exercise extent tree
sudo dd if=/dev/urandom of="$MOUNT_DIR/bigfile" bs=1M count=50 2>/dev/null
# Create many small files
for i in $(seq 1 100); do
    echo "Small file $i" | sudo tee "$MOUNT_DIR/small_$i.txt" > /dev/null
done
sudo umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
echo "  → ext4-extents.img ready"

# === Image 2: ext4 with large directory (HTree) ===
echo "Creating ext4-htree.img..."
dd if=/dev/zero of=ext4-htree.img bs=1M count=$IMG_SIZE_MB 2>/dev/null
mkfs.ext4 -b $BLOCK_SIZE ext4-htree.img
MOUNT_DIR=$(mktemp -d)
sudo mount ext4-htree.img "$MOUNT_DIR"
sudo mkdir "$MOUNT_DIR/bigdir"
for i in $(seq 1 5000); do
    sudo touch "$MOUNT_DIR/bigdir/file_$(printf '%05d' $i).txt"
done
sudo umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
echo "  → ext4-htree.img ready (5000 files in directory)"

# === Image 3: ext4 without extents (compatibility mode) ===
echo "Creating ext4-noextents.img..."
dd if=/dev/zero of=ext4-noextents.img bs=1M count=$IMG_SIZE_MB 2>/dev/null
mkfs.ext4 -O ^extents -b $BLOCK_SIZE ext4-noextents.img
MOUNT_DIR=$(mktemp -d)
sudo mount ext4-noextents.img "$MOUNT_DIR"
echo "Test without extents" | sudo tee "$MOUNT_DIR/test.txt" > /dev/null
sudo umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
echo "  → ext4-noextents.img ready (block map mode)"

# === Image 4: ext4 with 64-bit block groups ===
echo "Creating ext4-64bit.img..."
dd if=/dev/zero of=ext4-64bit.img bs=1M count=$IMG_SIZE_MB 2>/dev/null
mkfs.ext4 -O 64bit -b $BLOCK_SIZE ext4-64bit.img
echo "  → ext4-64bit.img ready"

echo ""
echo "Verification:"
for img in ext4-*.img; do
    echo "  $img: $(du -h "$img" | cut -f1)"
    tune2fs -l "$img" 2>/dev/null | grep -E "(Filesystem features|Inode size|Block size)" | sed 's/^/    /'
done
```

---

## Test Strategy

### Unit Tests (run as part of kernel build)

Each `test_*.zig` file contains kernel-level tests that operate on the actual data structures:

```zig
// test_checksums.zig
const crc32c = @import("../common/crc32c.zig");

test "CRC32c IETF test vector" {
    const result = crc32c.compute("123456789");
    try std.testing.expectEqual(@as(u32, 0xE3069283), result);
}

test "CRC32c empty string" {
    const result = crc32c.compute("");
    try std.testing.expectEqual(@as(u32, 0x00000000), result);
}
```

### Integration Tests (run against test images)

Mount test images in Zigix (QEMU), verify:

1. **ext3-clean.img**: Mounts without replay, files readable
2. **ext3-dirty.img**: Journal replays on mount, files intact after replay
3. **ext4-extents.img**: Large file reads correctly, extent tree navigated
4. **ext4-htree.img**: All 5000 files found via HTree lookup
5. **ext4-noextents.img**: Falls back to block map mode correctly
6. **ext4-64bit.img**: 64-bit block group descriptors parsed correctly

### Cross-check with Linux

For any test image, you can verify Zigix's behavior against Linux:

```bash
# Dump ext4 extent tree on Linux
debugfs ext4-extents.img -R 'extent_open /bigfile'

# Dump block group descriptors  
dumpe2fs ext4-64bit.img | head -50

# Check HTree structure
debugfs ext4-htree.img -R 'htree_dump /bigdir'

# Verify journal state
debugfs ext3-dirty.img -R 'logdump'
```

Compare this output against what Zigix reports to find discrepancies.
