/// ARM64 Syscall Handler
/// Processes SVC #0 exceptions from user space.
///
/// Linux AArch64 syscall ABI:
/// - X8 = syscall number
/// - X0-X5 = arguments
/// - X0 = return value
///
/// Note: AArch64 syscall numbers differ from x86_64!

const uart = @import("uart.zig");
const exception = @import("exception.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const vfs = @import("vfs.zig");
const fd_table = @import("fd_table.zig");
const vma = @import("vma.zig");
const pipe = @import("pipe.zig");
const futex = @import("futex.zig");
const signal = @import("signal.zig");
const socket = @import("socket.zig");
const tcp = @import("tcp.zig");
const udp = @import("udp.zig");
const ipv4 = @import("ipv4.zig");
const ethernet = @import("ethernet.zig");
const net_ring = @import("net_ring.zig");
const nic = @import("nic.zig");
const ext2 = @import("ext2.zig");
const timer = @import("timer.zig");
const epoll = @import("epoll.zig");
const smp = @import("smp.zig");
const gic = @import("gic.zig");
const boot = @import("boot.zig");

/// Disable PAN (allow kernel access to user pages). Call before accessing user memory.
inline fn panDisable() void {
    if (boot.pan_enabled) {
        asm volatile (".inst 0xD500409F"); // MSR PAN, #0
    }
}

/// Re-enable PAN (block kernel access to user pages). Call before returning to user.
inline fn panEnable() void {
    if (boot.pan_enabled) {
        asm volatile (".inst 0xD500419F"); // MSR PAN, #1
    }
}

/// Linux AArch64 syscall numbers
pub const SYS_read: u64 = 63;
pub const SYS_write: u64 = 64;
pub const SYS_openat: u64 = 56;
pub const SYS_close: u64 = 57;
pub const SYS_exit: u64 = 93;
pub const SYS_exit_group: u64 = 94;
pub const SYS_brk: u64 = 214;
pub const SYS_mmap: u64 = 222;
pub const SYS_munmap: u64 = 215;
pub const SYS_clone: u64 = 220;
pub const SYS_wait4: u64 = 260;
pub const SYS_getpid: u64 = 172;
pub const SYS_gettid: u64 = 178;
pub const SYS_sysinfo: u64 = 179;
pub const SYS_uname: u64 = 160;
pub const SYS_execve: u64 = 221;
pub const SYS_fstat: u64 = 80;
pub const SYS_newfstatat: u64 = 79;
pub const SYS_lseek: u64 = 62;
pub const SYS_dup: u64 = 23;
pub const SYS_dup3: u64 = 24;
pub const SYS_getcwd: u64 = 17;
pub const SYS_chdir: u64 = 49;
pub const SYS_mkdirat: u64 = 34;
pub const SYS_unlinkat: u64 = 35;
pub const SYS_getdents64: u64 = 61;
pub const SYS_getppid: u64 = 173;
pub const SYS_pipe2: u64 = 59;
pub const SYS_ioctl: u64 = 29;
pub const SYS_fcntl: u64 = 25;
pub const SYS_set_tid_address: u64 = 96;
pub const SYS_set_robust_list: u64 = 99;
pub const SYS_futex: u64 = 98;
pub const SYS_kill: u64 = 129;
pub const SYS_tgkill: u64 = 131;
pub const SYS_rt_sigaction: u64 = 134;
pub const SYS_rt_sigprocmask: u64 = 135;
pub const SYS_rt_sigreturn: u64 = 139;
pub const SYS_socket: u64 = 198;
pub const SYS_bind: u64 = 200;
pub const SYS_listen: u64 = 201;
pub const SYS_accept: u64 = 202;
pub const SYS_connect: u64 = 203;
pub const SYS_sendto: u64 = 206;
pub const SYS_recvfrom: u64 = 207;
pub const SYS_setsockopt: u64 = 208;
pub const SYS_getsockopt: u64 = 209;
pub const SYS_shutdown: u64 = 210;
pub const SYS_setuid: u64 = 146;
pub const SYS_setgid: u64 = 144;
pub const SYS_setpgid: u64 = 154;
pub const SYS_getpgid: u64 = 155;
pub const SYS_getuid: u64 = 174;
pub const SYS_geteuid: u64 = 175;
pub const SYS_getgid: u64 = 176;
pub const SYS_getegid: u64 = 177;
pub const SYS_ftruncate: u64 = 46;
pub const SYS_readlinkat: u64 = 78;
pub const SYS_sync: u64 = 81;
pub const SYS_fsync: u64 = 82;
pub const SYS_fdatasync: u64 = 83;
pub const SYS_clock_gettime: u64 = 113;
pub const SYS_tkill: u64 = 130;
pub const SYS_sigaltstack: u64 = 132;
pub const SYS_mprotect: u64 = 226;
pub const SYS_readv: u64 = 65;
pub const SYS_writev: u64 = 66;
pub const SYS_pread64: u64 = 67;
pub const SYS_pwrite64: u64 = 68;
pub const SYS_faccessat: u64 = 48;
pub const SYS_sched_yield: u64 = 124;
pub const SYS_madvise: u64 = 233;
pub const SYS_nanosleep: u64 = 101;
pub const SYS_renameat: u64 = 38;
pub const SYS_renameat2: u64 = 276;
pub const SYS_sched_setaffinity: u64 = 122;
pub const SYS_sched_getaffinity: u64 = 123;
pub const SYS_prlimit64: u64 = 261;
pub const SYS_getrandom: u64 = 278;
pub const SYS_mremap: u64 = 216;
pub const SYS_rseq: u64 = 293;
pub const SYS_ppoll: u64 = 73;
pub const SYS_lstat: u64 = 1039;
pub const SYS_fchmod: u64 = 52;
pub const SYS_fchown: u64 = 55;
pub const SYS_umask: u64 = 166;
pub const SYS_getrusage: u64 = 165;
pub const SYS_statfs: u64 = 43;
pub const SYS_fstatfs: u64 = 44;
pub const SYS_prctl: u64 = 167;
pub const SYS_clock_nanosleep: u64 = 115;
pub const SYS_fchownat: u64 = 54;
pub const SYS_fchmodat: u64 = 53;
pub const SYS_fallocate: u64 = 47;
pub const SYS_flock: u64 = 32;
pub const SYS_mknodat: u64 = 33;
pub const SYS_symlinkat: u64 = 36;
pub const SYS_linkat: u64 = 37;
pub const SYS_preadv: u64 = 69;
pub const SYS_pwritev: u64 = 70;
pub const SYS_statx: u64 = 291;
pub const SYS_utimensat: u64 = 88;
pub const SYS_copy_file_range: u64 = 285;
pub const SYS_epoll_create1: u64 = 20;
pub const SYS_epoll_ctl: u64 = 21;
pub const SYS_epoll_pwait: u64 = 22;

pub const SYS_splice: u64 = 76;
pub const SYS_tee: u64 = 77;
pub const SYS_inotify_init1: u64 = 26;
pub const SYS_inotify_add_watch: u64 = 27;
pub const SYS_inotify_rm_watch: u64 = 28;

// xattr syscalls (aarch64 Linux numbers)
pub const SYS_setxattr: u64 = 5;
pub const SYS_lsetxattr: u64 = 6;
pub const SYS_fsetxattr: u64 = 7;
pub const SYS_getxattr: u64 = 8;
pub const SYS_lgetxattr: u64 = 9;
pub const SYS_fgetxattr: u64 = 10;
pub const SYS_listxattr: u64 = 11;
pub const SYS_llistxattr: u64 = 12;
pub const SYS_flistxattr: u64 = 13;
pub const SYS_removexattr: u64 = 14;
pub const SYS_lremovexattr: u64 = 15;
pub const SYS_fremovexattr: u64 = 16;

pub const SYS_fadvise64: u64 = 223;
pub const SYS_sendfile: u64 = 71;
pub const SYS_getsockname: u64 = 204;
pub const SYS_getpeername: u64 = 205;

// Zigix-specific syscalls (above Linux range — 500+)
// NR 280 = Linux prlimit64 (already handled), NR 281 = Linux execveat
pub const SYS_net_attach: u64 = 500;
pub const SYS_net_hugepage_alloc: u64 = 501;
pub const SYS_sched_dedicate: u64 = 503;
pub const SYS_sched_release: u64 = 504;

// ============================================================================
// Syscall trace ring buffer — dump on page fault for debugging
// ============================================================================
const TRACE_SIZE = 64;

const TraceEntry = struct {
    pid: u16,
    nr: u16,
    arg0: u64,
    arg1: u64,
    result: i64,
};

var trace_ring: [TRACE_SIZE]TraceEntry = [_]TraceEntry{.{ .pid = 0, .nr = 0, .arg0 = 0, .arg1 = 0, .result = 0 }} ** TRACE_SIZE;
var trace_idx: usize = 0;

fn traceRecord(pid: u64, nr: u64, arg0: u64, arg1: u64, result: i64) void {
    const i = trace_idx % TRACE_SIZE;
    trace_ring[i] = .{
        .pid = @truncate(pid),
        .nr = @truncate(nr),
        .arg0 = arg0,
        .arg1 = arg1,
        .result = result,
    };
    trace_idx += 1;
}

/// Dump last N syscalls — called from fault handler
/// Dump syscall trace using ONLY raw UART writes — no Zig fmt to avoid
/// double-panic during crash diagnostics.
pub fn dumpTrace(n: usize) void {
    const count = if (trace_idx < n) trace_idx else n;
    if (count == 0) return;
    uart.writeString("[sc-trace] Last ");
    uart.writeDec(count);
    uart.writeString(" syscalls:\n");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx = (trace_idx -% count +% i) % TRACE_SIZE;
        const e = trace_ring[idx];
        uart.writeString("  P");
        uart.writeDec(e.pid);
        uart.writeString(" nr=");
        uart.writeDec(e.nr);
        uart.writeString(" x0=");
        uart.writeHex(e.arg0);
        uart.writeString(" x1=");
        uart.writeHex(e.arg1);
        uart.writeString(" -> ");
        // result is i64 (signed), print as hex to avoid signed fmt issues
        uart.writeHex(@bitCast(e.result));
        uart.writeByte('\n');
    }
}

/// Handle a syscall from user space
pub fn handle(frame: *exception.TrapFrame) void {
    // Disable PAN — syscall handlers access user memory via @ptrFromInt(user_va).
    // PAN is auto-re-enabled on next EL0→EL1 exception entry (SPAN=0 in SCTLR_EL1).
    panDisable();

    const syscall_num = frame.x[8];

    // execve/execveat modify frame directly and don't return a value
    if (syscall_num == SYS_execve) {
        sysExecve(frame);
        panEnable();
        return;
    }
    if (syscall_num == 281) { // execveat
        sysExecveat(frame);
        panEnable();
        return;
    }

    // rt_sigreturn restores the entire frame from the signal frame on the user stack.
    // Must not go through the normal return path which overwrites X0.
    if (syscall_num == SYS_rt_sigreturn) {
        signal.sysRtSigreturn(frame);
        signal.checkAndDeliver(frame);
        panEnable();
        return;
    }

    // Save process index and ELR so we can detect context switches.
    // Blocking syscalls call blockAndSchedule which either:
    //  (a) switches to a different process (index changes), or
    //  (b) self-wakes the same process after idling (ELR changes because
    //      the context was saved with a rewound ELR for SVC replay).
    // In both cases, the frame was restored from saved context and we
    // must not overwrite X0 with the syscall result.
    const idx_before = scheduler.currentProcessIndex();
    const elr_before = frame.elr;
    const saved_x0 = frame.x[0]; // Save before result overwrites it

    const result: i64 = switch (syscall_num) {
        SYS_read => sysRead(frame),
        SYS_write => sysWrite(frame),
        SYS_openat => sysOpenat(frame),
        SYS_close => sysClose(frame),
        SYS_exit => sysExit(frame),
        SYS_exit_group => sysExitGroup(frame),
        SYS_brk => sysBrk(frame),
        SYS_mmap => sysMmap(frame),
        SYS_munmap => sysMunmap(frame),
        SYS_mremap => sysMremap(frame),
        SYS_clone => sysClone(frame),
        SYS_wait4 => sysWait4(frame),
        SYS_getpid => sysGetpid(),
        SYS_getppid => sysGetppid(),
        SYS_gettid => sysGettid(),
        SYS_sysinfo => sysSysinfo(frame),
        158 => sysGetgroups(frame),
        103 => 0, // setitimer — stub
        SYS_uname => sysUname(frame),
        SYS_lseek => sysLseek(frame),
        SYS_dup => sysDup(frame),
        SYS_dup3 => sysDup3(frame),
        SYS_getcwd => sysGetcwd(frame),
        SYS_chdir => sysChdir(frame),
        SYS_mkdirat => sysMkdirat(frame),
        SYS_unlinkat => sysUnlinkat(frame),
        SYS_fstat, SYS_newfstatat => sysStat(frame),
        SYS_getdents64 => sysGetdents64(frame),
        SYS_pipe2 => sysPipe2(frame),
        SYS_futex => sysFutex(frame),
        SYS_kill => sysKill(frame),
        SYS_tgkill => sysKill(frame), // simplified: same as kill
        SYS_rt_sigaction => sysRtSigaction(frame),
        SYS_rt_sigprocmask => sysRtSigprocmask(frame),
        // SYS_rt_sigreturn handled above (before switch) — never reached here
        SYS_socket => sysSocket(frame),
        SYS_connect => sysConnect(frame),
        SYS_listen => sysListen(frame),
        SYS_accept => sysAccept(frame),
        SYS_sendto => sysSendto(frame),
        SYS_recvfrom => sysRecvfrom(frame),
        SYS_bind => sysBind(frame),
        SYS_shutdown => sysShutdown(frame),
        SYS_net_attach => sysNetAttach(frame),
        SYS_net_hugepage_alloc => sysNetHugepageAlloc(frame),
        SYS_setsockopt => sysSetsockopt(frame),
        SYS_getsockopt => sysGetsockopt(frame),
        SYS_ioctl => sysIoctl(frame),
        SYS_fcntl => sysFcntl(frame),
        SYS_pread64 => sysPread64(frame),
        SYS_pwrite64 => sysPwrite64(frame),
        SYS_faccessat => sysFaccessat(frame),
        SYS_sched_yield => sysSchedYield(),
        SYS_madvise => 0, // advisory — no-op, return success
        SYS_nanosleep => sysNanosleep(frame),
        SYS_renameat => sysRenameat(frame),
        SYS_renameat2 => sysRenameat2(frame),
        SYS_sched_setaffinity => 0, // stub — single-user OS, no affinity needed
        SYS_sched_getaffinity => sysSchedGetaffinity(frame),
        SYS_fallocate => sysFallocate(frame),
        SYS_flock => sysFlock(frame),
        SYS_mknodat => sysMknodat(frame),
        SYS_symlinkat => sysSymlinkat(frame),
        SYS_linkat => sysLinkat(frame),
        SYS_preadv => sysPreadv(frame),
        SYS_pwritev => sysPwritev(frame),
        SYS_statx => sysStatx(frame),
        SYS_prlimit64 => sysPrlimit64(frame),
        SYS_getrandom => sysGetrandom(frame),
        SYS_rseq => -38, // -ENOSYS (restartable sequences not supported)
        SYS_setuid => sysSetuid(frame),
        SYS_setgid => sysSetgid(frame),
        SYS_setpgid => sysSetpgid(frame),
        SYS_getpgid => sysGetpgid(frame),
        SYS_getuid => sysGetuid(),
        SYS_geteuid => sysGetEuid(),
        SYS_getgid => sysGetgid(),
        SYS_getegid => sysGetEgid(),
        SYS_ftruncate => sysFtruncate(frame),
        SYS_readlinkat => sysReadlinkat(frame),
        SYS_sync => sysSync(),
        SYS_fsync => sysFsync(frame),
        SYS_fdatasync => sysFdatasync(frame),
        SYS_clock_gettime => sysClockGettime(frame),
        SYS_tkill => sysTkill(frame),
        SYS_sigaltstack => 0, // stub — return success
        SYS_mprotect => sysMprotect(frame),
        SYS_readv => sysReadv(frame),
        SYS_writev => sysWritev(frame),
        SYS_set_tid_address => sysSetTidAddress(frame),
        SYS_set_robust_list => 0, // stub — return success
        SYS_ppoll => sysPpoll(frame),
        SYS_lstat => sysStat(frame), // lstat fallback — route to existing stat handler
        SYS_fchmod => sysFchmod(frame),
        SYS_fchown => sysFchown(frame),
        SYS_umask => sysUmask(frame),
        SYS_getrusage => sysGetrusage(frame),
        SYS_statfs => sysStatfs(frame),
        SYS_fstatfs => sysStatfs(frame), // shares implementation with statfs
        SYS_prctl => 0, // stub — return success
        SYS_clock_nanosleep => sysClockNanosleep(frame),
        SYS_fchownat => sysFchownat(frame),
        SYS_fchmodat => sysFchmodat(frame),
        SYS_utimensat => sysUtimensat(frame),
        SYS_copy_file_range => sysCopyFileRange(frame),
        SYS_epoll_create1 => epoll.sysEpollCreate1(frame),
        SYS_epoll_ctl => epoll.sysEpollCtl(frame),
        SYS_epoll_pwait => epoll.sysEpollWait(frame),
        SYS_sched_dedicate => sysSchedDedicate(frame),
        SYS_sched_release => sysSchedRelease(frame),
        SYS_fadvise64 => 0, // Advisory — always succeed (no-op)
        SYS_sendfile => sysSendfile(frame),
        SYS_splice => sysSplice(frame),
        SYS_tee => sysTee(frame),
        SYS_inotify_init1 => sysInotifyInit1(frame),
        SYS_inotify_add_watch => sysInotifyAddWatch(frame),
        SYS_inotify_rm_watch => sysInotifyRmWatch(frame),
        95 => sysWaitid(frame), // waitid
        // 281 (execveat) handled above with execve (early return path)
        SYS_getsockname => -38, // TODO
        SYS_getpeername => -38, // TODO
        // xattr syscalls
        SYS_getxattr, SYS_lgetxattr => sysGetxattr(frame, false),
        SYS_fgetxattr => sysFgetxattr(frame),
        SYS_listxattr, SYS_llistxattr => sysListxattr(frame, false),
        SYS_flistxattr => sysFlistxattr(frame),
        SYS_setxattr, SYS_lsetxattr => sysSetxattr(frame, false),
        SYS_fsetxattr => sysFsetxattr(frame),
        SYS_removexattr, SYS_lremovexattr => sysRemovexattr(frame, false),
        SYS_fremovexattr => sysfremovexattr(frame),
        else => blk: {
            uart.print("[syscall] Unknown syscall {} from PID {}\n", .{
                syscall_num,
                if (scheduler.currentProcess()) |p| p.pid else 0,
            });
            break :blk -38; // -ENOSYS
        },
    };

    // Only set return value if no context switch or ELR rewind happened.
    if (scheduler.currentProcessIndex() == idx_before and frame.elr == elr_before) {
        frame.x[0] = @bitCast(result);
    }

    // Record in trace ring buffer for post-crash analysis (with original x0)
    if (scheduler.currentProcess()) |tp| {
        if (tp.pid >= 3) {
            traceRecord(tp.pid, syscall_num, saved_x0, frame.x[1], result);
        }
    }

    // Check for pending signals before returning to userspace
    signal.checkAndDeliver(frame);

    // Re-enable PAN before returning to exception vector (and eventually ERET)
    panEnable();
}

/// Ensure all pages in [addr, addr+len) are mapped as user-accessible,
/// demand-paging as needed. On ARM64, kernel identity-mapping PTEs may
/// exist in L0[0] (the same 512GB range as user code). These are valid
/// entries that vmm.translate() finds, but they point to kernel memory,
/// not user data. We must check the PTE user flag to distinguish.
fn ensureUserPages(page_table: u64, addr: u64, len: usize) bool {
    if (len == 0) return true;
    var page = addr & ~@as(u64, 0xFFF);
    const end = addr + @as(u64, len);
    while (page < end) : (page += 4096) {
        const pte = vmm.getPTE(vmm.PhysAddr.from(page_table), vmm.VirtAddr.from(page));
        if (pte == null or !pte.?.isUser()) {
            if (!exception.demandPageUser(page)) return false;
        }
    }
    return true;
}

/// read(fd, buf, count) -> bytes_read
fn sysRead(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const buf_addr = frame.x[1];
    const count = frame.x[2];

    const proc = scheduler.currentProcess() orelse return -9;

    // Look up file description
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9; // -EBADF

    const read_fn = desc.inode.ops.read orelse return -9; // -EBADF

    const len: usize = if (count > 1048576) 1048576 else @truncate(count);

    // Ensure all pages in the user buffer are mapped (demand-page as needed)
    if (!ensureUserPages(proc.page_table, buf_addr, len)) return -14; // -EFAULT

    const buf: [*]u8 = @ptrFromInt(buf_addr);

    const result = read_fn(desc, buf, len);

    // EAGAIN — block and replay for blocking reads.
    if (result == -11) {
        // UART stdin: always block (single reader, IRQ wakes it)
        if (fd_num == 0) {
            uart.waiting_pid = proc.pid;
            proc.state = .blocked;
            frame.elr -= 4;
            scheduler.blockAndSchedule(frame);
            return 0;
        }
        // Blocking pipe: pipeRead already set proc.state = .blocked under
        // pipe_lock (SMP-safe). Just deschedule and replay on wake.
        if (pipe.isPipeInode(desc.inode) and proc.state == .blocked) {
            frame.elr -= 4;
            scheduler.blockAndSchedule(frame);
            return 0;
        }
        // Socket EAGAIN: set waiting_pid (TCP) and block for data arrival.
        // UDP/ICMP: socketRead already set sock.blocked_pid under socket_lock.
        if (socket.getSocketIndexFromInode(desc.inode)) |sock_idx| {
            if (socket.getSocket(sock_idx)) |sock| {
                if (sock.sock_type == socket.SOCK_STREAM) {
                    if (tcp.getConnection(sock.tcp_conn_idx)) |conn| {
                        conn.waiting_pid = proc.pid;
                    }
                }
                proc.state = .blocked_on_net;
                frame.elr -= 4;
                scheduler.blockAndSchedule(frame);
                return 0;
            }
        }
    }

    return result;
}

/// write(fd, buf, count) -> bytes_written
fn sysWrite(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const buf_addr = frame.x[1];
    const count = frame.x[2];

    const proc = scheduler.currentProcess() orelse return -9;

    // Look up file description
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9; // -EBADF

    const write_fn = desc.inode.ops.write orelse return -9; // -EBADF

    const len: usize = if (count > 1048576) 1048576 else @truncate(count);

    // Ensure all pages in the user buffer are mapped (demand-page as needed)
    if (!ensureUserPages(proc.page_table, buf_addr, len)) return -14; // -EFAULT

    const buf: [*]const u8 = @ptrFromInt(buf_addr);

    const result = write_fn(desc, buf, len);

    // EAGAIN — pipe buffer full. pipeWrite set .blocked under lock for
    // blocking pipes. Just deschedule and replay on wake.
    if (result == -11 and pipe.isPipeInode(desc.inode) and proc.state == .blocked) {
        frame.elr -= 4;
        scheduler.blockAndSchedule(frame);
        return 0;
    }

    // inotify: notify on successful write to regular files
    if (result > 0 and desc.inode.mode & vfs.S_IFMT == vfs.S_IFREG) {
        inotifyNotify(@truncate(desc.inode.ino), IN_MODIFY, null);
    }

    return result;
}

// --- /dev/null and /dev/zero pseudo-devices ---

fn devnullRead(_: *vfs.FileDescription, _: [*]u8, _: usize) isize {
    return 0; // EOF
}

fn devnullWrite(_: *vfs.FileDescription, _: [*]const u8, count: usize) isize {
    return @intCast(count); // Discard all data
}

fn devzeroRead(_: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    for (0..count) |i| buf[i] = 0;
    return @intCast(count);
}

const devnull_ops = vfs.FileOperations{
    .read = devnullRead,
    .write = devnullWrite,
};

const devzero_ops = vfs.FileOperations{
    .read = devzeroRead,
    .write = devnullWrite, // /dev/zero also discards writes
};

var devnull_inode = vfs.Inode{
    .ino = 0x10001,
    .mode = vfs.S_IFCHR | 0o666,
    .size = 0,
    .nlink = 1,
    .ops = &devnull_ops,
    .fs_data = null,
};

var devzero_inode = vfs.Inode{
    .ino = 0x10002,
    .mode = vfs.S_IFCHR | 0o666,
    .size = 0,
    .nlink = 1,
    .ops = &devzero_ops,
    .fs_data = null,
};

fn openDeviceFile(proc: *process.Process, inode: *vfs.Inode, flags: u32) i64 {
    const desc = vfs.allocFileDescription() orelse return -23; // -ENFILE
    desc.inode = inode;
    desc.flags = flags;

    const fd = fd_table.fdAlloc(&proc.fds, desc) orelse {
        vfs.releaseFileDescription(desc);
        return -24; // -EMFILE
    };
    proc.fd_cloexec[fd] = (flags & vfs.O_CLOEXEC != 0);

    return @intCast(fd);
}

// FIFO (named pipe) → pipe mapping table
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
        const desc = pipe.openExistingPipe(pidx, access_mode) orelse return -24;
        const fd = fd_table.fdAlloc(&proc.fds, desc) orelse {
            vfs.releaseFileDescription(desc);
            return -24;
        };
        proc.fd_cloexec[fd] = (flags & vfs.O_CLOEXEC != 0);
        return @intCast(fd);
    }

    // Create new pipe for this FIFO
    const result = pipe.createPipe() orelse return -24;

    // Register in FIFO map
    for (&fifo_map) |*entry| {
        if (!entry.active) {
            entry.active = true;
            entry.ino = inode.ino;
            entry.pipe_idx = pipe.getPipeIdx(result.read_desc.inode) orelse 0;
            break;
        }
    }

    // For FIFOs, return the requested end but keep the pipe alive.
    // Don't release the other end — just drop the FileDescription without closing the pipe.
    // The pipe stays alive via the FIFO map entry.
    const desc_to_use = if (access_mode == vfs.O_WRONLY) result.write_desc else result.read_desc;
    const fd = fd_table.fdAlloc(&proc.fds, desc_to_use) orelse {
        vfs.releaseFileDescription(desc_to_use);
        return -24;
    };
    proc.fd_cloexec[fd] = (flags & vfs.O_CLOEXEC != 0);
    // Release the unused FileDescription but DON'T call pipeClose on it
    // (just free the vfs.FileDescription struct without side effects)
    const unused = if (access_mode == vfs.O_WRONLY) result.read_desc else result.write_desc;
    vfs.releaseFileDescriptionNoClose(unused);
    return @intCast(fd);
}

/// openat(dirfd, pathname, flags, mode) -> fd
const AT_FDCWD: u64 = @bitCast(@as(i64, -100));

/// Resolve a path using a dirfd, matching Linux semantics:
/// - Absolute paths ignore the dirfd
/// - AT_FDCWD resolves relative to CWD
/// - Other dirfds resolve relative to the directory they point to
fn resolveWithDirfd(proc: *process.Process, dirfd: u64, path: []const u8) vfs.ResolveResult {
    if (path.len > 0 and path[0] == '/') {
        return vfs.resolvePath(path);
    } else if (dirfd != AT_FDCWD) {
        if (fd_table.fdGet(&proc.fds, @truncate(dirfd))) |desc| {
            return vfs.resolvePathFrom(desc.inode, path);
        }
        return vfs.ResolveResult{ .inode = null, .parent = null, .leaf_name = [_]u8{0} ** 256, .leaf_len = 0 };
    } else {
        var abs_buf: [512]u8 = undefined;
        const cwd = proc.cwd[0..proc.cwd_len];
        var abs_len: usize = cwd.len;
        for (0..cwd.len) |i| abs_buf[i] = cwd[i];
        if (abs_len > 0 and abs_buf[abs_len - 1] != '/') {
            abs_buf[abs_len] = '/';
            abs_len += 1;
        }
        const copy_len = @min(path.len, abs_buf.len - abs_len);
        for (0..copy_len) |i| abs_buf[abs_len + i] = path[i];
        abs_len += copy_len;
        return vfs.resolvePath(abs_buf[0..abs_len]);
    }
}

/// Check file permissions against process identity.
/// wanted: bitmask — 4=read, 2=write, 1=execute
fn checkPermission(inode: *vfs.Inode, wanted: u32, proc: *process.Process) bool {
    if (proc.euid == 0) return true; // root bypasses all
    const mode = inode.mode & 0o7777;
    const bits: u32 = if (proc.euid == inode.uid)
        (mode >> 6) & 7
    else if (proc.egid == inode.gid)
        (mode >> 3) & 7
    else
        mode & 7;
    return (bits & wanted) == wanted;
}

fn sysOpenat(frame: *exception.TrapFrame) i64 {
    const dirfd = frame.x[0];
    const path_addr = frame.x[1];
    const flags: u32 = @truncate(frame.x[2]);
    const mode: u32 = @truncate(frame.x[3]);

    const proc = scheduler.currentProcess() orelse return -9;

    // Ensure first page of path is mapped (demand-page if needed)
    if (!ensureUserPages(proc.page_table, path_addr, 1)) return -14; // -EFAULT

    // Read path from user space (identity mapped), demand-paging across page boundaries
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {
        // If the next byte crosses a page boundary, ensure that page is mapped
        const next_addr = path_addr + path_len + 1;
        if (next_addr & 0xFFF == 0 and path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }

    if (path_len == 0) return -2; // -ENOENT

    const path = path_ptr[0..path_len];

    // Intercept pseudo-device paths before VFS resolution
    if (path_len == 9 and streql(path, "/dev/null")) {
        return openDeviceFile(proc, &devnull_inode, flags);
    }
    if (path_len == 9 and streql(path, "/dev/zero")) {
        return openDeviceFile(proc, &devzero_inode, flags);
    }

    // Resolve path — handle dirfd for relative paths
    const result = blk: {
        if (path[0] == '/') {
            break :blk vfs.resolvePath(path);
        } else if (dirfd != AT_FDCWD) {
            // Relative to dirfd — look up inode from fd table
            if (fd_table.fdGet(&proc.fds, @truncate(dirfd))) |desc| {
                break :blk vfs.resolvePathFrom(desc.inode, path);
            }
            return -9; // -EBADF: invalid dirfd
        } else {
            // AT_FDCWD — relative to CWD (build absolute path)
            var abs_buf: [512]u8 = undefined;
            const cwd = proc.cwd[0..proc.cwd_len];
            var abs_len: usize = cwd.len;
            for (0..cwd.len) |i| abs_buf[i] = cwd[i];
            if (abs_len > 0 and abs_buf[abs_len - 1] != '/') {
                abs_buf[abs_len] = '/';
                abs_len += 1;
            }
            const copy_len = @min(path.len, abs_buf.len - abs_len);
            for (0..copy_len) |i| abs_buf[abs_len + i] = path[i];
            abs_len += copy_len;
            break :blk vfs.resolvePath(abs_buf[0..abs_len]);
        }
    };

    if (result.inode) |raw_inode| {
        // Follow symlinks unless O_NOFOLLOW is set
        const inode = if (raw_inode.mode & vfs.S_IFMT == vfs.S_IFLNK and flags & vfs.O_NOFOLLOW == 0)
            vfs.resolve(path) orelse return -2 // -ENOENT (dangling symlink)
        else
            raw_inode;

        // Permission check on existing file
        const access_mode = flags & vfs.O_ACCMODE;
        const wanted: u32 = switch (access_mode) {
            vfs.O_RDONLY => 4,
            vfs.O_WRONLY => 2,
            vfs.O_RDWR => 6,
            else => 4,
        };
        if (!checkPermission(inode, wanted, proc)) {
            return -13; // -EACCES
        }

        // O_DIRECTORY check — must be a directory
        if (flags & vfs.O_DIRECTORY != 0 and inode.mode & vfs.S_IFMT != vfs.S_IFDIR) {
            return -20; // -ENOTDIR
        }

        // FIFO (named pipe) — redirect to pipe subsystem
        if (inode.mode & vfs.S_IFMT == vfs.S_IFIFO) {
            return openFifo(proc, inode, flags);
        }

        // File exists — open it
        if (flags & vfs.O_TRUNC != 0 and inode.mode & vfs.S_IFMT == vfs.S_IFREG) {
            if (inode.ops.truncate) |trunc_fn| {
                _ = trunc_fn(inode);
            }
        }

        const desc = vfs.allocFileDescription() orelse {
            return -23; // -ENFILE
        };
        desc.inode = inode;
        desc.flags = flags;

        const fd = fd_table.fdAlloc(&proc.fds, desc) orelse {
            vfs.releaseFileDescription(desc);
            return -24; // -EMFILE
        };
        proc.fd_cloexec[fd] = (flags & vfs.O_CLOEXEC != 0);

        return @intCast(fd);
    }

    // File doesn't exist — create if O_CREAT
    if (flags & vfs.O_CREAT != 0) {
        const parent = result.parent orelse {
            return -2;
        };
        if (!checkPermission(parent, 3, proc)) return -13; // -EACCES (need W+X on parent)
        const create_fn = parent.ops.create orelse return -1; // -EPERM

        const name = result.leaf_name[0..result.leaf_len];
        const perm_bits = (mode & 0o7777) & ~proc.umask_val;
        const new_mode = if (mode & vfs.S_IFMT == 0) vfs.S_IFREG | perm_bits else (mode & vfs.S_IFMT) | perm_bits;
        const new_inode = create_fn(parent, name, new_mode) orelse return -12; // -ENOMEM

        // inotify: notify parent directory of creation
        inotifyNotify(@truncate(parent.ino), IN_CREATE, name);

        const desc = vfs.allocFileDescription() orelse return -23;
        desc.inode = new_inode;
        desc.flags = flags;

        const fd = fd_table.fdAlloc(&proc.fds, desc) orelse {
            vfs.releaseFileDescription(desc);
            return -24;
        };
        proc.fd_cloexec[fd] = (flags & vfs.O_CLOEXEC != 0);

        return @intCast(fd);
    }

    return -2; // -ENOENT
}

/// close(fd) -> 0
fn sysClose(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const proc = scheduler.currentProcess() orelse return -9;

    if (fd_table.fdClose(&proc.fds, fd_num)) {
        if (fd_num < fd_table.MAX_FDS) {
            proc.fd_cloexec[@truncate(fd_num)] = false;
        }
        return 0;
    }
    return -9; // -EBADF
}

/// Check if any other process shares this page table (CLONE_VM threads).
/// Returns true if any thread is non-zombie OR is zombie but still executing on a CPU.
fn isSharedAddressSpace(proc: *process.Process) bool {
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |other| {
            if (other.pid != proc.pid and other.page_table == proc.page_table) {
                // Any other process sharing this page table — even zombies.
                // Zombies still need the page table intact until they are reaped
                // (wait4 calls destroyAddressSpace). Destroying user pages while
                // a zombie sibling still references the same page table causes
                // double-free when the zombie is later reaped.
                return true;
            }
        }
    }
    return false;
}

