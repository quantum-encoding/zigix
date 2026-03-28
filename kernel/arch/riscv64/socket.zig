/// Socket abstraction layer — pool of sockets with VFS-integrated I/O.

const vfs = @import("vfs.zig");
const scheduler = @import("scheduler.zig");
const udp = @import("udp.zig");
const tcp = @import("tcp.zig");
const epoll = @import("epoll.zig");
const spinlock = @import("spinlock.zig");

pub const AF_INET: u16 = 2;
pub const SOCK_STREAM: u16 = 1;
pub const SOCK_DGRAM: u16 = 2;
pub const SOCK_RAW: u16 = 3;
pub const IPPROTO_ICMP: u16 = 1;
pub const IPPROTO_TCP: u16 = 6;
pub const IPPROTO_UDP: u16 = 17;

pub const S_IFSOCK: u32 = 0o140000;

const MAX_SOCKETS: usize = 32;
const UDP_RX_BUF_SIZE: usize = 2048;
const ACCEPT_QUEUE_SIZE: usize = 4;

pub const Socket = struct {
    family: u16,
    sock_type: u16,
    protocol: u16,
    bound_port: u16,
    remote_ip: u32,
    remote_port: u16,
    tcp_conn_idx: usize, // Index into tcp.connections[]
    udp_rx_buf: [UDP_RX_BUF_SIZE]u8,
    udp_rx_head: u16,
    udp_rx_count: u16,
    // For raw ICMP sockets
    icmp_rx_buf: [256]u8,
    icmp_rx_len: u16,
    icmp_rx_ready: bool,
    icmp_src_ip: u32,
    blocked_pid: u64,
    // Server (listen/accept) state
    listening: bool,
    accept_queue: [ACCEPT_QUEUE_SIZE]usize, // completed TCP connection indices
    accept_head: u8,
    accept_count: u8,
    accept_waiting_pid: u64,
    in_use: bool,
    so_reuseaddr: bool,
    tcp_nodelay: bool,
    so_keepalive: bool,
};

var sockets: [MAX_SOCKETS]Socket = [_]Socket{emptySocket()} ** MAX_SOCKETS;
var socket_inodes: [MAX_SOCKETS]vfs.Inode = undefined;
var inodes_initialized: bool = false;

/// SMP lock protecting all socket table state: sockets[], socket_inodes[], inodes_initialized.
/// Lock ordering: never hold socket_lock while acquiring tcp_lock (or vice versa).
var socket_lock: spinlock.IrqSpinlock = .{};

const socket_ops = vfs.FileOperations{
    .read = socketRead,
    .write = socketWrite,
    .close = socketClose,
    .readdir = null,
};

fn emptySocket() Socket {
    return .{
        .family = 0,
        .sock_type = 0,
        .protocol = 0,
        .bound_port = 0,
        .remote_ip = 0,
        .remote_port = 0,
        .tcp_conn_idx = 0,
        .udp_rx_buf = [_]u8{0} ** UDP_RX_BUF_SIZE,
        .udp_rx_head = 0,
        .udp_rx_count = 0,
        .icmp_rx_buf = [_]u8{0} ** 256,
        .icmp_rx_len = 0,
        .icmp_rx_ready = false,
        .icmp_src_ip = 0,
        .blocked_pid = 0,
        .listening = false,
        .accept_queue = [_]usize{0} ** ACCEPT_QUEUE_SIZE,
        .accept_head = 0,
        .accept_count = 0,
        .accept_waiting_pid = 0,
        .in_use = false,
        .so_reuseaddr = false,
        .tcp_nodelay = false,
        .so_keepalive = false,
    };
}

fn initInodes() void {
    for (0..MAX_SOCKETS) |i| {
        socket_inodes[i] = .{
            .ino = 0x20000 + i,
            .mode = S_IFSOCK | 0o666,
            .size = 0,
            .nlink = 1,
            .ops = &socket_ops,
            .fs_data = null,
        };
    }
    inodes_initialized = true;

    // Register UDP delivery callback
    udp.socket_deliver = deliverUdp;
}

