/// Zigix login — authenticates users via /etc/passwd and spawns their shell.
/// Architecture-portable: compiles for both x86_64 and aarch64.
/// Flow: print "login: " -> read username -> parse /etc/passwd -> setuid/setgid -> chdir home -> exec shell

const std = @import("std");
const sys = @import("sys");

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
            ::: "memory"
        );
    }
}

// ---- I/O helpers ----

fn puts(s: []const u8) void {
    _ = sys.write(1, s.ptr, s.len);
}

fn putchar(c: u8) void {
    _ = sys.write(1, @as([*]const u8, @ptrCast(&c)), 1);
}

// ---- Passwd entry ----

const PasswdEntry = struct {
    uid: u16,
    gid: u16,
    home: [64]u8,
    home_len: u8,
    shell: [64]u8,
    shell_len: u8,
    found: bool,
};

/// Parse /etc/passwd to find a matching username.
/// Format: username:x:uid:gid:gecos:home:shell
fn lookupUser(username: []const u8) PasswdEntry {
    const result = PasswdEntry{
        .uid = 0,
        .gid = 0,
        .home = [_]u8{0} ** 64,
        .home_len = 0,
        .shell = [_]u8{0} ** 64,
        .shell_len = 0,
        .found = false,
    };

    const fd = sys.open("/etc/passwd\x00", 0, 0); // O_RDONLY
    if (fd < 0) return result;

    var buf: [512]u8 = undefined;
    const n = sys.read(@intCast(fd), &buf, 512);
    _ = sys.close(@intCast(fd));

    if (n <= 0) return result;

    const data = buf[0..@intCast(n)];

    // Parse line by line
    var line_start: usize = 0;
    while (line_start < data.len) {
        // Find end of line
        var line_end = line_start;
        while (line_end < data.len and data[line_end] != '\n') line_end += 1;

        const line = data[line_start..line_end];
        if (line.len > 0) {
            if (parsePasswdLine(line, username)) |entry| {
                return entry;
            }
        }

        line_start = line_end + 1;
    }

    return result;
}

/// Parse a single passwd line. Returns entry if username matches.
fn parsePasswdLine(line: []const u8, username: []const u8) ?PasswdEntry {
    // Field 0: username
    // Field 1: password (x)
    // Field 2: uid
    // Field 3: gid
    // Field 4: gecos
    // Field 5: home
    // Field 6: shell

    var fields: [7]struct { start: usize, end: usize } = undefined;
    var field_count: usize = 0;
    var pos: usize = 0;

    while (field_count < 7) {
        const start = pos;
        while (pos < line.len and line[pos] != ':') pos += 1;
        fields[field_count] = .{ .start = start, .end = pos };
        field_count += 1;
        if (pos < line.len) pos += 1; // skip ':'
    }

    if (field_count < 7) return null;

    // Check username match
    const name = line[fields[0].start..fields[0].end];
    if (name.len != username.len) return null;
    for (0..name.len) |i| {
        if (name[i] != username[i]) return null;
    }

    // Parse uid
    const uid_str = line[fields[2].start..fields[2].end];
    const uid = parseU16(uid_str) orelse return null;

    // Parse gid
    const gid_str = line[fields[3].start..fields[3].end];
    const gid = parseU16(gid_str) orelse return null;

    // Copy home
    const home = line[fields[5].start..fields[5].end];
    const home_len = if (home.len > 63) 63 else home.len;

    // Copy shell
    const shell = line[fields[6].start..fields[6].end];
    const shell_len = if (shell.len > 63) 63 else shell.len;

    var result_entry = PasswdEntry{
        .uid = uid,
        .gid = gid,
        .home = [_]u8{0} ** 64,
        .home_len = @truncate(home_len),
        .shell = [_]u8{0} ** 64,
        .shell_len = @truncate(shell_len),
        .found = true,
    };

    for (0..home_len) |i| result_entry.home[i] = home[i];
    for (0..shell_len) |i| result_entry.shell[i] = shell[i];

    return result_entry;
}

fn parseU16(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    var val: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + @as(u16, c - '0');
    }
    return val;
}

/// Read a line from stdin (fd 0), echoing characters.
/// Returns the number of characters read (not including NUL).
fn readLine(buf: []u8) usize {
    var len: usize = 0;
    while (len < buf.len - 1) {
        var ch: [1]u8 = undefined;
        const n = sys.read(0, &ch, 1);
        if (n <= 0) continue;

        if (ch[0] == '\n' or ch[0] == '\r') {
            putchar('\n');
            break;
        }
        if (ch[0] == 127 or ch[0] == 8) { // backspace
            if (len > 0) {
                len -= 1;
                puts("\x08 \x08");
            }
            continue;
        }
        if (ch[0] < 32) continue; // ignore control chars

        buf[len] = ch[0];
        putchar(ch[0]);
        len += 1;
    }
    buf[len] = 0;
    return len;
}

// ---- Main login loop ----

export fn main() noreturn {
    while (true) {
        puts("\nlogin: ");

        var username_buf: [64]u8 = undefined;
        const ulen = readLine(&username_buf);
        if (ulen == 0) continue;

        const username = username_buf[0..ulen];

        const entry = lookupUser(username);
        if (!entry.found) {
            puts("Login incorrect\n");
            continue;
        }

        // Set gid first (setgid may fail after dropping root via setuid)
        _ = sys.setgid(entry.gid);
        _ = sys.setuid(entry.uid);

        // Change to home directory
        var home_nul: [65]u8 = undefined;
        for (0..entry.home_len) |i| home_nul[i] = entry.home[i];
        home_nul[entry.home_len] = 0;
        _ = sys.chdir(&home_nul);

        // Welcome message
        puts("Welcome, ");
        puts(username);
        putchar('\n');

        // exec the user's shell
        var shell_nul: [65]u8 = undefined;
        for (0..entry.shell_len) |i| shell_nul[i] = entry.shell[i];
        shell_nul[entry.shell_len] = 0;

        var argv_ptrs: [2]u64 = .{ @intFromPtr(&shell_nul), 0 };
        var envp_null: [1]u64 = .{0};
        _ = sys.execve(&shell_nul, @intFromPtr(&argv_ptrs), @intFromPtr(&envp_null));

        // If exec failed, print error and loop back
        puts("login: exec failed for ");
        puts(entry.shell[0..entry.shell_len]);
        putchar('\n');
    }
}
