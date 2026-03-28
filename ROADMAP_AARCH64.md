# Zigix ARM64 Roadmap: From Boot to Parity

Comprehensive implementation plan for the ARM64 (aarch64) port of Zigix. The goal is to reach feature parity with the x86_64 kernel, then leverage ARM64's unique advantages.

---

## Current Status (Feb 2026)

| Component | Status | Notes |
|-----------|--------|-------|
| boot.zig | ✅ Complete | Entry, stack, BSS clear, kmain, FDT integration, SMP secondary boot |
| fdt.zig | ✅ Complete | Flattened Device Tree parser (memory, UART, GIC, CPU discovery) |
| uart.zig | ✅ Complete | PL011 UART with custom print(), SMP-safe (IrqSpinlock TX/RX) |
| exception.zig | ✅ Complete | Vector table (2KB aligned), sync/IRQ handlers, demand paging for stale kernel PTEs, full SIMD/FP save/restore (v0-v31, FPCR, FPSR) |
| gic.zig | ✅ Complete | GICv2 distributor + CPU interface, split init, SGI IPI support |
| timer.zig | ✅ Complete | ARM Generic Timer at 100Hz, per-CPU ticks, atomic global counter |
| mmu.zig | ✅ Complete | Early 1GB block mappings, MMU enabled |
| pmm.zig | ✅ Complete | Bitmap allocator with ref counts, 2MB hugepages, SMP-safe (IrqSpinlock) |
| vmm.zig | ✅ Complete | Per-process L1, L0[0] destroy/fork with CoW, hugepage L2 block mapping |
| process.zig | ✅ Complete | Process struct, context, wake_tick, mmap_hint, cpu_id, SMP-safe (IrqSpinlock) |
| scheduler.zig | ✅ Complete | Round-robin preemptive + SCHED_DEDICATED, per-CPU state, IPI wakeup, SMP-safe |
| syscall.zig | ✅ Complete | 102 syscalls defined (75+ implemented), MAP_SHARED write-back, exit_group, thread-safe exit |
| spinlock.zig | ✅ Complete | Spinlock (cmpxchgWeak + WFE/SEV) + IrqSpinlock (DAIF save/restore) |
| smp.zig | ✅ Complete | Per-CPU state (TPIDR_EL1), PSCI CPU_ON boot, secondary entry/init |
| epoll.zig | ✅ Complete | epoll_create1/ctl/wait, level-triggered, SMP-safe (IrqSpinlock) |
| FP/SIMD | ✅ Complete | CPACR_EL1.FPEN set, full v0-v31 + FPCR/FPSR save/restore in exception handler |
| vfs.zig | ✅ Complete | Full VFS with mount table, path resolution, SMP-safe (IrqSpinlock) |
| ramfs.zig | ✅ Complete | In-memory filesystem, 4MB/file, 256 nodes, SMP-safe (IrqSpinlock) |
| fd_table.zig | ✅ Complete | Per-process file descriptors (256 max), UART I/O backend, dup/dup2 |
| elf.zig | ✅ Complete | Streaming ELF loader, 152MB Zig compiler + self-compiled 3.6MB binaries |
| virtio_mmio.zig | ✅ Complete | VirtIO MMIO transport, virtqueue management |
| virtio_blk.zig | ✅ Complete | Block device via virtio-mmio |
| ext2.zig | ✅ Complete | Full ext2 read-write, double-indirect blocks, rename, SMP-safe (IrqSpinlock) |
| vma.zig | ✅ Complete | VMA tracking, demand paging, file-backed mmap, mprotect with splitForProtect, 8192 VMAs |
| CoW (fork) | ✅ Complete | Deep-copy forkAddressSpace with per-process L1, handleCowFault |
| mmap/munmap | ✅ Complete | Anonymous + file-backed + MAP_SHARED write-back, per-process mmap_hint |
| mremap | ✅ Complete | Shrink/grow/move with MAYMOVE, CoW-aware |
| wait4 | ✅ Complete | Reap zombie children, block-on-wait |
| pipe.zig | ✅ Complete | 4KB ring buffer, VFS-integrated, SMP-safe (IrqSpinlock, wake-outside-lock) |
| futex.zig | ✅ Complete | FUTEX_WAIT/WAKE, physical address matching, SMP-safe (IrqSpinlock) |
| signal.zig | ✅ Complete | Signal delivery, rt_sigaction, rt_sigreturn, trampoline |
| Threads | ✅ Complete | CLONE_VM/SETTLS/PARENT_SETTID/CHILD_CLEARTID, pthread lifecycle, exit_group |
| virtio_net.zig | ✅ Complete | VirtIO MMIO net driver, RX/TX virtqueues, IRQ handling |
| ethernet.zig | ✅ Complete | Frame parsing/building, byte-swap helpers |
| arp.zig | ✅ Complete | ARP table, request/reply, blocking resolve |
| ipv4.zig | ✅ Complete | IPv4 parse/send, SLIRP defaults (10.0.2.15) |
| icmp.zig | ✅ Complete | Echo request/reply, boot ping |
| udp.zig | ✅ Complete | Stateless datagram send/receive |
| tcp.zig | ✅ Complete | Full TCP state machine, listen/accept, SMP-safe (IrqSpinlock, wake-outside-lock) |
| socket.zig | ✅ Complete | Socket abstraction, VFS integration, 32-socket pool, SMP-safe (IrqSpinlock) |
| net.zig | ✅ Complete | Network init and polling dispatcher (CPU 0 only for NIC safety) |
| checksum.zig | ✅ Complete | RFC 1071 internet checksum |
| net_ring.zig | ✅ Complete | Zero-copy shared ring (64 bufs, 256-entry SPSC ring, DMB barriers) |

**Kernel size:** ~17,400 lines of Zig across 37 source files
**Userspace:** ~4,500 lines across 9 programs + shared lib (all dual-arch x86_64/aarch64)
**Boot time:** <1 second to user process execution
**RAM usage:** ~350KB kernel + metadata, ~1.6GB free with 2GB RAM
**SMP:** 2-4 CPUs via QEMU `-smp N`, PSCI boot, per-CPU scheduling
**Syscalls:** 102 defined (75+ fully implemented, ~12 stubs, 4 custom)
**Test:** Full boot-to-HTTP verified with SMP — zinit→zhttpd+zlogin on 2 CPUs, curl returns HTML from ext2 over TCP
**Self-hosting:** `zig build-exe hello.zig` compiles AND runs on Zigix ARM64 — "Hello from Zigix!" printed
**Zig compiler:** 152MB static musl binary, demand-paged, multithreaded compilation with musl pthread

---

## Phase 1: Memory Management (A1-A3)

### A1: Full 4-Level Page Tables ✅ (Early mapping done)

**Goal:** Replace 1GB block mappings with proper 4-level page tables (L0→L1→L2→L3) using 4KB pages.

**Status:** Early init complete. Full VMM with allocPage callback pending.

**Why:** 1GB blocks work for early boot but prevent fine-grained memory protection. Need 4KB pages for:
- User/kernel separation
- Copy-on-Write (CoW)
- Demand paging
- Memory-mapped files

**Implementation:**
- `mmu.init(pmm_alloc)` — allocate page tables from PMM
- `mmu.mapPage(l0, virt, phys, flags)` — walk/create 4-level tables
- `mmu.unmapPage(l0, virt)` — clear entry, invalidate TLB
- `mmu.translate(l0, virt)` — walk tables, return physical address
- `mmu.switchAddressSpace(l0)` — write TTBR0_EL1

