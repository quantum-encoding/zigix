/// tmpfs — writable in-memory filesystem for /tmp.
///
/// Fixed pool of 128 inodes. Files capped at 64 pages (256KB).
/// Directories hold up to 32 children. Inode numbers start at 0x20000.

const types = @import("../types.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const vfs = @import("vfs.zig");
const serial = @import("../arch/x86_64/serial.zig");

const MAX_NODES: usize = 4096; // zig cc creates many temp files/dirs during compilation
// ?PhysAddr = optional u64 = 16 bytes on x86_64. One 4K page = 256 entries.
const MAX_DATA_PAGES: usize = 256; // max pages per file (1MB), fits in one page table page
const MAX_CHILDREN: usize = 128; // max children per dir, dynamically allocated
const DATA_PAGES_PER_BLOCK: usize = types.PAGE_SIZE / @sizeOf(?types.PhysAddr); // 256
const CHILDREN_PER_BLOCK: usize = types.PAGE_SIZE / @sizeOf(usize); // 512 (pointer size)
const INO_BASE: u64 = 0x20000;

// --- Extended attributes ---
pub const MAX_XATTRS: usize = 8;
pub const MAX_XATTR_NAME: usize = 64;
pub const MAX_XATTR_VAL: usize = 256;

pub const Xattr = struct {
    in_use: bool = false,
    name: [MAX_XATTR_NAME]u8 = [_]u8{0} ** MAX_XATTR_NAME,
    name_len: u8 = 0,
    value: [MAX_XATTR_VAL]u8 = [_]u8{0} ** MAX_XATTR_VAL,
    value_len: u16 = 0,
};

// --- Hard link table ---
// Tmpfs nodes embed their name, so a node can't appear under two different names
// via the children array alone. The hard link table stores additional directory
// entries (name → node) for hard-linked files.
const MAX_HARD_LINKS: usize = 32;
const HardLinkEntry = struct {
    in_use: bool = false,
    parent: ?*TmpfsNode = null,
    target: ?*TmpfsNode = null,
    name: [256]u8 = [_]u8{0} ** 256,
    name_len: u8 = 0,
};
var hard_links: [MAX_HARD_LINKS]HardLinkEntry = [_]HardLinkEntry{.{}} ** MAX_HARD_LINKS;

pub const TmpfsNode = struct {
    name: [256]u8,
    name_len: u8,
    inode: vfs.Inode,
    /// Pointer to PMM-allocated page holding data page addresses.
    /// Each entry is ?PhysAddr (8 bytes). One 4K page = 512 entries.
    /// Null until first write (allocated on demand).
    data_pages_ptr: ?[*]?types.PhysAddr = null,
    data_pages_phys: types.PhysAddr = 0, // physical page for freeing
    size: u64,
    /// Pointer to PMM-allocated page holding child pointers.
    /// Each entry is ?*TmpfsNode (8 bytes). One 4K page = 512 entries.
    /// Null until first child added (allocated on demand).
    children_ptr: ?[*]?*TmpfsNode = null,
    children_phys: types.PhysAddr = 0,
    child_count: u16,
    parent: ?*TmpfsNode,
    in_use: bool,
    xattrs: [MAX_XATTRS]Xattr = [_]Xattr{.{}} ** MAX_XATTRS,

    pub fn dataPages(self: *TmpfsNode) ?[*]?types.PhysAddr {
        return self.data_pages_ptr;
    }

    fn ensureDataPages(self: *TmpfsNode) ?[*]?types.PhysAddr {
        if (self.data_pages_ptr) |p| return p;
        const phys = pmm.allocPage() orelse return null;
        const virt = hhdm.physToVirt(phys);
        const ptr: [*]?types.PhysAddr = @ptrFromInt(virt);
        for (0..DATA_PAGES_PER_BLOCK) |i| ptr[i] = null;
        self.data_pages_ptr = ptr;
        self.data_pages_phys = phys;
        return ptr;
    }

    fn ensureChildren(self: *TmpfsNode) ?[*]?*TmpfsNode {
        if (self.children_ptr) |p| return p;
        const phys = pmm.allocPage() orelse return null;
        const virt = hhdm.physToVirt(phys);
        const ptr: [*]?*TmpfsNode = @ptrFromInt(virt);
        for (0..CHILDREN_PER_BLOCK) |i| ptr[i] = null;
        self.children_ptr = ptr;
        self.children_phys = phys;
        return ptr;
    }
};

var nodes: [MAX_NODES]TmpfsNode = undefined;
var next_ino: u64 = INO_BASE;
var initialized: bool = false;

const tmpfs_file_ops = vfs.FileOperations{
    .read = tmpfsRead,
    .write = tmpfsWrite,
    .truncate = tmpfsTruncate,
};

const tmpfs_symlink_ops = vfs.FileOperations{
    .readlink = tmpfsReadlink,
};

const tmpfs_dir_ops = vfs.FileOperations{
    .readdir = tmpfsReaddir,
    .lookup = lookup,
    .create = create,
    .unlink = unlink,
    .rmdir = tmpfsRmdir,
    .rename = tmpfsRename,
    .link = tmpfsLink,
    .symlink = tmpfsSymlink,
};

/// Initialize tmpfs — create root directory, return its inode.
pub fn init() *vfs.Inode {
    for (0..MAX_NODES) |i| {
        nodes[i].in_use = false;
        nodes[i].child_count = 0;
        nodes[i].size = 0;
        nodes[i].parent = null;
        nodes[i].data_pages_ptr = null;
        nodes[i].data_pages_phys = 0;
        nodes[i].children_ptr = null;
        nodes[i].children_phys = 0;
    }
    initialized = true;

    const root = allocNode() orelse @panic("tmpfs: cannot alloc root");
    root.name[0] = '/';
    root.name_len = 1;
    root.inode = .{
        .ino = next_ino,
        .mode = vfs.S_IFDIR | 0o777,
        .size = 0,
        .nlink = 2,
        .ops = &tmpfs_dir_ops,
        .fs_data = @ptrCast(root),
    };
    next_ino += 1;
    root.parent = root;

    return &root.inode;
}

/// Create a file or directory in a parent directory.
fn create(parent: *vfs.Inode, name: []const u8, mode: u32) ?*vfs.Inode {
    if (parent.mode & vfs.S_IFMT != vfs.S_IFDIR) return null;
    const parent_node: *TmpfsNode = @alignCast(@ptrCast(parent.fs_data orelse return null));

    // Check for duplicate name
    if (parent_node.children_ptr) |cp| {
        for (0..parent_node.child_count) |i| {
            if (cp[i]) |child| {
                if (nameEq(child.name[0..child.name_len], name)) return null;
            }
        }
    }

    if (parent_node.child_count >= MAX_CHILDREN) return null;

    const node = allocNode() orelse return null;
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
        .ops = if (is_dir) &tmpfs_dir_ops else &tmpfs_file_ops,
        .fs_data = @ptrCast(node),
    };
    next_ino += 1;

    const cp = parent_node.ensureChildren() orelse {
        node.in_use = false;
        return null;
    };
    cp[parent_node.child_count] = node;
    parent_node.child_count += 1;

    return &node.inode;
}

