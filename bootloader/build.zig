const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .uefi,
        .abi = .none,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bootloader = b.addExecutable(.{
        .name = "BOOTAA64",
        .root_module = module,
        .use_lld = true,
        .use_llvm = true,
    });

    b.installArtifact(bootloader);
}
