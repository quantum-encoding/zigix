#!/bin/bash
# Zigix automated test runner — builds, boots, runs tests, captures output, exits.
#
# Usage:
#   bash test.sh              # test with ext2 (default)
#   bash test.sh --ext3       # test with ext3 image
#   bash test.sh --ext4       # test with ext4 image
#   bash test.sh --quick      # skip disk image rebuild
#
# Output:
#   test-logs/test_YYYYMMDD_HHMMSS.log   — full serial + terminal output
#   Exit code 0 on success, 1 on build failure, 2 on timeout

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# --- Configuration ---
TIMEOUT_SECS=180          # Max seconds to wait for all tests (zig binary is 70MB)
BOOT_WAIT=5               # Seconds to wait for kernel boot
LOGIN_WAIT=2              # Seconds after login prompt
CMD_DELAY=0.3             # Seconds between commands
FS_TYPE="ext2"
SKIP_BUILD=false

for arg in "$@"; do
    case "$arg" in
        --ext3) FS_TYPE="ext3" ;;
        --ext4) FS_TYPE="ext4" ;;
        --quick) SKIP_BUILD=true ;;
    esac
done

# --- Log setup ---
mkdir -p test-logs
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGFILE="test-logs/test_${TIMESTAMP}_${FS_TYPE}.log"

header() {
    echo "========================================" | tee -a "$LOGFILE"
    echo "$1" | tee -a "$LOGFILE"
    echo "========================================" | tee -a "$LOGFILE"
}

log() {
    echo "[test] $1" | tee -a "$LOGFILE"
}

# --- Build phase ---
header "Zigix Test Run — $(date) — $FS_TYPE"

if [ "$SKIP_BUILD" = false ]; then
    log "Building kernel..."
    if ! zig build 2>&1 | tee -a "$LOGFILE"; then
        log "FATAL: Kernel build failed"
        exit 1
    fi

    log "Building disk image ($FS_TYPE)..."
    case "$FS_TYPE" in
        ext2) bash make_ext2_img.sh 2>&1 | tee -a "$LOGFILE" ;;
        ext3) bash make_ext3_img.sh 2>&1 | tee -a "$LOGFILE" ;;
        ext4) bash make_ext4_img.sh 2>&1 | tee -a "$LOGFILE" ;;
    esac
else
    log "Skipping build (--quick)"
fi

# --- Determine disk image ---
case "$FS_TYPE" in
    ext2) DISK_IMG="test.img" ;;
    ext3) DISK_IMG="test_ext3.img" ;;
    ext4) DISK_IMG="test_ext4.img" ;;
esac

if [ ! -f "$DISK_IMG" ]; then
    log "FATAL: Disk image $DISK_IMG not found"
    exit 1
fi

# --- Ensure ISO exists ---
KERNEL=zig-out/bin/zigix
ISO_FILE=zigix.iso
LIMINE_DIR=limine

if [ ! -f "$ISO_FILE" ] || [ "$SKIP_BUILD" = false ]; then
    log "Creating bootable ISO..."
    ISO_DIR=iso_root
    if [ -d "$ISO_DIR" ]; then
        sudo rm -rf "$ISO_DIR"
    fi
    mkdir -p "$ISO_DIR/boot/limine" "$ISO_DIR/EFI/BOOT"
    cp "$KERNEL" "$ISO_DIR/boot/zigix"
    cp limine.conf "$ISO_DIR/boot/limine/"
    cp "$LIMINE_DIR/limine-bios.sys" "$ISO_DIR/boot/limine/" 2>/dev/null || true
    cp "$LIMINE_DIR/limine-bios-cd.bin" "$ISO_DIR/boot/limine/" 2>/dev/null || true
    cp "$LIMINE_DIR/limine-uefi-cd.bin" "$ISO_DIR/boot/limine/" 2>/dev/null || true
    cp "$LIMINE_DIR/BOOTX64.EFI" "$ISO_DIR/EFI/BOOT/" 2>/dev/null || true
    cp "$LIMINE_DIR/BOOTIA32.EFI" "$ISO_DIR/EFI/BOOT/" 2>/dev/null || true
    xorriso -as mkisofs \
        -b boot/limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --efi-boot boot/limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        "$ISO_DIR" -o "$ISO_FILE" 2>/dev/null
    "$LIMINE_DIR/limine" bios-install "$ISO_FILE" 2>/dev/null || true
fi

