/// In-memory filesystem — file data backed by PMM-allocated pages.
///
/// Fixed pool of 2048 inodes. Files capped at 256 pages (1MB).
/// Directories hold up to 128 children.
///
/// ARM64 version: Uses identity mapping (phys == virt) instead of HHDM.

const pmm = @import("pmm.zig");
const vfs = @import("vfs.zig");
const uart = @import("uart.zig");
const spinlock = @import("spinlock.zig");

const PAGE_SIZE: usize = 4096;

const MAX_NODES: usize = 2048;
const MAX_DATA_PAGES: usize = 4096; // 16MB per file
const MAX_CHILDREN: usize = 128;

pub const RamfsNode = struct {
    name: [256]u8,
    name_len: u8,
    inode: vfs.Inode,
    // File data
    data_pages: [MAX_DATA_PAGES]?u64,
    size: u64,
    // Directory children
    children: [MAX_CHILDREN]?*RamfsNode,
    child_count: u8,
    parent: ?*RamfsNode,
    in_use: bool,
    // Symlink target (only used when inode.mode & S_IFMT == S_IFLNK)
    symlink_target: [256]u8 = [_]u8{0} ** 256,
    symlink_len: u8 = 0,
};

var nodes: [MAX_NODES]RamfsNode = undefined;
var next_ino: u64 = 1;
var initialized: bool = false;

/// SMP lock — protects nodes[], next_ino, and child list modifications.
var ramfs_lock: spinlock.IrqSpinlock = .{};

const ramfs_file_ops = vfs.FileOperations{
    .read = ramfsRead,
    .write = ramfsWrite,
    .close = null,
    .readdir = null,
    .truncate = ramfsTruncate,
};

const ramfs_dir_ops = vfs.FileOperations{
    .read = null,
    .write = null,
    .close = null,
    .readdir = ramfsReaddir,
    .lookup = lookup,
    .create = create,
    .unlink = unlink,
    .symlink = ramfsSymlink,
};

const ramfs_symlink_ops = vfs.FileOperations{
    .readlink = ramfsReadlink,
};

/// Initialize ramfs — create root directory, register lookup with VFS.
pub fn init() *vfs.Inode {
    for (0..MAX_NODES) |i| {
        nodes[i].in_use = false;
        nodes[i].child_count = 0;
        nodes[i].size = 0;
        nodes[i].parent = null;
        for (0..MAX_DATA_PAGES) |j| {
            nodes[i].data_pages[j] = null;
        }
        for (0..MAX_CHILDREN) |j| {
            nodes[i].children[j] = null;
        }
    }
    initialized = true;

    // Create root directory
    const root = allocNode() orelse @panic("ramfs: cannot alloc root");
    root.name[0] = '/';
    root.name_len = 1;
    root.inode = .{
        .ino = next_ino,
        .mode = vfs.S_IFDIR | 0o755,
        .size = 0,
        .nlink = 2,
        .ops = &ramfs_dir_ops,
        .fs_data = @ptrCast(root),
    };
    next_ino += 1;
    root.parent = root; // Root is its own parent

    uart.writeString("[ramfs] Initialized in-memory filesystem\n");

    return &root.inode;
}

