# Zigix Kernel Limits Audit — Production Sizing

**Purpose:** Every constant below was either hit during the Linux kernel build stress test or will be hit by any non-trivial workload. The kernel must support running itself — zig cc compiling 300 C files means 300+ processes, 100K+ page faults, 500+ VMAs per process, thousands of FDs system-wide.

**Reference workload:** `make -j1` of Linux 6.12.17 tinyconfig using zig cc as CC. This spawns 200+ short-lived processes (make → dash → zig cc → zig child), each doing 20+ mmaps, opening 5+ FDs, demand-paging 165MB binaries.

---

## CRITICAL — Hit During Testing

These caused crashes, hangs, or build failures during sessions.

### 1. MAX_VMAS (VMA slots per process)
- **File:** `kernel/mm/vma.zig`
- **Was:** 128
- **Changed to:** 512
- **Should be:** 1024
- **Why:** zig cc does 200+ mmaps for LLVM allocations. With munmap creating holes, active VMA count stays ~180-250. Linux default is 65530 (`vm.max_map_count`). 1024 gives headroom for zig cc + any future multi-threaded workload without wasting memory.
- **Memory cost:** `sizeof(Vma) × MAX_VMAS × MAX_PROCESSES` = ~64B × 1024 × 256 = **16 MB**

### 2. MAX_FDS / File Description Pool
- **File:** `kernel/fs/vfs.zig` or `kernel/proc/process.zig` (check both)
- **Current:** Likely 256 system-wide or per-process
- **Should be:** 4096 system-wide, 256 per-process
- **Why:** ENFILE ("too many open files") hit during kernel build header generation. 200+ processes × 3 base FDs (stdin/stdout/stderr) = 600 FDs minimum. With file opens for compilation, easily 1000+.
- **Also check:** FD leak on process exit — `destroyProcess` / zombie reap must close all open FDs. If FDs aren't freed when processes exit, the pool drains even with high limits.

### 3. MAX_PROCESSES / Process Table
- **File:** `kernel/proc/process.zig`
- **Current:** 256
- **Should be:** 512 minimum, 1024 preferred
- **Why:** Linux build spawns 200+ processes. With make -j2 (future SMP), double that. Zombie processes waiting for reap consume slots. PID recycling only works after reap.
- **Memory cost:** `sizeof(Process) × MAX_PROCESSES`. With 1024 VMAs embedded, each Process is ~70KB. 512 processes = **35 MB**, 1024 = **70 MB**. With 8GB RAM, either is fine.

### 4. NVMe I/O Queue Depth
- **File:** `kernel/drivers/nvme.zig`
- **Current:** Check `IO_QUEUE_SIZE` or equivalent
- **Should be:** 64 minimum, 256 preferred
- **Why:** Demand paging 165MB zig binary = 40K+ NVMe reads. With single I/O queue and polling, throughput is limited by round-trip latency. Deeper queue + batched submissions would help. The io_lock serializes access — with deeper queues, multiple commands can be in-flight.
- **Related:** NVMe completion timeout (50M spins) should log a warning, not silently return. The RIP sampling diagnostic caught the NVMe deadlock — keep a simplified version as permanent instrumentation.

### 5. Kernel Stack Size
- **File:** `kernel/proc/clone.zig` (allocPages call)
- **Current:** 64 pages = 256KB
- **Should be:** 256KB is fine for now
- **Note:** Canary corruption was from missing canary write, not stack overflow. But deep call chains (demand pager → ext2 → NVMe → page cache) use significant stack. Monitor via canary. If canary fires legitimately, bump to 128 pages = 512KB.

---

## HIGH PRIORITY — Will Hit on Real Workloads

### 6. Page Cache Size
- **File:** `kernel/mm/page_cache.zig`
- **Current:** Check `CACHE_SIZE` or `MAX_ENTRIES`
- **Should be:** 8192 minimum (32MB at 4KB/page), 32768 preferred (128MB)
- **Why:** zig cc is 165MB. With page cache < 165MB, every zig invocation re-reads the entire binary from NVMe. With 32K entries (128MB), the second zig cc invocation hits cache for most pages. Linux build invokes zig cc 300+ times — cache hit rate is the difference between 5 minutes and 5 hours.
- **Memory cost:** Cache entries are ~32B each + pinned physical pages. 32K entries = 1MB metadata + 128MB pinned pages. With 8GB RAM, use 10-15% for page cache.

### 7. tmpfs Size / Inode Limit
- **File:** `kernel/fs/tmpfs.zig`
- **Current:** Check `MAX_INODES`, `MAX_DATA_PAGES`
- **MAX_DATA_PAGES should be:** 65536 (256MB) — zig cc writes .o files, LLVM temp files, build artifacts
- **MAX_INODES should be:** 4096 — kernel build creates thousands of temp files
- **Why:** ENFILE / "cannot create" errors during build. The kernel build creates hundreds of .o files, .d dependency files, .cmd files, temp directories.

### 8. tmpfs MAX_DATA_PAGES Per File
- **File:** `kernel/fs/tmpfs.zig`
- **Was:** 64 (256KB per file) → fixed to 4096 (16MB)
- **Should be:** 16384 (64MB)
- **Why:** zig cc output files can be multi-MB. LLVM temp files during compilation can be 10MB+. The `-EFBIG` fix was good but 16MB may still be tight for large translation units.

