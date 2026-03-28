/// Zigix shell v1.0 — interactive shell with job control for the Zigix kernel.
/// Architecture-portable: compiles for both x86_64 and aarch64.
/// Builtins: echo, cd, pwd, exit, help, uname, cat, ls, mkdir, rmdir, rm, sync,
///           wc, grep, sort, head, tail, whoami, hostname, export, unset, env,
///           jobs, fg, bg, kill, sh
/// External commands: fork + execve + PATH lookup + wait4
/// 130+ core utilities in /bin/ (zls, zcat, zcp, zmv, zfind, zsed, zawk, ...)
/// Network tools: zping, zcurl, zhttpd, zsshd, zdpdk
/// Pipes: cmd1 | cmd2 | cmd3 (up to 4 stages)
/// Redirection: cmd > file, cmd >> file, cmd < file
/// Chaining: cmd1 ; cmd2, cmd1 && cmd2
/// Background: cmd &
/// Job control: Ctrl-C (SIGINT), Ctrl-Z (SIGTSTP), fg, bg, jobs
/// History: Up/Down arrow keys to browse previous commands

const std = @import("std");
const sys = @import("sys");

// ---- Panic handler (required for freestanding) ----

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    sys.exit(99);
}

// ---- Entry point ----

export fn _start() callconv(.naked) noreturn {
    if (comptime @import("builtin").cpu.arch == .riscv64) {
        asm volatile (
            \\mv a0, sp
            \\andi sp, sp, -16
            \\call main
            \\1: wfi
            \\j 1b
        );
    } else if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile (
            \\mov x0, sp
            \\mov x29, #0
            \\bl main
            \\1: wfi
            \\b 1b
        );
    } else {
        asm volatile (
            "mov %%rsp, %%rdi\n" ++
                "and $-16, %%rsp\n" ++
                "call main"
            ::: "memory"
        );
    }
}

// ---- Terminal / signal helpers ----

// Global aligned buffer for ioctl TIOCSPGRP — avoids CoW/SSE stack issues after fork
var ioctl_pgid_buf: [4]u8 align(4) = undefined;

fn tcsetpgrp(pgid: u64) void {
    const TIOCSPGRP: u64 = 0x5410;
    var v: u32 = @truncate(pgid);
    ioctl_pgid_buf[0] = @truncate(v);
    v >>= 8;
    ioctl_pgid_buf[1] = @truncate(v);
    v >>= 8;
    ioctl_pgid_buf[2] = @truncate(v);
    v >>= 8;
    ioctl_pgid_buf[3] = @truncate(v);
    _ = sys.ioctl(0, TIOCSPGRP, @intFromPtr(&ioctl_pgid_buf));
}

// Sigaction structs as global const — avoids stack-local arrays that trigger
// SSE movaps on misaligned stack after fork (CoW pages cause #GP not #PF).
const sig_dfl_act: [24]u8 = [_]u8{0} ** 24;
const sig_ign_act: [24]u8 = [_]u8{1} ++ [_]u8{0} ** 23;

/// Set signal handler to SIG_IGN (1)
fn ignoreSig(sig: u64) void {
    _ = sys.rt_sigaction(sig, @intFromPtr(&sig_ign_act), 0);
}

/// Set signal handler to SIG_DFL (0)
fn defaultSig(sig: u64) void {
    _ = sys.rt_sigaction(sig, @intFromPtr(&sig_dfl_act), 0);
}

// ---- I/O helpers ----

fn puts(s: []const u8) void {
    _ = sys.write(1, s.ptr, s.len);
}

fn putchar(c: u8) void {
    _ = sys.write(1, @ptrCast(&c), 1);
}

