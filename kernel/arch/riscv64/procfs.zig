/// procfs — virtual filesystem providing process and system information.
///
/// Mounted at /proc. Provides Linux-compatible entries:
///   /proc/self/status   — process status (PID, state, VmSize)
///   /proc/self/exe      — symlink to current executable
///   /proc/self/maps     — memory mappings (Linux format)
///   /proc/self/fd/      — directory of open file descriptors
///   /proc/self/cmdline  — process command line (NUL-separated)
///   /proc/uptime        — system uptime in seconds
///   /proc/meminfo       — memory statistics
///   /proc/cpuinfo       — CPU identification and features
///   /proc/version       — kernel version string
///   /proc/stat          — kernel/system statistics
///   /proc/filesystems   — supported filesystem types
///   /proc/loadavg       — load averages (stub)
///
/// Content is generated dynamically on each read from live kernel state.

const vfs = @import("vfs.zig");
const scheduler = @import("scheduler.zig");
const process = @import("process.zig");
const pmm = @import("pmm.zig");
const vma = @import("vma.zig");
const timer = @import("timer.zig");
const fd_table = @import("fd_table.zig");
const smp = @import("smp.zig");

const MAX_NODES: usize = 32;
const INO_BASE: u64 = 0x30000;

const NodeType = enum {
    root_dir,
    self_dir,
    self_fd_dir,
    uptime,
    meminfo,
    self_status,
    self_exe,
    self_maps,
    self_cmdline,
    version,
    cpuinfo,
    stat,
    filesystems,
    loadavg,
};

const MAX_CHILDREN: usize = 12;

const ProcfsNode = struct {
    name: [64]u8,
    name_len: u8,
    inode: vfs.Inode,
    node_type: NodeType,
    children: [MAX_CHILDREN]?*ProcfsNode,
    child_count: u8,
    parent: ?*ProcfsNode,
    in_use: bool,
};

var nodes: [MAX_NODES]ProcfsNode = undefined;
var next_ino: u64 = INO_BASE;
var initialized: bool = false;

// Scratch buffer for generating dynamic content — 8 KiB to handle large maps output
var scratch: [8192]u8 = undefined;

const procfs_dir_ops = vfs.FileOperations{
    .readdir = procfsReaddir,
    .lookup = procfsLookup,
};

const procfs_file_ops = vfs.FileOperations{
    .read = procfsRead,
    .readlink = procfsReadlink,
};

/// Separate ops for /proc/self/exe — it's a symlink, so inode mode is S_IFLNK.
/// read still works (returns exe path as text), but readlink is the primary interface.
const procfs_symlink_ops = vfs.FileOperations{
    .read = procfsRead,
    .readlink = procfsReadlink,
};

/// Separate ops for /proc/self/fd — dynamic directory that generates entries
/// from the current process's fd table at readdir/lookup time.
const procfs_fd_dir_ops = vfs.FileOperations{
    .readdir = procfsFdReaddir,
    .lookup = procfsFdLookup,
};

// ---- Init ----

