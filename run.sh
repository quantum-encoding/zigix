#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL=zig-out/bin/zigix
LIMINE_DIR=limine
ISO_DIR=iso_root
ISO_FILE=zigix.iso

# Build kernel
echo "[1/4] Building kernel..."
zig build

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: Kernel binary not found at $KERNEL"
    exit 1
fi

echo "       Kernel: $(ls -lh $KERNEL | awk '{print $5}') ELF x86_64"

# Rebuild disk image (userspace programs)
echo "       Rebuilding disk image..."
bash "$SCRIPT_DIR/make_ext2_img.sh" 2>&1 | sed 's/^/       /'

# Download Limine if needed
if [ ! -d "$LIMINE_DIR" ]; then
    echo "[2/4] Downloading Limine bootloader..."
    git clone https://github.com/limine-bootloader/limine.git \
        --branch=v8.x-binary --depth=1 2>/dev/null
else
    echo "[2/4] Limine bootloader: cached"
fi

# Build limine utility if needed
if [ ! -f "$LIMINE_DIR/limine" ]; then
    echo "       Building limine utility..."
    make -C "$LIMINE_DIR" 2>/dev/null
fi

# Create ISO structure
echo "[3/4] Creating bootable ISO..."
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/limine"
mkdir -p "$ISO_DIR/EFI/BOOT"

# Copy kernel and config
cp "$KERNEL" "$ISO_DIR/boot/zigix"
cp limine.conf "$ISO_DIR/boot/limine/"

# Copy Limine binaries
cp "$LIMINE_DIR/limine-bios.sys" "$ISO_DIR/boot/limine/" 2>/dev/null || true
cp "$LIMINE_DIR/limine-bios-cd.bin" "$ISO_DIR/boot/limine/" 2>/dev/null || true
cp "$LIMINE_DIR/limine-uefi-cd.bin" "$ISO_DIR/boot/limine/" 2>/dev/null || true
cp "$LIMINE_DIR/BOOTX64.EFI" "$ISO_DIR/EFI/BOOT/" 2>/dev/null || true
cp "$LIMINE_DIR/BOOTIA32.EFI" "$ISO_DIR/EFI/BOOT/" 2>/dev/null || true

# Create ISO (requires xorriso)
if ! command -v xorriso &>/dev/null; then
    echo "ERROR: xorriso not found. Install with:"
    echo "  brew install xorriso    # macOS"
    echo "  apt install xorriso     # Debian/Ubuntu"
    exit 1
fi

xorriso -as mkisofs \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$ISO_DIR" -o "$ISO_FILE" 2>/dev/null

# Install Limine BIOS stages
"$LIMINE_DIR/limine" bios-install "$ISO_FILE" 2>/dev/null || true

echo "       ISO: $(ls -lh $ISO_FILE | awk '{print $5}')"

# Run QEMU
echo "[4/4] Launching QEMU (serial output below)..."
echo "       Press Ctrl-A X to exit QEMU"
echo "========================================"

if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found. Install with:"
    echo "  brew install qemu       # macOS"
    echo "  apt install qemu-system-x86  # Debian/Ubuntu"
    exit 1
fi

DRIVE_OPTS=""
DISK_IMG="test.img"
BLOCK_DEV="${BLOCK_DEV:-virtio}"
if [ "${1:-}" = "--ext4" ] || [ "${2:-}" = "--ext4" ]; then
    DISK_IMG="test_ext4.img"
    if [ ! -f "$DISK_IMG" ]; then
        echo "       Building ext4 image..."
        bash "$SCRIPT_DIR/make_ext4_img.sh" 2>&1 | sed 's/^/       /'
    fi
fi
if [ "${1:-}" = "--ext3" ] || [ "${2:-}" = "--ext3" ]; then
    DISK_IMG="test_ext3.img"
    if [ ! -f "$DISK_IMG" ]; then
        echo "       Building ext3 image..."
        bash "$SCRIPT_DIR/make_ext3_img.sh" 2>&1 | sed 's/^/       /'
    fi
fi
if [ -f "$DISK_IMG" ]; then
    if [ "$BLOCK_DEV" = "nvme" ]; then
        DRIVE_OPTS="-drive file=$DISK_IMG,format=raw,if=none,id=nvme0 -device nvme,drive=nvme0,serial=ZIGIX-NVME"
        echo "       nvme: $DISK_IMG attached"
    else
        DRIVE_OPTS="-drive file=$DISK_IMG,format=raw,if=virtio"
        echo "       virtio-blk: $DISK_IMG attached"
    fi
fi

NET_OPTS="-device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::8080-:80"
echo "       virtio-net: SLIRP (10.0.2.15), port 8080->80"

DISPLAY_OPTS="-display none"
for arg in "$@"; do
    if [ "$arg" = "--gui" ] || [ "$arg" = "-g" ]; then
        DISPLAY_OPTS="-display sdl"
        echo "       Display: SDL window (framebuffer console)"
    fi
done

qemu-system-x86_64 \
    -cpu Haswell \
    -cdrom "$ISO_FILE" \
    $DRIVE_OPTS \
    $NET_OPTS \
    -serial stdio \
    $DISPLAY_OPTS \
    -no-reboot \
    -no-shutdown \
    -m 2G
