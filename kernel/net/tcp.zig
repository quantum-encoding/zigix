/// TCP — Transmission Control Protocol.
/// Supports: 3-way handshake, data send/recv, connection close,
/// retransmission with RTO, RTT measurement (RFC 6298), Reno congestion control.

const serial = @import("../arch/x86_64/serial.zig");
const ethernet = @import("ethernet.zig");
const checksum = @import("checksum.zig");
const ipv4 = @import("ipv4.zig");
const scheduler = @import("../proc/scheduler.zig");
const epoll = @import("../proc/epoll.zig");
const idt = @import("../arch/x86_64/idt.zig");

const TCP_HEADER_SIZE: usize = 20; // No options for MVP

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

pub const MAX_TCP_CONNECTIONS: usize = 64;
const RX_BUF_SIZE: usize = 4096;

// --- Retransmission / Congestion constants ---
const TX_BUF_SIZE: u16 = 8192;
const MAX_TX_SEGS: usize = 6;
const INITIAL_RTO: u32 = 100; // 1s at 100 Hz
const MIN_RTO: u32 = 20; // 200ms
const MAX_RTO: u32 = 6000; // 60s
const MAX_RETRANSMITS: u8 = 8;
const MSS: u16 = 1460; // MTU(1500) - IP(20) - TCP(20)

const TxSegment = struct {
    seq: u32,
    len: u16,
    retransmits: u8,
};

pub const TcpConnection = struct {
    state: TcpState,
    local_port: u16,
    remote_port: u16,
    local_ip: u32,
    remote_ip: u32,
    send_next: u32, // Next sequence number to send
    send_unack: u32, // Oldest unacknowledged sequence
    recv_next: u32, // Next expected sequence number
    rx_buf: [RX_BUF_SIZE]u8,
    rx_head: u16, // Write position
    rx_count: u16, // Bytes available
    waiting_pid: u64,
    in_use: bool,

    // --- Send buffer (circular, stores unacked data) ---
    tx_buf: [TX_BUF_SIZE]u8,
    tx_head: u16, // Read position (oldest unacked byte)
    tx_count: u16, // Total bytes in buffer
    tx_sent: u16, // Bytes sent but not yet acked
    tx_segs: [MAX_TX_SEGS]TxSegment,
    tx_seg_count: u8,

    // --- RTT measurement (RFC 6298) ---
    srtt: i32, // Scaled by 8
    rttvar: i32, // Scaled by 4
    rto: u32, // Current RTO in ticks (100 Hz)
    rtt_seq: u32, // Seq being timed (Karn's algorithm)
    rtt_measured: bool,

    // --- Congestion control (Reno) ---
    cwnd: u32, // Congestion window (bytes)
    ssthresh: u32, // Slow start threshold
    peer_window: u16, // Receiver's advertised window
    dup_ack_count: u8, // For fast retransmit (3 dup ACKs)
    in_recovery: bool,

    // --- RTO timer ---
    rto_deadline: u64, // Tick when RTO fires (0 = stopped)
};

var connections: [MAX_TCP_CONNECTIONS]TcpConnection = [_]TcpConnection{emptyConn()} ** MAX_TCP_CONNECTIONS;
var next_ephemeral_port: u16 = 49152;

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
        // Send buffer
        .tx_buf = [_]u8{0} ** TX_BUF_SIZE,
        .tx_head = 0,
        .tx_count = 0,
        .tx_sent = 0,
        .tx_segs = [_]TxSegment{.{ .seq = 0, .len = 0, .retransmits = 0 }} ** MAX_TX_SEGS,
        .tx_seg_count = 0,
        // RTT
        .srtt = 0,
        .rttvar = 0,
        .rto = INITIAL_RTO,
        .rtt_seq = 0,
        .rtt_measured = false,
        // Congestion
        .cwnd = MSS * 2, // Initial window: 2 segments
        .ssthresh = 65535,
        .peer_window = 4096,
        .dup_ack_count = 0,
        .in_recovery = false,
        // Timer
        .rto_deadline = 0,
    };
}

