/// zsshd — SSH-2 server for Zigix.
/// Supports curve25519-sha256 key exchange, chacha20-poly1305@openssh.com encryption,
/// ssh-ed25519 host key, password authentication, and remote shell access.
/// Usage: zsshd [port]    (default: port 22)

const std = @import("std");
const sys = @import("sys");
const ssh = @import("ssh.zig");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    sys.exit(99);
}

// ---- Entry point ----

export fn _start() callconv(.naked) noreturn {
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        asm volatile (
            "bl main"
            ::: "memory"
        );
    } else {
        asm volatile (
            "and $-16, %%rsp\n" ++
                "call main"
            ::: "memory"
        );
    }
}

export fn main() noreturn {
    puts("zsshd: Zigix SSH server v1.0\n");

    const port: u16 = 22;

    // Create TCP socket
    const server_fd = sys.socket(2, 1, 6); // AF_INET, SOCK_STREAM, IPPROTO_TCP
    if (server_fd < 0) {
        puts("zsshd: socket() failed\n");
        sys.exit(1);
    }

    // Bind to port
    var sa: [16]u8 = .{0} ** 16;
    sa[0] = 2; // AF_INET
    sa[2] = @truncate(port >> 8); // port big-endian
    sa[3] = @truncate(port);

    const bind_ret = sys.bind(@intCast(server_fd), &sa, 16);
    if (bind_ret < 0) {
        puts("zsshd: bind() failed\n");
        sys.exit(1);
    }

    const listen_ret = sys.listen_sock(@intCast(server_fd), 4);
    if (listen_ret < 0) {
        puts("zsshd: listen() failed\n");
        sys.exit(1);
    }

    puts("zsshd: listening on port 22\n");

    // Accept loop
    while (true) {
        const client_fd = sys.accept_sock(@intCast(server_fd), 0, 0);
        if (client_fd < 0) continue;

        // Fork to handle client
        const pid = sys.fork();
        if (pid == 0) {
            // Child: handle SSH connection
            _ = sys.close(@intCast(server_fd));
            handleConnection(@intCast(client_fd));
            sys.exit(0);
        }

        // Parent: close client fd, reap zombies
        _ = sys.close(@intCast(client_fd));
        // Non-blocking wait to reap any finished children (WNOHANG=1)
        _ = sys.wait4(@bitCast(@as(i64, -1)), 0, 1);
    }
}

// ---- Connection handler ----

fn handleConnection(client_fd: u64) void {
    var sess = ssh.initSession(client_fd);

    // 1. Version exchange
    if (!ssh.versionExchange(&sess)) {
        puts("zsshd: version exchange failed\n");
        return;
    }

    // 2. KEXINIT exchange
    if (!ssh.sendKexInit(&sess)) {
        puts("zsshd: send KEXINIT failed\n");
        return;
    }
    var kex_buf: [4096]u8 = undefined;
    if (ssh.recvKexInit(&sess, &kex_buf) == 0) {
        puts("zsshd: recv KEXINIT failed\n");
        return;
    }

    // 3. Key exchange (curve25519-sha256) + NEWKEYS
    if (!ssh.doKeyExchange(&sess)) {
        puts("zsshd: key exchange failed\n");
        return;
    }

    // 4. Service request (ssh-userauth)
    if (!ssh.handleServiceRequest(&sess)) {
        puts("zsshd: service request failed\n");
        return;
    }

    // 5. Authentication
    if (!ssh.handleAuth(&sess)) {
        puts("zsshd: auth failed\n");
        return;
    }

    // 6. Channel open
    if (!ssh.handleChannelOpen(&sess)) {
        puts("zsshd: channel open failed\n");
        return;
    }

    // 7. Channel request (shell/pty-req)
    if (!ssh.handleChannelRequest(&sess)) {
        puts("zsshd: channel request failed\n");
        return;
    }

    // 8. Spawn shell and relay
    spawnShell(&sess);

    // 9. Cleanup
    _ = ssh.sendChannelEof(&sess);
    _ = ssh.sendChannelClose(&sess);
    _ = ssh.sendDisconnect(&sess);
    _ = sys.close(client_fd);
}

