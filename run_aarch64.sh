#!/bin/bash
# Build and run Zigix on ARM64 (aarch64) with QEMU virt machine.
# Builds kernel + freestanding userspace, creates ext4 image, launches QEMU.
# Port forwarding: host 8080 → guest 80 (zhttpd)
#
# CPU profile selection (controls both build target and QEMU CPU model):
#   CPU=generic      — ARMv8.0 baseline (default, safe for any ARM64)
#   CPU=cortex-a72   — ARMv8.0 (QEMU default, RPi 4)
#   CPU=neoverse-n1  — ARMv8.2 (Graviton2, Ampere Altra)
#   CPU=neoverse-n2  — ARMv9.0 (Google Axion, Graviton3+)
#   CPU=neoverse-v2  — ARMv9.0 (high-perf server)
#
# Zig compiler: Set ZIG_AARCH64_DIR to include the Zig compiler on disk.
#   export ZIG_AARCH64_DIR=/tmp/zig-linux-aarch64
# The directory should contain 'zig' binary and optionally 'lib/' tree.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL=zig-out/bin/zigix-aarch64
IMG=ext4-aarch64.img

# CPU profile: map user-facing names to build system / QEMU names
CPU="${CPU:-generic}"
case "$CPU" in
    generic)      BUILD_CPU="generic";     QEMU_CPU="cortex-a57" ;;
    cortex-a72)   BUILD_CPU="cortex_a72";  QEMU_CPU="cortex-a72" ;;
    neoverse-n1)  BUILD_CPU="neoverse_n1"; QEMU_CPU="neoverse-n1" ;;
    neoverse-n2)  BUILD_CPU="neoverse_n2"; QEMU_CPU="neoverse-n2" ;;
    neoverse-v2)  BUILD_CPU="neoverse_v2"; QEMU_CPU="max" ;;
    *)            echo "Unknown CPU profile: $CPU"; exit 1 ;;
esac

# 1. Build ARM64 kernel
echo "[1/5] Building ARM64 kernel (cpu=$CPU)..."
zig build -Darch=aarch64 -Dcpu="$BUILD_CPU"
echo "       Kernel: $(ls -lh $KERNEL | awk '{print $5}') ELF aarch64"

# 2. Build freestanding userspace programs for aarch64
echo "[2/5] Building userspace programs..."
EXTRA_DIR=$(mktemp -d)
trap "rm -rf $EXTRA_DIR" EXIT

for prog in zsh zinit zlogin zping zcurl zgrep zbench zhttpd zsshd; do
    src="$SCRIPT_DIR/userspace/$prog"
    [ -d "$src" ] || continue
    echo "  Building $prog (aarch64)..."
    (cd "$src" && zig build -Darch=aarch64 2>/dev/null) || {
        echo "  WARN: $prog failed to build, skipping"
        continue
    }
    bin="$src/zig-out/bin/${prog}-aarch64"
    if [ -f "$bin" ]; then
        # Copy with the name WITHOUT the -aarch64 suffix
        # (the kernel expects /mnt/bin/zinit, /mnt/bin/zsh, etc.)
        cp "$bin" "$EXTRA_DIR/$prog"
    fi
done

bin_count=$(ls "$EXTRA_DIR" 2>/dev/null | wc -l | tr -d ' ')
echo "       $bin_count binaries ready"

# Use zsh as the shell binary (required by make_ext2_img.py)
SHELL_BIN="$EXTRA_DIR/zsh"
if [ ! -f "$SHELL_BIN" ]; then
    echo "ERROR: zsh binary not found"
    exit 1
fi