/// Remove a file (not directory) from parent.
fn unlink(parent: *vfs.Inode, name: []const u8) bool {
    const parent_node: *TmpfsNode = @alignCast(@ptrCast(parent.fs_data orelse {
        serial.writeString("[tmpfs-unlink] no fs_data\n");
        return false;
    }));

    // Check regular children first
    const cp = parent_node.children_ptr orelse {
        // No children allocated — check hard links only (fall through below)
        for (0..MAX_HARD_LINKS) |i| {
            if (hard_links[i].in_use and hard_links[i].parent == parent_node) {
                if (nameEq(hard_links[i].name[0..hard_links[i].name_len], name)) {
                    const target = hard_links[i].target.?;
                    hard_links[i].in_use = false;
                    if (target.inode.nlink > 0) target.inode.nlink -= 1;
                    if (target.inode.nlink == 0) {
                        freeDataPages(target);
                        target.in_use = false;
                    }
                    return true;
                }
            }
        }
        return false;
    };
    var idx: ?usize = null;
    for (0..parent_node.child_count) |i| {
        if (cp[i]) |child| {
            if (nameEq(child.name[0..child.name_len], name)) {
                if (child.inode.mode & vfs.S_IFMT == vfs.S_IFDIR) return false;
                idx = i;
                break;
            }
        }
    }

    if (idx) |i| {
        const child = cp[i].?;

        // Remove directory entry (shift children down)
        var j: usize = i;
        while (j + 1 < parent_node.child_count) : (j += 1) {
            cp[j] = cp[j + 1];
        }
        cp[parent_node.child_count - 1] = null;
        parent_node.child_count -= 1;

        // Decrement nlink — only free node data when last link removed.
        if (child.inode.nlink > 0) child.inode.nlink -= 1;
        if (child.inode.nlink == 0) {
            freeDataPages(child);
            child.in_use = false;
        }

        return true;
    }

    // Check hard link table
    for (0..MAX_HARD_LINKS) |i| {
        if (hard_links[i].in_use and hard_links[i].parent == parent_node) {
            if (nameEq(hard_links[i].name[0..hard_links[i].name_len], name)) {
                const target = hard_links[i].target.?;
                hard_links[i].in_use = false;
                if (target.inode.nlink > 0) target.inode.nlink -= 1;
                if (target.inode.nlink == 0) {
                    freeDataPages(target);
                    target.in_use = false;
                }
                return true;
            }
        }
    }

    return false;
}

