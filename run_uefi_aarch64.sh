#!/bin/bash
# Zigix ARM64 UEFI Boot — QEMU Test Script
#
# Builds the kernel + UEFI bootloader, creates an ESP directory,
# and launches QEMU with AAVMF firmware.
#
# Usage: bash run_uefi_aarch64.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL=zig-out/bin/zigix-aarch64
BOOTLOADER=bootloader/zig-out/bin/BOOTAA64.efi
UEFI_FW=/usr/share/edk2/aarch64/QEMU_EFI.fd
ESP_DIR=$(mktemp -d)
trap "rm -rf $ESP_DIR" EXIT

echo "========================================"
echo "  Zigix ARM64 UEFI Boot"
echo "========================================"
echo ""

# Check UEFI firmware
if [ ! -f "$UEFI_FW" ]; then
    echo "ERROR: UEFI firmware not found at $UEFI_FW"
    echo "Install with: pacman -S edk2-aarch64"
    exit 1
fi

# Step 1: Build kernel
echo "[1/4] Building ARM64 kernel..."
zig build -Darch=aarch64

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: Kernel not found at $KERNEL"
    exit 1
fi

# Step 2: Build bootloader
echo "[2/4] Building UEFI bootloader..."
(cd bootloader && zig build)

if [ ! -f "$BOOTLOADER" ]; then
    echo "ERROR: Bootloader not found at $BOOTLOADER"
    exit 1
fi

# Step 3: Create ESP directory structure
echo "[3/4] Creating ESP..."
mkdir -p "$ESP_DIR/EFI/BOOT"
mkdir -p "$ESP_DIR/zigix"
cp "$BOOTLOADER" "$ESP_DIR/EFI/BOOT/BOOTAA64.EFI"
cp "$KERNEL" "$ESP_DIR/zigix/zigix-aarch64"

echo "  ESP layout:"
echo "    /EFI/BOOT/BOOTAA64.EFI  ($(stat -c%s "$BOOTLOADER") bytes)"
echo "    /zigix/zigix-aarch64     ($(stat -c%s "$KERNEL") bytes)"

# Step 4: Build ext2 disk image (reuse existing or build via make_ext2_img.sh)
DISK_ARGS=""
if [ -f "ext2-aarch64.img" ]; then
    DISK_ARGS="-drive file=ext2-aarch64.img,format=raw,if=none,id=disk0 -device virtio-blk-device,drive=disk0"
    echo "  Disk: ext2-aarch64.img attached (existing)"
elif [ -f "make_ext2_img.sh" ]; then
    echo "[3.5/4] Building ext2 disk image..."
    bash make_ext2_img.sh 2>&1 | sed 's/^/    /'
    if [ -f "ext2-aarch64.img" ]; then
        DISK_ARGS="-drive file=ext2-aarch64.img,format=raw,if=none,id=disk0 -device virtio-blk-device,drive=disk0"
        echo "  Disk: ext2-aarch64.img attached"
    fi
fi

# Step 5: Launch QEMU with UEFI firmware
echo "[4/4] Launching QEMU UEFI..."
echo ""
echo "  QEMU: aarch64 virt, cortex-a72, 2GB RAM, 2 CPUs"
echo "  Firmware: $UEFI_FW"
echo "  Press Ctrl-A X to exit QEMU"
echo ""

qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -cpu cortex-a72 \
    -m 2G \
    -smp 2 \
    -bios "$UEFI_FW" \
    -drive "file=fat:rw:${ESP_DIR},format=vvfat,if=virtio" \
    $DISK_ARGS \
    -serial mon:stdio \
    -display none \
    -no-reboot
