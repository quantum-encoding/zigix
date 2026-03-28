/// Userspace zero-copy networking library for Zigix.
/// Maps the shared ring region and provides poll/submit API.

const RING_SIZE: u32 = 32;
const BUF_SIZE: usize = 2048;
const NET_HDR_SIZE: usize = 10;

pub const ZcDesc = extern struct {
    buf_idx: u16,
    len: u16,
    flags: u16,
    _pad: u16,
};

const DESC_FLAG_VALID: u16 = 1;

pub const RxPacket = struct {
    data: [*]const u8,
    len: u16,
    buf_idx: u16,
};

pub const TxBuf = struct {
    buf: [*]u8,
    buf_idx: u16,
};

pub const ZcNet = struct {
    base: u64,
    rx_prod: *volatile u32,
    rx_cons: *volatile u32,
    rx_descs: [*]volatile ZcDesc,
    tx_prod: *volatile u32,
    tx_cons: *volatile u32,
    tx_descs: [*]volatile ZcDesc,
    buf_base: [*]u8,
    stats_rx: *volatile u32,
    stats_tx: *volatile u32,
    stats_drops: *volatile u32,
    tx_alloc_next: u16, // next TX buffer index to try (16-31)

    pub fn init(base_addr: u64) ZcNet {
        return .{
            .base = base_addr,
            .rx_prod = @ptrFromInt(base_addr + 0x000),
            .rx_cons = @ptrFromInt(base_addr + 0x004),
            .rx_descs = @ptrFromInt(base_addr + 0x008),
            .tx_prod = @ptrFromInt(base_addr + 0x108),
            .tx_cons = @ptrFromInt(base_addr + 0x10C),
            .tx_descs = @ptrFromInt(base_addr + 0x110),
            .buf_base = @ptrFromInt(base_addr + 0x1000),
            .stats_rx = @ptrFromInt(base_addr + 0x210),
            .stats_tx = @ptrFromInt(base_addr + 0x214),
            .stats_drops = @ptrFromInt(base_addr + 0x218),
            .tx_alloc_next = 16, // TX buffers are indices 16-31
        };
    }

    /// Poll for a received packet. Returns null if none available.
    pub fn rxPoll(self: *ZcNet) ?RxPacket {
        const prod = self.rx_prod.*;
        const cons = self.rx_cons.*;
        if (prod == cons) return null;

        const slot = cons % RING_SIZE;
        const desc = self.rx_descs[slot];
        if (desc.flags & DESC_FLAG_VALID == 0) return null;

        // Frame data starts after the 10-byte virtio net header
        const offset = @as(usize, desc.buf_idx) * BUF_SIZE + NET_HDR_SIZE;
        return .{
            .data = self.buf_base + offset,
            .len = desc.len,
            .buf_idx = desc.buf_idx,
        };
    }

    /// Release the current RX packet (advance consumer index).
    pub fn rxRelease(self: *ZcNet) void {
        asm volatile ("mfence" ::: "memory");
        self.rx_cons.* = self.rx_cons.* +% 1;
    }

    /// Allocate a TX buffer. Returns null if all TX buffers are in use.
    /// TX buffers use indices 16-31.
    pub fn txAlloc(self: *ZcNet) ?TxBuf {
        // Simple linear scan starting from last allocated
        var tried: u16 = 0;
        while (tried < 16) : (tried += 1) {
            const idx = self.tx_alloc_next;
            self.tx_alloc_next = if (idx >= 31) 16 else idx + 1;

            // Check if this buffer is free (not pending in TX ring)
            if (!self.isTxPending(idx)) {
                // Give caller a pointer past the net header area
                const offset = @as(usize, idx) * BUF_SIZE;
                // Zero the net header (first 10 bytes)
                const buf_ptr = self.buf_base + offset;
                for (0..NET_HDR_SIZE) |i| {
                    buf_ptr[i] = 0;
                }
                return .{
                    .buf = buf_ptr + NET_HDR_SIZE,
                    .buf_idx = idx,
                };
            }
        }
        return null;
    }

    /// Submit a TX buffer for transmission. `len` is the Ethernet frame length.
    pub fn txSubmit(self: *ZcNet, buf_idx: u16, len: u16) void {
        const prod = self.tx_prod.*;
        const slot = prod % RING_SIZE;
        self.tx_descs[slot] = .{
            .buf_idx = buf_idx,
            .len = len,
            .flags = DESC_FLAG_VALID,
            ._pad = 0,
        };
        asm volatile ("mfence" ::: "memory");
        self.tx_prod.* = prod +% 1;
    }

    fn isTxPending(self: *ZcNet, buf_idx: u16) bool {
        const prod = self.tx_prod.*;
        const cons = self.tx_cons.*;
        var i = cons;
        while (i != prod) : (i +%= 1) {
            const slot = i % RING_SIZE;
            if (self.tx_descs[slot].buf_idx == buf_idx) return true;
        }
        return false;
    }
};

// --- Syscall wrappers ---

inline fn syscall0(nr: u64) isize {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> isize),
        : [nr] "{rax}" (nr),
        : "memory"
    );
}

pub fn attach() isize {
    return syscall0(500);
}

pub fn detach() isize {
    return syscall0(501);
}

pub fn kick() isize {
    return syscall0(502);
}
