/// RISC-V 64-bit Process management -- process struct, context, creation.
///
/// Context matches TrapFrame layout from trap.zig: 32 GP registers + sepc + sstatus.
/// Process creation sets up context for sret to U-mode:
///   sstatus.SPP = 0 (return to U-mode)
///   sstatus.SPIE = 1 (enable interrupts after sret)
///   sepc = entry point

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const spinlock = @import("spinlock.zig");
const vmm = @import("vmm.zig");
const vfs = @import("vfs.zig");
const fd_table = @import("fd_table.zig");
const elf = @import("elf.zig");
const vma = @import("vma.zig");
const signal = @import("signal.zig");

pub const MAX_SIGNALS: usize = signal.MAX_SIGNALS;

pub const KERNEL_STACK_PAGES: u64 = 32; // 128 KiB kernel stack
pub const USER_STACK_PAGES: u64 = 8;    // 32 KiB user stack (initial mapped pages)
pub const USER_STACK_VMA_PAGES: u64 = 12288; // 48 MiB stack VMA -- demand-paged

/// User virtual address layout (Sv39: 39-bit VA, user range 0 - 0x3FFFFFFFFF)
/// Code at VPN[2]=1 (1-2 GiB), stack near top of VPN[2]=1 (below 2 GiB).
/// Both in same L2 region to share intermediate page tables.
pub const USER_CODE_BASE: u64 = 0x40000000; // 1 GiB
pub const USER_STACK_TOP: u64 = 0x7FFFE000; // ~2 GiB - 8 KiB, same VPN[2]=1

pub const ProcessState = enum {
    ready,
    running,
    blocked,
    blocked_on_pipe,
    blocked_on_wait,
    blocked_on_futex,
    blocked_on_net,
    stopped,
    zombie,
};

/// Saved CPU context -- matches TrapFrame layout from trap.zig (272 bytes).
/// x[0..31] are the 32 GP registers (x0 is always 0 but reserved for indexing),
/// followed by sepc and sstatus.
pub const Context = extern struct {
    x: [32]u64 = [_]u64{0} ** 32, // x0-x31
    sepc: u64 = 0,                 // Saved program counter
    sstatus: u64 = 0,              // Saved status register

    /// Set syscall return value (a0 = x10)
    pub fn setReturn(self: *Context, value: u64) void {
        self.x[10] = value;
    }

    /// Get syscall number (a7 = x17 in Linux RISC-V ABI)
    pub fn syscallNum(self: *const Context) u64 {
        return self.x[17];
    }

    /// Get syscall arguments (a0-a5 = x10-x15)
    pub fn arg0(self: *const Context) u64 { return self.x[10]; }
    pub fn arg1(self: *const Context) u64 { return self.x[11]; }
    pub fn arg2(self: *const Context) u64 { return self.x[12]; }
    pub fn arg3(self: *const Context) u64 { return self.x[13]; }
    pub fn arg4(self: *const Context) u64 { return self.x[14]; }
    pub fn arg5(self: *const Context) u64 { return self.x[15]; }
};

/// sstatus bits for U-mode return via sret
const SSTATUS_SPP: u64 = 1 << 8;  // Supervisor Previous Privilege (0 = U-mode)
const SSTATUS_SPIE: u64 = 1 << 5; // Supervisor Previous Interrupt Enable
const SSTATUS_SUM: u64 = 1 << 18; // Supervisor User Memory access