fn write_uint(n: u64) void {
    if (n == 0) {
        putchar('0');
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

// ---- String utilities ----

fn streq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn strlen(s: [*]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

fn containsSubstr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (haystack[i + j] != needle[j]) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn strless(a: []const u8, b: []const u8) bool {
    const min_len = if (a.len < b.len) a.len else b.len;
    for (0..min_len) |i| {
        if (a[i] < b[i]) return true;
        if (a[i] > b[i]) return false;
    }
    return a.len < b.len;
}

// ---- Line reading ----

fn readLine(buf: []u8) usize {
    var pos: usize = 0;
    var browse_idx: usize = history_count;
    var saved_line: [256]u8 = undefined;
    var saved_len: usize = 0;
    var browsing = false;

    while (pos < buf.len - 1) {
        var byte: [1]u8 = undefined;
        const n = sys.read(0, &byte, 1);
        if (n <= 0) continue;

        const c = byte[0];

        // Enter (CR or LF)
        if (c == '\r' or c == '\n') {
            putchar('\n');
            buf[pos] = 0;
            return pos;
        }

        // Backspace (0x7F or 0x08)
        if (c == 0x7F or c == 0x08) {
            if (pos > 0) {
                pos -= 1;
                puts("\x08 \x08");
            }
            continue;
        }

        // Escape sequence (arrow keys)
        if (c == 0x1B) {
            var esc: [1]u8 = undefined;
            if (sys.read(0, &esc, 1) <= 0) continue;
            if (esc[0] != '[') continue;
            if (sys.read(0, &esc, 1) <= 0) continue;

            if (esc[0] == 'A') {
                // Up arrow — previous history
                if (history_count == 0) continue;
                if (!browsing) {
                    for (0..pos) |i| saved_line[i] = buf[i];
                    saved_len = pos;
                    browsing = true;
                    browse_idx = history_count;
                }
                if (browse_idx > 0) {
                    browse_idx -= 1;
                    const entry = historyGet(browse_idx);
                    pos = entry.len;
                    for (0..pos) |i| buf[i] = entry[i];
                    clearAndRedraw(buf[0..pos]);
                }
            } else if (esc[0] == 'B') {
                // Down arrow — next history / restore current
                if (!browsing) continue;
                if (browse_idx < history_count) {
                    browse_idx += 1;
                    if (browse_idx == history_count) {
                        // Restore saved line
                        pos = saved_len;
                        for (0..pos) |i| buf[i] = saved_line[i];
                    } else {
                        const entry = historyGet(browse_idx);
                        pos = entry.len;
                        for (0..pos) |i| buf[i] = entry[i];
                    }
                    clearAndRedraw(buf[0..pos]);
                }
            }
            // Ignore Left/Right/other sequences
            continue;
        }

        // Ignore non-printable (except tab)
        if (c < 0x20 and c != '\t') continue;

        // Regular character — echo and store
        putchar(c);
        buf[pos] = c;
        pos += 1;
        browsing = false;
    }
    buf[pos] = 0;
    return pos;
}

// ---- Command parsing ----

const MAX_ARGS = 16;
const MAX_STAGES = 4;

const Stage = struct {
    argv: [MAX_ARGS][*]const u8,
    argc: usize,
    redir_in: ?[*]const u8, // < file
    redir_out: ?[*]const u8, // > file or >> file
    append: bool, // true for >>
};

fn initStage() Stage {
    return .{
        .argv = undefined,
        .argc = 0,
        .redir_in = null,
        .redir_out = null,
        .append = false,
    };
}

fn parseLine(line: []u8, len: usize, argv: *[MAX_ARGS][*]const u8, argc: *usize) void {
    var i: usize = 0;
    argc.* = 0;

    while (i < len and argc.* < MAX_ARGS) {
        // Skip spaces
        while (i < len and line[i] == ' ') : (i += 1) {}
        if (i >= len) break;

        if (line[i] == '"') {
            // Quoted argument — skip opening quote
            i += 1;
            argv.*[argc.*] = @ptrCast(&line[i]);
            argc.* += 1;
            // Find closing quote
            while (i < len and line[i] != '"') : (i += 1) {}
            if (i < len) {
                line[i] = 0; // NUL-terminate at closing quote
                i += 1;
            }
        } else {
            // Unquoted argument
            argv.*[argc.*] = @ptrCast(&line[i]);
            argc.* += 1;
            while (i < len and line[i] != ' ') : (i += 1) {}
            if (i < len) {
                line[i] = 0;
                i += 1;
            }
        }
    }
}

/// Parse a tokenized line into pipeline stages with redirections.
/// Tokens are already NUL-terminated from parseLine.
fn parsePipeline(argv: [MAX_ARGS][*]const u8, argc: usize, stages: *[MAX_STAGES]Stage, num_stages: *usize) bool {
    num_stages.* = 1;
    stages[0] = initStage();

    var si: usize = 0; // current stage index
    var i: usize = 0;
    while (i < argc) {
        const tok = argSlice(argv[i]);

        if (streq(tok, "|")) {
            if (stages[si].argc == 0) {
                puts("syntax error near '|'\n");
                return false;
            }
            si += 1;
            if (si >= MAX_STAGES) {
                puts("too many pipe stages\n");
                return false;
            }
            stages[si] = initStage();
            num_stages.* = si + 1;
            i += 1;
            continue;
        }

        if (streq(tok, ">")) {
            i += 1;
            if (i >= argc) {
                puts("syntax error: expected filename after '>'\n");
                return false;
            }
            stages[si].redir_out = argv[i];
            stages[si].append = false;
            i += 1;
            continue;
        }

        if (streq(tok, ">>")) {
            i += 1;
            if (i >= argc) {
                puts("syntax error: expected filename after '>>'\n");
                return false;
            }
            stages[si].redir_out = argv[i];
            stages[si].append = true;
            i += 1;
            continue;
        }

        if (streq(tok, "<")) {
            i += 1;
            if (i >= argc) {
                puts("syntax error: expected filename after '<'\n");
                return false;
            }
            stages[si].redir_in = argv[i];
            i += 1;
            continue;
        }

        // Regular argument — add to current stage
        if (stages[si].argc < MAX_ARGS) {
            stages[si].argv[stages[si].argc] = argv[i];
            stages[si].argc += 1;
        }
        i += 1;
    }

    // Validate last stage has a command
    if (stages[si].argc == 0) {
        puts("syntax error: empty command\n");
        return false;
    }

    return true;
}

fn argSlice(ptr: [*]const u8) []const u8 {
    return ptr[0..strlen(ptr)];
}

// ---- Builtins ----

fn builtin_echo(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    var i: usize = 1;
    while (i < argc) : (i += 1) {
        if (i > 1) putchar(' ');
        puts(argSlice(argv[i]));
    }
    putchar('\n');
}

fn builtin_cd(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        _ = sys.chdir("/");
        return;
    }
    const ret = sys.chdir(argv[1]);
    if (ret < 0) {
        puts("cd: no such directory\n");
        last_exit_status = 1;
    }
}

fn builtin_pwd() void {
    var buf: [256]u8 = undefined;
    const ret = sys.getcwd(&buf, 256);
    if (ret >= 0) {
        puts(buf[0..@as(usize, @intCast(ret))]);
        putchar('\n');
    } else {
        puts("/\n"); // Fallback
    }
}

fn builtin_uname() void {
    var buf: [390]u8 = [_]u8{0} ** 390; // 6 * 65 = 390
    const ret = sys.uname(&buf);
    if (ret == 0) {
        // sysname
        puts(buf[0..strlen(@ptrCast(&buf[0]))]);
        putchar(' ');
        // nodename
        puts(buf[65 .. 65 + strlen(@ptrCast(&buf[65]))]);
        putchar(' ');
        // release
        puts(buf[130 .. 130 + strlen(@ptrCast(&buf[130]))]);
        putchar(' ');
        // version
        puts(buf[195 .. 195 + strlen(@ptrCast(&buf[195]))]);
        putchar(' ');
        // machine
        puts(buf[260 .. 260 + strlen(@ptrCast(&buf[260]))]);
        putchar('\n');
    } else {
        puts("Zigix\n");
    }
}

fn builtin_cat(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        puts("cat: missing file operand\n");
        last_exit_status = 1;
        return;
    }
    const fd = sys.open(argv[1], 0, 0); // O_RDONLY
    if (fd < 0) {
        puts("cat: ");
        puts(argSlice(argv[1]));
        puts(": No such file\n");
        last_exit_status = 1;
        return;
    }
    var buf: [512]u8 = undefined;
    while (true) {
        const n = sys.read(@intCast(fd), &buf, 512);
        if (n <= 0) break;
        _ = sys.write(1, &buf, @intCast(n));
    }
    _ = sys.close(@intCast(fd));
}

fn builtin_help() void {
    puts("Zigix shell v1.0 — 113 syscalls, ext2/ext3, TCP/IP networking\n\n");
    puts("Shell builtins:\n");
    puts("  echo [args...]       Print arguments\n");
    puts("  cd [path]            Change directory\n");
    puts("  pwd                  Print working directory\n");
    puts("  cat <file>           Print file contents\n");
    puts("  ls [path]            List directory\n");
    puts("  mkdir <path>         Create directory\n");
    puts("  rmdir <path>         Remove empty directory\n");
    puts("  rm <file>            Remove file\n");
    puts("  wc [-lwc] [file]     Count lines/words/bytes\n");
    puts("  grep <pat> [file]    Search for pattern\n");
    puts("  sort [file]          Sort lines\n");
    puts("  head [-N] [file]     Print first N lines\n");
    puts("  tail [-N] [file]     Print last N lines\n");
    puts("  whoami               Print current user\n");
    puts("  hostname             Print hostname\n");
    puts("  sh <script>          Run script file\n");
    puts("  export KEY=VALUE     Set environment variable\n");
    puts("  unset VAR            Remove environment variable\n");
    puts("  env                  Print all environment variables\n");
    puts("  jobs                 List background/stopped jobs\n");
    puts("  fg [%N]              Resume job in foreground\n");
    puts("  bg [%N]              Resume stopped job in background\n");
    puts("  kill [-SIG] PID      Send signal to process\n");
    puts("  sync                 Flush filesystem to disk\n");
    puts("  uname                System information\n");
    puts("  help                 Show this help\n");
    puts("  exit [code]          Exit shell\n");
    puts("\nExternal commands (/bin/):\n");
    puts("  Files:    zls zcp zmv zln zrm zmkdir zrmdir ztouch zchmod zchown\n");
    puts("            zfind ztree zdu zdf zstat zreadlink zrealpath ztruncate\n");
    puts("  Text:     zcat zhead ztail zsort zuniq zwc zcut ztr zsed zawk\n");
    puts("            zgrep zfold zjoin zpaste znl zfmt zcomm zcsplit ztac\n");
    puts("  Archive:  ztar zgzip zxz zzstd zshred zdd zsplit\n");
    puts("  System:   zps zfree zuptime zusers zwho zid zgroups zdate zuname\n");
    puts("            zsleep ztime ztimeout znproc zhostname zkill znohup\n");
    puts("  Network:  zping zcurl zhttpd zsshd zdpdk\n");
    puts("  Math:     zseq zfactor znumfmt zexpr zbase64 zbase32\n");
    puts("  Misc:     zecho zprintf zyes ztrue zfalse ztest ztee zxargs\n");
    puts("            zenv zprintenv zbasename zdirname zpwd zlogname\n");
    puts("  Bench:    zbench (kernel performance benchmarks)\n");
    puts("\nOperators: | > >> < ; && &\n");
    puts("Job control: Ctrl-C (interrupt), Ctrl-Z (suspend)\n");
    puts("Variables: $VAR or ${VAR} expansion\n");
    puts("Scripts:  /test1.sh  or  sh /test1.sh\n");
    puts("Quoting: \"hello world\" for spaces\n");
}

fn builtin_mkdir(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        puts("mkdir: missing operand\n");
        last_exit_status = 1;
        return;
    }
    const ret = sys.mkdir(argv[1], 0o755);
    if (ret < 0) {
        puts("mkdir: cannot create '");
        puts(argSlice(argv[1]));
        puts("'\n");
        last_exit_status = 1;
    }
}

fn builtin_rm(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        puts("rm: missing operand\n");
        last_exit_status = 1;
        return;
    }
    const ret = sys.unlink(argv[1]);
    if (ret < 0) {
        puts("rm: cannot remove '");
        puts(argSlice(argv[1]));
        puts("'\n");
        last_exit_status = 1;
    }
}

fn builtin_sync() void {
    sys.sync_();
    puts("sync: done\n");
}

// ---- Script execution ----

fn runScriptFile(path: [*]const u8) void {
    const fd = sys.open(path, O_RDONLY, 0);
    if (fd < 0) {
        puts("sh: cannot open '");
        puts(path[0..strlen(path)]);
        puts("'\n");
        last_exit_status = 1;
        return;
    }

    var script_line: [256]u8 = undefined;
    var sline_len: usize = 0;
    var read_buf: [512]u8 = undefined;

    while (true) {
        const n = sys.read(@intCast(fd), &read_buf, 512);
        if (n <= 0) {
            if (sline_len > 0 and script_line[0] != '#') {
                executeScriptLine(script_line[0..sline_len]);
            }
            break;
        }
        const count: usize = @intCast(n);
        for (0..count) |j| {
            if (read_buf[j] == '\n') {
                if (sline_len > 0 and script_line[0] != '#') {
                    executeScriptLine(script_line[0..sline_len]);
                }
                sline_len = 0;
            } else if (sline_len < script_line.len - 1) {
                script_line[sline_len] = read_buf[j];
                sline_len += 1;
            }
        }
    }

    _ = sys.close(@intCast(fd));
}