/// Allocate a socket. Returns socket index or null.
pub fn allocSocket(family: u16, sock_type: u16, protocol: u16) ?usize {
    if (!inodes_initialized) initInodes();

    socket_lock.acquire();

    var slot: ?usize = null;
    for (0..MAX_SOCKETS) |i| {
        if (!sockets[i].in_use) {
            sockets[i] = emptySocket();
            sockets[i].family = family;
            sockets[i].sock_type = sock_type;
            sockets[i].protocol = protocol;
            sockets[i].in_use = true;
            slot = i;
            break;
        }
    }

    socket_lock.release();

    const i = slot orelse return null;

    // For TCP sockets, allocate a TCP connection (outside socket_lock —
    // tcp.allocConnection acquires tcp_lock internally).
    if (sock_type == SOCK_STREAM) {
        if (tcp.allocConnection()) |conn_idx| {
            socket_lock.acquire();
            sockets[i].tcp_conn_idx = conn_idx;
            socket_lock.release();
        } else {
            socket_lock.acquire();
            sockets[i].in_use = false;
            socket_lock.release();
            return null;
        }
    }

    return i;
}

pub fn getSocket(idx: usize) ?*Socket {
    if (idx >= MAX_SOCKETS) return null;

    socket_lock.acquire();
    const in_use = sockets[idx].in_use;
    socket_lock.release();

    if (!in_use) return null;
    return &sockets[idx];
}

pub fn getSocketInode(idx: usize) *vfs.Inode {
    if (!inodes_initialized) initInodes();
    return &socket_inodes[idx];
}

fn getSocketIndex(inode: *vfs.Inode) ?usize {
    const addr = @intFromPtr(inode);
    const base = @intFromPtr(&socket_inodes[0]);
    if (addr < base) return null;
    const offset = addr - base;
    const idx = offset / @sizeOf(vfs.Inode);
    if (idx >= MAX_SOCKETS) return null;
    return idx;
}

/// Public version for syscall handlers to find socket index from inode.
pub fn getSocketIndexFromInode(inode: *vfs.Inode) ?usize {
    return getSocketIndex(inode);
}

// --- VFS operations ---

fn socketRead(desc: *vfs.FileDescription, buf: [*]u8, count: usize) isize {
    const idx = getSocketIndex(desc.inode) orelse return 0;

    // Read socket type and TCP conn index under lock, then release before
    // calling into TCP (which acquires its own tcp_lock).
    socket_lock.acquire();
    const sock = &sockets[idx];
    const sock_type = sock.sock_type;
    const protocol = sock.protocol;
    const tcp_conn_idx = sock.tcp_conn_idx;
    socket_lock.release();

    if (sock_type == SOCK_STREAM) {
        // TCP read — tcp.recvData acquires tcp_lock internally
        return tcp.recvData(tcp_conn_idx, buf[0..count]);
    } else if (sock_type == SOCK_DGRAM) {
        // UDP read — lock around ring buffer access
        socket_lock.acquire();

        if (sock.udp_rx_count == 0) {
            if (scheduler.currentProcess()) |proc| {
                sock.blocked_pid = proc.pid;
            }
            socket_lock.release();
            return -@as(isize, 11); // EAGAIN
        }
        const to_copy: usize = if (count > sock.udp_rx_count) @as(usize, sock.udp_rx_count) else count;
        for (0..to_copy) |i| {
            buf[i] = sock.udp_rx_buf[(sock.udp_rx_head +% @as(u16, @truncate(i))) % UDP_RX_BUF_SIZE];
        }
        sock.udp_rx_head = (sock.udp_rx_head +% @as(u16, @truncate(to_copy))) % @as(u16, UDP_RX_BUF_SIZE);
        sock.udp_rx_count -= @truncate(to_copy);

        socket_lock.release();
        return @intCast(to_copy);
    } else if (sock_type == SOCK_RAW and protocol == IPPROTO_ICMP) {
        // Raw ICMP socket — lock around ICMP rx buffer access
        socket_lock.acquire();

        if (!sock.icmp_rx_ready) {
            if (scheduler.currentProcess()) |proc| {
                sock.blocked_pid = proc.pid;
            }
            socket_lock.release();
            return -@as(isize, 11); // EAGAIN
        }
        const to_copy: usize = if (count > sock.icmp_rx_len) @as(usize, sock.icmp_rx_len) else count;
        for (0..to_copy) |i| {
            buf[i] = sock.icmp_rx_buf[i];
        }
        sock.icmp_rx_ready = false;

        socket_lock.release();
        return @intCast(to_copy);
    }
    return 0;
}

