echo "=== Stress fork+exec test ==="
echo "Running zig version..."
/zig/zig version

echo "=== Compiling hello.zig ==="
cat > /tmp/hello.zig << 'ZIGEOF'
const std = @import("std");
pub fn main() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("Hello from Zig!\n", .{}) catch {};
}
ZIGEOF

cd /tmp
/zig/zig build-exe hello.zig -target aarch64-linux-musl 2>&1
echo "Build exit: $?"

echo "=== Running hello ==="
./hello 2>&1

echo "=== Starting zig build stress (if build.zig exists) ==="
echo "done"
