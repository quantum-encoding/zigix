# Zigix Roadmap V2: U6 onwards — From "It boots" to "It ships"

The M1-M16 roadmap took Zigix from nothing to a working kernel: PMM, VMM, IDT, GDT, TSS, scheduler, syscalls, VFS, ext2, ELF loader, fork/exec, pipes, threads, futex, mmap, demand paging, CoW, signals.

The U1-U5 roadmap built the userspace: shell, init system, cross-compiled utilities, networking (virtio-net, TCP/IP, ARP, ICMP, UDP, DNS), and zcurl fetching web pages on bare metal.

**Status (Feb 2026):**

| Done | Milestone | What |
|------|-----------|------|
| M1-M7 | Kernel foundation | PMM, VMM, IDT, GDT, TSS, PIT, scheduler, syscalls |
| M8-M9 | Filesystem + ELF | VFS, ramfs, ext2 (read-only), ELF loader |
| M10 | Process lifecycle | fork, execve, wait4, pipes, dup2 |
| M11-M12 | Storage | virtio-blk, ext2 filesystem |
| M13 | Demand paging + CoW | Page fault handler, VMA tracking, ref counting |
| M14 | Threads | clone(CLONE_VM), futex, TLS (FS_BASE) |
| M15 | mmap | MAP_ANONYMOUS, MAP_PRIVATE, mprotect, munmap |
| U1 | Shell | zsh — freestanding Zig, line editing, builtins, fork+exec |
| U2 | Utilities | 126 musl cross-compiled utils + freestanding zping, zcurl, zgrep |
| U3 | Init | zinit — PID 1, fork+exec shell, reap children, respawn |
| U4 | Networking | virtio-net, Ethernet/ARP/IPv4/ICMP/UDP/TCP, socket syscalls |
| U5 | DNS + zcurl | DNS over UDP, HTTP/1.0 over TCP, fetches real websites |
| U6 | Pipes + zgrep | Shell pipelines, fd cleanup on exit, zombie memory reclamation |
| U7 | Signals + Job Control | Process groups, SIGSTOP/CONT/TSTP, Ctrl-C/Z, fg/bg/jobs/kill |
| U8 | /proc + /dev | procfs (status, exe, maps, uptime, meminfo), devfs (null, zero, urandom) |
| U10 | Env vars + PATH | export, $VAR expansion, PATH lookup, env builtins |
| U11 | Framebuffer console | Limine FB, 8x16 VGA font, VT100 escapes, dual serial+FB output |
| U12 | PS/2 Keyboard | IRQ 1 scancode Set 1 driver, shift/ctrl/caps lock, unified input |
| U13 | tmpfs | In-memory writable /tmp, create/write/unlink/truncate |
| U14 | ext2 write | Persistent writable ext2: alloc/free blocks+inodes, create/unlink, sync |
| U15 | Multi-User + Login | uid/gid on processes, /etc/passwd, permission checks, zlogin program |
| U16 | Shell scripting | if/then/else/fi, for/do/done, while/do/done, test/[, $?, ||, $(), #! shebang |
| U18 | SSH Server | zsshd — curve25519-sha256 + chacha20-poly1305 + ed25519, password auth, remote shell |
| U19 | HTTP Server | zhttpd — static file server, directory listing, Content-Type, 404 handling |
| U20 | Zero-copy networking | Shared ring architecture, zcnet_attach/detach/kick syscalls, zbench tool |

**Kernel:** ~7,600 lines of Zig | **Userspace:** ~5,600 lines across 14 freestanding programs
**Boot to shell:** ~2 seconds | **133 binaries in /bin/** | **128 MB ext2 image (4096-byte blocks)**
**Binary sizes:** 5-8 KB freestanding, 80-560 KB musl

---

## Tier 1: Unix Fundamentals (U6-U10) — "It's a real Unix"

Someone sits down at the serial console and can actually *do things*. Pipes, redirection, signals, job control, environment variables, dozens of utilities. This is where Zigix stops being a demo and starts being usable.

### U6: Shell Pipes + zgrep ✅

**Goal:** `zcurl http://example.com | zgrep title` — Unix pipeline primitive on bare metal.

**Status: COMPLETE**

**What was built:**

Shell pipeline parser+executor (~200 lines in zsh):
- Multi-stage pipelines: `cmd1 | cmd2 | cmd3` (up to 4 stages)
- Creates N-1 pipes, forks N children, dup2 stdin/stdout, close-all-fds pattern
- Builtins (`echo`, `cat`) work as pipeline stages via fork+builtin-in-child
- File redirection: `>`, `>>`, `<` with open+dup2 in child before exec
- Syscall wrappers: `sys_pipe` (nr 22), `sys_dup2` (nr 33)

Freestanding zgrep (~135 lines):
- Reads stdin byte-at-a-time, prints lines containing pattern to stdout
- Direct `int $0x80` syscalls — no musl, no std.Io dependency
- 5,296 bytes ELF

Kernel fixes (critical):
- **fd cleanup on exit**: `sysExit` closes all fds before zombie — pipe writers deliver EOF
- **Zombie memory reclamation**: `wait4` now calls `vmm.destroyAddressSpace()` + frees kernel stack pages (previously leaked ~100-400 KB per fork+exit)
- **Demand-paged stack VMA**: 1 MiB VMA (`USER_STACK_VMA_PAGES=256`) for musl binaries that need >16 KB stack
- **ELF buffer**: increased to 768 KB for largest musl binaries (zcurl 564 KB, zsort 389 KB, etc.)
- **TCP window**: advertise actual rx_buf free space instead of hardcoded 8192
- **sysRecvfrom**: set `waiting_pid` before blocking on TCP recv (fixed hung processes)

Build system:
- Freestanding zcurl/zping/zgrep copied LAST to override musl versions (musl std.Io needs io_uring/epoll which Zigix doesn't implement — writes silently fail)
- 133 binaries in /bin/, 128 MB ext2 image with 4096-byte blocks

**Verified working:**
```
zigix$ echo hello | zgrep hello
hello
zigix$ cat /etc/motd | zgrep Zigix
Welcome to Zigix!
zigix$ zcurl http://example.com | zgrep title
<!doctype html><html lang="en"><head><title>Example Domain</title>...
```

---

### U7: Signals + Job Control ✅

**Goal:** Ctrl-C sends SIGINT, `&` backgrounds processes, `fg`/`bg` manage jobs.

**Status: COMPLETE**

**What was built:**
- Process groups (pgid field, setpgid/getpgrp/getpgid syscalls 109/111/121)
- SIGSTOP/SIGCONT/SIGTSTP handling with stopProcess() and stopped state
- Serial Ctrl-C (0x03→SIGINT) and Ctrl-Z (0x1A→SIGTSTP) to foreground group
- wait4 WNOHANG + WUNTRACED support for polling and stopped child reporting
- Terminal foreground group (TIOCSPGRP/TIOCGPGRP via ioctl)
- Shell job table (8 slots), `&` background, `jobs`, `fg`, `bg`, `kill` builtins
- Shell ignores SIGINT/SIGTSTP, children restore default via rt_sigaction

**Why:** Without signals, a runaway process can only be killed by rebooting. Job control lets users multitask from a single terminal.

**Depends on:** U6 (shell maturity)

**Implementation:**

Kernel signal delivery (~300 lines):
- Signal pending bitmap per process (already have `sig_pending` field)
- `sys_kill(pid, sig)` syscall (nr 62) — set signal bit on target process
- `sys_rt_sigaction(sig, act, oldact)` syscall (nr 13) — register userspace handler
- `sys_rt_sigprocmask(how, set, oldset)` syscall (nr 14) — block/unblock signals
- Signal delivery: on return to userspace, check pending signals, divert to handler via signal trampoline frame
- Default actions: SIGINT/SIGTERM → kill, SIGSTOP → stop, SIGCONT → continue, SIGCHLD → ignore

Signal trampoline (~50 lines asm):
- Push interrupted context onto user stack
- Set RIP to signal handler
- After handler returns, `sys_rt_sigreturn` (nr 15) restores original context

Process groups (~100 lines):
- `sys_setpgid(pid, pgid)` syscall (nr 109)
- `sys_getpgrp()` syscall (nr 111)
- Terminal foreground process group — Ctrl-C sends SIGINT to foreground group

Shell job control (~200 lines in zsh):
- `&` suffix: don't wait, print `[1] <pid>`
- `jobs` builtin: list background jobs
- `fg %N`: bring job to foreground (SIGCONT + wait)
- `bg %N`: continue job in background (SIGCONT)
- Ctrl-C: send SIGINT to foreground process group
- Ctrl-Z: send SIGTSTP to foreground process group

**Pitfalls:**
- Signal delivery during syscall: must handle EINTR (restart or return error)
- Signal trampoline must be on the user stack with correct alignment
- Process group leader can't change its own group after children are created
- `waitpid` must report stopped children (WIFSTOPPED) for job control

**Verification:**
```
zigix$ sleep 10 &
[1] 5
zigix$ jobs
[1]+ Running    sleep 10
zigix$ fg %1
sleep 10
^C
zigix$
```

---

### U8: /proc + /dev ✅

**Goal:** `/proc/self/status`, `/dev/null`, `/dev/zero`, `/dev/urandom`. Virtual filesystems via VFS ops.

**Status: COMPLETE**

**What was built:**
- procfs: /proc/self/status, /proc/self/exe (readlink), /proc/self/maps, /proc/uptime, /proc/meminfo
- devfs: /dev/null (EOF read, discard write), /dev/zero (zero read), /dev/urandom (xorshift64), /dev/serial0
- Both mounted at boot via vfs.mount()

**Why:** System introspection. Many programs (including Zig's runtime) read `/proc/self/exe`. `/dev/null` and `/dev/zero` are essential Unix primitives.

**Depends on:** U6 (redirection to use /dev/null)

**Implementation:**

procfs (~200 lines):
- VFS backend: `procfs_read` returns generated text
- `/proc/self/status` — PID, state, memory usage
- `/proc/self/exe` — readlink returns path of current executable (critical for Zig)
- `/proc/self/maps` — VMA listing (useful for debugging)
- `/proc/uptime` — tick_count / 100
- `/proc/meminfo` — PMM free pages, total pages
- Mount at boot: `vfs.mount("/proc", procfs_root)`

devfs (~150 lines):
- `/dev/null` — read returns 0 (EOF), write discards
- `/dev/zero` — read returns zero bytes, write discards
- `/dev/urandom` — read returns pseudo-random bytes (LFSR or xorshift seeded from PIT)
- `/dev/serial0` — serial port (already exists as fd 0/1/2, formalize it)

**Pitfalls:**
- `/proc/self` must resolve `self` to the calling process's PID directory
- `readlink("/proc/self/exe")` is a separate syscall (nr 89) from read
- procfs entries are generated on read, not stored — size is unknown until read completes

**Verification:**
```
zigix$ zcat /proc/self/status
PID: 4
State: running
VmSize: 8 kB
zigix$ zcat /proc/meminfo
MemTotal: 126976 kB
MemFree: 125440 kB
zigix$ zecho test > /dev/null
zigix$ zhead -c 16 /dev/urandom | zhexdump
```

---

### U9: Mass Utility Import (partially complete)

**Goal:** Cross-compile 130+ Zig core utilities for Zigix. Bulk out `/bin/` with real tools.

**Status: BUILD COMPLETE** — 126 musl utils + 7 freestanding = 133 binaries in /bin/. Most haven't been individually tested on Zigix yet.

**What's already done (from U2/U6 work):**
- `make_ext2_img.sh` cross-compiles all `z*/` in `programs/zig_core_utils/` with `-Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall`
- 128 MB ext2 image with 4096-byte blocks (23.4 MB used)
- 768 KB ELF buffer in execve.zig handles largest musl binaries
- musl startup syscalls (sigaltstack, arch_prctl, set_tid_address) all stubbed
- Known issue: musl binaries using Zig's `std.Io` (buffered I/O) silently fail on Zigix — they need io_uring/epoll which Zigix doesn't implement. Simple utils that use `std.fs` directly work.

**Remaining work:**
- Test each utility individually — many will hit missing syscalls
- Implement commonly-needed syscalls as they surface: `getdents64` (nr 217) for zls, `stat/fstat` (nr 4/5), `lseek` (nr 8)
- For critical tools that fail due to std.Io: create freestanding versions (like zgrep, zcurl, zping)

**Verification target:**
```
zigix$ zls /bin
zcat  zcurl  zecho  zfalse  zgrep  zhead  zinit  zls  zpwd  zping
zsort  ztail  ztrue  zuname  zwc  ... (133 total)
zigix$ zseq 1 5 | zwc -l
5
```

---

### U10: Environment Variables + PATH ✅

**Goal:** `export`, `$HOME`, `$PATH` lookup, `.profile` on shell start. Programs inherit env via execve.

**Status: COMPLETE**

**What was built:**
- Shell env store (64 slots), export/unset/env builtins
- $VAR expansion in command parsing
- PATH lookup: split by `:`, search each directory for command
- Default env: PATH=/bin, HOME=/, SHELL=/bin/zsh

**Why:** Without PATH, you must type `/bin/zcat` instead of `zcat`. Without environment variables, programs can't find configuration, temp dirs, or the user's home directory.

**Depends on:** U9 (utilities to use PATH), U6 (shell maturity)

**Implementation:**

Kernel execve enhancement (~50 lines):
- Pass environment strings to child via the stack (Linux ABI: after argv, before auxvec)
- Already partially implemented — verify envp is copied correctly

Shell environment (~200 lines in zsh):
- `env` array: `[64]?[*:0]u8` — key=value strings
- `export VAR=value` — add/update in env array
- `$VAR` expansion in command parsing
- `$PATH` — split by `:`, search each directory for command name
- On startup: set defaults (`PATH=/bin`, `HOME=/`, `SHELL=/bin/zsh`)
- `.profile` — if `/etc/profile` exists, source it on startup (read + execute lines)

**Builtins to add:** `export`, `unset`, `env` (print all), `source`

**Pitfalls:**
- Environment is inherited on fork — must copy env array to child
- PATH search: try each directory, check file exists + is executable
- Variable expansion must handle edge cases: `$VAR`, `${VAR}`, unset vars → empty string
- `.profile` sourcing must not fork — execute builtins directly

**Verification:**
```
zigix$ export GREETING=hello
zigix$ zecho $GREETING
hello
zigix$ export PATH=/bin:/usr/bin
zigix$ zcat /proc/self/status
PID: 3
...
zigix$ env
PATH=/bin:/usr/bin
HOME=/
SHELL=/bin/zsh
GREETING=hello
```

---

## Tier 2: Self-Sufficient System (U11-U16) — "It runs real software"

Zigix can do actual work, not just demos. A framebuffer display, PS/2 keyboard, writable filesystems, multi-user security, and shell scripting. After Tier 2, Zigix is a standalone computer — no serial cable required.

### U11: Framebuffer + VGA Console ✅

**Goal:** Multiboot framebuffer, basic text rendering, VT100 escape codes. Visual output beyond serial.

**Status: COMPLETE**

**What was built:**
- Limine framebuffer request + response parsing (1024x768x32)
- 8x16 VGA bitmap font (95 printable ASCII glyphs, 1520 bytes)
- Text console: putChar, scroll, clearScreen, cursor tracking
- VT100 escape codes: cursor movement (A/B/C/D), position (H), erase (J/K), SGR colors (m)
- 16-color ANSI palette (standard 8 + bright 8)
- Dual output: serial + framebuffer for both kernel boot messages and userspace writes
- Console hook in serial.zig for kernel messages, direct call in fd_table.zig for userspace
- `run.sh --gui` flag for SDL display window

**Why:** Serial is fine for development but a real OS needs a screen. The framebuffer console is where users interact.

**Depends on:** U10 (shell is mature enough to drive a console)

**Implementation:**

Framebuffer driver (~200 lines):
- Limine provides framebuffer info in boot protocol response
- Linear framebuffer: `base_addr`, `width`, `height`, `pitch`, `bpp`
- Map framebuffer pages as write-combining (PAT/MTRR, or just uncacheable)
- `putPixel(x, y, color)`, `fillRect(x, y, w, h, color)`

Text console (~300 lines):
- 8x16 bitmap font (embedded, ~4 KB for 256 glyphs)
- `putChar(row, col, char, fg, bg)` — render glyph to framebuffer
- Scrolling: memmove the framebuffer up one row, clear bottom
- Cursor: blinking underscore via timer tick

VT100 escape code parser (~200 lines):
- `\033[nA` — cursor up, `\033[nB` — down, etc.
- `\033[2J` — clear screen
- `\033[0m` — reset, `\033[31m` — red, etc. (basic 8 colors)
- `\033[H` — home cursor
- Tab stops, line wrapping, backspace handling

Integration:
- fd 1/2 write goes to both serial AND framebuffer console
- fd 0 read still comes from serial (until U12 adds PS/2 keyboard)

**Pitfalls:**
- Framebuffer is 32-bit BGRA (or RGBA — check Limine format field)
- Scrolling by copying pixels is slow — consider a double-buffer or ring-buffer row scheme
- VT100 escape sequences can span multiple write() calls — must buffer partial sequences
- Font rendering at wrong BPP produces garbage — match font pixel writes to framebuffer format

**Verification:** Boot Zigix with `-display sdl` (instead of `-display none`), see text console with colored output.

---

### U12: PS/2 Keyboard Driver ✅

**Goal:** Scancode to ASCII, interrupt-driven input. Combined with framebuffer = standalone terminal.

**Status: COMPLETE**

**What was built:**
- IRQ 1 handler reads scancodes from port 0x60, translates via Set 1 table to ASCII
- Modifier tracking: Left/Right Shift, Ctrl, Caps Lock (toggle)
- Normal + shifted scancode tables (0x00–0x3A): letters, digits, symbols, Enter, Backspace, Tab, Space, Esc
- Ctrl+letter produces control codes 1–26 (Ctrl-C = 0x03, etc.)
- Extended scancodes (0xE0 prefix) silently skipped for now
- Unified input: pushes ASCII into serial.zig ring buffer via `pushInputByte()` — keyboard and serial share one input stream, existing blocking/wakeup works unchanged
- With U11 framebuffer, Zigix is now a standalone terminal (no serial cable required)

**Why:** With U11 + U12, Zigix is a standalone computer. No serial cable, no host terminal.

**Depends on:** U11 (display to see what you're typing)

**Implementation:**

PS/2 controller (~200 lines):
- I/O ports: 0x60 (data), 0x64 (status/command)
- IRQ 1 — keyboard interrupt
- Read scancode on IRQ, translate via scancode table
- Handle make/break codes (key down/up)
- Modifier tracking: Shift, Ctrl, Alt, CapsLock

Scancode table (~100 lines):
- Set 1 scancodes → ASCII mapping
- Shifted variants (a→A, 1→!, etc.)
- Special keys: Enter, Backspace, Tab, Arrow keys, F1-F12

Input integration:
- Keyboard IRQ writes to input ring buffer (same pattern as serial RX)
- fd 0 read pulls from keyboard buffer instead of (or in addition to) serial
- `waiting_pid` mechanism for blocking reads (same as serial)

**Pitfalls:**
- PS/2 controller may need initialization (self-test, enable first port)
- QEMU `-display sdl` or `-display gtk` required for keyboard input
- Scancode Set 1 vs Set 2 — QEMU typically uses Set 1 in legacy mode
- Must handle key repeat (auto-repeat generate multiple make codes)

**Verification:** Boot with display, type commands on the QEMU window (not serial).

---

### U13: tmpfs — In-Memory Writable Filesystem ✅

**Goal:** In-memory writable filesystem for /tmp. Programs can create, write, and delete files.

**Status: COMPLETE**

**What was built:**
- 128-inode pool, files up to 256KB (64 pages), directories with 32 children
- create, read, write (with O_APPEND), truncate, unlink, rmdir, readdir, lookup
- PMM page allocation on demand, free on unlink/truncate
- Mounted at `/tmp` during boot
- lseek (nr 8) and ftruncate (nr 77) syscalls added

**Why:** Currently ext2 is read-only. Shell redirection (`> file`), temp files, and build artifacts all need writable storage. tmpfs is simpler than ext2 write support.

**Depends on:** U6 (redirection needs writable target)

**Implementation:**

This is essentially a formalized version of the ramfs from M8, with proper create/write/delete:

tmpfs (~250 lines):
- Pool of 256 inodes, each with a linked list of 4 KB data pages
- `tmpfs_create(parent, name, mode)` — allocate inode, add dir entry
- `tmpfs_write(fd, data)` — extend file, allocate pages from PMM
- `tmpfs_unlink(parent, name)` — free data pages, free inode, remove dir entry
- `tmpfs_truncate(inode, size)` — shrink or extend file
- Mount at `/tmp` during init

**New syscalls (if not already present):**
- `creat` or `open` with O_CREAT (should already work via VFS)
- `unlink` (nr 87) — remove file
- `truncate` / `ftruncate` (nr 76/77) — resize file

**Pitfalls:**
- Data lost on reboot (by design — it's tmpfs)
- Must handle running out of PMM pages gracefully (return -ENOSPC)
- Directory operations must be atomic-ish (no half-created entries on error)

**Verification:**
```
zigix$ zecho "hello tmp" > /tmp/test.txt
zigix$ zcat /tmp/test.txt
hello tmp
zigix$ zrm /tmp/test.txt
zigix$ zcat /tmp/test.txt
zcat: /tmp/test.txt: No such file or directory
```

---

### U14: ext2 Write Support ✅

**Goal:** Write inodes, allocate blocks, create/delete files. `echo hello > file.txt` persists to disk across reboots.

**Status: COMPLETE**

**What was built:**
- Block bitmap: allocBlock/freeBlock — find free blocks, mark allocated/freed
- Inode bitmap: allocInode/freeInode — find free inodes, mark allocated/freed
- ext2Write: write data blocks, update i_block[], extend file
- ext2Create: allocate inode + add directory entry to parent
- ext2Unlink/ext2Rmdir: free data blocks, free inode, remove dir entry
- ext2TruncateVfs: shrink/grow file, free unused blocks
- sync() syscall (nr 162): flush dirty blocks to virtio-blk

**Verification:**
```
zigix$ echo "persistent data" > /hello_new.txt
zigix$ sync
zigix$ cat /hello_new.txt
persistent data
```

---

### U15: Multi-User + Login ✅

**Goal:** `/etc/passwd`, uid/gid on processes, permission checks, login program.

**Why:** Real Unix security model. Separate users can't read each other's files.

**Depends on:** U14 (writable ext2 for /etc/passwd)

**Implementation:**

User/group model (~200 lines):
- Process struct: add `uid`, `gid`, `euid`, `egid`
- `sys_getuid/setuid/getgid/setgid` syscalls
- File ownership: uid/gid stored in ext2 inode
- Permission checks: owner/group/other rwx bits on open/exec/stat

/etc/passwd parser (~100 lines):
- Format: `username:x:uid:gid:gecos:home:shell`
- `root:x:0:0:root:/root:/bin/zsh`
- `user:x:1000:1000:user:/home/user:/bin/zsh`

login program (~150 lines):
- Display "login: " prompt, read username
- Look up in /etc/passwd (no password check for MVP, or simple plaintext)
- setuid/setgid to user, chdir to home, exec shell
- zinit spawns login instead of shell directly

**Pitfalls:**
- Root (uid 0) bypasses all permission checks
- setuid can only be called by root (or to set euid back to real uid)
- Home directories must exist before login
- `su` command for switching users (bonus)

**Verification:**
```
Zigix v0.2

login: root
Welcome, root
zigix# whoami
root
zigix# exit
login: user
Welcome, user
zigix$ whoami
user
zigix$ zcat /root/secret.txt
zcat: Permission denied
```

---

### U16: Shell Scripting ✅

**Goal:** `if/then/fi`, `for/do/done`, `while/do/done`, `test`/`[ ]`, `$?`, `||`, `$()`, shebang.

**Status: COMPLETE**

**What was built:**

Shell enhancements (~500 lines in zsh):
- `$?` — last exit status variable
- `||` operator — execute next if previous failed (complements `&&`)
- `test` / `[ ]` builtin — file tests (-f, -d, -e), string tests (-z, -n, =, !=), integer compare (-eq, -ne, -lt, -gt, -le, -ge), `!` negation
- `if COND; then ... else ... fi` — conditional execution
- `for VAR in items; do ... done` — iteration with variable expansion
- `while COND; do ... done` — looping (max 1000 iterations)
- `$()` — command substitution via pipe+fork, captures stdout
- Control flow works in both scripts and interactive mode
- Nested if/for/while supported (depth tracking)

Kernel shebang support (~60 lines in execve.zig):
- Detects `#!` prefix when ELF header validation fails
- Parses interpreter path from shebang line
- Rebuilds argv: [interpreter, script_path, original_args...]
- Re-reads interpreter binary and proceeds with ELF loading

**Verification:**
```
zigix$ echo $?
0
zigix$ zfalse || echo "fallback"
fallback
zigix$ test -f /hello.txt && echo exists
exists
zigix$ for i in 1 2 3; do echo "Num: $i"; done
zigix$ if test -d /tmp; then echo "yes"; fi
zigix$ echo "I am in $(pwd)"
I am in /
```

---

## Tier 3: The Big Targets (U17-U21) — "This is production infrastructure"

These are the milestones that make Zigix relevant to the Quantum Zig Forge story — ultra-low-latency infrastructure. Each one exercises the entire stack. U20 (zero-copy networking) is the architectural keystone: it turns Zigix from "a hobby OS" into "the only OS where you can beat DPDK without bypassing the kernel."

### U17: Port the Zig Compiler [DONE]

**Goal:** Cross-compile Zig stage3 for Zigix. Run `zig build-exe hello.zig` on Zigix itself.

**Why:** Self-hosting is the holy grail for any OS. If Zigix can compile Zig, it can build anything.

**Depends on:** U14 (writable ext2), U9 (utilities), U8 (/proc/self/exe)

**Status: COMPLETE** — Kernel infrastructure ready for 165 MB Zig compiler binary.

**What was done:**
- Streaming demand-paged ELF loader (replaced 768 KiB buffer with file-backed VMAs)
- BSS-aware page fault handler (file_size boundary in VMAs)
- Inode pinning in ext2 cache (prevents eviction during demand paging)
- Linux-compatible stat struct (144 bytes)
- 17 new syscalls: pread64, pwrite64, access, sched_yield, madvise, dup, nanosleep, fcntl, rename, sched_getaffinity, newfstatat, faccessat, set_robust_list, pipe2, prlimit64, getrandom, rseq
- Expanded auxv: AT_PHDR, AT_PHENT, AT_PHNUM, AT_ENTRY, AT_UID/GID/EUID/EGID, AT_RANDOM, AT_CLKTCK
- Capacity increases: MAX_PROCESSES=64, MAX_FDS=128, MAX_VMAS=128, MAX_HEAP=256MB, PIPE_BUF=64KB, MAX_FILE_DESCRIPTIONS=512
- Read/write cap raised to 1 MiB, QEMU RAM to 1 GB, disk image to 1 GB with 4096 inodes
- ext2 cache: BLOCK_CACHE=128, INODE_CACHE=256
- Double-indirect block support in disk image builder
- /tmp directory, /hello.zig test file in disk image

**Verification:**
```
zigix$ zig version
0.16.0-dev.2510+bcb5218a2
zigix$ zig build-exe hello.zig
zigix$ ./hello
Hello from Zigix!
```

---

### U18: SSH Server ✅

**Goal:** `zsshd` — key exchange, encrypted channel, remote shell. Access Zigix over the network.

**Why:** Real remote access. Exercises the entire stack: networking, crypto, process management, terminal handling.

**Depends on:** U4 (networking) + U1 (shell) + U15 (multi-user auth)

**Implementation:**

Freestanding SSH-2 server with from-scratch crypto (~1800 lines, 22 KB binary):
- `userspace/zsshd/crypto.zig` — SHA-256, SHA-512, Curve25519, ChaCha20-Poly1305, Ed25519 (~900 lines)
- `userspace/zsshd/ssh.zig` — SSH-2 protocol state machine: version exchange, KEXINIT, curve25519-sha256 key exchange, key derivation, NEWKEYS, password auth via /etc/passwd, channel management (~600 lines)
- `userspace/zsshd/main.zig` — Server loop (fork-per-connection), shell spawning with pipe-based I/O, fork-based bidirectional relay (~200 lines)
- Single cipher suite: `curve25519-sha256` + `chacha20-poly1305@openssh.com` + `ssh-ed25519`
- Hardcoded Ed25519 host key (consistent fingerprint across boots)
- Password authentication against `/etc/passwd`
- Fork-based bidirectional relay: no shared mutable state, separate keys/seqs per direction

**Verification:**
```
# In QEMU with -netdev user,id=net0,hostfwd=tcp::2222-:22
zigix# zsshd &
zsshd: listening on port 22

# From host:
ssh -p 2222 -o KexAlgorithms=curve25519-sha256 \
    -o Ciphers=chacha20-poly1305@openssh.com \
    -o HostKeyAlgorithms=ssh-ed25519 \
    root@localhost
```

---

### U19: HTTP Server ✅

**Goal:** `zhttpd` — serve static files from ext2 over TCP.

**Why:** The networking stack goes full circle. Zigix serves content, not just fetches it.

**Status: COMPLETE**

**What was built:**

Freestanding `zhttpd` HTTP/1.0 server (~350 lines, 8,752 bytes ELF):
- Single-threaded accept loop: socket → bind → listen → accept → serve → close
- HTTP/1.0 request parser: extracts GET method and path from request line
- Static file serving: open → fstat (Content-Length) → read loop → write to client
- Directory listing: getdents64 → HTML index page with links
- Content-Type detection from file extension (.html, .txt, .sh, .json, .css, .js, .png, .jpg, .gif)
- 404/403/405/500 error responses with HTML bodies
- Path traversal protection: rejects `..` in URL paths
- Serial console logging: `GET /path → 200 1234`

Kernel bug fix (socket.zig):
- Fixed TCP `socketRead` EAGAIN wake: `conn.waiting_pid` now set when `read()` blocks on socket fd
- Without this fix, `read(client_fd)` would hang forever waiting for TCP data

Syscall library additions (sys.zig):
- Added `listen_sock`, `accept_sock`, `fstat`, `shutdown` wrappers + NR constants

Ext2 image:
- `/www/index.html` — default landing page with links to `/hello.txt`, `/etc/`, `/bin/`

**Verification:**
```
zigix# zhttpd &
zhttpd: listening on port 80
zigix# zcurl http://10.0.2.15/www/index.html
HTTP/1.0 200 OK
Content-Length: 215
Content-Type: text/html
...
# From host: curl http://localhost:8080/hello.txt
Hello from ext2!
```

---

### U20: Zero-Copy Networking — Shared Ring Architecture ✅

**Goal:** Userspace polls NIC packet rings directly via shared memory. No syscall, no interrupt, no copy in the hot path. Sub-microsecond packet processing.

**Status: COMPLETE**

**What was built:**
- Kernel `zcnet.zig` module: shared-memory packet ring (5 pages = 20 KiB control + 32 x 2048B buffers)
- Three new syscalls: `zcnet_attach(500)`, `zcnet_detach(501)`, `zcnet_kick(502)`
- virtio-net zero-copy branch: IRQ delivers to shared ring instead of kernel rx_ring
- Timer-driven TX drain + RX buffer repost in `net.poll()`
- Userspace `zcnet.zig` library: ZcNet struct with rxPoll/rxRelease/txAlloc/txSubmit
- `zbench` benchmark tool: 3-second RX poll test + 100-packet TX throughput test
- Process exit cleanup: automatic detach if owner process dies
- Coexistence: regular socket apps continue working when zc_mode is inactive

**Why this is the Zigix differentiator:**

The reason DPDK bypasses the Linux kernel is because Linux's networking stack is slow — sk_buff allocation, softirq processing, netfilter hooks, iptables traversal, protocol demuxing all add 5-15us per packet. DPDK's solution is to rip the NIC away from the kernel via VFIO and talk to registers from userspace. But that means you need a userspace driver for every NIC.

Zigix doesn't have sk_buffs, softirq, netfilter, or iptables. You control every instruction between the NIC and the application. So instead of "bypass the kernel," the architecture is **"the kernel is a thin zero-copy hardware abstraction"**:

```
Traditional Linux (5-15us/pkt):
  NIC → interrupt → softirq → sk_buff → netfilter → socket buf → copy_to_user → app

DPDK (<1us, hardware-specific):
  NIC registers → userspace PMD → app
  (kernel not involved, NIC bound to VFIO)

Zigix (<1us, ANY NIC with a Zigix driver):
  NIC → kernel driver fills shared ring → userspace polls ring → app
  (kernel handles hardware, userspace gets zero-copy access)
```

**The kernel's job reduces to three things:**
1. **PCI enumeration + BAR mapping** — find the NIC, map registers, load driver
2. **DMA setup** — allocate physical pages for descriptor rings and packet buffers, program the NIC's DMA engine
3. **Expose shared memory to userspace** — map the packet buffer pool and descriptor rings into the application's address space, then get out of the way

After setup, the hot path has **zero kernel involvement**. Userspace polls the ring directly. No syscall, no interrupt, no context switch, no copy. The NIC's DMA engine writes packets into shared memory that userspace can read directly.

**Depends on:** M15 (mmap), U4 (virtio-net driver), U14 (for persistent config)

**Implementation:**

Kernel shared ring interface (~300 lines):
- `sys_net_attach(nic_idx, queue_idx)` syscall — returns mmap-able fd for shared ring region
- Map the packet buffer pool (physical pages allocated for DMA) into userspace address space — same physical pages, two virtual mappings (kernel + user)
- Map descriptor ring (or shadow ring) into userspace
- NIC interrupt handler only fires for link-state changes and error conditions — normal RX/TX is pure polling

Userspace polling library (`zig_netstack`, ~500 lines):
- `rxBurst(ring, pkts, max)` / `txBurst(ring, pkts, count)` — poll ring head/tail pointers
- Zero-copy: packet data lives in the shared DMA region, no memcpy
- Batch processing: process 32-64 packets per poll iteration

```
┌─────────────────────────────────────────────────┐
│              Application                         │
│  (market_data_parser, financial_engine, etc.)    │
├─────────────────────────────────────────────────┤
│           Unified API: rxBurst / txBurst         │
├────────────┬──────────────┬─────────────────────┤
│  Linux:    │  Linux:      │  Zigix:              │
│  AF_XDP    │  Native PMD  │  Shared Ring         │
│  (any NIC) │  (Intel only)│  (any Zigix driver)  │
│            │              │                      │
│  Kernel    │  Userspace   │  Kernel driver       │
│  driver    │  driver via  │  sets up DMA +       │
│  handles   │  VFIO        │  shared memory,      │
│  hardware, │              │  then userspace      │
│  XDP gives │  Talks to    │  polls directly      │
│  zero-copy │  NIC regs    │                      │
│  rings     │  directly    │  No VFIO needed,     │
│            │              │  no UIO, no XDP —    │
│  Works w/  │  Hardware-   │  kernel IS ours      │
│  ANY NIC   │  specific    │                      │
└────────────┴──────────────┴─────────────────────┘
```

**How this differs from DPDK and AF_XDP:**
- **vs DPDK:** kernel still owns the NIC (can manage link state, error recovery, resource cleanup on process exit), but data plane is pure shared memory. No VFIO, no IOMMU translation overhead.
- **vs AF_XDP:** packets go NIC → DMA into shared buffer → userspace reads directly. No extra ring hop (AF_XDP has NIC → kernel driver → UMEM ring → userspace).

**What Zigix already has** for this:
- Physical memory manager: contiguous page allocation for DMA buffers
- Virtual memory manager: can map physical→virtual with arbitrary flags
- PCI enumeration: found virtio-net, can find any NIC
- virtio-net driver with descriptor rings
- mmap: can map kernel pages into userspace

**Competitive story:** "On Linux, we match DPDK performance on Intel hardware and work with any NIC via AF_XDP. On Zigix, we beat DPDK because there's no VFIO overhead, no IOMMU translation, and the kernel networking was designed for zero-copy from day one."

**Pitfalls:**
- DMA buffers must be physically contiguous and in the first 4 GB for some NICs (32-bit DMA)
- Shared ring protocol must handle producer/consumer races (memory barriers, cache line alignment)
- Process exit must reclaim shared ring resources — kernel tracks which process has what mapped
- virtio-net uses virtqueues (not raw descriptor rings) — shared ring is a shadow/translation layer

**Verification:**
```
zigix$ net_bench --mode poll --duration 5
Shared ring: 14.2 Mpps (0.07us/pkt)
zigix$ market_data_parser --nic 0 --queue 0
Parsing ITCH feed at 2.1 Gbps, 0 drops
```

---

### U21: Run a Quantum Zig Forge Program

**Goal:** Boot Zigix, run `timeseries_db` or `market_data_parser` or `zig-ai` on bare metal.

**Why:** The ultimate convergence — your OS running your software. The whole Quantum Zig Forge stack, from kernel to application, in Zig.

**Depends on:** U17 (Zig compiler for building), U19 (HTTP server for dashboard), U20 (zero-copy networking for market data)

**Vision:**
Boot Zigix → start HTTP server → start market data parser with zero-copy NIC access → serve dashboard showing live parsed data. All Zig, all bare metal, all yours.

**Verification:**
```
zigix$ timeseries_db &
[1] 5
zigix$ zhttpd -d /var/www &
[2] 6
zigix$ market_data_parser --nic 0 --queue 0 &
[3] 7
zigix$ zcurl http://localhost/api/status
{"db":"running","records":0,"uptime":"3s","pps":"14.2M"}
```

---

## Dependency Graph

```
Tier 1: Unix Fundamentals
U5 (DNS+zcurl) ✅
 │
 ├─► U6 (pipes+zgrep) ✅
 │    │
 │    ├─► U7 (signals+job control) ✅
 │    │    │
 │    │    └─► U12 (PS/2 keyboard) ✅
 │    │
 │    ├─► U8 (/proc + /dev) ✅
 │    │    │
 │    │    └─► U9 (test remaining utils)
 │    │         │
 │    │         └─► U10 (env vars + PATH) ✅
 │    │
 │    └─► U13 (tmpfs) ✅
 │
Tier 2: Self-Sufficient
 │
 ├─► U11 (framebuffer) ✅ ──► U12 (PS/2) ✅ ──► standalone terminal ✅
 │
 ├─► U13 (tmpfs) ✅ ──► U14 (ext2 write) ✅ ──► U15 (multi-user) ✅
 │
 └─► U16 (shell scripting) ✅ ◄── needs U10
 │
Tier 3: Big Targets
 │
 ├─► U17 (Zig compiler) ◄── needs U8, U9, U14
 │
 ├─► U18 (SSH server) ✅ ◄── needs U4, U1, U15
 │
 ├─► U19 (HTTP server) ◄── needs U14 (listen/accept ✅)
 │
 ├─► U20 (zero-copy networking) ✅ ◄── needs mmap, U4 driver model
 │
 └─► U21 (QZF on bare metal) ◄── needs everything, U20 for perf story
```

## Suggested Order

**Parallelizable quick wins (can be done in any order):**
- U13 (tmpfs) — small, independent, immediately useful
- U8 (/proc + /dev) — enables utility porting

**Critical path:**
U7 → U10 → U16 → U17

**Recommended session order:**
1. ~~U6 — pipes + zgrep~~ ✅
2. U13 — tmpfs (writable /tmp)
3. U8 — /proc + /dev (system introspection)
4. U9 — test remaining utilities (133 already built, need syscall stubs)
5. U10 — env vars + PATH (no more /bin/ prefix)
6. U7 — signals + job control (Ctrl-C, background jobs)
7. U11 — framebuffer console (visual output)
8. U12 — PS/2 keyboard (standalone terminal)
9. U14 — ext2 write (persistent storage)
10. U16 — shell scripting (automation)
11. U15 — multi-user + login (security)
12. U17 — port Zig compiler (self-hosting)
13. U18 — SSH server (remote access)
14. U19 — HTTP server (serve content)
15. U20 — zero-copy networking (shared ring architecture)
16. U21 — run QZF on bare metal (the convergence)

---

## Metrics

| Metric | Current (U6) | After Tier 1 | After Tier 2 | After Tier 3 |
|--------|-------------|-------------|-------------|-------------|
| Kernel lines | ~5,500 | ~7,000 | ~10,000 | ~12,000 |
| Userspace programs | 133 | 133+ | 140+ | 150+ |
| Syscalls | ~50 | ~70 | ~90 | ~120 |
| ext2 image size | 128 MB | 128 MB | 128 MB | 256 MB |
| Boot to shell | ~2s | ~2s | ~3s | ~3s |
| RAM required | 128 MB | 128 MB | 128 MB | 512 MB |
| Packet latency | timer-driven | timer-driven | timer-driven | <1us (shared ring) |