**ARM64-specific considerations:**
- TTBR0_EL1 for user space (low addresses)
- TTBR1_EL1 for kernel space (high addresses) — optional, can use single TTBR
- AF (Access Flag) must be set or hardware will fault
- AP[2:1] bits for permissions (unlike x86's separate R/W/X bits)

---

### A2: Virtual Memory Manager ✅

**Goal:** Port x86_64 VMM design to ARM64. Manage kernel and user address spaces.

**Depends on:** A1 (full page tables)

**Implementation:**

Port `kernel/mm/vmm.zig` concepts:
- `createAddressSpace()` — allocate L0, return handle
- `destroyAddressSpace()` — free all page tables and mapped pages
- `mapRange(virt, phys, size, flags)` — batch mapping
- `unmapRange(virt, size)` — batch unmapping
- HHDM (Higher Half Direct Map) or identity mapping for kernel

**Memory layout:**
```
0x0000_0000_0000_0000 - 0x0000_7FFF_FFFF_FFFF : User space (128 TB)
0xFFFF_0000_0000_0000 - 0xFFFF_FFFF_FFFF_FFFF : Kernel space (optional)
```

For simplicity, start with identity mapping (kernel uses physical addresses directly).

---

### A3: Higher Half Direct Map (HHDM) ✅ (Using identity mapping)

**Goal:** Map all physical memory at a fixed virtual offset for easy kernel access.

**Depends on:** A2 (VMM)

**Status:** Using identity mapping (phys == virt) instead of HHDM offset. This is simpler for QEMU virt and works because we control the entire address space. All kernel code accesses physical addresses directly.

---

## Phase 2: Process Management (A4-A7)

### A4: Process Structure ✅

**Goal:** Port x86_64 process subsystem to ARM64.

**Depends on:** A2 (VMM for per-process address spaces)

**Implementation:**

Port `kernel/proc/process.zig`:
```zig
const Process = struct {
    pid: u64,
    state: State,
    page_table: *PageTable,  // L0 pointer (ARM64)
    context: Context,        // Saved registers
    kernel_stack: u64,
    fd_table: [32]?*FileDescription,
    // ... same as x86_64
};

const Context = extern struct {
    x: [31]u64,     // X0-X30
    sp: u64,        // Stack pointer
    pc: u64,        // ELR_EL1 (return address)
    pstate: u64,    // SPSR_EL1
};
```

---

### A5: Context Switch ✅

**Goal:** Save/restore process state for preemptive multitasking.

**Depends on:** A4 (Process structure)

**Implementation:**

ARM64 context switch is cleaner than x86_64:
```zig
pub fn switchTo(old: *Process, new: *Process) void {
    // Save old context
    saveContext(&old.context);

    // Switch page table
    asm volatile ("msr TTBR0_EL1, %[ttbr]"
        :: [ttbr] "r" (@intFromPtr(new.page_table)));
    asm volatile ("isb");

    // Invalidate TLB
    asm volatile ("tlbi vmalle1is");
    asm volatile ("dsb sy");
    asm volatile ("isb");

    // Restore new context
    restoreContext(&new.context);
}
```

**Key differences from x86_64:**
- No TSS (Task State Segment) — ARM64 uses SP_EL1 directly
- No segment registers (CS, DS, etc.)
- Simpler register set (X0-X30 vs RAX-R15 + segments)

---

### A6: Scheduler ✅

**Goal:** Port round-robin scheduler with priority support.

**Depends on:** A5 (context switch)

**Implementation:**

Port `kernel/proc/scheduler.zig`:
- Process queue
- Timer interrupt calls `schedulerTick()`
- Priority levels
- Blocked states (I/O, pipe, futex)

**ARM64-specific:**
- Timer interrupt via GIC (IRQ 30)
- Context saved in TrapFrame on exception entry
- Return via `eret` instruction

---

### A7: Syscall Entry ✅

**Goal:** Handle `SVC #0` instruction for system calls.

**Depends on:** A4 (processes)

**Implementation:**

ARM64 uses `SVC` (Supervisor Call) instead of x86's `syscall`:
```zig
// In exception.zig handleSyncException
.svc_aarch64 => {
    // X8 = syscall number (Linux ABI)
    // X0-X5 = arguments
    // Return value goes in X0
    const result = syscall_table.dispatch(
        frame.x[8],  // syscall number
        .{ frame.x[0], frame.x[1], frame.x[2], frame.x[3], frame.x[4], frame.x[5] }
    );
    frame.x[0] = result;
}
```

**Syscall numbers:** Use Linux AArch64 numbers (different from x86_64!):
| Syscall | x86_64 | AArch64 |
|---------|--------|---------|
| read | 0 | 63 |
| write | 1 | 64 |
| open | 2 | -1 (use openat) |
| openat | 257 | 56 |
| close | 3 | 57 |
| exit | 60 | 93 |
| clone | 56 | 220 |
| mmap | 9 | 222 |

**Decision:** Support both Linux x86_64 and AArch64 syscall numbers, or pick one consistently. Recommendation: Use Linux AArch64 numbers since we're on ARM64.

---

## Phase 3: Filesystem & I/O (A8-A11)

### A8: VFS + ramfs ✅

**Goal:** Port Virtual Filesystem Switch and in-memory filesystem.

**Depends on:** A4 (processes for fd_table)

**Implementation:**

Port from x86_64 with zero changes:
- `kernel/fs/vfs.zig` — FileOperations, Inode, FileDescription
- `kernel/fs/ramfs.zig` — in-memory filesystem
- `kernel/fs/fd_table.zig` — per-process file descriptors

These are architecture-independent.

---

### A9: ELF Loader ✅ (EM_AARCH64, identity mapping)

**Goal:** Load AArch64 ELF binaries.

**Depends on:** A8 (VFS for reading files), A2 (VMM for mapping)

**Implementation:**

Port `kernel/proc/elf.zig`:
- Change `EM_X86_64` (62) to `EM_AARCH64` (183)
- Page table mapping uses ARM64 flags
- Entry point goes into process context PC field

**Cross-compile userspace:**
```bash
zig build -Dtarget=aarch64-linux-musl
```

---

### A10: virtio-blk Driver ✅ (MMIO transport)

**Goal:** Read/write disk sectors via virtio block device.

**Depends on:** A2 (VMM for MMIO mapping)

**Implementation:**

virtio is MMIO-based and largely architecture-independent:
- Port `kernel/drivers/virtio.zig`
- Port `kernel/drivers/virtio_blk.zig`
- QEMU virt machine virtio region: 0x0a000000

**ARM64-specific:**
- Memory barriers: use `dmb`, `dsb` instead of x86 `mfence`
- DMA addresses: ensure pages in first 4GB if NIC requires 32-bit DMA

---

### A11: ext2 Filesystem ✅

**Goal:** Read and write ext2 filesystem.

**Depends on:** A10 (block device)

**Implementation:**

Port from x86_64 with zero changes:
- `kernel/fs/ext2.zig` — architecture-independent

---

## Phase 4: Advanced Memory (A12-A14)

### A12: Demand Paging ✅

**Goal:** Allocate pages lazily on first access via page faults.

**Depends on:** A2 (VMM), A6 (scheduler for blocked state)

**Implementation:**

ARM64 page fault handling:
- Data abort (EC=0x24/0x25) and Instruction abort (EC=0x20/0x21)
- FAR_EL1 contains faulting address
- ESR_EL1 contains fault type (translation, permission, etc.)

VMA tracking:
```zig
const VMA = struct {
    start: u64,
    end: u64,
    flags: u32,  // readable, writable, executable
    file: ?*FileDescription,
    file_offset: u64,
};
```

---

### A13: Copy-on-Write (CoW) ✅

**Goal:** Share pages between parent/child after fork, copy on write.

**Depends on:** A12 (page fault handler), PMM ref counts (done)

**Implementation:**

- `vmm.forkAddressSpace()` — walks parent's user page tables, marks writable pages as RO+PTE_COW in both parent and child, increments ref counts
- `vmm.handleCowFault()` — on permission fault with PTE_COW: if ref>1 copy page, else just remap writable
- `sysClone()` — full fork with CoW (SIGCHLD flags), creates child with duplicated context/FDs/VMAs
- `sysWait4()` — reap zombie children, block parent if no zombies yet
- `sysExit()` — wakes parent if blocked on wait4

ARM64-specific:
- PTE_COW uses software-defined bit 55
- AP[2] set for read-only (ATTR_AP_RO = 2 << 6)
- TLB invalidation via `tlbi vale1is` / `tlbi vmalle1is`

---

### A14: mmap ✅

**Goal:** Map files and anonymous memory into process address space.

**Depends on:** A12 (demand paging), A11 (ext2 for file-backed)

**Implementation:**

- `sysMmap()` — anonymous private mappings via VMA + demand paging
- `sysMunmap()` — remove VMA, unmap pages, handle CoW ref counts
- Supports MAP_ANONYMOUS | MAP_PRIVATE, MAP_FIXED
- File-backed mmap planned for future

---

## Phase 5: Threading & Signals (A15-A17)

### A15: Threads (clone + futex) ✅

**Goal:** Multiple threads sharing address space.

**Depends on:** A6 (scheduler), A2 (shared page tables)

**Implementation:**

- `clone(CLONE_VM)` — creates thread with shared page table, new kernel stack, new TID
- `clone(SIGCHLD)` — fork with CoW (copy address space)
- `clone(CLONE_VM|CLONE_THREAD)` — thread shares parent TGID
- `futex(FUTEX_WAIT)` — block if `*uaddr == val`, physical address matching
- `futex(FUTEX_WAKE)` — wake up to N waiters
- `pipe2()` — 4KB ring buffer with reader/writer counts, VFS-integrated

---

### A16: Signals ✅

**Goal:** Deliver async signals to processes (SIGINT, SIGTERM, etc.).

**Depends on:** A15 (threads for signal delivery)

**Implementation:**

- Per-process signal bitmap (64-bit), mask, and action table (32 signals)
- `kill(pid, sig)` — send signal to process
- `rt_sigaction(sig, act, oldact)` — install/query signal handlers
- `rt_sigprocmask(how, set, oldset)` — block/unblock signals
- `rt_sigreturn()` — restore context from signal frame (SYS_rt_sigreturn=139)
- SIGKILL/SIGSTOP cannot be caught, blocked, or ignored
- Signal checking on syscall return and IRQ return to userspace

ARM64 signal frame:
- Saves X0-X30 + SP_EL0 + ELR_EL1 + SPSR_EL1 (288 bytes)
- Trampoline: `MOV X8, #139; SVC #0` (rt_sigreturn)

---

### A17: TLS (Thread-Local Storage) ✅

**Goal:** Support thread-local variables via TPIDR_EL0.

**Depends on:** A15 (threads)

**Status:** Already implemented — TPIDR_EL0 saved/restored on context switch via `restoreTlsBase()` in scheduler.zig. Process struct has `tls_base` field. Cloned threads inherit parent's TLS base.

---

## Phase 6: Networking (A18-A20)

### A18: virtio-net Driver ✅

**Goal:** Ethernet frame TX/RX via virtio network device.

**Depends on:** A10 (virtio infrastructure)

**Implementation:**

Complete rewrite using MMIO transport (not PCI+I/O ports like x86_64):
- `virtio_net.zig` — MMIO-based driver with RX (queue 0) / TX (queue 1) virtqueues
- 16 pre-posted 4KB RX buffers, kernel rx_ring (32 entries) for IRQ→poll handoff
- MAC read from config space via byte-sized MMIO reads
- Added `submitToQueue()` to `virtio_mmio.zig` for multi-queue notification
- IRQ wired through GIC (SPI, dynamic IRQ from device probe)
- Network polling at 100Hz from timer interrupt

QEMU test: `qemu-system-aarch64 -M virt ... -device virtio-net-device,netdev=net0 -netdev user,id=net0`

---

### A19: TCP/IP Stack ✅

**Goal:** Full networking stack with socket syscalls.

**Depends on:** A18 (virtio-net)

**Implementation:**

Ported from x86_64 (serial→uart, idt→timer, hlt→wfi, import path changes):
- `ethernet.zig` — frame parsing/building, byte-swap helpers
- `checksum.zig` — RFC 1071 internet checksum (pure copy, no arch deps)
- `arp.zig` — ARP table (8 entries), request/reply, blocking resolve
- `ipv4.zig` — parse/send, SLIRP defaults (10.0.2.15, gw 10.0.2.2)
- `icmp.zig` — echo request/reply, boot ping with timeout
- `udp.zig` — stateless datagram send/receive
- `tcp.zig` — TCP state machine (SYN/ACK/FIN), connect/send/recv/close
- `socket.zig` — socket pool (16), VFS integration, UDP delivery
- `net.zig` — init and poll dispatcher (up to 8 packets per tick)

Socket syscalls added to `syscall.zig` (AArch64 Linux numbers):
- socket(198), bind(200), listen(201), accept(202), connect(203)
- sendto(206), recvfrom(207), shutdown(210), setsockopt(208), getsockopt(209)

Boot verification: ARP resolves gateway, ICMP ping gets reply (TTL=255).

---

### A20: Zero-Copy Networking ✅

**Goal:** Shared ring buffers for sub-microsecond packet processing.

**Depends on:** A14 (mmap for shared memory), A18 (virtio-net)

**Implementation:**

`net_ring.zig` (~280 lines) — Shared ring infrastructure:
- Contiguous physical region: 67 pages (header + RX ring + TX ring + 64×4KB buffer pool)
- Mapped into both kernel (identity) and userspace via `sys_net_attach(280)`
- SPSC (single producer, single consumer) ring protocol:
  - RX: kernel produces (rx_prod), userspace consumes (rx_cons)
  - TX: userspace produces (tx_prod), kernel consumes (tx_cons)
- ARM64 DMB barriers (ishst for store-release, ishld for load-acquire)
- Cache-line aligned indices (64 bytes) to prevent false sharing
- Ring header with magic (0x5A4E5430 "ZNT0"), version, sizes
- Kernel poll path: `reclaimRx()` + `processTx()` called from timer tick

Integration:
- `net.zig` delivers raw frames to shared ring when active
- `syscall.zig` adds `SYS_net_attach(280)` — maps shared region into process
- Kernel stack (ARP/IP/ICMP/TCP) continues to process in parallel

**ARM64 advantages:**
- Simpler memory model than x86 — DMB ISH barriers are cheap
- No IOMMU complexity (identity mapping, all RAM < 4GB)
- Load-acquire/store-release semantics native to ARM64

---

## Phase 7: Userspace (A21-A25)

### A21: Cross-Compile Userspace for AArch64 ✅

**Goal:** Port all 5 userspace programs to compile for both x86_64 and aarch64.

**Status:** Complete. All userspace programs are now architecture-portable via a shared syscall abstraction layer.

**Implementation:**
- Created `userspace/lib/sys.zig` (~368 lines) — architecture-portable syscall abstraction
  - Comptime architecture detection: `const is_aarch64 = builtin.cpu.arch == .aarch64;`
  - `NR` struct with all syscall numbers for both architectures
  - `syscall0` through `syscall6` with arch-specific inline assembly (int $0x80 vs svc #0)
  - High-level wrappers translating legacy x86_64 syscalls to *at() equivalents on aarch64:
    - `open()` → `openat(AT_FDCWD, ...)`, `pipe()` → `pipe2(..., 0)`, `dup2()` → `dup3(..., 0)`
    - `mkdir()` → `mkdirat(AT_FDCWD, ...)`, `unlink()/rmdir()` → `unlinkat(AT_FDCWD, ..., flags)`
  - 30+ wrapper functions covering all syscalls used by userspace programs
- Created `userspace/lib/linker-aarch64.ld` — aarch64 ELF linker script (base 0x400000)
- Ported all 5 programs: zinit, zsh, zgrep, zping, zcurl
  - Replaced all inline `int $0x80` / `sys_*()` wrappers with `sys.*()` module calls
  - Added comptime-branching `_start()` (naked, selects aarch64 vs x86_64 entry)
  - Updated all `build.zig` files: `-Darch` option, sys module import, linker script selection

**Build verification:**
| Program | x86_64 | aarch64 |
|---------|--------|---------|
| zinit   | 5 KB   | 66 KB   |
| zsh     | 26 KB  | 87 KB   |
| zgrep   | 5 KB   | 66 KB   |
| zping   | 5 KB   | 67 KB   |
| zcurl   | 7 KB   | 66 KB   |

---

### A22: Shell (zsh) ✅

**Goal:** Port zsh to compile for AArch64.

**Status:** Complete. Covered as part of A21 — zsh is now dual-arch.

**Details:** The shell (2,159 lines, 25+ builtins, pipes, redirection, job control, history, variable expansion, script execution) compiles and works identically on both architectures via the shared `sys` module.

---

### A23: Init System ✅

**Goal:** PID 1 that spawns shell and reaps children.

**Status:** Complete. Covered as part of A21 — zinit is now dual-arch.

**Details:** zinit spawns `/bin/zsh`, reaps orphans via `wait4(-1)`, and respawns the shell on exit. Same logic for both architectures.

---

### A24: Syscall Parity with x86_64 ✅

**Goal:** Implement all syscalls present in x86_64 that were missing on aarch64.

**Depends on:** A21 (utilities)

**Added 14 syscalls:**
| Syscall | AArch64 # | Implementation |
|---------|-----------|----------------|
| getuid | 174 | Returns process real UID |
| geteuid | 175 | Returns process effective UID |
| getgid | 176 | Returns process real GID |
| getegid | 177 | Returns process effective GID |
| setpgid | 154 | Set process group ID (self or child) |
| getpgid | 155 | Get process group ID |
| ftruncate | 46 | Truncate file to length |
| readlinkat | 78 | Read symbolic link target |
| writev | 66 | Scatter-gather write |
| sync | 81 | Flush ext2 metadata to disk |
| clock_gettime | 113 | High-resolution timer (CLOCK_REALTIME/MONOTONIC) |
| mprotect | 226 | Change memory protection (stub — accepts silently) |
| sigaltstack | 132 | Alternate signal stack (stub — return success) |
| tkill | 130 | Send signal to specific thread |

**Also upgraded:**
- `ioctl` — now handles TIOCGPGRP/TIOCSPGRP for terminal foreground process group
- `setuid/setgid` — now implements real permission logic (root can set any, non-root restricted)
- `set_tid_address` — now saves clear_child_tid for thread cleanup
- Process struct — added uid/gid/euid/egid/pgid/clear_child_tid fields
- ProcessState — added `.stopped` variant

**Status:** Complete. aarch64 now has **46 syscalls** matching x86_64's 63 handlers (the delta is legacy x86_64-only syscalls like open/pipe/dup2 which aarch64 handles via openat/pipe2/dup3, and arch_prctl which is x86_64-specific).

---

### A25: Device Tree (FDT) Parser ✅

**Goal:** Parse Flattened Device Tree blob to discover hardware at runtime, enabling boot on real ARM64 boards (not just QEMU with hardcoded addresses).

**Depends on:** A1 (boot infrastructure)

**Implementation:**
| File | Lines | Purpose |
|------|-------|---------|
| `fdt.zig` | ~400 | Complete FDT parser: header validation, structure block walker, property extraction |
| `boot.zig` | +15 | FDT integration: call parser when DTB address is non-zero, update RAM size |
| `pmm.zig` | +5 | `setRamSize()` API for FDT-discovered RAM |

**FDT parser discovers:**
- RAM regions from `/memory` nodes (base + size, up to 4 regions)
- UART base address from `arm,pl011` compatible nodes
- GIC distributor and CPU interface addresses from GIC-compatible nodes
- CPU count from `/cpus` children
- Address/size cell widths for correct property decoding

**Hardware support:**
- **QEMU virt**: Uses hardcoded defaults (X0=0 with ELF `-kernel` direct boot)
- **U-Boot**: Will pass DTB in X0 per ARM64 boot protocol — FDT parser activates automatically
- **Raspberry Pi 3/4/5**: DTB provided by VideoCore firmware via U-Boot

**Status:** Complete. Parser compiles, integrates with boot sequence, and is ready for real hardware.

---

### A26: Boot-to-Shell ✅

**Goal:** Full interactive boot sequence: zinit → zlogin → zsh with working login and shell commands.

**Depends on:** A21-A23 (userspace), A24 (syscall parity), A25 (FDT)

**Bugs found and fixed during bring-up:**

1. **EC=60 BRK flood** — Zig's freestanding `defaultPanic` emits `brk #0x1`. The exception handler returned to the same BRK, creating an infinite loop. Fixed by adding a custom panic handler (`std.debug.FullPanic`) that prints the message via UART and halts with WFI, plus a kernel-mode BRK halt in the exception handler.

2. **UART RX buffer corruption** — `rx_head` contained `0xAAAAAAAAAAAAAAAA` (Zig Debug mode's `undefined` fill pattern for `rx_buf: [256]u8 = undefined`). Despite BSS being correctly cleared in `_start`, Zig's Debug runtime re-filled `undefined` globals with 0xAA after BSS clear. Fixed by explicitly initializing `rx_head = 0; rx_tail = 0; rx_count = 0` at the start of `uart.init()`.

3. **Signal alignment panic** — `signal.readFromUser` / `writeToUser` created `*const u64` from physical addresses that weren't 8-byte aligned. Zig Debug mode's alignment safety check panicked with "incorrect alignment". Fixed by using `*align(1)` pointers for all user memory access helpers.

**Boot sequence verified:**
```
zinit (PID 1) → fork → zlogin (PID 2) → "login: root" → "Welcome, root"
→ execve /mnt/bin/zsh → "zigix$ "
```

**Shell commands working:** `help`, `ls /`, `ls /mnt/bin`, `uname` ("Zigix zigix 0.1.0 #1 SMP aarch64"), `echo`, `cat /etc/passwd`, `pwd`

**Status:** Complete.

---

### A27: Kernel Maturity ✅

**Goal:** Harden kernel infrastructure for real workloads — file-backed mmap, real mprotect, expanded capacity.

**Depends on:** A26 (boot-to-shell)

**Implementation:**
- **File-backed mmap:** resolve fd → FileDescription → `vma.addFileVma()`, demand-paged via fault handler
- **Real mprotect:** walks PTEs, updates AP/UXN/PXN bits, TLBI per page (`vmm.updatePTEPermissions()`)
- **Per-process mmap_hint:** bounded by `MMAP_REGION_END=0x700000000000`, no global state
- **readv syscall (SYS_readv=65):** mirrors writev pattern, scatter-gather reads
- **ramfs capacity:** MAX_DATA_PAGES=1024 (4MB/file), MAX_NODES=256, MAX_CHILDREN=64
- **PMM default RAM:** 512MB; QEMU use `-m 512M` or larger

**Status:** Complete. 48 syscalls at this point.

---

### A27.5: x86 Hardening Port ✅

**Goal:** Port all x86_64 hardening features (mremap, ppoll, ext2 rename, capacity upgrades) to ARM64.

**Depends on:** A27 (kernel maturity)

**Implementation:**
- **mremap (SYS_mremap=216):** shrink/grow/move with MAYMOVE, CoW-aware, per-process mmap_hint
- **ppoll (SYS_ppoll=73):** full implementation, reads pollfd structs from user memory, validates fds
- **ext2Rename:** full directory entry manipulation, cross-dir ".." update, link count maintenance
- **sysRenameat:** path resolution, dispatches to VFS .rename op
- **12 new syscall stubs:** fchmod, fchown, umask, getrusage, statfs, fstatfs, prctl, clock_nanosleep, fchownat, fchmodat, lstat
- **Capacity upgrades:** MAX_FDS=256, MAX_WAITERS=128, BLOCK_CACHE_SIZE=512, MAX_ARGS=256, ARG_BUF_SIZE=32K
- **slot_in_use[] fix:** boolean array avoids comparing Optional(Process) (stack overflow fix)

**Status:** Complete. ~62 syscalls at this point.

---

### A28: TCP Listen/Accept + DPDK Foundations ✅

**Goal:** Server-side TCP (listen/accept) and hugepage memory allocation for DPDK integration.

**Depends on:** A27.5 (hardening)

**Implementation:**
- **TCP listen/accept:** ported from x86_64 — `listen` + `syn_received` states, `allocConnectionForServer()`, server-side 3-way handshake
- **socket.zig:** ACCEPT_QUEUE_SIZE=4, listening flag, accept_queue[], `findListeningSocket`, `queueAcceptedConnection`, `allocSocketWithConn`
- **sysListen (SYS=201):** validates SOCK_STREAM+bound, frees pre-alloc conn, sets listening=true
- **sysAccept (SYS=202):** blocking with `frame.elr -= 4` (ARM64 SVC is 4 bytes), dequeues from accept_queue, creates child socket+fd
- **Hugepage PMM:** `allocHugePage()` for 2MB-aligned contiguous 512-page blocks, `freeHugePage()`
- **SYS_net_hugepage_alloc (281):** maps hugepage into user address space at mmap_hint for zig_dpdk buffer pools
- **Capacity:** MAX_TCP_CONNECTIONS 8→32, MAX_SOCKETS 16→32

**Status:** Complete. ~65 syscalls at this point.

---

### A29: epoll + SCHED_DEDICATED + Hugepage VMM ✅

**Goal:** Event-driven I/O, deterministic scheduling for DPDK, and 2MB page mapping.

**Depends on:** A28 (TCP listen/accept)

**Implementation:**
- **epoll.zig (~430 lines):** epoll_create1/ctl/wait with VFS-backed fds, level-triggered
  - Linux AArch64 syscall numbers: epoll_create1=20, epoll_ctl=21, epoll_pwait=22
  - 8 epoll instances, 64 entries each, `wakeAllWaiters()` hooks in pipe/socket/tcp
  - `checkFdReadiness()`: pipe (EPOLLIN/EPOLLOUT/EPOLLHUP), socket (per type), regular files (always ready)
  - Blocking: `frame.elr -= 4`, deadline_tick for timeout, proc.wake_tick for timer-based wake
- **SCHED_DEDICATED:** `dedicated_pid` in scheduler, never preempts, SYS 503/504
- **Hugepage VMM:** `mapHugePage`/`unmapHugePage` via L2 block descriptors (DESC_BLOCK=0b01)
- **destroyUserPages** updated to free L2 block descriptors (hugepages)
- **zhttpd** cross-compiles for aarch64 (70KB binary)

**Status:** Complete. ~70 syscalls at this point.

---

### A30: zhttpd Verification ✅

**Goal:** Boot ARM64 kernel with virtio-net + virtio-blk, serve HTTP via zhttpd.

**Depends on:** A29 (epoll + TCP)

**Critical VMM bugs found and fixed:**

1. **Fork bomb (all execve'd processes run zinit's code):**
   Three bugs in vmm.zig: (1) `createAddressSpace` shared kernel L1 between all processes causing user page leaks, (2) `destroyUserPages` skipped L0[0] where user code lives, (3) `forkAddressSpace` copied L0[0] pointer without CoW. Fixed with per-process L1 allocation, proper L0[0] walk in destroy, deep-copy with CoW in fork.

2. **Permission faults from stale kernel split pages:**
   `splitL2Block` creates valid L3 entries for device memory across entire 2MB range. When user code at 0x401000+ is accessed, stale device entries generate permission faults. Fixed exception handler to treat non-user PTEs overlapping user VMAs as demand pages, plus TLB invalidation after mapping.

3. **zhttpd stat buffer mismatch:**
   Kernel stat struct is 144 bytes (st_mode@24, st_size@48). zhttpd used 32-byte buffer with wrong offsets. Fixed to match kernel layout.

**Verification:**
```
$ curl http://localhost:8080/www/index.html
<html>
<head><title>Zigix</title></head>
<body>
<h1>Welcome to Zigix</h1>
<p>Served by zhttpd on bare metal.</p>
</body>
</html>
```

Boot sequence: kernel → ext2 mount → zinit (PID 1) → fork → zhttpd (PID 2) listen:80 → zlogin (PID 3) → TCP accept → HTTP 200 with full HTML body.

**Status:** Complete. Full boot-to-HTTP verified on ARM64.

---

## Phase 8: Self-Hosting (A31+)

### A31: SCHED_DEDICATED Demo ✅

**Goal:** Userspace zero-copy packet polling demo — dedicated core + shared net_ring.

**Depends on:** A29 (SCHED_DEDICATED scheduler mode)

**Implementation:**
- **sys.zig wrappers:** Added 7 new NR constants and wrapper functions for epoll_create1/ctl/pwait, sched_dedicate/release, net_attach, net_hugepage_alloc. Also added EPOLLIN/EPOLLOUT/EPOLLERR/EPOLLHUP/EPOLL_CTL_ADD/DEL/MOD constants.
- **zdpdk program (~200 lines):** Zero-copy packet polling demo
  - Attaches to kernel net_ring (SYS 280) → 68-page shared ring at 0x300000
  - Validates ring header magic (0x5A4E5430 "ZNT0"), ring_size, buf_count, buf_size
  - Claims dedicated CPU core via SYS 503 (no preemption)
  - Tight poll loop: reads volatile rx_prod, processes PacketDesc entries, advances rx_cons
  - ARM64 DMB SY / x86 MFENCE barriers for consumer index visibility
  - YIELD/PAUSE hint on empty polls to reduce power consumption
  - Periodic stats: packet count and total bytes
- **Build:** Dual-arch (x86_64/aarch64), freestanding, ReleaseSmall, shared sys module

**Status:** Complete. ~72 syscall wrappers in sys.zig.

---

### A32: SMP Multi-Core ✅

**Goal:** Boot multiple CPUs on QEMU virt, both running user processes with shared ready queue and proper locking.

**Depends on:** A31 (SCHED_DEDICATED demo)

**New files:**

| File | Lines | Purpose |
|------|-------|---------|
| `spinlock.zig` | ~65 | Spinlock (cmpxchgWeak + WFE/SEV) + IrqSpinlock (DAIF save/restore) |
| `smp.zig` | ~265 | Per-CPU state, PSCI boot, secondary entry (naked asm), secondary_main |

**Modified files:**

| File | Changes |
|------|---------|
| `gic.zig` | Split `init()` → `initDistributor()` + `initCpuInterface()`, SGI_RESCHEDULE IPI support |
| `timer.zig` | Atomic global ticks, per-CPU timer_ticks, `initSecondary()`, CPU 0 only net.poll() |
| `scheduler.zig` | Per-CPU state via `smp.current()`, `sched_lock` IrqSpinlock, `pickNext()` skips running processes |
| `process.zig` | `cpu_id: i32` field (-1 = not running), `proc_lock` IrqSpinlock |
| `pmm.zig` | `pmm_lock` IrqSpinlock around all allocation/free/refcount ops |
| `uart.zig` | `uart_tx_lock` + `uart_rx_lock`, raw internal variants to avoid lock re-entry |
| `futex.zig` | `futex_lock` IrqSpinlock, wake-outside-lock pattern |
| `boot.zig` | `smp.initBsp()` after VMM, `bootSecondary()` loop after interrupts enabled |
| `exception.zig` | `pub` added to `vector_table` export for smp.zig reference |

**SMP architecture:**
- **Per-CPU state:** `PerCpu` struct held in `TPIDR_EL1` register — O(1) access via `smp.current()`
- **Secondary boot:** PSCI `CPU_ON` via `HVC #0` (func_id=0xC4000003). `SecondaryBootContext` struct passes TTBR0/stack/percpu/VBAR to avoid symbol resolution in naked asm.
- **Secondary init:** Sets CPACR → MAIR → TCR → TTBR0 → enables MMU → sets SP/TPIDR_EL1/VBAR → `secondary_main()` → GIC CPU interface + timer init → signal BSP → WFI idle loop.
- **Lock ordering:** `pmm > proc > sched > futex > uart` (each is narrow scope, no nesting)

**Verification:**
```
[smp] Booting CPU 1 (stack at 0x40abb000)...
[smp] CPU 1 entering scheduler
[smp] CPU 1 online (2 CPUs total)
[boot] 2 CPUs online
```
Full boot-to-shell with ext2 disk on 2 CPUs verified — zinit→zhttpd+zlogin running across both cores.

**Status:** Complete.

---

### A32.5: SMP Lock Completeness ✅

**Goal:** Make every kernel subsystem with global mutable state SMP-safe. Wire IPI reschedule so idle CPUs immediately wake when processes become ready.

**Depends on:** A32 (SMP multi-core)

**Implementation — 5 parallel work streams:**

A32 locked the foundation (PMM, UART, process, scheduler, futex). A32.5 completes coverage for all remaining subsystems:

| Stream | Files | Lock | Pattern |
|--------|-------|------|---------|
| VFS + ramfs | `vfs.zig`, `ramfs.zig` | `vfs_lock`, `ramfs_lock` | Lock released before filesystem callbacks; split lock regions in `create()` |
| ext2 | `ext2.zig` | `ext2_lock` | Coarse lock at public API; `*Unlocked` internal variants for re-entrancy |
| Socket + TCP | `socket.zig`, `tcp.zig` | `socket_lock`, `tcp_lock` | Never nested; wake-outside-lock in `handleTcp()` state machine |
| Pipe + epoll | `pipe.zig`, `epoll.zig` | `pipe_lock`, `epoll_lock` | Wake-outside-lock; snapshot pattern for `sysEpollWait()` |
| IPI wakeup | `scheduler.zig`, `smp.zig` | — | `wakeProcess()` sends `SGI_RESCHEDULE` to first idle CPU |

**Complete lock ordering (deadlock-free):**
```
pmm_lock > proc_lock > sched_lock > ext2_lock > vfs_lock > ramfs_lock
> socket_lock > tcp_lock > pipe_lock > epoll_lock > futex_lock > uart_lock
```

**Key SMP patterns established:**

1. **Wake-outside-lock:** Collect PIDs to wake while holding subsystem lock, release lock, then call `scheduler.wakeProcess()`. Used in: futex, pipe, socket, tcp, epoll.

2. **Snapshot pattern:** Copy shared state into stack-local variables under lock, release lock, then operate on the snapshot. Used in: `sysEpollWait()` (copies entry fields before readiness scan).

3. **Unlocked variants:** Public API acquires lock and delegates to `*Unlocked` internal function. Allows internal re-entrant calls without deadlock. Used in: ext2 (`lookupUnlocked`, `ext2UnlockUnlocked`), socket (`findListeningSocketLocked`).

4. **IPI reschedule:** `wakeProcess()` scans `per_cpu_data[]` for idle CPUs and sends `SGI_RESCHEDULE` via `gic.sendSGI()`. The idle CPU exits WFI immediately, runs `timerTick()`, and picks up the newly-ready process. Latency improved from up to 10ms (timer tick) to <1us (IPI delivery).

**Verification:**
```bash
# 2-CPU boot without disk
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 512M -smp 2 \
  -kernel zig-out/bin/zigix-aarch64 -serial file:/tmp/test.log
# → 2 CPUs online, userspace runs, clean halt

# Full boot-to-shell with ext2 disk
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 512M -smp 2 \
  -kernel zig-out/bin/zigix-aarch64 \
  -drive file=ext2-aarch64.img,format=raw,if=none,id=disk0 \
  -device virtio-blk-device,drive=disk0 \
  -serial file:/tmp/test.log
# → zinit→zhttpd(listen:80)+zlogin(login:), both CPUs scheduling
```

**Status:** Complete. All subsystems SMP-safe. Entire kernel verified on 2-CPU QEMU.

---

### A33: zig_dpdk Zigix Native Backend ✅

**Goal:** Implement `platform/zigix.zig` and `drivers/zigix.zig` for zig_dpdk — native zero-copy networking on Zigix ARM64/x86_64.

**Depends on:** A31 (dedicated scheduling), A28 (hugepages), A32 (SMP)

Complete rewrite of zig_dpdk's Zigix platform layer and driver to match the kernel's net_ring.zig protocol:

**platform/zigix.zig** (242 lines, rewritten from scratch):
- Constants match kernel exactly: RING_SIZE=256, BUF_COUNT=64, BUF_SIZE=4096, TOTAL_PAGES=67
- PacketDesc: `{ buf_idx: u32, length: u32, flags: u32, _pad: u32 }` (16 bytes)
- RingHeader: cache-line-aligned u32 indices (64-byte spacing), MAGIC=0x5A4E5430
- SharedNetQueue: header/rx_ring/tx_ring/buf_base pointers from base address + validate()
- Dual-arch syscall: `svc #0` (aarch64) / `int $0x80` (x86_64), NR=280 (net_attach)
- Proper memory barriers: `dmb ishst` (store-release), `dmb ishld` (load-acquire) on ARM64; compiler fence on x86_64
- TX buffer convention: userspace indices 0..31, kernel allocates from top (63, 62, ...)
- 6 comprehensive layout/offset tests

**drivers/zigix.zig** (341 lines, rewritten):
- Removed virtio net header handling (kernel passes raw Ethernet frames)
- Ring indexing via `& RING_MASK` (power-of-two, branchless)
- Proper barrier placement: load-acquire before reading producer/consumer, store-release before publishing
- Local packet/byte counters for stats (no shared stats in kernel net_ring)
- TX round-robin buffer allocation cycles through 0..TX_BUF_COUNT-1
- Validates ring header magic/config on attach
- 7 tests including vtable, defaults, burst-when-unattached, round-robin

Also fixed pre-existing Zig API compat issues in af_xdp.zig (mmap PROT/MAP types, sendto non-null buf, bpf syscall) and iommu.zig (mmap i64 offset, volatile discard).

Full test suite passes clean (zig build test).

---

### A34: Zig Compiler Port — `zig version` on Zigix ARM64 ✅

**Goal:** Boot a real-world 152MB static Zig compiler binary on Zigix ARM64 and run `zig version`.

**Depends on:** A33 (zig_dpdk native), A27 (kernel maturity), A14 (mmap), A15 (threads)

**Critical bug found and fixed:**

1. **SIMD/FP register clobber in exception handler:**
   The exception handler saved/restored only GP registers (X0-X30 + ELR + SPSR + SP = 272-byte frame). It did NOT save SIMD/FP registers (v0-v31, FPCR, FPSR). When page faults occurred during SIMD-heavy code paths (Zig compiler uses NEON extensively for string ops, hashing, memcpy), the d0 register got clobbered by the demand-paging code. This caused garbage data to be stored back to user memory — manifesting as a bogus 8.7GB mmap allocation (0x20578001c bytes) instead of small 4KB-8KB ones, triggering an OOM cascade.

   **Fix:** Save all 32×128-bit Q registers (q0-q31) + FPCR + FPSR on every exception entry, restore on exit. Frame size increased from 272 to 800 bytes:
   - 34×8 = 272 bytes (GP registers: X0-X30 + ELR + SPSR + SP)
   - 32×16 = 512 bytes (SIMD/FP registers: q0-q31)
   - 2×8 = 16 bytes (FPCR + FPSR)

2. **mmap_hint not reset in execve:**
   After `execve()`, the new process inherited the parent's `mmap_hint` which could be deep into the address space. The Zig compiler's first mmap would get placed at a high address, then subsequent mmaps would fail. Fixed by resetting `proc.mmap_hint` to the default base in `sysExecve()`.

3. **CLONE_SETTLS for threads:**
   The Zig compiler's musl runtime creates threads with `CLONE_SETTLS` to set TPIDR_EL0 for the new thread. The clone syscall handler now checks for CLONE_SETTLS and sets `new_proc.tls_base` from the TLS argument.

4. **MAP_FIXED VMA overlap handling:**
   `mmap(MAP_FIXED)` must silently unmap any existing VMAs that overlap the requested range before creating the new mapping. Without this, the Zig compiler's allocator would get ENOMEM when re-mapping regions.

**Verification:**
```
[zinit] Running /zig/zig version...
0.16.0-dev.2510+bcb5218a2
```

**Setup:**
- `run_aarch64.sh` updated with Zig tree preparation (extracts aarch64-linux-musl Zig binary into ext2 image at `/zig/`)
- `make_ext2_img.py` already handles the Zig tree structure
- QEMU: 1GB RAM needed (`-m 1G`) for demand-paging the 152MB static binary
- zinit runs `/zig/zig version` at boot, output appears on serial

**Status:** Complete. ~75 syscalls at this point.

---

### A35: Self-Hosting

**Goal:** Compile Zig programs on Zigix ARM64.

**Depends on:** A34 (Zig compiler)

```
zigix$ zig build-exe hello.zig
zigix$ ./hello
Hello from Zigix ARM64!
```

---

## ARM64-Specific Advantages

Once parity is achieved, ARM64 offers unique opportunities:

### 1. Apple Silicon Support
- M1/M2/M3 have excellent single-core performance
- Native macOS development → test on real ARM64 hardware
- Virtualization.framework for fast VM testing

### 2. Raspberry Pi Support
- Pi 4/5 are excellent development targets
- Real hardware, real peripherals (GPIO, SPI, I2C)
- Bare metal → no QEMU overhead

### 3. Cloud/Server Deployment
- AWS Graviton instances
- Ampere Altra servers
- Cost-effective, power-efficient

### 4. Mobile/Embedded
- Android devices (for research)
- Custom embedded systems
- IoT gateways

---

## Dependency Graph

```
A1 (Full Page Tables) ──┬──► A2 (VMM) ──┬──► A3 (HHDM)
                        │               │
                        │               └──► A4 (Process) ──► A5 (Context Switch)
                        │                                          │
                        │                                          ▼
                        │                                     A6 (Scheduler)
                        │                                          │
                        │                                          ▼
                        │                                     A7 (Syscall Entry)
                        │                                          │
                        ▼                                          ▼
                   A8 (VFS) ◄──────────────────────────────────────┘
                        │
                        ├──► A9 (ELF Loader)
                        │
                        └──► A10 (virtio-blk) ──► A11 (ext2)
                                                      │
                                                      ▼
                   A12 (Demand Paging) ──► A13 (CoW) ──► A14 (mmap)
                        │
                        ▼
                   A15 (Threads) ──► A16 (Signals) ──► A17 (TLS)
                        │
                        ▼
                   A18 (virtio-net) ──► A19 (TCP/IP) ──► A20 (Zero-Copy)
                        │
                        ▼
                   A21 (Utils) ──► A22 (Shell) ──► A23 (Init)
                        │
                        ▼
                   A24 (Syscall Parity) ──► A25 (FDT)
                        │
                        ▼
                   A26 (Boot-to-Shell) ──► A27 (Kernel Maturity) ──► A27.5 (Hardening)
                        │
                        ▼
                   A28 (TCP Listen/Accept) ──► A29 (epoll + SCHED_DEDICATED)
                        │
                        ▼
                   A30 (zhttpd Verified) ──► A31 (SCHED_DEDICATED Demo)
                        │
                        ▼
                   A32 (SMP Multi-Core) ──► A32.5 (SMP Lock Completeness)
                        │
                        ▼
                   A33 (zig_dpdk Native) ──► A34 (Zig Compiler) ──► A35 (Self-Hosting)
```

---

## Suggested Implementation Order

**Phase 1 (Foundation):**
1. ~~A1 — Full page tables~~ (early version done)
2. A2 — VMM port
3. A4 — Process structure
4. A5 — Context switch
5. A6 — Scheduler

**Phase 2 (Functionality):**
6. A7 — Syscall entry
7. A8 — VFS + ramfs (direct port)
8. A9 — ELF loader
9. A21 — Cross-compile utilities
10. A22 — Shell

**Phase 3 (Parity):**
11. A10 — virtio-blk
12. A11 — ext2
13. A12 — Demand paging
14. A13 — CoW
15. A14 — mmap
16. A15 — Threads
17. A16 — Signals

**Phase 4 (Network):**
18. A18 — virtio-net
19. A19 — TCP/IP stack
20. A20 — Zero-copy networking

**Phase 5 (Maturity):**
21. A23 — Init system
22. A24 — Syscall parity
23. A25 — FDT parser
24. A26 — Boot-to-shell
25. A27 — Kernel maturity (file-backed mmap, mprotect, readv, capacity)
26. A27.5 — x86 hardening port (mremap, ppoll, rename, stubs)

**Phase 6 (Server):**
27. A28 — TCP listen/accept + hugepage PMM
28. A29 — epoll + SCHED_DEDICATED + hugepage VMM
29. A30 — zhttpd verification (boot-to-HTTP)

**Phase 7 (DPDK + Self-Hosting):**
30. A31 — SCHED_DEDICATED demo
31. A32 — SMP multi-core (PSCI boot, spinlocks, per-CPU scheduler)
32. A32.5 — SMP lock completeness (all subsystems locked, IPI wakeup)
33. A33 — zig_dpdk Zigix native backend (platform + driver rewrite, dual-arch)
34. A34 — Zig compiler port (`zig version` on Zigix ARM64)
35. A35 — Self-hosting (`zig build-exe hello.zig` compiles and runs on Zigix)
36. A36 — Multi-file compilation (`@import("lib.zig")` + VMA compaction)

---

## Metrics

| Metric | A26 (Shell) | A30 (HTTP) | A32.5 (SMP) | A34 (Zig Run) | A35 (Self-Host) |
|--------|-------------|------------|-------------|---------------|-----------------|
| Kernel lines | ~10,900 | ~14,500 | ~15,800 | ~16,000 | **17,412** |
| Source files | 34 | 35 | 37 | 37 | **37** |
| Syscalls (impl) | 46 | ~70 | ~70 | ~75 | **75+** |
| Syscalls (total) | 46 | ~70 | ~70 | ~80 | **102** |
| CPUs | 1 | 1 | 2-4 (SMP) | 2-4 (SMP) | **2-4 (SMP)** |
| Boot time | <1s | <1s | <1s | <1s | **<1s** |
| RAM required | 256 MB | 512 MB | 512 MB | 1 GB | **2 GB** |
| Userspace progs | 6 | 7 | 9 | 9 | **9** |
| SMP locks | 0 | 0 | 12 | 12 | **12** |
| Exception frame | 272 B | 272 B | 272 B | 800 B | **800 B** |
| MAX_VMAS | 128 | 128 | 128 | 128 | **8,192** |
| MAX_PROCESSES | 64 | 64 | 64 | 64 | **128** |

---

## Testing Strategy

### QEMU virt Machine (Primary)
```bash
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M \
    -kernel zig-out/bin/zigix-aarch64 \
    -drive file=test.img,format=raw,if=virtio \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
    -serial stdio -display none
```

### Hardware Targets (Future)
- Raspberry Pi 4/5 via SD card boot
- Apple M1/M2 via Asahi Linux UEFI or custom bootloader
- AWS Graviton via custom AMI

---

## Summary

**39 milestones completed** (A1 through A36), covering:
- Boot, MMU, PMM, VMM (A1-A3)
- Process management, scheduling, syscalls (A4-A7)
- Filesystems: VFS, ramfs, ext2 (A8-A11)
- Demand paging, CoW, mmap (A12-A14)
- Threads, signals, TLS (A15-A17)
- Networking: virtio-net, full TCP/IP, zero-copy (A18-A20)
- Userspace: 9 dual-arch programs + shared lib (A21-A23)
- Kernel maturity: syscall parity, FDT, boot-to-shell (A24-A27.5)
- Server: TCP listen/accept, epoll, SCHED_DEDICATED, HTTP (A28-A31)
- SMP: multi-core boot, per-CPU state, complete locking, IPI (A32-A32.5)
- zig_dpdk: native Zigix backend with kernel-matching net_ring protocol (A33)
- Zig compiler port: 152MB static binary runs `zig version` on Zigix ARM64 (A34)
- **Self-hosting: `zig build-exe hello.zig` compiles and runs on Zigix ARM64 (A35)**
- **Multi-file: `@import("lib.zig")` local imports + VMA compaction (A36)**

The ARM64 port follows the same architectural principles as x86_64:
- Bitmap PMM with ref counts ✅
- 4-level page tables (L0→L1→L2→L3) ✅
- Preemptive scheduler with priority ✅
- VFS with pluggable filesystems ✅
- Full TCP/IP networking ✅
- SMP multi-core with per-CPU scheduling ✅
- Complete subsystem locking (12 IrqSpinlocks) ✅
- IPI-based instant process wakeup ✅
- Full SIMD/FP register preservation in exception handler ✅
- 152MB Zig compiler compiles multi-file programs on Zigix ✅
- VMA compaction for arena allocator workloads (8000+ mmap regions) ✅

Key differences from x86_64:
- Simpler boot (no Limine, direct kernel entry via PSCI)
- Cleaner exception model (vector table vs IDT)
- GICv2 with SGI IPI instead of APIC/LAPIC
- ARM Generic Timer instead of PIT (per-CPU, no configuration needed)
- TPIDR_EL0 for TLS, TPIDR_EL1 for per-CPU state
- WFE/SEV spinlocks instead of PAUSE-based spinning
- Identity mapping instead of HHDM

---

## Zigix vs Linux: Feature Comparison

### The Numbers

| Metric | Zigix ARM64 | Linux 6.x ARM64 | Coverage |
|--------|-------------|------------------|----------|
| **Total kernel LOC** | 17,412 | ~30,000,000 | 0.06% |
| **Kernel + shared LOC** | 40,224 (both arches) | ~30,000,000 | 0.13% |
| **Source files** | 37 (arch) + 71 (shared) | ~80,000 | 0.14% |
| **Syscalls (implemented)** | 75+ | ~450 | ~17% |
| **Syscalls (defined)** | 102 | ~450 | ~23% |
| **Filesystem types** | 2 (ext2, ramfs) | 50+ (ext4, btrfs, xfs, ...) | 4% |
| **Device drivers** | 3 (UART, virtio-blk, virtio-net) | ~10,000 | 0.03% |
| **Network protocols** | 5 (Ethernet, ARP, IPv4, TCP, UDP) | 40+ | ~13% |
| **Max CPUs** | 4 | 256+ | - |
| **Binary size** | 15 MB (debug) | ~30 MB (compressed vmlinuz) | - |
| **Boot time** | <1s (QEMU) | ~1-5s (typical) | - |
| **Language** | Zig (100%) | C (99%) + asm | - |

### What Zigix Has That Matters

Despite being 0.06% the size of Linux, Zigix covers the critical path for a self-hosting development environment:

| Capability | Status | Linux Equivalent |
|------------|--------|-----------------|
| **Process lifecycle** | fork, exec, exit, wait, threads | Full POSIX (clone, vfork, etc.) |
| **Memory management** | mmap, munmap, mremap, mprotect, brk, CoW, demand paging | Full VM subsystem |
| **File I/O** | read, write, readv, writev, pread, pwrite, lseek, ftruncate | Full VFS |
| **Directory ops** | openat, mkdirat, unlinkat, getdents64, renameat, getcwd, chdir | Full directory API |
| **Networking** | socket, bind, listen, accept, connect, sendto, recvfrom, epoll | Full socket API |
| **Signals** | rt_sigaction, rt_sigprocmask, rt_sigreturn, kill, tgkill | Full signal API |
| **Threading** | clone (CLONE_VM/SETTLS/PARENT_SETTID/CHILD_CLEARTID), futex | pthreads support |
| **File descriptors** | dup, dup3, pipe2, fcntl, ioctl | Full fd management |
| **Process info** | getpid, getppid, gettid, getuid/gid, uname | Full /proc-less info |
| **Timing** | clock_gettime, nanosleep, clock_nanosleep | Full POSIX timers |
| **Polling** | epoll_create1/ctl/wait, ppoll | Full event I/O |
| **Stat** | fstat, newfstatat, statx, statfs, faccessat | Full stat family |
| **Misc** | getrandom, prlimit64, sched_getaffinity | Partial |

### What Zigix Does NOT Have (vs Linux)

| Missing Feature | Impact | Priority |
|----------------|--------|----------|
| **ext4/btrfs/xfs** | ext2 only (no journaling in production path) | Medium |
| **IPv6** | IPv4 only | Low |
| **USB/PCIe/SCSI** | VirtIO only, no real hardware drivers | Low (QEMU) |
| **SELinux/capabilities** | No MAC, no fine-grained capabilities | Low |
| **cgroups/namespaces** | No container support | Low |
| **/proc, /sys, /dev** | No pseudo-filesystems (minimal /dev via ramfs) | Medium |
| **Dynamic linking** | Static musl only | Low |
| **IPC (SysV/POSIX)** | No shared memory, semaphores, message queues | Low |
| **ptrace** | No debugging/tracing support | Medium |
| **select/poll** | Have epoll + ppoll, no legacy select | Low |
| **Advanced scheduling** | Round-robin + SCHED_DEDICATED, no CFS/EEVDF | Low |
| **Swap** | No swap partition/file support | Low |
| **NUMA** | Single-node SMP only | Low |
| **Power management** | No suspend/resume, no cpufreq | Low |
| **Real hardware boot** | QEMU virt only (no RPi/Graviton yet) | **High** |

### Syscall Coverage by Category

```
Process Control    [==========--------]  12/20  (60%)   fork/exec/exit/wait/clone/kill/...
File I/O           [==============----]  16/22  (73%)   read/write/readv/writev/pread/pwrite/lseek/...
File Management    [============------]  14/22  (64%)   open/close/stat/fstat/ftruncate/rename/...
Directory          [==============----]   7/10  (70%)   openat/mkdirat/unlinkat/getdents64/chdir/...
Memory             [================--]   7/9   (78%)   mmap/munmap/mremap/mprotect/brk/madvise/...
Networking         [==============----]  12/18  (67%)   socket/bind/listen/accept/connect/send/recv/...
Signals            [==============----]   6/8   (75%)   sigaction/sigprocmask/sigreturn/kill/tkill/...
Threading          [============------]   4/6   (67%)   clone/futex/set_tid_address/sched_yield/...
Polling/Events     [================--]   6/8   (75%)   epoll_create1/ctl/wait/ppoll/...
Timing             [==============----]   3/5   (60%)   clock_gettime/nanosleep/clock_nanosleep/...
Info/Identity      [================--]  10/12  (83%)   getpid/getuid/uname/prlimit64/getrandom/...
```

**Overall: ~97/160 common syscalls covered (61%) — enough for musl libc + Zig compiler**

### Kernel Subsystem Comparison

```
                    Zigix ARM64              Linux ARM64
                    ───────────              ───────────
Boot            ┌─ PSCI + FDT ──────┐   ┌─ EFI/ACPI/DTB ────────┐
                │  ~400 lines        │   │  ~50,000 lines         │
                └────────────────────┘   └────────────────────────┘

Interrupts      ┌─ GICv2 ───────────┐   ┌─ GICv2/v3/v4 + ITS ──┐
                │  ~200 lines        │   │  ~15,000 lines         │
                └────────────────────┘   └────────────────────────┘

Memory          ┌─ PMM + VMM ───────┐   ┌─ Buddy + Slab + CMA ─┐
                │  ~1,400 lines      │   │  ~200,000 lines        │
                └────────────────────┘   └────────────────────────┘

Scheduler       ┌─ Round-Robin + DD ┐   ┌─ EEVDF + RT + DL ────┐
                │  ~500 lines        │   │  ~40,000 lines         │
                └────────────────────┘   └────────────────────────┘

Filesystem      ┌─ VFS + ext2 + ram ┐   ┌─ VFS + 50 FSes ──────┐
                │  ~4,200 lines      │   │  ~500,000 lines        │
                └────────────────────┘   └────────────────────────┘

Networking      ┌─ Eth/ARP/IP/TCP/  ┐   ┌─ Full netstack ───────┐
                │  UDP ~2,200 lines  │   │  ~2,000,000 lines      │
                └────────────────────┘   └────────────────────────┘

Drivers         ┌─ UART + 2 VirtIO ┐   ┌─ ~10,000 drivers ─────┐
                │  ~1,500 lines      │   │  ~15,000,000 lines     │
                └────────────────────┘   └────────────────────────┘
```

### What This Means

Zigix ARM64 is a **teaching/research kernel** that demonstrates every major OS concept in ~17K lines of readable Zig code, achieving what takes Linux ~30M lines of C. It's not a Linux replacement — it's a proof that a modern systems language can express the full self-hosting compilation pipeline (fork + exec + mmap + threads + futex + file I/O + signal handling) in a kernel small enough for one person to understand entirely.

The self-hosting milestone (A35) is particularly significant: the Zig compiler is one of the most demanding userspace applications (152MB binary, multithreaded arena allocator, hundreds of mmap calls, file-backed mmap with MAP_SHARED write-back, pthread lifecycle management) — and it runs on a kernel written from scratch in under a year.

---

## Forward Roadmap (A36+)

### Phase 8: Compiler Maturity

#### A36: Multi-File Compilation ✅

**Goal:** `zig build-exe` with `@import()` — compile programs that import local modules and use std library features.

**Verified:** multitest.zig imports lib.zig (fibonacci + factorial), uses std.debug.print with format strings. Compiled and executed successfully on Zigix ARM64.

**Key fix:** VMA compaction — the Zig compiler creates 8000+ mmap regions per compilation. When two compilations run sequentially (single-file then multi-file), the second exhausted all 8192 VMA slots. Added `compactVmas()` that merges adjacent anonymous VMAs with identical flags when the VMA list is full, using DMB barriers for SMP safety. This is the proper O(n) compaction approach — merging only happens when needed, not on every addVma call (which caused CLONE_VM race conditions).

#### A37: Build System Support
**Goal:** `zig build` (not just `zig build-exe`) — run the Zig build system, which uses `build.zig` files.

**What it tests:**
- Child process management (build runner spawns sub-processes)
- More complex file I/O patterns
- Working directory management

**Estimated complexity:** Medium (build runner is more complex than direct compilation)

### Phase 9: System Maturity

#### A38: /proc Filesystem
**Goal:** Implement a minimal procfs providing `/proc/self/maps`, `/proc/self/status`, `/proc/cpuinfo`.

**Why:** Many programs (including Zig) read `/proc` for system information. Currently they fail silently or get ENOENT.

**What it enables:**
- Better diagnostic capability
- Programs that check available memory or CPU features
- Self-introspection for debugging

#### A39: /dev Improvements
**Goal:** Proper `/dev/null`, `/dev/zero`, `/dev/urandom` character devices.

**Why:** Many programs redirect output to `/dev/null` or read random bytes from `/dev/urandom`. Currently these are either missing or faked.

#### A40: ext3 Journal Integration
**Goal:** Wire the existing `kernel/fs/ext3/` journal modules into the ARM64 ext2 path for crash-consistent metadata writes.

**Why:** ext2 without journaling risks filesystem corruption on unclean shutdown. The journal code already exists but isn't wired into the ARM64 write path.

**Estimated complexity:** Medium (code exists, needs integration)

### Phase 10: Real Hardware

#### A41: Raspberry Pi 4 Boot
**Goal:** Boot Zigix on real ARM64 hardware — Raspberry Pi 4 Model B.

**What's needed:**
- U-Boot or bare-metal entry via RPi4 firmware
- BCM2711 UART driver (mini UART or PL011)
- BCM2711 interrupt controller (GIC-400, GICv2-compatible)
- SD card or USB mass storage driver (or initial ramdisk)
- FDT parser already works (just needs real DTB)

**Estimated complexity:** High (new hardware platform, new drivers)

#### A42: Raspberry Pi 5 / Graviton
**Goal:** Extend hardware support to RPi5 (BCM2712, GICv3) or AWS Graviton (cloud ARM64).

### Phase 11: Hardening

#### A43: User/Kernel Address Space Separation
**Goal:** Move kernel to high virtual addresses (TTBR1_EL1) instead of identity mapping. User code uses TTBR0_EL1 only.

**Why:** Current identity mapping means user processes can theoretically access kernel memory if permission bits are wrong. Proper split eliminates this entire class of bugs.

#### A44: Stack Guard Pages
**Goal:** Map guard pages (unmapped) at stack boundaries to catch stack overflow with a clean fault instead of silent memory corruption.

#### A45: KASLR (Kernel Address Space Layout Randomization)
**Goal:** Randomize kernel load address to harden against exploits.

### Phase 12: Performance

#### A46: Slab Allocator
**Goal:** Replace bitmap PMM with a slab allocator for small kernel objects (process structs, VMAs, file descriptors).

**Why:** Current approach uses page-granularity allocation for everything. A slab allocator reduces internal fragmentation and improves cache behavior.

#### A47: Page Cache
**Goal:** Cache frequently-read ext2 blocks in memory to avoid repeated disk I/O.

**Why:** Every file read currently goes to virtio-blk. A page cache dramatically improves performance for repeated access patterns (compilation reads the same headers many times).

#### A48: VMA Merging
**Goal:** Merge adjacent VMAs with compatible flags to reduce VMA count.

**Why:** The Zig compiler creates hundreds of small adjacent anonymous VMAs. Merging reduces VMA list scan time from O(n) to O(n/k).

### Phase 13: Advanced Features

#### A49: Dynamic Linking (ld.so)
**Goal:** Support ELF shared libraries and dynamic linking via a minimal ld-linux-aarch64.so.

#### A50: ptrace
**Goal:** Implement ptrace for debugging support (PTRACE_ATTACH, PTRACE_PEEKDATA, PTRACE_CONT, etc.).

#### A51: POSIX IPC
**Goal:** Shared memory (shm_open/mmap), semaphores, message queues.

---

## Recommended Next Steps (Discussion)

Based on the current state, here are the highest-value next milestones in priority order:

### Tier 1: Immediate Value (Low Effort, High Impact)

1. **A36: Multi-file compilation** — Likely works already, just needs testing. Validates that the self-hosting story extends beyond hello-world.

2. **A39: /dev/null + /dev/zero + /dev/urandom** — Many programs need these. Simple to implement (special ramfs nodes with custom read/write ops). Probably ~50 lines each.

3. **A38: /proc/self/maps** — The Zig compiler and many musl functions try to read this. Even a stub that returns an empty file prevents ENOENT crashes.

### Tier 2: Medium Effort, Strategic Value

4. **A40: ext3 journal** — The code already exists in `kernel/fs/ext3/`. Wiring it in gives crash consistency, which matters for any real compilation workflow (losing output files to corruption is unacceptable).

5. **A37: `zig build` support** — The real Zig workflow uses `build.zig` files, not raw `zig build-exe`. Getting `zig build` working means Zigix can build real Zig projects.

6. **A48: VMA merging** — With 8192 VMA slots the immediate pressure is off, but merging adjacent compatible VMAs is the proper fix and improves scan performance.

### Tier 3: High Effort, Long-Term Vision

7. **A41: Raspberry Pi 4** — Real hardware is the ultimate validation. Extremely rewarding but requires new drivers.

8. **A43: User/kernel address space separation** — Proper security boundary. Significant VMM rework.

9. **A47: Page cache** — Major performance win for compilation workloads. Significant complexity.
