/// RISC-V syscall handler — Linux generic ABI (same as ARM64).
///
/// Syscall number in a7 (x17), arguments in a0-a5 (x10-x15).
/// Return value in a0 (x10).

const uart = @import("uart.zig");
const trap = @import("trap.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const vfs = @import("vfs.zig");
const fd_table = @import("fd_table.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const smp = @import("smp.zig");

// Linux RISC-V (generic) syscall numbers
const SYS_getcwd: u64 = 17;
const SYS_dup: u64 = 23;
const SYS_dup3: u64 = 24;
const SYS_ioctl: u64 = 29;
const SYS_mkdirat: u64 = 34;
const SYS_unlinkat: u64 = 35;
const SYS_openat: u64 = 56;
const SYS_close: u64 = 57;
const SYS_read: u64 = 63;
const SYS_write: u64 = 64;
const SYS_writev: u64 = 66;
const SYS_readlinkat: u64 = 78;
const SYS_fstat: u64 = 80;
const SYS_exit: u64 = 93;
const SYS_exit_group: u64 = 94;
const SYS_set_tid_address: u64 = 96;
const SYS_clock_gettime: u64 = 113;
const SYS_sched_yield: u64 = 124;
const SYS_kill: u64 = 129;
const SYS_rt_sigaction: u64 = 134;
const SYS_rt_sigprocmask: u64 = 135;
const SYS_uname: u64 = 160;
const SYS_getpid: u64 = 172;
const SYS_getppid: u64 = 173;
const SYS_getuid: u64 = 174;
const SYS_geteuid: u64 = 175;
const SYS_getgid: u64 = 176;
const SYS_getegid: u64 = 177;
const SYS_brk: u64 = 214;
const SYS_mmap: u64 = 222;
const SYS_mprotect: u64 = 226;
const SYS_munmap: u64 = 215;
const SYS_clone: u64 = 220;
const SYS_execve: u64 = 221;
const SYS_wait4: u64 = 260;
const SYS_pipe2: u64 = 59;
const SYS_getdents64: u64 = 61;
const SYS_chdir: u64 = 49;
const SYS_setpgid: u64 = 154;
const SYS_getpgid: u64 = 155;
const SYS_getrandom: u64 = 278;

pub fn handleSyscall(frame: *trap.TrapFrame) void {
    const nr = frame.x[17]; // a7 = syscall number
    const a0 = frame.x[10];
    const a1 = frame.x[11];
    const a2 = frame.x[12];
    const a3 = frame.x[13];
    _ = a3;

    const result: u64 = switch (nr) {
        SYS_write => sysWrite(a0, a1, a2),
        SYS_read => sysRead(a0, a1, a2),
        SYS_openat => sysOpenat(a1, a2),
        SYS_close => sysClose(a0),
        SYS_exit, SYS_exit_group => sysExit(frame, a0),
        SYS_clone => sysClone(frame),
        SYS_execve => sysExecve(frame, a0, a1, a2),
        SYS_wait4 => sysWait4(frame, a0, a1, a2),
        SYS_getpid => blk: {
            if (scheduler.currentProcess()) |p| break :blk p.tgid;
            break :blk 1;
        },
        SYS_getppid => blk: {
            if (scheduler.currentProcess()) |p| break :blk p.parent_pid;
            break :blk 0;
        },
        SYS_getuid, SYS_geteuid, SYS_getgid, SYS_getegid => 0,
        SYS_brk => sysBrk(a0),
        SYS_uname => sysUname(a0),
        SYS_set_tid_address => blk: {
            if (scheduler.currentProcess()) |p| break :blk p.pid;
            break :blk 1;
        },
        SYS_ioctl => @bitCast(@as(i64, -25)), // -ENOTTY
        SYS_dup => sysDup(a0),
        SYS_dup3 => sysDup3(a0, a1),
        SYS_pipe2 => sysPipe2(a0),
        SYS_fstat => sysFstat(a0, a1),
        SYS_getcwd => sysGetcwd(a0, a1),
        SYS_chdir => sysChdir(a0),
        SYS_setpgid => 0, // Stub success
        SYS_getpgid => blk: {
            if (scheduler.currentProcess()) |p| break :blk p.pid;
            break :blk 0;
        },
        SYS_rt_sigaction => 0, // Stub success
        SYS_rt_sigprocmask => 0, // Stub success
        SYS_kill => 0, // Stub success
        SYS_mmap => sysMmap(a0, a1, a2),
        SYS_mprotect => 0, // Stub success
        SYS_munmap => 0, // Stub success
        SYS_sched_yield => 0,
        SYS_clock_gettime => 0, // Stub
        SYS_getrandom => sysGetrandom(a0, a1),
        SYS_writev => sysWritev(a0, a1, a2),
        SYS_getdents64 => sysGetdents64(a0, a1, a2),
        else => blk: {
            if (nr < 300) {
                uart.print("[syscall] Unimpl nr={} a0={x}\n", .{ nr, a0 });
            }
            break :blk @bitCast(@as(i64, -38)); // -ENOSYS
        },
    };

    frame.x[10] = result;
}

fn sysWrite(fd: u64, buf_addr: u64, count: u64) u64 {
    if (fd == 1 or fd == 2) {
        // stdout/stderr → UART
        const buf: [*]const u8 = @ptrFromInt(buf_addr);
        var written: u64 = 0;
        while (written < count) : (written += 1) {
            uart.writeByte(buf[written]);
        }
        return written;
    }
    // File write via VFS
    const proc = scheduler.currentProcess() orelse return @bitCast(@as(i64, -9));
    if (fd >= fd_table.MAX_FDS) return @bitCast(@as(i64, -9));
    const desc = proc.fds[@intCast(fd)] orelse return @bitCast(@as(i64, -9));
    const read_fn = desc.inode.ops.write orelse return @bitCast(@as(i64, -9));
    const buf: [*]const u8 = @ptrFromInt(buf_addr);
    return @intCast(read_fn(desc, buf, @intCast(count)));
}

fn sysRead(fd: u64, buf_addr: u64, count: u64) u64 {
    if (fd == 0) {
        // stdin — read from UART (non-blocking for now)
        if (uart.readByte()) |byte| {
            const buf: [*]u8 = @ptrFromInt(buf_addr);
            buf[0] = byte;
            return 1;
        }
        return 0;
    }
    const proc = scheduler.currentProcess() orelse return @bitCast(@as(i64, -9));
    if (fd >= fd_table.MAX_FDS) return @bitCast(@as(i64, -9));
    const desc = proc.fds[@intCast(fd)] orelse return @bitCast(@as(i64, -9));
    const read_fn = desc.inode.ops.read orelse return @bitCast(@as(i64, -9));
    const buf: [*]u8 = @ptrFromInt(buf_addr);
    const result = read_fn(desc, buf, @intCast(count));
    if (result < 0) return @bitCast(@as(i64, result));
    return @intCast(result);
}

fn sysOpenat(path_addr: u64, flags: u64) u64 {
    _ = flags;
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    // Find null terminator
    var len: usize = 0;
    while (len < 256 and path_ptr[len] != 0) len += 1;
    const path = path_ptr[0..len];

    const inode = vfs.resolve(path) orelse return @bitCast(@as(i64, -2)); // -ENOENT
    const desc = vfs.allocFileDescription() orelse return @bitCast(@as(i64, -24)); // -EMFILE
    desc.inode = inode;
    desc.offset = 0;
    desc.flags = 0;

    const proc = scheduler.currentProcess() orelse return @bitCast(@as(i64, -9));
    // Find free fd
    for (3..fd_table.MAX_FDS) |i| {
        if (proc.fds[i] == null) {
            proc.fds[i] = desc;
            return i;
        }
    }
    return @bitCast(@as(i64, -24)); // -EMFILE
}

fn sysClose(fd: u64) u64 {
    if (fd <= 2) return 0; // Don't close stdio
    const proc = scheduler.currentProcess() orelse return @bitCast(@as(i64, -9));
    if (fd >= fd_table.MAX_FDS) return @bitCast(@as(i64, -9));
    if (proc.fds[@intCast(fd)]) |desc| {
        vfs.releaseFileDescription(desc);
        proc.fds[@intCast(fd)] = null;
        return 0;
    }
    return @bitCast(@as(i64, -9));
}

fn sysExit(frame: *trap.TrapFrame, status: u64) u64 {
    if (scheduler.currentProcess()) |proc| {
        uart.print("[exit] PID {} exited with status {}\n", .{ proc.pid, status });
        proc.state = .zombie;
        proc.exit_status = status;

        // Close file descriptors
        for (3..fd_table.MAX_FDS) |i| {
            if (proc.fds[i]) |desc| {
                vfs.releaseFileDescription(desc);
                proc.fds[i] = null;
            }
        }

        // Wake parent if blocked on wait4
        for (0..process.MAX_PROCESSES) |i| {
            if (!process.slot_in_use[i]) continue;
            const p = process.getProcess(i) orelse continue;
            if (p.pid == proc.parent_pid and p.state == .blocked_on_wait) {
                p.state = .ready;
                scheduler.makeRunnable(p);
                break;
            }
        }

        scheduler.schedule(frame);
    }
    while (true) asm volatile ("wfi");
}

fn sysBrk(addr: u64) u64 {
    const proc = scheduler.currentProcess() orelse return 0;
    if (addr == 0) return proc.heap_current;
    if (addr >= proc.heap_start and addr < 0x40_0000_0000) {
        // Allocate pages for the new break
        const old_page = (proc.heap_current + 4095) / 4096;
        const new_page = (addr + 4095) / 4096;
        var p = old_page;
        while (p < new_page) : (p += 1) {
            const phys = pmm.allocPage() orelse return proc.heap_current;
            const virt = p * 4096;
            vmm.mapPage(proc.page_table, virt, phys, .{
                .user = true,
                .writable = true,
            }) catch return proc.heap_current;
        }
        proc.heap_current = addr;
        return addr;
    }
    return proc.heap_current;
}

fn sysUname(buf_addr: u64) u64 {
    const buf: [*]u8 = @ptrFromInt(buf_addr);
    // struct utsname: 5 fields × 65 bytes each
    const sysname = "Zigix";
    const nodename = "riscv64";
    const release = "0.1.0";
    const version = "RISC-V QEMU virt";
    const machine = "riscv64";

    inline for (.{ sysname, nodename, release, version, machine }, 0..) |str, i| {
        const off = i * 65;
        for (str, 0..) |c, j| buf[off + j] = c;
        buf[off + str.len] = 0;
    }
    return 0;
}

fn sysDup(oldfd: u64) u64 {
    const proc = scheduler.currentProcess() orelse return @bitCast(@as(i64, -9));
    if (oldfd >= fd_table.MAX_FDS) return @bitCast(@as(i64, -9));
    const desc = proc.fds[@intCast(oldfd)] orelse return @bitCast(@as(i64, -9));
    for (0..fd_table.MAX_FDS) |i| {
        if (proc.fds[i] == null) {
            proc.fds[i] = desc;
            desc.ref_count += 1;
            return i;
        }
    }
    return @bitCast(@as(i64, -24));
}

fn sysDup3(oldfd: u64, newfd: u64) u64 {
    const proc = scheduler.currentProcess() orelse return @bitCast(@as(i64, -9));
    if (oldfd >= fd_table.MAX_FDS or newfd >= fd_table.MAX_FDS) return @bitCast(@as(i64, -9));
    const desc = proc.fds[@intCast(oldfd)] orelse return @bitCast(@as(i64, -9));
    if (proc.fds[@intCast(newfd)]) |old| {
        vfs.releaseFileDescription(old);
    }
    proc.fds[@intCast(newfd)] = desc;
    desc.ref_count += 1;
    return newfd;
}

fn sysFstat(fd: u64, buf_addr: u64) u64 {
    _ = fd;
    // Zero the stat buffer (128 bytes on riscv64)
    const buf: [*]u8 = @ptrFromInt(buf_addr);
    for (0..128) |i| buf[i] = 0;
    return 0;
}

fn sysGetcwd(buf_addr: u64, size: u64) u64 {
    if (size < 2) return @bitCast(@as(i64, -34)); // -ERANGE
    const buf: [*]u8 = @ptrFromInt(buf_addr);
    buf[0] = '/';
    buf[1] = 0;
    return buf_addr;
}

fn sysMmap(addr: u64, length: u64, prot: u64) u64 {
    _ = addr;
    _ = prot;
    const proc = scheduler.currentProcess() orelse return @bitCast(@as(i64, -12));
    // Simple anonymous mmap: allocate from mmap_hint downward
    const pages = (length + 4095) / 4096;
    const virt_base = proc.mmap_hint - pages * 4096;
    proc.mmap_hint = virt_base;

    var i: u64 = 0;
    while (i < pages) : (i += 1) {
        const phys = pmm.allocPage() orelse return @bitCast(@as(i64, -12));
        // Zero the page
        const ptr: [*]u8 = @ptrFromInt(phys);
        for (0..4096) |j| ptr[j] = 0;
        vmm.mapPage(proc.page_table, virt_base + i * 4096, phys, .{
            .user = true,
            .writable = true,
        }) catch return @bitCast(@as(i64, -12));
    }
    return virt_base;
}

fn sysGetrandom(buf_addr: u64, count: u64) u64 {
    // Fill with pseudo-random from timer
    const buf: [*]u8 = @ptrFromInt(buf_addr);
    var seed = @import("timer.zig").readCounter();
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        buf[i] = @truncate(seed >> 33);
    }
    return count;
}

fn sysWritev(fd: u64, iov_addr: u64, iovcnt: u64) u64 {
    var total: u64 = 0;
    var i: u64 = 0;
    while (i < iovcnt) : (i += 1) {
        const iov_ptr: [*]const u64 = @ptrFromInt(iov_addr + i * 16);
        const base = iov_ptr[0];
        const len = iov_ptr[1];
        if (len > 0) {
            total += sysWrite(fd, base, len);
        }
    }
    return total;
}

// ============================================================================
// Fork (clone syscall, nr=220)
// ============================================================================

const vma = @import("vma.zig");
const elf = @import("elf.zig");

fn sysClone(_: *trap.TrapFrame) u64 {
    const parent = scheduler.currentProcess() orelse return @bitCast(@as(i64, -1));

    // Find a free process slot
    const idx = process.findFreeSlot() orelse {
        uart.writeString("[fork] No free process slot\n");
        return @bitCast(@as(i64, -11)); // -EAGAIN
    };

    // Create child address space with CoW pages
    const child_pt = vmm.createAddressSpace() catch {
        return @bitCast(@as(i64, -12)); // -ENOMEM
    };
    vmm.cowCopyUserPages(parent.page_table, child_pt);

    // Allocate child kernel stack
    const kstack_phys = pmm.allocPagesGuarded(process.KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        vmm.destroyAddressSpace(child_pt);
        return @bitCast(@as(i64, -12));
    };
    const kstack_top = kstack_phys + process.KERNEL_STACK_PAGES * 4096;

    // Write stack canary
    const canary_ptr: *u64 = @ptrFromInt(kstack_phys);
    canary_ptr.* = pmm.STACK_CANARY;

    // Initialize child process
    const child = process.initSlot(idx);
    child.pid = process.allocPid();
    child.tgid = child.pid;
    child.parent_pid = parent.pid;
    child.page_table = child_pt;
    child.kernel_stack_phys = kstack_phys;
    child.kernel_stack_top = kstack_top;
    child.kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES);
    child.heap_start = parent.heap_start;
    child.heap_current = parent.heap_current;
    child.mmap_hint = parent.mmap_hint;

    // Copy context from parent (all registers + sepc + sstatus)
    child.context = parent.context;
    child.context.x[10] = 0; // Child returns 0 from fork

    // Copy file descriptors (increment ref counts)
    for (0..fd_table.MAX_FDS) |i| {
        if (parent.fds[i]) |desc| {
            child.fds[i] = desc;
            desc.ref_count += 1;
        }
    }

    // Copy VMAs
    vma.copyVmas(&child.vmas, &parent.vmas);

    child.state = .ready;
    process.registerPid(child.pid, idx);
    scheduler.makeRunnable(child);

    uart.print("[fork] PID {} → child PID {}\n", .{ parent.pid, child.pid });
    return child.pid; // Parent returns child PID
}

