/// zping -- ICMP echo (ping) utility for Zigix.
/// Architecture-portable: compiles for both x86_64 and aarch64.
/// Uses raw ICMP socket via the shared sys module. No std library.
/// Usage: zping [ip] -- defaults to 10.0.2.2 (QEMU gateway)

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
    _ = sys.write(1, @as([*]const u8, @ptrCast(&buf[i])), 20 - i);
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

// ---- ICMP checksum ----

fn icmpChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        const word = @as(u32, data[i]) << 8 | @as(u32, data[i + 1]);
        sum += word;
    }
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @truncate(~sum);
}

// ---- sockaddr_in builder ----

fn buildSockaddr(buf: *[16]u8, ip: u32, port: u16) void {
    // family = AF_INET (2), little-endian
    buf[0] = 2;
    buf[1] = 0;
    // port (big-endian)
    buf[2] = @truncate(port >> 8);
    buf[3] = @truncate(port);
    // addr (big-endian)
    buf[4] = @truncate(ip >> 24);
    buf[5] = @truncate(ip >> 16);
    buf[6] = @truncate(ip >> 8);
    buf[7] = @truncate(ip);
    // zero padding
    for (8..16) |i| buf[i] = 0;
}

// ---- IP string parser ----

fn parseIp(s: [*]const u8) u32 {
    var result: u32 = 0;
    var octet: u32 = 0;
    var dots: u32 = 0;
    var i: usize = 0;

    while (s[i] != 0) : (i += 1) {
        const c = s[i];
        if (c == '.') {
            result = (result << 8) | octet;
            octet = 0;
            dots += 1;
        } else if (c >= '0' and c <= '9') {
            octet = octet * 10 + (c - '0');
        } else {
            break;
        }
    }
    result = (result << 8) | octet;

    if (dots != 3) return 0x0A000202; // default to 10.0.2.2
    return result;
}

// ---- Main ----

export fn main() noreturn {
    // Default target: QEMU gateway
    const target_ip: u32 = 0x0A000202; // 10.0.2.2

    puts("PING ");
    write_ip(target_ip);
    putchar('\n');

    // Create raw ICMP socket: socket(AF_INET=2, SOCK_RAW=3, IPPROTO_ICMP=1)
    const fd = sys.socket(2, 3, 1);
    if (fd < 0) {
        puts("zping: socket failed\n");
        sys.exit(1);
    }

    const sock_fd: u64 = @intCast(fd);

    // Build sockaddr_in for sendto
    var dest_addr: [16]u8 = undefined;
    buildSockaddr(&dest_addr, target_ip, 0);

    // Send 4 ICMP echo requests
    var seq: u16 = 1;
    while (seq <= 4) : (seq += 1) {
        // Build ICMP echo request
        var icmp_pkt: [64]u8 = undefined;
        icmp_pkt[0] = 8; // Echo Request
        icmp_pkt[1] = 0; // Code
        icmp_pkt[2] = 0; // Checksum (placeholder)
        icmp_pkt[3] = 0;
        // ID = 0x5A49 ('ZI')
        icmp_pkt[4] = 0x5A;
        icmp_pkt[5] = 0x49;
        // Sequence number (big-endian)
        icmp_pkt[6] = @truncate(seq >> 8);
        icmp_pkt[7] = @truncate(seq);

        // Payload: "zigix-ping"
        const payload = "zigix-ping";
        for (0..payload.len) |i| {
            icmp_pkt[8 + i] = payload[i];
        }
        const pkt_len: usize = 8 + payload.len;

        // Zero rest
        for (pkt_len..64) |i| {
            icmp_pkt[i] = 0;
        }

        // Compute checksum
        const cksum = icmpChecksum(icmp_pkt[0..pkt_len]);
        icmp_pkt[2] = @truncate(cksum >> 8);
        icmp_pkt[3] = @truncate(cksum);

        // Send
        const sent = sys.sendto(sock_fd, &icmp_pkt, pkt_len, 0, @intFromPtr(&dest_addr), 16);
        if (sent < 0) {
            puts("zping: sendto failed\n");
            continue;
        }

        // Receive reply (blocking)
        var recv_buf: [128]u8 = undefined;
        const received = sys.recvfrom(sock_fd, &recv_buf, 128, 0, 0, 0);
        if (received >= 8) {
            // Parse reply: type(1) code(1) cksum(2) id(2) seq(2) + payload
            const reply_type = recv_buf[0];
            const reply_seq = @as(u16, recv_buf[6]) << 8 | recv_buf[7];

            if (reply_type == 0) {
                // Echo Reply
                puts("64 bytes from ");
                write_ip(target_ip);
                puts(": seq=");
                write_uint(reply_seq);
                puts(" ttl=255");
                putchar('\n');
            }
        } else if (received < 0) {
            puts("zping: recvfrom failed\n");
        }
    }

    _ = sys.close(sock_fd);
    sys.exit(0);
}
