/// Zigix userspace syscall abstraction — architecture-portable.
///
/// Detects target architecture at compile time and selects the right
/// syscall ABI (int $0x80 / SVC #0) and syscall numbers (x86_64 / AArch64).
///
/// Usage: const sys = @import("sys");
///        _ = sys.write(1, buf.ptr, buf.len);

const builtin = @import("builtin");
const is_aarch64 = builtin.cpu.arch == .aarch64;
const is_riscv64 = builtin.cpu.arch == .riscv64;
/// RISC-V uses the same generic Linux syscall numbers as ARM64
const is_generic_abi = is_aarch64 or is_riscv64;

/// AT_FDCWD: "use current working directory" for *at() syscalls
pub const AT_FDCWD: u64 = @bitCast(@as(i64, -100));
pub const AT_REMOVEDIR: u64 = 0x200;

// ============================================================================
// Syscall numbers — compile-time architecture selection
// ============================================================================

pub const NR = struct {
    pub const read: u64 = if (is_generic_abi) 63 else 0;
    pub const write: u64 = if (is_generic_abi) 64 else 1;
    pub const open: u64 = 2; // x86_64 only — use openat on generic ABI
    pub const openat: u64 = if (is_generic_abi) 56 else 257;
    pub const close: u64 = if (is_generic_abi) 57 else 3;
    pub const ioctl: u64 = if (is_generic_abi) 29 else 16;
    pub const pipe: u64 = 22; // x86_64 only — use pipe2 on generic ABI
    pub const pipe2: u64 = if (is_generic_abi) 59 else 293;
    pub const dup2: u64 = 33; // x86_64 only — use dup3 on generic ABI
    pub const dup3: u64 = if (is_generic_abi) 24 else 292;
    pub const getpid: u64 = if (is_generic_abi) 172 else 39;
    pub const socket: u64 = if (is_generic_abi) 198 else 41;
    pub const connect: u64 = if (is_generic_abi) 203 else 42;
    pub const sendto: u64 = if (is_generic_abi) 206 else 44;
    pub const recvfrom: u64 = if (is_generic_abi) 207 else 45;
    pub const bind: u64 = if (is_generic_abi) 200 else 49;
    pub const clone: u64 = if (is_generic_abi) 220 else 56;
    pub const execve: u64 = if (is_generic_abi) 221 else 59;
    pub const exit: u64 = if (is_generic_abi) 93 else 60;
    pub const wait4: u64 = if (is_generic_abi) 260 else 61;
    pub const kill: u64 = if (is_generic_abi) 129 else 62;
    pub const uname: u64 = if (is_generic_abi) 160 else 63;
    pub const getcwd: u64 = if (is_generic_abi) 17 else 79;
    pub const chdir: u64 = if (is_generic_abi) 49 else 80;
    pub const mkdir: u64 = 83; // x86_64 only — use mkdirat on generic ABI
    pub const mkdirat: u64 = if (is_generic_abi) 34 else 258;
    pub const rmdir: u64 = 84; // x86_64 only — use unlinkat on generic ABI
    pub const unlink: u64 = 87; // x86_64 only — use unlinkat on generic ABI
    pub const unlinkat: u64 = if (is_generic_abi) 35 else 263;
    pub const setpgid: u64 = if (is_generic_abi) 154 else 109;
    pub const getpgid: u64 = if (is_generic_abi) 155 else 121;
    pub const getpgrp: u64 = 111; // x86_64 only — use getpgid(0) on generic ABI
    pub const rt_sigaction: u64 = if (is_generic_abi) 134 else 13;
    pub const setuid: u64 = if (is_generic_abi) 146 else 105;
    pub const setgid: u64 = if (is_generic_abi) 144 else 106;
    pub const nanosleep: u64 = if (is_generic_abi) 101 else 35;
    pub const sync: u64 = if (is_generic_abi) 81 else 162;
    pub const fsync: u64 = if (is_generic_abi) 82 else 74;
    pub const fdatasync: u64 = if (is_generic_abi) 83 else 75;
    pub const sendfile: u64 = if (is_generic_abi) 71 else 40;
    pub const lseek: u64 = if (is_generic_abi) 62 else 8;
    pub const renameat: u64 = if (is_generic_abi) 38 else 263;
    pub const linkat: u64 = if (is_generic_abi) 37 else 265;
    pub const symlinkat: u64 = if (is_generic_abi) 36 else 266;
    pub const readlinkat: u64 = if (is_generic_abi) 78 else 267;
    pub const ftruncate: u64 = if (is_generic_abi) 46 else 77;
    pub const fchmod: u64 = if (is_generic_abi) 52 else 91;
    pub const fchmodat: u64 = if (is_generic_abi) 53 else 268;
    pub const fchown: u64 = if (is_generic_abi) 55 else 93;
    pub const fchownat: u64 = if (is_generic_abi) 54 else 260;
    pub const statfs_nr: u64 = if (is_generic_abi) 43 else 137;
    pub const fallocate_nr: u64 = if (is_generic_abi) 47 else 285;
    pub const utimensat: u64 = if (is_generic_abi) 88 else 280;
    pub const newfstatat: u64 = if (is_generic_abi) 79 else 262;
    pub const getdents64: u64 = if (is_generic_abi) 61 else 217;
    pub const fstat_nr: u64 = if (is_generic_abi) 80 else 5;
    pub const listen_nr: u64 = if (is_generic_abi) 201 else 50;
    pub const accept_nr: u64 = if (is_generic_abi) 202 else 43;
    pub const shutdown_nr: u64 = if (is_generic_abi) 210 else 48;
    pub const epoll_create1: u64 = if (is_generic_abi) 20 else 291;
    pub const epoll_ctl: u64 = if (is_generic_abi) 21 else 233;
    pub const epoll_pwait: u64 = if (is_generic_abi) 22 else 281;
    pub const copy_file_range: u64 = if (is_generic_abi) 285 else 326;
    pub const splice: u64 = if (is_generic_abi) 76 else 275;
    pub const tee: u64 = if (is_generic_abi) 77 else 276;
    pub const setxattr: u64 = if (is_generic_abi) 5 else 188;
    pub const getxattr: u64 = if (is_generic_abi) 8 else 191;
    pub const listxattr: u64 = if (is_generic_abi) 11 else 194;
    pub const removexattr: u64 = if (is_generic_abi) 14 else 197;
    pub const inotify_init1: u64 = if (is_generic_abi) 26 else 294;
    pub const inotify_add_watch: u64 = if (is_generic_abi) 27 else 254;
    pub const inotify_rm_watch: u64 = if (is_generic_abi) 28 else 255;
    pub const mknodat: u64 = if (is_generic_abi) 33 else 259;
    pub const fcntl: u64 = if (is_generic_abi) 25 else 72;
    // Zigix-specific syscalls (same number on all architectures)
    pub const net_attach: u64 = 280;
    pub const net_hugepage_alloc: u64 = 281;
    pub const sched_dedicate: u64 = 503;
    pub const sched_release: u64 = 504;
};