# --- Test commands ---
# These get fed to the shell via QEMU's serial stdin.
# Each line is sent with a small delay to let the shell process it.
TEST_COMMANDS=$(cat <<'TESTS'
uname
pwd
ls /
ls /bin
cat /hello.txt
echo "shell echo test: OK"
mkdir /tmp/testdir
ls /tmp
echo "hello from test" > /tmp/testdir/file1.txt
cat /tmp/testdir/file1.txt
wc /hello.txt
head -3 /etc/motd
whoami
hostname
env
cd /tmp
pwd
cd /
pwd
zls
zls /bin
zcat /hello.txt
zecho "zecho test: OK"
zwc /hello.txt
zhead -1 /etc/motd
ztrue ; echo "ztrue exit: $?"
zfalse ; echo "zfalse exit: $?"
zhead -3 /etc/motd
zls /tmp
env
zig version
echo "--- ALL TESTS COMPLETE ---"
exit
TESTS
)

# --- Launch QEMU with automated input ---
log "Launching QEMU ($FS_TYPE image, timeout=${TIMEOUT_SECS}s)..."

DRIVE_OPTS="-drive file=$DISK_IMG,format=raw,if=virtio"
NET_OPTS="-device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::8080-:80"

# Create a FIFO for feeding commands to QEMU
FIFO=$(mktemp -u /tmp/zigix_test_XXXXXX)
mkfifo "$FIFO"

# Background process: feed commands to QEMU's stdin via the FIFO
(
    # Wait for boot + login prompt
    sleep "$BOOT_WAIT"

    # Send login
    echo "user"
    sleep "$LOGIN_WAIT"

    # Send each test command with a delay
    while IFS= read -r cmd; do
        echo "$cmd"
        sleep "$CMD_DELAY"
    done <<< "$TEST_COMMANDS"

    # Give time for last command output, then kill QEMU
    sleep 2

    # Send Ctrl-A X to exit QEMU (0x01 = Ctrl-A, then 'x')
    printf '\x01x'

    # Safety: if QEMU doesn't exit, the timeout will kill it
    sleep 5
    printf '\x01x'
) > "$FIFO" &
FEEDER_PID=$!

# Run QEMU with timeout, capture all output
QEMU_EXIT=0
timeout "$TIMEOUT_SECS" qemu-system-x86_64 \
    -cpu Haswell \
    -cdrom "$ISO_FILE" \
    $DRIVE_OPTS \
    $NET_OPTS \
    -serial stdio \
    -display none \
    -no-reboot \
    -no-shutdown \
    -m 2G \
    < "$FIFO" 2>&1 | tee -a "$LOGFILE" || QEMU_EXIT=$?

# Cleanup
kill "$FEEDER_PID" 2>/dev/null || true
wait "$FEEDER_PID" 2>/dev/null || true
sudo rm -f "$FIFO"

# --- Analyze results ---
echo "" | tee -a "$LOGFILE"
header "Test Results Summary"

PASS=0
FAIL=0
TOTAL=0

check_output() {
    local pattern="$1"
    local label="$2"
    TOTAL=$((TOTAL + 1))
    if grep -q "$pattern" "$LOGFILE" 2>/dev/null; then
        echo "  PASS: $label" | tee -a "$LOGFILE"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label" | tee -a "$LOGFILE"
        FAIL=$((FAIL + 1))
    fi
}

check_output "Zigix shell v"                  "Shell boots"
check_output "Zigix zigix"                    "uname works"
check_output "Hello from ext"                 "cat /hello.txt"
check_output "shell echo test: OK"            "echo builtin"
check_output "hello from test"                "write + cat /tmp file"
check_output "zecho test: OK"                 "zecho external"
check_output "ztrue exit: 0"                  "ztrue returns 0"
check_output "ZIG_LIB_DIR=/zig/lib"          "ZIG_LIB_DIR env set"
check_output "0\."                            "zig version prints version"
check_output "ALL TESTS COMPLETE"             "Full test suite ran"

if [ "$QEMU_EXIT" -eq 124 ]; then
    # Timeout is only a failure if the test suite didn't finish
    if ! grep -q "ALL TESTS COMPLETE" "$LOGFILE" 2>/dev/null; then
        echo "  FAIL: QEMU timed out before tests completed" | tee -a "$LOGFILE"
        FAIL=$((FAIL + 1))
        TOTAL=$((TOTAL + 1))
    fi
fi

echo "" | tee -a "$LOGFILE"
echo "Results: $PASS/$TOTAL passed, $FAIL failed" | tee -a "$LOGFILE"
echo "Log: $LOGFILE" | tee -a "$LOGFILE"

if [ "$FAIL" -gt 0 ]; then
    exit 2
fi
exit 0