pub fn init() *vfs.Inode {
    for (0..MAX_NODES) |i| {
        nodes[i].in_use = false;
        nodes[i].child_count = 0;
    }
    initialized = true;

    // Create /proc root
    const root = allocNode() orelse unreachable;
    setName(root, "proc");
    root.node_type = .root_dir;
    root.parent = null;
    root.inode.mode = vfs.S_IFDIR | 0o555;
    root.inode.nlink = 2;
    root.inode.ops = &procfs_dir_ops;

    // Create /proc/self
    const self_node = allocNode() orelse unreachable;
    setName(self_node, "self");
    self_node.node_type = .self_dir;
    self_node.parent = root;
    self_node.inode.mode = vfs.S_IFDIR | 0o555;
    self_node.inode.nlink = 2;
    self_node.inode.ops = &procfs_dir_ops;
    addChild(root, self_node);

    // Create /proc/uptime
    const uptime_node = allocNode() orelse unreachable;
    setName(uptime_node, "uptime");
    uptime_node.node_type = .uptime;
    uptime_node.parent = root;
    uptime_node.inode.mode = vfs.S_IFREG | 0o444;
    uptime_node.inode.nlink = 1;
    uptime_node.inode.ops = &procfs_file_ops;
    addChild(root, uptime_node);

    // Create /proc/meminfo
    const meminfo_node = allocNode() orelse unreachable;
    setName(meminfo_node, "meminfo");
    meminfo_node.node_type = .meminfo;
    meminfo_node.parent = root;
    meminfo_node.inode.mode = vfs.S_IFREG | 0o444;
    meminfo_node.inode.nlink = 1;
    meminfo_node.inode.ops = &procfs_file_ops;
    addChild(root, meminfo_node);

    // Create /proc/version
    const version_node = allocNode() orelse unreachable;
    setName(version_node, "version");
    version_node.node_type = .version;
    version_node.parent = root;
    version_node.inode.mode = vfs.S_IFREG | 0o444;
    version_node.inode.nlink = 1;
    version_node.inode.ops = &procfs_file_ops;
    addChild(root, version_node);

    // Create /proc/cpuinfo
    const cpuinfo_node = allocNode() orelse unreachable;
    setName(cpuinfo_node, "cpuinfo");
    cpuinfo_node.node_type = .cpuinfo;
    cpuinfo_node.parent = root;
    cpuinfo_node.inode.mode = vfs.S_IFREG | 0o444;
    cpuinfo_node.inode.nlink = 1;
    cpuinfo_node.inode.ops = &procfs_file_ops;
    addChild(root, cpuinfo_node);

    // Create /proc/stat
    const stat_node = allocNode() orelse unreachable;
    setName(stat_node, "stat");
    stat_node.node_type = .stat;
    stat_node.parent = root;
    stat_node.inode.mode = vfs.S_IFREG | 0o444;
    stat_node.inode.nlink = 1;
    stat_node.inode.ops = &procfs_file_ops;
    addChild(root, stat_node);

    // Create /proc/filesystems
    const fs_node = allocNode() orelse unreachable;
    setName(fs_node, "filesystems");
    fs_node.node_type = .filesystems;
    fs_node.parent = root;
    fs_node.inode.mode = vfs.S_IFREG | 0o444;
    fs_node.inode.nlink = 1;
    fs_node.inode.ops = &procfs_file_ops;
    addChild(root, fs_node);

    // Create /proc/loadavg
    const loadavg_node = allocNode() orelse unreachable;
    setName(loadavg_node, "loadavg");
    loadavg_node.node_type = .loadavg;
    loadavg_node.parent = root;
    loadavg_node.inode.mode = vfs.S_IFREG | 0o444;
    loadavg_node.inode.nlink = 1;
    loadavg_node.inode.ops = &procfs_file_ops;
    addChild(root, loadavg_node);

    // Create /proc/self/status
    const status_node = allocNode() orelse unreachable;
    setName(status_node, "status");
    status_node.node_type = .self_status;
    status_node.parent = self_node;
    status_node.inode.mode = vfs.S_IFREG | 0o444;
    status_node.inode.nlink = 1;
    status_node.inode.ops = &procfs_file_ops;
    addChild(self_node, status_node);

    // Create /proc/self/exe — symlink to current executable
    const exe_node = allocNode() orelse unreachable;
    setName(exe_node, "exe");
    exe_node.node_type = .self_exe;
    exe_node.parent = self_node;
    exe_node.inode.mode = vfs.S_IFLNK | 0o777;
    exe_node.inode.nlink = 1;
    exe_node.inode.ops = &procfs_symlink_ops;
    addChild(self_node, exe_node);

    // Create /proc/self/maps
    const maps_node = allocNode() orelse unreachable;
    setName(maps_node, "maps");
    maps_node.node_type = .self_maps;
    maps_node.parent = self_node;
    maps_node.inode.mode = vfs.S_IFREG | 0o444;
    maps_node.inode.nlink = 1;
    maps_node.inode.ops = &procfs_file_ops;
    addChild(self_node, maps_node);

    // Create /proc/self/cmdline
    const cmdline_node = allocNode() orelse unreachable;
    setName(cmdline_node, "cmdline");
    cmdline_node.node_type = .self_cmdline;
    cmdline_node.parent = self_node;
    cmdline_node.inode.mode = vfs.S_IFREG | 0o444;
    cmdline_node.inode.nlink = 1;
    cmdline_node.inode.ops = &procfs_file_ops;
    addChild(self_node, cmdline_node);

    // Create /proc/self/fd — dynamic directory of open file descriptors
    const fd_dir_node = allocNode() orelse unreachable;
    setName(fd_dir_node, "fd");
    fd_dir_node.node_type = .self_fd_dir;
    fd_dir_node.parent = self_node;
    fd_dir_node.inode.mode = vfs.S_IFDIR | 0o555;
    fd_dir_node.inode.nlink = 2;
    fd_dir_node.inode.ops = &procfs_fd_dir_ops;
    addChild(self_node, fd_dir_node);

    return &root.inode;
}

// ---- Lookup ----

fn procfsLookup(parent: *vfs.Inode, name: []const u8) ?*vfs.Inode {
    const node: *ProcfsNode = @alignCast(@ptrCast(parent.fs_data orelse return null));

    for (0..node.child_count) |i| {
        const child = node.children[i] orelse continue;
        if (nameEq(child, name)) {
            return &child.inode;
        }
    }

    // For root_dir, support numeric PID lookups (e.g., /proc/1).
    // We resolve any numeric name to /proc/self's inode if the PID matches
    // a live process, so that /proc/<pid>/maps etc. work.
    if (node.node_type == .root_dir) {
        const pid = parseDec(name) orelse return null;
        if (process.findByPid(pid) != null) {
            // Return the "self" directory's inode — content generators already
            // read from the calling process. For per-PID accuracy in the future,
            // store the target PID in a dynamic node. For now, returning "self"
            // makes /proc/<mypid>/maps work correctly for the common case where
            // a process reads its own /proc/<pid>/ entries.
            for (0..node.child_count) |i| {
                const child = node.children[i] orelse continue;
                if (child.node_type == .self_dir) return &child.inode;
            }
        }
    }

    return null;
}

