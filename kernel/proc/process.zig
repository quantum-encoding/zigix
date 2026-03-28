/// Process management — process struct, context, creation.
/// TODO: Fixed [16]?Process table (~200+ bytes per slot) is fine for MVP.
/// Future: dynamic allocation for scaling beyond 16 processes.

const types = @import("../types.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const vmm = @import("../mm/vmm.zig");
const vma = @import("../mm/vma.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const vfs = @import("../fs/vfs.zig");
const fd_table = @import("../fs/fd_table.zig");
const elf = @import("elf.zig");
const capability = @import("../security/capability.zig");
const spinlock = @import("../arch/x86_64/spinlock.zig");

/// SMP lock protecting the process table (slot_in_use, processes arrays).
pub var proc_lock: spinlock.IrqSpinlock = .{};

pub const KERNEL_STACK_PAGES: u64 = 64; // 256 KiB kernel stack per process
pub const USER_STACK_PAGES: u64 = 8; // 32 KiB user stack (initial mapped pages)
pub const USER_STACK_VMA_PAGES: u64 = 12288; // 48 MiB stack VMA — demand-paged

// User virtual address layout
pub const USER_CODE_BASE: u64 = 0x400000;
pub const USER_STACK_TOP: u64 = 0x7FFFFFFFF000; // Stack grows down from here

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

/// Saved CPU context — layout matches the interrupt frame pushed by commonStub.
pub const Context = extern struct {
    // General-purpose registers (saved/restored on context switch)
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    r11: u64 = 0,
    r10: u64 = 0,
    r9: u64 = 0,
    r8: u64 = 0,
    rbp: u64 = 0,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rdx: u64 = 0,
    rcx: u64 = 0,
    rbx: u64 = 0,
    rax: u64 = 0,
    // CPU interrupt frame
    rip: u64 = 0,
    cs: u64 = 0,
    rflags: u64 = 0,
    rsp: u64 = 0,
    ss: u64 = 0,
};

pub const SignalAction = struct {
    handler: u64 = 0, // SIG_DFL(0), SIG_IGN(1), or function pointer
    flags: u64 = 0,
    mask: u64 = 0, // signals to block while handler runs
    restorer: u64 = 0, // SA_RESTORER: musl's signal return trampoline in .text
};

pub const MAX_SIGNALS: usize = 64;

pub const Process = struct {
    pid: types.ProcessId,
    tgid: types.ProcessId, // Thread group leader's PID
    pgid: types.ProcessId, // Process group ID
    state: ProcessState,
    page_table: types.PhysAddr, // PML4 physical address
    kernel_stack_phys: types.PhysAddr,
    kernel_stack_top: types.VirtAddr, // Virtual (HHDM) top of kernel stack
    kernel_stack_guard: u16 = 0, // Rowhammer guard pages on each side
    context: Context,
    heap_start: u64, // First page after code section
    heap_current: u64, // Current break (page-aligned)
    fds: [fd_table.MAX_FDS]?*vfs.FileDescription,
    cwd: [256]u8,
    cwd_len: u8,
    parent_pid: u64 = 0,
    exit_status: u64 = 0,
    clear_child_tid: u64 = 0, // set_tid_address target (0 = not set)
    fs_base: u64 = 0, // IA32_FS_BASE for TLS (set by arch_prctl ARCH_SET_FS)
    vmas: vma.VmaList = vma.emptyVmaList(),
    sig_pending: u64 = 0, // Pending signal bitmap
    sig_mask: u64 = 0, // Blocked signal mask
    sig_actions: [MAX_SIGNALS]SignalAction = [_]SignalAction{.{}} ** MAX_SIGNALS,
    in_signal_handler: bool = false, // True during signal delivery (prevents recursive SIGSEGV)
    vfork_blocked: bool = false, // True when parent is blocked waiting for vfork child
    exe_path: [256]u8 = [_]u8{0} ** 256,
    exe_path_len: u8 = 0,
    uid: u16 = 0,
    gid: u16 = 0,
    euid: u16 = 0,
    egid: u16 = 0,
    exec_inode: ?*anyopaque = null, // Pinned executable inode (for ext2 unpin on exit)
    wake_tick: u64 = 0, // Tick count at which to wake from nanosleep (0 = not sleeping)
    mmap_hint: u64 = 0x7000_0000_0000, // Per-process top-down mmap allocator
    umask_val: u32 = 0o022, // File creation mask
    sid: u64 = 0, // Session ID (0 = inherit from parent, set by setsid)
    capabilities: u64 = 0, // Zee eBPF capability bitmask (see security/capability.zig)
};

/// Default mmap base (top of mmap region, allocates downward)
const MMAP_BASE: u64 = 0x7000_0000_0000;

/// ASLR: randomize mmap base using RDTSC entropy.
/// Returns a random value in [MMAP_BASE - 1TB, MMAP_BASE], 2MB-aligned.
pub fn aslrMmapBase() u64 {
    const tsc = rdtsc();
    // Use low 20 bits of TSC for offset → 0 to 1M pages → 0 to 4GB range, 2MB-aligned
    const rand_pages = tsc & 0xFFFFF; // 0 to ~1M
    const offset = (rand_pages << 12) & ~@as(u64, 0x1FFFFF); // page-aligned then 2MB-aligned
    return MMAP_BASE - offset;
}

fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

pub const MAX_PROCESSES = 256;

var processes: [MAX_PROCESSES]?Process = [_]?Process{null} ** MAX_PROCESSES;
var slot_in_use: [MAX_PROCESSES]bool = [_]bool{false} ** MAX_PROCESSES;
var next_pid: types.ProcessId = 1;

// --- Free list for O(1) slot allocation ---
var free_next: [MAX_PROCESSES]?usize = [_]?usize{null} ** MAX_PROCESSES;
var free_head: ?usize = null;
var free_list_initialized: bool = false;

// --- PID hash table for O(1) lookup ---
const PID_HASH_SIZE: usize = 256;
var pid_to_idx: [PID_HASH_SIZE]?usize = [_]?usize{null} ** PID_HASH_SIZE;

fn pidHash(pid: types.ProcessId) usize {
    return @truncate(pid % PID_HASH_SIZE);
}

/// Initialize the free list (chain all slots). Call once at boot.
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

/// Register a PID→slot mapping in the hash table.
pub fn registerPid(pid: types.ProcessId, idx: usize) void {
    const h = pidHash(pid);
    pid_to_idx[h] = idx; // Simple direct mapping; collision: latest wins
}

/// Unregister a PID from the hash table.
pub fn unregisterPid(pid: types.ProcessId) void {
    const h = pidHash(pid);
    pid_to_idx[h] = null;
}

/// Find a process by PID using hash table (O(1) fast path, O(n) fallback).
pub fn findByPid(pid: types.ProcessId) ?*Process {
    const h = pidHash(pid);
    if (pid_to_idx[h]) |idx| {
        if (getProcess(idx)) |p| {
            if (p.pid == pid) return p;
        }
    }
    // Hash collision fallback: linear scan
    for (0..MAX_PROCESSES) |i| {
        if (slot_in_use[i]) {
            if (processes[i]) |*p| {
                if (p.pid == pid) return p;
            }
        }
    }
    return null;
}

/// Create a process from raw machine code bytes.
/// Allocates address space, kernel stack, copies code into user page,
/// maps user stack, and initializes the context for ring 3 entry.
pub fn createFromCode(code: []const u8) !*Process {
    const idx = findFreeSlot() orelse return error.TooManyProcesses;

    // Create a new address space (shares kernel half)
    const pml4 = vmm.createAddressSpace() catch return error.OutOfMemory;

    // Allocate kernel stack with rowhammer guard pages
    const kstack_phys = pmm.allocPagesGuarded(KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        vmm.destroyAddressSpace(pml4);
        return error.OutOfMemory;
    };
    const kstack_virt = hhdm.physToVirt(kstack_phys);
    const kstack_top = kstack_virt + KERNEL_STACK_PAGES * types.PAGE_SIZE;

    // Write stack canary at the bottom of the kernel stack
    const canary_ptr: *u64 = @ptrFromInt(kstack_virt);
    canary_ptr.* = pmm.STACK_CANARY;

    // Allocate a physical page for user code, zero it, copy program bytes
    const code_page = pmm.allocPage() orelse {
        pmm.freePagesGuarded(kstack_phys, KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES);
        vmm.destroyAddressSpace(pml4);
        return error.OutOfMemory;
    };
    zeroPage(code_page);
    const code_ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(code_page));
    const copy_len = if (code.len > types.PAGE_SIZE) types.PAGE_SIZE else code.len;
    for (0..copy_len) |i| {
        code_ptr[i] = code[i];
    }

    // Map user code page at USER_CODE_BASE (readable + executable, not writable)
    vmm.mapPage(pml4, USER_CODE_BASE, code_page, .{ .user = true }) catch {
        pmm.freePage(code_page);
        var p2: u64 = 0;
        while (p2 < KERNEL_STACK_PAGES) : (p2 += 1) {
            pmm.freePage(kstack_phys + p2 * types.PAGE_SIZE);
        }
        vmm.destroyAddressSpace(pml4);
        return error.OutOfMemory;
    };

    // Allocate and map user stack pages below USER_STACK_TOP
    var s: u64 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_page = pmm.allocPage() orelse {
            // Free previously allocated stack pages (they're mapped, destroyAddressSpace handles them)
            // Free code page, kstack, and pml4
            vmm.destroyAddressSpace(pml4);
            var p3: u64 = 0;
            while (p3 < KERNEL_STACK_PAGES) : (p3 += 1) {
                pmm.freePage(kstack_phys + p3 * types.PAGE_SIZE);
            }
            return error.OutOfMemory;
        };
        zeroPage(stack_page);
        const vaddr = USER_STACK_TOP - (USER_STACK_PAGES - s) * types.PAGE_SIZE;
        vmm.mapPage(pml4, vaddr, stack_page, .{
            .user = true,
            .writable = true,
            .no_execute = true,
        }) catch {
            pmm.freePage(stack_page);
            vmm.destroyAddressSpace(pml4);
            var p4: u64 = 0;
            while (p4 < KERNEL_STACK_PAGES) : (p4 += 1) {
                pmm.freePage(kstack_phys + p4 * types.PAGE_SIZE);
            }
            return error.OutOfMemory;
        };
    }

    const pid = next_pid;
    next_pid += 1;

    // Heap starts at page boundary after code section
    const code_pages = (code.len + types.PAGE_SIZE - 1) / types.PAGE_SIZE;
    const heap_start = USER_CODE_BASE + code_pages * types.PAGE_SIZE;

    slot_in_use[idx] = true;
    processes[idx] = .{
        .pid = pid,
        .tgid = pid, // Single-threaded: group leader is self
        .pgid = pid, // Own process group
        .state = .ready,
        .page_table = pml4,
        .kernel_stack_phys = kstack_phys,
        .kernel_stack_top = kstack_top,
        .kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES),
        .context = .{
            .rip = USER_CODE_BASE,
            .cs = gdt.USER_CS,
            .rflags = 0x202, // IF=1 (interrupts enabled) + reserved bit 1
            .rsp = USER_STACK_TOP,
            .ss = gdt.USER_DS,
        },
        .heap_start = heap_start,
        .heap_current = heap_start,
        .fds = [_]?*vfs.FileDescription{null} ** fd_table.MAX_FDS,
        .cwd = [_]u8{0} ** 256,
        .cwd_len = 1,
    };

    registerPid(pid, idx);

    // Pre-populate fd 0/1/2 with serial I/O
    fd_table.initStdio(&processes[idx].?.fds);
    processes[idx].?.cwd[0] = '/';

    // Set up VMAs for code, stack, and heap
    var proc_ptr = &(processes[idx].?);
    vma.initVmaList(&proc_ptr.vmas);
    _ = vma.addVma(&proc_ptr.vmas, USER_CODE_BASE, USER_CODE_BASE + code_pages * types.PAGE_SIZE, vma.VMA_READ | vma.VMA_EXEC | vma.VMA_USER);
    if (vma.addVma(&proc_ptr.vmas, USER_STACK_TOP - USER_STACK_VMA_PAGES * types.PAGE_SIZE, USER_STACK_TOP + types.PAGE_SIZE, vma.VMA_READ | vma.VMA_WRITE | vma.VMA_USER)) |stack_vma| {
        stack_vma.guard_pages = 1; // Stack overflow guard page at bottom
    }
    _ = vma.addVma(&proc_ptr.vmas, heap_start, heap_start, vma.VMA_READ | vma.VMA_WRITE | vma.VMA_USER);

    return proc_ptr;
}