fn executeScriptLine(line: []const u8) void {
    if (line.len == 0) return;

    // Print the command being executed
    puts("+ ");
    puts(line);
    putchar('\n');

    // Copy to mutable buffer (parseLine inserts NULs)
    var buf: [256]u8 = undefined;
    const len = if (line.len > 255) 255 else line.len;
    for (0..len) |i| {
        buf[i] = line[i];
    }
    buf[len] = 0; // NUL-terminate — parseLine doesn't NUL the last token

    // Split on ';' and execute each segment
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= len) {
        if (i == len or buf[i] == ';') {
            if (i > seg_start) {
                if (i < len) buf[i] = 0; // NUL-terminate at ';'
                executeSegment(buf[seg_start..i]);
            }
            seg_start = i + 1;
        }
        i += 1;
    }
}

fn builtin_sh(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        puts("sh: missing script file\n");
        last_exit_status = 1;
        return;
    }
    runScriptFile(argv[1]);
}

fn builtin_rmdir(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        puts("rmdir: missing operand\n");
        last_exit_status = 1;
        return;
    }
    const ret = sys.rmdir(argv[1]);
    if (ret < 0) {
        puts("rmdir: failed to remove '");
        puts(argSlice(argv[1]));
        puts("'\n");
        last_exit_status = 1;
    }
}

fn builtin_whoami() void {
    puts("root\n");
}

fn builtin_hostname() void {
    puts("zigix\n");
}

fn builtin_export(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        // No args: print all vars (same as env)
        builtin_env();
        return;
    }
    // Parse KEY=VALUE from argv[1]
    const arg = argSlice(argv[1]);
    var eq_pos: usize = 0;
    var found_eq = false;
    for (0..arg.len) |i| {
        if (arg[i] == '=') {
            eq_pos = i;
            found_eq = true;
            break;
        }
    }
    if (!found_eq) {
        // No '=': print the variable value if set
        if (envGet(arg.ptr, arg.len)) |val| {
            puts(arg);
            putchar('=');
            puts(val);
            putchar('\n');
        }
        return;
    }
    if (eq_pos == 0) {
        puts("export: invalid variable name\n");
        last_exit_status = 1;
        return;
    }
    const key_ptr: [*]const u8 = arg.ptr;
    const key_len = eq_pos;
    const val_ptr: [*]const u8 = @ptrCast(&arg.ptr[eq_pos + 1]);
    const val_len = arg.len - eq_pos - 1;
    envSet(key_ptr, key_len, val_ptr, val_len);
}

fn builtin_unset(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        puts("unset: missing variable name\n");
        last_exit_status = 1;
        return;
    }
    const name = argSlice(argv[1]);
    envUnset(name.ptr, name.len);
}

fn builtin_env() void {
    var i: usize = 0;
    while (i < env_count) : (i += 1) {
        const len: usize = env_lens[i];
        puts(env_store[i][0..len]);
        putchar('\n');
    }
}

fn builtin_jobs() void {
    for (0..MAX_JOBS) |i| {
        if (jobs[i].in_use) {
            puts("[");
            write_uint(i + 1);
            puts("]  ");
            switch (jobs[i].state) {
                .running => puts("Running        "),
                .stopped => puts("Stopped        "),
                .done => puts("Done           "),
            }
            puts(jobs[i].cmd[0..jobs[i].cmd_len]);
            if (jobs[i].state == .running) puts(" &");
            putchar('\n');
        }
    }
}

fn builtin_fg(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    var job_idx: ?usize = null;

    if (argc >= 2) {
        const arg = argSlice(argv[1]);
        if (arg.len > 1 and arg[0] == '%') {
            const num = parseUint(arg[1..]);
            if (num >= 1 and num <= MAX_JOBS and jobs[num - 1].in_use) {
                job_idx = num - 1;
            }
        }
    } else {
        job_idx = jobMostRecent();
    }

    if (job_idx == null) {
        puts("fg: no current job\n");
        last_exit_status = 1;
        return;
    }

    const idx = job_idx.?;
    const job_pgid = jobs[idx].pgid;

    puts(jobs[idx].cmd[0..jobs[idx].cmd_len]);
    putchar('\n');

    // Send SIGCONT if stopped
    if (jobs[idx].state == .stopped) {
        _ = sys.kill(@bitCast(-@as(i64, @bitCast(job_pgid))), 18); // SIGCONT=18
        jobs[idx].state = .running;
    }

    // Give terminal to the job's process group
    tcsetpgrp(job_pgid);

    // Wait for the foreground job
    waitForForeground(job_pgid, jobs[idx].pid, idx);

    // Restore terminal to shell
    tcsetpgrp(shell_pgid);
}

fn builtin_bg(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    var job_idx: ?usize = null;

    if (argc >= 2) {
        const arg = argSlice(argv[1]);
        if (arg.len > 1 and arg[0] == '%') {
            const num = parseUint(arg[1..]);
            if (num >= 1 and num <= MAX_JOBS and jobs[num - 1].in_use) {
                job_idx = num - 1;
            }
        }
    } else {
        job_idx = jobMostRecent();
    }

    if (job_idx == null) {
        puts("bg: no current job\n");
        last_exit_status = 1;
        return;
    }

    const idx = job_idx.?;

    if (jobs[idx].state != .stopped) {
        puts("bg: job already running\n");
        return;
    }

    // Send SIGCONT
    _ = sys.kill(@bitCast(-@as(i64, @bitCast(jobs[idx].pgid))), 18); // SIGCONT=18
    jobs[idx].state = .running;

    puts("[");
    write_uint(idx + 1);
    puts("] ");
    puts(jobs[idx].cmd[0..jobs[idx].cmd_len]);
    puts(" &\n");
}

fn builtin_kill(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        puts("kill: usage: kill [-SIG] PID\n");
        last_exit_status = 1;
        return;
    }

    var sig: u64 = 15; // Default: SIGTERM
    var pid_arg: usize = 1;

    // Check for -SIG argument
    const first = argSlice(argv[1]);
    if (first.len > 1 and first[0] == '-') {
        sig = parseUint(first[1..]);
        pid_arg = 2;
    }

    if (pid_arg >= argc) {
        puts("kill: missing PID\n");
        last_exit_status = 1;
        return;
    }

    const pid = parseUint(argSlice(argv[pid_arg]));
    if (pid == 0) {
        puts("kill: invalid PID\n");
        last_exit_status = 1;
        return;
    }

    const ret = sys.kill(pid, sig);
    if (ret < 0) {
        puts("kill: no such process\n");
        last_exit_status = 1;
    }
}

/// Wait for a foreground process group. Handles stopped (WUNTRACED) and exited.
fn waitForForeground(pgid: u64, lead_pid: u64, job_idx: usize) void {
    const WUNTRACED: u64 = 2;
    _ = pgid;

    var lead_done = false;

    while (true) {
        var wstatus_buf: [4]u8 = [_]u8{0} ** 4;
        const ret = sys.wait4(@bitCast(@as(i64, -1)), @intFromPtr(&wstatus_buf), WUNTRACED);
        if (ret <= 0) break;

        const child_pid: u64 = @bitCast(ret);
        const wstatus = @as(u32, wstatus_buf[0]) |
            (@as(u32, wstatus_buf[1]) << 8) |
            (@as(u32, wstatus_buf[2]) << 16) |
            (@as(u32, wstatus_buf[3]) << 24);

        if ((wstatus & 0xFF) == 0x7F) {
            // Child was stopped — update job table
            if (job_idx < MAX_JOBS and jobs[job_idx].in_use) {
                jobs[job_idx].state = .stopped;
            }
            putchar('\n');
            puts("[");
            write_uint(job_idx + 1);
            puts("]+  Stopped           ");
            if (job_idx < MAX_JOBS and jobs[job_idx].in_use) {
                puts(jobs[job_idx].cmd[0..jobs[job_idx].cmd_len]);
            }
            putchar('\n');
            break;
        }

        // Child exited
        last_exit_status = (wstatus >> 8) & 0xFF;
        if (child_pid == lead_pid) {
            lead_done = true;
        }

        // For single-stage pipelines, lead exit means we're done
        // For multi-stage, we may get other children finishing too
        if (lead_done) break;
    }
}

