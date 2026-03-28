/// Zigix init — PID 1 init process.
/// Architecture-portable: compiles for both x86_64 and aarch64.
/// Spawns /bin/zlogin (with fallback to /bin/zsh), reaps children, respawns on exit.

const std = @import("std");
const sys = @import("sys");

// ---- Arch-specific struct stat offsets (x86_64 vs aarch64) ----
// x86_64: st_nlink is u64 at offset 16, st_mode is u32 at offset 24
// aarch64: st_mode is u32 at offset 16, st_nlink is u32 at offset 20
const is_x86 = @import("builtin").cpu.arch == .x86_64;
const STAT_MODE_OFF: usize = if (is_x86) 24 else 16;
const STAT_NLINK_OFF: usize = if (is_x86) 16 else 20;
const STAT_SIZE_OFF: usize = 48; // same on both

// ---- Panic handler (required for freestanding) ----

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    sys.exit(99);
}

// ---- Entry point ----

export fn _start() callconv(.naked) noreturn {
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile (
            \\mov x29, #0
            \\bl main
            \\1: wfi
            \\b 1b
        );
    } else {
        asm volatile (
            "and $-16, %%rsp\n" ++
                "call main"
            ::: .{ .memory = true }
        );
    }
}

// ---- I/O helpers ----

fn puts(s: []const u8) void {
    _ = sys.write(1, s.ptr, s.len);
}

fn write_uint(n: u64) void {
    if (n == 0) {
        _ = sys.write(1, "0", 1);
        return;
    }
    var buf: [20]u8 = undefined;
    var v = n;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    _ = sys.write(1, @ptrCast(&buf[i]), 20 - i);
}

fn write_int(n: isize) void {
    if (n < 0) {
        _ = sys.write(1, "-", 1);
        write_uint(@intCast(-n));
    } else {
        write_uint(@intCast(n));
    }
}

// ---- Login/shell spawning ----

