/// TCP — Transmission Control Protocol.
/// Supports: 3-way handshake, data send/recv, connection close,
/// retransmission with RTO, RTT measurement (RFC 6298), Reno congestion control.

const ethernet = @import("ethernet.zig");
const checksum = @import("checksum.zig");
const ipv4 = @import("ipv4.zig");
const scheduler = @import("scheduler.zig");
const timer = @import("timer.zig");
const socket = @import("socket.zig");
const epoll = @import("epoll.zig");
const spinlock = @import("spinlock.zig");


const TCP_HEADER_SIZE: usize = 20;

// TCP flags
const FIN: u8 = 0x01;
const SYN: u8 = 0x02;
const RST: u8 = 0x04;
const PSH: u8 = 0x08;
const ACK: u8 = 0x10;

pub const TcpState = enum {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    time_wait,
};

pub const MAX_TCP_CONNECTIONS: usize = 128;
const RX_BUF_SIZE: usize = 4096;

// --- Retransmission / Congestion constants ---
const TX_BUF_SIZE: u16 = 8192;
const MAX_TX_SEGS: usize = 6;
const INITIAL_RTO: u32 = 100;
const MIN_RTO: u32 = 20;
const MAX_RTO: u32 = 6000;
const MAX_RETRANSMITS: u8 = 8;
const MSS: u16 = 1460;

const TxSegment = struct {
    seq: u32,
    len: u16,
    retransmits: u8,
};

// --- Out-of-order reassembly queue ---
const MAX_OOO_SEGS: usize = 8;
const OOO_BUF_SIZE: usize = 1500; // per-segment buffer (MSS)

const OooSegment = struct {
    seq: u32 = 0,
    len: u16 = 0,
    data: [OOO_BUF_SIZE]u8 = [_]u8{0} ** OOO_BUF_SIZE,
    in_use: bool = false,
};

pub const TcpConnection = struct {
    state: TcpState,
    local_port: u16,
    remote_port: u16,
    local_ip: u32,
    remote_ip: u32,
    send_next: u32,
    send_unack: u32,
    recv_next: u32,
    rx_buf: [RX_BUF_SIZE]u8,
    rx_head: u16,
    rx_count: u16,
    waiting_pid: u64,
    in_use: bool,

    // --- Send buffer ---
    tx_buf: [TX_BUF_SIZE]u8,
    tx_head: u16,
    tx_count: u16,
    tx_sent: u16,
    tx_segs: [MAX_TX_SEGS]TxSegment,
    tx_seg_count: u8,

    // --- RTT ---
    srtt: i32,
    rttvar: i32,
    rto: u32,
    rtt_seq: u32,
    rtt_measured: bool,

    // --- Congestion ---
    cwnd: u32,
    ssthresh: u32,
    peer_window: u16,
    dup_ack_count: u8,
    in_recovery: bool,

    // --- Timer ---
    rto_deadline: u64,

    // --- Out-of-order reassembly ---
    ooo_segs: [MAX_OOO_SEGS]OooSegment = [_]OooSegment{.{}} ** MAX_OOO_SEGS,
};

var connections: [MAX_TCP_CONNECTIONS]TcpConnection = [_]TcpConnection{emptyConn()} ** MAX_TCP_CONNECTIONS;
var next_ephemeral_port: u16 = 49152;

/// SMP lock protecting all TCP connection state: connections[], next_ephemeral_port.
/// Lock ordering: never hold tcp_lock while acquiring socket_lock (or vice versa).
var tcp_lock: spinlock.IrqSpinlock = .{};

fn emptyConn() TcpConnection {
    return .{
        .state = .closed,
        .local_port = 0,
        .remote_port = 0,
        .local_ip = 0,
        .remote_ip = 0,
        .send_next = 0,
        .send_unack = 0,
        .recv_next = 0,
        .rx_buf = [_]u8{0} ** RX_BUF_SIZE,
        .rx_head = 0,
        .rx_count = 0,
        .waiting_pid = 0,
        .in_use = false,
        .tx_buf = [_]u8{0} ** TX_BUF_SIZE,
        .tx_head = 0,
        .tx_count = 0,
        .tx_sent = 0,
        .tx_segs = [_]TxSegment{.{ .seq = 0, .len = 0, .retransmits = 0 }} ** MAX_TX_SEGS,
        .tx_seg_count = 0,
        .srtt = 0,
        .rttvar = 0,
        .rto = INITIAL_RTO,
        .rtt_seq = 0,
        .rtt_measured = false,
        .cwnd = MSS * 2,
        .ssthresh = 65535,
        .peer_window = 4096,
        .dup_ack_count = 0,
        .in_recovery = false,
        .rto_deadline = 0,
        .ooo_segs = [_]OooSegment{.{}} ** MAX_OOO_SEGS,
    };
}