// ---- Read ----

fn procfsRead(desc: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    const node: *ProcfsNode = @alignCast(@ptrCast(desc.inode.fs_data orelse return 0));
    const offset = desc.offset;

    // Generate content into scratch buffer
    const content_len = generateContent(node);
    if (content_len == 0) return 0;

    // Serve from scratch at current offset
    if (offset >= content_len) return 0;
    const avail = content_len - offset;
    const to_copy = if (count < avail) count else avail;

    for (0..to_copy) |i| {
        buf[i] = scratch[@as(usize, @truncate(offset)) + i];
    }
    desc.offset += to_copy;
    return @intCast(to_copy);
}

// ---- Readlink (for /proc/self/exe) ----

fn procfsReadlink(inode: *vfs.Inode, buf: [*]u8, bufsiz: usize) isize {
    const node: *ProcfsNode = @alignCast(@ptrCast(inode.fs_data orelse return -1));
    if (node.node_type != .self_exe) return -1;

    const proc = scheduler.currentProcess() orelse return -1;
    const len: usize = proc.exe_path_len;
    if (len == 0) return -1;
    const to_copy = if (bufsiz < len) bufsiz else len;
    for (0..to_copy) |i| {
        buf[i] = proc.exe_path[i];
    }
    return @intCast(to_copy);
}

// ---- Readdir ----

fn procfsReaddir(desc: *vfs.FileDescription, entry: *vfs.DirEntry) bool {
    const node: *ProcfsNode = @alignCast(@ptrCast(desc.inode.fs_data orelse return false));
    const idx = @as(usize, @truncate(desc.offset));

    // For root_dir: after static children, enumerate live PIDs as directories
    if (node.node_type == .root_dir) {
        if (idx < node.child_count) {
            // Static children first
            const child = node.children[idx] orelse return false;
            for (0..child.name_len) |i| {
                entry.name[i] = child.name[i];
            }
            entry.name_len = child.name_len;
            entry.ino = child.inode.ino;
            entry.d_type = if (child.inode.mode & vfs.S_IFMT == vfs.S_IFDIR) vfs.DT_DIR else if (child.inode.mode & vfs.S_IFMT == vfs.S_IFLNK) vfs.DT_LNK else vfs.DT_REG;
            desc.offset += 1;
            return true;
        }
        // After static children, enumerate PIDs
        const pid_offset = idx - node.child_count;
        var seen: usize = 0;
        for (0..process.MAX_PROCESSES) |i| {
            if (process.getProcess(i)) |proc| {
                if (seen == pid_offset) {
                    // Format PID as decimal string
                    const name_len = decToStr(proc.pid, &entry.name);
                    entry.name_len = @truncate(name_len);
                    entry.ino = INO_BASE + 0x1000 + proc.pid;
                    entry.d_type = vfs.DT_DIR;
                    desc.offset += 1;
                    return true;
                }
                seen += 1;
            }
        }
        return false;
    }

    // Non-root directories: just enumerate static children
    if (idx >= node.child_count) return false;
    const child = node.children[idx] orelse return false;

    for (0..child.name_len) |i| {
        entry.name[i] = child.name[i];
    }
    entry.name_len = child.name_len;
    entry.ino = child.inode.ino;
    entry.d_type = if (child.inode.mode & vfs.S_IFMT == vfs.S_IFDIR) vfs.DT_DIR else if (child.inode.mode & vfs.S_IFMT == vfs.S_IFLNK) vfs.DT_LNK else vfs.DT_REG;

    desc.offset += 1;
    return true;
}

// ---- /proc/self/fd/ — dynamic directory ----

/// Static inode pool for /proc/self/fd/<n> symlinks.
/// Each entry is a symlink whose readlink returns the path of the fd's underlying file.
/// We reuse a small pool since only one readdir/lookup can be active at a time per CPU.
const MAX_FD_INODES: usize = 16;
var fd_inodes: [MAX_FD_INODES]vfs.Inode = undefined;
var fd_inode_fds: [MAX_FD_INODES]u16 = [_]u16{0} ** MAX_FD_INODES; // fd number for readlink
var fd_inode_next: usize = 0;

const procfs_fd_symlink_ops = vfs.FileOperations{
    .readlink = procfsFdReadlink,
};

