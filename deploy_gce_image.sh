#!/bin/bash
# Build, package, and deploy Zigix as a native GCE custom image.
#
# This creates a GPT disk image with ESP + ext4 root, uploads it to
# Cloud Storage, and imports it as a GCE custom image with UEFI boot.
#
# Usage:
#   ./deploy_gce_image.sh              # Full: build + package + upload + create image
#   ./deploy_gce_image.sh build        # Build kernel + bootloader + disk image
#   ./deploy_gce_image.sh package      # Create tar.gz from existing disk.raw
#   ./deploy_gce_image.sh upload       # Upload to GCS + create image
#   ./deploy_gce_image.sh test-qemu    # Test UEFI boot locally in QEMU on VM
#   ./deploy_gce_image.sh boot         # Create instance from custom image
#
# Environment:
#   BUCKET    — GCS bucket for image upload (default: zigix-images)
#   IMAGE     — GCE image name (default: zigix-arm64-YYYYMMDD)
#   INSTANCE  — Instance name for boot test (default: zigix-native)
#   ZONE      — GCE zone (default: europe-west4-a)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${PROJECT:-YOUR_PROJECT_ID}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com}"
BUCKET="${BUCKET:-YOUR_BUCKET}"
IMAGE="${IMAGE:-zigix-arm64-$(date +%Y%m%d)}"
INSTANCE="${INSTANCE:-zigix-native}"
ZONE="${ZONE:-europe-west4-a}"
VM_TEST="${VM_TEST:-zigix-axion-ext4-testing}"

KERNEL=zig-out/bin/zigix-aarch64
BOOTLOADER=bootloader/zig-out/bin/BOOTAA64.efi
EXT4_IMG=ext4-aarch64.img
DISK_RAW=disk.raw

ACTION="${1:-full}"

build_all() {
    echo "========================================"
    echo "  Zigix GCE Image Builder"
    echo "========================================"
    echo ""

    # Step 1: Build kernel
    echo "[1/5] Building ARM64 kernel..."
    zig build -Darch=aarch64
    echo "       Kernel: $(ls -lh $KERNEL | awk '{print $5}')"

    # Step 2: Build bootloader
    echo "[2/5] Building UEFI bootloader..."
    (cd bootloader && zig build)
    echo "       Bootloader: $(ls -lh $BOOTLOADER | awk '{print $5}')"

    # Step 3: Build userspace + ext4 root image
    echo "[3/5] Building userspace..."
    EXTRA_DIR=$(mktemp -d)
    trap "rm -rf $EXTRA_DIR" EXIT

    for prog in zsh zinit zlogin zping zcurl zgrep zbench zhttpd zsshd; do
        src="$SCRIPT_DIR/userspace/$prog"
        [ -d "$src" ] || continue
        (cd "$src" && zig build -Darch=aarch64 2>/dev/null) || continue
        bin="$src/zig-out/bin/${prog}-aarch64"
        [ -f "$bin" ] && cp "$bin" "$EXTRA_DIR/$prog"
    done
    echo "       $(ls "$EXTRA_DIR" 2>/dev/null | wc -l | tr -d ' ') binaries"

    echo "[4/5] Creating ext4 root filesystem..."
    SHELL_BIN="$EXTRA_DIR/zsh"
    # Zig compiler tree: ZIG_AARCH64_DIR env var points to zig-aarch64-linux distribution
    ZIG_TREE="${ZIG_AARCH64_DIR:-}"
    if [ -f "$SHELL_BIN" ]; then
        if [ -n "$ZIG_TREE" ] && [ -d "$ZIG_TREE" ]; then
            echo "       Including Zig compiler from $ZIG_TREE"
            python3 make_ext4_img.py "$EXT4_IMG" "$SHELL_BIN" "$EXTRA_DIR" "" "$ZIG_TREE"
        else
            python3 make_ext4_img.py "$EXT4_IMG" "$SHELL_BIN" "$EXTRA_DIR"
        fi
    else
        python3 make_ext4_img.py "$EXT4_IMG"
    fi
    echo "       Root FS: $(ls -lh $EXT4_IMG | awk '{print $5}')"

    # Step 4: Create GPT disk image
    echo "[5/5] Creating GPT disk image..."
    python3 make_gce_disk.py "$DISK_RAW" "$BOOTLOADER" "$KERNEL" "$EXT4_IMG"
    echo "       Disk: $(ls -lh $DISK_RAW | awk '{print $5}')"
}

