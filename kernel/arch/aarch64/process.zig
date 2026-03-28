/// ARM64 Process management — process struct, context, creation.
/// Equivalent to x86_64 kernel/proc/process.zig but with ARM64-specific context.

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const spinlock = @import("spinlock.zig");
const vmm = @import("vmm.zig");
const exception = @import("exception.zig");
const vfs = @import("vfs.zig");
const fd_table = @import("fd_table.zig");
const elf = @import("elf.zig");
const vma = @import("vma.zig");
const signal = @import("signal.zig");
const sve = @import("sve.zig");
const cpu_features = @import("cpu_features.zig");

pub const MAX_SIGNALS: usize = signal.MAX_SIGNALS;

pub const KERNEL_STACK_PAGES: u64 = 32;  // 128 KiB kernel stack (safer margin for deep call chains)
pub const USER_STACK_PAGES: u64 = 8;    // 32 KiB user stack (initial mapped pages)
pub const USER_STACK_VMA_PAGES: u64 = 12288; // 48 MiB stack VMA — demand-paged

/// User virtual address layout
/// Note: For ARM64, we use addresses in the user range (TTBR0)
pub const USER_CODE_BASE: u64 = 0x400000;
pub const USER_STACK_TOP: u64 = 0x7FFFFFFFE000;

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

/// Saved CPU context — matches the TrapFrame layout from exception.zig (800 bytes)
pub const Context = extern struct {
    x: [31]u64 = [_]u64{0} ** 31,  // X0-X30
    sp: u64 = 0,                   // User stack pointer (SP_EL0)
    elr: u64 = 0,                  // Exception Link Register (return address)
    spsr: u64 = 0,                 // Saved Program Status Register
    simd: [32][2]u64 = [_][2]u64{.{ 0, 0 }} ** 32,  // q0-q31 SIMD/FP registers
    fpcr: u64 = 0,                 // Floating-point Control Register
    fpsr: u64 = 0,                 // Floating-point Status Register

    /// Set syscall return value (X0)
    pub fn setReturn(self: *Context, value: u64) void {
        self.x[0] = value;
    }

    /// Get syscall number (X8 in Linux AArch64 ABI)
    pub fn syscallNum(self: *const Context) u64 {
        return self.x[8];
    }

    /// Get syscall arguments (X0-X5)
    pub fn arg0(self: *const Context) u64 { return self.x[0]; }
    pub fn arg1(self: *const Context) u64 { return self.x[1]; }
    pub fn arg2(self: *const Context) u64 { return self.x[2]; }
    pub fn arg3(self: *const Context) u64 { return self.x[3]; }
    pub fn arg4(self: *const Context) u64 { return self.x[4]; }
    pub fn arg5(self: *const Context) u64 { return self.x[5]; }
};

/// SPSR bits for EL0 (user mode)
const SPSR_EL0: u64 = 0b0000; // EL0 with SP_EL0, AArch64
const SPSR_DAIF_CLEAR: u64 = 0; // All exceptions unmasked

