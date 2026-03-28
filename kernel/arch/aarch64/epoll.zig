/// epoll — Event-driven I/O multiplexing (level-triggered) for ARM64.
///
/// epoll_create1 allocates an instance with a VFS-backed fd.
/// epoll_ctl adds/modifies/removes monitored fds.
/// epoll_wait scans monitored fds for readiness, blocking if none ready.
///
/// Readiness is determined by calling subsystem-specific checkReadiness()
/// functions (pipe.zig, socket.zig). Subsystems call wakeAllWaiters()
/// when events occur that might change readiness.
///
/// ARM64 adaptations from x86_64:
///   - TrapFrame instead of InterruptFrame
///   - Return values via frame.x[0] instead of frame.rax
///   - Arguments via frame.x[0..3] instead of rdi/rsi/rdx/r10
///   - SVC replay: frame.elr -= 4 (4-byte SVC instruction vs 2-byte syscall)
///   - Identity mapping: no HHDM translation needed
///   - No errno module: raw negative error values
///   - No syscall.validateUserBuffer/copyFromUser/copyToUser: use vmm.translate + direct access

const exception = @import("exception.zig");
const uart = @import("uart.zig");
const vfs = @import("vfs.zig");
const fd_table = @import("fd_table.zig");
const pipe = @import("pipe.zig");
const socket = @import("socket.zig");
const scheduler = @import("scheduler.zig");
const process = @import("process.zig");
const vmm = @import("vmm.zig");
const timer = @import("timer.zig");
const spinlock = @import("spinlock.zig");

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

// --- Error constants (raw negative values, no errno module on ARM64) ---

const ESRCH: i64 = -3;
const EBADF: i64 = -9;
const ENOMEM: i64 = -12;
const EFAULT: i64 = -14;
const EEXIST: i64 = -17;
const EINVAL: i64 = -22;
const ENFILE: i64 = -23;
const EMFILE: i64 = -24;
const ENOENT: i64 = -2;

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

/// SMP lock protecting all epoll global mutable state: instances[],
/// epoll_inodes[], inodes_initialized. Must be held when reading or modifying
/// instance entries, waiting_pid, or deadline_tick fields. Released before
/// calling into the scheduler, pipe, or socket subsystems to avoid lock
/// ordering violations and deadlock.
var epoll_lock: spinlock.IrqSpinlock = .{};

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
    epoll_lock.acquire();
    instances[idx].in_use = false;
    epoll_lock.release();
}

// --- Core operations ---

fn allocEpoll() ?usize {
    if (!inodes_initialized) initInodes();

    epoll_lock.acquire();
    for (0..MAX_EPOLL_INSTANCES) |i| {
        if (!instances[i].in_use) {
            instances[i] = emptyInstance();
            instances[i].in_use = true;
            epoll_lock.release();
            return i;
        }
    }
    epoll_lock.release();
    return null;
}

