/// zhttpd — HTTP/1.0 static file server for Zigix.
/// Serves files from the ext2 filesystem over TCP.
/// Usage: zhttpd [port]    (default: port 80)

const std = @import("std");
const sys = @import("sys");

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

export fn main() noreturn {
    puts("zhttpd: Zigix HTTP server\n");

    const port: u16 = 80;

    // Create TCP socket
    const server_fd = sys.socket(2, 1, 6); // AF_INET, SOCK_STREAM, IPPROTO_TCP
    if (server_fd < 0) {
        puts("zhttpd: socket() failed\n");
        sys.exit(1);
    }

    // Bind to port
    var sa: [16]u8 = [_]u8{0} ** 16;
    sa[0] = 2; // AF_INET (little-endian)
    sa[1] = 0;
    sa[2] = @truncate(port >> 8); // port big-endian
    sa[3] = @truncate(port);
    // addr = 0.0.0.0 (INADDR_ANY) — already zeroed

    const bind_ret = sys.bind(@intCast(server_fd), &sa, 16);
    if (bind_ret < 0) {
        puts("zhttpd: bind() failed\n");
        sys.exit(1);
    }

    // Listen
    const listen_ret = sys.listen_sock(@intCast(server_fd), 4);
    if (listen_ret < 0) {
        puts("zhttpd: listen() failed\n");
        sys.exit(1);
    }

    puts("zhttpd: listening on port 80\n");

    // Accept loop — fork per connection for concurrency
    while (true) {
        const client_fd = sys.accept_sock(@intCast(server_fd), 0, 0);
        if (client_fd < 0) continue;

        const pid = sys.fork();
        if (pid == 0) {
            // Child: handle request, then exit
            _ = sys.close(@intCast(server_fd));
            handleClient(@intCast(client_fd));
            _ = sys.close(@intCast(client_fd));
            sys.exit(0);
        } else {
            // Parent: close client fd, reap zombies, continue accepting
            _ = sys.close(@intCast(client_fd));
            reapChildren();
        }
    }
}

// ---- Non-blocking child reaping ----

fn reapChildren() void {
    // WNOHANG = 1: don't block, return immediately if no child exited
    while (sys.wait4(@bitCast(@as(i64, -1)), 0, 1) > 0) {}
}

// ---- Request handling ----

fn handleClient(client_fd: u64) void {
    // Read HTTP request
    var req_buf: [2048]u8 = undefined;
    const n = sys.read(client_fd, &req_buf, req_buf.len);
    if (n <= 0) return;

    const req = req_buf[0..@intCast(n)];

    // Parse request line: "GET /path HTTP/1.x\r\n" or "HEAD /path HTTP/1.x\r\n"
    if (req.len < 14) {
        sendError(client_fd, "400", "Bad Request");
        return;
    }

    // Detect method: GET or HEAD
    var is_head = false;
    var path_start: usize = 0;

    if (req.len >= 4 and eql(req[0..4], "GET ")) {
        path_start = 4;
    } else if (req.len >= 5 and eql(req[0..5], "HEAD ")) {
        path_start = 5;
        is_head = true;
    } else {
        sendError(client_fd, "405", "Method Not Allowed");
        return;
    }

    // Find end of path (space before HTTP/1.x)
    var path_end: usize = path_start;
    while (path_end < req.len and req[path_end] != ' ' and req[path_end] != '\r') : (path_end += 1) {}

    if (path_end <= path_start) {
        sendError(client_fd, "400", "Bad Request");
        return;
    }

    const url_path = req[path_start..path_end];

    // Security: reject path traversal
    if (containsDotDot(url_path)) {
        sendError(client_fd, "403", "Forbidden");
        return;
    }

    // Build filesystem path — url_path already starts with /
    var path_buf: [256]u8 = undefined;
    const path_len = url_path.len;
    if (path_len >= path_buf.len) {
        sendError(client_fd, "414", "URI Too Long");
        return;
    }
    @memcpy(path_buf[0..path_len], url_path);
    path_buf[path_len] = 0; // NUL terminate

    // Log request
    if (is_head) {
        puts("zhttpd: HEAD ");
    } else {
        puts("zhttpd: GET ");
    }
    _ = sys.write(1, url_path.ptr, url_path.len);
    puts(" ");

    // Try to open the file
    const file_fd = sys.open(&path_buf, 0, 0); // O_RDONLY
    if (file_fd < 0) {
        send404(client_fd, url_path);
        puts("404\n");
        return;
    }

    // fstat to get size and check if directory
    // Kernel stat struct is 144 bytes (Linux layout)
    var stat_buf: [144]u8 = undefined;
    const stat_ret = sys.fstat(@intCast(file_fd), &stat_buf);
    if (stat_ret < 0) {
        _ = sys.close(@intCast(file_fd));
        sendError(client_fd, "500", "Internal Server Error");
        puts("500\n");
        return;
    }

    // Parse st_mode (u32 LE): offset 16 on aarch64, offset 24 on x86_64
    // (aarch64 asm-generic stat has 4-byte st_mode before st_nlink;
    //  x86_64 has 8-byte st_nlink before 4-byte st_mode)
    const mode_off: usize = if (comptime @import("builtin").cpu.arch == .aarch64) 16 else 24;
    const st_mode = @as(u32, stat_buf[mode_off]) |
        (@as(u32, stat_buf[mode_off + 1]) << 8) |
        (@as(u32, stat_buf[mode_off + 2]) << 16) |
        (@as(u32, stat_buf[mode_off + 3]) << 24);

    // Check if directory (S_IFDIR = 0o040000)
    if (st_mode & 0o170000 == 0o040000) {
        _ = sys.close(@intCast(file_fd));
        serveDirectory(client_fd, url_path, &path_buf, is_head);
        puts("200 dir\n");
        return;
    }

    // Parse st_size (offset 48, u64 LE)
    const st_size = @as(u64, stat_buf[48]) |
        (@as(u64, stat_buf[49]) << 8) |
        (@as(u64, stat_buf[50]) << 16) |
        (@as(u64, stat_buf[51]) << 24) |
        (@as(u64, stat_buf[52]) << 32) |
        (@as(u64, stat_buf[53]) << 40) |
        (@as(u64, stat_buf[54]) << 48) |
        (@as(u64, stat_buf[55]) << 56);

    // Determine content type from extension
    const content_type = detectContentType(url_path);

    // Build and send response headers
    var hdr_buf: [512]u8 = undefined;
    var hdr_len: usize = 0;

    hdr_len += copyStr(&hdr_buf, hdr_len, "HTTP/1.0 200 OK\r\nContent-Length: ");
    hdr_len += writeUint(hdr_buf[hdr_len..], st_size);
    hdr_len += copyStr(&hdr_buf, hdr_len, "\r\nContent-Type: ");
    hdr_len += copyStr(&hdr_buf, hdr_len, content_type);
    hdr_len += copyStr(&hdr_buf, hdr_len, "\r\nConnection: close\r\n\r\n");

    _ = sys.write(client_fd, &hdr_buf, hdr_len);

    // Stream file content (skip for HEAD requests)
    var total_sent: u64 = 0;
    if (!is_head) {
        var file_buf: [1024]u8 = undefined;
        while (true) {
            const bytes_read = sys.read(@intCast(file_fd), &file_buf, file_buf.len);
            if (bytes_read <= 0) break;
            _ = sys.write(client_fd, &file_buf, @intCast(bytes_read));
            total_sent += @intCast(bytes_read);
        }
    } else {
        total_sent = st_size;
    }

    _ = sys.close(@intCast(file_fd));

    // Log
    puts("200 ");
    var log_buf: [20]u8 = undefined;
    const log_len = writeUint(&log_buf, total_sent);
    _ = sys.write(1, &log_buf, log_len);
    puts("\n");
}

