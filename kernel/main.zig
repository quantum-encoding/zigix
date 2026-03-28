const std = @import("std");
const limine = @import("limine.zig");
const serial = @import("arch/x86_64/serial.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pic = @import("arch/x86_64/pic.zig");
const pit = @import("arch/x86_64/pit.zig");
const tss = @import("arch/x86_64/tss.zig");
const syscall_entry = @import("arch/x86_64/syscall_entry.zig");
const hhdm = @import("mm/hhdm.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const process = @import("proc/process.zig");
const scheduler = @import("proc/scheduler.zig");
const user_program = @import("proc/user_program.zig");
const syscall_table = @import("proc/syscall_table.zig");
const vfs = @import("fs/vfs.zig");
const ramfs = @import("fs/ramfs.zig");
const tmpfs = @import("fs/tmpfs.zig");
const procfs = @import("fs/procfs.zig");
const devfs = @import("fs/devfs.zig");
const pipe = @import("fs/pipe.zig");
const pci_mod = @import("drivers/pci.zig");
const virtio_blk = @import("drivers/virtio_blk.zig");
const virtio_net = @import("drivers/virtio_net.zig");
const nvme = @import("drivers/nvme.zig");
const block_io = @import("fs/ext3/block_io.zig");
const ext2 = @import("fs/ext2.zig");
const console = @import("drivers/console.zig");
const ps2_keyboard = @import("drivers/ps2_keyboard.zig");
const swap = @import("mm/swap.zig");
const net = @import("net/net.zig");
const arp = @import("net/arp.zig");
const icmp = @import("net/icmp.zig");
const ipv4 = @import("net/ipv4.zig");
const boot_info_mod = @import("boot_info.zig");
const acpi_parser = @import("acpi/acpi_parser.zig");
const acpi_io = @import("acpi/acpi_io.zig");
const klog = @import("klog/klog.zig");
const smp = @import("arch/x86_64/smp.zig");
const lapic = @import("arch/x86_64/lapic.zig");

// ---- Static buffer for loading shell ELF from ext2 ----

var shell_elf_buf: [65536]u8 = undefined;

// ---- Limine requests (placed in .limine_reqs section) ----

pub export var base_revision: limine.BaseRevision linksection(".limine_reqs") = .{};
pub export var memmap_request: limine.MemmapRequest linksection(".limine_reqs") = .{};
pub export var hhdm_request: limine.HhdmRequest linksection(".limine_reqs") = .{};
// SMP uses INIT/SIPI/SIPI (kernel-owned AP boot), not Limine SMP protocol

// ---- Kernel entry point ----

export fn _start(boot_info_addr: u64) callconv(.c) noreturn {
    // Earliest possible diagnostic — raw COM1 write before anything else.
    // This confirms the kernel entry point was reached.
    earlySerialStr("[kernel] _start reached\r\n");

    // Enable SSE — required before any code that might use SSE/AVX instructions.
    enableSSE();
    earlySerialStr("[kernel] SSE enabled\r\n");

    earlySerialStr("[kernel] serial.init()\r\n");
    serial.init();
    earlySerialStr("[kernel] serial.init() done\r\n");
    earlySerialStr("[kernel] console.init()\r\n");
    console.init();
    earlySerialStr("[kernel] console.init() done\r\n");
    earlySerialStr("[kernel] klog.init()\r\n");
    klog.init(&serial.writeString, &serial.writeByte, &getTickCount);
    earlySerialStr("[kernel] klog.init() done\r\n");

    serial.writeString("\n");
    serial.writeString("========================================\n");
    serial.writeString("  Zigix OS\n");
    serial.writeString("  x86_64 bare-metal operating system\n");
    serial.writeString("  Written in Zig by Quantum Encoding Ltd\n");
    serial.writeString("  info@quantumencoding.io\n");
    serial.writeString("========================================\n");
    serial.writeString("\n");
    earlySerialStr("[kernel] banner printed\r\n");

    const log = klog.scoped(.boot);

    // Detect boot source: UEFI bootloader (BootInfo) or Limine
    const uefi_boot = boot_info_mod.isBootInfo(boot_info_addr);

    if (uefi_boot) {
        log.info("uefi_boot", .{});
    } else if (base_revision.isSupported()) {
        log.info("limine_ok", .{});
    } else {
        log.warn("limine_mismatch", .{});
    }

    log.info("serial_ready", .{});

    // Interrupt infrastructure
    gdt.init();
    smp.initBsp(); // Per-CPU state + GS_BASE (must be before idt.init for per-CPU fxsave)
    idt.init();
    pic.init();
    pit.init();

    // Memory initialization (different path for UEFI vs Limine)
    if (uefi_boot) {
        initMemoryFromBootInfo(@ptrFromInt(boot_info_addr));
    } else {
        initMemory();
    }

    // LAPIC timer (replaces PIT IRQ0 for per-CPU scheduling ticks)
    lapic.init();

    // PS/2 keyboard (must be after PIC init)
    ps2_keyboard.init();

    // Enable interrupts
    asm volatile ("sti");
    log.info("interrupts_enabled", .{});

    // Flush boot log entries accumulated before timer tick drain started
    klog.flush();

    log.info("phase_u20", .{});

    // Initialize process table free list
    process.initProcessTable();

    // TSS + syscall table + syscall instruction MSRs
    gdt.loadTss(tss.getTssPtr());
    tss.initIst(); // IST1 for double fault handler
    syscall_entry.init();
    syscall_table.init();
    // syscall_table.trace_all = true; // Debug: trace all processes

    // Boot secondary CPUs (APs) via Limine SMP protocol
    smp.bootAPs();

    // PCI bus scan + block device init (virtio-blk first, NVMe fallback)
    var blk_ok = false;
    pci_mod.scanBus();

    const blk_log = klog.scoped(.virtio);

    // Try virtio-blk first (backward compatibility)
    if (pci_mod.findDevice(0x1AF4, 0x1001)) |dev| {
        if (virtio_blk.init(dev)) {
            block_io.init(&virtio_blk.readSectors, &virtio_blk.writeSectors, &serial.writeString);
            blk_ok = true;
        } else {
            blk_log.err("blk_init_failed", .{});
        }
    }

    // If no virtio-blk, try NVMe
    if (!blk_ok) {
        const nvme_log = klog.scoped(.nvme);
        if (pci_mod.findByClass(0x01, 0x08, 0x02)) |nvme_dev| {
            pci_mod.enableDevice(nvme_dev);
            if (nvme.init(nvme_dev)) {
                block_io.init(&nvme.readSectors, &nvme.writeSectors, &serial.writeString);
                blk_ok = true;
            } else {
                nvme_log.err("init_failed", .{});
            }
        } else {
            nvme_log.warn("no_device", .{});
        }
    }

    // Network init: try gVNIC (GCE) first, then virtio-net (QEMU)
    const net_log = klog.scoped(.net);
    const nic = @import("drivers/nic.zig");
    var net_ok = false;

    // gVNIC: Google Virtual NIC (PCI vendor 0x1AE0, device 0x0042)
    if (pci_mod.findDevice(0x1AE0, 0x0042)) |gvnic_dev| {
        pci_mod.enableDevice(gvnic_dev);
        const gvnic = @import("drivers/gvnic.zig");
        if (gvnic.init(gvnic_dev)) {
            nic.registerGvnic();
            // Get IP from DHCP (GCE has a DHCP server on the virtual network)
            const dhcp = @import("net/dhcp.zig");
            if (dhcp.discover(500)) |cfg| {
                ipv4.our_ip = cfg.our_ip;
                ipv4.gateway_ip = cfg.gateway_ip;
                ipv4.subnet_mask = cfg.subnet_mask;
                if (cfg.dns_ip != 0) ipv4.dns_ip = cfg.dns_ip;
            } else {
                serial.writeString("[boot] DHCP failed, using defaults\n");
            }
            net.init();
            // Initialize kernel DNS resolver with DHCP-provided DNS server
            const dns = @import("lib/dns.zig");
            dns.init(ipv4.dns_ip);
            net_ok = true;
            net_log.info("gvnic_ready", .{});
        } else {
            net_log.err("gvnic_init_failed", .{});
        }
    }

    // Fallback: virtio-net (QEMU)
    if (!net_ok) {
        if (pci_mod.findDevice(0x1AF4, 0x1000)) |net_dev| {
            if (virtio_net.init(net_dev)) {
                nic.registerVirtio();
                net.init();
                net_ok = true;
            } else {
                net_log.err("virtio_init_failed", .{});
            }
        }
    }

    // Check for GPT partition table — offset block I/O to the root partition
    if (blk_ok) {
        const gpt = @import("fs/gpt.zig");
        if (gpt.findLinuxRootPartition(block_io.readSectorsRaw)) |part| {
            block_io.setPartitionOffset(part.start_lba);
            serial.writeString("[boot] GPT: root partition found, offset set\n");
        }
    }

    // Try ext2 on disk, fall back to ramfs
    const fs_log = klog.scoped(.vfs);
    var ext2_mounted = false;
    if (blk_ok) {
        if (ext2.init()) {
            if (ext2.getRootInode()) |root| {
                if (vfs.mount("/", root)) {
                    fs_log.info("mount_ext2", .{});
                    ext2_mounted = true;

                    // Mount tmpfs at /tmp for writable scratch space
                    const tmpfs_root = tmpfs.init();
                    if (vfs.mount("/tmp", tmpfs_root)) {
                        fs_log.info("mount_tmpfs", .{});
                    }

                    // Mount procfs at /proc for process/system info
                    const procfs_root = procfs.init();
                    if (vfs.mount("/proc", procfs_root)) {
                        fs_log.info("mount_procfs", .{});
                    }

                    // Mount devfs at /dev for device nodes
                    const devfs_root = devfs.init();
                    if (vfs.mount("/dev", devfs_root)) {
                        fs_log.info("mount_devfs", .{});
                    }

                    // Initialize swap (requires ext2 mounted for /swapfile)
                    swap.init();

                    testExt2();
                }
            }
        } else {
            fs_log.warn("no_ext2", .{});
        }
    }
    if (!ext2_mounted) {
        const root_inode = ramfs.init();
        if (vfs.mount("/", root_inode)) {
            fs_log.info("mount_ramfs", .{});
        } else {
            fs_log.fatal("no_filesystem", .{});
            halt();
        }
    }

    // Try to load init from /bin/zinit, fall back to /bin/zsh
    const proc_log = klog.scoped(.proc);
    if (ext2_mounted) {
        const init_bytes = vfs.readWholeFile("/bin/zinit", &shell_elf_buf);
        if (init_bytes) |bytes| {
            bootProcess("/bin/zinit", bytes);
        } else if (vfs.readWholeFile("/bin/zsh", &shell_elf_buf)) |bytes| {
            bootProcess("/bin/zsh", bytes);
        } else {
            proc_log.err("no_init_found", .{});
        }
    }

    // Fallback: run a simple hello-world program
    proc_log.info("fallback_start", .{});
    const proc1 = process.createFromCode(&user_program.user_code) catch {
        proc_log.fatal("create_failed", .{});
        halt();
    };

    // Set up stdin/stdout/stderr pointing to serial console
    const fd_table = @import("fs/fd_table.zig");
    fd_table.initStdio(&proc1.fds);

    const mem_log = klog.scoped(.mem);
    mem_log.info("pre_sched_free", .{ .pages = pmm.getFreePages() });

    earlySerialStr("[kernel] About to startFirst()\r\n");
    klog.flush();
    scheduler.startFirst(proc1);
}

// ---- ext2 filesystem test ----

fn testExt2() void {
    const e2_log = klog.scoped(.ext2);
    e2_log.debug("ls_root", .{});

    const root = vfs.getRootInode() orelse return;
    var desc = vfs.allocFileDescription() orelse return;
    desc.inode = root;
    desc.offset = 0;
    desc.flags = vfs.O_RDONLY;

    var dir_entry: vfs.DirEntry = undefined;
    while (root.ops.readdir.?(desc, &dir_entry)) {
        e2_log.debug("dirent", .{ .ino = dir_entry.ino, .dtype = @as(u64, dir_entry.d_type) });
    }
    vfs.releaseFileDescription(desc);

    testReadFile("/hello.txt");
    testReadFile("/testdir/test2.txt");
}

fn testReadFile(path: []const u8) void {
    const e2_log = klog.scoped(.ext2);

    const inode = vfs.resolve(path) orelse {
        e2_log.debug("not_found", .{});
        return;
    };

    var desc = vfs.allocFileDescription() orelse return;
    desc.inode = inode;
    desc.offset = 0;
    desc.flags = vfs.O_RDONLY;

    var buf: [256]u8 = undefined;
    const n = inode.ops.read.?(desc, &buf, 256);
    if (n > 0) {
        e2_log.debug("read_ok", .{ .bytes = @as(u64, @intCast(n)) });
    }

    vfs.releaseFileDescription(desc);
}

// ---- Boot process helper ----

fn bootProcess(name: []const u8, bytes: usize) void {
    const bp_log = klog.scoped(.proc);
    bp_log.info("loading", .{ .bytes = @as(u64, bytes) });

    // CRITICAL: Disable interrupts to prevent timer tick from picking up
    // the newly created process before startFirst properly switches context.
    // The boot stack is in UEFI memory (not HHDM), so if the scheduler
    // switches CR3 to the process's address space, the boot stack becomes
    // unmapped → double fault. startFirst's iretq re-enables interrupts.
    asm volatile ("cli");

    const proc1 = process.createFromElf(shell_elf_buf[0..bytes]) catch {
        bp_log.fatal("create_failed", .{});
        halt();
    };
    // Store exe_path for /proc/self/exe
    const name_len = if (name.len > 255) 255 else name.len;
    for (0..name_len) |i| {
        proc1.exe_path[i] = name[i];
    }
    proc1.exe_path_len = @truncate(name_len);

    bp_log.info("created_init", .{ .pid = proc1.pid });

    const mem_log = klog.scoped(.mem);
    mem_log.info("pre_sched_free", .{ .pages = pmm.getFreePages() });

    // Flush all klog entries before entering scheduler (noreturn)
    klog.flush();

    scheduler.startFirst(proc1);
}

// ---- Memory initialization ----

fn initMemory() void {
    const mm_log = klog.scoped(.mem);

    // HHDM
    const hhdm_resp = readVolatilePtr(limine.HhdmResponse, &hhdm_request.response);
    if (hhdm_resp) |resp| {
        hhdm.init(resp.offset);
    } else {
        mm_log.fatal("no_hhdm", .{});
        halt();
    }

    // Physical memory manager
    const memmap_resp = readVolatilePtr(limine.MemmapResponse, &memmap_request.response);
    if (memmap_resp) |resp| {
        pmm.init(resp);
    } else {
        mm_log.fatal("no_memmap", .{});
        halt();
    }

    // Self-test: alloc, write, verify, free
    if (pmm.allocPage()) |page| {
        const ptr: *volatile u64 = @ptrFromInt(hhdm.physToVirt(page));
        ptr.* = 0xDEAD_BEEF_CAFE_BABE;
        if (ptr.* == 0xDEAD_BEEF_CAFE_BABE) {
            mm_log.info("pmm_selftest_ok", .{});
        } else {
            mm_log.err("pmm_selftest_write", .{});
        }
        pmm.freePage(page);
    } else {
        mm_log.err("pmm_selftest_alloc", .{});
    }

    // Contiguous allocation test
    if (pmm.allocPages(16)) |pages| {
        mm_log.info("contig_test_ok", .{ .addr = pages });
        pmm.freePages(pages, 16);
    } else {
        mm_log.err("contig_test_fail", .{});
    }

    mm_log.info("pmm_free", .{ .pages = pmm.getFreePages() });

    // Milestone 4: virtual memory manager
    vmm.init();
    testVMM();
}

/// Initialize memory subsystem from UEFI BootInfo.
/// Uses the simplified memory map entries from the UEFI bootloader.
fn initMemoryFromBootInfo(info: *const boot_info_mod.BootInfo) void {
    const mm_log = klog.scoped(.mem);

    // HHDM: use the offset provided by the bootloader's page tables
    hhdm.init(info.hhdm_offset);

    // Parse ACPI tables if bootloader provided RSDP
    if (info.acpi_rsdp != 0) {
        acpi_io.init(&hhdm.physToVirt, &serial.writeString);
        if (acpi_parser.init(info.acpi_rsdp)) {
            const acpi_log = klog.scoped(.acpi);
            acpi_log.info("tables_parsed", .{});
        }
    }

    // PMM: initialize from BootInfo memory map entries
    const entries: [*]const boot_info_mod.BootMemEntry = @ptrFromInt(info.mmap_addr);
    pmm.initFromBootEntries(
        entries,
        info.mmap_count,
        info.kernel_phys_base,
        info.kernel_phys_end,
    );

    // Self-test
    if (pmm.allocPage()) |page| {
        const ptr: *volatile u64 = @ptrFromInt(hhdm.physToVirt(page));
        ptr.* = 0xDEAD_BEEF_CAFE_BABE;
        if (ptr.* == 0xDEAD_BEEF_CAFE_BABE) {
            mm_log.info("pmm_selftest_ok", .{});
        } else {
            mm_log.err("pmm_selftest_write", .{});
        }
        pmm.freePage(page);
    } else {
        mm_log.err("pmm_selftest_alloc", .{});
    }

    // VMM
    vmm.init();

    // Recovery registry — register PMM failure modes
    pmm.initRecovery();
}

fn testVMM() void {
    const vmm_log = klog.scoped(.vmm);
    const pml4 = vmm.getKernelPML4();

    // Test 1: translate a known HHDM address
    const test_phys: u64 = 0x100000;
    const test_virt = hhdm.physToVirt(test_phys);
    if (vmm.translate(pml4, test_virt)) |resolved| {
        if (resolved == test_phys) {
            vmm_log.info("translate_ok", .{ .phys = test_phys });
        } else {
            vmm_log.err("translate_wrong", .{ .expected = test_phys, .got = resolved });
        }
    } else {
        vmm_log.err("translate_unmapped", .{ .virt = test_virt });
    }

    // Test 2: map a new virtual page, write through it, verify via physical
    const test_vaddr: u64 = 0xFFFF_DEAD_0000_0000;
    const phys_page = pmm.allocPage() orelse {
        vmm_log.err("map_test_nopage", .{});
        return;
    };

    vmm.mapPage(pml4, test_vaddr, phys_page, .{ .writable = true }) catch {
        vmm_log.err("map_failed", .{ .vaddr = test_vaddr });
        pmm.freePage(phys_page);
        return;
    };

    const vptr: *volatile u64 = @ptrFromInt(test_vaddr);
    vptr.* = 0xCAFE_BABE_1234_5678;
    const pptr: *volatile u64 = @ptrFromInt(hhdm.physToVirt(phys_page));
    if (pptr.* == 0xCAFE_BABE_1234_5678) {
        vmm_log.info("map_test_ok", .{});
    } else {
        vmm_log.err("map_test_mismatch", .{});
    }

    // Test 3: unmap and verify
    vmm.unmapPage(pml4, test_vaddr);
    if (vmm.translate(pml4, test_vaddr) == null) {
        vmm_log.info("unmap_ok", .{});
    } else {
        vmm_log.err("unmap_failed", .{});
    }
    pmm.freePage(phys_page);

    // Test 4: create a new address space
    if (vmm.createAddressSpace()) |new_pml4| {
        if (vmm.translate(new_pml4, test_virt)) |resolved| {
            if (resolved == test_phys) {
                vmm_log.info("addrspace_ok", .{});
            } else {
                vmm_log.err("addrspace_wrong", .{});
            }
        } else {
            vmm_log.err("addrspace_unmapped", .{});
        }
        vmm.destroyAddressSpace(new_pml4);
    } else |_| {
        vmm_log.err("addrspace_create", .{});
    }

    vmm_log.info("vmm_free", .{ .pages = pmm.getFreePages() });
}

/// Read a Limine response pointer with volatile semantics
/// (the bootloader writes these before we run).
fn readVolatilePtr(comptime T: type, field: *?*T) ?*T {
    const ptr: *const volatile ?*T = @ptrCast(field);
    return ptr.*;
}

// ---- SSE enablement ----

fn enableSSE() void {
    earlySerialStr("[kernel] enableSSE: CR0\r\n");

    // CR0: clear EM (bit 2), set MP (bit 1)
    var cr0 = asm volatile ("movq %%cr0, %[cr0]"
        : [cr0] "=r" (-> u64),
    );
    cr0 &= ~@as(u64, (1 << 2) | (1 << 3)); // Clear EM (bit 2) + TS (bit 3)
    cr0 |= (1 << 1); // Set MP
    asm volatile ("movq %[cr0], %%cr0"
        :
        : [cr0] "r" (cr0),
    );

    earlySerialStr("[kernel] enableSSE: CPUID leaf 1\r\n");

    // CPUID leaf 1: check XSAVE support (ECX bit 26) and AVX (ECX bit 28)
    var cpuid1_ecx: u32 = undefined;
    var cpuid1_eax: u32 = undefined;
    var cpuid1_ebx: u32 = undefined;
    var cpuid1_edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (cpuid1_eax),
          [_] "={ebx}" (cpuid1_ebx),
          [_] "={ecx}" (cpuid1_ecx),
          [_] "={edx}" (cpuid1_edx),
        : [_] "{eax}" (@as(u32, 1)),
    );
    const has_xsave = (cpuid1_ecx & (1 << 26)) != 0;
    const has_avx = (cpuid1_ecx & (1 << 28)) != 0;

    earlySerialStr("[kernel] enableSSE: CR4\r\n");

    // CR4: set OSFXSR (bit 9) + OSXMMEXCPT (bit 10)
    // Only set OSXSAVE (bit 18) if CPU supports XSAVE
    var cr4 = asm volatile ("movq %%cr4, %[cr4]"
        : [cr4] "=r" (-> u64),
    );
    cr4 |= (1 << 9) | (1 << 10); // OSFXSR + OSXMMEXCPT (always safe)
    cr4 &= ~@as(u64, 1 << 16); // Clear FSGSBASE — force arch_prctl for TLS
    if (has_xsave) {
        cr4 |= (1 << 18); // OSXSAVE — only if CPU supports it
    }

    // CPUID leaf 7: probe SMEP (EBX.7) and SMAP (EBX.20)
    var cpuid_ebx: u32 = undefined;
    var cpuid_eax_out: u32 = undefined;
    var cpuid_ecx_out: u32 = undefined;
    var cpuid_edx_out: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (cpuid_eax_out),
          [_] "={ebx}" (cpuid_ebx),
          [_] "={ecx}" (cpuid_ecx_out),
          [_] "={edx}" (cpuid_edx_out),
        : [_] "{eax}" (@as(u32, 7)),
          [_] "{ecx}" (@as(u32, 0)),
    );
    const has_smep = (cpuid_ebx & (1 << 7)) != 0;
    const has_smap = (cpuid_ebx & (1 << 20)) != 0;
    // SMEP/SMAP disabled for now — debugging userspace entry triple fault on GCE
    _ = has_smep;
    _ = has_smap;

    asm volatile ("movq %[cr4], %%cr4"
        :
        : [cr4] "r" (cr4),
    );

    earlySerialStr("[kernel] enableSSE: CR4 loaded\r\n");

    // XCR0: enable x87 (bit 0) + SSE (bit 1), and AVX (bit 2) only if supported
    if (has_xsave) {
        const xcr0_val: u32 = if (has_avx) 7 else 3; // x87+SSE+AVX or x87+SSE
        earlySerialStr("[kernel] enableSSE: xsetbv\r\n");
        asm volatile ("xsetbv"
            :
            : [_] "{ecx}" (@as(u32, 0)),
              [_] "{eax}" (xcr0_val),
              [_] "{edx}" (@as(u32, 0)),
        );
    }

    earlySerialStr("[kernel] enableSSE: done\r\n");
}