/// Remove an empty directory from parent.
fn tmpfsRmdir(parent: *vfs.Inode, name: []const u8) bool {
    const parent_node: *TmpfsNode = @alignCast(@ptrCast(parent.fs_data orelse return false));

    const cp = parent_node.children_ptr orelse return false;
    var idx: ?usize = null;
    for (0..parent_node.child_count) |i| {
        if (cp[i]) |child| {
            if (nameEq(child.name[0..child.name_len], name)) {
                if (child.inode.mode & vfs.S_IFMT != vfs.S_IFDIR) return false;
                if (child.child_count != 0) return false; // Not empty
                idx = i;
                break;
            }
        }
    }

    const i = idx orelse return false;
    const child = cp[i].?;

    freeDataPages(child);
    freeChildren(child);
    child.in_use = false;

    var j: usize = i;
    while (j + 1 < parent_node.child_count) : (j += 1) {
        cp[j] = cp[j + 1];
    }
    cp[parent_node.child_count - 1] = null;
    parent_node.child_count -= 1;

    return true;
}

/// Lookup a child by name in a directory.
fn lookup(parent: *vfs.Inode, name: []const u8) ?*vfs.Inode {
    const node: *TmpfsNode = @alignCast(@ptrCast(parent.fs_data orelse return null));

    if (node.children_ptr) |cp| {
        for (0..node.child_count) |i| {
            if (cp[i]) |child| {
                if (nameEq(child.name[0..child.name_len], name)) {
                    return &child.inode;
                }
            }
        }
    }
    // Check hard link table for additional names
    for (0..MAX_HARD_LINKS) |i| {
        if (hard_links[i].in_use and hard_links[i].parent == node) {
            if (nameEq(hard_links[i].name[0..hard_links[i].name_len], name)) {
                return &hard_links[i].target.?.inode;
            }
        }
    }
    return null;
}

// --- VFS operation implementations ---

fn tmpfsRead(desc: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    const node: *TmpfsNode = @alignCast(@ptrCast(desc.inode.fs_data orelse return 0));

    if (desc.offset >= node.size) return 0;

    const available: usize = @truncate(node.size - desc.offset);
    const to_read = @min(count, available);
    var read_total: usize = 0;
    var file_off = desc.offset;

    while (read_total < to_read) {
        const page_idx = file_off / types.PAGE_SIZE;
        const page_off: usize = @truncate(file_off % types.PAGE_SIZE);
        const chunk = @min(to_read - read_total, types.PAGE_SIZE - page_off);

        if (page_idx >= MAX_DATA_PAGES) break;

        const dp_phys = if (node.dataPages()) |dp| dp[@as(usize, @truncate(page_idx))] else null;
        if (dp_phys) |phys| {
            const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
            for (0..chunk) |i| {
                buf[read_total + i] = ptr[page_off + i];
            }
        } else {
            for (0..chunk) |i| {
                buf[read_total + i] = 0;
            }
        }

        read_total += chunk;
        file_off += chunk;
    }

    desc.offset = file_off;
    return @intCast(read_total);
}