// ============================================================================
// File open flags (Linux ABI)
// ============================================================================

pub const O_RDONLY: u64 = 0;
pub const O_WRONLY: u64 = 1;
pub const O_RDWR: u64 = 2;
pub const O_CREAT: u64 = 0o100;
pub const O_TRUNC: u64 = 0o1000;
pub const O_APPEND: u64 = 0o2000;

// ============================================================================
// epoll constants (Linux ABI)
// ============================================================================

pub const EPOLLIN: u32 = 0x001;
pub const EPOLLPRI: u32 = 0x002;
pub const EPOLLOUT: u32 = 0x004;
pub const EPOLLERR: u32 = 0x008;
pub const EPOLLHUP: u32 = 0x010;

pub const EPOLL_CTL_ADD: u32 = 1;
pub const EPOLL_CTL_DEL: u32 = 2;
pub const EPOLL_CTL_MOD: u32 = 3;

// ============================================================================
// Raw syscall primitives — architecture-specific inline assembly
// ============================================================================

pub inline fn syscall0(nr: u64) isize {
    if (is_riscv64) {
        return asm volatile ("ecall"
            : [ret] "={a0}" (-> isize),
            : [nr] "{a7}" (nr),
            : .{ .memory = true }
        );
    } else if (is_aarch64) {
        return asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [nr] "{x8}" (nr),
            : .{ .memory = true }
        );
    } else {
        return asm volatile ("int $0x80"
            : [ret] "={rax}" (-> isize),
            : [nr] "{rax}" (nr),
            : .{ .memory = true }
        );
    }
}

