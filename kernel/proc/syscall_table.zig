/// Syscall dispatch table — function pointer array indexed by syscall number.
/// Adding a new syscall is a one-line table entry in init().
/// Unknown syscalls return -ENOSYS so userspace can probe gracefully.

const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const types = @import("../types.zig");
const errno = @import("errno.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const syscall = @import("syscall.zig");
const memory = @import("memory.zig");
const vfs = @import("../fs/vfs.zig");
const fd_table = @import("../fs/fd_table.zig");
const pipe = @import("../fs/pipe.zig");

const clone_mod = @import("clone.zig");
const execve_mod = @import("execve.zig");
const futex = @import("futex.zig");
const mmap_mod = @import("../mm/mmap.zig");
const vma_mod = @import("../mm/vma.zig");
const signal = @import("signal.zig");
const syscall_entry = @import("../arch/x86_64/syscall_entry.zig");
const socket_syscalls = @import("../net/socket_syscalls.zig");
const socket_mod = @import("../net/socket.zig");
const ext2 = @import("../fs/ext2.zig");
const zcnet = @import("../net/zcnet.zig");
const security = @import("../security/policy.zig");
const epoll_mod = @import("epoll.zig");

const Handler = *const fn (*idt.InterruptFrame) void;
const MAX_SYSCALL: usize = 512; // Accommodates DPDK syscalls (510-511)

var table: [MAX_SYSCALL]?Handler = [_]?Handler{null} ** MAX_SYSCALL;

pub fn init() void {
    // I/O
    table[0] = syscall.sysRead;
    table[1] = syscall.sysWrite;
    // Filesystem
    table[2] = sysOpen;
    table[3] = sysClose;
    table[4] = sysStat;
    table[5] = sysFstat;
    table[8] = sysLseek;
    // Memory
    table[9] = mmap_mod.sysMmap; // mmap
    table[10] = mmap_mod.sysMprotect; // mprotect
    table[11] = mmap_mod.sysMunmap; // munmap
    table[12] = memory.sysBrk;
    // Signals
    table[13] = signal.sysRtSigaction; // rt_sigaction
    table[14] = signal.sysRtSigprocmask; // rt_sigprocmask
    table[15] = signal.sysRtSigreturn; // rt_sigreturn
    // I/O control
    table[16] = sysIoctl; // ioctl
    // Scatter/gather I/O
    table[19] = sysReadv; // readv
    table[20] = sysWritev; // writev
    // Pipes
    table[22] = sysPipe;
    // File descriptor
    table[33] = sysDup2;
    // Process
    table[39] = syscall.sysGetpid;
    table[56] = clone_mod.sysClone;
    table[57] = sysFork;
    table[58] = sysVfork;
    table[59] = execve_mod.sysExecve;
    table[60] = syscall.sysExit;
    // Wait
    table[61] = sysWait4;
    table[62] = signal.sysKill; // kill
    // System info
    table[63] = sysUname;
    // Filesystem (continued)
    table[73] = sysFlock;
    table[79] = sysGetcwd;
    table[80] = sysChdir;
    table[77] = sysFtruncate;
    table[83] = sysMkdir;
    table[84] = sysRmdir;
    table[87] = sysUnlink;
    table[89] = sysReadlink;
    // Process groups
    table[109] = sysSetpgid;
    table[111] = sysGetpgrp;
    table[121] = sysGetpgid;
    // Identity
    table[102] = sysGetuid;
    table[104] = sysGetgid;
    table[105] = sysSetuid;
    table[106] = sysSetgid;
    table[107] = sysGetEuid;
    table[108] = sysGetEgid;
    table[186] = sysGettid;
    // Futex
    table[202] = futex.sysFutex;
    // Directory listing
    table[217] = sysGetdents64;
    // Signals (continued)
    table[131] = sysSigaltstack; // sigaltstack (Zig runtime needs this)
    table[200] = sysTkill; // tkill
    table[234] = sysTgkill; // tgkill
    // Architecture-specific
    table[158] = sysArchPrctl; // arch_prctl
    // Thread ID address
    table[218] = sysSetTidAddress;
    // Time
    table[228] = sysClockGettime;
    // Process exit (group)
    table[231] = sysExitGroup; // exit_group
    // Socket
    table[41] = socket_syscalls.sysSocket; // socket
    table[42] = socket_syscalls.sysConnect; // connect
    table[43] = socket_syscalls.sysAccept; // accept
    table[44] = socket_syscalls.sysSendto; // sendto
    table[45] = socket_syscalls.sysRecvfrom; // recvfrom
    table[48] = socket_syscalls.sysShutdown; // shutdown
    table[49] = socket_syscalls.sysBind; // bind
    table[50] = socket_syscalls.sysListen; // listen
    // Sync
    table[162] = sysSync;
    // Filesystem (AT_FDCWD)
    table[257] = sysOpenat;
    // New syscalls for Zig compiler support
    table[17] = sysPread64; // pread64
    table[18] = sysPwrite64; // pwrite64
    table[21] = sysAccess; // access
    table[24] = sysSchedYield; // sched_yield
    table[28] = sysMadvise; // madvise
    table[32] = sysDup; // dup
    table[35] = sysNanosleep; // nanosleep
    table[72] = sysFcntl; // fcntl
    table[82] = sysRename; // rename
    table[204] = sysSchedGetaffinity; // sched_getaffinity
    table[262] = sysNewfstatat; // newfstatat
    table[269] = sysFaccessat; // faccessat
    table[439] = sysFaccessat; // faccessat2 (same handler, flags arg ignored)
    table[273] = sysSetRobustList; // set_robust_list
    table[293] = sysPipe2; // pipe2
    table[302] = sysPrlimit64; // prlimit64
    table[318] = sysGetrandom; // getrandom
    table[296] = sysPwritev; // pwritev
    table[334] = sysRseq; // rseq
    // Hardening: common stubs
    table[74] = sysFsync; // fsync (was incorrectly at 36)
    table[75] = sysFdatasync; // fdatasync (was incorrectly at 37)
    table[54] = sysSetsockopt; // setsockopt
    table[55] = sysGetsockopt; // getsockopt
    table[110] = sysGetppid; // getppid
    table[227] = sysClockGetres; // clock_getres
    table[258] = sysMkdirat; // mkdirat (was incorrectly at 266)
    table[261] = sysUnlinkat; // unlinkat
    table[263] = sysRenameat; // renameat
    table[264] = sysRenameat; // renameat2 (flags in r8 — ignored for now, same as renameat)
    // Zero-copy networking
    table[500] = zcnet.sysAttach; // zcnet_attach
    table[501] = zcnet.sysDetach; // zcnet_detach
    table[502] = zcnet.sysKick; // zcnet_kick
    // Phase 2: Zig compiler readiness
    table[6] = sysLstat; // lstat (alias stat, no symlinks)
    table[7] = sysPoll; // poll
    table[25] = mmap_mod.sysMremap; // mremap
    table[91] = sysFchmod; // fchmod
    table[93] = sysFchown; // fchown
    table[95] = sysUmask; // umask
    table[98] = sysGetrusage; // getrusage
    table[137] = sysStatfs; // statfs
    table[138] = sysFstatfs; // fstatfs
    table[157] = sysPrctl; // prctl
    table[230] = sysClockNanosleep; // clock_nanosleep
    table[260] = sysFchownat; // fchownat
    table[267] = sysReadlinkat; // readlinkat
    table[268] = sysFchmodat; // fchmodat
    table[271] = sysPpoll; // ppoll
    table[292] = sysDup3; // dup3
    // epoll
    table[232] = epoll_mod.sysEpollWait; // epoll_wait
    table[233] = epoll_mod.sysEpollCtl; // epoll_ctl
    table[291] = epoll_mod.sysEpollCreate1; // epoll_create1
    // Scheduling
    table[503] = sysSchedDedicate; // sched_dedicate (Zigix custom)
    table[504] = sysSchedRelease; // sched_release (Zigix custom)
    // DPDK / hugepage support (Zigix custom)
    table[510] = sysVirtToPhys; // virt_to_phys: translate user vaddr → physical
    table[511] = sysDmaInfo; // dma_info: get hugepage VMA physical base + size
    // Phase 3: Missing syscalls to prevent silent failures
    // Phase 3.1: I/O + simple process
    table[295] = sysPreadv; // preadv
    table[332] = sysStatx; // statx
    table[112] = sysSetsid; // setsid
    table[147] = sysGetsid; // getsid
    table[115] = sysGetgroups; // getgroups
    table[116] = sysSetgroups; // setgroups
    // Phase 3.2: Filesystem metadata
    table[90] = sysChmod; // chmod
    table[92] = sysChown; // chown
    table[94] = sysLchown; // lchown
    table[76] = sysTruncate; // truncate
    table[81] = sysFchdir; // fchdir
    table[320] = sysUtimensat; // utimensat
    // Phase 3.3: Filesystem structure
    table[88] = sysSymlink; // symlink
    table[266] = sysSymlinkat; // symlinkat
    table[86] = sysLink; // link
    table[265] = sysLinkat; // linkat
    // Phase 3.4: Feature stubs (return proper errors instead of ENOSYS)
    table[285] = sysFallocate; // fallocate
    table[133] = sysMknod; // mknod (used by mkfifo)
    table[259] = sysMknodat; // mknodat
    // inotify
    table[253] = sysInotifyInit; // inotify_init
    table[254] = sysInotifyAddWatch; // inotify_add_watch
    table[255] = sysInotifyRmWatch; // inotify_rm_watch
    table[294] = sysInotifyInit1; // inotify_init1
    // xattr
    table[188] = sysSetxattr; // setxattr
    table[189] = sysLsetxattr; // lsetxattr
    table[190] = sysGetxattr; // getxattr
    table[191] = sysLgetxattr; // lgetxattr
    table[194] = sysListxattr; // listxattr
    table[195] = sysListxattr; // llistxattr (same as listxattr)
    table[197] = sysRemovexattr; // removexattr
    // Phase 3.4: Socket + advanced I/O
    table[288] = sysAccept4; // accept4
    table[51] = sysGetsockname; // getsockname
    table[52] = sysGetpeername; // getpeername
    table[40] = sysSendfile; // sendfile
    table[326] = sysCopyFileRange; // copy_file_range
    table[23] = sysSelect; // select

    serial.writeString("[syscall] Table initialized (136 handlers)\n");
}

// --- Output helpers for tracing ---

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        serial.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    serial.writeString(buf[i..]);
}

// --- Syscall tracing ---
// Set trace_pids[0..] to non-zero PIDs to trace memory syscalls for those processes.
// Set trace_all = true to trace ALL processes (noisy).
pub var trace_pids: [4]u64 = .{ 0, 0, 0, 0 };
pub var trace_all: bool = false;

fn shouldTrace(pid: u64) bool {
    if (trace_all) return true;
    for (trace_pids) |tp| {
        if (tp != 0 and tp == pid) return true;
    }
    return false;
}

fn isTracedSyscall(nr: u64) bool {
    return switch (nr) {
        // File ops: openat(257), mkdir(83), mkdirat(258), write(1), pwritev(296),
        // close(3), unlinkat(263), fstatat(262)
        1, 3, 83, 257, 258, 262, 263, 296 => true,
        else => false,
    };
}

fn traceEntry(nr: u64, pid: u64, frame: *idt.InterruptFrame) void {
    serial.writeString("[sc] PID=");
    writeDecimal(pid);
    serial.writeString(" nr=");
    writeDecimal(nr);

    // For openat/mkdirat/fstatat, dump the path from rsi (2nd arg = pathname)
    if (nr == 257 or nr == 258 or nr == 262 or nr == 263) {
        serial.writeString(" fd=");
        const fd_signed: i64 = @bitCast(frame.rdi);
        if (fd_signed == -100) {
            serial.writeString("AT_CWD");
        } else {
            writeDecimal(frame.rdi);
        }
        serial.writeString(" path=\"");
        // Read up to 64 bytes of the path from user memory
        if (scheduler.currentProcess()) |proc| {
            var path_buf: [64]u8 = undefined;
            const len = syscall.copyFromUser(proc.page_table, frame.rsi, &path_buf, 63);
            if (len > 0) {
                serial.writeString(path_buf[0..len]);
            }
        }
        serial.writeString("\"");
        if (nr == 257) {
            serial.writeString(" flags=0x");
            writeHex(frame.rdx);
        }
    } else {
        serial.writeString(" args=[");
        writeHex(frame.rdi);
        serial.writeString(",");
        writeHex(frame.rsi);
        serial.writeString("]");
    }
    serial.writeString("\n");
}

fn traceReturn(nr: u64, pid: u64, ret: u64) void {
    serial.writeString("[sc] PID=");
    writeDecimal(pid);
    serial.writeString(" nr=");
    writeDecimal(nr);
    serial.writeString(" → ");
    // Check if return value looks like an error (negative, as unsigned > 0xFFFFF000...)
    const signed: i64 = @bitCast(ret);
    if (signed < 0 and signed >= -4095) {
        serial.writeString("-");
        writeDecimal(@as(u64, @intCast(-signed)));
    } else {
        serial.writeString("0x");
        writeHex(ret);
    }
    serial.writeString("\n");
}

pub fn dispatch(frame: *idt.InterruptFrame) void {
    const nr = frame.rax;

    if (nr < MAX_SYSCALL) {
        if (table[@as(usize, @truncate(nr))]) |handler| {
            // Trace all syscalls for crashing utility PIDs
            if (scheduler.currentProcess()) |p| {
                if (p.pid >= 10 and p.pid <= 25) {
                    serial.writeString("[sc] ");
                    writeDecSc(p.pid);
                    serial.writeString(" nr=");
                    writeDecSc(nr);
                    serial.writeString("\n");
                }
            }
            handler(frame);
            // Log return value for mmap(9), brk(12), arch_prctl(158)
            if (scheduler.currentProcess()) |p| {
                if (p.pid >= 10 and p.pid <= 25 and (nr == 9 or nr == 12 or nr == 158)) {
                    serial.writeString("[ret] ");
                    writeDecSc(p.pid);
                    serial.writeString(" nr=");
                    writeDecSc(nr);
                    serial.writeString("=0x");
                    writeHexSc(frame.rax);
                    serial.writeString("\n");
                }
            }
            return;
        }
    }
    // Unknown syscall — log and return -ENOSYS
    if (scheduler.currentProcess()) |p| {
        serial.writeString("[ENOSYS] pid=");
        writeDecSc(p.pid);
        serial.writeString(" nr=");
        writeDecSc(nr);
        serial.writeString(" rdi=0x");
        writeHexSc(frame.rdi);
        serial.writeString("\n");
    }
    frame.rax = @bitCast(@as(i64, -errno.ENOSYS));
}

fn writeDecSc(v: u64) void {
    if (v == 0) { serial.writeByte('0'); return; }
    var buf: [20]u8 = undefined;
    var val = v;
    var i: usize = 20;
    while (val > 0) { i -= 1; buf[i] = @truncate((val % 10) + '0'); val /= 10; }
    serial.writeString(buf[i..]);
}

fn writeHexSc(v: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var val = v;
    var i: usize = 16;
    while (i > 0) { i -= 1; buf[i] = hex[@as(usize, @truncate(val & 0xf))]; val >>= 4; }
    serial.writeString(&buf);
}

// --- Permission check ---

/// Check file permissions against process identity.
/// wanted: bitmask — 4=read, 2=write, 1=execute
fn checkPermission(inode: *vfs.Inode, wanted: u32, proc: *process.Process) bool {
    if (proc.euid == 0) return true; // root bypasses all

    const mode = inode.mode & 0o7777; // permission bits only

    const bits: u32 = if (proc.euid == inode.uid)
        (mode >> 6) & 7 // owner bits
    else if (proc.egid == inode.gid)
        (mode >> 3) & 7 // group bits
    else
        mode & 7; // other bits

    return (bits & wanted) == wanted;
}

// --- FIFO (named pipe) support ---

const MAX_FIFOS: usize = 16;
const FifoEntry = struct { ino: u64, pipe_idx: usize, active: bool };
var fifo_map: [MAX_FIFOS]FifoEntry = [_]FifoEntry{.{ .ino = 0, .pipe_idx = 0, .active = false }} ** MAX_FIFOS;

fn openFifo(proc: *process.Process, inode: *vfs.Inode, flags: u32) i64 {
    const access_mode = flags & vfs.O_ACCMODE;

    // Check if this FIFO already has a pipe allocated
    var existing_idx: ?usize = null;
    for (&fifo_map) |*entry| {
        if (entry.active and entry.ino == inode.ino) {
            existing_idx = entry.pipe_idx;
            break;
        }
    }

    if (existing_idx) |pidx| {
        const desc = pipe.openExistingPipe(pidx, access_mode) orelse return -@as(i64, errno.EMFILE);
        const fd = fd_table.fdAlloc(&proc.fds, desc) orelse {
            vfs.releaseFileDescription(desc);
            return -@as(i64, errno.EMFILE);
        };
        return @intCast(fd);
    }

    // Create new pipe for this FIFO
    const result = pipe.createPipe() orelse return -@as(i64, errno.EMFILE);

    // Register in FIFO map
    for (&fifo_map) |*entry| {
        if (!entry.active) {
            entry.active = true;
            entry.ino = inode.ino;
            entry.pipe_idx = pipe.getPipeIdx(result.read_desc.inode) orelse 0;
            break;
        }
    }

    // Return the requested end, release the other without closing the pipe
    const desc_to_use = if (access_mode == vfs.O_WRONLY) result.write_desc else result.read_desc;
    const fd = fd_table.fdAlloc(&proc.fds, desc_to_use) orelse {
        vfs.releaseFileDescription(desc_to_use);
        return -@as(i64, errno.EMFILE);
    };
    const unused = if (access_mode == vfs.O_WRONLY) result.read_desc else result.write_desc;
    vfs.releaseFileDescriptionNoClose(unused);
    return @intCast(fd);
}

// --- Filesystem syscalls ---

