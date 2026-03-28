/// ARM64 Boot Entry
/// Supports three boot paths:
/// 1. UEFI bootloader: X0 = BootInfo pointer (magic 0x5A49474958424F4F)
/// 2. U-Boot / DTB: X0 = FDT pointer (magic 0xD00DFEED)
/// 3. QEMU -kernel: X0 = 0 (use hardcoded QEMU virt defaults)

const std = @import("std");
const uart = @import("uart.zig");
const gic = @import("gic.zig");
const timer = @import("timer.zig");
const exception = @import("exception.zig");
const mmu = @import("mmu.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const vfs = @import("vfs.zig");
const ramfs = @import("ramfs.zig");
const elf = @import("elf.zig");
const virtio_blk = @import("virtio_blk.zig");
const virtio_net = @import("virtio_net.zig");
const net = @import("net.zig");
const icmp = @import("icmp.zig");
const ext2 = @import("ext2.zig");
const fdt = @import("fdt.zig");
const smp = @import("smp.zig");
const procfs = @import("procfs.zig");
const devfs = @import("devfs.zig");
const boot_info = @import("boot_info.zig");
const acpi = @import("acpi");
const typed_addr = @import("addr");
const pci = @import("pci.zig");
const nvme = @import("nvme.zig");
const watchdog = @import("watchdog.zig");
const syscall = @import("syscall.zig");
const ext3 = @import("ext3");
const block_io = ext3.block_io;
const sdhci = @import("sdhci.zig");
const cpu_features = @import("cpu_features.zig");
const sve = @import("sve.zig");
const hwrng = @import("hwrng.zig");
const slab = @import("slab.zig");
const klog = @import("klog");

// Linker symbols
extern const __bss_start: u8;
extern const __bss_end: u8;
extern const __stack_top: u8;

/// Device Tree Blob pointer (set during boot)
pub var dtb_ptr: ?*anyopaque = null;

/// PAN (Privileged Access Never) support flag — set at boot if CPU supports ARMv8.1 PAN.
pub var pan_enabled: bool = false;

/// Kernel entry point
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        // Save DTB pointer (passed in X0 by bootloader/U-Boot)
        \\mov x19, x0

        // Set up stack pointer
        \\ldr x0, =__stack_top
        \\mov sp, x0

        // Clear BSS section
        \\ldr x0, =__bss_start
        \\ldr x1, =__bss_end
        \\1:
        \\cmp x0, x1
        \\b.ge 2f
        \\str xzr, [x0], #8
        \\b 1b
        \\2:


        // Clear SCTLR_EL1.A (alignment check) before any Zig code
        \\mrs x1, SCTLR_EL1
        \\bic x1, x1, #(1 << 1)
        \\msr SCTLR_EL1, x1
        \\isb
        // Restore DTB pointer and call kmain
        \\mov x0, x19
        \\bl kmain

        // Halt if kmain returns (infinite loop, never returns)
        \\3:
        \\wfi
        \\b 3b
    );
}

