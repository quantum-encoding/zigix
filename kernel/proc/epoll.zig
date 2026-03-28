/// epoll — Event-driven I/O multiplexing (level-triggered).
///
/// epoll_create1 allocates an instance with a VFS-backed fd.
/// epoll_ctl adds/modifies/removes monitored fds.
/// epoll_wait scans monitored fds for readiness, blocking if none ready.
///
/// Readiness is determined by calling subsystem-specific checkReadiness()
/// functions (pipe.zig, socket.zig). Subsystems call wakeAllWaiters()
/// when events occur that might change readiness.

const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const vfs = @import("../fs/vfs.zig");
const fd_table = @import("../fs/fd_table.zig");
const pipe = @import("../fs/pipe.zig");
const socket = @import("../net/socket.zig");
const scheduler = @import("scheduler.zig");
const process = @import("process.zig");
const syscall = @import("syscall.zig");
const errno = @import("errno.zig");
const vmm = @import("../mm/vmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const types = @import("../types.zig");

// --- Linux ABI constants ---

pub const EPOLLIN: u32 = 0x001;
pub const EPOLLPRI: u32 = 0x002;
pub const EPOLLOUT: u32 = 0x004;
pub const EPOLLERR: u32 = 0x008;
pub const EPOLLHUP: u32 = 0x010;
pub const EPOLLET: u32 = 0x80000000;

pub const EPOLL_CTL_ADD: u32 = 1;
pub const EPOLL_CTL_DEL: u32 = 2;
pub const EPOLL_CTL_MOD: u32 = 3;

// --- Data structures ---

const MAX_EPOLL_INSTANCES: usize = 32;
const MAX_EPOLL_ENTRIES: usize = 256;

const EpollEntry = struct {
    fd: u32,
    events: u32,
    user_data: u64,
    in_use: bool,
};

const EpollInstance = struct {
    entries: [MAX_EPOLL_ENTRIES]EpollEntry,
    waiting_pid: u64,
    deadline_tick: u64, // For timeout support (0 = no deadline)
    in_use: bool,
};

fn emptyEntry() EpollEntry {
    return .{ .fd = 0, .events = 0, .user_data = 0, .in_use = false };
}

fn emptyInstance() EpollInstance {
    return .{
        .entries = [_]EpollEntry{emptyEntry()} ** MAX_EPOLL_ENTRIES,
        .waiting_pid = 0,
        .deadline_tick = 0,
        .in_use = false,
    };
}

var instances: [MAX_EPOLL_INSTANCES]EpollInstance = [_]EpollInstance{emptyInstance()} ** MAX_EPOLL_INSTANCES;

// --- VFS integration ---

var epoll_inodes: [MAX_EPOLL_INSTANCES]vfs.Inode = undefined;
var inodes_initialized: bool = false;

const epoll_ops = vfs.FileOperations{
    .close = epollClose,
};

fn initInodes() void {
    for (0..MAX_EPOLL_INSTANCES) |i| {
        epoll_inodes[i] = .{
            .ino = 0x30000 + i,
            .mode = vfs.S_IFREG | 0o600, // epoll fd appears as regular file
            .size = 0,
            .nlink = 1,
            .ops = &epoll_ops,
            .fs_data = null,
        };
    }
    inodes_initialized = true;
}

fn getEpollIndex(inode: *vfs.Inode) ?usize {
    const addr = @intFromPtr(inode);
    const base = @intFromPtr(&epoll_inodes[0]);
    if (addr < base) return null;
    const offset = addr - base;
    const idx = offset / @sizeOf(vfs.Inode);
    if (idx >= MAX_EPOLL_INSTANCES) return null;
    return idx;
}

fn epollClose(desc: *vfs.FileDescription) void {
    const idx = getEpollIndex(desc.inode) orelse return;
    instances[idx].in_use = false;
}

// --- Core operations ---

fn allocEpoll() ?usize {
    if (!inodes_initialized) initInodes();
    for (0..MAX_EPOLL_INSTANCES) |i| {
        if (!instances[i].in_use) {
            instances[i] = emptyInstance();
            instances[i].in_use = true;
            return i;
        }
    }
    return null;
}

/// Check readiness of a single fd in the context of a process.
/// Returns the ready event bitmask (intersection of requested events and actual readiness).
fn checkFdReadiness(fds: *[fd_table.MAX_FDS]?*vfs.FileDescription, fd: u32, requested: u32) u32 {
    if (fd >= fd_table.MAX_FDS) return 0;
    const desc = fds[fd] orelse return EPOLLHUP; // closed fd → HUP

    const inode = desc.inode;
    const file_type = inode.mode & vfs.S_IFMT;

    var ready: u32 = 0;

    if (file_type == vfs.S_IFIFO) {
        // Pipe
        ready = pipe.checkReadiness(inode);
    } else if (file_type == socket.S_IFSOCK) {
        // Socket
        ready = socket.checkReadiness(inode);
    } else {
        // Regular file or other — always ready
        ready = EPOLLIN | EPOLLOUT;
    }

    // EPOLLERR and EPOLLHUP are always reported regardless of requested mask
    return (ready & requested) | (ready & (EPOLLERR | EPOLLHUP));
}

/// Wake all processes blocked on any epoll instance.
/// Called from subsystems (pipe, socket, tcp) when events occur.
pub fn wakeAllWaiters() void {
    for (0..MAX_EPOLL_INSTANCES) |i| {
        if (instances[i].in_use and instances[i].waiting_pid != 0) {
            scheduler.wakeProcess(instances[i].waiting_pid);
            instances[i].waiting_pid = 0;
        }
    }
}

// --- Syscall handlers ---

/// epoll_create1(flags) → fd — nr 291
pub fn sysEpollCreate1(frame: *idt.InterruptFrame) void {
    // flags (frame.rdi) ignored for MVP (EPOLL_CLOEXEC not needed)

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const ep_idx = allocEpoll() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };

    const desc = vfs.allocFileDescription() orelse {
        instances[ep_idx].in_use = false;
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };
    desc.inode = &epoll_inodes[ep_idx];
    desc.flags = vfs.O_RDWR;
    desc.offset = 0;

    const fd_num = fd_table.fdAlloc(&current.fds, desc) orelse {
        vfs.releaseFileDescription(desc);
        instances[ep_idx].in_use = false;
        frame.rax = @bitCast(@as(i64, -errno.EMFILE));
        return;
    };

    frame.rax = fd_num;
}

