/// Virtual Filesystem Switch — core abstractions for all filesystem operations.
///
/// VFS operations use kernel-accessible pointers. The syscall layer handles
/// user memory translation (copyFromUser/copyToUser) before calling into VFS.
///
/// Path resolution walks from the root inode, following mount points.
/// Supports split resolution: resolve(parent, leaf_name) for O_CREAT.

const serial = @import("../arch/x86_64/serial.zig");
const errno = @import("../proc/errno.zig");
const spinlock = @import("../arch/x86_64/spinlock.zig");

/// SMP lock protecting the fd_pool array.
var fd_pool_lock: spinlock.IrqSpinlock = .{};

// --- File type and mode constants (Linux-compatible) ---

pub const S_IFMT: u32 = 0o170000; // File type mask
pub const S_IFREG: u32 = 0o100000; // Regular file
pub const S_IFDIR: u32 = 0o040000; // Directory
pub const S_IFIFO: u32 = 0o010000; // FIFO/pipe
pub const S_IFLNK: u32 = 0o120000; // Symbolic link
pub const S_IFSOCK: u32 = 0o140000; // Socket

pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_ACCMODE: u32 = 3;
pub const O_CREAT: u32 = 0o100;
pub const O_TRUNC: u32 = 0o1000;
pub const O_APPEND: u32 = 0o2000;
pub const O_NOFOLLOW: u32 = 0o400000;
pub const O_CLOEXEC: u32 = 0o2000000;
pub const O_DIRECTORY: u32 = 0o200000;

pub const DT_REG: u8 = 8;
pub const DT_DIR: u8 = 4;
pub const DT_LNK: u8 = 10;

pub const AT_FDCWD: i32 = -100;

// --- Core types ---

/// Operations vtable — each filesystem (ramfs, serial, pipe, tmpfs) provides its own.
pub const FileOperations = struct {
    read: ?*const fn (*FileDescription, [*]u8, usize) isize = null,
    write: ?*const fn (*FileDescription, [*]const u8, usize) isize = null,
    close: ?*const fn (*FileDescription) void = null,
    readdir: ?*const fn (*FileDescription, *DirEntry) bool = null,
    lookup: ?*const fn (*Inode, []const u8) ?*Inode = null,
    create: ?*const fn (*Inode, []const u8, u32) ?*Inode = null,
    unlink: ?*const fn (*Inode, []const u8) bool = null,
    rmdir: ?*const fn (*Inode, []const u8) bool = null,
    truncate: ?*const fn (*Inode) bool = null,
    readlink: ?*const fn (*Inode, [*]u8, usize) isize = null,
    rename: ?*const fn (*Inode, []const u8, *Inode, []const u8) bool = null,
    symlink: ?*const fn (*Inode, []const u8, []const u8) ?*Inode = null, // parent, name, target
    link: ?*const fn (*Inode, []const u8, *Inode) bool = null, // parent, name, target_inode
};

/// Inode — represents a file/directory in the filesystem.
pub const Inode = struct {
    ino: u64,
    mode: u32, // S_IFREG | permissions, S_IFDIR | permissions
    size: u64,
    nlink: u32,
    uid: u16 = 0,
    gid: u16 = 0,
    ops: *const FileOperations,
    fs_data: ?*anyopaque, // Filesystem-specific (ramfs: *RamfsNode)
};

/// Open file description — one per open() call, shared via dup/fork.
pub const FileDescription = struct {
    inode: *Inode,
    offset: u64,
    flags: u32,
    ref_count: u32,
    in_use: bool,
    lock_type: u8 = 0, // 0=none, 1=LOCK_SH, 2=LOCK_EX
};

/// Directory entry — used by readdir operations.
pub const DirEntry = struct {
    name: [256]u8,
    name_len: u8,
    ino: u64,
    d_type: u8,
};

/// Stat result — Linux-compatible (simplified for MVP).
pub const Stat = struct {
    st_ino: u64,
    st_mode: u32,
    st_nlink: u32,
    st_size: u64,
    st_uid: u32,
    st_gid: u32,
};

// --- FileDescription pool ---

const MAX_FILE_DESCRIPTIONS: usize = 2048; // Zig compiler opens 100s of source files
var fd_pool: [MAX_FILE_DESCRIPTIONS]FileDescription = undefined;
var fd_pool_initialized: bool = false;

