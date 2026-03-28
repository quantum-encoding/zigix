#!/bin/bash
# Create an ext2-formatted test disk image for Zigix ARM64 (aarch64).
# Builds userspace programs for aarch64 and bundles them into a 1GB image.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COREUTILS_DIR="$(cd "$SCRIPT_DIR/../programs/zig_core_utils" && pwd)"
IMG="$SCRIPT_DIR/test.img"
ANY_REBUILT=0

# Check if a binary needs rebuilding: returns 0 (true) if sources are newer than output.
needs_build() {
    local bin="$1"
    local src_dir="$2"
    [ ! -f "$bin" ] && return 0
    if find "$src_dir" \( -name '*.zig' -o -name 'build.zig.zon' \) -newer "$bin" 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

# Build freestanding userspace programs for aarch64
SHELL_BIN="$SCRIPT_DIR/userspace/zsh/zig-out/bin/zsh-aarch64"

# zbench excluded — uses x86_64 inline asm, not yet ported to aarch64
for prog in zsh zinit zlogin zping zcurl zgrep zhttpd zsshd zdpdk; do
    src="$SCRIPT_DIR/userspace/$prog"
    [ -d "$src" ] || { echo "Skipping $prog (not found)"; continue; }
    bin="$SCRIPT_DIR/userspace/$prog/zig-out/bin/${prog}-aarch64"
    if needs_build "$bin" "$src"; then
        echo "Building $prog (aarch64)..."
        (cd "$src" && zig build -Darch=aarch64 2>/dev/null)
        ANY_REBUILT=1
    else
        echo "Skipping $prog (up to date)"
    fi
done

# Cross-compile ALL core utils from zig_core_utils for aarch64-linux-musl
MUSL_OPTS="-Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall"
built=0
skipped=0
failed=0

echo ""
echo "Cross-compiling zig_core_utils for aarch64-linux-musl..."
for dir in "$COREUTILS_DIR"/z*/; do
    [ -d "$dir" ] || continue
    util=$(basename "$dir")
    [ -f "$dir/build.zig" ] || continue
    bin="$dir/zig-out/bin/$util"
    if needs_build "$bin" "$dir"; then
        if (cd "$dir" && zig build $MUSL_OPTS 2>/dev/null); then
            built=$((built + 1))
            ANY_REBUILT=1
        else
            failed=$((failed + 1))
        fi
    else
        skipped=$((skipped + 1))
    fi
done
echo "  Core utils: $built built, $skipped up-to-date, $failed failed"

# Skip image generation if nothing was rebuilt and image exists
if [ "$ANY_REBUILT" -eq 0 ] && [ -f "$IMG" ]; then
    echo ""
    echo "Disk image up to date, skipping regeneration"
    echo "Done: $(ls -lh "$IMG" | awk '{print $5}') ext2 image (cached)"
    exit 0
fi

# Collect extra binaries into a temp directory
EXTRA_DIR=$(mktemp -d)

# Copy freestanding aarch64 binaries (strip -aarch64 suffix for /bin/ names)
for prog in zinit zlogin zping zcurl zgrep zhttpd zsshd zdpdk; do
    src_bin="$SCRIPT_DIR/userspace/$prog/zig-out/bin/${prog}-aarch64"
    if [ -f "$src_bin" ]; then
        cp "$src_bin" "$EXTRA_DIR/$prog"
    fi
done

# Copy all cross-compiled core utils (musl aarch64)
for dir in "$COREUTILS_DIR"/z*/; do
    [ -d "$dir" ] || continue
    util=$(basename "$dir")
    cp "$dir/zig-out/bin/$util" "$EXTRA_DIR/" 2>/dev/null || true
done

# Count what we're packaging
bin_count=$(ls "$EXTRA_DIR" | wc -l | tr -d ' ')
echo "  Packaging $bin_count binaries into /bin/"

# Prepare Zig compiler tree (binary + selective lib/) for /zig/ directory
ZIG_LINUX_DIR="${ZIG_LINUX_DIR:-/usr/local/zig}"
ZIG_TREE=""
if [ -f "$ZIG_LINUX_DIR/zig" ] && [ -d "$ZIG_LINUX_DIR/lib" ]; then
    echo ""
    echo "Preparing Zig compiler tree from $ZIG_LINUX_DIR..."
    ZIG_TREE=$(mktemp -d)
    # Copy the Zig binary
    cp "$ZIG_LINUX_DIR/zig" "$ZIG_TREE/"
    # Copy lib/ excluding the heavy libc/ directory
    mkdir -p "$ZIG_TREE/lib"
    rsync -a --exclude='libc/' "$ZIG_LINUX_DIR/lib/" "$ZIG_TREE/lib/"
    # Copy only the libc subdirs needed for aarch64-linux-musl target
    mkdir -p "$ZIG_TREE/lib/libc/include"
    rsync -a "$ZIG_LINUX_DIR/lib/libc/musl/" "$ZIG_TREE/lib/libc/musl/" 2>/dev/null || true
    rsync -a "$ZIG_LINUX_DIR/lib/libc/include/generic-musl/" "$ZIG_TREE/lib/libc/include/generic-musl/" 2>/dev/null || true
    rsync -a "$ZIG_LINUX_DIR/lib/libc/include/aarch64-linux-musl/" "$ZIG_TREE/lib/libc/include/aarch64-linux-musl/" 2>/dev/null || true
    rsync -a "$ZIG_LINUX_DIR/lib/libc/include/any-linux-any/" "$ZIG_TREE/lib/libc/include/any-linux-any/" 2>/dev/null || true
    zig_files=$(find "$ZIG_TREE" -type f | wc -l | tr -d ' ')
    zig_size=$(du -sh "$ZIG_TREE" | cut -f1)
    echo "  Zig tree: $zig_files files, $zig_size"
elif [ -f "$ZIG_LINUX_DIR/zig" ]; then
    echo "Adding Zig compiler (binary only) from $ZIG_LINUX_DIR..."
    cp "$ZIG_LINUX_DIR/zig" "$EXTRA_DIR/" 2>/dev/null || true
fi

# Build ext2 image with shell + extras + test scripts + optional zig tree
SCRIPTS_DIR="$SCRIPT_DIR/test_scripts"
if [ -n "$ZIG_TREE" ]; then
    python3 "$SCRIPT_DIR/make_ext2_img.py" "$IMG" "$SHELL_BIN" "$EXTRA_DIR" "$SCRIPTS_DIR" "$ZIG_TREE"
else
    python3 "$SCRIPT_DIR/make_ext2_img.py" "$IMG" "$SHELL_BIN" "$EXTRA_DIR" "$SCRIPTS_DIR"
fi

rm -rf "$EXTRA_DIR"
[ -n "$ZIG_TREE" ] && rm -rf "$ZIG_TREE"

echo "Done: $(ls -lh "$IMG" | awk '{print $5}') ext2 image"
