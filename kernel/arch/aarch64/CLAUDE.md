# IMPORTANT — Development Target

Hey — why are we developing locally with cortex-a57 + TCG? We have a Google Axion VM rented and running right now:

- **Instance**: `zigix-axion` in `europe-west4-a`, status: Running
- **Machine**: `c4a-standard-1` (1 vCPU, 4 GB RAM, ARM64)
- **CPU**: Google Axion (Neoverse V2, ARMv9.2)
- **IP**: `<YOUR_INSTANCE_IP>`
- **Disk**: 10 GB Hyperdisk balanced, Ubuntu 24.04 ARM64

Our previous local development was targeting ARMv8 and ARMv9.2. Due to hardware delays we moved to developing on Google Axion. We should be using `deploy_axion.sh` to build with `-Dcpu=neoverse_n2` and run with KVM passthrough (`-cpu host`) on the actual Axion hardware — not emulating an ancient cortex-a57 under TCG on a Mac.

The HVF/MTTCG workarounds you've been adding (forced MMIO VMEXITs, aggressive cache maintenance, etc.) may be masking real bugs or adding unnecessary overhead on real hardware where KVM provides proper coherency. Please develop and test on the Axion VM going forward. Use `run_aarch64.sh` for quick local smoke tests only if needed, but the real target is always the Axion instance.

**CRITICAL — Build on the VM, not locally.** The ext2/ext4 disk image is ~1 GB. Uploading it to the Axion VM takes 5+ minutes every time. That completely kills iteration speed. You need to:

1. SSH into the Axion VM (`deploy_axion.sh ssh` or `ssh <YOUR_INSTANCE_IP>`)
2. Clone/pull the repo on the VM
3. Build the kernel AND generate the disk image directly on the VM
4. Run QEMU with KVM on the VM

The only things that should go over the network are git pushes (code, small files). Never transfer the disk image. The VM has Zig installed and can build everything natively — that's the whole point of renting ARM64 hardware.

---

# Zigix ARM64 (aarch64) Port

## Overview

