/// RISC-V 64-bit Boot Entry
///
/// QEMU virt machine with OpenSBI:
/// - OpenSBI runs in M-mode, provides SBI services
/// - Kernel enters in S-mode at 0x80200000
/// - a0 = hart ID, a1 = DTB pointer

const std = @import("std");
const uart = @import("uart.zig");
const trap = @import("trap.zig");
const plic = @import("plic.zig");
const timer_mod = @import("timer.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const smp = @import("smp.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const vfs = @import("vfs.zig");
const ramfs = @import("ramfs.zig");
const slab = @import("slab.zig");
const virtio_blk = @import("virtio_blk.zig");
const block_io = @import("block_io.zig");
const ext2 = @import("ext2.zig");

extern const __bss_start: u8;
extern const __bss_end: u8;
extern const __stack_top: u8;

export fn kmain(hart_id: u64, dtb_ptr: u64) noreturn {
    uart.init();

    uart.writeString("\n");
    uart.writeString("========================================\n");
    uart.writeString("  Zigix OS\n");
    uart.writeString("  RISC-V 64-bit bare-metal OS\n");
    uart.writeString("  Written in Zig by Quantum Encoding Ltd\n");
    uart.writeString("  info@quantumencoding.io\n");
    uart.writeString("========================================\n");
    uart.writeString("\n");

    uart.print("[boot] Hart ID: {}\n", .{hart_id});
    uart.print("[boot] DTB at: {x}\n", .{dtb_ptr});

    // Install trap vector
    trap.init();
    uart.writeString("[boot] Trap vector installed\n");

    // Initialize SMP (single hart for now)
    smp.initBsp();

    // Initialize PLIC
    plic.init();
    plic.enable(plic.IRQ_UART0);
    plic.setPriority(plic.IRQ_UART0, 1);

    // Initialize timer
    timer_mod.init();

    // Enable S-mode interrupts (timer + external + software)
    const sie = readCsr("sie");
    writeCsr("sie", sie | (1 << 5) | (1 << 9) | (1 << 1));

    // Enable global S-mode interrupts + SUM (user memory access from S-mode)
    const sstatus = readCsr("sstatus");
    writeCsr("sstatus", sstatus | (1 << 1) | (1 << 18));

    // Initialize PMM
    pmm.init();

    // Initialize slab allocator
    slab.init();

    // Initialize VMM (Sv39 identity mapping)
    // NOTE: Sv39 paging is enabled by vmm.init(). If this causes a boot loop,
    // the identity mapping needs debugging.
    vmm.init() catch {
        uart.writeString("[boot] ERROR: VMM init failed\n");
    };
    uart.writeString("[boot] VMM initialized\n");

    // Initialize process table
    uart.writeString("[boot] Initializing process table...\n");
    process.initProcessTable();
    uart.writeString("[boot] Process table initialized\n");

    // Initialize VFS with ramfs root
    uart.writeString("[boot] Calling ramfs.init()...\n");
    const root_inode = ramfs.init();
    uart.writeString("[boot] ramfs initialized\n");
    if (vfs.mount("/", root_inode)) {
        uart.writeString("[boot] VFS: mounted ramfs at /\n");
    }

    // Create directory structure
    if (vfs.resolve("/")) |root| {
        if (root.ops.create) |create_fn| {
            _ = create_fn(root, "tmp", vfs.S_IFDIR | 0o1777);
            _ = create_fn(root, "dev", vfs.S_IFDIR | 0o755);
            _ = create_fn(root, "bin", vfs.S_IFDIR | 0o755);
            uart.writeString("[boot] VFS: created /tmp /dev /bin\n");
        }
    }

    // VMM tests
    vmmTest();

    // --- Block device: virtio-blk ---
    // Disable interrupts during block device init — timer IRQ during MMIO
    // register setup can corrupt the virtio negotiation sequence.
    writeCsr("sstatus", readCsr("sstatus") & ~@as(u64, 1 << 1)); // Clear SIE
    uart.writeString("[boot] Probing virtio-blk...\n");
    const have_disk = virtio_blk.init();
    if (have_disk) {
        block_io.init(&virtio_blk.readSectors, &virtio_blk.writeSectors, &uart.writeString);
        uart.writeString("[boot] Block device: virtio-blk\n");
        if (ext2.init()) {
            if (ext2.getRootInode()) |ext2_root| {
                vfs.replaceRoot(ext2_root);
                uart.writeString("[boot] ext2 mounted as root /\n");
            }
        }
    } else {
        uart.writeString("[boot] No block device (ramfs only)\n");
    }

    // Enable interrupts
    writeCsr("sstatus", readCsr("sstatus") | (1 << 1));

    uart.writeString("\n[boot] Zigix RISC-V kernel booted successfully!\n");
    uart.print("[boot] Free pages: {} ({} MB)\n", .{
        pmm.getFreePages(), pmm.getFreePages() * 4096 / 1024 / 1024,
    });

    // Try to load shell from disk first, fall back to embedded hello
    uart.writeString("[boot] Creating first userspace process...\n");
    const proc = loadShellFromDisk() orelse blk: {
        uart.writeString("[boot] No shell found on disk, using embedded hello\n");
        break :blk process.createFromCode(&user_hello_code) catch {
            uart.writeString("[boot] FATAL: createFromCode failed\n");
            while (true) asm volatile ("wfi");
        };
    };

    uart.print("[boot] Starting PID {} at {x}\n", .{ proc.pid, proc.context.sepc });
    scheduler.startFirst(proc);
}

/// Try to load /bin/zsh-riscv64 ELF from the ext2 disk.
/// Returns null if file not found or load fails.
fn loadShellFromDisk() ?*process.Process {
    // Allocate 16 pages (64 KiB) from PMM for ELF read buffer
    const BUF_PAGES = 16;
    const buf_phys = pmm.allocPages(BUF_PAGES) orelse {
        uart.writeString("[boot] Cannot allocate ELF buffer\n");
        return null;
    };
    const buf_ptr: [*]u8 = @ptrFromInt(buf_phys);
    const buf = buf_ptr[0 .. BUF_PAGES * 4096];

    const paths = [_][]const u8{ "/bin/zsh-riscv64", "/bin/zsh", "/bin/init" };
    for (paths) |path| {
        if (vfs.readWholeFile(path, buf)) |bytes_read| {
            if (bytes_read < 64) continue;
            uart.writeString("[boot] Loaded ");
            uart.writeString(path);
            uart.print(" ({} bytes)\n", .{bytes_read});
            const p = process.createFromElfData(buf[0..bytes_read]) catch {
                uart.writeString("[boot] ELF load failed\n");
                continue;
            };
            // Free the buffer — ELF data has been copied into process pages
            pmm.freePages(buf_phys, BUF_PAGES);
            return p;
        }
    }
    pmm.freePages(buf_phys, BUF_PAGES);
    return null;
}

fn vmmTest() void {
    if (vmm.translate(vmm.getKernelRoot(), 0x80200000)) |phys| {
        if (phys == 0x80200000) {
            uart.writeString("[vmm-test] identity mapping PASS\n");
        } else {
            uart.writeString("[vmm-test] identity mapping FAIL\n");
        }
    } else {
        uart.writeString("[vmm-test] identity mapping FAIL (null)\n");
    }
}

/// Embedded RISC-V userspace program:
///   write(1, "Hello from RISC-V userspace!\n", 29)
///   exit(0)
const user_hello_code = [_]u8{
    // li a7, 64 (SYS_write)
    0x93, 0x08, 0x00, 0x04,
    // li a0, 1 (fd=stdout)
    0x13, 0x05, 0x10, 0x00,
    // auipc a1, 0
    0x97, 0x05, 0x00, 0x00,
    // addi a1, a1, 28 (offset to string)
    0x93, 0x85, 0xc5, 0x01,
    // li a2, 29 (count)
    0x13, 0x06, 0xd0, 0x01,
    // ecall
    0x73, 0x00, 0x00, 0x00,
    // li a7, 93 (SYS_exit)
    0x93, 0x08, 0xd0, 0x05,
    // li a0, 0 (status=0)
    0x13, 0x05, 0x00, 0x00,
    // ecall
    0x73, 0x00, 0x00, 0x00,
    // "Hello from RISC-V userspace!\n"
    'H', 'e', 'l', 'l', 'o', ' ', 'f', 'r',
    'o', 'm', ' ', 'R', 'I', 'S', 'C', '-',
    'V', ' ', 'u', 's', 'e', 'r', 's', 'p',
    'a', 'c', 'e', '!', '\n', 0, 0, 0,
};

// --- Entry point ---

export fn _start() linksection(".text._start") callconv(.naked) noreturn {
    asm volatile (
        \\li t0, 0x10000000
        \\li t1, 0x5A
        \\sb t1, 0(t0)
        \\bnez a0, .Lpark
        \\la sp, __stack_top
        \\la t0, __bss_start
        \\la t1, __bss_end
        \\.Lclear_bss:
        \\bgeu t0, t1, .Lbss_done
        \\sd zero, 0(t0)
        \\addi t0, t0, 8
        \\j .Lclear_bss
        \\.Lbss_done:
        \\call kmain
        \\.Lpark:
        \\wfi
        \\j .Lpark
    );
}

// --- CSR helpers ---

pub inline fn readCsr(comptime name: []const u8) u64 {
    return asm volatile ("csrr %[ret], " ++ name
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeCsr(comptime name: []const u8, value: u64) void {
    asm volatile ("csrw " ++ name ++ ", %[val]"
        :
        : [val] "r" (value),
    );
}

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    uart.writeString("\n[PANIC] ");
    uart.writeString(msg);
    uart.writeString("\n");
    while (true) asm volatile ("wfi");
}