pub const Process = struct {
    pid: u64 = 0,
    tgid: u64 = 0,
    state: ProcessState = .ready,
    page_table: u64 = 0,          // Physical address of Sv39 root page table
    kernel_stack_phys: u64 = 0,
    kernel_stack_top: u64 = 0,
    kernel_stack_guard: u16 = 0,
    context: Context = .{},
    heap_start: u64 = 0,
    heap_current: u64 = 0,
    parent_pid: u64 = 0,
    exit_status: u64 = 0,
    mmap_hint: u64 = 0x3FFFF0000000, // Top-down mmap allocator (Sv39 user range)
    euid: u16 = 0,
    egid: u16 = 0,
    umask_val: u32 = 0o022,
    pgid: u32 = 0,
    clear_child_tid: u64 = 0,
    wake_tick: u64 = 0,
    cpu_id: i32 = -1,
    vma_lock: spinlock.IrqSpinlock = .{},
    fds: [fd_table.MAX_FDS]?*vfs.FileDescription = [_]?*vfs.FileDescription{null} ** fd_table.MAX_FDS,
    fd_cloexec: [fd_table.MAX_FDS]bool = [_]bool{false} ** fd_table.MAX_FDS,
    cwd: [256]u8 = [_]u8{'/'} ++ [_]u8{0} ** 255,
    cwd_len: u8 = 1,
    vmas: vma.VmaList = [_]vma.Vma{.{}} ** vma.MAX_VMAS,
    sig_pending: u64 = 0,
    sig_mask: u64 = 0,
    sig_actions: [MAX_SIGNALS]signal.SignalAction = [_]signal.SignalAction{.{}} ** MAX_SIGNALS,
    exe_path: [256]u8 = [_]u8{0} ** 256,
    exe_path_len: u8 = 0,
    killed: bool = false,
    rq_next: ?*Process = null,
    home_cpu: u32 = 0,
};

/// Default mmap base (top of mmap region in Sv39 user space)
const MMAP_BASE: u64 = 0x3FFFF0000000;

pub const MAX_PROCESSES = 256;

/// Process table -- validity tracked by slot_in_use[].
var processes: [MAX_PROCESSES]Process = [_]Process{.{}} ** MAX_PROCESSES;
pub var slot_in_use: [MAX_PROCESSES]bool = [_]bool{false} ** MAX_PROCESSES;
var next_pid: u64 = 1;

/// SMP lock -- protects process table, slot_in_use, and next_pid.
pub var proc_lock: spinlock.IrqSpinlock = .{};

// --- Free list for O(1) slot allocation ---
var free_next: [MAX_PROCESSES]?usize = [_]?usize{null} ** MAX_PROCESSES;
var free_head: ?usize = null;
var free_list_initialized: bool = false;

// --- PID hash table for O(1) lookup ---
const PID_HASH_SIZE: usize = 128;
var pid_to_idx: [PID_HASH_SIZE]?usize = [_]?usize{null} ** PID_HASH_SIZE;

fn pidHash(pid: u64) usize {
    return @truncate(pid % PID_HASH_SIZE);
}

/// Initialize the free list. Call once at boot.
pub fn initProcessTable() void {
    var i: usize = MAX_PROCESSES;
    while (i > 0) {
        i -= 1;
        if (!slot_in_use[i]) {
            free_next[i] = free_head;
            free_head = i;
        }
    }
    free_list_initialized = true;
}

/// Register a PID->slot mapping.
pub fn registerPid(pid: u64, idx: usize) void {
    pid_to_idx[pidHash(pid)] = idx;
}

/// Unregister a PID from the hash table.
pub fn unregisterPid(pid: u64) void {
    pid_to_idx[pidHash(pid)] = null;
}

pub fn getProcess(idx: usize) ?*Process {
    if (idx >= MAX_PROCESSES) return null;
    if (!slot_in_use[idx]) return null;
    return &processes[idx];
}

pub fn clearSlot(idx: usize) void {
    if (idx < MAX_PROCESSES) {
        if (slot_in_use[idx]) {
            unregisterPid(processes[idx].pid);
        }
        slot_in_use[idx] = false;
        free_next[idx] = free_head;
        free_head = idx;
    }
}

pub fn findFreeSlot() ?usize {
    proc_lock.acquire();
    defer proc_lock.release();
    return findFreeSlotUnlocked();
}

fn findFreeSlotUnlocked() ?usize {
    if (!free_list_initialized) initProcessTable();

    if (free_head) |idx| {
        free_head = free_next[idx];
        free_next[idx] = null;
        return idx;
    }
    return null;
}