/// Create a process from an ELF64 binary.
/// Parses ELF headers, maps PT_LOAD segments, allocates kernel and user stacks,
/// sets up initial stack with argc/argv/envp/auxv, and initializes context.
pub fn createFromElf(elf_data: []const u8) !*Process {
    const idx = findFreeSlot() orelse return error.TooManyProcesses;

    // Create a new address space (shares kernel half)
    const pml4 = vmm.createAddressSpace() catch return error.OutOfMemory;

    // Allocate kernel stack with rowhammer guard pages
    const kstack_phys = pmm.allocPagesGuarded(KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        vmm.destroyAddressSpace(pml4);
        return error.OutOfMemory;
    };
    const kstack_virt = hhdm.physToVirt(kstack_phys);
    const kstack_top = kstack_virt + KERNEL_STACK_PAGES * types.PAGE_SIZE;

    // Write stack canary at the bottom of the kernel stack
    const canary_ptr2: *u64 = @ptrFromInt(kstack_virt);
    canary_ptr2.* = pmm.STACK_CANARY;

    // Load ELF segments into address space
    const elf_info = elf.loadElf(pml4, elf_data) catch return error.OutOfMemory;

    // Allocate and map user stack pages below USER_STACK_TOP
    var s: u64 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_page = pmm.allocPage() orelse return error.OutOfMemory;
        zeroPage(stack_page);
        const vaddr = USER_STACK_TOP - (USER_STACK_PAGES - s) * types.PAGE_SIZE;
        vmm.mapPage(pml4, vaddr, stack_page, .{
            .user = true,
            .writable = true,
            .no_execute = true,
        }) catch return error.OutOfMemory;
    }

    // Set up initial stack: argc, argv NULL, envp NULL, auxv
    // Layout at RSP (16-byte aligned):
    //   RSP+0:  argc = 0
    //   RSP+8:  argv terminator (NULL)
    //   RSP+16: envp terminator (NULL)
    //   RSP+24: AT_PAGESZ (6)
    //   RSP+32: 4096
    //   RSP+40: AT_NULL (0)
    //   RSP+48: 0
    const initial_rsp = USER_STACK_TOP - 64; // 16-byte aligned, 56 bytes of data + 8 padding

    // Write stack data via HHDM
    if (vmm.translate(pml4, initial_rsp)) |stack_phys| {
        const stack_ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(stack_phys));
        const off: usize = @truncate(initial_rsp & 0xFFF);
        // argc = 0
        writeU64(stack_ptr + off, 0);
        // argv[0] = NULL
        writeU64(stack_ptr + off + 8, 0);
        // envp[0] = NULL
        writeU64(stack_ptr + off + 16, 0);
        // AT_PAGESZ = 6
        writeU64(stack_ptr + off + 24, 6);
        // value = 4096
        writeU64(stack_ptr + off + 32, 4096);
        // AT_NULL = 0
        writeU64(stack_ptr + off + 40, 0);
        // value = 0
        writeU64(stack_ptr + off + 48, 0);
    }

    const pid = next_pid;
    next_pid += 1;

    // Heap starts after highest ELF segment
    const heap_start = elf_info.highest_addr;

    slot_in_use[idx] = true;
    processes[idx] = .{
        .pid = pid,
        .tgid = pid, // Single-threaded: group leader is self
        .pgid = pid, // Own process group
        .state = .ready,
        .page_table = pml4,
        .kernel_stack_phys = kstack_phys,
        .kernel_stack_top = kstack_top,
        .kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES),
        .context = .{
            .rip = elf_info.entry,
            .cs = gdt.USER_CS,
            .rflags = 0x202, // IF=1 + reserved bit 1
            .rsp = initial_rsp,
            .ss = gdt.USER_DS,
        },
        .heap_start = heap_start,
        .heap_current = heap_start,
        .mmap_hint = aslrMmapBase(),
        .fds = [_]?*vfs.FileDescription{null} ** fd_table.MAX_FDS,
        .cwd = [_]u8{0} ** 256,
        .cwd_len = 1,
        .capabilities = capability.CAP_ALL, // Boot processes get all capabilities
    };

    registerPid(pid, idx);

    fd_table.initStdio(&processes[idx].?.fds);
    processes[idx].?.cwd[0] = '/';

    // Set up VMAs for ELF segments, stack, and heap
    var proc_ptr = &(processes[idx].?);
    vma.initVmaList(&proc_ptr.vmas);
    // Code VMA covers the entire ELF load region
    _ = vma.addVma(&proc_ptr.vmas, USER_CODE_BASE, elf_info.highest_addr, vma.VMA_READ | vma.VMA_EXEC | vma.VMA_USER);
    if (vma.addVma(&proc_ptr.vmas, USER_STACK_TOP - USER_STACK_VMA_PAGES * types.PAGE_SIZE, USER_STACK_TOP + types.PAGE_SIZE, vma.VMA_READ | vma.VMA_WRITE | vma.VMA_USER)) |stack_vma| {
        stack_vma.guard_pages = 1; // Stack overflow guard page at bottom
    }
    _ = vma.addVma(&proc_ptr.vmas, heap_start, heap_start, vma.VMA_READ | vma.VMA_WRITE | vma.VMA_USER);

    return proc_ptr;
}

