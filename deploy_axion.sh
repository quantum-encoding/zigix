#!/bin/bash
# Deploy and test Zigix on Google Cloud C4A (Axion / Neoverse N2).
#
# This script:
#   1. Creates a C4A Axion instance with your exact GCP config
#   2. Installs QEMU on the instance
#   3. Builds the kernel targeting neoverse-n2
#   4. Cross-compiles userspace for aarch64-linux-musl
#   5. Uploads kernel + disk image
#   6. Runs Zigix under QEMU with KVM passthrough (native N2 speed)
#
# Usage:
#   ./deploy_axion.sh              # Create instance + build + deploy + run
#   ./deploy_axion.sh create       # Just create the instance
#   ./deploy_axion.sh setup        # Install QEMU on existing instance
#   ./deploy_axion.sh build        # Just build kernel + userspace locally
#   ./deploy_axion.sh deploy       # Upload kernel + image to instance
#   ./deploy_axion.sh run          # Run Zigix on the instance
#   ./deploy_axion.sh ssh          # SSH into the instance
#   ./deploy_axion.sh teardown     # Delete the instance
#
# Environment overrides:
#   INSTANCE  — instance name (default: zigix-axion)
#   ZONE      — GCE zone (default: europe-west4-a)
#   CORES     — vCPU count: 1, 2, 4, 8... (default: 1)
#   SMP       — QEMU SMP count for Zigix (default: 2)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# --- GCP Configuration ---
PROJECT="${PROJECT:-YOUR_PROJECT_ID}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com}"
INSTANCE="${INSTANCE:-zigix-axion}"
ZONE="${ZONE:-europe-west4-a}"
REGION="${ZONE%-*}"    # europe-west4 from europe-west4-a
CORES="${CORES:-1}"
SMP="${SMP:-2}"
MACHINE="c4a-standard-${CORES}"
IMAGE="projects/ubuntu-os-pro-cloud/global/images/ubuntu-minimal-pro-2404-noble-arm64-v20260225"

KERNEL=zig-out/bin/zigix-aarch64
IMG=ext4-aarch64.img

ACTION="${1:-full}"

# ──────────────────────────────────────────────────────────────────────
# Instance lifecycle
# ──────────────────────────────────────────────────────────────────────

create_instance() {
    echo "=== Creating C4A Axion instance ==="
    echo "    Instance: $INSTANCE"
    echo "    Machine:  $MACHINE (Neoverse N2)"
    echo "    Zone:     $ZONE"
    echo "    Project:  $PROJECT"
    echo ""

    gcloud compute instances create "$INSTANCE" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --machine-type="$MACHINE" \
        --network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
        --can-ip-forward \
        --no-restart-on-failure \
        --maintenance-policy=TERMINATE \
        --provisioning-model=STANDARD \
        --service-account="$SERVICE_ACCOUNT" \
        --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/trace.append \
        --create-disk=auto-delete=yes,boot=yes,device-name="$INSTANCE",image="$IMAGE",mode=rw,provisioned-iops=3000,provisioned-throughput=140,size=10,type=hyperdisk-balanced \
        --no-shielded-secure-boot \
        --shielded-vtpm \
        --shielded-integrity-monitoring \
        --labels=goog-ec-src=vm_add-gcloud,purpose=zigix-test \
        --reservation-affinity=none

    echo ""
    echo "    Instance created. Waiting for SSH..."

    # Wait for SSH to be available
    for i in $(seq 1 20); do
        if gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" \
            --command="echo ready" 2>/dev/null; then
            echo "    SSH ready"
            return 0
        fi
        echo "    Waiting... ($i/20)"
        sleep 5
    done
    echo "    WARNING: SSH may not be ready yet, try again in a moment"
}

setup_instance() {
    echo "=== Installing QEMU on $INSTANCE ==="

    gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" --command="
        sudo apt-get update -qq
        sudo apt-get install -y -qq qemu-system-arm
        echo ''
        echo 'QEMU version:'
        qemu-system-aarch64 --version | head -1
        echo ''
        echo 'CPU info:'
        lscpu | grep -E 'Model name|Architecture|CPU\(s\):|Flags'
        echo ''
        echo 'KVM available:'
        ls -la /dev/kvm 2>/dev/null || echo '  /dev/kvm not found (will use TCG)'
    "
}

teardown() {
    echo "=== Deleting instance $INSTANCE ==="
    gcloud compute instances delete "$INSTANCE" \
        --zone="$ZONE" --project="$PROJECT" --quiet
    echo "    Instance deleted"
}

