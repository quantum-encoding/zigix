const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Architecture selection
    const arch = b.option(
        std.Target.Cpu.Arch,
        "arch",
        "Target architecture (x86_64, aarch64, or riscv64)",
    ) orelse .x86_64;

    // CPU model selection (aarch64 only)
    // Controls compiler instruction selection — runtime feature detection always happens.
    //   generic      — ARMv8.0 baseline, runs everywhere (QEMU cortex-a72, any real hardware)
    //   neoverse_n1  — ARMv8.2 (AWS Graviton2, Ampere Altra)
    //   neoverse_n2  — ARMv9.0 (Google Axion, AWS Graviton3+, Ampere AmpereOne)
    //   neoverse_v2  — ARMv9.0 (Google Axion T2A, high-perf)
    //   cortex_a72   — ARMv8.0 (QEMU default, Raspberry Pi 4)
    const CpuProfile = enum {
        generic,
        cortex_a72,
        neoverse_n1,
        neoverse_n2,
        neoverse_v2,
    };

    const cpu_profile = b.option(
        CpuProfile,
        "cpu",
        "ARM64 CPU target profile (default: generic)",
    ) orelse .generic;

    // Build target query with optional CPU model
    const target_query: std.Target.Query = blk: {
        var q: std.Target.Query = .{
            .cpu_arch = arch,
            .os_tag = .freestanding,
            .abi = .none,
        };

        if (arch == .aarch64) {
            q.cpu_model = switch (cpu_profile) {
                .generic => .baseline,
                .cortex_a72 => .{ .explicit = &std.Target.aarch64.cpu.cortex_a72 },
                .neoverse_n1 => .{ .explicit = &std.Target.aarch64.cpu.neoverse_n1 },
                .neoverse_n2 => .{ .explicit = &std.Target.aarch64.cpu.neoverse_n2 },
                .neoverse_v2 => .{ .explicit = &std.Target.aarch64.cpu.neoverse_v2 },
            };
        }

        break :blk q;
    };

    const target = b.resolveTargetQuery(target_query);

    // Select source file and linker script based on architecture
    const root_source = switch (arch) {
        .x86_64 => b.path("kernel/main.zig"),
        .aarch64 => b.path("kernel/arch/aarch64/boot.zig"),
        .riscv64 => b.path("kernel/arch/riscv64/boot.zig"),
        else => @panic("Unsupported architecture"),
    };

    const linker_script = switch (arch) {
        .x86_64 => b.path("linker.ld"),
        .aarch64 => b.path("linker-aarch64.ld"),
        .riscv64 => b.path("linker-riscv64.ld"),
        else => @panic("Unsupported architecture"),
    };

    const kernel_name = switch (arch) {
        .x86_64 => "zigix",
        .aarch64 => "zigix-aarch64",
        .riscv64 => "zigix-riscv64",
        else => "zigix",
    };

    const module = b.createModule(.{
        .root_source_file = root_source,
        .target = target,
        .optimize = optimize,
        // Architecture-specific code model settings
        .code_model = switch (arch) {
            .x86_64 => .kernel,
            .riscv64 => .medium, // medany — PC-relative addressing for high addresses
            else => .default,
        },
        .red_zone = if (arch == .x86_64) false else null,
        .pic = if (arch == .x86_64) true else null,
    });

    // For aarch64: add ext3 journal module as a named import since it lives
    // outside the aarch64 module root (kernel/arch/aarch64/)
    if (arch == .aarch64) {
        const ext3_mod = b.createModule(.{
            .root_source_file = b.path("kernel/fs/ext3/ext3.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("ext3", ext3_mod);

        const ext4_mod = b.createModule(.{
            .root_source_file = b.path("kernel/fs/ext4_module.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("ext4", ext4_mod);

        const acpi_mod = b.createModule(.{
            .root_source_file = b.path("kernel/acpi/acpi.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("acpi", acpi_mod);

        const klog_mod = b.createModule(.{
            .root_source_file = b.path("kernel/klog/klog.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("klog", klog_mod);

        const safety_mod = b.createModule(.{
            .root_source_file = b.path("kernel/safety/addr.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("addr", safety_mod);
    }

    // Load address override (aarch64 only)
    // Default: 0x40080000 (QEMU virt). Override for bare metal:
    //   -Dload_addr=0x80000       — Raspberry Pi 4/5
    //   -Dload_addr=0x40000000    — U-Boot standard
    const load_addr_str = b.option(
        []const u8,
        "load_addr",
        "ARM64 kernel load address as hex string, e.g. '0x80000' (default: 0x40080000)",
    );
    const load_addr: ?u64 = if (load_addr_str) |s| blk: {
        // Strip "0x" or "0X" prefix if present
        const hex = if (s.len > 2 and (s[0] == '0') and (s[1] == 'x' or s[1] == 'X'))
            s[2..]
        else
            s;
        break :blk std.fmt.parseInt(u64, hex, 16) catch @panic("Invalid load_addr hex value");
    } else null;

    const kernel = b.addExecutable(.{
        .name = kernel_name,
        .root_module = module,
        .use_lld = true,
        .use_llvm = true,
    });

    kernel.setLinkerScript(linker_script);

    // Generate linker script with custom load address if specified
    if (arch == .aarch64) {
        if (load_addr) |addr| {
            const ld_content = std.fmt.allocPrint(b.allocator,
                \\/* Generated linker script for load_addr=0x{x} */
                \\ENTRY(_start)
                \\PROVIDE(__load_addr = 0x{x});
                \\SECTIONS
                \\{{
                \\    . = __load_addr;
                \\    .text : {{ *(.text._start) *(.text .text.*) }}
                \\    .rodata : ALIGN(4K) {{ *(.rodata .rodata.*) }}
                \\    .data : ALIGN(4K) {{ *(.data .data.*) }}
                \\    .bss : ALIGN(4K) {{ __bss_start = .; *(.bss .bss.*) *(COMMON) __bss_end = .; }}
                \\    . = ALIGN(16);
                \\    . += 64K;
                \\    __stack_top = .;
                \\    /DISCARD/ : {{ *(.comment) *(.note*) *(.eh_frame*) }}
                \\}}
            , .{ addr, addr }) catch @panic("OOM");
            const wf = b.addWriteFiles();
            const custom_ld = wf.add("linker-aarch64-custom.ld", ld_content);
            kernel.setLinkerScript(custom_ld);
        }
    }

    b.installArtifact(kernel);

    // Convenience steps
    const run_step = b.step("run", "Build and run in QEMU");

    if (arch == .x86_64) {
        // x86_64: Use existing run.sh
        const run_cmd = b.addSystemCommand(&.{"./run.sh"});
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);
    } else if (arch == .aarch64) {
        // aarch64: QEMU CPU matches build profile
        const qemu_cpu = switch (cpu_profile) {
            .generic => "cortex-a72",
            .cortex_a72 => "cortex-a72",
            .neoverse_n1 => "neoverse-n1",
            .neoverse_n2 => "neoverse-n2",
            .neoverse_v2 => "max",    // QEMU may not have neoverse-v2, use max
        };

        const run_cmd = b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-M",     "virt,gic-version=max",
            "-cpu",   qemu_cpu,
            "-m",     "256M",
            "-kernel", "zig-out/bin/zigix-aarch64",
            "-serial", "stdio",
            "-display", "none",
            "-no-reboot",
        });
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);
    }
}