// ---- Output helpers ----

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        serial.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    serial.writeString(buf[i..]);
}

// ---- Early serial output (raw COM1, no dependencies) ----

fn earlySerialStr(s: []const u8) void {
    for (s) |c| {
        // Wait for transmit buffer empty (LSR bit 5)
        while (asm volatile ("inb %[port], %[val]"
            : [val] "={al}" (-> u8),
            : [port] "N{dx}" (@as(u16, 0x3FD)),
        ) & 0x20 == 0) {
            asm volatile ("pause");
        }
        // Write byte
        asm volatile ("outb %[val], %[port]"
            :
            : [val] "{al}" (c),
              [port] "N{dx}" (@as(u16, 0x3F8)),
        );
    }
}

// ---- klog tick source ----

fn getTickCount() u64 {
    return idt.getTickCount();
}

// ---- Halt ----

pub fn halt() noreturn {
    earlySerialStr("\r\n[kernel] HALT — system stopped\r\n");
    // Use sti+hlt to allow timer ticks (klog drain) while halted.
    // The CPU wakes on each IRQ, executes the handler, then re-halts.
    while (true) {
        asm volatile ("sti\nhlt" ::: .{ .memory = true });
    }
}

// ---- Panic handler (required for freestanding) ----

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // Dump klog ring buffer for post-mortem analysis
    klog.panicDump(64);

    serial.writeString("\n!!! KERNEL PANIC !!!\n");
    serial.writeString(msg);
    serial.writeString("\n");

    // Print return address to identify crash location (use with llvm-nm)
    if (ret_addr) |addr| {
        serial.writeString("  return address: 0x");
        const hex = "0123456789abcdef";
        var buf: [16]u8 = undefined;
        var v: u64 = addr;
        var i: usize = 16;
        while (i > 0) {
            i -= 1;
            buf[i] = hex[@as(usize, @truncate(v & 0xf))];
            v >>= 4;
        }
        serial.writeString(&buf);
        serial.writeString("\n");
    }

    // Also print RBP for manual stack walk
    const rbp = asm volatile ("movq %%rbp, %[rbp]"
        : [rbp] "=r" (-> u64),
    );
    serial.writeString("  RBP: 0x");
    {
        const hex2 = "0123456789abcdef";
        var buf2: [16]u8 = undefined;
        var v2: u64 = rbp;
        var j: usize = 16;
        while (j > 0) {
            j -= 1;
            buf2[j] = hex2[@as(usize, @truncate(v2 & 0xf))];
            v2 >>= 4;
        }
        serial.writeString(&buf2);
    }
    serial.writeString("\n");

    halt();
}