fn initPool() void {
    for (0..MAX_FILE_DESCRIPTIONS) |i| {
        fd_pool[i] = .{
            .inode = undefined,
            .offset = 0,
            .flags = 0,
            .ref_count = 0,
            .in_use = false,
        };
    }
    fd_pool_initialized = true;
}

/// Check if acquiring a lock would conflict with existing locks on the same inode.
/// Returns true if there's a conflict. lock_op: 1=LOCK_SH, 2=LOCK_EX.
pub fn checkFlockConflict(target: *const FileDescription, lock_op: u8) bool {
    if (!fd_pool_initialized) return false;
    const target_ino = target.inode.ino;
    for (0..MAX_FILE_DESCRIPTIONS) |i| {
        if (!fd_pool[i].in_use) continue;
        if (fd_pool[i].inode.ino != target_ino) continue;
        if (@intFromPtr(&fd_pool[i]) == @intFromPtr(target)) continue;
        if (lock_op == 2 and fd_pool[i].lock_type != 0) return true; // EX conflicts with any
        if (lock_op == 1 and fd_pool[i].lock_type == 2) return true; // SH conflicts with EX
    }
    return false;
}

pub fn allocFileDescription() ?*FileDescription {
    const flags = fd_pool_lock.acquire();
    defer fd_pool_lock.release(flags);
    if (!fd_pool_initialized) initPool();
    for (0..MAX_FILE_DESCRIPTIONS) |i| {
        if (!fd_pool[i].in_use) {
            fd_pool[i].in_use = true;
            fd_pool[i].offset = 0;
            fd_pool[i].ref_count = 1;
            return &fd_pool[i];
        }
    }
    // ENFILE diagnostic: count in-use by ref_count
    var in_use: u32 = 0;
    var ref1: u32 = 0;
    var ref2plus: u32 = 0;
    for (0..MAX_FILE_DESCRIPTIONS) |j| {
        if (fd_pool[j].in_use) {
            in_use += 1;
            if (fd_pool[j].ref_count <= 1) ref1 += 1 else ref2plus += 1;
        }
    }
    serial.writeString("[ENFILE] pool full: ");
    serial.writeByte(@as(u8, @truncate((in_use / 1000) % 10)) + '0');
    serial.writeByte(@as(u8, @truncate((in_use / 100) % 10)) + '0');
    serial.writeByte(@as(u8, @truncate((in_use / 10) % 10)) + '0');
    serial.writeByte(@as(u8, @truncate(in_use % 10)) + '0');
    serial.writeString("/2048 ref1=");
    serial.writeByte(@as(u8, @truncate((ref1 / 1000) % 10)) + '0');
    serial.writeByte(@as(u8, @truncate((ref1 / 100) % 10)) + '0');
    serial.writeByte(@as(u8, @truncate((ref1 / 10) % 10)) + '0');
    serial.writeByte(@as(u8, @truncate(ref1 % 10)) + '0');
    serial.writeString(" ref2+=");
    serial.writeByte(@as(u8, @truncate((ref2plus / 1000) % 10)) + '0');
    serial.writeByte(@as(u8, @truncate((ref2plus / 100) % 10)) + '0');
    serial.writeByte(@as(u8, @truncate((ref2plus / 10) % 10)) + '0');
    serial.writeByte(@as(u8, @truncate(ref2plus % 10)) + '0');
    serial.writeString("\n");
    return null;
}

pub fn releaseFileDescription(desc: *FileDescription) void {
    if (desc.ref_count > 0) {
        desc.ref_count -= 1;
    }
    if (desc.ref_count == 0) {
        // Call the filesystem's close handler if present.
        // Validate pointers are in kernel address space (higher half on x86_64,
        // or HHDM on both architectures) to avoid crashing on stale descriptors.
        const inode_addr = @intFromPtr(desc.inode);
        if (inode_addr > 0x1000) { // Basic non-null sanity check
            if (desc.inode.ops.close) |close_fn| {
                close_fn(desc);
            }
        }
        desc.in_use = false;
    }
}

/// Release a FileDescription without calling close handlers.
/// Used for FIFO handling where we drop the unused pipe end's descriptor
/// without actually closing the pipe.
pub fn releaseFileDescriptionNoClose(desc: *FileDescription) void {
    desc.in_use = false;
}

// --- Mount table ---

pub const MountPoint = struct {
    path: [256]u8,
    path_len: u8,
    root_inode: *Inode,
    in_use: bool,
};

const MAX_MOUNTS: usize = 8;
var mounts: [MAX_MOUNTS]MountPoint = [_]MountPoint{.{
    .path = [_]u8{0} ** 256,
    .path_len = 0,
    .root_inode = undefined,
    .in_use = false,
}} ** MAX_MOUNTS;