// ============================================================================
// Execve (syscall nr=221)
// ============================================================================

// Global buffers for execve (avoid kernel stack overflow)
var g_exec_path: [256]u8 = undefined;
var g_exec_path_len: usize = 0;
var g_elf_buf: [4096]u8 = undefined; // First page of ELF for header parsing

fn sysExecve(frame: *trap.TrapFrame, path_addr: u64, argv_addr: u64, envp_addr: u64) u64 {
    _ = argv_addr;
    _ = envp_addr;

    const proc = scheduler.currentProcess() orelse return @bitCast(@as(i64, -1));

    // Copy path from user space
    const path_ptr: [*]const u8 = @ptrFromInt(path_addr);
    g_exec_path_len = 0;
    while (g_exec_path_len < 255 and path_ptr[g_exec_path_len] != 0) {
        g_exec_path[g_exec_path_len] = path_ptr[g_exec_path_len];
        g_exec_path_len += 1;
    }
    const path = g_exec_path[0..g_exec_path_len];

    // Resolve the executable
    const inode = vfs.resolve(path) orelse {
        return @bitCast(@as(i64, -2)); // -ENOENT
    };

    // Read the full file into PMM buffer
    const BUF_PAGES = 16; // 64 KiB
    const buf_phys = pmm.allocPages(BUF_PAGES) orelse return @bitCast(@as(i64, -12));
    const buf_ptr: [*]u8 = @ptrFromInt(buf_phys);
    const buf = buf_ptr[0 .. BUF_PAGES * 4096];

    const bytes_read = vfs.readWholeFile(path, buf) orelse {
        pmm.freePages(buf_phys, BUF_PAGES);
        return @bitCast(@as(i64, -5)); // -EIO
    };
    _ = inode;

    if (bytes_read < 64) {
        pmm.freePages(buf_phys, BUF_PAGES);
        return @bitCast(@as(i64, -8)); // -ENOEXEC
    }

    uart.writeString("[exec] ");
    uart.writeString(path);
    uart.print(" ({} bytes)\n", .{bytes_read});

    // === POINT OF NO RETURN ===
    // Destroy old address space
    vmm.destroyUserPagesCoW(proc.page_table);
    vma.initVmaList(&proc.vmas);

    // Load ELF into the address space
    const elf_info = elf.loadElf(proc.page_table, buf_ptr[0..bytes_read]) catch {
        uart.writeString("[exec] ELF load failed\n");
        pmm.freePages(buf_phys, BUF_PAGES);
        proc.state = .zombie;
        proc.exit_status = 127;
        scheduler.schedule(frame);
        return 0;
    };

    pmm.freePages(buf_phys, BUF_PAGES);

    // Allocate and map new user stack
    var s: u64 = 0;
    while (s < process.USER_STACK_PAGES) : (s += 1) {
        const stack_page = pmm.allocPage() orelse {
            proc.state = .zombie;
            proc.exit_status = 127;
            scheduler.schedule(frame);
            return 0;
        };
        zeroPage(stack_page);
        const vaddr = process.USER_STACK_TOP - (process.USER_STACK_PAGES - s) * 4096;
        vmm.mapPage(proc.page_table, vaddr, stack_page, .{
            .user = true,
            .writable = true,
        }) catch {};
    }

    // Write argc=0, argv=NULL on stack (simplified — full argv support later)
    const stack_setup_base = process.USER_STACK_TOP - 32;
    if (vmm.translate(proc.page_table, stack_setup_base)) |phys| {
        const stack_ptr: [*]volatile u64 = @ptrFromInt(phys);
        stack_ptr[0] = 0; // argc
        stack_ptr[1] = 0; // argv[0] = NULL
        stack_ptr[2] = 0; // envp[0] = NULL
        stack_ptr[3] = 0; // auxv terminator
    }

    // Update process state
    proc.heap_start = elf_info.highest_addr;
    proc.heap_current = elf_info.highest_addr;

    // Add VMAs
    _ = vma.addVma(&proc.vmas, process.USER_CODE_BASE, elf_info.highest_addr, .{
        .readable = true, .writable = true, .executable = true, .user = true,
    });
    const stack_vma_start = process.USER_STACK_TOP - process.USER_STACK_VMA_PAGES * 4096;
    _ = vma.addVma(&proc.vmas, stack_vma_start, process.USER_STACK_TOP, .{
        .readable = true, .writable = true, .user = true, .stack = true,
    });

    // Set context to new entry point (execve never returns to caller)
    frame.sepc = elf_info.entry;
    frame.x[2] = stack_setup_base; // sp
    // Clear all GP registers (except sp)
    for (0..32) |i| {
        if (i != 2) frame.x[i] = 0;
    }
    frame.sstatus = (frame.sstatus & ~@as(u64, 1 << 8)) | (1 << 5) | (1 << 18); // SPP=0, SPIE=1, SUM=1

    // Flush TLB for new address space
    vmm.switchAddressSpace(proc.page_table);

    return 0; // Won't actually be returned — sret goes to new entry
}