# ──────────────────────────────────────────────────────────────────────
# Build
# ──────────────────────────────────────────────────────────────────────

build_kernel() {
    echo "=== Building kernel (neoverse-n2) ==="
    zig build -Darch=aarch64 -Dcpu=neoverse_n2
    echo "    Kernel: $(ls -lh $KERNEL | awk '{print $5}') ELF aarch64"
}

build_userspace() {
    echo "=== Building userspace ==="
    EXTRA_DIR=$(mktemp -d)

    for prog in zsh zinit zlogin zping zcurl zgrep zbench zhttpd zsshd; do
        src="$SCRIPT_DIR/userspace/$prog"
        [ -d "$src" ] || continue
        echo "  Building $prog..."
        (cd "$src" && zig build -Darch=aarch64 2>/dev/null) || {
            echo "  WARN: $prog failed, skipping"
            continue
        }
        bin="$src/zig-out/bin/${prog}-aarch64"
        [ -f "$bin" ] && cp "$bin" "$EXTRA_DIR/$prog"
    done

    # Add pre-built zigix-chat if available
    if [ -f "$HOME/zigix-chat" ]; then
        cp "$HOME/zigix-chat" "$EXTRA_DIR/zigix-chat"
        chmod +x "$EXTRA_DIR/zigix-chat"
        echo "  Added: zigix-chat (pre-built)"
    fi

    # Add BusyBox if available (provides 400+ Unix utilities)
    if [ -f "$HOME/busybox" ]; then
        cp "$HOME/busybox" "$EXTRA_DIR/busybox"
        chmod +x "$EXTRA_DIR/busybox"
        echo "  Added: busybox ($(ls -lh $HOME/busybox | awk '{print $5}'))"
    fi

    bin_count=$(ls "$EXTRA_DIR" 2>/dev/null | wc -l | tr -d ' ')
    echo "    $bin_count binaries ready"

    SHELL_BIN="$EXTRA_DIR/zsh"
    if [ ! -f "$SHELL_BIN" ]; then
        echo "ERROR: zsh binary not found"
        rm -rf "$EXTRA_DIR"
        exit 1
    fi

    echo "=== Creating disk image ==="
    SCRIPTS_DIR="$SCRIPT_DIR/test_scripts"
    # Add API key at root level (make_ext4_img copies flat files from scripts_dir to /)
    if [ -f "$HOME/anthropic_key" ]; then
        cp "$HOME/anthropic_key" "$SCRIPTS_DIR/anthropic_key"
    fi
    ZIG_AARCH64_DIR="${ZIG_AARCH64_DIR:-/tmp/zig-linux-aarch64}"
    if [ -f "$ZIG_AARCH64_DIR/zig" ] && [ -d "$ZIG_AARCH64_DIR/lib" ]; then
        ZIG_TREE=$(mktemp -d)
        cp "$ZIG_AARCH64_DIR/zig" "$ZIG_TREE/"
        mkdir -p "$ZIG_TREE/lib"
        rsync -a --exclude='libc/' "$ZIG_AARCH64_DIR/lib/" "$ZIG_TREE/lib/"
        mkdir -p "$ZIG_TREE/lib/libc/include"
        rsync -a "$ZIG_AARCH64_DIR/lib/libc/musl/" "$ZIG_TREE/lib/libc/musl/" 2>/dev/null || true
        rsync -a "$ZIG_AARCH64_DIR/lib/libc/include/generic-musl/" "$ZIG_TREE/lib/libc/include/generic-musl/" 2>/dev/null || true
        rsync -a "$ZIG_AARCH64_DIR/lib/libc/include/aarch64-linux-musl/" "$ZIG_TREE/lib/libc/include/aarch64-linux-musl/" 2>/dev/null || true
        rsync -a "$ZIG_AARCH64_DIR/lib/libc/include/any-linux-any/" "$ZIG_TREE/lib/libc/include/any-linux-any/" 2>/dev/null || true
        python3 "$SCRIPT_DIR/make_ext4_img.py" "$IMG" "$SHELL_BIN" "$EXTRA_DIR" "$SCRIPTS_DIR" "$ZIG_TREE"
        rm -rf "$ZIG_TREE"
    else
        python3 "$SCRIPT_DIR/make_ext4_img.py" "$IMG" "$SHELL_BIN" "$EXTRA_DIR" "$SCRIPTS_DIR"
    fi
    echo "    Image: $(ls -lh $IMG | awk '{print $5}')"

    rm -rf "$EXTRA_DIR"
}