fn streql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

/// Close all file descriptors for a process. Decrements ref_counts and calls
/// the file's close function (e.g. pipeClose) when ref_count reaches 0.
/// Essential for pipe semantics: writer exit must decrement pipe.writers.
/// Kill a process and all threads in its thread group.
/// Used from crash handlers (SIGSEGV, abort) to ensure threads don't leak
/// pipe FDs that would block parent processes forever.
pub fn killThreadGroup(proc: *process.Process, exit_status: u64) void {
    const tgid = proc.tgid;
    closeAllFds(proc);
    proc.killed = true;
    proc.state = .zombie;
    proc.exit_status = exit_status;

    // Kill all other threads in the same thread group.
    // Set `killed` flag FIRST — this survives even if a mid-syscall thread
    // overwrites .zombie with a blocked state before the SGI fires.
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.tgid == tgid and p.pid != proc.pid and p.state != .zombie) {
                p.killed = true;
                // DMB to ensure killed is visible before state change
                asm volatile ("dmb ish" ::: .{ .memory = true });
                p.state = .zombie;
                p.exit_status = exit_status;
                // Send IPI if the thread is running on another CPU
                if (p.cpu_id >= 0) {
                    gic.sendSGI(@intCast(@as(u32, @bitCast(p.cpu_id))), gic.SGI_RESCHEDULE);
                }
            }
        }
    }

    // Spin-wait for all killed threads to get off-CPU.
    // Without this, a thread mid-syscall on another CPU could still be executing
    // when we return, potentially accessing shared resources (page tables, FDs).
    // The killed flag + handleIrqException/blockAndSchedule checks ensure
    // threads will exit promptly.
    var spin: u32 = 0;
    while (spin < 10_000_000) : (spin += 1) {
        var all_off = true;
        for (0..process.MAX_PROCESSES) |i| {
            if (process.getProcess(i)) |p| {
                if (p.tgid == tgid and p.pid != proc.pid and p.cpu_id >= 0) {
                    all_off = false;
                    break;
                }
            }
        }
        if (all_off) break;
        asm volatile ("yield");
    }

    // Close FDs for killed threads (now safely off-CPU)
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.tgid == tgid and p.pid != proc.pid) {
                closeAllFds(p);
            }
        }
    }

    // Wake parent
    if (proc.parent_pid != 0) {
        if (process.findByPid(proc.parent_pid)) |parent| {
            signal.postSignal(parent, signal.SIGCHLD);
            if (parent.state == .blocked_on_wait) {
                scheduler.wakeProcess(parent.pid);
            }
        }
    }
}

pub fn closeAllFds(proc: *process.Process) void {
    var fd_count: u32 = 0;
    for (0..fd_table.MAX_FDS) |i| {
        if (proc.fds[i]) |desc| {
            proc.fds[i] = null;
            proc.fd_cloexec[i] = false;
            vfs.releaseFileDescription(desc);
            fd_count += 1;
        }
    }
}

/// exit(status) -> does not return
fn sysExit(frame: *exception.TrapFrame) i64 {
    const status = frame.x[0];
    const proc = scheduler.currentProcess() orelse return -1;

    // Trace only non-zero exit status (errors)
    if (proc.pid >= 3 and status != 0) {
        uart.print("[exit] pid={} status={}\n", .{ proc.pid, status });
    }

    // Close all file descriptors before going zombie.
    // This ensures pipe writer counts are decremented and blocked readers woken.
    closeAllFds(proc);

    // Mark process as zombie
    proc.state = .zombie;
    proc.exit_status = status;

    // Reparent children to init (PID 1) — prevents permanent zombie leaks
    if (proc.tgid == proc.pid) {
        var need_wake_init = false;
        for (0..process.MAX_PROCESSES) |ri| {
            if (process.getProcess(ri)) |child| {
                if (child.parent_pid == proc.pid and child.pid != proc.pid) {
                    child.parent_pid = 1;
                    if (child.state == .zombie) need_wake_init = true;
                }
            }
        }
        if (need_wake_init) {
            if (process.findByPid(1)) |init_proc| {
                if (init_proc.state == .blocked_on_wait) {
                    scheduler.wakeProcess(init_proc.pid);
                }
            }
        }
    }

    // Handle clear_child_tid (pthread_join support)
    if (proc.clear_child_tid != 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(proc.clear_child_tid))) |_| {
            const tid_ptr: *align(1) u32 = @ptrFromInt(proc.clear_child_tid);
            tid_ptr.* = 0;
            _ = futex.wakeAddress(proc.page_table, proc.clear_child_tid, 1);
        }
    }

    // Only destroy user pages if no other thread shares this address space
    if (!isSharedAddressSpace(proc)) {
        // Unpin executable inode before destroying the address space
        if (proc.pinned_exec_inode) |pinned| {
            ext2.unpinInode(pinned);
            proc.pinned_exec_inode = null;
        }
        // Write back MAP_SHARED file-backed pages before destroying the address space.
        const vma_owner = process.getVmaOwner(proc);
        syncAllSharedVmas(proc.page_table, &vma_owner.vmas);
        // Release file refs from all file-backed VMAs before destroying pages.
        vma.releaseAllFileRefs(&vma_owner.vmas);
        vmm.destroyUserPages(vmm.PhysAddr.from(proc.page_table));
    }

    // Wake parent if it's blocked on wait4
    if (proc.parent_pid != 0) {
        if (process.findByPid(proc.parent_pid)) |parent| {
            if (parent.state == .blocked_on_wait) {
                scheduler.wakeProcess(parent.pid);
                if (proc.pid >= 3) {
                    uart.print("[exit] woke parent P{}\n", .{parent.pid});
                }
            } else if (proc.pid >= 3) {
                uart.print("[exit] parent P{} not waiting (state={})\n", .{ parent.pid, @intFromEnum(parent.state) });
            }
        } else if (proc.pid >= 3) {
            uart.print("[exit] parent P{} not found!\n", .{proc.parent_pid});
        }
    }

    // Schedule next process
    scheduler.schedule(frame);

    return 0; // Never reached
}

/// exit_group(status) -> does not return
/// Kills all threads in the thread group, then exits the calling thread.
fn sysExitGroup(frame: *exception.TrapFrame) i64 {
    const status = frame.x[0];
    const proc = scheduler.currentProcess() orelse return -1;
    const tgid = proc.tgid;

    if (proc.pid >= 3 and status != 0) {
        uart.print("[exit_group] pid={} status={}\n", .{ proc.pid, status });
    }

    // Mark all other threads in the thread group as zombie and send IPIs
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.tgid == tgid and p.pid != proc.pid and p.state != .zombie) {
                p.killed = true;
                asm volatile ("dmb ish" ::: .{ .memory = true });
                p.state = .zombie;
                p.exit_status = status;
                // Handle clear_child_tid for killed threads
                if (p.clear_child_tid != 0) {
                    if (vmm.translate(vmm.PhysAddr.from(p.page_table), vmm.VirtAddr.from(p.clear_child_tid))) |_| {
                        const ptr: *align(1) u32 = @ptrFromInt(p.clear_child_tid);
                        ptr.* = 0;
                        _ = futex.wakeAddress(p.page_table, p.clear_child_tid, 1);
                    }
                }
                // Send IPI to force context switch if running on another CPU
                if (p.cpu_id >= 0) {
                    gic.sendSGI(@intCast(@as(u32, @bitCast(p.cpu_id))), gic.SGI_RESCHEDULE);
                }
                // DON'T free kernel stack here — thread may still be executing!
                // Kernel stacks are freed during wait4 reap.
            }
        }
    }

    // Wait for all killed threads to be off-CPU before destroying shared address space
    var spin: u32 = 0;
    while (spin < 10_000_000) : (spin += 1) {
        var all_off = true;
        for (0..process.MAX_PROCESSES) |i| {
            if (process.getProcess(i)) |p| {
                if (p.tgid == tgid and p.pid != proc.pid and p.cpu_id >= 0) {
                    all_off = false;
                    break;
                }
            }
        }
        if (all_off) break;
        asm volatile ("yield");
    }

    // Close fds for all killed threads (now safely off-CPU).
    // Each thread has its own fd table copy with elevated ref_counts.
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.tgid == tgid and p.pid != proc.pid) {
                closeAllFds(p);
            }
        }
    }

    // Now exit the calling thread (last one destroys the address space)
    return sysExit(frame);
}

/// brk(addr) -> new_brk
fn sysBrk(frame: *exception.TrapFrame) i64 {
    const addr = frame.x[0];
    const proc = scheduler.currentProcess() orelse return -1;
    const vp = getVmaProcess(proc);

    if (addr == 0) {
        return @intCast(vp.heap_current);
    }

    vp.vma_lock.acquire();
    defer vp.vma_lock.release();

    // Align to page boundary
    const new_brk = (addr + pmm.PAGE_SIZE - 1) & ~(pmm.PAGE_SIZE - 1);

    if (new_brk < vp.heap_start) {
        return @intCast(vp.heap_current);
    }

    // Grow heap: expand the heap VMA and let demand paging handle allocation
    if (new_brk > vp.heap_current) {
        // Find the heap VMA by looking for a readable+writable VMA that contains
        // or abuts heap_current. We cannot match on start==heap_start because
        // MAP_FIXED may have overridden the first page(s) with a guard (PROT_NONE),
        // leaving a split VMA with different flags at the original heap_start.
        var found_heap_vma = false;
        for (0..vma.MAX_VMAS) |i| {
            if (vp.vmas[i].in_use and vp.vmas[i].flags.readable and vp.vmas[i].flags.writable and
                vp.vmas[i].start <= vp.heap_current and vp.vmas[i].end >= vp.heap_current)
            {
                vp.vmas[i].end = new_brk;
                found_heap_vma = true;
                break;
            }
        }
        if (!found_heap_vma) {
            // Heap VMA was split/overridden — create a new one from heap_current
            _ = vma.addVma(&vp.vmas, vp.heap_current, new_brk, .{
                .readable = true, .writable = true, .user = true,
            });
        }

        var current = vp.heap_current;
        while (current < new_brk) : (current += pmm.PAGE_SIZE) {
            const page = pmm.allocPage() orelse return @intCast(vp.heap_current);
            zeroPage(page);
            vmm.mapPage(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(current), vmm.PhysAddr.from(page), .{
                .user = true,
                .writable = true,
                .executable = false,
            }) catch return @intCast(vp.heap_current);
        }
    }

    vp.heap_current = new_brk;
    return @intCast(new_brk);
}

/// getpid() -> pid
fn sysGetpid() i64 {
    if (scheduler.currentProcess()) |proc| {
        return @intCast(proc.tgid);
    }
    return -1;
}

/// gettid() -> tid
fn sysGettid() i64 {
    if (scheduler.currentProcess()) |proc| {
        return @intCast(proc.pid);
    }
    return -1;
}

/// uname(buf) -> 0
fn sysUname(frame: *exception.TrapFrame) i64 {
    const buf_addr = frame.x[0];
    const proc = scheduler.currentProcess() orelse return -1;

    // Ensure buffer pages are mapped (demand-page if needed)
    // utsname is 390 bytes, may span 2 pages
    if (!ensureUserPages(proc.page_table, buf_addr, 390)) {
        return -14; // -EFAULT
    }

    // struct utsname has 65-byte fields (with null terminator)
    const buf: [*]u8 = @ptrFromInt(buf_addr);

    // sysname
    const sysname = "Zigix";
    for (0..sysname.len) |i| {
        buf[i] = sysname[i];
    }
    buf[sysname.len] = 0;

    // nodename (offset 65)
    const nodename = "zigix";
    for (0..nodename.len) |i| {
        buf[65 + i] = nodename[i];
    }
    buf[65 + nodename.len] = 0;

    // release (offset 130)
    const release = "0.1.0";
    for (0..release.len) |i| {
        buf[130 + i] = release[i];
    }
    buf[130 + release.len] = 0;

    // version (offset 195)
    const version = "#1 SMP";
    for (0..version.len) |i| {
        buf[195 + i] = version[i];
    }
    buf[195 + version.len] = 0;

    // machine (offset 260)
    const machine = "aarch64";
    for (0..machine.len) |i| {
        buf[260 + i] = machine[i];
    }
    buf[260 + machine.len] = 0;

    return 0;
}

/// lseek(fd, offset, whence) -> new_offset
fn sysLseek(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const offset: i64 = @bitCast(frame.x[1]);
    const whence = frame.x[2];

    const proc = scheduler.currentProcess() orelse return -9;
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9;

    // Pipes, sockets, and character devices (UART) are not seekable
    const mode = desc.inode.mode & vfs.S_IFMT;
    if (mode == vfs.S_IFIFO or mode == vfs.S_IFSOCK or mode == vfs.S_IFCHR) {
        return -29; // -ESPIPE
    }

    const SEEK_SET: u64 = 0;
    const SEEK_CUR: u64 = 1;
    const SEEK_END: u64 = 2;
    const SEEK_DATA: u64 = 3;
    const SEEK_HOLE: u64 = 4;

    const new_off: i64 = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => @as(i64, @intCast(desc.offset)) + offset,
        SEEK_END => @as(i64, @intCast(desc.inode.size)) + offset,
        SEEK_DATA => blk: {
            // Return offset of next data at or after offset
            // For non-sparse files, offset itself is data if < size
            if (offset < 0) break :blk @as(i64, -6); // -ENXIO
            const uoff: u64 = @intCast(offset);
            if (uoff >= desc.inode.size) break :blk @as(i64, -6); // -ENXIO
            break :blk offset; // Simplified: all data is "data" (no hole detection)
        },
        SEEK_HOLE => blk: {
            // Return offset of next hole at or after offset
            // For non-sparse files, the only "hole" is at EOF
            if (offset < 0) break :blk @as(i64, -6); // -ENXIO
            const uoff: u64 = @intCast(offset);
            if (uoff >= desc.inode.size) break :blk @as(i64, -6); // -ENXIO
            break :blk @as(i64, @intCast(desc.inode.size)); // Hole starts at EOF
        },
        else => return -22, // -EINVAL
    };

    if (new_off < 0) return -22;
    desc.offset = @intCast(new_off);
    return new_off;
}

/// dup(oldfd) -> newfd
fn sysDup(frame: *exception.TrapFrame) i64 {
    const oldfd = frame.x[0];
    const proc = scheduler.currentProcess() orelse return -9;
    const desc = fd_table.fdGet(&proc.fds, oldfd) orelse return -9;

    _ = @atomicRmw(u32, &desc.ref_count, .Add, 1, .acq_rel);
    const newfd = fd_table.fdAlloc(&proc.fds, desc) orelse {
        _ = @atomicRmw(u32, &desc.ref_count, .Sub, 1, .acq_rel);
        return -24; // -EMFILE
    };
    // dup() never sets FD_CLOEXEC on the new fd
    proc.fd_cloexec[newfd] = false;
    return @intCast(newfd);
}

/// dup3(oldfd, newfd, flags) -> newfd
fn sysDup3(frame: *exception.TrapFrame) i64 {
    const oldfd = frame.x[0];
    const newfd = frame.x[1];
    const flags: u32 = @truncate(frame.x[2]);
    const proc = scheduler.currentProcess() orelse return -9;

    if (fd_table.fdDup2(&proc.fds, oldfd, newfd) == 0) {
        // Per-fd cloexec: set based on dup3 flags, NOT inherited from source fd
        if (newfd < fd_table.MAX_FDS) {
            proc.fd_cloexec[@truncate(newfd)] = (flags & vfs.O_CLOEXEC != 0);
        }
        return @intCast(newfd);
    }
    return -9; // -EBADF
}

/// getcwd(buf, size) -> buf
fn sysGetcwd(frame: *exception.TrapFrame) i64 {
    const buf_addr = frame.x[0];
    const size = frame.x[1];
    const proc = scheduler.currentProcess() orelse return -1;

    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(buf_addr)) == null) return -14;

    const cwd_len: usize = proc.cwd_len;
    if (cwd_len + 1 > size) return -34; // -ERANGE

    const buf: [*]u8 = @ptrFromInt(buf_addr);
    for (0..cwd_len) |i| {
        buf[i] = proc.cwd[i];
    }
    buf[cwd_len] = 0;

    return @intCast(buf_addr);
}

/// chdir(path) -> 0
fn sysChdir(frame: *exception.TrapFrame) i64 {
    const path_addr = frame.x[0];
    const proc = scheduler.currentProcess() orelse return -1;

    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(path_addr)) == null) return -14;

    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {}

    const path = path_ptr[0..path_len];
    const inode = vfs.resolve(path) orelse return -2; // -ENOENT

    // Must be a directory
    if (inode.mode & vfs.S_IFMT != vfs.S_IFDIR) return -20; // -ENOTDIR

    for (0..path_len) |i| {
        proc.cwd[i] = path[i];
    }
    proc.cwd_len = @truncate(path_len);

    return 0;
}