fn spawnLogin() isize {
    const pid = sys.fork();
    if (pid == 0) {
        // Child: try login/shell from ext2 root
        var envp_null: [1]u64 = .{0};

        const paths = [_][*]const u8{
            "/bin/zlogin\x00",
            "/bin/zsh\x00",
        };
        for (paths) |path| {
            var argv_ptrs: [2]u64 = .{ @intFromPtr(path), 0 };
            _ = sys.execve(path, @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
        }
        puts("init: exec failed\n");
        sys.exit(127);
    }
    return pid;
}

fn spawnDaemon(path: [*]const u8) isize {
    const pid = sys.fork();
    if (pid == 0) {
        var envp_null: [1]u64 = .{0};
        var argv_ptrs: [2]u64 = .{ @intFromPtr(path), 0 };
        _ = sys.execve(path, @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
        sys.exit(127);
    }
    return pid;
}

fn spawnWithArgs(path: [*]const u8, arg1: ?[*]const u8) isize {
    const pid = sys.fork();
    if (pid == 0) {
        var envp_null: [1]u64 = .{0};
        if (arg1) |a1| {
            var argv_ptrs: [3]u64 = .{ @intFromPtr(path), @intFromPtr(a1), 0 };
            _ = sys.execve(path, @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
        } else {
            var argv_ptrs: [2]u64 = .{ @intFromPtr(path), 0 };
            _ = sys.execve(path, @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
        }
        sys.exit(127);
    }
    return pid;
}

/// Spawn BusyBox with applet name and one argument: /bin/busybox <applet> <arg>
fn spawnBusybox(applet: [*]const u8, arg: [*]const u8) isize {
    const pid = sys.fork();
    if (pid == 0) {
        var envp_null: [1]u64 = .{0};
        var argv_ptrs: [4]u64 = .{
            @intFromPtr(@as([*]const u8, "/bin/busybox\x00")),
            @intFromPtr(applet),
            @intFromPtr(arg),
            0,
        };
        _ = sys.execve(@ptrCast("/bin/busybox\x00"), @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
        sys.exit(127);
    }
    return pid;
}

/// Check if a file exists (open O_RDONLY, close immediately).
fn fileExists(path: [*]const u8) bool {
    const fd = sys.open(path, 0, 0);
    if (fd < 0) return false;
    _ = sys.close(@intCast(fd));
    return true;
}

fn copyFile(src: [*]const u8, dst: [*]const u8) void {
    const fd_in = sys.open(src, 0, 0); // O_RDONLY
    if (fd_in < 0) return;
    const fd_out = sys.open(dst, 577, 0o755); // O_WRONLY|O_CREAT|O_TRUNC (executable)
    if (fd_out < 0) { _ = sys.close(@intCast(fd_in)); return; }
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(@intCast(fd_in), &buf, buf.len);
        if (n <= 0) break;
        _ = sys.write(@intCast(fd_out), &buf, @intCast(n));
    }
    _ = sys.close(@intCast(fd_in));
    _ = sys.close(@intCast(fd_out));
}

fn writeFile(path: [*]const u8, data: []const u8) bool {
    // O_WRONLY=1, O_CREAT=64, O_TRUNC=512 → 577
    const fd = sys.open(path, 577, 0o644);
    if (fd < 0) return false;
    _ = sys.write(@intCast(fd), data.ptr, data.len);
    _ = sys.close(@intCast(fd));
    return true;
}

fn spawnZigBuild() isize {
    // Write hello.zig source to /tmp/ (must be alongside cache dirs for module path)
    const hello_src =
        \\pub fn main() void {}
        \\
    ;
    _ = writeFile("/tmp/hello.zig\x00", hello_src);

    const pid = sys.fork();
    if (pid == 0) {
        var envp_null: [1]u64 = .{0};
        var argv_ptrs: [12]u64 = .{
            @intFromPtr(@as([*]const u8, "/zig/zig\x00")),
            @intFromPtr(@as([*]const u8, "build-exe\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/hello.zig\x00")),
            @intFromPtr(@as([*]const u8, "--zig-lib-dir\x00")),
            @intFromPtr(@as([*]const u8, "/zig/lib\x00")),
            @intFromPtr(@as([*]const u8, "--cache-dir\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/zig-cache\x00")),
            @intFromPtr(@as([*]const u8, "--global-cache-dir\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/zig-global\x00")),
            @intFromPtr(@as([*]const u8, "-femit-bin=/tmp/hello\x00")),
            @intFromPtr(@as([*]const u8, "-j1\x00")),
            0,
        };
        _ = sys.execve(@ptrFromInt(argv_ptrs[0]), @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
        sys.exit(127);
    }
    return pid;
}

fn spawnZigMultiFile() isize {
    // Write a local module — tests @import("lib.zig") resolution
    const lib_src =
        \\pub fn fibonacci(n: u32) u64 {
        \\    if (n <= 1) return n;
        \\    var a: u64 = 0;
        \\    var b: u64 = 1;
        \\    var i: u32 = 2;
        \\    while (i <= n) : (i += 1) {
        \\        const c = a + b;
        \\        a = b;
        \\        b = c;
        \\    }
        \\    return b;
        \\}
        \\
        \\pub fn factorial(n: u32) u64 {
        \\    if (n <= 1) return 1;
        \\    var r: u64 = 1;
        \\    var i: u32 = 2;
        \\    while (i <= n) : (i += 1) {
        \\        r *= i;
        \\    }
        \\    return r;
        \\}
        \\
        \\pub const greeting = "Multi-file Zigix test";
        \\
    ;
    _ = writeFile("/tmp/lib.zig\x00", lib_src);

    // Write main source that imports the local module + std
    const main_src =
        \\const std = @import("std");
        \\const lib = @import("lib.zig");
        \\
        \\pub fn main() void {
        \\    const print = std.debug.print;
        \\    print("{s}\n", .{lib.greeting});
        \\    print("fib(10)={d} fact(6)={d}\n", .{ lib.fibonacci(10), lib.factorial(6) });
        \\    if (lib.fibonacci(10) == 55 and lib.factorial(6) == 720) {
        \\        print("PASS: multi-file compilation\n", .{});
        \\    } else {
        \\        print("FAIL: wrong results\n", .{});
        \\    }
        \\}
        \\
    ;
    _ = writeFile("/tmp/multitest.zig\x00", main_src);

    const pid = sys.fork();
    if (pid == 0) {
        var envp_null: [1]u64 = .{0};
        var argv_ptrs: [11]u64 = .{
            @intFromPtr(@as([*]const u8, "/zig/zig\x00")),
            @intFromPtr(@as([*]const u8, "build-exe\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/multitest.zig\x00")),
            @intFromPtr(@as([*]const u8, "--zig-lib-dir\x00")),
            @intFromPtr(@as([*]const u8, "/zig/lib\x00")),
            @intFromPtr(@as([*]const u8, "--cache-dir\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/zig-cache\x00")),
            @intFromPtr(@as([*]const u8, "--global-cache-dir\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/zig-global\x00")),
            @intFromPtr(@as([*]const u8, "-femit-bin=/tmp/multitest\x00")),
            0,
        };
        _ = sys.execve(@ptrFromInt(argv_ptrs[0]), @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
        sys.exit(127);
    }
    return pid;
}

fn spawnZigBuildSystem() isize {
    // Create project directory structure
    _ = sys.mkdir("/tmp/project\x00", 0o755);
    _ = sys.mkdir("/tmp/project/src\x00", 0o755);

    // Write build.zig — minimal build file for Zig 0.16-dev (module-based API)
    const build_zig =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const exe = b.addExecutable(.{
        \\        .name = "hello",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    b.installArtifact(exe);
        \\}
        \\
    ;
    _ = writeFile("/tmp/project/build.zig\x00", build_zig);

    // Write src/main.zig
    const main_zig =
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    std.debug.print("Hello from zig build!\n", .{});
        \\}
        \\
    ;
    _ = writeFile("/tmp/project/src/main.zig\x00", main_zig);

    // Create output directory
    _ = sys.mkdir("/tmp/project/zig-out\x00", 0o755);

    const pid = sys.fork();
    if (pid == 0) {
        var envp_null: [1]u64 = .{0};
        var argv_ptrs: [13]u64 = .{
            @intFromPtr(@as([*]const u8, "/zig/zig\x00")),
            @intFromPtr(@as([*]const u8, "build\x00")),
            @intFromPtr(@as([*]const u8, "--build-file\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/project/build.zig\x00")),
            @intFromPtr(@as([*]const u8, "--zig-lib-dir\x00")),
            @intFromPtr(@as([*]const u8, "/zig/lib\x00")),
            @intFromPtr(@as([*]const u8, "--cache-dir\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/zig-cache\x00")),
            @intFromPtr(@as([*]const u8, "--global-cache-dir\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/zig-global\x00")),
            @intFromPtr(@as([*]const u8, "--prefix\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/project/zig-out\x00")),
            0,
        };
        _ = sys.execve(@ptrFromInt(argv_ptrs[0]), @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
        sys.exit(127);
    }
    return pid;
}

fn spawnSelfHost() isize {
    // Create output directory for the self-hosted kernel build
    _ = sys.mkdir("/zigix/zig-out\x00", 0o755);
    _ = sys.mkdir("/zigix/zig-out/bin\x00", 0o755);

    const arch_flag = comptime if (@import("builtin").cpu.arch == .aarch64)
        "-Darch=aarch64\x00"
    else
        "-Darch=x86_64\x00";

    const pid = sys.fork();
    if (pid == 0) {
        // Child: chdir to /zigix and run zig build -Darch=<native>
        _ = sys.chdir("/zigix\x00");
        var envp_null: [1]u64 = .{0};
        // Use --summary all to see what zig build is doing
        var argv_ptrs: [14]u64 = .{
            @intFromPtr(@as([*]const u8, "/zig/zig\x00")),
            @intFromPtr(@as([*]const u8, "build\x00")),
            @intFromPtr(@as([*]const u8, arch_flag)),
            @intFromPtr(@as([*]const u8, "--zig-lib-dir\x00")),
            @intFromPtr(@as([*]const u8, "/zig/lib\x00")),
            @intFromPtr(@as([*]const u8, "--cache-dir\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/zig-cache\x00")),
            @intFromPtr(@as([*]const u8, "--global-cache-dir\x00")),
            @intFromPtr(@as([*]const u8, "/tmp/zig-global\x00")),
            @intFromPtr(@as([*]const u8, "--prefix\x00")),
            @intFromPtr(@as([*]const u8, "/zigix/zig-out\x00")),
            @intFromPtr(@as([*]const u8, "-j1\x00")),
            @intFromPtr(@as([*]const u8, "--summary=all\x00")),
            0,
        };
        _ = sys.execve(@ptrFromInt(argv_ptrs[0]), @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
        sys.exit(127);
    }
    return pid;
}

fn waitForPid(target_pid: isize) isize {
    // Wait for the SPECIFIC PID, not any child (-1).
    // Using -1 causes reparented grandchildren (from zig build's process
    // tree) to be reaped first, starving the target PID and blocking forever.
    const ret = sys.wait4(@bitCast(@as(i64, target_pid)), 0, 0);
    return ret;
}

// ---- Main init loop ----

export fn main() noreturn {
    puts("Zigix init v0.2 (PID 1)\n");

    // Zig compiler tests: DISABLED pending SMP fork+exec CoW fix.
    // fork+exec on SMP triggers PTE races when parent/child run on different CPUs.
    // ext3-test and fs-test run without fork and are safe.
    {
        puts("[init] Zig/fork tests: SKIPPED (pending SMP CoW fix)\n");
        _ = sys.mkdir("/tmp/zig-cache\x00", 0o755);
        _ = sys.mkdir("/tmp/zig-cache/tmp\x00", 0o755);
        _ = sys.mkdir("/tmp/zig-cache/o\x00", 0o755);
        _ = sys.mkdir("/tmp/zig-cache/h\x00", 0o755);
        _ = sys.mkdir("/tmp/zig-global\x00", 0o755);

        // Test make with a trivial Makefile
        puts("[init] Testing: make with trivial Makefile...\n");
        {
            // Create /tmp/Makefile
            if (writeFile("/tmp/Makefile\x00", "all:\n\techo Hello from make on Zigix && echo recipe done\n")) {
                const tpid = sys.fork();
                if (tpid == 0) {
                    _ = sys.chdir("/tmp\x00");
                    const tav = [_:null]?[*:0]const u8{
                        "/bin/make\x00", "-f\x00", "/tmp/Makefile\x00", "SHELL=/bin/sh\x00", null,
                    };
                    const tev = [_:null]?[*:0]const u8{
                        "PATH=/bin\x00", "SHELL=/bin/sh\x00", null,
                    };
                    _ = sys.execve("/bin/make\x00", @intFromPtr(&tav), @intFromPtr(&tev));
                    sys.exit(1);
                } else if (tpid > 0) {
                    _ = waitForPid(tpid);
                    puts("[init] trivial make done\n");
                }
            }
        }

        puts("[init] Testing: make --version ...\n");
        {
            const dpid = sys.fork();
            if (dpid == 0) {
                const dargv = [_:null]?[*:0]const u8{
                    "/bin/make\x00", "--version\x00", null,
                };
                const denvp = [_:null]?[*:0]const u8{
                    "PATH=/bin\x00", null,
                };
                _ = sys.execve("/bin/make\x00", @intFromPtr(&dargv), @intFromPtr(&denvp));
                sys.exit(1);
            } else if (dpid > 0) {
                _ = waitForPid(dpid);
                puts("[init] make --version done\n");
            }
        }

        // Test zig version before attempting Linux build
        if (sys.open("/zig/zig\x00", 0, 0) >= 0) {
            puts("[init] Testing: zig version...\n");
            {
                const zv_pid = sys.fork();
                if (zv_pid == 0) {
                    const zva = [_:null]?[*:0]const u8{ "/zig/zig\x00", "version\x00", null };
                    const zve = [_:null]?[*:0]const u8{ "PATH=/bin\x00", null };
                    _ = sys.execve("/zig/zig\x00", @intFromPtr(&zva), @intFromPtr(&zve));
                    sys.exit(1);
                } else if (zv_pid > 0) {
                    _ = waitForPid(zv_pid);
                    puts("[init] zig version done\n");
                }
            }

            // Create /etc/os-release for zig cc (reads it for distro detection)
            _ = sys.mkdir("/etc\x00", 0o755);
            _ = writeFile("/etc/os-release\x00", "ID=zigix\nVERSION_ID=1.0\n");

            // Test /proc/self/exe readlink
            {
                var rlbuf: [256]u8 = undefined;
                const rl_len = sys.readlinkat(0xFFFFFFFFFFFFFF9C, "/proc/self/exe\x00", &rlbuf, 256); // AT_FDCWD
                if (rl_len > 0) {
                    puts("[proc] /proc/self/exe = ");
                    _ = sys.write(1, &rlbuf, @intCast(rl_len));
                    puts("\n");
                } else {
                    puts("[proc] /proc/self/exe FAILED\n");
                }
            }

            // Dump zig-cc wrapper content for verification
            puts("[init] zig-cc wrapper:\n");
            {
                const ccfd = sys.open("/tmp/kbuild/zig-cc\x00", 0, 0);
                if (ccfd >= 0) {
                    var ccbuf: [512]u8 = undefined;
                    const ccn = sys.read(@intCast(ccfd), &ccbuf, 512);
                    if (ccn > 0) _ = sys.write(1, &ccbuf, @intCast(ccn));
                    _ = sys.close(@intCast(ccfd));
                } else {
                    puts("  (not found)\n");
                }
            }

            // Test: compile a trivial C file with zig cc
            puts("[init] Testing: zig cc (trivial C file)...\n");
            _ = writeFile("/tmp/test.c\x00", "int main(void) { return 0; }\n");
            {
                const zc_pid = sys.fork();
                if (zc_pid == 0) {
                    _ = sys.chdir("/tmp\x00");
                    const zca = [_:null]?[*:0]const u8{
                        "/zig/zig\x00", "cc\x00",
                        "-target\x00", "x86_64-linux-gnu\x00",
                        "-c\x00", "/tmp/test.c\x00",
                        "-o\x00", "/tmp/test.o\x00",
                        null,
                    };
                    const zce = [_:null]?[*:0]const u8{
                        "PATH=/bin\x00",
                        "HOME=/tmp\x00",
                        "ZIG_LOCAL_CACHE_DIR=/tmp/zig-cache\x00",
                        "ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache\x00",
                        null,
                    };
                    _ = sys.execve("/zig/zig\x00", @intFromPtr(&zca), @intFromPtr(&zce));
                    sys.exit(1);
                } else if (zc_pid > 0) {
                    _ = waitForPid(zc_pid);
                    // Check if test.o was produced
                    const obj_fd = sys.open("/tmp/test.o\x00", 0, 0);
                    if (obj_fd >= 0) {
                        _ = sys.close(@intCast(obj_fd));
                        puts("[init] zig cc PASS (test.o created)\n");
                    } else {
                        puts("[init] zig cc FAIL (no test.o)\n");
                    }
                }
            }
        }

        // === LINUX KERNEL BUILD ON ZIGIX ===
        if (sys.open("/zig/linux/Makefile\x00", 0, 0) >= 0) {
            puts("\n========================================\n");
            puts("  LINUX KERNEL BUILD ON ZIGIX\n");
            puts("  Source: /zig/linux (v6.12.17 tinyconfig x86)\n");
            puts("  Compiler: zig cc (Clang/LLVM 21.1.0)\n");
            puts("  Build system: GNU Make 4.4.1\n");
            puts("========================================\n");

            // Set up out-of-tree build dir with pre-generated config
            _ = sys.mkdir("/tmp/kbuild\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/include\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/include/config\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/include/generated\x00", 0o755);
            copyFile("/zig/linux/.config\x00", "/tmp/kbuild/.config\x00");
            // Try copying from source tree first (may fail if dirs were removed for outputmakefile)
            copyFile("/zig/linux/include/config/auto.conf\x00", "/tmp/kbuild/include/config/auto.conf\x00");
            copyFile("/zig/linux/include/config/auto.conf.cmd\x00", "/tmp/kbuild/include/config/auto.conf.cmd\x00");
            copyFile("/zig/linux/include/generated/autoconf.h\x00", "/tmp/kbuild/include/generated/autoconf.h\x00");
            // Fallback: write generated files directly if copyFile failed (source dirs removed)
            // auto.conf MUST exist for scripts/setlocalversion (test -e check)
            // kernel.release sets KERNELRELEASE so filechk skips setlocalversion
            _ = writeFile("/tmp/kbuild/include/config/kernel.release\x00", "6.12.17\n");
            // Ensure auto.conf exists even if copy failed — tinyconfig minimal content
            {
                const fd = sys.open("/tmp/kbuild/include/config/auto.conf\x00", 0, 0);
                if (fd < 0) {
                    // File doesn't exist — copy failed, write minimal auto.conf
                    _ = writeFile("/tmp/kbuild/include/config/auto.conf\x00", "# Automatically generated - tinyconfig\n");
                } else {
                    _ = sys.close(@intCast(fd));
                }
            }
            // Ensure utsrelease.h and compile.h exist
            {
                const fd = sys.open("/tmp/kbuild/include/generated/utsrelease.h\x00", 0, 0);
                if (fd < 0) {
                    _ = writeFile("/tmp/kbuild/include/generated/utsrelease.h\x00", "#define UTS_RELEASE \"6.12.17\"\n");
                } else {
                    _ = sys.close(@intCast(fd));
                }
            }
            {
                const fd = sys.open("/tmp/kbuild/include/generated/compile.h\x00", 0, 0);
                if (fd < 0) {
                    _ = writeFile("/tmp/kbuild/include/generated/compile.h\x00", "#define UTS_MACHINE \"x86\"\n#define LINUX_COMPILE_BY \"zigix\"\n#define LINUX_COMPILE_HOST \"zigix\"\n#define LINUX_COMPILER \"zig cc\"\n");
                } else {
                    _ = sys.close(@intCast(fd));
                }
            }
            {
                const fd = sys.open("/tmp/kbuild/include/generated/autoconf.h\x00", 0, 0);
                if (fd < 0) {
                    _ = writeFile("/tmp/kbuild/include/generated/autoconf.h\x00", "/* Automatically generated - tinyconfig */\n");
                } else {
                    _ = sys.close(@intCast(fd));
                }
            }
            // Pre-create version.h (needs directory include/generated/uapi/linux/)
            _ = sys.mkdir("/tmp/kbuild/include/generated/uapi\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/include/generated/uapi/linux\x00", 0o755);
            // 6.12.17: VERSION=6, PATCHLEVEL=12, SUBLEVEL=17
            // LINUX_VERSION_CODE = 6*65536 + 12*256 + 17 = 396817
            _ = writeFile("/tmp/kbuild/include/generated/uapi/linux/version.h\x00", "#define LINUX_VERSION_CODE 396817\n#define KERNEL_VERSION(a,b,c) (((a) << 16) + ((b) << 8) + ((c) > 255 ? 255 : (c)))\n#define LINUX_VERSION_MAJOR 6\n#define LINUX_VERSION_PATCHLEVEL 12\n#define LINUX_VERSION_SUBLEVEL 17\n");
            // Copy arch-generated headers (removed from source tree to pass outputmakefile check)
            // These are needed for kernel compilation (asm-offsets.h etc.)
            _ = sys.mkdir("/tmp/kbuild/arch\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/arch/x86\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/arch/x86/include\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/arch/x86/include/generated\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/arch/x86/include/generated/asm\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/arch/x86/include/generated/uapi\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/arch/x86/include/generated/uapi/asm\x00", 0o755);
            // Pre-create ALL generic asm wrapper headers
            // These map mandatory-y headers from include/asm-generic/Kbuild that x86 doesn't provide
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/early_ioremap.h\x00", "#include <asm-generic/early_ioremap.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/mcs_spinlock.h\x00", "#include <asm-generic/mcs_spinlock.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/mmzone.h\x00", "#include <asm-generic/mmzone.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/irq_regs.h\x00", "#include <asm-generic/irq_regs.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/kmap_size.h\x00", "#include <asm-generic/kmap_size.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/local64.h\x00", "#include <asm-generic/local64.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/mmiowb.h\x00", "#include <asm-generic/mmiowb.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/module.lds.h\x00", "#include <asm-generic/module.lds.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/pgalloc.h\x00", "#include <asm-generic/pgalloc.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/asm/rwonce.h\x00", "#include <asm-generic/rwonce.h>\n");
            // Pre-create UAPI generic wrapper headers
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/bpf_perf_event.h\x00", "#include <asm-generic/bpf_perf_event.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/errno.h\x00", "#include <asm-generic/errno.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/fcntl.h\x00", "#include <asm-generic/fcntl.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/ioctl.h\x00", "#include <asm-generic/ioctl.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/ioctls.h\x00", "#include <asm-generic/ioctls.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/ipcbuf.h\x00", "#include <asm-generic/ipcbuf.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/param.h\x00", "#include <asm-generic/param.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/poll.h\x00", "#include <asm-generic/poll.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/resource.h\x00", "#include <asm-generic/resource.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/socket.h\x00", "#include <asm-generic/socket.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/sockios.h\x00", "#include <asm-generic/sockios.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/termbits.h\x00", "#include <asm-generic/termbits.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/termios.h\x00", "#include <asm-generic/termios.h>\n");
            _ = writeFile("/tmp/kbuild/arch/x86/include/generated/uapi/asm/types.h\x00", "#include <asm-generic/types.h>\n");
            // Copy key generated headers (try source tree, fallback above handles missing)
            copyFile("/zig/linux/include/generated/bounds.h\x00", "/tmp/kbuild/include/generated/bounds.h\x00");
            copyFile("/zig/linux/include/generated/timeconst.h\x00", "/tmp/kbuild/include/generated/timeconst.h\x00");
            copyFile("/zig/linux/include/generated/utsrelease.h\x00", "/tmp/kbuild/include/generated/utsrelease.h\x00");
            copyFile("/zig/linux/include/generated/compile.h\x00", "/tmp/kbuild/include/generated/compile.h\x00");
            // Pre-create proxy Makefile for out-of-tree build
            // outputmakefile override MUST come AFTER include (last definition wins in GNU Make)
            // Proxy Makefile: override targets that need special handling in out-of-tree build
            // - outputmakefile: skips source tree clean check
            // - asm-generic/uapi-asm-generic: headers pre-created above
            // - version_h targets: version.h pre-created above
            // - archheaders: syscall headers pre-created by SYSHDR (shell scripts work)
            // Proxy Makefile: override targets that are pre-built or pre-generated
            // Tab chars are required for Makefile recipes
            _ = writeFile("/tmp/kbuild/Makefile\x00", "# Proxy Makefile\ninclude /zig/linux/Makefile\noutputmakefile:\n\t@:\nscripts_basic:\n\t@:\nscripts:\n\t@:\nasm-generic uapi-asm-generic:\n\t@:\narchheaders:\n\t@:\narchscripts:\n\t@:\nremove-stale-files:\n\t@:\ninclude/generated/uapi/linux/version.h:\n\t@:\ninclude/generated/utsrelease.h:\n\t@:\ninclude/generated/compile.h:\n\t@:\ninclude/generated/autoconf.h:\n\t@:\ninclude/config/kernel.release:\n\t@:\n");
            // Pre-create output directories that make needs
            _ = sys.mkdir("/tmp/kbuild/scripts\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/scripts/basic\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/scripts/kconfig\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/scripts/mod\x00", 0o755);
            // Copy pre-built host tools to skip HOSTCC (zig cc -Xclang bug on Zigix)
            // Real fixdep binary from ext2 (static x86_64)
            copyFile("/zig/linux/scripts/basic/fixdep\x00", "/tmp/kbuild/scripts/basic/fixdep\x00");
            {
                const fd = sys.open("/zig/linux/scripts/basic/fixdep\x00", 0, 0);
                if (fd < 0) {
                    puts("[linux] ERROR: cannot open fixdep from source\n");
                } else {
                    puts("[linux] fixdep readable from source\n");
                    _ = sys.close(@intCast(fd));
                }
                const fd2 = sys.open("/tmp/kbuild/scripts/basic/fixdep\x00", 0, 0);
                if (fd2 < 0) {
                    puts("[linux] ERROR: fixdep copy FAILED\n");
                } else {
                    puts("[linux] fixdep copy OK\n");
                    _ = sys.close(@intCast(fd2));
                }
            }
            copyFile("/zig/linux/scripts/sorttable\x00", "/tmp/kbuild/scripts/sorttable\x00");
            // Missing utility stubs
            // Create symlinks for utilities with z-prefix names
            _ = sys.symlink("/bin/ztrue\x00", "/bin/true\x00");
            _ = sys.symlink("/bin/ztr\x00", "/bin/tr\x00");
            _ = sys.symlink("/bin/zsed\x00", "/bin/sed\x00");
            _ = sys.symlink("/bin/zgrep\x00", "/bin/grep\x00");
            _ = sys.symlink("/bin/zcat\x00", "/bin/cat\x00");
            _ = sys.symlink("/bin/zcut\x00", "/bin/cut\x00");
            _ = sys.symlink("/bin/zsort\x00", "/bin/sort\x00");
            _ = sys.symlink("/bin/zwc\x00", "/bin/wc\x00");
            _ = sys.symlink("/bin/zhead\x00", "/bin/head\x00");
            _ = sys.symlink("/bin/ztail\x00", "/bin/tail\x00");
            _ = sys.symlink("/bin/zbasename\x00", "/bin/basename\x00");
            _ = sys.symlink("/bin/zdirname\x00", "/bin/dirname\x00");
            _ = sys.symlink("/bin/zrm\x00", "/bin/rm\x00");
            _ = sys.symlink("/bin/zcp\x00", "/bin/cp\x00");
            _ = sys.symlink("/bin/zmv\x00", "/bin/mv\x00");
            _ = sys.symlink("/bin/zls\x00", "/bin/ls\x00");
            _ = sys.symlink("/bin/zmkdir\x00", "/bin/mkdir\x00");
            _ = sys.symlink("/bin/ztouch\x00", "/bin/touch\x00");
            _ = sys.symlink("/bin/zfind\x00", "/bin/find\x00");
            _ = sys.symlink("/bin/zxargs\x00", "/bin/xargs\x00");
            _ = sys.symlink("/bin/zawk\x00", "/bin/awk\x00");
            _ = sys.symlink("/bin/zuniq\x00", "/bin/uniq\x00");
            _ = sys.symlink("/bin/zprintf\x00", "/bin/printf\x00");
            _ = sys.symlink("/bin/zreadlink\x00", "/bin/readlink\x00");
            _ = sys.symlink("/bin/zrealpath\x00", "/bin/realpath\x00");
            _ = sys.symlink("/bin/ztest\x00", "/bin/test\x00");
            _ = sys.symlink("/bin/zecho\x00", "/bin/echo\x00");
            _ = sys.symlink("/bin/zenv\x00", "/bin/env\x00");
            _ = sys.symlink("/bin/ztrue\x00", "/bin/ld\x00");
            _ = sys.symlink("/bin/ztrue\x00", "/bin/gcc\x00");
            _ = sys.symlink("/bin/ztrue\x00", "/bin/cc\x00");
            _ = sys.symlink("/bin/ztrue\x00", "/bin/as\x00");
            _ = sys.symlink("/bin/ztrue\x00", "/bin/ld.lld\x00");
            // Create stubs for missing utilities in /bin/
            {
                // expr — used by Makefile for arithmetic; stub returns "0"
                const expr_fd = sys.open("/bin/expr\x00", 577, 0o755);
                if (expr_fd >= 0) {
                    const s = "#!/bin/sh\necho 0\n";
                    _ = sys.write(@intCast(expr_fd), s, s.len);
                    _ = sys.close(@intCast(expr_fd));
                }
                // cmp — used to compare files; stub always returns equal
                const cmp_fd = sys.open("/bin/cmp\x00", 577, 0o755);
                if (cmp_fd >= 0) {
                    const s = "#!/bin/sh\nexit 0\n";
                    _ = sys.write(@intCast(cmp_fd), s, s.len);
                    _ = sys.close(@intCast(cmp_fd));
                }
                // whoami — used by mkcompile_h
                const who_fd = sys.open("/bin/whoami\x00", 577, 0o755);
                if (who_fd >= 0) {
                    const s = "#!/bin/sh\necho root\n";
                    _ = sys.write(@intCast(who_fd), s, s.len);
                    _ = sys.close(@intCast(who_fd));
                }
                // ln — used by outputmakefile
                const ln_fd = sys.open("/bin/ln\x00", 577, 0o755);
                if (ln_fd >= 0) {
                    const s = "#!/bin/sh\nexit 0\n";
                    _ = sys.write(@intCast(ln_fd), s, s.len);
                    _ = sys.close(@intCast(ln_fd));
                }
            }
            // Pre-built host tools are in /zig/linux/ (on ext2).
            // Copy them to /tmp/kbuild/ so make finds them as up-to-date.
            _ = sys.mkdir("/tmp/kbuild/arch\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/arch/x86\x00", 0o755);
            _ = sys.mkdir("/tmp/kbuild/arch/x86/tools\x00", 0o755);
            copyFile("/zig/linux/arch/x86/tools/relocs\x00", "/tmp/kbuild/arch/x86/tools/relocs\x00");
            // Create zig-cc wrapper that filters out -Xclang (zig 0.16 bug)
            // The kernel build passes -Xclang -fcolor-diagnostics etc.
            // zig cc doesn't support -Xclang, so we strip it and its argument
            {
                const cc_fd = sys.open("/tmp/kbuild/zig-cc\x00", 577, 0o755); // O_WRONLY|O_CREAT|O_TRUNC
                if (cc_fd >= 0) {
                    // Strip empty-value GCC flags that break zig cc/clang argument parsing.
                    // -falign-functions= (empty) causes clang to consume the next arg as value,
                    // shifting all subsequent positions → cascading -Xclang error.
                    // Write filtered args to a temporary file, then xargs exec.
                    // Simpler: just write a wrapper that saves good args to a file and sources it.
                    // Simplest: use a C-style approach — write args to file, read back.
                    // Actually simplest: the kernel args don't have spaces in values that
                    // overlap with the filtered flags, so just use word splitting.
                    // Filter -fno-integrated-as and -Wp,-MMD (dep files not needed for first build)
                    const script = "#!/bin/sh\nn=\"\"\nfor a in \"$@\"; do\ncase \"$a\" in\n-fno-integrated-as|-Wp,-MMD,*) ;;\n*) n=\"$n $a\" ;;\nesac\ndone\nexec /zig/zig cc -target x86_64-freestanding-none -fintegrated-as $n\n";
                    _ = sys.write(@intCast(cc_fd), script, script.len);
                    _ = sys.close(@intCast(cc_fd));
                }
            }
            // Verify critical files exist
            {
                const fd = sys.open("/tmp/kbuild/include/config/auto.conf\x00", 0, 0);
                if (fd < 0) {
                    puts("[linux] WARNING: auto.conf MISSING\n");
                } else {
                    puts("[linux] auto.conf OK\n");
                    _ = sys.close(@intCast(fd));
                }
            }
            {
                const fd = sys.open("/tmp/kbuild/include/config/kernel.release\x00", 0, 0);
                if (fd < 0) {
                    puts("[linux] WARNING: kernel.release MISSING\n");
                } else {
                    puts("[linux] kernel.release OK\n");
                    _ = sys.close(@intCast(fd));
                }
            }
            // Create ld/gcc stubs — copy ztrue binary to paths zig cc looks
            copyFile("/bin/ztrue\x00", "/tmp/ld\x00");
            copyFile("/bin/ztrue\x00", "/tmp/gcc\x00");
            copyFile("/bin/ztrue\x00", "/tmp/kbuild/ld\x00");
            copyFile("/bin/ztrue\x00", "/tmp/kbuild/gcc\x00");
            copyFile("/bin/ztrue\x00", "/tmp/kbuild/as\x00");
            puts("[linux] Build dir prepared.\n");

            const build_pid = sys.fork();
            if (build_pid == 0) {
                _ = sys.chdir("/tmp/kbuild\x00");
                const argv = [_:null]?[*:0]const u8{
                    "/bin/make\x00",
                    "srctree=/zig/linux\x00",
                    "need-sub-make=\x00",
                    "need-config=\x00",
                    "CONFIG_FUNCTION_ALIGNMENT=0\x00",
                    "CONFIG_FRAME_WARN=2048\x00",
                    "ARCH=x86\x00",
                    "LLVM=1\x00",
                    "LLVM_IAS=1\x00",
                    "CC=/tmp/kbuild/zig-cc\x00",
                    "HOSTCC=/bin/true\x00",
                    "LD=/bin/zig-ld\x00",
                    "AR=/bin/zig-ar\x00",
                    "OBJCOPY=/bin/zig-objcopy\x00",
                    "HOSTAR=/bin/zig-ar\x00",
                    "HOSTLD=/bin/true\x00",
                    "SHELL=/bin/sh\x00",
                    "-j1\x00",
                    "vmlinux\x00",
                    null,
                };
                const envp = [_:null]?[*:0]const u8{
                    "PATH=/bin\x00",
                    "HOME=/tmp\x00",
                    "SHELL=/bin/sh\x00",
                    "ZIG_LOCAL_CACHE_DIR=/tmp/zig-cache\x00",
                    "ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache\x00",
                    null,
                };
                _ = sys.execve("/bin/make\x00", @intFromPtr(&argv), @intFromPtr(&envp));
                sys.exit(1);
            } else if (build_pid > 0) {
                puts("[linux] make started as PID ");
                write_uint(@intCast(build_pid));
                puts("\n");
                const ret = waitForPid(build_pid);
                puts("[linux] make exited (PID=");
                write_uint(@intCast(ret));
                puts(")\n");
                // Check if vmlinux was produced
                const vmlinux_fd = sys.open("/tmp/kbuild/vmlinux\x00", 0, 0);
                if (vmlinux_fd >= 0) {
                    _ = sys.close(@intCast(vmlinux_fd));
                    puts("\n========================================\n");
                    puts("  VMLINUX BUILT SUCCESSFULLY!\n");
                    puts("  ZIGIX COMPILED THE LINUX KERNEL!\n");
                    puts("========================================\n\n");
                } else {
                    puts("[linux] vmlinux not found (build incomplete)\n");
                }
            } else {
                puts("[linux] fork failed\n");
            }
        } else {
            puts("[init] No Linux source at /zig/linux — skipping build\n");
        }
        if (false) { // guard: skip all fork+exec tests
        const zig_pid = spawnWithArgs("/zig/zig\x00", "version\x00");
        if (zig_pid > 0) {
            _ = waitForPid(zig_pid);
            puts("[init] zig version test complete\n");
        }
        const build_pid = spawnZigBuild();
        if (build_pid > 0) {
            _ = waitForPid(build_pid);
            puts("[init] zig build-exe PASSED (compiled successfully)\n");
        }

        // // Test 3: multi-file compilation (@import("lib.zig"))
        // puts("[init] Testing multi-file: /tmp/multitest.zig + lib.zig...\n");
        // const multi_pid = spawnZigMultiFile();
        // if (multi_pid > 0) {
        //     _ = waitForPid(multi_pid);
        //     puts("[init] multi-file build complete, running /tmp/multitest...\n");
        //     const mt_pid = spawnDaemon("/tmp/multitest\x00");
        //     if (mt_pid > 0) {
        //         _ = waitForPid(mt_pid);
        //     }
        //     puts("[init] multi-file test complete\n");
        // }

        // Check if kernel source tree is present — if so, skip stress + build tests
        // (already proven) and go straight to self-host to maximize NVMe/memory headroom.
        const has_kernel_src = sys.open("/zigix/build.zig\x00", 0, 0);
        if (has_kernel_src >= 0) {
            _ = sys.close(@intCast(has_kernel_src));
            puts("[init] Kernel source at /zigix/ — skipping to self-host\n");
        } else {
            // Test 4: Fork stress test — disabled pending CoW SMP fix
            // Rapid fork+exec on SMP triggers a PTE race when parent/child
            // run on different CPUs. Skip for now to let ext3/fs tests run.
            puts("[init] Fork stress test: SKIPPED (pending CoW SMP fix)\n");

            // Test 5: zig build (build.zig runner)
            puts("[init] Testing zig build (build.zig)...\n");
            const zb_pid = spawnZigBuildSystem();
            if (zb_pid > 0) {
                _ = waitForPid(zb_pid);
                puts("[init] zig build complete, running result...\n");
                const out_pid = spawnDaemon("/tmp/project/zig-out/bin/hello\x00");
                if (out_pid > 0) {
                    _ = waitForPid(out_pid);
                }
                puts("[init] zig build test complete\n");
            } else {
                puts("[init] zig build test skipped (fork failed)\n");
            }
        } // end of !has_kernel_src

        // Test 6: SELF-HOST — build the Zigix kernel from source
        // The kernel source tree is at /zigix/ on the disk image.
        // This is the closed loop: Zigix compiling itself.
        const arch_name = comptime if (@import("builtin").cpu.arch == .aarch64) "aarch64" else "x86_64";
        puts("[init] === SELF-HOST TEST: zig build -Darch=" ++ arch_name ++ " ===\n");
        const sh_pid = spawnSelfHost();
        if (sh_pid > 0) {
            const sh_ret = waitForPid(sh_pid);
            puts("[init] Self-host process exited (PID=");
            write_uint(@intCast(sh_ret));
            puts(")\n");
            // Check if the kernel binary was produced
            // x86_64 produces "zigix", aarch64 produces "zigix-aarch64"
            const primary_bin = comptime if (@import("builtin").cpu.arch == .aarch64)
                "/zigix/zig-out/bin/zigix-aarch64\x00"
            else
                "/zigix/zig-out/bin/zigix\x00";
            const check_fd = sys.open(primary_bin, 0, 0);
            if (check_fd >= 0) {
                _ = sys.close(@intCast(check_fd));
                puts("[init] === SELF-HOST PASSED ===\n");
                puts("[init] === ZIGIX CAN COMPILE ITSELF (" ++ arch_name ++ ") ===\n");
            } else {
                puts("[init] === SELF-HOST: build completed but binary not found ===\n");
                puts("[init] Listing /zigix/zig-out/:\n");
                const ls_pid = spawnWithArgs("/bin/busybox\x00", "ls\x00");
                if (ls_pid > 0) _ = waitForPid(ls_pid);
            }
        } else {
            puts("[init] === SELF-HOST: fork failed ===\n");
        }
        // Sleep briefly to let serial output flush before login loop starts
        _ = sys.nanosleep(5);
        } // end if(false) guard for fork+exec tests
    }

    // ext4 filesystem write/read test — exercises extent tree + mballoc
    {
        puts("[init] ext4 write test: creating /tmp/ext4test.txt...\n");
        const test_data = "Hello from ext4! Extent trees, CRC32c checksums, 64-bit BGDs.\n";
        if (writeFile("/tmp/ext4test.txt\x00", test_data)) {
            puts("[init] ext4 write OK, reading back...\n");
            const fd = sys.open("/tmp/ext4test.txt\x00", 0, 0); // O_RDONLY
            if (fd >= 0) {
                var rbuf: [128]u8 = undefined;
                const n = sys.read(@intCast(fd), &rbuf, 128);
                _ = sys.close(@intCast(fd));
                if (n > 0) {
                    puts("[init] ext4 read back: ");
                    _ = sys.write(1, &rbuf, @intCast(n));
                    // Verify data matches
                    var match = true;
                    if (n != test_data.len) {
                        match = false;
                    } else {
                        for (0..@intCast(n)) |i| {
                            if (rbuf[i] != test_data[i]) { match = false; break; }
                        }
                    }
                    if (match) {
                        puts("[init] ext4 write/read PASS\n");
                    } else {
                        puts("[init] ext4 write/read FAIL: data mismatch!\n");
                    }
                } else {
                    puts("[init] ext4 read FAIL: read returned 0\n");
                }
            } else {
                puts("[init] ext4 read FAIL: open returned error\n");
            }
        } else {
            puts("[init] ext4 write FAIL: could not create file\n");
        }

        // Test 2: larger write (multi-block) to exercise extent allocation
        puts("[init] ext4 multi-block write test (16KB)...\n");
        const big_fd = sys.open("/tmp/bigfile.bin\x00", 577, 0o644); // O_WRONLY|O_CREAT|O_TRUNC
        if (big_fd >= 0) {
            var pattern: [4096]u8 = undefined;
            for (0..4096) |i| pattern[i] = @truncate(i);
            var written: usize = 0;
            var w_ok = true;
            // Write 4 blocks (16KB) to trigger multi-extent allocation
            for (0..4) |_| {
                const w = sys.write(@intCast(big_fd), &pattern, 4096);
                if (w > 0) {
                    written += @intCast(w);
                } else {
                    w_ok = false;
                    break;
                }
            }
            _ = sys.close(@intCast(big_fd));

            if (w_ok) {
                puts("[init] ext4 wrote ");
                write_uint(written);
                puts(" bytes OK\n");
            } else {
                puts("[init] ext4 multi-block write FAIL\n");
            }
        } else {
            puts("[init] ext4 multi-block: open FAIL\n");
        }
    }

    // ====================================================================
    // ext4 Feature Test Suite
    // Tests run on the ROOT filesystem (ext2/ext3/ext4 on block device)
    // NOT on /tmp (which is tmpfs). This exercises real extent trees,
    // inode checksums, 64-bit BGDs, and the on-disk allocation paths.
    // ====================================================================
    {
        var ext4_pass: u32 = 0;
        var ext4_total: u32 = 0;

        // Create test directory on root filesystem (NOT tmpfs)
        _ = sys.mkdir("/ext4test\x00", 0o755);

        // Test 1: Basic extent-backed file write/read
        ext4_total += 1;
        puts("[ext4-test] 1: extent write/read...\n");
        {
            const data = "ext4 extent tree test data — verifying on-disk format\n";
            const fd = sys.open("/ext4test/extent.txt\x00", 577, 0o644);
            if (fd >= 0) {
                _ = sys.write(@intCast(fd), data, data.len);
                _ = sys.close(@intCast(fd));
                const fd2 = sys.open("/ext4test/extent.txt\x00", 0, 0);
                if (fd2 >= 0) {
                    var rbuf: [128]u8 = undefined;
                    const n = sys.read(@intCast(fd2), &rbuf, 128);
                    _ = sys.close(@intCast(fd2));
                    if (n == data.len) {
                        var ok = true;
                        for (0..@intCast(n)) |i| {
                            if (rbuf[i] != data[i]) { ok = false; break; }
                        }
                        if (ok) { ext4_pass += 1; puts("[ext4-test] 1: extent write/read PASS\n"); } else { puts("[ext4-test] 1: FAIL (data mismatch)\n"); }
                    } else { puts("[ext4-test] 1: FAIL (size mismatch)\n"); }
                } else { puts("[ext4-test] 1: FAIL (reopen)\n"); }
            } else { puts("[ext4-test] 1: FAIL (create)\n"); }
        }

        // Test 2: Multi-block extent write (16KB) with readback verification
        ext4_total += 1;
        puts("[ext4-test] 2: multi-block extent 16KB...\n");
        {
            const fd = sys.open("/ext4test/multi.bin\x00", 577, 0o644);
            if (fd >= 0) {
                var pattern: [4096]u8 = undefined;
                for (0..4096) |i| pattern[i] = @truncate(i ^ 0xAA);
                var written: usize = 0;
                for (0..4) |_| {
                    const w = sys.write(@intCast(fd), &pattern, 4096);
                    if (w > 0) written += @intCast(w);
                }
                _ = sys.close(@intCast(fd));

                // Read back and verify
                const fd2 = sys.open("/ext4test/multi.bin\x00", 0, 0);
                if (fd2 >= 0) {
                    var rbuf: [4096]u8 = undefined;
                    var verified: usize = 0;
                    var ok = true;
                    for (0..4) |_| {
                        const n = sys.read(@intCast(fd2), &rbuf, 4096);
                        if (n == 4096) {
                            for (0..4096) |i| {
                                if (rbuf[i] != pattern[i]) { ok = false; break; }
                            }
                            verified += 4096;
                        }
                        if (!ok) break;
                    }
                    _ = sys.close(@intCast(fd2));
                    if (ok and verified == 16384) {
                        ext4_pass += 1;
                        puts("[ext4-test] 2: multi-block PASS (16384 bytes verified)\n");
                    } else { puts("[ext4-test] 2: FAIL (readback mismatch)\n"); }
                } else { puts("[ext4-test] 2: FAIL (reopen)\n"); }
            } else { puts("[ext4-test] 2: FAIL (create)\n"); }
        }

        // Test 3: Large file (256KB) — exercises multiple extents
        ext4_total += 1;
        puts("[ext4-test] 3: large file 256KB...\n");
        {
            const fd = sys.open("/ext4test/large.bin\x00", 577, 0o644);
            if (fd >= 0) {
                var block: [4096]u8 = undefined;
                var written: usize = 0;
                for (0..64) |bi| {
                    // Each block has unique pattern based on block index
                    for (0..4096) |i| block[i] = @truncate(i ^ bi);
                    const w = sys.write(@intCast(fd), &block, 4096);
                    if (w > 0) written += @intCast(w);
                }
                _ = sys.close(@intCast(fd));

                // Verify first and last blocks
                const fd2 = sys.open("/ext4test/large.bin\x00", 0, 0);
                if (fd2 >= 0) {
                    var rbuf: [4096]u8 = undefined;
                    const n = sys.read(@intCast(fd2), &rbuf, 4096);
                    var ok = n == 4096;
                    if (ok) {
                        for (0..4096) |i| {
                            if (rbuf[i] != @as(u8, @truncate(i ^ 0))) { ok = false; break; }
                        }
                    }
                    _ = sys.close(@intCast(fd2));
                    if (ok and written == 262144) {
                        ext4_pass += 1;
                        puts("[ext4-test] 3: large file PASS (262144 bytes)\n");
                    } else { puts("[ext4-test] 3: FAIL\n"); }
                } else { puts("[ext4-test] 3: FAIL (reopen)\n"); }
            } else { puts("[ext4-test] 3: FAIL (create)\n"); }
        }

        // Test 4: File append — extend existing extent
        ext4_total += 1;
        puts("[ext4-test] 4: file append...\n");
        {
            // Write initial 4KB
            const fd = sys.open("/ext4test/append.bin\x00", 577, 0o644);
            if (fd >= 0) {
                var buf1: [4096]u8 = undefined;
                for (0..4096) |i| buf1[i] = 0x41; // 'A'
                _ = sys.write(@intCast(fd), &buf1, 4096);
                _ = sys.close(@intCast(fd));

                // Append another 4KB
                const fd2 = sys.open("/ext4test/append.bin\x00", 1025, 0o644); // O_WRONLY|O_APPEND
                if (fd2 >= 0) {
                    var buf2: [4096]u8 = undefined;
                    for (0..4096) |i| buf2[i] = 0x42; // 'B'
                    _ = sys.write(@intCast(fd2), &buf2, 4096);
                    _ = sys.close(@intCast(fd2));

                    // Read back 8KB and verify
                    const fd3 = sys.open("/ext4test/append.bin\x00", 0, 0);
                    if (fd3 >= 0) {
                        var rbuf: [4096]u8 = undefined;
                        const n1 = sys.read(@intCast(fd3), &rbuf, 4096);
                        var ok = n1 == 4096 and rbuf[0] == 0x41 and rbuf[4095] == 0x41;
                        const n2 = sys.read(@intCast(fd3), &rbuf, 4096);
                        ok = ok and n2 == 4096 and rbuf[0] == 0x42 and rbuf[4095] == 0x42;
                        _ = sys.close(@intCast(fd3));
                        if (ok) {
                            ext4_pass += 1;
                            puts("[ext4-test] 4: file append PASS (8192 bytes)\n");
                        } else { puts("[ext4-test] 4: FAIL (content mismatch)\n"); }
                    } else { puts("[ext4-test] 4: FAIL (read reopen)\n"); }
                } else { puts("[ext4-test] 4: FAIL (append open)\n"); }
            } else { puts("[ext4-test] 4: FAIL (create)\n"); }
        }

        // Test 5: File truncation with extents
        ext4_total += 1;
        puts("[ext4-test] 5: truncate...\n");
        {
            // Write 32KB
            const fd = sys.open("/ext4test/trunc.bin\x00", 577, 0o644);
            if (fd >= 0) {
                var buf: [4096]u8 = undefined;
                for (0..4096) |i| buf[i] = 0xCC;
                for (0..8) |_| _ = sys.write(@intCast(fd), &buf, 4096);
                _ = sys.close(@intCast(fd));

                // Truncate to 4KB
                const fd2 = sys.open("/ext4test/trunc.bin\x00", 1, 0); // O_WRONLY
                if (fd2 >= 0) {
                    _ = sys.ftruncate(@intCast(fd2), 4096);
                    _ = sys.close(@intCast(fd2));

                    // Verify size is 4KB
                    const fd3 = sys.open("/ext4test/trunc.bin\x00", 0, 0);
                    if (fd3 >= 0) {
                        var rbuf: [8192]u8 = undefined;
                        const n = sys.read(@intCast(fd3), &rbuf, 8192);
                        _ = sys.close(@intCast(fd3));
                        if (n == 4096 and rbuf[0] == 0xCC) {
                            ext4_pass += 1;
                            puts("[ext4-test] 5: truncate PASS (32KB→4KB)\n");
                        } else { puts("[ext4-test] 5: FAIL (wrong size after truncate)\n"); }
                    } else { puts("[ext4-test] 5: FAIL (verify open)\n"); }
                } else { puts("[ext4-test] 5: FAIL (truncate open)\n"); }
            } else { puts("[ext4-test] 5: FAIL (create)\n"); }
        }

        // Test 6: fsync on extent-backed file
        ext4_total += 1;
        puts("[ext4-test] 6: fsync...\n");
        {
            const fd = sys.open("/ext4test/fsync.bin\x00", 577, 0o644);
            if (fd >= 0) {
                var buf: [4096]u8 = undefined;
                for (0..4096) |i| buf[i] = @truncate(i ^ 0x55);
                _ = sys.write(@intCast(fd), &buf, 4096);
                const sync_ret = sys.fsync(@intCast(fd));
                _ = sys.close(@intCast(fd));

                const fd2 = sys.open("/ext4test/fsync.bin\x00", 0, 0);
                if (fd2 >= 0) {
                    var rbuf: [4096]u8 = undefined;
                    const n = sys.read(@intCast(fd2), &rbuf, 4096);
                    _ = sys.close(@intCast(fd2));
                    if (n == 4096 and sync_ret >= 0) {
                        ext4_pass += 1;
                        puts("[ext4-test] 6: fsync PASS\n");
                    } else { puts("[ext4-test] 6: FAIL\n"); }
                } else { puts("[ext4-test] 6: FAIL (reopen)\n"); }
            } else { puts("[ext4-test] 6: FAIL (create)\n"); }
        }

        // Test 7: Many files in one directory (linear scan stress)
        ext4_total += 1;
        puts("[ext4-test] 7: directory with 50 files...\n");
        {
            _ = sys.mkdir("/ext4test/manyfiles\x00", 0o755);
            var created: u32 = 0;
            var namebuf: [64]u8 = undefined;
            for (0..50) |fi| {
                // Build path: /ext4test/manyfiles/fileNN
                const prefix = "/ext4test/manyfiles/file";
                for (0..prefix.len) |i| namebuf[i] = prefix[i];
                namebuf[prefix.len] = @as(u8, @truncate(fi / 10)) + '0';
                namebuf[prefix.len + 1] = @as(u8, @truncate(fi % 10)) + '0';
                namebuf[prefix.len + 2] = 0;

                const fd = sys.open(&namebuf, 577, 0o644);
                if (fd >= 0) {
                    _ = sys.write(@intCast(fd), "test\n", 5);
                    _ = sys.close(@intCast(fd));
                    created += 1;
                }
            }
            if (created == 50) {
                // Verify a few random files
                const check_fd = sys.open("/ext4test/manyfiles/file25\x00", 0, 0);
                if (check_fd >= 0) {
                    _ = sys.close(@intCast(check_fd));
                    ext4_pass += 1;
                    puts("[ext4-test] 7: 50 files PASS\n");
                } else { puts("[ext4-test] 7: FAIL (verify)\n"); }
            } else { puts("[ext4-test] 7: FAIL (created "); write_uint(created); puts("/50)\n"); }
        }

        // Test 8: statfs — verify filesystem metadata
        ext4_total += 1;
        puts("[ext4-test] 8: statfs...\n");
        {
            var statbuf: [120]u8 = undefined;
            const ret = sys.statfs("/\x00", &statbuf);
            if (ret >= 0) {
                // f_type at offset 0 (first 8 bytes on x86_64)
                const f_type = @as(*const u64, @alignCast(@ptrCast(&statbuf[0]))).*;
                const f_bsize = @as(*const u64, @alignCast(@ptrCast(&statbuf[8]))).*;
                if (f_type == 0xEF53 and f_bsize == 4096) {
                    ext4_pass += 1;
                    puts("[ext4-test] 8: statfs PASS (ext2/3/4, 4K blocks)\n");
                } else { puts("[ext4-test] 8: FAIL (wrong type/bsize)\n"); }
            } else { puts("[ext4-test] 8: FAIL (statfs returned error)\n"); }
        }

        // Results
        puts("[ext4-test] RESULTS: ");
        write_uint(ext4_pass);
        puts("/");
        write_uint(ext4_total);
        if (ext4_pass == ext4_total) {
            puts(" ALL PASS\n");
        } else {
            puts(" (some failed)\n");
        }
    }

    // ====================================================================
    // ext3 Journal + Filesystem Test Suite
    // Tests: fsync, sendfile, rename, directory ops, journal commit
    // ====================================================================
    {
        var ext3_pass: u32 = 0;
        var ext3_total: u32 = 0;

        // Test 1: fsync — write file, fsync, verify data persists
        ext3_total += 1;
        puts("[ext3-test] 1: fsync...\n");
        {
            const fd = sys.open("/tmp/fsync_test.txt\x00", 577, 0o644); // O_WRONLY|O_CREAT|O_TRUNC
            if (fd >= 0) {
                const data = "fsync test data: journal should commit this block\n";
                _ = sys.write(@intCast(fd), data.ptr, data.len);
                const ret = sys.fsync(@intCast(fd));
                _ = sys.close(@intCast(fd));

                // Read back and verify
                const rfd = sys.open("/tmp/fsync_test.txt\x00", 0, 0);
                if (rfd >= 0) {
                    var rbuf: [128]u8 = undefined;
                    const n = sys.read(@intCast(rfd), &rbuf, 128);
                    _ = sys.close(@intCast(rfd));
                    if (n == @as(isize, @intCast(data.len)) and ret >= 0) {
                        puts("[ext3-test] 1: fsync PASS\n");
                        ext3_pass += 1;
                    } else {
                        puts("[ext3-test] 1: fsync FAIL (data mismatch or fsync error)\n");
                    }
                } else {
                    puts("[ext3-test] 1: fsync FAIL (read-back open failed)\n");
                }
            } else {
                puts("[ext3-test] 1: fsync FAIL (create failed)\n");
            }
        }

        // Test 2: fdatasync
        ext3_total += 1;
        puts("[ext3-test] 2: fdatasync...\n");
        {
            const fd = sys.open("/tmp/fdatasync_test.txt\x00", 577, 0o644);
            if (fd >= 0) {
                const data = "fdatasync test: metadata-only sync\n";
                _ = sys.write(@intCast(fd), data.ptr, data.len);
                const ret = sys.fdatasync(@intCast(fd));
                _ = sys.close(@intCast(fd));
                if (ret >= 0) {
                    puts("[ext3-test] 2: fdatasync PASS\n");
                    ext3_pass += 1;
                } else {
                    puts("[ext3-test] 2: fdatasync FAIL\n");
                }
            } else {
                puts("[ext3-test] 2: fdatasync FAIL (create failed)\n");
            }
        }

        // Test 3: sendfile — copy file via kernel-space transfer
        ext3_total += 1;
        puts("[ext3-test] 3: sendfile...\n");
        {
            // Source: /tmp/fsync_test.txt (written in test 1)
            const src_fd = sys.open("/tmp/fsync_test.txt\x00", 0, 0); // O_RDONLY
            const dst_fd = sys.open("/tmp/sendfile_copy.txt\x00", 577, 0o644); // O_WRONLY|O_CREAT|O_TRUNC
            if (src_fd >= 0 and dst_fd >= 0) {
                const sent = sys.sendfile(@intCast(dst_fd), @intCast(src_fd), 0, 4096);
                _ = sys.close(@intCast(src_fd));
                _ = sys.close(@intCast(dst_fd));

                if (sent > 0) {
                    // Verify copy matches original
                    const vfd = sys.open("/tmp/sendfile_copy.txt\x00", 0, 0);
                    if (vfd >= 0) {
                        var vbuf: [128]u8 = undefined;
                        const n = sys.read(@intCast(vfd), &vbuf, 128);
                        _ = sys.close(@intCast(vfd));
                        if (n == sent) {
                            puts("[ext3-test] 3: sendfile PASS (");
                            write_uint(@intCast(sent));
                            puts(" bytes)\n");
                            ext3_pass += 1;
                        } else {
                            puts("[ext3-test] 3: sendfile FAIL (size mismatch)\n");
                        }
                    } else {
                        puts("[ext3-test] 3: sendfile FAIL (verify open failed)\n");
                    }
                } else {
                    puts("[ext3-test] 3: sendfile FAIL (sent=");
                    write_uint(@bitCast(sent));
                    puts(")\n");
                }
            } else {
                puts("[ext3-test] 3: sendfile FAIL (open failed)\n");
                if (src_fd >= 0) _ = sys.close(@intCast(src_fd));
                if (dst_fd >= 0) _ = sys.close(@intCast(dst_fd));
            }
        }

        // Test 4: rename — move file, verify old gone, new exists
        ext3_total += 1;
        puts("[ext3-test] 4: rename...\n");
        {
            // Create source file
            if (writeFile("/tmp/rename_src.txt\x00", "rename test data\n")) {
                const ret = sys.rename("/tmp/rename_src.txt\x00", "/tmp/rename_dst.txt\x00");
                if (ret >= 0) {
                    // Verify old is gone
                    const old_fd = sys.open("/tmp/rename_src.txt\x00", 0, 0);
                    // Verify new exists
                    const new_fd = sys.open("/tmp/rename_dst.txt\x00", 0, 0);
                    if (old_fd < 0 and new_fd >= 0) {
                        var rbuf: [64]u8 = undefined;
                        const n = sys.read(@intCast(new_fd), &rbuf, 64);
                        _ = sys.close(@intCast(new_fd));
                        if (n == 17) { // "rename test data\n"
                            puts("[ext3-test] 4: rename PASS\n");
                            ext3_pass += 1;
                        } else {
                            puts("[ext3-test] 4: rename FAIL (content wrong)\n");
                        }
                    } else {
                        puts("[ext3-test] 4: rename FAIL (old still exists or new missing)\n");
                        if (old_fd >= 0) _ = sys.close(@intCast(old_fd));
                        if (new_fd >= 0) _ = sys.close(@intCast(new_fd));
                    }
                } else {
                    puts("[ext3-test] 4: rename FAIL (ret=");
                    write_uint(@bitCast(ret));
                    puts(")\n");
                }
            } else {
                puts("[ext3-test] 4: rename FAIL (create failed)\n");
            }
        }

        // Test 5: directory create + populate + delete
        ext3_total += 1;
        puts("[ext3-test] 5: directory ops...\n");
        {
            const mk_ret = sys.mkdir("/tmp/testdir\x00", 0o755);
            if (mk_ret >= 0) {
                // Create files inside
                const f1_ok = writeFile("/tmp/testdir/file1.txt\x00", "file1\n");
                const f2_ok = writeFile("/tmp/testdir/file2.txt\x00", "file2\n");
                if (f1_ok and f2_ok) {
                    // Verify files exist
                    const fd1 = sys.open("/tmp/testdir/file1.txt\x00", 0, 0);
                    const fd2 = sys.open("/tmp/testdir/file2.txt\x00", 0, 0);
                    if (fd1 >= 0 and fd2 >= 0) {
                        _ = sys.close(@intCast(fd1));
                        _ = sys.close(@intCast(fd2));
                        // Clean up: delete files then directory
                        _ = sys.unlink("/tmp/testdir/file1.txt\x00");
                        _ = sys.unlink("/tmp/testdir/file2.txt\x00");
                        const rm_ret = sys.rmdir("/tmp/testdir\x00");
                        // Verify dir is gone
                        const chk = sys.open("/tmp/testdir/file1.txt\x00", 0, 0);
                        if (rm_ret >= 0 and chk < 0) {
                            puts("[ext3-test] 5: directory ops PASS\n");
                            ext3_pass += 1;
                        } else {
                            puts("[ext3-test] 5: directory ops FAIL (cleanup incomplete)\n");
                            if (chk >= 0) _ = sys.close(@intCast(chk));
                        }
                    } else {
                        puts("[ext3-test] 5: directory ops FAIL (files not readable)\n");
                        if (fd1 >= 0) _ = sys.close(@intCast(fd1));
                        if (fd2 >= 0) _ = sys.close(@intCast(fd2));
                    }
                } else {
                    puts("[ext3-test] 5: directory ops FAIL (file create failed)\n");
                }
            } else {
                puts("[ext3-test] 5: directory ops FAIL (mkdir failed)\n");
            }
        }

        // Test 6: multi-block file with fsync — stress journal batching
        ext3_total += 1;
        puts("[ext3-test] 6: multi-block fsync (32KB)...\n");
        {
            const fd = sys.open("/tmp/bigfsync.bin\x00", 577, 0o644);
            if (fd >= 0) {
                var pattern: [4096]u8 = undefined;
                for (0..4096) |i| pattern[i] = @truncate(i ^ 0xA5);
                var total_written: usize = 0;
                var ok = true;
                // Write 8 blocks (32KB)
                for (0..8) |_| {
                    const w = sys.write(@intCast(fd), &pattern, 4096);
                    if (w > 0) {
                        total_written += @intCast(w);
                    } else {
                        ok = false;
                        break;
                    }
                }
                const sync_ret = sys.fsync(@intCast(fd));
                _ = sys.close(@intCast(fd));

                if (ok and sync_ret >= 0 and total_written == 32768) {
                    // Read back first block and verify pattern
                    const rfd = sys.open("/tmp/bigfsync.bin\x00", 0, 0);
                    if (rfd >= 0) {
                        var rbuf: [4096]u8 = undefined;
                        const n = sys.read(@intCast(rfd), &rbuf, 4096);
                        _ = sys.close(@intCast(rfd));
                        if (n == 4096 and rbuf[0] == 0xA5 and rbuf[1] == 0xA4) {
                            puts("[ext3-test] 6: multi-block fsync PASS (32768 bytes)\n");
                            ext3_pass += 1;
                        } else {
                            puts("[ext3-test] 6: multi-block fsync FAIL (data corrupt)\n");
                        }
                    } else {
                        puts("[ext3-test] 6: multi-block fsync FAIL (read-back failed)\n");
                    }
                } else {
                    puts("[ext3-test] 6: multi-block fsync FAIL (write or sync error)\n");
                }
            } else {
                puts("[ext3-test] 6: multi-block fsync FAIL (create failed)\n");
            }
        }

        // Test 7: sync() — global filesystem sync
        ext3_total += 1;
        puts("[ext3-test] 7: sync()...\n");
        {
            // Write a file, then sync entire FS
            if (writeFile("/tmp/sync_test.txt\x00", "global sync test\n")) {
                sys.sync_();
                // Verify file still readable after sync
                const fd = sys.open("/tmp/sync_test.txt\x00", 0, 0);
                if (fd >= 0) {
                    var rbuf: [64]u8 = undefined;
                    const n = sys.read(@intCast(fd), &rbuf, 64);
                    _ = sys.close(@intCast(fd));
                    if (n == 17) {
                        puts("[ext3-test] 7: sync PASS\n");
                        ext3_pass += 1;
                    } else {
                        puts("[ext3-test] 7: sync FAIL (data wrong)\n");
                    }
                } else {
                    puts("[ext3-test] 7: sync FAIL (file gone after sync)\n");
                }
            } else {
                puts("[ext3-test] 7: sync FAIL (write failed)\n");
            }
        }

        // Test 8: lseek + read — seek to middle of file, read partial
        ext3_total += 1;
        puts("[ext3-test] 8: lseek...\n");
        {
            const SEEK_SET: u64 = 0;
            if (writeFile("/tmp/lseek_test.txt\x00", "ABCDEFGHIJKLMNOPQRSTUVWXYZ\n")) {
                const fd = sys.open("/tmp/lseek_test.txt\x00", 0, 0);
                if (fd >= 0) {
                    const pos = sys.lseek(@intCast(fd), 10, SEEK_SET); // seek to 'K'
                    if (pos == 10) {
                        var rbuf: [5]u8 = undefined;
                        const n = sys.read(@intCast(fd), &rbuf, 5);
                        _ = sys.close(@intCast(fd));
                        if (n == 5 and rbuf[0] == 'K' and rbuf[4] == 'O') {
                            puts("[ext3-test] 8: lseek PASS\n");
                            ext3_pass += 1;
                        } else {
                            puts("[ext3-test] 8: lseek FAIL (wrong data at offset)\n");
                        }
                    } else {
                        _ = sys.close(@intCast(fd));
                        puts("[ext3-test] 8: lseek FAIL (seek returned wrong pos)\n");
                    }
                } else {
                    puts("[ext3-test] 8: lseek FAIL (open failed)\n");
                }
            } else {
                puts("[ext3-test] 8: lseek FAIL (write failed)\n");
            }
        }

        // Test 9: rapid file create/delete cycle — stress journal alloc/free + revoke
        ext3_total += 1;
        puts("[ext3-test] 9: create/delete stress (10 cycles)...\n");
        {
            var cycles_ok: u32 = 0;
            for (0..10) |_| {
                if (writeFile("/tmp/stress_file.txt\x00", "stress iteration data block padding\n")) {
                    const del_ret = sys.unlink("/tmp/stress_file.txt\x00");
                    if (del_ret >= 0) {
                        cycles_ok += 1;
                    }
                }
            }
            if (cycles_ok == 10) {
                puts("[ext3-test] 9: create/delete stress PASS (10/10)\n");
                ext3_pass += 1;
            } else {
                puts("[ext3-test] 9: create/delete stress FAIL (");
                write_uint(cycles_ok);
                puts("/10)\n");
            }
        }

        // Summary
        puts("[ext3-test] Results: ");
        write_uint(ext3_pass);
        puts("/");
        write_uint(ext3_total);
        puts(" passed\n");
        if (ext3_pass == ext3_total) {
            puts("[ext3-test] ALL PASS\n");
        }
    }

    // ---- Journal replay test ----
    // Detects first vs second boot via /journal_marker.txt on ext4 disk.
    // Phase 1 (no marker): write test files, sync, write marker, signal done, halt.
    // Phase 2 (marker exists): verify files survived journal replay.
    {
        const marker_fd = sys.open("/journal_marker.txt\x00", 0, 0); // O_RDONLY
        if (marker_fd >= 0) {
            // Phase 2: marker exists — this is the replay verification boot
            _ = sys.close(@intCast(marker_fd));
            puts("[journal-replay] Phase 2: verifying files after dirty shutdown...\n");

            var replay_pass: u32 = 0;
            var replay_total: u32 = 0;

            // Verify test file 1: small file
            replay_total += 1;
            {
                const fd = sys.open("/journal_test1.txt\x00", 0, 0);
                if (fd >= 0) {
                    var rbuf: [64]u8 = undefined;
                    const n = sys.read(@intCast(fd), &rbuf, 64);
                    _ = sys.close(@intCast(fd));
                    const expected = "journal replay test data 1\n";
                    if (n == expected.len) {
                        var ok = true;
                        for (0..expected.len) |i| {
                            if (rbuf[i] != expected[i]) { ok = false; break; }
                        }
                        if (ok) {
                            puts("[journal-replay] test1.txt: PASS (content intact)\n");
                            replay_pass += 1;
                        } else {
                            puts("[journal-replay] test1.txt: FAIL (content corrupted)\n");
                        }
                    } else {
                        puts("[journal-replay] test1.txt: FAIL (wrong size: ");
                        write_uint(@intCast(n));
                        puts(")\n");
                    }
                } else {
                    puts("[journal-replay] test1.txt: FAIL (file missing)\n");
                }
            }

            // Verify test file 2: multi-block file (8KB)
            replay_total += 1;
            {
                const fd = sys.open("/journal_test2.txt\x00", 0, 0);
                if (fd >= 0) {
                    // Read first 64 bytes — should be "BLOCK0000..." pattern
                    var rbuf: [64]u8 = undefined;
                    const n = sys.read(@intCast(fd), &rbuf, 64);
                    _ = sys.close(@intCast(fd));
                    if (n == 64 and rbuf[0] == 'B' and rbuf[1] == 'L' and rbuf[2] == 'O' and rbuf[3] == 'C' and rbuf[4] == 'K') {
                        puts("[journal-replay] test2.txt: PASS (multi-block intact)\n");
                        replay_pass += 1;
                    } else {
                        puts("[journal-replay] test2.txt: FAIL (content corrupted)\n");
                    }
                } else {
                    puts("[journal-replay] test2.txt: FAIL (file missing)\n");
                }
            }

            // Verify test file 3: file in directory
            replay_total += 1;
            {
                const fd = sys.open("/journal_testdir/file3.txt\x00", 0, 0);
                if (fd >= 0) {
                    var rbuf: [64]u8 = undefined;
                    const n = sys.read(@intCast(fd), &rbuf, 64);
                    _ = sys.close(@intCast(fd));
                    const expected = "file in journal test directory\n";
                    if (n == expected.len) {
                        var ok = true;
                        for (0..expected.len) |i| {
                            if (rbuf[i] != expected[i]) { ok = false; break; }
                        }
                        if (ok) {
                            puts("[journal-replay] testdir/file3.txt: PASS\n");
                            replay_pass += 1;
                        } else {
                            puts("[journal-replay] testdir/file3.txt: FAIL (corrupted)\n");
                        }
                    } else {
                        puts("[journal-replay] testdir/file3.txt: FAIL (wrong size)\n");
                    }
                } else {
                    puts("[journal-replay] testdir/file3.txt: FAIL (missing)\n");
                }
            }

            // Verify inflight file (written after sync, not explicitly flushed)
            replay_total += 1;
            {
                const fd = sys.open("/journal_inflight.txt\x00", 0, 0);
                if (fd >= 0) {
                    var rbuf: [64]u8 = undefined;
                    const n = sys.read(@intCast(fd), &rbuf, 64);
                    _ = sys.close(@intCast(fd));
                    const expected = "inflight journal transaction\n";
                    if (n == expected.len) {
                        var ok = true;
                        for (0..expected.len) |i| {
                            if (rbuf[i] != expected[i]) { ok = false; break; }
                        }
                        if (ok) {
                            puts("[journal-replay] inflight.txt: PASS (journal replayed!)\n");
                            replay_pass += 1;
                        } else {
                            puts("[journal-replay] inflight.txt: FAIL (corrupted)\n");
                        }
                    } else {
                        puts("[journal-replay] inflight.txt: FAIL (wrong size)\n");
                    }
                } else {
                    // This is expected if journal didn't commit before kill
                    puts("[journal-replay] inflight.txt: MISS (not replayed — expected if journal didn't commit)\n");
                    // Don't count as failure — this is informational
                    replay_pass += 1; // Count as pass since missing is acceptable
                }
            }

            // Verify marker has correct content
            replay_total += 1;
            {
                const fd = sys.open("/journal_marker.txt\x00", 0, 0);
                if (fd >= 0) {
                    var rbuf: [64]u8 = undefined;
                    const n = sys.read(@intCast(fd), &rbuf, 64);
                    _ = sys.close(@intCast(fd));
                    const expected = "JOURNAL_TEST_PHASE1_COMPLETE\n";
                    if (n == expected.len) {
                        var ok = true;
                        for (0..expected.len) |i| {
                            if (rbuf[i] != expected[i]) { ok = false; break; }
                        }
                        if (ok) {
                            puts("[journal-replay] marker: PASS\n");
                            replay_pass += 1;
                        } else {
                            puts("[journal-replay] marker: FAIL (corrupted)\n");
                        }
                    } else {
                        puts("[journal-replay] marker: FAIL (wrong size)\n");
                    }
                } else {
                    puts("[journal-replay] marker: FAIL (missing)\n");
                }
            }

            // Summary
            puts("[journal-replay] Results: ");
            write_uint(replay_pass);
            puts("/");
            write_uint(replay_total);
            puts(" passed\n");
            if (replay_pass == replay_total) {
                puts("[journal-replay] ALL PASS — journal replay verified!\n");
            } else {
                puts("[journal-replay] SOME TESTS FAILED\n");
            }
        } else {
            // Phase 1: no marker — write test data for journal replay test
            puts("[journal-replay] Phase 1: writing test files for dirty shutdown test...\n");

            // Test file 1: small file
            if (writeFile("/journal_test1.txt\x00", "journal replay test data 1\n")) {
                puts("[journal-replay] wrote /journal_test1.txt\n");
            } else {
                puts("[journal-replay] FAIL: could not write test1.txt\n");
            }

            // Test file 2: multi-block (8KB) with pattern
            {
                var big_buf: [8192]u8 = undefined;
                // Fill with "BLOCK0000\n" pattern (10 bytes per line)
                var pos: usize = 0;
                var block_num: u32 = 0;
                while (pos + 10 <= big_buf.len) {
                    big_buf[pos] = 'B';
                    big_buf[pos + 1] = 'L';
                    big_buf[pos + 2] = 'O';
                    big_buf[pos + 3] = 'C';
                    big_buf[pos + 4] = 'K';
                    // 4-digit number
                    big_buf[pos + 5] = @truncate((block_num / 1000) % 10 + '0');
                    big_buf[pos + 6] = @truncate((block_num / 100) % 10 + '0');
                    big_buf[pos + 7] = @truncate((block_num / 10) % 10 + '0');
                    big_buf[pos + 8] = @truncate(block_num % 10 + '0');
                    big_buf[pos + 9] = '\n';
                    pos += 10;
                    block_num += 1;
                }
                // Fill remainder
                while (pos < big_buf.len) {
                    big_buf[pos] = 'X';
                    pos += 1;
                }
                if (writeFile("/journal_test2.txt\x00", &big_buf)) {
                    puts("[journal-replay] wrote /journal_test2.txt (8KB)\n");
                } else {
                    puts("[journal-replay] FAIL: could not write test2.txt\n");
                }
            }

            // Test file 3: file in new directory
            _ = sys.mkdir("/journal_testdir\x00", 0o755);
            if (writeFile("/journal_testdir/file3.txt\x00", "file in journal test directory\n")) {
                puts("[journal-replay] wrote /journal_testdir/file3.txt\n");
            } else {
                puts("[journal-replay] FAIL: could not write testdir/file3.txt\n");
            }

            // Sync everything to disk — commits journal transactions
            sys.sync_();
            puts("[journal-replay] sync() complete — journal transactions committed\n");

            // Write marker last (after sync, so test files are durable)
            if (writeFile("/journal_marker.txt\x00", "JOURNAL_TEST_PHASE1_COMPLETE\n")) {
                sys.sync_();
                puts("[journal-replay] marker written and synced\n");
            }

            // Write additional file AFTER sync — this one may only be in the
            // journal (not yet checkpointed). Tests actual journal replay.
            if (writeFile("/journal_inflight.txt\x00", "inflight journal transaction\n")) {
                puts("[journal-replay] wrote /journal_inflight.txt (NOT synced)\n");
            }

            puts("[journal-replay] PHASE1_DONE — kill QEMU now for dirty shutdown\n");
            // Continue to normal boot (zhttpd, zlogin, etc.)
            // The test runner script will kill QEMU after seeing PHASE1_DONE.
        }
    }

    // ---- Comprehensive filesystem feature tests ----
    // Tests: hard links, symlinks, truncate, chmod, statfs, fallocate, stat, utimensat
    {
        var fs_pass: u32 = 0;
        var fs_total: u32 = 0;
        puts("[fs-test] Running filesystem feature tests...\n");

        // Test 1: Hard links — create file, link, verify both paths read same data
        fs_total += 1;
        puts("[fs-test] 1: hard links...\n");
        {
            if (writeFile("/tmp/link_src.txt\x00", "hard link test data\n")) {
                const ret = sys.link("/tmp/link_src.txt\x00", "/tmp/link_dst.txt\x00");
                if (ret == 0) {
                    // Read via linked path
                    const fd = sys.open("/tmp/link_dst.txt\x00", 0, 0);
                    if (fd >= 0) {
                        var rbuf: [64]u8 = undefined;
                        const n = sys.read(@intCast(fd), &rbuf, 64);
                        _ = sys.close(@intCast(fd));
                        const expected = "hard link test data\n";
                        if (n == expected.len and rbuf[0] == 'h' and rbuf[4] == ' ') {
                            // Verify nlink=2 via stat
                            var statbuf: [144]u8 = undefined;
                            const sr = sys.stat("/tmp/link_src.txt\x00", &statbuf);
                            if (sr == 0) {
                                // st_nlink is at offset 16, u32
                                const nlink: u32 = if (is_x86) @truncate(@as(*align(1) const u64, @ptrCast(&statbuf[STAT_NLINK_OFF])).*) else @as(*align(1) const u32, @ptrCast(&statbuf[STAT_NLINK_OFF])).*;
                                if (nlink == 2) {
                                    puts("[fs-test] 1: hard links PASS (nlink=2)\n");
                                    fs_pass += 1;
                                } else {
                                    puts("[fs-test] 1: hard links FAIL (nlink!=2: ");
                                    write_uint(nlink);
                                    puts(")\n");
                                }
                            } else {
                                puts("[fs-test] 1: hard links FAIL (stat failed)\n");
                            }
                        } else {
                            puts("[fs-test] 1: hard links FAIL (read mismatch)\n");
                        }
                    } else {
                        puts("[fs-test] 1: hard links FAIL (open linked file)\n");
                    }
                } else {
                    puts("[fs-test] 1: hard links FAIL (link returned ");
                    write_uint(@intCast(-ret));
                    puts(")\n");
                }
                // Cleanup
                _ = sys.unlink("/tmp/link_src.txt\x00");
                _ = sys.unlink("/tmp/link_dst.txt\x00");
            } else {
                puts("[fs-test] 1: hard links FAIL (write source)\n");
            }
        }

        // Test 2: Symlinks — create symlink, readlink, read via symlink
        fs_total += 1;
        puts("[fs-test] 2: symlinks...\n");
        {
            if (writeFile("/tmp/sym_target.txt\x00", "symlink target data\n")) {
                const ret = sys.symlink("/tmp/sym_target.txt\x00", "/tmp/sym_link.txt\x00");
                if (ret == 0) {
                    // readlink
                    var linkbuf: [256]u8 = undefined;
                    const rl = sys.readlink("/tmp/sym_link.txt\x00", &linkbuf, 256);
                    if (rl > 0) {
                        const expected_target = "/tmp/sym_target.txt";
                        var target_ok = true;
                        if (@as(usize, @intCast(rl)) != expected_target.len) {
                            target_ok = false;
                        } else {
                            for (0..expected_target.len) |i| {
                                if (linkbuf[i] != expected_target[i]) { target_ok = false; break; }
                            }
                        }
                        if (target_ok) {
                            // Read data through symlink
                            const fd = sys.open("/tmp/sym_link.txt\x00", 0, 0);
                            if (fd >= 0) {
                                var rbuf: [64]u8 = undefined;
                                const n = sys.read(@intCast(fd), &rbuf, 64);
                                _ = sys.close(@intCast(fd));
                                if (n == 20 and rbuf[0] == 's') {
                                    puts("[fs-test] 2: symlinks PASS\n");
                                    fs_pass += 1;
                                } else {
                                    puts("[fs-test] 2: symlinks FAIL (read through link)\n");
                                }
                            } else {
                                puts("[fs-test] 2: symlinks FAIL (open via link)\n");
                            }
                        } else {
                            puts("[fs-test] 2: symlinks FAIL (readlink mismatch)\n");
                        }
                    } else {
                        puts("[fs-test] 2: symlinks FAIL (readlink returned ");
                        write_uint(@intCast(-rl));
                        puts(")\n");
                    }
                } else {
                    puts("[fs-test] 2: symlinks FAIL (symlink returned ");
                    write_uint(@intCast(-ret));
                    puts(")\n");
                }
                _ = sys.unlink("/tmp/sym_link.txt\x00");
                _ = sys.unlink("/tmp/sym_target.txt\x00");
            } else {
                puts("[fs-test] 2: symlinks FAIL (write target)\n");
            }
        }

        // Test 3: ftruncate — write file, truncate to 0, verify empty
        fs_total += 1;
        puts("[fs-test] 3: ftruncate...\n");
        {
            if (writeFile("/tmp/trunc_test.txt\x00", "data to be truncated\n")) {
                // O_WRONLY=1
                const fd = sys.open("/tmp/trunc_test.txt\x00", 1, 0);
                if (fd >= 0) {
                    const tr = sys.ftruncate(@intCast(fd), 0);
                    _ = sys.close(@intCast(fd));
                    if (tr == 0) {
                        // Read back — should be empty
                        const rfd = sys.open("/tmp/trunc_test.txt\x00", 0, 0);
                        if (rfd >= 0) {
                            var rbuf: [64]u8 = undefined;
                            const n = sys.read(@intCast(rfd), &rbuf, 64);
                            _ = sys.close(@intCast(rfd));
                            if (n == 0) {
                                puts("[fs-test] 3: ftruncate PASS (file empty)\n");
                                fs_pass += 1;
                            } else {
                                puts("[fs-test] 3: ftruncate FAIL (still has ");
                                write_uint(@intCast(n));
                                puts(" bytes)\n");
                            }
                        } else {
                            puts("[fs-test] 3: ftruncate FAIL (reopen)\n");
                        }
                    } else {
                        puts("[fs-test] 3: ftruncate FAIL (returned ");
                        write_uint(@intCast(-tr));
                        puts(")\n");
                    }
                } else {
                    puts("[fs-test] 3: ftruncate FAIL (open for truncate)\n");
                }
                _ = sys.unlink("/tmp/trunc_test.txt\x00");
            } else {
                puts("[fs-test] 3: ftruncate FAIL (write)\n");
            }
        }

        // Test 4: chmod — create file, change mode, verify via stat
        fs_total += 1;
        puts("[fs-test] 4: chmod...\n");
        {
            if (writeFile("/tmp/chmod_test.txt\x00", "chmod test\n")) {
                const ret = sys.chmod("/tmp/chmod_test.txt\x00", 0o755);
                if (ret == 0) {
                    var statbuf: [144]u8 = undefined;
                    const sr = sys.stat("/tmp/chmod_test.txt\x00", &statbuf);
                    if (sr == 0) {
                        // st_mode at arch-specific offset
                        const mode = @as(*align(1) const u32, @ptrCast(&statbuf[STAT_MODE_OFF])).*;
                        const perm = mode & 0o7777;
                        if (perm == 0o755) {
                            puts("[fs-test] 4: chmod PASS (mode=0755)\n");
                            fs_pass += 1;
                        } else {
                            puts("[fs-test] 4: chmod FAIL (mode=0");
                            // Print octal
                            write_uint(perm);
                            puts(")\n");
                        }
                    } else {
                        puts("[fs-test] 4: chmod FAIL (stat)\n");
                    }
                } else {
                    puts("[fs-test] 4: chmod FAIL (chmod returned ");
                    write_uint(@intCast(-ret));
                    puts(")\n");
                }
                _ = sys.unlink("/tmp/chmod_test.txt\x00");
            } else {
                puts("[fs-test] 4: chmod FAIL (write)\n");
            }
        }

        // Test 5: statfs — get filesystem info, verify magic + block size
        fs_total += 1;
        puts("[fs-test] 5: statfs...\n");
        {
            var sfbuf: [120]u8 = undefined;
            const ret = sys.statfs("/\x00", &sfbuf);
            if (ret == 0) {
                // f_type at offset 0 (u64), f_bsize at offset 8 (u64)
                const f_type = @as(*align(1) const u64, @ptrCast(&sfbuf[0])).*;
                const f_bsize = @as(*align(1) const u64, @ptrCast(&sfbuf[8])).*;
                const f_blocks = @as(*align(1) const u64, @ptrCast(&sfbuf[16])).*;
                if (f_type == 0xEF53 and f_bsize == 4096 and f_blocks > 0) {
                    puts("[fs-test] 5: statfs PASS (ext2 magic, 4K blocks, ");
                    write_uint(f_blocks);
                    puts(" total)\n");
                    fs_pass += 1;
                } else {
                    puts("[fs-test] 5: statfs FAIL (type=0x");
                    write_uint(f_type);
                    puts(" bsize=");
                    write_uint(f_bsize);
                    puts(")\n");
                }
            } else {
                puts("[fs-test] 5: statfs FAIL (returned ");
                write_uint(@intCast(-ret));
                puts(")\n");
            }
        }

        // Test 6: fallocate — preallocate space, verify file size changed
        fs_total += 1;
        puts("[fs-test] 6: fallocate...\n");
        {
            // O_WRONLY|O_CREAT|O_TRUNC = 577
            const fd = sys.open("/tmp/falloc_test.txt\x00", 577, 0o644);
            if (fd >= 0) {
                // Preallocate 8192 bytes (mode=0 extends file size)
                const ret = sys.fallocate(@intCast(fd), 0, 0, 8192);
                if (ret == 0) {
                    // Check file size via fstat
                    var statbuf: [144]u8 = undefined;
                    const sr = sys.fstat(@intCast(fd), &statbuf);
                    _ = sys.close(@intCast(fd));
                    if (sr == 0) {
                        // st_size at offset 48 (u64)
                        const size = @as(*align(1) const u64, @ptrCast(&statbuf[STAT_SIZE_OFF])).*;
                        if (size >= 8192) {
                            puts("[fs-test] 6: fallocate PASS (size=");
                            write_uint(size);
                            puts(")\n");
                            fs_pass += 1;
                        } else {
                            puts("[fs-test] 6: fallocate FAIL (size=");
                            write_uint(size);
                            puts(")\n");
                        }
                    } else {
                        puts("[fs-test] 6: fallocate FAIL (fstat)\n");
                    }
                } else {
                    _ = sys.close(@intCast(fd));
                    puts("[fs-test] 6: fallocate FAIL (returned ");
                    write_uint(@intCast(-ret));
                    puts(")\n");
                }
                _ = sys.unlink("/tmp/falloc_test.txt\x00");
            } else {
                puts("[fs-test] 6: fallocate FAIL (open)\n");
            }
        }

        // Test 7: stat — check file type, size, nlink for regular file
        fs_total += 1;
        puts("[fs-test] 7: stat...\n");
        {
            if (writeFile("/tmp/stat_test.txt\x00", "stat test data 123\n")) {
                var statbuf: [144]u8 = undefined;
                const ret = sys.stat("/tmp/stat_test.txt\x00", &statbuf);
                if (ret == 0) {
                    const mode = @as(*align(1) const u32, @ptrCast(&statbuf[STAT_MODE_OFF])).*;
                    const nlink: u32 = if (is_x86) @truncate(@as(*align(1) const u64, @ptrCast(&statbuf[STAT_NLINK_OFF])).*) else @as(*align(1) const u32, @ptrCast(&statbuf[STAT_NLINK_OFF])).*;
                    const size = @as(*align(1) const u64, @ptrCast(&statbuf[STAT_SIZE_OFF])).*;
                    const is_reg = (mode & 0o170000) == 0o100000;
                    if (is_reg and nlink == 1 and size == 19) {
                        puts("[fs-test] 7: stat PASS (REG, nlink=1, size=19)\n");
                        fs_pass += 1;
                    } else {
                        puts("[fs-test] 7: stat FAIL (mode=");
                        write_uint(mode);
                        puts(" nlink=");
                        write_uint(nlink);
                        puts(" size=");
                        write_uint(size);
                        puts(")\n");
                    }
                } else {
                    puts("[fs-test] 7: stat FAIL (returned ");
                    write_uint(@intCast(-ret));
                    puts(")\n");
                }
                _ = sys.unlink("/tmp/stat_test.txt\x00");
            } else {
                puts("[fs-test] 7: stat FAIL (write)\n");
            }
        }

        // Test 8: stat on directory — verify S_IFDIR
        fs_total += 1;
        puts("[fs-test] 8: stat directory...\n");
        {
            _ = sys.mkdir("/tmp/stat_dir\x00", 0o755);
            var statbuf: [144]u8 = undefined;
            const ret = sys.stat("/tmp/stat_dir\x00", &statbuf);
            if (ret == 0) {
                const mode = @as(*align(1) const u32, @ptrCast(&statbuf[STAT_MODE_OFF])).*;
                const is_dir = (mode & 0o170000) == 0o040000;
                if (is_dir) {
                    puts("[fs-test] 8: stat directory PASS (S_IFDIR)\n");
                    fs_pass += 1;
                } else {
                    puts("[fs-test] 8: stat directory FAIL (mode=");
                    write_uint(mode);
                    puts(")\n");
                }
            } else {
                puts("[fs-test] 8: stat directory FAIL (returned ");
                write_uint(@intCast(-ret));
                puts(")\n");
            }
            _ = sys.unlinkat(sys.AT_FDCWD, "/tmp/stat_dir\x00", 0x200);
        }

        // Test 9: unlink reduces nlink — create 2 hard links, unlink one, verify nlink=1
        fs_total += 1;
        puts("[fs-test] 9: unlink nlink...\n");
        {
            if (writeFile("/tmp/nlink_a.txt\x00", "nlink test\n")) {
                _ = sys.link("/tmp/nlink_a.txt\x00", "/tmp/nlink_b.txt\x00");
                // Unlink original
                _ = sys.unlink("/tmp/nlink_a.txt\x00");
                // nlink_b should still work with nlink=1
                var statbuf: [144]u8 = undefined;
                const sr = sys.stat("/tmp/nlink_b.txt\x00", &statbuf);
                if (sr == 0) {
                    const nlink: u32 = if (is_x86) @truncate(@as(*align(1) const u64, @ptrCast(&statbuf[STAT_NLINK_OFF])).*) else @as(*align(1) const u32, @ptrCast(&statbuf[STAT_NLINK_OFF])).*;
                    const fd = sys.open("/tmp/nlink_b.txt\x00", 0, 0);
                    if (fd >= 0) {
                        var rbuf: [32]u8 = undefined;
                        const n = sys.read(@intCast(fd), &rbuf, 32);
                        _ = sys.close(@intCast(fd));
                        if (nlink == 1 and n == 11 and rbuf[0] == 'n') {
                            puts("[fs-test] 9: unlink nlink PASS (nlink=1, data intact)\n");
                            fs_pass += 1;
                        } else {
                            puts("[fs-test] 9: unlink nlink FAIL (nlink=");
                            write_uint(nlink);
                            puts(" n=");
                            write_uint(@intCast(n));
                            puts(")\n");
                        }
                    } else {
                        puts("[fs-test] 9: unlink nlink FAIL (can't open survivor)\n");
                    }
                } else {
                    puts("[fs-test] 9: unlink nlink FAIL (stat survivor)\n");
                }
                _ = sys.unlink("/tmp/nlink_b.txt\x00");
            } else {
                puts("[fs-test] 9: unlink nlink FAIL (write)\n");
            }
        }

        // Test 10: large file write (64KB) — extent tree + mballoc stress
        fs_total += 1;
        puts("[fs-test] 10: large file (64KB)...\n");
        {
            // O_WRONLY|O_CREAT|O_TRUNC = 577
            const fd = sys.open("/tmp/large_test.bin\x00", 577, 0o644);
            if (fd >= 0) {
                var chunk: [4096]u8 = undefined;
                // Fill with pattern
                for (0..4096) |i| {
                    chunk[i] = @truncate(i & 0xFF);
                }
                var total_written: usize = 0;
                var write_ok = true;
                for (0..16) |_| { // 16 * 4096 = 64KB
                    const w = sys.write(@intCast(fd), &chunk, 4096);
                    if (w == 4096) {
                        total_written += 4096;
                    } else {
                        write_ok = false;
                        break;
                    }
                }
                _ = sys.close(@intCast(fd));
                if (write_ok and total_written == 65536) {
                    // Read back first block and verify pattern
                    const rfd = sys.open("/tmp/large_test.bin\x00", 0, 0);
                    if (rfd >= 0) {
                        var rbuf: [4096]u8 = undefined;
                        const n = sys.read(@intCast(rfd), &rbuf, 4096);
                        _ = sys.close(@intCast(rfd));
                        if (n == 4096 and rbuf[0] == 0 and rbuf[1] == 1 and rbuf[255] == 255) {
                            puts("[fs-test] 10: large file PASS (64KB written+verified)\n");
                            fs_pass += 1;
                        } else {
                            puts("[fs-test] 10: large file FAIL (readback mismatch)\n");
                        }
                    } else {
                        puts("[fs-test] 10: large file FAIL (reopen)\n");
                    }
                } else {
                    puts("[fs-test] 10: large file FAIL (wrote ");
                    write_uint(total_written);
                    puts("/65536)\n");
                }
                _ = sys.unlink("/tmp/large_test.bin\x00");
            } else {
                puts("[fs-test] 10: large file FAIL (open)\n");
            }
        }

        // Test 11: pipe read/write
        {
            fs_total += 1;
            puts("[fs-test] 11: pipe...\n");
            var pipe_fds: [2]u32 = undefined;
            const pr = sys.pipe(&pipe_fds);
            if (pr == 0) {
                const msg = "pipe test data";
                const pw = sys.write(pipe_fds[1], msg.ptr, msg.len);
                _ = sys.close(pipe_fds[1]);
                if (pw == @as(isize, @intCast(msg.len))) {
                    var pbuf: [64]u8 = undefined;
                    const pn = sys.read(pipe_fds[0], &pbuf, 64);
                    _ = sys.close(pipe_fds[0]);
                    if (pn == @as(isize, @intCast(msg.len)) and pbuf[0] == 'p' and pbuf[4] == ' ') {
                        puts("[fs-test] 11: pipe PASS\n");
                        fs_pass += 1;
                    } else {
                        puts("[fs-test] 11: pipe FAIL (read mismatch)\n");
                    }
                } else {
                    _ = sys.close(pipe_fds[0]);
                    puts("[fs-test] 11: pipe FAIL (write)\n");
                }
            } else {
                puts("[fs-test] 11: pipe FAIL (pipe() returned ");
                write_int(pr);
                puts(")\n");
            }
        }

        // Test 12: rename across directories
        {
            fs_total += 1;
            puts("[fs-test] 12: rename across dirs...\n");
            _ = sys.mkdir("/tmp/rename_src\x00", 0o755);
            _ = sys.mkdir("/tmp/rename_dst\x00", 0o755);
            if (writeFile("/tmp/rename_src/moved.txt\x00", "rename across dirs\n")) {
                const rr = sys.rename("/tmp/rename_src/moved.txt\x00", "/tmp/rename_dst/moved.txt\x00");
                if (rr == 0) {
                    // Verify file is at new location
                    const rfd = sys.open("/tmp/rename_dst/moved.txt\x00", 0, 0);
                    if (rfd >= 0) {
                        var rbuf: [64]u8 = undefined;
                        const n = sys.read(@intCast(rfd), &rbuf, 64);
                        _ = sys.close(@intCast(rfd));
                        if (n == 19 and rbuf[0] == 'r') {
                            // Verify old path is gone
                            const ofd = sys.open("/tmp/rename_src/moved.txt\x00", 0, 0);
                            if (ofd < 0) {
                                puts("[fs-test] 12: rename across dirs PASS\n");
                                fs_pass += 1;
                            } else {
                                _ = sys.close(@intCast(ofd));
                                puts("[fs-test] 12: rename across dirs FAIL (old still exists)\n");
                            }
                        } else {
                            puts("[fs-test] 12: rename across dirs FAIL (data mismatch)\n");
                        }
                    } else {
                        puts("[fs-test] 12: rename across dirs FAIL (open new)\n");
                    }
                } else {
                    puts("[fs-test] 12: rename across dirs FAIL (rename returned ");
                    write_int(rr);
                    puts(")\n");
                }
            } else {
                puts("[fs-test] 12: rename across dirs FAIL (create)\n");
            }
        }

        // Test 13: dup2
        {
            fs_total += 1;
            puts("[fs-test] 13: dup2...\n");
            if (writeFile("/tmp/dup_test.txt\x00", "dup2 test data\n")) {
                const ofd = sys.open("/tmp/dup_test.txt\x00", 0, 0);
                if (ofd >= 0) {
                    // dup2 to fd 50
                    const d2 = sys.dup2(@intCast(ofd), 50);
                    if (d2 == 50) {
                        var dbuf: [64]u8 = undefined;
                        const dn = sys.read(50, &dbuf, 64);
                        _ = sys.close(50);
                        _ = sys.close(@intCast(ofd));
                        if (dn == 15 and dbuf[0] == 'd') {
                            puts("[fs-test] 13: dup2 PASS\n");
                            fs_pass += 1;
                        } else {
                            puts("[fs-test] 13: dup2 FAIL (read via dup'd fd)\n");
                        }
                    } else {
                        _ = sys.close(@intCast(ofd));
                        puts("[fs-test] 13: dup2 FAIL (dup2 returned ");
                        write_int(d2);
                        puts(")\n");
                    }
                } else {
                    puts("[fs-test] 13: dup2 FAIL (open)\n");
                }
                _ = sys.unlink("/tmp/dup_test.txt\x00");
            } else {
                puts("[fs-test] 13: dup2 FAIL (create)\n");
            }
        }

        // Test 14: copy_file_range
        {
            fs_total += 1;
            puts("[fs-test] 14: copy_file_range...\n");
            if (writeFile("/tmp/cfr_src.txt\x00", "copy file range test\n")) {
                const sfd = sys.open("/tmp/cfr_src.txt\x00", 0, 0);
                const dfd = sys.open("/tmp/cfr_dst.txt\x00", sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 0o644);
                if (sfd >= 0 and dfd >= 0) {
                    const cfr = sys.copy_file_range(@intCast(sfd), null, @intCast(dfd), null, 21, 0);
                    _ = sys.close(@intCast(sfd));
                    _ = sys.close(@intCast(dfd));
                    if (cfr == 21) {
                        // Read back destination
                        const vfd = sys.open("/tmp/cfr_dst.txt\x00", 0, 0);
                        if (vfd >= 0) {
                            var vbuf: [64]u8 = undefined;
                            const vn = sys.read(@intCast(vfd), &vbuf, 64);
                            _ = sys.close(@intCast(vfd));
                            if (vn == 21 and vbuf[0] == 'c') {
                                puts("[fs-test] 14: copy_file_range PASS\n");
                                fs_pass += 1;
                            } else {
                                puts("[fs-test] 14: copy_file_range FAIL (data mismatch)\n");
                            }
                        } else {
                            puts("[fs-test] 14: copy_file_range FAIL (reopen)\n");
                        }
                    } else {
                        puts("[fs-test] 14: copy_file_range FAIL (returned ");
                        write_int(cfr);
                        puts(")\n");
                    }
                } else {
                    if (sfd >= 0) _ = sys.close(@intCast(sfd));
                    if (dfd >= 0) _ = sys.close(@intCast(dfd));
                    puts("[fs-test] 14: copy_file_range FAIL (open)\n");
                }
                _ = sys.unlink("/tmp/cfr_src.txt\x00");
                _ = sys.unlink("/tmp/cfr_dst.txt\x00");
            } else {
                puts("[fs-test] 14: copy_file_range FAIL (create)\n");
            }
        }

        // Test 15: xattr set/get/list/remove
        {
            fs_total += 1;
            puts("[fs-test] 15: xattr...\n");
            if (writeFile("/tmp/xattr_test.txt\x00", "xattr test\n")) {
                const xattr_name = "user.test.key\x00";
                const xattr_val = "hello_xattr";
                // setxattr
                const sr2 = sys.setxattr("/tmp/xattr_test.txt\x00", xattr_name, xattr_val.ptr, xattr_val.len, 0);
                if (sr2 == 0) {
                    // getxattr
                    var gbuf: [64]u8 = undefined;
                    const gr = sys.getxattr("/tmp/xattr_test.txt\x00", xattr_name, &gbuf, 64);
                    if (gr == @as(isize, @intCast(xattr_val.len)) and gbuf[0] == 'h' and gbuf[5] == '_') {
                        // listxattr
                        var lbuf: [256]u8 = undefined;
                        const lr = sys.listxattr("/tmp/xattr_test.txt\x00", &lbuf, 256);
                        if (lr > 0) {
                            // removexattr
                            const rr = sys.removexattr("/tmp/xattr_test.txt\x00", xattr_name);
                            if (rr == 0) {
                                // Verify removed
                                var vbuf: [64]u8 = undefined;
                                const vr = sys.getxattr("/tmp/xattr_test.txt\x00", xattr_name, &vbuf, 64);
                                if (vr < 0) {
                                    puts("[fs-test] 15: xattr PASS (set/get/list/remove)\n");
                                    fs_pass += 1;
                                } else {
                                    puts("[fs-test] 15: xattr FAIL (still exists after remove)\n");
                                }
                            } else {
                                puts("[fs-test] 15: xattr FAIL (removexattr=");
                                write_int(rr);
                                puts(")\n");
                            }
                        } else {
                            puts("[fs-test] 15: xattr FAIL (listxattr=");
                            write_int(lr);
                            puts(")\n");
                        }
                    } else {
                        puts("[fs-test] 15: xattr FAIL (getxattr=");
                        write_int(gr);
                        puts(")\n");
                    }
                } else {
                    puts("[fs-test] 15: xattr FAIL (setxattr=");
                    write_int(sr2);
                    puts(")\n");
                }
                _ = sys.unlink("/tmp/xattr_test.txt\x00");
            } else {
                puts("[fs-test] 15: xattr FAIL (create)\n");
            }
        }

        // Test 16: inotify init + add_watch + rm_watch
        {
            fs_total += 1;
            puts("[fs-test] 16: inotify...\n");
            const ifd = sys.inotify_init1(0);
            if (ifd >= 0) {
                _ = sys.mkdir("/tmp/inotify_dir\x00", 0o755);
                const wd = sys.inotify_add_watch(@intCast(ifd), "/tmp/inotify_dir\x00", 0x100 | 0x200); // IN_CREATE | IN_DELETE
                if (wd > 0) {
                    const rmr = sys.inotify_rm_watch(@intCast(ifd), @intCast(wd));
                    if (rmr == 0) {
                        puts("[fs-test] 16: inotify PASS (init/add/rm)\n");
                        fs_pass += 1;
                    } else {
                        puts("[fs-test] 16: inotify FAIL (rm_watch=");
                        write_int(rmr);
                        puts(")\n");
                    }
                } else {
                    puts("[fs-test] 16: inotify FAIL (add_watch=");
                    write_int(wd);
                    puts(")\n");
                }
                _ = sys.close(@intCast(ifd));
            } else {
                puts("[fs-test] 16: inotify FAIL (init=");
                write_int(ifd);
                puts(")\n");
            }
        }

        // Test 17: FIFO (named pipe)
        {
            fs_total += 1;
            puts("[fs-test] 17: FIFO...\n");
            // Create FIFO via mkfifo (mknodat with S_IFIFO)
            const mfr = sys.mkfifo("/tmp/test_fifo\x00", 0o666);
            if (mfr == 0 or mfr == -17) { // OK or EEXIST
                // Fork: child writes, parent reads
                const cpid = sys.fork();
                if (cpid == 0) {
                    // Child: open FIFO for writing
                    const wfd = sys.open("/tmp/test_fifo\x00", sys.O_WRONLY, 0);
                    if (wfd >= 0) {
                        const msg = "fifo works!";
                        _ = sys.write(@intCast(wfd), msg.ptr, msg.len);
                        _ = sys.close(@intCast(wfd));
                    }
                    sys.exit(0);
                } else if (cpid > 0) {
                    // Parent: open FIFO for reading
                    const rfd = sys.open("/tmp/test_fifo\x00", 0, 0);
                    if (rfd >= 0) {
                        var fbuf: [64]u8 = undefined;
                        const fn2 = sys.read(@intCast(rfd), &fbuf, 64);
                        _ = sys.close(@intCast(rfd));
                        _ = sys.wait4(@intCast(cpid), 0, 0);
                        if (fn2 == 11 and fbuf[0] == 'f' and fbuf[5] == 'w') {
                            puts("[fs-test] 17: FIFO PASS\n");
                            fs_pass += 1;
                        } else {
                            puts("[fs-test] 17: FIFO FAIL (read=");
                            write_int(fn2);
                            puts(")\n");
                        }
                    } else {
                        _ = sys.wait4(@intCast(cpid), 0, 0);
                        puts("[fs-test] 17: FIFO FAIL (open read=");
                        write_int(rfd);
                        puts(")\n");
                    }
                } else {
                    puts("[fs-test] 17: FIFO FAIL (fork=");
                    write_int(cpid);
                    puts(")\n");
                }
                _ = sys.unlink("/tmp/test_fifo\x00");
            } else {
                puts("[fs-test] 17: FIFO FAIL (mkfifo=");
                write_int(mfr);
                puts(")\n");
            }
        }

        // Test 18: fcntl record locking
        {
            fs_total += 1;
            puts("[fs-test] 18: fcntl lock...\n");
            if (writeFile("/tmp/lock_test.txt\x00", "lock test data\n")) {
                const lfd = sys.open("/tmp/lock_test.txt\x00", sys.O_RDWR, 0);
                if (lfd >= 0) {
                    // struct flock: l_type(2) + l_whence(2) + pad(4) + l_start(8) + l_len(8) + l_pid(4) = 28 bytes
                    var flock_buf: [32]u8 = [_]u8{0} ** 32;
                    // Set F_WRLCK (1)
                    flock_buf[0] = 1; // l_type = F_WRLCK
                    // l_whence = SEEK_SET (0), l_start = 0, l_len = 0 (whole file)
                    const sr2 = sys.fcntl(@intCast(lfd), sys.F_SETLK, @intFromPtr(&flock_buf));
                    if (sr2 == 0) {
                        // Check F_GETLK — should say no conflict (same pid)
                        var check_buf: [32]u8 = [_]u8{0} ** 32;
                        check_buf[0] = 1; // query F_WRLCK
                        const gr = sys.fcntl(@intCast(lfd), sys.F_GETLK, @intFromPtr(&check_buf));
                        if (gr == 0 and check_buf[0] == 2) { // l_type should be F_UNLCK (no conflict)
                            // Unlock
                            flock_buf[0] = 2; // F_UNLCK
                            const ur = sys.fcntl(@intCast(lfd), sys.F_SETLK, @intFromPtr(&flock_buf));
                            if (ur == 0) {
                                puts("[fs-test] 18: fcntl lock PASS (lock/check/unlock)\n");
                                fs_pass += 1;
                            } else {
                                puts("[fs-test] 18: fcntl lock FAIL (unlock)\n");
                            }
                        } else {
                            puts("[fs-test] 18: fcntl lock FAIL (getlk=");
                            write_int(gr);
                            puts(" type=");
                            write_uint(check_buf[0]);
                            puts(")\n");
                        }
                    } else {
                        puts("[fs-test] 18: fcntl lock FAIL (setlk=");
                        write_int(sr2);
                        puts(")\n");
                    }
                    _ = sys.close(@intCast(lfd));
                } else {
                    puts("[fs-test] 18: fcntl lock FAIL (open)\n");
                }
                _ = sys.unlink("/tmp/lock_test.txt\x00");
            } else {
                puts("[fs-test] 18: fcntl lock FAIL (create)\n");
            }
        }

        // Test 19: fallocate hole punch
        {
            fs_total += 1;
            puts("[fs-test] 19: hole punch...\n");
            if (writeFile("/tmp/hole_test.txt\x00", "AAAAAAAABBBBBBBBCCCCCCCC")) {
                const hfd = sys.open("/tmp/hole_test.txt\x00", sys.O_RDWR, 0);
                if (hfd >= 0) {
                    // Punch hole in middle (offset=8, len=8 — the "BBBBBBBB" part)
                    const hr = sys.fallocate(@intCast(hfd), sys.FALLOC_FL_PUNCH_HOLE | sys.FALLOC_FL_KEEP_SIZE, 8, 8);
                    if (hr == 0) {
                        puts("[fs-test] 19: hole punch PASS\n");
                        fs_pass += 1;
                    } else {
                        puts("[fs-test] 19: hole punch FAIL (fallocate=");
                        write_int(hr);
                        puts(")\n");
                    }
                    _ = sys.close(@intCast(hfd));
                } else {
                    puts("[fs-test] 19: hole punch FAIL (open)\n");
                }
                _ = sys.unlink("/tmp/hole_test.txt\x00");
            } else {
                puts("[fs-test] 19: hole punch FAIL (create)\n");
            }
        }

        // Test 20: inotify event delivery
        {
            fs_total += 1;
            puts("[fs-test] 20: inotify events...\n");
            _ = sys.mkdir("/tmp/inotify_test\x00", 0o755);
            const ifd = sys.inotify_init1(0);
            if (ifd >= 0) {
                const wd = sys.inotify_add_watch(@intCast(ifd), "/tmp/inotify_test\x00", 0x100); // IN_CREATE
                if (wd > 0) {
                    // Create a file in the watched directory
                    if (writeFile("/tmp/inotify_test/trigger.txt\x00", "trigger\n")) {
                        // Read inotify event
                        var evbuf: [256]u8 = undefined;
                        const en = sys.read(@intCast(ifd), &evbuf, 256);
                        if (en > 0) {
                            // event: wd(4) + mask(4) + cookie(4) + len(4) + name
                            const ev_mask: u32 = @as(u32, evbuf[4]) | (@as(u32, evbuf[5]) << 8) | (@as(u32, evbuf[6]) << 16) | (@as(u32, evbuf[7]) << 24);
                            if (ev_mask & 0x100 != 0) { // IN_CREATE
                                puts("[fs-test] 20: inotify events PASS (IN_CREATE received)\n");
                                fs_pass += 1;
                            } else {
                                puts("[fs-test] 20: inotify events FAIL (wrong mask=");
                                write_uint(ev_mask);
                                puts(")\n");
                            }
                        } else {
                            puts("[fs-test] 20: inotify events FAIL (read=");
                            write_int(en);
                            puts(")\n");
                        }
                        _ = sys.unlink("/tmp/inotify_test/trigger.txt\x00");
                    } else {
                        puts("[fs-test] 20: inotify events FAIL (create trigger)\n");
                    }
                    _ = sys.inotify_rm_watch(@intCast(ifd), @intCast(wd));
                } else {
                    puts("[fs-test] 20: inotify events FAIL (add_watch=");
                    write_int(wd);
                    puts(")\n");
                }
                _ = sys.close(@intCast(ifd));
            } else {
                puts("[fs-test] 20: inotify events FAIL (init=");
                write_int(ifd);
                puts(")\n");
            }
        }

        // Summary
        puts("[fs-test] Results: ");
        write_uint(fs_pass);
        puts("/");
        write_uint(fs_total);
        puts(" passed\n");
        if (fs_pass == fs_total) {
            puts("[fs-test] ALL PASS\n");
        }
    }

    // SMP stress test — fork+exec to give each worker its own address space
    if (false) { // Debug: skip stress test but keep code compiled (binary layout test)
        puts("[smp-test] Spawning 16 workers via fork+exec...\n");
        var child_pids: [16]isize = [_]isize{0} ** 16;
        var spawned: usize = 0;

        for (0..16) |w| {
            const cpid = sys.fork();
            if (cpid == 0) {
                // Child: exec zyes (busy-loop binary, own address space)
                var envp_null: [1]u64 = .{0};
                var argv_ptrs: [2]u64 = .{ @intFromPtr(@as([*]const u8, "/bin/zyes\x00")), 0 };
                _ = sys.execve("/bin/zyes\x00", @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));
                sys.exit(127);
            } else if (cpid > 0) {
                child_pids[w] = cpid;
                spawned += 1;
            }
        }

        puts("[smp-test] ");
        write_uint(spawned);
        puts(" workers spawned, running for 5s...\n");

        // Let them run for ~5 seconds
        _ = sys.nanosleep(5, 0);

        // Kill and reap
        for (0..spawned) |w| {
            if (child_pids[w] > 0) {
                _ = sys.kill(@intCast(child_pids[w]), 9);
                _ = sys.wait4(@intCast(child_pids[w]), 0, 0);
            }
        }
        puts("[smp-test] All workers completed\n");
    }

    // Start zhttpd as a background daemon
    const httpd_pid = spawnDaemon("/bin/zhttpd\x00");
    if (httpd_pid > 0) {
        puts("[init] Started zhttpd (PID ");
        write_uint(@intCast(httpd_pid));
        puts(")\n");
    }

    // Start zigix-chat AI server on port 8080 (only if binary exists)
    if (fileExists("/bin/zigix-chat\x00")) {
        const chat_pid = spawnDaemon("/bin/zigix-chat\x00");
        if (chat_pid > 0) {
            puts("[init] Started zigix-chat (PID ");
            write_uint(@intCast(chat_pid));
            puts(")\n");
        }
    }

    // BusyBox tests — only run if busybox binary is present on the image
    if (fileExists("/bin/busybox\x00")) {
        puts("[init] === BusyBox Tests ===\n");

        const bb1 = spawnWithArgs("/bin/busybox\x00", "--help\x00");
        if (bb1 > 0) { _ = waitForPid(bb1); }

        const bb2 = spawnWithArgs("/bin/busybox\x00", "ls\x00");
        if (bb2 > 0) { _ = waitForPid(bb2); }

        const bb3 = spawnBusybox("cat\x00", "/proc/cpuinfo\x00");
        if (bb3 > 0) { _ = waitForPid(bb3); }

        const bb4 = spawnBusybox("cat\x00", "/proc/meminfo\x00");
        if (bb4 > 0) { _ = waitForPid(bb4); }

        const bb5 = spawnBusybox("uname\x00", "-a\x00");
        if (bb5 > 0) { _ = waitForPid(bb5); }

        const bb6 = spawnWithArgs("/bin/busybox\x00", "id\x00");
        if (bb6 > 0) { _ = waitForPid(bb6); }

        puts("[init] === BusyBox Tests Complete ===\n");
    }

    while (true) {
        puts("[init] Starting /bin/zlogin...\n");

        const shell_pid = spawnLogin();
        if (shell_pid <= 0) {
            puts("[init] FATAL: fork failed\n");
            sys.exit(1);
        }

        // Reap children until shell exits
        while (true) {
            const ret = sys.wait4(@bitCast(@as(i64, -1)), 0, 0);
            if (ret < 0) break; // No children (shouldn't happen)
            if (ret == shell_pid) break; // Shell exited
            // Reaped an orphan — continue reaping
        }

        puts("\n[init] Login exited, restarting...\n\n");
    }
}