/// Allocate a TCP connection slot. Returns index or null.
pub fn allocConnection() ?usize {
    tcp_lock.acquire();
    defer tcp_lock.release();

    for (0..MAX_TCP_CONNECTIONS) |i| {
        if (!connections[i].in_use) {
            connections[i] = emptyConn();
            connections[i].in_use = true;
            connections[i].local_ip = ipv4.our_ip;
            connections[i].local_port = next_ephemeral_port;
            next_ephemeral_port +%= 1;
            if (next_ephemeral_port < 49152) next_ephemeral_port = 49152;
            return i;
        }
    }
    return null;
}

pub fn getConnection(idx: usize) ?*TcpConnection {
    if (idx >= MAX_TCP_CONNECTIONS) return null;

    tcp_lock.acquire();
    const in_use = connections[idx].in_use;
    tcp_lock.release();

    if (!in_use) return null;
    return &connections[idx];
}

pub fn freeConnection(idx: usize) void {
    if (idx < MAX_TCP_CONNECTIONS) {
        tcp_lock.acquire();
        connections[idx].in_use = false;
        connections[idx].state = .closed;
        tcp_lock.release();
    }
}

/// Internal: allocate server connection with tcp_lock already held.
fn allocConnectionForServerLocked(local_port: u16, remote_ip: u32, remote_port: u16, syn_seq: u32) ?usize {
    for (0..MAX_TCP_CONNECTIONS) |i| {
        if (!connections[i].in_use) {
            connections[i] = emptyConn();
            connections[i].in_use = true;
            connections[i].local_ip = ipv4.our_ip;
            connections[i].local_port = local_port;
            connections[i].remote_ip = remote_ip;
            connections[i].remote_port = remote_port;
            connections[i].recv_next = syn_seq +% 1;

            // Generate ISN from timer tick count
            connections[i].send_next = @truncate(timer.getTicks() *% 2654435761);
            connections[i].send_unack = connections[i].send_next;
            connections[i].state = .syn_received;

            // Send SYN|ACK (sendSegment reads conn fields + calls ipv4.send, safe under tcp_lock)
            sendSegment(&connections[i], SYN | ACK, &[_]u8{});
            connections[i].send_next +%= 1;

            return i;
        }
    }
    return null;
}

/// Allocate a TCP connection for an incoming server-side handshake.
/// Uses the specified local_port (not ephemeral) and sets state to syn_received.
/// Sends SYN|ACK and returns connection index.
pub fn allocConnectionForServer(local_port: u16, remote_ip: u32, remote_port: u16, syn_seq: u32) ?usize {
    tcp_lock.acquire();
    const result = allocConnectionForServerLocked(local_port, remote_ip, remote_port, syn_seq);
    tcp_lock.release();
    return result;
}

