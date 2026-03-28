#!/bin/bash
# Create an ext4-formatted bootable disk image for Zigix.
# Builds userspace programs and all zig_core_utils, bundles them into a 1GB ext4 image.
# Same structure as make_ext2_img.sh but produces ext4 with extents, checksums, 64-bit BGDs.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COREUTILS_DIR="$(cd "$SCRIPT_DIR/../programs/zig_core_utils" && pwd)"
IMG="$SCRIPT_DIR/test_ext4.img"
ANY_REBUILT=0

needs_build() {
    local bin="$1"
    local src_dir="$2"
    [ ! -f "$bin" ] && return 0
    if find "$src_dir" \( -name '*.zig' -o -name 'build.zig.zon' \) -newer "$bin" 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

# Build freestanding userspace programs
SHELL_BIN="$SCRIPT_DIR/userspace/zsh/zig-out/bin/zsh"

for prog in zsh zinit zlogin zping zcurl zgrep zbench zhttpd zsshd zdpdk; do
    src="$SCRIPT_DIR/userspace/$prog"
    [ -d "$src" ] || { echo "Skipping $prog (not found)"; continue; }
    bin="$SCRIPT_DIR/userspace/$prog/zig-out/bin/$prog"
    if needs_build "$bin" "$src"; then
        echo "Building $prog..."
        (cd "$src" && zig build 2>/dev/null)
        ANY_REBUILT=1
    else
        echo "Skipping $prog (up to date)"
    fi
done

# Cross-compile core utils
MUSL_OPTS="-Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall"
built=0
skipped=0
failed=0

echo ""
echo "Cross-compiling zig_core_utils for x86_64-linux-musl..."
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

# Skip if nothing rebuilt and image exists
if [ "$ANY_REBUILT" -eq 0 ] && [ -f "$IMG" ]; then
    echo ""
    echo "ext4 image up to date, skipping regeneration"
    echo "Done: $(ls -lh "$IMG" | awk '{print $5}') ext4 image (cached)"
    exit 0
fi

# Collect extra binaries
EXTRA_DIR=$(mktemp -d)

cp "$SCRIPT_DIR/userspace/zinit/zig-out/bin/zinit" "$EXTRA_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/userspace/zlogin/zig-out/bin/zlogin" "$EXTRA_DIR/" 2>/dev/null || true

for dir in "$COREUTILS_DIR"/z*/; do
    [ -d "$dir" ] || continue
    util=$(basename "$dir")
    cp "$dir/zig-out/bin/$util" "$EXTRA_DIR/" 2>/dev/null || true
done

# Freestanding versions override musl versions
cp "$SCRIPT_DIR/userspace/zping/zig-out/bin/zping" "$EXTRA_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/userspace/zcurl/zig-out/bin/zcurl" "$EXTRA_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/userspace/zgrep/zig-out/bin/zgrep" "$EXTRA_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/userspace/zbench/zig-out/bin/zbench" "$EXTRA_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/userspace/zhttpd/zig-out/bin/zhttpd" "$EXTRA_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/userspace/zsshd/zig-out/bin/zsshd" "$EXTRA_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/userspace/zdpdk/zig-out/bin/zdpdk" "$EXTRA_DIR/" 2>/dev/null || true

bin_count=$(ls "$EXTRA_DIR" | wc -l | tr -d ' ')
echo "  Packaging $bin_count binaries into /bin/"

# Optional Zig compiler tree
ZIG_LINUX_DIR="${ZIG_LINUX_DIR:-/tmp/zig-linux-x86_64}"
ZIG_TREE=""
if [ -f "$ZIG_LINUX_DIR/zig" ] && [ -d "$ZIG_LINUX_DIR/lib" ]; then
    echo ""
    echo "Preparing Zig compiler tree from $ZIG_LINUX_DIR..."
    ZIG_TREE=$(mktemp -d)
    cp "$ZIG_LINUX_DIR/zig" "$ZIG_TREE/"
    mkdir -p "$ZIG_TREE/lib"
    rsync -a --exclude='libc/' "$ZIG_LINUX_DIR/lib/" "$ZIG_TREE/lib/"
    mkdir -p "$ZIG_TREE/lib/libc/include"
    rsync -a "$ZIG_LINUX_DIR/lib/libc/musl/" "$ZIG_TREE/lib/libc/musl/" 2>/dev/null || true
    rsync -a "$ZIG_LINUX_DIR/lib/libc/include/generic-musl/" "$ZIG_TREE/lib/libc/include/generic-musl/" 2>/dev/null || true
    rsync -a "$ZIG_LINUX_DIR/lib/libc/include/x86_64-linux-musl/" "$ZIG_TREE/lib/libc/include/x86_64-linux-musl/" 2>/dev/null || true
    rsync -a "$ZIG_LINUX_DIR/lib/libc/include/any-linux-any/" "$ZIG_TREE/lib/libc/include/any-linux-any/" 2>/dev/null || true
    zig_files=$(find "$ZIG_TREE" -type f | wc -l | tr -d ' ')
    zig_size=$(du -sh "$ZIG_TREE" | cut -f1)
    echo "  Zig tree: $zig_files files, $zig_size"
elif [ -f "$ZIG_LINUX_DIR/zig" ]; then
    echo "Adding Zig compiler (binary only) from $ZIG_LINUX_DIR..."
    cp "$ZIG_LINUX_DIR/zig" "$EXTRA_DIR/" 2>/dev/null || true
fi

# Build ext4 image
SCRIPTS_DIR="$SCRIPT_DIR/test_scripts"
echo ""
echo "Generating ext4 image..."
if [ -n "$ZIG_TREE" ]; then
    python3 "$SCRIPT_DIR/make_ext4_img.py" "$IMG" "$SHELL_BIN" "$EXTRA_DIR" "$SCRIPTS_DIR" "$ZIG_TREE"
else
    python3 "$SCRIPT_DIR/make_ext4_img.py" "$IMG" "$SHELL_BIN" "$EXTRA_DIR" "$SCRIPTS_DIR"
fi

rm -rf "$EXTRA_DIR"
[ -n "$ZIG_TREE" ] && rm -rf "$ZIG_TREE"

echo "Done: $(ls -lh "$IMG" | awk '{print $5}') ext4 image"