pub fn mount(path: []const u8, root_inode: *Inode) bool {
    for (0..MAX_MOUNTS) |i| {
        if (!mounts[i].in_use) {
            const len = if (path.len > 255) 255 else path.len;
            for (0..len) |j| {
                mounts[i].path[j] = path[j];
            }
            mounts[i].path[len] = 0;
            mounts[i].path_len = @truncate(len);
            mounts[i].root_inode = root_inode;
            mounts[i].in_use = true;
            return true;
        }
    }
    return false;
}

/// Get the root inode for "/"
pub fn getRootInode() ?*Inode {
    for (0..MAX_MOUNTS) |i| {
        if (mounts[i].in_use and mounts[i].path_len == 1 and mounts[i].path[0] == '/') {
            return mounts[i].root_inode;
        }
    }
    return null;
}

// --- Path resolution ---

/// Resolve a full path to an inode, following symlinks (including final component).
pub fn resolve(path: []const u8) ?*Inode {
    return resolveFollowing(path, 0);
}

/// Resolve a path to an inode without following the final symlink.
/// Used by readlink/lstat which need the symlink inode itself.
pub fn resolveNoFollow(path: []const u8) ?*Inode {
    const result = resolvePath(path);
    return result.inode;
}

fn resolveFollowing(path: []const u8, depth: u8) ?*Inode {
    if (depth >= 8) return null; // ELOOP
    const result = resolvePath(path);
    const inode = result.inode orelse return null;

    // Follow symlink in final component
    if (inode.mode & S_IFMT == S_IFLNK) {
        const readlink_fn = inode.ops.readlink orelse return null;
        var target_buf: [256]u8 = undefined;
        const len = readlink_fn(inode, &target_buf, 256);
        if (len <= 0) return null;
        const target_len: usize = @intCast(len);
        return resolveFollowing(target_buf[0..target_len], depth + 1);
    }

    return inode;
}

/// Resolve a path, returning both the target inode and the parent + leaf name.
/// If the leaf doesn't exist, inode is null but parent and leaf_name are set.
pub const ResolveResult = struct {
    inode: ?*Inode,
    parent: ?*Inode,
    leaf_name: [256]u8,
    leaf_len: u8,
};

