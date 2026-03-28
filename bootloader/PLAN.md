# Plan: A41 — UEFI Bootloader for Zigix ARM64

## Context

Zigix ARM64 currently boots via QEMU's `-kernel` flag (direct ELF load). For real hardware
(CIX P1 / Orange Pi 6 Plus), the boot chain is: Boot ROM → TF-A → UEFI → **our code**.
UEFI requires a PE32+ application. We need a standalone UEFI bootloader that loads the
kernel ELF from an ESP (EFI System Partition) and transfers control.

**Zig version**: 0.16.0-dev.2510+bcb5218a2
**UEFI firmware**: `/usr/share/edk2/aarch64/QEMU_EFI.fd` (already installed)

## Architecture

```
UEFI Firmware
    ↓ loads PE32+ from ESP
bootloader/BOOTAA64.EFI  (aarch64-uefi target)
    ↓ reads kernel ELF via UEFI SimpleFileSystem
    ↓ parses ELF, copies PT_LOAD segments to p_vaddr
    ↓ finds DTB + ACPI RSDP from UEFI config tables
    ↓ GetMemoryMap → ExitBootServices
    ↓ EL2→EL1 drop (if needed)
    ↓ x0 = BootInfo pointer, branch to kernel entry
zigix-aarch64 ELF kernel  (unchanged, same as QEMU boot)
```

## File Structure

```
zigix/
  bootloader/
    build.zig          — aarch64-uefi PE32+ build
    main.zig           — UEFI entry, file loading, ExitBootServices
    elf_loader.zig     — ELF64 parser + UEFI AllocatePages loader
    boot_info.zig      — BootInfo struct definition (shared layout)
    el_drop.zig        — EL2→EL1 transition assembly
    console.zig        — ASCII→UCS-2 print helper for UEFI console
  kernel/arch/aarch64/
    boot_info.zig      — BootInfo struct (kernel side, identical layout)
    boot.zig           — Modified: detect BootInfo magic vs raw DTB vs zero
  run_uefi_aarch64.sh  — QEMU UEFI launch script
```

## BootInfo Protocol

The bootloader passes a `BootInfo` struct pointer in X0 to the kernel. The kernel
detects which boot path was used by examining X0:

1. **X0 points to BootInfo** (magic = `0x5A49474958424F4F` "ZIGIXBOO") → UEFI boot
2. **X0 points to FDT** (first 4 bytes = `0xD00DFEED` big-endian) → U-Boot/DTB boot
3. **X0 = 0** → QEMU virt defaults (current behavior)

```zig
pub const BootInfo = extern struct {
    magic: u64,                    // 0x5A49474958424F4F
    version: u32,                  // 1
    _pad: u32,
    dtb_addr: u64,                 // FDT address (0 if not found)
    acpi_rsdp: u64,                // ACPI 2.0 RSDP (0 if not found)
    mmap_addr: u64,                // UEFI memory map entries
    mmap_count: u32,
    mmap_descriptor_size: u32,
    mmap_descriptor_version: u32,
    _pad2: u32,
    framebuffer_addr: u64,         // GOP framebuffer (0 = none)
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_pitch: u32,
    _pad3: u32,
};
```

## Implementation Steps

### Step 1: Build scaffolding
- Create `bootloader/build.zig` targeting `aarch64-uefi`
- Create `bootloader/console.zig` (ASCII→UCS-2 print helper)
- Create `bootloader/main.zig` with just banner print + watchdog disable
- **Test**: QEMU UEFI shell loads and runs the EFI app, prints banner

### Step 2: Kernel file loading
- Use LoadedImage protocol to find ESP device
- Use SimpleFileSystem to open `\zigix\zigix-aarch64`
- Read entire ELF into allocated buffer
- **Test**: bootloader prints kernel file size

### Step 3: ELF segment loading
- Create `bootloader/elf_loader.zig`
- Parse ELF64 headers, validate (AArch64, ET_EXEC)
- For each PT_LOAD: AllocatePages at p_vaddr, copy p_filesz, zero BSS
- **Test**: prints "Loaded N segments, entry=0x40097ef8"

### Step 4: BootInfo + config table discovery
- Create `bootloader/boot_info.zig`
- Find DTB via EFI_DTB_TABLE_GUID in system table config entries
- Find ACPI RSDP via ACPI_20_TABLE_GUID
- Allocate page for BootInfo + memory map copy

### Step 5: ExitBootServices
- GetMemoryMap with 16KB static buffer
- Copy memory map into BootInfo region
- ExitBootServices with retry loop (up to 5 attempts)

### Step 6: EL2→EL1 drop + jump
- Create `bootloader/el_drop.zig`
- Check CurrentEL: if EL2, configure HCR_EL2.RW=1, SPSR_EL2=0x3c5, ELR_EL2=entry, eret
- If EL1, direct branch with x0=BootInfo
- **Test**: kernel boots to UART output via UEFI path