fn builtin_wc(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    var show_lines = false;
    var show_words = false;
    var show_bytes = false;
    var file_arg: ?[*]const u8 = null;

    var i: usize = 1;
    while (i < argc) : (i += 1) {
        const arg = argSlice(argv[i]);
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                if (c == 'l') show_lines = true
                else if (c == 'w') show_words = true
                else if (c == 'c') show_bytes = true;
            }
        } else {
            file_arg = argv[i];
        }
    }

    // Default: show all
    if (!show_lines and !show_words and !show_bytes) {
        show_lines = true;
        show_words = true;
        show_bytes = true;
    }

    var fd: u64 = 0; // stdin
    var opened = false;
    if (file_arg) |f| {
        const ret = sys.open(f, O_RDONLY, 0);
        if (ret < 0) {
            puts("wc: cannot open file\n");
            last_exit_status = 1;
            return;
        }
        fd = @intCast(ret);
        opened = true;
    }

    var lines: u64 = 0;
    var words: u64 = 0;
    var bytes: u64 = 0;
    var in_word = false;
    var buf: [512]u8 = undefined;

    while (true) {
        const n = sys.read(fd, &buf, 512);
        if (n <= 0) break;
        const count: usize = @intCast(n);
        bytes += count;
        for (0..count) |j| {
            if (buf[j] == '\n') {
                lines += 1;
                in_word = false;
            } else if (buf[j] == ' ' or buf[j] == '\t') {
                in_word = false;
            } else {
                if (!in_word) words += 1;
                in_word = true;
            }
        }
    }

    if (opened) _ = sys.close(fd);

    if (show_lines) {
        write_uint(lines);
        putchar(' ');
    }
    if (show_words) {
        write_uint(words);
        putchar(' ');
    }
    if (show_bytes) {
        write_uint(bytes);
    }
    putchar('\n');
}

fn builtin_grep(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc < 2) {
        puts("grep: missing pattern\n");
        last_exit_status = 1;
        return;
    }

    const pattern = argSlice(argv[1]);
    var file_arg: ?[*]const u8 = null;
    if (argc >= 3) file_arg = argv[2];

    var fd: u64 = 0;
    var opened = false;
    if (file_arg) |f| {
        const ret = sys.open(f, O_RDONLY, 0);
        if (ret < 0) {
            puts("grep: cannot open file\n");
            last_exit_status = 1;
            return;
        }
        fd = @intCast(ret);
        opened = true;
    }

    var line_buf: [512]u8 = undefined;
    var line_len: usize = 0;
    var buf: [512]u8 = undefined;
    var found_any = false;

    while (true) {
        const n = sys.read(fd, &buf, 512);
        if (n <= 0) {
            // Process last line if no trailing newline
            if (line_len > 0) {
                if (containsSubstr(line_buf[0..line_len], pattern)) {
                    puts(line_buf[0..line_len]);
                    putchar('\n');
                    found_any = true;
                }
            }
            break;
        }
        const count: usize = @intCast(n);
        for (0..count) |j| {
            if (buf[j] == '\n') {
                if (containsSubstr(line_buf[0..line_len], pattern)) {
                    puts(line_buf[0..line_len]);
                    putchar('\n');
                    found_any = true;
                }
                line_len = 0;
            } else if (line_len < line_buf.len) {
                line_buf[line_len] = buf[j];
                line_len += 1;
            }
        }
    }

    if (opened) _ = sys.close(fd);
    if (!found_any) last_exit_status = 1;
}

fn sortLine(idx: usize) []const u8 {
    const off = idx * SORT_LINE_SIZE;
    const len: usize = sort_lens[idx];
    return sort_buf[off .. off + len];
}

fn swapSortLines(a: usize, b: usize) void {
    const a_off = a * SORT_LINE_SIZE;
    const b_off = b * SORT_LINE_SIZE;
    var tmp: [SORT_LINE_SIZE]u8 = undefined;
    for (0..SORT_LINE_SIZE) |i| {
        tmp[i] = sort_buf[a_off + i];
        sort_buf[a_off + i] = sort_buf[b_off + i];
        sort_buf[b_off + i] = tmp[i];
    }
    const tmp_len = sort_lens[a];
    sort_lens[a] = sort_lens[b];
    sort_lens[b] = tmp_len;
}

fn builtin_sort(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    var file_arg: ?[*]const u8 = null;
    if (argc >= 2) file_arg = argv[1];

    var fd: u64 = 0;
    var opened = false;
    if (file_arg) |f| {
        const ret = sys.open(f, O_RDONLY, 0);
        if (ret < 0) {
            puts("sort: cannot open file\n");
            last_exit_status = 1;
            return;
        }
        fd = @intCast(ret);
        opened = true;
    }

    // Read all lines
    var num_lines: usize = 0;
    var cur_len: usize = 0;
    var buf: [512]u8 = undefined;

    while (num_lines < SORT_MAX_LINES) {
        const n = sys.read(fd, &buf, 512);
        if (n <= 0) {
            if (cur_len > 0 and num_lines < SORT_MAX_LINES) {
                sort_lens[num_lines] = @truncate(cur_len);
                num_lines += 1;
            }
            break;
        }
        const count: usize = @intCast(n);
        for (0..count) |j| {
            if (buf[j] == '\n') {
                if (num_lines < SORT_MAX_LINES) {
                    sort_lens[num_lines] = @truncate(cur_len);
                    num_lines += 1;
                    cur_len = 0;
                }
            } else if (cur_len < SORT_LINE_SIZE and num_lines < SORT_MAX_LINES) {
                sort_buf[num_lines * SORT_LINE_SIZE + cur_len] = buf[j];
                cur_len += 1;
            }
        }
    }

    if (opened) _ = sys.close(fd);

    // Insertion sort
    if (num_lines > 1) {
        var i: usize = 1;
        while (i < num_lines) : (i += 1) {
            var j = i;
            while (j > 0) {
                const a = sortLine(j - 1);
                const b = sortLine(j);
                if (strless(b, a)) {
                    swapSortLines(j - 1, j);
                    j -= 1;
                } else {
                    break;
                }
            }
        }
    }

    // Print sorted lines
    for (0..num_lines) |k| {
        const line = sortLine(k);
        puts(line);
        putchar('\n');
    }
}

fn builtin_head(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    var n_lines: u64 = 10;
    var file_arg: ?[*]const u8 = null;

    var i: usize = 1;
    while (i < argc) : (i += 1) {
        const arg = argSlice(argv[i]);
        if (arg.len > 1 and arg[0] == '-' and arg[1] >= '0' and arg[1] <= '9') {
            n_lines = parseUint(arg[1..]);
        } else {
            file_arg = argv[i];
        }
    }

    var fd: u64 = 0;
    var opened = false;
    if (file_arg) |f| {
        const ret = sys.open(f, O_RDONLY, 0);
        if (ret < 0) {
            puts("head: cannot open file\n");
            last_exit_status = 1;
            return;
        }
        fd = @intCast(ret);
        opened = true;
    }

    var lines_printed: u64 = 0;
    var buf: [512]u8 = undefined;

    outer: while (lines_printed < n_lines) {
        const n = sys.read(fd, &buf, 512);
        if (n <= 0) break;
        const count: usize = @intCast(n);
        for (0..count) |j| {
            putchar(buf[j]);
            if (buf[j] == '\n') {
                lines_printed += 1;
                if (lines_printed >= n_lines) break :outer;
            }
        }
    }

    if (opened) _ = sys.close(fd);
}