pub fn resolvePath(path: []const u8) ResolveResult {
    var result = ResolveResult{
        .inode = null,
        .parent = null,
        .leaf_name = [_]u8{0} ** 256,
        .leaf_len = 0,
    };

    if (path.len == 0) return result;
    if (path[0] != '/') return result; // Absolute paths only

    const root = getRootInode() orelse return result;

    // "/" itself
    if (path.len == 1) {
        result.inode = root;
        return result;
    }

    var current: *Inode = root;
    var pos: usize = 1; // Skip leading '/'

    // Accumulated path buffer for mount-point matching
    var accum: [256]u8 = undefined;
    accum[0] = '/';
    var accum_len: usize = 1;

    while (pos < path.len) {
        // Skip consecutive slashes
        while (pos < path.len and path[pos] == '/') pos += 1;
        if (pos >= path.len) break;

        // Extract component
        const start = pos;
        while (pos < path.len and path[pos] != '/') pos += 1;
        const component = path[start..pos];

        if (component.len == 0) continue;
        if (component.len > 255) return result;

        // Check if current is a directory
        if (current.mode & S_IFMT != S_IFDIR) return result;

        // Handle "." — stay at current directory
        if (component.len == 1 and component[0] == '.') {
            // Check if this is the last component
            var tmp_pos = pos;
            while (tmp_pos < path.len and path[tmp_pos] == '/') tmp_pos += 1;
            if (pos >= path.len or tmp_pos >= path.len) {
                result.inode = current;
                result.parent = current;
                result.leaf_name[0] = '.';
                result.leaf_len = 1;
            }
            continue;
        }

        // Handle ".." — go to parent directory
        if (component.len == 2 and component[0] == '.' and component[1] == '.') {
            // Strip last component from accumulated path to walk up
            if (accum_len > 1) {
                // Remove trailing component: "/foo/bar" → "/foo"
                var k: usize = accum_len - 1;
                while (k > 0 and accum[k] != '/') k -= 1;
                if (k == 0) {
                    accum_len = 1; // Back to root "/"
                } else {
                    accum_len = k;
                }
            }
            // Re-resolve from root to the shortened path
            var parent_inode = root;
            if (accum_len > 1) {
                if (resolvePath(accum[0..accum_len]).inode) |resolved| {
                    parent_inode = resolved;
                }
            }
            current = parent_inode;

            var tmp_pos2 = pos;
            while (tmp_pos2 < path.len and path[tmp_pos2] == '/') tmp_pos2 += 1;
            if (pos >= path.len or tmp_pos2 >= path.len) {
                result.inode = current;
                result.parent = current;
                result.leaf_name[0] = '.';
                result.leaf_name[1] = '.';
                result.leaf_len = 2;
            }
            continue;
        }

        // Is this the last component?
        var at_end = pos >= path.len;
        if (!at_end) {
            var tmp = pos;
            while (tmp < path.len and path[tmp] == '/') tmp += 1;
            at_end = (tmp >= path.len);
        }

        if (at_end) {
            result.parent = current;
            const len = if (component.len > 255) 255 else component.len;
            for (0..len) |i| {
                result.leaf_name[i] = component[i];
            }
            result.leaf_len = @truncate(len);
        }

        // Build accumulated path: append "/" if needed, then component
        if (accum_len > 1 and accum_len < accum.len) {
            accum[accum_len] = '/';
            accum_len += 1;
        }
        const copy_len = @min(component.len, accum.len - accum_len);
        for (0..copy_len) |i| {
            accum[accum_len + i] = component[i];
        }
        accum_len += copy_len;

        // Check mount table BEFORE filesystem lookup — mount points may not
        // exist in the parent filesystem (e.g. /tmp not in ext2)
        if (findMount(accum[0..accum_len])) |mount_root| {
            current = mount_root;
            if (at_end) {
                result.inode = mount_root;
                result.parent = mount_root; // parent for creates inside mount root
            }
            continue;
        }

        // Per-inode filesystem lookup
        const lookup_fn = current.ops.lookup orelse return result;
        if (lookup_fn(current, component)) |child| {
            // Follow intermediate symlinks (not the final component)
            if (!at_end and child.mode & S_IFMT == S_IFLNK) {
                if (resolveFollowing(accum[0..accum_len], 0)) |resolved| {
                    current = resolved;
                } else {
                    return result; // Broken symlink in intermediate component
                }
            } else {
                current = child;
                if (at_end) {
                    result.inode = child;
                }
            }
        } else {
            return result; // parent + leaf_name set if this was last component
        }
    }

    // If we reach here without setting inode, path was just "/"
    if (result.inode == null and result.parent == null) {
        result.inode = current;
    }

    return result;
}

/// Find a mount point by exact path match (excluding "/" root).
fn findMount(path: []const u8) ?*Inode {
    // Don't match "/" — that's handled by getRootInode
    if (path.len == 1 and path[0] == '/') return null;

    for (0..MAX_MOUNTS) |i| {
        if (mounts[i].in_use) {
            const mp_len: usize = mounts[i].path_len;
            if (mp_len == path.len) {
                var match = true;
                for (0..mp_len) |j| {
                    if (mounts[i].path[j] != path[j]) {
                        match = false;
                        break;
                    }
                }
                if (match) return mounts[i].root_inode;
            }
        }
    }
    return null;
}

/// Fill a Stat struct from an inode.
pub fn statFromInode(inode: *const Inode, st: *Stat) void {
    st.st_ino = inode.ino;
    st.st_mode = inode.mode;
    st.st_nlink = inode.nlink;
    st.st_size = inode.size;
    st.st_uid = inode.uid;
    st.st_gid = inode.gid;
}

/// Read an entire file into a kernel buffer. Returns bytes read, or null on error.
/// Used by the kernel to load ELF binaries at boot and by execve.
pub fn readWholeFile(path: []const u8, buf: []u8) ?usize {
    const inode = resolve(path) orelse return null;

    // Must be a regular file
    if (inode.mode & S_IFMT != S_IFREG) return null;

    const read_fn = inode.ops.read orelse return null;

    var desc = FileDescription{
        .inode = inode,
        .offset = 0,
        .flags = O_RDONLY,
        .ref_count = 1,
        .in_use = true,
    };

    var total: usize = 0;
    while (total < buf.len) {
        const chunk = @min(buf.len - total, 4096);
        const ptr: [*]u8 = @ptrCast(&buf[total]);
        const n = read_fn(&desc, ptr, chunk);
        if (n <= 0) break;
        total += @intCast(n);
    }

    return total;
}