fn socketWrite(desc: *vfs.FileDescription, buf: [*]const u8, count: usize) isize {
    const idx = getSocketIndex(desc.inode) orelse return 0;

    // Snapshot socket state under lock, release before calling TCP/UDP
    socket_lock.acquire();
    const sock = &sockets[idx];
    const sock_type = sock.sock_type;
    const tcp_conn_idx = sock.tcp_conn_idx;
    const bound_port = sock.bound_port;
    const remote_ip = sock.remote_ip;
    const remote_port = sock.remote_port;
    socket_lock.release();

    if (sock_type == SOCK_STREAM) {
        // tcp.sendData acquires tcp_lock internally
        return tcp.sendData(tcp_conn_idx, buf[0..count]);
    } else if (sock_type == SOCK_DGRAM) {
        if (remote_ip == 0) return -@as(isize, 107); // ENOTCONN
        if (udp.send(bound_port, remote_ip, remote_port, buf[0..count])) {
            return @intCast(count);
        }
        return -@as(isize, 5); // EIO
    }
    return 0;
}

fn socketClose(desc: *vfs.FileDescription) void {
    const idx = getSocketIndex(desc.inode) orelse return;

    // Snapshot socket state and drain accept queue indices under lock
    socket_lock.acquire();
    const sock = &sockets[idx];
    const is_listening = sock.listening;
    const sock_type = sock.sock_type;
    const tcp_conn_idx = sock.tcp_conn_idx;

    // Collect queued connection indices to free outside the lock
    var queued_conns: [ACCEPT_QUEUE_SIZE]usize = undefined;
    var queued_count: u8 = 0;

    if (is_listening) {
        while (sock.accept_count > 0) {
            queued_conns[queued_count] = sock.accept_queue[sock.accept_head];
            queued_count += 1;
            sock.accept_head = @truncate((@as(usize, sock.accept_head) + 1) % ACCEPT_QUEUE_SIZE);
            sock.accept_count -= 1;
        }
    }

    sock.in_use = false;
    socket_lock.release();

    // Free TCP resources outside socket_lock (tcp functions acquire tcp_lock)
    if (is_listening) {
        for (0..queued_count) |j| {
            tcp.freeConnection(queued_conns[j]);
        }
    } else if (sock_type == SOCK_STREAM) {
        tcp.close(tcp_conn_idx);
    }
}

// --- UDP delivery callback ---

fn deliverUdp(dst_port: u16, src_ip: u32, src_port: u16, data: []const u8) void {
    _ = src_ip;
    _ = src_port;

    var wake_pid: u64 = 0;

    // Find a socket bound to dst_port — scan and buffer write under lock
    socket_lock.acquire();

    for (0..MAX_SOCKETS) |i| {
        if (sockets[i].in_use and sockets[i].sock_type == SOCK_DGRAM and sockets[i].bound_port == dst_port) {
            const sock = &sockets[i];
            const space = UDP_RX_BUF_SIZE - @as(usize, sock.udp_rx_count);
            const to_copy = if (data.len > space) space else data.len;

            for (0..to_copy) |j| {
                const pos = (sock.udp_rx_head +% @as(u16, @truncate(sock.udp_rx_count)) +% @as(u16, @truncate(j))) % UDP_RX_BUF_SIZE;
                sock.udp_rx_buf[pos] = data[j];
            }
            sock.udp_rx_count += @truncate(to_copy);

            // Save PID to wake outside the lock
            if (sock.blocked_pid != 0) {
                wake_pid = sock.blocked_pid;
                sock.blocked_pid = 0;
            }

            socket_lock.release();

            // Wake blocked reader and notify epoll outside lock
            if (wake_pid != 0) {
                scheduler.wakeProcess(wake_pid);
            }
            epoll.wakeAllWaiters();
            return;
        }
    }

    socket_lock.release();
}

/// Internal: find listening socket without acquiring the lock (caller must hold socket_lock).
fn findListeningSocketLocked(port: u16) ?usize {
    for (0..MAX_SOCKETS) |i| {
        if (sockets[i].in_use and sockets[i].listening and sockets[i].bound_port == port) {
            return i;
        }
    }
    return null;
}

/// Find a listening socket bound to the given port.
pub fn findListeningSocket(port: u16) ?usize {
    socket_lock.acquire();
    defer socket_lock.release();

    return findListeningSocketLocked(port);
}

/// Queue a completed server-side connection for accept().
/// Called from tcp.zig when a syn_received connection receives its ACK.
/// Caller must NOT hold tcp_lock (this function only acquires socket_lock).
pub fn queueAcceptedConnection(local_port: u16, conn_idx: usize) void {
    var wake_pid: u64 = 0;

    socket_lock.acquire();

    const sock_idx = findListeningSocketLocked(local_port) orelse {
        socket_lock.release();
        return;
    };
    const sock = &sockets[sock_idx];

    if (sock.accept_count >= ACCEPT_QUEUE_SIZE) {
        socket_lock.release();
        return; // queue full, drop
    }

    const tail = (@as(usize, sock.accept_head) + @as(usize, sock.accept_count)) % ACCEPT_QUEUE_SIZE;
    sock.accept_queue[tail] = conn_idx;
    sock.accept_count += 1;

    // Save PID to wake outside the lock
    if (sock.accept_waiting_pid != 0) {
        wake_pid = sock.accept_waiting_pid;
        sock.accept_waiting_pid = 0;
    }

    socket_lock.release();

    // Wake process blocked on accept() and notify epoll outside lock
    if (wake_pid != 0) {
        scheduler.wakeProcess(wake_pid);
    }
    epoll.wakeAllWaiters();
}

