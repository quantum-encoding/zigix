# Zee eBPF — Zigix Kernel Security Subsystem

## Overview

Zee eBPF is the kernel-native security policy enforcement layer for Zigix.
It provides the same protection model as Guardian Shield's userspace
implementations (libwarden, libmacwarden, es_warden) but enforced at the
only layer that cannot be bypassed: inline in the kernel's VFS dispatch path,
compiled in at build time.

### The Problem

Guardian Shield has three implementations of the same security model:

| Layer | Mechanism | Bypassable? |
|---|---|---|
| **libwarden** (Linux) | LD_PRELOAD syscall interception | Yes — static binaries, dlopen, direct syscall |
| **libmacwarden** (macOS) | DYLD interposition | Yes — hardened binaries, raw syscalls |
| **es_warden** (macOS) | Endpoint Security framework | No — but requires Apple entitlement |

All three enforce the same model: **protected paths checked against a
whitelist, with root override**. They differ only in where the hook sits.

Zee eBPF puts the hook in the kernel's VFS operations — the mandatory
path every file operation must traverse. There is no userspace bypass because
the check happens before the filesystem ever sees the request.

### Design Principles

1. **Kernel-inline enforcement.** Policy checks are compiled into the syscall
   handlers via `@import`. Not a loadable module — part of the kernel binary.

2. **Root overrides everything.** `euid == 0` bypasses all policy checks.
   This matches Unix semantics: `sudo` grants full access. The threat model
   is unprivileged processes (AI agents, sandboxed services), not root.

3. **Path-based, not process-name-based.** Protection applies to paths
   regardless of which process touches them. Any unprivileged process gets
   denied. This eliminates the cat-and-mouse of process name matching.

4. **Zero runtime overhead for allowed operations.** Protected paths are
   `comptime` arrays. The check is a prefix comparison against a short list —
   branch-predictable, no allocations, no locks, no hash tables.

5. **Whitelist takes precedence.** A path under a protected prefix that is
   also under a whitelisted prefix is allowed. This prevents the policy from
   breaking normal operations (e.g., /tmp inside /etc wouldn't be blocked,
   /var/tmp is always writable).

---

## Architecture

### Two-Tier Design

```
Tier 1: Comptime Policy (this document)
├── Protected path prefixes      — compiled into kernel .rodata
├── Whitelisted path prefixes    — compiled into kernel .rodata
├── VFS hook functions           — inlined at each syscall dispatch site
├── Capability model             — u64 bitmask per process, fork inherits, execve drops
└── Root override                — euid == 0 implicitly has all capabilities

Tier 2: Runtime VM (future)
├── Bytecode instruction set     — ~15 opcodes, no loops
├── Minimal verifier             — bounds check, termination proof
├── Dynamic policy loading       — privileged syscall (root only)
└── Per-process policy contexts  — attached via bpf() syscall
```

Tier 1 ships now. It provides the Guardian Shield baseline — protected
directories that unprivileged processes cannot modify. Tier 2 adds runtime
flexibility for dynamic policies (per-session agent sandboxing, etc.).

### Hook Points

Every mutating VFS operation gets a policy check. Read-only operations
(read, readdir, stat, readlink) are not hooked — the threat model is
data destruction and unauthorized modification, not information disclosure.

| Operation | Syscalls | What It Blocks |
|---|---|---|
| **unlink** | unlink(87), unlinkat(263) | File deletion in protected paths |
| **rmdir** | rmdir(84) | Directory deletion in protected paths |
| **rename** | rename(82), renameat(264) | Moving files out of protected paths |
| **create** | open+O_CREAT, openat+O_CREAT | File creation in protected paths |
| **truncate** | truncate(76), ftruncate(77), open+O_TRUNC | Data destruction via truncation |
| **symlink** | symlink(88), symlinkat(266) | Symlink creation in protected paths |
| **link** | link(86), linkat(265) | Hardlink creation in protected paths |

### Policy Evaluation

```
policyCheck(path, operation, process) → ALLOW | DENY

1. if process has CAP_MODIFY_PROTECTED → ALLOW  (root implicitly has all caps)
2. if path starts with whitelist entry → ALLOW
3. if path starts with protected entry → DENY
4. → ALLOW                                       (default permit)
```

The check runs BEFORE the filesystem operation function pointer is called.
If denied, the syscall returns `-EACCES` and the filesystem never sees
the request.

### Capability Model

Each process has a `capabilities: u64` bitmask. No POSIX-style
ambient/inheritable/permitted/effective split — you have it or you don't.

**Capability bits:**
```
CAP_MODIFY_PROTECTED  (1 << 0)  — write to protected paths
CAP_LOAD_POLICY       (1 << 1)  — load runtime BPF policies (future)
CAP_NET_ADMIN         (1 << 2)  — modify network configuration
CAP_PROC_ADMIN        (1 << 3)  — signal/ptrace other processes
CAP_MOUNT             (1 << 4)  — mount/unmount filesystems
CAP_RAW_IO            (1 << 5)  — direct port/memory I/O
CAP_SETUID            (1 << 6)  — change uid/gid
CAP_CHOWN             (1 << 7)  — change file ownership
```

**Inheritance rules:**
- **Root (euid == 0):** Implicitly has all capabilities, always.
- **Fork:** Child inherits parent's capability bitmask.
- **Execve:** Capabilities dropped to 0 unless the binary path is in a
  comptime whitelist (e.g., `/bin/zsh`, `/sbin/zinit`, `/zig/zig`).
  Root processes always retain all caps regardless of whitelist.

This means: zinit (root, CAP_ALL) → fork → exec `/bin/zsh` (whitelisted,
keeps caps) → fork → exec `/home/user/agent` (not whitelisted, caps = 0).
The agent cannot modify `/etc/` even if it somehow escalates to the same
uid as the shell, because it lacks CAP_MODIFY_PROTECTED.