/// mkdirat(dirfd, pathname, mode) -> 0
fn sysMkdirat(frame: *exception.TrapFrame) i64 {
    const dirfd = frame.x[0];
    const path_addr = frame.x[1];
    const mode: u32 = @truncate(frame.x[2]);

    const proc = scheduler.currentProcess() orelse return -1;

    // Ensure first page of path is mapped (demand-page if needed)
    if (!ensureUserPages(proc.page_table, path_addr, 1)) return -14; // -EFAULT

    // Read path from user space, demand-paging across page boundaries
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {
        const next_addr = path_addr + path_len + 1;
        if (next_addr & 0xFFF == 0 and path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }

    if (path_len == 0) return -2; // -ENOENT

    const path = path_ptr[0..path_len];

    // Resolve path — handle dirfd for relative paths
    const result = blk: {
        if (path[0] == '/') {
            break :blk vfs.resolvePath(path);
        } else if (dirfd != AT_FDCWD) {
            if (fd_table.fdGet(&proc.fds, @truncate(dirfd))) |desc| {
                break :blk vfs.resolvePathFrom(desc.inode, path);
            }
            return -9; // -EBADF
        } else {
            // AT_FDCWD — relative to CWD (build absolute path)
            var abs_buf: [512]u8 = undefined;
            const cwd = proc.cwd[0..proc.cwd_len];
            var abs_len: usize = cwd.len;
            for (0..cwd.len) |i| abs_buf[i] = cwd[i];
            if (abs_len > 0 and abs_buf[abs_len - 1] != '/') {
                abs_buf[abs_len] = '/';
                abs_len += 1;
            }
            const copy_len = @min(path.len, abs_buf.len - abs_len);
            for (0..copy_len) |i| abs_buf[abs_len + i] = path[i];
            abs_len += copy_len;
            break :blk vfs.resolvePath(abs_buf[0..abs_len]);
        }
    };

    if (result.inode != null) return -17; // -EEXIST

    const parent = result.parent orelse return -2; // -ENOENT
    if (!checkPermission(parent, 3, proc)) return -13; // -EACCES (need W+X on parent)
    const create_fn = parent.ops.create orelse return -1; // -EPERM
    const name = result.leaf_name[0..result.leaf_len];

    const effective_mode = vfs.S_IFDIR | ((mode & 0o7777) & ~proc.umask_val);
    _ = create_fn(parent, name, effective_mode) orelse return -12; // -ENOMEM

    return 0;
}

/// mknodat(dirfd, pathname, mode, dev) -> 0
fn sysMknodat(frame: *exception.TrapFrame) i64 {
    const dirfd = frame.x[0];
    const path_addr = frame.x[1];
    const mode: u32 = @truncate(frame.x[2]);
    const dev: u32 = @truncate(frame.x[3]);

    const proc = scheduler.currentProcess() orelse return -1;

    // Validate mode type
    const fmt = mode & vfs.S_IFMT;
    if (fmt != vfs.S_IFREG and fmt != vfs.S_IFCHR and fmt != vfs.S_IFBLK and
        fmt != vfs.S_IFIFO and fmt != vfs.S_IFSOCK)
    {
        return -22; // -EINVAL
    }

    if (!ensureUserPages(proc.page_table, path_addr, 1)) return -14;

    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {
        const next_addr = path_addr + path_len + 1;
        if (next_addr & 0xFFF == 0 and path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }
    if (path_len == 0) return -2;

    const path = path_ptr[0..path_len];

    const result = blk: {
        if (path[0] == '/') {
            break :blk vfs.resolvePath(path);
        } else if (dirfd != AT_FDCWD) {
            if (fd_table.fdGet(&proc.fds, @truncate(dirfd))) |desc| {
                break :blk vfs.resolvePathFrom(desc.inode, path);
            }
            return -9;
        } else {
            var abs_buf: [512]u8 = undefined;
            const cwd = proc.cwd[0..proc.cwd_len];
            var abs_len: usize = cwd.len;
            for (0..cwd.len) |i| abs_buf[i] = cwd[i];
            if (abs_len > 0 and abs_buf[abs_len - 1] != '/') {
                abs_buf[abs_len] = '/';
                abs_len += 1;
            }
            const copy_len = @min(path.len, abs_buf.len - abs_len);
            for (0..copy_len) |i| abs_buf[abs_len + i] = path[i];
            abs_len += copy_len;
            break :blk vfs.resolvePath(abs_buf[0..abs_len]);
        }
    };

    if (result.inode != null) return -17; // -EEXIST

    const parent = result.parent orelse return -2;
    if (!checkPermission(parent, 3, proc)) return -13;
    const create_fn = parent.ops.create orelse return -1;
    const name = result.leaf_name[0..result.leaf_len];

    // Set pending rdev for ext2Create to pick up (protected by ext2_lock inside create)
    ext2.pending_mknod_rdev = dev;

    const effective_mode = fmt | ((mode & 0o7777) & ~proc.umask_val);
    _ = create_fn(parent, name, effective_mode) orelse {
        ext2.pending_mknod_rdev = 0;
        return -12;
    };

    return 0;
}

/// unlinkat(dirfd, pathname, flags) -> 0
/// When flags contains AT_REMOVEDIR (0x200), behaves like rmdir.
fn sysUnlinkat(frame: *exception.TrapFrame) i64 {
    const dirfd = frame.x[0];
    const path_addr = frame.x[1];
    const flags = frame.x[2];
    const AT_REMOVEDIR: u64 = 0x200;

    const proc = scheduler.currentProcess() orelse return -1;

    if (!ensureUserPages(proc.page_table, path_addr, 1)) return -14;

    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {
        const next_addr = path_addr + path_len + 1;
        if (next_addr & 0xFFF == 0 and path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }

    if (path_len == 0) return -2;

    const path = path_ptr[0..path_len];
    const result = blk: {
        if (path[0] == '/') {
            break :blk vfs.resolvePath(path);
        } else if (dirfd != AT_FDCWD) {
            if (fd_table.fdGet(&proc.fds, @truncate(dirfd))) |desc| {
                break :blk vfs.resolvePathFrom(desc.inode, path);
            }
            return -9; // -EBADF
        } else {
            var abs_buf: [512]u8 = undefined;
            const cwd = proc.cwd[0..proc.cwd_len];
            var abs_len: usize = cwd.len;
            for (0..cwd.len) |i| abs_buf[i] = cwd[i];
            if (abs_len > 0 and abs_buf[abs_len - 1] != '/') {
                abs_buf[abs_len] = '/';
                abs_len += 1;
            }
            const copy_len = @min(path.len, abs_buf.len - abs_len);
            for (0..copy_len) |i| abs_buf[abs_len + i] = path[i];
            abs_len += copy_len;
            break :blk vfs.resolvePath(abs_buf[0..abs_len]);
        }
    };

    const parent = result.parent orelse return -2;
    if (!checkPermission(parent, 3, proc)) return -13; // -EACCES (need W+X on parent)

    const name = result.leaf_name[0..result.leaf_len];

    // AT_REMOVEDIR: remove directory (like rmdir)
    if (flags & AT_REMOVEDIR != 0) {
        const rmdir_fn = parent.ops.rmdir orelse return -38; // -ENOSYS
        if (rmdir_fn(parent, name)) return 0;
        return -39; // -ENOTEMPTY
    }

    // Sticky bit enforcement: in a directory with S_ISVTX set,
    // only the file owner, directory owner, or root can delete files
    if (parent.mode & vfs.S_ISVTX != 0 and proc.uid != 0) {
        if (parent.ops.lookup) |lookup_fn| {
            if (lookup_fn(parent, name)) |target| {
                if (target.uid != proc.uid and parent.uid != proc.uid) {
                    return -1; // -EPERM
                }
            }
        }
    }

    const unlink_fn = parent.ops.unlink orelse return -1;

    if (unlink_fn(parent, name)) {
        inotifyNotify(@truncate(parent.ino), IN_DELETE, name);
        return 0;
    }
    return -2; // -ENOENT
}

/// renameat(olddirfd, oldpath, newdirfd, newpath) -> 0
fn sysRenameat(frame: *exception.TrapFrame) i64 {
    const old_dirfd = frame.x[0];
    const old_path_addr = frame.x[1];
    const new_dirfd = frame.x[2];
    const new_path_addr = frame.x[3];

    const proc = scheduler.currentProcess() orelse return -1;
    // Read old path from user space
    if (!ensureUserPages(proc.page_table, old_path_addr, 1)) return -14;
    const old_path_ptr: [*]const u8 = @ptrFromInt(old_path_addr);
    var old_path_len: usize = 0;
    while (old_path_len < 255 and old_path_ptr[old_path_len] != 0) : (old_path_len += 1) {
        const next_addr = old_path_addr + old_path_len + 1;
        if (next_addr & 0xFFF == 0 and old_path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }
    if (old_path_len == 0) return -2;
    const old_path = old_path_ptr[0..old_path_len];

    // Read new path from user space
    if (!ensureUserPages(proc.page_table, new_path_addr, 1)) return -14;
    const new_path_ptr: [*]const u8 = @ptrFromInt(new_path_addr);
    var new_path_len: usize = 0;
    while (new_path_len < 255 and new_path_ptr[new_path_len] != 0) : (new_path_len += 1) {
        const next_addr = new_path_addr + new_path_len + 1;
        if (next_addr & 0xFFF == 0 and new_path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }
    if (new_path_len == 0) return -2;
    const new_path = new_path_ptr[0..new_path_len];

    // Resolve old path using dirfd
    const old_result = resolveWithDirfd(proc, old_dirfd, old_path);

    // Resolve new path using dirfd
    const new_result = resolveWithDirfd(proc, new_dirfd, new_path);

    // Old path must exist (source must be found)
    if (old_result.inode == null) {
        uart.print("[rename-e] ENOENT old: ", .{});
        uart.writeString(old_path);
        uart.writeString("\n");
        return -2; // -ENOENT
    }

    // Both must have valid parent directories
    const old_parent = old_result.parent orelse {
        uart.print("[rename-e] no old_parent: ", .{});
        uart.writeString(old_path);
        uart.writeString("\n");
        return -2;
    };
    const new_parent = new_result.parent orelse {
        uart.print("[rename-e] no new_parent dirfd={}: ", .{new_dirfd});
        uart.writeString(new_path);
        if (new_dirfd == AT_FDCWD) {
            uart.print(" cwd=", .{});
            uart.writeString(proc.cwd[0..proc.cwd_len]);
        }
        uart.writeString("\n");
        return -2;
    };

    // Permission check: need W+X on both parent directories
    if (!checkPermission(old_parent, 3, proc)) return -13; // -EACCES
    if (!checkPermission(new_parent, 3, proc)) return -13; // -EACCES

    // Old parent must support rename
    const rename_fn = old_parent.ops.rename orelse return -38; // -ENOSYS

    const old_leaf = old_result.leaf_name[0..old_result.leaf_len];
    const new_leaf = new_result.leaf_name[0..new_result.leaf_len];

    if (rename_fn(old_parent, old_leaf, new_parent, new_leaf)) {
        inotifyNotify(@truncate(old_parent.ino), IN_MOVED_FROM, old_leaf);
        inotifyNotify(@truncate(new_parent.ino), IN_MOVED_TO, new_leaf);
        return 0;
    }
    return -2; // -ENOENT
}

/// renameat2(olddirfd, oldpath, newdirfd, newpath, flags) -> 0
/// Like renameat but with flags: RENAME_NOREPLACE=1, RENAME_EXCHANGE=2
fn sysRenameat2(frame: *exception.TrapFrame) i64 {
    const flags: u32 = @truncate(frame.x[4]);
    const RENAME_NOREPLACE: u32 = 1;
    const RENAME_EXCHANGE: u32 = 2;

    if (flags & ~@as(u32, RENAME_NOREPLACE | RENAME_EXCHANGE) != 0) return -22; // -EINVAL
    // NOREPLACE and EXCHANGE are mutually exclusive
    if (flags & RENAME_NOREPLACE != 0 and flags & RENAME_EXCHANGE != 0) return -22;

    if (flags & RENAME_EXCHANGE != 0) {
        return sysRenameExchange(frame);
    }

    if (flags & RENAME_NOREPLACE != 0) {
        // Check if dest exists first
        const proc = scheduler.currentProcess() orelse return -1;
        const new_path_addr = frame.x[3];
        if (!ensureUserPages(proc.page_table, new_path_addr, 1)) return -14;
        const new_path_ptr: [*]const u8 = @ptrFromInt(new_path_addr);
        var new_path_len: usize = 0;
        while (new_path_len < 255 and new_path_ptr[new_path_len] != 0) : (new_path_len += 1) {
            const next_addr = new_path_addr + new_path_len + 1;
            if (next_addr & 0xFFF == 0 and new_path_len + 1 < 255) {
                if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
            }
        }
        if (new_path_len == 0) return -2;
        const new_path = new_path_ptr[0..new_path_len];
        const new_dirfd = frame.x[2];
        const new_result = resolveWithDirfd(proc, new_dirfd, new_path);
        if (new_result.inode != null) return -17; // -EEXIST
    }

    // Delegate to normal renameat (which handles the actual rename)
    return sysRenameat(frame);
}

/// RENAME_EXCHANGE: atomically swap two directory entries.
fn sysRenameExchange(frame: *exception.TrapFrame) i64 {
    const proc = scheduler.currentProcess() orelse return -1;

    // Resolve old path
    const old_path_addr = frame.x[1];
    if (!ensureUserPages(proc.page_table, old_path_addr, 1)) return -14;
    const old_path_ptr: [*]const u8 = @ptrFromInt(old_path_addr);
    var old_path_len: usize = 0;
    while (old_path_len < 255 and old_path_ptr[old_path_len] != 0) : (old_path_len += 1) {
        const next_addr = old_path_addr + old_path_len + 1;
        if (next_addr & 0xFFF == 0 and old_path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }
    if (old_path_len == 0) return -2;

    // Resolve new path
    const new_path_addr = frame.x[3];
    if (!ensureUserPages(proc.page_table, new_path_addr, 1)) return -14;
    const new_path_ptr: [*]const u8 = @ptrFromInt(new_path_addr);
    var new_path_len: usize = 0;
    while (new_path_len < 255 and new_path_ptr[new_path_len] != 0) : (new_path_len += 1) {
        const next_addr = new_path_addr + new_path_len + 1;
        if (next_addr & 0xFFF == 0 and new_path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }
    if (new_path_len == 0) return -2;

    const old_dirfd = frame.x[0];
    const new_dirfd = frame.x[2];

    const old_result = resolveWithDirfd(proc, old_dirfd, old_path_ptr[0..old_path_len]);
    const old_parent = old_result.inode orelse return -2; // -ENOENT
    const old_name = old_result.leaf_name[0..old_result.leaf_len];

    const new_result = resolveWithDirfd(proc, new_dirfd, new_path_ptr[0..new_path_len]);
    const new_parent = new_result.inode orelse return -2;
    const new_name = new_result.leaf_name[0..new_result.leaf_len];

    // Both entries must exist for EXCHANGE
    const old_inode = old_parent.ops.lookup.?(old_parent, old_name) orelse return -2;
    const new_inode = new_parent.ops.lookup.?(new_parent, new_name) orelse return -2;

    // Swap: update inode numbers in directory entries
    // This is done by removing both entries and re-adding them with swapped inodes
    const old_ino: u32 = @truncate(old_inode.ino);
    const new_ino: u32 = @truncate(new_inode.ino);
    const old_mode = old_inode.mode;
    const new_mode = new_inode.mode;

    // Use ext2's rename: remove old, add new_ino under old_name; remove new, add old_ino under new_name
    // We use forceDirEntryRemove + addDirEntry at the ext2 level
    // For simplicity, use the VFS rename which already handles directory entry manipulation
    // Step 1: Rename old -> temp (removes old entry, creates temp entry with old's ino)
    // Step 2: Rename new -> old_name (removes new entry, creates old_name with new's ino)
    // Step 3: Rename temp -> new_name
    // This is too complex. Instead, directly swap inode numbers in the directory entries.

    // Direct approach: modify directory entries in-place
    if (ext2.swapDirEntryInodes(old_parent, old_name, new_ino, new_mode) and
        ext2.swapDirEntryInodes(new_parent, new_name, old_ino, old_mode))
    {
        return 0;
    }
    return -5; // -EIO
}

/// fchmod(fd, mode) -> 0
fn sysFchmod(frame: *exception.TrapFrame) i64 {
    const fd: u32 = @truncate(frame.x[0]);
    const new_mode: u32 = @truncate(frame.x[1]);
    const proc = scheduler.currentProcess() orelse return -1;
    const desc = fd_table.fdGet(&proc.fds, fd) orelse return -9; // -EBADF
    const inode = desc.inode;
    // Only owner or root can chmod
    if (proc.euid != 0 and proc.euid != inode.uid) return -1; // -EPERM
    inode.mode = (inode.mode & vfs.S_IFMT) | (new_mode & 0o7777);
    ext2.setInodeMode(inode);
    return 0;
}

/// fchown(fd, owner, group) -> 0
fn sysFchown(frame: *exception.TrapFrame) i64 {
    const fd: u32 = @truncate(frame.x[0]);
    const owner: u32 = @truncate(frame.x[1]);
    const group: u32 = @truncate(frame.x[2]);
    const proc = scheduler.currentProcess() orelse return -1;
    const desc = fd_table.fdGet(&proc.fds, fd) orelse return -9; // -EBADF
    const inode = desc.inode;
    // Only root can chown
    if (proc.euid != 0) return -1; // -EPERM
    if (owner != 0xFFFFFFFF) inode.uid = @truncate(owner);
    if (group != 0xFFFFFFFF) inode.gid = @truncate(group);
    ext2.setInodeOwner(inode);
    return 0;
}

/// fchmodat(dirfd, path, mode, flags) -> 0
fn sysFchmodat(frame: *exception.TrapFrame) i64 {
    const dirfd = frame.x[0];
    const path_addr = frame.x[1];
    const new_mode: u32 = @truncate(frame.x[2]);
    const proc = scheduler.currentProcess() orelse return -1;
    if (!ensureUserPages(proc.page_table, path_addr, 1)) return -14;
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {}
    if (path_len == 0) return -2;
    const result = resolveWithDirfd(proc, dirfd, path_ptr[0..path_len]);
    const inode = result.inode orelse return -2; // -ENOENT
    if (proc.euid != 0 and proc.euid != inode.uid) return -1; // -EPERM
    inode.mode = (inode.mode & vfs.S_IFMT) | (new_mode & 0o7777);
    ext2.setInodeMode(inode);
    return 0;
}

/// fchownat(dirfd, path, owner, group, flags) -> 0
fn sysFchownat(frame: *exception.TrapFrame) i64 {
    const dirfd = frame.x[0];
    const path_addr = frame.x[1];
    const owner: u32 = @truncate(frame.x[2]);
    const group: u32 = @truncate(frame.x[3]);
    const proc = scheduler.currentProcess() orelse return -1;
    if (!ensureUserPages(proc.page_table, path_addr, 1)) return -14;
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {}
    if (path_len == 0) return -2;
    const result = resolveWithDirfd(proc, dirfd, path_ptr[0..path_len]);
    const inode = result.inode orelse return -2; // -ENOENT
    if (proc.euid != 0) return -1; // -EPERM
    if (owner != 0xFFFFFFFF) inode.uid = @truncate(owner);
    if (group != 0xFFFFFFFF) inode.gid = @truncate(group);
    ext2.setInodeOwner(inode);
    return 0;
}

/// fstat/newfstatat -> fill stat buffer
fn sysStat(frame: *exception.TrapFrame) i64 {
    const fd_or_dirfd = frame.x[0];
    const path_or_buf = frame.x[1];
    const proc = scheduler.currentProcess() orelse return -1;

    // Simple fstat path: if syscall is SYS_fstat
    const syscall_num = frame.x[8];
    if (syscall_num == SYS_fstat) {
        const desc = fd_table.fdGet(&proc.fds, fd_or_dirfd) orelse return -9;
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(path_or_buf)) == null) return -14;
        fillStatBuf(desc.inode, path_or_buf);
        return 0;
    }

    // newfstatat: dirfd, path, statbuf, flags
    const dirfd = fd_or_dirfd;
    const path_addr = path_or_buf;
    const stat_addr = frame.x[2];
    const stat_flags: u32 = @truncate(frame.x[3]);
    const AT_EMPTY_PATH: u32 = 0x1000;

    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(path_addr)) == null) return -14;
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(stat_addr)) == null) return -14;

    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {}

    // AT_EMPTY_PATH: stat the fd itself
    if (path_len == 0 and stat_flags & AT_EMPTY_PATH != 0) {
        const desc = fd_table.fdGet(&proc.fds, dirfd) orelse return -9;
        fillStatBuf(desc.inode, stat_addr);
        return 0;
    }

    const path = path_ptr[0..path_len];

    // Intercept pseudo-device paths
    if (path_len == 9 and streql(path, "/dev/null")) {
        fillStatBuf(&devnull_inode, stat_addr);
        return 0;
    }
    if (path_len == 9 and streql(path, "/dev/zero")) {
        fillStatBuf(&devzero_inode, stat_addr);
        return 0;
    }

    const inode = blk: {
        if (path.len > 0 and path[0] == '/') {
            break :blk vfs.resolve(path) orelse {
                if (proc.pid >= 2) {
                    uart.print("[stat-e] P{} fstatat: ", .{proc.pid});
                    uart.writeString(path);
                    uart.writeString("\n");
                }
                return -2;
            };
        } else if (dirfd != AT_FDCWD) {
            if (fd_table.fdGet(&proc.fds, @truncate(dirfd))) |desc| {
                const res = vfs.resolvePathFrom(desc.inode, path);
                break :blk res.inode orelse {
                    if (proc.pid >= 2) {
                        uart.print("[stat-e] P{} fstatat(fd): ", .{proc.pid});
                        uart.writeString(path);
                        uart.writeString("\n");
                    }
                    return -2;
                };
            }
            return -9; // -EBADF: invalid dirfd
        } else {
            // AT_FDCWD — relative to CWD (build absolute path)
            var abs_buf: [512]u8 = undefined;
            const cwd = proc.cwd[0..proc.cwd_len];
            var abs_len: usize = cwd.len;
            for (0..cwd.len) |i| abs_buf[i] = cwd[i];
            if (abs_len > 0 and abs_buf[abs_len - 1] != '/') {
                abs_buf[abs_len] = '/';
                abs_len += 1;
            }
            const copy_len = @min(path.len, abs_buf.len - abs_len);
            for (0..copy_len) |i| abs_buf[abs_len + i] = path[i];
            abs_len += copy_len;
            break :blk vfs.resolve(abs_buf[0..abs_len]) orelse {
                if (proc.pid >= 2) {
                    uart.print("[stat-e] P{} fstatat(cwd): ", .{proc.pid});
                    uart.writeString(abs_buf[0..abs_len]);
                    uart.writeString("\n");
                }
                return -2;
            };
        }
    };
    fillStatBuf(inode, stat_addr);
    return 0;
}

fn fillStatBuf(inode: *vfs.Inode, buf_addr: u64) void {
    // Linux AArch64 struct stat (from asm-generic/stat.h + musl) — 128 bytes
    // NOTE: aarch64 layout differs from x86_64! Key difference:
    //   x86_64: st_nlink is 8 bytes at offset 16, st_mode is 4 bytes at offset 24
    //   aarch64: st_mode is 4 bytes at offset 16, st_nlink is 4 bytes at offset 20
    //
    // Offset  Size  Field
    //   0       8   st_dev
    //   8       8   st_ino
    //  16       4   st_mode      (differs from x86_64!)
    //  20       4   st_nlink     (differs from x86_64!)
    //  24       4   st_uid
    //  28       4   st_gid
    //  32       8   st_rdev
    //  40       8   __pad1
    //  48       8   st_size
    //  56       4   st_blksize
    //  60       4   __pad2
    //  64       8   st_blocks
    //  72       8   st_atime (sec)
    //  80       8   st_atime_nsec
    //  88       8   st_mtime (sec)
    //  96       8   st_mtime_nsec
    // 104       8   st_ctime (sec)
    // 112       8   st_ctime_nsec
    // 120       8   __unused[0..1]
    const buf: [*]u8 = @ptrFromInt(buf_addr);

    // Zero entire 128-byte struct first (handles padding and unused fields)
    for (0..128) |i| {
        buf[i] = 0;
    }

    // st_dev (offset 0) = 0
    writeU64(buf, 8, inode.ino);                            // st_ino
    writeU32(buf, 16, inode.mode);                          // st_mode (4 bytes on aarch64!)
    writeU32(buf, 20, @truncate(inode.nlink));               // st_nlink (4 bytes on aarch64!)
    writeU32(buf, 24, @as(u32, inode.uid));                   // st_uid
    writeU32(buf, 28, @as(u32, inode.gid));                   // st_gid
    writeU64(buf, 32, @as(u64, inode.rdev)); // st_rdev
    // __pad1 (offset 40) = 0
    writeU64(buf, 48, inode.size);                          // st_size
    writeU32(buf, 56, 4096);                                // st_blksize (4 bytes on aarch64!)
    // __pad2 (offset 60) = 0
    const blocks = (inode.size + 511) / 512;
    writeU64(buf, 64, blocks);                              // st_blocks

    // Read timestamps from ext2 cache
    const ts = ext2.getTimestamps(inode);
    writeU64(buf, 72, @as(u64, ts.atime));                  // st_atime (sec)
    // st_atime_nsec (offset 80) = 0
    writeU64(buf, 88, @as(u64, ts.mtime));                  // st_mtime (sec)
    // st_mtime_nsec (offset 96) = 0
    writeU64(buf, 104, @as(u64, ts.ctime));                 // st_ctime (sec)
    // st_ctime_nsec (offset 112) = 0
}

fn writeU32(buf: [*]u8, off: usize, val: u32) void {
    buf[off + 0] = @truncate(val);
    buf[off + 1] = @truncate(val >> 8);
    buf[off + 2] = @truncate(val >> 16);
    buf[off + 3] = @truncate(val >> 24);
}

fn writeU64(buf: [*]u8, off: usize, val: u64) void {
    buf[off + 0] = @truncate(val);
    buf[off + 1] = @truncate(val >> 8);
    buf[off + 2] = @truncate(val >> 16);
    buf[off + 3] = @truncate(val >> 24);
    buf[off + 4] = @truncate(val >> 32);
    buf[off + 5] = @truncate(val >> 40);
    buf[off + 6] = @truncate(val >> 48);
    buf[off + 7] = @truncate(val >> 56);
}

fn writeU16(buf: [*]u8, off: usize, val: u16) void {
    buf[off + 0] = @truncate(val);
    buf[off + 1] = @truncate(val >> 8);
}

fn writeI64(buf: [*]u8, off: usize, val: i64) void {
    writeU64(buf, off, @bitCast(val));
}

/// statx(dirfd, pathname, flags, mask, statxbuf) -> 0 or -errno
/// struct statx is 256 bytes:
///   0: u32 stx_mask           28: u16 stx_mode
///   4: u32 stx_blksize        30: u16 __spare0
///   8: u64 stx_attributes     32: u64 stx_ino
///  16: u32 stx_nlink          40: u64 stx_size
///  20: u32 stx_uid            48: u64 stx_blocks
///  24: u32 stx_gid            56: u64 stx_attributes_mask
///  64-79: statx_timestamp stx_atime  (i64 sec, u32 nsec, i32 __reserved)
///  80-95: stx_btime   96-111: stx_ctime   112-127: stx_mtime
/// 128: u32 stx_rdev_major  132: u32 stx_rdev_minor
/// 136: u32 stx_dev_major   140: u32 stx_dev_minor
/// 144: u64 stx_mnt_id      152-255: spare
fn sysStatx(frame: *exception.TrapFrame) i64 {
    const dirfd = frame.x[0];
    const path_addr = frame.x[1];
    const flags: u32 = @truncate(frame.x[2]);
    // mask = frame.x[3] — we always fill all fields
    const statx_addr = frame.x[4];

    const proc = scheduler.currentProcess() orelse return -1;
    const AT_EMPTY_PATH: u32 = 0x1000;

    if (!ensureUserPages(proc.page_table, statx_addr, 256)) return -14; // -EFAULT

    // Resolve the inode — same logic as sysStat/newfstatat
    const inode: *vfs.Inode = blk: {
        if (flags & AT_EMPTY_PATH != 0) {
            // stat the fd itself
            const desc = fd_table.fdGet(&proc.fds, dirfd) orelse return -9; // -EBADF
            break :blk desc.inode;
        }

        if (!ensureUserPages(proc.page_table, path_addr, 1)) return -14;
        const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
        var path_len: usize = 0;
        while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {}

        if (path_len == 0) {
            // Empty path without AT_EMPTY_PATH
            return -2; // -ENOENT
        }

        const path = path_ptr[0..path_len];
        if (path[0] == '/') {
            break :blk vfs.resolve(path) orelse return -2;
        } else if (dirfd != AT_FDCWD) {
            if (fd_table.fdGet(&proc.fds, @truncate(dirfd))) |desc| {
                const res = vfs.resolvePathFrom(desc.inode, path);
                break :blk res.inode orelse return -2;
            }
            return -9; // -EBADF
        } else {
            // AT_FDCWD — relative to CWD
            var abs_buf: [512]u8 = undefined;
            const cwd = proc.cwd[0..proc.cwd_len];
            var abs_len: usize = cwd.len;
            for (0..cwd.len) |i| abs_buf[i] = cwd[i];
            if (abs_len > 0 and abs_buf[abs_len - 1] != '/') {
                abs_buf[abs_len] = '/';
                abs_len += 1;
            }
            const copy_len = @min(path.len, abs_buf.len - abs_len);
            for (0..copy_len) |i| abs_buf[abs_len + i] = path[i];
            abs_len += copy_len;
            break :blk vfs.resolve(abs_buf[0..abs_len]) orelse return -2;
        }
    };

    // Fill statx buffer
    const buf: [*]u8 = @ptrFromInt(statx_addr);

    // Zero entire 256-byte struct
    for (0..256) |i| {
        buf[i] = 0;
    }

    // STATX_BASIC_STATS = 0x07FF
    writeU32(buf, 0, 0x07FF); // stx_mask: all basic stats filled
    writeU32(buf, 4, 4096); // stx_blksize
    // stx_attributes (offset 8) = 0
    writeU32(buf, 16, @truncate(inode.nlink)); // stx_nlink
    writeU32(buf, 20, @as(u32, inode.uid)); // stx_uid
    writeU32(buf, 24, @as(u32, inode.gid)); // stx_gid
    writeU16(buf, 28, @truncate(inode.mode)); // stx_mode
    writeU64(buf, 32, inode.ino); // stx_ino
    writeU64(buf, 40, inode.size); // stx_size
    const blocks = (inode.size + 511) / 512;
    writeU64(buf, 48, blocks); // stx_blocks
    // stx_attributes_mask (offset 56) = 0

    // Timestamps: statx_timestamp = { i64 tv_sec, u32 tv_nsec, i32 __reserved }
    // stx_atime at offset 64, stx_btime at 80, stx_ctime at 96, stx_mtime at 112
    const ts = ext2.getTimestamps(inode);
    writeU64(buf, 64, @as(u64, ts.atime)); // stx_atime.tv_sec
    writeU64(buf, 96, @as(u64, ts.ctime)); // stx_ctime.tv_sec
    writeU64(buf, 112, @as(u64, ts.mtime)); // stx_mtime.tv_sec

    // stx_rdev_major / stx_rdev_minor (offsets 128, 132)
    if (inode.rdev != 0) {
        const major: u32 = (inode.rdev >> 8) & 0xFFF;
        const minor: u32 = (inode.rdev & 0xFF) | ((inode.rdev >> 12) & 0xFFF00);
        writeU32(buf, 128, major);
        writeU32(buf, 132, minor);
    }

    return 0;
}

/// getdents64(fd, buf, count) -> bytes_written
fn sysGetdents64(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const buf_addr = frame.x[1];
    const count = frame.x[2];

    const proc = scheduler.currentProcess() orelse return -9;
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9;

    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(buf_addr)) == null) return -14;

    // Must be a directory
    if (desc.inode.mode & vfs.S_IFMT != vfs.S_IFDIR) return -20;

    const readdir_fn = desc.inode.ops.readdir orelse return -22;

    const buf: [*]u8 = @ptrFromInt(buf_addr);
    var written: usize = 0;

    while (written + 280 <= count) { // Each entry needs up to ~280 bytes
        var entry: vfs.DirEntry = undefined;
        if (!readdir_fn(desc, &entry)) break;

        // struct linux_dirent64: d_ino(8) d_off(8) d_reclen(2) d_type(1) d_name(...)
        const name_len: usize = entry.name_len;
        const reclen: usize = ((19 + name_len + 1) + 7) & ~@as(usize, 7); // Align to 8

        if (written + reclen > count) break;

        // d_ino
        writeU64(buf + written, 0, entry.ino);
        // d_off (next offset)
        writeU64(buf + written, 8, desc.offset);
        // d_reclen
        buf[written + 16] = @truncate(reclen);
        buf[written + 17] = @truncate(reclen >> 8);
        // d_type
        buf[written + 18] = entry.d_type;
        // d_name
        for (0..name_len) |i| {
            buf[written + 19 + i] = entry.name[i];
        }
        buf[written + 19 + name_len] = 0;

        // Zero padding
        var pad = written + 19 + name_len + 1;
        while (pad < written + reclen) : (pad += 1) {
            buf[pad] = 0;
        }

        written += reclen;
    }

    return @intCast(written);
}

/// getppid() -> parent pid
fn sysGetppid() i64 {
    if (scheduler.currentProcess()) |proc| {
        return @intCast(proc.parent_pid);
    }
    return -1;
}

// ============================================================================
// clone (fork) — A13
// ============================================================================

/// Clone flags (Linux AArch64)
const CLONE_VM: u64 = 0x00000100;
const CLONE_FS: u64 = 0x00000200;
const CLONE_FILES: u64 = 0x00000400;
const CLONE_SIGHAND: u64 = 0x00000800;
const CLONE_THREAD: u64 = 0x00010000;
const CLONE_VFORK: u64 = 0x00004000;
const CLONE_PARENT_SETTID: u64 = 0x00100000;
const CLONE_CHILD_SETTID: u64 = 0x01000000;
const CLONE_CHILD_CLEARTID: u64 = 0x00200000;
const CLONE_SETTLS: u64 = 0x00080000;
const SIGCHLD: u64 = 17;

/// clone(flags, child_stack, parent_tidptr, tls, child_tidptr)
/// For simple fork: flags = SIGCHLD, child_stack = 0
fn sysClone(frame: *exception.TrapFrame) i64 {
    const flags = frame.x[0];
    const child_stack = frame.x[1];
    const parent_tidptr = frame.x[2];
    // x[3] = tls (handled inside cloneThread via CLONE_SETTLS)
    const child_tidptr = frame.x[4];

    const parent = scheduler.currentProcess() orelse return -1;

    // CLONE_VM = thread creation (shared address space)
    if (flags & CLONE_VM != 0) {
        return cloneThread(frame, parent, flags, child_stack, parent_tidptr, child_tidptr);
    }

    // Without CLONE_VM = fork with CoW
    // Find a free process slot
    const child_idx = process.findFreeSlot() orelse return -11; // -EAGAIN

    // Hold vma_lock during fork to prevent CLONE_VM threads from concurrently
    // modifying the address space (munmap/mmap). Without this, a worker thread
    // can zero a PTE via munmap while forkAddressSpace reads and re-writes it
    // with CoW, creating a stale PTE with no backing VMA.
    const vp = getVmaProcess(parent);
    vp.vma_lock.acquire();

    // Fork the address space with CoW (VMA-aware: private-copies stale PTEs)
    const child_pt = vmm.forkAddressSpace(vmm.PhysAddr.from(parent.page_table), &vp.vmas) catch {
        vp.vma_lock.release();
        return -12; // -ENOMEM
    };

    // Allocate kernel stack for child with rowhammer guard pages
    const kstack_phys = pmm.allocPagesGuarded(process.KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        vp.vma_lock.release();
        vmm.destroyAddressSpace(child_pt);
        return -12;
    };
    const kstack_top = kstack_phys + process.KERNEL_STACK_PAGES * pmm.PAGE_SIZE;

    // Write stack canary at the bottom of the kernel stack
    const fork_canary: *u64 = @ptrFromInt(kstack_phys);
    fork_canary.* = pmm.STACK_CANARY;

    // Allocate child PID
    const child_pid = process.allocPid();

    // Initialize the child process directly in the process table.
    // This avoids putting the large Process struct (~55KB with 1024 VMAs)
    // on the kernel stack. initSlotForFork copies VMAs, fds, signals, CWD.
    const child = process.initSlotForFork(child_idx, parent);

    vp.vma_lock.release();
    child.pid = child_pid;
    child.tgid = child_pid;
    child.page_table = child_pt.toInt();
    child.kernel_stack_phys = kstack_phys;
    child.kernel_stack_top = kstack_top;
    child.kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES);
    child.parent_pid = parent.pid;
    // Read ACTUAL TPIDR_EL0 — parent.tls_base is only updated on context switch
    // and may be stale if the user changed TPIDR_EL0 since then (e.g. musl __init_tls).
    child.tls_base = asm volatile ("mrs %[tls], TPIDR_EL0"
        : [tls] "=r" (-> u64),
    );
    child.sig_pending = 0;

    // Save parent's context from the trap frame (GP + SIMD/FP)
    for (0..31) |i| {
        child.context.x[i] = frame.x[i];
    }
    child.context.sp = frame.sp;
    child.context.elr = frame.elr;
    child.context.spsr = frame.spsr;
    for (0..32) |i| {
        child.context.simd[i] = frame.simd[i];
    }
    child.context.fpcr = frame.fpcr;
    child.context.fpsr = frame.fpsr;

    // Child returns 0 from clone
    child.context.x[0] = 0;

    // If child_stack was specified, use it
    if (child_stack != 0) {
        child.context.sp = child_stack;
    }

    // Ensure all context stores are visible before marking ready.
    // Without this barrier, an idle CPU's timer tick could see .ready
    // state before the context is fully written (ARM64 store reordering).
    asm volatile ("dmb ish" ::: .{ .memory = true });

    process.registerPid(child_pid, child_idx);

    // Enqueue child on least-loaded CPU's runqueue + IPI
    scheduler.makeRunnable(child);

    // Parent returns child PID
    return @intCast(child_pid);
}

// ============================================================================
// wait4 — reap child processes
// ============================================================================

/// wait4(pid, wstatus, options, rusage) -> pid of reaped child
fn sysWait4(frame: *exception.TrapFrame) i64 {
    const wait_pid: i64 = @bitCast(frame.x[0]);
    const wstatus_addr = frame.x[1];
    const options = frame.x[2];
    const rusage_addr = frame.x[3];

    const WNOHANG: u64 = 1;

    const parent = scheduler.currentProcess() orelse return -1;

    // Search for zombie children
    var found_child = false;
    for (0..process.MAX_PROCESSES) |i| {
        const child = process.getProcess(i) orelse continue;
        if (child.parent_pid != parent.pid) continue;

        // If wait_pid > 0, only wait for specific PID
        if (wait_pid > 0 and child.pid != @as(u64, @intCast(wait_pid))) continue;

        found_child = true;

        if (child.state == .zombie) {
            const child_pid = child.pid;
            const exit_status = child.exit_status;

            // Write wstatus if pointer provided
            if (wstatus_addr != 0) {
                if (vmm.translate(vmm.PhysAddr.from(parent.page_table), vmm.VirtAddr.from(wstatus_addr)) != null) {
                    // Linux wstatus format: (exit_code << 8) for normal exit
                    const wstatus: u32 = @truncate((exit_status & 0xFF) << 8);
                    const buf: [*]u8 = @ptrFromInt(wstatus_addr);
                    writeU32(buf, 0, wstatus);
                }
            }

            // Zero-fill rusage struct if pointer provided (144 bytes on aarch64 Linux).
            // Without this, callers see garbage from the stack, causing @intCast panics
            // in Zig's getMaxRss() when rusage.maxrss is negative garbage.
            if (rusage_addr != 0) {
                if (vmm.translate(vmm.PhysAddr.from(parent.page_table), vmm.VirtAddr.from(rusage_addr)) != null) {
                    const ru_buf: [*]u8 = @ptrFromInt(rusage_addr);
                    for (0..144) |ri| {
                        ru_buf[ri] = 0;
                    }
                }
            }

            // Unpin executable inode if still pinned (crash paths skip sysExit)
            if (child.pinned_exec_inode) |pinned| {
                ext2.unpinInode(pinned);
                child.pinned_exec_inode = null;
            }

            // Destroy address space only if no other process shares it.
            // CLONE_VM threads share the same page_table. The last one
            // reaped must free it; others just clear their pointer.
            if (child.page_table != 0) {
                var shared = false;
                for (0..process.MAX_PROCESSES) |si| {
                    if (process.getProcess(si)) |other| {
                        if (other.pid != child_pid and other.page_table == child.page_table) {
                            shared = true;
                            break;
                        }
                    }
                }
                if (!shared) {
                    vmm.destroyAddressSpace(vmm.PhysAddr.from(child.page_table));
                }
                child.page_table = 0;
            }

            // Reap: free kernel stack (guarded allocation — includes buffer pages)
            if (child.kernel_stack_phys != 0) {
                if (child.kernel_stack_guard > 0) {
                    pmm.freePagesGuarded(child.kernel_stack_phys, process.KERNEL_STACK_PAGES, child.kernel_stack_guard);
                } else {
                    pmm.freePages(child.kernel_stack_phys, process.KERNEL_STACK_PAGES);
                }
            }

            // Free the process slot
            process.clearSlot(i);

            return @intCast(child_pid);
        }
    }

    if (!found_child) {
        return -10; // -ECHILD
    }

    if (options & WNOHANG != 0) {
        return 0; // No zombie yet, don't block
    }

    // Block until a child exits.
    // Back up ELR by 4 bytes to re-execute the SVC instruction on wake.
    // When woken (child exits → zombie), the replayed wait4 will find
    // the zombie child and return its PID normally.
    frame.elr -= 4;
    parent.state = .blocked_on_wait;
    scheduler.blockAndSchedule(frame);

    // After blockAndSchedule, the frame belongs to a DIFFERENT process.
    // handle() detects this via idx_before and won't overwrite x[0].
    return 0;
}

