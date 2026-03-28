/// Pipe subsystem — ring buffer with VFS-integrated read/write/close.
///
/// Each pipe is a 4 KiB ring buffer with reader/writer counts.
/// pipeRead returns negated EAGAIN when empty (has writers) or 0 (EOF, no writers).
/// pipeWrite returns negated EAGAIN when full or negated EPIPE (no readers).
/// Close decrements reader/writer counts and wakes blocked peers.

const vfs = @import("vfs.zig");
const fd_table = @import("fd_table.zig");
const serial = @import("../arch/x86_64/serial.zig");
const scheduler = @import("../proc/scheduler.zig");
const epoll = @import("../proc/epoll.zig");

const PIPE_BUF_SIZE: u16 = 65535;
const MAX_PIPES: usize = 32;

pub const Pipe = struct {
    buffer: [PIPE_BUF_SIZE]u8,
    read_pos: u16,
    write_pos: u16,
    count: u16,
    readers: u8,
    writers: u8,
    blocked_reader_pid: u64,
    blocked_writer_pid: u64,
    in_use: bool,
};

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
    const p = &pipes[idx];

    if (p.count == 0) {
        if (p.writers == 0) return 0; // EOF — no writers left
        // Set blocked reader for wake-up
        if (scheduler.currentProcess()) |proc| {
            p.blocked_reader_pid = proc.pid;
        }
        return -@as(isize, 11); // -EAGAIN
    }

    const to_copy = if (count > p.count) @as(usize, p.count) else count;

    // Bulk copy using contiguous ring buffer regions (two-phase)
    const first = @min(to_copy, @as(usize, PIPE_BUF_SIZE - p.read_pos));
    @memcpy(buf[0..first], p.buffer[p.read_pos..][0..first]);
    const second = to_copy - first;
    if (second > 0) @memcpy(buf[first..][0..second], p.buffer[0..second]);
    p.read_pos = @truncate((@as(u32, p.read_pos) + @as(u32, @truncate(to_copy))) % PIPE_BUF_SIZE);
    p.count -= @truncate(to_copy);

    // Wake blocked writer if any
    if (p.blocked_writer_pid != 0) {
        scheduler.wakeProcess(p.blocked_writer_pid);
        p.blocked_writer_pid = 0;
    }

    // Notify epoll waiters (pipe now has space for writers)
    epoll.wakeAllWaiters();

    return @intCast(to_copy);
}

fn pipeWrite(desc: *vfs.FileDescription, buf: [*]const u8, count: usize) isize {
    const idx = getPipeIndex(desc.inode) orelse return 0;
    const p = &pipes[idx];

    if (p.readers == 0) {
        // Send SIGPIPE to current process
        if (scheduler.currentProcess()) |proc| {
            const sig = @import("../proc/signal.zig");
            sig.postSignal(proc, sig.SIGPIPE);
        }
        return -@as(isize, 32); // -EPIPE
    }

    const space: u16 = PIPE_BUF_SIZE - p.count;
    if (space == 0) {
        if (scheduler.currentProcess()) |proc| {
            p.blocked_writer_pid = proc.pid;
        }
        return -@as(isize, 11); // -EAGAIN
    }

    const to_copy = if (count > space) @as(usize, space) else count;

    // Bulk copy using contiguous ring buffer regions (two-phase)
    const first = @min(to_copy, @as(usize, PIPE_BUF_SIZE - p.write_pos));
    @memcpy(p.buffer[p.write_pos..][0..first], buf[0..first]);
    const second = to_copy - first;
    if (second > 0) @memcpy(p.buffer[0..second], buf[first..][0..second]);
    p.write_pos = @truncate((@as(u32, p.write_pos) + @as(u32, @truncate(to_copy))) % PIPE_BUF_SIZE);
    p.count += @truncate(to_copy);

    // Wake blocked reader if any
    if (p.blocked_reader_pid != 0) {
        scheduler.wakeProcess(p.blocked_reader_pid);
        p.blocked_reader_pid = 0;
    }

    // Notify epoll waiters (pipe now has data for readers)
    epoll.wakeAllWaiters();

    return @intCast(to_copy);
}