/// Create a file or directory in a parent directory.
pub fn create(parent: *vfs.Inode, name: []const u8, mode: u32) ?*vfs.Inode {
    if (parent.mode & vfs.S_IFMT != vfs.S_IFDIR) return null;
    const parent_node: *RamfsNode = @alignCast(@ptrCast(parent.fs_data orelse return null));

    // Check for duplicate name and capacity under lock
    ramfs_lock.acquire();
    for (0..parent_node.child_count) |i| {
        if (parent_node.children[i]) |child| {
            if (nameEq(child.name[0..child.name_len], name)) {
                ramfs_lock.release();
                return null;
            }
        }
    }
    if (parent_node.child_count >= MAX_CHILDREN) {
        ramfs_lock.release();
        return null;
    }
    ramfs_lock.release();

    // allocNode() acquires ramfs_lock internally
    const node = allocNode() orelse return null;

    // Finalize node fields and link into parent under lock
    ramfs_lock.acquire();

    const len = if (name.len > 255) 255 else name.len;
    for (0..len) |i| {
        node.name[i] = name[i];
    }
    node.name_len = @truncate(len);
    node.parent = parent_node;

    const is_dir = (mode & vfs.S_IFMT == vfs.S_IFDIR);
    node.inode = .{
        .ino = next_ino,
        .mode = mode,
        .size = 0,
        .nlink = if (is_dir) 2 else 1,
        .ops = if (is_dir) &ramfs_dir_ops else &ramfs_file_ops,
        .fs_data = @ptrCast(node),
    };
    next_ino += 1;

    parent_node.children[parent_node.child_count] = node;
    parent_node.child_count += 1;

    ramfs_lock.release();

    return &node.inode;
}

/// Remove a file (not directory) from parent.
pub fn unlink(parent: *vfs.Inode, name: []const u8) bool {
    const parent_node: *RamfsNode = @alignCast(@ptrCast(parent.fs_data orelse return false));

    ramfs_lock.acquire();

    var idx: ?usize = null;
    for (0..parent_node.child_count) |i| {
        if (parent_node.children[i]) |child| {
            if (nameEq(child.name[0..child.name_len], name)) {
                // Don't allow unlinking directories
                if (child.inode.mode & vfs.S_IFMT == vfs.S_IFDIR) {
                    ramfs_lock.release();
                    return false;
                }
                idx = i;
                break;
            }
        }
    }

    const i = idx orelse {
        ramfs_lock.release();
        return false;
    };
    const child = parent_node.children[i].?;

    // Free data pages — PMM has its own leaf lock, safe to call here
    freeDataPages(child);

    // Remove from parent: shift children
    child.in_use = false;
    var j: usize = i;
    while (j + 1 < parent_node.child_count) : (j += 1) {
        parent_node.children[j] = parent_node.children[j + 1];
    }
    parent_node.children[parent_node.child_count - 1] = null;
    parent_node.child_count -= 1;

    ramfs_lock.release();
    return true;
}

/// Write data into a ramfs file. Called with kernel-accessible buffer.
pub fn writeData(inode: *vfs.Inode, data: []const u8, offset: u64) isize {
    const node: *RamfsNode = @alignCast(@ptrCast(inode.fs_data orelse return -1));

    ramfs_lock.acquire();

    var written: usize = 0;
    var file_off = offset;
    var src_off: usize = 0;

    while (src_off < data.len) {
        const page_idx = file_off / PAGE_SIZE;
        const page_off: usize = @truncate(file_off % PAGE_SIZE);
        const chunk = @min(data.len - src_off, PAGE_SIZE - page_off);

        if (page_idx >= MAX_DATA_PAGES) break;

        // Allocate page if needed — PMM has its own leaf lock, safe to call here
        if (node.data_pages[@as(usize, @truncate(page_idx))] == null) {
            const page = pmm.allocPage() orelse break;
            zeroPage(page);
            node.data_pages[@as(usize, @truncate(page_idx))] = page;
        }

        const phys = node.data_pages[@as(usize, @truncate(page_idx))].?;
        // ARM64 identity mapping: phys == virt
        const ptr: [*]u8 = @ptrFromInt(phys);
        for (0..chunk) |i| {
            ptr[page_off + i] = data[src_off + i];
        }

        written += chunk;
        file_off += chunk;
        src_off += chunk;
    }

    // Update file size
    if (file_off > node.size) {
        node.size = file_off;
        inode.size = file_off;
    }

    ramfs_lock.release();
    return @intCast(written);
}

// --- VFS operation implementations ---