// ============================================================================
// Wait4 (syscall nr=260)
// ============================================================================

fn sysWait4(frame: *trap.TrapFrame, target_pid: u64, wstatus_addr: u64, options: u64) u64 {
    const parent = scheduler.currentProcess() orelse return @bitCast(@as(i64, -1));
    const WNOHANG: u64 = 1;

    // Scan process table for children
    var found_zombie: ?usize = null;
    var has_children: bool = false;

    for (0..process.MAX_PROCESSES) |i| {
        if (!process.slot_in_use[i]) continue;
        const p = process.getProcess(i) orelse continue;
        if (p.parent_pid != parent.pid) continue;

        // Filter by target_pid: -1 = any child, >0 = specific pid
        if (target_pid != @as(u64, @bitCast(@as(i64, -1))) and target_pid != 0 and p.pid != target_pid) continue;

        has_children = true;
        if (p.state == .zombie) {
            found_zombie = i;
            break;
        }
    }

    if (found_zombie) |idx| {
        const child = process.getProcess(idx).?;
        const child_pid = child.pid;
        const exit_code = child.exit_status;

        // Write wstatus if pointer is non-null
        if (wstatus_addr != 0) {
            const wstatus_ptr: *u32 = @ptrFromInt(wstatus_addr);
            wstatus_ptr.* = @truncate((exit_code & 0xFF) << 8); // WIFEXITED format
        }

        // Reap: free kernel stack and process slot
        if (child.kernel_stack_phys != 0) {
            pmm.freePages(child.kernel_stack_phys, process.KERNEL_STACK_PAGES);
        }
        // Free user pages if this is a group leader (not a thread)
        if (child.tgid == child.pid and child.page_table != 0) {
            vmm.destroyUserPagesCoW(child.page_table);
            // Free the root page table itself
            pmm.freePage(child.page_table);
        }
        process.clearSlot(idx);
        return child_pid;
    }

    if (!has_children) {
        return @bitCast(@as(i64, -10)); // -ECHILD
    }

    if (options & WNOHANG != 0) {
        return 0; // No zombie yet, don't block
    }

    // Block until a child exits
    parent.state = .blocked_on_wait;
    // Rewind sepc so syscall re-executes when woken
    frame.sepc -= 4; // ecall is 4 bytes
    scheduler.blockAndSchedule(frame);
    return 0; // Will re-execute wait4 when woken
}