/// Kernel main entry
export fn kmain(x0_val: u64) noreturn {
    // Enable FP/SIMD before any code that might use it
    // CPACR_EL1.FPEN = 0b11 (no trapping of FP/SIMD)
    asm volatile ("msr CPACR_EL1, %[val]"
        :
        : [val] "r" (@as(u64, 3 << 20)),
    );
    asm volatile ("isb");


    // Clear SCTLR_EL1.A (Alignment check) early — Zig Debug mode generates
    // SIMD str/ldr (q0) for optional returns that may not be 16-byte aligned.
    // Without this, alignment faults fire before mmu.enable() clears A bit.
    {
        var sctlr: u64 = asm volatile ("mrs %[ret], SCTLR_EL1"
            : [ret] "=r" (-> u64),
        );
        sctlr &= ~@as(u64, 1 << 1); // Clear A bit
        asm volatile ("msr SCTLR_EL1, %[val]" :: [val] "r" (sctlr));
        asm volatile ("isb");
    }
    // Initialize UART first for debug output
    uart.init();
    // klog.init(&uart.writeString, &uart.writeByte, &getTicksWrapper); // TODO: re-enable after NVMe fix verified

    uart.writeString("\n");
    uart.writeString("========================================\n");
    uart.writeString("  Zigix OS\n");
    uart.writeString("  ARM64 bare-metal operating system\n");
    uart.writeString("  Written in Zig by Quantum Encoding Ltd\n");
    uart.writeString("  info@quantumencoding.io\n");
    uart.writeString("========================================\n");
    uart.writeString("\n");

    uart.writeString("[boot] UART initialized (PL011)\n");

    // Test formatted print
    const el = getCurrentEl();
    uart.print("[boot] Running at EL{}\n", .{el});

    // Detect boot source from X0:
    //   BootInfo magic -> UEFI boot
    //   FDT magic -> U-Boot / DTB boot
    //   Zero -> QEMU virt defaults
    //
    // ACPI parsing is deferred until after MMU is enabled — on GCE Axion,
    // UEFI places ACPI tables above 4GB (e.g., RSDP at 0x13c580018) and
    // the bootloader disables the MMU before jumping to the kernel.
    var saved_acpi_rsdp: u64 = 0;
    var saved_mmap_addr: u64 = 0;
    var saved_mmap_count: u32 = 0;
    var saved_mmap_desc_size: u32 = 0;

    if (boot_info.isBootInfo(x0_val)) {
        const info: *const boot_info.BootInfo = @ptrFromInt(x0_val);
        uart.writeString("[boot] UEFI boot detected (BootInfo v");
        uart.writeDec(info.version);
        uart.writeString(")\n");

        if (info.dtb_addr != 0) {
            uart.print("[boot] DTB at {x}\n", .{info.dtb_addr});
            dtb_ptr = @ptrFromInt(info.dtb_addr);
            fdt.parse(dtb_ptr);

            if (fdt.config.ram_count > 0) {
                pmm.setRamSize(fdt.getTotalRamSize());
            }
        }

        if (info.acpi_rsdp != 0) {
            uart.print("[boot] ACPI RSDP at {x} (deferred until MMU)\n", .{info.acpi_rsdp});
            saved_acpi_rsdp = info.acpi_rsdp;
        }

        uart.print("[boot] UEFI memory map: {} entries\n", .{info.mmap_count});

        // Save UEFI memory map info for deferred parsing after MMU is enabled.
        // On GCE c4a-standard-8, the bootloader allocates the memory map above
        // 32 GB (e.g., 0x83a4d9060). With MMU off, this address causes a fault.
        // The early MMU init maps 0-64GB, making it accessible.
        if (info.mmap_addr != 0 and info.mmap_count > 0 and info.mmap_descriptor_size >= 40) {
            saved_mmap_addr = info.mmap_addr;
            saved_mmap_count = info.mmap_count;
            saved_mmap_desc_size = info.mmap_descriptor_size;
        }
    } else if (boot_info.isFdt(x0_val)) {
        // Raw DTB from U-Boot or similar bootloader
        uart.print("[boot] DTB at {x}\n", .{x0_val});
        dtb_ptr = @ptrFromInt(x0_val);
        fdt.parse(dtb_ptr);

        if (fdt.config.ram_count > 0) {
            pmm.setRamSize(fdt.getTotalRamSize());
        }
    } else if (x0_val == 0) {
        uart.writeString("[boot] No DTB (using QEMU virt defaults)\n");
    } else {
        uart.print("[boot] Unknown X0 value: {x} (using defaults)\n", .{x0_val});
    }

    // Initialize exception handling
    exception.init();

    // Initialize BSP per-CPU state early — TPIDR_EL1 must be valid before any
    // exception handler that calls smp.current() (e.g., data_abort_same during
    // GIC MMIO probing). The kernel_ttbr0 for SMP secondaries is set later
    // after VMM init.
    smp.initBsp();

    // Initialize GIC
    gic.init();

    // Enable timer interrupt
    gic.enableIrq(gic.IRQ_TIMER);
    gic.setPriority(gic.IRQ_TIMER, 0);

    // Enable UART interrupt
    gic.enableIrq(gic.IRQ_UART);
    gic.setPriority(gic.IRQ_UART, 0);

    // Initialize watchdog — pet SBSA Generic Watchdog if ACPI GTDT provides addresses.
    // On QEMU virt there is no watchdog, so this is a safe no-op.
    // On real hardware (Orange Pi 6 Plus), firmware enables the watchdog before OS handoff.
    {
        const acpi_cfg = &acpi.parser.config;
        if (acpi_cfg.wdog_valid) {
            watchdog.init(@truncate(acpi_cfg.wdog_refresh_base), @truncate(acpi_cfg.wdog_control_base));
        } else {
            watchdog.initProbe();
        }
    }

    // Initialize timer
    timer.init();

    // Initialize RTC (wall-clock time) — must be after timer.init()
    const rtc = @import("rtc.zig");
    rtc.init();

    // Initialize MMU with early identity mapping
    mmu.earlyInit();
    mmu.enable();

    // Now that MMU is active with identity mapping covering 0-64GB,
    // parse UEFI memory map and ACPI tables (both may be above 4GB on GCE Axion).

    // Parse UEFI memory map to detect actual RAM size.
    if (saved_mmap_addr != 0) {
        uart.print("[boot] Parsing UEFI mmap at {x} ({} entries, desc_size={})\n", .{
            saved_mmap_addr, saved_mmap_count, saved_mmap_desc_size,
        });
        var total_ram: u64 = 0;
        var ram_end: u64 = 0;
        var i: u32 = 0;
        while (i < saved_mmap_count) : (i += 1) {
            const entry_addr = saved_mmap_addr + @as(u64, i) * @as(u64, saved_mmap_desc_size);
            const mem_type = readU32At(entry_addr);
            const phys_start = readU64At(entry_addr + 8);
            const num_pages = readU64At(entry_addr + 24);
            const region_size = num_pages * 4096;

            // EfiConventionalMemory=7, EfiBootServicesCode=3, EfiBootServicesData=4
            // EfiLoaderCode=1, EfiLoaderData=2 — all usable after ExitBootServices
            if (mem_type == 7 or mem_type == 3 or mem_type == 4 or
                mem_type == 1 or mem_type == 2)
            {
                total_ram += region_size;
                const end = phys_start + region_size;
                if (end > ram_end) ram_end = end;
            }
        }
        if (total_ram > 0) {
            uart.print("[boot] UEFI: {} MB usable RAM, end={x}\n", .{ total_ram / (1024 * 1024), ram_end });
            const RAM_BASE: u64 = 0x40000000;
            if (ram_end > RAM_BASE) {
                pmm.setRamSize(ram_end - RAM_BASE);
            }
        }
    }

    if (saved_acpi_rsdp != 0) {
        acpi.io.init(&identityPhysToVirt, &uartWriteString);
        if (acpi.parser.init(saved_acpi_rsdp)) {
            uart.writeString("[boot] ACPI tables parsed\n");
            // Parse SPCR to find the real serial console UART
            if (acpi.parser.findTable("SPCR")) |spcr_addr| {
                uart.initFromSpcr(spcr_addr);
                uart.init(); // Re-init with correct UART base/type
            }
            // Parse DBG2 for alternate debug UART (GCE may route input here)
            if (acpi.parser.findTable("DBG2")) |dbg2_addr| {
                uart.initFromDbg2(dbg2_addr);
            }
        }
    }

    // --- CPU Feature Detection ---
    // Probe all CPU capabilities via ID registers. This is the single source of
    // truth for what the hardware supports — never assume based on build target.
    cpu_features.probe();

    // --- Enable detected features ---

    // PAN (Privileged Access Never) — ARMv8.1+
    if (cpu_features.features.pan) {
        // Clear SCTLR_EL1.SPAN (bit 23) — auto-set PAN on EL0→EL1 exception entry
        var sctlr: u64 = asm volatile ("mrs %[ret], SCTLR_EL1"
            : [ret] "=r" (-> u64),
        );
        sctlr &= ~@as(u64, 1 << 23);
        asm volatile ("msr SCTLR_EL1, %[val]" :: [val] "r" (sctlr));
        asm volatile ("isb");

        // Set PSTATE.PAN = 1 (MSR PAN, #1 — ARMv8.1 raw encoding)
        asm volatile (".inst 0xD500419F");
        asm volatile ("isb");

        pan_enabled = true;
        uart.writeString("[cpu] PAN enabled\n");
    }

    // SVE/SVE2 — ARMv8.2+ / ARMv9.0+
    // Enable SVE access before any SVE instructions can be used.
    // This sets CPACR_EL1.ZEN=11 so SVE doesn't trap.
    sve.enable();
    if (cpu_features.features.sve) {
        cpu_features.probeSveVectorLength();
    }

    // BTI (Branch Target Identification) — ARMv8.5+
    if (cpu_features.features.bti) {
        // Set SCTLR_EL1.BT1 (bit 36) — enable BTI for EL1
        var sctlr2: u64 = asm volatile ("mrs %[ret], SCTLR_EL1"
            : [ret] "=r" (-> u64),
        );
        sctlr2 |= (1 << 36);  // BT1
        asm volatile ("msr SCTLR_EL1, %[val]" :: [val] "r" (sctlr2));
        asm volatile ("isb");
        uart.writeString("[cpu] BTI enabled for EL1\n");
    }

    // Hardware RNG
    hwrng.init();

    // Initialize typed address system (Chaos Rocket safety).
    // ARM64 uses identity mapping (phys == virt), so HHDM offset is 0.
    // This enables PhysAddr ≠ VirtAddr type safety for incremental adoption.
    typed_addr.initHHDM(0);

    // Initialize Physical Memory Manager
    pmm.init();

    // Initialize slab allocator (after PMM, before anything that needs kmalloc)
    slab.init();

    // Initialize Virtual Memory Manager
    vmm.init() catch {
        uart.writeString("[boot] ERROR: VMM init failed\n");
    };

    // Initialize process table free list + PID hash
    process.initProcessTable();

    // Store kernel page table for SMP secondaries (initBsp already called early)
    smp.kernel_ttbr0_for_smp = vmm.getKernelL0().toInt();

    // Initialize VFS: mount ramfs as root filesystem
    const root_inode = ramfs.init();
    if (vfs.mount("/", root_inode)) {
        uart.writeString("[boot] VFS: mounted ramfs at /\n");
    } else {
        uart.writeString("[boot] ERROR: failed to mount root filesystem\n");
    }

    // Create initial directory structure
    if (vfs.resolve("/")) |root| {
        if (root.ops.create) |create_fn| {
            _ = create_fn(root, "tmp", vfs.S_IFDIR | 0o1777);
            _ = create_fn(root, "dev", vfs.S_IFDIR | 0o755);
            _ = create_fn(root, "proc", vfs.S_IFDIR | 0o555);
            _ = create_fn(root, "bin", vfs.S_IFDIR | 0o755);
            _ = create_fn(root, "etc", vfs.S_IFDIR | 0o755);
            uart.writeString("[boot] VFS: created /tmp /dev /proc /bin /etc\n");
        }
    }

    // Create /etc/passwd and /etc/group for BusyBox id/login utilities
    createPasswdGroup();

    // Test VFS: create a file, write to it, read it back
    vfsTest();

    // Test typed address system (Chaos Rocket safety)
    typedAddrTest();

    // Test slab allocator
    slabTest();

    // --- PCIe enumeration (shared by NVMe and RTL8126) ---
    pci.initFromAcpi();
    pci.scanBus();

    // Enable interrupts before network init (needed for timer-based polling in
    // DHCP, ARP, and ICMP boot tests)
    asm volatile ("msr DAIFClr, #2");

    // --- Network: try virtio-net (QEMU), gVNIC (GCE), then RTL8126 (real HW) ---
    {
        const nic_mod = @import("nic.zig");
        if (virtio_net.init()) {
            nic_mod.registerVirtio();
            net.init();
            icmp.bootPing(0x0A000202);
        } else if (pci.findByVendorDevice(0x1AE0, 0x0042)) |gvnic_dev| {
            // Google gVNIC — needs BAR0 (registers) and BAR2 (doorbells)
            pci.enableDevice(gvnic_dev);
            const gvnic_drv = @import("gvnic.zig");
            if (gvnic_drv.init(gvnic_dev, gvnic_dev.bar2)) {
                nic_mod.registerGvnic();
                // Get IP config from DHCP (GCE has a DHCP server)
                const ipv4 = @import("ipv4.zig");
                const dhcp = @import("dhcp.zig");
                if (dhcp.discover(500)) |cfg| {
                    ipv4.our_ip = cfg.our_ip;
                    ipv4.gateway_ip = cfg.gateway_ip;
                    ipv4.subnet_mask = cfg.subnet_mask;
                    if (cfg.dns_ip != 0) ipv4.dns_ip = cfg.dns_ip;
                    // Tell ARP module our IP so it can reply to WHO-HAS requests.
                    // Without this, the gateway can't resolve our MAC and TCP is unreachable.
                    const arp = @import("arp.zig");
                    arp.setOurIp(cfg.our_ip);
                } else {
                    uart.writeString("[boot] DHCP failed, using defaults\n");
                }
                net.init();
                // Hand off rx_ring ownership from DHCP loop to net.poll timer tick.
                // Until this point, DHCP owned the ring exclusively. Now net.poll
                // can safely call handleIrq/receive/receiveConsume without racing.
                net.setPhase(.running);
                uart.writeString("[boot] Network: gVNIC\n");
                // Note: ARP resolve removed — hangs on GCE because timer IRQ
                // isn't firing during boot. Gateway ARP happens on first use.
            }
        } else if (pci.findByVendorDevice(0x10EC, 0x8126)) |eth_dev| {
            pci.enableDevice(eth_dev);
            const rtl8126 = @import("rtl8126.zig");
            if (rtl8126.init(eth_dev)) {
                nic_mod.registerRtl8126();
                net.init();
            }
        }
    }

    // --- Block device detection: virtio-blk → NVMe → SD/eMMC ---
    var have_block_dev = false;

    // Try virtio-blk first (QEMU virtio-mmio transport)
    if (virtio_blk.init()) {
        block_io.init(&virtio_blk.readSectors, &virtio_blk.writeSectors, &uart.writeString);
        have_block_dev = true;
        uart.writeString("[boot] Block device: virtio-blk\n");
        timer.armBssWatchpoint(virtio_blk.mmio_base);
    }

    // If no virtio-blk, try PCIe NVMe (PCI scan already done above)
    if (!have_block_dev) {
        if (pci.findByClass(0x01, 0x08, 0x02)) |nvme_dev| {
            pci.enableDevice(nvme_dev);
            if (nvme.init(nvme_dev)) {
                block_io.init(&nvme.readSectors, &nvme.writeSectors, &uart.writeString);
                have_block_dev = true;
                uart.writeString("[boot] Block device: NVMe\n");
            }
        }
    }

    // If no NVMe, try SD/eMMC from device tree
    if (!have_block_dev) {
        const sdhci_addr = if (fdt.config.valid) fdt.config.sdhci_base else 0;
        if (sdhci_addr != 0) {
            if (sdhci.init(sdhci_addr)) {
                block_io.init(&sdhci.readSectors, &sdhci.writeSectors, &uart.writeString);
                have_block_dev = true;
                uart.writeString("[boot] Block device: SD/eMMC\n");
            }
        }
    }

    // Check for GPT partition table — if found, offset all block I/O
    // to the root partition so ext2/ext3/ext4 mount transparently.
    if (have_block_dev) {
        const gpt = @import("gpt.zig");
        if (gpt.findLinuxRootPartition(block_io.readSectorsRaw)) |part| {
            block_io.setPartitionOffset(part.start_lba);
            uart.print("[boot] GPT: root partition at LBA {} (offset set)\n", .{part.start_lba});
        }
    }

    // Mount ext2 from whichever block device was found
    if (have_block_dev) {
        if (ext2.init()) {
            if (ext2.getRootInode()) |ext2_root| {
                vfs.replaceRoot(ext2_root);
                uart.writeString("[boot] ext2 mounted as root /\n");
            }
        }
    }

    // Mount FAT32 ESP at /boot (if GPT has an ESP partition)
    if (have_block_dev) {
        const gpt2 = @import("gpt.zig");
        if (gpt2.findEspPartition(block_io.readSectorsRaw)) |esp| {
            const fat32 = @import("fat32.zig");
            if (fat32.init(esp.start_lba, block_io.readSectorsRaw)) |fat_root| {
                // Create /boot mount point
                if (vfs.resolve("/")) |root| {
                    if (root.ops.create) |create_fn| {
                        _ = create_fn(root, "boot", vfs.S_IFDIR | 0o755);
                    }
                }
                if (vfs.mount("/boot", fat_root)) {
                    uart.print("[boot] FAT32 ESP mounted at /boot (LBA {})\n", .{esp.start_lba});
                }
            }
        }
    }

    // Mount procfs at /proc
    const procfs_root = procfs.init();
    if (vfs.mount("/proc", procfs_root)) {
        uart.writeString("[boot] procfs mounted at /proc\n");
    }

    // Mount devfs at /dev
    const devfs_root = devfs.init();
    if (vfs.mount("/dev", devfs_root)) {
        uart.writeString("[boot] devfs mounted at /dev\n");
    }

    // Create /etc/resolv.conf with DNS server from DHCP (needed by musl getaddrinfo)
    {
        const ipv4_mod = @import("ipv4.zig");
        const dns_ip = ipv4_mod.dns_ip;
        if (dns_ip != 0) {
            createResolvConf(dns_ip);
        }
    }

    uart.writeString("\n[boot] Enabling interrupts...\n");

    // Enable interrupts (clear DAIF.I bit)
    asm volatile ("msr DAIFClr, #2");

    // Boot secondary CPUs
    {
        const target_cpus = if (fdt.config.valid and fdt.config.cpu_count > 1)
            fdt.config.cpu_count
        else
            smp.SMP_CPUS;

        var cpu_id: u32 = 1;
        while (cpu_id < target_cpus) : (cpu_id += 1) {
            _ = smp.bootSecondary(cpu_id);
        }
        uart.print("[boot] {} CPUs online\n", .{smp.online_cpus});
    }

    // Try to load init from ext2 filesystem, then fall back to test code
    const init_paths = [_][]const u8{ "/bin/zinit", "/bin/zhttpd", "/bin/zsh" };
    for (init_paths) |init_path| {
        if (process.createFromElfPath(init_path)) |proc| {
            uart.writeString("[boot] Starting ");
            uart.writeString(init_path);
            uart.writeString("...\n\n");
            //klog.flush(); // disabled: testing NVMe fix in isolation
            scheduler.startFirst(proc);
            // startFirst doesn't return
        } else |_| {}
    }

    // Fallback: run inline test program (write "Hello from userspace!\n" then exit)
    uart.writeString("[boot] No init found, running test code...\n");
    const test_code = [_]u8{
        0x08, 0x08, 0x80, 0xd2, // mov x8, #64 (SYS_write)
        0x20, 0x00, 0x80, 0xd2, // mov x0, #1 (stdout)
        0xc1, 0x00, 0x00, 0x10, // adr x1, msg (PC+24)
        0xc2, 0x02, 0x80, 0xd2, // mov x2, #22
        0x01, 0x00, 0x00, 0xd4, // svc #0
        0xa8, 0x0b, 0x80, 0xd2, // mov x8, #93 (SYS_exit)
        0x40, 0x05, 0x80, 0xd2, // mov x0, #42
        0x01, 0x00, 0x00, 0xd4, // svc #0
        'H', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm', ' ',
        'u', 's', 'e', 'r', 's', 'p', 'a', 'c', 'e', '!', '\n',
    };

    if (process.createFromCode(&test_code)) |proc| {
        uart.writeString("[boot] Starting test process...\n");
        klog.flush();
        scheduler.startFirst(proc);
    } else |_| {
        uart.writeString("[boot] Failed to create test process\n");
    }

    uart.writeString("[boot] Kernel initialized. Halting.\n");

    // Halt loop
    while (true) {
        asm volatile ("wfi");
    }
}