fn tmpfsWrite(desc: *vfs.FileDescription, buf: [*]const u8, count: usize) isize {
    const node: *TmpfsNode = @alignCast(@ptrCast(desc.inode.fs_data orelse return -1));

    var file_off = desc.offset;
    if (desc.flags & vfs.O_APPEND != 0) {
        file_off = node.size;
    }

    var written: usize = 0;
    while (written < count) {
        const page_idx = file_off / types.PAGE_SIZE;
        const page_off: usize = @truncate(file_off % types.PAGE_SIZE);
        const chunk = @min(count - written, types.PAGE_SIZE - page_off);

        if (page_idx >= MAX_DATA_PAGES) {
            // Return -EFBIG (file too large) instead of silently writing 0.
            // Silent 0-byte return causes callers to retry forever (Toyota pattern
            // from Chaos Rocket: silent failure propagates instead of being detected).
            if (written == 0) return -@as(isize, 27); // EFBIG = 27
            break;
        }

        const dp = node.ensureDataPages() orelse break;
        if (dp[@as(usize, @truncate(page_idx))] == null) {
            const page = pmm.allocPage() orelse break;
            zeroPage(page);
            dp[@as(usize, @truncate(page_idx))] = page;
        }

        const phys = dp[@as(usize, @truncate(page_idx))].?;
        const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
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

    return @intCast(written);
}

fn tmpfsTruncate(inode: *vfs.Inode) bool {
    const node: *TmpfsNode = @alignCast(@ptrCast(inode.fs_data orelse return false));
    freeDataPages(node);
    node.size = 0;
    inode.size = 0;
    return true;
}

fn tmpfsReaddir(desc: *vfs.FileDescription, entry: *vfs.DirEntry) bool {
    const node: *TmpfsNode = @alignCast(@ptrCast(desc.inode.fs_data orelse return false));

    const idx: usize = @truncate(desc.offset);

    // Regular children first
    if (idx < node.child_count) {
        const cp = node.children_ptr orelse return false;
        const child = cp[idx] orelse return false;
        entry.name = [_]u8{0} ** 256;
        for (0..child.name_len) |i| entry.name[i] = child.name[i];
        entry.name_len = child.name_len;
        entry.ino = child.inode.ino;
        entry.d_type = if (child.inode.mode & vfs.S_IFMT == vfs.S_IFDIR) vfs.DT_DIR else vfs.DT_REG;
        desc.offset += 1;
        return true;
    }

    // Then hard link entries for this directory
    var hl_idx: usize = idx - node.child_count;
    for (0..MAX_HARD_LINKS) |i| {
        if (hard_links[i].in_use and hard_links[i].parent == node) {
            if (hl_idx == 0) {
                const target = hard_links[i].target.?;
                entry.name = [_]u8{0} ** 256;
                for (0..hard_links[i].name_len) |j| entry.name[j] = hard_links[i].name[j];
                entry.name_len = hard_links[i].name_len;
                entry.ino = target.inode.ino;
                entry.d_type = if (target.inode.mode & vfs.S_IFMT == vfs.S_IFDIR) vfs.DT_DIR else vfs.DT_REG;
                desc.offset += 1;
                return true;
            }
            hl_idx -= 1;
        }
    }

    return false;
}

fn tmpfsReadlink(inode: *vfs.Inode, buf: [*]u8, bufsize: usize) isize {
    const node: *TmpfsNode = @alignCast(@ptrCast(inode.fs_data orelse return -1));
    const target_len = inode.size;
    if (target_len == 0) return 0;
    const page_phys = if (node.dataPages()) |dp| dp[0] orelse return -1 else return -1;
    const src: [*]const u8 = @ptrFromInt(hhdm.physToVirt(page_phys));
    const copy_len = if (target_len < bufsize) target_len else bufsize;
    for (0..copy_len) |i| buf[i] = src[i];
    return @intCast(copy_len);
}

/// Hard link: add a new directory entry pointing to an existing inode.
/// Uses the hard link table to store additional (name → node) mappings,
/// since tmpfs nodes embed their name and can't appear under two names
/// via the children array.
fn tmpfsLink(parent: *vfs.Inode, name: []const u8, target: *vfs.Inode) bool {
    const parent_node: *TmpfsNode = @alignCast(@ptrCast(parent.fs_data orelse return false));
    const target_node: *TmpfsNode = @alignCast(@ptrCast(target.fs_data orelse return false));

    // Check for duplicate name in children
    if (parent_node.children_ptr) |cp| {
        for (0..parent_node.child_count) |i| {
            if (cp[i]) |child| {
                if (nameEq(child.name[0..child.name_len], name)) return false;
            }
        }
    }
    // Check for duplicate name in hard link table
    for (0..MAX_HARD_LINKS) |i| {
        if (hard_links[i].in_use and hard_links[i].parent == parent_node) {
            if (nameEq(hard_links[i].name[0..hard_links[i].name_len], name)) return false;
        }
    }

    // Find a free hard link table entry
    for (0..MAX_HARD_LINKS) |i| {
        if (!hard_links[i].in_use) {
            hard_links[i].in_use = true;
            hard_links[i].parent = parent_node;
            hard_links[i].target = target_node;
            const len: u8 = if (name.len > 255) 255 else @truncate(name.len);
            for (0..len) |j| hard_links[i].name[j] = name[j];
            hard_links[i].name_len = len;
            target.nlink += 1;
            return true;
        }
    }
    return false; // Hard link table full
}

/// Symlink: create a new node storing the target path as data.
fn tmpfsSymlink(parent: *vfs.Inode, name: []const u8, target: []const u8) ?*vfs.Inode {
    const parent_node: *TmpfsNode = @alignCast(@ptrCast(parent.fs_data orelse return null));
    if (parent_node.child_count >= MAX_CHILDREN) return null;

    const node = allocNode() orelse return null;
    const len = if (name.len > 255) 255 else name.len;
    for (0..len) |i| node.name[i] = name[i];
    node.name_len = @truncate(len);
    node.parent = parent_node;

    node.inode = .{
        .ino = next_ino,
        .mode = vfs.S_IFLNK | 0o777,
        .size = target.len,
        .nlink = 1,
        .ops = &tmpfs_symlink_ops,
        .fs_data = @ptrCast(node),
    };
    next_ino += 1;

    // Store symlink target in first data page
    if (target.len > 0 and target.len <= types.PAGE_SIZE) {
        const dp = node.ensureDataPages() orelse {
            node.in_use = false;
            return null;
        };
        const page = pmm.allocPage() orelse {
            node.in_use = false;
            return null;
        };
        zeroPage(page);
        const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(page));
        for (0..target.len) |i| ptr[i] = target[i];
        dp[0] = page;
    }

    const cp = parent_node.ensureChildren() orelse {
        node.in_use = false;
        return null;
    };
    cp[parent_node.child_count] = node;
    parent_node.child_count += 1;

    return &node.inode;
}