/// waitid(idtype, id, siginfo_t *infop, options, rusage *ru)
/// Like wait4 but with siginfo_t output. Required by musl's waitpid/waitid
/// and by the Zig build runner for child process management.
fn sysWaitid(frame: *exception.TrapFrame) i64 {
    const idtype = frame.x[0]; // P_ALL=0, P_PID=1, P_PGID=2
    const id: i64 = @bitCast(frame.x[1]);
    const infop_addr = frame.x[2];
    const options = frame.x[3];
    const rusage_addr = frame.x[4];

    const P_ALL: u64 = 0;
    const P_PID: u64 = 1;
    const WNOHANG: u64 = 1;
    const WEXITED: u64 = 4;
    const WNOWAIT: u64 = 0x01000000;

    // Must have at least WEXITED
    if (options & WEXITED == 0 and options & 2 == 0) return -22; // -EINVAL

    const parent = scheduler.currentProcess() orelse return -1;

    // Search for matching children
    var found_child = false;
    for (0..process.MAX_PROCESSES) |i| {
        const child = process.getProcess(i) orelse continue;
        if (child.parent_pid != parent.pid) continue;

        // Filter by idtype
        switch (idtype) {
            P_PID => {
                if (id > 0 and child.pid != @as(u64, @intCast(id))) continue;
            },
            P_ALL => {}, // match any child
            else => {}, // P_PGID etc — match any for now
        }

        found_child = true;

        if (child.state == .zombie and (options & WEXITED != 0)) {
            const child_pid = child.pid;
            const exit_status = child.exit_status;

            // Fill siginfo_t at infop_addr
            // Linux aarch64 siginfo_t layout (128 bytes):
            //   offset 0:  si_signo (i32) = SIGCHLD (17)
            //   offset 4:  si_errno (i32) = 0
            //   offset 8:  si_code  (i32) = CLD_EXITED (1)
            //   offset 12: padding
            //   offset 16: si_pid   (i32)
            //   offset 20: si_uid   (i32)
            //   offset 24: si_status (i32)
            if (infop_addr != 0) {
                // Demand-page the siginfo buffer if needed
                if (vmm.translate(vmm.PhysAddr.from(parent.page_table), vmm.VirtAddr.from(infop_addr)) == null) {
                    _ = exception.demandPageUser(infop_addr);
                }
                if (vmm.translate(vmm.PhysAddr.from(parent.page_table), vmm.VirtAddr.from(infop_addr)) != null) {
                    const buf: [*]u8 = @ptrFromInt(infop_addr);
                    // Zero the entire 128-byte siginfo_t
                    for (0..128) |zi| buf[zi] = 0;
                    // si_signo = SIGCHLD (17)
                    writeU32(buf, 0, 17);
                    // si_errno = 0 (already zero)
                    // si_code = CLD_EXITED (1)
                    writeU32(buf, 8, 1);
                    // si_pid
                    writeU32(buf, 16, @truncate(child_pid));
                    // si_uid = 0
                    // si_status = exit code
                    writeU32(buf, 24, @truncate(exit_status));
                }
            }

            // Zero-fill rusage if provided
            if (rusage_addr != 0) {
                if (vmm.translate(vmm.PhysAddr.from(parent.page_table), vmm.VirtAddr.from(rusage_addr)) != null) {
                    const ru_buf: [*]u8 = @ptrFromInt(rusage_addr);
                    for (0..144) |ri| ru_buf[ri] = 0;
                }
            }

            // Reap the child (unless WNOWAIT)
            if (options & WNOWAIT == 0) {
                if (child.pinned_exec_inode) |pinned| {
                    ext2.unpinInode(pinned);
                    child.pinned_exec_inode = null;
                }
                if (child.page_table != 0) {
                    var shared = false;
                    for (0..process.MAX_PROCESSES) |si| {
                        if (process.getProcess(si)) |other| {
                            if (other.pid != child_pid and other.page_table == child.page_table) {
                                shared = true;
                                break;
                            }
                        }
                    }
                    if (!shared) {
                        vmm.destroyAddressSpace(vmm.PhysAddr.from(child.page_table));
                    }
                    child.page_table = 0;
                }
                if (child.kernel_stack_phys != 0) {
                    if (child.kernel_stack_guard > 0) {
                        pmm.freePagesGuarded(child.kernel_stack_phys, process.KERNEL_STACK_PAGES, child.kernel_stack_guard);
                    } else {
                        pmm.freePages(child.kernel_stack_phys, process.KERNEL_STACK_PAGES);
                    }
                }
                process.clearSlot(i);
            }

            return 0; // waitid returns 0 on success (not child PID)
        }
    }

    if (!found_child) {
        return -10; // -ECHILD
    }

    if (options & WNOHANG != 0) {
        // No zombie yet — zero out siginfo to indicate no child changed state
        if (infop_addr != 0) {
            if (vmm.translate(vmm.PhysAddr.from(parent.page_table), vmm.VirtAddr.from(infop_addr)) == null) {
                _ = exception.demandPageUser(infop_addr);
            }
            if (vmm.translate(vmm.PhysAddr.from(parent.page_table), vmm.VirtAddr.from(infop_addr)) != null) {
                const buf: [*]u8 = @ptrFromInt(infop_addr);
                for (0..128) |zi| buf[zi] = 0;
            }
        }
        return 0;
    }

    // Block until a child exits
    frame.elr -= 4;
    parent.state = .blocked_on_wait;
    scheduler.blockAndSchedule(frame);
    return 0;
}

// ============================================================================
// mmap / munmap — A14
// ============================================================================

/// mmap flags
const MAP_ANONYMOUS: u32 = 0x20;
const MAP_PRIVATE: u32 = 0x02;
const MAP_FIXED: u32 = 0x10;
const MAP_SHARED: u32 = 0x01;

/// Protection flags
const PROT_READ: u32 = 0x1;
const PROT_WRITE: u32 = 0x2;
const PROT_EXEC: u32 = 0x4;
const PROT_NONE: u32 = 0x0;

/// mmap region bounds — prevent collision with stack and kernel space
const MMAP_REGION_START: u64 = 0x7F8000000000;
const MMAP_REGION_END: u64 = 0x7FFFF0000000;

/// For CLONE_VM threads, return the thread group leader to share VMA/mmap state.
/// Without this, each thread allocates from its own mmap_hint copy, causing
/// overlapping mappings in the shared page table → memory corruption.
fn getVmaProcess(proc: *process.Process) *process.Process {
    return process.getVmaOwner(proc);
}

/// mmap(addr, length, prot, flags, fd, offset) -> mapped_addr
fn sysMmap(frame: *exception.TrapFrame) i64 {
    const addr_hint = frame.x[0];
    const length = frame.x[1];
    const prot: u32 = @truncate(frame.x[2]);
    const flags: u32 = @truncate(frame.x[3]);
    const fd_raw: i64 = @bitCast(frame.x[4]);
    const offset = frame.x[5];

    const proc = scheduler.currentProcess() orelse return -1;
    const vp = getVmaProcess(proc);

    if (length == 0) return -22; // -EINVAL

    // W^X enforcement: reject simultaneous write+execute
    if ((prot & PROT_WRITE) != 0 and (prot & PROT_EXEC) != 0) return -22; // -EINVAL

    vp.vma_lock.acquire();
    defer vp.vma_lock.release();

    // Page-align length
    const aligned_len = (length + pmm.PAGE_SIZE - 1) & ~(pmm.PAGE_SIZE - 1);

    // Choose virtual address (use VMA owner's hint for consistent allocation)
    // Growth gap for top-down allocations: 64 MB reserved above each non-hint
    // allocation so mremap can grow in place.  Zig's InternPool has bugs in
    // the mremap MOVE path (stale pointers), so in-place growth is critical.
    // Hint-based allocations are honored exactly (the compiler expects this).
    const MMAP_GROWTH_GAP = 16384 * pmm.PAGE_SIZE; // 64 MB

    var map_addr: u64 = undefined;
    if (flags & MAP_FIXED != 0 and addr_hint != 0) {
        map_addr = addr_hint & ~@as(u64, 0xFFF);
    } else if (addr_hint != 0) {
        // Non-MAP_FIXED hint: honor it if usable
        const rounded = (addr_hint + pmm.PAGE_SIZE - 1) & ~@as(u64, 0xFFF);
        var hint_usable = rounded >= MMAP_REGION_START and rounded + aligned_len <= MMAP_REGION_END;
        if (hint_usable) {
            const hint_end = rounded + aligned_len;
            for (0..vma.MAX_VMAS) |vi| {
                if (!vp.vmas[vi].in_use) continue;
                if (vp.vmas[vi].start < hint_end and vp.vmas[vi].end > rounded) {
                    hint_usable = false;
                    break;
                }
            }
        }
        if (hint_usable) {
            map_addr = rounded;
            // Track for top-down fallback
            if (rounded < vp.mmap_hint) {
                vp.mmap_hint = rounded;
            }
        } else {
            // Hint unusable — top-down with gap
            const total2 = aligned_len + MMAP_GROWTH_GAP;
            if (vp.mmap_hint < MMAP_REGION_START + total2) {
                return -12;
            }
            vp.mmap_hint -= total2;
            map_addr = vp.mmap_hint; // allocation at bottom, gap above
        }
    } else {
        // No hint — top-down with gap above for mremap growth
        const total = aligned_len + MMAP_GROWTH_GAP;
        if (vp.mmap_hint < MMAP_REGION_START + total) {
            return -12;
        }
        vp.mmap_hint -= total;
        map_addr = vp.mmap_hint; // allocation at bottom, gap above
    }

    // Validate address stays in mmap region (allow MAP_FIXED anywhere in user space)
    if (flags & MAP_FIXED == 0 and (map_addr < MMAP_REGION_START or map_addr + aligned_len > MMAP_REGION_END)) {
        return -12;
    }

    // MAP_FIXED: handle overlapping VMAs and unmap old pages
    if (flags & MAP_FIXED != 0) {
        const map_end = map_addr + aligned_len;

        // Remove/split/trim overlapping VMAs
        if (!vma.handleMapFixedOverlap(&vp.vmas, map_addr, map_end)) {
            return -12; // -ENOMEM (no VMA slot for split)
        }

        // Unmap old physical pages — zero PTE + TLBI broadcast BEFORE freeing
        var page: u64 = map_addr;
        while (page < map_end) : (page += pmm.PAGE_SIZE) {
            if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page))) |pte| {
                if (pte.isValid()) {
                    const phys = pte.getPhysAddr();
                    const is_cow = pte.isCow();
                    const is_user = pte.isUser();
                    vmm.unmapPage(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page));
                    vmm.invalidatePage(vmm.VirtAddr.from(page)); // Broadcast TLBI to all CPUs + DSB SY
                    if (is_cow) {
                        _ = pmm.decRef(phys);
                    } else if (is_user) {
                        pmm.freePage(phys);
                    }
                }
            }
        }
    }

    // Build VMA flags
    const vma_flags = vma.VmaFlags{
        .readable = (prot & PROT_READ) != 0,
        .writable = (prot & PROT_WRITE) != 0,
        .executable = (prot & PROT_EXEC) != 0,
        .user = true,
        .shared = (flags & MAP_SHARED) != 0,
        .file_backed = (flags & MAP_ANONYMOUS == 0),
    };

    if (flags & MAP_ANONYMOUS != 0) {
        // Anonymous mapping — demand paging allocates zero pages on fault
        if (vma.addVma(&vp.vmas, map_addr, map_addr + aligned_len, vma_flags) == null) {
            uart.print("[mmap] addVma FAIL P{} addr={x} len={x}\n", .{ proc.pid, map_addr, aligned_len });
            return -12; // -ENOMEM
        }
    } else {
        // File-backed mmap — resolve fd and create file-backed VMA
        if (fd_raw < 0) return -9; // -EBADF
        const fd_num: u64 = @intCast(fd_raw);
        const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9;

        // Page-align offset
        const page_offset = offset & ~@as(u64, 0xFFF);

        // Create file-backed VMA — demand paging reads from file on fault.
        // addFileVma increments ref_count so the FileDescription stays alive
        // even after the fd is closed (linker pattern: mmap then close fd).
        if (vma.addFileVma(&vp.vmas, map_addr, map_addr + aligned_len, vma_flags, desc, page_offset) == null) {
            uart.print("[mmap] addFileVma FAIL P{} addr={x} len={x}\n", .{ proc.pid, map_addr, aligned_len });
            return -12; // -ENOMEM
        }
    }


    return @intCast(map_addr);
}

/// Write back MAP_SHARED dirty pages to the backing file.
/// Must be called BEFORE the VMA or pages are destroyed.
fn syncSharedPages(page_table: u64, v: *const vma.Vma) void {
    if (!v.flags.shared or !v.flags.file_backed) return;
    const desc = v.file orelse return;
    const write_fn = desc.inode.ops.write orelse return;

    var page_addr = v.start;
    while (page_addr < v.end) : (page_addr += pmm.PAGE_SIZE) {
        const pte = vmm.getPTE(vmm.PhysAddr.from(page_table), vmm.VirtAddr.from(page_addr)) orelse continue;
        if (!pte.isValid() or !pte.isUser()) continue;

        const phys = pte.getPhysAddr();
        const page_ptr: [*]const u8 = @ptrFromInt(phys);

        const file_off = v.file_offset + (page_addr - v.start);
        const remaining = v.end - page_addr;
        const chunk: usize = if (remaining > pmm.PAGE_SIZE) pmm.PAGE_SIZE else @truncate(remaining);

        var tmp_desc = vfs.FileDescription{
            .inode = desc.inode,
            .offset = file_off,
            .flags = vfs.O_WRONLY,
            .ref_count = 1,
            .in_use = true,
        };
        _ = write_fn(&tmp_desc, page_ptr, chunk);
    }
}

/// Write back all MAP_SHARED file-backed VMAs for a process.
fn syncAllSharedVmas(page_table: u64, vmas: *vma.VmaList) void {
    for (vmas) |*v| {
        if (!v.in_use) continue;
        if (!v.flags.shared or !v.flags.file_backed) continue;
        syncSharedPages(page_table, v);
    }
}

/// munmap(addr, length) -> 0
fn sysMunmap(frame: *exception.TrapFrame) i64 {
    const addr = frame.x[0];
    const length = frame.x[1];

    const proc = scheduler.currentProcess() orelse return -1;
    const vp = getVmaProcess(proc);

    if (addr & 0xFFF != 0) return -22; // -EINVAL, must be page-aligned

    vp.vma_lock.acquire();
    defer vp.vma_lock.release();

    const aligned_len = (length + pmm.PAGE_SIZE - 1) & ~(pmm.PAGE_SIZE - 1);
    const unmap_end = addr + aligned_len;

    // Write back MAP_SHARED pages BEFORE removing VMAs (data must reach the file)
    for (&vp.vmas) |*v| {
        if (!v.in_use) continue;
        if (!v.flags.shared or !v.flags.file_backed) continue;
        // Check overlap with unmap range
        if (v.end <= addr or v.start >= unmap_end) continue;
        syncSharedPages(proc.page_table, v);
    }

    // Remove/trim/split VMAs overlapping the unmapped range (handles partial unmaps)
    _ = vma.handleMapFixedOverlap(&vp.vmas, addr, unmap_end);

    // Unmap pages in the range — zero PTE, broadcast TLBI, THEN free physical page.
    // Without TLBI between unmap and free, another CPU with stale TLB entries can
    // read/write the freed physical page after PMM reuses it (SMP data corruption).
    var page: u64 = addr;
    while (page < addr + aligned_len) : (page += pmm.PAGE_SIZE) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page)) != null) {
            if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page))) |pte| {
                const phys = pte.getPhysAddr();
                const is_cow = pte.isCow();
                vmm.unmapPage(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page));
                vmm.invalidatePage(vmm.VirtAddr.from(page)); // Broadcast TLBI to all CPUs + DSB SY
                if (is_cow) {
                    _ = pmm.decRef(phys);
                } else {
                    pmm.freePage(phys);
                }
            } else {
                vmm.unmapPage(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page));
                vmm.invalidatePage(vmm.VirtAddr.from(page));
            }
        }
    }

    return 0;
}

/// mremap(old_addr, old_size, new_size, flags, new_addr) -> new_addr or error
const MREMAP_MAYMOVE: u64 = 1;

fn sysMremap(frame: *exception.TrapFrame) i64 {
    const old_addr = frame.x[0];
    const old_size = frame.x[1];
    const new_size = frame.x[2];
    const flags = frame.x[3];

    if (old_addr & 0xFFF != 0 or old_size == 0 or new_size == 0) return -22; // -EINVAL

    const proc = scheduler.currentProcess() orelse return -3;

    const vp = getVmaProcess(proc);

    vp.vma_lock.acquire();
    defer vp.vma_lock.release();

    const aligned_old = (old_size + pmm.PAGE_SIZE - 1) & ~(pmm.PAGE_SIZE - 1);
    const aligned_new = (new_size + pmm.PAGE_SIZE - 1) & ~(pmm.PAGE_SIZE - 1);

    // Find VMA covering old_addr
    const v = vma.findVma(&vp.vmas, old_addr) orelse return -14; // -EFAULT

    if (aligned_new <= aligned_old) {
        // Shrink: unmap and free excess pages
        var page: u64 = old_addr + aligned_new;
        while (page < old_addr + aligned_old) : (page += pmm.PAGE_SIZE) {
            if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page)) != null) {
                if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page))) |pte| {
                    const phys = pte.getPhysAddr();
                    const is_cow = pte.isCow();
                    vmm.unmapPage(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page));
                    vmm.invalidatePage(vmm.VirtAddr.from(page));
                    if (is_cow) {
                        _ = pmm.decRef(phys);
                    } else {
                        pmm.freePage(phys);
                    }
                } else {
                    vmm.unmapPage(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page));
                    vmm.invalidatePage(vmm.VirtAddr.from(page));
                }
            }
        }
        for (0..vma.MAX_VMAS) |i| {
            if (vp.vmas[i].in_use and vp.vmas[i].start == v.start and vp.vmas[i].end == v.end) {
                vp.vmas[i].end = old_addr + aligned_new;
                break;
            }
        }
        return @intCast(old_addr);
    }

    // Grow: check if can extend in place
    const new_end = old_addr + aligned_new;
    var can_grow = true;
    for (0..vma.MAX_VMAS) |i| {
        const other = &vp.vmas[i];
        if (!other.in_use) continue;
        if (other.start == v.start and other.end == v.end) continue;
        if (other.start < new_end and other.end > old_addr + aligned_old) {
            can_grow = false;
            break;
        }
    }

    if (can_grow) {
        for (0..vma.MAX_VMAS) |i| {
            if (vp.vmas[i].in_use and vp.vmas[i].start == v.start and vp.vmas[i].end == v.end) {
                vp.vmas[i].end = new_end;
                break;
            }
        }
        return @intCast(old_addr);
    }

    // Move (MAYMOVE)
    if (flags & MREMAP_MAYMOVE == 0) return -12; // -ENOMEM

    if (vp.mmap_hint < MMAP_REGION_START + aligned_new) return -12;
    vp.mmap_hint -= aligned_new;
    const new_addr_val = vp.mmap_hint;

    if (vma.addVma(&vp.vmas, new_addr_val, new_addr_val + aligned_new, v.flags) == null) {
        return -12;
    }

    // Move page table entries — same physical pages, new virtual addresses.
    var moved_pages: u64 = 0;
    var unmapped_pages: u64 = 0;
    var offset: u64 = 0;
    while (offset < aligned_old) : (offset += pmm.PAGE_SIZE) {
        if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(old_addr + offset))) |pte| {
            if (pte.isValid()) {
                const phys = pte.getPhysAddr();
                vmm.mapPage(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(new_addr_val + offset), vmm.PhysAddr.from(phys), .{
                    .user = v.flags.user,
                    .writable = v.flags.writable,
                    .executable = v.flags.executable,
                }) catch break;
                if (pte.isCow()) {
                    if (vmm.getPTE(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(new_addr_val + offset))) |new_pte| {
                        new_pte.raw |= vmm.PTE_COW;
                    }
                }
                pte.raw = 0;
                vmm.invalidatePage(vmm.VirtAddr.from(old_addr + offset));
                moved_pages += 1;
            } else {
                unmapped_pages += 1;
            }
        } else {
            unmapped_pages += 1;
        }
    }

    _ = vma.removeVma(&vp.vmas, old_addr, old_addr + aligned_old);

    return @intCast(new_addr_val);
}

// ============================================================================
// Thread creation (CLONE_VM) — A15
// ============================================================================

fn cloneThread(frame: *exception.TrapFrame, parent: *process.Process, flags: u64, child_stack: u64, parent_tidptr: u64, child_tidptr: u64) i64 {
    if (child_stack == 0) return -22; // -EINVAL: threads require a stack

    const child_idx = process.findFreeSlot() orelse return -11; // -EAGAIN

    const kstack_phys = pmm.allocPagesGuarded(process.KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse return -12;
    const kstack_top = kstack_phys + process.KERNEL_STACK_PAGES * pmm.PAGE_SIZE;

    // Write stack canary at the bottom of the kernel stack
    const clone_canary: *u64 = @ptrFromInt(kstack_phys);
    clone_canary.* = pmm.STACK_CANARY;

    const child_tid = process.allocPid();

    // Initialize directly in the process table to avoid putting the large
    // Process struct (~200KB with VMAs) on the 256KB kernel stack.
    const child = process.initSlotForClone(child_idx, parent);
    child.pid = child_tid;
    child.tgid = if (flags & CLONE_THREAD != 0) parent.tgid else child_tid;
    child.kernel_stack_phys = kstack_phys;
    child.kernel_stack_top = kstack_top;
    child.kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES);
    child.parent_pid = parent.pid;
    child.tls_base = if (flags & CLONE_SETTLS != 0) frame.x[3] else parent.tls_base;
    child.cwd_len = parent.cwd_len;

    // CLONE_CHILD_CLEARTID: set clear_child_tid for futex wakeup on exit (pthread_join)
    if (flags & CLONE_CHILD_CLEARTID != 0) {
        child.clear_child_tid = child_tidptr;
    }

    for (0..256) |i| {
        child.cwd[i] = parent.cwd[i];
    }

    // Share FDs (VMAs already copied by initSlotForClone).
    // Atomic increment: parent/sibling on another CPU may close FDs concurrently.
    for (0..fd_table.MAX_FDS) |i| {
        if (parent.fds[i]) |desc| {
            _ = @atomicRmw(u32, &desc.ref_count, .Add, 1, .acq_rel);
            child.fds[i] = desc;
        } else {
            child.fds[i] = null;
        }
    }

    // Copy context from trap frame, child returns 0
    for (0..31) |i| {
        child.context.x[i] = frame.x[i];
    }
    child.context.sp = child_stack; // Thread gets its own stack
    child.context.elr = frame.elr;
    child.context.spsr = frame.spsr;
    for (0..32) |i| {
        child.context.simd[i] = frame.simd[i];
    }
    child.context.fpcr = frame.fpcr;
    child.context.fpsr = frame.fpsr;
    child.context.x[0] = 0; // Child returns 0

    // Copy signal state
    child.sig_actions = parent.sig_actions;
    child.sig_mask = parent.sig_mask;
    child.sig_pending = 0;

    // CLONE_PARENT_SETTID: write child TID to parent's address space
    if (flags & CLONE_PARENT_SETTID != 0 and parent_tidptr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(parent.page_table), vmm.VirtAddr.from(parent_tidptr))) |_| {
            const ptr: *align(1) u32 = @ptrFromInt(parent_tidptr);
            ptr.* = @truncate(child_tid);
        }
    }

    // CLONE_CHILD_SETTID: write child TID to shared address space
    if (flags & CLONE_CHILD_SETTID != 0 and child_tidptr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(parent.page_table), vmm.VirtAddr.from(child_tidptr))) |_| {
            const ptr: *align(1) u32 = @ptrFromInt(child_tidptr);
            ptr.* = @truncate(child_tid);
        }
    }

    // Ensure all context/state stores are visible before marking ready.
    // Without this barrier, an idle CPU could see .ready before context
    // is fully written and try to schedule the thread with garbage state.
    asm volatile ("dmb ish" ::: .{ .memory = true });

    process.registerPid(child_tid, child_idx);

    // Enqueue child thread on least-loaded CPU's runqueue + IPI
    scheduler.makeRunnable(child);

    return @intCast(child_tid);
}

// ============================================================================
// pipe2, futex, kill, sigaction, sigprocmask — A15/A16
// ============================================================================

/// pipe2(pipefd[2], flags) -> 0
fn sysPipe2(frame: *exception.TrapFrame) i64 {
    const pipefd_addr = frame.x[0];
    const flags: u32 = @truncate(frame.x[1]);

    const proc = scheduler.currentProcess() orelse return -1;
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(pipefd_addr)) == null) return -14;

    const result = pipe.createPipe() orelse return -24; // -EMFILE

    // Propagate O_NONBLOCK/O_CLOEXEC from flags into file descriptions.
    // createPipe sets O_RDONLY/O_WRONLY; OR in the requested flags.
    const extra = flags & (vfs.O_NONBLOCK | vfs.O_CLOEXEC);
    result.read_desc.flags |= extra;
    result.write_desc.flags |= extra;

    const rfd = fd_table.fdAlloc(&proc.fds, result.read_desc) orelse {
        vfs.releaseFileDescription(result.read_desc);
        vfs.releaseFileDescription(result.write_desc);
        return -24;
    };
    const wfd = fd_table.fdAlloc(&proc.fds, result.write_desc) orelse {
        _ = fd_table.fdClose(&proc.fds, rfd);
        vfs.releaseFileDescription(result.write_desc);
        return -24;
    };

    // Set per-fd cloexec flags (O_CLOEXEC is per-fd, not per-FileDescription)
    if (flags & vfs.O_CLOEXEC != 0) {
        proc.fd_cloexec[rfd] = true;
        proc.fd_cloexec[wfd] = true;
    }

    // Write fds to user buffer
    const buf: [*]u8 = @ptrFromInt(pipefd_addr);
    writeU32(buf, 0, @truncate(rfd));
    writeU32(buf, 4, @truncate(wfd));

    return 0;
}

/// futex(uaddr, futex_op, val, val2/timeout, uaddr2, val3) -> result
fn sysFutex(frame: *exception.TrapFrame) i64 {
    const uaddr = frame.x[0];
    const futex_op = frame.x[1];
    const val = frame.x[2];
    const val2 = frame.x[3]; // timeout for WAIT, max_requeue for REQUEUE
    const uaddr2 = frame.x[4]; // target address for REQUEUE
    const val3 = frame.x[5]; // expected value for CMP_REQUEUE

    const proc = scheduler.currentProcess() orelse return -1;

    const res = futex.sysFutex(uaddr, futex_op, val, val2, uaddr2, val3, proc);

    // Special return: -516 means FUTEX_WAIT succeeded, need to block.
    // Unlike pipe/socket reads which replay the SVC on wake, futex MUST
    // return to userspace so the caller can re-check its actual condition
    // (mutex state, work queue, etc.). Set X0=0 (success) before blocking.
    if (res == -516) {
        frame.x[0] = 0; // futex returns 0 on wake
        scheduler.blockAndSchedule(frame);
        return 0;
    }

    return res;
}

/// kill(pid, sig)
fn sysKill(frame: *exception.TrapFrame) i64 {
    return signal.sysKill(frame.x[0], frame.x[1]);
}

/// rt_sigaction(signum, act, oldact, sigsetsize)
fn sysRtSigaction(frame: *exception.TrapFrame) i64 {
    const proc = scheduler.currentProcess() orelse return -1;
    return signal.sysRtSigaction(frame.x[0], frame.x[1], frame.x[2], proc);
}

/// rt_sigprocmask(how, set, oldset, sigsetsize)
fn sysRtSigprocmask(frame: *exception.TrapFrame) i64 {
    const proc = scheduler.currentProcess() orelse return -1;
    return signal.sysRtSigprocmask(frame.x[0], frame.x[1], frame.x[2], proc);
}

// ============================================================================
// Socket syscalls — A18/A19
// ============================================================================

/// socket(domain, type, protocol) — nr 198
fn sysSocket(frame: *exception.TrapFrame) i64 {
    const domain: u16 = @truncate(frame.x[0]);
    const sock_type: u16 = @truncate(frame.x[1]);
    const protocol: u16 = @truncate(frame.x[2]);

    const current = scheduler.currentProcess() orelse return -3; // -ESRCH

    if (domain != socket.AF_INET) return -97; // -EAFNOSUPPORT

    if (sock_type != socket.SOCK_STREAM and sock_type != socket.SOCK_DGRAM and sock_type != socket.SOCK_RAW) {
        return -22; // -EINVAL
    }

    const sock_idx = socket.allocSocket(domain, sock_type, protocol) orelse return -23; // -ENFILE

    // Create a VFS FileDescription for this socket
    const desc = vfs.allocFileDescription() orelse return -23;
    desc.inode = socket.getSocketInode(sock_idx);
    desc.flags = vfs.O_RDWR;
    desc.offset = 0;

    const fd_num = fd_table.fdAlloc(&current.fds, desc) orelse {
        vfs.releaseFileDescription(desc);
        return -24; // -EMFILE
    };

    return @intCast(fd_num);
}

/// connect(sockfd, addr, addrlen) — nr 203
fn sysConnect(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const addr_ptr = frame.x[1];
    const addrlen = frame.x[2];

    const current = scheduler.currentProcess() orelse return -3;

    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9; // -EBADF

    if (addrlen < 16) return -14; // -EFAULT
    if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(addr_ptr)) == null) return -14;

    // Read sockaddr_in from user space (identity mapped via TTBR0)
    const sa_buf: [*]const u8 = @ptrFromInt(addr_ptr);

    // Parse sockaddr_in: family(2) + port(2 BE) + addr(4 BE) + zero(8)
    const sa_family: u16 = @as(u16, sa_buf[0]) | (@as(u16, sa_buf[1]) << 8);
    if (sa_family != socket.AF_INET) return -97; // -EAFNOSUPPORT

    const port = ethernet.getU16BE(sa_buf[2..4]);
    const ip = ethernet.getU32BE(sa_buf[4..8]);

    // Find the socket from the fd's inode
    const sock_idx = socket.getSocketIndexFromInode(desc.inode) orelse return -9;
    const sock = socket.getSocket(sock_idx) orelse return -9;

    if (sock.sock_type == socket.SOCK_STREAM) {
        // TCP connect (blocking)
        const conn = tcp.getConnection(sock.tcp_conn_idx) orelse return -111; // -ECONNREFUSED

        // Check if already connected (syscall restart after wake)
        if (conn.state == .established) {
            sock.remote_ip = ip;
            sock.remote_port = port;
            return 0;
        }

        // If connection failed (RST received), report error
        if (conn.state == .closed and sock.remote_ip != 0) {
            return -111; // -ECONNREFUSED
        }

        // If not already connecting, initiate the handshake
        if (conn.state != .syn_sent) {
            if (!tcp.connect(sock.tcp_conn_idx, ip, port)) {
                return -111;
            }
        }

        // Block until connection established or failed.
        // Replay SVC on wake: the check at line 1246 will detect .established.
        conn.waiting_pid = current.pid;
        current.state = .blocked_on_net;
        frame.elr -= 4;
        scheduler.blockAndSchedule(frame);
        return 0;
    } else if (sock.sock_type == socket.SOCK_DGRAM) {
        // UDP connect just sets destination
        sock.remote_ip = ip;
        sock.remote_port = port;
        return 0;
    } else {
        // Raw socket — just store remote IP
        sock.remote_ip = ip;
        return 0;
    }
}

/// sendto(sockfd, buf, len, flags, dest_addr, addrlen) — nr 206
fn sysSendto(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const buf_addr = frame.x[1];
    const len = frame.x[2];
    // flags = frame.x[3]
    const dest_addr = frame.x[4];
    const dest_addrlen = frame.x[5];

    const current = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9;

    if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(buf_addr)) == null) return -14;

    const sock_idx = socket.getSocketIndexFromInode(desc.inode) orelse return -9;
    const sock = socket.getSocket(sock_idx) orelse return -9;

    // Determine destination
    var dst_ip: u32 = sock.remote_ip;
    var dst_port: u16 = sock.remote_port;

    if (dest_addr != 0 and dest_addrlen >= 16) {
        if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(dest_addr)) != null) {
            const sa_buf: [*]const u8 = @ptrFromInt(dest_addr);
            dst_port = ethernet.getU16BE(sa_buf[2..4]);
            dst_ip = ethernet.getU32BE(sa_buf[4..8]);
        }
    }

    // Read user data directly (TTBR0 maps user pages)
    const actual_len: usize = if (len > 1472) 1472 else @truncate(len);
    var send_buf: [1472]u8 = undefined;
    const src: [*]const u8 = @ptrFromInt(buf_addr);
    for (0..actual_len) |i| {
        send_buf[i] = src[i];
    }

    if (sock.sock_type == socket.SOCK_DGRAM) {
        if (udp.send(sock.bound_port, dst_ip, dst_port, send_buf[0..actual_len])) {
            return @intCast(actual_len);
        }
        return -5; // -EIO
    } else if (sock.sock_type == socket.SOCK_STREAM) {
        const sent = tcp.sendData(sock.tcp_conn_idx, send_buf[0..actual_len]);
        if (sent >= 0) {
            return @as(i64, sent);
        }
        return -5; // -EIO
    } else if (sock.sock_type == socket.SOCK_RAW and sock.protocol == socket.IPPROTO_ICMP) {
        // Raw ICMP send — data is a full ICMP packet
        if (ipv4.send(ipv4.PROTO_ICMP, dst_ip, send_buf[0..actual_len])) {
            return @intCast(actual_len);
        }
        return -5;
    }
    return -22; // -EINVAL
}