// ---- Directory listing ----

fn serveDirectory(client_fd: u64, url_path: []const u8, path_buf: *[256]u8, is_head: bool) void {
    const dir_fd = sys.open(path_buf, 0, 0);
    if (dir_fd < 0) {
        sendError(client_fd, "500", "Internal Server Error");
        return;
    }

    // Build HTML directory listing into a body buffer
    var body: [4096]u8 = undefined;
    var blen: usize = 0;

    blen += copyStr(&body, blen, "<html><head><title>Index of ");
    blen += copyBuf(&body, blen, url_path);
    blen += copyStr(&body, blen, "</title></head><body><h1>Index of ");
    blen += copyBuf(&body, blen, url_path);
    blen += copyStr(&body, blen, "</h1><hr><pre>\n");

    // Read directory entries
    var dents_buf: [2048]u8 = undefined;
    const dents_n = sys.getdents64(@intCast(dir_fd), &dents_buf, dents_buf.len);
    _ = sys.close(@intCast(dir_fd));

    if (dents_n > 0) {
        const dents_len: usize = @intCast(dents_n);
        var pos: usize = 0;
        while (pos + 19 < dents_len) {
            // Parse linux_dirent64: d_ino(8) + d_off(8) + d_reclen(2) + d_type(1) + name
            const reclen = @as(u16, dents_buf[pos + 16]) | (@as(u16, dents_buf[pos + 17]) << 8);
            if (reclen == 0) break;
            const d_type = dents_buf[pos + 18];
            const name_start = pos + 19;

            // Find NUL terminator
            var name_end = name_start;
            while (name_end < pos + reclen and dents_buf[name_end] != 0) : (name_end += 1) {}
            const name = dents_buf[name_start..name_end];

            if (name.len > 0 and blen + name.len * 2 + 64 < body.len) {
                blen += copyStr(&body, blen, "<a href=\"");
                // Build link: for root paths, just /name; for sub-paths, path/name
                if (url_path.len > 1) {
                    blen += copyBuf(&body, blen, url_path);
                    if (url_path[url_path.len - 1] != '/') {
                        body[blen] = '/';
                        blen += 1;
                    }
                } else {
                    body[blen] = '/';
                    blen += 1;
                }
                blen += copyBuf(&body, blen, name);
                blen += copyStr(&body, blen, "\">");
                blen += copyBuf(&body, blen, name);
                if (d_type == 4) { // DT_DIR
                    body[blen] = '/';
                    blen += 1;
                }
                blen += copyStr(&body, blen, "</a>\n");
            }

            pos += reclen;
        }
    }

    blen += copyStr(&body, blen, "</pre><hr></body></html>\n");

    // Send response
    var hdr_buf: [256]u8 = undefined;
    var hdr_len: usize = 0;
    hdr_len += copyStr(&hdr_buf, hdr_len, "HTTP/1.0 200 OK\r\nContent-Length: ");
    hdr_len += writeUint(hdr_buf[hdr_len..], blen);
    hdr_len += copyStr(&hdr_buf, hdr_len, "\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n");

    _ = sys.write(client_fd, &hdr_buf, hdr_len);
    if (!is_head) {
        _ = sys.write(client_fd, &body, blen);
    }
}

