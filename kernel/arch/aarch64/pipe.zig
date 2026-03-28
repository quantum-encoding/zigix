/// Pipe subsystem — ring buffer with VFS-integrated read/write/close.
///
/// Each pipe is a 64 KiB ring buffer with reader/writer counts.
/// pipeRead returns negated EAGAIN when empty (has writers) or 0 (EOF, no writers).
/// pipeWrite returns negated EAGAIN when full or negated EPIPE (no readers).
/// Close decrements reader/writer counts and wakes blocked peers.

const vfs = @import("vfs.zig");
const fd_table = @import("fd_table.zig");
const uart = @import("uart.zig");
const scheduler = @import("scheduler.zig");
const epoll = @import("epoll.zig");
const spinlock = @import("spinlock.zig");

const PIPE_BUF_SIZE: u32 = 65536;
const MAX_PIPES: usize = 128;

pub const Pipe = struct {
    buffer: [PIPE_BUF_SIZE]u8,
    read_pos: u32,
    write_pos: u32,
    count: u32,
    readers: u8,
    writers: u8,
    blocked_reader_pid: u64,
    blocked_writer_pid: u64,
    in_use: bool,
};

/// SMP lock protecting all pipe global mutable state: pipes[], pipe_inodes[],
/// inodes_initialized. Must be held when reading or modifying any pipe's ring
/// buffer, counters, or blocked_*_pid fields. Released before calling into the
/// scheduler or epoll subsystem to avoid lock ordering violations.
var pipe_lock: spinlock.IrqSpinlock = .{};

var pipes: [MAX_PIPES]Pipe = [_]Pipe{.{
    .buffer = [_]u8{0} ** PIPE_BUF_SIZE,
    .read_pos = 0,
    .write_pos = 0,
    .count = 0,
    .readers = 0,
    .writers = 0,
    .blocked_reader_pid = 0,
    .blocked_writer_pid = 0,
    .in_use = false,
}} ** MAX_PIPES;

var pipe_inodes: [MAX_PIPES]vfs.Inode = undefined;
var inodes_initialized: bool = false;

const pipe_ops = vfs.FileOperations{
    .read = pipeRead,
    .write = pipeWrite,
    .close = pipeClose,
    .readdir = null,
};

/// Returns true if the given inode belongs to a pipe.
pub fn isPipeInode(inode: *const vfs.Inode) bool {
    return inode.ops == &pipe_ops;
}

fn initInodes() void {
    for (0..MAX_PIPES) |i| {
        pipe_inodes[i] = .{
            .ino = 0x10000 + i,
            .mode = vfs.S_IFIFO | 0o666,
            .size = 0,
            .nlink = 1,
            .ops = &pipe_ops,
            .fs_data = null,
        };
    }
    inodes_initialized = true;
}

fn getPipeIndex(inode: *vfs.Inode) ?usize {
    const addr = @intFromPtr(inode);
    const base = @intFromPtr(&pipe_inodes[0]);
    if (addr < base) return null;
    const offset = addr - base;
    const idx = offset / @sizeOf(vfs.Inode);
    if (idx >= MAX_PIPES) return null;
    return idx;
}

fn pipeRead(desc: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    const idx = getPipeIndex(desc.inode) orelse return 0;

    pipe_lock.acquire();

    const p = &pipes[idx];

    if (p.count == 0) {
        if (p.writers == 0) {
            pipe_lock.release();
            return 0; // EOF
        }
        if (scheduler.currentProcess()) |proc| {
            p.blocked_reader_pid = proc.pid;
            // For blocking pipes, set .blocked atomically under pipe_lock
            // so wakeProcess (called by pipeWrite/pipeClose on another CPU)
            // always sees the correct state. Without this, the wake can fire
            // between pipeRead returning and sysRead setting .blocked → lost wake.
            if (desc.flags & vfs.O_NONBLOCK == 0) {
                proc.state = .blocked;
            }
        }
        pipe_lock.release();
        return -@as(isize, 11); // -EAGAIN
    }

    const to_copy = if (count > p.count) @as(usize, p.count) else count;

    // Bulk copy using contiguous ring buffer regions (two-phase)
    const first = @min(to_copy, @as(usize, PIPE_BUF_SIZE - p.read_pos));
    @memcpy(buf[0..first], p.buffer[p.read_pos..][0..first]);
    const second = to_copy - first;
    if (second > 0) @memcpy(buf[first..][0..second], p.buffer[0..second]);
    p.read_pos = (p.read_pos + @as(u32, @truncate(to_copy))) % PIPE_BUF_SIZE;
    p.count -= @as(u32, @truncate(to_copy));

    // Collect wake target under lock, then release before calling out
    var wake_writer_pid: u64 = 0;
    if (p.blocked_writer_pid != 0) {
        wake_writer_pid = p.blocked_writer_pid;
        p.blocked_writer_pid = 0;
    }

    pipe_lock.release();

    // Wake blocked writer and epoll waiters outside lock
    if (wake_writer_pid != 0) {
        scheduler.wakeProcess(wake_writer_pid);
    }
    epoll.wakeAllWaiters();

    return @intCast(to_copy);
}