/// recvfrom(sockfd, buf, len, flags, src_addr, addrlen) — nr 207
fn sysRecvfrom(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const buf_addr = frame.x[1];
    const len = frame.x[2];
    // flags = frame.x[3], src_addr = frame.x[4], addrlen = frame.x[5]

    const current = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9;

    if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(buf_addr)) == null) return -14;

    const sock_idx = socket.getSocketIndexFromInode(desc.inode) orelse return -9;
    const sock = socket.getSocket(sock_idx) orelse return -9;

    // Read from socket
    var kernel_buf: [4096]u8 = undefined;
    const read_len: usize = if (len > 4096) 4096 else @truncate(len);

    var result: isize = 0;

    if (sock.sock_type == socket.SOCK_STREAM) {
        result = tcp.recvData(sock.tcp_conn_idx, kernel_buf[0..read_len]);
    } else if (sock.sock_type == socket.SOCK_DGRAM) {
        if (sock.udp_rx_count == 0) {
            sock.blocked_pid = current.pid;
            result = -11; // EAGAIN
        } else {
            const to_copy: usize = if (read_len > sock.udp_rx_count) @as(usize, sock.udp_rx_count) else read_len;
            for (0..to_copy) |i| {
                kernel_buf[i] = sock.udp_rx_buf[(sock.udp_rx_head +% @as(u16, @truncate(i))) % 2048];
            }
            sock.udp_rx_head = (sock.udp_rx_head +% @as(u16, @truncate(to_copy))) % 2048;
            sock.udp_rx_count -= @truncate(to_copy);
            result = @intCast(to_copy);
        }
    } else if (sock.sock_type == socket.SOCK_RAW and sock.protocol == socket.IPPROTO_ICMP) {
        if (!sock.icmp_rx_ready) {
            sock.blocked_pid = current.pid;
            result = -11; // EAGAIN
        } else {
            const to_copy: usize = if (read_len > sock.icmp_rx_len) @as(usize, sock.icmp_rx_len) else read_len;
            for (0..to_copy) |i| {
                kernel_buf[i] = sock.icmp_rx_buf[i];
            }
            sock.icmp_rx_ready = false;
            result = @intCast(to_copy);
        }
    }

    if (result == -11) {
        // EAGAIN — block until data arrives.
        // Replay SVC on wake so the recv is re-attempted with data present.
        if (sock.sock_type == socket.SOCK_STREAM) {
            if (tcp.getConnection(sock.tcp_conn_idx)) |conn| {
                conn.waiting_pid = current.pid;
            }
        }
        current.state = .blocked_on_net;
        frame.elr -= 4;
        scheduler.blockAndSchedule(frame);
        return 0;
    }

    if (result < 0) {
        return @as(i64, result);
    }

    // Copy to user (TTBR0 maps user pages)
    const bytes: usize = @intCast(result);
    if (bytes > 0) {
        const dst: [*]u8 = @ptrFromInt(buf_addr);
        for (0..bytes) |i| {
            dst[i] = kernel_buf[i];
        }
        return @intCast(bytes);
    }
    return 0;
}

/// bind(sockfd, addr, addrlen) — nr 200
fn sysBind(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const addr_ptr = frame.x[1];
    const addrlen = frame.x[2];

    const current = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9;

    if (addrlen < 16) return -14;
    if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(addr_ptr)) == null) return -14;

    const sa_buf: [*]const u8 = @ptrFromInt(addr_ptr);
    const port = ethernet.getU16BE(sa_buf[2..4]);

    const sock_idx = socket.getSocketIndexFromInode(desc.inode) orelse return -9;
    const sock = socket.getSocket(sock_idx) orelse return -9;

    sock.bound_port = port;
    return 0;
}

/// shutdown(sockfd, how) — nr 210
fn sysShutdown(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];

    const current = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9;

    const sock_idx = socket.getSocketIndexFromInode(desc.inode) orelse return -9;
    const sock = socket.getSocket(sock_idx) orelse return -9;

    if (sock.sock_type == socket.SOCK_STREAM) {
        tcp.close(sock.tcp_conn_idx);
    }

    return 0;
}

// ============================================================================
// Zero-copy networking — A20
// ============================================================================

/// net_attach(nic_idx, queue_idx) — nr 280
/// Creates a shared ring region and maps it into the calling process.
/// Returns the userspace virtual address of the shared ring, or -errno.
/// The shared region layout is described in net_ring.zig.
fn sysNetAttach(frame: *exception.TrapFrame) i64 {
    _ = frame.x[0]; // nic_idx (reserved for multi-NIC, currently ignored)
    _ = frame.x[1]; // queue_idx (reserved for multi-queue, currently ignored)

    const current = scheduler.currentProcess() orelse return -3; // -ESRCH

    if (!nic.isInitialized()) return -19; // -ENODEV

    const addr = net_ring.attach(current) orelse return -12; // -ENOMEM

    return @bitCast(addr);
}

// ============================================================================
// Identity syscalls — A24 (syscall parity)
// ============================================================================

/// getuid() -> real uid
fn sysGetuid() i64 {
    if (scheduler.currentProcess()) |proc| return proc.uid else return 0;
}

/// geteuid() -> effective uid
fn sysGetEuid() i64 {
    if (scheduler.currentProcess()) |proc| return proc.euid else return 0;
}

/// getgid() -> real gid
fn sysGetgid() i64 {
    if (scheduler.currentProcess()) |proc| return proc.gid else return 0;
}

/// getegid() -> effective gid
fn sysGetEgid() i64 {
    if (scheduler.currentProcess()) |proc| return proc.egid else return 0;
}

/// getgroups(size, list) -> number of supplementary groups
/// BusyBox `id` calls this with size>0 and expects gid_t values written to list.
fn sysGetgroups(frame: *exception.TrapFrame) i64 {
    const size: i64 = @bitCast(frame.x[0]);
    const list_addr = frame.x[1];

    // size == 0: just return the number of supplementary groups
    if (size == 0) return 1;

    if (size < 0) return -22; // -EINVAL

    const proc = scheduler.currentProcess() orelse return -1;

    // Ensure the user buffer is mapped (gid_t = u32 = 4 bytes)
    if (!ensureUserPages(proc.page_table, list_addr, 4)) {
        return -14; // -EFAULT
    }

    // Write gid 0 (root) as the single supplementary group
    const gid_ptr: *align(1) u32 = @ptrFromInt(list_addr);
    gid_ptr.* = 0;

    return 1; // 1 group written
}

/// setuid(uid) -> 0 or -EPERM
fn sysSetuid(frame: *exception.TrapFrame) i64 {
    const target: u16 = @truncate(frame.x[0]);
    const proc = scheduler.currentProcess() orelse return -3; // -ESRCH
    if (proc.euid == 0) {
        proc.uid = target;
        proc.euid = target;
    } else if (target == proc.uid) {
        proc.euid = target;
    } else {
        return -1; // -EPERM
    }
    return 0;
}

/// setgid(gid) -> 0 or -EPERM
fn sysSetgid(frame: *exception.TrapFrame) i64 {
    const target: u16 = @truncate(frame.x[0]);
    const proc = scheduler.currentProcess() orelse return -3;
    if (proc.euid == 0) {
        proc.gid = target;
        proc.egid = target;
    } else if (target == proc.gid) {
        proc.egid = target;
    } else {
        return -1; // -EPERM
    }
    return 0;
}

// ============================================================================
// Process group syscalls
// ============================================================================

/// setpgid(pid, pgid) -> 0 or -ESRCH
fn sysSetpgid(frame: *exception.TrapFrame) i64 {
    const target_pid = frame.x[0];
    const new_pgid = frame.x[1];

    const current = scheduler.currentProcess() orelse return -3;

    const actual_pid: u64 = if (target_pid == 0) current.pid else target_pid;
    const actual_pgid: u32 = @truncate(if (new_pgid == 0) actual_pid else new_pgid);

    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.pid == actual_pid) {
                if (p.pid != current.pid and p.parent_pid != current.pid) {
                    return -3; // -ESRCH
                }
                p.pgid = actual_pgid;
                return 0;
            }
        }
    }
    return -3; // -ESRCH
}

/// getpgid(pid) -> pgid or -ESRCH. pid=0 means self.
fn sysGetpgid(frame: *exception.TrapFrame) i64 {
    const target_pid = frame.x[0];
    const current = scheduler.currentProcess() orelse return -3;

    if (target_pid == 0) {
        return @intCast(current.pgid);
    }

    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.pid == target_pid) {
                return @intCast(p.pgid);
            }
        }
    }
    return -3; // -ESRCH
}

// ============================================================================
// File syscalls
// ============================================================================

/// ftruncate(fd, length) -> 0
/// flock(fd, operation) -> 0 or -errno
/// Advisory file locking: LOCK_SH (1), LOCK_EX (2), LOCK_UN (8), LOCK_NB (4).
fn sysFlock(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const operation = frame.x[1];

    const LOCK_SH: u64 = 1;
    const LOCK_EX: u64 = 2;
    const LOCK_NB: u64 = 4;
    const LOCK_UN: u64 = 8;

    const proc = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9; // -EBADF

    const op = operation & ~LOCK_NB;
    const non_blocking = (operation & LOCK_NB) != 0;

    if (op == LOCK_UN) {
        desc.lock_type = 0;
        return 0;
    }

    if (op != LOCK_SH and op != LOCK_EX) return -22; // -EINVAL

    const wanted: u8 = if (op == LOCK_SH) 1 else 2;

    if (vfs.checkFlockConflict(desc, wanted)) {
        if (non_blocking) return -11; // -EAGAIN
        // Blocking: in a single-user OS, just succeed (avoid deadlock)
    }

    desc.lock_type = wanted;
    return 0;
}

// ============================================================================
// fcntl record locking (F_SETLK / F_GETLK / F_SETLKW)
// ============================================================================

const F_RDLCK: u16 = 0;
const F_WRLCK: u16 = 1;
const F_UNLCK: u16 = 2;

const MAX_RECORD_LOCKS: usize = 128;

const RecordLock = struct {
    in_use: bool,
    ino: u64,
    pid: u64,
    start: u64,
    len: u64, // 0 = to end of file
    lock_type: u16, // F_RDLCK or F_WRLCK
};

var record_locks: [MAX_RECORD_LOCKS]RecordLock = [_]RecordLock{.{
    .in_use = false,
    .ino = 0,
    .pid = 0,
    .start = 0,
    .len = 0,
    .lock_type = 0,
}} ** MAX_RECORD_LOCKS;

/// Read struct flock from userspace (aarch64 layout)
/// struct flock { short l_type; short l_whence; long l_start; long l_len; int l_pid; }
fn readFlock(addr: u64, proc: anytype) struct { l_type: u16, l_whence: u16, l_start: u64, l_len: u64, l_pid: u32 } {
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(addr)) == null) return .{ .l_type = 0, .l_whence = 0, .l_start = 0, .l_len = 0, .l_pid = 0 };
    const p: [*]const u8 = @ptrFromInt(addr);
    const l_type: u16 = @as(u16, p[0]) | (@as(u16, p[1]) << 8);
    const l_whence: u16 = @as(u16, p[2]) | (@as(u16, p[3]) << 8);
    var l_start: u64 = 0;
    for (0..8) |i| l_start |= @as(u64, p[8 + i]) << @intCast(i * 8);
    var l_len: u64 = 0;
    for (0..8) |i| l_len |= @as(u64, p[16 + i]) << @intCast(i * 8);
    var l_pid: u32 = 0;
    for (0..4) |i| l_pid |= @as(u32, p[24 + i]) << @intCast(i * 8);
    return .{ .l_type = l_type, .l_whence = l_whence, .l_start = l_start, .l_len = l_len, .l_pid = l_pid };
}

fn writeFlock(addr: u64, l_type: u16, l_whence: u16, l_start: u64, l_len: u64, l_pid: u32) void {
    const p: [*]u8 = @ptrFromInt(addr);
    p[0] = @truncate(l_type);
    p[1] = @truncate(l_type >> 8);
    p[2] = @truncate(l_whence);
    p[3] = @truncate(l_whence >> 8);
    // padding bytes 4-7
    for (4..8) |i| p[i] = 0;
    for (0..8) |i| p[8 + i] = @truncate(l_start >> @intCast(i * 8));
    for (0..8) |i| p[16 + i] = @truncate(l_len >> @intCast(i * 8));
    for (0..4) |i| p[24 + i] = @truncate(l_pid >> @intCast(i * 8));
}

fn locksOverlap(a_start: u64, a_len: u64, b_start: u64, b_len: u64) bool {
    const a_end = if (a_len == 0) ~@as(u64, 0) else a_start + a_len;
    const b_end = if (b_len == 0) ~@as(u64, 0) else b_start + b_len;
    return a_start < b_end and b_start < a_end;
}

fn fcntlGetlk(proc: *process.Process, desc: *vfs.FileDescription, arg: u64) i64 {
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(arg)) == null) return -14;
    const fl = readFlock(arg, proc);
    const ino = desc.inode.ino;
    const pid = proc.pid;

    // Search for conflicting lock
    for (&record_locks) |*lk| {
        if (!lk.in_use or lk.ino != ino or lk.pid == pid) continue;
        if (!locksOverlap(fl.l_start, fl.l_len, lk.start, lk.len)) continue;
        // Conflict: read locks don't conflict with read locks
        if (fl.l_type == F_RDLCK and lk.lock_type == F_RDLCK) continue;
        // Found conflict — fill in details
        writeFlock(arg, lk.lock_type, 0, lk.start, lk.len, @truncate(lk.pid));
        return 0;
    }
    // No conflict — set l_type = F_UNLCK
    writeFlock(arg, F_UNLCK, 0, 0, 0, 0);
    return 0;
}

fn fcntlSetlk(proc: *process.Process, desc: *vfs.FileDescription, arg: u64, blocking: bool) i64 {
    _ = blocking; // For now, non-blocking only (single-user OS avoids deadlock)
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(arg)) == null) return -14;
    const fl = readFlock(arg, proc);
    const ino = desc.inode.ino;
    const pid = proc.pid;

    if (fl.l_type == F_UNLCK) {
        // Unlock: remove matching locks
        for (&record_locks) |*lk| {
            if (lk.in_use and lk.ino == ino and lk.pid == pid and
                locksOverlap(fl.l_start, fl.l_len, lk.start, lk.len))
            {
                lk.in_use = false;
            }
        }
        return 0;
    }

    // Check for conflicts from other processes
    for (&record_locks) |*lk| {
        if (!lk.in_use or lk.ino != ino or lk.pid == pid) continue;
        if (!locksOverlap(fl.l_start, fl.l_len, lk.start, lk.len)) continue;
        if (fl.l_type == F_RDLCK and lk.lock_type == F_RDLCK) continue;
        return -11; // -EAGAIN (would block)
    }

    // Replace or create lock — first try to merge with existing lock from same pid
    for (&record_locks) |*lk| {
        if (lk.in_use and lk.ino == ino and lk.pid == pid and
            locksOverlap(fl.l_start, fl.l_len, lk.start, lk.len))
        {
            lk.lock_type = fl.l_type;
            lk.start = fl.l_start;
            lk.len = fl.l_len;
            return 0;
        }
    }

    // New lock
    for (&record_locks) |*lk| {
        if (!lk.in_use) {
            lk.in_use = true;
            lk.ino = ino;
            lk.pid = pid;
            lk.start = fl.l_start;
            lk.len = fl.l_len;
            lk.lock_type = fl.l_type;
            return 0;
        }
    }
    return -11; // -EAGAIN (no free lock slots)
}

/// Clean up record locks when a process exits or closes an fd
pub fn cleanupRecordLocks(pid: u64) void {
    for (&record_locks) |*lk| {
        if (lk.in_use and lk.pid == pid) lk.in_use = false;
    }
}

fn sysFtruncate(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const length = frame.x[1];

    const proc = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9; // -EBADF

    if (length == 0) {
        if (desc.inode.ops.truncate) |trunc_fn| {
            _ = trunc_fn(desc.inode);
        }
        desc.inode.size = 0;
    } else {
        // Non-zero ftruncate: update both VFS and filesystem-level size.
        // Without this, file-backed mmap reads see the old (0) size from
        // the ext2 disk inode and return EOF.
        if (desc.inode.ops.setsize) |setsize_fn| {
            _ = setsize_fn(desc.inode, length);
        } else {
            desc.inode.size = length;
        }
    }

    return 0;
}

/// fallocate(fd, mode, offset, len) -> 0 or -errno
/// Preallocates disk space for a file. mode=0 extends file size if needed,
/// FALLOC_FL_KEEP_SIZE (1) preallocates without changing size.
fn sysFallocate(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const mode: u32 = @truncate(frame.x[1]);
    const offset = frame.x[2];
    const len = frame.x[3];

    const FALLOC_FL_KEEP_SIZE: u32 = 0x01;
    const FALLOC_FL_PUNCH_HOLE: u32 = 0x02;

    const proc = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9;

    // Only regular files
    if (desc.inode.mode & vfs.S_IFMT != vfs.S_IFREG) return -38; // -ENOSYS

    // Hole punching: zero out blocks in range, free them
    if (mode & FALLOC_FL_PUNCH_HOLE != 0) {
        // PUNCH_HOLE must be combined with KEEP_SIZE per Linux semantics
        if (mode & FALLOC_FL_KEEP_SIZE == 0) return -22; // -EINVAL
        return ext2.ext2PunchHole(@truncate(desc.inode.ino), offset, len);
    }

    const end = offset + len;
    const current_size = desc.inode.size;

    // If mode=0, extend file size if end > current size
    if (mode & FALLOC_FL_KEEP_SIZE == 0 and end > current_size) {
        if (desc.inode.ops.setsize) |setsize_fn| {
            _ = setsize_fn(desc.inode, end);
        } else {
            desc.inode.size = end;
        }
    }

    // Block preallocation is handled implicitly by our block allocator's
    // batch preallocation.

    return 0;
}

/// readlinkat(dirfd, pathname, buf, bufsiz) -> bytes read or -errno
fn sysReadlinkat(frame: *exception.TrapFrame) i64 {
    const _dirfd = frame.x[0];
    const path_addr = frame.x[1];
    const buf_addr = frame.x[2];
    const bufsiz = frame.x[3];
    _ = _dirfd;

    const proc = scheduler.currentProcess() orelse return -3;

    // Ensure path pages are demand-paged with user PTEs
    if (!ensureUserPages(proc.page_table, path_addr, 256)) return -14;

    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {}

    // Special case: /proc/self/exe → return process's executable path
    const self_exe = "/proc/self/exe";
    if (path_len == self_exe.len and streql(path_ptr[0..path_len], self_exe)) {
        if (proc.exe_path_len == 0) return -2; // -ENOENT
        // Ensure output buffer pages are demand-paged
        if (!ensureUserPages(proc.page_table, buf_addr, proc.exe_path_len)) return -14;
        const copy_len: usize = if (proc.exe_path_len > bufsiz) @truncate(bufsiz) else proc.exe_path_len;
        const dst: [*]u8 = @ptrFromInt(buf_addr);
        for (0..copy_len) |i| {
            dst[i] = proc.exe_path[i];
        }
        // Diagnostic: log /proc/self/exe reads for zig processes (PID >= 6)
        if (proc.pid >= 6) {
            uart.print("[readlink] P{} /proc/self/exe -> ", .{proc.pid});
            for (0..copy_len) |i| uart.writeByte(proc.exe_path[i]);
            uart.writeByte('\n');
        }
        return @intCast(copy_len);
    }

    const inode = vfs.resolveNoFollow(path_ptr[0..path_len]) orelse return -2; // -ENOENT

    const readlink_fn = inode.ops.readlink orelse return -22; // -EINVAL

    var kern_buf: [256]u8 = undefined;
    const max_len: usize = if (bufsiz > 256) 256 else @truncate(bufsiz);
    const len = readlink_fn(inode, &kern_buf, max_len);
    if (len < 0) return -22;

    const result_len: usize = @intCast(len);
    // Ensure output buffer pages are demand-paged
    if (!ensureUserPages(proc.page_table, buf_addr, result_len)) return -14;
    const dst: [*]u8 = @ptrFromInt(buf_addr);
    for (0..result_len) |i| {
        dst[i] = kern_buf[i];
    }

    return @intCast(result_len);
}

/// symlinkat(target, newdirfd, linkpath) -> 0 or -errno
fn sysSymlinkat(frame: *exception.TrapFrame) i64 {
    const target_addr = frame.x[0];
    const _newdirfd = frame.x[1];
    const linkpath_addr = frame.x[2];
    _ = _newdirfd; // Only AT_FDCWD supported

    const proc = scheduler.currentProcess() orelse return -3;

    // Read target string from user memory
    if (!ensureUserPages(proc.page_table, target_addr, 256)) return -14; // -EFAULT
    const target_ptr: [*]const u8 = @ptrFromInt(target_addr);
    var target_len: usize = 0;
    while (target_len < 255 and target_ptr[target_len] != 0) : (target_len += 1) {}
    if (target_len == 0) return -2; // -ENOENT

    // Read linkpath string from user memory
    if (!ensureUserPages(proc.page_table, linkpath_addr, 256)) return -14; // -EFAULT
    const link_ptr: [*]const u8 = @ptrFromInt(linkpath_addr);
    var link_len: usize = 0;
    while (link_len < 255 and link_ptr[link_len] != 0) : (link_len += 1) {}
    if (link_len == 0) return -2; // -ENOENT

    // Resolve linkpath to find parent directory
    const result = vfs.resolvePath(link_ptr[0..link_len]);
    if (result.inode != null) return -17; // -EEXIST

    const parent = result.parent orelse return -2; // -ENOENT

    const symlink_fn = parent.ops.symlink orelse return -30; // -EROFS

    if (symlink_fn(parent, result.leaf_name[0..result.leaf_len], target_ptr[0..target_len])) |_| {
        return 0;
    } else {
        return -5; // -EIO
    }
}

/// linkat(olddirfd, oldpath, newdirfd, newpath, flags) -> 0 or -errno
/// Creates a hard link: new directory entry pointing to the same inode.
fn sysLinkat(frame: *exception.TrapFrame) i64 {
    const old_dirfd = frame.x[0];
    const old_path_addr = frame.x[1];
    const new_dirfd = frame.x[2];
    const new_path_addr = frame.x[3];
    const flags: u32 = @truncate(frame.x[4]);
    _ = flags; // AT_EMPTY_PATH / AT_SYMLINK_FOLLOW — not needed for basic support

    const proc = scheduler.currentProcess() orelse return -1;

    // Read old path
    if (!ensureUserPages(proc.page_table, old_path_addr, 1)) return -14;
    const old_path_ptr: [*]const u8 = @ptrFromInt(old_path_addr);
    var old_path_len: usize = 0;
    while (old_path_len < 255 and old_path_ptr[old_path_len] != 0) : (old_path_len += 1) {
        const next_addr = old_path_addr + old_path_len + 1;
        if (next_addr & 0xFFF == 0 and old_path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }
    if (old_path_len == 0) return -2;
    const old_path = old_path_ptr[0..old_path_len];

    // Read new path
    if (!ensureUserPages(proc.page_table, new_path_addr, 1)) return -14;
    const new_path_ptr: [*]const u8 = @ptrFromInt(new_path_addr);
    var new_path_len: usize = 0;
    while (new_path_len < 255 and new_path_ptr[new_path_len] != 0) : (new_path_len += 1) {
        const next_addr = new_path_addr + new_path_len + 1;
        if (next_addr & 0xFFF == 0 and new_path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next_addr, 1)) break;
        }
    }
    if (new_path_len == 0) return -2;
    const new_path = new_path_ptr[0..new_path_len];

    // Resolve old path — must exist
    const old_result = resolveWithDirfd(proc, old_dirfd, old_path);
    const source_inode = old_result.inode orelse return -2; // -ENOENT

    // Cannot hard link directories
    if (source_inode.mode & vfs.S_IFMT == vfs.S_IFDIR) return -31; // -EMLINK (or -EPERM)

    // Resolve new path — must NOT exist
    const new_result = resolveWithDirfd(proc, new_dirfd, new_path);
    if (new_result.inode != null) return -17; // -EEXIST

    const new_parent = new_result.parent orelse return -2;
    if (!checkPermission(new_parent, 3, proc)) return -13; // -EACCES

    // Must be same filesystem (same superblock)
    // For simplicity, just check both are ext2
    const link_fn = new_parent.ops.link orelse return -38; // -ENOSYS

    const new_leaf = new_result.leaf_name[0..new_result.leaf_len];
    if (link_fn(new_parent, new_leaf, source_inode)) {
        return 0;
    }
    return -5; // -EIO
}

/// readv(fd, iov, iovcnt) -> bytes read
fn sysReadv(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const iov_addr = frame.x[1];
    const iovcnt = frame.x[2];

    const proc = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9; // -EBADF
    const read_fn = desc.inode.ops.read orelse return -9;

    if (iovcnt == 0 or iovcnt > 1024) return -22; // -EINVAL

    var total_read: usize = 0;
    const cnt: usize = @truncate(iovcnt);

    for (0..cnt) |i| {
        const iov_entry_addr = iov_addr + i * 16;
        if (!ensureUserPages(proc.page_table, iov_entry_addr, 16)) break;

        // Read iov_base(u64) + iov_len(u64)
        const entry: [*]const u8 = @ptrFromInt(iov_entry_addr);
        const iov_base = readU64LE(entry[0..8]);
        const iov_len = readU64LE(entry[8..16]);

        if (iov_len == 0) continue;
        const actual_len: usize = if (iov_len > 1048576) 1048576 else @truncate(iov_len);
        if (!ensureUserPages(proc.page_table, iov_base, actual_len)) break;

        const buf: [*]u8 = @ptrFromInt(iov_base);
        const n = read_fn(desc, buf, actual_len);
        if (n == -11 and total_read == 0) {
            if (fd_num == 0) {
                uart.waiting_pid = proc.pid;
                proc.state = .blocked;
                frame.elr -= 4;
                scheduler.blockAndSchedule(frame);
                return 0;
            }
            if (pipe.isPipeInode(desc.inode) and proc.state == .blocked) {
                frame.elr -= 4;
                scheduler.blockAndSchedule(frame);
                return 0;
            }
        }
        if (n <= 0) break;
        total_read += @intCast(n);
    }

    return @intCast(total_read);
}

/// writev(fd, iov, iovcnt) -> bytes written
fn sysWritev(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const iov_addr = frame.x[1];
    const iovcnt = frame.x[2];

    const proc = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9; // -EBADF
    const write_fn = desc.inode.ops.write orelse return -9;

    if (iovcnt == 0 or iovcnt > 1024) return -22; // -EINVAL

    var total_written: usize = 0;
    const cnt: usize = @truncate(iovcnt);

    for (0..cnt) |i| {
        const iov_entry_addr = iov_addr + i * 16;
        if (!ensureUserPages(proc.page_table, iov_entry_addr, 16)) break;

        // Read iov_base(u64) + iov_len(u64)
        const entry: [*]const u8 = @ptrFromInt(iov_entry_addr);
        const iov_base = readU64LE(entry[0..8]);
        const iov_len = readU64LE(entry[8..16]);

        if (iov_len == 0) continue;
        const actual_len: usize = if (iov_len > 1048576) 1048576 else @truncate(iov_len);
        if (!ensureUserPages(proc.page_table, iov_base, actual_len)) break;

        const buf: [*]const u8 = @ptrFromInt(iov_base);
        const n = write_fn(desc, buf, actual_len);
        if (n == -11 and total_written == 0 and pipe.isPipeInode(desc.inode) and proc.state == .blocked) {
            frame.elr -= 4;
            scheduler.blockAndSchedule(frame);
            return 0;
        }
        if (n <= 0) break;
        total_written += @intCast(n);
    }

    return @intCast(total_written);
}

/// preadv(fd, iov, iovcnt, offset) — nr 69
/// Scatter-gather read at a given file offset without changing position.
/// Uses a stack-local FileDescription to avoid racing on desc.offset with
/// other threads sharing the same fd table (CLONE_VM).
fn sysPreadv(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const iov_addr = frame.x[1];
    const iovcnt = frame.x[2];
    const offset = frame.x[3];

    const proc = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9; // -EBADF
    const read_fn = desc.inode.ops.read orelse return -9;

    if (iovcnt == 0 or iovcnt > 1024) return -22; // -EINVAL

    // Use a private FileDescription with the requested offset so we never
    // touch the shared desc.offset — safe for concurrent preadv from threads.
    var tmp_desc = vfs.FileDescription{
        .inode = desc.inode,
        .offset = offset,
        .flags = desc.flags,
        .ref_count = 1,
        .in_use = true,
    };

    var total_read: usize = 0;
    const cnt: usize = @truncate(iovcnt);

    for (0..cnt) |i| {
        const iov_entry_addr = iov_addr + i * 16;
        if (!ensureUserPages(proc.page_table, iov_entry_addr, 16)) break;

        const entry: [*]const u8 = @ptrFromInt(iov_entry_addr);
        const iov_base = readU64LE(entry[0..8]);
        const iov_len = readU64LE(entry[8..16]);

        if (iov_len == 0) continue;
        const actual_len: usize = if (iov_len > 1048576) 1048576 else @truncate(iov_len);
        if (!ensureUserPages(proc.page_table, iov_base, actual_len)) break;

        const buf: [*]u8 = @ptrFromInt(iov_base);
        const n = read_fn(&tmp_desc, buf, actual_len);
        if (n <= 0) break;
        total_read += @intCast(n);
    }

    return @intCast(total_read);
}

/// pwritev(fd, iov, iovcnt, offset) — nr 70
/// Scatter-gather write at a given file offset without changing position.
/// Uses a stack-local FileDescription to avoid racing on desc.offset with
/// other threads sharing the same fd table (CLONE_VM).
fn sysPwritev(frame: *exception.TrapFrame) i64 {
    const fd_num = frame.x[0];
    const iov_addr = frame.x[1];
    const iovcnt = frame.x[2];
    const offset = frame.x[3];

    const proc = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&proc.fds, fd_num) orelse return -9; // -EBADF
    const write_fn = desc.inode.ops.write orelse return -9;

    if (iovcnt == 0 or iovcnt > 1024) return -22; // -EINVAL

    var tmp_desc = vfs.FileDescription{
        .inode = desc.inode,
        .offset = offset,
        .flags = desc.flags,
        .ref_count = 1,
        .in_use = true,
    };

    var total_written: usize = 0;
    const cnt: usize = @truncate(iovcnt);

    for (0..cnt) |i| {
        const iov_entry_addr = iov_addr + i * 16;
        if (!ensureUserPages(proc.page_table, iov_entry_addr, 16)) break;

        const entry: [*]const u8 = @ptrFromInt(iov_entry_addr);
        const iov_base = readU64LE(entry[0..8]);
        const iov_len = readU64LE(entry[8..16]);

        if (iov_len == 0) continue;
        const actual_len: usize = if (iov_len > 1048576) 1048576 else @truncate(iov_len);
        if (!ensureUserPages(proc.page_table, iov_base, actual_len)) break;

        const buf: [*]const u8 = @ptrFromInt(iov_base);
        const n = write_fn(&tmp_desc, buf, actual_len);
        if (n <= 0) break;
        total_written += @intCast(n);
    }
    return @intCast(total_written);
}

/// sync() -> 0
fn sysSync() i64 {
    ext2.sync();
    return 0;
}

/// fsync(fd) -> 0. Flush file data+metadata to disk, commit journal.
fn sysFsync(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const current = scheduler.currentProcess() orelse return -3;
    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9; // -EBADF

    // Write inode metadata to disk if this is an ext2 file
    if (desc.inode.ino >= 2) { // ext2 inodes start at 2
        _ = ext2.flushInode(desc.inode.ino);
    }

    ext2.syncFile();
    return 0;
}

/// fdatasync(fd) -> 0. Flush file data to disk (skip metadata if unchanged).
fn sysFdatasync(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const current = scheduler.currentProcess() orelse return -3;
    _ = fd_table.fdGet(&current.fds, fd) orelse return -9; // -EBADF

    // For now, same as fsync — we don't track dirty data vs metadata separately
    ext2.syncFile();
    return 0;
}

// ============================================================================
// Time syscalls
// ============================================================================

