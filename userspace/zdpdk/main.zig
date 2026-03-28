/// zdpdk — Zero-copy packet polling demo for Zigix.
///
/// Demonstrates SCHED_DEDICATED + net_ring: attaches to the kernel's shared
/// net_ring, claims a dedicated CPU core (no preemption), and polls for
/// packets in a tight loop with zero syscalls on the hot path.
///
/// Usage: zdpdk (no arguments — runs until interrupted or limit reached)

const std = @import("std");
const sys = @import("sys");

const builtin = @import("builtin");
const is_aarch64 = builtin.cpu.arch == .aarch64;

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    sys.exit(99);
}

// ---- Entry point ----

export fn _start() callconv(.naked) noreturn {
    if (comptime is_aarch64) {
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

// ---- Net ring shared memory layout (matches kernel net_ring.zig) ----

// RingHeader offsets: magic(0), version(4), ring_size(8), buf_count(12), buf_size(16)
// Cache-line-aligned indices: rx_prod(@32+0=32), rx_cons(@64+0=96), tx_prod(@128+0=160), tx_cons(@192+0=224)
//
// RingHeader is an extern struct with align(64) fields:
//   bytes 0-31:  magic, version, ring_size, buf_count, buf_size, _reserved[3]
//   bytes 32-95: rx_prod (u32) + 15x u32 padding  (64 bytes, aligned to 64)
//   bytes 96-159: rx_cons (u32) + 15x u32 padding
//   bytes 160-223: tx_prod (u32) + 15x u32 padding
//   bytes 224-287: tx_cons (u32) + 15x u32 padding

const HEADER_MAGIC_OFFSET: usize = 0;
const HEADER_RING_SIZE_OFFSET: usize = 8;
const HEADER_BUF_COUNT_OFFSET: usize = 12;
const HEADER_BUF_SIZE_OFFSET: usize = 16;

// These are computed from the RingHeader layout:
// First 8 u32 fields (32 bytes), then rx_prod at next 64-byte boundary
const HEADER_RX_PROD_OFFSET: usize = 32;
const HEADER_RX_CONS_OFFSET: usize = 96;
const HEADER_TX_PROD_OFFSET: usize = 160;
const HEADER_TX_CONS_OFFSET: usize = 224;

const PAGE_SIZE: usize = 4096;
const RX_RING_OFFSET: usize = PAGE_SIZE; // page 1
const TX_RING_OFFSET: usize = 2 * PAGE_SIZE; // page 2
const BUF_POOL_OFFSET: usize = 3 * PAGE_SIZE; // pages 3-66

const RING_MAGIC: u32 = 0x5A4E5430; // "ZNT0"

// PacketDesc: buf_idx(u32) + length(u32) + flags(u32) + _pad(u32) = 16 bytes
const DESC_SIZE: usize = 16;

// Stats reporting interval
const STATS_INTERVAL: u64 = 100;

// ---- Volatile memory access helpers ----

fn volatileReadU32(addr: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

fn volatileWriteU32(addr: usize, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = val;
}

// ARM64 data memory barrier — ensures all preceding stores are visible
fn dmb() void {
    if (comptime is_aarch64) {
        asm volatile ("dmb sy" ::: "memory");
    } else {
        asm volatile ("mfence" ::: "memory");
    }
}

// ---- Main logic ----

export fn main() noreturn {
    puts("zdpdk: Zigix DPDK demo — zero-copy packet polling\n");

    // Step 1: Attach to kernel's shared net_ring
    const attach_ret = sys.net_attach(0, 0);
    if (attach_ret < 0) {
        puts("zdpdk: net_attach failed (");
        printInt(attach_ret);
        puts(")\n");
        puts("zdpdk: no virtio-net? exiting\n");
        sys.exit(1);
    }

    const base: usize = @intCast(attach_ret);
    puts("zdpdk: net_ring attached at 0x");
    printHex(base);
    puts("\n");

    // Step 2: Validate ring header
    const magic = volatileReadU32(base + HEADER_MAGIC_OFFSET);
    if (magic != RING_MAGIC) {
        puts("zdpdk: bad magic 0x");
        printHex(magic);
        puts(" (expected 0x5A4E5430)\n");
        sys.exit(1);
    }

    const ring_size = volatileReadU32(base + HEADER_RING_SIZE_OFFSET);
    const buf_count = volatileReadU32(base + HEADER_BUF_COUNT_OFFSET);
    const buf_size = volatileReadU32(base + HEADER_BUF_SIZE_OFFSET);

    puts("zdpdk: ring_size=");
    printUint(@intCast(ring_size));
    puts(" buf_count=");
    printUint(@intCast(buf_count));
    puts(" buf_size=");
    printUint(@intCast(buf_size));
    puts("\n");

    // Step 3: Claim dedicated CPU core
    const ded_ret = sys.sched_dedicate(0);
    if (ded_ret < 0) {
        puts("zdpdk: sched_dedicate failed (");
        printInt(ded_ret);
        puts(") — running without dedicated core\n");
    } else {
        puts("zdpdk: SCHED_DEDICATED — core 0 claimed, preemption disabled\n");
    }

    // Step 4: Poll loop — zero-copy packet processing
    puts("zdpdk: entering poll loop...\n");

    const ring_mask: u32 = ring_size - 1; // power-of-two ring
    var local_cons: u32 = 0;
    var total_pkts: u64 = 0;
    var total_bytes: u64 = 0;
    var poll_cycles: u64 = 0;

    while (true) {
        // Read producer index (written by kernel on packet arrival)
        const rx_prod = volatileReadU32(base + HEADER_RX_PROD_OFFSET);

        if (rx_prod != local_cons) {
            // Packets available — process batch
            while (local_cons != rx_prod) {
                const desc_addr = base + RX_RING_OFFSET + @as(usize, local_cons & ring_mask) * DESC_SIZE;

                // Read PacketDesc fields
                const buf_idx = volatileReadU32(desc_addr);
                const pkt_len = volatileReadU32(desc_addr + 4);

                // Buffer address = pool base + buf_idx * buf_size
                _ = base + BUF_POOL_OFFSET + @as(usize, buf_idx) * @as(usize, buf_size);
                // In a real driver we'd process the packet data here.
                // For the demo, just count.

                total_pkts += 1;
                total_bytes += pkt_len;

                local_cons +%= 1;
            }

            // Write back consumer index so kernel can reclaim buffers
            volatileWriteU32(base + HEADER_RX_CONS_OFFSET, local_cons);
            dmb();

            // Print stats periodically
            if (total_pkts % STATS_INTERVAL == 0 and total_pkts > 0) {
                puts("zdpdk: ");
                printUint(total_pkts);
                puts(" pkts, ");
                printUint(total_bytes);
                puts(" bytes\n");
            }
        } else {
            // No packets — yield hint to reduce power consumption
            poll_cycles += 1;
            if (comptime is_aarch64) {
                asm volatile ("yield" ::: "memory");
            } else {
                asm volatile ("pause" ::: "memory");
            }
        }
    }
}

// ---- Output helpers ----

fn puts(s: []const u8) void {
    _ = sys.write(1, s.ptr, s.len);
}

fn printUint(val: u64) void {
    if (val == 0) {
        puts("0");
        return;
    }
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) : (len += 1) {
        tmp[len] = @truncate((v % 10) + '0');
        v /= 10;
    }
    // Reverse
    var out: [20]u8 = undefined;
    for (0..len) |i| {
        out[i] = tmp[len - 1 - i];
    }
    _ = sys.write(1, &out, len);
}

fn printInt(val: isize) void {
    if (val < 0) {
        puts("-");
        printUint(@intCast(-val));
    } else {
        printUint(@intCast(val));
    }
}

fn printHex(val: usize) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[v & 0xf];
        v >>= 4;
    }
    // Skip leading zeros (but keep at least one digit)
    var start: usize = 0;
    while (start < 15 and buf[start] == '0') : (start += 1) {}
    _ = sys.write(1, buf[start..].ptr, 16 - start);
}