pub inline fn syscall1(nr: u64, a1: u64) isize {
    if (is_riscv64) {
        return asm volatile ("ecall"
            : [ret] "={a0}" (-> isize),
            : [nr] "{a7}" (nr),
              [a1] "{a0}" (a1),
            : .{ .memory = true }
        );
    } else if (is_aarch64) {
        return asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [nr] "{x8}" (nr),
              [a1] "{x0}" (a1),
            : .{ .memory = true }
        );
    } else {
        return asm volatile ("int $0x80"
            : [ret] "={rax}" (-> isize),
            : [nr] "{rax}" (nr),
              [a1] "{rdi}" (a1),
            : .{ .memory = true }
        );
    }
}

pub inline fn syscall2(nr: u64, a1: u64, a2: u64) isize {
    if (is_riscv64) {
        return asm volatile ("ecall"
            : [ret] "={a0}" (-> isize),
            : [nr] "{a7}" (nr),
              [a1] "{a0}" (a1),
              [a2] "{a1}" (a2),
            : .{ .memory = true }
        );
    } else if (is_aarch64) {
        return asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [nr] "{x8}" (nr),
              [a1] "{x0}" (a1),
              [a2] "{x1}" (a2),
            : .{ .memory = true }
        );
    } else {
        return asm volatile ("int $0x80"
            : [ret] "={rax}" (-> isize),
            : [nr] "{rax}" (nr),
              [a1] "{rdi}" (a1),
              [a2] "{rsi}" (a2),
            : .{ .memory = true }
        );
    }
}

pub inline fn syscall3(nr: u64, a1: u64, a2: u64, a3: u64) isize {
    if (is_riscv64) {
        return asm volatile ("ecall"
            : [ret] "={a0}" (-> isize),
            : [nr] "{a7}" (nr),
              [a1] "{a0}" (a1),
              [a2] "{a1}" (a2),
              [a3] "{a2}" (a3),
            : .{ .memory = true }
        );
    } else if (is_aarch64) {
        return asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [nr] "{x8}" (nr),
              [a1] "{x0}" (a1),
              [a2] "{x1}" (a2),
              [a3] "{x2}" (a3),
            : .{ .memory = true }
        );
    } else {
        return asm volatile ("int $0x80"
            : [ret] "={rax}" (-> isize),
            : [nr] "{rax}" (nr),
              [a1] "{rdi}" (a1),
              [a2] "{rsi}" (a2),
              [a3] "{rdx}" (a3),
            : .{ .memory = true }
        );
    }
}

pub inline fn syscall4(nr: u64, a1: u64, a2: u64, a3: u64, a4: u64) isize {
    if (is_riscv64) {
        return asm volatile ("ecall"
            : [ret] "={a0}" (-> isize),
            : [nr] "{a7}" (nr),
              [a1] "{a0}" (a1),
              [a2] "{a1}" (a2),
              [a3] "{a2}" (a3),
              [a4] "{a3}" (a4),
            : .{ .memory = true }
        );
    } else if (is_aarch64) {
        return asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [nr] "{x8}" (nr),
              [a1] "{x0}" (a1),
              [a2] "{x1}" (a2),
              [a3] "{x2}" (a3),
              [a4] "{x3}" (a4),
            : .{ .memory = true }
        );
    } else {
        return asm volatile ("int $0x80"
            : [ret] "={rax}" (-> isize),
            : [nr] "{rax}" (nr),
              [a1] "{rdi}" (a1),
              [a2] "{rsi}" (a2),
              [a3] "{rdx}" (a3),
              [a4] "{r10}" (a4),
            : .{ .memory = true }
        );
    }
}

pub inline fn syscall5(nr: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) isize {
    if (is_riscv64) {
        return asm volatile ("ecall"
            : [ret] "={a0}" (-> isize),
            : [nr] "{a7}" (nr),
              [a1] "{a0}" (a1),
              [a2] "{a1}" (a2),
              [a3] "{a2}" (a3),
              [a4] "{a3}" (a4),
              [a5] "{a4}" (a5),
            : .{ .memory = true }
        );
    } else if (is_aarch64) {
        return asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [nr] "{x8}" (nr),
              [a1] "{x0}" (a1),
              [a2] "{x1}" (a2),
              [a3] "{x2}" (a3),
              [a4] "{x3}" (a4),
              [a5] "{x4}" (a5),
            : .{ .memory = true }
        );
    } else {
        return asm volatile ("int $0x80"
            : [ret] "={rax}" (-> isize),
            : [nr] "{rax}" (nr),
              [a1] "{rdi}" (a1),
              [a2] "{rsi}" (a2),
              [a3] "{rdx}" (a3),
              [a4] "{r10}" (a4),
              [a5] "{r8}" (a5),
            : .{ .memory = true }
        );
    }
}