/// Handle an incoming TCP segment (payload after IPv4 header).
/// Called from network interrupt path. Uses "wake-outside-lock" pattern to
/// avoid holding tcp_lock while calling into socket or scheduler subsystems.
pub fn handleTcp(src_ip: u32, data: []const u8) void {
    if (data.len < TCP_HEADER_SIZE) return;

    // Parse header fields (no lock needed — reads from incoming packet buffer)
    const src_port = ethernet.getU16BE(data[0..2]);
    const dst_port = ethernet.getU16BE(data[2..4]);
    const seq_num = ethernet.getU32BE(data[4..8]);
    const ack_num = ethernet.getU32BE(data[8..12]);
    const data_offset = (data[12] >> 4) * 4;
    const flags = data[13];

    const peer_win = ethernet.getU16BE(data[14..16]);

    if (data_offset > data.len) return;

    const payload = data[@as(usize, data_offset)..];

    // --- Connection lookup under tcp_lock ---
    tcp_lock.acquire();

    const conn_idx = findConnectionLocked(src_ip, src_port, dst_port) orelse {
        tcp_lock.release();

        // No matching connection — check for listening socket on incoming SYN.
        // socket.findListeningSocket acquires socket_lock internally (safe: tcp_lock released).
        if (flags & SYN != 0 and flags & ACK == 0) {
            if (socket.findListeningSocket(dst_port) != null) {
                // Allocate server-side connection under tcp_lock, sends SYN-ACK
                tcp_lock.acquire();
                _ = allocConnectionForServerLocked(dst_port, src_ip, src_port, seq_num);
                tcp_lock.release();
                return;
            }
        }
        // No listener — send RST if not a RST (stateless, no lock needed)
        if (flags & RST == 0) {
            sendRst(src_ip, src_port, dst_port, seq_num, ack_num, flags);
        }
        return;
    };

    // --- State machine under tcp_lock ---
    // Deferred actions to execute after releasing tcp_lock
    var wake_pid: u64 = 0;
    var do_epoll_wake: bool = false;
    var do_queue_accept: bool = false;
    var accept_local_port: u16 = 0;
    var accept_conn_idx: usize = 0;

    const conn = &connections[conn_idx];

    switch (conn.state) {
        .syn_sent => {
            // Expecting SYN+ACK
            if (flags & (SYN | ACK) == (SYN | ACK)) {
                conn.recv_next = seq_num +% 1;
                conn.send_unack = ack_num;
                conn.state = .established;
                conn.rto_deadline = 0;
                conn.peer_window = peer_win;

                // Send ACK (safe under tcp_lock — only touches conn + ipv4.send)
                sendSegment(conn, ACK, &[_]u8{});

                // Defer wake
                if (conn.waiting_pid != 0) {
                    wake_pid = conn.waiting_pid;
                    conn.waiting_pid = 0;
                }
                do_epoll_wake = true;
            } else if (flags & RST != 0) {
                conn.state = .closed;
                if (conn.waiting_pid != 0) {
                    wake_pid = conn.waiting_pid;
                    conn.waiting_pid = 0;
                }
                do_epoll_wake = true;
            }
        },
        .syn_received => {
            // Server-side: expecting ACK to complete 3-way handshake
            if (flags & ACK != 0) {
                conn.send_unack = ack_num;
                conn.state = .established;
                // Defer queueAcceptedConnection (acquires socket_lock)
                do_queue_accept = true;
                accept_local_port = conn.local_port;
                accept_conn_idx = conn_idx;
            } else if (flags & RST != 0) {
                conn.state = .closed;
                conn.in_use = false;
                do_epoll_wake = true;
            }
        },
        .established => {
            if (flags & RST != 0) {
                conn.state = .closed;
                if (conn.waiting_pid != 0) {
                    wake_pid = conn.waiting_pid;
                    conn.waiting_pid = 0;
                }

                tcp_lock.release();

                if (wake_pid != 0) scheduler.wakeProcess(wake_pid);
                return;
            }

            // Process ACK with retransmission/congestion logic
            if (flags & ACK != 0) {
                processAck(conn, ack_num, peer_win);
            }

            // Process incoming data with out-of-order reassembly
            if (payload.len > 0) {
                if (seq_num == conn.recv_next) {
                    // In-order segment — deliver directly
                    deliverPayload(conn, payload);

                    // Drain any contiguous OOO segments that now fit
                    drainOooQueue(conn);

                    // Send ACK for all delivered data
                    sendSegment(conn, ACK, &[_]u8{});

                    if (conn.waiting_pid != 0) {
                        wake_pid = conn.waiting_pid;
                        conn.waiting_pid = 0;
                    }
                    do_epoll_wake = true;
                } else if (seqAfter(seq_num, conn.recv_next)) {
                    // Out-of-order — buffer for later reassembly
                    storeOooSegment(conn, seq_num, payload);
                    // Send duplicate ACK to trigger fast retransmit of missing data
                    sendSegment(conn, ACK, &[_]u8{});
                }
                // else: old/duplicate segment, ignore
            }

            // Handle FIN
            if (flags & FIN != 0) {
                conn.recv_next +%= 1;
                conn.state = .close_wait;
                sendSegment(conn, ACK, &[_]u8{});
                if (conn.waiting_pid != 0 and wake_pid == 0) {
                    wake_pid = conn.waiting_pid;
                    conn.waiting_pid = 0;
                }
                do_epoll_wake = true;
            }
        },
        .fin_wait_1 => {
            if (flags & ACK != 0) {
                conn.send_unack = ack_num;
                if (flags & FIN != 0) {
                    conn.recv_next +%= 1;
                    conn.state = .time_wait;
                    sendSegment(conn, ACK, &[_]u8{});
                    if (conn.waiting_pid != 0) {
                        wake_pid = conn.waiting_pid;
                        conn.waiting_pid = 0;
                    }
                } else {
                    conn.state = .fin_wait_2;
                }
            }
        },
        .fin_wait_2 => {
            if (flags & FIN != 0) {
                conn.recv_next +%= 1;
                conn.state = .time_wait;
                sendSegment(conn, ACK, &[_]u8{});
                if (conn.waiting_pid != 0) {
                    wake_pid = conn.waiting_pid;
                    conn.waiting_pid = 0;
                }
            }
        },
        .last_ack => {
            if (flags & ACK != 0) {
                conn.state = .closed;
                conn.in_use = false;
                if (conn.waiting_pid != 0) {
                    wake_pid = conn.waiting_pid;
                    conn.waiting_pid = 0;
                }
            }
        },
        else => {},
    }

    tcp_lock.release();

    // --- Deferred actions outside tcp_lock ---
    if (do_queue_accept) {
        // socket.queueAcceptedConnection acquires socket_lock internally
        socket.queueAcceptedConnection(accept_local_port, accept_conn_idx);
    }
    if (wake_pid != 0) {
        scheduler.wakeProcess(wake_pid);
    }
    if (do_epoll_wake) {
        epoll.wakeAllWaiters();
    }
}