/// Allocate a socket wrapping a pre-existing TCP connection (for accept).
pub fn allocSocketWithConn(family: u16, sock_type: u16, protocol: u16, conn_idx: usize) ?usize {
    if (!inodes_initialized) initInodes();

    socket_lock.acquire();
    defer socket_lock.release();

    for (0..MAX_SOCKETS) |i| {
        if (!sockets[i].in_use) {
            sockets[i] = emptySocket();
            sockets[i].family = family;
            sockets[i].sock_type = sock_type;
            sockets[i].protocol = protocol;
            sockets[i].tcp_conn_idx = conn_idx;
            sockets[i].in_use = true;
            return i;
        }
    }
    return null;
}

/// Deliver an ICMP reply to a raw ICMP socket (called from icmp.zig).
pub fn deliverIcmpReply(src_ip: u32, data: []const u8) void {
    var wake_pid: u64 = 0;

    socket_lock.acquire();

    for (0..MAX_SOCKETS) |i| {
        if (sockets[i].in_use and sockets[i].sock_type == SOCK_RAW and sockets[i].protocol == IPPROTO_ICMP) {
            const sock = &sockets[i];
            const to_copy = if (data.len > 256) 256 else data.len;
            for (0..to_copy) |j| {
                sock.icmp_rx_buf[j] = data[j];
            }
            sock.icmp_rx_len = @truncate(to_copy);
            sock.icmp_rx_ready = true;
            sock.icmp_src_ip = src_ip;

            // Save PID to wake outside the lock
            if (sock.blocked_pid != 0) {
                wake_pid = sock.blocked_pid;
                sock.blocked_pid = 0;
            }

            socket_lock.release();

            // Wake blocked reader and notify epoll outside lock
            if (wake_pid != 0) {
                scheduler.wakeProcess(wake_pid);
            }
            epoll.wakeAllWaiters();
            return;
        }
    }

    socket_lock.release();
}

/// Check poll/epoll readiness for a socket inode.
/// Returns bitmask of EPOLLIN/EPOLLOUT/EPOLLHUP.
pub fn checkReadiness(inode: *vfs.Inode) u32 {
    const idx = getSocketIndex(inode) orelse return 0;

    // Snapshot socket state under lock
    socket_lock.acquire();
    const sock = &sockets[idx];
    if (!sock.in_use) {
        socket_lock.release();
        return 0;
    }

    const is_listening = sock.listening;
    const sock_type = sock.sock_type;
    const tcp_conn_idx = sock.tcp_conn_idx;
    const udp_rx_count = sock.udp_rx_count;
    const icmp_rx_ready = sock.icmp_rx_ready;
    const accept_count = sock.accept_count;
    socket_lock.release();

    var events: u32 = 0;

    if (is_listening) {
        // Listening socket: readable when connections are queued
        if (accept_count > 0) events |= 0x001; // EPOLLIN
        return events;
    }

    if (sock_type == SOCK_STREAM) {
        // tcp.getConnection reads tcp state — no socket_lock needed
        if (tcp.getConnection(tcp_conn_idx)) |conn| {
            if (conn.rx_count > 0) events |= 0x001; // EPOLLIN (data available)
            if (conn.state == .close_wait or conn.state == .closed or conn.state == .time_wait) {
                events |= 0x001 | 0x010; // EPOLLIN (EOF) | EPOLLHUP
            }
            if (conn.state == .established and conn.tx_count < conn.tx_buf.len) events |= 0x004; // EPOLLOUT (can write if tx_buf has space)
        } else {
            events |= 0x008 | 0x010; // EPOLLERR | EPOLLHUP (no connection)
        }
    } else if (sock_type == SOCK_DGRAM) {
        if (udp_rx_count > 0) events |= 0x001; // EPOLLIN
        events |= 0x004; // EPOLLOUT (UDP is always writable)
    } else if (sock_type == SOCK_RAW) {
        if (icmp_rx_ready) events |= 0x001; // EPOLLIN
        events |= 0x004; // EPOLLOUT
    }

    return events;
}