pub fn allocPid() u64 {
    proc_lock.acquire();
    defer proc_lock.release();
    return allocPidUnlocked();
}

fn allocPidUnlocked() u64 {
    const pid = next_pid;
    next_pid += 1;
    return pid;
}

/// Zero-initialize a process slot in-place using @memset.
fn zeroSlot(idx: usize) void {
    const raw: [*]u8 = @ptrCast(&processes[idx]);
    @memset(raw[0..@sizeOf(Process)], 0);
}

/// Initialize a fresh process slot (for createFromCode/ELF).
pub fn initSlot(idx: usize) *Process {
    slot_in_use[idx] = true;
    zeroSlot(idx);
    const p = &processes[idx];
    p.state = .ready;
    p.cpu_id = -1;
    p.mmap_hint = MMAP_BASE;
    p.cwd[0] = '/';
    p.cwd_len = 1;
    fd_table.initStdio(&p.fds);
    return p;
}

/// Initialize a process slot for fork (CoW).
pub fn initSlotForFork(idx: usize, parent: *Process) *Process {
    slot_in_use[idx] = true;
    zeroSlot(idx);
    const child = &processes[idx];
    child.state = .blocked;
    child.heap_start = parent.heap_start;
    child.heap_current = parent.heap_current;
    child.mmap_hint = parent.mmap_hint;
    child.umask_val = parent.umask_val;
    child.cpu_id = -1;
    child.cwd_len = parent.cwd_len;
    // Copy VMAs element-by-element, incrementing file refs
    for (0..vma.MAX_VMAS) |i| {
        child.vmas[i] = parent.vmas[i];
        if (child.vmas[i].in_use) {
            if (child.vmas[i].file) |f| _ = @atomicRmw(u32, &f.ref_count, .Add, 1, .acq_rel);
        }
    }
    // Copy file descriptors with atomic ref count increment
    for (0..fd_table.MAX_FDS) |i| {
        if (parent.fds[i]) |desc| {
            _ = @atomicRmw(u32, &desc.ref_count, .Add, 1, .acq_rel);
            child.fds[i] = desc;
        }
        child.fd_cloexec[i] = parent.fd_cloexec[i];
    }
    // Copy signal state
    child.sig_actions = parent.sig_actions;
    child.sig_mask = parent.sig_mask;
    // Copy CWD
    for (0..256) |ci| {
        child.cwd[ci] = parent.cwd[ci];
    }
    return child;
}

/// Initialize a process slot for CLONE_VM thread creation.
pub fn initSlotForClone(idx: usize, parent: *Process) *Process {
    slot_in_use[idx] = true;
    zeroSlot(idx);
    const child = &processes[idx];
    child.state = .blocked;
    child.page_table = parent.page_table;
    child.heap_start = parent.heap_start;
    child.heap_current = parent.heap_current;
    child.mmap_hint = parent.mmap_hint;
    child.umask_val = parent.umask_val;
    child.cpu_id = -1;
    // Copy parent's VMAs element-by-element
    for (0..vma.MAX_VMAS) |i| {
        child.vmas[i] = parent.vmas[i];
    }
    return child;
}

fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..pmm.PAGE_SIZE) |i| {
        ptr[i] = 0;
    }
}

/// Find a process by PID -- O(1) via hash table, linear fallback on collision.
pub fn findByPid(pid: u64) ?*Process {
    const idx = pid_to_idx[pidHash(pid)];
    if (idx) |i| {
        if (getProcess(i)) |p| {
            if (p.pid == pid) return p;
        }
    }
    // Fallback: linear scan
    for (0..MAX_PROCESSES) |i| {
        if (getProcess(i)) |p| {
            if (p.pid == pid) return p;
        }
    }
    return null;
}

/// For CLONE_VM threads, return the thread group leader to share VMA/mmap state.
pub fn getVmaOwner(proc: *Process) *Process {
    if (proc.pid == proc.tgid) return proc;
    return findByPid(proc.tgid) orelse proc;
}

