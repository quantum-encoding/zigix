/// Clone syscall — creates threads (CLONE_VM) or fork (no CLONE_VM with CoW).
///
/// Thread: shares parent PML4, new kernel stack, new TID.
/// Fork: new PML4 with CoW copies of user pages. Parent and child share
///   physical pages read-only; first write triggers CoW in fault.zig.

const types = @import("../types.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const vmm = @import("../mm/vmm.zig");
const vma = @import("../mm/vma.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const errno = @import("errno.zig");
const fd_table = @import("../fs/fd_table.zig");
const vfs = @import("../fs/vfs.zig");
const fault = @import("../mm/fault.zig");

// Clone flags (Linux ABI)
const CLONE_VM: u64 = 0x00000100;
const CLONE_FS: u64 = 0x00000200;
const CLONE_FILES: u64 = 0x00000400;
const CLONE_SIGHAND: u64 = 0x00000800;
const CLONE_THREAD: u64 = 0x00010000;
const CLONE_SETTLS: u64 = 0x00080000;
const CLONE_PARENT_SETTID: u64 = 0x00100000;
const CLONE_CHILD_CLEARTID: u64 = 0x00200000;

const CLONE_VFORK: u64 = 0x00004000;

/// Syscall 56: clone(flags, child_stack)
pub fn sysClone(frame: *idt.InterruptFrame) void {
    const flags = frame.rdi;
    const child_stack = frame.rsi;

    const parent = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (flags & CLONE_VM != 0 and flags & CLONE_THREAD != 0) {
        // True threads (CLONE_VM|CLONE_THREAD) — share address space
        cloneThread(frame, parent, flags, child_stack);
    } else {
        // Regular fork OR posix_spawn (CLONE_VM without CLONE_THREAD).
        cloneFork(frame, parent, child_stack);
    }

    // CLONE_VFORK: block parent until child calls execve or _exit.
    // musl's posix_spawn uses clone(CLONE_VM|CLONE_VFORK|SIGCHLD, stack).
    // Without this, parent and child race — child's musl init between
    // clone-return and execve modifies shared globals (signal state,
    // errno) corrupting the parent's data.
    if (flags & CLONE_VFORK != 0 and @as(i64, @bitCast(frame.rax)) > 0) {
        // frame.rax has the child PID (positive = parent)
        parent.vfork_blocked = true;
        parent.state = .blocked;
        scheduler.blockAndSchedule(frame);
    }
}

/// Thread creation: shares parent address space.
/// Initializes directly in global process table to avoid stack overflow.
fn cloneThread(frame: *idt.InterruptFrame, parent: *process.Process, flags: u64, child_stack: u64) void {
    if (child_stack == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const idx = process.findFreeSlot() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    };

    const kstack_phys = pmm.allocPagesGuarded(process.KERNEL_STACK_PAGES, pmm.ROWHAMMER_GUARD_PAGES) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    };
    const kstack_virt = hhdm.physToVirt(kstack_phys);
    const kstack_top = kstack_virt + process.KERNEL_STACK_PAGES * types.PAGE_SIZE;

    // Write stack canary at the bottom of the kernel stack
    const canary_ptr: *u64 = @ptrFromInt(kstack_virt);
    canary_ptr.* = pmm.STACK_CANARY;

    const child_tid = process.allocPid();
    const child = process.initSlot(idx);

    child.pid = child_tid;
    child.tgid = if (flags & CLONE_THREAD != 0) parent.tgid else child_tid;
    child.pgid = parent.pgid;
    // NOTE: state set to .ready AFTER all fields initialized (see below)
    child.page_table = parent.page_table; // CLONE_VM: share address space
    child.kernel_stack_phys = kstack_phys;
    child.kernel_stack_top = kstack_top;
    child.kernel_stack_guard = @intCast(pmm.ROWHAMMER_GUARD_PAGES);
    child.heap_start = parent.heap_start;
    child.heap_current = parent.heap_current;
    child.mmap_hint = parent.mmap_hint;
    child.fds = parent.fds;
    // Increment ref_counts on inherited file descriptions.
    // Without this, child exit closes fds → ref drops to 0 → fd released
    // while parent still holds the reference → use-after-free / pool drain.
    for (0..fd_table.MAX_FDS) |i| {
        if (child.fds[i]) |desc| {
            if (desc.ref_count < 255) {
                desc.ref_count += 1;
            }
        }
    }
    child.cwd = parent.cwd;
    child.cwd_len = parent.cwd_len;
    child.parent_pid = parent.pid;
    child.vmas = parent.vmas;
    child.uid = parent.uid;
    child.gid = parent.gid;
    child.euid = parent.euid;
    child.egid = parent.egid;
    child.capabilities = parent.capabilities; // Zee eBPF: inherit capabilities on fork

    child.context = .{
        .r15 = frame.r15,
        .r14 = frame.r14,
        .r13 = frame.r13,
        .r12 = frame.r12,
        .r11 = frame.r11,
        .r10 = frame.r10,
        .r9 = frame.r9,
        .r8 = frame.r8,
        .rbp = frame.rbp,
        .rdi = frame.rdi,
        .rsi = frame.rsi,
        .rdx = frame.rdx,
        .rcx = frame.rcx,
        .rbx = frame.rbx,
        .rax = 0, // Child gets 0
        .rip = frame.rip,
        .cs = frame.cs,
        .rflags = frame.rflags,
        .rsp = child_stack,
        .ss = frame.ss,
    };

    // CLONE_SETTLS: set TLS base for the child thread
    if (flags & CLONE_SETTLS != 0) {
        child.fs_base = frame.r8;
    }

    // CLONE_CHILD_CLEARTID: kernel clears *ctid and futex-wakes on thread exit
    if (flags & CLONE_CHILD_CLEARTID != 0) {
        child.clear_child_tid = frame.r10;
    }

    // CLONE_PARENT_SETTID: write child TID to *ptid in parent's address space
    if (flags & CLONE_PARENT_SETTID != 0) {
        const ptid_addr = frame.rdx;
        if (ptid_addr != 0) {
            if (vmm.translate(parent.page_table, ptid_addr)) |phys| {
                const ptr: *u32 = @ptrFromInt(hhdm.physToVirt(phys));
                ptr.* = @truncate(child_tid);
            }
        }
    }

    process.registerPid(child_tid, idx);

    // Mark child as ready ONLY after all fields are initialized
    child.state = .ready;

    serial.writeString("[clone] PID ");
    writeDecimal(parent.pid);
    serial.writeString(" -> TID ");
    writeDecimal(child_tid);
    serial.writeString(" (CLONE_VM");
    if (flags & CLONE_THREAD != 0) serial.writeString("|CLONE_THREAD");
    if (flags & CLONE_SETTLS != 0) serial.writeString("|CLONE_SETTLS");
    if (flags & CLONE_CHILD_CLEARTID != 0) serial.writeString("|CLONE_CHILD_CLEARTID");
    serial.writeString(")\n");

    frame.rax = child_tid;
}

/// Fork: create a new process with CoW copies of user pages.
/// NOTE: Process struct is ~3.6 KiB — we initialize directly in the global
/// process table (via initSlot) to avoid kernel stack overflow on 16 KiB stacks.
fn cloneFork(frame: *idt.InterruptFrame, parent: *process.Process, child_stack: u64) void {
    const idx = process.findFreeSlot() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    };

    // 1. Allocate kernel stack for child
    const kstack_phys = pmm.allocPages(process.KERNEL_STACK_PAGES) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    };
    const kstack_virt = hhdm.physToVirt(kstack_phys);
    const kstack_top = kstack_virt + process.KERNEL_STACK_PAGES * types.PAGE_SIZE;

    // Write stack canary at the bottom of the kernel stack
    const canary_ptr: *u64 = @ptrFromInt(kstack_virt);
    canary_ptr.* = pmm.STACK_CANARY;

    // 2. Create new address space (shares kernel half, empty user half)
    const child_pml4 = vmm.createAddressSpace() catch {
        var p: u64 = 0;
        while (p < process.KERNEL_STACK_PAGES) : (p += 1) {
            pmm.freePage(kstack_phys + p * types.PAGE_SIZE);
        }
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    };

    // 3. Copy user pages with CoW — walk parent's PML4 entries 0-255
    if (!cowCopyUserPages(parent.page_table, child_pml4)) {
        vmm.destroyAddressSpace(child_pml4);
        var p: u64 = 0;
        while (p < process.KERNEL_STACK_PAGES) : (p += 1) {
            pmm.freePage(kstack_phys + p * types.PAGE_SIZE);
        }
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    }

    // 4. Build child process directly in the global process table (no stack copy)
    const child_pid = process.allocPid();
    const child = process.initSlot(idx);

    child.pid = child_pid;
    child.tgid = child_pid; // New process group (not a thread)
    child.pgid = parent.pgid; // Inherit parent's process group
    // NOTE: state set to .ready AFTER all fields are initialized (below)
    child.page_table = child_pml4;
    child.kernel_stack_phys = kstack_phys;
    child.kernel_stack_top = kstack_top;
    child.heap_start = parent.heap_start;
    child.heap_current = parent.heap_current;
    child.mmap_hint = parent.mmap_hint;
    child.cwd = parent.cwd;
    child.cwd_len = parent.cwd_len;
    child.parent_pid = parent.pid;
    child.vmas = parent.vmas;
    child.uid = parent.uid;
    child.gid = parent.gid;
    child.euid = parent.euid;
    child.egid = parent.egid;
    child.capabilities = parent.capabilities; // Zee eBPF: inherit capabilities on fork
    child.fs_base = parent.fs_base; // Inherit TLS pointer for context switch restore

    // Context: same as parent but rax=0, same RSP (CoW handles writes)
    child.context = .{
        .r15 = frame.r15,
        .r14 = frame.r14,
        .r13 = frame.r13,
        .r12 = frame.r12,
        .r11 = frame.r11,
        .r10 = frame.r10,
        .r9 = frame.r9,
        .r8 = frame.r8,
        .rbp = frame.rbp,
        .rdi = frame.rdi,
        .rsi = frame.rsi,
        .rdx = frame.rdx,
        .rcx = frame.rcx,
        .rbx = frame.rbx,
        .rax = 0, // Child fork() returns 0
        .rip = frame.rip,
        .cs = frame.cs,
        .rflags = frame.rflags,
        .rsp = if (child_stack != 0) child_stack else frame.rsp,
        .ss = frame.ss,
    };

    // Copy fd table with refcount increments
    child.fds = parent.fds;
    for (0..fd_table.MAX_FDS) |i| {
        if (child.fds[i]) |desc| {
            if (desc.ref_count < 255) {
                desc.ref_count += 1;
            }
        }
    }

    // Copy signal state
    child.sig_actions = parent.sig_actions;
    child.sig_mask = parent.sig_mask;
    child.sig_pending = 0; // Pending signals are not inherited

    process.registerPid(child_pid, idx);

    // Mark child as ready ONLY after all fields are initialized.
    // Without this, the scheduler could pick up the child between
    // initSlot (which zeros VMAs) and the VMA copy, causing the
    // child to run with empty VMAs → SIGSEGV on first TLS access.
    child.state = .ready;

    // Parent returns child PID
    frame.rax = child_pid;
}