// ---- Error responses ----

fn sendError(client_fd: u64, code: []const u8, reason: []const u8) void {
    var body: [512]u8 = undefined;
    var blen: usize = 0;
    blen += copyStr(&body, blen, "<html><body><h1>");
    blen += copyBuf(&body, blen, code);
    body[blen] = ' ';
    blen += 1;
    blen += copyBuf(&body, blen, reason);
    blen += copyStr(&body, blen, "</h1></body></html>\n");

    var hdr: [256]u8 = undefined;
    var hlen: usize = 0;
    hlen += copyStr(&hdr, hlen, "HTTP/1.0 ");
    hlen += copyBuf(&hdr, hlen, code);
    hdr[hlen] = ' ';
    hlen += 1;
    hlen += copyBuf(&hdr, hlen, reason);
    hlen += copyStr(&hdr, hlen, "\r\nContent-Length: ");
    hlen += writeUint(hdr[hlen..], blen);
    hlen += copyStr(&hdr, hlen, "\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n");

    _ = sys.write(client_fd, &hdr, hlen);
    _ = sys.write(client_fd, &body, blen);
}

fn send404(client_fd: u64, path: []const u8) void {
    var body: [512]u8 = undefined;
    var blen: usize = 0;
    blen += copyStr(&body, blen, "<html><body><h1>404 Not Found</h1><p>");
    blen += copyBuf(&body, blen, path);
    blen += copyStr(&body, blen, " was not found on this server.</p></body></html>\n");

    var hdr: [256]u8 = undefined;
    var hlen: usize = 0;
    hlen += copyStr(&hdr, hlen, "HTTP/1.0 404 Not Found\r\nContent-Length: ");
    hlen += writeUint(hdr[hlen..], blen);
    hlen += copyStr(&hdr, hlen, "\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n");

    _ = sys.write(client_fd, &hdr, hlen);
    _ = sys.write(client_fd, &body, blen);
}

// ---- Content-Type detection ----

fn detectContentType(path: []const u8) []const u8 {
    // Find last '.' in path
    var dot_pos: usize = path.len;
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.') {
            dot_pos = i;
            break;
        }
        if (path[i] == '/') break;
    }

    if (dot_pos >= path.len) return "application/octet-stream";

    const ext = path[dot_pos..];

    if (eql(ext, ".html") or eql(ext, ".htm")) return "text/html";
    if (eql(ext, ".txt")) return "text/plain";
    if (eql(ext, ".sh")) return "text/plain";
    if (eql(ext, ".log")) return "text/plain";
    if (eql(ext, ".json")) return "application/json";
    if (eql(ext, ".css")) return "text/css";
    if (eql(ext, ".js")) return "application/javascript";
    if (eql(ext, ".png")) return "image/png";
    if (eql(ext, ".jpg") or eql(ext, ".jpeg")) return "image/jpeg";
    if (eql(ext, ".gif")) return "image/gif";

    return "application/octet-stream";
}

// ---- String/buffer helpers ----

fn puts(s: []const u8) void {
    _ = sys.write(1, s.ptr, s.len);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |idx| {
        if (a[idx] != b[idx]) return false;
    }
    return true;
}

fn containsDotDot(path: []const u8) bool {
    if (path.len < 2) return false;
    for (0..path.len - 1) |idx| {
        if (path[idx] == '.' and path[idx + 1] == '.') return true;
    }
    return false;
}

fn copyStr(dst: []u8, offset: usize, src: []const u8) usize {
    const avail = dst.len - offset;
    const to_copy = if (src.len > avail) avail else src.len;
    for (0..to_copy) |idx| {
        dst[offset + idx] = src[idx];
    }
    return to_copy;
}

fn copyBuf(dst: []u8, offset: usize, src: []const u8) usize {
    return copyStr(dst, offset, src);
}

fn writeUint(buf: []u8, val: u64) usize {
    if (val == 0) {
        if (buf.len > 0) buf[0] = '0';
        return 1;
    }

    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) : (len += 1) {
        tmp[len] = @truncate((v % 10) + '0');
        v /= 10;
    }

    // Reverse into dst
    const to_copy = if (len > buf.len) buf.len else len;
    for (0..to_copy) |idx| {
        buf[idx] = tmp[len - 1 - idx];
    }
    return to_copy;
}