### Default Policy (Comptime)

Protected paths (cannot be modified by unprivileged processes):
```
/etc/          — system configuration
/boot/         — bootloader, kernel images
/bin/          — core binaries
/sbin/         — system binaries
/usr/          — installed packages, libraries
/zigix/        — kernel and system files
/zig/          — Zig compiler and stdlib
```

Whitelisted paths (exempt from protection even under protected prefixes):
```
/tmp/          — temporary files (world-writable by design)
/var/tmp/      — persistent temporary files
/proc/         — procfs (virtual, no real files)
/dev/          — devfs (virtual devices)
```

### Kernel Integration

The policy module lives at `kernel/security/policy.zig` and is imported
by `syscall_table.zig`. Each syscall handler calls `policy.checkMutate()`
with the resolved path and the current process before dispatching to the
filesystem operation.

```zig
// In sysUnlink, after path resolution and permission check:
const security = @import("../security/policy.zig");
if (!security.checkMutate(path_buf[0..path_len], current)) {
    frame.rax = @bitCast(@as(i64, -errno.EACCES));
    return;
}
// Now safe to call ops.unlink
```

The import is unconditional. The policy is always active. There is no
config file, no runtime toggle, no emergency disable. The kernel IS the
policy. To change the policy, rebuild the kernel.

This is a feature, not a limitation. The userspace implementations
(libwarden, libmacwarden) need emergency bypasses because they can lock
you out of a running system. The kernel policy can't lock you out because
root overrides it, and you need root to boot the system in the first place.

### Logging

Denied operations are logged to the kernel serial console:

```
[SECURITY] DENIED unlink /etc/passwd by PID 42 (euid=1000)
[SECURITY] DENIED rename /bin/sh by PID 42 (euid=1000)
```

Allowed operations (including root overrides) are not logged by default
to avoid flooding the console during normal builds.

---

## Comparison with Linux eBPF

| Aspect | Linux eBPF | Zee eBPF (Tier 1) |
|---|---|---|
| Policy loading | Runtime (bpf() syscall) | Compile time (Zig comptime) |
| Verifier | 20K+ lines of C, constant CVEs | Not needed — policy is Zig code |
| Hook mechanism | kprobe/tracepoint/LSM | Direct function call in syscall handler |
| Bypass resistance | Root can detach programs | Root is the override (by design) |
| Overhead | JIT'd bytecode, ~10ns/call | Inlined prefix comparison, ~2ns |
| Policy language | eBPF bytecode (C → LLVM → BPF) | Zig (comptime string arrays) |

### Why Not Just Use Linux LSM Hooks?

LSM (Linux Security Modules) is closer to what we're doing than eBPF.
But LSM has problems:

1. **Only one LSM can be "major" at a time** — SELinux OR AppArmor, not both
2. **Complex policy languages** — SELinux policy is notoriously impenetrable
3. **Bolted on** — LSM hooks were added retroactively, coverage is inconsistent

Zee eBPF is designed into the kernel from the start. Every mutating VFS
operation has a hook because we control the VFS code. The policy is Zig
arrays, not a domain-specific language.

---

## Tier 2: Runtime VM (Future)

The runtime VM enables dynamic policies loaded after boot. Use cases:

- Per-session AI agent sandboxing (this agent can write to /workspace, not /home)
- Temporary capability grants (build process needs /usr/lib for 60 seconds)
- Audit-only mode (log but don't block, for policy development)

### Instruction Set (Draft)

```
LOAD_FIELD  <field_id>     — load context field onto stack (pid, euid, path, operation)
LOAD_IMM    <value>        — load immediate value
CMP_EQ / CMP_PREFIX        — compare top two stack values
BRANCH_IF   <offset>       — conditional branch (forward only — no loops)
RETURN      <ALLOW|DENY>   — terminate with policy decision
```

~15 opcodes. No loops (guarantees termination). No arbitrary memory access
(only typed context fields). Max program size: 256 instructions.

The verifier is trivial: check all branches go forward, all field accesses
are valid IDs, program length <= 256. Maybe 100 lines of Zig.

### Loading Interface

```zig
// Privileged syscall (root only): load a BPF program
sys_zee_bpf(cmd, attr, size) → fd

// cmd = ZEE_BPF_PROG_LOAD: verify + load bytecode, return program fd
// cmd = ZEE_BPF_PROG_ATTACH: attach program fd to hook point
// cmd = ZEE_BPF_PROG_DETACH: remove program from hook point
```

Runtime programs run AFTER comptime policy. Comptime DENY cannot be
overridden by a runtime program. Runtime programs can only further
restrict — never widen — the comptime policy (deny-by-default stacking).

---

## File Layout

```
kernel/security/
├── ZEE_EBPF.md        — this document
├── policy.zig          — comptime policy engine (Tier 1)
├── capability.zig      — capability definitions + execve whitelist
└── (future)
    ├── vm.zig          — bytecode interpreter (Tier 2)
    ├── verifier.zig    — program verification (Tier 2)
    └── bpf_syscall.zig — sys_zee_bpf handler (Tier 2)
```

## Version History

- **v1.0** — Comptime VFS policy hooks (unlink, rmdir, rename, create,
  truncate, symlink, link). Root override. Serial logging. Protected
  paths: /etc, /boot, /bin, /sbin, /usr, /zigix, /zig.
- **v1.1** — Capability model. Per-process u64 bitmask, fork inherits,
  execve drops unless whitelisted. CAP_MODIFY_PROTECTED replaces
  bare euid==0 check in policy evaluation. 8 capability bits defined.