/// Allocate a TCP connection slot. Returns index or null.
pub fn allocConnection() ?usize {
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

/// Allocate a TCP connection for an incoming server-side handshake.
/// Uses the specified local_port (not ephemeral) and sets state to syn_received.
/// Sends SYN|ACK and returns connection index.
pub fn allocConnectionForServer(local_port: u16, remote_ip: u32, remote_port: u16, syn_seq: u32) ?usize {
    for (0..MAX_TCP_CONNECTIONS) |i| {
        if (!connections[i].in_use) {
            connections[i] = emptyConn();
            connections[i].in_use = true;
            connections[i].local_ip = ipv4.our_ip;
            connections[i].local_port = local_port;
            connections[i].remote_ip = remote_ip;
            connections[i].remote_port = remote_port;
            connections[i].recv_next = syn_seq +% 1;

            // Generate ISN from tick count
            connections[i].send_next = @truncate(idt.getTickCount() *% 2654435761);
            connections[i].send_unack = connections[i].send_next;
            connections[i].state = .syn_received;

            // Send SYN|ACK
            sendSegment(&connections[i], SYN | ACK, &[_]u8{});
            connections[i].send_next +%= 1;

            return i;
        }
    }
    return null;
}

pub fn getConnection(idx: usize) ?*TcpConnection {
    if (idx >= MAX_TCP_CONNECTIONS) return null;
    if (!connections[idx].in_use) return null;
    return &connections[idx];
}

pub fn freeConnection(idx: usize) void {
    if (idx < MAX_TCP_CONNECTIONS) {
        connections[idx].in_use = false;
        connections[idx].state = .closed;
    }
}

/// Handle an incoming TCP segment (payload after IPv4 header).
pub fn handleTcp(src_ip: u32, data: []const u8) void {
    if (data.len < TCP_HEADER_SIZE) return;

    const src_port = ethernet.getU16BE(data[0..2]);
    const dst_port = ethernet.getU16BE(data[2..4]);
    const seq_num = ethernet.getU32BE(data[4..8]);
    const ack_num = ethernet.getU32BE(data[8..12]);
    const data_offset = (data[12] >> 4) * 4;
    const flags = data[13];

    if (data_offset > data.len) return;

    const payload = data[@as(usize, data_offset)..];

    // Find matching connection
    const peer_win = ethernet.getU16BE(data[14..16]);

    const conn_idx = findConnection(src_ip, src_port, dst_port) orelse {
        // No matching connection — check for listening socket on incoming SYN
        if (flags & SYN != 0 and flags & ACK == 0) {
            const sock_mod = @import("socket.zig");
            if (sock_mod.findListeningSocket(dst_port) != null) {
                // Allocate server-side connection and send SYN-ACK
                _ = allocConnectionForServer(dst_port, src_ip, src_port, seq_num);
                return;
            }
        }
        // No listener — send RST if not a RST
        if (flags & RST == 0) {
            sendRst(src_ip, src_port, dst_port, seq_num, ack_num, flags);
        }
        return;
    };

    const conn = &connections[conn_idx];

    switch (conn.state) {
        .syn_sent => {
            // Expecting SYN+ACK
            if (flags & (SYN | ACK) == (SYN | ACK)) {
                conn.recv_next = seq_num +% 1;
                conn.send_unack = ack_num;
                conn.state = .established;
                conn.rto_deadline = 0; // Stop SYN retransmit timer
                conn.peer_window = peer_win;

                // Send ACK
                sendSegment(conn, ACK, &[_]u8{});

                // Wake blocked process
                if (conn.waiting_pid != 0) {
                    scheduler.wakeProcess(conn.waiting_pid);
                    conn.waiting_pid = 0;
                }
                epoll.wakeAllWaiters();
            } else if (flags & RST != 0) {
                conn.state = .closed;
                if (conn.waiting_pid != 0) {
                    scheduler.wakeProcess(conn.waiting_pid);
                    conn.waiting_pid = 0;
                }
                epoll.wakeAllWaiters();
            }
        },
        .syn_received => {
            // Server-side: expecting ACK to complete 3-way handshake
            if (flags & ACK != 0) {
                conn.send_unack = ack_num;
                conn.state = .established;
                // Queue completed connection for accept()
                const sock_mod = @import("socket.zig");
                sock_mod.queueAcceptedConnection(conn.local_port, conn_idx);
            } else if (flags & RST != 0) {
                conn.state = .closed;
                conn.in_use = false;
            }
        },
        .established => {
            if (flags & RST != 0) {
                conn.state = .closed;
                wakeWaiter(conn);
                epoll.wakeAllWaiters();
                return;
            }

            // Process ACK with retransmission/congestion logic
            if (flags & ACK != 0) {
                processAck(conn, ack_num, peer_win);
            }

            // Process incoming data
            if (payload.len > 0 and seq_num == conn.recv_next) {
                const space = RX_BUF_SIZE - @as(usize, conn.rx_count);
                const to_copy = if (payload.len > space) space else payload.len;

                for (0..to_copy) |i| {
                    const pos = (conn.rx_head +% @as(u16, @truncate(conn.rx_count)) +% @as(u16, @truncate(i))) % RX_BUF_SIZE;
                    conn.rx_buf[pos] = payload[i];
                }
                conn.rx_count += @truncate(to_copy);
                conn.recv_next +%= @truncate(to_copy);

                // Send ACK
                sendSegment(conn, ACK, &[_]u8{});

                // Wake blocked reader
                wakeWaiter(conn);
                epoll.wakeAllWaiters();
            }

            // Handle FIN
            if (flags & FIN != 0) {
                conn.recv_next +%= 1;
                conn.state = .close_wait;
                sendSegment(conn, ACK, &[_]u8{});
                wakeWaiter(conn);
                epoll.wakeAllWaiters();
            }
        },
        .fin_wait_1 => {
            if (flags & ACK != 0) {
                conn.send_unack = ack_num;
                if (flags & FIN != 0) {
                    conn.recv_next +%= 1;
                    conn.state = .time_wait;
                    sendSegment(conn, ACK, &[_]u8{});
                    wakeWaiter(conn);
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
                wakeWaiter(conn);
            }
        },
        .last_ack => {
            if (flags & ACK != 0) {
                conn.state = .closed;
                conn.in_use = false;
                wakeWaiter(conn);
            }
        },
        else => {},
    }
}

/// Initiate a TCP connection (blocking 3-way handshake).
pub fn connect(conn_idx: usize, dst_ip: u32, dst_port: u16) bool {
    const conn = getConnection(conn_idx) orelse return false;

    conn.remote_ip = dst_ip;
    conn.remote_port = dst_port;

    // Use PIT tick count as pseudo-random ISN
    conn.send_next = @truncate(idt.getTickCount() *% 2654435761);
    conn.send_unack = conn.send_next;

    // Send SYN
    conn.state = .syn_sent;
    sendSegment(conn, SYN, &[_]u8{});
    conn.send_next +%= 1;

    // Start RTO timer for SYN retransmission
    conn.rto_deadline = idt.getTickCount() + conn.rto;

    return true;
}

/// Send data on an established connection (buffered + congestion-controlled).
pub fn sendData(conn_idx: usize, data: []const u8) isize {
    const conn = getConnection(conn_idx) orelse return -1;
    if (conn.state != .established) return -1;

    // Copy into circular tx_buf
    const space = TX_BUF_SIZE - conn.tx_count;
    if (space == 0) return -@as(isize, 11); // EAGAIN — buffer full
    const to_copy: u16 = @truncate(if (data.len > space) space else data.len);

    var i: u16 = 0;
    while (i < to_copy) : (i += 1) {
        const pos = (conn.tx_head +% conn.tx_count +% i) % TX_BUF_SIZE;
        conn.tx_buf[pos] = data[i];
    }
    conn.tx_count += to_copy;

    // Try to flush what the congestion window allows
    flushSendBuffer(conn);

    return @intCast(to_copy);
}

/// Core sender: transmit while bytes_in_flight < min(cwnd, peer_window).
fn flushSendBuffer(conn: *TcpConnection) void {
    const effective_window = @min(conn.cwnd, @as(u32, conn.peer_window));
    const in_flight: u32 = conn.tx_sent;

    if (in_flight >= effective_window) return;
    const can_send = effective_window - in_flight;
    const unsent = conn.tx_count - conn.tx_sent;
    if (unsent == 0) return;

    const to_send: u16 = @intCast(@min(@min(@as(u32, unsent), can_send), MSS));
    if (to_send == 0) return;

    // Build payload from circular tx_buf
    var payload: [1460]u8 = undefined;
    var j: u16 = 0;
    while (j < to_send) : (j += 1) {
        const pos = (conn.tx_head +% conn.tx_sent +% j) % TX_BUF_SIZE;
        payload[j] = conn.tx_buf[pos];
    }

    // Record segment for retransmission
    if (conn.tx_seg_count < MAX_TX_SEGS) {
        conn.tx_segs[conn.tx_seg_count] = .{
            .seq = conn.send_next,
            .len = to_send,
            .retransmits = 0,
        };
        conn.tx_seg_count += 1;
    }

    // Start RTT measurement on first unacked segment
    if (!conn.rtt_measured and conn.tx_seg_count == 1) {
        conn.rtt_seq = conn.send_next;
    }

    sendSegmentWithSeq(conn, PSH | ACK, conn.send_next, payload[0..to_send]);
    conn.send_next +%= @as(u32, to_send);
    conn.tx_sent += to_send;

    // Start RTO timer if not already running
    if (conn.rto_deadline == 0) {
        conn.rto_deadline = idt.getTickCount() + conn.rto;
    }
}

/// Handle ACK: advance tx_buf, measure RTT, update cwnd, detect dup ACKs.
fn processAck(conn: *TcpConnection, ack_num: u32, peer_win: u16) void {
    conn.peer_window = peer_win;
    const old_unack = conn.send_unack;

    // Check for new data acknowledged
    const acked_bytes = ack_num -% old_unack;
    if (acked_bytes == 0 or acked_bytes > conn.tx_count) {
        // Duplicate ACK
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

    // RTT sample (Karn's algorithm: only measure non-retransmitted segments)
    if (!conn.rtt_measured) {
        const seq_diff = ack_num -% conn.rtt_seq;
        if (seq_diff > 0 and conn.tx_segs[0].retransmits == 0) {
            const rtt_ticks = idt.getTickCount() -| (conn.rto_deadline -| conn.rto);
            updateRto(conn, @truncate(rtt_ticks));
            conn.rtt_measured = true;
        }
    }

    // Advance tx_buf: remove acked bytes
    advanceTxBuffer(conn, @truncate(acked_bytes));

    // Congestion window update
    if (conn.in_recovery) {
        if (acked_bytes >= conn.cwnd) {
            conn.in_recovery = false;
        }
    } else if (conn.cwnd < conn.ssthresh) {
        // Slow start: cwnd += MSS per ACK
        conn.cwnd += MSS;
    } else {
        // Congestion avoidance: cwnd += MSS*MSS/cwnd per ACK
        conn.cwnd += @as(u32, MSS) * MSS / conn.cwnd;
    }

    // Restart RTO timer if data still outstanding, else stop
    if (conn.tx_sent > 0) {
        conn.rto_deadline = idt.getTickCount() + conn.rto;
    } else {
        conn.rto_deadline = 0;
    }

    // Try to send more data
    conn.rtt_measured = false;
    flushSendBuffer(conn);
}

/// RFC 6298 SRTT/RTTVAR/RTO calculation.
fn updateRto(conn: *TcpConnection, rtt: u32) void {
    const r: i32 = @intCast(rtt);
    if (conn.srtt == 0) {
        // First measurement
        conn.srtt = r * 8;
        conn.rttvar = r * 2;
    } else {
        // RTTVAR = (3/4)*RTTVAR + (1/4)*|SRTT/8 - R|
        const diff = if (@divTrunc(conn.srtt, 8) > r) @divTrunc(conn.srtt, 8) - r else r - @divTrunc(conn.srtt, 8);
        conn.rttvar = @divTrunc(3 * conn.rttvar + diff, 4);
        // SRTT = (7/8)*SRTT + (1/8)*R
        conn.srtt = @divTrunc(7 * conn.srtt + r * 8, 8);
    }
    // RTO = SRTT/8 + 4*RTTVAR, clamped to [MIN_RTO, MAX_RTO]
    var rto: u32 = @intCast(@max(1, @divTrunc(conn.srtt, 8) + conn.rttvar));
    if (rto < MIN_RTO) rto = MIN_RTO;
    if (rto > MAX_RTO) rto = MAX_RTO;
    conn.rto = rto;
}

/// On 3 dup ACKs: fast retransmit + enter recovery.
fn fastRetransmit(conn: *TcpConnection) void {
    conn.ssthresh = @max(conn.cwnd / 2, @as(u32, MSS) * 2);
    conn.cwnd = conn.ssthresh + 3 * MSS;
    conn.in_recovery = true;

    // Retransmit oldest unacked segment
    if (conn.tx_seg_count > 0) {
        retransmitSegment(conn, 0);
    }
}

/// Read from circular tx_buf and retransmit segment at given index.
fn retransmitSegment(conn: *TcpConnection, seg_idx: usize) void {
    if (seg_idx >= conn.tx_seg_count) return;
    const seg = &conn.tx_segs[seg_idx];
    if (seg.retransmits >= MAX_RETRANSMITS) {
        // Connection failed — too many retransmits
        conn.state = .closed;
        wakeWaiter(conn);
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

    // Exponential backoff
    conn.rto = @min(conn.rto * 2, MAX_RTO);
    conn.rto_deadline = idt.getTickCount() + conn.rto;
}

/// Remove acked bytes from tx_buf, compact segment array.
fn advanceTxBuffer(conn: *TcpConnection, acked: u16) void {
    conn.tx_head = (conn.tx_head +% acked) % TX_BUF_SIZE;
    conn.tx_count -= acked;
    conn.tx_sent -|= acked;

    // Remove fully-acked segments from the front
    var removed: u8 = 0;
    var remaining_ack: u32 = acked;
    for (0..conn.tx_seg_count) |i| {
        if (remaining_ack >= conn.tx_segs[i].len) {
            remaining_ack -= conn.tx_segs[i].len;
            removed += 1;
        } else {
            // Partial ack — shrink this segment
            conn.tx_segs[i].seq +%= @truncate(remaining_ack);
            conn.tx_segs[i].len -= @truncate(remaining_ack);
            break;
        }
    }

    // Compact segment array
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

/// Called from net.poll() at 100Hz: check RTO deadlines.
pub fn tcpTimerPoll() void {
    const current_tick = idt.getTickCount();
    for (0..MAX_TCP_CONNECTIONS) |i| {
        if (!connections[i].in_use) continue;
        const conn = &connections[i];
        if (conn.rto_deadline != 0 and current_tick >= conn.rto_deadline) {
            // RTO expired — retransmit oldest segment
            if (conn.tx_seg_count > 0) {
                // Multiplicative decrease
                conn.ssthresh = @max(conn.cwnd / 2, @as(u32, MSS) * 2);
                conn.cwnd = MSS; // Reset to 1 MSS
                retransmitSegment(conn, 0);
            } else {
                conn.rto_deadline = 0;
            }
        }
    }
}

/// Like sendSegment() but with explicit sequence number (for retransmits).
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
    const conn = getConnection(conn_idx) orelse return -1;

    if (conn.rx_count == 0) {
        if (conn.state == .close_wait or conn.state == .closed or conn.state == .time_wait) {
            return 0; // EOF
        }
        return -11; // EAGAIN
    }

    const to_copy: usize = if (buf.len > conn.rx_count) @as(usize, conn.rx_count) else buf.len;

    for (0..to_copy) |i| {
        buf[i] = conn.rx_buf[(conn.rx_head +% @as(u16, @truncate(i))) % RX_BUF_SIZE];
    }

    conn.rx_head = (conn.rx_head +% @as(u16, @truncate(to_copy))) % @as(u16, RX_BUF_SIZE);
    conn.rx_count -= @truncate(to_copy);

    return @intCast(to_copy);
}

/// Close a TCP connection (initiate FIN).
pub fn close(conn_idx: usize) void {
    const conn = getConnection(conn_idx) orelse return;

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
}

// --- Internal ---

fn findConnection(remote_ip: u32, remote_port: u16, local_port: u16) ?usize {
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