/// clock_gettime(clockid, timespec) -> 0
fn sysClockGettime(frame: *exception.TrapFrame) i64 {
    const clock_id = frame.x[0];
    const buf_addr = frame.x[1];

    if (clock_id > 1) return -22; // -EINVAL (only CLOCK_REALTIME=0, CLOCK_MONOTONIC=1)

    const proc = scheduler.currentProcess() orelse return -3;
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(buf_addr)) == null) return -14; // -EFAULT

    const buf: [*]u8 = @ptrFromInt(buf_addr);

    if (clock_id == 0) {
        // CLOCK_REALTIME — Unix epoch time from RTC + monotonic timer
        const rtc_mod = @import("rtc.zig");
        const t = rtc_mod.getEpochTime();
        writeU64(buf, 0, t.sec);
        writeU64(buf, 8, t.nsec);
    } else {
        // CLOCK_MONOTONIC — uptime since boot
        const ticks = timer.getTicks();
        writeU64(buf, 0, ticks / 100);
        writeU64(buf, 8, (ticks % 100) * 10_000_000);
    }

    return 0;
}

// ============================================================================
// Memory protection
// ============================================================================

/// mprotect(addr, len, prot) -> 0
/// Updates page table permissions for already-mapped pages and VMA flags.
fn sysMprotect(frame: *exception.TrapFrame) i64 {
    const addr = frame.x[0];
    const length = frame.x[1];
    const prot: u32 = @truncate(frame.x[2]);

    if (addr & 0xFFF != 0) return -22; // -EINVAL, must be page-aligned
    if (length == 0) return -22;

    const proc = scheduler.currentProcess() orelse return -1;

    // Diagnostic: trace mprotect for PID 5 (debug crash)
    if (proc.pid >= 5) {
        uart.print("[mpr] P{} {x}+{x} prot={}\n", .{ proc.pid, addr, length, prot });
    }

    const vp = getVmaProcess(proc);

    vp.vma_lock.acquire();
    defer vp.vma_lock.release();

    const aligned_len = (length + pmm.PAGE_SIZE - 1) & ~(pmm.PAGE_SIZE - 1);
    const prot_end = addr + aligned_len;
    const writable = (prot & PROT_WRITE) != 0;
    const executable = (prot & PROT_EXEC) != 0;
    const readable = (prot & PROT_READ) != 0;

    // W^X enforcement: reject simultaneous write+execute
    if (writable and executable) return -22; // -EINVAL

    // Update page table entries for each page in the range
    // For PROT_NONE (prot=0): clear user access bit to make page kernel-only
    const user_accessible = readable or writable or executable;
    var page: u64 = addr;
    while (page < prot_end) : (page += pmm.PAGE_SIZE) {
        vmm.updatePTEPermissions(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(page), writable, executable, user_accessible);
    }

    // Update VMA flags — use splitForProtect for safe splitting with rollback
    var new_flags = vma.VmaFlags{
        .readable = readable,
        .writable = writable,
        .executable = executable,
        .user = true,
    };

    // Walk overlapping VMAs and split/update as needed.
    // Process one VMA at a time via findVmaMut to avoid mutating the list during iteration.
    var cursor = addr;
    while (cursor < prot_end) {
        const v = vma.findVmaMut(&vp.vmas, cursor) orelse {
            // Gap in VMA coverage — skip to next page
            cursor += pmm.PAGE_SIZE;
            continue;
        };
        // Preserve file_backed and shared flags from the original VMA
        new_flags.file_backed = v.flags.file_backed;
        new_flags.shared = v.flags.shared;
        new_flags.stack = v.flags.stack;

        const ve = v.end;
        _ = vma.splitForProtect(&vp.vmas, cursor, prot_end, new_flags);
        // Advance past this VMA (splitForProtect may have trimmed it)
        cursor = ve;
    }

    return 0;
}

// ============================================================================
// Signal helpers
// ============================================================================

/// tkill(tid, sig) -> 0 or -ESRCH
fn sysTkill(frame: *exception.TrapFrame) i64 {
    const tid = frame.x[0];
    const sig: u6 = @truncate(frame.x[1]);

    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |proc| {
            if (proc.pid == tid) {
                signal.postSignal(proc, sig);
                return 0;
            }
        }
    }
    return -3; // -ESRCH
}

/// set_tid_address(tidptr) -> tid
fn sysSetTidAddress(frame: *exception.TrapFrame) i64 {
    const proc = scheduler.currentProcess() orelse return -3;
    proc.clear_child_tid = frame.x[0];
    return @intCast(proc.pid);
}

// ============================================================================
// ioctl — terminal foreground process group
// ============================================================================

/// ioctl(fd, request, arg) -> 0 or -ENOTTY
fn sysIoctl(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const request = frame.x[1];
    const arg = frame.x[2];

    const TIOCGPGRP: u64 = 0x540F;
    const TIOCSPGRP: u64 = 0x5410;
    const TIOCGWINSZ: u64 = 0x5413;
    const TCGETS: u64 = 0x5401;

    // Terminal ioctls only on stdio fds
    if (fd <= 2) {
        if (request == TIOCSPGRP) {
            const proc = scheduler.currentProcess() orelse return -3;
            if (arg != 0 and vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(arg)) != null) {
                const buf: [*]const u8 = @ptrFromInt(arg);
                const pgid: u32 = @as(u32, buf[0]) |
                    (@as(u32, buf[1]) << 8) |
                    (@as(u32, buf[2]) << 16) |
                    (@as(u32, buf[3]) << 24);
                uart.fg_pgid = pgid;
                return 0;
            }
            return -14; // -EFAULT
        }
        if (request == TIOCGPGRP) {
            const proc = scheduler.currentProcess() orelse return -3;
            if (arg != 0 and vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(arg)) != null) {
                const buf: [*]u8 = @ptrFromInt(arg);
                writeU32(buf, 0, uart.fg_pgid);
                return 0;
            }
            return -14; // -EFAULT
        }
        if (request == TIOCGWINSZ) {
            const proc = scheduler.currentProcess() orelse return -3;
            // Only real UART-backed fds are terminals. These have NO entry
            // in the fd table (sysWrite/sysRead special-case fd 0-2 to UART).
            // Any fd with a FileDescription (pipe, regular file) is NOT a terminal.
            if (fd_table.fdGet(&proc.fds, fd) != null) {
                return -25; // -ENOTTY — fd has a real FileDescription (not UART)
            }
            // Real terminal (UART) — return default 80x24
            if (arg != 0 and vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(arg)) != null) {
                const buf: [*]u8 = @ptrFromInt(arg);
                buf[0] = 24; buf[1] = 0; // ws_row = 24
                buf[2] = 80; buf[3] = 0; // ws_col = 80
                buf[4] = 0;  buf[5] = 0; // ws_xpixel = 0
                buf[6] = 0;  buf[7] = 0; // ws_ypixel = 0
                return 0;
            }
            return -14; // -EFAULT
        }
        if (request == TCGETS) {
            const proc = scheduler.currentProcess() orelse return -3;
            if (fd_table.fdGet(&proc.fds, fd) != null) {
                return -25; // -ENOTTY — not a terminal
            }
            return -25; // -ENOTTY (UART doesn't implement full termios yet)
        }
    }

    return -25; // -ENOTTY
}

fn readU64FromUser(buf: [*]const u8, off: usize) u64 {
    var val: u64 = 0;
    for (0..8) |i| {
        val |= @as(u64, buf[off + i]) << @intCast(i * 8);
    }
    return val;
}

fn readU64LE(buf: *const [8]u8) u64 {
    var val: u64 = 0;
    for (0..8) |i| {
        val |= @as(u64, buf[i]) << @intCast(i * 8);
    }
    return val;
}

fn writeU64LE(buf: *[8]u8, val: u64) void {
    var v = val;
    for (0..8) |i| {
        buf[i] = @truncate(v);
        v >>= 8;
    }
}

// ============================================================================
// New syscalls — U17 port from x86_64
// ============================================================================

/// pread64(fd, buf, count, offset) — nr 67
/// Read at a given offset without changing the file position.
fn sysPread64(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const buf_addr = frame.x[1];
    const count = frame.x[2];
    const offset = frame.x[3]; // 4th arg via x3 on ARM64

    const current = scheduler.currentProcess() orelse return -3; // -ESRCH

    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9; // -EBADF

    const read_fn = desc.inode.ops.read orelse return -9; // -EBADF

    if (!ensureUserPages(current.page_table, buf_addr, if (count > 1048576) 1048576 else @truncate(count))) return -14;

    // Use a private FileDescription — pread must not touch the shared desc.offset
    // and must be safe for concurrent calls from CLONE_VM threads.
    var tmp_desc = vfs.FileDescription{
        .inode = desc.inode,
        .offset = offset,
        .flags = desc.flags,
        .ref_count = 1,
        .in_use = true,
    };

    const actual_len: usize = if (count > 1048576) 1048576 else @truncate(count);
    var total_read: usize = 0;
    var remaining = actual_len;
    var addr = buf_addr;

    while (remaining > 0) {
        const page_offset: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, pmm.PAGE_SIZE - page_offset);

        const ptr: [*]u8 = @ptrFromInt(addr);
        const n = read_fn(&tmp_desc, ptr, chunk);
        if (n <= 0) break;
        total_read += @intCast(n);
        if (@as(usize, @intCast(n)) < chunk) break;

        addr += chunk;
        remaining -= chunk;
    }

    return @intCast(total_read);
}

/// pwrite64(fd, buf, count, offset) — nr 68
/// Write at a given offset without changing the file position.
/// Uses a private FileDescription for thread safety (CLONE_VM).
fn sysPwrite64(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const buf_addr = frame.x[1];
    const count = frame.x[2];
    const offset = frame.x[3]; // 4th arg via x3 on ARM64

    const current = scheduler.currentProcess() orelse return -3; // -ESRCH

    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9; // -EBADF

    const write_fn = desc.inode.ops.write orelse return -9; // -EBADF

    const actual_len: usize = if (count > 1048576) 1048576 else @truncate(count);
    if (!ensureUserPages(current.page_table, buf_addr, actual_len)) return -14;

    var tmp_desc = vfs.FileDescription{
        .inode = desc.inode,
        .offset = offset,
        .flags = desc.flags,
        .ref_count = 1,
        .in_use = true,
    };

    var total_written: usize = 0;
    var remaining = actual_len;
    var addr = buf_addr;

    while (remaining > 0) {
        const page_offset: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, pmm.PAGE_SIZE - page_offset);

        const ptr: [*]const u8 = @ptrFromInt(addr);
        const n = write_fn(&tmp_desc, ptr, chunk);
        if (n <= 0) break;
        total_written += @intCast(n);

        addr += chunk;
        remaining -= chunk;
    }

    return @intCast(total_written);
}

/// faccessat(dirfd, pathname, mode, flags) — nr 48
/// Check whether the calling process can access the file.
fn sysFaccessat(frame: *exception.TrapFrame) i64 {
    // dirfd = frame.x[0] — only AT_FDCWD supported
    const path_addr = frame.x[1];

    const proc = scheduler.currentProcess() orelse return -3; // -ESRCH

    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(path_addr)) == null) return -14; // -EFAULT

    // Read null-terminated path from user space (identity mapped)
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {}

    if (path_len == 0) return -2; // -ENOENT

    // Resolve relative paths using CWD
    var path_buf: [512]u8 = undefined;
    var resolved_len: usize = 0;

    if (path_ptr[0] != '/') {
        // Prepend CWD
        const cwd_len: usize = proc.cwd_len;
        for (0..cwd_len) |i| {
            path_buf[i] = proc.cwd[i];
        }
        resolved_len = cwd_len;
        if (resolved_len > 0 and path_buf[resolved_len - 1] != '/') {
            path_buf[resolved_len] = '/';
            resolved_len += 1;
        }
        for (0..path_len) |i| {
            if (resolved_len >= path_buf.len - 1) break;
            path_buf[resolved_len] = path_ptr[i];
            resolved_len += 1;
        }
    } else {
        for (0..path_len) |i| {
            path_buf[i] = path_ptr[i];
        }
        resolved_len = path_len;
    }

    // Intercept pseudo-device paths
    const resolved_path = path_buf[0..resolved_len];
    if (resolved_len == 9 and streql(resolved_path, "/dev/null")) return 0;
    if (resolved_len == 9 and streql(resolved_path, "/dev/zero")) return 0;

    const inode = vfs.resolve(resolved_path) orelse {
        if (proc.pid >= 2) {
            uart.print("[access-e] P{} faccessat: ", .{proc.pid});
            uart.writeString(resolved_path);
            uart.writeString("\n");
        }
        return -2; // -ENOENT
    };
    _ = inode;

    // File exists — for our simple OS, return success
    return 0;
}

/// sched_yield() — nr 124
/// Yield the processor to another thread.
fn sysSchedYield() i64 {
    return 0;
}

/// nanosleep(req, rem) — nr 101
/// Sleep for the specified time. Busy-waits using ARM64 timer counter.
fn sysNanosleep(frame: *exception.TrapFrame) i64 {
    const req_addr = frame.x[0];

    const proc = scheduler.currentProcess() orelse return -3; // -ESRCH

    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(req_addr)) == null) return -14; // -EFAULT

    // Read timespec {tv_sec: i64, tv_nsec: i64} from user (identity mapped)
    const req_ptr: [*]const u8 = @ptrFromInt(req_addr);
    const tv_sec = readU64LE(req_ptr[0..8]);
    const tv_nsec = readU64LE(req_ptr[8..16]);

    // Read ARM64 timer frequency (ticks per second)
    const freq: u64 = asm volatile ("mrs %[ret], CNTFRQ_EL0"
        : [ret] "=r" (-> u64),
    );

    // Calculate total ticks to wait
    const total_ticks = tv_sec * freq + (tv_nsec * freq) / 1_000_000_000;

    // Read current counter
    const start: u64 = asm volatile ("mrs %[ret], CNTPCT_EL0"
        : [ret] "=r" (-> u64),
    );

    // Busy-wait using ARM64 yield hint
    while (true) {
        const now: u64 = asm volatile ("mrs %[ret], CNTPCT_EL0"
            : [ret] "=r" (-> u64),
        );
        if (now - start >= total_ticks) break;
        asm volatile ("yield");
    }

    return 0;
}

/// fcntl(fd, cmd, arg) — nr 25
/// File descriptor control operations.
fn sysFcntl(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const cmd: u32 = @truncate(frame.x[1]);
    const arg = frame.x[2];

    const F_DUPFD: u32 = 0;
    const F_GETFD: u32 = 1;
    const F_SETFD: u32 = 2;
    const F_GETFL: u32 = 3;
    const F_SETFL: u32 = 4;
    const F_GETLK: u32 = 5;
    const F_SETLK: u32 = 6;
    const F_SETLKW: u32 = 7;
    const F_DUPFD_CLOEXEC: u32 = 1030;

    const current = scheduler.currentProcess() orelse return -3; // -ESRCH

    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9; // -EBADF

    switch (cmd) {
        F_DUPFD, F_DUPFD_CLOEXEC => {
            // Duplicate fd to lowest available >= arg
            _ = @atomicRmw(u32, &desc.ref_count, .Add, 1, .acq_rel);
            const min_fd: usize = @truncate(arg);
            var new_fd: ?u32 = null;
            for (min_fd..fd_table.MAX_FDS) |i| {
                if (current.fds[i] == null) {
                    current.fds[i] = desc;
                    current.fd_cloexec[i] = (cmd == F_DUPFD_CLOEXEC);
                    new_fd = @truncate(i);
                    break;
                }
            }
            if (new_fd) |nfd| {
                return @intCast(nfd);
            } else {
                _ = @atomicRmw(u32, &desc.ref_count, .Sub, 1, .acq_rel);
                return -24; // -EMFILE
            }
        },
        F_GETFD => {
            if (fd < fd_table.MAX_FDS) {
                return if (current.fd_cloexec[@truncate(fd)]) 1 else 0;
            }
            return 0;
        },
        F_SETFD => {
            if (fd < fd_table.MAX_FDS) {
                current.fd_cloexec[@truncate(fd)] = (arg & 1 != 0); // FD_CLOEXEC = 1
            }
            return 0;
        },
        F_GETFL => {
            return @intCast(desc.flags);
        },
        F_SETFL => {
            // Preserve access mode (O_ACCMODE), only change O_APPEND/O_NONBLOCK.
            const changeable = vfs.O_APPEND | vfs.O_NONBLOCK;
            desc.flags = (desc.flags & ~changeable) | (@as(u32, @truncate(arg)) & changeable);
            return 0;
        },
        F_GETLK => {
            return fcntlGetlk(current, desc, arg);
        },
        F_SETLK, F_SETLKW => {
            return fcntlSetlk(current, desc, arg, cmd == F_SETLKW);
        },
        else => {
            return -22; // -EINVAL
        },
    }
}

/// sched_getaffinity(pid, cpusetsize, mask) — nr 122
/// Returns CPU mask based on actual online CPUs.
fn sysSchedGetaffinity(frame: *exception.TrapFrame) i64 {
    // pid = frame.x[0] — ignored, always return for current
    const cpusetsize = frame.x[1];
    const mask_addr = frame.x[2];

    const proc = scheduler.currentProcess() orelse return -3; // -ESRCH

    if (cpusetsize == 0) return -22; // -EINVAL

    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(mask_addr)) == null) return -14; // -EFAULT

    // Report 1 CPU to force single-threaded compilation (avoid thread pool deadlock)
    // TODO: Fix futex/condvar interaction and restore real CPU count
    const ncpus: u64 = 1;
    const cpu_mask: u8 = if (ncpus >= 8) 0xFF else @truncate((@as(u16, 1) << @truncate(ncpus)) - 1);

    const buf: [*]u8 = @ptrFromInt(mask_addr);
    buf[0] = cpu_mask;

    // Zero remaining bytes if cpusetsize > 1
    if (cpusetsize > 1) {
        const zero_len: usize = if (cpusetsize - 1 > 128) 128 else @truncate(cpusetsize - 1);
        for (0..zero_len) |i| {
            buf[1 + i] = 0;
        }
    }

    // Linux returns the cpuset size written (minimum 8 bytes)
    const ret_size: usize = if (cpusetsize < 8) @as(usize, @truncate(cpusetsize)) else 8;
    return @intCast(ret_size);
}

/// prlimit64(pid, resource, new_rlim, old_rlim) — nr 261
/// Get/set resource limits. Returns hardcoded values.
fn sysPrlimit64(frame: *exception.TrapFrame) i64 {
    // pid = frame.x[0] — ignored
    const resource: u32 = @truncate(frame.x[1]);
    // new_rlim = frame.x[2] — ignored
    const old_rlim_addr = frame.x[3]; // 4th arg via x3

    const RLIMIT_STACK: u32 = 3;
    const RLIMIT_NOFILE: u32 = 7;
    const RLIMIT_AS: u32 = 9;
    const RLIM_INFINITY: u64 = 0xFFFFFFFFFFFFFFFF;

    const proc = scheduler.currentProcess() orelse return -3; // -ESRCH

    // If old_rlim is non-null, write current limits
    if (old_rlim_addr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(old_rlim_addr)) == null) return -14; // -EFAULT

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

        // Write struct rlimit {rlim_cur: u64, rlim_max: u64} = 16 bytes LE
        const buf: [*]u8 = @ptrFromInt(old_rlim_addr);
        writeU64(buf, 0, soft);
        writeU64(buf, 8, hard);
    }

    // Ignore new_rlim (don't actually change limits)
    return 0;
}

/// getrandom(buf, buflen, flags) — nr 278
/// Fill buffer with random bytes using ARM64 timer counter PRNG.
fn sysGetrandom(frame: *exception.TrapFrame) i64 {
    const buf_addr = frame.x[0];
    const buflen = frame.x[1];
    // flags = frame.x[2] — ignored

    const proc = scheduler.currentProcess() orelse return -3; // -ESRCH

    if (buflen == 0) return 0;

    const actual_len: usize = if (buflen > 256) 256 else @truncate(buflen);

    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(buf_addr)) == null) return -14; // -EFAULT

    // Generate random bytes using ARM64 timer counter as seed (replaces x86 RDTSC)
    var seed: u64 = asm volatile ("mrs %[ret], CNTPCT_EL0"
        : [ret] "=r" (-> u64),
    );

    // Write directly to user buffer (identity mapped on ARM64)
    const buf: [*]u8 = @ptrFromInt(buf_addr);
    for (0..actual_len) |i| {
        seed = seed *% 6364136223846793005 +% 1;
        buf[i] = @truncate(seed >> 33);
    }

    return @intCast(actual_len);
}

/// sysinfo(info) — nr 179
/// Linux aarch64 struct sysinfo layout (112 bytes total):
///   offset   0: long uptime             (8 bytes)
///   offset   8: unsigned long loads[3]   (24 bytes)
///   offset  32: unsigned long totalram   (8 bytes)
///   offset  40: unsigned long freeram    (8 bytes)
///   offset  48: unsigned long sharedram  (8 bytes)
///   offset  56: unsigned long bufferram  (8 bytes)
///   offset  64: unsigned long totalswap  (8 bytes)
///   offset  72: unsigned long freeswap   (8 bytes)
///   offset  80: unsigned short procs     (2 bytes)
///   offset  82: unsigned short pad       (2 bytes)
///   offset  84: (4 bytes alignment padding to next u64)
///   offset  88: unsigned long totalhigh  (8 bytes)
///   offset  96: unsigned long freehigh   (8 bytes)
///   offset 104: unsigned int mem_unit    (4 bytes)
///   offset 108: char _f[4]              (padding to 112)
fn sysSysinfo(frame: *exception.TrapFrame) i64 {
    const info_addr = frame.x[0];
    const proc = scheduler.currentProcess() orelse return -3;

    // Ensure both the first and last bytes of the 112-byte struct are mapped
    // (the buffer could span a page boundary)
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(info_addr)) == null) {
        if (!ensureUserPages(proc.page_table, info_addr, 1)) return -14;
    }
    const end_addr = info_addr + 112 - 1;
    if ((end_addr & ~@as(u64, 0xFFF)) != (info_addr & ~@as(u64, 0xFFF))) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(end_addr)) == null) {
            if (!ensureUserPages(proc.page_table, end_addr, 1)) return -14;
        }
    }

    const dst: [*]u8 = @ptrFromInt(info_addr);
    for (0..112) |i| dst[i] = 0;

    const pmm_mod = @import("pmm.zig");
    const total_pages = pmm_mod.getTotalPages();
    const free_pages = pmm_mod.getFreePages();
    const page_size: u64 = 4096;
    const ticks = timer.getTicks();
    const uptime: u64 = ticks / 100;

    const up_bytes = @as([8]u8, @bitCast(uptime));
    for (0..8) |i| dst[i] = up_bytes[i];
    const total_bytes = @as([8]u8, @bitCast(total_pages * page_size));
    for (0..8) |i| dst[32 + i] = total_bytes[i];
    const free_bytes = @as([8]u8, @bitCast(free_pages * page_size));
    for (0..8) |i| dst[40 + i] = free_bytes[i];

    var nprocs: u16 = 0;
    const process_mod = @import("process.zig");
    for (0..process_mod.MAX_PROCESSES) |idx| {
        if (process_mod.slot_in_use[idx]) nprocs += 1;
    }
    dst[80] = @truncate(nprocs);
    dst[81] = @truncate(nprocs >> 8);
    dst[104] = 1; // mem_unit = 1 (u32 at offset 104, values are in bytes)

    return 0;
}

// ============================================================================
// execve — A26 (boot-to-shell)
// ============================================================================

const elf = @import("elf.zig");

/// Small buffer for ELF header + program headers (64 + 70*56 = ~4 KiB max)
const ELF_HDR_BUF_SIZE: usize = 4096;
var elf_hdr_buf: [ELF_HDR_BUF_SIZE]u8 = undefined;

/// Buffers for saving argv/envp strings before address space teardown
const MAX_ARGS: usize = 256;
const ARG_BUF_SIZE: usize = 32768;
var arg_buf: [ARG_BUF_SIZE]u8 = undefined;
const MAX_ENV_ARGS: usize = 256;
const ENV_BUF_SIZE: usize = 32768;
var env_buf: [ENV_BUF_SIZE]u8 = undefined;

/// execve(path, argv, envp) — nr 221
/// Replace the current process image with a new ELF binary.
/// This function does NOT return on success — the process resumes at the new entry point.
/// execveat(dirfd, pathname, argv, envp, flags) — NR 281
/// Used by Zig's std.process.Child.spawn() for LLD invocation.
/// Remap args to execve format (ignore dirfd, assume AT_FDCWD).
fn sysExecveat(frame: *exception.TrapFrame) void {
    // execveat: x0=dirfd, x1=pathname, x2=argv, x3=envp, x4=flags
    // Remap to execve: x0=pathname, x1=argv, x2=envp
    frame.x[0] = frame.x[1]; // pathname
    frame.x[1] = frame.x[2]; // argv
    frame.x[2] = frame.x[3]; // envp
    sysExecve(frame);
}

