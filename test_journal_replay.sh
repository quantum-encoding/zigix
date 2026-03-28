#!/bin/bash
# Test ext3 journal dirty shutdown + replay on ARM64.
#
# Phase 1: Boot Zigix, write test files to ext4, sync journal, kill QEMU (dirty shutdown)
# Phase 2: Boot again with SAME image — journal replays, verify files survived
#
# Usage: bash test_journal_replay.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL=zig-out/bin/zigix-aarch64
IMG=ext4-aarch64.img
LOG1=/tmp/journal_phase1.log
LOG2=/tmp/journal_phase2.log
SMP="${SMP:-2}"
ACCEL="${ACCEL:-tcg,thread=single}"

echo "=== Journal Replay Test ==="
echo ""

# 1. Build kernel + userspace
echo "[1/4] Building kernel + userspace..."
zig build -Darch=aarch64

for prog in zsh zinit zlogin zping zcurl zgrep zhttpd zsshd; do
    src="$SCRIPT_DIR/userspace/$prog"
    [ -d "$src" ] || continue
    (cd "$src" && zig build -Darch=aarch64 2>/dev/null) || {
        echo "  WARN: $prog failed to build"
        continue
    }
done

# Collect binaries
EXTRA_DIR=$(mktemp -d)
trap "rm -rf $EXTRA_DIR" EXIT
for prog in zsh zinit zlogin zping zcurl zgrep zhttpd zsshd; do
    bin="$SCRIPT_DIR/userspace/$prog/zig-out/bin/${prog}-aarch64"
    [ -f "$bin" ] && cp "$bin" "$EXTRA_DIR/$prog"
done
SHELL_BIN="$EXTRA_DIR/zsh"
[ -f "$SHELL_BIN" ] || { echo "ERROR: zsh not built"; exit 1; }

# 2. Create fresh image
echo "[2/4] Creating ext4 image..."
SCRIPTS_DIR="$SCRIPT_DIR/test_scripts"
python3 "$SCRIPT_DIR/make_ext4_img.py" "$IMG" "$SHELL_BIN" "$EXTRA_DIR" "$SCRIPTS_DIR"

# 3. Phase 1: Boot, write test files, dirty shutdown
echo "[3/4] Phase 1: booting for journal write..."
echo "       Waiting for PHASE1_DONE signal..."

# Run QEMU in background, capture output
qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -accel "$ACCEL" \
    -cpu cortex-a57 \
    -m 4G \
    -smp "$SMP" \
    -kernel "$KERNEL" \
    -drive file=$IMG,format=raw,if=none,id=disk0 -device virtio-blk-device,drive=disk0 \
    -device virtio-net-device,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8081-:80 \
    -serial stdio \
    -display none \
    -no-reboot > "$LOG1" 2>&1 &
QEMU_PID=$!

# Wait for Phase 1 completion signal (max 60 seconds)
WAITED=0
while [ $WAITED -lt 60 ]; do
    if grep -q "PHASE1_DONE" "$LOG1" 2>/dev/null; then
        echo "       Phase 1 complete — killing QEMU (dirty shutdown)..."
        sleep 1  # Let a couple more writes happen
        kill -9 $QEMU_PID 2>/dev/null || true
        wait $QEMU_PID 2>/dev/null || true
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ $WAITED -ge 60 ]; then
    echo "ERROR: Phase 1 timed out"
    kill -9 $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
    echo "--- Phase 1 log ---"
    tail -30 "$LOG1"
    exit 1
fi

echo "       Phase 1 log:"
grep '\[journal-replay\]' "$LOG1" | sed 's/^/         /'

# 4. Phase 2: Reboot with SAME image — journal should replay
echo "[4/4] Phase 2: rebooting for journal replay verification..."

qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -accel "$ACCEL" \
    -cpu cortex-a57 \
    -m 4G \
    -smp "$SMP" \
    -kernel "$KERNEL" \
    -drive file=$IMG,format=raw,if=none,id=disk0 -device virtio-blk-device,drive=disk0 \
    -device virtio-net-device,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8081-:80 \
    -serial stdio \
    -display none \
    -no-reboot > "$LOG2" 2>&1 &
QEMU_PID=$!

# Wait for Phase 2 results (max 60 seconds)
WAITED=0
while [ $WAITED -lt 60 ]; do
    if grep -q "journal-replay.*Results:" "$LOG2" 2>/dev/null; then
        sleep 2  # Let remaining output flush
        kill $QEMU_PID 2>/dev/null || true
        wait $QEMU_PID 2>/dev/null || true
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ $WAITED -ge 60 ]; then
    echo "ERROR: Phase 2 timed out"
    kill -9 $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
    echo "--- Phase 2 log ---"
    tail -30 "$LOG2"
    exit 1
fi

echo ""
echo "=== Journal Replay Results ==="
echo ""
echo "  Journal detection:"
grep '\[ext3\]' "$LOG2" | head -10 | sed 's/^/    /'
echo ""
echo "  Replay verification:"
grep '\[journal-replay\]' "$LOG2" | sed 's/^/    /'
echo ""

# Check result
if grep -q "journal-replay.*ALL PASS" "$LOG2"; then
    echo "  RESULT: PASS — journal replay recovered all data after dirty shutdown"
    exit 0
else
    echo "  RESULT: FAIL — journal replay did not recover all data"
    exit 1
fi