fn procfsFdLookup(_parent: *vfs.Inode, name: []const u8) ?*vfs.Inode {
    _ = _parent;
    const fd_num = parseDec(name) orelse return null;
    if (fd_num >= fd_table.MAX_FDS) return null;

    const proc = scheduler.currentProcess() orelse return null;
    if (proc.fds[@as(usize, @truncate(fd_num))] == null) return null;

    // Allocate a dynamic inode for this fd symlink
    const slot = fd_inode_next % MAX_FD_INODES;
    fd_inode_next +%= 1;
    fd_inodes[slot] = .{
        .ino = INO_BASE + 0x2000 + fd_num,
        .mode = vfs.S_IFLNK | 0o777,
        .size = 0,
        .nlink = 1,
        .ops = &procfs_fd_symlink_ops,
        .fs_data = null,
    };
    fd_inode_fds[slot] = @truncate(fd_num);
    // Store slot index in rdev field so readlink can find the fd number
    fd_inodes[slot].rdev = @truncate(slot);
    return &fd_inodes[slot];
}

fn procfsFdReadlink(inode: *vfs.Inode, buf: [*]u8, bufsiz: usize) isize {
    const slot = inode.rdev;
    if (slot >= MAX_FD_INODES) return -1;
    const fd_num: usize = fd_inode_fds[slot];

    const proc = scheduler.currentProcess() orelse return -1;
    if (fd_num >= fd_table.MAX_FDS) return -1;
    const desc = proc.fds[fd_num] orelse return -1;

    // Try to identify the file — check inode number and mode
    const ino = desc.inode.ino;
    const mode = desc.inode.mode & vfs.S_IFMT;

    // Format: "type:[inode]" for non-regular files, or try to find path
    var tmp: [128]u8 = undefined;
    var len: usize = 0;

    if (mode == vfs.S_IFCHR) {
        const prefix = "pipe:";
        // Character devices (UART/console)
        const label = "/dev/console";
        for (label) |c| {
            if (len < tmp.len) {
                tmp[len] = c;
                len += 1;
            }
        }
        _ = prefix;
    } else if (mode == vfs.S_IFIFO) {
        const label = "pipe:[";
        for (label) |c| {
            if (len < tmp.len) {
                tmp[len] = c;
                len += 1;
            }
        }
        len = appendDecSmall(&tmp, len, ino);
        if (len < tmp.len) {
            tmp[len] = ']';
            len += 1;
        }
    } else if (mode == vfs.S_IFSOCK) {
        const label = "socket:[";
        for (label) |c| {
            if (len < tmp.len) {
                tmp[len] = c;
                len += 1;
            }
        }
        len = appendDecSmall(&tmp, len, ino);
        if (len < tmp.len) {
            tmp[len] = ']';
            len += 1;
        }
    } else {
        // Regular/directory — use inode number as fallback path identifier
        const label = "/proc/self/fd/";
        for (label) |c| {
            if (len < tmp.len) {
                tmp[len] = c;
                len += 1;
            }
        }
        len = appendDecSmall(&tmp, len, fd_num);
    }

    const to_copy = if (bufsiz < len) bufsiz else len;
    for (0..to_copy) |i| {
        buf[i] = tmp[i];
    }
    return @intCast(to_copy);
}

fn procfsFdReaddir(desc: *vfs.FileDescription, entry: *vfs.DirEntry) bool {
    const proc = scheduler.currentProcess() orelse return false;
    const start_fd = @as(usize, @truncate(desc.offset));

    // Find next open fd starting from current offset
    var fd: usize = start_fd;
    while (fd < fd_table.MAX_FDS) : (fd += 1) {
        if (proc.fds[fd] != null) {
            // Format fd number as name
            const name_len = decToStr(fd, &entry.name);
            entry.name_len = @truncate(name_len);
            entry.ino = INO_BASE + 0x2000 + fd;
            entry.d_type = vfs.DT_LNK;
            desc.offset = @intCast(fd + 1);
            return true;
        }
    }
    return false;
}

// ---- Content generation ----