fn writeU64(ptr: [*]u8, val: u64) void {
    var v = val;
    for (0..8) |i| {
        ptr[i] = @truncate(v);
        v >>= 8;
    }
}

pub fn getProcess(idx: usize) ?*Process {
    if (idx >= MAX_PROCESSES) return null;
    if (!slot_in_use[idx]) return null;
    return &(processes[idx].?);
}

/// Clear a process slot (used by wait4 to reap zombies).
pub fn clearSlot(idx: usize) void {
    if (idx < MAX_PROCESSES) {
        // Unregister PID from hash table before clearing
        if (slot_in_use[idx]) {
            if (processes[idx]) |p| {
                unregisterPid(p.pid);
            }
        }
        slot_in_use[idx] = false;
        // NOTE: Do NOT write `processes[idx] = null` here.
        // ?Process is ~10 KiB. In debug mode, Zig creates a null value on
        // the stack then copies it — overflowing the 32 KiB kernel stack.
        // The HHDM has no guard pages, so the overflow silently corrupts
        // whatever physical page is adjacent to the stack (e.g. a PML4).
        // slot_in_use[idx] = false is the authoritative "slot empty" check.

        // Return to free list
        free_next[idx] = free_head;
        free_head = idx;
    }
}

pub fn findFreeSlot() ?usize {
    const flags = proc_lock.acquire();
    defer proc_lock.release(flags);
    if (!free_list_initialized) initProcessTable();

    // O(1) free list pop
    if (free_head) |idx| {
        free_head = free_next[idx];
        free_next[idx] = null;
        return idx;
    }
    return null;
}