// ============================================================================
// Helper syscalls for shell (pipe2, chdir, getdents64)
// ============================================================================

fn sysPipe2(pipefd_addr: u64) u64 {
    _ = pipefd_addr;
    return @bitCast(@as(i64, -38)); // -ENOSYS (TODO)
}

fn sysChdir(path_addr: u64) u64 {
    _ = path_addr;
    return 0; // Stub success (single-directory for now)
}

fn sysGetdents64(fd: u64, buf_addr: u64, count: u64) u64 {
    const proc = scheduler.currentProcess() orelse return @bitCast(@as(i64, -9));
    if (fd >= fd_table.MAX_FDS) return @bitCast(@as(i64, -9));
    const desc = proc.fds[@intCast(fd)] orelse return @bitCast(@as(i64, -9));
    const inode = desc.inode;

    // Must be a directory
    if (inode.mode & 0o170000 != 0o040000) return @bitCast(@as(i64, -20)); // -ENOTDIR

    const readdir_fn = inode.ops.readdir orelse return @bitCast(@as(i64, -22)); // -EINVAL

    const buf: [*]u8 = @ptrFromInt(buf_addr);
    var pos: usize = 0;
    var entry: vfs.DirEntry = undefined;

    while (readdir_fn(desc, &entry)) {
        // struct linux_dirent64: d_ino(8) + d_off(8) + d_reclen(2) + d_type(1) + d_name[...]
        const name_len = entry.name_len;
        const reclen: u16 = @intCast(((19 + name_len + 1) + 7) & ~@as(usize, 7)); // 8-byte aligned
        if (pos + reclen > count) break;

        const ino_ptr: *align(1) u64 = @ptrCast(buf + pos);
        ino_ptr.* = entry.ino;
        const off_ptr: *align(1) u64 = @ptrCast(buf + pos + 8);
        off_ptr.* = pos + reclen;
        const reclen_ptr: *align(1) u16 = @ptrCast(buf + pos + 16);
        reclen_ptr.* = reclen;
        buf[pos + 18] = entry.d_type;
        for (0..name_len) |j| {
            buf[pos + 19 + j] = entry.name[j];
        }
        buf[pos + 19 + name_len] = 0;
        pos += reclen;
    }

    return pos;
}

fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..4096) |i| ptr[i] = 0;
}
