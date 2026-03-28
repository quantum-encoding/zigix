/// zgrep -- simple substring filter for Zigix.
/// Reads stdin line-by-line, prints lines containing the search pattern.
/// Architecture-portable: compiles for both x86_64 and aarch64.
/// Usage: zgrep <pattern>

const std = @import("std");
const sys = @import("sys");

// ---- Panic handler (required for freestanding) ----

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    sys.exit(1);
}

// ---- Entry point ----

export fn _start() callconv(.naked) noreturn {
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        // ARM64: kernel places argc/argv on the stack per ELF ABI.
        // Save original SP in x0 (first argument) before calling main.
        asm volatile (
            \\mov x0, sp
            \\mov x29, #0
            \\bl main
            \\1: wfi
            \\b 1b
        );
    } else {
        asm volatile (
            "and $-16, %%rsp\n" ++
                "call main"
            ::: "memory"
        );
    }
}

// ---- Argument extraction ----

/// On x86_64, the kernel places argc, argv[], envp[] on the initial stack
/// (ELF ABI). By the time main() runs, RSP has been aligned and a return
/// address pushed by `call`, so the original stack image is at [rbp+8] if
/// we had a frame pointer -- but since _start is naked we instead read the
/// frame base directly. We use inline asm to grab the stack base pointer
/// that _start received. The `call main` pushed an 8-byte return address,
/// and the function prologue pushed rbp (another 8 bytes), so the original
/// stack image (argc) lives at rbp+16.
///
/// On aarch64, the kernel may not yet pass argc/argv through the stack in
/// Zigix. We fall back to reading from stdin only (no pattern argument) or
/// the kernel places args at a known address. For now, aarch64 extracts
/// args from the stack pointer similarly -- the kernel is expected to place
/// argc at the stack base before _start overwrites SP.
///
/// This function returns null if argument extraction is not available.
fn getArgv(initial_sp: usize) ?struct { argc: usize, argv: [*]const [*]const u8 } {
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        // ARM64: _start saved original SP in x0, passed as initial_sp.
        // Stack layout per ELF ABI: [SP+0]=argc, [SP+8]=argv[0], ...
        if (initial_sp == 0) return null;
        const stack_ptr: [*]const u64 = @ptrFromInt(initial_sp);
        const argc = stack_ptr[0];
        const argv: [*]const [*]const u8 = @ptrFromInt(initial_sp + 8);
        return .{ .argc = argc, .argv = argv };
    } else {
        // x86_64: _start did `and $-16, rsp; call main`. The `call` pushed
        // a return address. main's prologue pushed rbp. So the original
        // stack (argc at top) is at rbp + 16.
        const base: [*]const u64 = asm volatile (""
            : [bp] "={rbp}" (-> [*]const u64),
        );
        const stack_ptr: [*]const u64 = @ptrFromInt(@intFromPtr(base) + 16);
        const argc = stack_ptr[0];
        const argv: [*]const [*]const u8 = @ptrFromInt(@intFromPtr(stack_ptr) + 8);
        return .{ .argc = argc, .argv = argv };
    }
}

// ---- Main ----

export fn main(initial_sp: usize) noreturn {
    const args = getArgv(initial_sp);

    if (args) |a| {
        if (a.argc < 2) {
            puts("Usage: zgrep <pattern>\n");
            sys.exit(1);
        }

        const pattern = a.argv[1];
        const pattern_len = strlen(pattern);
        grepStdin(pattern, pattern_len);
    } else {
        // No argument extraction available (e.g. aarch64 without kernel
        // argc/argv support). Print diagnostic and exit.
        puts("zgrep: argument passing not yet supported on this architecture\n");
        sys.exit(1);
    }

    sys.exit(0);
}

// ---- Core grep logic ----

/// Read stdin line-by-line, printing lines that contain the given pattern.
fn grepStdin(pattern: [*]const u8, pattern_len: usize) void {
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        var byte: [1]u8 = undefined;
        const n = sys.read(0, &byte, 1);
        if (n <= 0) {
            // EOF -- flush last line if non-empty
            if (line_len > 0) {
                if (contains(line_buf[0..line_len], pattern, pattern_len)) {
                    _ = sys.write(1, &line_buf, line_len);
                    _ = sys.write(1, "\n".ptr, 1);
                }
            }
            break;
        }

        if (byte[0] == '\n') {
            // End of line -- check for match
            if (contains(line_buf[0..line_len], pattern, pattern_len)) {
                _ = sys.write(1, &line_buf, line_len);
                _ = sys.write(1, "\n".ptr, 1);
            }
            line_len = 0;
        } else {
            if (line_len < line_buf.len) {
                line_buf[line_len] = byte[0];
                line_len += 1;
            }
        }
    }
}

// ---- String helpers ----

fn strlen(s: [*]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

fn puts(s: []const u8) void {
    _ = sys.write(1, s.ptr, s.len);
}

/// Returns true if haystack contains needle as a substring.
fn contains(haystack: []const u8, needle: [*]const u8, needle_len: usize) bool {
    if (needle_len == 0) return true;
    if (haystack.len < needle_len) return false;
    const limit = haystack.len - needle_len + 1;
    for (0..limit) |i| {
        var match = true;
        for (0..needle_len) |j| {
            if (haystack[i + j] != needle[j]) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