package_image() {
    echo "=== Packaging disk image ==="
    if [ ! -f "$DISK_RAW" ]; then
        echo "ERROR: $DISK_RAW not found. Run 'build' first."
        exit 1
    fi
    tar -czf zigix-arm64.tar.gz "$DISK_RAW"
    echo "    Archive: $(ls -lh zigix-arm64.tar.gz | awk '{print $5}')"
}

upload_image() {
    echo "=== Uploading to GCS ==="

    # Ensure bucket exists
    gsutil ls "gs://$BUCKET/" 2>/dev/null || {
        echo "  Creating bucket gs://$BUCKET/..."
        gsutil mb -p "$PROJECT" -l europe-west4 "gs://$BUCKET/"
    }

    echo "  Uploading zigix-arm64.tar.gz..."
    gsutil cp zigix-arm64.tar.gz "gs://$BUCKET/zigix-arm64.tar.gz"

    echo "  Creating GCE image: $IMAGE..."
    gcloud compute images create "$IMAGE" \
        --project="$PROJECT" \
        --source-uri="gs://$BUCKET/zigix-arm64.tar.gz" \
        --guest-os-features=UEFI_COMPATIBLE \
        --architecture=ARM64 \
        --description="Zigix ARM64 bare-metal OS ($(date +%Y-%m-%d))"

    echo ""
    echo "    Image created: $IMAGE"
    echo "    To boot: gcloud compute instances create $INSTANCE \\"
    echo "        --image=$IMAGE --machine-type=c4a-standard-1 \\"
    echo "        --zone=$ZONE --project=$PROJECT"
}

test_qemu_uefi() {
    echo "=== Testing UEFI boot on $VM_TEST ==="

    if [ ! -f "$DISK_RAW" ]; then
        echo "ERROR: $DISK_RAW not found. Run 'build' first."
        exit 1
    fi

    # Upload disk image to test VM
    echo "  Uploading disk image..."
    gcloud compute scp "$DISK_RAW" "$VM_TEST:~/disk.raw" \
        --zone="$ZONE" --project="$PROJECT"

    # Run QEMU with UEFI firmware
    echo "  Starting QEMU UEFI boot..."
    echo "  (Press Ctrl-A X to exit)"
    echo ""

    gcloud compute ssh "$VM_TEST" --zone="$ZONE" --project="$PROJECT" -- -t '
        UEFI_FW=$(ls /usr/share/qemu-efi-aarch64/QEMU_EFI.fd 2>/dev/null || \
                   ls /usr/share/edk2/aarch64/QEMU_EFI.fd 2>/dev/null)
        if [ -z "$UEFI_FW" ]; then
            echo "ERROR: No UEFI firmware found"
            exit 1
        fi
        echo "UEFI firmware: $UEFI_FW"

        qemu-system-aarch64 \
            -M virt,gic-version=3 \
            -cpu cortex-a72 \
            -m 2G \
            -smp 2 \
            -bios "$UEFI_FW" \
            -drive file=$HOME/disk.raw,format=raw,if=virtio \
            -serial mon:stdio \
            -display none \
            -no-reboot
    '
}

boot_instance() {
    echo "=== Booting Zigix on GCE ==="

    gcloud compute instances create "$INSTANCE" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --machine-type=c4a-standard-1 \
        --network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
        --no-restart-on-failure \
        --maintenance-policy=TERMINATE \
        --provisioning-model=STANDARD \
        --service-account="$SERVICE_ACCOUNT" \
        --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write \
        --image="$IMAGE" \
        --no-shielded-secure-boot \
        --shielded-vtpm \
        --shielded-integrity-monitoring \
        --labels=purpose=zigix-native

    echo ""
    echo "  Instance created. Serial console:"
    echo "  gcloud compute connect-to-serial-port $INSTANCE --zone=$ZONE --project=$PROJECT"
}

case "$ACTION" in
    full)
        build_all
        package_image
        upload_image
        ;;
    build)
        build_all
        ;;
    package)
        package_image
        ;;
    upload)
        package_image
        upload_image
        ;;
    test-qemu)
        test_qemu_uefi
        ;;
    boot)
        boot_instance
        ;;
    *)
        echo "Zigix GCE Image Deploy"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  full       Build + package + upload + create image (default)"
        echo "  build      Build kernel + bootloader + disk image"
        echo "  package    Create tar.gz from disk.raw"
        echo "  upload     Upload to GCS + create GCE image"
        echo "  test-qemu  Test UEFI boot in QEMU on test VM"
        echo "  boot       Create GCE instance from custom image"
        echo ""
        echo "Environment:"
        echo "  BUCKET=$BUCKET"
        echo "  IMAGE=$IMAGE"
        echo "  INSTANCE=$INSTANCE"
        echo "  ZONE=$ZONE"
        exit 1
        ;;
esac