fn builtin_tail(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    var n_lines: u64 = 10;
    var file_arg: ?[*]const u8 = null;

    var i: usize = 1;
    while (i < argc) : (i += 1) {
        const arg = argSlice(argv[i]);
        if (arg.len > 1 and arg[0] == '-' and arg[1] >= '0' and arg[1] <= '9') {
            n_lines = parseUint(arg[1..]);
        } else {
            file_arg = argv[i];
        }
    }

    var fd: u64 = 0;
    var opened = false;
    if (file_arg) |f| {
        const ret = sys.open(f, O_RDONLY, 0);
        if (ret < 0) {
            puts("tail: cannot open file\n");
            last_exit_status = 1;
            return;
        }
        fd = @intCast(ret);
        opened = true;
    }

    // Read all lines into sort_buf (shared buffer)
    var num_lines: usize = 0;
    var cur_len: usize = 0;
    var buf: [512]u8 = undefined;

    for (0..SORT_MAX_LINES) |j| sort_lens[j] = 0;

    while (true) {
        const n = sys.read(fd, &buf, 512);
        if (n <= 0) {
            if (cur_len > 0 and num_lines < SORT_MAX_LINES) {
                sort_lens[num_lines] = @truncate(cur_len);
                num_lines += 1;
            }
            break;
        }
        const count: usize = @intCast(n);
        for (0..count) |j| {
            if (buf[j] == '\n') {
                if (num_lines < SORT_MAX_LINES) {
                    sort_lens[num_lines] = @truncate(cur_len);
                    num_lines += 1;
                    cur_len = 0;
                }
            } else if (cur_len < SORT_LINE_SIZE and num_lines < SORT_MAX_LINES) {
                sort_buf[num_lines * SORT_LINE_SIZE + cur_len] = buf[j];
                cur_len += 1;
            }
        }
    }

    if (opened) _ = sys.close(fd);

    // Print last n_lines
    const start = if (num_lines > @as(usize, @truncate(n_lines))) num_lines - @as(usize, @truncate(n_lines)) else 0;
    for (start..num_lines) |k| {
        const line = sortLine(k);
        puts(line);
        putchar('\n');
    }
}

fn builtin_ls(argv: [MAX_ARGS][*]const u8, argc: usize) void {
    if (argc >= 2) {
        const fd = sys.open(argv[1], O_RDONLY, 0);
        if (fd < 0) {
            puts("ls: cannot access '");
            puts(argSlice(argv[1]));
            puts("'\n");
            return;
        }
        lsDir(@intCast(fd));
        _ = sys.close(@intCast(fd));
    } else {
        // Use cwd
        var path_buf: [257]u8 = undefined;
        const ret = sys.getcwd(&path_buf, 256);
        if (ret > 0) {
            path_buf[@intCast(ret)] = 0;
        } else {
            path_buf[0] = '/';
            path_buf[1] = 0;
        }
        const fd = sys.open(@ptrCast(&path_buf), O_RDONLY, 0);
        if (fd < 0) {
            puts("ls: cannot open directory\n");
            return;
        }
        lsDir(@intCast(fd));
        _ = sys.close(@intCast(fd));
    }
}

fn lsDir(fd: u64) void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const nread = sys.getdents64(fd, &buf, 1024);
        if (nread <= 0) break;

        var pos: usize = 0;
        while (pos < @as(usize, @intCast(nread))) {
            const reclen = @as(u16, buf[pos + 16]) | (@as(u16, buf[pos + 17]) << 8);
            const d_type = buf[pos + 18];
            const name_ptr: [*]const u8 = @ptrCast(&buf[pos + 19]);
            const name = name_ptr[0..strlen(name_ptr)];

            // Skip . and ..
            if (!streq(name, ".") and !streq(name, "..")) {
                puts(name);
                if (d_type == 4) putchar('/'); // DT_DIR
                putchar('\n');
            }

            pos += reclen;
        }
    }
}

/// Returns true if the command was a builtin.
fn tryBuiltin(argv: [MAX_ARGS][*]const u8, argc: usize) bool {
    const cmd = argSlice(argv[0]);
    if (streq(cmd, "echo")) {
        builtin_echo(argv, argc);
        return true;
    }
    if (streq(cmd, "cd")) {
        builtin_cd(argv, argc);
        return true;
    }
    if (streq(cmd, "pwd")) {
        builtin_pwd();
        return true;
    }
    if (streq(cmd, "uname")) {
        builtin_uname();
        return true;
    }
    if (streq(cmd, "cat")) {
        builtin_cat(argv, argc);
        return true;
    }
    if (streq(cmd, "help")) {
        builtin_help();
        return true;
    }
    if (streq(cmd, "ls")) {
        builtin_ls(argv, argc);
        return true;
    }
    if (streq(cmd, "mkdir")) {
        builtin_mkdir(argv, argc);
        return true;
    }
    if (streq(cmd, "rm")) {
        builtin_rm(argv, argc);
        return true;
    }
    if (streq(cmd, "sync")) {
        builtin_sync();
        return true;
    }
    if (streq(cmd, "rmdir")) {
        builtin_rmdir(argv, argc);
        return true;
    }
    if (streq(cmd, "whoami")) {
        builtin_whoami();
        return true;
    }
    if (streq(cmd, "hostname")) {
        builtin_hostname();
        return true;
    }
    if (streq(cmd, "wc")) {
        builtin_wc(argv, argc);
        return true;
    }
    if (streq(cmd, "grep")) {
        builtin_grep(argv, argc);
        return true;
    }
    if (streq(cmd, "sort")) {
        builtin_sort(argv, argc);
        return true;
    }
    if (streq(cmd, "head")) {
        builtin_head(argv, argc);
        return true;
    }
    if (streq(cmd, "tail")) {
        builtin_tail(argv, argc);
        return true;
    }
    if (streq(cmd, "sh")) {
        builtin_sh(argv, argc);
        return true;
    }
    if (streq(cmd, "export")) {
        builtin_export(argv, argc);
        return true;
    }
    if (streq(cmd, "unset")) {
        builtin_unset(argv, argc);
        return true;
    }
    if (streq(cmd, "env")) {
        builtin_env();
        return true;
    }
    if (streq(cmd, "jobs")) {
        builtin_jobs();
        return true;
    }
    if (streq(cmd, "fg")) {
        builtin_fg(argv, argc);
        return true;
    }
    if (streq(cmd, "bg")) {
        builtin_bg(argv, argc);
        return true;
    }
    if (streq(cmd, "kill")) {
        builtin_kill(argv, argc);
        return true;
    }
    // Direct script execution: /path/to/script.sh
    if (cmd.len > 3 and cmd[cmd.len - 3] == '.' and cmd[cmd.len - 2] == 's' and cmd[cmd.len - 1] == 'h') {
        runScriptFile(argv[0]);
        return true;
    }
    if (streq(cmd, "exit")) {
        const code: u64 = if (argc > 1) parseUint(argSlice(argv[1])) else 0;
        sys.exit(code);
    }
    return false;
}

fn parseUint(s: []const u8) u64 {
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        result = result * 10 + (c - '0');
    }
    return result;
}

// ---- O_* flags (matching kernel vfs.zig) ----

const O_RDONLY: u64 = 0;
const O_WRONLY: u64 = 1;
const O_CREAT: u64 = 0o100;
const O_TRUNC: u64 = 0o1000;
const O_APPEND: u64 = 0o2000;

// ---- History ----

const HISTORY_SIZE: usize = 16;
var history_buf: [HISTORY_SIZE * 256]u8 = [_]u8{0} ** (HISTORY_SIZE * 256);
var history_lens: [HISTORY_SIZE]u8 = [_]u8{0} ** HISTORY_SIZE;
var history_start: usize = 0;
var history_count: usize = 0;
var last_exit_status: u64 = 0;
var shell_pgid: u64 = 0;

// ---- Sort/tail shared buffers ----

const SORT_MAX_LINES: usize = 64;
const SORT_LINE_SIZE: usize = 256;
var sort_buf: [SORT_MAX_LINES * SORT_LINE_SIZE]u8 = [_]u8{0} ** (SORT_MAX_LINES * SORT_LINE_SIZE);
var sort_lens: [SORT_MAX_LINES]u16 = [_]u16{0} ** SORT_MAX_LINES;

// ---- Environment variables ----

const MAX_ENV: usize = 32;
const ENV_SIZE: usize = 256; // max "KEY=VALUE\0" length
var env_store: [MAX_ENV][ENV_SIZE]u8 = undefined;
var env_lens: [MAX_ENV]u8 = [_]u8{0} ** MAX_ENV;
var env_count: usize = 0;

// ---- Job table ----

const MAX_JOBS: usize = 8;

const JobState = enum { running, stopped, done };

const Job = struct {
    pid: u64,
    pgid: u64,
    state: JobState,
    cmd: [64]u8,
    cmd_len: u8,
    in_use: bool,
};

var jobs: [MAX_JOBS]Job = [_]Job{.{
    .pid = 0,
    .pgid = 0,
    .state = .done,
    .cmd = [_]u8{0} ** 64,
    .cmd_len = 0,
    .in_use = false,
}} ** MAX_JOBS;