pub inline fn syscall6(nr: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64) isize {
    if (is_riscv64) {
        return asm volatile ("ecall"
            : [ret] "={a0}" (-> isize),
            : [nr] "{a7}" (nr),
              [a1] "{a0}" (a1),
              [a2] "{a1}" (a2),
              [a3] "{a2}" (a3),
              [a4] "{a3}" (a4),
              [a5] "{a4}" (a5),
              [a6] "{a5}" (a6),
            : .{ .memory = true }
        );
    } else if (is_aarch64) {
        return asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [nr] "{x8}" (nr),
              [a1] "{x0}" (a1),
              [a2] "{x1}" (a2),
              [a3] "{x2}" (a3),
              [a4] "{x3}" (a4),
              [a5] "{x4}" (a5),
              [a6] "{x5}" (a6),
            : .{ .memory = true }
        );
    } else {
        return asm volatile ("int $0x80"
            : [ret] "={rax}" (-> isize),
            : [nr] "{rax}" (nr),
              [a1] "{rdi}" (a1),
              [a2] "{rsi}" (a2),
              [a3] "{rdx}" (a3),
              [a4] "{r10}" (a4),
              [a5] "{r8}" (a5),
              [a6] "{r9}" (a6),
            : .{ .memory = true }
        );
    }
}

// ============================================================================
// High-level syscall wrappers — portable across x86_64 and aarch64
// These translate legacy x86_64 syscalls (open, pipe, dup2, etc.) to their
// *at() equivalents on aarch64 where the legacy versions don't exist.
// ============================================================================

pub fn write(fd: u64, buf: [*]const u8, len: usize) isize {
    return syscall3(NR.write, fd, @intFromPtr(buf), len);
}

pub fn read(fd: u64, buf: [*]u8, len: usize) isize {
    return syscall3(NR.read, fd, @intFromPtr(buf), len);
}

pub fn exit(code: u64) noreturn {
    _ = syscall1(NR.exit, code);
    unreachable;
}

pub fn open(path: [*]const u8, flags: u64, mode: u64) isize {
    if (is_generic_abi) {
        return syscall4(NR.openat, AT_FDCWD, @intFromPtr(path), flags, mode);
    } else {
        return syscall3(NR.open, @intFromPtr(path), flags, mode);
    }
}

pub fn close(fd: u64) isize {
    return syscall1(NR.close, fd);
}

pub fn fork() isize {
    return syscall2(NR.clone, 0, 0);
}

pub fn execve(path: [*]const u8, argv: u64, envp: u64) isize {
    return syscall3(NR.execve, @intFromPtr(path), argv, envp);
}

pub fn wait4(pid: u64, wstatus: u64, options: u64) isize {
    return syscall3(NR.wait4, pid, wstatus, options);
}

pub fn getpid() u64 {
    return @bitCast(syscall0(NR.getpid));
}

pub fn getcwd(buf: [*]u8, size: usize) isize {
    return syscall2(NR.getcwd, @intFromPtr(buf), size);
}

pub fn chdir(path: [*]const u8) isize {
    return syscall1(NR.chdir, @intFromPtr(path));
}

pub fn uname(buf: [*]u8) isize {
    return syscall1(NR.uname, @intFromPtr(buf));
}

pub fn pipe(fds: *[2]u32) isize {
    if (is_generic_abi) {
        return syscall2(NR.pipe2, @intFromPtr(fds), 0);
    } else {
        return syscall1(NR.pipe, @intFromPtr(fds));
    }
}

pub fn dup2(oldfd: u64, newfd: u64) isize {
    if (is_generic_abi) {
        return syscall3(NR.dup3, oldfd, newfd, 0);
    } else {
        return syscall2(NR.dup2, oldfd, newfd);
    }
}

pub fn mkdir(path: [*]const u8, mode: u64) isize {
    if (is_generic_abi) {
        return syscall3(NR.mkdirat, AT_FDCWD, @intFromPtr(path), mode);
    } else {
        return syscall2(NR.mkdir, @intFromPtr(path), mode);
    }
}