fn tmpfsRename(old_parent: *vfs.Inode, old_name: []const u8, new_parent: *vfs.Inode, new_name: []const u8) bool {
    const old_node: *TmpfsNode = @alignCast(@ptrCast(old_parent.fs_data orelse return false));
    const new_node: *TmpfsNode = @alignCast(@ptrCast(new_parent.fs_data orelse return false));

    // Find the child in old parent
    const old_cp = old_node.children_ptr orelse return false;
    var child_ptr: ?*TmpfsNode = null;
    var old_idx: usize = 0;
    for (0..old_node.child_count) |i| {
        if (old_cp[i]) |child| {
            if (child.name_len == old_name.len) {
                var match = true;
                for (0..old_name.len) |j| {
                    if (child.name[j] != old_name[j]) { match = false; break; }
                }
                if (match) {
                    child_ptr = child;
                    old_idx = i;
                    break;
                }
            }
        }
    }
    const child = child_ptr orelse return false;

    // Remove from old parent (shift children down)
    var i: usize = old_idx;
    while (i + 1 < old_node.child_count) : (i += 1) {
        old_cp[i] = old_cp[i + 1];
    }
    old_cp[old_node.child_count - 1] = null;
    old_node.child_count -= 1;

    // Update child name
    for (0..new_name.len) |j| child.name[j] = new_name[j];
    child.name_len = @truncate(new_name.len);
    child.parent = new_node;

    // Add to new parent
    if (new_node.child_count >= MAX_CHILDREN) return false;
    const new_cp = new_node.ensureChildren() orelse return false;
    new_cp[new_node.child_count] = child;
    new_node.child_count += 1;

    return true;
}

// --- Helpers ---

fn allocNode() ?*TmpfsNode {
    for (0..MAX_NODES) |i| {
        if (!nodes[i].in_use) {
            nodes[i].in_use = true;
            nodes[i].child_count = 0;
            nodes[i].size = 0;
            nodes[i].parent = null;
            nodes[i].data_pages_ptr = null;
            nodes[i].data_pages_phys = 0;
            nodes[i].children_ptr = null;
            nodes[i].children_phys = 0;
            return &nodes[i];
        }
    }
    return null;
}

fn freeDataPages(node: *TmpfsNode) void {
    if (node.dataPages()) |dp| {
        for (0..MAX_DATA_PAGES) |i| {
            if (dp[i]) |phys| {
                pmm.freePage(phys);
                dp[i] = null;
            }
        }
    }
    if (node.data_pages_phys != 0) {
        pmm.freePage(node.data_pages_phys);
        node.data_pages_ptr = null;
        node.data_pages_phys = 0;
    }
}

fn freeChildren(node: *TmpfsNode) void {
    if (node.children_phys != 0) {
        pmm.freePage(node.children_phys);
        node.children_ptr = null;
        node.children_phys = 0;
    }
}

fn nameEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

/// Get a TmpfsNode from an inode (if it's a tmpfs inode).
pub fn nodeFromInode(inode: *vfs.Inode) ?*TmpfsNode {
    if (inode.ino < INO_BASE) return null;
    return @alignCast(@ptrCast(inode.fs_data orelse return null));
}

fn zeroPage(phys: types.PhysAddr) void {
    const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    for (0..types.PAGE_SIZE) |i| {
        ptr[i] = 0;
    }
}
