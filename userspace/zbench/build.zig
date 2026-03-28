const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const exe = b.addExecutable(.{
        .name = "zbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
        .use_lld = true,
        .use_llvm = true,
    });

    exe.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(exe);
}