pub fn unlink(path: [*]const u8) isize {
    if (is_generic_abi) {
        return syscall3(NR.unlinkat, AT_FDCWD, @intFromPtr(path), 0);
    } else {
        return syscall1(NR.unlink, @intFromPtr(path));
    }
}

pub fn unlinkat(dirfd: u64, path: [*]const u8, flags: u64) isize {
    return syscall3(NR.unlinkat, dirfd, @intFromPtr(path), flags);
}

pub fn rmdir(path: [*]const u8) isize {
    if (is_generic_abi) {
        return syscall3(NR.unlinkat, AT_FDCWD, @intFromPtr(path), AT_REMOVEDIR);
    } else {
        return syscall1(NR.rmdir, @intFromPtr(path));
    }
}

pub fn kill(pid: u64, sig: u64) isize {
    return syscall2(NR.kill, pid, sig);
}

pub fn setpgid(pid: u64, pgid: u64) isize {
    return syscall2(NR.setpgid, pid, pgid);
}

pub fn getpgrp() u64 {
    if (is_generic_abi) {
        return @bitCast(syscall1(NR.getpgid, 0));
    } else {
        return @bitCast(syscall0(NR.getpgrp));
    }
}

pub fn ioctl(fd: u64, request: u64, arg: u64) isize {
    return syscall3(NR.ioctl, fd, request, arg);
}

pub fn rt_sigaction(sig: u64, act: u64, oldact: u64) isize {
    return syscall3(NR.rt_sigaction, sig, act, oldact);
}

pub fn setuid(uid: u64) isize {
    return syscall1(NR.setuid, uid);
}

pub fn setgid(gid: u64) isize {
    return syscall1(NR.setgid, gid);
}

pub fn sync_() void {
    _ = syscall0(NR.sync);
}

pub fn fsync(fd: u64) isize {
    return syscall1(NR.fsync, fd);
}

pub fn fdatasync(fd: u64) isize {
    return syscall1(NR.fdatasync, fd);
}

pub fn sendfile(out_fd: u64, in_fd: u64, offset: u64, count: u64) isize {
    return syscall4(NR.sendfile, out_fd, in_fd, offset, count);
}

pub fn lseek(fd: u64, offset: u64, whence: u64) isize {
    return syscall3(NR.lseek, fd, offset, whence);
}

pub fn renameat(olddirfd: u64, oldpath: [*]const u8, newdirfd: u64, newpath: [*]const u8) isize {
    return syscall4(NR.renameat, olddirfd, @intFromPtr(oldpath), newdirfd, @intFromPtr(newpath));
}

pub fn rename(oldpath: [*]const u8, newpath: [*]const u8) isize {
    return renameat(AT_FDCWD, oldpath, AT_FDCWD, newpath);
}

pub fn linkat(olddirfd: u64, oldpath: [*]const u8, newdirfd: u64, newpath: [*]const u8, flags: u64) isize {
    return syscall5(NR.linkat, olddirfd, @intFromPtr(oldpath), newdirfd, @intFromPtr(newpath), flags);
}

pub fn link(oldpath: [*]const u8, newpath: [*]const u8) isize {
    return linkat(AT_FDCWD, oldpath, AT_FDCWD, newpath, 0);
}

pub fn symlinkat(target: [*]const u8, newdirfd: u64, linkpath: [*]const u8) isize {
    return syscall3(NR.symlinkat, @intFromPtr(target), newdirfd, @intFromPtr(linkpath));
}

pub fn symlink(target: [*]const u8, linkpath: [*]const u8) isize {
    return symlinkat(target, AT_FDCWD, linkpath);
}

pub fn readlinkat(dirfd: u64, pathname: [*]const u8, buf: [*]u8, bufsiz: usize) isize {
    return syscall4(NR.readlinkat, dirfd, @intFromPtr(pathname), @intFromPtr(buf), bufsiz);
}

pub fn readlink(pathname: [*]const u8, buf: [*]u8, bufsiz: usize) isize {
    return readlinkat(AT_FDCWD, pathname, buf, bufsiz);
}

pub fn ftruncate(fd: u64, length: u64) isize {
    return syscall2(NR.ftruncate, fd, length);
}

pub fn fchmod(fd: u64, mode: u64) isize {
    return syscall2(NR.fchmod, fd, mode);
}