/// Check readiness of a single fd in the context of a process.
/// Returns the ready event bitmask (intersection of requested events and actual readiness).
fn checkFdReadiness(fds: *[fd_table.MAX_FDS]?*vfs.FileDescription, fd: u32, requested: u32) u32 {
    if (fd >= fd_table.MAX_FDS) return 0;
    const desc = fds[fd] orelse return EPOLLHUP; // closed fd -> HUP

    const inode = desc.inode;
    const file_type = inode.mode & vfs.S_IFMT;

    var ready: u32 = 0;

    if (file_type == vfs.S_IFIFO) {
        // Pipe — delegate to pipe subsystem
        ready = pipe.checkReadiness(inode);
    } else if (file_type == socket.S_IFSOCK) {
        // Socket — delegate to socket subsystem
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
    var pids_to_wake: [MAX_EPOLL_INSTANCES]u64 = [_]u64{0} ** MAX_EPOLL_INSTANCES;
    var wake_count: usize = 0;

    epoll_lock.acquire();
    for (0..MAX_EPOLL_INSTANCES) |i| {
        if (instances[i].in_use and instances[i].waiting_pid != 0) {
            pids_to_wake[wake_count] = instances[i].waiting_pid;
            wake_count += 1;
            instances[i].waiting_pid = 0;
        }
    }
    epoll_lock.release();

    // Wake processes outside lock to avoid holding epoll_lock across scheduler calls
    if (wake_count > 0) {
        uart.print("[ep-wake] waking {} pids:", .{wake_count});
        for (0..wake_count) |i| {
            uart.print(" P{}", .{pids_to_wake[i]});
        }
        uart.print("\n", .{});
    }
    for (0..wake_count) |i| {
        scheduler.wakeProcess(pids_to_wake[i]);
    }
}

// --- Syscall handlers ---
// ARM64 pattern: all return i64, frame return value set via frame.x[0].

/// epoll_create1(flags) -> fd
pub fn sysEpollCreate1(frame: *exception.TrapFrame) i64 {
    // flags (frame.x[0]) ignored for MVP (EPOLL_CLOEXEC not needed)
    _ = frame.x[0];

    const current = scheduler.currentProcess() orelse {
        return ESRCH;
    };

    // allocEpoll acquires/releases epoll_lock internally
    const ep_idx = allocEpoll() orelse {
        return ENFILE;
    };

    // VFS/fd_table operations done outside epoll_lock
    const desc = vfs.allocFileDescription() orelse {
        epoll_lock.acquire();
        instances[ep_idx].in_use = false;
        epoll_lock.release();
        return ENFILE;
    };
    desc.inode = &epoll_inodes[ep_idx];
    desc.flags = vfs.O_RDWR;
    desc.offset = 0;

    const fd_num = fd_table.fdAlloc(&current.fds, desc) orelse {
        vfs.releaseFileDescription(desc);
        epoll_lock.acquire();
        instances[ep_idx].in_use = false;
        epoll_lock.release();
        return EMFILE;
    };

    return @as(i64, @intCast(fd_num));
}

/// epoll_ctl(epfd, op, fd, event) -> 0 or negative error
pub fn sysEpollCtl(frame: *exception.TrapFrame) i64 {
    const epfd = frame.x[0];
    const op: u32 = @truncate(frame.x[1]);
    const target_fd: u32 = @truncate(frame.x[2]);
    const event_ptr = frame.x[3];

    const current = scheduler.currentProcess() orelse {
        return ESRCH;
    };

    // Get epoll instance from epfd (fd_table lookup is per-process, no epoll_lock needed)
    const ep_desc = fd_table.fdGet(&current.fds, epfd) orelse {
        return EBADF;
    };
    const ep_idx = getEpollIndex(ep_desc.inode) orelse {
        return EINVAL;
    };

    // Validate target fd exists (per-process state, no epoll_lock needed)
    if (target_fd >= fd_table.MAX_FDS or fd_table.fdGet(&current.fds, target_fd) == null) {
        return EBADF;
    }

    switch (op) {
        EPOLL_CTL_ADD => {
            // Read epoll_event from user memory BEFORE acquiring lock
            if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(event_ptr)) == null) {
                return EFAULT;
            }
            const ev_bytes = @as(*align(1) const [12]u8, @ptrFromInt(event_ptr));

            const events = @as(u32, ev_bytes[0]) |
                (@as(u32, ev_bytes[1]) << 8) |
                (@as(u32, ev_bytes[2]) << 16) |
                (@as(u32, ev_bytes[3]) << 24);
            const data = @as(u64, ev_bytes[4]) |
                (@as(u64, ev_bytes[5]) << 8) |
                (@as(u64, ev_bytes[6]) << 16) |
                (@as(u64, ev_bytes[7]) << 24) |
                (@as(u64, ev_bytes[8]) << 32) |
                (@as(u64, ev_bytes[9]) << 40) |
                (@as(u64, ev_bytes[10]) << 48) |
                (@as(u64, ev_bytes[11]) << 56);

            epoll_lock.acquire();

            const ep = &instances[ep_idx];
            if (!ep.in_use) {
                epoll_lock.release();
                return EBADF;
            }

            // Check not already monitored
            for (0..MAX_EPOLL_ENTRIES) |i| {
                if (ep.entries[i].in_use and ep.entries[i].fd == target_fd) {
                    epoll_lock.release();
                    return EEXIST;
                }
            }

            // Find free entry
            for (0..MAX_EPOLL_ENTRIES) |i| {
                if (!ep.entries[i].in_use) {
                    ep.entries[i] = .{
                        .fd = target_fd,
                        .events = events,
                        .user_data = data,
                        .in_use = true,
                    };
                    epoll_lock.release();
                    return 0;
                }
            }
            epoll_lock.release();
            return ENOMEM;
        },
        EPOLL_CTL_DEL => {
            epoll_lock.acquire();

            const ep = &instances[ep_idx];
            if (!ep.in_use) {
                epoll_lock.release();
                return EBADF;
            }

            for (0..MAX_EPOLL_ENTRIES) |i| {
                if (ep.entries[i].in_use and ep.entries[i].fd == target_fd) {
                    ep.entries[i].in_use = false;
                    epoll_lock.release();
                    return 0;
                }
            }
            epoll_lock.release();
            return ENOENT;
        },
        EPOLL_CTL_MOD => {
            // Read updated event from user memory BEFORE acquiring lock
            if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(event_ptr)) == null) {
                return EFAULT;
            }
            const ev_bytes = @as(*align(1) const [12]u8, @ptrFromInt(event_ptr));

            const events = @as(u32, ev_bytes[0]) |
                (@as(u32, ev_bytes[1]) << 8) |
                (@as(u32, ev_bytes[2]) << 16) |
                (@as(u32, ev_bytes[3]) << 24);
            const data = @as(u64, ev_bytes[4]) |
                (@as(u64, ev_bytes[5]) << 8) |
                (@as(u64, ev_bytes[6]) << 16) |
                (@as(u64, ev_bytes[7]) << 24) |
                (@as(u64, ev_bytes[8]) << 32) |
                (@as(u64, ev_bytes[9]) << 40) |
                (@as(u64, ev_bytes[10]) << 48) |
                (@as(u64, ev_bytes[11]) << 56);

            epoll_lock.acquire();

            const ep = &instances[ep_idx];
            if (!ep.in_use) {
                epoll_lock.release();
                return EBADF;
            }

            for (0..MAX_EPOLL_ENTRIES) |i| {
                if (ep.entries[i].in_use and ep.entries[i].fd == target_fd) {
                    ep.entries[i].events = events;
                    ep.entries[i].user_data = data;
                    epoll_lock.release();
                    return 0;
                }
            }
            epoll_lock.release();
            return ENOENT;
        },
        else => {
            return EINVAL;
        },
    }
}