pub const Process = struct {
    pid: u64 = 0,
    tgid: u64 = 0,
    state: ProcessState = .ready,
    page_table: u64 = 0,
    kernel_stack_phys: u64 = 0,
    kernel_stack_top: u64 = 0,
    kernel_stack_guard: u16 = 0, // Rowhammer guard pages on each side
    context: Context = .{},
    heap_start: u64 = 0,
    heap_current: u64 = 0,
    parent_pid: u64 = 0,
    exit_status: u64 = 0,
    tls_base: u64 = 0,       // TPIDR_EL0 for TLS
    uid: u16 = 0,
    gid: u16 = 0,
    euid: u16 = 0,
    egid: u16 = 0,
    mmap_hint: u64 = 0x7FFFF0000000,  // Top-down mmap allocator (starts at MMAP_REGION_END)
    umask_val: u32 = 0o022,
    pgid: u32 = 0,
    clear_child_tid: u64 = 0,
    wake_tick: u64 = 0,           // Timer-based wakeup (for epoll timeout, nanosleep)
    cpu_id: i32 = -1,             // CPU currently running this process (-1 = not running)
    vma_lock: spinlock.IrqSpinlock = .{},  // Protects vmas + page_table for CLONE_VM threads
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

    // SVE state — lazily allocated on first SVE instruction use.
    // null = process has never used SVE (no context to save/restore).
    // Allocation happens on SVE trap (CPACR_EL1.ZEN=00 causes sync exception).
    sve_context: ?*sve.SveContext = null,
    sve_dirty: bool = false,  // true if SVE registers modified since last save

    // SMP kill flag — set by killThreadGroup/sysExitGroup to prevent syscall
    // handlers from overwriting zombie state. Checked in blockAndSchedule and
    // handleIrqException. Unlike .state, this flag is never cleared by syscall
    // handlers, so it survives the race where a mid-syscall thread sets a
    // blocked state after killThreadGroup has marked it zombie.
    killed: bool = false,

    // Pinned executable inode — prevents ext2 cache eviction during demand paging.
    // Set on execve, unpinned on next execve or exit.
    pinned_exec_inode: ?*vfs.Inode = null,

    // Per-CPU runqueue linkage — intrusive singly-linked list.
    // null when not on any runqueue (running, blocked, or zombie).
    rq_next: ?*Process = null,
    // CPU this process is assigned to for scheduling (set on fork/exec).
    home_cpu: u32 = 0,
};

/// Default mmap base (top of mmap region, allocates downward)
const MMAP_BASE: u64 = 0x7FFFF0000000;

/// ASLR: randomize mmap base using CNTVCT_EL0 entropy.
/// Returns a random value in [MMAP_BASE - 4GB, MMAP_BASE], 2MB-aligned.
pub fn aslrMmapBase() u64 {
    const cnt = asm volatile ("mrs %[ret], CNTVCT_EL0"
        : [ret] "=r" (-> u64),
    );
    // Use low 20 bits for offset → 0 to ~1M pages → 0 to 4GB range, 2MB-aligned
    const rand_pages = cnt & 0xFFFFF;
    const offset = (rand_pages << 12) & ~@as(u64, 0x1FFFFF);
    return MMAP_BASE - offset;
}

pub const MAX_PROCESSES = 512;

/// Process table — non-Optional, validity tracked by slot_in_use[].
/// CRITICAL: Never assign to processes[idx] using a struct literal — in Debug
/// mode Zig creates a ~450KB stack temporary (8192 VMAs * 56 bytes) that
/// overflows the kernel stack and corrupts adjacent BSS (pipe_inodes, etc).
/// Always use zeroSlot() + individual field writes.
var processes: [MAX_PROCESSES]Process = [_]Process{.{}} ** MAX_PROCESSES;
pub var slot_in_use: [MAX_PROCESSES]bool = [_]bool{false} ** MAX_PROCESSES;
var next_pid: u64 = 1;

/// SMP lock — protects process table, slot_in_use, and next_pid.
pub var proc_lock: spinlock.IrqSpinlock = .{};

// --- Free list for O(1) slot allocation ---
var free_next: [MAX_PROCESSES]?usize = [_]?usize{null} ** MAX_PROCESSES;
var free_head: ?usize = null;
var free_list_initialized: bool = false;

// --- PID hash table for O(1) lookup ---
const PID_HASH_SIZE: usize = 512;
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

/// Register a PID→slot mapping.
pub fn registerPid(pid: u64, idx: usize) void {
    pid_to_idx[pidHash(pid)] = idx;
}

/// Unregister a PID from the hash table.
pub fn unregisterPid(pid: u64) void {
    pid_to_idx[pidHash(pid)] = null;
}