/// epoll_ctl(epfd, op, fd, event) — nr 233
pub fn sysEpollCtl(frame: *idt.InterruptFrame) void {
    const epfd = frame.rdi;
    const op: u32 = @truncate(frame.rsi);
    const target_fd: u32 = @truncate(frame.rdx);
    const event_ptr = frame.r10; // 4th arg is r10

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Get epoll instance from epfd
    const ep_desc = fd_table.fdGet(&current.fds, epfd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const ep_idx = getEpollIndex(ep_desc.inode) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    };
    const ep = &instances[ep_idx];
    if (!ep.in_use) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }

    // Validate target fd exists
    if (target_fd >= fd_table.MAX_FDS or fd_table.fdGet(&current.fds, target_fd) == null) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }

    switch (op) {
        EPOLL_CTL_ADD => {
            // Check not already monitored
            for (0..MAX_EPOLL_ENTRIES) |i| {
                if (ep.entries[i].in_use and ep.entries[i].fd == target_fd) {
                    frame.rax = @bitCast(@as(i64, -errno.EEXIST));
                    return;
                }
            }

            // Read epoll_event from user: { u32 events, u64 data } = 12 bytes (packed)
            if (!syscall.validateUserBuffer(event_ptr, 12)) {
                frame.rax = @bitCast(@as(i64, -errno.EFAULT));
                return;
            }
            var ev_buf: [12]u8 = undefined;
            if (syscall.copyFromUserRaw(current.page_table, event_ptr, &ev_buf, 12) < 12) {
                frame.rax = @bitCast(@as(i64, -errno.EFAULT));
                return;
            }
            const events = @as(u32, ev_buf[0]) |
                (@as(u32, ev_buf[1]) << 8) |
                (@as(u32, ev_buf[2]) << 16) |
                (@as(u32, ev_buf[3]) << 24);
            const data = @as(u64, ev_buf[4]) |
                (@as(u64, ev_buf[5]) << 8) |
                (@as(u64, ev_buf[6]) << 16) |
                (@as(u64, ev_buf[7]) << 24) |
                (@as(u64, ev_buf[8]) << 32) |
                (@as(u64, ev_buf[9]) << 40) |
                (@as(u64, ev_buf[10]) << 48) |
                (@as(u64, ev_buf[11]) << 56);

            // Find free entry
            for (0..MAX_EPOLL_ENTRIES) |i| {
                if (!ep.entries[i].in_use) {
                    ep.entries[i] = .{
                        .fd = target_fd,
                        .events = events,
                        .user_data = data,
                        .in_use = true,
                    };
                    frame.rax = 0;
                    return;
                }
            }
            frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        },
        EPOLL_CTL_DEL => {
            for (0..MAX_EPOLL_ENTRIES) |i| {
                if (ep.entries[i].in_use and ep.entries[i].fd == target_fd) {
                    ep.entries[i].in_use = false;
                    frame.rax = 0;
                    return;
                }
            }
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        },
        EPOLL_CTL_MOD => {
            if (!syscall.validateUserBuffer(event_ptr, 12)) {
                frame.rax = @bitCast(@as(i64, -errno.EFAULT));
                return;
            }
            var ev_buf: [12]u8 = undefined;
            if (syscall.copyFromUserRaw(current.page_table, event_ptr, &ev_buf, 12) < 12) {
                frame.rax = @bitCast(@as(i64, -errno.EFAULT));
                return;
            }
            const events = @as(u32, ev_buf[0]) |
                (@as(u32, ev_buf[1]) << 8) |
                (@as(u32, ev_buf[2]) << 16) |
                (@as(u32, ev_buf[3]) << 24);
            const data = @as(u64, ev_buf[4]) |
                (@as(u64, ev_buf[5]) << 8) |
                (@as(u64, ev_buf[6]) << 16) |
                (@as(u64, ev_buf[7]) << 24) |
                (@as(u64, ev_buf[8]) << 32) |
                (@as(u64, ev_buf[9]) << 40) |
                (@as(u64, ev_buf[10]) << 48) |
                (@as(u64, ev_buf[11]) << 56);

            for (0..MAX_EPOLL_ENTRIES) |i| {
                if (ep.entries[i].in_use and ep.entries[i].fd == target_fd) {
                    ep.entries[i].events = events;
                    ep.entries[i].user_data = data;
                    frame.rax = 0;
                    return;
                }
            }
            frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        },
        else => {
            frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        },
    }
}