/// epoll_wait(epfd, events, maxevents, timeout) -> count or negative error
pub fn sysEpollWait(frame: *exception.TrapFrame) i64 {
    const epfd = frame.x[0];
    const events_ptr = frame.x[1];
    const maxevents: u32 = @truncate(frame.x[2]);
    const timeout: i32 = @bitCast(@as(u32, @truncate(frame.x[3])));

    const current = scheduler.currentProcess() orelse {
        return ESRCH;
    };

    if (maxevents == 0 or maxevents > 256) {
        return EINVAL;
    }

    // Get epoll instance (fd_table is per-process, no epoll_lock needed)
    const ep_desc = fd_table.fdGet(&current.fds, epfd) orelse {
        return EBADF;
    };
    const ep_idx = getEpollIndex(ep_desc.inode) orelse {
        return EINVAL;
    };

    // Snapshot the entries under lock so we can release before calling into
    // pipe/socket subsystems (which have their own locks).
    var snapshot_fds: [MAX_EPOLL_ENTRIES]u32 = undefined;
    var snapshot_events: [MAX_EPOLL_ENTRIES]u32 = undefined;
    var snapshot_data: [MAX_EPOLL_ENTRIES]u64 = undefined;
    var snapshot_in_use: [MAX_EPOLL_ENTRIES]bool = undefined;

    epoll_lock.acquire();

    const ep = &instances[ep_idx];
    if (!ep.in_use) {
        epoll_lock.release();
        return EBADF;
    }

    for (0..MAX_EPOLL_ENTRIES) |i| {
        snapshot_fds[i] = ep.entries[i].fd;
        snapshot_events[i] = ep.entries[i].events;
        snapshot_data[i] = ep.entries[i].user_data;
        snapshot_in_use[i] = ep.entries[i].in_use;
    }

    epoll_lock.release();

    // Scan monitored fds for readiness WITHOUT holding epoll_lock.
    // checkFdReadiness calls into pipe/socket which acquire their own locks.
    var count: u32 = 0;
    var ready_buf: [256 * 12]u8 = undefined; // maxevents * sizeof(epoll_event)

    for (0..MAX_EPOLL_ENTRIES) |i| {
        if (count >= maxevents) break;
        if (!snapshot_in_use[i]) continue;

        const ready = checkFdReadiness(&current.fds, snapshot_fds[i], snapshot_events[i]);
        if (ready != 0) {
            // Write epoll_event: { u32 events, u64 data } = 12 bytes packed
            const off = count * 12;
            ready_buf[off] = @truncate(ready);
            ready_buf[off + 1] = @truncate(ready >> 8);
            ready_buf[off + 2] = @truncate(ready >> 16);
            ready_buf[off + 3] = @truncate(ready >> 24);
            const d = snapshot_data[i];
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
        // Copy results to user memory (identity mapping: validate then write directly)
        const bytes: usize = @as(usize, count) * 12;
        if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(events_ptr)) == null) {
            return EFAULT;
        }
        const dest: [*]u8 = @ptrFromInt(events_ptr);
        for (0..bytes) |b| {
            dest[b] = ready_buf[b];
        }
        // Clear deadline under lock since we're returning events
        epoll_lock.acquire();
        instances[ep_idx].deadline_tick = 0;
        epoll_lock.release();
        return @as(i64, @intCast(count));
    }

    // No ready fds
    if (timeout == 0) {
        return 0;
    }

    // Set up blocking state under lock, then release before calling scheduler
    epoll_lock.acquire();

    // Re-check in_use under lock (could have been closed concurrently)
    if (!instances[ep_idx].in_use) {
        epoll_lock.release();
        return EBADF;
    }

    // Check if deadline already set (re-entry after block)
    if (instances[ep_idx].deadline_tick != 0) {
        const current_tick = timer.getTicks();
        if (current_tick >= instances[ep_idx].deadline_tick) {
            // Timeout expired
            instances[ep_idx].deadline_tick = 0;
            instances[ep_idx].waiting_pid = 0;
            epoll_lock.release();
            return 0;
        }
        // Not expired, re-block with remaining time
        current.wake_tick = instances[ep_idx].deadline_tick;
    } else if (timeout > 0) {
        // First entry — set deadline
        // Timer runs at 100Hz, so convert ms to ticks: (timeout_ms + 9) / 10
        const ticks: u64 = (@as(u64, @intCast(timeout)) + 9) / 10;
        instances[ep_idx].deadline_tick = timer.getTicks() + ticks;
        current.wake_tick = instances[ep_idx].deadline_tick;
    }
    // timeout == -1: infinite wait, no wake_tick

    // Record this process as waiting AND set .blocked UNDER epoll_lock.
    // wakeAllWaiters acquires epoll_lock, reads waiting_pid, then calls
    // wakeProcess which only transitions blocked states to .ready.
    // If we set .blocked AFTER releasing the lock, a wakeProcess call
    // between the release and the state write sees .running → no-op → deadlock.
    instances[ep_idx].waiting_pid = current.pid;
    current.state = .blocked;

    epoll_lock.release();

    // Re-scan readiness after committing the blocked state.  Between our
    // first scan and setting waiting_pid, the pipe/socket could have become
    // ready (e.g. pipeClose decremented writers).  wakeAllWaiters might
    // have fired before we set waiting_pid, so the wake was lost.  A
    // re-scan here catches that TOCTOU window.
    //
    // If events are found, collect them, cancel the block, and return
    // directly.  We cannot use SVC replay here because handleSyscall
    // overwrites frame.x[0] (the epfd argument) with the return value.
    {
        var rc: u32 = 0;
        var rc_buf: [256 * 12]u8 = undefined;

        for (0..MAX_EPOLL_ENTRIES) |ri| {
            if (rc >= maxevents) break;
            if (!snapshot_in_use[ri]) continue;
            const rready = checkFdReadiness(&current.fds, snapshot_fds[ri], snapshot_events[ri]);
            if (rready != 0) {
                const off = rc * 12;
                rc_buf[off] = @truncate(rready);
                rc_buf[off + 1] = @truncate(rready >> 8);
                rc_buf[off + 2] = @truncate(rready >> 16);
                rc_buf[off + 3] = @truncate(rready >> 24);
                const d = snapshot_data[ri];
                rc_buf[off + 4] = @truncate(d);
                rc_buf[off + 5] = @truncate(d >> 8);
                rc_buf[off + 6] = @truncate(d >> 16);
                rc_buf[off + 7] = @truncate(d >> 24);
                rc_buf[off + 8] = @truncate(d >> 32);
                rc_buf[off + 9] = @truncate(d >> 40);
                rc_buf[off + 10] = @truncate(d >> 48);
                rc_buf[off + 11] = @truncate(d >> 56);
                rc += 1;
            }
        }

        if (rc > 0) {
            // Events appeared — cancel the block and return them directly.
            current.state = .running;
            epoll_lock.acquire();
            instances[ep_idx].waiting_pid = 0;
            instances[ep_idx].deadline_tick = 0;
            epoll_lock.release();

            const rc_bytes: usize = @as(usize, rc) * 12;
            if (vmm.translate(vmm.PhysAddr.from(current.page_table), vmm.VirtAddr.from(events_ptr)) == null) return EFAULT;
            const dest: [*]u8 = @ptrFromInt(events_ptr);
            for (0..rc_bytes) |b| {
                dest[b] = rc_buf[b];
            }
            return @as(i64, @intCast(rc));
        }
    }

    // Block the process and replay the SVC instruction on wake.
    // Scheduler has its own sched_lock — never hold epoll_lock across this call.
    uart.print("[ep-blk] P{} epfd={}\n", .{ current.pid, epfd });
    frame.elr -= 4; // ARM64 SVC is 4 bytes — replay on wake
    scheduler.blockAndSchedule(frame);
    return 0; // Dummy return — process has been switched out
}
