# Zigix

A dual-architecture operating system kernel written in Zig, targeting self-hosting and Linux binary compatibility on bare-metal cloud hardware.

**Part of [Quantum Zig Forge](https://github.com/quantum-encoding/quantum-zig-forge) — a monorepo of production-grade Zig programs by QUANTUM ENCODING LTD.**

## Current Status

**Self-hosting achieved on ARM64.** The Zig compiler compiles itself on Zigix — bare-metal on Google Cloud Axion (c4a-standard-2, Neoverse-V2). `zig version`, `zig build-exe`, and the full linker phase all pass. 86,000+ processes created during the self-host test, 25 MB of serial output, zero crashes (v45c).

**40+ milestones complete** across two architectures. 138 syscall handlers on both aarch64 and x86_64. Runs unmodified Linux binaries (BusyBox 1.36.1: **10/10 pass**) on Google Cloud bare metal — both **ARM64** (C4A Axion / Neoverse-V2) and **x86_64** (C4D). ext4 filesystem with journal, gVNIC networking, DHCP, HTTP server serving real traffic cross-region. Direct TLS 1.3 to external APIs, sub-second boot. SMP on both architectures (2 CPUs, spinlock-based scheduler).

**Chaos Rocket safety system.** Typed addresses (`PhysAddr` ≠ `VirtAddr` at compile time), comptime struct layout assertions for all hardware descriptors, recovery handlers for demand paging, and validate-before-use inode cache. 17 compile-time unit tests + 8 runtime boot tests — all passing on bare metal.

### Kernel Milestones

| Milestone | Description | Status |
|-----------|-------------|--------|
| M1–M4 | Boot, GDT/IDT/PIC/PIT, PMM, 4-level VMM | Complete |
| M5–M6 | Ring 3 userspace (TSS, iretq), preemptive scheduler | Complete |
| M7–M9 | Syscall table, VFS + ramfs, ELF64 loader | Complete |
| M10–M12 | Pipes + blocking I/O, virtio-blk, ext2 read-only | Complete |
| M13–M16 | Demand paging, threads + futex, mmap, signals | Complete |

### Userspace Milestones

| Milestone | Description | Status |
|-----------|-------------|--------|
| U1 | Shell (zsh — freestanding Zig, line editing, builtins) | Complete |
| U2 | Cross-compiled utilities (132 musl static binaries) | Complete |
| U3 | Init system (zinit — PID 1, fork+exec, respawn) | Complete |
| U4 | TCP/IP networking (virtio-net, Ethernet/ARP/IPv4/TCP/UDP/ICMP) | Complete |
| U5 | DNS resolver + zcurl (HTTP/1.0 client) | Complete |
| U6 | Shell pipelines + zgrep (fd cleanup, zombie reclamation) | Complete |
| U7 | Signals + job control (process groups, Ctrl-C/Z, fg/bg/jobs) | Complete |
| U8 | /proc + /dev (procfs, devfs — null/zero/urandom) | Complete |
| U9 | Mass utility import (133 binaries in /bin/) | Complete |
| U10 | Environment variables + PATH lookup | Complete |
| U11 | Framebuffer console (Limine FB, VGA font, VT100 escapes) | Complete |
| U12 | PS/2 keyboard (IRQ 1, scancode Set 1, shift/ctrl/caps) | Complete |
| U13 | tmpfs (writable /tmp) | Complete |
| U14 | ext2 write (persistent block/inode alloc, sync) | Complete |
| U15 | Multi-user + login (uid/gid, /etc/passwd, zlogin) | Complete |
| U16 | Shell scripting (if/for/while, test, $?, shebang) | Complete |
| U17 | Zig compiler port (streaming demand-paged ELF, 165 MB binary) | Complete |
| U18 | SSH server (zsshd — curve25519, chacha20-poly1305, ed25519) | Complete |
| U19 | HTTP server (zhttpd — static files, directory listing) | Complete |
| U20 | Zero-copy networking (shared ring, zcnet syscalls, zbench) | Complete |

### Cloud + Hardware Milestones (aarch64)

| Milestone | Description | Status |
|-----------|-------------|--------|
| C1 | Google Cloud Axion (Neoverse-V2) bare-metal boot via UEFI | Complete |
| C2 | NVMe driver (PCI, admin + I/O queues, MSI-X) | Complete |
| C3 | gVNIC driver (DQO RDA, GCE virtual NIC, DHCP) | Complete |
| C4 | GICv3 + ITS (MSI-X LPI routing, device/collection tables) | Complete |
| C5 | ext4 filesystem (journal, extents, 64-bit, checksums, flex_bg) | Complete |
| C6 | FAT32 read-only (ESP auto-mount at /boot) | Complete |
| C7 | GPT partition table parser (Linux + ESP GUID detection) | Complete |
| C8 | Direct TLS 1.3 (HTTPS to api.anthropic.com, no relay) | Complete |
| C9 | TCP out-of-order reassembly (4-slot OOO queue per connection) | Complete |
| C10 | /proc filesystem (cpuinfo, meminfo, maps, exe, fd, version) | Complete |
| C11 | Signal handling (SIGTERM/INT/PIPE/CHLD/STOP/CONT, mask save/restore) | Complete |
| C12 | BusyBox 1.36.1 compatibility (400+ applets, **10/10 test pass**) | Complete |
| C13 | Two-machine distributed demo (AI chat + metrics TSDB) | Complete |
| C14 | **Self-hosting: Zig compiler compiles itself on Zigix ARM64** | Complete |
| C15 | Login shell (zlogin prompt on GCE serial console) | Complete |
| C16 | SMP scheduling (2 CPUs, spinlock-based, futex wake IPI) | Complete |
| C17 | **Chaos Rocket safety: typed addresses, comptime assertions, recovery handlers** | Complete |

### Self-Hosting Milestone (v45c — March 2026)

The Zig 0.16.0-dev compiler runs on Zigix and compiles itself. Tested on Google Cloud Axion (c4a-standard-2, ARM64, bare metal):

1. **`zig version`** — prints version string, exercises basic ELF loading + musl + stdout
2. **`zig build-exe /tmp/hello.zig`** — full compilation: tokenizer, parser, Sema, codegen (LLVM backend), 3.97 MB of object file output via ~5,000 ext2 write operations, 240,000+ NVMe commands
3. **Linker phase** — spawns a second thread (`clone(CLONE_VM|CLONE_THREAD)`), links the compiled object into an executable, exercises heavy mmap/munmap/futex under SMP scheduling pressure

The self-host test exercises virtually every kernel subsystem simultaneously: demand paging (thousands of page faults), SMP scheduling (dual-CPU futex ping-pong), ext2 file I/O (read compiler sources, write object files), NVMe (sustained 4KB random read/write), and process management (fork, clone, execve, wait4, exit_group).

Key bugs fixed during the self-host campaign (v41–v45):
- **SPSR validation false positive** — nested exception returns (EL1→EL1) legitimately have kernel SPSR; the diagnostic trap was killing the linker on every data_abort_same during syscall handling
- **DMA page pinning** — NVMe, gVNIC, GICv3 ITS, and virtio DMA pages now saturate PMM ref counts (defense-in-depth)
- **Non-page-aligned VMA demand paging** — partial first-page reads for file-backed mappings with sub-page VMA start addresses
- **Inode stale pointer re-resolution** — demand paging validates inode pointers and re-resolves from ext2 cache if evicted
- **Page cache pollution** — partial first-page reads no longer inserted into the page cache

Serial log: `demo_logs/selfhost-v45c-PASSED.log` (45,371 lines, PID 86,868)

### Chaos Rocket Safety System

Inspired by the Mars Climate Orbiter and Ariane 5 failures — compile-time prevention of unit confusion bugs and graceful runtime recovery.

**Typed addresses** (`kernel/safety/addr.zig`): `PhysAddr` and `VirtAddr` are distinct types parameterized by `Address(.physical)` vs `Address(.virtual)`. You cannot pass, compare, or assign between them without explicit conversion via `toVirt()`/`toPhys()`. Every VMM public API function uses typed addresses — 17 functions across `vmm.zig`, with callers updated in 12 files.

**Comptime struct assertions**: Every `extern struct` that maps to hardware gets `comptime { assert(@offsetOf(RxCompDesc, "buf_id") == 12); }` checks. The gVNIC `buf_id` offset bug (v50e, 20+ deploy iterations to find) becomes a compile error. Applied to gVNIC (5 structs) and NVMe (2 structs).

**Recovery handlers**: Demand paging maps a zero page on I/O failure instead of killing the process. The kernel stays stable — the process may crash on its own terms (SIGBUS from bad data), but other processes keep running. Covers: inode re-resolve failure, missing read function, read timeouts.

**Validate-before-use inode cache**: Every demand page fault re-resolves the inode via `ext2.loadInode(ino)` instead of trusting stale `FileDescription` pointers. With 2048 cache slots and 19K+ inodes, cache thrashing is guaranteed during self-host tests.

**Typed network boot state machine**: `NetPhase` enum (`.uninitialized` → `.dhcp` → `.running`) replaces the boolean `dhcp_complete` flag. Each phase owns the rx_ring exclusively — no consumer races by construction.

**Test coverage** (17 compile-time + 8 runtime):

```
$ zig test kernel/safety/addr.zig
17/17 tests passed

[typed-addr-test] 1: getKernelL0 non-null PASS
[typed-addr-test] 2: translate kernel VA PASS
[typed-addr-test] 3: translate unmapped=null PASS
[typed-addr-test] 4: create+destroy addr space PASS
[typed-addr-test] 5: mapPage+translate round-trip PASS
[typed-addr-test] 6: getPTE valid+user PASS
[typed-addr-test] 7: invalidatePage no crash PASS
[typed-addr-test] 8: syncCodePage no crash PASS
[typed-addr-test] Results: 8/8 ALL PASS
```

## Linux Binary Compatibility

Unmodified Linux binaries compiled with `aarch64-linux-musl` run on Zigix without modification. Proven with BusyBox 1.36.1 (400+ applets, 2.1 MB static binary) on Google Cloud Axion:

```
$ busybox --help        # 400+ applets listed
$ busybox ls /bin       # directory listing
$ busybox cat /proc/cpuinfo  # ARM Neoverse-V2 with full features
$ busybox cat /proc/meminfo  # 2 GB RAM, proper Linux format
$ busybox uname -a      # Zigix zigix 0.1.0 #1 SMP aarch64 GNU/Linux
$ busybox id            # uid=0 gid=0 groups=0
$ busybox free          # 2 GB RAM with formatted output
$ busybox uptime        # load averages working
```

All 10/10 test commands pass. Serial log: `demo_logs/busybox-10-10-bbm-fix.log`

## Architecture Overview

Zigix runs on two architectures with shared subsystem design:

```
┌──────────────────────────────────────────────────────────────────┐
│                        USERSPACE (Ring 3 / EL0)                  │
│                                                                  │
│  zinit (PID 1)  →  zlogin  →  zsh (shell scripting)             │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  BusyBox 1.36.1 (400+ applets, static aarch64-linux-musl)  │ │
│  │  132 zig_core_utils: zls zgrep zfind zawk zsed ztar zjq .. │ │
│  │  9 freestanding programs: zcurl zping zsshd zhttpd zbench . │ │
│  │  zigix_chat: AI chat server (TLS 1.3 → Claude API)         │ │
│  │  zigix_tsdb: Time-series metrics store                      │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                  │
│                    int 0x80 / syscall (x86_64)                   │
│                    SVC #0 (aarch64)                               │
├──────────────────────────────────────────────────────────────────┤
│                        KERNEL (Ring 0 / EL1)                     │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │  Syscall Dispatch — 138 handlers (both architectures)        ││
│  │  Linux ABI compatible: same numbers, same errno values       ││
│  └──────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌───────────────┐ ┌───────────────┐ ┌────────────────────────┐ │
│  │  Processes     │ │  Memory       │ │  Filesystem            │ │
│  │  64 slots      │ │  PMM bitmap   │ │  VFS vtable dispatch   │ │
│  │  fork/execve   │ │  4-level VMM  │ │  ext2/3/4 r/w, tmpfs  │ │
│  │  clone+futex   │ │  demand paging│ │  FAT32 (ESP), GPT     │ │
│  │  signals       │ │  mmap/brk     │ │  procfs, devfs, ramfs  │ │
│  │  job control   │ │  CoW fork     │ │  pipes (64 KB buffer)  │ │
│  │  epoll         │ │  hugepages    │ │  page cache (LRU 4096) │ │
│  └───────────────┘ └───────────────┘ └────────────────────────┘ │
│                                                                  │
│  ┌───────────────┐ ┌───────────────┐ ┌────────────────────────┐ │
│  │  Networking    │ │  Drivers      │ │  Arch-Specific         │ │
│  │  Ethernet/ARP  │ │  NVMe (PCI)   │ │  x86_64: PIC/PIT/TSS  │ │
│  │  IPv4/ICMP     │ │  gVNIC (GCE)  │ │          GDT/IDT       │ │
│  │  TCP + OOO     │ │  virtio-blk   │ │          serial COM1   │ │
│  │  UDP + DNS     │ │  virtio-net   │ │  aarch64: GICv3 + ITS  │ │
│  │  TLS 1.3       │ │  PCI bus scan │ │           PL011 UART   │ │
│  │  DHCP client   │ │  framebuffer  │ │           ARM timer    │ │
│  │  socket API    │ │  PS/2 kbd     │ │           UEFI boot    │ │
│  └───────────────┘ └───────────────┘ └────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

## Filesystem Stack

Seven filesystem implementations behind a unified VFS with operation vtables:

| Filesystem | Mount Point | Description |
|------------|-------------|-------------|
| ext4 | `/` (aarch64) | Full ext4 with journal, extents, 64-bit, checksums, flex_bg, metadata_csum |
| ext3 | `/` | ext4-compatible with journal (dirty shutdown replay, fsync, fdatasync) |
| ext2 | `/` (x86_64) | Read/write, block/inode cache (128/256 entries), double-indirect blocks |
| FAT32 | `/boot` | Read-only, auto-mounted from GPT ESP partition |
| tmpfs | `/tmp` | In-memory writable storage, auto-cleared |
| procfs | `/proc` | 13 entries: cpuinfo, meminfo, version, stat, loadavg, filesystems, self/{maps,exe,fd,cmdline,status} |
| devfs | `/dev` | Device nodes: null, zero, urandom, serial0 |
| ramfs | (early boot) | In-memory filesystem before disk is available |

### ext4 Features

- **Journal** (ext3/ext4): transaction commit, fsync/fdatasync, dirty shutdown replay
- **Extents**: B-tree extent mapping (replaces indirect blocks)
- **64-bit mode**: 64-byte group descriptors, >2TB filesystem support
- **Checksums**: CRC32c metadata checksums (superblock, group descriptors, inodes)
- **Flexible block groups**: flex_bg for improved locality
- **256-byte inodes**: nanosecond timestamps, extra fields
- **Page cache**: LRU eviction, 4096-entry cache with readahead

### Test Results (aarch64 bare metal)

```
typed-addr-test: 8/8 ALL PASS (getKernelL0, translate, unmapped, create/destroy,
                                mapPage round-trip, getPTE, invalidatePage, syncCodePage)
ext3-test:       9/9 ALL PASS (fsync, fdatasync, sendfile, rename, directory ops,
                                multi-block fsync, sync, lseek, create/delete stress)
fs-test:         20/20 ALL PASS (hard links, symlinks, ftruncate, chmod, statfs,
                                  fallocate, stat, unlink, large file, pipe, rename,
                                  dup2, copy_file_range, xattr, inotify, FIFO,
                                  fcntl lock, hole punch, inotify events)
addr.zig:        17/17 ALL PASS (zero/null, page alignment, index round-trip,
                                  HHDM identity + offset, comparisons, type safety)
```

### GPT + FAT32

The GPT parser (`gpt.zig`) reads the partition table at boot to find the ext4 root partition and ESP. FAT32 (`fat32.zig`) provides read-only access to the EFI System Partition, auto-mounted at `/boot`. This supports the UEFI boot chain on GCE.

## aarch64 Kernel — Google Cloud Axion

The aarch64 port runs on Google Cloud C4A instances (Axion / Neoverse-V2 / ARMv9.2) as a bare-metal OS. Zigix boots via UEFI, takes ownership of the hardware, and serves real traffic.

### Hardware

| Component | Implementation |
|-----------|---------------|
| Boot | UEFI PE32+ bootloader, GPT disk, NVMe root |
| CPU | ARM Neoverse-V2 (ARMv9.2), 2 CPUs (SMP): SVE, PAuth, BTI, RNG, PAN |
| Interrupt | GICv3 + ITS (Interrupt Translation Service for MSI-X LPIs) |
| Timer | ARM Generic Timer (CNTPCT_EL0, 100 Hz tick) |
| Storage | NVMe (PCI, admin + I/O completion queues, MSI-X) |
| Network | gVNIC (Google Virtual NIC, DQO RDA mode, DHCP auto-config) |
| Serial | PL011 UART at `0x09000000` (GCE serial console) |
| ACPI | RSDP/XSDT/MADT/MCFG/GTDT parsing for hardware discovery |
| MMU | 4-level page tables, ARM64 break-before-make compliant |

### Deployment Pipeline

```bash
# 1. Build on Axion VM (native ARM64, no cross-compilation)
ssh zigix-axion
cd quantum-zig-forge/zigix
zig build -Darch=aarch64 -Dcpu=neoverse_n2
cd bootloader && zig build && cd ..

# 2. Build userspace + ext4 disk image
python3 make_ext4_img.py ext4-aarch64.img ...

# 3. Create GCE disk image (GPT + ESP + ext4 root)
python3 make_gce_disk.py disk.raw bootloader/zig-out/bin/BOOTAA64.efi \
    zig-out/bin/zigix-aarch64 ext4-aarch64.img

# 4. Upload and create GCE image
tar -czf zigix.tar.gz disk.raw
gsutil cp zigix.tar.gz gs://YOUR_BUCKET/
gcloud compute images create zigix-latest \
    --source-uri=gs://YOUR_BUCKET/zigix.tar.gz \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC \
    --architecture=ARM64

# 5. Boot bare-metal instance
gcloud compute instances create zigix-test \
    --machine-type=c4a-standard-1 \
    --image=zigix-latest \
    --zone=europe-west4-a

# 6. Read serial output
gcloud compute instances get-serial-port-output zigix-test
```

### 138+ Implemented Syscalls (aarch64)

The aarch64 port implements 138+ Linux syscall handlers covering process management, memory, filesystem, networking, signals, and compatibility:

**Process:** read(63), write(64), writev(66), pwritev(286), openat(56), close(57), fstat(80), newfstatat(79), lseek(62), mmap(222), mprotect(226), munmap(215), brk(214), clone(220), execve(221), exit(93), exit_group(94), wait4(260), getpid(172), getppid(173), gettid(178), getuid(174), getgid(176), geteuid(175), getegid(177), getgroups(158), set_tid_address(96), sched_yield(124), nanosleep(101), clock_gettime(113), uname(160), getcwd(17), chdir(49), pipe2(59), dup(23), dup2(dup3:24), fcntl(25), ioctl(29), access(faccessat:48), readlinkat(78), mkdirat(34), unlinkat(35), renameat(38), ftruncate(46), fallocate(47), statfs(43), fstatfs(44), sendfile(71), copy_file_range(285), getdents64(61), prlimit64(261), getrandom(278), sysinfo(179), setitimer(103), sched_getaffinity(123), set_robust_list(99), rseq(293)

**Threads + Signals:** futex(98), rt_sigaction(134), rt_sigprocmask(135), rt_sigreturn(139), kill(129), tkill(130), tgkill(131)

**Networking:** socket(198), connect(203), accept(202), sendto(206), recvfrom(207), bind(200), listen(201), shutdown(210), setsockopt(208), getsockopt(209), ppoll(73)

**Filesystem Extended:** fchmod(52), fchmodat(53), fchown(55), utimensat(88), fsync(82), fdatasync(83), sync(81), flock(32), splice(76), tee(77), fsetxattr(7), fgetxattr(10), flistxattr(13), fremovexattr(16), inotify_init1(26), inotify_add_watch(27), inotify_rm_watch(28), epoll_create1(20), epoll_ctl(21), epoll_pwait(22), mknod(mknodat:33)

## x86_64 Kernel — Google Cloud C4D + QEMU

Dual boot path: UEFI bootloader for GCE bare metal, Limine for QEMU development. Runs on Google Cloud C4D instances (AMD Turin / EPYC 5th gen) with NVMe storage and gVNIC networking. Full userspace, HTTP server, login prompt — feature parity with aarch64.

**Proven on GCE c4d-standard-2** (2 vCPU, 8 GB RAM, 10 GB NVMe, gVNIC):
- UEFI boot → NVMe (3-level PCIe bridge scan) → GPT → ext2 mount
- gVNIC: DQO RDA, MSI-X, DHCP auto-config, link UP, HTTP serving
- `curl http://<internal-ip>/` returns directory listing from zhttpd
- 138 syscall handlers, zinit + zlogin + zhttpd + BusyBox
- `zig build-exe /tmp/hello.zig` passes — compilation + linking
- SMP: 2 CPUs via ACPI MADT, LAPIC timer, IOAPIC routing
- Cross-region HTTP test: ARM64 build machine (europe-west4) → x86_64 Zigix (us-central1)

### Hardware Layer

| Component | Implementation |
|-----------|---------------|
| Boot | UEFI PE32+ bootloader (GCE) / Limine (QEMU), HHDM at `0xFFFF800000000000` |
| GDT | 7 entries: null, kernel CS/DS, user CS/DS, TSS (16-byte descriptor) |
| IDT | 256 vectors via comptime-generated stubs, DPL=3 for vector 0x80 |
| PIC | 8259A remapped to vectors 32–47 |
| PIT | 100 Hz (10 ms ticks) |
| Serial | COM1 at 0x3F8 (primary console, GCE serial port) |
| TSS | Per-thread RSP0 for ring transitions |
| Storage | NVMe (PCIe bridge recursive scan, admin + I/O queues) |
| Network | gVNIC (Google Virtual NIC, DQO RDA, DHCP) / virtio-net (QEMU) |
| ACPI | RSDP/XSDT/MADT/MCFG parsing (2 CPUs, ECAM, IOAPIC) |

### Cloud + Hardware Milestones (x86_64)

| Milestone | Description | Status |
|-----------|-------------|--------|
| X1 | UEFI PE32+ bootloader (ExitBootServices, page tables, kernel jump) | Complete |
| X2 | GCE c4d bare-metal boot (8 GB RAM, 2 CPUs via ACPI MADT) | Complete |
| X3 | PCIe bridge recursive scan (3-level topology, 12 devices) | Complete |
| X4 | NVMe driver (behind PCIe bridges, 10 GB disk, 4096 queue depth) | Complete |
| X5 | GPT partition table parser (ESP + Linux root detection) | Complete |
| X6 | ext2 filesystem mount (block cache, inode cache, ext3 journal) | Complete |
| X7 | gVNIC driver port (DQO RDA, MSI-X, BAR0/BAR1/BAR2 MMIO) | Complete |
| X8 | DHCP client (GCE internal IP auto-configuration) | Complete |
| X9 | Full userspace (zinit, zhttpd port 80, zlogin, BusyBox) | Complete |
| X10 | Cross-region HTTP demo (curl from ARM64 → x86_64 Zigix) | Complete |
| X11 | Structured kernel logger (klog — comptime filtering, ring buffer) | Complete |
| X12 | **zig build-exe passes** (compilation + linking, self-host in progress) | Complete |
| X13 | SMP boot (2 CPUs via ACPI MADT, LAPIC/IOAPIC) | Complete |

### Deployment Pipeline (x86_64 / GCE)

```bash
# 1. Cross-compile on ARM64 build machine (or native x86_64)
ssh zigix-axion
cd quantum-zig-forge/zigix
zig build -Darch=x86_64
cd bootloader_x86 && zig build && cd ..

# 2. Build userspace + ext2 disk image
for prog in zsh zinit zlogin zping zcurl zgrep zbench zhttpd zsshd; do
    (cd userspace/$prog && zig build)
done
python3 make_ext2_img.py ext2-x86.img ...

# 3. Create GCE disk image (GPT + ESP + ext2 root)
python3 make_gce_disk_x86.py disk-x86.raw \
    bootloader_x86/zig-out/bin/BOOTX64.efi \
    zig-out/bin/zigix ext2-x86.img

# 4. Upload and create GCE image
tar -czf zigix-x86.tar.gz disk.raw
gsutil cp zigix-x86.tar.gz gs://YOUR_BUCKET/
gcloud compute images create zigix-x86-latest \
    --source-uri=gs://YOUR_BUCKET/zigix-x86.tar.gz \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC \
    --architecture=X86_64

# 5. Boot bare-metal instance
gcloud compute instances create zigix-x86-test \
    --machine-type=c4d-standard-2 \
    --network-interface=nic-type=GVNIC \
    --image=zigix-x86-latest \
    --zone=us-central1-a
```

### 138 Implemented Syscalls (x86_64)

**Process:** read(0), write(1), open(2), close(3), stat(4), fstat(5), lseek(8), mmap(9), mprotect(10), munmap(11), brk(12), pread64(17), pwrite64(18), writev(20), access(21), pipe(22), sched_yield(24), madvise(28), dup(32), dup2(33), nanosleep(35), getpid(39), fork(57), execve(59), exit(60), wait4(61), kill(62), uname(63), fcntl(72), ftruncate(77), getcwd(79), chdir(80), rename(82), mkdir(83), rmdir(84), unlink(87), readlink(89), getuid(102), setuid(105), getgid(104), setgid(106), geteuid(107), getegid(108), setpgid(109), getpgrp(111), getpgid(121), sigaltstack(131), arch_prctl(158), sync(162), getppid(110), getdents64(217), clock_gettime(228), exit_group(231), openat(257), newfstatat(262), faccessat(269), set_robust_list(273), pipe2(293), prlimit64(302), getrandom(318), rseq(334)

**Threads:** clone(56), futex(202), set_tid_address(218), gettid(186), tkill(200), tgkill(234)

**Signals:** rt_sigaction(13), rt_sigprocmask(14), rt_sigreturn(15)

**Networking:** socket(41), connect(42), accept(43), sendto(44), recvfrom(45), shutdown(48), bind(49), listen(50), setsockopt(54), getsockopt(55)

## Networking Stack

Full Layer 2–4 TCP/IP stack implemented from scratch:

```
Application:  zcurl, zsshd, zhttpd, zigix_chat (TLS 1.3)
TLS:          TLS 1.3 via Zig std.crypto.tls (direct HTTPS)
Transport:    TCP (state machine, OOO reassembly) / UDP
Network:      IPv4 / ICMP echo / DHCP client
Link:         Ethernet / ARP (cache + resolution)
Driver:       gVNIC (GCE) / virtio-net (QEMU) / zero-copy rings
```

### Direct TLS 1.3

Zigix establishes TLS 1.3 connections directly from bare metal — no relay or proxy. The AI chat server (`zigix_chat`) makes HTTPS requests to `api.anthropic.com` using Zig's `std.crypto.tls` with custom socket-backed I/O vtables. Demonstrated on GCE with real Claude API calls.

### TCP Out-of-Order Reassembly

The TCP stack handles reordered segments with a 4-slot per-connection OOO queue. Early-arriving segments are buffered and delivered in order once the gap is filled. Required for TLS 1.3 reliability over real networks.

## Custom Userspace Programs

Nine freestanding programs written in Zig using direct `SVC #0` / `int $0x80` syscalls (no musl dependency). Binary sizes range from 5–96 KB.

| Program | Size | Description |
|---------|------|-------------|
| zinit | 97 KB | Init system (PID 1) — boot tests, zig self-host, conditional BusyBox tests, respawn |
| zsh | 87 KB | Shell — line editing, 26 builtins, pipes, job control, **script mode** (`zsh /path/to/script.sh`) |
| zlogin | 68 KB | Login program — /etc/passwd auth, uid/gid switching |
| zping | 67 KB | ICMP ping — raw socket, checksum, RTT measurement |
| zgrep | 67 KB | Grep — substring matching, works in shell pipelines |
| zcurl | 69 KB | HTTP client — **dynamic DNS** (`/etc/resolv.conf` or fallback 10.0.2.3), HTTP/1.0 |
| zhttpd | 71 KB | HTTP server — static file serving, directory listing, Content-Type, fork-per-connection |
| zsshd | 83 KB | SSH server — curve25519-sha256, chacha20-poly1305, ed25519 host keys |
| zbench | ~8 KB | Network benchmark — zero-copy shared ring throughput testing |

## Building & Running

### Requirements

- Zig 0.16.0-dev
- Python 3 (for ext4/ext2 image generation)
- For x86_64: QEMU + xorriso (for ISO)
- For aarch64/GCE: `gcloud` CLI, GCE project with C4A quota

### Quick Start (x86_64 / QEMU)

```bash
cd zigix

# Build kernel + userspace + disk image + ISO, then launch QEMU
bash run.sh

# With SDL framebuffer window
bash run.sh --gui
```

### Quick Start (aarch64 / Google Cloud)

```bash
cd zigix

# Build for ARM64
zig build -Darch=aarch64 -Dcpu=neoverse_n2
cd bootloader && zig build && cd ..

# Build ext4 image and GCE disk
python3 make_ext4_img.py ext4-aarch64.img $SHELL_BIN $EXTRA_DIR test_scripts
python3 make_gce_disk.py disk.raw bootloader/zig-out/bin/BOOTAA64.efi \
    zig-out/bin/zigix-aarch64 ext4-aarch64.img

# Deploy to GCE (see deploy_axion.sh for full workflow)
tar -czf zigix.tar.gz disk.raw
gsutil cp zigix.tar.gz gs://YOUR_BUCKET/
gcloud compute images create zigix-latest \
    --source-uri=gs://YOUR_BUCKET/zigix.tar.gz \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC --architecture=ARM64
gcloud compute instances create zigix-test \
    --machine-type=c4a-standard-1 --image=zigix-latest
```

## System Limits

| Resource | Limit |
|----------|-------|
| Processes | 64 |
| FDs per process | 128 (256 on aarch64) |
| Global file descriptions | 2,048 |
| VMAs per process | 8,192 (required for Zig compiler's mmap pressure) |
| Inode cache | 2,048 entries (FIFO eviction, pin support) |
| Kernel stack | 64 KB per process (16 pages, canary at bottom) |
| Heap (brk) | 256 MiB |
| User stack VMA | 48 MiB |
| Pipe buffer | 64 KB |
| Page cache | 4,096 entries (LRU) |
| RAM | Tested up to 32 GB (GCE c4a-standard-8) / 8 GB (c4d-standard-2) / 1 GB (QEMU) |
| CPUs | 2 (SMP, tested on both c4a and c4d) |
| Disk image | 2 GB GPT (100 MB ESP + ~1.9 GB ext2/ext4 root) |

## Design Principles

**Linux syscall ABI compatibility.** Same syscall numbers, same register conventions, same errno values. Programs compiled with `zig build -Dtarget=aarch64-linux-musl` or `x86_64-linux-musl` run on Zigix without modification. BusyBox 1.36.1 (400+ applets) runs 10/10.

**Demand paging everywhere.** `brk`, `mmap`, and `execve` create VMAs without allocating physical pages. First access triggers a page fault that allocates and maps a zero page (or reads from a file-backed inode via the page cache). ARM64 block descriptor splitting uses proper break-before-make protocol.

**Real hardware, not just emulators.** Zigix runs on Google Cloud bare metal on **both architectures**: ARM64 (C4A Axion / Neoverse-V2 with GICv3+ITS) and x86_64 (C4D AMD Turin with LAPIC/IOAPIC). Both use NVMe storage, gVNIC networking, and DHCP. HTTP server tested cross-region (ARM64 europe-west4 → x86_64 us-central1). QEMU path exists for development convenience.

**Zig all the way down.** Kernel, init, shell, utilities — everything is Zig. Zero separate `.asm` files. Context switches work by overwriting `TrapFrame` in-place. Signal delivery pushes trampoline code onto the user stack.

**Dual architecture.** x86_64 is the reference; aarch64 is the cloud deployment target. All subsystems above the hardware abstraction layer (VFS, ext2/3/4, TCP/IP, scheduler, process management) are shared without modification.

## Project Structure

```
zigix/
├── kernel/
│   ├── main.zig                           Entry point
│   ├── arch/
│   │   ├── x86_64/                        8 files
│   │   │   ├── gdt.zig, idt.zig, pic.zig, pit.zig
│   │   │   ├── serial.zig, tss.zig, io.zig
│   │   │   └── syscall_entry.zig
│   │   └── aarch64/                       50+ files
│   │       ├── boot.zig                   UEFI boot, ACPI, FDT
│   │       ├── uart.zig                   PL011 UART
│   │       ├── gic.zig                    GICv3 + ITS
│   │       ├── timer.zig                  ARM Generic Timer
│   │       ├── exception.zig              Exception vectors, demand paging
│   │       ├── vmm.zig                    4-level VMM, BBM-compliant splits
│   │       ├── pmm.zig                    Bitmap PMM + ref counts
│   │       ├── syscall.zig                138+ syscall handlers
│   │       ├── nvme.zig                   NVMe driver (PCI, MSI-X)
│   │       ├── gvnic.zig                  gVNIC driver (DQO RDA)
│   │       ├── gpt.zig                    GPT partition parser
│   │       ├── fat32.zig                  FAT32 read-only driver
│   │       ├── dhcp.zig                   DHCP client
│   │       ├── tcp.zig                    TCP + OOO reassembly
│   │       ├── page_cache.zig             LRU page cache (4096 entries)
│   │       ├── signal.zig                 Signal delivery + mask
│   │       ├── procfs.zig                 /proc filesystem
│   │       ├── epoll.zig                  epoll (8 instances, 64 entries)
│   │       └── ...
│   ├── drivers/
│   │   ├── nvme.zig                       NVMe (shared, PCIe bridge scan)
│   │   ├── gvnic.zig                      gVNIC x86_64 port (DQO RDA)
│   │   ├── nic.zig                        NIC abstraction (gVNIC / virtio-net)
│   │   ├── pci.zig                        PCI bus scanner (recursive bridges)
│   │   ├── virtio_blk.zig, virtio_net.zig Virtio drivers (QEMU)
│   │   └── console.zig, ps2_keyboard.zig  Console / input
│   ├── fs/
│   │   ├── ext2.zig                       ext2 read/write
│   │   ├── ext3/                          Journal (types, replay, write)
│   │   ├── ext4_module.zig                ext4 features (extents, 64-bit, checksums)
│   │   ├── gpt.zig                        GPT partition parser (shared)
│   │   └── vfs.zig, ramfs.zig, tmpfs.zig, procfs.zig, devfs.zig, pipe.zig
│   ├── safety/
│   │   ├── addr.zig                       Typed address system (PhysAddr ≠ VirtAddr, 17 tests)
│   │   └── recovery.zig                   Failure recovery registry (comptime-defined chains)
│   ├── klog/                              Structured kernel logger
│   │   ├── klog.zig                       Public API (scoped, comptime filtering)
│   │   ├── ring.zig                       Lock-free ring buffer (4096 entries, .bss)
│   │   ├── subsystems.zig                 42 subsystem registry
│   │   ├── serial_sink.zig                Drain to serial (runtime filter bitmask)
│   │   ├── format.zig                     [tick][LVL][sub] msg key=value formatter
│   │   └── command.zig                    Serial command parser (>filter, >dump, >stats)
│   ├── net/
│   │   ├── dhcp.zig                       DHCP client (shared)
│   │   ├── tcp.zig, ipv4.zig, arp.zig    TCP/IP stack
│   │   └── ethernet.zig, icmp.zig, udp.zig, socket.zig
│   └── ...
├── bootloader/                            UEFI PE32+ bootloader (aarch64)
├── bootloader_x86/                        UEFI PE32+ bootloader (x86_64)
├── userspace/
│   ├── zinit/                             Init + BusyBox test suite
│   ├── zsh/, zlogin/, zcurl/, zping/
│   ├── zhttpd/, zsshd/, zgrep/, zbench/
│   └── ...
├── programs/
│   ├── zigix_chat/                        AI chat server (TLS 1.3 → Claude)
│   └── zigix_tsdb/                        Time-series metrics store
├── make_ext4_img.py                       ext4 image builder (Python)
├── make_gce_disk.py                       GCE disk image builder (GPT + ESP)
├── deploy_axion.sh                        GCE deployment automation
├── demo_logs/                             Proof artifacts (serial logs)
│   ├── selfhost-v45c-PASSED.log           Self-host PASSED (45K lines, PID 86K)
│   ├── selfhost-v43f-canary-intact.log    Stack canary diagnosis (DMA vs overflow)
│   ├── selfhost-v44-dma-pinned.log        NVMe DMA pinning test
│   ├── selfhost-v44e-lockfree.log         Lock-free crash UART diagnostics
│   ├── busybox-10-10-bbm-fix.log         BusyBox 10/10 on Axion (ARM64)
│   ├── x86-gce-v32-http-working.log      HTTP 200 OK cross-region test
│   ├── x86-gce-selfhost-v3.log           x86 zig build-exe pass
│   └── shell-v5-rx-working.log           gVNIC RX completions arriving
└── build.zig                              Zig build system
```

## Related Projects

Zigix is part of the Quantum Zig Forge monorepo:

- **zig_core_utils** — 132 GNU coreutils replacements with SIMD acceleration (10x faster `find`, SIMD `grep`/`sha256sum`)
- **zig_inference** — ML inference engine (GGUF/LLaMA, Whisper transcription, Piper TTS)
- **zig_ai** — Universal AI CLI (Claude, Gemini, Grok, GPT-5.2) with agent mode and native tool calling
- **http_sentinel** — Production HTTP client library with AI provider backends
- **zig_pdf_generator** — Cross-platform PDF library with C FFI and WebAssembly

## License

MIT License — QUANTUM ENCODING LTD

```
Copyright 2025-2026 QUANTUM ENCODING LTD
Website: https://quantumencoding.io
Contact: rich@quantumencoding.io
```