/// open(path, flags, mode) — nr 2
fn sysOpen(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;
    const flags: u32 = @truncate(frame.rsi);
    const mode: u32 = @truncate(frame.rdx);

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Read raw path from user
    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Resolve relative paths by prepending cwd
    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const result = vfs.resolvePath(path_buf[0..path_len]);
    var inode: *vfs.Inode = undefined;

    if (result.inode) |found| {
        // Follow symlinks unless O_NOFOLLOW is set
        if (found.mode & vfs.S_IFMT == vfs.S_IFLNK and flags & vfs.O_NOFOLLOW == 0) {
            inode = vfs.resolve(path_buf[0..path_len]) orelse {
                frame.rax = @bitCast(@as(i64, -errno.ENOENT));
                return;
            };
        } else {
            inode = found;
        }
    } else if (flags & vfs.O_CREAT != 0) {
        // File doesn't exist, create it via parent's vtable
        const parent = result.parent orelse {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
            return;
        };
        // Permission check: need W+X on parent directory for creation
        if (!checkPermission(parent, 3, current)) {
            frame.rax = @bitCast(@as(i64, -errno.EACCES));
            return;
        }
        // Zee eBPF: security policy check
        if (!security.checkMutate(path_buf[0..path_len], current)) {
            frame.rax = @bitCast(@as(i64, -errno.EACCES));
            return;
        }
        const create_fn = parent.ops.create orelse {
            frame.rax = @bitCast(@as(i64, -errno.EROFS));
            return;
        };
        const file_mode = vfs.S_IFREG | (mode & 0o777);
        inode = create_fn(parent, result.leaf_name[0..result.leaf_len], file_mode) orelse {
            frame.rax = @bitCast(@as(i64, -errno.ENFILE));
            return;
        };
        // Post inotify IN_CREATE event
        inotifyPostEvent(parent.ino, 0x100, result.leaf_name[0..result.leaf_len]);
    } else {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Don't open directories for writing
    if (inode.mode & vfs.S_IFMT == vfs.S_IFDIR) {
        const access = flags & vfs.O_ACCMODE;
        if (access != vfs.O_RDONLY) {
            frame.rax = @bitCast(@as(i64, -errno.EISDIR));
            return;
        }
    }

    // FIFO (named pipe) — redirect to pipe subsystem
    if (inode.mode & vfs.S_IFMT == vfs.S_IFIFO) {
        const fifo_fd = openFifo(current, inode, flags);
        frame.rax = @bitCast(fifo_fd);
        return;
    }

    // Permission check
    const access_mode = flags & vfs.O_ACCMODE;
    const wanted: u32 = switch (access_mode) {
        vfs.O_RDONLY => 4,
        vfs.O_WRONLY => 2,
        vfs.O_RDWR => 6,
        else => 4,
    };
    if (!checkPermission(inode, wanted, current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    const desc = vfs.allocFileDescription() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };
    desc.inode = inode;
    desc.flags = flags;
    desc.offset = 0;

    if (flags & vfs.O_TRUNC != 0) {
        // Zee eBPF: security policy check for truncation
        if (!security.checkMutate(path_buf[0..path_len], current)) {
            vfs.releaseFileDescription(desc);
            frame.rax = @bitCast(@as(i64, -errno.EACCES));
            return;
        }
        if (inode.ops.truncate) |trunc_fn| {
            _ = trunc_fn(inode);
        }
        inode.size = 0;
    }

    const fd_num = fd_table.fdAlloc(&current.fds, desc) orelse {
        vfs.releaseFileDescription(desc);
        frame.rax = @bitCast(@as(i64, -errno.EMFILE));
        return;
    };

    frame.rax = fd_num;
}

/// close(fd) — nr 3
fn sysClose(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (fd_table.fdClose(&current.fds, fd)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
    }
}

/// lseek(fd, offset, whence) — nr 8
fn sysLseek(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const offset: i64 = @bitCast(frame.rsi);
    const whence: u32 = @truncate(frame.rdx);

    const SEEK_SET: u32 = 0;
    const SEEK_CUR: u32 = 1;
    const SEEK_END: u32 = 2;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const new_off: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => @as(i64, @intCast(desc.offset)) + offset,
        SEEK_END => @as(i64, @intCast(desc.inode.size)) + offset,
        else => {
            frame.rax = @bitCast(@as(i64, -errno.EINVAL));
            return;
        },
    };

    if (new_off < 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    desc.offset = @intCast(new_off);
    frame.rax = @bitCast(new_off);
}

/// flock(fd, operation) — nr 73
/// Advisory file locking: LOCK_SH (1), LOCK_EX (2), LOCK_UN (8), LOCK_NB (4).
fn sysFlock(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const operation = frame.rsi;

    const LOCK_SH: u64 = 1;
    const LOCK_EX: u64 = 2;
    const LOCK_NB: u64 = 4;
    const LOCK_UN: u64 = 8;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const op = operation & ~LOCK_NB;
    const non_blocking = (operation & LOCK_NB) != 0;

    if (op == LOCK_UN) {
        desc.lock_type = 0;
        frame.rax = 0;
        return;
    }

    if (op != LOCK_SH and op != LOCK_EX) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const wanted: u8 = if (op == LOCK_SH) 1 else 2;

    if (vfs.checkFlockConflict(desc, wanted)) {
        if (non_blocking) {
            frame.rax = @bitCast(@as(i64, -errno.EAGAIN));
            return;
        }
        // Blocking: in a single-user OS, just succeed (avoid deadlock)
    }

    desc.lock_type = wanted;
    frame.rax = 0;
}

/// ftruncate(fd, length) — nr 77
fn sysFtruncate(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const length = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (length == 0) {
        // Truncate to zero — call filesystem truncate op
        if (desc.inode.ops.truncate) |trunc_fn| {
            _ = trunc_fn(desc.inode);
        }
        desc.inode.size = 0;
    } else {
        // Set size (don't free pages — sparse file semantics)
        desc.inode.size = length;
    }

    frame.rax = 0;
}

/// stat(path, statbuf) — nr 4, Linux x86_64 struct stat (144 bytes)
fn sysStat(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;
    const buf_addr = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1) or !syscall.validateUserBuffer(buf_addr, 144)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Resolve relative paths by prepending cwd
    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const inode = vfs.resolve(path_buf[0..path_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    var st: vfs.Stat = undefined;
    vfs.statFromInode(inode, &st);

    var buf: [144]u8 = [_]u8{0} ** 144;
    packStat(&buf, &st);

    if (syscall.copyToUser(current.page_table, buf_addr, &buf)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// fstat(fd, statbuf) — nr 5
fn sysFstat(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const buf_addr = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(buf_addr, 144)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    var st: vfs.Stat = undefined;
    vfs.statFromInode(desc.inode, &st);

    var buf: [144]u8 = [_]u8{0} ** 144;
    packStat(&buf, &st);

    if (syscall.copyToUser(current.page_table, buf_addr, &buf)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// mkdir(path, mode) — nr 83
fn sysMkdir(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;
    const mode: u32 = @truncate(frame.rsi);

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Resolve relative paths by prepending cwd
    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const result = vfs.resolvePath(path_buf[0..path_len]);

    if (result.inode != null) {
        frame.rax = @bitCast(@as(i64, -errno.EEXIST));
        return;
    }

    const parent = result.parent orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Permission check: need W+X on parent directory
    if (!checkPermission(parent, 3, current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    // Zee eBPF: security policy check
    if (!security.checkMutate(path_buf[0..path_len], current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    const create_fn = parent.ops.create orelse {
        frame.rax = @bitCast(@as(i64, -errno.EROFS));
        return;
    };
    const dir_mode = vfs.S_IFDIR | (mode & 0o777);
    if (create_fn(parent, result.leaf_name[0..result.leaf_len], dir_mode)) |_| {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
    }
}

/// unlink(path) — nr 87, remove a file (not directory)
fn sysUnlink(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Resolve relative paths by prepending cwd
    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const result = vfs.resolvePath(path_buf[0..path_len]);

    if (result.inode == null) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    const parent = result.parent orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Permission check: need W+X on parent directory
    if (!checkPermission(parent, 3, current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    // Zee eBPF: security policy check
    if (!security.checkMutate(path_buf[0..path_len], current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    const unlink_fn = parent.ops.unlink orelse {
        frame.rax = @bitCast(@as(i64, -errno.EROFS));
        return;
    };
    if (unlink_fn(parent, result.leaf_name[0..result.leaf_len])) {
        frame.rax = 0;
    } else {
        serial.writeString("[unlink-fail] ");
        serial.writeString(path_buf[0..path_len]);
        serial.writeString("\n");
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
    }
}

/// readlink(path, buf, bufsiz) — nr 89, read symbolic link target
fn sysReadlink(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;
    const buf_addr = frame.rsi;
    const bufsiz = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // /proc/self/exe → return current process executable path
    const proc_self_exe = "/proc/self/exe";
    // Debug: log readlink path
    serial.writeString("[readlink] ");
    serial.writeString(raw_path[0..raw_len]);
    serial.writeString("\n");
    if (raw_len >= proc_self_exe.len and
        eqlBytes(raw_path[0..proc_self_exe.len], proc_self_exe))
    {
        serial.writeString("[readlink] /proc/self/exe matched! exe=");
        serial.writeString(current.exe_path[0..current.exe_path_len]);
        serial.writeString("\n");
        const exe_len = current.exe_path_len;
        if (exe_len == 0) {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
            return;
        }
        const copy_len: usize = if (bufsiz > exe_len) exe_len else @truncate(bufsiz);
        if (!syscall.validateUserBuffer(buf_addr, copy_len)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
        if (!syscall.copyToUser(current.page_table, buf_addr, current.exe_path[0..copy_len])) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
        frame.rax = copy_len;
        return;
    }

    // Resolve relative paths by prepending cwd
    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const result = vfs.resolvePath(path_buf[0..path_len]);
    const inode = result.inode orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    const readlink_fn = inode.ops.readlink orelse {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    };

    // Call readlink into a kernel buffer, then copy to user
    var kern_buf: [256]u8 = undefined;
    const max_len = if (bufsiz > 256) 256 else @as(usize, @truncate(bufsiz));
    const len = readlink_fn(inode, &kern_buf, max_len);
    if (len < 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const result_len: usize = @intCast(len);
    if (!syscall.validateUserBuffer(buf_addr, result_len)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }
    if (!syscall.copyToUser(current.page_table, buf_addr, kern_buf[0..result_len])) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }
    frame.rax = @intCast(result_len);
}

/// getdents64(fd, dirp, count) — nr 217, read directory entries
fn sysGetdents64(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const buf_addr = frame.rsi;
    const count = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(buf_addr, count)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const readdir_fn = desc.inode.ops.readdir orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOTDIR));
        return;
    };

    var total_written: usize = 0;
    const max: usize = @truncate(count);
    var scratch: [512]u8 = undefined;

    while (true) {
        var entry: vfs.DirEntry = undefined;
        if (!readdir_fn(desc, &entry)) break;

        // linux_dirent64: d_ino(8) + d_off(8) + d_reclen(2) + d_type(1) + name + NUL
        const name_size: usize = @as(usize, entry.name_len) + 1;
        const raw_len = 8 + 8 + 2 + 1 + name_size;
        const reclen = (raw_len + 7) & ~@as(usize, 7); // Align to 8

        if (total_written + reclen > max) {
            desc.offset -= 1; // Rewind: couldn't fit this entry
            break;
        }
        if (reclen > scratch.len) break;

        // Zero for padding
        for (0..reclen) |i| {
            scratch[i] = 0;
        }

        writeU64LE(scratch[0..8], entry.ino);
        writeU64LE(scratch[8..16], desc.offset);
        scratch[16] = @truncate(reclen);
        scratch[17] = @truncate(reclen >> 8);
        scratch[18] = entry.d_type;
        for (0..entry.name_len) |i| {
            scratch[19 + i] = entry.name[i];
        }

        if (!syscall.copyToUser(current.page_table, buf_addr + total_written, scratch[0..reclen])) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }

        total_written += reclen;
    }

    frame.rax = total_written;
}

/// openat(dirfd, path, flags, mode) — nr 257, MVP: AT_FDCWD only
fn sysOpenat(frame: *idt.InterruptFrame) void {
    const dirfd = frame.rdi;
    if (@as(i64, @bitCast(dirfd)) == vfs.AT_FDCWD) {
        // Shift openat args to open convention: path→rdi, flags→rsi, mode→rdx
        frame.rdi = frame.rsi;
        frame.rsi = frame.rdx;
        frame.rdx = frame.r10;
        sysOpen(frame);
        return;
    }

    // Real dirfd — resolve relative path from dir inode
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const dir_desc = fd_table.fdGet(&current.fds, dirfd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const dir_inode = dir_desc.inode;
    if (dir_inode.mode & vfs.S_IFMT != vfs.S_IFDIR) {
        frame.rax = @bitCast(@as(i64, -errno.ENOTDIR));
        return;
    }

    const path_addr = frame.rsi;
    const flags: u32 = @truncate(frame.rdx);
    const mode: u32 = @truncate(frame.r10);

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var path_buf: [256]u8 = undefined;
    const path_len = syscall.copyFromUser(current.page_table, path_addr, &path_buf, 255);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Absolute path — ignore dirfd, use normal open
    if (path_buf[0] == '/') {
        frame.rdi = path_addr;
        frame.rsi = @as(u64, flags);
        frame.rdx = @as(u64, mode);
        sysOpen(frame);
        return;
    }

    // Walk relative path from dir inode, component by component
    const resolved = resolveFromInode(dir_inode, path_buf[0..path_len]);

    var inode: *vfs.Inode = undefined;
    if (resolved.inode) |found| {
        inode = found;
    } else if (flags & vfs.O_CREAT != 0) {
        const parent = resolved.parent orelse {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
            return;
        };
        const create_fn = parent.ops.create orelse {
            frame.rax = @bitCast(@as(i64, -errno.EROFS));
            return;
        };
        const file_mode = vfs.S_IFREG | (mode & 0o777);
        inode = create_fn(parent, resolved.leaf_name[0..resolved.leaf_len], file_mode) orelse {
            frame.rax = @bitCast(@as(i64, -errno.ENFILE));
            return;
        };
    } else {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Check directory open rules
    if (inode.mode & vfs.S_IFMT == vfs.S_IFDIR) {
        const access = flags & vfs.O_ACCMODE;
        if (access != vfs.O_RDONLY) {
            frame.rax = @bitCast(@as(i64, -errno.EISDIR));
            return;
        }
    }

    const desc = vfs.allocFileDescription() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };
    desc.inode = inode;
    desc.flags = flags;
    desc.offset = 0;

    if (flags & vfs.O_TRUNC != 0) {
        if (inode.ops.truncate) |trunc_fn| {
            _ = trunc_fn(inode);
        }
        inode.size = 0;
    }

    const fd_num = fd_table.fdAlloc(&current.fds, desc) orelse {
        vfs.releaseFileDescription(desc);
        frame.rax = @bitCast(@as(i64, -errno.EMFILE));
        return;
    };

    frame.rax = fd_num;
}

// --- Pipe / process syscalls ---

/// pipe(pipefd[2]) — nr 22
fn sysPipe(frame: *idt.InterruptFrame) void {
    const arr_addr = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(arr_addr, 8)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const result = pipe.createPipe() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };

    // Allocate fds for both ends
    const read_fd = fd_table.fdAlloc(&current.fds, result.read_desc) orelse {
        vfs.releaseFileDescription(result.read_desc);
        vfs.releaseFileDescription(result.write_desc);
        frame.rax = @bitCast(@as(i64, -errno.EMFILE));
        return;
    };

    const write_fd = fd_table.fdAlloc(&current.fds, result.write_desc) orelse {
        _ = fd_table.fdClose(&current.fds, read_fd);
        vfs.releaseFileDescription(result.write_desc);
        frame.rax = @bitCast(@as(i64, -errno.EMFILE));
        return;
    };

    // Write [read_fd, write_fd] to user array (two 32-bit ints)
    var buf: [8]u8 = undefined;
    writeU32LE(buf[0..4], read_fd);
    writeU32LE(buf[4..8], write_fd);

    if (syscall.copyToUser(current.page_table, arr_addr, &buf)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// dup2(oldfd, newfd) — nr 33
fn sysDup2(frame: *idt.InterruptFrame) void {
    const oldfd = frame.rdi;
    const newfd = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const result = fd_table.fdDup2(&current.fds, oldfd, newfd);
    if (result == 0) {
        frame.rax = newfd;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
    }
}

/// wait4(pid, wstatus, options, rusage) — nr 61
/// pid=-1 means wait for any child. Supports WNOHANG and WUNTRACED.
fn sysWait4(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const WNOHANG: u64 = 1;
    const WUNTRACED: u64 = 2;

    const my_pid = current.pid;
    const wait_pid: i64 = @bitCast(frame.rdi); // pid argument: >0 = specific, -1 = any, 0 = same group
    const options = frame.rdx;
    var found_zombie: ?usize = null;
    var found_stopped: ?usize = null;
    var has_live_children = false;

    // Scan process table for matching children
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.parent_pid == my_pid) {
                // Filter by requested PID
                const matches = if (wait_pid > 0)
                    p.pid == @as(u64, @intCast(wait_pid)) // Specific PID
                else if (wait_pid == -1)
                    true // Any child
                else if (wait_pid == 0)
                    p.pgid == current.pgid // Same process group
                else
                    p.pgid == @as(u64, @intCast(-wait_pid)); // Specific group

                if (!matches) {
                    // Not the child we're looking for, but still counts as live
                    has_live_children = true;
                    continue;
                }

                if (p.state == .zombie) {
                    if (found_zombie == null) found_zombie = i;
                } else if (p.state == .stopped and (options & WUNTRACED) != 0) {
                    if (found_stopped == null) found_stopped = i;
                    has_live_children = true;
                } else {
                    has_live_children = true;
                }
            }
        }
    }

    if (found_zombie) |idx| {
        const child = process.getProcess(idx).?;
        const child_pid = child.pid;

        // Write exit status to user wstatus pointer if non-null
        const wstatus_addr = frame.rsi;
        if (wstatus_addr != 0 and syscall.validateUserBuffer(wstatus_addr, 4)) {
            // Linux wstatus format: (exit_code << 8) for normal exit
            const wstatus: u32 = @truncate(child.exit_status << 8);
            var buf: [4]u8 = undefined;
            writeU32LE(&buf, wstatus);
            if (!syscall.copyToUser(current.page_table, wstatus_addr, &buf)) {
                frame.rax = @bitCast(@as(i64, -errno.EFAULT));
                return;
            }
        }

        // Free the zombie's memory.
        // Only destroy address space for group leaders (fork children).
        // Threads (tgid != pid) share the parent's address space.
        if (child.tgid == child.pid) {
            vmm.destroyAddressSpace(child.page_table);
        }

        // Free the kernel stack (guarded allocation — includes buffer pages)
        if (child.kernel_stack_guard > 0) {
            pmm.freePagesGuarded(child.kernel_stack_phys, process.KERNEL_STACK_PAGES, child.kernel_stack_guard);
        } else {
            var kp: u64 = 0;
            while (kp < process.KERNEL_STACK_PAGES) : (kp += 1) {
                pmm.freePage(child.kernel_stack_phys + kp * types.PAGE_SIZE);
            }
        }

        // Free the process slot
        process.clearSlot(idx);

        frame.rax = child_pid;
    } else if (found_stopped) |idx| {
        // Report stopped child (don't reap — it's still alive)
        const child = process.getProcess(idx).?;
        const child_pid = child.pid;

        const wstatus_addr = frame.rsi;
        if (wstatus_addr != 0 and syscall.validateUserBuffer(wstatus_addr, 4)) {
            // Stopped status: (sig << 8) | 0x7F — already encoded in exit_status
            const wstatus: u32 = @truncate(child.exit_status);
            var buf: [4]u8 = undefined;
            writeU32LE(&buf, wstatus);
            if (!syscall.copyToUser(current.page_table, wstatus_addr, &buf)) {
                frame.rax = @bitCast(@as(i64, -errno.EFAULT));
                return;
            }
        }

        frame.rax = child_pid;
    } else if (has_live_children) {
        if ((options & WNOHANG) != 0) {
            // WNOHANG: no waitable child ready, return 0 immediately
            frame.rax = 0;
        } else {
            // Block until a child exits or stops
            frame.rip -= 2; // Rewind past `int 0x80` for syscall restart
            current.state = .blocked_on_wait;
            scheduler.blockAndSchedule(frame);
        }
    } else {
        // No children at all
        frame.rax = @bitCast(@as(i64, -errno.ECHILD));
    }
}

// --- Process group syscalls ---

/// setpgid(pid, pgid) — nr 109
/// pid=0 means self, pgid=0 means use pid as pgid.
fn sysSetpgid(frame: *idt.InterruptFrame) void {
    const target_pid = frame.rdi;
    const new_pgid = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const actual_pid: u64 = if (target_pid == 0) current.pid else target_pid;
    const actual_pgid: u64 = if (new_pgid == 0) actual_pid else new_pgid;

    // Find target process
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.pid == @as(u32, @truncate(actual_pid))) {
                // Only allow setting pgid of self or own children
                if (p.pid != current.pid and p.parent_pid != current.pid) {
                    frame.rax = @bitCast(@as(i64, -errno.ESRCH));
                    return;
                }
                p.pgid = @truncate(actual_pgid);
                frame.rax = 0;
                return;
            }
        }
    }
    frame.rax = @bitCast(@as(i64, -errno.ESRCH));
}

/// getpgrp() — nr 111. Returns calling process's process group ID.
fn sysGetpgrp(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess() orelse {
        frame.rax = 0;
        return;
    };
    frame.rax = current.pgid;
}

/// getpgid(pid) — nr 121. pid=0 means self.
fn sysGetpgid(frame: *idt.InterruptFrame) void {
    const target_pid = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (target_pid == 0) {
        frame.rax = current.pgid;
        return;
    }

    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.pid == target_pid) {
                frame.rax = p.pgid;
                return;
            }
        }
    }
    frame.rax = @bitCast(@as(i64, -errno.ESRCH));
}

// --- Utility syscalls ---

fn sysUname(frame: *idt.InterruptFrame) void {
    const buf_addr = frame.rdi;
    const FIELD_LEN = 65;
    const STRUCT_SIZE = FIELD_LEN * 6; // sysname, nodename, release, version, machine, domainname

    if (!syscall.validateUserBuffer(buf_addr, STRUCT_SIZE)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Build utsname in kernel buffer
    var utsname: [STRUCT_SIZE]u8 = [_]u8{0} ** STRUCT_SIZE;
    copyField(utsname[0 * FIELD_LEN ..][0..FIELD_LEN], "Zigix");
    copyField(utsname[1 * FIELD_LEN ..][0..FIELD_LEN], "zigix");
    copyField(utsname[2 * FIELD_LEN ..][0..FIELD_LEN], "0.10.0");
    copyField(utsname[3 * FIELD_LEN ..][0..FIELD_LEN], "#1");
    copyField(utsname[4 * FIELD_LEN ..][0..FIELD_LEN], "x86_64");
    // domainname left as zeros

    if (syscall.copyToUser(current.page_table, buf_addr, &utsname)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

fn sysClockGettime(frame: *idt.InterruptFrame) void {
    const clock_id = frame.rdi;
    const buf_addr = frame.rsi;

    // Support CLOCK_REALTIME (0) and CLOCK_MONOTONIC (1)
    if (clock_id > 1) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    if (!syscall.validateUserBuffer(buf_addr, 16)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const ticks = idt.getTickCount();
    const seconds: u64 = ticks / 100;
    const nanoseconds: u64 = (ticks % 100) * 10_000_000;

    // Pack timespec as two little-endian u64s
    var buf: [16]u8 = undefined;
    writeU64LE(buf[0..8], seconds);
    writeU64LE(buf[8..16], nanoseconds);

    if (syscall.copyToUser(current.page_table, buf_addr, &buf)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

fn sysGetuid(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess();
    frame.rax = if (current) |proc| proc.uid else 0;
}

fn sysGetgid(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess();
    frame.rax = if (current) |proc| proc.gid else 0;
}

fn sysGetEuid(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess();
    frame.rax = if (current) |proc| proc.euid else 0;
}

fn sysGetEgid(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess();
    frame.rax = if (current) |proc| proc.egid else 0;
}

/// setuid(uid) — nr 105
fn sysSetuid(frame: *idt.InterruptFrame) void {
    const target: u16 = @truncate(frame.rdi);
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    if (current.euid == 0) {
        // Root can set to any uid
        current.uid = target;
        current.euid = target;
    } else if (target == current.uid) {
        // Non-root can set euid back to real uid
        current.euid = target;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }
    frame.rax = 0;
}

/// setgid(gid) — nr 106
fn sysSetgid(frame: *idt.InterruptFrame) void {
    const target: u16 = @truncate(frame.rdi);
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    if (current.euid == 0) {
        current.gid = target;
        current.egid = target;
    } else if (target == current.gid) {
        current.egid = target;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }
    frame.rax = 0;
}

fn sysGettid(frame: *idt.InterruptFrame) void {
    // Process.pid IS the TID (unique per thread)
    const current = scheduler.currentProcess();
    frame.rax = if (current) |proc| proc.pid else 0;
}

/// set_tid_address(tidptr) — nr 218
/// Sets clear_child_tid so the kernel writes 0 and futex-wakes on thread exit.
fn sysSetTidAddress(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    current.clear_child_tid = frame.rdi;
    frame.rax = current.pid; // Return TID (per Linux convention)
}

// --- fork, getcwd, chdir ---

/// fork() — nr 57. Wrapper: clone(flags=0, child_stack=0).
fn sysFork(frame: *idt.InterruptFrame) void {
    frame.rdi = 0; // flags = 0 (no CLONE_VM)
    frame.rsi = 0; // child_stack = 0
    clone_mod.sysClone(frame);
}

/// vfork(void) — nr 58. Equivalent to clone(CLONE_VFORK|CLONE_VM|SIGCHLD, 0).
/// Parent blocks until child execs or exits.
fn sysVfork(frame: *idt.InterruptFrame) void {
    frame.rdi = 0x00004111; // CLONE_VFORK | CLONE_VM | SIGCHLD
    frame.rsi = 0; // child_stack = 0 (use parent's)
    clone_mod.sysClone(frame);
}

/// getcwd(buf, size) — nr 79
fn sysGetcwd(frame: *idt.InterruptFrame) void {
    const buf_addr = frame.rdi;
    const size = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (current.cwd_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    if (size < @as(u64, current.cwd_len)) {
        frame.rax = @bitCast(@as(i64, -errno.ERANGE));
        return;
    }

    if (!syscall.validateUserBuffer(buf_addr, current.cwd_len)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    if (syscall.copyToUser(current.page_table, buf_addr, current.cwd[0..current.cwd_len])) {
        frame.rax = current.cwd_len;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// chdir(path) — nr 80
fn sysChdir(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var path_buf: [256]u8 = undefined;
    const path_len = syscall.copyFromUser(current.page_table, path_addr, &path_buf, 255);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Validate the path exists and is a directory
    const inode = vfs.resolve(path_buf[0..path_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    if (inode.mode & vfs.S_IFMT != vfs.S_IFDIR) {
        frame.rax = @bitCast(@as(i64, -errno.ENOTDIR));
        return;
    }

    // Update cwd
    for (0..path_len) |i| {
        current.cwd[i] = path_buf[i];
    }
    current.cwd_len = @truncate(path_len);

    frame.rax = 0;
}

// --- ioctl, writev, arch_prctl, exit_group ---

/// ioctl(fd, request, ...) — nr 16
/// Handles TIOCSPGRP/TIOCGPGRP for terminal foreground process group.
/// Other requests return -ENOTTY (musl isatty check).
fn sysIoctl(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const request = frame.rsi;
    const arg = frame.rdx;

    const TIOCGPGRP: u64 = 0x540F;
    const TIOCSPGRP: u64 = 0x5410;

    // Only handle terminal ioctls on fd 0 (stdin/serial)
    if (fd == 0 or fd == 1 or fd == 2) {
        if (request == TIOCSPGRP) {
            // Set foreground process group
            const current = scheduler.currentProcess() orelse {
                frame.rax = @bitCast(@as(i64, -errno.ESRCH));
                return;
            };
            if (arg != 0 and syscall.validateUserBuffer(arg, 4)) {
                var buf: [4]u8 = undefined;
                const copied = syscall.copyFromUserRaw(current.page_table, arg, &buf, 4);
                if (copied == 4) {
                    const pgid: u32 = @as(u32, buf[0]) |
                        (@as(u32, buf[1]) << 8) |
                        (@as(u32, buf[2]) << 16) |
                        (@as(u32, buf[3]) << 24);
                    serial.fg_pgid = pgid;
                    frame.rax = 0;
                    return;
                }
            }
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
        if (request == TIOCGPGRP) {
            // Get foreground process group
            const current = scheduler.currentProcess() orelse {
                frame.rax = @bitCast(@as(i64, -errno.ESRCH));
                return;
            };
            if (arg != 0 and syscall.validateUserBuffer(arg, 4)) {
                const pgid: u32 = @truncate(serial.fg_pgid);
                var buf: [4]u8 = undefined;
                writeU32LE(&buf, pgid);
                if (syscall.copyToUser(current.page_table, arg, &buf)) {
                    frame.rax = 0;
                    return;
                }
            }
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
    }

    frame.rax = @bitCast(@as(i64, -errno.ENOTTY));
}

/// readv(fd, iov, iovcnt) — nr 19
/// Scatter read: iterate iovec array, read into each buffer.
fn sysReadv(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const iov_addr = frame.rsi;
    const iovcnt = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (iovcnt == 0 or iovcnt > 1024) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const read_fn = desc.inode.ops.read orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    var total_read: usize = 0;
    const cnt: usize = @truncate(iovcnt);

    for (0..cnt) |i| {
        const iov_entry_addr = iov_addr + i * 16;
        if (!syscall.validateUserBuffer(iov_entry_addr, 16)) break;

        var iov_data: [16]u8 = undefined;
        const copied = syscall.copyFromUserRaw(current.page_table, iov_entry_addr, &iov_data, 16);
        if (copied < 16) break;

        const iov_base = readU64LE(iov_data[0..8]);
        const iov_len = readU64LE(iov_data[8..16]);

        if (iov_len == 0) continue;
        if (!syscall.validateUserBuffer(iov_base, iov_len)) break;

        const actual_len: usize = if (iov_len > 1048576) 1048576 else @truncate(iov_len);
        var remaining = actual_len;
        var addr = iov_base;

        while (remaining > 0) {
            const page_offset: usize = @truncate(addr & 0xFFF);
            const chunk = @min(remaining, types.PAGE_SIZE - page_offset);

            if (vmm.translate(current.page_table, addr)) |phys| {
                const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
                const n = read_fn(desc, ptr, chunk);
                if (n <= 0) {
                    if (total_read > 0) {
                        frame.rax = total_read;
                        return;
                    }
                    // Propagate error/EOF on first read
                    frame.rax = if (n == 0) 0 else @bitCast(@as(i64, -errno.EIO));
                    return;
                }
                total_read += @intCast(n);
                if (@as(usize, @intCast(n)) < chunk) {
                    // Short read — stop here
                    frame.rax = total_read;
                    return;
                }
            } else break;

            addr += chunk;
            remaining -= chunk;
        }
    }

    frame.rax = total_read;
}

/// writev(fd, iov, iovcnt) — nr 20
/// Gather write: iterate iovec array, write each buffer.
fn sysWritev(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const iov_addr = frame.rsi;
    const iovcnt = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };


    if (iovcnt == 0 or iovcnt > 1024) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const write_fn = desc.inode.ops.write orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    var total_written: usize = 0;
    const cnt: usize = @truncate(iovcnt);

    for (0..cnt) |i| {
        // Each iovec is {base: u64, len: u64} = 16 bytes
        const iov_entry_addr = iov_addr + i * 16;
        if (!syscall.validateUserBuffer(iov_entry_addr, 16)) {
            break;
        }

        // Read iov_base and iov_len from user memory
        var iov_data: [16]u8 = undefined;
        const copied = syscall.copyFromUserRaw(current.page_table, iov_entry_addr, &iov_data, 16);
        if (copied < 16) break;

        const iov_base = readU64LE(iov_data[0..8]);
        const iov_len = readU64LE(iov_data[8..16]);

        if (iov_len == 0) continue;
        if (!syscall.validateUserBuffer(iov_base, iov_len)) break;

        // Write this iovec's data page-by-page
        const actual_len: usize = if (iov_len > 1048576) 1048576 else @truncate(iov_len);
        var remaining = actual_len;
        var addr = iov_base;

        while (remaining > 0) {
            const page_offset: usize = @truncate(addr & 0xFFF);
            const chunk = @min(remaining, types.PAGE_SIZE - page_offset);

            const phys = vmm.translate(current.page_table, addr) orelse blk: {
                // Page not yet mapped — try demand paging
                const fault = @import("../mm/fault.zig");
                if (fault.demandPageUser(addr)) {
                    break :blk vmm.translate(current.page_table, addr) orelse break;
                }
                break;
            };
            const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
            const n = write_fn(desc, ptr, chunk);
            if (n <= 0) break;
            total_written += @intCast(n);

            addr += chunk;
            remaining -= chunk;
        }
    }

    frame.rax = total_written;
}

/// arch_prctl(code, addr) — nr 158
/// ARCH_SET_FS (0x1002): set FS base for TLS. Required by musl __init_tls.
fn sysArchPrctl(frame: *idt.InterruptFrame) void {
    const code = frame.rdi;
    const addr = frame.rsi;

    const ARCH_SET_FS: u64 = 0x1002;
    const ARCH_GET_FS: u64 = 0x1003;

    if (code == ARCH_SET_FS) {
        // Write addr to IA32_FS_BASE MSR
        const IA32_FS_BASE: u32 = 0xC0000100;
        syscall_entry.wrmsrPub(IA32_FS_BASE, addr);

        // Save in process struct for context switch restore
        if (scheduler.currentProcess()) |proc| {
            proc.fs_base = addr;
            // Log FS_BASE for debugging TLS VMA issues
            serial.writeString("[fs] pid=");
            writeDecSc(proc.pid);
            serial.writeString(" fs=0x");
            writeHexSc(addr);
            serial.writeString("\n");
        }
        frame.rax = 0;
    } else if (code == ARCH_GET_FS) {
        if (scheduler.currentProcess()) |proc| {
            frame.rax = proc.fs_base;
        } else {
            frame.rax = 0;
        }
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
    }
}

/// sigaltstack(ss, old_ss) — nr 131
/// Stub: Zig runtime calls this to set up signal alternate stack.
/// We don't use alternate stacks yet, but return success so Zig startup doesn't panic.
fn sysSigaltstack(frame: *idt.InterruptFrame) void {
    _ = frame.rdi; // ss
    _ = frame.rsi; // old_ss
    frame.rax = 0; // success
}

/// tkill(tid, sig) — nr 200
/// Send a signal to a specific thread.
fn sysTkill(frame: *idt.InterruptFrame) void {
    const tid = frame.rdi;
    const sig: u6 = @truncate(frame.rsi);

    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |proc| {
            if (proc.pid == tid) {
                signal.postSignal(proc, sig);
                frame.rax = 0;
                return;
            }
        }
    }
    frame.rax = @bitCast(@as(i64, -errno.ESRCH));
}

/// tgkill(tgid, tid, sig) — nr 234
/// Same as tkill but with thread group verification.
fn sysTgkill(frame: *idt.InterruptFrame) void {
    // Shift args: ignore tgid, use tid and sig
    frame.rdi = frame.rsi; // tid
    frame.rsi = frame.rdx; // sig
    sysTkill(frame);
}

/// rmdir(path) — nr 84, remove an empty directory
fn sysRmdir(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Resolve relative paths by prepending cwd
    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const result = vfs.resolvePath(path_buf[0..path_len]);

    if (result.inode == null) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    const parent = result.parent orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Zee eBPF: security policy check
    if (!security.checkMutate(path_buf[0..path_len], current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    const rmdir_fn = parent.ops.rmdir orelse {
        frame.rax = @bitCast(@as(i64, -errno.EROFS));
        return;
    };
    if (rmdir_fn(parent, result.leaf_name[0..result.leaf_len])) {
        frame.rax = 0;
    } else {
        serial.writeString("[rmdir-fail] ");
        serial.writeString(path_buf[0..path_len]);
        serial.writeString("\n");
        frame.rax = @bitCast(@as(i64, -errno.ENOTEMPTY));
    }
}

/// sync() — nr 162
/// Flush filesystem metadata to disk.
fn sysSync(frame: *idt.InterruptFrame) void {
    ext2.sync();
    frame.rax = 0;
}

/// exit_group(status) — nr 231
/// For single-threaded processes, same as exit().
fn sysExitGroup(frame: *idt.InterruptFrame) void {
    syscall.sysExit(frame);
}

// --- New syscalls for Zig compiler support ---

/// pread64(fd, buf, count, offset) — nr 17
/// Read at a given offset without changing the file position.
fn sysPread64(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const buf_addr = frame.rsi;
    const count = frame.rdx;
    const offset = frame.r10; // 4th arg via r10

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (!syscall.validateUserBuffer(buf_addr, count)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const read_fn = desc.inode.ops.read orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Save original offset, set to requested position
    const saved_offset = desc.offset;
    desc.offset = offset;

    const actual_len: usize = if (count > 1048576) 1048576 else @truncate(count);
    var total_read: usize = 0;
    var remaining = actual_len;
    var addr = buf_addr;

    while (remaining > 0) {
        const page_offset: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, types.PAGE_SIZE - page_offset);

        if (vmm.translate(current.page_table, addr)) |phys| {
            const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
            const n = read_fn(desc, ptr, chunk);
            if (n <= 0) break;
            total_read += @intCast(n);
            if (@as(usize, @intCast(n)) < chunk) break;
        } else break;

        addr += chunk;
        remaining -= chunk;
    }

    // Restore original offset (pread doesn't change position)
    desc.offset = saved_offset;
    frame.rax = total_read;
}

/// pwrite64(fd, buf, count, offset) — nr 18
/// Write at a given offset without changing the file position.
fn sysPwrite64(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const buf_addr = frame.rsi;
    const count = frame.rdx;
    const offset = frame.r10; // 4th arg via r10

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (!syscall.validateUserBuffer(buf_addr, count)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const write_fn = desc.inode.ops.write orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const saved_offset = desc.offset;
    desc.offset = offset;

    const actual_len: usize = if (count > 1048576) 1048576 else @truncate(count);
    var total_written: usize = 0;
    var remaining = actual_len;
    var addr = buf_addr;

    while (remaining > 0) {
        const page_offset: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, types.PAGE_SIZE - page_offset);

        if (vmm.translate(current.page_table, addr)) |phys| {
            const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
            const n = write_fn(desc, ptr, chunk);
            if (n <= 0) break;
            total_written += @intCast(n);
        } else break;

        addr += chunk;
        remaining -= chunk;
    }

    desc.offset = saved_offset;
    frame.rax = total_written;
}

/// pwritev(fd, iov, iovcnt, offset) — nr 296
/// Positional gather write. Returns -ESPIPE for non-seekable fds (pipes, console).
fn sysPwritev(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const iov_addr = frame.rsi;
    const iovcnt = frame.rdx;
    const offset = frame.r10; // 4th arg via r10

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (iovcnt == 0 or iovcnt > 1024) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Only regular files support positional I/O.
    // Pipes, console, sockets → ESPIPE so Zig's writer falls back to streaming.
    const S_IFMT: u32 = 0o170000;
    const S_IFREG: u32 = 0o100000;
    if (desc.inode.mode & S_IFMT != S_IFREG) {
        frame.rax = @bitCast(@as(i64, -errno.ESPIPE));
        return;
    }

    const write_fn = desc.inode.ops.write orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Save offset, set to requested position
    const saved_offset = desc.offset;
    desc.offset = offset;

    var total_written: usize = 0;
    const cnt: usize = @truncate(iovcnt);

    for (0..cnt) |i| {
        const iov_entry_addr = iov_addr + i * 16;
        if (!syscall.validateUserBuffer(iov_entry_addr, 16)) break;

        var iov_data: [16]u8 = undefined;
        const copied = syscall.copyFromUserRaw(current.page_table, iov_entry_addr, &iov_data, 16);
        if (copied < 16) break;

        const iov_base = readU64LE(iov_data[0..8]);
        const iov_len = readU64LE(iov_data[8..16]);

        if (iov_len == 0) continue;
        if (!syscall.validateUserBuffer(iov_base, iov_len)) break;

        const actual_len: usize = if (iov_len > 1048576) 1048576 else @truncate(iov_len);
        var remaining = actual_len;
        var addr = iov_base;

        while (remaining > 0) {
            const page_offset: usize = @truncate(addr & 0xFFF);
            const chunk = @min(remaining, types.PAGE_SIZE - page_offset);

            const phys = vmm.translate(current.page_table, addr) orelse blk: {
                const fault = @import("../mm/fault.zig");
                if (fault.demandPageUser(addr)) {
                    break :blk vmm.translate(current.page_table, addr) orelse break;
                }
                break;
            };
            const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
            const n = write_fn(desc, ptr, chunk);
            if (n <= 0) break;
            total_written += @intCast(n);

            addr += chunk;
            remaining -= chunk;
        }
    }

    // Restore original offset (positional write shouldn't change it)
    desc.offset = saved_offset;
    frame.rax = total_written;
}

/// access(pathname, mode) — nr 21
/// Check whether the calling process can access the file.
fn sysAccess(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Resolve relative paths
    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const inode = vfs.resolve(path_buf[0..path_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };
    _ = inode;

    // File exists — for our simple OS, return success
    frame.rax = 0;
}

/// sched_yield() — nr 24
/// Yield the processor to another thread.
fn sysSchedYield(frame: *idt.InterruptFrame) void {
    frame.rax = 0;
}

/// madvise(addr, length, advice) — nr 28
/// Advisory — no-op, return success.
fn sysMadvise(frame: *idt.InterruptFrame) void {
    frame.rax = 0;
}

/// dup(oldfd) — nr 32
/// Duplicate a file descriptor, returning the lowest available fd.
fn sysDup(frame: *idt.InterruptFrame) void {
    const oldfd = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, oldfd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    desc.ref_count += 1;
    const new_fd = fd_table.fdAlloc(&current.fds, desc) orelse {
        desc.ref_count -= 1;
        frame.rax = @bitCast(@as(i64, -errno.EMFILE));
        return;
    };

    frame.rax = new_fd;
}

/// nanosleep(req, rem) — nr 35
/// Sleep for the specified time. Busy-waits using tick counter.
fn sysNanosleep(frame: *idt.InterruptFrame) void {
    const req_addr = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(req_addr, 16)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Read timespec {tv_sec: i64, tv_nsec: i64} from user
    var req_buf: [16]u8 = undefined;
    const copied = syscall.copyFromUserRaw(current.page_table, req_addr, &req_buf, 16);
    if (copied < 16) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const tv_sec = readU64LE(req_buf[0..8]);
    const tv_nsec = readU64LE(req_buf[8..16]);

    // Convert to ticks (100 Hz timer = 10ms per tick)
    const total_ticks = tv_sec * 100 + tv_nsec / 10_000_000;

    if (total_ticks == 0) {
        frame.rax = 0;
        return;
    }

    // Block until wake_tick, scheduler will wake us in timerTick
    current.wake_tick = idt.getTickCount() + total_ticks;
    current.state = .blocked;
    frame.rip -= 2; // Rewind past `int 0x80` for syscall restart
    scheduler.blockAndSchedule(frame);
}

/// fcntl(fd, cmd, arg) — nr 72
/// File descriptor control operations.
fn sysFcntl(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const cmd: u32 = @truncate(frame.rsi);
    const arg = frame.rdx;

    const F_DUPFD: u32 = 0;
    const F_GETFD: u32 = 1;
    const F_SETFD: u32 = 2;
    const F_GETFL: u32 = 3;
    const F_SETFL: u32 = 4;
    const F_DUPFD_CLOEXEC: u32 = 1030;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    switch (cmd) {
        F_DUPFD, F_DUPFD_CLOEXEC => {
            // Duplicate fd to lowest available >= arg
            desc.ref_count += 1;
            const min_fd: usize = @truncate(arg);
            var new_fd: ?u32 = null;
            for (min_fd..fd_table.MAX_FDS) |i| {
                if (current.fds[i] == null) {
                    current.fds[i] = desc;
                    new_fd = @truncate(i);
                    break;
                }
            }
            if (new_fd) |nfd| {
                frame.rax = nfd;
            } else {
                desc.ref_count -= 1;
                frame.rax = @bitCast(@as(i64, -errno.EMFILE));
            }
        },
        F_GETFD => {
            // We don't track close-on-exec per fd, return 0
            frame.rax = 0;
        },
        F_SETFD => {
            // Ignore close-on-exec flag (we don't implement it)
            frame.rax = 0;
        },
        F_GETFL => {
            frame.rax = desc.flags;
        },
        F_SETFL => {
            // Only allow changing O_APPEND, O_NONBLOCK, etc.
            desc.flags = @truncate(arg);
            frame.rax = 0;
        },
        6, 7 => {
            // F_SETLK(6), F_SETLKW(7) — stub: pretend lock succeeded.
            // No contention possible in single-address-space processes.
            frame.rax = 0;
        },
        5 => {
            // F_GETLK(5) — check for conflicting lock.
            // Since we don't implement real locking, there's never a conflict.
            // Set l_type = F_UNLCK (2) to indicate no conflicting lock.
            if (arg != 0) {
                const proc = scheduler.currentProcess() orelse {
                    frame.rax = @bitCast(@as(i64, -errno.ESRCH));
                    return;
                };
                // struct flock { short l_type; ... } — l_type is first field (2 bytes on x86_64)
                // Linux flock: l_type=i16 at offset 0, then l_whence=i16, l_start=i64, l_len=i64, l_pid=i32
                const F_UNLCK: u16 = 2;
                const pte = vmm.translate(proc.page_table, arg);
                if (pte != null) {
                    const phys = pte.? & ~@as(u64, 0xFFF);
                    const off: usize = @truncate(arg & 0xFFF);
                    const base: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
                    // Write F_UNLCK to l_type (first 2 bytes)
                    base[off] = @truncate(F_UNLCK);
                    base[off + 1] = 0;
                }
            }
            frame.rax = 0;
        },
        else => {
            frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        },
    }
}

/// rename(oldpath, newpath) — nr 82
fn sysRename(frame: *idt.InterruptFrame) void {
    const oldpath_addr = frame.rdi;
    const newpath_addr = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(oldpath_addr, 1) or !syscall.validateUserBuffer(newpath_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Copy both paths from user
    var raw_old: [256]u8 = undefined;
    const raw_old_len = syscall.copyFromUser(current.page_table, oldpath_addr, &raw_old, 255);
    if (raw_old_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    var raw_new: [256]u8 = undefined;
    const raw_new_len = syscall.copyFromUser(current.page_table, newpath_addr, &raw_new, 255);
    if (raw_new_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Resolve relative paths
    var old_buf: [512]u8 = undefined;
    const old_len = resolveRelativePath(current, &raw_old, raw_old_len, &old_buf);
    if (old_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    var new_buf: [512]u8 = undefined;
    const new_len = resolveRelativePath(current, &raw_new, raw_new_len, &new_buf);
    if (new_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    // Resolve both paths to get parents and leaf names
    const old_result = vfs.resolvePath(old_buf[0..old_len]);
    if (old_result.inode == null) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }
    const old_parent = old_result.parent orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    const new_result = vfs.resolvePath(new_buf[0..new_len]);
    const new_parent = new_result.parent orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Permission check: need W+X on both parent directories
    if (!checkPermission(old_parent, 3, current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }
    if (!checkPermission(new_parent, 3, current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    // Zee eBPF: security policy check on both paths
    if (!security.checkMutate(old_buf[0..old_len], current) or !security.checkMutate(new_buf[0..new_len], current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    // Both parents must have rename ops (same filesystem)
    const rename_fn = old_parent.ops.rename orelse {
        frame.rax = @bitCast(@as(i64, -errno.EXDEV));
        return;
    };
    if (new_parent.ops.rename == null) {
        frame.rax = @bitCast(@as(i64, -errno.EXDEV));
        return;
    }

    if (rename_fn(old_parent, old_result.leaf_name[0..old_result.leaf_len], new_parent, new_result.leaf_name[0..new_result.leaf_len])) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EIO));
    }
}

/// sched_getaffinity(pid, cpusetsize, mask) — nr 204
/// Return a 1-bit CPU mask (single CPU system).
fn sysSchedGetaffinity(frame: *idt.InterruptFrame) void {
    const cpusetsize = frame.rsi;
    const mask_addr = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (cpusetsize == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    if (!syscall.validateUserBuffer(mask_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Write 1-byte mask: CPU 0 is available
    var mask: [1]u8 = .{0x01};
    if (syscall.copyToUser(current.page_table, mask_addr, &mask)) {
        // Zero remaining bytes if cpusetsize > 1
        if (cpusetsize > 1) {
            const zero_len: usize = if (cpusetsize - 1 > 128) 128 else @truncate(cpusetsize - 1);
            var zeros: [128]u8 = [_]u8{0} ** 128;
            if (!syscall.copyToUser(current.page_table, mask_addr + 1, zeros[0..zero_len])) {
                frame.rax = @bitCast(@as(i64, -errno.EFAULT));
                return;
            }
        }
        // Linux returns the cpuset size written (minimum 8 bytes)
        const ret_size: usize = if (cpusetsize < 8) @as(usize, @truncate(cpusetsize)) else 8;
        frame.rax = ret_size;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// newfstatat(dirfd, pathname, statbuf, flags) — nr 262
/// Like stat but relative to a directory fd. AT_FDCWD supported.
fn sysNewfstatat(frame: *idt.InterruptFrame) void {
    const dirfd = frame.rdi;
    const path_addr = frame.rsi;
    const buf_addr = frame.rdx;
    const flags = frame.r10;
    const AT_EMPTY_PATH: u64 = 0x1000;

    if (@as(i64, @bitCast(dirfd)) == vfs.AT_FDCWD) {
        // Delegate: shift args to stat convention (path→rdi, buf→rsi)
        frame.rdi = path_addr;
        frame.rsi = buf_addr;
        sysStat(frame);
        return;
    }

    // Real dirfd — resolve via fd table
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const dir_desc = fd_table.fdGet(&current.fds, dirfd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (!syscall.validateUserBuffer(buf_addr, 144)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // AT_EMPTY_PATH: stat the fd itself
    var inode: *vfs.Inode = undefined;
    if (flags & AT_EMPTY_PATH != 0) {
        inode = dir_desc.inode;
    } else {
        if (!syscall.validateUserBuffer(path_addr, 1)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }

        var path_buf: [256]u8 = undefined;
        const path_len = syscall.copyFromUser(current.page_table, path_addr, &path_buf, 255);
        if (path_len == 0) {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
            return;
        }

        // Absolute path — use normal stat
        if (path_buf[0] == '/') {
            frame.rdi = path_addr;
            frame.rsi = buf_addr;
            sysStat(frame);
            return;
        }

        const dir_inode = dir_desc.inode;
        if (dir_inode.mode & vfs.S_IFMT != vfs.S_IFDIR) {
            frame.rax = @bitCast(@as(i64, -errno.ENOTDIR));
            return;
        }

        const resolved = resolveFromInode(dir_inode, path_buf[0..path_len]);
        inode = resolved.inode orelse {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
            return;
        };
    }

    var st: vfs.Stat = undefined;
    vfs.statFromInode(inode, &st);

    var buf: [144]u8 = [_]u8{0} ** 144;
    packStat(&buf, &st);

    if (syscall.copyToUser(current.page_table, buf_addr, &buf)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// faccessat(dirfd, pathname, mode, flags) — nr 269
/// Like access but relative to a directory fd. AT_FDCWD supported.
fn sysFaccessat(frame: *idt.InterruptFrame) void {
    const dirfd = frame.rdi;

    if (@as(i64, @bitCast(dirfd)) == vfs.AT_FDCWD) {
        frame.rdi = frame.rsi;
        frame.rsi = frame.rdx;
        sysAccess(frame);
        return;
    }

    // Real dirfd — resolve and check existence
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const dir_desc = fd_table.fdGet(&current.fds, dirfd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const dir_inode = dir_desc.inode;
    if (dir_inode.mode & vfs.S_IFMT != vfs.S_IFDIR) {
        frame.rax = @bitCast(@as(i64, -errno.ENOTDIR));
        return;
    }

    const path_addr = frame.rsi;
    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var path_buf: [256]u8 = undefined;
    const path_len = syscall.copyFromUser(current.page_table, path_addr, &path_buf, 255);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    const resolved = resolveFromInode(dir_inode, path_buf[0..path_len]);
    if (resolved.inode != null) {
        frame.rax = 0; // exists → accessible
    } else {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
    }
}

/// set_robust_list(head, len) — nr 273
/// No-op stub — robust futex lists not implemented.
fn sysSetRobustList(frame: *idt.InterruptFrame) void {
    frame.rax = 0;
}

/// pipe2(pipefd, flags) — nr 293
/// Like pipe() but with flags (O_CLOEXEC, O_NONBLOCK). Flags ignored.
fn sysPipe2(frame: *idt.InterruptFrame) void {
    // Ignore flags (in rsi), delegate to pipe
    sysPipe(frame);
}

/// prlimit64(pid, resource, new_rlim, old_rlim) — nr 302
/// Get/set resource limits. Returns hardcoded values.
fn sysPrlimit64(frame: *idt.InterruptFrame) void {
    const resource: u32 = @truncate(frame.rsi);
    // new_rlim = rdx (ignored)
    const old_rlim_addr = frame.r10; // 4th arg via r10

    const RLIMIT_STACK: u32 = 3;
    const RLIMIT_NOFILE: u32 = 7;
    const RLIMIT_AS: u32 = 9;
    const RLIM_INFINITY: u64 = 0xFFFFFFFFFFFFFFFF;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // If old_rlim is non-null, write current limits
    if (old_rlim_addr != 0) {
        if (!syscall.validateUserBuffer(old_rlim_addr, 16)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }

        var rlim_buf: [16]u8 = undefined;
        var soft: u64 = RLIM_INFINITY;
        var hard: u64 = RLIM_INFINITY;

        switch (resource) {
            RLIMIT_STACK => {
                // 48 MiB stack
                soft = 48 * 1024 * 1024;
                hard = 48 * 1024 * 1024;
            },
            RLIMIT_NOFILE => {
                soft = fd_table.MAX_FDS;
                hard = fd_table.MAX_FDS;
            },
            RLIMIT_AS => {
                soft = RLIM_INFINITY;
                hard = RLIM_INFINITY;
            },
            else => {
                // Return infinity for unknown resources
            },
        }

        writeU64LE(rlim_buf[0..8], soft);
        writeU64LE(rlim_buf[8..16], hard);
        if (!syscall.copyToUser(current.page_table, old_rlim_addr, &rlim_buf)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
    }

    // Ignore new_rlim (don't actually change limits)
    frame.rax = 0;
}

/// getrandom(buf, buflen, flags) — nr 318
/// Fill buffer with random bytes using RDTSC-based PRNG.
fn sysGetrandom(frame: *idt.InterruptFrame) void {
    const buf_addr = frame.rdi;
    const buflen = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (buflen == 0) {
        frame.rax = 0;
        return;
    }

    const actual_len: usize = if (buflen > 256) 256 else @truncate(buflen);

    if (!syscall.validateUserBuffer(buf_addr, actual_len)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Generate random bytes using RDTSC-seeded LCG
    var seed: u64 = rdtsc();
    var rand_buf: [256]u8 = undefined;
    for (0..actual_len) |i| {
        seed = seed *% 6364136223846793005 +% 1;
        rand_buf[i] = @truncate(seed >> 33);
    }

    if (syscall.copyToUser(current.page_table, buf_addr, rand_buf[0..actual_len])) {
        frame.rax = actual_len;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// rseq(rseq, rseq_len, flags, sig) — nr 334
/// Restartable sequences — not supported, return -ENOSYS.
fn sysRseq(frame: *idt.InterruptFrame) void {
    frame.rax = @bitCast(@as(i64, -errno.ENOSYS));
}

// --- Hardening: common syscall stubs ---

/// getppid() — nr 110. Return parent process ID.
fn sysGetppid(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess() orelse {
        frame.rax = 0;
        return;
    };
    frame.rax = current.parent_pid;
}

/// fsync(fd) — nr 36. Flush file data+metadata to disk, commit journal.
fn sysFsync(frame: *idt.InterruptFrame) void {
    const fd_num = frame.rdi;
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    const desc = fd_table.fdGet(&current.fds, fd_num) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    // Flush inode metadata to disk if this is an ext2 file (ino >= 2)
    if (desc.inode.ino >= 2 and desc.inode.ino < 0x20000) {
        ext2.writeInodeMetadata(desc.inode);
    }
    ext2.syncFile();
    frame.rax = 0;
}

/// fdatasync(fd) — nr 37. Flush file data to disk, commit journal.
fn sysFdatasync(frame: *idt.InterruptFrame) void {
    const fd_num = frame.rdi;
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    _ = fd_table.fdGet(&current.fds, fd_num) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    ext2.syncFile();
    frame.rax = 0;
}

/// setsockopt(fd, level, optname, optval, optlen) — nr 54.
fn sysSetsockopt(frame: *idt.InterruptFrame) void {
    const fd_num: usize = @truncate(frame.rdi);
    const level: u32 = @truncate(frame.rsi);
    const optname: u32 = @truncate(frame.rdx);
    const optval_ptr: u64 = frame.r10;

    const proc = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -9)); // -EBADF
        return;
    };
    if (fd_num >= fd_table.MAX_FDS) {
        frame.rax = @bitCast(@as(i64, -9));
        return;
    }
    const desc = proc.fds[fd_num] orelse {
        frame.rax = @bitCast(@as(i64, -9));
        return;
    };
    const sock_idx = socket_mod.getSocketIndexFromInode(desc.inode) orelse {
        frame.rax = @bitCast(@as(i64, -88)); // -ENOTSOCK
        return;
    };
    const sock = socket_mod.getSocket(sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -88));
        return;
    };

    const val: u32 = if (optval_ptr != 0) blk: {
        const phys = vmm.translate(proc.page_table, optval_ptr) orelse break :blk @as(u32, 0);
        const ptr: *align(1) const u32 = @ptrFromInt(hhdm.physToVirt(phys));
        break :blk ptr.*;
    } else 0;
    const enabled = val != 0;

    const SOL_SOCKET: u32 = 1;
    const SO_REUSEADDR: u32 = 2;
    const SO_KEEPALIVE: u32 = 9;
    const IPPROTO_TCP: u32 = 6;
    const TCP_NODELAY: u32 = 1;

    switch (level) {
        SOL_SOCKET => switch (optname) {
            SO_REUSEADDR => sock.so_reuseaddr = enabled,
            SO_KEEPALIVE => sock.so_keepalive = enabled,
            else => {},
        },
        IPPROTO_TCP => switch (optname) {
            TCP_NODELAY => sock.tcp_nodelay = enabled,
            else => {},
        },
        else => {},
    }
    frame.rax = 0;
}

/// getsockopt(fd, level, optname, optval, optlen) — nr 55.
fn sysGetsockopt(frame: *idt.InterruptFrame) void {
    const fd_num: usize = @truncate(frame.rdi);
    const level: u32 = @truncate(frame.rsi);
    const optname: u32 = @truncate(frame.rdx);
    const optval_ptr: u64 = frame.r10;
    const optlen_ptr: u64 = frame.r8;

    const proc = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -9));
        return;
    };
    if (fd_num >= fd_table.MAX_FDS) {
        frame.rax = @bitCast(@as(i64, -9));
        return;
    }
    const desc = proc.fds[fd_num] orelse {
        frame.rax = @bitCast(@as(i64, -9));
        return;
    };
    const sock_idx = socket_mod.getSocketIndexFromInode(desc.inode) orelse {
        frame.rax = @bitCast(@as(i64, -88));
        return;
    };
    const sock = socket_mod.getSocket(sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -88));
        return;
    };

    const SOL_SOCKET: u32 = 1;
    const SO_REUSEADDR: u32 = 2;
    const SO_KEEPALIVE: u32 = 9;
    const IPPROTO_TCP: u32 = 6;
    const TCP_NODELAY: u32 = 1;

    var val: u32 = 0;
    switch (level) {
        SOL_SOCKET => switch (optname) {
            SO_REUSEADDR => val = @intFromBool(sock.so_reuseaddr),
            SO_KEEPALIVE => val = @intFromBool(sock.so_keepalive),
            else => {},
        },
        IPPROTO_TCP => switch (optname) {
            TCP_NODELAY => val = @intFromBool(sock.tcp_nodelay),
            else => {},
        },
        else => {},
    }

    if (optval_ptr != 0) {
        if (vmm.translate(proc.page_table, optval_ptr)) |phys| {
            const p: *align(1) u32 = @ptrFromInt(hhdm.physToVirt(phys));
            p.* = val;
        }
    }
    if (optlen_ptr != 0) {
        if (vmm.translate(proc.page_table, optlen_ptr)) |phys| {
            const p: *align(1) u32 = @ptrFromInt(hhdm.physToVirt(phys));
            p.* = 4;
        }
    }
    frame.rax = 0;
}

/// clock_getres(clockid, res) — nr 227
/// Write 10ms resolution (our PIT runs at 100 Hz).
fn sysClockGetres(frame: *idt.InterruptFrame) void {
    const clock_id = frame.rdi;
    const res_addr = frame.rsi;

    // Support CLOCK_REALTIME (0) and CLOCK_MONOTONIC (1)
    if (clock_id > 1) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    // If res is NULL, just return success (per POSIX)
    if (res_addr == 0) {
        frame.rax = 0;
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(res_addr, 16)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Resolution: 10ms = 10,000,000 ns
    var buf: [16]u8 = undefined;
    writeU64LE(buf[0..8], 0); // tv_sec = 0
    writeU64LE(buf[8..16], 10_000_000); // tv_nsec = 10ms
    if (syscall.copyToUser(current.page_table, res_addr, &buf)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// unlinkat(dirfd, pathname, flags) — nr 261
/// AT_FDCWD support. AT_REMOVEDIR flag delegates to rmdir.
fn sysUnlinkat(frame: *idt.InterruptFrame) void {
    const dirfd = frame.rdi;
    const AT_REMOVEDIR: u64 = 0x200;

    // (debug logging removed — was accidentally breaking unlinkat by returning ESRCH)

    if (@as(i64, @bitCast(dirfd)) == vfs.AT_FDCWD) {
        const flags = frame.rdx;
        frame.rdi = frame.rsi;
        if (flags & AT_REMOVEDIR != 0) {
            sysRmdir(frame);
        } else {
            sysUnlink(frame);
        }
        return;
    }

    // Real dirfd — resolve via fd table
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const dir_desc = fd_table.fdGet(&current.fds, dirfd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const dir_inode = dir_desc.inode;
    if (dir_inode.mode & vfs.S_IFMT != vfs.S_IFDIR) {
        frame.rax = @bitCast(@as(i64, -errno.ENOTDIR));
        return;
    }

    const path_addr = frame.rsi;
    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var path_buf: [256]u8 = undefined;
    const path_len = syscall.copyFromUser(current.page_table, path_addr, &path_buf, 255);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    const resolved = resolveFromInode(dir_inode, path_buf[0..path_len]);
    if (resolved.inode == null) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }
    const parent = resolved.parent orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    const flags = frame.rdx;
    if (flags & AT_REMOVEDIR != 0) {
        // Remove directory
        const rmdir_fn = parent.ops.rmdir orelse {
            frame.rax = @bitCast(@as(i64, -errno.EROFS));
            return;
        };
        if (rmdir_fn(parent, resolved.leaf_name[0..resolved.leaf_len])) {
            frame.rax = 0;
        } else {
            frame.rax = @bitCast(@as(i64, -errno.ENOTEMPTY));
        }
    } else {
        // Remove file
        const inode = resolved.inode.?;
        if (inode.mode & vfs.S_IFMT == vfs.S_IFDIR) {
            frame.rax = @bitCast(@as(i64, -errno.EISDIR));
            return;
        }
        const unlink_fn = parent.ops.unlink orelse {
            frame.rax = @bitCast(@as(i64, -errno.EROFS));
            return;
        };
        if (unlink_fn(parent, resolved.leaf_name[0..resolved.leaf_len])) {
            frame.rax = 0;
        } else {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        }
    }
}

/// renameat(olddirfd, oldpath, newdirfd, newpath) — nr 263
/// AT_FDCWD support only.
fn sysRenameat(frame: *idt.InterruptFrame) void {
    const olddirfd = frame.rdi;
    const newdirfd = frame.rdx;

    if (@as(i64, @bitCast(olddirfd)) != vfs.AT_FDCWD or @as(i64, @bitCast(newdirfd)) != vfs.AT_FDCWD) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }

    // Shift: oldpath→rdi, newpath→rsi
    frame.rdi = frame.rsi;
    frame.rsi = frame.r10; // 4th arg via r10
    sysRename(frame);
}

/// mkdirat(dirfd, pathname, mode) — nr 266
/// AT_FDCWD support.
fn sysMkdirat(frame: *idt.InterruptFrame) void {
    const dirfd = frame.rdi;

    if (@as(i64, @bitCast(dirfd)) == vfs.AT_FDCWD) {
        // Shift: pathname→rdi, mode→rsi
        frame.rdi = frame.rsi;
        frame.rsi = frame.rdx;
        sysMkdir(frame);
        return;
    }

    // Real dirfd — resolve via fd table
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, dirfd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const dir_inode = desc.inode;
    if (dir_inode.mode & vfs.S_IFMT != vfs.S_IFDIR) {
        frame.rax = @bitCast(@as(i64, -errno.ENOTDIR));
        return;
    }

    const path_addr = frame.rsi;
    const mode: u32 = @truncate(frame.rdx);

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var name_buf: [256]u8 = undefined;
    const name_len = syscall.copyFromUser(current.page_table, path_addr, &name_buf, 255);
    if (name_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Resolve path (may have multiple components like "a/b/c")
    const resolved = resolveFromInode(dir_inode, name_buf[0..name_len]);
    if (resolved.inode != null) {
        frame.rax = @bitCast(@as(i64, -errno.EEXIST));
        return;
    }
    const parent = resolved.parent orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    const create_fn = parent.ops.create orelse {
        frame.rax = @bitCast(@as(i64, -errno.EROFS));
        return;
    };
    const dir_mode = vfs.S_IFDIR | (mode & 0o777);
    if (create_fn(parent, resolved.leaf_name[0..resolved.leaf_len], dir_mode)) |_| {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
    }
}

// --- Phase 2: Zig compiler readiness syscalls ---

/// lstat(path, statbuf) — nr 6. Alias for stat (no real symlinks).
fn sysLstat(frame: *idt.InterruptFrame) void {
    sysStat(frame);
}

/// fchmod(fd, mode) — nr 91.
fn sysFchmod(frame: *idt.InterruptFrame) void {
    const fd: u32 = @truncate(frame.rdi);
    const new_mode: u32 = @truncate(frame.rsi);
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const inode = desc.inode;
    if (current.euid != 0 and current.euid != inode.uid) {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }
    inode.mode = (inode.mode & vfs.S_IFMT) | (new_mode & 0o7777);
    if (inode.ino >= 2 and inode.ino < 0x20000) ext2.setInodeMode(inode);
    frame.rax = 0;
}

/// fchown(fd, owner, group) — nr 93.
fn sysFchown(frame: *idt.InterruptFrame) void {
    const fd: u32 = @truncate(frame.rdi);
    const owner: u32 = @truncate(frame.rsi);
    const group: u32 = @truncate(frame.rdx);
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const inode = desc.inode;
    if (current.euid != 0) {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }
    if (owner != 0xFFFFFFFF) inode.uid = @truncate(owner);
    if (group != 0xFFFFFFFF) inode.gid = @truncate(group);
    if (inode.ino >= 2 and inode.ino < 0x20000) ext2.setInodeOwner(inode);
    frame.rax = 0;
}

/// umask(mask) — nr 95. Swap old/new umask, return previous.
fn sysUmask(frame: *idt.InterruptFrame) void {
    const new_mask: u32 = @truncate(frame.rdi & 0o7777);
    const current = scheduler.currentProcess() orelse {
        frame.rax = 0o022;
        return;
    };
    const old = current.umask_val;
    current.umask_val = new_mask;
    frame.rax = old;
}

/// getrusage(who, usage) — nr 98. Write zeroed 144-byte struct.
fn sysGetrusage(frame: *idt.InterruptFrame) void {
    const buf_addr = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(buf_addr, 144)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var buf: [144]u8 = [_]u8{0} ** 144;
    if (syscall.copyToUser(current.page_table, buf_addr, &buf)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// statfs(path, buf) — nr 137. Minimal ext2 statfs.
fn sysStatfs(frame: *idt.InterruptFrame) void {
    const buf_addr = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // struct statfs is 120 bytes on x86_64 Linux
    if (!syscall.validateUserBuffer(buf_addr, 120)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var buf: [120]u8 = [_]u8{0} ** 120;
    // f_type = 0xEF53 (ext2)
    writeU64LE(buf[0..8], 0xEF53);
    // f_bsize = 4096
    writeU64LE(buf[8..16], 4096);
    // f_blocks
    writeU64LE(buf[16..24], 65536);
    // f_bfree
    writeU64LE(buf[24..32], 32768);
    // f_bavail
    writeU64LE(buf[32..40], 32768);
    // f_files
    writeU64LE(buf[40..48], 8192);
    // f_ffree
    writeU64LE(buf[48..56], 4096);
    // f_namelen (offset 88)
    writeU64LE(buf[88..96], 255);

    if (syscall.copyToUser(current.page_table, buf_addr, &buf)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// fstatfs(fd, buf) — nr 138. Same as statfs via fd.
fn sysFstatfs(frame: *idt.InterruptFrame) void {
    // Shift buf_addr to rsi position for sysStatfs
    frame.rsi = frame.rsi;
    sysStatfs(frame);
}

/// prctl(option, arg2, arg3, arg4, arg5) — nr 157
fn sysPrctl(frame: *idt.InterruptFrame) void {
    // PR_SET_NAME = 15, others: return 0
    frame.rax = 0;
}

/// clock_nanosleep(clockid, flags, request, remain) — nr 230
/// Shift args and delegate to nanosleep.
fn sysClockNanosleep(frame: *idt.InterruptFrame) void {
    // clockid=rdi, flags=rsi, request=rdx, remain=r10
    // nanosleep wants: req=rdi, rem=rsi
    frame.rdi = frame.rdx; // request → rdi
    frame.rsi = frame.r10; // remain → rsi
    sysNanosleep(frame);
}

/// fchownat(dirfd, pathname, owner, group, flags) — nr 260.
fn sysFchownat(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rsi;
    const owner: u32 = @truncate(frame.rdx);
    const group: u32 = @truncate(frame.r10);
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    if (current.euid != 0) {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }
    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }
    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) { frame.rax = @bitCast(@as(i64, -errno.ENOENT)); return; }
    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) { frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG)); return; }
    const inode = vfs.resolve(path_buf[0..path_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };
    if (owner != 0xFFFFFFFF) inode.uid = @truncate(owner);
    if (group != 0xFFFFFFFF) inode.gid = @truncate(group);
    if (inode.ino >= 2 and inode.ino < 0x20000) ext2.setInodeOwner(inode);
    frame.rax = 0;
}

/// readlinkat(dirfd, pathname, buf, bufsiz) — nr 267
/// Check AT_FDCWD, shift args, delegate to readlink.
fn sysReadlinkat(frame: *idt.InterruptFrame) void {
    const dirfd = frame.rdi;
    if (@as(i64, @bitCast(dirfd)) != vfs.AT_FDCWD) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }
    // readlinkat(dirfd, path, buf, bufsiz) → readlink(path, buf, bufsiz)
    frame.rdi = frame.rsi; // pathname → rdi
    frame.rsi = frame.rdx; // buf → rsi
    frame.rdx = frame.r10; // bufsiz → rdx
    sysReadlink(frame);
}

/// fchmodat(dirfd, pathname, mode, flags) — nr 268.
fn sysFchmodat(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rsi;
    const new_mode: u32 = @truncate(frame.rdx);
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }
    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) { frame.rax = @bitCast(@as(i64, -errno.ENOENT)); return; }
    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) { frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG)); return; }
    const inode = vfs.resolve(path_buf[0..path_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };
    if (current.euid != 0 and current.euid != inode.uid) {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }
    inode.mode = (inode.mode & vfs.S_IFMT) | (new_mode & 0o7777);
    if (inode.ino >= 2 and inode.ino < 0x20000) ext2.setInodeMode(inode);
    frame.rax = 0;
}

/// ppoll(fds, nfds, tmo_p, sigmask, sigsetsize) — nr 271
/// Delegate to sysPoll (ignore sigmask/timespec differences).
fn sysPpoll(frame: *idt.InterruptFrame) void {
    sysPoll(frame);
}

/// dup3(oldfd, newfd, flags) — nr 292. Delegate to dup2 (ignore flags).
fn sysDup3(frame: *idt.InterruptFrame) void {
    sysDup2(frame);
}

/// poll(fds, nfds, timeout) — nr 7
/// For our synchronous kernel, files are always ready.
fn sysPoll(frame: *idt.InterruptFrame) void {
    const fds_addr = frame.rdi;
    const nfds = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (nfds == 0) {
        frame.rax = 0;
        return;
    }

    // Cap nfds to prevent excessive work
    const actual_nfds: usize = if (nfds > 64) 64 else @truncate(nfds);

    // struct pollfd = { int fd; short events; short revents; } = 8 bytes
    const POLLFD_SIZE: usize = 8;
    var ready: usize = 0;

    for (0..actual_nfds) |i| {
        const entry_addr = fds_addr + i * POLLFD_SIZE;

        if (!syscall.validateUserBuffer(entry_addr, POLLFD_SIZE)) break;

        // Read pollfd from user
        var pfd: [8]u8 = undefined;
        const copied = syscall.copyFromUserRaw(current.page_table, entry_addr, &pfd, POLLFD_SIZE);
        if (copied < POLLFD_SIZE) break;

        const fd: i32 = @bitCast(@as(u32, pfd[0]) | (@as(u32, pfd[1]) << 8) |
            (@as(u32, pfd[2]) << 16) | (@as(u32, pfd[3]) << 24));
        const events: i16 = @bitCast(@as(u16, pfd[4]) | (@as(u16, pfd[5]) << 8));

        // Set revents: if fd is valid, report events as ready
        var revents: i16 = 0;
        if (fd >= 0 and fd < @as(i32, @intCast(fd_table.MAX_FDS))) {
            if (fd_table.fdGet(&current.fds, @intCast(fd)) != null) {
                // POLLIN=1, POLLOUT=4, POLLHUP=16
                revents = events & 0x0045; // POLLIN|POLLPRI|POLLOUT
                if (revents != 0) ready += 1;
            } else {
                revents = 0x0020; // POLLNVAL
            }
        } else {
            revents = 0x0020; // POLLNVAL
        }

        // Write revents back (bytes 6-7 of pollfd)
        pfd[6] = @truncate(@as(u16, @bitCast(revents)));
        pfd[7] = @truncate(@as(u16, @bitCast(revents)) >> 8);

        _ = syscall.copyToUser(current.page_table, entry_addr, &pfd);
    }

    frame.rax = ready;
}

/// sched_dedicate(core_id) — nr 503 (Zigix custom).
/// Pins the calling process to a CPU core with zero preemption.
/// On single-CPU Zigix, core_id must be 0. The dedicated process
/// runs until it voluntarily yields, blocks, or exits.
fn sysSchedDedicate(frame: *idt.InterruptFrame) void {
    const core_id = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Single-CPU: only core 0 is valid
    if (core_id != 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    // Check if another process already holds the core
    if (scheduler.isDedicated()) {
        frame.rax = @bitCast(@as(i64, -errno.EBUSY));
        return;
    }

    scheduler.setDedicated(current.pid);
    frame.rax = 0;
}

/// sched_release() — nr 504 (Zigix custom).
/// Releases the dedicated core, resuming normal scheduling.
fn sysSchedRelease(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };
    _ = current;

    scheduler.clearDedicated();
    frame.rax = 0;
}

// --- DPDK / Hugepage support syscalls ---

/// virt_to_phys(vaddr) → physical address (nr 510)
/// Translates a user virtual address to its physical address.
/// For hugepage VMAs, computes: VMA.phys_base + (vaddr - VMA.start).
/// For regular 4K pages, walks the page table via vmm.translate().
/// Returns 0 on failure (unmapped address).
///
/// This is the key primitive for DMA descriptor programming: NIC descriptors
/// contain physical addresses, and userspace needs to fill them from its
/// virtual address space.
fn sysVirtToPhys(frame: *idt.InterruptFrame) void {
    const vaddr = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = 0;
        return;
    };

    // Fast path: check if the address is in a hugepage VMA
    const found_vma = vma_mod.findVma(&current.vmas, vaddr);
    if (found_vma) |v| {
        if (v.flags & vma_mod.VMA_HUGEPAGE != 0 and v.phys_base != 0) {
            // Hugepage VMA with known contiguous physical base
            frame.rax = v.phys_base + (vaddr - v.start);
            return;
        }
    }

    // Slow path: walk the page table
    if (vmm.translate(current.page_table, vaddr)) |phys| {
        frame.rax = phys;
    } else {
        frame.rax = 0;
    }
}

/// dma_info(vaddr, info_buf) → 0 on success, -EFAULT on error (nr 511)
/// Returns DMA information for the VMA containing vaddr:
///   info_buf[0]: physical base address
///   info_buf[1]: VMA size in bytes
///   info_buf[2]: page size (4096, 2097152, or 1073741824)
///   info_buf[3]: VMA flags
///
/// Used by zig_dpdk to discover hugepage region boundaries for IOMMU mapping.
fn sysDmaInfo(frame: *idt.InterruptFrame) void {
    const vaddr = frame.rdi;
    const info_addr = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(info_addr, 32)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const found_vma = vma_mod.findVma(&current.vmas, vaddr);
    if (found_vma) |v| {
        var info: [4]u64 = .{
            v.phys_base,
            v.end - v.start,
            v.page_size,
            @as(u64, v.flags),
        };
        if (syscall.copyToUser(current.page_table, info_addr, @as(*[32]u8, @ptrCast(&info)))) {
            frame.rax = 0;
        } else {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        }
    } else {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
    }
}

// --- Phase 3: Missing syscalls ---

/// preadv(fd, iov, iovcnt, offset) — nr 295
/// Positional scatter read. Returns -ESPIPE for non-seekable fds.
fn sysPreadv(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const iov_addr = frame.rsi;
    const iovcnt = frame.rdx;
    const offset = frame.r10;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (iovcnt == 0 or iovcnt > 1024) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Only regular files support positional I/O
    if (desc.inode.mode & vfs.S_IFMT != vfs.S_IFREG) {
        frame.rax = @bitCast(@as(i64, -errno.ESPIPE));
        return;
    }

    const read_fn = desc.inode.ops.read orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const saved_offset = desc.offset;
    desc.offset = offset;

    var total_read: usize = 0;
    const cnt: usize = @truncate(iovcnt);

    for (0..cnt) |i| {
        const iov_entry_addr = iov_addr + i * 16;
        if (!syscall.validateUserBuffer(iov_entry_addr, 16)) break;

        var iov_data: [16]u8 = undefined;
        const copied = syscall.copyFromUserRaw(current.page_table, iov_entry_addr, &iov_data, 16);
        if (copied < 16) break;

        const iov_base = readU64LE(iov_data[0..8]);
        const iov_len = readU64LE(iov_data[8..16]);

        if (iov_len == 0) continue;
        if (!syscall.validateUserBuffer(iov_base, iov_len)) break;

        const actual_len: usize = if (iov_len > 1048576) 1048576 else @truncate(iov_len);
        var remaining = actual_len;
        var addr = iov_base;

        while (remaining > 0) {
            const page_offset: usize = @truncate(addr & 0xFFF);
            const chunk = @min(remaining, types.PAGE_SIZE - page_offset);

            const phys = vmm.translate(current.page_table, addr) orelse blk: {
                const fault = @import("../mm/fault.zig");
                if (fault.demandPageUser(addr)) {
                    break :blk vmm.translate(current.page_table, addr) orelse break;
                }
                break;
            };
            const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
            const n = read_fn(desc, ptr, chunk);
            if (n <= 0) {
                if (total_read > 0) {
                    desc.offset = saved_offset;
                    frame.rax = total_read;
                    return;
                }
                break;
            }
            total_read += @intCast(n);
            if (@as(usize, @intCast(n)) < chunk) {
                desc.offset = saved_offset;
                frame.rax = total_read;
                return;
            }

            addr += chunk;
            remaining -= chunk;
        }
    }

    desc.offset = saved_offset;
    frame.rax = total_read;
}

/// statx(dirfd, pathname, flags, mask, statxbuf) — nr 332
/// Extended stat. Zig uses this for fileLength() and filePathKind().
fn sysStatx(frame: *idt.InterruptFrame) void {
    const dirfd = frame.rdi;
    const path_addr = frame.rsi;
    const flags: u32 = @truncate(frame.rdx);
    // mask in r10 (ignored — we fill everything)
    const buf_addr = frame.r8; // 5th arg

    const AT_EMPTY_PATH: u32 = 0x1000;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    var inode: *vfs.Inode = undefined;

    if (flags & AT_EMPTY_PATH != 0) {
        // AT_EMPTY_PATH: stat the fd itself
        const desc = fd_table.fdGet(&current.fds, dirfd) orelse {
            frame.rax = @bitCast(@as(i64, -errno.EBADF));
            return;
        };
        inode = desc.inode;
    } else {
        // Path-based: resolve path
        if (!syscall.validateUserBuffer(path_addr, 1)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }

        var raw_path: [256]u8 = undefined;
        const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
        if (raw_len == 0) {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
            return;
        }

        var path_buf: [512]u8 = undefined;
        const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
        if (path_len == 0) {
            frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
            return;
        }

        inode = vfs.resolve(path_buf[0..path_len]) orelse {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
            return;
        };
    }

    if (!syscall.validateUserBuffer(buf_addr, 256)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // struct statx is 256 bytes
    var buf: [256]u8 = [_]u8{0} ** 256;
    // stx_mask (offset 0, u32) — STATX_BASIC_STATS = 0x7FF
    writeU32LE(buf[0..4], 0x7FF);
    // stx_blksize (offset 4, u32)
    writeU32LE(buf[4..8], 4096);
    // stx_attributes (offset 8, u64) — 0
    // stx_nlink (offset 16, u32)
    writeU32LE(buf[16..20], inode.nlink);
    // stx_uid (offset 20, u32)
    writeU32LE(buf[20..24], inode.uid);
    // stx_gid (offset 24, u32)
    writeU32LE(buf[24..28], inode.gid);
    // stx_mode (offset 28, u16)
    buf[28] = @truncate(inode.mode);
    buf[29] = @truncate(inode.mode >> 8);
    // stx_ino (offset 32, u64)
    writeU64LE(buf[32..40], inode.ino);
    // stx_size (offset 40, u64)
    writeU64LE(buf[40..48], inode.size);
    // stx_blocks (offset 48, u64) = (size + 511) / 512
    writeU64LE(buf[48..56], (inode.size + 511) / 512);
    // stx_attributes_mask (offset 56, u64) — 0
    // timestamps left as zero

    if (syscall.copyToUser(current.page_table, buf_addr, &buf)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
    }
}

/// setsid() — nr 112. Create a new session.
fn sysSetsid(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Check if already a process group leader with other members
    // (simplified: just set sid and pgid)
    current.sid = current.pid;
    current.pgid = @truncate(current.pid);
    frame.rax = current.pid;
}

/// getsid(pid) — nr 147. Get session ID. pid=0 means self.
fn sysGetsid(frame: *idt.InterruptFrame) void {
    const target_pid = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (target_pid == 0) {
        frame.rax = current.sid;
        return;
    }

    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.pid == target_pid) {
                frame.rax = p.sid;
                return;
            }
        }
    }
    frame.rax = @bitCast(@as(i64, -errno.ESRCH));
}

/// getgroups(size, list) — nr 115. Return 0 (no supplementary groups).
fn sysGetgroups(frame: *idt.InterruptFrame) void {
    frame.rax = 0;
}

/// setgroups(size, list) — nr 116. No-op, return 0.
fn sysSetgroups(frame: *idt.InterruptFrame) void {
    frame.rax = 0;
}

// --- Phase 3.2: Filesystem metadata ---

/// chmod(pathname, mode) — nr 90
fn sysChmod(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;
    const new_mode: u32 = @truncate(frame.rsi);

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const inode = vfs.resolve(path_buf[0..path_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Only owner or root can chmod
    if (current.euid != 0 and current.euid != inode.uid) {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }

    // Update mode: keep file type, change permission bits
    inode.mode = (inode.mode & vfs.S_IFMT) | (new_mode & 0o7777);

    // Persist to disk via ext2
    if (inode.ino >= 2 and inode.ino < 0x20000) ext2.setInodeMode(inode);

    frame.rax = 0;
}

/// chown(pathname, owner, group) — nr 92
fn sysChown(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;
    const owner: u32 = @truncate(frame.rsi);
    const group: u32 = @truncate(frame.rdx);

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const inode = vfs.resolve(path_buf[0..path_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Only root can chown
    if (current.euid != 0) {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }

    // -1 (0xFFFFFFFF) means "don't change"
    if (owner != 0xFFFFFFFF) inode.uid = @truncate(owner);
    if (group != 0xFFFFFFFF) inode.gid = @truncate(group);

    if (inode.ino >= 2 and inode.ino < 0x20000) ext2.setInodeOwner(inode);

    frame.rax = 0;
}

/// lchown(pathname, owner, group) — nr 94. Like chown but don't follow symlinks.
/// Our VFS doesn't auto-follow symlinks, so this is identical to chown.
fn sysLchown(frame: *idt.InterruptFrame) void {
    sysChown(frame);
}

/// truncate(path, length) — nr 76
fn sysTruncate(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;
    const length = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const inode = vfs.resolve(path_buf[0..path_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    if (inode.mode & vfs.S_IFMT == vfs.S_IFDIR) {
        frame.rax = @bitCast(@as(i64, -errno.EISDIR));
        return;
    }

    // Zee eBPF: security policy check
    if (!security.checkMutate(path_buf[0..path_len], current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    if (length == 0) {
        if (inode.ops.truncate) |trunc_fn| {
            _ = trunc_fn(inode);
        }
        inode.size = 0;
    } else {
        inode.size = length;
    }

    frame.rax = 0;
}

/// fchdir(fd) — nr 81. Change cwd to directory referenced by fd.
fn sysFchdir(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (desc.inode.mode & vfs.S_IFMT != vfs.S_IFDIR) {
        frame.rax = @bitCast(@as(i64, -errno.ENOTDIR));
        return;
    }

    // For fchdir we'd need the path associated with the fd.
    // Since our kernel doesn't track inode→path mapping,
    // return success (the fd is valid and is a directory).
    // Most programs that use fchdir also did a prior openat which set the path.
    frame.rax = 0;
}

/// utimensat(dirfd, pathname, times, flags) — nr 320
/// Update file timestamps. times is struct timespec[2] or NULL (set to current time).
fn sysUtimensat(frame: *idt.InterruptFrame) void {
    const dirfd = frame.rdi;
    const path_addr = frame.rsi;
    // times_addr = rdx, flags = r10

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Support AT_FDCWD and empty-path fd-based
    if (path_addr == 0 or (@as(i64, @bitCast(dirfd)) != vfs.AT_FDCWD and path_addr == 0)) {
        // fd-based: stat the fd
        const desc = fd_table.fdGet(&current.fds, dirfd) orelse {
            frame.rax = @bitCast(@as(i64, -errno.EBADF));
            return;
        };
        _ = desc;
        // timestamps are not persisted in our VFS, return success
        frame.rax = 0;
        return;
    }

    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    var path_buf: [512]u8 = undefined;
    const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const inode = vfs.resolve(path_buf[0..path_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };
    _ = inode;

    // Timestamps not fully tracked in our inode struct — accept and return success
    frame.rax = 0;
}

// --- Phase 3.3: Filesystem structure (symlink/link) ---

/// symlink(target, linkpath) — nr 88
fn sysSymlink(frame: *idt.InterruptFrame) void {
    const target_addr = frame.rdi;
    const linkpath_addr = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(target_addr, 1) or !syscall.validateUserBuffer(linkpath_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Read target path
    var target_buf: [256]u8 = undefined;
    const target_len = syscall.copyFromUser(current.page_table, target_addr, &target_buf, 255);
    if (target_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Read and resolve linkpath
    var raw_link: [256]u8 = undefined;
    const raw_link_len = syscall.copyFromUser(current.page_table, linkpath_addr, &raw_link, 255);
    if (raw_link_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    var link_buf: [512]u8 = undefined;
    const link_len = resolveRelativePath(current, &raw_link, raw_link_len, &link_buf);
    if (link_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const result = vfs.resolvePath(link_buf[0..link_len]);
    if (result.inode != null) {
        frame.rax = @bitCast(@as(i64, -errno.EEXIST));
        return;
    }

    const parent = result.parent orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Zee eBPF: security policy check
    if (!security.checkMutate(link_buf[0..link_len], current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    const symlink_fn = parent.ops.symlink orelse {
        frame.rax = @bitCast(@as(i64, -errno.EROFS));
        return;
    };

    if (symlink_fn(parent, result.leaf_name[0..result.leaf_len], target_buf[0..target_len])) |_| {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EIO));
    }
}

/// symlinkat(target, newdirfd, linkpath) — nr 266
fn sysSymlinkat(frame: *idt.InterruptFrame) void {
    const newdirfd = frame.rsi;

    if (@as(i64, @bitCast(newdirfd)) != vfs.AT_FDCWD) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }

    // Shift: target stays in rdi, linkpath (rdx) → rsi
    frame.rsi = frame.rdx;
    sysSymlink(frame);
}

/// link(oldpath, newpath) — nr 86
fn sysLink(frame: *idt.InterruptFrame) void {
    const oldpath_addr = frame.rdi;
    const newpath_addr = frame.rsi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (!syscall.validateUserBuffer(oldpath_addr, 1) or !syscall.validateUserBuffer(newpath_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Resolve oldpath to get target inode
    var raw_old: [256]u8 = undefined;
    const raw_old_len = syscall.copyFromUser(current.page_table, oldpath_addr, &raw_old, 255);
    if (raw_old_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    var old_buf: [512]u8 = undefined;
    const old_len = resolveRelativePath(current, &raw_old, raw_old_len, &old_buf);
    if (old_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const target_inode = vfs.resolve(old_buf[0..old_len]) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Can't hard-link directories
    if (target_inode.mode & vfs.S_IFMT == vfs.S_IFDIR) {
        frame.rax = @bitCast(@as(i64, -errno.EPERM));
        return;
    }

    // Resolve newpath to get parent + leaf
    var raw_new: [256]u8 = undefined;
    const raw_new_len = syscall.copyFromUser(current.page_table, newpath_addr, &raw_new, 255);
    if (raw_new_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    var new_buf: [512]u8 = undefined;
    const new_len = resolveRelativePath(current, &raw_new, raw_new_len, &new_buf);
    if (new_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
        return;
    }

    const new_result = vfs.resolvePath(new_buf[0..new_len]);
    if (new_result.inode != null) {
        frame.rax = @bitCast(@as(i64, -errno.EEXIST));
        return;
    }

    const parent = new_result.parent orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Zee eBPF: security policy check
    if (!security.checkMutate(new_buf[0..new_len], current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    const link_fn = parent.ops.link orelse {
        frame.rax = @bitCast(@as(i64, -errno.EROFS));
        return;
    };

    if (link_fn(parent, new_result.leaf_name[0..new_result.leaf_len], target_inode)) {
        frame.rax = 0;
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EIO));
    }
}

/// linkat(olddirfd, oldpath, newdirfd, newpath, flags) — nr 265
fn sysLinkat(frame: *idt.InterruptFrame) void {
    const olddirfd = frame.rdi;
    const newdirfd = frame.rdx;

    if (@as(i64, @bitCast(olddirfd)) != vfs.AT_FDCWD or @as(i64, @bitCast(newdirfd)) != vfs.AT_FDCWD) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }

    // Shift: oldpath(rsi)→rdi, newpath(r10)→rsi
    frame.rdi = frame.rsi;
    frame.rsi = frame.r10;
    sysLink(frame);
}

// --- Phase 3.4: Socket + advanced I/O ---

/// accept4(fd, addr, addrlen, flags) — nr 288
/// Like accept but with flags (SOCK_CLOEXEC, SOCK_NONBLOCK). Flags ignored.
fn sysAccept4(frame: *idt.InterruptFrame) void {
    // Ignore flags in r10, delegate to accept
    socket_syscalls.sysAccept(frame);
}

/// getsockname(fd, addr, addrlen) — nr 51
fn sysGetsockname(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const addr_ptr = frame.rsi;
    const addrlen_ptr = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Check if this is a socket (mode has S_IFSOCK)
    const sock = socket_syscalls.getSocketFromInode(desc.inode) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOTSOCK));
        return;
    };

    if (addr_ptr == 0) {
        frame.rax = 0;
        return;
    }

    if (!syscall.validateUserBuffer(addr_ptr, 16)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Build sockaddr_in: family(2 LE) + port(2 BE) + ip(4 BE) + zero(8)
    var sa: [16]u8 = [_]u8{0} ** 16;
    sa[0] = 2; // AF_INET
    sa[1] = 0;
    // Port in network byte order (big endian)
    sa[2] = @truncate(sock.bound_port >> 8);
    sa[3] = @truncate(sock.bound_port);
    // Local IP: 10.0.2.15 for QEMU SLIRP
    sa[4] = 10;
    sa[5] = 0;
    sa[6] = 2;
    sa[7] = 15;

    if (!syscall.copyToUser(current.page_table, addr_ptr, &sa)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Write addrlen if provided
    if (addrlen_ptr != 0 and syscall.validateUserBuffer(addrlen_ptr, 4)) {
        var len_buf: [4]u8 = undefined;
        writeU32LE(&len_buf, 16);
        _ = syscall.copyToUser(current.page_table, addrlen_ptr, &len_buf);
    }

    frame.rax = 0;
}

/// getpeername(fd, addr, addrlen) — nr 52
fn sysGetpeername(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const addr_ptr = frame.rsi;
    const addrlen_ptr = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const sock = socket_syscalls.getSocketFromInode(desc.inode) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOTSOCK));
        return;
    };

    if (sock.remote_ip == 0 and sock.remote_port == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOTCONN));
        return;
    }

    if (addr_ptr == 0) {
        frame.rax = 0;
        return;
    }

    if (!syscall.validateUserBuffer(addr_ptr, 16)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var sa: [16]u8 = [_]u8{0} ** 16;
    sa[0] = 2; // AF_INET
    sa[1] = 0;
    sa[2] = @truncate(sock.remote_port >> 8);
    sa[3] = @truncate(sock.remote_port);
    // IP in network byte order
    sa[4] = @truncate(sock.remote_ip >> 24);
    sa[5] = @truncate(sock.remote_ip >> 16);
    sa[6] = @truncate(sock.remote_ip >> 8);
    sa[7] = @truncate(sock.remote_ip);

    if (!syscall.copyToUser(current.page_table, addr_ptr, &sa)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    if (addrlen_ptr != 0 and syscall.validateUserBuffer(addrlen_ptr, 4)) {
        var len_buf: [4]u8 = undefined;
        writeU32LE(&len_buf, 16);
        _ = syscall.copyToUser(current.page_table, addrlen_ptr, &len_buf);
    }

    frame.rax = 0;
}

/// sendfile(out_fd, in_fd, offset, count) — nr 40
/// Kernel-space file-to-file copy.
fn sysSendfile(frame: *idt.InterruptFrame) void {
    const out_fd = frame.rdi;
    const in_fd = frame.rsi;
    // offset_ptr = rdx (ignored for simplicity — use current position)
    const count = frame.r10;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const in_desc = fd_table.fdGet(&current.fds, in_fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const out_desc = fd_table.fdGet(&current.fds, out_fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const read_fn = in_desc.inode.ops.read orelse {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    };

    const write_fn = out_desc.inode.ops.write orelse {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    };

    const max_count: usize = if (count > 65536) 65536 else @truncate(count);
    var total: usize = 0;
    var buf: [4096]u8 = undefined;

    while (total < max_count) {
        const to_read = @min(buf.len, max_count - total);
        const n = read_fn(in_desc, &buf, to_read);
        if (n <= 0) break;
        const read_bytes: usize = @intCast(n);
        const w = write_fn(out_desc, &buf, read_bytes);
        if (w <= 0) break;
        total += @as(usize, @intCast(w));
    }

    frame.rax = total;
}

/// copy_file_range(fd_in, off_in, fd_out, off_out, len, flags) — nr 326
/// Kernel-space file-to-file copy between two fds.
fn sysCopyFileRange(frame: *idt.InterruptFrame) void {
    const fd_in = frame.rdi;
    // off_in_ptr = rsi (ignored)
    const fd_out = frame.rdx;
    // off_out_ptr = r10 (ignored)
    const len = frame.r8;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const in_desc = fd_table.fdGet(&current.fds, fd_in) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const out_desc = fd_table.fdGet(&current.fds, fd_out) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const read_fn = in_desc.inode.ops.read orelse {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    };

    const write_fn = out_desc.inode.ops.write orelse {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    };

    const max_len: usize = if (len > 65536) 65536 else @truncate(len);
    var total: usize = 0;
    var buf: [4096]u8 = undefined;

    while (total < max_len) {
        const to_read = @min(buf.len, max_len - total);
        const n = read_fn(in_desc, &buf, to_read);
        if (n <= 0) break;
        const read_bytes: usize = @intCast(n);
        const w = write_fn(out_desc, &buf, read_bytes);
        if (w <= 0) break;
        total += @as(usize, @intCast(w));
    }

    frame.rax = total;
}

/// select(nfds, readfds, writefds, exceptfds, timeout) — nr 23
/// Convert fd_set bitmasks to poll-style checking.
fn sysSelect(frame: *idt.InterruptFrame) void {
    const nfds: usize = @truncate(frame.rdi);
    const readfds_addr = frame.rsi;
    const writefds_addr = frame.rdx;
    // exceptfds = r10, timeout = r8

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (nfds > fd_table.MAX_FDS) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    // fd_set is 128 bytes (1024 bits) on Linux
    const FD_SET_SIZE: usize = 128;
    var read_set: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;
    var write_set: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;
    var ready: usize = 0;

    // Read fd sets from user
    if (readfds_addr != 0 and syscall.validateUserBuffer(readfds_addr, FD_SET_SIZE)) {
        _ = syscall.copyFromUserRaw(current.page_table, readfds_addr, &read_set, FD_SET_SIZE);
    }
    if (writefds_addr != 0 and syscall.validateUserBuffer(writefds_addr, FD_SET_SIZE)) {
        _ = syscall.copyFromUserRaw(current.page_table, writefds_addr, &write_set, FD_SET_SIZE);
    }

    // Check which fds are ready (for our simple kernel, valid fds are always ready)
    var out_read: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;
    var out_write: [FD_SET_SIZE]u8 = [_]u8{0} ** FD_SET_SIZE;

    for (0..nfds) |fd| {
        const byte_idx = fd / 8;
        const bit_idx: u3 = @truncate(fd % 8);
        const mask: u8 = @as(u8, 1) << bit_idx;

        if (read_set[byte_idx] & mask != 0) {
            if (fd_table.fdGet(&current.fds, @truncate(fd)) != null) {
                out_read[byte_idx] |= mask;
                ready += 1;
            }
        }
        if (write_set[byte_idx] & mask != 0) {
            if (fd_table.fdGet(&current.fds, @truncate(fd)) != null) {
                out_write[byte_idx] |= mask;
                ready += 1;
            }
        }
    }

    // Write back result sets
    if (readfds_addr != 0) {
        _ = syscall.copyToUser(current.page_table, readfds_addr, &out_read);
    }
    if (writefds_addr != 0) {
        _ = syscall.copyToUser(current.page_table, writefds_addr, &out_write);
    }

    frame.rax = ready;
}

// --- Helper: resolve relative path ---

/// Resolve a relative path by prepending cwd. Returns 0 on overflow (-ENAMETOOLONG).
/// Walk a relative path from a given directory inode, component by component.
/// Returns the resolved inode (or parent + leaf_name for creation).
fn resolveFromInode(start: *vfs.Inode, path: []const u8) vfs.ResolveResult {
    var result = vfs.ResolveResult{
        .inode = null,
        .parent = null,
        .leaf_name = [_]u8{0} ** 256,
        .leaf_len = 0,
    };

    if (path.len == 0) return result;

    var cur: *vfs.Inode = start;
    var pos: usize = 0;

    while (pos < path.len) {
        while (pos < path.len and path[pos] == '/') pos += 1;
        if (pos >= path.len) break;

        const comp_start = pos;
        while (pos < path.len and path[pos] != '/') pos += 1;
        const component = path[comp_start..pos];
        if (component.len == 0) continue;
        if (component.len > 255) return result;

        if (cur.mode & vfs.S_IFMT != vfs.S_IFDIR) return result;

        // Is this the last component?
        var at_end = pos >= path.len;
        if (!at_end) {
            var tmp = pos;
            while (tmp < path.len and path[tmp] == '/') tmp += 1;
            at_end = (tmp >= path.len);
        }

        if (at_end) {
            result.parent = cur;
            const len = @min(component.len, @as(usize, 255));
            for (0..len) |i| result.leaf_name[i] = component[i];
            result.leaf_len = @truncate(len);
        }

        const lookup_fn = cur.ops.lookup orelse return result;
        if (lookup_fn(cur, component)) |child| {
            cur = child;
            if (at_end) result.inode = child;
        } else {
            return result; // Not found — parent + leaf set if last component
        }
    }

    if (result.inode == null and result.parent == null) {
        result.inode = cur;
    }

    return result;
}

fn resolveRelativePath(current: *process.Process, raw_path: []const u8, raw_len: usize, path_buf: *[512]u8) usize {
    var path_len: usize = 0;
    if (raw_path[0] != '/') {
        const cwd_len: usize = current.cwd_len;
        // Check total length will fit: cwd + '/' + raw_len
        const separator: usize = if (cwd_len > 0 and current.cwd[cwd_len - 1] != '/') 1 else 0;
        if (cwd_len + separator + raw_len >= path_buf.len) return 0; // overflow
        for (0..cwd_len) |i| {
            path_buf[i] = current.cwd[i];
        }
        path_len = cwd_len;
        if (separator == 1) {
            path_buf[path_len] = '/';
            path_len += 1;
        }
        for (0..raw_len) |i| {
            path_buf[path_len] = raw_path[i];
            path_len += 1;
        }
    } else {
        if (raw_len >= path_buf.len) return 0; // overflow
        for (0..raw_len) |i| {
            path_buf[i] = raw_path[i];
        }
        path_len = raw_len;
    }
    return path_len;
}

/// Read RDTSC (timestamp counter) for PRNG seed.
fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
    );
    return @as(u64, high) << 32 | low;
}

fn readU64LE(buf: *const [8]u8) u64 {
    var val: u64 = 0;
    for (0..8) |i| {
        val |= @as(u64, buf[i]) << @intCast(i * 8);
    }
    return val;
}

// --- Helpers ---

/// Pack a Linux x86_64 struct stat (144 bytes).
fn packStat(buf: *[144]u8, st: *const vfs.Stat) void {
    // Zero the entire buffer first (handles padding and unused fields)
    for (0..144) |i| buf[i] = 0;
    // st_dev (offset 0, 8 bytes) = 0
    writeU64LE(buf[8..16], st.st_ino); // st_ino (offset 8)
    writeU64LE(buf[16..24], st.st_nlink); // st_nlink (offset 16)
    writeU32LE(buf[24..28], st.st_mode); // st_mode (offset 24)
    writeU32LE(buf[28..32], st.st_uid); // st_uid (offset 28)
    writeU32LE(buf[32..36], st.st_gid); // st_gid (offset 32)
    // __pad0 (offset 36, 4 bytes) = 0
    // st_rdev (offset 40, 8 bytes) = 0
    writeU64LE(buf[48..56], st.st_size); // st_size (offset 48)
    writeU64LE(buf[56..64], 4096); // st_blksize (offset 56)
    // st_blocks (offset 64) = (size + 511) / 512
    const blocks = (st.st_size + 511) / 512;
    writeU64LE(buf[64..72], blocks); // st_blocks
    // st_atime/mtime/ctime + nsec fields all left as 0
    // __unused[3] at offset 120, 24 bytes = 0
}

fn copyField(dest: *[65]u8, src: []const u8) void {
    const len = if (src.len > 64) 64 else src.len;
    for (0..len) |i| {
        dest[i] = src[i];
    }
    // Rest already zeroed
}

fn writeU64LE(buf: *[8]u8, val: u64) void {
    var v = val;
    for (0..8) |i| {
        buf[i] = @truncate(v);
        v >>= 8;
    }
}

fn writeU32LE(buf: *[4]u8, val: u32) void {
    var v = val;
    for (0..4) |i| {
        buf[i] = @truncate(v);
        v >>= 8;
    }
}

// ============================================================
// Phase 3.4: Feature stubs
// ============================================================

/// fallocate(fd, mode, offset, len) — nr 285
/// mode=0: extend file to offset+len if it's shorter.
/// mode=FALLOC_FL_PUNCH_HOLE|FALLOC_FL_KEEP_SIZE (3): zero the range, keep size.
fn sysFallocate(frame: *idt.InterruptFrame) void {
    const fd_num: i32 = @truncate(@as(i64, @bitCast(frame.rdi)));
    const mode: u32 = @truncate(frame.rsi);
    const offset: u64 = frame.rdx;
    const len: u64 = frame.r10;

    if (fd_num < 0) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (fd_num < 0 or @as(usize, @intCast(fd_num)) >= current.fds.len) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }
    const desc = current.fds[@intCast(fd_num)] orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const FALLOC_FL_KEEP_SIZE: u32 = 0x01;
    const FALLOC_FL_PUNCH_HOLE: u32 = 0x02;

    if (mode == 0) {
        // Default mode: ensure file is at least offset+len bytes.
        const new_size = offset + len;
        if (new_size > desc.inode.size) {
            desc.inode.size = new_size;
            // Also update tmpfs node size (tmpfs stores size separately)
            if (desc.inode.ino >= 0x20000 and desc.inode.fs_data != null) {
                const TmpfsNode = @import("../fs/tmpfs.zig").TmpfsNode;
                const tnode: *TmpfsNode = @alignCast(@ptrCast(desc.inode.fs_data.?));
                tnode.size = new_size;
            }
        }
        frame.rax = 0;
    } else if (mode & FALLOC_FL_PUNCH_HOLE != 0 and mode & FALLOC_FL_KEEP_SIZE != 0) {
        // Punch hole: zero the specified range, keep file size.
        // For tmpfs: zero the affected page ranges.
        // For ext2: just zero the data (we don't support true sparse files).
        const end = offset + len;
        const inode = desc.inode;

        // Only handle tmpfs for now (inode numbers >= 0x20000)
        if (inode.ino >= 0x20000 and inode.fs_data != null) {
            const node_ptr: *anyopaque = inode.fs_data.?;
            // Zero affected bytes in data pages
            var pos = offset;
            while (pos < end) {
                const page_idx = pos / types.PAGE_SIZE;
                const page_off: usize = @truncate(pos % types.PAGE_SIZE);
                const chunk = @min(end - pos, types.PAGE_SIZE - page_off);

                if (page_idx < 4096) { // MAX_DATA_PAGES
                    // Read the data_pages field from the TmpfsNode
                    // TmpfsNode layout: name(256) + name_len(1) + inode(vfs.Inode) + data_pages...
                    // We need to get the data page at this index.
                    // Use the inode's read function to check if page exists.
                    // Simpler: cast fs_data to get the node.
                    const TmpfsNode = @import("../fs/tmpfs.zig").TmpfsNode;
                    const tnode: *TmpfsNode = @alignCast(@ptrCast(node_ptr));
                    const dp_phys = if (tnode.dataPages()) |dp| dp[@as(usize, @truncate(page_idx))] else null;
                    if (dp_phys) |phys| {
                        const base: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
                        var k: usize = 0;
                        while (k < chunk) : (k += 1) {
                            base[page_off + k] = 0;
                        }
                    }
                    // If page doesn't exist, it's already zero (sparse) — nothing to do.
                }
                pos += chunk;
            }
            frame.rax = 0;
        } else {
            // ext2 or other fs: not supported yet
            frame.rax = @bitCast(@as(i64, -95)); // EOPNOTSUPP
        }
    } else {
        frame.rax = @bitCast(@as(i64, -95)); // EOPNOTSUPP
    }
}

/// mknod(pathname, mode, dev) — nr 133
/// Support S_IFIFO (named pipe) creation via tmpfs.
fn sysMknod(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;
    const mode: u32 = @truncate(frame.rsi);

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // S_IFIFO = 0o010000
    const S_IFIFO: u32 = 0o010000;
    if (mode & 0o170000 == S_IFIFO) {
        // Create a named pipe — delegate to pipe infrastructure
        // For now, create a regular file with FIFO mode (programs check mode)
        if (!syscall.validateUserBuffer(path_addr, 1)) {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        }
        var raw_path: [256]u8 = undefined;
        const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
        if (raw_len == 0) {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
            return;
        }
        var path_buf: [512]u8 = undefined;
        const path_len = resolveRelativePath(current, &raw_path, raw_len, &path_buf);
        if (path_len == 0) {
            frame.rax = @bitCast(@as(i64, -errno.ENAMETOOLONG));
            return;
        }
        const result = vfs.resolvePath(path_buf[0..path_len]);
        if (result.inode != null) {
            frame.rax = @bitCast(@as(i64, -errno.EEXIST));
            return;
        }
        const parent = result.parent orelse {
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
            return;
        };
        const create_fn = parent.ops.create orelse {
            frame.rax = @bitCast(@as(i64, -errno.EROFS));
            return;
        };
        // Create with FIFO mode
        if (create_fn(parent, result.leaf_name[0..result.leaf_len], mode)) |_| {
            frame.rax = 0;
        } else {
            frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        }
        return;
    }

    // Other device types not supported
    frame.rax = @bitCast(@as(i64, -errno.EPERM));
}

/// mknodat(dirfd, pathname, mode, dev) — nr 259
fn sysMknodat(frame: *idt.InterruptFrame) void {
    const dirfd = frame.rdi;
    if (@as(i64, @bitCast(dirfd)) == vfs.AT_FDCWD) {
        frame.rdi = frame.rsi;
        frame.rsi = frame.rdx;
        sysMknod(frame);
        return;
    }
    frame.rax = @bitCast(@as(i64, -errno.ENOSYS));
}

// ============================================================
// Inotify — lightweight file event monitoring
// ============================================================

const MAX_INOTIFY_WATCHES: usize = 16;
const MAX_INOTIFY_EVENTS: usize = 32;

const InotifyWatch = struct {
    in_use: bool = false,
    ifd: i32 = -1, // inotify fd this watch belongs to
    wd: i32 = 0, // watch descriptor
    ino: u64 = 0, // inode number of watched path
    mask: u32 = 0, // event mask
};

const InotifyEvent = struct {
    in_use: bool = false,
    ifd: i32 = -1, // inotify fd that should receive this event
    wd: i32 = 0, // watch descriptor that matched
    mask: u32 = 0, // event type (IN_CREATE, IN_DELETE, etc.)
    name: [256]u8 = [_]u8{0} ** 256,
    name_len: u32 = 0,
};

var inotify_watches: [MAX_INOTIFY_WATCHES]InotifyWatch = [_]InotifyWatch{.{}} ** MAX_INOTIFY_WATCHES;
var inotify_events: [MAX_INOTIFY_EVENTS]InotifyEvent = [_]InotifyEvent{.{}} ** MAX_INOTIFY_EVENTS;
var next_wd: i32 = 1;
var next_inotify_fd: i32 = 100; // Use high fd numbers to avoid conflicts

/// Post an inotify event for filesystem operations.
/// Called by VFS operations (create, unlink, etc.) to notify watchers.
pub fn inotifyPostEvent(parent_ino: u64, event_mask: u32, name: []const u8) void {
    // Find watches matching this parent inode
    for (0..MAX_INOTIFY_WATCHES) |i| {
        if (inotify_watches[i].in_use and inotify_watches[i].ino == parent_ino) {
            if (inotify_watches[i].mask & event_mask != 0) {
                // Find free event slot
                for (0..MAX_INOTIFY_EVENTS) |j| {
                    if (!inotify_events[j].in_use) {
                        inotify_events[j].in_use = true;
                        inotify_events[j].ifd = inotify_watches[i].ifd;
                        inotify_events[j].wd = inotify_watches[i].wd;
                        inotify_events[j].mask = event_mask;
                        const len: u32 = if (name.len > 255) 255 else @truncate(name.len);
                        for (0..len) |k| inotify_events[j].name[k] = name[k];
                        inotify_events[j].name_len = len;
                        break;
                    }
                }
            }
        }
    }
}

fn inotifyRead(ifd: i32, buf: [*]u8, count: usize) isize {
    // struct inotify_event { i32 wd; u32 mask; u32 cookie; u32 len; char name[]; }
    // Minimum size: 16 bytes (without name). With name: 16 + len (rounded to align).
    var written: usize = 0;
    for (0..MAX_INOTIFY_EVENTS) |i| {
        if (inotify_events[i].in_use and inotify_events[i].ifd == ifd) {
            const name_len = inotify_events[i].name_len;
            // Align name_len to 4 bytes (Linux requirement)
            const aligned_len = (name_len + 4) & ~@as(u32, 3);
            const event_size: usize = 16 + aligned_len;

            if (written + event_size > count) break;

            // Write wd (i32)
            const wd_bytes: [4]u8 = @bitCast(inotify_events[i].wd);
            for (0..4) |k| buf[written + k] = wd_bytes[k];
            // Write mask (u32)
            const mask_bytes: [4]u8 = @bitCast(inotify_events[i].mask);
            for (0..4) |k| buf[written + 4 + k] = mask_bytes[k];
            // Write cookie (u32) = 0
            for (0..4) |k| buf[written + 8 + k] = 0;
            // Write len (u32)
            const len_bytes: [4]u8 = @bitCast(aligned_len);
            for (0..4) |k| buf[written + 12 + k] = len_bytes[k];
            // Write name + null padding
            for (0..aligned_len) |k| {
                buf[written + 16 + k] = if (k < name_len) inotify_events[i].name[k] else 0;
            }

            written += event_size;
            inotify_events[i].in_use = false; // Consume event
        }
    }
    return @intCast(written);
}

// Static inotify inode — shared by all inotify fds.
const inotify_ops = vfs.FileOperations{
    .read = inotifyReadOp,
};

fn inotifyReadOp(desc: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    // desc.offset stores the inotify fd number
    return inotifyRead(@truncate(@as(i64, @bitCast(desc.offset))), buf, count);
}

var inotify_inode: vfs.Inode = .{
    .ino = 0xFFFFF, // Special inode number for inotify
    .mode = 0,
    .size = 0,
    .nlink = 1,
    .ops = &inotify_ops,
    .fs_data = null,
};

/// inotify_init() — nr 253
fn sysInotifyInit(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Allocate a real fd
    const desc = vfs.allocFileDescription() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };
    desc.inode = &inotify_inode;
    desc.flags = vfs.O_RDONLY;
    desc.ref_count = 1;
    desc.in_use = true;

    // Use offset to store inotify fd identifier
    const ifd = next_inotify_fd;
    next_inotify_fd += 1;
    desc.offset = @bitCast(@as(i64, ifd));

    // Find free fd slot in process
    for (0..current.fds.len) |i| {
        if (current.fds[i] == null) {
            current.fds[i] = desc;
            frame.rax = i;
            return;
        }
    }
    vfs.releaseFileDescription(desc);
    frame.rax = @bitCast(@as(i64, -errno.EMFILE));
}

/// inotify_add_watch(ifd, pathname, mask) — nr 254
fn sysInotifyAddWatch(frame: *idt.InterruptFrame) void {
    const fd_num: usize = @truncate(frame.rdi);
    const path_addr = frame.rsi;
    const mask: u32 = @truncate(frame.rdx);

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Get the inotify fd identifier from the FileDescription
    if (fd_num >= current.fds.len) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }
    const desc = current.fds[fd_num] orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const ifd: i32 = @truncate(@as(i64, @bitCast(desc.offset)));

    var path_buf: [256]u8 = undefined;
    const path_len = syscall.copyFromUser(current.page_table, path_addr, &path_buf, 255);
    if (path_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Resolve path to get inode number
    var resolved_buf: [512]u8 = undefined;
    const resolved_len = resolveRelativePath(current, &path_buf, path_len, &resolved_buf);
    const resolve_path = if (resolved_len > 0) resolved_buf[0..resolved_len] else path_buf[0..path_len];
    const inode = vfs.resolve(resolve_path) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    // Find free watch slot
    for (0..MAX_INOTIFY_WATCHES) |i| {
        if (!inotify_watches[i].in_use) {
            inotify_watches[i].in_use = true;
            inotify_watches[i].ifd = ifd;
            inotify_watches[i].wd = next_wd;
            inotify_watches[i].ino = inode.ino;
            inotify_watches[i].mask = mask;
            const wd = next_wd;
            next_wd += 1;
            frame.rax = @bitCast(@as(i64, wd));
            return;
        }
    }
    frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
}

/// inotify_rm_watch(ifd, wd) — nr 255
fn sysInotifyRmWatch(frame: *idt.InterruptFrame) void {
    const fd_num: usize = @truncate(frame.rdi);
    const wd: i32 = @truncate(@as(i64, @bitCast(frame.rsi)));

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (fd_num >= current.fds.len) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }
    const desc = current.fds[fd_num] orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const ifd: i32 = @truncate(@as(i64, @bitCast(desc.offset)));

    for (0..MAX_INOTIFY_WATCHES) |i| {
        if (inotify_watches[i].in_use and inotify_watches[i].ifd == ifd and inotify_watches[i].wd == wd) {
            inotify_watches[i].in_use = false;
            frame.rax = 0;
            return;
        }
    }
    frame.rax = @bitCast(@as(i64, -errno.EINVAL));
}

/// inotify_init1(flags) — nr 294
fn sysInotifyInit1(frame: *idt.InterruptFrame) void {
    // flags are ignored (IN_NONBLOCK, IN_CLOEXEC)
    sysInotifyInit(frame);
}

// ============================================================
// Extended Attributes (xattr)
// ============================================================

const tmpfs_mod = @import("../fs/tmpfs.zig");

fn resolveInodeForXattr(frame: *idt.InterruptFrame) ?*vfs.Inode {
    const current = scheduler.currentProcess() orelse return null;
    const path_addr = frame.rdi;
    var path_buf: [256]u8 = undefined;
    const path_len = syscall.copyFromUser(current.page_table, path_addr, &path_buf, 255);
    if (path_len == 0) return null;

    var resolved_buf: [512]u8 = undefined;
    const resolved_len = resolveRelativePath(current, &path_buf, path_len, &resolved_buf);
    if (resolved_len == 0) return null;

    return vfs.resolve(resolved_buf[0..resolved_len]);
}

/// setxattr(path, name, value, size, flags) — nr 188
fn sysSetxattr(frame: *idt.InterruptFrame) void {
    const inode = resolveInodeForXattr(frame) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    const current = scheduler.currentProcess().?;
    const name_addr = frame.rsi;
    const value_addr = frame.rdx;
    const size: usize = @truncate(frame.r10);

    var name_buf: [64]u8 = undefined;
    const name_len = syscall.copyFromUser(current.page_table, name_addr, &name_buf, 63);
    if (name_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const node = tmpfs_mod.nodeFromInode(inode) orelse {
        // Non-tmpfs inode — not supported
        frame.rax = @bitCast(@as(i64, -95)); // EOPNOTSUPP
        return;
    };

    // Check if xattr already exists (update it)
    for (0..tmpfs_mod.MAX_XATTRS) |i| {
        if (node.xattrs[i].in_use and xattrNameEq(node.xattrs[i].name[0..node.xattrs[i].name_len], name_buf[0..name_len])) {
            // Update existing
            const vlen: u16 = if (size > tmpfs_mod.MAX_XATTR_VAL) @truncate(tmpfs_mod.MAX_XATTR_VAL) else @truncate(size);
            if (size > 0 and value_addr != 0) {
                _ = syscall.copyFromUser(current.page_table, value_addr, &node.xattrs[i].value, vlen);
            }
            node.xattrs[i].value_len = vlen;
            frame.rax = 0;
            return;
        }
    }

    // Find free slot
    for (0..tmpfs_mod.MAX_XATTRS) |i| {
        if (!node.xattrs[i].in_use) {
            node.xattrs[i].in_use = true;
            for (0..name_len) |j| node.xattrs[i].name[j] = name_buf[j];
            node.xattrs[i].name_len = @truncate(name_len);
            const vlen: u16 = if (size > tmpfs_mod.MAX_XATTR_VAL) @truncate(tmpfs_mod.MAX_XATTR_VAL) else @truncate(size);
            if (size > 0 and value_addr != 0) {
                _ = syscall.copyFromUser(current.page_table, value_addr, &node.xattrs[i].value, vlen);
            }
            node.xattrs[i].value_len = vlen;
            frame.rax = 0;
            return;
        }
    }
    frame.rax = @bitCast(@as(i64, -errno.ENOMEM)); // No space for xattr
}

/// lsetxattr — nr 189 (same as setxattr, no symlink follow)
fn sysLsetxattr(frame: *idt.InterruptFrame) void {
    sysSetxattr(frame);
}

/// getxattr(path, name, value, size) — nr 190
fn sysGetxattr(frame: *idt.InterruptFrame) void {
    const inode = resolveInodeForXattr(frame) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    const current = scheduler.currentProcess().?;
    const name_addr = frame.rsi;
    const value_addr = frame.rdx;
    const buf_size: usize = @truncate(frame.r10);

    var name_buf: [64]u8 = undefined;
    const name_len = syscall.copyFromUser(current.page_table, name_addr, &name_buf, 63);
    if (name_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const node = tmpfs_mod.nodeFromInode(inode) orelse {
        frame.rax = @bitCast(@as(i64, -61)); // ENODATA
        return;
    };

    for (0..tmpfs_mod.MAX_XATTRS) |i| {
        if (node.xattrs[i].in_use and xattrNameEq(node.xattrs[i].name[0..node.xattrs[i].name_len], name_buf[0..name_len])) {
            const vlen = node.xattrs[i].value_len;
            if (buf_size == 0) {
                // Size query
                frame.rax = vlen;
                return;
            }
            if (vlen > buf_size) {
                frame.rax = @bitCast(@as(i64, -errno.E2BIG));
                return;
            }
            // Copy value to user buffer
            if (value_addr != 0 and vlen > 0) {
                const phys = vmm.translate(current.page_table, value_addr) orelse {
                    frame.rax = @bitCast(@as(i64, -errno.EFAULT));
                    return;
                };
                const base: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys & ~@as(u64, 0xFFF)));
                const off: usize = @truncate(value_addr & 0xFFF);
                const copy_len = @min(vlen, @as(u16, @truncate(types.PAGE_SIZE - off)));
                for (0..copy_len) |k| base[off + k] = node.xattrs[i].value[k];
            }
            frame.rax = vlen;
            return;
        }
    }
    frame.rax = @bitCast(@as(i64, -61)); // ENODATA
}

/// lgetxattr — nr 191
fn sysLgetxattr(frame: *idt.InterruptFrame) void {
    sysGetxattr(frame);
}

/// listxattr(path, list, size) — nr 194
fn sysListxattr(frame: *idt.InterruptFrame) void {
    const inode = resolveInodeForXattr(frame) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    const current = scheduler.currentProcess().?;
    const list_addr = frame.rsi;
    const buf_size: usize = @truncate(frame.rdx);

    const node = tmpfs_mod.nodeFromInode(inode) orelse {
        frame.rax = 0; // No xattrs on non-tmpfs
        return;
    };

    // Calculate total size needed: each name + null terminator
    var total: usize = 0;
    for (0..tmpfs_mod.MAX_XATTRS) |i| {
        if (node.xattrs[i].in_use) {
            total += node.xattrs[i].name_len + 1; // +1 for null separator
        }
    }

    if (buf_size == 0) {
        frame.rax = total; // Size query
        return;
    }

    if (total > buf_size) {
        frame.rax = @bitCast(@as(i64, -errno.E2BIG));
        return;
    }

    // Copy names to user buffer (null-separated)
    if (list_addr != 0 and total > 0) {
        const phys = vmm.translate(current.page_table, list_addr) orelse {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
            return;
        };
        const base: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys & ~@as(u64, 0xFFF)));
        const off: usize = @truncate(list_addr & 0xFFF);
        var pos: usize = 0;
        for (0..tmpfs_mod.MAX_XATTRS) |i| {
            if (node.xattrs[i].in_use) {
                for (0..node.xattrs[i].name_len) |k| {
                    if (off + pos + k < types.PAGE_SIZE) base[off + pos + k] = node.xattrs[i].name[k];
                }
                pos += node.xattrs[i].name_len;
                if (off + pos < types.PAGE_SIZE) base[off + pos] = 0; // null separator
                pos += 1;
            }
        }
    }
    frame.rax = total;
}

/// removexattr(path, name) — nr 197
fn sysRemovexattr(frame: *idt.InterruptFrame) void {
    const inode = resolveInodeForXattr(frame) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    const current = scheduler.currentProcess().?;
    const name_addr = frame.rsi;

    var name_buf: [64]u8 = undefined;
    const name_len = syscall.copyFromUser(current.page_table, name_addr, &name_buf, 63);
    if (name_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const node = tmpfs_mod.nodeFromInode(inode) orelse {
        frame.rax = @bitCast(@as(i64, -61)); // ENODATA
        return;
    };

    for (0..tmpfs_mod.MAX_XATTRS) |i| {
        if (node.xattrs[i].in_use and xattrNameEq(node.xattrs[i].name[0..node.xattrs[i].name_len], name_buf[0..name_len])) {
            node.xattrs[i].in_use = false;
            frame.rax = 0;
            return;
        }
    }
    frame.rax = @bitCast(@as(i64, -61)); // ENODATA
}

fn xattrNameEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