fn jobAdd(pid: u64, pgid: u64, cmd: []const u8, state: JobState) usize {
    for (0..MAX_JOBS) |i| {
        if (!jobs[i].in_use) {
            jobs[i].pid = pid;
            jobs[i].pgid = pgid;
            jobs[i].state = state;
            jobs[i].in_use = true;
            const clen = if (cmd.len > 63) 63 else cmd.len;
            for (0..clen) |j| {
                jobs[i].cmd[j] = cmd[j];
            }
            jobs[i].cmd_len = @truncate(clen);
            return i + 1; // Job numbers are 1-based
        }
    }
    return 0; // No slot available
}

fn jobFindByPid(pid: u64) ?usize {
    for (0..MAX_JOBS) |i| {
        if (jobs[i].in_use and jobs[i].pid == pid) return i;
    }
    return null;
}

fn jobMostRecent() ?usize {
    var best: ?usize = null;
    for (0..MAX_JOBS) |i| {
        if (jobs[i].in_use and (jobs[i].state == .running or jobs[i].state == .stopped)) {
            best = i;
        }
    }
    return best;
}

fn jobRemove(idx: usize) void {
    if (idx < MAX_JOBS) {
        jobs[idx].in_use = false;
    }
}

/// Reap background jobs using WNOHANG. Called before each prompt.
/// Only checks for exited (zombie) children — NOT stopped ones.
/// Using WUNTRACED here would cause an infinite loop because stopped children
/// remain in .stopped state and would be re-reported on every wait4 call.
fn reapBackgroundJobs() void {
    const WNOHANG: u64 = 1;
    while (true) {
        var wstatus_buf: [4]u8 = [_]u8{0} ** 4;
        const ret = sys.wait4(@bitCast(@as(i64, -1)), @intFromPtr(&wstatus_buf), WNOHANG);
        if (ret <= 0) break;

        const child_pid: u64 = @bitCast(ret);

        if (jobFindByPid(child_pid)) |idx| {
            puts("[");
            write_uint(idx + 1);
            puts("]  Done           ");
            puts(jobs[idx].cmd[0..jobs[idx].cmd_len]);
            putchar('\n');
            jobRemove(idx);
        }
    }
}

fn envInit() void {
    envSet("PATH", 4, "/bin:/zig", 9);
    envSet("HOME", 4, "/", 1);
    envSet("SHELL", 5, "/bin/zsh", 8);
    envSet("ZIG_LIB_DIR", 11, "/zig/lib", 8);
}