/// Get the index of a process by PID.
pub fn findIndexByPid(pid: u64) ?usize {
    const idx = pid_to_idx[pidHash(pid)];
    if (idx) |i| {
        if (getProcess(i)) |p| {
            if (p.pid == pid) return i;
        }
    }
    // Fallback: linear scan
    for (0..MAX_PROCESSES) |i| {
        if (getProcess(i)) |p| {
            if (p.pid == pid) return i;
        }
    }
    return null;
}

/// Create a process from raw machine code bytes.
pub fn createFromCode(code: []const u8) !*Process {
    const idx = findFreeSlot() orelse return error.TooManyProcesses;

    // Create a new address space
    const root_phys = vmm.createAddressSpace() catch return error.OutOfMemory;

    // Allocate kernel stack with guard pages
    const kstack_phys = pmm.allocPagesGuarded(KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        vmm.destroyAddressSpace(root_phys);
        return error.OutOfMemory;
    };
    const kstack_top = kstack_phys + KERNEL_STACK_PAGES * pmm.PAGE_SIZE;

    // Write stack canary at the bottom
    const canary_ptr: *u64 = @ptrFromInt(kstack_phys);
    canary_ptr.* = pmm.STACK_CANARY;

    // Allocate a physical page for user code
    const code_page = pmm.allocPage() orelse return error.OutOfMemory;
    zeroPage(code_page);

    // Copy code to the page
    const code_ptr: [*]u8 = @ptrFromInt(code_page);
    const copy_len = if (code.len > pmm.PAGE_SIZE) pmm.PAGE_SIZE else code.len;
    for (0..copy_len) |i| {
        code_ptr[i] = code[i];
    }

    // Map user code page
    vmm.mapPage(root_phys, USER_CODE_BASE, code_page, .{
        .user = true,
        .executable = true,
    }) catch return error.OutOfMemory;

    // Allocate and map user stack
    var s: u64 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_page = pmm.allocPage() orelse return error.OutOfMemory;
        zeroPage(stack_page);
        const vaddr = USER_STACK_TOP - (USER_STACK_PAGES - s) * pmm.PAGE_SIZE;
        vmm.mapPage(root_phys, vaddr, stack_page, .{
            .user = true,
            .writable = true,
            .executable = false,
        }) catch return error.OutOfMemory;
    }

    const pid = next_pid;
    next_pid += 1;

    // Heap starts after code
    const code_pages = (code.len + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
    const heap_start = USER_CODE_BASE + code_pages * pmm.PAGE_SIZE;

    const p = initSlot(idx);
    p.pid = pid;
    p.tgid = pid;
    p.page_table = root_phys;
    p.kernel_stack_phys = kstack_phys;
    p.kernel_stack_top = kstack_top;
    p.kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES);
    // Set up context for sret to U-mode
    p.context.sepc = USER_CODE_BASE;
    p.context.x[2] = USER_STACK_TOP; // sp = x2
    p.context.sstatus = SSTATUS_SPIE | SSTATUS_SUM; // SPP=0 (U-mode), SPIE=1
    p.heap_start = heap_start;
    p.heap_current = heap_start;

    // Code VMA
    const code_pages_count = (code.len + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
    _ = vma.addVma(&p.vmas, USER_CODE_BASE, USER_CODE_BASE + code_pages_count * pmm.PAGE_SIZE, .{
        .readable = true,
        .executable = true,
    });

    // Stack VMA (full VMA size, only top pages mapped eagerly)
    const stack_vma_start = USER_STACK_TOP - USER_STACK_VMA_PAGES * pmm.PAGE_SIZE;
    if (vma.addVma(&p.vmas, stack_vma_start, USER_STACK_TOP, .{
        .readable = true,
        .writable = true,
        .stack = true,
    })) |stack_vma| {
        stack_vma.guard_pages = 1;
    }

    // Heap VMA (starts empty, grows via brk)
    _ = vma.addVma(&p.vmas, heap_start, heap_start, .{
        .readable = true,
        .writable = true,
    });

    registerPid(pid, idx);
    uart.print("[proc] Created PID {} at {x}\n", .{ pid, USER_CODE_BASE });

    return p;
}