This is the ARM64 port of Zigix. The x86_64 kernel is the **reference implementation** — every subsystem design has been proven there first. This port translates the architecture-specific layer while keeping everything above it identical.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Userspace: Shell, Utilities (cross-compiled, same source) │
├─────────────────────────────────────────────────────────────┤
│  Syscall Interface (same 51 syscalls, same numbers)        │
├─────────────────────────────────────────────────────────────┤
│  VFS / ext2 / tmpfs / ramfs (portable, zero changes)       │
├─────────────────────────────────────────────────────────────┤
│  TCP/IP / UDP / ICMP / ARP (portable, zero changes)        │
├─────────────────────────────────────────────────────────────┤
│  Process / Scheduler / ELF Loader (portable logic)         │
├─────────────────────────────────────────────────────────────┤
│  VMM / PMM (logic portable, page table format differs)     │
├─────────────────────────────────────────────────────────────┤
│  *** ARCH-SPECIFIC LAYER (this directory) ***              │
│  uart.zig, gic.zig, timer.zig, exception.zig, boot.zig     │
└─────────────────────────────────────────────────────────────┘
```

## What's Portable (Zero Changes)

These files work on ARM64 without modification:
- `kernel/fs/*` — VFS, ext2, tmpfs, ramfs, pipes, fd_table
- `kernel/net/*` — Full TCP/IP stack, sockets, DNS
- `kernel/proc/process.zig` — Process table, PIDs
- `kernel/proc/scheduler.zig` — Scheduling logic
- `kernel/proc/syscall_table.zig` — Syscall handlers (not entry)
- `kernel/proc/elf.zig` — Just change `EM_X86_64` to `EM_AARCH64`
- `kernel/drivers/virtio.zig` — virtio is MMIO, works on ARM64

## What Needs ARM64 Implementation

### 1. Boot Entry (`boot.zig`)

**x86_64**: Limine bootloader, multiboot protocol
**ARM64**: Device Tree, direct kernel entry

QEMU `-machine virt` provides:
- RAM at `0x40000000`
- Device Tree blob passed in x0
- Entry at `_start` with MMU off

```zig
export fn _start() callconv(.naked) noreturn {
    // x0 = DTB pointer (save it)
    // Set up stack pointer
    // Clear BSS
    // Call kmain()
}
```

### 2. UART Output (`uart.zig`)

**x86_64**: COM1 serial via I/O ports (0x3F8)
**ARM64**: PL011 UART via MMIO

QEMU virt PL011 at `0x09000000`:
```zig
const UART_BASE: usize = 0x09000000;
const UARTDR: *volatile u32 = @ptrFromInt(UART_BASE + 0x00);  // Data
const UARTFR: *volatile u32 = @ptrFromInt(UART_BASE + 0x18);  // Flags
const UARTFR_TXFF: u32 = 1 << 5;  // TX FIFO full

pub fn writeByte(byte: u8) void {
    while ((UARTFR.* & UARTFR_TXFF) != 0) {}
    UARTDR.* = byte;
}
```

### 3. Interrupt Controller (`gic.zig`)

**x86_64**: PIC (8259) or APIC
**ARM64**: GIC (Generic Interrupt Controller)

QEMU virt GICv2:
- Distributor at `0x08000000`
- CPU interface at `0x08010000`

Key differences:
- ARM64 has 4 exception levels (EL0-EL3)
- Interrupts are IRQ (normal) or FIQ (fast)
- GIC manages interrupt routing and priority

```zig
const GICD_BASE: usize = 0x08000000;
const GICC_BASE: usize = 0x08010000;

// Enable GIC distributor and CPU interface
// Configure interrupt priorities
// Unmask timer and UART interrupts
```

### 4. Timer (`timer.zig`)

**x86_64**: PIT (8254) at 1.193182 MHz
**ARM64**: ARM Generic Timer

Much cleaner on ARM64:
```zig
// Read current counter
fn readCounter() u64 {
    return asm volatile ("mrs %[ret], CNTPCT_EL0" : [ret] "=r" -> u64);
}

// Read timer frequency
fn readFrequency() u64 {
    return asm volatile ("mrs %[ret], CNTFRQ_EL0" : [ret] "=r" -> u64);
}

// Set timer to fire after N ticks
fn setTimer(ticks: u64) void {
    asm volatile ("msr CNTP_TVAL_EL0, %[val]" :: [val] "r" (ticks));
    asm volatile ("msr CNTP_CTL_EL0, %[val]" :: [val] "r" (@as(u64, 1)));  // Enable
}
```

### 5. Exception Vectors (`exception.zig`)

**x86_64**: IDT (256 entries), each pointing to a handler
**ARM64**: Exception vector table, 4 entries per exception level

Vector table layout (16 entries total):
```
Offset 0x000: Synchronous, Current EL, SP_EL0
Offset 0x080: IRQ, Current EL, SP_EL0
Offset 0x100: FIQ, Current EL, SP_EL0
Offset 0x180: SError, Current EL, SP_EL0
Offset 0x200: Synchronous, Current EL, SP_ELx
... (repeat for lower EL using AArch64, lower EL using AArch32)
```

```zig
export fn vector_table() callconv(.naked) void {
    // Aligned to 2KB, each vector is 32 instructions (128 bytes)
    asm volatile (
        \\.balign 0x800
        \\// Current EL, SP_EL0
        \\b sync_current_el_sp0
        \\.balign 0x80
        \\b irq_current_el_sp0
        // ... etc
    );
}
```

### 6. Syscall Entry (`syscall_entry.zig`)

**x86_64**: `syscall` instruction, LSTAR MSR
**ARM64**: `SVC #0` instruction, synchronous exception

```zig
// Syscall handler - called from exception vector
pub fn handleSvc(regs: *TrapFrame) void {
    const syscall_num = regs.x8;  // Syscall number in x8
    const args = .{ regs.x0, regs.x1, regs.x2, regs.x3, regs.x4, regs.x5 };
    regs.x0 = syscall_table.dispatch(syscall_num, args);
}
```

### 7. Page Tables (`mmu.zig`)

**x86_64**: 4-level (PML4 → PDPT → PD → PT), 9 bits per level
**ARM64**: 4-level (L0 → L1 → L2 → L3), similar but different descriptor format

ARM64 descriptor bits:
```
Bits 47:12 = Physical address
Bit 1:0 = Type (0b11 = table/page valid)
Bit 10 = AF (Access Flag, must be 1)
Bit 6 = AP[1] (0 = RW, 1 = RO)
Bit 54 = XN (Execute Never)
```

### 8. Context Switch

**x86_64**: Save RAX-R15, RIP, RSP, RFLAGS
**ARM64**: Save X0-X30, SP, PC, PSTATE

```zig
const Context = extern struct {
    x: [31]u64,        // X0-X30
    sp: u64,           // Stack pointer
    pc: u64,           // Program counter (ELR_EL1)
    pstate: u64,       // Saved PSTATE (SPSR_EL1)
};
```

## QEMU Testing

```bash
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M \
    -kernel zig-out/bin/zigix-aarch64 \
    -drive file=test.img,format=raw,if=virtio \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
    -serial stdio -display none -no-reboot
```

QEMU virt machine memory map:
```
0x00000000 - Flash
0x08000000 - GIC distributor
0x08010000 - GIC CPU interface
0x09000000 - PL011 UART
0x0a000000 - virtio MMIO region
0x40000000 - RAM start
```

## Build

```bash
# Cross-compile kernel
zig build -Dtarget=aarch64-freestanding

# Cross-compile userspace
cd userspace/zsh && zig build -Dtarget=aarch64-linux-musl
```

## Implementation Order

1. **boot.zig + uart.zig** — Get to "Hello from kernel"
2. **exception.zig** — Exception vector table, basic handlers
3. **gic.zig + timer.zig** — Interrupts and timer tick
4. **mmu.zig** — Page tables (reuse PMM/VMM logic from x86_64)
5. **syscall_entry.zig** — SVC handler
6. **Context switch** — Process switching works
7. **Test**: Mount ext2, run shell (cross-compiled for aarch64)

## Reference Files

Always read the x86_64 equivalent first:
- `boot.zig` ← `kernel/main.zig` (entry point structure)
- `uart.zig` ← `kernel/arch/x86_64/serial.zig` (same interface)
- `gic.zig` ← `kernel/arch/x86_64/pic.zig` (same concept)
- `timer.zig` ← `kernel/arch/x86_64/pit.zig` (same interface)
- `exception.zig` ← `kernel/arch/x86_64/idt.zig` (same concept)
- `syscall_entry.zig` ← `kernel/arch/x86_64/syscall_entry.zig`

## Key Registers

```
X0-X7   - Arguments / return values
X8      - Syscall number (Linux ABI)
X9-X15  - Caller-saved temporaries
X16-X17 - Intra-procedure-call scratch
X18     - Platform register (reserved)
X19-X28 - Callee-saved
X29     - Frame pointer
X30     - Link register (return address)
SP      - Stack pointer
PC      - Program counter
```

## Tips

1. ARM64 inline assembly uses different constraints: `"r"` for general registers
2. No I/O ports — everything is memory-mapped
3. MMU must be explicitly enabled (off at boot on QEMU virt)
4. EL1 is kernel mode, EL0 is user mode
5. `WFI` instruction for idle (like x86 `hlt`)
6. `DMB`, `DSB`, `ISB` for memory barriers (important for MMIO)
