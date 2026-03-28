/// Socket syscall handlers (41-50) — socket, connect, accept, sendto, recvfrom, bind, listen, shutdown.

const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const vmm = @import("../mm/vmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const types = @import("../types.zig");
const errno = @import("../proc/errno.zig");
const process = @import("../proc/process.zig");
const scheduler = @import("../proc/scheduler.zig");
const syscall = @import("../proc/syscall.zig");
const vfs = @import("../fs/vfs.zig");
const fd_table = @import("../fs/fd_table.zig");
const socket = @import("socket.zig");
const tcp = @import("tcp.zig");
const udp = @import("udp.zig");
const icmp = @import("icmp.zig");
const ethernet = @import("ethernet.zig");
const ipv4 = @import("ipv4.zig");

/// socket(domain, type, protocol) — nr 41
pub fn sysSocket(frame: *idt.InterruptFrame) void {
    const domain: u16 = @truncate(frame.rdi);
    const sock_type: u16 = @truncate(frame.rsi);
    const protocol: u16 = @truncate(frame.rdx);

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    if (domain != socket.AF_INET) {
        frame.rax = @bitCast(@as(i64, -errno.EAFNOSUPPORT));
        return;
    }

    // Validate type
    if (sock_type != socket.SOCK_STREAM and sock_type != socket.SOCK_DGRAM and sock_type != socket.SOCK_RAW) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const sock_idx = socket.allocSocket(domain, sock_type, protocol) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };

    // Create a VFS FileDescription for this socket
    const desc = vfs.allocFileDescription() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };
    desc.inode = socket.getSocketInode(sock_idx);
    desc.flags = vfs.O_RDWR;
    desc.offset = 0;

    const fd_num = fd_table.fdAlloc(&current.fds, desc) orelse {
        vfs.releaseFileDescription(desc);
        frame.rax = @bitCast(@as(i64, -errno.EMFILE));
        return;
    };


    frame.rax = fd_num;
}

/// connect(sockfd, addr, addrlen) — nr 42
pub fn sysConnect(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const addr_ptr = frame.rsi;
    const addrlen = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Read sockaddr_in from user (16 bytes)
    if (addrlen < 16 or !syscall.validateUserBuffer(addr_ptr, 16)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var sa_buf: [16]u8 = undefined;
    const copied = syscall.copyFromUserRaw(current.page_table, addr_ptr, &sa_buf, 16);
    if (copied < 16) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    // Parse sockaddr_in: family(2) + port(2 BE) + addr(4 BE) + zero(8)
    const sa_family: u16 = @as(u16, sa_buf[0]) | (@as(u16, sa_buf[1]) << 8);
    if (sa_family != socket.AF_INET) {
        frame.rax = @bitCast(@as(i64, -errno.EAFNOSUPPORT));
        return;
    }

    const port = ethernet.getU16BE(sa_buf[2..4]);
    const ip = ethernet.getU32BE(sa_buf[4..8]);

    // Find the socket from the fd's inode
    const sock_idx = getSocketFromDesc(desc) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const sock = socket.getSocket(sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (sock.sock_type == socket.SOCK_STREAM) {
        // TCP connect (blocking)
        const conn = tcp.getConnection(sock.tcp_conn_idx) orelse {
            frame.rax = @bitCast(@as(i64, -errno.ECONNREFUSED));
            return;
        };

        // Check if already connected (syscall restart after wake)
        if (conn.state == .established) {
            sock.remote_ip = ip;
            sock.remote_port = port;
            frame.rax = 0;
            return;
        }

        // If connection failed (RST received), report error
        if (conn.state == .closed and sock.remote_ip != 0) {
            frame.rax = @bitCast(@as(i64, -errno.ECONNREFUSED));
            return;
        }

        // If not already connecting, initiate the handshake
        if (conn.state != .syn_sent) {
            if (!tcp.connect(sock.tcp_conn_idx, ip, port)) {
                frame.rax = @bitCast(@as(i64, -errno.ECONNREFUSED));
                return;
            }
        }

        // Block until connection established or failed
        conn.waiting_pid = current.pid;
        frame.rip -= 2;
        current.state = .blocked_on_net;
        scheduler.blockAndSchedule(frame);
        return;
    } else if (sock.sock_type == socket.SOCK_DGRAM) {
        // UDP connect just sets destination
        sock.remote_ip = ip;
        sock.remote_port = port;
        frame.rax = 0;
    } else {
        // Raw socket — just store remote IP
        sock.remote_ip = ip;
        frame.rax = 0;
    }
}

/// accept(sockfd, addr, addrlen) — nr 43
pub fn sysAccept(frame: *idt.InterruptFrame) void {

    const fd = frame.rdi;
    const addr_ptr = frame.rsi;
    // addrlen_ptr = frame.rdx (ignored for MVP)

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const sock_idx = getSocketFromDesc(desc) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const sock = socket.getSocket(sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (!sock.listening) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    // Check for queued connections
    if (sock.accept_count == 0) {
        // Block until a connection arrives
        sock.accept_waiting_pid = current.pid;
        frame.rip -= 2;
        current.state = .blocked_on_net;
        scheduler.blockAndSchedule(frame);
        return;
    }

    // Dequeue completed connection
    const conn_idx = sock.accept_queue[sock.accept_head];
    sock.accept_head = @truncate((@as(usize, sock.accept_head) + 1) % 4);
    sock.accept_count -= 1;

    const conn = tcp.getConnection(conn_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ECONNABORTED));
        return;
    };

    // Create new socket wrapping this connection
    const new_sock_idx = socket.allocSocketWithConn(socket.AF_INET, socket.SOCK_STREAM, 0, conn_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };

    // Set remote address on the new socket
    const new_sock = socket.getSocket(new_sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };
    new_sock.remote_ip = conn.remote_ip;
    new_sock.remote_port = conn.remote_port;
    new_sock.bound_port = conn.local_port;

    // Create VFS FileDescription + fd
    const new_desc = vfs.allocFileDescription() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENFILE));
        return;
    };
    new_desc.inode = socket.getSocketInode(new_sock_idx);
    new_desc.flags = vfs.O_RDWR;
    new_desc.offset = 0;

    const new_fd = fd_table.fdAlloc(&current.fds, new_desc) orelse {
        vfs.releaseFileDescription(new_desc);
        frame.rax = @bitCast(@as(i64, -errno.EMFILE));
        return;
    };

    // Write peer address to user if requested
    if (addr_ptr != 0) {
        var sa_buf: [16]u8 = [_]u8{0} ** 16;
        sa_buf[0] = @truncate(socket.AF_INET); // sa_family low byte
        sa_buf[1] = @truncate(socket.AF_INET >> 8);
        ethernet.putU16BE(sa_buf[2..4], conn.remote_port);
        ethernet.putU32BE(sa_buf[4..8], conn.remote_ip);
        _ = syscall.copyToUser(current.page_table, addr_ptr, &sa_buf);
    }

    frame.rax = new_fd;
}