pub fn sysExecve(frame: *exception.TrapFrame) void {
    const path_addr = frame.x[0];
    const argv_addr = frame.x[1];
    const envp_addr = frame.x[2];

    const current = scheduler.currentProcess() orelse {
        frame.x[0] = @bitCast(@as(i64, -3)); // -ESRCH
        return;
    };

    // 1. Copy path from user space (identity mapped: phys == virt)
    if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(path_addr)) == null) {
        if (!ensureUserPages(current.page_table, path_addr, 1)) {
            frame.x[0] = @bitCast(@as(i64, -14)); // -EFAULT
            return;
        }
    }

    var path_buf: [256]u8 = undefined;
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {
        path_buf[path_len] = path_ptr[path_len];
    }
    if (path_len == 0) {
        frame.x[0] = @bitCast(@as(i64, -2)); // -ENOENT
        return;
    }

    // 2. Copy argv strings from user space before we destroy the address space
    var argc: usize = 0;
    var arg_offsets: [MAX_ARGS]usize = undefined;
    var arg_lens: [MAX_ARGS]usize = undefined;
    var arg_total: usize = 0;

    if (argv_addr != 0 and vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(argv_addr)) != null) {
        var argv_ptr = argv_addr;
        while (argc < MAX_ARGS) {
            if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(argv_ptr)) == null) break;
            const str_addr = readUserU64(argv_ptr);
            if (str_addr == 0) break; // NULL terminator

            if (arg_total >= ARG_BUF_SIZE) break;
            arg_offsets[argc] = arg_total;

            // Copy null-terminated string
            if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(str_addr)) == null) break;
            const sp: [*]const u8 = @ptrFromInt(str_addr);
            var slen: usize = 0;
            while (slen < ARG_BUF_SIZE - arg_total - 1 and sp[slen] != 0) : (slen += 1) {
                arg_buf[arg_total + slen] = sp[slen];
            }
            arg_buf[arg_total + slen] = 0;
            arg_lens[argc] = slen;
            arg_total += slen + 1;
            argc += 1;
            argv_ptr += 8;
        }
    }

    // 2b. Copy envp strings
    var envc: usize = 0;
    var env_offsets: [MAX_ENV_ARGS]usize = undefined;
    var env_lens: [MAX_ENV_ARGS]usize = undefined;
    var env_total: usize = 0;

    if (envp_addr != 0 and vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(envp_addr)) != null) {
        var envp_ptr = envp_addr;
        while (envc < MAX_ENV_ARGS) {
            if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(envp_ptr)) == null) break;
            const str_addr = readUserU64(envp_ptr);
            if (str_addr == 0) break;

            if (env_total >= ENV_BUF_SIZE) break;
            env_offsets[envc] = env_total;

            if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(str_addr)) == null) break;
            const sp: [*]const u8 = @ptrFromInt(str_addr);
            var slen: usize = 0;
            while (slen < ENV_BUF_SIZE - env_total - 1 and sp[slen] != 0) : (slen += 1) {
                env_buf[env_total + slen] = sp[slen];
            }
            env_buf[env_total + slen] = 0;
            env_lens[envc] = slen;
            env_total += slen + 1;
            envc += 1;
            envp_ptr += 8;
        }
    }

    // 3. Resolve executable inode and check permission
    var exec_inode = vfs.resolve(path_buf[0..path_len]) orelse {
        uart.print("[execve] P{} ENOENT: ", .{current.pid});
        for (0..path_len) |pi| uart.writeByte(path_buf[pi]);
        uart.writeByte('\n');
        frame.x[0] = @bitCast(@as(i64, -2)); // -ENOENT
        return;
    };

    if (!checkExecPermission(exec_inode, current)) {
        uart.print("[execve] P{} EACCES\n", .{current.pid});
        frame.x[0] = @bitCast(@as(i64, -13)); // -EACCES
        return;
    }

    // Read first 4 KiB of the file (ELF header + program headers)
    var hdr_bytes = readFileHead(exec_inode, &elf_hdr_buf) orelse {
        uart.print("[execve] P{} readFileHead failed\n", .{current.pid});
        frame.x[0] = @bitCast(@as(i64, -2)); // -ENOENT
        return;
    };

    if (hdr_bytes == 0) {
        uart.print("[execve] P{} hdr_bytes=0\n", .{current.pid});
        frame.x[0] = @bitCast(@as(i64, -8)); // -ENOEXEC
        return;
    }

    // 4. Validate ELF header; handle #! shebang scripts
    const elf_hdr_check = elf.getHeader(elf_hdr_buf[0..hdr_bytes]);
    if (elf_hdr_check == null) {
        uart.print("[execve] P{} getHeader null, hdr_bytes={}, magic={x}{x}{x}{x}\n", .{
            current.pid, hdr_bytes, elf_hdr_buf[0], elf_hdr_buf[1], elf_hdr_buf[2], elf_hdr_buf[3],
        });
    }
    if (elf_hdr_check == null) {
        if (hdr_bytes >= 2 and elf_hdr_buf[0] == '#' and elf_hdr_buf[1] == '!') {
            // Parse interpreter path from shebang line
            var interp_start: usize = 2;
            while (interp_start < hdr_bytes and elf_hdr_buf[interp_start] == ' ') interp_start += 1;
            var interp_end: usize = interp_start;
            while (interp_end < hdr_bytes and elf_hdr_buf[interp_end] != '\n' and
                elf_hdr_buf[interp_end] != ' ' and elf_hdr_buf[interp_end] != '\r') interp_end += 1;

            const ipath_len = interp_end - interp_start;
            if (ipath_len == 0) {
                frame.x[0] = @bitCast(@as(i64, -8)); // -ENOEXEC
                return;
            }

            // Save original path and argv before rebuilding
            var orig_path: [256]u8 = undefined;
            for (0..path_len) |k| orig_path[k] = path_buf[k];
            const orig_path_len = path_len;

            var saved_args: [ARG_BUF_SIZE]u8 = undefined;
            var saved_offsets: [MAX_ARGS]usize = undefined;
            var saved_lens: [MAX_ARGS]usize = undefined;
            const saved_argc = argc;
            for (0..arg_total) |k| saved_args[k] = arg_buf[k];
            for (0..argc) |k| {
                saved_offsets[k] = arg_offsets[k];
                saved_lens[k] = arg_lens[k];
            }

            // Rebuild: argv[0]=interpreter, argv[1]=script, argv[2:]=orig[1:]
            arg_total = 0;
            argc = 0;

            arg_offsets[0] = 0;
            arg_lens[0] = ipath_len;
            for (0..ipath_len) |k| arg_buf[k] = elf_hdr_buf[interp_start + k];
            arg_buf[ipath_len] = 0;
            arg_total = ipath_len + 1;
            argc = 1;

            if (arg_total + orig_path_len + 1 <= ARG_BUF_SIZE) {
                arg_offsets[argc] = arg_total;
                arg_lens[argc] = orig_path_len;
                for (0..orig_path_len) |k| arg_buf[arg_total + k] = orig_path[k];
                arg_buf[arg_total + orig_path_len] = 0;
                arg_total += orig_path_len + 1;
                argc += 1;
            }

            var oi: usize = 1;
            while (oi < saved_argc and argc < MAX_ARGS) : (oi += 1) {
                const olen = saved_lens[oi];
                if (arg_total + olen + 1 > ARG_BUF_SIZE) break;
                arg_offsets[argc] = arg_total;
                arg_lens[argc] = olen;
                for (0..olen) |k| arg_buf[arg_total + k] = saved_args[saved_offsets[oi] + k];
                arg_buf[arg_total + olen] = 0;
                arg_total += olen + 1;
                argc += 1;
            }

            // Update path to interpreter and re-resolve inode
            path_len = ipath_len;
            for (0..ipath_len) |k| path_buf[k] = elf_hdr_buf[interp_start + k];

            exec_inode = vfs.resolve(path_buf[0..path_len]) orelse {
                frame.x[0] = @bitCast(@as(i64, -2)); // -ENOENT
                return;
            };
            hdr_bytes = readFileHead(exec_inode, &elf_hdr_buf) orelse {
                frame.x[0] = @bitCast(@as(i64, -2)); // -ENOENT
                return;
            };
            if (hdr_bytes == 0 or elf.getHeader(elf_hdr_buf[0..hdr_bytes]) == null) {
                frame.x[0] = @bitCast(@as(i64, -8)); // -ENOEXEC
                return;
            }
        } else {
            frame.x[0] = @bitCast(@as(i64, -8)); // -ENOEXEC
            return;
        }
    }

    // Store executable path for /proc/self/exe
    for (0..path_len) |pi| {
        current.exe_path[pi] = path_buf[pi];
    }
    current.exe_path_len = @truncate(path_len);

    // === Point of no return — destroy old address space ===

    // 5. Tear down old user pages and flush stale TLB entries.
    // Without the TLB flush, subsequent PMM allocations may reuse freed
    // page-table pages while stale TLB entries still point to the old
    // physical frames. Kernel writes to user VAs (argv/envp setup below)
    // would then corrupt the newly-allocated page tables, causing address
    // size faults (DFSC=2) when the user process resumes.
    vmm.destroyUserPages(vmm.PhysAddr.from(current.page_table));
    vmm.invalidateAll();

    // Unpin only THIS process's previously pinned executable inode.
    // unpinAllInodes() was wrong — it nuked every process's pins, causing
    // demand paging to read from recycled inode cache slots (wrong file data).
    if (current.pinned_exec_inode) |prev_inode| {
        ext2.unpinInode(prev_inode);
        current.pinned_exec_inode = null;
    }

    // Release file refs from old VMAs before clearing (prevents FileDescription leaks)
    vma.releaseAllFileRefs(&current.vmas);
    // Reset VMAs before adding new ones
    vma.initVmaList(&current.vmas);

    // 6. Parse ELF header and create demand-paged VMAs for each PT_LOAD segment
    const header = elf.getHeader(elf_hdr_buf[0..hdr_bytes]).?;
    var highest_addr: u64 = 0;
    var lowest_addr: u64 = 0xFFFFFFFFFFFFFFFF;
    var segments_loaded: u32 = 0;

    // Allocate a persistent FileDescription for demand paging.
    // This must outlive execve since page faults will read from it.
    const exec_fd = vfs.allocFileDescription() orelse {
        uart.writeString("[execve] Failed to alloc file description\n");
        closeAllFds(current);
        current.state = .zombie;
        current.exit_status = 127;
        scheduler.schedule(frame);
        return;
    };
    exec_fd.inode = exec_inode;
    exec_fd.offset = 0;
    exec_fd.flags = vfs.O_RDONLY;

    var ph_i: u16 = 0;
    while (ph_i < header.e_phnum) : (ph_i += 1) {
        const phdr_off = header.e_phoff + @as(u64, ph_i) * @as(u64, header.e_phentsize);
        if (phdr_off + @sizeOf(elf.Elf64Phdr) > hdr_bytes) continue;

        const phdr: *align(1) const elf.Elf64Phdr = @ptrCast(&elf_hdr_buf[@as(usize, @truncate(phdr_off))]);
        if (phdr.p_type != 1) continue; // PT_LOAD only

        // Page-aligned segment boundaries
        const seg_start = phdr.p_vaddr & ~@as(u64, 0xFFF);
        const seg_end = pageAlignUp(phdr.p_vaddr + phdr.p_memsz);

        // VMA flags from ELF segment flags (ARM64 packed struct format)
        const vma_flags = vma.VmaFlags{
            .readable = (phdr.p_flags & 4) != 0, // PF_R
            .writable = (phdr.p_flags & 2) != 0, // PF_W
            .executable = (phdr.p_flags & 1) != 0, // PF_X
            .user = true,
            .file_backed = true,
        };

        // File offset aligned to page boundary
        const p_offset_aligned = phdr.p_offset & ~@as(u64, 0xFFF);
        // file_size = how many bytes of VMA are file-backed (includes page-offset padding)
        const file_size = phdr.p_filesz + (phdr.p_vaddr & 0xFFF);

        // Create file-backed VMA for this segment (demand-paged)
        _ = vma.addElfVma(
            &current.vmas,
            seg_start,
            seg_end,
            vma_flags,
            exec_fd,
            p_offset_aligned,
            file_size,
        );

        segments_loaded += 1;

        if (seg_end > highest_addr) highest_addr = seg_end;
        if (seg_start < lowest_addr) lowest_addr = seg_start;
    }

    if (segments_loaded == 0) {
        vfs.releaseFileDescription(exec_fd);
        uart.writeString("[execve] No PT_LOAD segments found\n");
        closeAllFds(current);
        current.state = .zombie;
        current.exit_status = 127;
        scheduler.schedule(frame);
        return;
    }

    // Release the creator's reference to exec_fd. Each addElfVma call above
    // incremented ref_count, so the VMAs now own the remaining references.
    // When VMAs are cleaned up (next execve or exit), refs will be released.
    vfs.releaseFileDescription(exec_fd);

    // Pin the executable inode so it doesn't get evicted from cache during demand paging
    ext2.pinInode(exec_inode);
    current.pinned_exec_inode = exec_inode;

    // 7. Allocate and map new user stack
    var s: u64 = 0;
    while (s < process.USER_STACK_PAGES) : (s += 1) {
        const stack_page = pmm.allocPage() orelse {
            closeAllFds(current);
            current.state = .zombie;
            current.exit_status = 127;
            scheduler.schedule(frame);
            return;
        };
        zeroPage(stack_page);
        const vaddr = process.USER_STACK_TOP - (process.USER_STACK_PAGES - s) * 4096;
        vmm.mapPage(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(vaddr), vmm.PhysAddr.from(stack_page), .{
            .user = true,
            .writable = true,
            .executable = false,
        }) catch {
            closeAllFds(current);
            current.state = .zombie;
            current.exit_status = 127;
            scheduler.schedule(frame);
            return;
        };
    }

    // 8. Set up initial stack layout (same as Linux):
    //    [argv string data] [envp string data] [16 random bytes] [padding]
    //    argc, argv[0..], NULL, envp[0..], NULL, auxv pairs..., AT_NULL

    var str_pos: u64 = process.USER_STACK_TOP;
    var user_argv_addrs: [MAX_ARGS]u64 = undefined;

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const slen = arg_lens[i] + 1; // +1 for NUL
        str_pos -= slen;
        // Write string to user stack (identity mapped)
        const dst: [*]u8 = @ptrFromInt(str_pos);
        for (0..slen) |k| dst[k] = arg_buf[arg_offsets[i] + k];
        user_argv_addrs[i] = str_pos;
    }

    var user_envp_addrs: [MAX_ENV_ARGS]u64 = undefined;
    var ei: usize = 0;
    while (ei < envc) : (ei += 1) {
        const slen = env_lens[ei] + 1;
        str_pos -= slen;
        const dst: [*]u8 = @ptrFromInt(str_pos);
        for (0..slen) |k| dst[k] = env_buf[env_offsets[ei] + k];
        user_envp_addrs[ei] = str_pos;
    }

    // Write 16 random bytes for AT_RANDOM
    str_pos -= 16;
    const random_addr = str_pos;
    {
        var rand_buf: [16]u8 = undefined;
        // Use CNTVCT_EL0-based PRNG for random bytes
        var seed: u64 = readCounter();
        for (0..16) |ri| {
            seed = seed *% 6364136223846793005 +% 1;
            rand_buf[ri] = @truncate(seed >> 33);
        }
        const rand_dst: [*]u8 = @ptrFromInt(random_addr);
        for (0..16) |ri| rand_dst[ri] = rand_buf[ri];
    }

    // Align down to 16 bytes (ARM64 SP must be 16-byte aligned)
    str_pos = str_pos & ~@as(u64, 0xF);

    // Calculate SP: argc + argv ptrs + NULL + envp ptrs + NULL + auxv entries
    // auxv: AT_PHDR, AT_PHENT, AT_PHNUM, AT_PAGESZ, AT_ENTRY, AT_UID, AT_EUID,
    //        AT_GID, AT_EGID, AT_RANDOM, AT_CLKTCK, AT_NULL = 12 pairs = 24 u64s
    const auxv_count: usize = 24; // 12 key-value pairs
    const n_entries = 1 + argc + 1 + envc + 1 + auxv_count;
    var new_sp = str_pos - n_entries * 8;
    new_sp = new_sp & ~@as(u64, 0xF); // 16-byte align

    // Write stack entries
    var pos: u64 = new_sp;

    // argc
    writeUserU64(pos, argc);
    pos += 8;

    // argv[0..argc]
    var j: usize = 0;
    while (j < argc) : (j += 1) {
        writeUserU64(pos, user_argv_addrs[j]);
        pos += 8;
    }

    // argv terminator
    writeUserU64(pos, 0);
    pos += 8;

    // envp[0..envc]
    var ej: usize = 0;
    while (ej < envc) : (ej += 1) {
        writeUserU64(pos, user_envp_addrs[ej]);
        pos += 8;
    }

    // envp terminator
    writeUserU64(pos, 0);
    pos += 8;

    // Auxiliary vector
    // AT_PHDR (3) = address of program headers in memory
    const at_phdr_addr = lowest_addr + header.e_phoff;
    writeUserU64(pos, 3); // AT_PHDR
    pos += 8;
    writeUserU64(pos, at_phdr_addr);
    pos += 8;

    // AT_PHENT (4) = size of program header entry
    writeUserU64(pos, 4); // AT_PHENT
    pos += 8;
    writeUserU64(pos, header.e_phentsize);
    pos += 8;

    // AT_PHNUM (5) = number of program headers
    writeUserU64(pos, 5); // AT_PHNUM
    pos += 8;
    writeUserU64(pos, header.e_phnum);
    pos += 8;

    // AT_PAGESZ (6) = page size
    writeUserU64(pos, 6); // AT_PAGESZ
    pos += 8;
    writeUserU64(pos, 4096);
    pos += 8;

    // AT_ENTRY (9) = entry point
    writeUserU64(pos, 9); // AT_ENTRY
    pos += 8;
    writeUserU64(pos, header.e_entry);
    pos += 8;

    // AT_UID (11) = real uid
    writeUserU64(pos, 11); // AT_UID
    pos += 8;
    writeUserU64(pos, current.uid);
    pos += 8;

    // AT_EUID (12) = effective uid
    writeUserU64(pos, 12); // AT_EUID
    pos += 8;
    writeUserU64(pos, current.euid);
    pos += 8;

    // AT_GID (13) = real gid
    writeUserU64(pos, 13); // AT_GID
    pos += 8;
    writeUserU64(pos, current.gid);
    pos += 8;

    // AT_EGID (14) = effective gid
    writeUserU64(pos, 14); // AT_EGID
    pos += 8;
    writeUserU64(pos, current.egid);
    pos += 8;

    // AT_CLKTCK (17) = clock ticks per second
    writeUserU64(pos, 17); // AT_CLKTCK
    pos += 8;
    writeUserU64(pos, 100);
    pos += 8;

    // AT_RANDOM (25) = pointer to 16 random bytes
    writeUserU64(pos, 25); // AT_RANDOM
    pos += 8;
    writeUserU64(pos, random_addr);
    pos += 8;

    // AT_NULL (0) = end of auxv
    writeUserU64(pos, 0); // AT_NULL
    pos += 8;
    writeUserU64(pos, 0);
    pos += 8;

    // 9. Update process state
    current.heap_start = highest_addr;
    current.heap_current = highest_addr;
    current.mmap_hint = process.aslrMmapBase(); // ASLR: randomized top-down base

    // Add stack VMA (ELF VMAs already added above)
    // No heap VMA created here — sysBrk creates/extends it on first use.
    _ = vma.addVma(&current.vmas, process.USER_STACK_TOP - process.USER_STACK_VMA_PAGES * 4096, process.USER_STACK_TOP, .{
        .readable = true, .writable = true, .user = true, .stack = true,
    });

    // Reset signal handlers to SIG_DFL (per POSIX)
    for (0..process.MAX_SIGNALS) |si| {
        current.sig_actions[si] = .{};
    }
    current.sig_pending = 0;
    current.clear_child_tid = 0;
    current.tls_base = 0;

    // Close FD_CLOEXEC file descriptors (POSIX: per-fd flag, NOT per-FileDescription)
    for (0..fd_table.MAX_FDS) |fi| {
        if (current.fds[fi]) |desc| {
            if (current.fd_cloexec[fi]) {
                vfs.releaseFileDescription(desc);
                current.fds[fi] = null;
                current.fd_cloexec[fi] = false;
            }
        }
    }

    // 10. Set trap frame to new entry point
    for (0..31) |xi| {
        frame.x[xi] = 0;
    }
    frame.elr = header.e_entry; // PC = new entry point
    frame.sp = new_sp; // SP = top of new stack
    frame.spsr = 0; // EL0, AArch64, all exceptions unmasked

    uart.print("[execve] P{} entry={x} sp={x} segs={} ", .{ current.pid, header.e_entry, new_sp, segments_loaded });
    for (0..path_len) |pi| uart.writeByte(path_buf[pi]);
    uart.writeByte('\n');

    // Flush TLB by reloading TTBR0
    vmm.switchAddressSpace(vmm.PhysAddr.from(current.page_table));

    // Return from exception will enter the new program
}

/// Read a u64 from a user-space address (identity mapped)
fn readUserU64(addr: u64) u64 {
    const p: [*]const u8 = @ptrFromInt(addr);
    var val: u64 = 0;
    for (0..8) |k| {
        val |= @as(u64, p[k]) << @intCast(k * 8);
    }
    return val;
}

/// Write a u64 to a user-space address (identity mapped)
fn writeUserU64(addr: u64, val: u64) void {
    const p: [*]u8 = @ptrFromInt(addr);
    var v = val;
    for (0..8) |k| {
        p[k] = @truncate(v);
        v >>= 8;
    }
}

/// Zero a physical page (identity mapped)
fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..4096) |k| {
        ptr[k] = 0;
    }
}

/// ppoll(fds, nfds, tmo_p, sigmask, sigsetsize) -> ready count
/// Checks actual readiness for pipe fds (data available, EOF, writable).
/// Non-pipe fds (regular files) are reported as always ready.
/// If no fds are ready and timeout is non-zero, blocks until a pipe
/// becomes readable then replays the syscall.
fn sysPpoll(frame: *exception.TrapFrame) i64 {
    const fds_addr = frame.x[0];
    const nfds = frame.x[1];
    const tmo_addr = frame.x[2];

    const proc = scheduler.currentProcess() orelse return -3; // -ESRCH

    if (nfds == 0) return 0;

    const actual_nfds: usize = if (nfds > 64) 64 else @truncate(nfds);
    const POLLFD_SIZE: usize = 8; // struct pollfd: i32 fd + i16 events + i16 revents

    // Collect pipe inodes for the blocking phase
    var pipe_inodes: [64]?*vfs.Inode = [_]?*vfs.Inode{null} ** 64;
    var has_pipes = false;

    while (true) {
        // Phase 1: Check actual readiness of each fd
        var ready: usize = 0;

        for (0..actual_nfds) |i| {
            const entry_addr = fds_addr + i * POLLFD_SIZE;
            if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(entry_addr)) == null) {
                // Demand-page the pollfd array
                if (!exception.demandPageUser(entry_addr & ~@as(u64, 0xFFF))) break;
            }

            const pfd: [*]u8 = @ptrFromInt(entry_addr);

            const fd: i32 = @bitCast(@as(u32, pfd[0]) | (@as(u32, pfd[1]) << 8) |
                (@as(u32, pfd[2]) << 16) | (@as(u32, pfd[3]) << 24));
            const events: i16 = @bitCast(@as(u16, pfd[4]) | (@as(u16, pfd[5]) << 8));

            var revents: i16 = 0;
            if (fd >= 0 and fd < @as(i32, @intCast(fd_table.MAX_FDS))) {
                if (fd_table.fdGet(&proc.fds, @intCast(fd))) |desc| {
                    if (@intFromPtr(desc.inode) == 0) {
                        revents = 0x0020; // POLLNVAL — treat null inode as invalid
                    } else if (pipe.isPipeInode(desc.inode)) {
                        // Check actual pipe readiness
                        const pr = pipe.checkReadiness(desc.inode);
                        if (pr & 0x001 != 0 and events & 1 != 0) revents |= 1; // POLLIN
                        if (pr & 0x004 != 0 and events & 4 != 0) revents |= 4; // POLLOUT
                        if (pr & 0x010 != 0) revents |= 0x10; // POLLHUP (always reported)
                        // Track pipe inodes for potential blocking
                        if (events & 1 != 0) {
                            pipe_inodes[i] = desc.inode;
                            has_pipes = true;
                        }
                    } else {
                        // Non-pipe fds (regular files, sockets) are always ready
                        revents = events & 0x0045; // POLLIN | POLLPRI | POLLOUT
                    }
                    if (revents != 0) ready += 1;
                } else {
                    revents = 0x0020; // POLLNVAL
                }
            } else {
                revents = 0x0020; // POLLNVAL
            }

            pfd[6] = @truncate(@as(u16, @bitCast(revents)));
            pfd[7] = @truncate(@as(u16, @bitCast(revents)) >> 8);
        }

        if (ready > 0) {
            return @intCast(ready);
        }

        // Phase 2: Nothing ready — check if we should block
        // timeout == NULL (0) means infinite wait; {0,0} means non-blocking
        if (tmo_addr != 0) {
            if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(tmo_addr)) != null) {
                const tmo: [*]const u8 = @ptrFromInt(tmo_addr);
                var tv_sec: u64 = 0;
                for (0..8) |k| tv_sec |= @as(u64, tmo[k]) << @intCast(k * 8);
                var tv_nsec: u64 = 0;
                for (0..8) |k| tv_nsec |= @as(u64, tmo[8 + k]) << @intCast(k * 8);
                if (tv_sec == 0 and tv_nsec == 0) return 0; // Non-blocking poll
            }
        }

        // No pipe fds to wait on — can't block, return 0
        if (!has_pipes) return 0;

        // Phase 3: Atomically re-check pipe readiness and block if still empty.
        // pollRegisterOrReady closes the TOCTOU race between Phase 1 check and
        // the blocking decision by holding pipe_lock across both operations.
        if (pipe.pollRegisterOrReady(pipe_inodes[0..actual_nfds])) {
            // A pipe became ready during the race window — loop back to Phase 1
            continue;
        }

        // Process is now .blocked (set atomically under pipe_lock).
        // Rewind PC to replay SVC on wake — the next ppoll invocation
        // will find ready fds in Phase 1.
        frame.elr -= 4;
        scheduler.blockAndSchedule(frame);
        return 0;
    }
}

/// getrusage(who, usage) -> 0
/// Returns a zeroed rusage struct (144 bytes). Sufficient for programs that
/// only check whether the call succeeds.
fn sysGetrusage(frame: *exception.TrapFrame) i64 {
    const buf_addr = frame.x[1];
    const proc = scheduler.currentProcess() orelse return -3; // -ESRCH
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(buf_addr)) == null) return -14; // -EFAULT

    // Zero-fill the 144-byte struct rusage
    const buf: [*]u8 = @ptrFromInt(buf_addr);
    for (0..144) |i| {
        buf[i] = 0;
    }
    return 0;
}

/// statfs/fstatfs(path_or_fd, buf) -> 0
/// Returns a synthetic statfs struct representing a basic ext2-like filesystem.
fn sysStatfs(frame: *exception.TrapFrame) i64 {
    const buf_addr = frame.x[1];
    const proc = scheduler.currentProcess() orelse return -3; // -ESRCH
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(buf_addr)) == null) return -14; // -EFAULT

    const buf: [*]u8 = @ptrFromInt(buf_addr);
    // Zero the struct first (120 bytes covers the statfs64 layout)
    for (0..120) |i| {
        buf[i] = 0;
    }

    // Get real values from ext2 superblock
    const sb = ext2.getSuperblockInfo();

    writeU64(buf, 0, 0xEF53); // f_type = EXT2_SUPER_MAGIC
    writeU64(buf, 8, sb.block_size); // f_bsize
    writeU64(buf, 16, sb.blocks_count); // f_blocks
    writeU64(buf, 24, sb.free_blocks); // f_bfree
    writeU64(buf, 32, sb.free_blocks); // f_bavail (same as bfree, no reserved blocks)
    writeU64(buf, 40, sb.inodes_count); // f_files
    writeU64(buf, 48, sb.free_inodes); // f_ffree
    // f_namelen (offset 88) = 255
    writeU64(buf, 88, 255);
    return 0;
}

/// clock_nanosleep(clockid, flags, request, remain) -> 0
/// Delegates to the existing sysNanosleep after shifting arguments:
/// nanosleep expects (request=x0, remain=x1) but clock_nanosleep
/// passes (clockid=x0, flags=x1, request=x2, remain=x3).
fn sysClockNanosleep(frame: *exception.TrapFrame) i64 {
    frame.x[0] = frame.x[2]; // request pointer
    frame.x[1] = frame.x[3]; // remain pointer
    return sysNanosleep(frame);
}

/// Read the first `buf.len` bytes of a file via inode read op. Returns bytes read.
fn readFileHead(inode: *vfs.Inode, buf: []u8) ?usize {
    const read_fn = inode.ops.read orelse return null;
    var desc = vfs.FileDescription{
        .inode = inode,
        .offset = 0,
        .flags = vfs.O_RDONLY,
        .ref_count = 1,
        .in_use = true,
    };
    var total: usize = 0;
    var retries: u32 = 0;
    while (total < buf.len) {
        const chunk = @min(buf.len - total, 4096);
        const ptr: [*]u8 = @ptrCast(&buf[total]);
        const n = read_fn(&desc, ptr, chunk);
        if (n <= 0) {
            // Retry on transient I/O failure (NVMe timeout after heavy I/O).
            // After compilation (8K+ writes), the NVMe device may need time
            // to recover before handling the 152 MB zig binary re-exec for LLD.
            retries += 1;
            if (retries < 20) {
                // Brief delay: yield to let NVMe completion queue drain
                var delay: u32 = 0;
                while (delay < 100_000) : (delay += 1) {
                    asm volatile ("yield");
                }
                desc.offset = total;
                continue;
            }
            break;
        }
        retries = 0;
        total += @intCast(n);
    }
    return total;
}

/// Read ARM64 virtual counter register for PRNG seeding
fn readCounter() u64 {
    return asm volatile ("mrs %[ret], CNTVCT_EL0"
        : [ret] "=r" (-> u64),
    );
}

/// Align an address up to the next page boundary
fn pageAlignUp(addr: u64) u64 {
    return (addr + 4095) & ~@as(u64, 4095);
}

/// Check if a process has execute permission on an inode.
/// Note: ARM64 Inode does not carry uid/gid, so we check mode bits
/// with owner/group defaulting to 0. Root always passes.
fn checkExecPermission(inode: *vfs.Inode, proc: *process.Process) bool {
    if (proc.euid == 0) return true;
    const mode = inode.mode & 0o7777;
    // Without uid/gid on Inode, treat all non-root as "other" class
    const bits: u32 = mode & 7;
    return (bits & 1) != 0;
}

// ============================================================================
// TCP listen/accept — A28
// ============================================================================

/// listen(sockfd, backlog) — nr 201
fn sysListen(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    // backlog = frame.x[1] (ignored — fixed accept queue of 4)

    const current = scheduler.currentProcess() orelse return -3; // -ESRCH

    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9; // -EBADF

    const sock_idx = socket.getSocketIndexFromInode(desc.inode) orelse return -9;
    const sock = socket.getSocket(sock_idx) orelse return -9;

    // Must be a bound TCP socket
    if (sock.sock_type != socket.SOCK_STREAM) return -95; // -EOPNOTSUPP
    if (sock.bound_port == 0) return -22; // -EINVAL

    // Free the pre-allocated TCP connection (listening sockets don't use one)
    tcp.freeConnection(sock.tcp_conn_idx);
    sock.tcp_conn_idx = tcp.MAX_TCP_CONNECTIONS; // sentinel

    sock.listening = true;
    uart.print("[syscall] listen(port={}) ok\n", .{sock.bound_port});
    return 0;
}

/// accept(sockfd, addr, addrlen) — nr 202
fn sysAccept(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const addr_ptr = frame.x[1];
    // addrlen_ptr = frame.x[2] (ignored for MVP)

    const current = scheduler.currentProcess() orelse return -3; // -ESRCH

    const desc = fd_table.fdGet(&current.fds, fd) orelse return -9; // -EBADF

    const sock_idx = socket.getSocketIndexFromInode(desc.inode) orelse return -9;
    const sock = socket.getSocket(sock_idx) orelse return -9;

    if (!sock.listening) return -22; // -EINVAL

    // Check for queued connections
    if (sock.accept_count == 0) {
        // Block until a connection arrives
        sock.accept_waiting_pid = current.pid;
        current.state = .blocked_on_net;
        frame.elr -= 4; // Replay SVC on wakeup (SVC is 4 bytes on ARM64)
        scheduler.blockAndSchedule(frame);
        return 0; // Never reached — frame belongs to different process after blockAndSchedule
    }

    // Dequeue completed connection
    const conn_idx = sock.accept_queue[sock.accept_head];
    sock.accept_head = @truncate((@as(usize, sock.accept_head) + 1) % 4);
    sock.accept_count -= 1;

    const conn = tcp.getConnection(conn_idx) orelse return -103; // -ECONNABORTED

    // Create new socket wrapping this connection
    const new_sock_idx = socket.allocSocketWithConn(socket.AF_INET, socket.SOCK_STREAM, 0, conn_idx) orelse return -23; // -ENFILE

    // Set remote address on the new socket
    const new_sock = socket.getSocket(new_sock_idx) orelse return -23;
    new_sock.remote_ip = conn.remote_ip;
    new_sock.remote_port = conn.remote_port;
    new_sock.bound_port = conn.local_port;

    // Create VFS FileDescription + fd
    const new_desc = vfs.allocFileDescription() orelse return -23; // -ENFILE
    new_desc.inode = socket.getSocketInode(new_sock_idx);
    new_desc.flags = 2; // O_RDWR
    new_desc.offset = 0;

    const new_fd = fd_table.fdAlloc(&current.fds, new_desc) orelse {
        vfs.releaseFileDescription(new_desc);
        return -24; // -EMFILE
    };

    // Write peer address to user if requested
    if (addr_ptr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(addr_ptr)) != null) {
            var sa_buf: [16]u8 = [_]u8{0} ** 16;
            sa_buf[0] = @truncate(socket.AF_INET); // sa_family low byte
            sa_buf[1] = @truncate(socket.AF_INET >> 8);
            ethernet.putU16BE(sa_buf[2..4], conn.remote_port);
            ethernet.putU32BE(sa_buf[4..8], conn.remote_ip);
            const dest: [*]u8 = @ptrFromInt(addr_ptr);
            for (0..16) |i| {
                dest[i] = sa_buf[i];
            }
        }
    }

    uart.print("[syscall] accept() -> fd {} (remote {}:{})\n", .{ new_fd, conn.remote_ip, conn.remote_port });
    return @intCast(new_fd);
}

// ============================================================================
// Hugepage allocation — A28 DPDK foundation
// ============================================================================

/// net_hugepage_alloc(size_hint) — nr 281
/// Allocate a 2MB hugepage and map it into the caller's address space.
/// Returns userspace virtual address of the mapped region.
fn sysNetHugepageAlloc(frame: *exception.TrapFrame) i64 {
    _ = frame.x[0]; // size_hint (reserved, currently always allocates 2MB)

    const current = scheduler.currentProcess() orelse return -3; // -ESRCH

    // Allocate a 2MB hugepage from PMM
    const phys = pmm.allocHugePage() orelse return -12; // -ENOMEM

    // Map all 512 pages into user address space (top-down)
    const pages = pmm.HUGE_PAGE_PAGES;
    const alloc_size = pages * pmm.PAGE_SIZE;
    if (current.mmap_hint < MMAP_REGION_START + alloc_size) {
        pmm.freeHugePage(phys);
        return -12;
    }
    current.mmap_hint -= alloc_size;
    const user_base = current.mmap_hint;

    var i: u64 = 0;
    while (i < pages) : (i += 1) {
        const page_phys = phys + i * pmm.PAGE_SIZE;
        const page_virt = user_base + i * pmm.PAGE_SIZE;
        vmm.mapPage(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(page_virt), vmm.PhysAddr.from(page_phys), .{
            .writable = true,
            .user = true,
            .executable = false,
        }) catch {
            pmm.freeHugePage(phys);
            return -12; // -ENOMEM
        };
    }

    uart.print("[syscall] net_hugepage_alloc -> 0x{x} (2MB)\n", .{user_base});
    return @bitCast(user_base);
}

/// sched_dedicate(core_id) — nr 503 (Zigix custom).
/// Pins the calling process to a CPU core with zero preemption.
/// On single-CPU Zigix, core_id must be 0.
fn sysSchedDedicate(frame: *exception.TrapFrame) i64 {
    const core_id = frame.x[0];

    const current = scheduler.currentProcess() orelse return -3; // -ESRCH

    // Single-CPU: only core 0 is valid
    if (core_id != 0) return -22; // -EINVAL

    // Check if another process already holds the core
    if (scheduler.isDedicated()) return -16; // -EBUSY

    scheduler.setDedicated(current.pid);
    return 0;
}

/// sched_release() — nr 504 (Zigix custom).
/// Releases the dedicated core, resuming normal scheduling.
fn sysSchedRelease(frame: *exception.TrapFrame) i64 {
    _ = frame;
    scheduler.clearDedicated();
    return 0;
}

/// sendfile(out_fd, in_fd, offset, count) -> bytes_sent
/// Copies data between file descriptors in-kernel.
fn sysSendfile(frame: *exception.TrapFrame) i64 {
    const out_fd = frame.x[0];
    const in_fd = frame.x[1];
    const off_ptr = frame.x[2]; // *off_t or NULL
    const count = frame.x[3];

    const proc = scheduler.currentProcess() orelse return -9;

    const desc_in = fd_table.fdGet(&proc.fds, in_fd) orelse return -9; // -EBADF
    const desc_out = fd_table.fdGet(&proc.fds, out_fd) orelse return -9;

    const read_fn = desc_in.inode.ops.read orelse return -22; // -EINVAL
    const write_fn = desc_out.inode.ops.write orelse return -22;

    // Handle optional offset pointer
    const saved_offset = desc_in.offset;
    if (off_ptr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(off_ptr))) |_| {
            const off_bytes: [*]const u8 = @ptrFromInt(off_ptr);
            var off_val: u64 = 0;
            for (0..8) |i| {
                off_val |= @as(u64, off_bytes[i]) << @intCast(i * 8);
            }
            desc_in.offset = off_val;
        } else return -14; // -EFAULT
    }

    // Use a kernel-side bounce buffer (4KB at a time)
    const bounce_page = pmm.allocPage() orelse return -12; // -ENOMEM
    defer pmm.freePage(bounce_page);
    const bounce: [*]u8 = @ptrFromInt(bounce_page);

    var total: u64 = 0;
    const max = if (count > 1024 * 1024) @as(u64, 1024 * 1024) else count; // cap at 1MB

    while (total < max) {
        const chunk: usize = @intCast(@min(max - total, 4096));
        const nr = read_fn(desc_in, bounce, chunk);
        if (nr <= 0) break;

        const nw = write_fn(desc_out, bounce, @intCast(nr));
        if (nw <= 0) break;
        total += @intCast(nw);
        if (nw < nr) break;
    }

    // Write back updated offset if pointer provided
    if (off_ptr != 0) {
        const off_bytes: [*]u8 = @ptrFromInt(off_ptr);
        const new_off = desc_in.offset;
        for (0..8) |i| {
            off_bytes[i] = @truncate(new_off >> @intCast(i * 8));
        }
        desc_in.offset = saved_offset; // Restore file position (sendfile uses offset ptr)
    }

    return @intCast(total);
}