/// Set or update an environment variable. Stores "KEY=VALUE\0" in env_store[slot].
fn envSet(key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void {
    const total = key_len + 1 + val_len; // "KEY=VALUE"
    if (total >= ENV_SIZE) return; // too long

    // Search for existing key
    var i: usize = 0;
    while (i < env_count) : (i += 1) {
        if (envKeyMatch(i, key, key_len)) {
            // Update existing entry
            writeEnvEntry(i, key, key_len, val, val_len);
            return;
        }
    }

    // Add new entry
    if (env_count >= MAX_ENV) return; // full
    writeEnvEntry(env_count, key, key_len, val, val_len);
    env_count += 1;
}

fn writeEnvEntry(slot: usize, key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void {
    var pos: usize = 0;
    for (0..key_len) |j| {
        env_store[slot][pos] = key[j];
        pos += 1;
    }
    env_store[slot][pos] = '=';
    pos += 1;
    for (0..val_len) |j| {
        env_store[slot][pos] = val[j];
        pos += 1;
    }
    env_store[slot][pos] = 0; // NUL-terminate
    env_lens[slot] = @truncate(pos);
}

/// Get the value portion of an env var (after '='). Returns null if not found.
fn envGet(key: [*]const u8, key_len: usize) ?[]const u8 {
    var i: usize = 0;
    while (i < env_count) : (i += 1) {
        if (envKeyMatch(i, key, key_len)) {
            // Return slice after "KEY="
            const start = key_len + 1;
            const len: usize = env_lens[i];
            if (start > len) return "";
            return env_store[i][start..len];
        }
    }
    return null;
}

fn envKeyMatch(slot: usize, key: [*]const u8, key_len: usize) bool {
    const len: usize = env_lens[slot];
    if (len < key_len + 1) return false; // must have at least "KEY="
    // Check key matches and next char is '='
    for (0..key_len) |j| {
        if (env_store[slot][j] != key[j]) return false;
    }
    return env_store[slot][key_len] == '=';
}

fn envUnset(key: [*]const u8, key_len: usize) void {
    var i: usize = 0;
    while (i < env_count) : (i += 1) {
        if (envKeyMatch(i, key, key_len)) {
            // Move last entry into this slot
            if (i < env_count - 1) {
                const last = env_count - 1;
                for (0..ENV_SIZE) |j| {
                    env_store[i][j] = env_store[last][j];
                }
                env_lens[i] = env_lens[last];
            }
            env_count -= 1;
            return;
        }
    }
}

/// Expand $VAR and ${VAR} references in input, writing result to output.
/// Returns the length of the expanded string.
fn expandVars(input: []const u8, output: []u8) usize {
    var out_pos: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (out_pos >= output.len) break;

        if (input[i] == '$' and i + 1 < input.len) {
            i += 1; // skip '$'

            if (input[i] == '{') {
                // ${VAR} form
                i += 1; // skip '{'
                const name_start = i;
                while (i < input.len and input[i] != '}') : (i += 1) {}
                const name_len = i - name_start;
                if (i < input.len) i += 1; // skip '}'

                if (name_len > 0) {
                    if (envGet(@ptrCast(&input[name_start]), name_len)) |val| {
                        for (val) |c| {
                            if (out_pos >= output.len) break;
                            output[out_pos] = c;
                            out_pos += 1;
                        }
                    }
                }
            } else if (input[i] == '$') {
                // $$ — treat as literal '$'
                output[out_pos] = '$';
                out_pos += 1;
                i += 1;
            } else if (input[i] == '?') {
                // $? — last exit status
                i += 1;
                var tmpbuf: [20]u8 = undefined;
                var v = last_exit_status;
                var ti: usize = 20;
                if (v == 0) {
                    ti -= 1;
                    tmpbuf[ti] = '0';
                } else {
                    while (v > 0) {
                        ti -= 1;
                        tmpbuf[ti] = @truncate((v % 10) + '0');
                        v /= 10;
                    }
                }
                for (tmpbuf[ti..20]) |c| {
                    if (out_pos >= output.len) break;
                    output[out_pos] = c;
                    out_pos += 1;
                }
            } else if (isVarChar(input[i])) {
                // $VAR form — scan alphanumeric/underscore
                const name_start = i;
                while (i < input.len and isVarChar(input[i])) : (i += 1) {}
                const name_len = i - name_start;

                if (envGet(@ptrCast(&input[name_start]), name_len)) |val| {
                    for (val) |c| {
                        if (out_pos >= output.len) break;
                        output[out_pos] = c;
                        out_pos += 1;
                    }
                }
            } else {
                // Lone '$' followed by non-var char — keep literal '$'
                output[out_pos] = '$';
                out_pos += 1;
                // Don't consume the next char — it's not part of a var name
            }
        } else {
            output[out_pos] = input[i];
            out_pos += 1;
            i += 1;
        }
    }

    return out_pos;
}

fn isVarChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

fn historyAdd(line: []const u8) void {
    if (line.len == 0) return;
    const len: u8 = if (line.len > 255) 255 else @truncate(line.len);

    // Don't add duplicate of most recent entry
    if (history_count > 0) {
        const last = (history_start + history_count - 1) % HISTORY_SIZE;
        const lo = last * 256;
        if (history_lens[last] == len) {
            var same = true;
            for (0..len) |i| {
                if (history_buf[lo + i] != line[i]) {
                    same = false;
                    break;
                }
            }
            if (same) return;
        }
    }

    const slot = (history_start + history_count) % HISTORY_SIZE;
    const offset = slot * 256;
    for (0..len) |i| {
        history_buf[offset + i] = line[i];
    }
    history_lens[slot] = len;
    if (history_count < HISTORY_SIZE) {
        history_count += 1;
    } else {
        history_start = (history_start + 1) % HISTORY_SIZE;
    }
}

fn historyGet(idx: usize) []const u8 {
    const actual = (history_start + idx) % HISTORY_SIZE;
    const offset = actual * 256;
    const len: usize = history_lens[actual];
    return history_buf[offset .. offset + len];
}

fn clearAndRedraw(buf: []const u8) void {
    putchar('\r');
    puts("zigix$ ");
    puts(buf);
    puts("\x1b[K"); // Clear to end of line
}

// ---- Child process setup ----

/// Run a builtin in a child process context (stdout may be a pipe).
/// Returns true if command was a builtin that ran.
fn tryBuiltinInChild(argv: [MAX_ARGS][*]const u8, argc: usize) bool {
    const cmd = argSlice(argv[0]);
    if (streq(cmd, "echo")) {
        builtin_echo(argv, argc);
        return true;
    }
    if (streq(cmd, "cat")) {
        builtin_cat(argv, argc);
        return true;
    }
    if (streq(cmd, "pwd")) {
        builtin_pwd();
        return true;
    }
    if (streq(cmd, "uname")) {
        builtin_uname();
        return true;
    }
    if (streq(cmd, "ls")) {
        builtin_ls(argv, argc);
        return true;
    }
    if (streq(cmd, "mkdir")) {
        builtin_mkdir(argv, argc);
        return true;
    }
    if (streq(cmd, "rm")) {
        builtin_rm(argv, argc);
        return true;
    }
    if (streq(cmd, "sync")) {
        builtin_sync();
        return true;
    }
    if (streq(cmd, "rmdir")) {
        builtin_rmdir(argv, argc);
        return true;
    }
    if (streq(cmd, "whoami")) {
        builtin_whoami();
        return true;
    }
    if (streq(cmd, "hostname")) {
        builtin_hostname();
        return true;
    }
    if (streq(cmd, "wc")) {
        builtin_wc(argv, argc);
        return true;
    }
    if (streq(cmd, "grep")) {
        builtin_grep(argv, argc);
        return true;
    }
    if (streq(cmd, "sort")) {
        builtin_sort(argv, argc);
        return true;
    }
    if (streq(cmd, "head")) {
        builtin_head(argv, argc);
        return true;
    }
    if (streq(cmd, "tail")) {
        builtin_tail(argv, argc);
        return true;
    }
    if (streq(cmd, "sh")) {
        builtin_sh(argv, argc);
        return true;
    }
    if (streq(cmd, "env")) {
        builtin_env();
        return true;
    }
    if (cmd.len > 3 and cmd[cmd.len - 3] == '.' and cmd[cmd.len - 2] == 's' and cmd[cmd.len - 1] == 'h') {
        runScriptFile(argv[0]);
        return true;
    }
    return false;
}

/// In a forked child: apply redirections, try builtin, then exec.
fn childExec(stage: *const Stage) noreturn {
    // Apply input redirection
    if (stage.redir_in) |filename| {
        const fd = sys.open(filename, O_RDONLY, 0);
        if (fd < 0) {
            puts("cannot open: ");
            puts(argSlice(filename));
            putchar('\n');
            sys.exit(1);
        }
        _ = sys.dup2(@intCast(fd), 0);
        _ = sys.close(@intCast(fd));
    }

    // Apply output redirection
    if (stage.redir_out) |filename| {
        const flags: u64 = if (stage.append)
            O_WRONLY | O_CREAT | O_APPEND
        else
            O_WRONLY | O_CREAT | O_TRUNC;
        const fd = sys.open(filename, flags, 0o666);
        if (fd < 0) {
            puts("cannot open: ");
            puts(argSlice(filename));
            putchar('\n');
            sys.exit(1);
        }
        _ = sys.dup2(@intCast(fd), 1);
        _ = sys.close(@intCast(fd));
    }

    // Try running as a builtin (stdout is already redirected to pipe if needed)
    if (tryBuiltinInChild(stage.argv, stage.argc)) {
        sys.exit(0);
    }

    const cmd = argSlice(stage.argv[0]);

    // Build argv pointer array for execve (NULL-terminated)
    var argv_ptrs: [MAX_ARGS + 1]u64 = [_]u64{0} ** (MAX_ARGS + 1);
    for (0..stage.argc) |i| {
        argv_ptrs[i] = @intFromPtr(stage.argv[i]);
    }

    // Build envp pointer array from env_store
    var envp_ptrs: [MAX_ENV + 1]u64 = [_]u64{0} ** (MAX_ENV + 1);
    for (0..env_count) |i| {
        envp_ptrs[i] = @intFromPtr(&env_store[i]);
    }

    // Check if command contains '/' — use as-is (absolute or relative path)
    var has_slash = false;
    for (cmd) |c| {
        if (c == '/') {
            has_slash = true;
            break;
        }
    }

    if (has_slash) {
        _ = sys.execve(stage.argv[0], @intFromPtr(&argv_ptrs), @intFromPtr(&envp_ptrs));
    } else {
        // PATH lookup: try each directory in PATH
        const path_val = envGet("PATH", 4) orelse "/bin";
        var path_buf: [256]u8 = undefined;

        var start: usize = 0;
        var pi: usize = 0;
        while (pi <= path_val.len) : (pi += 1) {
            if (pi == path_val.len or path_val[pi] == ':') {
                const dir_len = pi - start;
                // Build: dir + "/" + cmd + NUL
                if (dir_len + 1 + cmd.len < path_buf.len) {
                    var pos: usize = 0;
                    for (0..dir_len) |k| {
                        path_buf[pos] = path_val[start + k];
                        pos += 1;
                    }
                    path_buf[pos] = '/';
                    pos += 1;
                    for (0..cmd.len) |k| {
                        path_buf[pos] = cmd[k];
                        pos += 1;
                    }
                    path_buf[pos] = 0;

                    // argv[0] should be the command name as typed, path_buf is the resolved path
                    _ = sys.execve(@ptrCast(&path_buf), @intFromPtr(&argv_ptrs), @intFromPtr(&envp_ptrs));
                    // If execve returns, it failed for this path — try next
                }
                start = pi + 1;
            }
        }
    }

    // All attempts failed
    puts(cmd);
    puts(": command not found\n");
    sys.exit(127);
}

// ---- Pipeline execution ----

fn executePipeline(stages: *[MAX_STAGES]Stage, num_stages: usize) void {
    executePipelineEx(stages, num_stages, false);
}

fn executePipelineEx(stages: *[MAX_STAGES]Stage, num_stages: usize, background: bool) void {
    // Single command, no pipes, no redirection, foreground: try builtins first
    if (!background and num_stages == 1 and stages[0].redir_in == null and stages[0].redir_out == null) {
        if (tryBuiltin(stages[0].argv, stages[0].argc)) return;
    }

    // Build command string for job table
    var cmd_str: [64]u8 = [_]u8{0} ** 64;
    var cmd_len: usize = 0;
    for (0..num_stages) |si| {
        if (si > 0 and cmd_len + 3 < 64) {
            cmd_str[cmd_len] = ' ';
            cmd_str[cmd_len + 1] = '|';
            cmd_str[cmd_len + 2] = ' ';
            cmd_len += 3;
        }
        for (0..stages[si].argc) |ai| {
            if (ai > 0 and cmd_len < 63) {
                cmd_str[cmd_len] = ' ';
                cmd_len += 1;
            }
            const tok = argSlice(stages[si].argv[ai]);
            for (tok) |c| {
                if (cmd_len >= 63) break;
                cmd_str[cmd_len] = c;
                cmd_len += 1;
            }
        }
    }

    // Multi-stage pipeline: create N-1 pipes, fork N children
    var pipe_fds: [MAX_STAGES - 1][2]u32 = undefined;

    if (num_stages > 1) {
        // Create all pipes
        for (0..num_stages - 1) |i| {
            if (sys.pipe(&pipe_fds[i]) < 0) {
                puts("pipe failed\n");
                for (0..i) |j| {
                    _ = sys.close(pipe_fds[j][0]);
                    _ = sys.close(pipe_fds[j][1]);
                }
                return;
            }
        }
    }

    // Fork N children — all in the same process group (first child's pid)
    var child_pids: [MAX_STAGES]u64 = [_]u64{0} ** MAX_STAGES;
    var child_pgid: u64 = 0; // Will be set to first child's pid
    var child_count: usize = 0;

    for (0..num_stages) |i| {
        const pid = sys.fork();
        if (pid == 0) {
            // ---- Child process ----
            // Set up process group
            if (child_pgid == 0) {
                // First child: create new process group with own pid
                _ = sys.setpgid(0, 0);
            } else {
                // Join the first child's process group
                _ = sys.setpgid(0, child_pgid);
            }

            // Restore default signal handlers (shell had them ignored)
            defaultSig(2); // SIGINT
            defaultSig(20); // SIGTSTP

            // Connect stdin from previous pipe (if not first stage)
            if (i > 0) {
                _ = sys.dup2(pipe_fds[i - 1][0], 0);
            }
            // Connect stdout to next pipe (if not last stage)
            if (i < num_stages - 1) {
                _ = sys.dup2(pipe_fds[i][1], 1);
            }
            // Close ALL pipe fds in child
            if (num_stages > 1) {
                for (0..num_stages - 1) |j| {
                    _ = sys.close(pipe_fds[j][0]);
                    _ = sys.close(pipe_fds[j][1]);
                }
            }
            // Exec (applies any file redirections too)
            childExec(&stages[i]);
        } else if (pid > 0) {
            const child_pid: u64 = @bitCast(pid);
            child_pids[i] = child_pid;

            // Parent also sets pgid (race prevention — whichever runs first wins)
            if (i == 0) {
                child_pgid = child_pid;
                _ = sys.setpgid(child_pid, child_pid);
            } else {
                _ = sys.setpgid(child_pid, child_pgid);
            }

            child_count += 1;
        } else {
            puts("fork failed\n");
        }
    }

    // Parent: close ALL pipe fds
    if (num_stages > 1) {
        for (0..num_stages - 1) |i| {
            _ = sys.close(pipe_fds[i][0]);
            _ = sys.close(pipe_fds[i][1]);
        }
    }

    if (child_count == 0) return;

    if (background) {
        // Background job: add to job table, don't wait
        const job_num = jobAdd(child_pids[0], child_pgid, cmd_str[0..cmd_len], .running);
        if (job_num > 0) {
            puts("[");
            write_uint(job_num);
            puts("] ");
            write_uint(child_pids[0]);
            putchar('\n');
        }
    } else {
        // Foreground job: give terminal to child group, wait, then reclaim
        tcsetpgrp(child_pgid);

        // Add to job table temporarily (for stopped job tracking)
        const job_num = jobAdd(child_pids[0], child_pgid, cmd_str[0..cmd_len], .running);
        const job_idx = if (job_num > 0) job_num - 1 else 0;

        waitForForeground(child_pgid, child_pids[child_count - 1], job_idx);

        // Reclaim terminal for shell
        tcsetpgrp(shell_pgid);

        // Clean up job entry if it completed (not stopped)
        if (job_num > 0 and job_idx < MAX_JOBS and jobs[job_idx].in_use and jobs[job_idx].state != .stopped) {
            jobRemove(job_idx);
        }
    }
}

// ---- Chain / segment execution ----

fn executeSegment(segment: []u8) void {
    // Expand $VAR references before parsing into tokens
    var expanded: [512]u8 = undefined;
    const exp_len = expandVars(segment, &expanded);
    // NUL-terminate: parseLine doesn't NUL the last token, and argSlice/strlen
    // reads past the slice end, so the byte after content must be 0.
    if (exp_len < expanded.len) expanded[exp_len] = 0;

    var argv: [MAX_ARGS][*]const u8 = undefined;
    var argc: usize = 0;
    parseLine(expanded[0..exp_len], exp_len, &argv, &argc);
    if (argc == 0) return;

    // Detect trailing '&' for background execution
    var background = false;
    if (argc > 0 and streq(argSlice(argv[argc - 1]), "&")) {
        background = true;
        argc -= 1;
        if (argc == 0) return;
    }

    last_exit_status = 0;

    // Split on '&&' tokens and execute sub-segments
    var start: usize = 0;
    var after_and = false;
    var j: usize = 0;
    while (j <= argc) {
        var hit_and = false;
        if (j < argc and streq(argSlice(argv[j]), "&&")) {
            hit_and = true;
        }

        if (j == argc or hit_and) {
            const sub_argc = j - start;
            if (sub_argc > 0 and (!after_and or last_exit_status == 0)) {
                var sub_argv: [MAX_ARGS][*]const u8 = undefined;
                for (0..sub_argc) |k| sub_argv[k] = argv[start + k];

                var stages: [MAX_STAGES]Stage = undefined;
                var num_stages: usize = 0;
                if (parsePipeline(sub_argv, sub_argc, &stages, &num_stages)) {
                    executePipelineEx(&stages, num_stages, background);
                }
            }
            after_and = hit_and;
            start = j + 1;
        }
        j += 1;
    }
}

// ---- Script execution ----

/// Execute a script file line-by-line.
fn runScript(path: [*]const u8) noreturn {
    const fd = sys.open(path, 0, 0); // O_RDONLY
    if (fd < 0) {
        puts("zsh: cannot open script: ");
        var i: usize = 0;
        while (path[i] != 0) : (i += 1) putchar(path[i]);
        putchar('\n');
        sys.exit(1);
    }
    const script_fd: u64 = @intCast(fd);

    var buf: [4096]u8 = undefined;
    var line: [256]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        const n = sys.read(script_fd, &buf, buf.len);
        if (n <= 0) break;
        const bytes: usize = @intCast(n);

        for (0..bytes) |bi| {
            if (buf[bi] == '\n' or buf[bi] == '\r') {
                if (line_len > 0) {
                    // Skip comments
                    if (line[0] != '#') {
                        // Split on ';' and execute each segment
                        var seg_start: usize = 0;
                        var si: usize = 0;
                        while (si <= line_len) {
                            if (si == line_len or line[si] == ';') {
                                if (si > seg_start) {
                                    if (si < line_len) line[si] = 0;
                                    executeSegment(line[seg_start..si]);
                                }
                                seg_start = si + 1;
                            }
                            si += 1;
                        }
                    }
                }
                line_len = 0;
            } else {
                if (line_len < line.len - 1) {
                    line[line_len] = buf[bi];
                    line_len += 1;
                }
            }
        }
    }

    // Handle last line without trailing newline
    if (line_len > 0 and line[0] != '#') {
        var seg_start: usize = 0;
        var si: usize = 0;
        while (si <= line_len) {
            if (si == line_len or line[si] == ';') {
                if (si > seg_start) {
                    if (si < line_len) line[si] = 0;
                    executeSegment(line[seg_start..si]);
                }
                seg_start = si + 1;
            }
            si += 1;
        }
    }

    _ = sys.close(script_fd);
    sys.exit(0);
}

