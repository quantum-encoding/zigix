/// procfs — virtual filesystem providing process and system information.
///
/// Mounted at /proc. Provides /proc/self/status, /proc/self/exe,
/// /proc/self/maps, /proc/uptime, /proc/meminfo.
/// Content is generated dynamically on each read from live kernel state.

const vfs = @import("vfs.zig");
const scheduler = @import("../proc/scheduler.zig");
const process = @import("../proc/process.zig");
const pmm = @import("../mm/pmm.zig");
const vma = @import("../mm/vma.zig");
const idt = @import("../arch/x86_64/idt.zig");

const MAX_NODES: usize = 24;
const INO_BASE: u64 = 0x30000;

const NodeType = enum {
    root_dir,
    self_dir,
    uptime,
    meminfo,
    self_status,
    self_exe,
    self_maps,
    version,
    cpuinfo,
    stat,
};

const MAX_CHILDREN: usize = 8;

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

// Scratch buffer for generating dynamic content
var scratch: [4096]u8 = undefined;

const procfs_dir_ops = vfs.FileOperations{
    .readdir = procfsReaddir,
    .lookup = procfsLookup,
};

const procfs_file_ops = vfs.FileOperations{
    .read = procfsRead,
    .readlink = procfsReadlink,
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

    // Create /proc/self/status
    const status_node = allocNode() orelse unreachable;
    setName(status_node, "status");
    status_node.node_type = .self_status;
    status_node.parent = self_node;
    status_node.inode.mode = vfs.S_IFREG | 0o444;
    status_node.inode.nlink = 1;
    status_node.inode.ops = &procfs_file_ops;
    addChild(self_node, status_node);

    // Create /proc/self/exe
    const exe_node = allocNode() orelse unreachable;
    setName(exe_node, "exe");
    exe_node.node_type = .self_exe;
    exe_node.parent = self_node;
    exe_node.inode.mode = vfs.S_IFREG | 0o444;
    exe_node.inode.nlink = 1;
    exe_node.inode.ops = &procfs_file_ops;
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

    if (idx >= node.child_count) return false;
    const child = node.children[idx] orelse return false;

    for (0..child.name_len) |i| {
        entry.name[i] = child.name[i];
    }
    entry.name_len = child.name_len;
    entry.ino = child.inode.ino;
    entry.d_type = if (child.inode.mode & vfs.S_IFMT == vfs.S_IFDIR) vfs.DT_DIR else vfs.DT_REG;

    desc.offset += 1;
    return true;
}

// ---- Content generation ----