/// Initiate a TCP connection (sends SYN).
pub fn connect(conn_idx: usize, dst_ip: u32, dst_port: u16) bool {
    tcp_lock.acquire();

    if (conn_idx >= MAX_TCP_CONNECTIONS or !connections[conn_idx].in_use) {
        tcp_lock.release();
        return false;
    }

    const conn = &connections[conn_idx];
    conn.remote_ip = dst_ip;
    conn.remote_port = dst_port;

    // Use timer tick count as pseudo-random ISN
    conn.send_next = @truncate(timer.getTicks() *% 2654435761);
    conn.send_unack = conn.send_next;

    // Send SYN
    conn.state = .syn_sent;
    sendSegment(conn, SYN, &[_]u8{});
    conn.send_next +%= 1;
    conn.rto_deadline = timer.getTicks() + conn.rto;

    tcp_lock.release();
    return true;
}

/// Send data on an established connection (buffered + congestion-controlled).
pub fn sendData(conn_idx: usize, data: []const u8) isize {
    tcp_lock.acquire();

    if (conn_idx >= MAX_TCP_CONNECTIONS or !connections[conn_idx].in_use) {
        tcp_lock.release();
        return -1;
    }

    const conn = &connections[conn_idx];
    if (conn.state != .established) {
        tcp_lock.release();
        return -1;
    }

    const space = TX_BUF_SIZE - conn.tx_count;
    if (space == 0) {
        tcp_lock.release();
        return -@as(isize, 11); // EAGAIN
    }
    const to_copy: u16 = @truncate(if (data.len > space) space else data.len);

    var i: u16 = 0;
    while (i < to_copy) : (i += 1) {
        const pos = (conn.tx_head +% conn.tx_count +% i) % TX_BUF_SIZE;
        conn.tx_buf[pos] = data[i];
    }
    conn.tx_count += to_copy;

    flushSendBuffer(conn);

    tcp_lock.release();
    return @intCast(to_copy);
}

