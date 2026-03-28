/// devfs — virtual filesystem providing device nodes.
///
/// Mounted at /dev. Provides /dev/null, /dev/zero, /dev/urandom, /dev/serial0.
/// /dev/null discards writes and reads EOF. /dev/zero reads as zeroes.
/// /dev/urandom provides pseudo-random bytes via xorshift64.

const vfs = @import("vfs.zig");
const fd_table = @import("fd_table.zig");
const timer = @import("timer.zig");

const MAX_NODES: usize = 8;
const INO_BASE: u64 = 0x40000;
const MAX_CHILDREN: usize = 8;

const NodeType = enum {
    root_dir,
    dev_null,
    dev_zero,
    dev_urandom,
    dev_serial0,
};

const DevfsNode = struct {
    name: [64]u8,
    name_len: u8,
    inode: vfs.Inode,
    node_type: NodeType,
    children: [MAX_CHILDREN]?*DevfsNode,
    child_count: u8,
    in_use: bool,
};

var nodes: [MAX_NODES]DevfsNode = undefined;
var next_ino: u64 = INO_BASE;

// xorshift64 PRNG state
var prng_state: u64 = 0;

const devfs_dir_ops = vfs.FileOperations{
    .readdir = devfsReaddir,
    .lookup = devfsLookup,
};

const dev_null_ops = vfs.FileOperations{
    .read = devNullRead,
    .write = devNullWrite,
};

const dev_zero_ops = vfs.FileOperations{
    .read = devZeroRead,
    .write = devNullWrite, // same as null: discard
};

const dev_urandom_ops = vfs.FileOperations{
    .read = devUrandomRead,
    .write = devNullWrite, // discard writes
};

// ---- Init ----

pub fn init() *vfs.Inode {
    for (0..MAX_NODES) |i| {
        nodes[i].in_use = false;
        nodes[i].child_count = 0;
    }

    // Create /dev root
    const root = allocNode() orelse unreachable;
    setName(root, "dev");
    root.node_type = .root_dir;
    root.inode.mode = vfs.S_IFDIR | 0o755;
    root.inode.nlink = 2;
    root.inode.ops = &devfs_dir_ops;

    // /dev/null
    const null_node = allocNode() orelse unreachable;
    setName(null_node, "null");
    null_node.node_type = .dev_null;
    null_node.inode.mode = vfs.S_IFREG | 0o666;
    null_node.inode.nlink = 1;
    null_node.inode.ops = &dev_null_ops;
    addChild(root, null_node);

    // /dev/zero
    const zero_node = allocNode() orelse unreachable;
    setName(zero_node, "zero");
    zero_node.node_type = .dev_zero;
    zero_node.inode.mode = vfs.S_IFREG | 0o666;
    zero_node.inode.nlink = 1;
    zero_node.inode.ops = &dev_zero_ops;
    addChild(root, zero_node);

    // /dev/urandom
    const urandom_node = allocNode() orelse unreachable;
    setName(urandom_node, "urandom");
    urandom_node.node_type = .dev_urandom;
    urandom_node.inode.mode = vfs.S_IFREG | 0o666;
    urandom_node.inode.nlink = 1;
    urandom_node.inode.ops = &dev_urandom_ops;
    addChild(root, urandom_node);

    // /dev/serial0
    const serial_node = allocNode() orelse unreachable;
    setName(serial_node, "serial0");
    serial_node.node_type = .dev_serial0;
    serial_node.inode.mode = vfs.S_IFREG | 0o666;
    serial_node.inode.nlink = 1;
    serial_node.inode.ops = &fd_table.serial_ops;
    addChild(root, serial_node);

    return &root.inode;
}

// ---- Lookup ----

fn devfsLookup(parent: *vfs.Inode, name: []const u8) ?*vfs.Inode {
    const node: *DevfsNode = @alignCast(@ptrCast(parent.fs_data orelse return null));

    for (0..node.child_count) |i| {
        const child = node.children[i] orelse continue;
        if (nameEq(child, name)) {
            return &child.inode;
        }
    }
    return null;
}

// ---- Device operations ----

fn devNullRead(_: *vfs.FileDescription, _: [*]u8, _: usize) isize {
    return 0; // EOF
}

fn devNullWrite(_: *vfs.FileDescription, _: [*]const u8, count: usize) isize {
    return @intCast(count); // discard
}

fn devZeroRead(_: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    for (0..count) |i| {
        buf[i] = 0;
    }
    return @intCast(count);
}

fn devUrandomRead(_: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    // Lazy-seed from ARM generic timer tick count
    if (prng_state == 0) {
        prng_state = timer.getTicks() | 1; // Must not be zero
    }

    var i: usize = 0;
    while (i < count) {
        // xorshift64
        prng_state ^= prng_state << 13;
        prng_state ^= prng_state >> 7;
        prng_state ^= prng_state << 17;

        // Extract 8 bytes from state
        const bytes: [8]u8 = @bitCast(prng_state);
        var j: usize = 0;
        while (j < 8 and i < count) {
            buf[i] = bytes[j];
            i += 1;
            j += 1;
        }
    }
    return @intCast(count);
}

// ---- Readdir ----

fn devfsReaddir(desc: *vfs.FileDescription, entry: *vfs.DirEntry) bool {
    const node: *DevfsNode = @alignCast(@ptrCast(desc.inode.fs_data orelse return false));
    const idx = @as(usize, @truncate(desc.offset));

    if (idx >= node.child_count) return false;
    const child = node.children[idx] orelse return false;

    for (0..child.name_len) |i| {
        entry.name[i] = child.name[i];
    }
    entry.name_len = child.name_len;
    entry.ino = child.inode.ino;
    entry.d_type = vfs.DT_REG; // All device nodes appear as regular files

    desc.offset += 1;
    return true;
}

// ---- Node management ----

fn allocNode() ?*DevfsNode {
    for (0..MAX_NODES) |i| {
        if (!nodes[i].in_use) {
            nodes[i].in_use = true;
            nodes[i].child_count = 0;
            for (0..MAX_CHILDREN) |j| {
                nodes[i].children[j] = null;
            }
            nodes[i].inode = .{
                .ino = next_ino,
                .mode = 0,
                .size = 0,
                .nlink = 1,
                .ops = &dev_null_ops,
                .fs_data = @ptrCast(&nodes[i]),
            };
            next_ino += 1;
            return &nodes[i];
        }
    }
    return null;
}

fn setName(node: *DevfsNode, name: []const u8) void {
    const len = if (name.len > 63) 63 else name.len;
    for (0..len) |i| {
        node.name[i] = name[i];
    }
    node.name_len = @truncate(len);
}

fn addChild(parent: *DevfsNode, child: *DevfsNode) void {
    if (parent.child_count < MAX_CHILDREN) {
        parent.children[parent.child_count] = child;
        parent.child_count += 1;
    }
}

fn nameEq(node: *DevfsNode, name: []const u8) bool {
    if (node.name_len != name.len) return false;
    for (0..name.len) |i| {
        if (node.name[i] != name[i]) return false;
    }
    return true;
}
