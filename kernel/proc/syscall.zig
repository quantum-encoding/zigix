/// Syscall handlers and dispatch entry point.
/// Convention: rax = syscall number, rdi/rsi/rdx/r10/r8/r9 = args.
/// Return value in rax. Negative values are -errno on error.

const serial = @import("../arch/x86_64/serial.zig");
const idt = @import("../arch/x86_64/idt.zig");
const vmm = @import("../mm/vmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const types = @import("../types.zig");
const scheduler = @import("scheduler.zig");
const errno = @import("errno.zig");
const syscall_table = @import("syscall_table.zig");
const vfs = @import("../fs/vfs.zig");
const fd_table = @import("../fs/fd_table.zig");
const fault = @import("../mm/fault.zig");

const USER_SPACE_END: u64 = 0x0000_8000_0000_0000;

/// Entry point from int 0x80 — delegates to syscall table.
pub fn dispatch(frame: *idt.InterruptFrame) void {
    syscall_table.dispatch(frame);
}

// --- Syscall handlers (pub so syscall_table can reference them) ---

/// write(fd, buf, count) — unified through fd_table.
/// The VFS write operation receives kernel-accessible pointers page-by-page.
/// If VFS returns -EAGAIN with 0 bytes written, blocks the process (syscall restart).
pub fn sysWrite(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const buf_addr = frame.rsi;
    const len = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };


    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Check write permission
    const access = desc.flags & vfs.O_ACCMODE;
    if (access != vfs.O_WRONLY and access != vfs.O_RDWR) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }

    const write_fn = desc.inode.ops.write orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (!validateUserBuffer(buf_addr, len)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const actual_len: usize = if (len > 1048576) 1048576 else @truncate(len);

    // Iterate user buffer page-by-page, passing kernel pointers to VFS write
    var written: usize = 0;
    var remaining = actual_len;
    var addr = buf_addr;

    while (remaining > 0) {
        const page_offset: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, types.PAGE_SIZE - page_offset);

        if (vmm.translate(current.page_table, addr)) |phys| {
            const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
            const n = write_fn(desc, ptr, chunk);
            if (n < 0) {
                // Check for EAGAIN with nothing written yet — block
                if (n == -@as(isize, 11) and written == 0) {
                    // Rewind RIP past `int 0x80` (2 bytes) for syscall restart
                    frame.rip -= 2;
                    current.state = .blocked_on_pipe;
                    scheduler.blockAndSchedule(frame);
                    return;
                }
                // EPIPE — deliver SIGPIPE to current process
                if (n == -@as(isize, 32) and written == 0) {
                    const signal = @import("signal.zig");
                    signal.postSignal(current, signal.SIGPIPE);
                    frame.rax = @bitCast(@as(i64, -errno.EPIPE));
                    return;
                }
                break;
            }
            if (n == 0) break;
            written += @intCast(n);
        } else {
            // Page not yet mapped — try demand paging and retry once
            if (fault.demandPageUser(addr)) {
                if (vmm.translate(current.page_table, addr)) |phys| {
                    const ptr2: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
                    const n2 = write_fn(desc, ptr2, chunk);
                    if (n2 > 0) {
                        written += @intCast(n2);
                        addr += chunk;
                        remaining -= chunk;
                        continue;
                    }
                }
            }
            break;
        }

        addr += chunk;
        remaining -= chunk;
    }

    frame.rax = written;
}