/// Create a process from raw ELF data in memory.
pub fn createFromElfData(data: []const u8) !*Process {
    const idx = findFreeSlot() orelse return error.TooManyProcesses;

    // Create a new address space
    const root_phys = vmm.createAddressSpace() catch return error.OutOfMemory;

    // Load ELF segments into the address space
    const elf_info = elf.loadElf(root_phys, data) catch |err| {
        vmm.destroyAddressSpace(root_phys);
        return switch (err) {
            error.InvalidElf => error.InvalidExecutable,
            error.OutOfMemory => error.OutOfMemory,
        };
    };

    // Allocate kernel stack with guard pages
    const kstack_phys = pmm.allocPagesGuarded(KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        vmm.destroyAddressSpace(root_phys);
        return error.OutOfMemory;
    };
    const kstack_top = kstack_phys + KERNEL_STACK_PAGES * pmm.PAGE_SIZE;

    // Write stack canary
    const canary_ptr: *u64 = @ptrFromInt(kstack_phys);
    canary_ptr.* = pmm.STACK_CANARY;

    // Allocate and map user stack
    var s: u64 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_page = pmm.allocPage() orelse return error.OutOfMemory;
        zeroPage(stack_page);
        const vaddr = USER_STACK_TOP - (USER_STACK_PAGES - s) * pmm.PAGE_SIZE;
        vmm.mapPage(root_phys, vaddr, stack_page, .{
            .user = true,
            .writable = true,
            .executable = false,
        }) catch return error.OutOfMemory;
    }

    const pid = next_pid;
    next_pid += 1;

    // Heap starts after the highest ELF segment
    const heap_start = elf_info.highest_addr;

    const p = initSlot(idx);
    p.pid = pid;
    p.tgid = pid;
    p.page_table = root_phys;
    p.kernel_stack_phys = kstack_phys;
    p.kernel_stack_top = kstack_top;
    p.kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES);
    // Write argc=0, argv=NULL, envp=NULL, auxv terminator on stack (Linux ELF ABI)
    // Then set sp to point to argc.
    const stack_setup_base = USER_STACK_TOP - 32; // 4 * 8 bytes
    if (vmm.translate(root_phys, stack_setup_base)) |phys| {
        const stack_ptr: [*]volatile u64 = @ptrFromInt(phys);
        stack_ptr[0] = 0; // argc = 0
        stack_ptr[1] = 0; // argv[0] = NULL
        stack_ptr[2] = 0; // envp[0] = NULL
        stack_ptr[3] = 0; // auxv terminator
    }
    // Set up context for sret to U-mode
    p.context.sepc = elf_info.entry;
    p.context.x[2] = stack_setup_base; // sp points to argc
    p.context.sstatus = SSTATUS_SPIE | SSTATUS_SUM; // SPP=0 (U-mode), SPIE=1
    p.heap_start = heap_start;
    p.heap_current = heap_start;

    // Code/data VMA (from ELF load base to highest address)
    _ = vma.addVma(&p.vmas, USER_CODE_BASE, elf_info.highest_addr, .{
        .readable = true,
        .writable = true,
        .executable = true,
        .user = true,
    });

    // Stack VMA
    const stack_vma_start = USER_STACK_TOP - USER_STACK_VMA_PAGES * pmm.PAGE_SIZE;
    if (vma.addVma(&p.vmas, stack_vma_start, USER_STACK_TOP, .{
        .readable = true,
        .writable = true,
        .user = true,
        .stack = true,
    })) |stack_vma| {
        stack_vma.guard_pages = 1;
    }

    // Heap VMA
    _ = vma.addVma(&p.vmas, heap_start, heap_start, .{
        .readable = true,
        .writable = true,
        .user = true,
    });

    registerPid(pid, idx);
    uart.print("[proc] Created PID {} from ELF, entry={x}\n", .{ pid, elf_info.entry });

    return p;
}
