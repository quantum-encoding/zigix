/// Per-process file descriptor table management and UART I/O backend.
///
/// fd 0 = stdin (UART RX via IRQ ring buffer, blocks if no data)
/// fd 1 = stdout (UART write)
/// fd 2 = stderr (UART write)
///
/// UART FileDescriptions are static singletons shared across all processes.

const vfs = @import("vfs.zig");
const uart = @import("uart.zig");

pub const MAX_FDS: usize = 256;

// --- UART I/O backend ---

pub const serial_ops = vfs.FileOperations{
    .read = uartRead,
    .write = uartWrite,
    .close = null, // Never close serial fds
    .readdir = null,
};

var uart_inode = vfs.Inode{
    .ino = 0, // Special: device inode
    .mode = 0o020666, // Character device, rw-rw-rw-
    .size = 0,
    .nlink = 1,
    .ops = &serial_ops,
    .fs_data = null,
};

// Static FileDescriptions for stdin/stdout/stderr — never freed
var stdin_desc = vfs.FileDescription{
    .inode = &uart_inode,
    .offset = 0,
    .flags = vfs.O_RDONLY,
    .ref_count = 255, // Sentinel: never release
    .in_use = true,
};

var stdout_desc = vfs.FileDescription{
    .inode = &uart_inode,
    .offset = 0,
    .flags = vfs.O_WRONLY,
    .ref_count = 255,
    .in_use = true,
};

var stderr_desc = vfs.FileDescription{
    .inode = &uart_inode,
    .offset = 0,
    .flags = vfs.O_WRONLY,
    .ref_count = 255,
    .in_use = true,
};

/// Initialize a process's fd table with stdin/stdout/stderr.
pub fn initStdio(table: *[MAX_FDS]?*vfs.FileDescription) void {
    for (0..MAX_FDS) |i| {
        table[i] = null;
    }
    table[0] = &stdin_desc;
    table[1] = &stdout_desc;
    table[2] = &stderr_desc;
}

/// Allocate the lowest available fd for a FileDescription.
pub fn fdAlloc(table: *[MAX_FDS]?*vfs.FileDescription, desc: *vfs.FileDescription) ?u32 {
    for (0..MAX_FDS) |i| {
        if (table[i] == null) {
            table[i] = desc;
            return @truncate(i);
        }
    }
    return null;
}

/// Look up a FileDescription by fd number.
pub fn fdGet(table: *[MAX_FDS]?*vfs.FileDescription, fd: u64) ?*vfs.FileDescription {
    if (fd >= MAX_FDS) return null;
    return table[@as(usize, @truncate(fd))];
}

/// Close an fd: release the FileDescription, clear the slot.
pub fn fdClose(table: *[MAX_FDS]?*vfs.FileDescription, fd: u64) bool {
    if (fd >= MAX_FDS) return false;
    const idx: usize = @truncate(fd);
    const desc = table[idx] orelse return false;
    table[idx] = null;
    vfs.releaseFileDescription(desc);
    return true;
}

/// Duplicate oldfd onto newfd. Closes newfd if open. Returns 0 on success, -1 on error.
pub fn fdDup2(table: *[MAX_FDS]?*vfs.FileDescription, oldfd: u64, newfd: u64) i32 {
    if (oldfd >= MAX_FDS or newfd >= MAX_FDS) return -1;
    const old_idx: usize = @truncate(oldfd);
    const new_idx: usize = @truncate(newfd);
    const src = table[old_idx] orelse return -1;

    // Close newfd if currently open
    if (table[new_idx]) |existing| {
        vfs.releaseFileDescription(existing);
    }

    table[new_idx] = src;
    _ = @atomicRmw(u32, &src.ref_count, .Add, 1, .acq_rel);
    return 0;
}

// --- UART operation implementations ---

fn uartRead(_: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    // Read from UART RX ring buffer. If no data, return -EAGAIN
    // (the caller in sysRead will block the process and restart the syscall).
    var read: usize = 0;
    while (read < count) {
        if (uart.readByte()) |byte| {
            buf[read] = byte;
            read += 1;
            // Return after each line (newline) for line-buffered behavior
            if (byte == '\n' or byte == '\r') break;
        } else {
            break;
        }
    }
    if (read == 0) {
        // No data available — signal EAGAIN so sysRead blocks
        return -@as(isize, 11); // -EAGAIN
    }
    return @intCast(read);
}

fn uartWrite(_: *vfs.FileDescription, buf: [*]const u8, count: usize) isize {
    for (0..count) |i| {
        uart.writeByte(buf[i]);
    }
    return @intCast(count);
}
