# Zigix Kernel Roadmap — February 2026

## Current State

Both kernels build clean. ARM64 is the production platform (22.4 KLOC, 44 files, SMP, full TCP/IP, NVMe, ext3). x86_64 is the reference implementation (shared modules + 1.2 KLOC arch-specific, NVMe, no SMP, no network driver).

### Completed (A1–A51 + cross-arch parity)
- Boot, UART, exceptions, GIC, timer, MMU, PMM, VMM
- Process model, scheduler, ELF loader, fork, mmap, threads, signals, TLS
- VFS, ext2 (r/w), ext3 journal, ramfs, procfs, devfs
- virtio-blk, virtio-net (ARM64), full TCP/IP stack, epoll, sockets
- SMP 2–4 CPUs (ARM64), all subsystems SMP-safe
- Zig compiler self-hosting — `zig build` works on Zigix ARM64
- PCIe ECAM + NVMe on both architectures
- 75+ syscalls, dual-arch userspace (6 programs)
- Socket options (SO_REUSEADDR, TCP_NODELAY, SO_KEEPALIVE)
- /proc/{version,cpuinfo,stat,uptime,meminfo,self/*}
- MMU block mapping translation fix (ARM64)
- Security: SMEP/SMAP (x86_64), PAN (ARM64), W^X enforcement

---

## Track 1: Real Hardware Boot — Orange Pi 6 Plus

**Highest priority. This takes Zigix from emulation to bare metal.**

Target: CIX CD8180 (P1), 12-core Armv9.2, GICv3, PL011 UART, UEFI boot (EDK2), dual NVMe PCIe4, 2x RTL8126 5GbE.

### H1: EFI Stub — DONE (A41, 765 lines)
- `bootloader/main.zig`: UEFI entry, SimpleFileSystem kernel loading, ExitBootServices retry loop
- `bootloader/elf_loader.zig`: ELF64 parser, PT_LOAD segment loading, BSS zeroing
- `bootloader/boot_info.zig`: BootInfo struct with DTB + ACPI RSDP pointers
- `bootloader/console.zig`: ASCII→UCS-2 UEFI console output
- Output: `zig-out/bin/BOOTAA64.EFI` (PE32+ via aarch64-uefi target)

### H2: EL2 to EL1 Drop — DONE (A41, 99 lines)
- `bootloader/el_drop.zig`: Reads CurrentEL, configures HCR_EL2 (RW=1), SPSR_EL2=0x3c5
- Enables FP/SIMD (CPACR_EL1.FPEN, CPTR_EL2), executes `eret` into EL1
- Falls through to direct branch if already at EL1

### H3: GICv3 Driver — DONE (A46, 248 lines)
- `kernel/arch/aarch64/gicv3.zig`: System register interface (ICC_*_EL1)
- Redistributor walk by MPIDR affinity (128KB stride, 64 frames max)
- SGIs via ICC_SGI1R_EL1 for IPI
- Runtime dispatch in `gic.zig`: ACPI MADT → FDT → hardware probe fallback
- GICv2 still works for QEMU virt (backward compatible)

### H4: UART Address Swap — DONE (A49)
- `uart.zig`: Added `REAL_HW_UART_BASE = 0x040D0000` for Orange Pi debug UART2
- Baud rate branches on base address: 24MHz (QEMU) vs 100MHz (real HW)
- FDT/ACPI already updates `uart_base` dynamically at runtime

### H5: Watchdog Timer — DONE (A49, 149 lines)
- `kernel/arch/aarch64/watchdog.zig`: SBSA Generic Watchdog driver
- ACPI GTDT parsing discovers watchdog refresh/control frame addresses
- `tick()` called from timer interrupt on CPU 0, pets every 5 seconds
- `forceReset()` wired into panic handler — auto-reboots on real hardware
- On QEMU (no watchdog in GTDT), all functions are safe no-ops

### H6: ACPI Table Parsing — DONE (A42+A49, ~650 lines)
- `kernel/acpi/acpi_parser.zig`: RSDP validation, XSDT/RSDT walk, table directory (16 entries)
- `kernel/acpi/acpi_tables.zig`: ACPI 6.5 structs (MADT, MCFG, GTDT, GICC, GICD, GIC_REDIST, GIC_ITS)
- MADT: extracts GICD base, GICR base, GIC version, per-CPU GICC, up to 16 CPUs
- MCFG: extracts ECAM base, segment, bus range
- GTDT: extracts SBSA Generic Watchdog refresh/control frame addresses
- **BIOS supports ACPI or Device Tree** (selectable in setup) — use ACPI mode

### H7: PCIe ECAM from ACPI — DONE (A49)
- `pci.zig`: `ECAM_BASE` constant → `ecam_base` variable, `initFromAcpi()` reads ACPI MCFG
- Falls back to 0x3f000000 (QEMU virt default) if no ACPI
- Called from `boot.zig` before `scanBus()` — seamless for both QEMU and real HW

### H8: NVMe on Real Hardware — DONE (706 lines)
- `kernel/arch/aarch64/nvme.zig`: Full NVMe 1.x controller init, admin + I/O queues
- Hardware-agnostic (NVMe spec-compliant), works via PCIe ECAM
- Verify DMA coherency on CIX P1 (should be cache-coherent for PCIe)

### H9: RTL8126 Ethernet NIC Driver — DONE (A50, 586 lines + 75 line NIC abstraction)
- `kernel/arch/aarch64/rtl8126.zig`: Full bare-metal RTL8126 5GbE driver
- `kernel/arch/aarch64/nic.zig`: NIC abstraction layer (runtime dispatch: virtio-net or RTL8126)
- PCIe discovery via `pci.findByVendorDevice(0x10EC, 0x8126)`, BAR0 MMIO
- Legacy 16B RX descriptors, 32B TX descriptors (RTL8125 mode)
- 32-entry TX/RX rings, 16 pre-posted RX DMA buffers, synchronous TX
- Polling + IRQ hybrid (handleIrq called from GIC + timer poll at 100Hz)
- Boot order: try virtio-net (QEMU) → try RTL8126 (real HW) → register winner in nic.zig
- 8 network stack files updated: `virtio_net` → `nic` (net.zig, arp.zig, ipv4.zig, icmp.zig, gic.zig, syscall.zig, net_ring.zig, boot.zig)
- PCI scan shows `[Ethernet]` tag for class 02:00
- Without firmware blobs, PHY negotiates up to 1GbE (5GbE requires rtl8126a-*.fw)
- Reference: `memory/rtl8126_driver.md` for full register map

### Hardware Prerequisites
| Item | Cost |
|------|------|
| Orange Pi 6 Plus 32GB | ~$250 |
| NVMe 1TB (host OS) | ~$70 |
| NVMe 512GB (Zigix) | ~$40 |
| FTDI FT232R USB-UART 3.3V | ~$12 |
| USB-C PD 100W PSU | ~$30 |
| Pi Zero 2 W (serial capture) | ~$20 |
| Misc (cables, switch, SD card) | ~$43 |
| **Total** | **~$465** |

---

## Track 2: Security Hardening

### S1: x86_64 SMAP/SMEP — DONE (A51, ~30 lines)
- CR4 bits 20 (SMEP) and 21 (SMAP), CPUID-probed at boot
- SMEP: prevent kernel executing user pages
- SMAP: prevent kernel accessing user pages — no STAC/CLAC needed (HHDM pattern already safe)
- Fixed 3 setsockopt/getsockopt sites that bypassed HHDM

### S2: ARM64 PAN — DONE (A51, ~35 lines)
- Privileged Access Never — kernel can't access user memory unless explicitly unlocked
- ID_AA64MMFR1_EL1 feature probe, SCTLR_EL1.SPAN=0 for auto-set on exception entry
- PAN disable/enable wrappers in syscall.handle(), SMP secondary CPU boot path
- Raw `.inst` encoding for ARMv8.1 PAN instructions (v8.0 assembler baseline)

### S3: Stack Canaries (~150 lines)
- Comptime random canary in stack frames
- Zig `-fstack-protector` support

### S4: W^X Enforcement (~50 lines)
- Ensure no VMA is simultaneously writable AND executable
- Reject mmap with PROT_WRITE|PROT_EXEC

---

## Track 3: ext4 Filesystem — DONE (A52)

ext4 feature set fully implemented and integrated on both architectures.

### Phase 2: Non-Breaking — DONE (~1800 lines)
| Milestone | Description | Status |
|-----------|-------------|--------|
| E1 | CRC32c checksums (`common/crc32c.zig`, 66 lines) | **DONE** |
| E2 | 256-byte inodes with CRC32c checksums (`ext4/inode_ext4.zig`, 194 lines) | **DONE** |
| E3 | 64-bit block group descriptors (`ext4/block_group_64.zig`, 180 lines) | **DONE** |
| E4 | Flexible block groups (`ext4/flex_bg.zig`) | **DONE** |
| E5 | Multiblock allocator (`ext4/mballoc.zig`) | **DONE** |
| E6 | Delayed allocation (`ext4/delayed_alloc.zig`) | **DONE** |

### Phase 3: Structural — DONE (~550 lines)
| Milestone | Description | Status |
|-----------|-------------|--------|
| X1 | Extent tree (`ext4/extents.zig`, 290 lines) | **DONE** |
| X2 | HTree indexed directories (`ext4/htree.zig`) | **DONE** |

### Integration — DONE (A52)
- x86_64 `ext2.zig`: All ext4 modules imported and integrated (inode checksums, extent lookup/insert, 64-bit BGDs)
- ARM64 `ext2.zig`: All ext4 modules ported via `ext4` named module in build.zig (A52)
- `make_ext4_img.py`: 840+ lines — creates ext4 images with CRC32c, extents, 256-byte inodes, 64-bit BGDs, JBD2 journal
- `run_aarch64.sh`: Now uses ext4 images instead of ext3
- `common/superblock.zig`: Unified parser detects ext2/ext3/ext4 from feature flags

---

## Track 4: x86_64 Feature Parity

### X1: x86_64 SMP (~2000–3000 lines)
- Local APIC + I/O APIC initialization
- AP startup via SIPI (Startup Inter-Processor Interrupt)
- Per-CPU state: GDT, TSS, IDT, kernel stack
- IPI mechanism, spinlock infrastructure
- Port lock ordering from ARM64

### X2: x86_64 virtio-net (~800–1200 lines)
- PCI-based transport (BAR0 I/O port + BAR1 MMIO or MSI-X)
- Same virtio spec as ARM64, different transport layer
- Enables actual networking on x86_64 QEMU

### X3: x86_64 SCHED_DEDICATED (~200 lines)
- Port from ARM64 (requires X1 SMP first)
- Pin process to specific core, disable preemption

---

## Track 5: Future Features

### F1: USB Stack (~3000+ lines)
- XHCI controller driver, hub enumeration
- USB mass storage class, USB HID (keyboard/mouse)

### F2: GPU / Framebuffer (~1500+ lines)
- Linear framebuffer from UEFI GOP
- Text console with font rendering

### F3: Sound (~1000+ lines)
- Intel HDA or USB Audio Class

### F4: Kernel Modules / Dynamic Loading
- ELF relocation for .ko-style modules

---

## Real Hardware Readiness Summary

| Item | Status | Remaining |
|------|--------|-----------|
| H1 EFI Stub | **DONE** (A41) | 0 lines |
| H2 EL2→EL1 | **DONE** (A41) | 0 lines |
| H3 GICv3 | **DONE** (A46) | 0 lines |
| H4 UART swap | **DONE** (A49) | 0 lines |
| H5 Watchdog | **DONE** (A49) | 0 lines |
| H6 ACPI + GTDT | **DONE** (A42+A49) | 0 lines |
| H7 PCIe from ACPI | **DONE** (A49) | 0 lines |
| H8 NVMe | **DONE** (A48) | 0 lines |
| H9 RTL8126 Ethernet | **DONE** (A50) | 0 lines |

**H1–H9 complete. All real hardware drivers written. 0 lines remaining.**
**Ready for first boot on Orange Pi 6 Plus when hardware arrives.**

## Priority Matrix

| Rank | Track | Item | Effort | Impact |
|------|-------|------|--------|--------|
| 1 | S3 | Stack canaries | 1 day | Stack smash detection |
| 2 | ext4 P2 | CRC32c, inodes, 64-bit | 2 weeks | Modern filesystem |
| 3 | X1 | x86_64 SMP | 2 weeks | Multi-core Intel |
| 4 | ext4 P3 | Extents, HTree | 2 weeks | Large file perf |
| 5 | - | Real hardware test | When HW arrives | Validation |

---

## What's Needed from Orange Pi Docs

### Already Have
- BIOS Porting Guide (62 pages) — UART addresses, boot flow
- Linux DT Dev Guide (61 pages) — peripheral addresses, interrupt IDs
- ACPI Bring-up Guide — ACPI table layout
- Security Guide
- Linux System User Manual v0.7 (448 pages) — hardware specs, serial setup, adapter status
- BIOS User Manual v1.4 (29 pages) — BIOS setup, PCIe config, watchdog, boot manager

### Confirmed from Docs (no longer TBD)
- **Ethernet NIC: Realtek RTL8126** (5GbE, PCIe-attached, 2 ports)
- **Watchdog: enabled by default** in BIOS Platform Configuration
- **UEFI firmware: Tianocore/EDK2** (UEFI v2.70, Shell v2.2)
- **ACPI mode supported** (selectable in BIOS — ACPI or Device Tree)
- **Firmware stack**: SE → PBL → ATF (BL2/BL31 v2.7) → PM → TEE → UEFI → OS
- **Debug serial**: 10-pin header, UART2 = BIOS + kernel logs @ 115200 baud
- **PCIe topology**: 5 ports — X8(Port0/GPU), X4(Port1/SSD1), X2(Port2), X1(Port3), X1(Port4)
- **NVMe paths**: `PciRoot(0x0)/Pci(0x0,0x0)/Pci(0x0,0x0)/NVMe(...)` (Port0/Port1)

### Still Need from TRM (9,230 pages, requires registration)
1. **GIC base addresses** — GICD_BASE and GICR_BASE for CIX P1 (or get from ACPI MADT at runtime)
2. **PCIe controller registers** — ECAM base, PHY init (or UEFI handles all of it?)
3. **Watchdog registers** — base address, timeout config, pet/reset sequence (for direct register access)
4. **Clock tree** — which clocks need enabling for PCIe/NVMe/Ethernet?
5. **Power domains** — do we need to enable power rails for peripherals?
6. **GPIO/IOMUX** — pin mux for UART2, PCIe PERST signals

### Can Get from ACPI at Runtime (reduces TRM dependency)
- GIC: MADT table -> GICD base, GICR base, CPU interfaces
- PCIe: MCFG table -> ECAM base, bus range
- Memory map: EFI GetMemoryMap()
- Timer: already standard ARM Generic Timer

---

## Quick Wins (< 1 day each)

1. ~~ARM64 PAN enable~~ — **DONE** (A51)
2. ~~x86_64 SMEP/SMAP~~ — **DONE** (A51)
3. ~~W^X enforcement~~ — **DONE** (A44)
4. **/proc/self/cmdline** — useful for programs reading own args (~1 hour)
5. **Verify x86_64 NVMe boot** — run `BLOCK_DEV=nvme ./run.sh` (~30 min)

---

## Remaining Stub Syscalls (intentional, non-blocking)

| Syscall | Arch | What It Does | Priority |
|---------|------|-------------|----------|
| madvise | Both | Advisory memory hint | Low (no-op is correct) |
| sigaltstack | Both | Alternate signal stack | Low (signals work without it) |
| set_robust_list | Both | Robust futex cleanup | Low (futex works without it) |
| prctl | Both | Process control misc | Low (PR_SET_NAME useful later) |
| rseq | Both | Restartable sequences | None (returns -ENOSYS) |
| sched_setaffinity | ARM64 | CPU affinity | Low (SMP works without it) |

---

## Architecture Feature Matrix

| Feature | ARM64 | x86_64 |
|---------|-------|--------|
| SMP | 2–4 CPUs | No |
| NVMe | PCIe ECAM | Legacy PCI |
| virtio-blk | MMIO | PCI I/O ports |
| virtio-net | MMIO | Not implemented |
| TCP/IP | Full stack | Full stack (no driver) |
| ext2/ext3 | Full | Full |
| procfs/devfs | Full | Full |
| Socket options | Full | Full |
| SIMD save/restore | v0-v31, FPCR, FPSR | XSAVE/XRSTOR (AVX2) |
| Security | PAN, PXN, W^X, stack guards | SMEP, SMAP, W^X, stack guards |
| Zig self-hosting | zig build works | zig version works |