/// read(fd, buf, count) — reads through fd_table VFS operations.
/// If VFS returns -EAGAIN with 0 bytes read, blocks the process (syscall restart).
pub fn sysRead(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const buf_addr = frame.rsi;
    const len = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Check read permission (O_RDONLY == 0, O_RDWR == 2)
    const access = desc.flags & vfs.O_ACCMODE;
    if (access != vfs.O_RDONLY and access != vfs.O_RDWR) {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    }

    const read_fn = desc.inode.ops.read orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (!validateUserBuffer(buf_addr, len)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const actual_len: usize = if (len > 1048576) 1048576 else @truncate(len);

    // Iterate user buffer page-by-page, passing kernel pointers to VFS read
    var total_read: usize = 0;
    var remaining = actual_len;
    var addr = buf_addr;

    while (remaining > 0) {
        const page_offset: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, types.PAGE_SIZE - page_offset);

        if (vmm.translate(current.page_table, addr)) |phys| {
            const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
            const n = read_fn(desc, ptr, chunk);
            if (n < 0) {
                // Check for EAGAIN with nothing read yet — block
                if (n == -@as(isize, 11) and total_read == 0) {
                    // Rewind RIP past `int 0x80` (2 bytes) for syscall restart
                    frame.rip -= 2;
                    current.state = .blocked_on_pipe;
                    // If reading from serial (stdin), register for serial IRQ wakeup
                    if (desc.inode.ino == 0 and desc.inode.mode & 0o170000 == 0o020000) {
                        serial.waiting_pid = current.pid;
                    }
                    scheduler.blockAndSchedule(frame);
                    return;
                }
                break;
            }
            if (n == 0) break; // EOF
            total_read += @intCast(n);
            if (@as(usize, @intCast(n)) < chunk) break; // Short read
        } else {
            // Page not yet mapped — try demand paging and retry once
            if (fault.demandPageUser(addr)) {
                if (vmm.translate(current.page_table, addr)) |phys| {
                    const ptr2: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
                    const n2 = read_fn(desc, ptr2, chunk);
                    if (n2 > 0) {
                        total_read += @intCast(n2);
                        if (@as(usize, @intCast(n2)) < chunk) break;
                        addr += chunk;
                        remaining -= chunk;
                        continue;
                    } else if (n2 < 0) {
                        if (n2 == -@as(isize, 11) and total_read == 0) {
                            frame.rip -= 2;
                            current.state = .blocked_on_pipe;
                            scheduler.blockAndSchedule(frame);
                            return;
                        }
                    }
                }
            }
            break;
        }

        addr += chunk;
        remaining -= chunk;
    }

    frame.rax = total_read;
}

pub fn sysExit(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess();
    if (current) |proc| {
        // Unpin executable inode if pinned
        if (proc.exec_inode) |inode_ptr| {
            const ext2_mod = @import("../fs/ext2.zig");
            const inode: *vfs.Inode = @alignCast(@ptrCast(inode_ptr));
            ext2_mod.unpinInode(inode);
            proc.exec_inode = null;
        }

        // Release dedicated core if this process holds it
        scheduler.clearDedicatedIfOwner(proc.pid);

        // Cleanup zero-copy networking if this process owns it
        const zcnet = @import("../net/zcnet.zig");
        zcnet.cleanupForProcess(proc.pid);

        // Close all file descriptors — critical for pipe EOF delivery.
        // When a pipe writer exits, this decrements the writer count so
        // the reader sees EOF instead of blocking forever.
        for (0..fd_table.MAX_FDS) |i| {
            if (proc.fds[i] != null) {
                _ = fd_table.fdClose(&proc.fds, @truncate(i));
            }
        }

        proc.state = .zombie;
        proc.exit_status = frame.rdi;

        // Wake vfork parent if this process was a vfork child
        if (proc.parent_pid != 0) {
            const process_mod2 = @import("process.zig");
            for (0..process_mod2.MAX_PROCESSES) |vi| {
                if (process_mod2.getProcess(vi)) |vp| {
                    if (vp.pid == proc.parent_pid and vp.vfork_blocked) {
                        vp.vfork_blocked = false;
                        vp.state = .ready;
                        break;
                    }
                }
            }
        }

        // Reparent children to init (PID 1) — prevents permanent zombie leaks
        if (proc.tgid == proc.pid) {
            const process_mod = @import("process.zig");
            var need_wake_init = false;
            for (0..process_mod.MAX_PROCESSES) |ri| {
                if (process_mod.getProcess(ri)) |child| {
                    if (child.parent_pid == proc.pid and child.pid != proc.pid) {
                        child.parent_pid = 1;
                        if (child.state == .zombie) need_wake_init = true;
                    }
                }
            }
            if (need_wake_init) {
                scheduler.wakeProcess(1);
            }
        }

        // clear_child_tid: write 0 to *tidptr and futex_wake(1)
        if (proc.clear_child_tid != 0) {
            const futex = @import("futex.zig");
            // Write 0 to the user address via page table + HHDM
            if (vmm.translate(proc.page_table, proc.clear_child_tid)) |phys| {
                const ptr: *u32 = @ptrFromInt(hhdm.physToVirt(phys));
                ptr.* = 0;
            }
            _ = futex.wakeAddress(proc.page_table, proc.clear_child_tid, 1);
            proc.clear_child_tid = 0;
        }

        // Wake parent if it's blocked on wait — but only for group leaders (tgid == pid)
        // Threads (tgid != pid) communicate exit via futex, not wait4
        if (proc.parent_pid != 0 and proc.tgid == proc.pid) {
            const process_mod = @import("process.zig");
            const sig = @import("signal.zig");
            for (0..process_mod.MAX_PROCESSES) |i| {
                if (process_mod.getProcess(i)) |p| {
                    if (p.pid == proc.parent_pid) {
                        sig.postSignal(p, sig.SIGCHLD);
                        if (p.state == .blocked_on_wait) {
                            scheduler.wakeProcess(proc.parent_pid);
                        }
                        break;
                    }
                }
            }
        }
    } else {
        serial.writeString("[syscall] exit (no current process)\n");
    }

    // Schedule next ready process. If none exist, schedule() halts.
    scheduler.schedule(frame);
}