fn generateContent(node: *ProcfsNode) u64 {
    var pos: usize = 0;

    switch (node.node_type) {
        .uptime => {
            const ticks = idt.getTickCount();
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
            pos = appendStr(&scratch, pos, "MemTotal:   ");
            pos = appendDec(&scratch, pos, total_kb);
            pos = appendStr(&scratch, pos, " kB\nMemFree:    ");
            pos = appendDec(&scratch, pos, free_kb);
            pos = appendStr(&scratch, pos, " kB\n");
        },
        .self_status => {
            const proc = scheduler.currentProcess() orelse return 0;
            pos = appendStr(&scratch, pos, "PID:\t");
            pos = appendDec(&scratch, pos, proc.pid);
            pos = appendStr(&scratch, pos, "\nState:\t");
            pos = appendStr(&scratch, pos, stateStr(proc.state));
            pos = appendStr(&scratch, pos, "\nVmSize:\t");
            // Count in-use VMAs and sum their sizes
            var vm_kb: u64 = 0;
            for (0..vma.MAX_VMAS) |i| {
                if (proc.vmas[i].in_use) {
                    vm_kb += (proc.vmas[i].end - proc.vmas[i].start) / 1024;
                }
            }
            pos = appendDec(&scratch, pos, vm_kb);
            pos = appendStr(&scratch, pos, " kB\nExe:\t");
            for (0..proc.exe_path_len) |i| {
                if (pos < scratch.len) {
                    scratch[pos] = proc.exe_path[i];
                    pos += 1;
                }
            }
            pos = appendStr(&scratch, pos, "\n");
        },
        .self_exe => {
            const proc = scheduler.currentProcess() orelse return 0;
            for (0..proc.exe_path_len) |i| {
                if (pos < scratch.len) {
                    scratch[pos] = proc.exe_path[i];
                    pos += 1;
                }
            }
            if (pos < scratch.len) {
                scratch[pos] = '\n';
                pos += 1;
            }
        },
        .self_maps => {
            const proc = scheduler.currentProcess() orelse return 0;
            for (0..vma.MAX_VMAS) |i| {
                if (!proc.vmas[i].in_use) continue;
                const v = &proc.vmas[i];
                // Format: start-end rwxp offset
                pos = appendHex(&scratch, pos, v.start, 12);
                scratch[pos] = '-';
                pos += 1;
                pos = appendHex(&scratch, pos, v.end, 12);
                scratch[pos] = ' ';
                pos += 1;
                scratch[pos] = if (v.flags & vma.VMA_READ != 0) 'r' else '-';
                pos += 1;
                scratch[pos] = if (v.flags & vma.VMA_WRITE != 0) 'w' else '-';
                pos += 1;
                scratch[pos] = if (v.flags & vma.VMA_EXEC != 0) 'x' else '-';
                pos += 1;
                scratch[pos] = 'p';
                pos += 1;
                scratch[pos] = ' ';
                pos += 1;
                pos = appendHex(&scratch, pos, v.file_offset, 8);
                scratch[pos] = '\n';
                pos += 1;
                if (pos >= scratch.len - 64) break; // Safety margin
            }
        },
        .version => {
            pos = appendStr(&scratch, pos, "Zigix 1.0 (x86_64)\n");
        },
        .cpuinfo => {
            // Use CPUID leaf 0 to get vendor string
            var ebx: u32 = undefined;
            var edx: u32 = undefined;
            var ecx: u32 = undefined;
            asm volatile ("cpuid"
                : [ebx] "={ebx}" (ebx),
                  [ecx] "={ecx}" (ecx),
                  [edx] "={edx}" (edx),
                : [eax] "{eax}" (@as(u32, 0)),
            );
            var vendor: [12]u8 = undefined;
            const ebx_bytes: [4]u8 = @bitCast(ebx);
            const edx_bytes: [4]u8 = @bitCast(edx);
            const ecx_bytes: [4]u8 = @bitCast(ecx);
            for (0..4) |bi| {
                vendor[bi] = ebx_bytes[bi];
                vendor[4 + bi] = edx_bytes[bi];
                vendor[8 + bi] = ecx_bytes[bi];
            }
            pos = appendStr(&scratch, pos, "vendor_id\t: ");
            pos = appendStr(&scratch, pos, &vendor);
            pos = appendStr(&scratch, pos, "\nmodel name\t: x86_64 processor\ncpu MHz\t\t: 0\n");
        },
        .stat => {
            pos = appendStr(&scratch, pos, "cpu  0 0 0 0 0 0 0 0 0 0\n");
            const ticks = idt.getTickCount();
            pos = appendStr(&scratch, pos, "btime ");
            pos = appendDec(&scratch, pos, ticks / 100);
            pos = appendStr(&scratch, pos, "\nprocesses 1\n");
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

// ---- Formatting helpers ----

fn appendStr(buf: *[4096]u8, pos: usize, s: []const u8) usize {
    var p = pos;
    for (s) |c| {
        if (p >= buf.len) break;
        buf[p] = c;
        p += 1;
    }
    return p;
}

fn appendDec(buf: *[4096]u8, pos: usize, value: u64) usize {
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

fn appendHex(buf: *[4096]u8, pos: usize, value: u64, width: usize) usize {
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