fn pipeWrite(desc: *vfs.FileDescription, buf: [*]const u8, count: usize) isize {
    const idx = getPipeIndex(desc.inode) orelse return 0;

    pipe_lock.acquire();

    const p = &pipes[idx];

    if (p.readers == 0) {
        pipe_lock.release();
        return -@as(isize, 32); // -EPIPE
    }

    const space: u32 = PIPE_BUF_SIZE - p.count;
    if (space == 0) {
        if (scheduler.currentProcess()) |proc| {
            p.blocked_writer_pid = proc.pid;
            if (desc.flags & vfs.O_NONBLOCK == 0) {
                proc.state = .blocked;
            }
        }
        pipe_lock.release();
        return -@as(isize, 11); // -EAGAIN
    }

    const to_copy = if (count > space) @as(usize, space) else count;

    // Bulk copy using contiguous ring buffer regions (two-phase)
    const first = @min(to_copy, @as(usize, PIPE_BUF_SIZE - p.write_pos));
    @memcpy(p.buffer[p.write_pos..][0..first], buf[0..first]);
    const second = to_copy - first;
    if (second > 0) @memcpy(p.buffer[0..second], buf[first..][0..second]);
    p.write_pos = (p.write_pos + @as(u32, @truncate(to_copy))) % PIPE_BUF_SIZE;
    p.count += @as(u32, @truncate(to_copy));

    // Collect wake target under lock, then release before calling out
    var wake_reader_pid: u64 = 0;
    if (p.blocked_reader_pid != 0) {
        wake_reader_pid = p.blocked_reader_pid;
        p.blocked_reader_pid = 0;
    }

    pipe_lock.release();

    // Wake blocked reader and epoll waiters outside lock
    if (wake_reader_pid != 0) {
        scheduler.wakeProcess(wake_reader_pid);
    }
    epoll.wakeAllWaiters();

    return @intCast(to_copy);
}

fn pipeClose(desc: *vfs.FileDescription) void {
    const idx = getPipeIndex(desc.inode) orelse return;

    pipe_lock.acquire();

    const p = &pipes[idx];

    var wake_pid: u64 = 0;

    const access = desc.flags & vfs.O_ACCMODE;
    if (access == vfs.O_RDONLY) {
        if (p.readers > 0) p.readers -= 1;
        if (p.blocked_writer_pid != 0) {
            wake_pid = p.blocked_writer_pid;
            p.blocked_writer_pid = 0;
        }
    } else if (access == vfs.O_WRONLY) {
        if (p.writers > 0) p.writers -= 1;
        if (p.blocked_reader_pid != 0) {
            wake_pid = p.blocked_reader_pid;
            p.blocked_reader_pid = 0;
        }
    }

    if (p.readers == 0 and p.writers == 0) {
        p.in_use = false;
    }

    pipe_lock.release();

    // Wake blocked peer and epoll waiters outside lock
    if (wake_pid != 0) {
        scheduler.wakeProcess(wake_pid);
    }
    epoll.wakeAllWaiters();
}

/// Check poll/epoll readiness for a pipe inode.
/// Returns bitmask of EPOLLIN/EPOLLOUT/EPOLLHUP.
pub fn checkReadiness(inode: *vfs.Inode) u32 {
    const idx = getPipeIndex(inode) orelse return 0;

    pipe_lock.acquire();

    const p = &pipes[idx];
    if (!p.in_use) {
        pipe_lock.release();
        return 0;
    }

    var events: u32 = 0;

    // Readable: has data, or EOF (no writers)
    if (p.count > 0 or p.writers == 0) events |= 0x001; // EPOLLIN

    // Writable: has space and has readers
    if (p.count < PIPE_BUF_SIZE and p.readers > 0) events |= 0x004; // EPOLLOUT

    // HUP: no writers left
    if (p.writers == 0) events |= 0x010; // EPOLLHUP

    pipe_lock.release();

    return events;
}