/// sendto(sockfd, buf, len, flags, dest_addr, addrlen) — nr 44
pub fn sysSendto(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const buf_addr = frame.rsi;
    const len = frame.rdx;
    // flags = frame.r10 (4th arg)
    const dest_addr = frame.r8;
    const dest_addrlen = frame.r9;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (!syscall.validateUserBuffer(buf_addr, len)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const sock_idx = getSocketFromDesc(desc) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const sock = socket.getSocket(sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Determine destination
    var dst_ip: u32 = sock.remote_ip;
    var dst_port: u16 = sock.remote_port;

    if (dest_addr != 0 and dest_addrlen >= 16) {
        var sa_buf: [16]u8 = undefined;
        const sa_copied = syscall.copyFromUserRaw(current.page_table, dest_addr, &sa_buf, 16);
        if (sa_copied >= 8) {
            dst_port = ethernet.getU16BE(sa_buf[2..4]);
            dst_ip = ethernet.getU32BE(sa_buf[4..8]);
        }
    }

    // Copy user data page-by-page
    const actual_len: usize = if (len > 1472) 1472 else @truncate(len);
    var send_buf: [1472]u8 = undefined;
    var total_copied: usize = 0;
    var addr = buf_addr;
    var remaining = actual_len;

    while (remaining > 0) {
        const page_offset: usize = @truncate(addr & 0xFFF);
        const chunk = @min(remaining, types.PAGE_SIZE - page_offset);

        if (vmm.translate(current.page_table, addr)) |phys| {
            const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
            for (0..chunk) |i| {
                send_buf[total_copied + i] = ptr[i];
            }
            total_copied += chunk;
        } else {
            break;
        }
        addr += chunk;
        remaining -= chunk;
    }

    if (sock.sock_type == socket.SOCK_DGRAM) {
        if (udp.send(sock.bound_port, dst_ip, dst_port, send_buf[0..total_copied])) {
            frame.rax = total_copied;
        } else {
            frame.rax = @bitCast(@as(i64, -errno.EIO));
        }
    } else if (sock.sock_type == socket.SOCK_STREAM) {
        const sent = tcp.sendData(sock.tcp_conn_idx, send_buf[0..total_copied]);
        if (sent >= 0) {
            frame.rax = @as(u64, @bitCast(@as(i64, sent)));
        } else {
            frame.rax = @bitCast(@as(i64, -errno.EIO));
        }
    } else if (sock.sock_type == socket.SOCK_RAW and sock.protocol == socket.IPPROTO_ICMP) {
        // Raw ICMP send — data is a full ICMP packet
        if (ipv4.send(ipv4.PROTO_ICMP, dst_ip, send_buf[0..total_copied])) {
            frame.rax = total_copied;
        } else {
            frame.rax = @bitCast(@as(i64, -errno.EIO));
        }
    } else {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
    }
}

/// recvfrom(sockfd, buf, len, flags, src_addr, addrlen) — nr 45
pub fn sysRecvfrom(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;
    const buf_addr = frame.rsi;
    const len = frame.rdx;
    // flags = frame.r10 (4th arg)
    // src_addr = frame.r8, addrlen = frame.r9 (ignored for MVP)

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (!syscall.validateUserBuffer(buf_addr, len)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const sock_idx = getSocketFromDesc(desc) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const sock = socket.getSocket(sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Read from socket
    var kernel_buf: [4096]u8 = undefined;
    const read_len: usize = if (len > 4096) 4096 else @truncate(len);

    var result: isize = 0;

    if (sock.sock_type == socket.SOCK_STREAM) {
        result = tcp.recvData(sock.tcp_conn_idx, kernel_buf[0..read_len]);
    } else if (sock.sock_type == socket.SOCK_DGRAM) {
        if (sock.udp_rx_count == 0) {
            sock.blocked_pid = current.pid;
            result = -11; // EAGAIN
        } else {
            const to_copy: usize = if (read_len > sock.udp_rx_count) @as(usize, sock.udp_rx_count) else read_len;
            for (0..to_copy) |i| {
                kernel_buf[i] = sock.udp_rx_buf[(sock.udp_rx_head +% @as(u16, @truncate(i))) % 2048];
            }
            sock.udp_rx_head = (sock.udp_rx_head +% @as(u16, @truncate(to_copy))) % 2048;
            sock.udp_rx_count -= @truncate(to_copy);
            result = @intCast(to_copy);
        }
    } else if (sock.sock_type == socket.SOCK_RAW and sock.protocol == socket.IPPROTO_ICMP) {
        if (!sock.icmp_rx_ready) {
            sock.blocked_pid = current.pid;
            result = -11; // EAGAIN
        } else {
            const to_copy: usize = if (read_len > sock.icmp_rx_len) @as(usize, sock.icmp_rx_len) else read_len;
            for (0..to_copy) |i| {
                kernel_buf[i] = sock.icmp_rx_buf[i];
            }
            sock.icmp_rx_ready = false;
            result = @intCast(to_copy);
        }
    }

    if (result == -11) {
        // EAGAIN — block. Set waiting_pid so the wake callback can find us.
        if (sock.sock_type == socket.SOCK_STREAM) {
            if (tcp.getConnection(sock.tcp_conn_idx)) |conn| {
                conn.waiting_pid = current.pid;
            }
        }
        frame.rip -= 2;
        current.state = .blocked_on_net;
        scheduler.blockAndSchedule(frame);
        return;
    }

    if (result < 0) {
        frame.rax = @bitCast(@as(i64, result));
        return;
    }

    // Copy to user
    const bytes: usize = @intCast(result);
    if (bytes > 0) {
        if (syscall.copyToUser(current.page_table, buf_addr, kernel_buf[0..bytes])) {
            frame.rax = bytes;
        } else {
            frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        }
    } else {
        frame.rax = 0;
    }
}

/// bind(sockfd, addr, addrlen) — nr 49
pub fn sysBind(frame: *idt.InterruptFrame) void {

    const fd = frame.rdi;
    const addr_ptr = frame.rsi;
    const addrlen = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (addrlen < 16 or !syscall.validateUserBuffer(addr_ptr, 16)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var sa_buf: [16]u8 = undefined;
    const copied = syscall.copyFromUserRaw(current.page_table, addr_ptr, &sa_buf, 16);
    if (copied < 8) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    const port = ethernet.getU16BE(sa_buf[2..4]);

    const sock_idx = getSocketFromDesc(desc) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const sock = socket.getSocket(sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    sock.bound_port = port;

    frame.rax = 0;
}

/// listen(sockfd, backlog) — nr 50
pub fn sysListen(frame: *idt.InterruptFrame) void {

    const fd = frame.rdi;
    // backlog = frame.rsi (ignored — fixed accept queue of 4)

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const sock_idx = getSocketFromDesc(desc) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const sock = socket.getSocket(sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    // Must be a bound TCP socket
    if (sock.sock_type != socket.SOCK_STREAM) {
        frame.rax = @bitCast(@as(i64, -errno.EOPNOTSUPP));
        return;
    }
    if (sock.bound_port == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    // Free the pre-allocated TCP connection (listening sockets don't use one)
    tcp.freeConnection(sock.tcp_conn_idx);
    sock.tcp_conn_idx = tcp.MAX_TCP_CONNECTIONS; // sentinel

    sock.listening = true;

    frame.rax = 0;
}

/// shutdown(sockfd, how) — nr 48
pub fn sysShutdown(frame: *idt.InterruptFrame) void {
    const fd = frame.rdi;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const desc = fd_table.fdGet(&current.fds, fd) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    const sock_idx = getSocketFromDesc(desc) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };
    const sock = socket.getSocket(sock_idx) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EBADF));
        return;
    };

    if (sock.sock_type == socket.SOCK_STREAM) {
        tcp.close(sock.tcp_conn_idx);
    }

    frame.rax = 0;
}

// --- Helper ---

fn getSocketFromDesc(desc: *vfs.FileDescription) ?usize {
    return socket.getSocketIndexFromInode(desc.inode);
}

/// Get a Socket pointer from an inode. Used by getsockname/getpeername.
pub fn getSocketFromInode(inode: *vfs.Inode) ?*socket.Socket {
    const idx = socket.getSocketIndexFromInode(inode) orelse return null;
    return socket.getSocket(idx);
}