/// Walk parent's user page tables and create CoW mappings in child.
/// For each present leaf page:
///   - Mark parent PTE read-only + CoW bit
///   - Create matching read-only + CoW PTE in child
///   - Increment physical page ref count
/// Returns false on OOM (child address space may be partially filled).
fn cowCopyUserPages(parent_pml4: types.PhysAddr, child_pml4: types.PhysAddr) bool {
    // Acquire page table lock — prevents CoW fault handler on other CPUs from
    // modifying PTEs that we're about to mark as read-only+CoW.
    const lock_flags = fault.pt_lock.acquire();
    defer fault.pt_lock.release(lock_flags);

    const parent_pml4_tbl: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, parent_pml4);
    const child_pml4_tbl: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, child_pml4);
    const max_phys = pmm.getHighestPhys();

    // Walk user half only (PML4 entries 0-255)
    // CRITICAL: Pin parent's intermediate page table pages before any allocation.
    // Without pinning, cowCopyUserPages allocates child pages from the PMM, which
    // may trigger PMM to reclaim recently-freed pages. If a parent's PD/PT page
    // was freed by a previous child's destroyAddressSpace (ref counting error),
    // it could be reused mid-walk, corrupting the parent's page tables.
    // Pinning (incRef) ensures parent's pages survive the entire fork.
    for (0..256) |pin_idx| {
        if (!parent_pml4_tbl.entries[pin_idx].isPresent()) continue;
        const pin_pdpt = parent_pml4_tbl.entries[pin_idx].getPhysAddr();
        if (pin_pdpt == 0 or pin_pdpt >= max_phys) continue;
        pmm.incRef(pin_pdpt); // Pin parent PDPT
        const pin_pdpt_tbl: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, pin_pdpt);
        for (0..512) |pin_pdpt_idx| {
            if (!pin_pdpt_tbl.entries[pin_pdpt_idx].isPresent()) continue;
            if (pin_pdpt_tbl.entries[pin_pdpt_idx].huge_page) continue;
            const pin_pd = pin_pdpt_tbl.entries[pin_pdpt_idx].getPhysAddr();
            if (pin_pd == 0 or pin_pd >= max_phys) continue;
            pmm.incRef(pin_pd); // Pin parent PD
            const pin_pd_tbl: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, pin_pd);
            for (0..512) |pin_pd_idx| {
                if (!pin_pd_tbl.entries[pin_pd_idx].isPresent()) continue;
                if (pin_pd_tbl.entries[pin_pd_idx].huge_page) continue;
                const pin_pt = pin_pd_tbl.entries[pin_pd_idx].getPhysAddr();
                if (pin_pt == 0 or pin_pt >= max_phys) continue;
                pmm.incRef(pin_pt); // Pin parent PT
            }
        }
    }

    for (0..256) |pml4_idx| {
        if (!parent_pml4_tbl.entries[pml4_idx].isPresent()) continue;
        const parent_pdpt_phys = parent_pml4_tbl.entries[pml4_idx].getPhysAddr();
        if (parent_pdpt_phys == 0 or parent_pdpt_phys >= max_phys) continue;

        // Allocate child PDPT (double-ref for page table pages)
        const child_pdpt_phys = pmm.allocPage() orelse return false;
        pmm.incRef(child_pdpt_phys);
        zeroPageTable(child_pdpt_phys);
        // Two-step memory write: avoids Zig 0.16 packed struct codegen bug
        child_pml4_tbl.entries[pml4_idx] = .{ .present = true, .writable = true, .user = true };
        child_pml4_tbl.entries[pml4_idx].setPhysAddr(child_pdpt_phys);

        const parent_pdpt: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, parent_pdpt_phys);
        const child_pdpt: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, child_pdpt_phys);

        for (0..512) |pdpt_idx| {
            if (!parent_pdpt.entries[pdpt_idx].isPresent()) continue;
            if (parent_pdpt.entries[pdpt_idx].huge_page) continue; // Skip 1GiB pages

            const parent_pd_phys = parent_pdpt.entries[pdpt_idx].getPhysAddr();
            if (parent_pd_phys == 0 or parent_pd_phys >= max_phys) continue;

            // Allocate child PD (double-ref for page table pages)
            const child_pd_phys = pmm.allocPage() orelse return false;
            pmm.incRef(child_pd_phys);
            zeroPageTable(child_pd_phys);
            // Two-step memory write: avoids Zig 0.16 packed struct codegen bug
            child_pdpt.entries[pdpt_idx] = .{ .present = true, .writable = true, .user = true };
            child_pdpt.entries[pdpt_idx].setPhysAddr(child_pd_phys);

            const parent_pd: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, parent_pd_phys);
            const child_pd: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, child_pd_phys);

            for (0..512) |pd_idx| {
                if (!parent_pd.entries[pd_idx].isPresent()) continue;
                if (parent_pd.entries[pd_idx].huge_page) continue; // Skip 2MiB pages

                const parent_pt_phys = parent_pd.entries[pd_idx].getPhysAddr();
                if (parent_pt_phys == 0 or parent_pt_phys >= max_phys) {
                    serial.writeString("[cow] BUG: bad PT phys=0x");
                    writeHex(parent_pt_phys);
                    serial.writeString(" pd_idx=");
                    writeDecimal(pd_idx);
                    serial.writeString(" raw=0x");
                    writeHex(@as(u64, @bitCast(parent_pd.entries[pd_idx])));
                    serial.writeString(" PD_page=0x");
                    writeHex(parent_pd_phys);
                    serial.writeString(" PD_ref=");
                    writeDecimal(pmm.getRef(parent_pd_phys));
                    serial.writeString("\n");
                    continue;
                }

                // Allocate child PT (double-ref for page table pages)
                const child_pt_phys = pmm.allocPage() orelse return false;
                pmm.incRef(child_pt_phys);
                zeroPageTable(child_pt_phys);
                // Two-step memory write: avoids Zig 0.16 packed struct codegen bug
                child_pd.entries[pd_idx] = .{ .present = true, .writable = true, .user = true };
                child_pd.entries[pd_idx].setPhysAddr(child_pt_phys);

                const parent_pt: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, parent_pt_phys);
                const child_pt: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, child_pt_phys);

                for (0..512) |pt_idx| {
                    if (!parent_pt.entries[pt_idx].isPresent()) continue;

                    const phys = parent_pt.entries[pt_idx].getPhysAddr();
                    if (phys == 0 or phys >= max_phys) continue; // Skip corrupted leaf PTEs

                    // Mark parent PTE as read-only + CoW using atomic u64 write.
                    // Avoids multiple separate packed struct field modifications
                    // through a pointer, which can corrupt phys_frame in Zig 0.16.
                    var raw: u64 = @bitCast(parent_pt.entries[pt_idx]);
                    raw &= ~@as(u64, 2); // Clear writable (bit 1)
                    raw |= @as(u64, 1) << 9; // Set CoW in os_bits (bit 9)
                    parent_pt.entries[pt_idx] = @bitCast(raw);

                    // Create child PTE: copy parent flags (now read-only + CoW)
                    child_pt.entries[pt_idx] = parent_pt.entries[pt_idx];

                    // Increment ref count for the shared page
                    pmm.incRef(phys);

                    // Invalidate parent TLB entry for this page
                    const virt = (@as(u64, pml4_idx) << 39) |
                        (@as(u64, pdpt_idx) << 30) |
                        (@as(u64, pd_idx) << 21) |
                        (@as(u64, pt_idx) << 12);
                    vmm.invlpg(virt);
                }
            }
        }
    }

    // Unpin parent's intermediate page table pages
    for (0..256) |unpin_idx| {
        if (!parent_pml4_tbl.entries[unpin_idx].isPresent()) continue;
        const unpin_pdpt = parent_pml4_tbl.entries[unpin_idx].getPhysAddr();
        if (unpin_pdpt == 0 or unpin_pdpt >= max_phys) continue;
        const unpin_pdpt_tbl: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, unpin_pdpt);
        for (0..512) |unpin_pdpt_idx| {
            if (!unpin_pdpt_tbl.entries[unpin_pdpt_idx].isPresent()) continue;
            if (unpin_pdpt_tbl.entries[unpin_pdpt_idx].huge_page) continue;
            const unpin_pd = unpin_pdpt_tbl.entries[unpin_pdpt_idx].getPhysAddr();
            if (unpin_pd == 0 or unpin_pd >= max_phys) continue;
            const unpin_pd_tbl: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, unpin_pd);
            for (0..512) |unpin_pd_idx| {
                if (!unpin_pd_tbl.entries[unpin_pd_idx].isPresent()) continue;
                if (unpin_pd_tbl.entries[unpin_pd_idx].huge_page) continue;
                const unpin_pt = unpin_pd_tbl.entries[unpin_pd_idx].getPhysAddr();
                if (unpin_pt == 0 or unpin_pt >= max_phys) continue;
                _ = pmm.decRef(unpin_pt); // Unpin parent PT
            }
            _ = pmm.decRef(unpin_pd); // Unpin parent PD
        }
        _ = pmm.decRef(unpin_pdpt); // Unpin parent PDPT
    }

    return true;
}

fn zeroPageTable(phys: types.PhysAddr) void {
    const table: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, phys);
    for (0..512) |i| {
        table.entries[i] = .{};
    }
}

// --- Output helpers ---

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}

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