/// epoll_wait(epfd, events, maxevents, timeout) — nr 232
pub fn sysEpollWait(frame: *idt.InterruptFrame) void {
    const epfd = frame.rdi;
    const events_ptr = frame.rsi;
    const maxevents: u32 = @truncate(frame.rdx);
    const timeout: i32 = @bitCast(@as(u32, @truncate(frame.r10))); // 4th arg

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (maxevents == 0 or maxevents > 256) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    // Get epoll instance
    const ep_desc = fd_table.fdGet(&current.fds, epfd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const ep_idx = getEpollIndex(ep_desc.inode) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    };
    const ep = &instances[ep_idx];
    if (!ep.in_use) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }

    // Scan monitored fds for readiness
    var count: u32 = 0;
    var ready_buf: [256 * 12]u8 = undefined; // maxevents * sizeof(epoll_event)

    for (0..MAX_EPOLL_ENTRIES) |i| {
        if (count >= maxevents) break;
        if (!ep.entries[i].in_use) continue;

        const ready = checkFdReadiness(&current.fds, ep.entries[i].fd, ep.entries[i].events);
        if (ready != 0) {
            // Write epoll_event: { u32 events, u64 data } = 12 bytes packed
            const off = count * 12;
            ready_buf[off] = @truncate(ready);
            ready_buf[off + 1] = @truncate(ready >> 8);
            ready_buf[off + 2] = @truncate(ready >> 16);
            ready_buf[off + 3] = @truncate(ready >> 24);
            const d = ep.entries[i].user_data;
            ready_buf[off + 4] = @truncate(d);
            ready_buf[off + 5] = @truncate(d >> 8);
            ready_buf[off + 6] = @truncate(d >> 16);
            ready_buf[off + 7] = @truncate(d >> 24);
            ready_buf[off + 8] = @truncate(d >> 32);
            ready_buf[off + 9] = @truncate(d >> 40);
            ready_buf[off + 10] = @truncate(d >> 48);
            ready_buf[off + 11] = @truncate(d >> 56);
            count += 1;
        }
    }

    if (count > 0) {
        // Copy results to user
        const bytes: usize = @as(usize, count) * 12;
        if (syscall.copyToUser(current.page_table, events_ptr, ready_buf[0..bytes])) {
            ep.deadline_tick = 0;
            frame.rax = count;
        } else {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        }
        return;
    }

    // No ready fds
    if (timeout == 0) {
        frame.rax = 0;
        return;
    }

    // Check if deadline already set (re-entry after block)
    if (ep.deadline_tick != 0) {
        const current_tick = idt.getTickCount();
        if (current_tick >= ep.deadline_tick) {
            // Timeout expired
            ep.deadline_tick = 0;
            ep.waiting_pid = 0;
            frame.rax = 0;
            return;
        }
        // Not expired, re-block with remaining time
        current.wake_tick = ep.deadline_tick;
    } else if (timeout > 0) {
        // First entry — set deadline
        const ticks: u64 = (@as(u64, @intCast(timeout)) + 9) / 10; // 100Hz timer
        ep.deadline_tick = idt.getTickCount() + ticks;
        current.wake_tick = ep.deadline_tick;
    }
    // timeout == -1: infinite wait, no wake_tick

    // Block
    ep.waiting_pid = current.pid;
    frame.rip -= 2;
    current.state = .blocked;
    scheduler.blockAndSchedule(frame);
}