fn flushSendBuffer(conn: *TcpConnection) void {
    const effective_window = @min(conn.cwnd, @as(u32, conn.peer_window));
    const in_flight: u32 = conn.tx_sent;
    if (in_flight >= effective_window) return;
    const can_send = effective_window - in_flight;
    const unsent = conn.tx_count - conn.tx_sent;
    if (unsent == 0) return;

    const to_send: u16 = @intCast(@min(@min(@as(u32, unsent), can_send), MSS));
    if (to_send == 0) return;

    var payload: [1460]u8 = undefined;
    var j: u16 = 0;
    while (j < to_send) : (j += 1) {
        const pos = (conn.tx_head +% conn.tx_sent +% j) % TX_BUF_SIZE;
        payload[j] = conn.tx_buf[pos];
    }

    if (conn.tx_seg_count < MAX_TX_SEGS) {
        conn.tx_segs[conn.tx_seg_count] = .{ .seq = conn.send_next, .len = to_send, .retransmits = 0 };
        conn.tx_seg_count += 1;
    }

    if (!conn.rtt_measured and conn.tx_seg_count == 1) {
        conn.rtt_seq = conn.send_next;
    }

    sendSegmentWithSeq(conn, PSH | ACK, conn.send_next, payload[0..to_send]);
    conn.send_next +%= @as(u32, to_send);
    conn.tx_sent += to_send;

    if (conn.rto_deadline == 0) {
        conn.rto_deadline = timer.getTicks() + conn.rto;
    }
}

fn processAck(conn: *TcpConnection, ack_num: u32, peer_win: u16) void {
    conn.peer_window = peer_win;
    const old_unack = conn.send_unack;
    const acked_bytes = ack_num -% old_unack;

    if (acked_bytes == 0 or acked_bytes > conn.tx_count) {
        if (ack_num == old_unack and conn.tx_sent > 0) {
            conn.dup_ack_count += 1;
            if (conn.dup_ack_count >= 3 and !conn.in_recovery) {
                fastRetransmit(conn);
            }
        }
        return;
    }

    conn.dup_ack_count = 0;
    conn.send_unack = ack_num;

    if (!conn.rtt_measured) {
        const seq_diff = ack_num -% conn.rtt_seq;
        if (seq_diff > 0 and conn.tx_segs[0].retransmits == 0) {
            const rtt_ticks = timer.getTicks() -| (conn.rto_deadline -| conn.rto);
            updateRto(conn, @truncate(rtt_ticks));
            conn.rtt_measured = true;
        }
    }

    advanceTxBuffer(conn, @truncate(acked_bytes));

    if (conn.in_recovery) {
        if (acked_bytes >= conn.cwnd) conn.in_recovery = false;
    } else if (conn.cwnd < conn.ssthresh) {
        conn.cwnd += MSS;
    } else {
        conn.cwnd += @as(u32, MSS) * MSS / conn.cwnd;
    }

    if (conn.tx_sent > 0) {
        conn.rto_deadline = timer.getTicks() + conn.rto;
    } else {
        conn.rto_deadline = 0;
    }

    conn.rtt_measured = false;
    flushSendBuffer(conn);
}

fn updateRto(conn: *TcpConnection, rtt: u32) void {
    const r: i32 = @intCast(rtt);
    if (conn.srtt == 0) {
        conn.srtt = r * 8;
        conn.rttvar = r * 2;
    } else {
        const diff = if (@divTrunc(conn.srtt, 8) > r) @divTrunc(conn.srtt, 8) - r else r - @divTrunc(conn.srtt, 8);
        conn.rttvar = @divTrunc(3 * conn.rttvar + diff, 4);
        conn.srtt = @divTrunc(7 * conn.srtt + r * 8, 8);
    }
    var rto: u32 = @intCast(@max(1, @divTrunc(conn.srtt, 8) + conn.rttvar));
    if (rto < MIN_RTO) rto = MIN_RTO;
    if (rto > MAX_RTO) rto = MAX_RTO;
    conn.rto = rto;
}

fn fastRetransmit(conn: *TcpConnection) void {
    conn.ssthresh = @max(conn.cwnd / 2, @as(u32, MSS) * 2);
    conn.cwnd = conn.ssthresh + 3 * MSS;
    conn.in_recovery = true;
    if (conn.tx_seg_count > 0) retransmitSegment(conn, 0);
}