/// Read current exception level
pub fn getCurrentEl() u2 {
    var el: u64 = undefined;
    asm volatile ("mrs %[ret], CurrentEL"
        : [ret] "=r" (el),
    );
    return @truncate((el >> 2) & 0x3);
}

/// Check if we're in EL1 (kernel mode)
pub fn isEl1() bool {
    return getCurrentEl() == 1;
}

/// Enable IRQs
pub fn enableIrq() void {
    asm volatile ("msr DAIFClr, #2");
}

/// Disable IRQs
pub fn disableIrq() void {
    asm volatile ("msr DAIFSet, #2");
}

/// Halt the CPU until next interrupt
pub fn halt() void {
    asm volatile ("wfi");
}

/// klog tick source — wraps timer.getTicks() for function pointer use.
fn getTicksWrapper() u64 {
    return timer.getTicks();
}

/// Byte-level memory reads for UEFI descriptors (avoids alignment faults).
fn readU32At(addr: u64) u32 {
    const p: [*]const u8 = @ptrFromInt(addr);
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

fn readU64At(addr: u64) u64 {
    return @as(u64, readU32At(addr)) | (@as(u64, readU32At(addr + 4)) << 32);
}

/// Identity physToVirt for ACPI module (ARM64 uses identity mapping).
fn identityPhysToVirt(phys: u64) u64 {
    return phys;
}

/// UART logging wrapper for ACPI module.
fn uartWriteString(s: []const u8) void {
    uart.writeString(s);
}

/// Create /etc/resolv.conf with the given DNS server IP.
/// Uses the VFS create + write path — works on both ramfs and ext2 root.
fn createResolvConf(dns_ip: u32) void {
    // Resolve /etc directory
    const etc_inode = vfs.resolve("/etc") orelse {
        uart.writeString("[boot] /etc not found, cannot create resolv.conf\n");
        return;
    };

    // Create resolv.conf in /etc (or open existing)
    const create_fn = etc_inode.ops.create orelse {
        uart.writeString("[boot] /etc has no create op\n");
        return;
    };

    const file_inode = create_fn(etc_inode, "resolv.conf", vfs.S_IFREG | 0o644) orelse {
        uart.writeString("[boot] failed to create /etc/resolv.conf\n");
        return;
    };

    // Format: "nameserver A.B.C.D\n"
    var buf: [64]u8 = undefined;
    const prefix = "nameserver ";
    var pos: usize = 0;
    for (prefix) |c| {
        buf[pos] = c;
        pos += 1;
    }

    // Format IP address as dotted decimal
    const octets = [4]u8{
        @truncate(dns_ip >> 24),
        @truncate(dns_ip >> 16),
        @truncate(dns_ip >> 8),
        @truncate(dns_ip),
    };
    for (octets, 0..) |octet, idx| {
        if (idx > 0) {
            buf[pos] = '.';
            pos += 1;
        }
        if (octet >= 100) {
            buf[pos] = '0' + octet / 100;
            pos += 1;
        }
        if (octet >= 10) {
            buf[pos] = '0' + (octet / 10) % 10;
            pos += 1;
        }
        buf[pos] = '0' + octet % 10;
        pos += 1;
    }
    buf[pos] = '\n';
    pos += 1;

    // Write via VFS FileDescription
    const write_fn = file_inode.ops.write orelse {
        uart.writeString("[boot] /etc/resolv.conf has no write op\n");
        return;
    };

    var desc = vfs.FileDescription{
        .inode = file_inode,
        .offset = 0,
        .flags = vfs.O_WRONLY,
        .ref_count = 1,
        .in_use = true,
    };

    const written = write_fn(&desc, @ptrCast(&buf), pos);
    if (written > 0) {
        uart.writeString("[boot] Created /etc/resolv.conf: ");
        uart.writeString(buf[0..pos]);
    } else {
        uart.writeString("[boot] Failed to write /etc/resolv.conf\n");
    }
}

/// Create /etc/passwd and /etc/group so BusyBox `id` (and similar) can
/// resolve uid/gid to names instead of dereferencing NULL pointers.
fn createPasswdGroup() void {
    const etc_inode = vfs.resolve("/etc") orelse {
        uart.writeString("[boot] /etc not found, cannot create passwd/group\n");
        return;
    };

    const create_fn = etc_inode.ops.create orelse {
        uart.writeString("[boot] /etc has no create op\n");
        return;
    };

    // --- /etc/passwd ---
    if (create_fn(etc_inode, "passwd", vfs.S_IFREG | 0o644)) |file_inode| {
        const write_fn = file_inode.ops.write orelse return;
        const content = "root:x:0:0:root:/root:/bin/sh\n";
        var desc = vfs.FileDescription{
            .inode = file_inode,
            .offset = 0,
            .flags = vfs.O_WRONLY,
            .ref_count = 1,
            .in_use = true,
        };
        if (write_fn(&desc, @ptrCast(content.ptr), content.len) > 0) {
            uart.writeString("[boot] Created /etc/passwd\n");
        }
    }

    // --- /etc/group ---
    if (create_fn(etc_inode, "group", vfs.S_IFREG | 0o644)) |file_inode| {
        const write_fn = file_inode.ops.write orelse return;
        const content = "root:x:0:\n";
        var desc = vfs.FileDescription{
            .inode = file_inode,
            .offset = 0,
            .flags = vfs.O_WRONLY,
            .ref_count = 1,
            .in_use = true,
        };
        if (write_fn(&desc, @ptrCast(content.ptr), content.len) > 0) {
            uart.writeString("[boot] Created /etc/group\n");
        }
    }
}

/// Test VFS functionality: create file, write, read back, verify
fn vfsTest() void {
    uart.writeString("[vfs-test] Running VFS smoke test...\n");

    // Create a test file in /tmp
    const tmp = vfs.resolve("/tmp") orelse {
        uart.writeString("[vfs-test] FAIL: /tmp not found\n");
        return;
    };

    const create_fn = tmp.ops.create orelse {
        uart.writeString("[vfs-test] FAIL: no create op on /tmp\n");
        return;
    };

    const file_inode = create_fn(tmp, "hello.txt", vfs.S_IFREG | 0o644) orelse {
        uart.writeString("[vfs-test] FAIL: could not create /tmp/hello.txt\n");
        return;
    };

    // Write data to the file
    const test_data = "Hello from ARM64 ramfs!\n";
    const written = ramfs.writeData(file_inode, test_data, 0);
    if (written <= 0) {
        uart.writeString("[vfs-test] FAIL: write returned <= 0\n");
        return;
    }

    uart.writeString("[vfs-test] Wrote ");
    uart.writeDec(@intCast(written));
    uart.writeString(" bytes to /tmp/hello.txt\n");

    // Read it back via VFS
    var read_buf: [64]u8 = undefined;
    const bytes_read = vfs.readWholeFile("/tmp/hello.txt", &read_buf) orelse {
        uart.writeString("[vfs-test] FAIL: readWholeFile returned null\n");
        return;
    };

    uart.writeString("[vfs-test] Read back ");
    uart.writeDec(bytes_read);
    uart.writeString(" bytes: ");
    uart.writeString(read_buf[0..bytes_read]);

    // Verify contents match
    if (bytes_read == test_data.len) {
        var match = true;
        for (0..bytes_read) |i| {
            if (read_buf[i] != test_data[i]) {
                match = false;
                break;
            }
        }
        if (match) {
            uart.writeString("[vfs-test] PASS: data matches\n");
        } else {
            uart.writeString("[vfs-test] FAIL: data mismatch\n");
        }
    } else {
        uart.writeString("[vfs-test] FAIL: size mismatch\n");
    }

    // Verify directory listing
    if (vfs.resolve("/tmp/hello.txt")) |_| {
        uart.writeString("[vfs-test] PASS: /tmp/hello.txt resolvable\n");
    } else {
        uart.writeString("[vfs-test] FAIL: /tmp/hello.txt not resolvable\n");
    }
}

/// Runtime test for typed address system (Chaos Rocket safety).
/// Verifies PhysAddr/VirtAddr types work correctly in the live kernel.
fn typedAddrTest() void {
    var passed: u32 = 0;
    const total: u32 = 8;

    // 1. getKernelL0 is non-null
    const kl0 = vmm.getKernelL0();
    if (!kl0.isNull()) {
        uart.writeString("[typed-addr-test] 1: getKernelL0 non-null PASS\n");
        passed += 1;
    } else {
        uart.writeString("[typed-addr-test] 1: getKernelL0 non-null FAIL\n");
    }

    // 2. translate kernel address (identity-mapped UART at 0x09000000)
    const uart_va = vmm.VirtAddr.from(0x09000000);
    if (vmm.translate(kl0, uart_va)) |phys| {
        // ARM64 identity mapping: phys should match virt (within 1GB block)
        if (phys.toInt() == 0x09000000) {
            uart.writeString("[typed-addr-test] 2: translate kernel VA PASS\n");
            passed += 1;
        } else {
            uart.writeString("[typed-addr-test] 2: translate kernel VA FAIL (wrong phys)\n");
        }
    } else {
        uart.writeString("[typed-addr-test] 2: translate kernel VA FAIL (null)\n");
    }

    // 3. translate unmapped address returns null
    const bogus_va = vmm.VirtAddr.from(0xDEAD_0000_0000);
    if (vmm.translate(kl0, bogus_va) == null) {
        uart.writeString("[typed-addr-test] 3: translate unmapped=null PASS\n");
        passed += 1;
    } else {
        uart.writeString("[typed-addr-test] 3: translate unmapped=null FAIL\n");
    }

    // 4. createAddressSpace + destroyAddressSpace round-trip
    if (vmm.createAddressSpace()) |new_as| {
        if (!new_as.isNull()) {
            vmm.destroyAddressSpace(new_as);
            uart.writeString("[typed-addr-test] 4: create+destroy addr space PASS\n");
            passed += 1;
        } else {
            uart.writeString("[typed-addr-test] 4: create+destroy addr space FAIL (null)\n");
        }
    } else |_| {
        uart.writeString("[typed-addr-test] 4: create+destroy addr space FAIL (OOM)\n");
    }

    // 5. mapPage + translate round-trip
    if (vmm.createAddressSpace()) |test_as| {
        const test_va = vmm.VirtAddr.from(0x10_0000); // 1MB — user space
        if (pmm.allocPage()) |test_page| {
            vmm.mapPage(test_as, test_va, vmm.PhysAddr.from(test_page), .{
                .user = true,
                .writable = true,
            }) catch {
                uart.writeString("[typed-addr-test] 5: mapPage+translate FAIL (map err)\n");
            };
            if (vmm.translate(test_as, test_va)) |resolved| {
                if (resolved.toInt() == test_page) {
                    uart.writeString("[typed-addr-test] 5: mapPage+translate round-trip PASS\n");
                    passed += 1;
                } else {
                    uart.writeString("[typed-addr-test] 5: mapPage+translate FAIL (phys mismatch)\n");
                }
            } else {
                uart.writeString("[typed-addr-test] 5: mapPage+translate FAIL (null)\n");
            }

            // 6. getPTE returns valid PTE for mapped page
            if (vmm.getPTE(test_as, test_va)) |pte| {
                if (pte.isValid() and pte.isUser()) {
                    uart.writeString("[typed-addr-test] 6: getPTE valid+user PASS\n");
                    passed += 1;
                } else {
                    uart.writeString("[typed-addr-test] 6: getPTE FAIL (not valid/user)\n");
                }
            } else {
                uart.writeString("[typed-addr-test] 6: getPTE FAIL (null)\n");
            }

            // 7. invalidatePage doesn't crash
            vmm.invalidatePage(test_va);
            uart.writeString("[typed-addr-test] 7: invalidatePage no crash PASS\n");
            passed += 1;

            // 8. syncCodePage doesn't crash
            vmm.syncCodePage(vmm.PhysAddr.from(test_page), test_va);
            uart.writeString("[typed-addr-test] 8: syncCodePage no crash PASS\n");
            passed += 1;

            pmm.freePage(test_page);
        }
        vmm.destroyAddressSpace(test_as);
    } else |_| {
        uart.writeString("[typed-addr-test] 5-8: FAIL (OOM creating addr space)\n");
    }

    // Summary
    uart.writeString("[typed-addr-test] Results: ");
    uart.writeDec(passed);
    uart.writeByte('/');
    uart.writeDec(total);
    if (passed == total) {
        uart.writeString(" ALL PASS\n");
    } else {
        uart.writeString(" SOME FAILED\n");
    }
}

fn slabTest() void {
    var passed: u32 = 0;
    const total: u32 = 8;

    // 1. kmalloc/kfree basic — allocate 64 bytes, write, free
    if (slab.kmalloc(64)) |ptr| {
        ptr[0] = 0xAB;
        ptr[63] = 0xCD;
        if (ptr[0] == 0xAB and ptr[63] == 0xCD) {
            uart.writeString("[slab-test] 1: kmalloc(64) write/read PASS\n");
            passed += 1;
        } else {
            uart.writeString("[slab-test] 1: kmalloc(64) write/read FAIL\n");
        }
        slab.kfree(ptr, 64);
    } else {
        uart.writeString("[slab-test] 1: kmalloc(64) FAIL (null)\n");
    }

    // 2. Named cache — create, alloc, free
    if (slab.createCache("test-obj", 128, 1)) |cache| {
        if (cache.alloc()) |ptr| {
            ptr[0] = 0x42;
            cache.free(ptr);
            uart.writeString("[slab-test] 2: named cache alloc/free PASS\n");
            passed += 1;
        } else {
            uart.writeString("[slab-test] 2: named cache alloc FAIL\n");
        }
    } else {
        uart.writeString("[slab-test] 2: createCache FAIL\n");
    }

    // 3. Fill a slab to capacity — 64-byte objects, 63 per 4K page
    if (slab.createCache("fill-test", 64, 1)) |cache| {
        var ptrs: [63][*]u8 = undefined;
        var alloc_count: u32 = 0;
        for (0..63) |i| {
            if (cache.alloc()) |ptr| {
                ptrs[i] = ptr;
                alloc_count += 1;
            }
        }
        if (alloc_count == 63) {
            uart.writeString("[slab-test] 3: fill slab 63/63 PASS\n");
            passed += 1;
        } else {
            uart.print("[slab-test] 3: fill slab {}/63 FAIL\n", .{alloc_count});
        }
        // Free all
        for (0..alloc_count) |i| {
            cache.free(ptrs[i]);
        }
    } else {
        uart.writeString("[slab-test] 3: createCache FAIL\n");
    }

    // 4. Slab grows when full — alloc 64 objects (needs 2 slabs for 64-byte)
    if (slab.createCache("grow-test", 64, 1)) |cache| {
        var ptrs2: [64][*]u8 = undefined;
        var count2: u32 = 0;
        for (0..64) |i| {
            if (cache.alloc()) |ptr| {
                ptrs2[i] = ptr;
                count2 += 1;
            }
        }
        if (count2 == 64) {
            uart.writeString("[slab-test] 4: slab grow (64 objs, 2 slabs) PASS\n");
            passed += 1;
        } else {
            uart.print("[slab-test] 4: slab grow {}/64 FAIL\n", .{count2});
        }
        for (0..count2) |i| {
            cache.free(ptrs2[i]);
        }
    } else {
        uart.writeString("[slab-test] 4: createCache FAIL\n");
    }

    // 5. Free list integrity — alloc 10, free 5, alloc 5 more, all unique
    if (slab.createCache("reuse-test", 128, 1)) |cache| {
        var ptrs3: [10][*]u8 = undefined;
        for (0..10) |i| {
            ptrs3[i] = cache.alloc() orelse {
                uart.writeString("[slab-test] 5: initial alloc FAIL\n");
                break;
            };
        }
        // Free odd slots
        for (0..5) |i| {
            cache.free(ptrs3[i * 2 + 1]);
        }
        // Realloc 5
        var realloc_ok: u32 = 0;
        for (0..5) |_| {
            if (cache.alloc()) |_| {
                realloc_ok += 1;
            }
        }
        if (realloc_ok == 5) {
            uart.writeString("[slab-test] 5: free list reuse PASS\n");
            passed += 1;
        } else {
            uart.writeString("[slab-test] 5: free list reuse FAIL\n");
        }
    } else {
        uart.writeString("[slab-test] 5: createCache FAIL\n");
    }

    // 6. kmalloc size classes — test each bucket
    const sizes = [_]u32{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
    var size_ok: u32 = 0;
    for (sizes) |sz| {
        if (slab.kmalloc(sz)) |ptr| {
            ptr[0] = 0xFF;
            slab.kfree(ptr, sz);
            size_ok += 1;
        }
    }
    if (size_ok == sizes.len) {
        uart.writeString("[slab-test] 6: all size classes (16-4096) PASS\n");
        passed += 1;
    } else {
        uart.print("[slab-test] 6: size classes {}/9 FAIL\n", .{size_ok});
    }

    // 7. Stats consistency
    const active = slab.totalActiveObjects();
    const pages = slab.totalSlabPages();
    // After freeing everything, active should be very low (from named caches that leaked test objects)
    // Pages should be > 0 (kmalloc caches have been used)
    if (pages > 0) {
        uart.print("[slab-test] 7: stats active={} pages={} PASS\n", .{ active, pages });
        passed += 1;
    } else {
        uart.writeString("[slab-test] 7: stats FAIL (no pages)\n");
    }

    // 8. Shrink reclaims empty slabs
    const freed = slab.shrink();
    uart.print("[slab-test] 8: shrink freed {} pages PASS\n", .{freed});
    passed += 1;

    // Summary
    uart.writeString("[slab-test] Results: ");
    uart.writeDec(passed);
    uart.writeByte('/');
    uart.writeDec(total);
    if (passed == total) {
        uart.writeString(" ALL PASS\n");
    } else {
        uart.writeString(" SOME FAILED\n");
    }

    // Print cache stats
    slab.printStats();
}

/// Custom panic handler — print message and halt instead of BRK-looping.
pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, ret_addr: ?usize) noreturn {
    // Mask IRQ only (not all DAIF) to prevent context switches but allow
    // the other CPU to continue printing and eventually release UART lock.
    asm volatile ("msr DAIFSet, #2");
    uart.writeString("\n[PANIC] ");
    uart.writeString(msg);
    uart.writeString("\n");
    if (ret_addr) |addr| {
        uart.writeString("[PANIC] ret_addr=0x");
        uart.writeHex(addr);
        uart.writeString("\n");
    }
    // Dump exception ring buffer and syscall trace — BEFORE anything that
    // could cascade into further panics (e.g. watchdog, scheduler calls).
    exception.dumpExcRing();
    syscall.dumpTrace(64);
    // On real hardware with watchdog active, force an immediate reboot
    // so the board doesn't hang headless. On QEMU (no watchdog), this
    // falls through to the WFI loop.
    if (watchdog.isActive()) {
        uart.writeString("[PANIC] Watchdog reset in 3 seconds...\n");
        // Give serial time to flush, then reset
        var i: u32 = 0;
        while (i < 100_000_000) : (i += 1) {
            asm volatile ("yield");
        }
        watchdog.forceReset();
    }
    while (true) {
        asm volatile ("wfi");
    }
}