// ---- Main shell loop ----

export fn main(initial_sp: usize) noreturn {
    envInit();

    // Check for -c mode (sh -c "command") or script mode (sh /path/to/script.sh)
    if (initial_sp != 0) {
        const stack_ptr: [*]const u64 = @ptrFromInt(initial_sp);
        const argc = stack_ptr[0];
        if (argc >= 3) {
            const argv1: [*]const u8 = @ptrFromInt(stack_ptr[2]); // argv[1]
            // Check for -c flag
            if (argv1[0] == '-' and argv1[1] == 'c' and argv1[2] == 0) {
                // Execute argv[2] as a command string
                const cmd_str: [*]const u8 = @ptrFromInt(stack_ptr[3]); // argv[2]
                // Find length
                var cmd_len: usize = 0;
                while (cmd_str[cmd_len] != 0 and cmd_len < 1023) cmd_len += 1;
                // Copy to local buffer and execute
                var c_buf: [1024]u8 = undefined;
                for (0..cmd_len) |ci| c_buf[ci] = cmd_str[ci];
                c_buf[cmd_len] = 0;
                executeScriptLine(c_buf[0..cmd_len]);
                sys.exit(0);
            }
        }
        if (argc >= 2) {
            const argv1: [*]const u8 = @ptrFromInt(stack_ptr[2]); // argv[1]
            runScript(argv1);
        }
    }

    // Interactive mode
    shell_pgid = sys.getpid();
    _ = sys.setpgid(0, 0);
    tcsetpgrp(shell_pgid);

    ignoreSig(2); // SIGINT
    ignoreSig(20); // SIGTSTP

    puts("Zigix shell v1.0\n");
    puts("Type 'help' for available commands.\n\n");

    while (true) {
        reapBackgroundJobs();
        puts("zigix$ ");

        var line: [256]u8 = undefined;
        const len = readLine(&line);
        if (len == 0) continue;

        historyAdd(line[0..len]);

        // Split on ';' and execute each segment
        var seg_start: usize = 0;
        var i: usize = 0;
        while (i <= len) {
            if (i == len or line[i] == ';') {
                if (i > seg_start) {
                    if (i < len) line[i] = 0;
                    executeSegment(line[seg_start..i]);
                }
                seg_start = i + 1;
            }
            i += 1;
        }
    }
}