### Step 7: Kernel-side BootInfo detection
- Create `kernel/arch/aarch64/boot_info.zig` (same struct)
- Modify `boot.zig` kmain: check X0 for BootInfo magic, FDT magic, or zero
- Extract DTB from BootInfo if present, fall through to existing FDT parse

### Step 8: Integration test script
- Create `run_uefi_aarch64.sh`: builds kernel + bootloader, creates ESP dir, runs QEMU
- QEMU: `-bios /usr/share/edk2/aarch64/QEMU_EFI.fd -drive file=fat:rw:ESP_DIR,...`
- **Test**: full boot to zinit/zsh via UEFI path

## Key Technical Details

### UEFI Entry Point (Zig convention)
```zig
pub fn main(handle: uefi.Handle, st: *uefi.tables.SystemTable) uefi.Status
```

### ExitBootServices Retry Pattern
GetMemoryMap and ExitBootServices must be called back-to-back. Any allocation between
them invalidates the MapKey. Use a pre-allocated static buffer and retry loop.

### EL2→EL1 Drop
UEFI on real hardware hands off at EL2. Set HCR_EL2.RW=1 (AArch64 EL1),
SPSR_EL2=0x3c5 (DAIF masked, EL1h), ELR_EL2=kernel entry, then `eret`.

### AllocatePages at Fixed Address
The kernel ELF specifies load address 0x40080000 (QEMU virt). Use
`AllocatePages(.address, .loader_data, pages, addr)` to place segments exactly there.
QEMU UEFI firmware has this range as ConventionalMemory.

### DTB Discovery
UEFI config table GUID for DTB: `{b1b621d5-f19c-41a5-830b-d9152c69aae0}`

## Verification

1. `cd zigix/bootloader && zig build` → produces `zig-out/bin/BOOTAA64.EFI`
2. `cd zigix && zig build -Darch=aarch64` → kernel ELF (unchanged)
3. `bash run_uefi_aarch64.sh` → QEMU boots:
   ```
   Zigix UEFI Bootloader v0.1
   Loading kernel from \zigix\zigix-aarch64...
   ELF: 4 segments, entry=0x40097ef8
   DTB: 0x44000000 (from UEFI config)
   Memory map: 42 entries
   ExitBootServices: OK
   Jumping to kernel at EL1...

   ========================================
     Zigix ARM64
     aarch64 freestanding kernel
   ========================================
   [boot] UART initialized (PL011)
   [boot] UEFI boot detected
   [boot] DTB at 0x44000000
   ...
   ```
4. Existing QEMU `-kernel` boot path still works (regression test)

## Files Summary

| File | Action | ~Lines |
|------|--------|--------|
| `bootloader/build.zig` | CREATE | 30 |
| `bootloader/console.zig` | CREATE | 50 |
| `bootloader/main.zig` | CREATE | 250 |
| `bootloader/elf_loader.zig` | CREATE | 150 |
| `bootloader/boot_info.zig` | CREATE | 40 |
| `bootloader/el_drop.zig` | CREATE | 60 |
| `kernel/arch/aarch64/boot_info.zig` | CREATE | 40 |
| `kernel/arch/aarch64/boot.zig` | MODIFY | +30 |
| `run_uefi_aarch64.sh` | CREATE | 50 |
| **Total** | | **~700** |

## x86_64 UEFI Bootloader (Parallel Track)

The same architecture applies to x86_64 with these differences:

| Aspect | ARM64 | x86_64 |
|--------|-------|--------|
| PE32+ target | `aarch64-uefi` | `x86_64-uefi` |
| Default EFI path | `\EFI\BOOT\BOOTAA64.EFI` | `\EFI\BOOT\BOOTX64.EFI` |
| QEMU firmware | `edk2/aarch64/QEMU_EFI.fd` | `edk2/x64/OVMF_CODE.fd` |
| EL drop | EL2→EL1 via `eret` | Long mode already active, no drop needed |
| Kernel ELF | `zigix-aarch64` at 0x40080000 | `zigix` (higher-half, ~0xFFFFFFFF80100000) |
| ELF machine | EM_AARCH64 (0xB7) | EM_X86_64 (0x3E) |
| Register ABI | x0 = BootInfo | rdi = BootInfo (SysV ABI) |

The x86_64 bootloader shares: `boot_info.zig` layout, ELF loader logic (different machine check),
ExitBootServices retry pattern, config table discovery. The EL drop module is ARM64-only.
The x86_64 version is simpler since there's no exception level transition.

**Shared code strategy**: `boot_info.zig` is defined identically in both bootloaders (cannot
share source files across different build targets). The BootInfo struct layout is the contract.

x86_64 files:
```
zigix/
  bootloader_x86/
    build.zig          — x86_64-uefi PE32+ build
    main.zig           — Same flow as ARM64 minus EL drop
    elf_loader.zig     — Same logic, EM_X86_64 validation
    boot_info.zig      — Identical struct layout
    console.zig        — Same ASCII→UCS-2 helper
  kernel/
    boot_info.zig      — Identical struct, x86 kernel side
    main.zig           — Modified: detect BootInfo magic
  run_uefi_x86.sh     — QEMU OVMF launch script
```