fn retransmitSegment(conn: *TcpConnection, seg_idx: usize) void {
    if (seg_idx >= conn.tx_seg_count) return;
    const seg = &conn.tx_segs[seg_idx];
    if (seg.retransmits >= MAX_RETRANSMITS) {
        conn.state = .closed;
        return;
    }

    var payload: [1460]u8 = undefined;
    const offset_in_buf = seg.seq -% conn.send_unack;
    var k: u16 = 0;
    while (k < seg.len) : (k += 1) {
        const pos = (conn.tx_head +% @as(u16, @truncate(offset_in_buf)) +% k) % TX_BUF_SIZE;
        payload[k] = conn.tx_buf[pos];
    }

    seg.retransmits += 1;
    sendSegmentWithSeq(conn, PSH | ACK, seg.seq, payload[0..seg.len]);
    conn.rto = @min(conn.rto * 2, MAX_RTO);
    conn.rto_deadline = timer.getTicks() + conn.rto;
}

fn advanceTxBuffer(conn: *TcpConnection, acked: u16) void {
    conn.tx_head = (conn.tx_head +% acked) % TX_BUF_SIZE;
    conn.tx_count -= acked;
    conn.tx_sent -|= acked;

    var removed: u8 = 0;
    var remaining_ack: u32 = acked;
    for (0..conn.tx_seg_count) |i| {
        if (remaining_ack >= conn.tx_segs[i].len) {
            remaining_ack -= conn.tx_segs[i].len;
            removed += 1;
        } else {
            conn.tx_segs[i].seq +%= @truncate(remaining_ack);
            conn.tx_segs[i].len -= @truncate(remaining_ack);
            break;
        }
    }

    if (removed > 0) {
        var dst: u8 = 0;
        var src: u8 = removed;
        while (src < conn.tx_seg_count) : ({
            dst += 1;
            src += 1;
        }) {
            conn.tx_segs[dst] = conn.tx_segs[src];
        }
        conn.tx_seg_count -= removed;
    }
}

/// Called from net.poll() at 100Hz.
pub fn tcpTimerPoll() void {
    tcp_lock.acquire();
    defer tcp_lock.release();

    const current_tick = timer.getTicks();
    for (0..MAX_TCP_CONNECTIONS) |i| {
        if (!connections[i].in_use) continue;
        const conn = &connections[i];
        if (conn.rto_deadline != 0 and current_tick >= conn.rto_deadline) {
            if (conn.tx_seg_count > 0) {
                conn.ssthresh = @max(conn.cwnd / 2, @as(u32, MSS) * 2);
                conn.cwnd = MSS;
                retransmitSegment(conn, 0);
            } else {
                conn.rto_deadline = 0;
            }
        }
    }
}

// --- Out-of-order reassembly helpers ---