fn generateContent(node: *ProcfsNode) u64 {
    var pos: usize = 0;

    switch (node.node_type) {
        .uptime => {
            const ticks = timer.getTicks();
            const secs = ticks / 100;
            const centisecs = ticks % 100;
            pos = appendStr(&scratch, pos, "");
            pos = appendDec(&scratch, pos, secs);
            scratch[pos] = '.';
            pos += 1;
            // Zero-pad centiseconds to 2 digits
            if (centisecs < 10) {
                scratch[pos] = '0';
                pos += 1;
            }
            pos = appendDec(&scratch, pos, centisecs);
            pos = appendStr(&scratch, pos, " 0.00\n");
        },
        .meminfo => {
            const total_kb = pmm.getTotalPages() * 4; // 4KB per page
            const free_kb = pmm.getFreePages() * 4;
            // MemAvailable approximation: free memory (no page cache in our kernel)
            const avail_kb = free_kb;

            pos = appendStr(&scratch, pos, "MemTotal:       ");
            pos = appendDecPadded(&scratch, pos, total_kb, 8);
            pos = appendStr(&scratch, pos, " kB\nMemFree:        ");
            pos = appendDecPadded(&scratch, pos, free_kb, 8);
            pos = appendStr(&scratch, pos, " kB\nMemAvailable:   ");
            pos = appendDecPadded(&scratch, pos, avail_kb, 8);
            pos = appendStr(&scratch, pos, " kB\nBuffers:        ");
            pos = appendDecPadded(&scratch, pos, 0, 8);
            pos = appendStr(&scratch, pos, " kB\nCached:         ");
            pos = appendDecPadded(&scratch, pos, 0, 8);
            pos = appendStr(&scratch, pos, " kB\nSwapCached:     ");
            pos = appendDecPadded(&scratch, pos, 0, 8);
            pos = appendStr(&scratch, pos, " kB\nSwapTotal:      ");
            pos = appendDecPadded(&scratch, pos, 0, 8);
            pos = appendStr(&scratch, pos, " kB\nSwapFree:       ");
            pos = appendDecPadded(&scratch, pos, 0, 8);
            pos = appendStr(&scratch, pos, " kB\n");
        },
        .self_status => {
            const proc = scheduler.currentProcess() orelse return 0;
            pos = appendStr(&scratch, pos, "Name:\t");
            // Use exe path basename as Name
            var name_start: usize = 0;
            for (0..proc.exe_path_len) |i| {
                if (proc.exe_path[i] == '/') name_start = i + 1;
            }
            for (name_start..proc.exe_path_len) |i| {
                if (pos < scratch.len) {
                    scratch[pos] = proc.exe_path[i];
                    pos += 1;
                }
            }
            pos = appendStr(&scratch, pos, "\nUmask:\t");
            pos = appendOct(&scratch, pos, proc.umask_val);
            pos = appendStr(&scratch, pos, "\nState:\t");
            pos = appendStr(&scratch, pos, stateChar(proc.state));
            pos = appendStr(&scratch, pos, " (");
            pos = appendStr(&scratch, pos, stateStr(proc.state));
            pos = appendStr(&scratch, pos, ")\nTgid:\t");
            pos = appendDec(&scratch, pos, proc.tgid);
            pos = appendStr(&scratch, pos, "\nPid:\t");
            pos = appendDec(&scratch, pos, proc.pid);
            pos = appendStr(&scratch, pos, "\nPPid:\t");
            pos = appendDec(&scratch, pos, proc.parent_pid);
            pos = appendStr(&scratch, pos, "\nUid:\t");
            pos = appendDec(&scratch, pos, proc.uid);
            pos = appendStr(&scratch, pos, "\t");
            pos = appendDec(&scratch, pos, proc.euid);
            pos = appendStr(&scratch, pos, "\t");
            pos = appendDec(&scratch, pos, proc.uid);
            pos = appendStr(&scratch, pos, "\t");
            pos = appendDec(&scratch, pos, proc.uid);
            pos = appendStr(&scratch, pos, "\nGid:\t");
            pos = appendDec(&scratch, pos, proc.gid);
            pos = appendStr(&scratch, pos, "\t");
            pos = appendDec(&scratch, pos, proc.egid);
            pos = appendStr(&scratch, pos, "\t");
            pos = appendDec(&scratch, pos, proc.gid);
            pos = appendStr(&scratch, pos, "\t");
            pos = appendDec(&scratch, pos, proc.gid);
            pos = appendStr(&scratch, pos, "\nVmSize:\t");
            // Count in-use VMAs and sum their sizes
            var vm_kb: u64 = 0;
            for (0..vma.MAX_VMAS) |i| {
                if (proc.vmas[i].in_use) {
                    vm_kb += (proc.vmas[i].end - proc.vmas[i].start) / 1024;
                }
            }
            pos = appendDec(&scratch, pos, vm_kb);
            pos = appendStr(&scratch, pos, " kB\nThreads:\t1\n");
        },
        .self_exe => {
            // When read as a file (not readlink), return exe path
            const proc = scheduler.currentProcess() orelse return 0;
            for (0..proc.exe_path_len) |i| {
                if (pos < scratch.len) {
                    scratch[pos] = proc.exe_path[i];
                    pos += 1;
                }
            }
        },
        .self_cmdline => {
            // Return exe path as cmdline (NUL-terminated, no trailing newline)
            const proc = scheduler.currentProcess() orelse return 0;
            for (0..proc.exe_path_len) |i| {
                if (pos < scratch.len) {
                    scratch[pos] = proc.exe_path[i];
                    pos += 1;
                }
            }
            // NUL terminator (Linux /proc/self/cmdline uses NUL separators)
            if (pos < scratch.len) {
                scratch[pos] = 0;
                pos += 1;
            }
        },
        .self_maps => {
            const proc = scheduler.currentProcess() orelse return 0;
            for (0..vma.MAX_VMAS) |i| {
                if (!proc.vmas[i].in_use) continue;
                const v = &proc.vmas[i];
                // Linux format: start-end perms offset dev inode pathname
                // Example: 00400000-00401000 r-xp 00000000 00:00 0          /bin/hello
                pos = appendHex(&scratch, pos, v.start, 12);
                scratch[pos] = '-';
                pos += 1;
                pos = appendHex(&scratch, pos, v.end, 12);
                scratch[pos] = ' ';
                pos += 1;
                // Permissions: rwxp/rwxs
                scratch[pos] = if (v.flags.readable) 'r' else '-';
                pos += 1;
                scratch[pos] = if (v.flags.writable) 'w' else '-';
                pos += 1;
                scratch[pos] = if (v.flags.executable) 'x' else '-';
                pos += 1;
                scratch[pos] = if (v.flags.shared) 's' else 'p';
                pos += 1;
                scratch[pos] = ' ';
                pos += 1;
                // Offset
                pos = appendHex(&scratch, pos, v.file_offset, 8);
                scratch[pos] = ' ';
                pos += 1;
                // Device (major:minor) — we use 00:00 for anonymous, fd:00 for file-backed
                if (v.file != null) {
                    pos = appendStr(&scratch, pos, "fd:00");
                } else {
                    pos = appendStr(&scratch, pos, "00:00");
                }
                scratch[pos] = ' ';
                pos += 1;
                // Inode number — 0 for anonymous
                if (v.file) |f| {
                    pos = appendDec(&scratch, pos, f.inode.ino);
                } else {
                    scratch[pos] = '0';
                    pos += 1;
                }
                // Pathname — identify VMA type
                if (v.flags.stack) {
                    pos = appendStr(&scratch, pos, "                           [stack]");
                } else if (v.file != null and i == 0) {
                    // First file-backed VMA is likely the executable
                    pos = appendStr(&scratch, pos, "           ");
                    for (0..proc.exe_path_len) |j| {
                        if (pos < scratch.len) {
                            scratch[pos] = proc.exe_path[j];
                            pos += 1;
                        }
                    }
                } else if (v.start == proc.heap_start) {
                    pos = appendStr(&scratch, pos, "                           [heap]");
                }
                scratch[pos] = '\n';
                pos += 1;
                if (pos >= scratch.len - 128) break; // Safety margin
            }
        },
        .version => {
            pos = appendStr(&scratch, pos, "Zigix version 1.0.0 (aarch64) (zig 0.16) #1 SMP\n");
        },
        .cpuinfo => {
            // Use runtime-detected CPU identification from cpu_features module
            const cpu_feat = @import("cpu_features.zig");
            const cpuid = cpu_feat.cpu_id;
            const feat = cpu_feat.features;

            // Enumerate per-CPU entries (Linux shows one block per logical CPU)
            var cpu_id: u32 = 0;
            while (cpu_id < smp.online_cpus) : (cpu_id += 1) {
                if (cpu_id > 0) {
                    // Blank line between CPU entries
                    pos = appendStr(&scratch, pos, "\n");
                }
                pos = appendStr(&scratch, pos, "processor\t: ");
                pos = appendDec(&scratch, pos, cpu_id);
                pos = appendStr(&scratch, pos, "\nBogoMIPS\t: 48.00\n");
                pos = appendStr(&scratch, pos, "CPU implementer\t: 0x");
                pos = appendHex(&scratch, pos, cpuid.implementer, 2);
                pos = appendStr(&scratch, pos, "\nCPU variant\t: 0x");
                pos = appendHex(&scratch, pos, @as(u8, cpuid.variant), 1);
                pos = appendStr(&scratch, pos, "\nCPU part\t: 0x");
                pos = appendHex(&scratch, pos, cpuid.part_number, 3);
                pos = appendStr(&scratch, pos, "\nCPU revision\t: ");
                pos = appendDec(&scratch, pos, @as(u32, cpuid.revision));
                pos = appendStr(&scratch, pos, "\nmodel name\t: ");
                pos = appendStr(&scratch, pos, cpuid.implementerName());
                pos = appendStr(&scratch, pos, " ");
                pos = appendStr(&scratch, pos, cpuid.partName());
                pos = appendStr(&scratch, pos, "\n");

                // Feature flags (Linux-compatible format)
                pos = appendStr(&scratch, pos, "Features\t:");
                if (feat.fp) pos = appendStr(&scratch, pos, " fp");
                if (feat.asimd) pos = appendStr(&scratch, pos, " asimd");
                if (feat.aes) pos = appendStr(&scratch, pos, " aes");
                if (feat.pmull) pos = appendStr(&scratch, pos, " pmull");
                if (feat.sha1) pos = appendStr(&scratch, pos, " sha1");
                if (feat.sha256) pos = appendStr(&scratch, pos, " sha2");
                if (feat.crc32) pos = appendStr(&scratch, pos, " crc32");
                if (feat.lse) pos = appendStr(&scratch, pos, " atomics");
                if (feat.fp16) pos = appendStr(&scratch, pos, " fphp asimdhp");
                if (feat.dot_prod) pos = appendStr(&scratch, pos, " asimddp");
                if (feat.sve) pos = appendStr(&scratch, pos, " sve");
                if (feat.sve2) pos = appendStr(&scratch, pos, " sve2");
                if (feat.pan) pos = appendStr(&scratch, pos, " pan");
                if (feat.pauth) pos = appendStr(&scratch, pos, " paca pacg");
                if (feat.bti) pos = appendStr(&scratch, pos, " bti");
                if (feat.mte) pos = appendStr(&scratch, pos, " mte");
                if (feat.rng) pos = appendStr(&scratch, pos, " rng");
                if (feat.sb) pos = appendStr(&scratch, pos, " sb");
                if (feat.ras) pos = appendStr(&scratch, pos, " ras");
                if (feat.fcma) pos = appendStr(&scratch, pos, " fcma");
                if (feat.jscvt) pos = appendStr(&scratch, pos, " jscvt");
                pos = appendStr(&scratch, pos, "\n");

                // SVE vector length
                if (feat.sve) {
                    pos = appendStr(&scratch, pos, "SVE vector length\t: ");
                    pos = appendDec(&scratch, pos, @as(u32, feat.sve_vl_bytes) * 8);
                    pos = appendStr(&scratch, pos, " bits\n");
                }

                if (pos >= scratch.len - 512) break; // Safety margin
            }
        },
        .stat => {
            // Linux-compatible /proc/stat format
            pos = appendStr(&scratch, pos, "cpu  0 0 0 0 0 0 0 0 0 0\n");

            // Per-CPU lines
            var cpu_id: u32 = 0;
            while (cpu_id < smp.online_cpus) : (cpu_id += 1) {
                pos = appendStr(&scratch, pos, "cpu");
                pos = appendDec(&scratch, pos, cpu_id);
                pos = appendStr(&scratch, pos, " 0 0 0 0 0 0 0 0 0 0\n");
            }

            const ticks = timer.getTicks();
            pos = appendStr(&scratch, pos, "btime ");
            pos = appendDec(&scratch, pos, ticks / 100);
            // Count running processes
            var nprocs: u64 = 0;
            for (0..process.MAX_PROCESSES) |i| {
                if (process.getProcess(i) != null) nprocs += 1;
            }
            pos = appendStr(&scratch, pos, "\nprocesses ");
            pos = appendDec(&scratch, pos, nprocs);
            pos = appendStr(&scratch, pos, "\nprocs_running ");
            pos = appendDec(&scratch, pos, smp.online_cpus);
            pos = appendStr(&scratch, pos, "\nprocs_blocked 0\n");
        },
        .filesystems => {
            pos = appendStr(&scratch, pos, "nodev\tproc\n");
            pos = appendStr(&scratch, pos, "nodev\ttmpfs\n");
            pos = appendStr(&scratch, pos, "nodev\tramfs\n");
            pos = appendStr(&scratch, pos, "nodev\tdevfs\n");
            pos = appendStr(&scratch, pos, "\text2\n");
            pos = appendStr(&scratch, pos, "\text3\n");
        },
        .loadavg => {
            // Stub — many programs just need it to exist and be parseable
            pos = appendStr(&scratch, pos, "0.00 0.00 0.00 1/");
            var nprocs: u64 = 0;
            for (0..process.MAX_PROCESSES) |i| {
                if (process.getProcess(i) != null) nprocs += 1;
            }
            pos = appendDec(&scratch, pos, nprocs);
            pos = appendStr(&scratch, pos, " ");
            // Last PID
            const proc = scheduler.currentProcess();
            const last_pid = if (proc) |p| p.pid else 1;
            pos = appendDec(&scratch, pos, last_pid);
            pos = appendStr(&scratch, pos, "\n");
        },
        else => return 0,
    }

    return pos;
}