# ──────────────────────────────────────────────────────────────────────
# Deploy and run
# ──────────────────────────────────────────────────────────────────────

deploy() {
    echo "=== Deploying to $INSTANCE ($ZONE) ==="

    # Upload kernel
    echo "  Uploading kernel..."
    gcloud compute scp "$KERNEL" "$INSTANCE:~/zigix-aarch64" \
        --zone="$ZONE" --project="$PROJECT"

    # Upload disk image
    if [ -f "$IMG" ]; then
        echo "  Uploading disk image..."
        gcloud compute scp "$IMG" "$INSTANCE:~/ext4-aarch64.img" \
            --zone="$ZONE" --project="$PROJECT"
    fi

    # Create the run script on the instance
    echo "  Creating run script..."
    gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" --command='
cat > ~/run_zigix.sh << '\''RUNEOF'\''
#!/bin/bash
# Run Zigix on real Neoverse N2 hardware via QEMU
KERNEL=$HOME/zigix-aarch64
IMG=$HOME/ext4-aarch64.img
SMP=${SMP:-'"$SMP"'}

echo "=== Zigix on Google Axion (Neoverse N2) ==="
echo "CPU: $(lscpu | grep "Model name" | sed "s/.*: *//")"
echo "Cores available: $(nproc)"
echo "QEMU SMP: $SMP"
echo ""

# KVM passthrough — real hardware, no emulation
if [ -e /dev/kvm ]; then
    ACCEL="-accel kvm"
    QEMU_CPU="host"
    echo "Using KVM acceleration (native speed)"
else
    ACCEL="-accel tcg"
    QEMU_CPU="neoverse-n2"
    echo "KVM not available, using TCG with neoverse-n2 emulation"
fi

# Disk image (optional — kernel has inline test if no image)
DISK_ARGS=""
if [ -f "$IMG" ]; then
    DISK_ARGS="-drive file=$IMG,format=raw,if=none,id=disk0 -device virtio-blk-device,drive=disk0"
    echo "Disk image: $(ls -lh $IMG | awk "{print \$5}")"
fi

echo "========================================"
echo "Press Ctrl-A X to exit QEMU"
echo ""

exec qemu-system-aarch64 \
    -M virt,gic-version=max \
    -cpu $QEMU_CPU \
    $ACCEL \
    -m 2G \
    -smp $SMP \
    -kernel $KERNEL \
    $DISK_ARGS \
    -device virtio-net-device,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8080-:80 \
    -serial mon:stdio \
    -display none \
    -no-reboot
RUNEOF
chmod +x ~/run_zigix.sh
'
    echo "    Deploy complete"
}

run_on_instance() {
    echo "=== Running Zigix on $INSTANCE ==="
    gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT" \
        -- -t "~/run_zigix.sh"
}

ssh_to_instance() {
    gcloud compute ssh "$INSTANCE" --zone="$ZONE" --project="$PROJECT"
}

# ──────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────

case "$ACTION" in
    full)
        create_instance
        setup_instance
        build_kernel
        build_userspace
        deploy
        run_on_instance
        ;;
    create)
        create_instance
        setup_instance
        ;;
    setup)
        setup_instance
        ;;
    build)
        build_kernel
        build_userspace
        ;;
    deploy)
        deploy
        ;;
    run)
        run_on_instance
        ;;
    ssh)
        ssh_to_instance
        ;;
    teardown)
        teardown
        ;;
    *)
        echo "Zigix Axion Deploy Script"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  full      Create instance + setup + build + deploy + run (default)"
        echo "  create    Create GCE instance and install QEMU"
        echo "  setup     Install QEMU on existing instance"
        echo "  build     Build kernel + userspace locally"
        echo "  deploy    Upload kernel + image to instance"
        echo "  run       Run Zigix on the instance"
        echo "  ssh       SSH into the instance"
        echo "  teardown  Delete the instance"
        echo ""
        echo "Environment:"
        echo "  INSTANCE=$INSTANCE"
        echo "  ZONE=$ZONE"
        echo "  CORES=$CORES (machine: $MACHINE)"
        echo "  SMP=$SMP (QEMU vCPUs for Zigix)"
        echo "  PROJECT=$PROJECT"
        exit 1
        ;;
esac