pub fn sysGetpid(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess();
    frame.rax = if (current) |proc| proc.tgid else 0; // Returns thread group leader's PID
}

// --- User memory helpers (pub for use by other syscall files) ---

/// Validate that a user buffer [buf, buf+len) is entirely within user space.
pub fn validateUserBuffer(buf: u64, len: u64) bool {
    if (buf >= USER_SPACE_END) return false;
    const end = @addWithOverflow(buf, len);
    if (end[1] != 0) return false;
    if (end[0] > USER_SPACE_END) return false;
    return true;
}

/// Copy kernel data to user-space buffer via page table translation + HHDM.
pub fn copyToUser(page_table: u64, user_addr: u64, data: []const u8) bool {
    var remaining = data.len;
    var addr = user_addr;
    var offset: usize = 0;

    while (remaining > 0) {
        const page_off: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, types.PAGE_SIZE - page_off);

        const phys = vmm.translate(page_table, addr) orelse blk: {
            if (fault.demandPageUser(addr)) {
                break :blk vmm.translate(page_table, addr) orelse return false;
            }
            return false;
        };
        const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
        for (0..chunk) |i| {
            ptr[i] = data[offset + i];
        }

        addr += chunk;
        offset += chunk;
        remaining -= chunk;
    }
    return true;
}

/// Copy user-space data to kernel buffer via page table translation + HHDM.
/// For null-terminated strings, set max_len to buffer size (stops at NUL or max_len).
pub fn copyFromUser(page_table: u64, user_addr: u64, kernel_buf: []u8, max_len: usize) usize {
    var copied: usize = 0;
    var addr = user_addr;
    const limit = @min(max_len, kernel_buf.len);

    while (copied < limit) {
        const page_off: usize = @truncate(addr & 0xFFF);
        const chunk = @min(limit - copied, types.PAGE_SIZE - page_off);

        const phys = vmm.translate(page_table, addr) orelse blk: {
            // Try demand paging, then retry
            if (fault.demandPageUser(addr)) {
                break :blk vmm.translate(page_table, addr) orelse break;
            }
            break;
        };
        const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
        for (0..chunk) |i| {
            const byte = ptr[i];
            kernel_buf[copied + i] = byte;
            if (byte == 0) return copied + i; // NUL terminator
        }

        addr += chunk;
        copied += chunk;
    }
    return copied;
}

/// Copy raw bytes from user-space to kernel buffer (does NOT stop at NUL).
/// Used for reading binary structures like iovec from user memory.
pub fn copyFromUserRaw(page_table: u64, user_addr: u64, kernel_buf: []u8, max_len: usize) usize {
    var copied: usize = 0;
    var addr = user_addr;
    const limit = @min(max_len, kernel_buf.len);

    while (copied < limit) {
        const page_off: usize = @truncate(addr & 0xFFF);
        const chunk = @min(limit - copied, types.PAGE_SIZE - page_off);

        const phys = vmm.translate(page_table, addr) orelse blk: {
            if (fault.demandPageUser(addr)) {
                break :blk vmm.translate(page_table, addr) orelse break;
            }
            break;
        };
        const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
        for (0..chunk) |i| {
            kernel_buf[copied + i] = ptr[i];
        }

        addr += chunk;
        copied += chunk;
    }
    return copied;
}

// --- Output helpers ---

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
