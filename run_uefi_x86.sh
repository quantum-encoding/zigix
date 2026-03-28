#!/bin/bash
# Zigix x86_64 UEFI Boot — QEMU Test Script
#
# Builds the kernel + UEFI bootloader, creates an ESP directory,
# and launches QEMU with OVMF firmware.
#
# Usage: bash run_uefi_x86.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL=zig-out/bin/zigix
BOOTLOADER=bootloader_x86/zig-out/bin/BOOTX64.efi
UEFI_FW=/usr/share/edk2/x64/OVMF.4m.fd
ESP_DIR=$(mktemp -d)
trap "rm -rf $ESP_DIR" EXIT

echo "========================================"
echo "  Zigix x86_64 UEFI Boot"
echo "========================================"
echo ""

# Check UEFI firmware
if [ ! -f "$UEFI_FW" ]; then
    echo "ERROR: OVMF firmware not found at $UEFI_FW"
    echo "Install with: pacman -S edk2-ovmf"
    exit 1
fi

# Step 1: Build kernel
echo "[1/4] Building x86_64 kernel..."
zig build

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: Kernel not found at $KERNEL"
    exit 1
fi

# Step 2: Build bootloader
echo "[2/4] Building UEFI bootloader..."
(cd bootloader_x86 && zig build)

if [ ! -f "$BOOTLOADER" ]; then
    echo "ERROR: Bootloader not found at $BOOTLOADER"
    exit 1
fi

# Step 3: Create ESP directory structure
echo "[3/4] Creating ESP..."
mkdir -p "$ESP_DIR/EFI/BOOT"
mkdir -p "$ESP_DIR/zigix"
cp "$BOOTLOADER" "$ESP_DIR/EFI/BOOT/BOOTX64.EFI"
cp "$KERNEL" "$ESP_DIR/zigix/zigix"

echo "  ESP layout:"
echo "    /EFI/BOOT/BOOTX64.EFI  ($(stat -c%s "$BOOTLOADER") bytes)"
echo "    /zigix/zigix            ($(stat -c%s "$KERNEL") bytes)"

# Step 4: Attach disk image if available
DISK_ARGS=""
if [ -f "ext2.img" ]; then
    DISK_ARGS="-drive file=ext2.img,format=raw,if=virtio"
    echo "  Disk: ext2.img attached"
elif [ -f "make_ext2_img.sh" ] && [ -f "ext2-aarch64.img" ]; then
    # x86 disk image not found, skip
    echo "  No x86 disk image found (ext2.img)"
fi

# Step 5: Launch QEMU with OVMF firmware
echo "[4/4] Launching QEMU UEFI..."
echo ""
echo "  QEMU: x86_64, Haswell, 2GB RAM"
echo "  Firmware: $UEFI_FW"
echo "  Press Ctrl-A X to exit QEMU"
echo ""

qemu-system-x86_64 \
    -cpu Haswell \
    -m 2G \
    -bios "$UEFI_FW" \
    -drive "file=fat:rw:${ESP_DIR},format=vvfat,if=virtio" \
    $DISK_ARGS \
    -serial mon:stdio \
    -display none \
    -no-reboot