/// Create a process from raw machine code bytes
pub fn createFromCode(code: []const u8) !*Process {
    const idx = findFreeSlot() orelse return error.TooManyProcesses;

    // Create a new address space
    const l0 = (vmm.createAddressSpace() catch return error.OutOfMemory).toInt();

    // Allocate kernel stack with rowhammer guard pages
    const kstack_phys = pmm.allocPagesGuarded(KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        vmm.destroyAddressSpace(vmm.PhysAddr.from(l0));
        return error.OutOfMemory;
    };
    const kstack_top = kstack_phys + KERNEL_STACK_PAGES * pmm.PAGE_SIZE;

    // Write stack canary at the bottom of the kernel stack
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
    vmm.mapPage(vmm.PhysAddr.from(l0), vmm.VirtAddr.from(USER_CODE_BASE), vmm.PhysAddr.from(code_page), .{
        .user = true,
        .executable = true,
    }) catch return error.OutOfMemory;

    // Allocate and map user stack
    var s: u64 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_page = pmm.allocPage() orelse return error.OutOfMemory;
        zeroPage(stack_page);
        const vaddr = USER_STACK_TOP - (USER_STACK_PAGES - s) * pmm.PAGE_SIZE;
        vmm.mapPage(vmm.PhysAddr.from(l0), vmm.VirtAddr.from(vaddr), vmm.PhysAddr.from(stack_page), .{
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
    p.page_table = l0;
    p.kernel_stack_phys = kstack_phys;
    p.kernel_stack_top = kstack_top;
    p.kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES);
    p.context.elr = USER_CODE_BASE;
    p.context.sp = USER_STACK_TOP;
    p.context.spsr = SPSR_EL0;
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
        stack_vma.guard_pages = 1; // Stack overflow guard page at bottom
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
        // Return to free list
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
/// CRITICAL: Never use `processes[idx] = Process{...}` — in Debug mode, Zig
/// creates a ~450KB stack temporary for the struct literal (8192 VMAs * 56 bytes),
/// which overflows the kernel stack and corrupts adjacent BSS memory.
fn zeroSlot(idx: usize) void {
    const raw: [*]u8 = @ptrCast(&processes[idx]);
    @memset(raw[0..@sizeOf(Process)], 0);
}

/// Initialize a process slot directly in the table for CLONE_VM thread creation.
/// Uses zeroSlot + field writes (no struct literal = no stack temporary).
pub fn initSlotForClone(idx: usize, parent: *Process) *Process {
    slot_in_use[idx] = true;
    zeroSlot(idx);
    const child = &processes[idx];
    child.state = .blocked; // Not schedulable until caller finishes context setup
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

/// Initialize a fresh process slot (for createFromCode/ELF).
/// Uses zeroSlot + stdio init + VMA init.
pub fn initSlot(idx: usize) *Process {
    slot_in_use[idx] = true;
    zeroSlot(idx);
    const p = &processes[idx];
    p.state = .ready;
    p.cpu_id = -1;
    p.mmap_hint = aslrMmapBase();
    p.cwd[0] = '/';
    p.cwd_len = 1;
    fd_table.initStdio(&p.fds);
    return p;
}

/// Initialize a process slot for fork (CoW). Uses zeroSlot to avoid creating
/// a ~450KB stack temporary. Copies VMAs, fds, signals, CWD from parent.
pub fn initSlotForFork(idx: usize, parent: *Process) *Process {
    slot_in_use[idx] = true;
    zeroSlot(idx);
    const child = &processes[idx];
    child.state = .blocked; // Not schedulable until caller finishes context setup
    child.heap_start = parent.heap_start;
    child.heap_current = parent.heap_current;
    child.mmap_hint = parent.mmap_hint;
    child.umask_val = parent.umask_val;
    child.cpu_id = -1;
    child.cwd_len = parent.cwd_len;
    // Copy VMAs element-by-element, incrementing file refs for file-backed VMAs
    for (0..vma.MAX_VMAS) |i| {
        child.vmas[i] = parent.vmas[i];
        if (child.vmas[i].in_use) {
            if (child.vmas[i].file) |f| _ = @atomicRmw(u32, &f.ref_count, .Add, 1, .acq_rel);
        }
    }
    // Copy file descriptors with atomic ref count increment and cloexec flags.
    // Must be atomic: parent/sibling on another CPU may releaseFileDescription
    // concurrently (e.g., closing pipe FDs after fork).
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

fn zeroPage(phys: u64) void {
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..pmm.PAGE_SIZE) |i| {
        ptr[i] = 0;
    }
}

/// Find a process by PID — O(1) via hash table, linear fallback on collision.
pub fn findByPid(pid: u64) ?*Process {
    const idx = pid_to_idx[pidHash(pid)];
    if (idx) |i| {
        if (getProcess(i)) |p| {
            if (p.pid == pid) return p;
        }
    }
    // Fallback: linear scan (hash collision or unregistered)
    for (0..MAX_PROCESSES) |i| {
        if (getProcess(i)) |p| {
            if (p.pid == pid) return p;
        }
    }
    return null;
}

/// For CLONE_VM threads, return the thread group leader to share VMA/mmap state.
/// This ensures all threads in the same address space see consistent VMAs.
pub fn getVmaOwner(proc: *Process) *Process {
    if (proc.pid == proc.tgid) return proc;
    return findByPid(proc.tgid) orelse proc;
}

/// Get the index of a process by PID — O(1) via hash table.
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

/// Create a process from an ELF binary stored in the VFS
pub fn createFromElfPath(path: []const u8) !*Process {
    // Read the ELF binary from the filesystem
    var elf_buf: [256 * 1024]u8 = undefined; // 256KB max
    const elf_size = vfs.readWholeFile(path, &elf_buf) orelse return error.FileNotFound;

    return createFromElfData(elf_buf[0..elf_size]);
}

/// Create a process from raw ELF data in memory
pub fn createFromElfData(data: []const u8) !*Process {
    const idx = findFreeSlot() orelse return error.TooManyProcesses;

    // Create a new address space
    const l0 = (vmm.createAddressSpace() catch return error.OutOfMemory).toInt();

    // Load ELF segments into the address space
    const elf_info = elf.loadElf(l0, data) catch |err| {
        vmm.destroyAddressSpace(vmm.PhysAddr.from(l0));
        return switch (err) {
            error.InvalidElf => error.InvalidExecutable,
            error.OutOfMemory => error.OutOfMemory,
        };
    };

    // Allocate kernel stack with rowhammer guard pages
    const kstack_phys = pmm.allocPagesGuarded(KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        vmm.destroyUserPages(vmm.PhysAddr.from(l0));
        vmm.destroyAddressSpace(vmm.PhysAddr.from(l0));
        return error.OutOfMemory;
    };
    const kstack_top = kstack_phys + KERNEL_STACK_PAGES * pmm.PAGE_SIZE;

    // Write stack canary at the bottom of the kernel stack
    const canary_ptr2: *u64 = @ptrFromInt(kstack_phys);
    canary_ptr2.* = pmm.STACK_CANARY;

    // Allocate and map user stack
    var s: u64 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_page = pmm.allocPage() orelse return error.OutOfMemory;
        zeroPage(stack_page);
        const vaddr = USER_STACK_TOP - (USER_STACK_PAGES - s) * pmm.PAGE_SIZE;
        vmm.mapPage(vmm.PhysAddr.from(l0), vmm.VirtAddr.from(vaddr), vmm.PhysAddr.from(stack_page), .{
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
    p.page_table = l0;
    p.kernel_stack_phys = kstack_phys;
    p.kernel_stack_top = kstack_top;
    p.kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES);
    p.context.elr = elf_info.entry;
    p.context.sp = USER_STACK_TOP;
    p.context.spsr = SPSR_EL0;
    p.heap_start = heap_start;
    p.heap_current = heap_start;

    // Code/data VMA (from ELF load base to highest address)
    _ = vma.addVma(&p.vmas, USER_CODE_BASE, elf_info.highest_addr, .{
        .readable = true,
        .writable = true,
        .executable = true,
        .user = true,
    });

    // Stack VMA (full 1 MiB, only top pages mapped eagerly — rest demand-paged)
    const stack_vma_start = USER_STACK_TOP - USER_STACK_VMA_PAGES * pmm.PAGE_SIZE;
    if (vma.addVma(&p.vmas, stack_vma_start, USER_STACK_TOP, .{
        .readable = true,
        .writable = true,
        .user = true,
        .stack = true,
    })) |stack_vma| {
        stack_vma.guard_pages = 1; // Stack overflow guard page at bottom
    }

    // Heap VMA (starts empty, grows via brk)
    _ = vma.addVma(&p.vmas, heap_start, heap_start, .{
        .readable = true,
        .writable = true,
        .user = true,
    });

    registerPid(pid, idx);
    uart.print("[proc] Created PID {} from ELF, entry={x}\n", .{ pid, elf_info.entry });

    return p;
}