// ---- Shell spawning and bidirectional relay ----

fn spawnShell(sess: *ssh.SshSession) void {
    // Create two pipe pairs
    var stdin_pipe: [2]u32 = undefined; // [0]=read, [1]=write
    var stdout_pipe: [2]u32 = undefined;

    if (sys.pipe(&stdin_pipe) < 0) {
        puts("zsshd: stdin pipe failed\n");
        return;
    }
    if (sys.pipe(&stdout_pipe) < 0) {
        puts("zsshd: stdout pipe failed\n");
        return;
    }

    // Fork the shell process
    const shell_pid = sys.fork();
    if (shell_pid < 0) {
        puts("zsshd: fork shell failed\n");
        return;
    }

    if (shell_pid == 0) {
        // Child: set up stdin/stdout/stderr and exec shell
        _ = sys.dup2(stdin_pipe[0], 0); // stdin reads from pipe
        _ = sys.dup2(stdout_pipe[1], 1); // stdout writes to pipe
        _ = sys.dup2(stdout_pipe[1], 2); // stderr writes to pipe

        // Close unused pipe ends
        _ = sys.close(stdin_pipe[0]);
        _ = sys.close(stdin_pipe[1]);
        _ = sys.close(stdout_pipe[0]);
        _ = sys.close(stdout_pipe[1]);

        // Close the SSH socket
        _ = sys.close(sess.socket_fd);

        // Set uid/gid if authenticated
        if (sess.auth_gid != 0) _ = sys.setgid(sess.auth_gid);
        if (sess.auth_uid != 0) _ = sys.setuid(sess.auth_uid);

        // Exec the shell
        // Build argv: ["/bin/zsh", null]
        var argv: [2]u64 = .{ @intFromPtr(@as([*]const u8, "/bin/zsh")), 0 };
        var envp: [1]u64 = .{0};
        _ = sys.execve("/bin/zsh", @intFromPtr(&argv), @intFromPtr(&envp));

        // If execve fails
        puts("zsshd: execve /bin/zsh failed\n");
        sys.exit(127);
    }

    // Parent: close unused pipe ends
    _ = sys.close(stdin_pipe[0]); // shell reads from this
    _ = sys.close(stdout_pipe[1]); // shell writes to this

    const write_fd = stdin_pipe[1]; // we write to shell's stdin
    const read_fd = stdout_pipe[0]; // we read from shell's stdout

    // Fork-based bidirectional relay
    // Relay-A (parent): shell stdout -> SSH channel data
    // Relay-B (child):  SSH channel data -> shell stdin
    const relay_pid = sys.fork();
    if (relay_pid < 0) {
        puts("zsshd: fork relay failed\n");
        _ = sys.close(write_fd);
        _ = sys.close(read_fd);
        return;
    }

    if (relay_pid == 0) {
        // Relay-B: SSH -> shell stdin
        _ = sys.close(read_fd);
        relayFromSsh(sess, @intCast(write_fd));
        _ = sys.close(write_fd);
        sys.exit(0);
    }

    // Relay-A: shell stdout -> SSH
    _ = sys.close(write_fd);
    relayToSsh(sess, @intCast(read_fd));
    _ = sys.close(read_fd);

    // Wait for shell to exit
    _ = sys.wait4(@bitCast(@as(i64, -1)), 0, 0);
}

fn relayToSsh(sess: *ssh.SshSession, read_fd: u64) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(read_fd, &buf, buf.len);
        if (n <= 0) break; // Shell closed stdout (exited)
        if (!ssh.sendChannelData(sess, buf[0..@intCast(n)])) break;
    }
}

fn relayFromSsh(sess: *ssh.SshSession, write_fd: u64) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = ssh.recvChannelData(sess, &buf);
        if (n == 0) break; // Client sent EOF/CLOSE or connection dropped
        _ = sys.write(@intCast(write_fd), buf[0..n].ptr, n);
    }
}

// ---- Output helpers ----

fn puts(s: []const u8) void {
    _ = sys.write(1, s.ptr, s.len);
}
