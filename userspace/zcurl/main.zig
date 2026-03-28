/// zcurl -- HTTP client for Zigix.
/// Architecture-portable: compiles for both x86_64 and aarch64.
/// Resolves hostnames via DNS over UDP, fetches pages via HTTP/1.0 over TCP.
/// Usage: zcurl http://hostname/path
///        zcurl http://1.2.3.4:80/path

const std = @import("std");
const sys = @import("sys");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    sys.exit(99);
}

// ---- Entry point ----

export fn _start() callconv(.naked) noreturn {
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        // ARM64: save original SP (argc/argv) in x0 before calling main.
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

export fn main(initial_sp: usize) noreturn {
    if (comptime @import("builtin").cpu.arch == .aarch64) {
        // ARM64: _start saved original SP in x0. Read argc/argv from stack.
        if (initial_sp != 0) {
            const stack_ptr: [*]const u64 = @ptrFromInt(initial_sp);
            mainWithArgs(stack_ptr);
        }
        puts("zcurl: failed to read arguments\n");
        sys.exit(1);
    } else {
        const stack_ptr = asm volatile (""
            : [ret] "={rbp}" (-> [*]const u64),
        );
        mainWithArgs(stack_ptr);
    }
}

fn mainWithArgs(stack_ptr: [*]const u64) noreturn {
    const argc = stack_ptr[0];
    const argv: [*]const [*]const u8 = @ptrFromInt(@intFromPtr(stack_ptr) + 8);

    if (argc < 2) {
        puts("Usage: zcurl http://hostname/path\n");
        sys.exit(1);
    }

    const url = argv[1];
    doRequest(url);
    sys.exit(0);
}

// ---- I/O helpers ----

fn puts(s: []const u8) void {
    _ = sys.write(1, s.ptr, s.len);
}

fn putchar(c: u8) void {
    _ = sys.write(1, @as([*]const u8, @ptrCast(&c)), 1);
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

fn write_ip(ip: u32) void {
    write_uint((ip >> 24) & 0xFF);
    putchar('.');
    write_uint((ip >> 16) & 0xFF);
    putchar('.');
    write_uint((ip >> 8) & 0xFF);
    putchar('.');
    write_uint(ip & 0xFF);
}

// ---- String helpers ----

fn strlen(s: [*]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

fn memcpy(dst: [*]u8, src: [*]const u8, len: usize) void {
    for (0..len) |i| dst[i] = src[i];
}

// ---- sockaddr_in builder ----

fn buildSockaddr(buf: *[16]u8, ip: u32, port: u16) void {
    buf[0] = 2; // AF_INET
    buf[1] = 0;
    buf[2] = @truncate(port >> 8); // port (big-endian)
    buf[3] = @truncate(port);
    buf[4] = @truncate(ip >> 24); // addr (big-endian)
    buf[5] = @truncate(ip >> 16);
    buf[6] = @truncate(ip >> 8);
    buf[7] = @truncate(ip);
    for (8..16) |i| buf[i] = 0;
}

// ---- URL parser ----

const UrlInfo = struct {
    host: [*]const u8,
    host_len: usize,
    path: [*]const u8,
    path_len: usize,
    port: u16,
    is_ip: bool,
    ip: u32,
};

fn parseUrl(url: [*]const u8) ?UrlInfo {
    const url_len = strlen(url);

    // Must start with "http://"
    if (url_len < 8) return null;
    if (url[0] != 'h' or url[1] != 't' or url[2] != 't' or url[3] != 'p' or
        url[4] != ':' or url[5] != '/' or url[6] != '/') return null;

    const host_start: usize = 7;

    // Find end of host (: or / or end)
    var host_end: usize = host_start;
    while (host_end < url_len and url[host_end] != ':' and url[host_end] != '/' and url[host_end] != 0) {
        host_end += 1;
    }

    const host_len = host_end - host_start;
    if (host_len == 0) return null;

    var port: u16 = 80;
    var path_start: usize = host_end;

    // Parse optional port
    if (host_end < url_len and url[host_end] == ':') {
        path_start = host_end + 1;
        port = 0;
        while (path_start < url_len and url[path_start] >= '0' and url[path_start] <= '9') {
            port = port * 10 + @as(u16, url[path_start] - '0');
            path_start += 1;
        }
    }

    // Determine path
    var path: [*]const u8 = "/";
    var path_len: usize = 1;
    if (path_start < url_len and url[path_start] == '/') {
        path = url + path_start;
        path_len = url_len - path_start;
    }

    // Detect bare IP vs hostname
    var is_ip = true;
    var dots: u32 = 0;
    for (host_start..host_end) |i| {
        const c = url[i];
        if (c == '.') {
            dots += 1;
        } else if (c < '0' or c > '9') {
            is_ip = false;
            break;
        }
    }
    if (dots != 3) is_ip = false;

    var ip: u32 = 0;
    if (is_ip) {
        ip = parseIpSlice(url + host_start, host_len);
    }

    return UrlInfo{
        .host = url + host_start,
        .host_len = host_len,
        .path = path,
        .path_len = path_len,
        .port = port,
        .is_ip = is_ip,
        .ip = ip,
    };
}

fn parseIpSlice(s: [*]const u8, len: usize) u32 {
    var result: u32 = 0;
    var octet: u32 = 0;
    for (0..len) |i| {
        const c = s[i];
        if (c == '.') {
            result = (result << 8) | octet;
            octet = 0;
        } else if (c >= '0' and c <= '9') {
            octet = octet * 10 + (c - '0');
        }
    }
    result = (result << 8) | octet;
    return result;
}

// ---- DNS resolver ----

/// Read DNS server IP from /etc/resolv.conf, fallback to 10.0.2.3 (QEMU SLIRP).
/// GCE uses 169.254.169.254 or gateway-provided DNS via DHCP.
fn getDnsServer() u32 {
    const fd = sys.open(@ptrCast("/etc/resolv.conf\x00"), 0, 0);
    if (fd >= 0) {
        const rfd: u64 = @intCast(fd);
        var buf: [256]u8 = undefined;
        const n = sys.read(rfd, &buf, buf.len);
        _ = sys.close(rfd);
        if (n > 0) {
            const bytes: usize = @intCast(n);
            // Find "nameserver X.X.X.X"
            var i: usize = 0;
            while (i + 11 < bytes) : (i += 1) {
                if (buf[i] == 'n' and i + 11 <= bytes and
                    buf[i + 1] == 'a' and buf[i + 2] == 'm' and buf[i + 3] == 'e' and
                    buf[i + 4] == 's' and buf[i + 5] == 'e' and buf[i + 6] == 'r' and
                    buf[i + 7] == 'v' and buf[i + 8] == 'e' and buf[i + 9] == 'r' and
                    buf[i + 10] == ' ')
                {
                    // Parse IP starting at i+11
                    var ip: u32 = 0;
                    var octet: u32 = 0;
                    var octets: u8 = 0;
                    var j: usize = i + 11;
                    while (j < bytes) : (j += 1) {
                        if (buf[j] >= '0' and buf[j] <= '9') {
                            octet = octet * 10 + (buf[j] - '0');
                        } else if (buf[j] == '.') {
                            ip = (ip << 8) | octet;
                            octet = 0;
                            octets += 1;
                        } else break;
                    }
                    if (octets == 3) {
                        ip = (ip << 8) | octet;
                        return ip;
                    }
                }
            }
        }
    }
    return 0x0A000203; // Fallback: 10.0.2.3
}

var dns_server_ip: u32 = 0;

fn dnsResolve(hostname: [*]const u8, hostname_len: usize) ?u32 {
    // Create UDP socket
    const fd = sys.socket(2, 2, 17); // AF_INET, SOCK_DGRAM, IPPROTO_UDP
    if (fd < 0) {
        puts("zcurl: dns socket failed\n");
        return null;
    }
    const sock_fd: u64 = @intCast(fd);

    // Bind to ephemeral port
    var bind_addr: [16]u8 = undefined;
    buildSockaddr(&bind_addr, 0, 53535);
    const br = sys.bind(sock_fd, &bind_addr, 16);
    if (br < 0) {
        puts("zcurl: dns bind failed\n");
        _ = sys.close(sock_fd);
        return null;
    }

    // Build DNS query
    var query: [512]u8 = undefined;
    var qlen: usize = 0;

    // Header: ID=0x4249, flags=0x0100 (RD), QDCOUNT=1
    query[0] = 0x42;
    query[1] = 0x49; // ID
    query[2] = 0x01;
    query[3] = 0x00; // flags: RD=1
    query[4] = 0x00;
    query[5] = 0x01; // QDCOUNT=1
    query[6] = 0x00;
    query[7] = 0x00; // ANCOUNT=0
    query[8] = 0x00;
    query[9] = 0x00; // NSCOUNT=0
    query[10] = 0x00;
    query[11] = 0x00; // ARCOUNT=0
    qlen = 12;

    // QNAME: label-encode hostname (e.g. "example.com" -> \x07example\x03com\x00)
    var label_start: usize = 0;
    for (0..hostname_len) |i| {
        if (hostname[i] == '.') {
            const label_len = i - label_start;
            query[qlen] = @truncate(label_len);
            qlen += 1;
            memcpy(query[qlen..].ptr, hostname + label_start, label_len);
            qlen += label_len;
            label_start = i + 1;
        }
    }
    // Final label
    const last_len = hostname_len - label_start;
    query[qlen] = @truncate(last_len);
    qlen += 1;
    memcpy(query[qlen..].ptr, hostname + label_start, last_len);
    qlen += last_len;
    query[qlen] = 0x00; // terminator
    qlen += 1;

    // QTYPE=A(1), QCLASS=IN(1)
    query[qlen] = 0x00;
    query[qlen + 1] = 0x01;
    query[qlen + 2] = 0x00;
    query[qlen + 3] = 0x01;
    qlen += 4;

    // Send to DNS server
    var dns_addr: [16]u8 = undefined;
    if (dns_server_ip == 0) dns_server_ip = getDnsServer();
    buildSockaddr(&dns_addr, dns_server_ip, 53);
    const sent = sys.sendto(sock_fd, &query, qlen, 0, @intFromPtr(&dns_addr), 16);
    if (sent < 0) {
        puts("zcurl: dns sendto failed\n");
        _ = sys.close(sock_fd);
        return null;
    }

    // Receive response
    var resp: [512]u8 = undefined;
    const received = sys.recvfrom(sock_fd, &resp, 512, 0, 0, 0);
    _ = sys.close(sock_fd);

    if (received < 12) {
        puts("zcurl: dns response too short\n");
        return null;
    }
    const resp_len: usize = @intCast(received);

    // Check ANCOUNT > 0
    const ancount = @as(u16, resp[6]) << 8 | resp[7];
    if (ancount == 0) {
        puts("zcurl: dns no answers\n");
        return null;
    }

    // Skip question section: find end of QNAME + 4 bytes (QTYPE + QCLASS)
    var pos: usize = 12;
    pos = skipDnsName(resp[0..resp_len], pos);
    pos += 4; // QTYPE + QCLASS

    // Parse answer RRs -- find first TYPE=A
    var ans: u16 = 0;
    while (ans < ancount and pos < resp_len) : (ans += 1) {
        pos = skipDnsName(resp[0..resp_len], pos);
        if (pos + 10 > resp_len) break;

        const rtype = @as(u16, resp[pos]) << 8 | resp[pos + 1];
        const rdlength = @as(u16, resp[pos + 8]) << 8 | resp[pos + 9];
        pos += 10; // TYPE(2) + CLASS(2) + TTL(4) + RDLENGTH(2)

        if (rtype == 1 and rdlength == 4 and pos + 4 <= resp_len) {
            // A record: 4 bytes IPv4
            const ip = @as(u32, resp[pos]) << 24 |
                @as(u32, resp[pos + 1]) << 16 |
                @as(u32, resp[pos + 2]) << 8 |
                @as(u32, resp[pos + 3]);
            return ip;
        }

        pos += rdlength; // skip RDATA
    }

    puts("zcurl: dns no A record\n");
    return null;
}

fn skipDnsName(pkt: []const u8, start: usize) usize {
    var pos = start;
    while (pos < pkt.len) {
        const b = pkt[pos];
        if (b == 0) {
            // End of name
            return pos + 1;
        } else if (b & 0xC0 == 0xC0) {
            // Compression pointer -- 2 bytes, done
            return pos + 2;
        } else {
            // Label: length byte + label data
            pos += 1 + @as(usize, b);
        }
    }
    return pos;
}

// ---- HTTP client ----

fn httpGet(ip: u32, port: u16, host: [*]const u8, host_len: usize, path: [*]const u8, path_len: usize) void {
    // Create TCP socket
    const fd = sys.socket(2, 1, 6); // AF_INET, SOCK_STREAM, IPPROTO_TCP
    if (fd < 0) {
        puts("zcurl: tcp socket failed\n");
        return;
    }
    const sock_fd: u64 = @intCast(fd);

    // Connect
    var server_addr: [16]u8 = undefined;
    buildSockaddr(&server_addr, ip, port);
    const cr = sys.connect(sock_fd, &server_addr, 16);
    if (cr < 0) {
        puts("zcurl: connect failed\n");
        _ = sys.close(sock_fd);
        return;
    }

    // Build HTTP/1.0 request
    var req: [1024]u8 = undefined;
    var rlen: usize = 0;

    // "GET "
    const get_str = "GET ";
    memcpy(req[rlen..].ptr, get_str.ptr, get_str.len);
    rlen += get_str.len;

    // path
    memcpy(req[rlen..].ptr, path, path_len);
    rlen += path_len;

    // " HTTP/1.0\r\nHost: "
    const mid_str = " HTTP/1.0\r\nHost: ";
    memcpy(req[rlen..].ptr, mid_str.ptr, mid_str.len);
    rlen += mid_str.len;

    // host
    memcpy(req[rlen..].ptr, host, host_len);
    rlen += host_len;

    // "\r\nConnection: close\r\n\r\n"
    const end_str = "\r\nConnection: close\r\n\r\n";
    memcpy(req[rlen..].ptr, end_str.ptr, end_str.len);
    rlen += end_str.len;

    // Send request
    const sent = sys.sendto(sock_fd, &req, rlen, 0, 0, 0);
    if (sent < 0) {
        puts("zcurl: send failed\n");
        _ = sys.close(sock_fd);
        return;
    }

    // Read response loop
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = sys.recvfrom(sock_fd, &buf, 1024, 0, 0, 0);
        if (n <= 0) break; // EOF or error
        _ = sys.write(1, &buf, @intCast(n));
    }

    _ = sys.close(sock_fd);
}

// ---- Main logic ----

fn doRequest(url: [*]const u8) void {
    const info = parseUrl(url) orelse {
        puts("zcurl: invalid URL (use http://hostname/path)\n");
        return;
    };

    var ip: u32 = undefined;

    if (info.is_ip) {
        ip = info.ip;
    } else {
        // Resolve hostname via DNS
        puts("Resolving ");
        _ = sys.write(1, info.host, info.host_len);
        puts("... ");

        ip = dnsResolve(info.host, info.host_len) orelse {
            puts("failed\n");
            return;
        };
        write_ip(ip);
        putchar('\n');
    }

    puts("Connecting to ");
    write_ip(ip);
    putchar(':');
    write_uint(info.port);
    puts("...\n");

    httpGet(ip, info.port, info.host, info.host_len, info.path, info.path_len);
}