/// splice(fd_in, off_in, fd_out, off_out, len, flags) -> bytes transferred
/// Transfers data between a pipe and a file descriptor (or between two pipes).
fn sysSplice(frame: *exception.TrapFrame) i64 {
    const fd_in = frame.x[0];
    const off_in_ptr = frame.x[1];
    const fd_out = frame.x[2];
    const off_out_ptr = frame.x[3];
    const len = frame.x[4];
    // flags = frame.x[5] (SPLICE_F_MOVE, SPLICE_F_NONBLOCK, etc. — ignored for now)

    const proc = scheduler.currentProcess() orelse return -9;
    const desc_in = fd_table.fdGet(&proc.fds, fd_in) orelse return -9;
    const desc_out = fd_table.fdGet(&proc.fds, fd_out) orelse return -9;

    const read_fn = desc_in.inode.ops.read orelse return -22;
    const write_fn = desc_out.inode.ops.write orelse return -22;

    // Handle optional offset pointers (only for non-pipe fds)
    const saved_in_offset = desc_in.offset;
    const saved_out_offset = desc_out.offset;
    if (off_in_ptr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(off_in_ptr))) |_| {
            const ob: [*]const u8 = @ptrFromInt(off_in_ptr);
            var v: u64 = 0;
            for (0..8) |i| v |= @as(u64, ob[i]) << @intCast(i * 8);
            desc_in.offset = v;
        } else return -14;
    }
    if (off_out_ptr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(off_out_ptr))) |_| {
            const ob: [*]const u8 = @ptrFromInt(off_out_ptr);
            var v: u64 = 0;
            for (0..8) |i| v |= @as(u64, ob[i]) << @intCast(i * 8);
            desc_out.offset = v;
        } else return -14;
    }

    const bounce_page = pmm.allocPage() orelse return -12;
    defer pmm.freePage(bounce_page);
    const bounce: [*]u8 = @ptrFromInt(bounce_page);

    var total: u64 = 0;
    const max = if (len > 1024 * 1024) @as(u64, 1024 * 1024) else len;

    while (total < max) {
        const chunk: usize = @intCast(@min(max - total, 4096));
        const nr = read_fn(desc_in, bounce, chunk);
        if (nr <= 0) break;
        const nw = write_fn(desc_out, bounce, @intCast(nr));
        if (nw <= 0) break;
        total += @intCast(nw);
        if (nw < nr) break;
    }

    // Write back updated offsets
    if (off_in_ptr != 0) {
        const ob: [*]u8 = @ptrFromInt(off_in_ptr);
        const v = desc_in.offset;
        for (0..8) |i| ob[i] = @truncate(v >> @intCast(i * 8));
        desc_in.offset = saved_in_offset;
    }
    if (off_out_ptr != 0) {
        const ob: [*]u8 = @ptrFromInt(off_out_ptr);
        const v = desc_out.offset;
        for (0..8) |i| ob[i] = @truncate(v >> @intCast(i * 8));
        desc_out.offset = saved_out_offset;
    }

    return @intCast(total);
}

/// tee(fd_in, fd_out, len, flags) -> bytes copied
/// Duplicates data from one pipe to another without consuming it.
/// Simplified: acts like splice between two pipe fds (consumes from input).
fn sysTee(frame: *exception.TrapFrame) i64 {
    const fd_in = frame.x[0];
    const fd_out = frame.x[1];
    const len = frame.x[2];
    // flags = frame.x[3] — ignored

    const proc = scheduler.currentProcess() orelse return -9;
    const desc_in = fd_table.fdGet(&proc.fds, fd_in) orelse return -9;
    const desc_out = fd_table.fdGet(&proc.fds, fd_out) orelse return -9;

    const read_fn = desc_in.inode.ops.read orelse return -22;
    const write_fn = desc_out.inode.ops.write orelse return -22;

    const bounce_page = pmm.allocPage() orelse return -12;
    defer pmm.freePage(bounce_page);
    const bounce: [*]u8 = @ptrFromInt(bounce_page);

    var total: u64 = 0;
    const max = if (len > 1024 * 1024) @as(u64, 1024 * 1024) else len;

    while (total < max) {
        const chunk: usize = @intCast(@min(max - total, 4096));
        const nr = read_fn(desc_in, bounce, chunk);
        if (nr <= 0) break;
        const nw = write_fn(desc_out, bounce, @intCast(nr));
        if (nw <= 0) break;
        total += @intCast(nw);
        if (nw < nr) break;
    }

    return @intCast(total);
}

/// Copy a null-terminated string from userspace into a kernel buffer.
fn copyUserStr(addr: u64, buf: []u8, proc: anytype) ?[]const u8 {
    if (addr == 0) return null;
    if (!ensureUserPages(proc.page_table, addr, 1)) return null;
    const ptr: [*]const u8 = @ptrFromInt(addr);
    var len: usize = 0;
    while (len < buf.len - 1 and ptr[len] != 0) : (len += 1) {
        buf[len] = ptr[len];
        const next = addr + len + 1;
        if (next & 0xFFF == 0 and len + 1 < buf.len - 1) {
            if (!ensureUserPages(proc.page_table, next, 1)) break;
        }
    }
    return buf[0..len];
}

/// Resolve path to inode number for xattr operations
fn xattrResolveIno(path_addr: u64, proc: anytype, comptime follow: bool) ?u32 {
    if (!ensureUserPages(proc.page_table, path_addr, 1)) return null;
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {
        const next = path_addr + path_len + 1;
        if (next & 0xFFF == 0 and path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next, 1)) break;
        }
    }
    const path = path_ptr[0..path_len];
    const inode = if (follow) vfs.resolve(path) else vfs.resolveNoFollow(path);
    return if (inode) |i| @as(u32, @truncate(i.ino)) else null;
}

/// getxattr/lgetxattr(path, name, value, size)
fn sysGetxattr(frame: *exception.TrapFrame, comptime nofollow: bool) i64 {
    const proc = scheduler.currentProcess() orelse return -9;
    const ino = xattrResolveIno(frame.x[0], proc, !nofollow) orelse return -2;

    const name_addr = frame.x[1];
    const value_addr = frame.x[2];
    const size = frame.x[3];

    // Copy xattr name from userspace
    var name_buf: [256]u8 = undefined;
    const name = copyUserStr(name_addr, &name_buf, proc) orelse return -14;

    if (size == 0) {
        // Size query
        var dummy: [0]u8 = undefined;
        return ext2.ext2Getxattr(ino, name, &dummy);
    }

    if (size > 65536) return -22;
    // Use stack buffer for small values, otherwise fail
    var value_buf: [4096]u8 = undefined;
    const buf_size = if (size <= 4096) @as(usize, @intCast(size)) else return -22;
    const result = ext2.ext2Getxattr(ino, name, value_buf[0..buf_size]);
    if (result < 0) return result;

    // Copy to userspace
    const len: usize = @intCast(result);
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(value_addr))) |_| {
        const dst: [*]u8 = @ptrFromInt(value_addr);
        for (0..len) |i| dst[i] = value_buf[i];
    } else return -14;

    return result;
}

/// fgetxattr(fd, name, value, size)
fn sysFgetxattr(frame: *exception.TrapFrame) i64 {
    const proc = scheduler.currentProcess() orelse return -9;
    const fd = frame.x[0];
    const desc = fd_table.fdGet(&proc.fds, fd) orelse return -9;
    const ino: u32 = @truncate(desc.inode.ino);

    const name_addr = frame.x[1];
    const value_addr = frame.x[2];
    const size = frame.x[3];

    var name_buf: [256]u8 = undefined;
    const name = copyUserStr(name_addr, &name_buf, proc) orelse return -14;

    if (size == 0) {
        var dummy: [0]u8 = undefined;
        return ext2.ext2Getxattr(ino, name, &dummy);
    }

    if (size > 4096) return -22;
    var value_buf: [4096]u8 = undefined;
    const buf_size: usize = @intCast(size);
    const result = ext2.ext2Getxattr(ino, name, value_buf[0..buf_size]);
    if (result < 0) return result;

    const len: usize = @intCast(result);
    if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(value_addr))) |_| {
        const dst: [*]u8 = @ptrFromInt(value_addr);
        for (0..len) |i| dst[i] = value_buf[i];
    } else return -14;
    return result;
}

/// setxattr/lsetxattr(path, name, value, size, flags)
fn sysSetxattr(frame: *exception.TrapFrame, comptime nofollow: bool) i64 {
    const proc = scheduler.currentProcess() orelse return -9;
    const ino = xattrResolveIno(frame.x[0], proc, !nofollow) orelse return -2;

    const name_addr = frame.x[1];
    const value_addr = frame.x[2];
    const size = frame.x[3];
    const flags: u32 = @truncate(frame.x[4]);

    var name_buf: [256]u8 = undefined;
    const name = copyUserStr(name_addr, &name_buf, proc) orelse return -14;

    if (size > 4096) return -22;
    var value_buf: [4096]u8 = undefined;
    const val_len: usize = @intCast(size);
    if (val_len > 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(value_addr))) |_| {
            const src: [*]const u8 = @ptrFromInt(value_addr);
            for (0..val_len) |i| value_buf[i] = src[i];
        } else return -14;
    }

    return ext2.ext2Setxattr(ino, name, value_buf[0..val_len], flags);
}

/// fsetxattr(fd, name, value, size, flags)
fn sysFsetxattr(frame: *exception.TrapFrame) i64 {
    const proc = scheduler.currentProcess() orelse return -9;
    const fd = frame.x[0];
    const desc = fd_table.fdGet(&proc.fds, fd) orelse return -9;
    const ino: u32 = @truncate(desc.inode.ino);

    const name_addr = frame.x[1];
    const value_addr = frame.x[2];
    const size = frame.x[3];
    const flags: u32 = @truncate(frame.x[4]);

    var name_buf: [256]u8 = undefined;
    const name = copyUserStr(name_addr, &name_buf, proc) orelse return -14;

    if (size > 4096) return -22;
    var value_buf: [4096]u8 = undefined;
    const val_len: usize = @intCast(size);
    if (val_len > 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(value_addr))) |_| {
            const src: [*]const u8 = @ptrFromInt(value_addr);
            for (0..val_len) |i| value_buf[i] = src[i];
        } else return -14;
    }

    return ext2.ext2Setxattr(ino, name, value_buf[0..val_len], flags);
}

/// listxattr/llistxattr(path, list, size)
fn sysListxattr(frame: *exception.TrapFrame, comptime nofollow: bool) i64 {
    const proc = scheduler.currentProcess() orelse return -9;
    const ino = xattrResolveIno(frame.x[0], proc, !nofollow) orelse return -2;

    const list_addr = frame.x[1];
    const size = frame.x[2];

    if (size == 0) {
        var dummy: [0]u8 = undefined;
        return ext2.ext2Listxattr(ino, &dummy);
    }

    if (size > 65536) return -22;
    var list_buf: [4096]u8 = undefined;
    const buf_size: usize = if (size <= 4096) @intCast(size) else return -22;
    const result = ext2.ext2Listxattr(ino, list_buf[0..buf_size]);
    if (result < 0) return result;

    const len: usize = @intCast(result);
    if (len > 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(list_addr))) |_| {
            const dst: [*]u8 = @ptrFromInt(list_addr);
            for (0..len) |i| dst[i] = list_buf[i];
        } else return -14;
    }
    return result;
}

/// flistxattr(fd, list, size)
fn sysFlistxattr(frame: *exception.TrapFrame) i64 {
    const proc = scheduler.currentProcess() orelse return -9;
    const fd = frame.x[0];
    const desc = fd_table.fdGet(&proc.fds, fd) orelse return -9;
    const ino: u32 = @truncate(desc.inode.ino);

    const list_addr = frame.x[1];
    const size = frame.x[2];

    if (size == 0) {
        var dummy: [0]u8 = undefined;
        return ext2.ext2Listxattr(ino, &dummy);
    }

    if (size > 4096) return -22;
    var list_buf: [4096]u8 = undefined;
    const buf_size: usize = @intCast(size);
    const result = ext2.ext2Listxattr(ino, list_buf[0..buf_size]);
    if (result < 0) return result;

    const len: usize = @intCast(result);
    if (len > 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(list_addr))) |_| {
            const dst: [*]u8 = @ptrFromInt(list_addr);
            for (0..len) |i| dst[i] = list_buf[i];
        } else return -14;
    }
    return result;
}

/// removexattr/lremovexattr(path, name)
fn sysRemovexattr(frame: *exception.TrapFrame, comptime nofollow: bool) i64 {
    const proc = scheduler.currentProcess() orelse return -9;
    const ino = xattrResolveIno(frame.x[0], proc, !nofollow) orelse return -2;

    const name_addr = frame.x[1];
    var name_buf: [256]u8 = undefined;
    const name = copyUserStr(name_addr, &name_buf, proc) orelse return -14;

    return ext2.ext2Removexattr(ino, name);
}

/// fremovexattr(fd, name)
fn sysfremovexattr(frame: *exception.TrapFrame) i64 {
    const proc = scheduler.currentProcess() orelse return -9;
    const fd = frame.x[0];
    const desc = fd_table.fdGet(&proc.fds, fd) orelse return -9;
    const ino: u32 = @truncate(desc.inode.ino);

    const name_addr = frame.x[1];
    var name_buf: [256]u8 = undefined;
    const name = copyUserStr(name_addr, &name_buf, proc) orelse return -14;

    return ext2.ext2Removexattr(ino, name);
}

// ============================================================================
// inotify — filesystem event notification
// ============================================================================

const IN_ACCESS: u32 = 0x00000001;
const IN_MODIFY: u32 = 0x00000002;
const IN_ATTRIB: u32 = 0x00000004;
const IN_CLOSE_WRITE: u32 = 0x00000008;
const IN_CLOSE_NOWRITE: u32 = 0x00000010;
const IN_OPEN: u32 = 0x00000020;
const IN_MOVED_FROM: u32 = 0x00000040;
const IN_MOVED_TO: u32 = 0x00000080;
const IN_CREATE: u32 = 0x00000100;
const IN_DELETE: u32 = 0x00000200;
const IN_DELETE_SELF: u32 = 0x00000400;
const IN_MOVE_SELF: u32 = 0x00000800;
const IN_NONBLOCK: u32 = 0x00000800; // O_NONBLOCK for inotify_init1

const MAX_INOTIFY_INSTANCES: usize = 8;
const MAX_WATCHES_PER_INSTANCE: usize = 32;
const INOTIFY_EVENT_BUF_SIZE: usize = 4096;

const InotifyWatch = struct {
    wd: i32, // watch descriptor
    ino: u32, // inode number being watched
    mask: u32, // event mask
    active: bool,
};

const InotifyEvent = struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    name_len: u32, // includes padding to align to 4 bytes
    // followed by name bytes
};

const InotifyInstance = struct {
    active: bool,
    flags: u32,
    watches: [MAX_WATCHES_PER_INSTANCE]InotifyWatch,
    next_wd: i32,
    // Event ring buffer
    event_buf: [INOTIFY_EVENT_BUF_SIZE]u8,
    event_write: usize,
    event_read: usize,
    event_count: usize,

    fn init(self: *InotifyInstance, fl: u32) void {
        self.active = true;
        self.flags = fl;
        self.next_wd = 1;
        self.event_write = 0;
        self.event_read = 0;
        self.event_count = 0;
        for (&self.watches) |*w| w.active = false;
    }

    fn addWatch(self: *InotifyInstance, ino: u32, mask: u32) i32 {
        // Check if already watching this inode
        for (&self.watches) |*w| {
            if (w.active and w.ino == ino) {
                w.mask = mask; // update mask
                return w.wd;
            }
        }
        // Find free slot
        for (&self.watches) |*w| {
            if (!w.active) {
                w.active = true;
                w.ino = ino;
                w.mask = mask;
                w.wd = self.next_wd;
                self.next_wd += 1;
                return w.wd;
            }
        }
        return -28; // -ENOSPC
    }

    fn rmWatch(self: *InotifyInstance, wd: i32) i32 {
        for (&self.watches) |*w| {
            if (w.active and w.wd == wd) {
                w.active = false;
                return 0;
            }
        }
        return -22; // -EINVAL
    }

    fn queueEvent(self: *InotifyInstance, wd: i32, mask: u32, name: ?[]const u8) void {
        const name_len: usize = if (name) |n| n.len + 1 else 0; // +1 for null
        const padded_name_len = (name_len + 3) & ~@as(usize, 3); // align to 4
        const event_size = 16 + padded_name_len; // sizeof(inotify_event) header = 16

        if (self.event_count + event_size > INOTIFY_EVENT_BUF_SIZE) return; // drop if full

        const w = self.event_write;
        // Write event header (wd, mask, cookie, len)
        self.event_buf[w] = @truncate(@as(u32, @bitCast(wd)));
        self.event_buf[w + 1] = @truncate(@as(u32, @bitCast(wd)) >> 8);
        self.event_buf[w + 2] = @truncate(@as(u32, @bitCast(wd)) >> 16);
        self.event_buf[w + 3] = @truncate(@as(u32, @bitCast(wd)) >> 24);
        self.event_buf[w + 4] = @truncate(mask);
        self.event_buf[w + 5] = @truncate(mask >> 8);
        self.event_buf[w + 6] = @truncate(mask >> 16);
        self.event_buf[w + 7] = @truncate(mask >> 24);
        // cookie = 0
        for (8..12) |i| self.event_buf[w + i] = 0;
        // len
        const pnl: u32 = @truncate(padded_name_len);
        self.event_buf[w + 12] = @truncate(pnl);
        self.event_buf[w + 13] = @truncate(pnl >> 8);
        self.event_buf[w + 14] = @truncate(pnl >> 16);
        self.event_buf[w + 15] = @truncate(pnl >> 24);

        if (name) |n| {
            for (0..n.len) |i| self.event_buf[w + 16 + i] = n[i];
            self.event_buf[w + 16 + n.len] = 0; // null terminator
            // Zero padding
            for (n.len + 1..padded_name_len) |i| self.event_buf[w + 16 + i] = 0;
        }

        self.event_write += event_size;
        self.event_count += event_size;
    }
};

var inotify_instances: [MAX_INOTIFY_INSTANCES]InotifyInstance = undefined;
var inotify_initialized = false;

fn initInotify() void {
    if (inotify_initialized) return;
    for (&inotify_instances) |*inst| inst.active = false;
    inotify_initialized = true;
}

// VFS hook: called after filesystem operations to notify inotify watches
pub fn inotifyNotify(ino: u32, mask: u32, name: ?[]const u8) void {
    if (!inotify_initialized) return;
    for (&inotify_instances) |*inst| {
        if (!inst.active) continue;
        for (&inst.watches) |*w| {
            if (w.active and w.ino == ino and (w.mask & mask) != 0) {
                inst.queueEvent(w.wd, mask, name);
            }
        }
    }
}

// inotify inode for fd-based read
var inotify_inodes: [MAX_INOTIFY_INSTANCES]vfs.Inode = undefined;

fn inotifyRead(desc: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    // Find which instance this fd belongs to
    const idx = desc.inode.ino - 0xFFFF0000; // magic offset
    if (idx >= MAX_INOTIFY_INSTANCES) return -9;
    var inst = &inotify_instances[idx];
    if (!inst.active) return -9;

    if (inst.event_count == 0) {
        if (inst.flags & IN_NONBLOCK != 0) return -11; // -EAGAIN
        return 0; // No events
    }

    const avail = @min(count, inst.event_count);
    for (0..avail) |i| buf[i] = inst.event_buf[inst.event_read + i];
    inst.event_read += avail;
    inst.event_count -= avail;

    // Reset pointers if drained
    if (inst.event_count == 0) {
        inst.event_read = 0;
        inst.event_write = 0;
    }

    return @intCast(avail);
}

const inotify_ops = vfs.FileOperations{
    .read = inotifyRead,
};

/// inotify_init1(flags) -> fd
fn sysInotifyInit1(frame: *exception.TrapFrame) i64 {
    const flags: u32 = @truncate(frame.x[0]);
    const proc = scheduler.currentProcess() orelse return -9;

    initInotify();

    // Find free instance
    for (&inotify_instances, 0..) |*inst, idx| {
        if (!inst.active) {
            inst.init(flags);

            // Create inode for this instance
            var inode = &inotify_inodes[idx];
            inode.ino = @truncate(0xFFFF0000 + idx);
            inode.mode = vfs.S_IFREG | 0o600;
            inode.size = 0;
            inode.nlink = 1;
            inode.uid = 0;
            inode.gid = 0;
            inode.ops = &inotify_ops;

            const desc = vfs.allocFileDescription() orelse {
                inst.active = false;
                return -23;
            };
            desc.inode = inode;
            desc.flags = 0;
            desc.offset = 0;

            const fd = fd_table.fdAlloc(&proc.fds, desc) orelse {
                vfs.releaseFileDescription(desc);
                inst.active = false;
                return -24;
            };

            return @intCast(fd);
        }
    }
    return -23; // -ENFILE
}

/// inotify_add_watch(fd, path, mask) -> wd
fn sysInotifyAddWatch(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const path_addr = frame.x[1];
    const mask: u32 = @truncate(frame.x[2]);

    const proc = scheduler.currentProcess() orelse return -9;
    const desc = fd_table.fdGet(&proc.fds, fd) orelse return -9;

    // Find which inotify instance this fd belongs to
    const magic_ino = desc.inode.ino;
    if (magic_ino < 0xFFFF0000) return -22; // not an inotify fd
    const idx = magic_ino - 0xFFFF0000;
    if (idx >= MAX_INOTIFY_INSTANCES) return -22;
    var inst = &inotify_instances[idx];
    if (!inst.active) return -22;

    // Resolve path to inode
    if (!ensureUserPages(proc.page_table, path_addr, 1)) return -14;
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    var path_len: usize = 0;
    while (path_len < 255 and path_ptr[path_len] != 0) : (path_len += 1) {
        const next = path_addr + path_len + 1;
        if (next & 0xFFF == 0 and path_len + 1 < 255) {
            if (!ensureUserPages(proc.page_table, next, 1)) break;
        }
    }
    const path = path_ptr[0..path_len];
    const inode = vfs.resolve(path) orelse return -2;

    return inst.addWatch(@truncate(inode.ino), mask);
}

/// inotify_rm_watch(fd, wd) -> 0 or error
fn sysInotifyRmWatch(frame: *exception.TrapFrame) i64 {
    const fd = frame.x[0];
    const wd: i32 = @truncate(@as(i64, @bitCast(frame.x[1])));

    const proc = scheduler.currentProcess() orelse return -9;
    const desc = fd_table.fdGet(&proc.fds, fd) orelse return -9;

    const magic_ino = desc.inode.ino;
    if (magic_ino < 0xFFFF0000) return -22;
    const idx = magic_ino - 0xFFFF0000;
    if (idx >= MAX_INOTIFY_INSTANCES) return -22;
    var inst = &inotify_instances[idx];
    if (!inst.active) return -22;

    return inst.rmWatch(wd);
}

/// copy_file_range(fd_in, off_in, fd_out, off_out, len, flags) -> bytes_copied
/// Copies data between two file descriptors in-kernel without userspace bounce.
fn sysCopyFileRange(frame: *exception.TrapFrame) i64 {
    const fd_in = frame.x[0];
    const off_in_ptr = frame.x[1]; // *u64 or NULL
    const fd_out = frame.x[2];
    const off_out_ptr = frame.x[3]; // *u64 or NULL
    const len = frame.x[4];

    // frame.x[5] = flags (must be 0)

    const proc = scheduler.currentProcess() orelse return -9;

    const desc_in = fd_table.fdGet(&proc.fds, fd_in) orelse return -9; // -EBADF
    const desc_out = fd_table.fdGet(&proc.fds, fd_out) orelse return -9;

    const read_fn = desc_in.inode.ops.read orelse return -9;
    const write_fn = desc_out.inode.ops.write orelse return -9;

    // Read optional offsets from userspace
    var in_off: u64 = desc_in.offset;
    var out_off: u64 = desc_out.offset;

    if (off_in_ptr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(off_in_ptr)) == null) {
            if (!exception.demandPageUser(off_in_ptr & ~@as(u64, 0xFFF))) return -14;
        }
        const p: *align(1) const u64 = @ptrFromInt(off_in_ptr);
        in_off = p.*;
    }
    if (off_out_ptr != 0) {
        if (vmm.translate(vmm.PhysAddr.from(proc.page_table), vmm.VirtAddr.from(off_out_ptr)) == null) {
            if (!exception.demandPageUser(off_out_ptr & ~@as(u64, 0xFFF))) return -14;
        }
        const p: *align(1) const u64 = @ptrFromInt(off_out_ptr);
        out_off = p.*;
    }

    const total_len: usize = if (len > 1048576) 1048576 else @truncate(len);

    // Use a stack buffer to shuttle data in 4KB chunks
    var buf: [4096]u8 = undefined;
    var copied: usize = 0;

    // Save/restore desc offsets — use temporary FileDescription copies for
    // positional I/O so we don't clobber the shared offset during the loop.
    const saved_in_off = desc_in.offset;
    const saved_out_off = desc_out.offset;

    while (copied < total_len) {
        const chunk = @min(total_len - copied, 4096);

        // Position the fd for this read
        desc_in.offset = in_off;
        const n = read_fn(desc_in, &buf, chunk);
        if (n <= 0) break;
        const nbytes: usize = @intCast(n);

        // Position the fd for this write
        desc_out.offset = out_off;
        const w = write_fn(desc_out, &buf, nbytes);
        if (w <= 0) break;
        const wbytes: usize = @intCast(w);

        in_off += wbytes;
        out_off += wbytes;
        copied += wbytes;

        if (wbytes < nbytes) break;
    }

    // Update offsets: if caller provided offset pointers, write back;
    // otherwise update the file description's offset.
    if (off_in_ptr != 0) {
        const p: *align(1) u64 = @ptrFromInt(off_in_ptr);
        p.* = in_off;
        desc_in.offset = saved_in_off; // restore — caller manages offset
    } else {
        desc_in.offset = in_off;
    }
    if (off_out_ptr != 0) {
        const p: *align(1) u64 = @ptrFromInt(off_out_ptr);
        p.* = out_off;
        desc_out.offset = saved_out_off;
    } else {
        desc_out.offset = out_off;
    }

    if (copied == 0) return -5; // -EIO if nothing could be copied
    return @intCast(copied);
}

// ---- umask ----

fn sysUmask(frame: *exception.TrapFrame) i64 {
    const new_mask: u32 = @truncate(frame.x[0] & 0o7777);
    const proc = scheduler.currentProcess() orelse return 0o022;
    const old = proc.umask_val;
    proc.umask_val = new_mask;
    return @intCast(old);
}

// ---- utimensat ----

fn sysUtimensat(frame: *exception.TrapFrame) i64 {
    // utimensat(dirfd, pathname, times[2], flags)
    // times[0] = atime, times[1] = mtime. Each is { i64 sec, i64 nsec }.
    // nsec == UTIME_NOW (0x3FFFFFFF) means use current time.
    // nsec == UTIME_OMIT (0x3FFFFFFE) means don't change.
    // times == NULL means set both to current time.
    const dirfd = frame.x[0];
    const path_addr = frame.x[1];
    const times_addr = frame.x[2];
    _ = frame.x[3]; // flags (AT_SYMLINK_NOFOLLOW etc)

    const proc = scheduler.currentProcess() orelse return -14;

    const UTIME_NOW: i64 = 0x3FFFFFFF;
    const UTIME_OMIT: i64 = 0x3FFFFFFE;

    // Resolve the inode
    const inode: *vfs.Inode = blk: {
        if (path_addr == 0) {
            // NULL path — operate on fd (dirfd)
            const desc = fd_table.fdGet(&proc.fds, dirfd) orelse return -9;
            break :blk desc.inode;
        }
        if (!ensureUserPages(proc.page_table, path_addr, 1)) return -14;
        const ptr: [*]const u8 = @ptrFromInt(path_addr);
        var path_len: usize = 0;
        while (path_len < 255 and ptr[path_len] != 0) : (path_len += 1) {}
        if (path_len == 0) return -2;
        const path = ptr[0..path_len];

        if (path[0] == '/') {
            break :blk vfs.resolve(path) orelse return -2;
        } else if (dirfd != AT_FDCWD) {
            if (fd_table.fdGet(&proc.fds, @truncate(dirfd))) |desc| {
                const res = vfs.resolvePathFrom(desc.inode, path);
                break :blk res.inode orelse return -2;
            }
            return -9;
        } else {
            var abs_buf: [512]u8 = undefined;
            const cwd = proc.cwd[0..proc.cwd_len];
            var abs_len: usize = cwd.len;
            for (0..cwd.len) |i| abs_buf[i] = cwd[i];
            if (abs_len > 0 and abs_buf[abs_len - 1] != '/') {
                abs_buf[abs_len] = '/';
                abs_len += 1;
            }
            const copy_len = @min(path.len, abs_buf.len - abs_len);
            for (0..copy_len) |i| abs_buf[abs_len + i] = path[i];
            abs_len += copy_len;
            break :blk vfs.resolve(abs_buf[0..abs_len]) orelse return -2;
        }
    };

    // Read timespec values from userspace
    var atime_sec: i64 = -1; // -1 = use UTIME_NOW
    var mtime_sec: i64 = -1;
    var atime_nsec: i64 = UTIME_NOW;
    var mtime_nsec: i64 = UTIME_NOW;

    if (times_addr != 0) {
        if (!ensureUserPages(proc.page_table, times_addr, 32)) return -14;
        const tptr: [*]const u8 = @ptrFromInt(times_addr);
        // struct timespec { i64 tv_sec; i64 tv_nsec; } — two of them
        atime_sec = @bitCast(readU64FromUser(tptr, 0));
        atime_nsec = @bitCast(readU64FromUser(tptr, 8));
        mtime_sec = @bitCast(readU64FromUser(tptr, 16));
        mtime_nsec = @bitCast(readU64FromUser(tptr, 24));
    }

    // Apply timestamps via ext2
    if (atime_nsec != UTIME_OMIT or mtime_nsec != UTIME_OMIT) {
        ext2.setTimestamps(inode, atime_sec, atime_nsec, mtime_sec, mtime_nsec);
    }

    return 0;
}

// ---- setsockopt / getsockopt ----

fn sysSetsockopt(frame: *exception.TrapFrame) i64 {
    const fd: usize = @truncate(frame.x[0]);
    const level: u32 = @truncate(frame.x[1]);
    const optname: u32 = @truncate(frame.x[2]);
    const optval_ptr = frame.x[3];
    _ = frame.x[4]; // optlen

    const proc = scheduler.currentProcess() orelse return -9; // -EBADF
    if (fd >= fd_table.MAX_FDS) return -9;
    const desc = proc.fds[fd] orelse return -9;
    const sock_idx = socket.getSocketIndexFromInode(desc.inode) orelse return -88; // -ENOTSOCK

    const sock = socket.getSocket(sock_idx) orelse return -88;

    // Read option value (typically 4-byte int)
    const val: u32 = if (optval_ptr != 0)
        @as(*align(1) const u32, @ptrFromInt(optval_ptr)).*
    else
        0;
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
    return 0;
}

fn sysGetsockopt(frame: *exception.TrapFrame) i64 {
    const fd: usize = @truncate(frame.x[0]);
    const level: u32 = @truncate(frame.x[1]);
    const optname: u32 = @truncate(frame.x[2]);
    const optval_ptr = frame.x[3];
    const optlen_ptr = frame.x[4];

    const proc = scheduler.currentProcess() orelse return -9;
    if (fd >= fd_table.MAX_FDS) return -9;
    const desc = proc.fds[fd] orelse return -9;
    const sock_idx = socket.getSocketIndexFromInode(desc.inode) orelse return -88;
    const sock = socket.getSocket(sock_idx) orelse return -88;

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
        const p: *align(1) u32 = @ptrFromInt(optval_ptr);
        p.* = val;
    }
    if (optlen_ptr != 0) {
        const p: *align(1) u32 = @ptrFromInt(optlen_ptr);
        p.* = 4;
    }
    return 0;
}