/// Atomically check if any of the given pipe inodes are readable (have data
/// or EOF). If none are ready: registers the current process PID as
/// blocked_reader_pid on each pipe and sets process state to .blocked.
///
/// This MUST be called after a non-blocking readiness scan found nothing ready,
/// to close the TOCTOU race between checking and blocking.
///
/// Returns true if any pipe became ready (caller should re-scan).
/// Returns false if the process was blocked (caller should rewind ELR and
/// call blockAndSchedule).
pub fn pollRegisterOrReady(inodes: []?*vfs.Inode) bool {
    const proc = scheduler.currentProcess() orelse return true;

    pipe_lock.acquire();

    // Check if any pipe has data or EOF (writers == 0)
    var any_ready = false;
    for (inodes) |maybe_inode| {
        const inode = maybe_inode orelse continue;
        const idx = getPipeIndex(inode) orelse continue;
        const p = &pipes[idx];
        if (!p.in_use) continue;
        if (p.count > 0 or p.writers == 0) {
            any_ready = true;
            break;
        }
    }

    if (any_ready) {
        pipe_lock.release();
        return true;
    }

    // None ready — register for wakeup on each pipe and block
    for (inodes) |maybe_inode| {
        const inode = maybe_inode orelse continue;
        const idx = getPipeIndex(inode) orelse continue;
        const p = &pipes[idx];
        if (p.in_use and p.blocked_reader_pid == 0) {
            p.blocked_reader_pid = proc.pid;
        }
    }
    proc.state = .blocked;

    pipe_lock.release();
    return false;
}

pub const PipeResult = struct {
    read_desc: *vfs.FileDescription,
    write_desc: *vfs.FileDescription,
};

pub fn createPipe() ?PipeResult {
    if (!inodes_initialized) initInodes();

    pipe_lock.acquire();

    var pipe_idx: ?usize = null;
    for (0..MAX_PIPES) |i| {
        if (!pipes[i].in_use) {
            pipe_idx = i;
            break;
        }
    }
    const idx = pipe_idx orelse {
        pipe_lock.release();
        return null;
    };

    pipes[idx].read_pos = 0;
    pipes[idx].write_pos = 0;
    pipes[idx].count = 0;
    pipes[idx].readers = 1;
    pipes[idx].writers = 1;
    pipes[idx].blocked_reader_pid = 0;
    pipes[idx].blocked_writer_pid = 0;
    pipes[idx].in_use = true;

    pipe_lock.release();

    // VFS allocations done outside pipe_lock (separate subsystem)
    const read_desc = vfs.allocFileDescription() orelse {
        pipe_lock.acquire();
        pipes[idx].in_use = false;
        pipe_lock.release();
        return null;
    };
    read_desc.inode = &pipe_inodes[idx];
    read_desc.flags = vfs.O_RDONLY;
    read_desc.offset = 0;

    const write_desc = vfs.allocFileDescription() orelse {
        vfs.releaseFileDescription(read_desc);
        pipe_lock.acquire();
        pipes[idx].in_use = false;
        pipe_lock.release();
        return null;
    };
    write_desc.inode = &pipe_inodes[idx];
    write_desc.flags = vfs.O_WRONLY;
    write_desc.offset = 0;

    return .{
        .read_desc = read_desc,
        .write_desc = write_desc,
    };
}

/// Get the pipe index from a pipe inode pointer.
pub fn getPipeIdx(inode: *vfs.Inode) ?usize {
    const addr = @intFromPtr(inode);
    const base = @intFromPtr(&pipe_inodes[0]);
    if (addr < base) return null;
    const offset = addr - base;
    const idx = offset / @sizeOf(vfs.Inode);
    if (idx >= MAX_PIPES) return null;
    return idx;
}

/// Open an existing pipe by index (for FIFO support).
/// Increments reader or writer count depending on access_mode.
pub fn openExistingPipe(idx: usize, access_mode: u32) ?*vfs.FileDescription {
    if (idx >= MAX_PIPES) return null;
    if (!inodes_initialized) initInodes();

    pipe_lock.acquire();
    if (!pipes[idx].in_use) {
        pipe_lock.release();
        return null;
    }

    if (access_mode == vfs.O_WRONLY) {
        pipes[idx].writers +|= 1;
    } else {
        pipes[idx].readers +|= 1;
    }
    pipe_lock.release();

    const desc = vfs.allocFileDescription() orelse {
        pipe_lock.acquire();
        if (access_mode == vfs.O_WRONLY) {
            pipes[idx].writers -|= 1;
        } else {
            pipes[idx].readers -|= 1;
        }
        pipe_lock.release();
        return null;
    };
    desc.inode = &pipe_inodes[idx];
    desc.flags = if (access_mode == vfs.O_WRONLY) vfs.O_WRONLY else vfs.O_RDONLY;
    desc.offset = 0;
    return desc;
}