/// Check if seq a is after seq b (handles wraparound)
fn seqAfter(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

/// Deliver payload bytes to connection's RX buffer
fn deliverPayload(conn: *TcpConnection, payload: []const u8) void {
    const space = RX_BUF_SIZE - @as(usize, conn.rx_count);
    const to_copy = if (payload.len > space) space else payload.len;

    for (0..to_copy) |i| {
        const pos = (conn.rx_head +% @as(u16, @truncate(conn.rx_count)) +% @as(u16, @truncate(i))) % RX_BUF_SIZE;
        conn.rx_buf[pos] = payload[i];
    }
    conn.rx_count += @truncate(to_copy);
    conn.recv_next +%= @truncate(to_copy);
}

/// Store an out-of-order segment for later reassembly
fn storeOooSegment(conn: *TcpConnection, seq: u32, payload: []const u8) void {
    // Don't store if payload is too large
    if (payload.len > OOO_BUF_SIZE) return;

    // Check for duplicate — already have this seq?
    for (&conn.ooo_segs) |*seg| {
        if (seg.in_use and seg.seq == seq) return;
    }

    // Find an empty slot
    for (&conn.ooo_segs) |*seg| {
        if (!seg.in_use) {
            seg.seq = seq;
            seg.len = @truncate(payload.len);
            for (0..payload.len) |i| seg.data[i] = payload[i];
            seg.in_use = true;
            return;
        }
    }
    // Queue full — drop this segment (sender will retransmit)
}

/// Drain contiguous segments from the OOO queue
fn drainOooQueue(conn: *TcpConnection) void {
    var drained = true;
    while (drained) {
        drained = false;
        for (&conn.ooo_segs) |*seg| {
            if (seg.in_use and seg.seq == conn.recv_next) {
                deliverPayload(conn, seg.data[0..seg.len]);
                seg.in_use = false;
                drained = true;
                break; // restart scan — recv_next changed
            }
        }
    }
}

fn sendSegmentWithSeq(conn: *TcpConnection, flags: u8, seq: u32, payload: []const u8) void {
    var tcp_pkt: [1500]u8 = undefined;
    const tcp_len = TCP_HEADER_SIZE + payload.len;

    ethernet.putU16BE(tcp_pkt[0..2], conn.local_port);
    ethernet.putU16BE(tcp_pkt[2..4], conn.remote_port);
    ethernet.putU32BE(tcp_pkt[4..8], seq);
    ethernet.putU32BE(tcp_pkt[8..12], conn.recv_next);
    tcp_pkt[12] = (TCP_HEADER_SIZE / 4) << 4;
    tcp_pkt[13] = flags;
    const window: u16 = @truncate(RX_BUF_SIZE - @as(usize, conn.rx_count));
    ethernet.putU16BE(tcp_pkt[14..16], window);
    tcp_pkt[16] = 0;
    tcp_pkt[17] = 0;
    tcp_pkt[18] = 0;
    tcp_pkt[19] = 0;

    for (0..payload.len) |pi| {
        tcp_pkt[TCP_HEADER_SIZE + pi] = payload[pi];
    }

    const tcp_total: u16 = @truncate(tcp_len);
    const pseudo_sum = checksum.pseudoHeaderSum(conn.local_ip, conn.remote_ip, ipv4.PROTO_TCP, tcp_total);
    const cksum = checksum.checksumWithSeed(pseudo_sum, tcp_pkt[0..tcp_len]);
    ethernet.putU16BE(tcp_pkt[16..18], cksum);

    _ = ipv4.send(ipv4.PROTO_TCP, conn.remote_ip, tcp_pkt[0..tcp_len]);
}

/// Read data from rx_buf. Returns bytes read, or 0 if empty.
pub fn recvData(conn_idx: usize, buf: []u8) isize {
    tcp_lock.acquire();

    if (conn_idx >= MAX_TCP_CONNECTIONS or !connections[conn_idx].in_use) {
        tcp_lock.release();
        return -1;
    }

    const conn = &connections[conn_idx];

    if (conn.rx_count == 0) {
        if (conn.state == .close_wait or conn.state == .closed or conn.state == .time_wait) {
            tcp_lock.release();
            return 0; // EOF
        }
        tcp_lock.release();
        return -11; // EAGAIN
    }

    const to_copy: usize = if (buf.len > conn.rx_count) @as(usize, conn.rx_count) else buf.len;

    for (0..to_copy) |i| {
        buf[i] = conn.rx_buf[(conn.rx_head +% @as(u16, @truncate(i))) % RX_BUF_SIZE];
    }

    conn.rx_head = (conn.rx_head +% @as(u16, @truncate(to_copy))) % @as(u16, RX_BUF_SIZE);
    conn.rx_count -= @truncate(to_copy);

    tcp_lock.release();
    return @intCast(to_copy);
}

/// Close a TCP connection (initiate FIN).
pub fn close(conn_idx: usize) void {
    tcp_lock.acquire();

    if (conn_idx >= MAX_TCP_CONNECTIONS or !connections[conn_idx].in_use) {
        tcp_lock.release();
        return;
    }

    const conn = &connections[conn_idx];

    switch (conn.state) {
        .established => {
            sendSegment(conn, FIN | ACK, &[_]u8{});
            conn.send_next +%= 1;
            conn.state = .fin_wait_1;
        },
        .close_wait => {
            sendSegment(conn, FIN | ACK, &[_]u8{});
            conn.send_next +%= 1;
            conn.state = .last_ack;
        },
        else => {
            conn.state = .closed;
            conn.in_use = false;
        },
    }

    tcp_lock.release();
}

// --- Internal ---

/// Internal: find connection with tcp_lock already held.
fn findConnectionLocked(remote_ip: u32, remote_port: u16, local_port: u16) ?usize {
    for (0..MAX_TCP_CONNECTIONS) |i| {
        if (connections[i].in_use and
            connections[i].remote_ip == remote_ip and
            connections[i].remote_port == remote_port and
            connections[i].local_port == local_port)
        {
            return i;
        }
    }
    return null;
}

fn sendSegment(conn: *TcpConnection, flags: u8, payload: []const u8) void {
    var tcp_pkt: [1500]u8 = undefined;
    const tcp_len = TCP_HEADER_SIZE + payload.len;

    ethernet.putU16BE(tcp_pkt[0..2], conn.local_port);
    ethernet.putU16BE(tcp_pkt[2..4], conn.remote_port);
    ethernet.putU32BE(tcp_pkt[4..8], conn.send_next);
    ethernet.putU32BE(tcp_pkt[8..12], conn.recv_next);
    tcp_pkt[12] = (TCP_HEADER_SIZE / 4) << 4; // data offset
    tcp_pkt[13] = flags;
    const window: u16 = @truncate(RX_BUF_SIZE - @as(usize, conn.rx_count));
    ethernet.putU16BE(tcp_pkt[14..16], window); // advertise actual free space
    tcp_pkt[16] = 0; // checksum placeholder
    tcp_pkt[17] = 0;
    tcp_pkt[18] = 0; // urgent pointer
    tcp_pkt[19] = 0;

    // Copy payload
    for (0..payload.len) |i| {
        tcp_pkt[TCP_HEADER_SIZE + i] = payload[i];
    }

    // Compute TCP checksum with pseudo-header
    const tcp_total: u16 = @truncate(tcp_len);
    const pseudo_sum = checksum.pseudoHeaderSum(conn.local_ip, conn.remote_ip, ipv4.PROTO_TCP, tcp_total);
    const cksum = checksum.checksumWithSeed(pseudo_sum, tcp_pkt[0..tcp_len]);
    ethernet.putU16BE(tcp_pkt[16..18], cksum);

    _ = ipv4.send(ipv4.PROTO_TCP, conn.remote_ip, tcp_pkt[0..tcp_len]);
}

fn sendRst(remote_ip: u32, remote_port: u16, local_port: u16, seq: u32, ack: u32, in_flags: u8) void {
    var tcp_pkt: [TCP_HEADER_SIZE]u8 = undefined;

    ethernet.putU16BE(tcp_pkt[0..2], local_port);
    ethernet.putU16BE(tcp_pkt[2..4], remote_port);

    if (in_flags & ACK != 0) {
        ethernet.putU32BE(tcp_pkt[4..8], ack);
        ethernet.putU32BE(tcp_pkt[8..12], 0);
        tcp_pkt[13] = RST;
    } else {
        ethernet.putU32BE(tcp_pkt[4..8], 0);
        ethernet.putU32BE(tcp_pkt[8..12], seq +% 1);
        tcp_pkt[13] = RST | ACK;
    }

    tcp_pkt[12] = (TCP_HEADER_SIZE / 4) << 4;
    ethernet.putU16BE(tcp_pkt[14..16], 0);
    tcp_pkt[16] = 0;
    tcp_pkt[17] = 0;
    tcp_pkt[18] = 0;
    tcp_pkt[19] = 0;

    // Compute checksum
    const pseudo_sum = checksum.pseudoHeaderSum(ipv4.our_ip, remote_ip, ipv4.PROTO_TCP, TCP_HEADER_SIZE);
    const cksum = checksum.checksumWithSeed(pseudo_sum, &tcp_pkt);
    ethernet.putU16BE(tcp_pkt[16..18], cksum);

    _ = ipv4.send(ipv4.PROTO_TCP, remote_ip, &tcp_pkt);
}

fn wakeWaiter(conn: *TcpConnection) void {
    if (conn.waiting_pid != 0) {
        scheduler.wakeProcess(conn.waiting_pid);
        conn.waiting_pid = 0;
    }
}