/// Allocate the next PID and increment the counter.
pub fn allocPid() types.ProcessId {
    const pid = next_pid;
    next_pid += 1;
    return pid;
}

/// Insert a process into a specific slot and return a pointer to it.
pub fn setSlot(idx: usize, proc: Process) *Process {
    processes[idx] = proc;
    slot_in_use[idx] = true;
    registerPid(proc.pid, idx);
    return &(processes[idx].?);
}

/// Initialize a process slot with default values and return a mutable pointer.
/// Use this to build the Process in-place (avoids putting ~3.6 KiB on the stack).
pub fn initSlot(idx: usize) *Process {
    slot_in_use[idx] = true;
    processes[idx] = Process{
        .pid = 0,
        .tgid = 0,
        .pgid = 0,
        .state = .ready,
        .page_table = 0,
        .kernel_stack_phys = 0,
        .kernel_stack_top = 0,
        .context = .{},
        .heap_start = 0,
        .heap_current = 0,
        .fds = [_]?*vfs.FileDescription{null} ** fd_table.MAX_FDS,
        .cwd = [_]u8{0} ** 256,
        .cwd_len = 0,
    };
    return &(processes[idx].?);
}

fn zeroPage(phys: types.PhysAddr) void {
    const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    for (0..types.PAGE_SIZE) |i| {
        ptr[i] = 0;
    }
}
