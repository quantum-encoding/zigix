# PCI ECAM Probe Fix — External Abort Infinite Loop

**Date:** 2026-02-13
**Files changed:** `kernel/arch/aarch64/exception.zig`, `kernel/arch/aarch64/pci.zig`

## Symptom

Boot stalls at `[pci] Scanning PCIe bus 0...` with 585,000+ lines of:
```
[fault] Page fault with no process!
```

QEMU never progresses past PCI scan. 30-second timeout expires.

## Root Cause

QEMU virt's PCIe ECAM window at `0x3f000000` raises a **Synchronous External Abort**
when reading config space for non-existent bus/device/function combinations.

The ARM64 exception flow:

1. `configRead32()` reads `*volatile u32` at `0x3f000000 + (dev << 15)`
2. QEMU has no device at that BDF — raises external abort
3. ARM64 exception: `data_abort_same` (EC=0x25)
4. Handler checks: FAR=0x3f000XXX, which is `>= 0x400000` and `< 0x0001_0000_0000_0000`
5. Passes the user-range check! Calls `handlePageFault()`
6. `handlePageFault()`: no current process (boot, pre-scheduler) → prints message, returns
7. `data_abort_same` returns from exception
8. CPU re-executes faulting instruction at ELR_EL1 (unchanged) → goto step 2
9. **Infinite loop**

Key insight: `0x3f000000` is in the "user address range" check (`>= 0x400000`)
but is actually device memory. The handler never advances ELR past the fault.

## Fix

### 1. exception.zig — Device probe fault handler

Added `device_probe_faulted` flag and early check in `data_abort_same`:

```zig
pub var device_probe_faulted: bool = false;

// In data_abort_same, BEFORE the user-range check:
if (far < 0x40000000) {
    @as(*volatile bool, @ptrCast(&device_probe_faulted)).* = true;
    frame.elr += 4;  // Skip faulting instruction
    return;
}
```

Any fault with FAR in device memory (0-1GB) is treated as a probe failure.
ELR is advanced by 4 bytes (one ARM64 instruction) to skip the faulting load.

### 2. pci.zig — Config read with fault detection

```zig
pub fn configRead32(...) u32 {
    @as(*volatile bool, @ptrCast(&exception.device_probe_faulted)).* = false;
    asm volatile ("dmb sy" ::: "memory");
    const val = ptr.*;
    asm volatile ("dmb sy" ::: "memory");
    if (@as(*volatile bool, @ptrCast(&exception.device_probe_faulted)).*) return 0xFFFFFFFF;
    return val;
}
```

This is the ARM64 equivalent of Linux's `fixup_exception()` pattern for PCI probing.

## Why volatile for the flag?

The flag is set by the exception handler (which runs in the same thread but at
a different EL). The compiler doesn't know the exception handler modifies the
flag between the clear and the check. Without volatile, the compiler could
optimize away the check ("I just set it to false, so it must be false").

## Result

```
[pci]  Scanning PCIe bus 0...
[pci]  No devices found
```

Boot completes in ~2 seconds through PCI scan. Previously: infinite loop.

## Notes

- On x86, PCI config space always returns `0xFFFF` for non-existent devices (ISA legacy)
- On ARM64 MMIO ECAM, the bus may raise an abort instead — platform-dependent
- The `far < 0x40000000` check covers the entire first 1GB (device memory region)
- This also protects `configWrite32()` from write-abort infinite loops
- QEMU virt with `virtio-blk-device` (MMIO transport, not PCI) has no PCIe devices,
  so ALL 32 device slots return "no device" via this fault path