fn ramfsRead(desc: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    const node: *RamfsNode = @alignCast(@ptrCast(desc.inode.fs_data orelse return 0));

    ramfs_lock.acquire();

    if (desc.offset >= node.size) {
        ramfs_lock.release();
        return 0; // EOF
    }

    const available: usize = @truncate(node.size - desc.offset);
    const to_read = @min(count, available);
    var read_total: usize = 0;
    var file_off = desc.offset;

    while (read_total < to_read) {
        const page_idx = file_off / PAGE_SIZE;
        const page_off: usize = @truncate(file_off % PAGE_SIZE);
        const chunk = @min(to_read - read_total, PAGE_SIZE - page_off);

        if (page_idx >= MAX_DATA_PAGES) break;

        if (node.data_pages[@as(usize, @truncate(page_idx))]) |phys| {
            // ARM64 identity mapping: phys == virt
            const ptr: [*]const u8 = @ptrFromInt(phys);
            for (0..chunk) |i| {
                buf[read_total + i] = ptr[page_off + i];
            }
        } else {
            // Sparse hole — return zeros
            for (0..chunk) |i| {
                buf[read_total + i] = 0;
            }
        }

        read_total += chunk;
        file_off += chunk;
    }

    desc.offset = file_off;

    ramfs_lock.release();
    return @intCast(read_total);
}

fn ramfsWrite(desc: *vfs.FileDescription, buf: [*]const u8, count: usize) isize {
    const node: *RamfsNode = @alignCast(@ptrCast(desc.inode.fs_data orelse return -1));

    ramfs_lock.acquire();

    var file_off = desc.offset;
    if (desc.flags & vfs.O_APPEND != 0) {
        file_off = node.size;
    }

    var written: usize = 0;
    while (written < count) {
        const page_idx = file_off / PAGE_SIZE;
        const page_off: usize = @truncate(file_off % PAGE_SIZE);
        const chunk = @min(count - written, PAGE_SIZE - page_off);

        if (page_idx >= MAX_DATA_PAGES) break;

        // PMM has its own leaf lock, safe to call here
        if (node.data_pages[@as(usize, @truncate(page_idx))] == null) {
            const page = pmm.allocPage() orelse break;
            zeroPage(page);
            node.data_pages[@as(usize, @truncate(page_idx))] = page;
        }

        const phys = node.data_pages[@as(usize, @truncate(page_idx))].?;
        // ARM64 identity mapping: phys == virt
        const ptr: [*]u8 = @ptrFromInt(phys);
        for (0..chunk) |i| {
            ptr[page_off + i] = buf[written + i];
        }

        written += chunk;
        file_off += chunk;
    }

    if (file_off > node.size) {
        node.size = file_off;
        desc.inode.size = file_off;
    }
    desc.offset = file_off;

    ramfs_lock.release();
    return @intCast(written);
}

fn ramfsReaddir(desc: *vfs.FileDescription, entry: *vfs.DirEntry) bool {
    const node: *RamfsNode = @alignCast(@ptrCast(desc.inode.fs_data orelse return false));

    ramfs_lock.acquire();
    defer ramfs_lock.release();

    const idx: usize = @truncate(desc.offset);
    if (idx >= node.child_count) return false;

    const child = node.children[idx] orelse return false;

    entry.name = [_]u8{0} ** 256;
    for (0..child.name_len) |i| {
        entry.name[i] = child.name[i];
    }
    entry.name_len = child.name_len;
    entry.ino = child.inode.ino;
    const ftype = child.inode.mode & vfs.S_IFMT;
    entry.d_type = if (ftype == vfs.S_IFDIR) vfs.DT_DIR else if (ftype == vfs.S_IFLNK) vfs.DT_LNK else vfs.DT_REG;

    desc.offset += 1;
    return true;
}

// --- Symlink operations ---