# 3. Prepare Zig compiler tree for aarch64 (optional)
echo "[3/5] Preparing Zig compiler tree..."
ZIG_AARCH64_DIR="${ZIG_AARCH64_DIR:-/tmp/zig-linux-aarch64}"
ZIG_TREE=""
if [ -f "$ZIG_AARCH64_DIR/zig" ] && [ -d "$ZIG_AARCH64_DIR/lib" ]; then
    ZIG_TREE=$(mktemp -d)
    cp "$ZIG_AARCH64_DIR/zig" "$ZIG_TREE/"
    # Zig compiler expects lib/ relative to its exe directory.
    # Binary at /zig/zig → looks for /zig/lib/std/std.zig
    mkdir -p "$ZIG_TREE/lib"
    rsync -a --exclude='libc/' "$ZIG_AARCH64_DIR/lib/" "$ZIG_TREE/lib/"
    # Copy only the libc subdirs needed for aarch64-linux-musl target
    mkdir -p "$ZIG_TREE/lib/libc/include"
    rsync -a "$ZIG_AARCH64_DIR/lib/libc/musl/" "$ZIG_TREE/lib/libc/musl/" 2>/dev/null || true
    rsync -a "$ZIG_AARCH64_DIR/lib/libc/include/generic-musl/" "$ZIG_TREE/lib/libc/include/generic-musl/" 2>/dev/null || true
    rsync -a "$ZIG_AARCH64_DIR/lib/libc/include/aarch64-linux-musl/" "$ZIG_TREE/lib/libc/include/aarch64-linux-musl/" 2>/dev/null || true
    rsync -a "$ZIG_AARCH64_DIR/lib/libc/include/any-linux-any/" "$ZIG_TREE/lib/libc/include/any-linux-any/" 2>/dev/null || true
    zig_files=$(find "$ZIG_TREE" -type f | wc -l | tr -d ' ')
    zig_size=$(du -sh "$ZIG_TREE" | cut -f1)
    echo "       Zig tree: $zig_files files, $zig_size (binary + selective lib/)"
elif [ -f "$ZIG_AARCH64_DIR/zig" ]; then
    # No lib/ — just the binary
    ZIG_TREE=$(mktemp -d)
    cp "$ZIG_AARCH64_DIR/zig" "$ZIG_TREE/"
    echo "       Zig binary only ($(ls -lh "$ZIG_AARCH64_DIR/zig" | awk '{print $5}'))"
else
    echo "       Skipped (set ZIG_AARCH64_DIR to include Zig compiler)"
fi

# 4. Build ext4 image (CRC32c checksums, 256-byte inodes, extents, 64-bit BGDs)
echo "[4/5] Creating ext4 disk image..."
SCRIPTS_DIR="$SCRIPT_DIR/test_scripts"
if [ -n "$ZIG_TREE" ]; then
    python3 "$SCRIPT_DIR/make_ext4_img.py" "$IMG" "$SHELL_BIN" "$EXTRA_DIR" "$SCRIPTS_DIR" "$ZIG_TREE"
    rm -rf "$ZIG_TREE"
else
    python3 "$SCRIPT_DIR/make_ext4_img.py" "$IMG" "$SHELL_BIN" "$EXTRA_DIR" "$SCRIPTS_DIR"
fi
echo "       Image: $(ls -lh $IMG | awk '{print $5}')"

# 5. Launch QEMU
echo "[5/5] Launching QEMU aarch64 (serial output below)..."
echo "       Press Ctrl-A X to exit QEMU"
echo "       Port forwarding: host:8080 → guest:80 (zhttpd)"
echo "       Test with: curl http://localhost:8080/www/index.html"

# Block device selection: virtio-blk (default) or NVMe
# Usage: BLOCK_DEV=nvme ./run_aarch64.sh
BLOCK_DEV="${BLOCK_DEV:-virtio}"

if [ "$BLOCK_DEV" = "nvme" ]; then
    DRIVE_ARGS="-drive file=$IMG,format=raw,if=none,id=nvme0 -device nvme,drive=nvme0,serial=ZIGIX-NVME"
    echo "       Block device: NVMe (PCIe)"
else
    DRIVE_ARGS="-drive file=$IMG,format=raw,if=none,id=disk0 -device virtio-blk-device,drive=disk0"
    echo "       Block device: virtio-blk (MMIO)"
fi

echo "========================================"

SMP="${SMP:-2}"
echo "       CPU profile: $CPU (QEMU: $QEMU_CPU), SMP: $SMP"

# QEMU 7.x MTTCG has a known bug with virtio-mmio on ARM64 where the avail
# ring is not properly synchronized between vCPU threads and the I/O thread,
# causing descriptor ring corruption (0xAAAA pattern). Use single-threaded TCG
# which still emulates SMP correctly but processes vCPUs sequentially.
# Override with ACCEL=tcg for multi-threaded, or ACCEL=kvm on real hardware.
ACCEL="${ACCEL:-tcg,thread=single}"
GIC_VER="${GIC_VER:-3}"
qemu-system-aarch64 \
    -M virt,gic-version="$GIC_VER" \
    -accel "$ACCEL" \
    -cpu "$QEMU_CPU" \
    -m "${MEM:-4G}" \
    -smp "$SMP" \
    -kernel "$KERNEL" \
    $DRIVE_ARGS \
    -device virtio-net-device,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8080-:80 \
    -serial mon:stdio \
    -display none \
    -no-reboot
