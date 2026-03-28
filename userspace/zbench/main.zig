/// zbench — Zero-copy networking benchmark for Zigix.
/// Attaches to the shared packet ring, runs RX poll + TX throughput tests.

const std = @import("std");
const zcnet = @import("zcnet.zig");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    sys_exit(99);
}

export fn _start() callconv(.c) noreturn {
    main();
}

// ---- Syscall primitives ----

inline fn syscall0(nr: u64) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
        : "memory"
    );
}

inline fn syscall1(nr: u64, a1: u64) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
          [a1] "{rdi}" (a1),
        : "memory"
    );
}

inline fn syscall2(nr: u64, a1: u64, a2: u64) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
        : "memory"
    );
}

inline fn syscall3(nr: u64, a1: u64, a2: u64, a3: u64) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : "memory"
    );
}

fn sys_write(fd: u64, buf: [*]const u8, len: usize) isize {
    return syscall3(1, fd, @intFromPtr(buf), len);
}

fn sys_exit(code: u64) noreturn {
    _ = syscall1(60, code);
    unreachable;
}

/// clock_gettime(clock_id, timespec*) — nr 228
fn sys_clock_gettime(buf: *[16]u8) isize {
    return syscall2(228, 1, @intFromPtr(buf)); // CLOCK_MONOTONIC=1
}

// ---- I/O helpers ----

fn puts(s: []const u8) void {
    _ = sys_write(1, s.ptr, s.len);
}

fn putchar(c: u8) void {
    _ = sys_write(1, @ptrCast(&c), 1);
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
    _ = sys_write(1, @ptrCast(&buf[i]), 20 - i);
}

fn writeHex16(val: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    _ = sys_write(1, &buf, 16);
}

fn readU64LE(buf: *const [8]u8) u64 {
    var val: u64 = 0;
    for (0..8) |i| {
        val |= @as(u64, buf[i]) << @as(u6, @truncate(i * 8));
    }
    return val;
}

fn getTickSeconds() u64 {
    var ts: [16]u8 = undefined;
    _ = sys_clock_gettime(&ts);
    return readU64LE(ts[0..8]);
}

// ---- Ethernet helpers ----

/// Build a minimal Ethernet frame (broadcast, ethertype 0x0800).
fn buildMinFrame(buf: [*]u8, seq: u16) usize {
    // Destination MAC: broadcast
    for (0..6) |i| buf[i] = 0xFF;
    // Source MAC: 52:54:00:12:34:56
    buf[6] = 0x52;
    buf[7] = 0x54;
    buf[8] = 0x00;
    buf[9] = 0x12;
    buf[10] = 0x34;
    buf[11] = 0x56;
    // EtherType: 0x0800 (IPv4, but we'll just send dummy data)
    buf[12] = 0x08;
    buf[13] = 0x00;
    // Payload: "ZBENCH" + sequence number (pad to 46 bytes minimum)
    buf[14] = 'Z';
    buf[15] = 'B';
    buf[16] = 'E';
    buf[17] = 'N';
    buf[18] = 'C';
    buf[19] = 'H';
    buf[20] = @truncate(seq >> 8);
    buf[21] = @truncate(seq);
    // Zero pad to minimum frame (60 bytes total = 14 header + 46 payload)
    for (22..60) |i| buf[i] = 0;
    return 60; // minimum Ethernet frame
}

// ---- Main ----

fn main() noreturn {
    puts("zbench: Zero-copy networking benchmark\n");

    // Attach to shared ring
    const result = zcnet.attach();
    if (result < 0) {
        puts("zbench: attach failed (errno=");
        write_uint(@as(u64, @bitCast(-result)));
        puts(")\n");
        sys_exit(1);
    }

    const base: u64 = @bitCast(result);
    puts("zbench: attached at 0x");
    writeHex16(base);
    putchar('\n');

    var ring = zcnet.ZcNet.init(base);

    // RX poll test: count packets received over ~3 seconds
    puts("zbench: RX poll test (3 seconds)...\n");

    const start_time = getTickSeconds();
    var rx_count: u64 = 0;

    while (true) {
        const now = getTickSeconds();
        if (now >= start_time + 3) break;

        if (ring.rxPoll()) |_| {
            rx_count += 1;
            ring.rxRelease();
        }
    }

    puts("zbench: received ");
    write_uint(rx_count);
    puts(" packets\n");

    // TX throughput test: send 100 minimum-size frames
    puts("zbench: TX throughput test (100 packets)...\n");

    var tx_count: u64 = 0;
    var seq: u16 = 0;
    while (seq < 100) : (seq += 1) {
        if (ring.txAlloc()) |alloc| {
            const frame_len = buildMinFrame(alloc.buf, seq);
            ring.txSubmit(alloc.buf_idx, @truncate(frame_len));
            tx_count += 1;
        } else {
            // TX ring full — kick to flush and retry
            _ = zcnet.kick();
            // Try one more time
            if (ring.txAlloc()) |alloc| {
                const frame_len = buildMinFrame(alloc.buf, seq);
                ring.txSubmit(alloc.buf_idx, @truncate(frame_len));
                tx_count += 1;
            }
        }
    }

    // Final kick to drain any remaining
    _ = zcnet.kick();

    puts("zbench: sent ");
    write_uint(tx_count);
    puts(" packets\n");

    // Print stats from shared control page
    puts("zbench: stats: rx=");
    write_uint(ring.stats_rx.*);
    puts(" tx=");
    write_uint(ring.stats_tx.*);
    puts(" drops=");
    write_uint(ring.stats_drops.*);
    putchar('\n');

    // Detach
    _ = zcnet.detach();
    puts("zbench: done\n");

    sys_exit(0);
}