fn pipeClose(desc: *vfs.FileDescription) void {
    const idx = getPipeIndex(desc.inode) orelse return;
    const p = &pipes[idx];

    // Determine if this was a reader or writer based on flags
    const access = desc.flags & vfs.O_ACCMODE;
    if (access == vfs.O_RDONLY) {
        if (p.readers > 0) p.readers -= 1;
        // Wake blocked writer — they'll get EPIPE on retry
        if (p.blocked_writer_pid != 0) {
            scheduler.wakeProcess(p.blocked_writer_pid);
            p.blocked_writer_pid = 0;
        }
    } else if (access == vfs.O_WRONLY) {
        if (p.writers > 0) p.writers -= 1;
        // Wake blocked reader — they'll get EOF on retry
        if (p.blocked_reader_pid != 0) {
            scheduler.wakeProcess(p.blocked_reader_pid);
            p.blocked_reader_pid = 0;
        }
    }

    // Free pipe if both ends closed
    if (p.readers == 0 and p.writers == 0) {
        p.in_use = false;
    }

    // Notify epoll waiters (HUP/EOF conditions changed)
    epoll.wakeAllWaiters();
}

/// Get the pipe index for a pipe inode (public wrapper).
pub fn getPipeIdx(inode: *vfs.Inode) ?usize {
    return getPipeIndex(inode);
}

/// Open an existing pipe by index, returning a FileDescription for the requested access mode.
/// Used by FIFO (named pipe) handling to attach to an already-created pipe.
pub fn openExistingPipe(idx: usize, access_mode: u32) ?*vfs.FileDescription {
    if (idx >= MAX_PIPES or !pipes[idx].in_use) return null;
    if (!inodes_initialized) initInodes();

    const desc = vfs.allocFileDescription() orelse return null;
    desc.inode = &pipe_inodes[idx];
    desc.flags = access_mode;
    desc.offset = 0;

    // Increment the appropriate reader/writer count
    if (access_mode == vfs.O_WRONLY) {
        pipes[idx].writers += 1;
    } else {
        pipes[idx].readers += 1;
    }

    return desc;
}

/// Create a pipe: returns read and write FileDescriptions, or null on failure.
pub const PipeResult = struct {
    read_desc: *vfs.FileDescription,
    write_desc: *vfs.FileDescription,
};

pub fn createPipe() ?PipeResult {
    if (!inodes_initialized) initInodes();

    // Find free pipe slot
    var pipe_idx: ?usize = null;
    for (0..MAX_PIPES) |i| {
        if (!pipes[i].in_use) {
            pipe_idx = i;
            break;
        }
    }
    const idx = pipe_idx orelse return null;

    // Initialize pipe
    pipes[idx].read_pos = 0;
    pipes[idx].write_pos = 0;
    pipes[idx].count = 0;
    pipes[idx].readers = 1;
    pipes[idx].writers = 1;
    pipes[idx].blocked_reader_pid = 0;
    pipes[idx].blocked_writer_pid = 0;
    pipes[idx].in_use = true;

    // Allocate two FileDescriptions
    const read_desc = vfs.allocFileDescription() orelse {
        pipes[idx].in_use = false;
        return null;
    };
    read_desc.inode = &pipe_inodes[idx];
    read_desc.flags = vfs.O_RDONLY;
    read_desc.offset = 0;

    const write_desc = vfs.allocFileDescription() orelse {
        vfs.releaseFileDescription(read_desc);
        pipes[idx].in_use = false;
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

/// Check poll/epoll readiness for a pipe inode.
/// Returns bitmask of EPOLLIN/EPOLLOUT/EPOLLHUP.
pub fn checkReadiness(inode: *vfs.Inode) u32 {
    const idx = getPipeIndex(inode) orelse return 0;
    const p = &pipes[idx];
    if (!p.in_use) return 0;

    var events: u32 = 0;

    // Readable: has data, or EOF (no writers)
    if (p.count > 0 or p.writers == 0) events |= 0x001; // EPOLLIN

    // Writable: has space and has readers
    if (p.count < PIPE_BUF_SIZE and p.readers > 0) events |= 0x004; // EPOLLOUT

    // HUP: no writers left
    if (p.writers == 0) events |= 0x010; // EPOLLHUP

    return events;
}

fn writeDecimal(value: usize) void {
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