pub fn fchmodat(dirfd: u64, pathname: [*]const u8, mode: u64, flags: u64) isize {
    return syscall4(NR.fchmodat, dirfd, @intFromPtr(pathname), mode, flags);
}

pub fn chmod(pathname: [*]const u8, mode: u64) isize {
    return fchmodat(AT_FDCWD, pathname, mode, 0);
}

pub fn fchown(fd: u64, owner: u64, group: u64) isize {
    return syscall3(NR.fchown, fd, owner, group);
}

pub fn fchownat(dirfd: u64, pathname: [*]const u8, owner: u64, group: u64, flags: u64) isize {
    return syscall5(NR.fchownat, dirfd, @intFromPtr(pathname), owner, group, flags);
}

pub fn statfs(pathname: [*]const u8, buf: [*]u8) isize {
    return syscall2(NR.statfs_nr, @intFromPtr(pathname), @intFromPtr(buf));
}

pub fn fallocate(fd: u64, mode: u64, offset: u64, len: u64) isize {
    return syscall4(NR.fallocate_nr, fd, mode, offset, len);
}

pub fn utimensat(dirfd: u64, pathname: [*]const u8, times: [*]const u8, flags: u64) isize {
    return syscall4(NR.utimensat, dirfd, @intFromPtr(pathname), @intFromPtr(times), flags);
}

pub fn newfstatat(dirfd: u64, pathname: [*]const u8, buf: [*]u8, flags: u64) isize {
    return syscall4(NR.newfstatat, dirfd, @intFromPtr(pathname), @intFromPtr(buf), flags);
}

pub fn stat(pathname: [*]const u8, buf: [*]u8) isize {
    return newfstatat(AT_FDCWD, pathname, buf, 0);
}

pub fn getdents64(fd: u64, buf: [*]u8, count: usize) isize {
    return syscall3(NR.getdents64, fd, @intFromPtr(buf), count);
}

pub fn fstat(fd: u64, buf: [*]u8) isize {
    return syscall2(NR.fstat_nr, fd, @intFromPtr(buf));
}

pub fn listen_sock(fd: u64, backlog: u64) isize {
    return syscall2(NR.listen_nr, fd, backlog);
}

pub fn accept_sock(fd: u64, addr: u64, addrlen: u64) isize {
    return syscall3(NR.accept_nr, fd, addr, addrlen);
}

pub fn shutdown(fd: u64, how: u64) isize {
    return syscall2(NR.shutdown_nr, fd, how);
}

pub fn socket(domain: u64, sock_type: u64, protocol: u64) isize {
    return syscall3(NR.socket, domain, sock_type, protocol);
}

pub fn connect(fd: u64, addr: [*]const u8, addrlen: u64) isize {
    return syscall3(NR.connect, fd, @intFromPtr(addr), addrlen);
}

pub fn bind(fd: u64, addr: [*]const u8, addrlen: u64) isize {
    return syscall3(NR.bind, fd, @intFromPtr(addr), addrlen);
}

pub fn sendto(fd: u64, buf: [*]const u8, len: usize, flags: u64, dest_addr: u64, addrlen: u64) isize {
    return syscall6(NR.sendto, fd, @intFromPtr(buf), len, flags, dest_addr, addrlen);
}

pub fn recvfrom(fd: u64, buf: [*]u8, len: usize, flags: u64, src_addr: u64, addrlen: u64) isize {
    return syscall6(NR.recvfrom, fd, @intFromPtr(buf), len, flags, src_addr, addrlen);
}

// ============================================================================
// epoll wrappers
// ============================================================================

pub fn epoll_create1(flags: u64) isize {
    return syscall1(NR.epoll_create1, flags);
}

pub fn epoll_ctl(epfd: u64, op: u64, fd: u64, event: u64) isize {
    return syscall4(NR.epoll_ctl, epfd, op, fd, event);
}

pub fn epoll_pwait(epfd: u64, events: u64, maxevents: u64, timeout: u64) isize {
    return syscall4(NR.epoll_pwait, epfd, events, maxevents, timeout);
}

// ============================================================================
// Zigix-specific syscall wrappers
// ============================================================================

pub fn net_attach(nic_idx: u64, queue_idx: u64) isize {
    return syscall2(NR.net_attach, nic_idx, queue_idx);
}

pub fn net_hugepage_alloc(hint: u64) isize {
    return syscall1(NR.net_hugepage_alloc, hint);
}

