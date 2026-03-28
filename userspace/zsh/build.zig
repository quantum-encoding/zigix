const std = @import("std");

pub fn build(b: *std.Build) void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "Target architecture") orelse .x86_64;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const exe = b.addExecutable(.{
        .name = if (arch == .aarch64) "zsh-aarch64" else if (arch == .riscv64) "zsh-riscv64" else "zsh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "sys", .module = b.createModule(.{
                    .root_source_file = b.path("../lib/sys.zig"),
                    .target = target,
                    .optimize = .ReleaseSmall,
                }) },
            },
        }),
        .use_lld = true,
        .use_llvm = true,
    });

    if (arch == .riscv64) {
        exe.setLinkerScript(b.path("../lib/linker-riscv64.ld"));
    } else if (arch == .aarch64) {
        exe.setLinkerScript(b.path("../lib/linker-aarch64.ld"));
    } else {
        exe.setLinkerScript(b.path("linker.ld"));
    }

    b.installArtifact(exe);
}