fn ramfsReadlink(inode: *vfs.Inode, buf: [*]u8, bufsiz: usize) isize {
    const node: *RamfsNode = @alignCast(@ptrCast(inode.fs_data orelse return -1));

    ramfs_lock.acquire();
    defer ramfs_lock.release();

    const copy_len = @min(@as(usize, node.symlink_len), bufsiz);
    for (0..copy_len) |i| {
        buf[i] = node.symlink_target[i];
    }
    return @intCast(copy_len);
}

fn ramfsSymlink(parent: *vfs.Inode, name: []const u8, target: []const u8) ?*vfs.Inode {
    if (parent.mode & vfs.S_IFMT != vfs.S_IFDIR) return null;
    if (name.len == 0 or name.len > 255 or target.len == 0 or target.len > 255) return null;

    const parent_node: *RamfsNode = @alignCast(@ptrCast(parent.fs_data orelse return null));

    ramfs_lock.acquire();

    // Check for duplicate name
    for (0..parent_node.child_count) |i| {
        if (parent_node.children[i]) |child| {
            if (nameEq(child.name[0..child.name_len], name)) {
                ramfs_lock.release();
                return null;
            }
        }
    }
    if (parent_node.child_count >= MAX_CHILDREN) {
        ramfs_lock.release();
        return null;
    }
    ramfs_lock.release();

    const node = allocNode() orelse return null;

    ramfs_lock.acquire();

    const nlen = if (name.len > 255) 255 else name.len;
    for (0..nlen) |i| {
        node.name[i] = name[i];
    }
    node.name_len = @truncate(nlen);
    node.parent = parent_node;

    // Store symlink target
    for (0..target.len) |i| {
        node.symlink_target[i] = target[i];
    }
    node.symlink_len = @truncate(target.len);

    node.inode = .{
        .ino = next_ino,
        .mode = vfs.S_IFLNK | 0o777,
        .size = target.len,
        .nlink = 1,
        .ops = &ramfs_symlink_ops,
        .fs_data = @ptrCast(node),
    };
    next_ino += 1;

    parent_node.children[parent_node.child_count] = node;
    parent_node.child_count += 1;

    ramfs_lock.release();
    return &node.inode;
}

fn ramfsTruncate(inode: *vfs.Inode) bool {
    const node: *RamfsNode = @alignCast(@ptrCast(inode.fs_data orelse return false));

    ramfs_lock.acquire();
    freeDataPages(node);
    node.size = 0;
    inode.size = 0;
    ramfs_lock.release();
    return true;
}

// --- Lookup (registered with VFS) ---

fn lookup(parent: *vfs.Inode, name: []const u8) ?*vfs.Inode {
    const node: *RamfsNode = @alignCast(@ptrCast(parent.fs_data orelse return null));

    ramfs_lock.acquire();
    defer ramfs_lock.release();

    for (0..node.child_count) |i| {
        if (node.children[i]) |child| {
            if (nameEq(child.name[0..child.name_len], name)) {
                return &child.inode;
            }
        }
    }
    return null;
}

// --- Helpers ---

fn allocNode() ?*RamfsNode {
    ramfs_lock.acquire();
    defer ramfs_lock.release();

    for (0..MAX_NODES) |i| {
        if (!nodes[i].in_use) {
            nodes[i].in_use = true;
            nodes[i].child_count = 0;
            nodes[i].size = 0;
            nodes[i].parent = null;
            for (0..MAX_DATA_PAGES) |j| {
                nodes[i].data_pages[j] = null;
            }
            for (0..MAX_CHILDREN) |j| {
                nodes[i].children[j] = null;
            }
            return &nodes[i];
        }
    }
    return null;
}

fn freeDataPages(node: *RamfsNode) void {
    for (0..MAX_DATA_PAGES) |i| {
        if (node.data_pages[i]) |phys| {
            pmm.freePage(phys);
            node.data_pages[i] = null;
        }
    }
}

fn nameEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn zeroPage(phys: u64) void {
    // ARM64 identity mapping: phys == virt
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..PAGE_SIZE) |i| {
        ptr[i] = 0;
    }
}