pub fn sched_dedicate(core_id: u64) isize {
    return syscall1(NR.sched_dedicate, core_id);
}

pub fn sched_release() isize {
    return syscall0(NR.sched_release);
}

// ============================================================================
// Output helpers — no dependency on std
// ============================================================================

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = formatBuf(&buf, fmt, args);
    _ = write(1, s.ptr, s.len);
}

fn formatBuf(buf: *[1024]u8, comptime fmt: []const u8, args: anytype) []const u8 {
    _ = args;
    // Simple passthrough for string-only format
    if (fmt.len <= 1024) {
        @memcpy(buf[0..fmt.len], fmt);
        return buf[0..fmt.len];
    }
    return fmt[0..1024];
}

pub fn copy_file_range(fd_in: u64, off_in: ?*u64, fd_out: u64, off_out: ?*u64, len: u64, flags: u64) isize {
    return syscall6(NR.copy_file_range, fd_in, @intFromPtr(off_in), fd_out, @intFromPtr(off_out), len, flags);
}

pub fn splice(fd_in: u64, off_in: ?*u64, fd_out: u64, off_out: ?*u64, len: u64, flags: u64) isize {
    return syscall6(NR.splice, fd_in, @intFromPtr(off_in), fd_out, @intFromPtr(off_out), len, flags);
}

pub fn tee(fd_in: u64, fd_out: u64, len: u64, flags: u64) isize {
    return syscall4(NR.tee, fd_in, fd_out, len, flags);
}

// xattr
pub fn setxattr(path: [*]const u8, name: [*]const u8, value: [*]const u8, size: u64, flags: u64) isize {
    return syscall5(NR.setxattr, @intFromPtr(path), @intFromPtr(name), @intFromPtr(value), size, flags);
}

pub fn getxattr(path: [*]const u8, name: [*]const u8, value: [*]u8, size: u64) isize {
    return syscall4(NR.getxattr, @intFromPtr(path), @intFromPtr(name), @intFromPtr(value), size);
}

pub fn listxattr(path: [*]const u8, list: [*]u8, size: u64) isize {
    return syscall3(NR.listxattr, @intFromPtr(path), @intFromPtr(list), size);
}

pub fn removexattr(path: [*]const u8, name: [*]const u8) isize {
    return syscall2(NR.removexattr, @intFromPtr(path), @intFromPtr(name));
}

// inotify
pub fn inotify_init1(flags: u64) isize {
    return syscall1(NR.inotify_init1, flags);
}

pub fn inotify_add_watch(fd: u64, path: [*]const u8, mask: u64) isize {
    return syscall3(NR.inotify_add_watch, fd, @intFromPtr(path), mask);
}

pub fn inotify_rm_watch(fd: u64, wd: u64) isize {
    return syscall2(NR.inotify_rm_watch, fd, wd);
}

pub fn mknodat(dirfd: u64, path: [*]const u8, mode: u64, dev: u64) isize {
    return syscall4(NR.mknodat, dirfd, @intFromPtr(path), mode, dev);
}

pub fn mkfifo(path: [*]const u8, mode: u64) isize {
    return mknodat(AT_FDCWD, path, S_IFIFO | mode, 0);
}

pub fn fcntl(fd: u64, cmd: u64, arg: u64) isize {
    return syscall3(NR.fcntl, fd, cmd, arg);
}

pub const S_IFIFO: u64 = 0o010000;
pub const F_GETLK: u64 = 5;
pub const F_SETLK: u64 = 6;
pub const F_SETLKW: u64 = 7;
pub const F_RDLCK: u16 = 0;
pub const F_WRLCK: u16 = 1;
pub const F_UNLCK: u16 = 2;

pub const FALLOC_FL_KEEP_SIZE: u64 = 0x01;
pub const FALLOC_FL_PUNCH_HOLE: u64 = 0x02;

pub fn puts(s: []const u8) void {
    _ = write(1, s.ptr, s.len);
}

pub fn putchar(c: u8) void {
    _ = write(1, @as([*]const u8, @ptrCast(&c)), 1);
}

/// Sleep for the given number of seconds.
pub fn nanosleep(seconds: u64) isize {
    // struct timespec { tv_sec: i64, tv_nsec: i64 }
    var ts: [2]u64 = .{ seconds, 0 };
    return syscall2(NR.nanosleep, @intFromPtr(&ts), 0);
}