### 9. mmap Hint / Address Space Layout
- **File:** `kernel/proc/process.zig` (`aslrMmapBase`)
- **Current:** Starts at ~0x7000_0000_0000, grows down
- **Should verify:** The gap between mmap region and stack is sufficient. With 200+ mmaps of 128KB each = 25MB of address space consumed. Not a problem now but with multi-threaded zig (many more mmaps), check for mmap/stack collision.
- **Also:** `allocMmapRegion` never checks for VMA overlap — it just decrements. If mmap region grows into ELF load addresses, silent corruption. Add a floor check (e.g., refuse allocations below 0x1000_0000_0000).

---

## MEDIUM PRIORITY — Robustness

### 10. ext2 Block Cache / Read Buffer
- **File:** `kernel/fs/ext2.zig`
- **Current:** Reads one block at a time
- **Should consider:** Read-ahead of 8-16 contiguous blocks for sequential access. Demand paging is inherently sequential for code segments — the ELF is laid out linearly. Reading 8 blocks per NVMe command would 8x throughput for code page loading.

### 11. Futex Wait Queue
- **File:** `kernel/proc/futex.zig`
- **Current:** Check wait queue size
- **Should be:** 256 entries minimum
- **Why:** musl's threading uses futex for all synchronization. zig cc spawns LLVM threads. Each waiting thread needs a futex queue slot. If the queue is too small, futex(FUTEX_WAIT) returns -ENOMEM and musl's lock spins forever.

### 12. Signal Queue / Pending Signals
- **File:** `kernel/proc/signal.zig`
- **Current:** Single pending bitmask (64 signals)
- **Should verify:** rt_sigqueueinfo support if any binary uses real-time signals. The bitmask approach loses signal count (two SIGCHLDs delivered as one). Not critical for the Linux build but matters for robust process management.

### 13. Pipe Buffer Size
- **File:** `kernel/fs/pipe.zig` or FIFO implementation
- **Current:** Check `PIPE_BUF_SIZE`
- **Should be:** 65536 (64KB, matching Linux default)
- **Why:** The kernel build uses pipes heavily (make | sh -c "..."). Small pipe buffers cause excessive context switches as writer blocks after every few KB.

### 14. Environment / Argument Passing (execve)
- **File:** `kernel/proc/execve.zig`
- **Current:** Check max argv/envp size
- **Should be:** 128KB combined (Linux's MAX_ARG_STRLEN = 131072)
- **Why:** Kernel build passes very long CFLAGS strings via environment. If the env block is truncated, zig cc gets incomplete flags → mysterious compilation failures.

---

## LOW PRIORITY — Future Scaling

### 15. SMP Scalability
- Per-CPU runqueues: ✅ done
- Per-CPU NVMe I/O queues: Not done (single io_lock). For SMP, create one I/O queue per CPU.
- TLB shootdown: Not implemented. Required for SMP correctness when unmapping shared pages.
- Per-CPU page cache locks: Current cache uses global access. With SMP, this becomes a bottleneck.

### 16. PMM Bitmap vs Buddy Allocator
- **Current:** Bitmap allocator (O(n) scan for contiguous pages)
- **Should consider:** Buddy allocator for O(log n) allocation of large contiguous blocks. allocPages(64) for kernel stacks scans the entire bitmap — slow under memory pressure.

### 17. VMA Tree (Future)
- **Current:** Linear array scan in findVma (O(n))
- **Should consider:** Red-black tree (O(log n)) when MAX_VMAS > 256. With 1024 VMAs, linear scan is ~1024 comparisons per page fault. At 100K page faults, that's 100M comparisons.

---

## Quick Reference — Recommended Values

| Constant | Current | Recommended | File |
|----------|---------|-------------|------|
| MAX_VMAS | 512 | 1024 | kernel/mm/vma.zig |
| MAX_FDS (system) | ~256 | 4096 | kernel/fs/vfs.zig |
| MAX_FDS (per-proc) | ~256 | 256 (fine) | kernel/proc/process.zig |
| MAX_PROCESSES | 256 | 512 | kernel/proc/process.zig |
| Page Cache entries | ? | 32768 | kernel/mm/page_cache.zig |
| tmpfs MAX_INODES | ? | 4096 | kernel/fs/tmpfs.zig |
| tmpfs MAX_DATA_PAGES | 4096 | 16384 | kernel/fs/tmpfs.zig |
| tmpfs per-file pages | 4096 | 16384 | kernel/fs/tmpfs.zig |
| Pipe buffer | ? | 65536 | kernel/fs/pipe.zig |
| NVMe queue depth | ? | 256 | kernel/drivers/nvme.zig |
| Futex wait queue | ? | 256 | kernel/proc/futex.zig |
| Kernel stack pages | 64 | 64 (fine) | kernel/proc/clone.zig |
| execve arg buffer | ? | 131072 | kernel/proc/execve.zig |

---

## Memory Budget (8GB RAM, recommended values)

| Component | Calculation | Size |
|-----------|------------|------|
| Process table (512 procs × ~70KB) | 512 × 70KB | 35 MB |
| Page cache (32K pages pinned) | 32768 × 4KB | 128 MB |
| Kernel stacks (256 active × 256KB) | 256 × 256KB | 64 MB |
| tmpfs data (64K pages) | 65536 × 4KB | 256 MB |
| PMM bitmap (8GB / 4KB / 8) | | 256 KB |
| NVMe queues + buffers | | ~4 MB |
| **Total kernel overhead** | | **~487 MB** |
| **Available for user pages** | | **~7.5 GB** |

This leaves 94% of RAM for user-space demand paging — more than enough for zig cc's 165MB working set plus the Linux source tree.