fn stateStr(state: process.ProcessState) []const u8 {
    return switch (state) {
        .ready => "ready",
        .running => "running",
        .blocked => "sleeping",
        .blocked_on_pipe => "sleeping",
        .blocked_on_wait => "sleeping",
        .blocked_on_futex => "sleeping",
        .blocked_on_net => "sleeping",
        .stopped => "stopped",
        .zombie => "zombie",
    };
}

fn stateChar(state: process.ProcessState) []const u8 {
    return switch (state) {
        .ready => "R",
        .running => "R",
        .blocked, .blocked_on_pipe, .blocked_on_wait, .blocked_on_futex, .blocked_on_net => "S",
        .stopped => "T",
        .zombie => "Z",
    };
}

// ---- Formatting helpers ----

fn appendStr(buf: *[8192]u8, pos: usize, s: []const u8) usize {
    var p = pos;
    for (s) |c| {
        if (p >= buf.len) break;
        buf[p] = c;
        p += 1;
    }
    return p;
}

fn appendDec(buf: *[8192]u8, pos: usize, value: u64) usize {
    if (value == 0) {
        if (pos < buf.len) {
            buf[pos] = '0';
            return pos + 1;
        }
        return pos;
    }
    var tmp: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        tmp[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    var p = pos;
    while (i < 20) {
        if (p >= buf.len) break;
        buf[p] = tmp[i];
        p += 1;
        i += 1;
    }
    return p;
}

/// Append a decimal value right-justified in a field of `width` characters.
fn appendDecPadded(buf: *[8192]u8, pos: usize, value: u64, width: usize) usize {
    // First format the number to find its length
    var tmp: [20]u8 = undefined;
    var v = value;
    var digits: usize = 0;
    if (v == 0) {
        tmp[19] = '0';
        digits = 1;
    } else {
        var idx: usize = 20;
        while (v > 0) {
            idx -= 1;
            tmp[idx] = @truncate((v % 10) + '0');
            v /= 10;
            digits += 1;
        }
    }

    var p = pos;
    // Pad with spaces
    var pad = if (width > digits) width - digits else 0;
    while (pad > 0) : (pad -= 1) {
        if (p >= buf.len) break;
        buf[p] = ' ';
        p += 1;
    }
    // Write digits
    const start = 20 - digits;
    var idx2 = start;
    while (idx2 < 20) {
        if (p >= buf.len) break;
        buf[p] = tmp[idx2];
        p += 1;
        idx2 += 1;
    }
    return p;
}

fn appendOct(buf: *[8192]u8, pos: usize, value: u32) usize {
    // Format as octal with leading zeros (4 digits)
    var p = pos;
    const digits = [_]u8{
        @truncate(((value >> 9) & 0o7) + '0'),
        @truncate(((value >> 6) & 0o7) + '0'),
        @truncate(((value >> 3) & 0o7) + '0'),
        @truncate((value & 0o7) + '0'),
    };
    for (digits) |d| {
        if (p >= buf.len) break;
        buf[p] = d;
        p += 1;
    }
    return p;
}

fn appendHex(buf: *[8192]u8, pos: usize, value: u64, width: usize) usize {
    const hex = "0123456789abcdef";
    if (width > 16) return pos;
    var p = pos;
    var w: usize = 0;
    while (w < width) {
        if (p >= buf.len) break;
        const shift: u6 = @truncate((width - 1 - w) * 4);
        const nibble: usize = @truncate((value >> shift) & 0xF);
        buf[p] = hex[nibble];
        p += 1;
        w += 1;
    }
    return p;
}

/// Decimal to string into a small buffer (for fd numbers, PIDs in directory entries)
fn appendDecSmall(buf: *[128]u8, pos: usize, value: u64) usize {
    if (value == 0) {
        if (pos < buf.len) {
            buf[pos] = '0';
            return pos + 1;
        }
        return pos;
    }
    var tmp: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        tmp[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    var p = pos;
    while (i < 20) {
        if (p >= buf.len) break;
        buf[p] = tmp[i];
        p += 1;
        i += 1;
    }
    return p;
}

/// Format a u64 as decimal into a name buffer, return length written.
fn decToStr(value: u64, buf: *[256]u8) usize {
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        tmp[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    var len: usize = 0;
    while (i < 20) {
        buf[len] = tmp[i];
        len += 1;
        i += 1;
    }
    return len;
}

/// Parse a decimal number from a string. Returns null on invalid input.
fn parseDec(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        result = result *% 10 +% (c - '0');
    }
    return result;
}

// ---- Node management ----

fn allocNode() ?*ProcfsNode {
    for (0..MAX_NODES) |i| {
        if (!nodes[i].in_use) {
            nodes[i].in_use = true;
            nodes[i].child_count = 0;
            nodes[i].parent = null;
            for (0..MAX_CHILDREN) |j| {
                nodes[i].children[j] = null;
            }
            nodes[i].inode = .{
                .ino = next_ino,
                .mode = 0,
                .size = 0,
                .nlink = 1,
                .ops = &procfs_file_ops,
                .fs_data = @ptrCast(&nodes[i]),
            };
            next_ino += 1;
            return &nodes[i];
        }
    }
    return null;
}

fn setName(node: *ProcfsNode, name: []const u8) void {
    const len = if (name.len > 63) 63 else name.len;
    for (0..len) |i| {
        node.name[i] = name[i];
    }
    node.name_len = @truncate(len);
}

fn addChild(parent: *ProcfsNode, child: *ProcfsNode) void {
    if (parent.child_count < MAX_CHILDREN) {
        parent.children[parent.child_count] = child;
        parent.child_count += 1;
    }
}

fn nameEq(node: *ProcfsNode, name: []const u8) bool {
    if (node.name_len != name.len) return false;
    for (0..name.len) |i| {
        if (node.name[i] != name[i]) return false;
    }
    return true;
}
