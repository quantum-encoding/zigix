/// mmap / munmap / mprotect syscall handlers.
///
/// Provides MAP_ANONYMOUS|MAP_PRIVATE (required for Zig's page_allocator)
/// and file-backed private mappings. Address allocation is top-down from
/// 0x7000_0000_0000, below the user stack and above the brk heap.

const types = @import("../types.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const hhdm = @import("hhdm.zig");
const vma = @import("vma.zig");
const serial = @import("../arch/x86_64/serial.zig");
const scheduler = @import("../proc/scheduler.zig");
const idt = @import("../arch/x86_64/idt.zig");
const errno = @import("../proc/errno.zig");
const fd_table = @import("../fs/fd_table.zig");
const vfs = @import("../fs/vfs.zig");

const PAGE_SIZE = types.PAGE_SIZE;

// Linux mmap prot flags
const PROT_READ: u64 = 1;
const PROT_WRITE: u64 = 2;
const PROT_EXEC: u64 = 4;

// Linux mmap flags
const MAP_SHARED: u64 = 0x01;
const MAP_PRIVATE: u64 = 0x02;
const MAP_FIXED: u64 = 0x10;
const MAP_ANONYMOUS: u64 = 0x20;
const MAP_HUGETLB: u64 = 0x40000;
const MAP_HUGE_2MB: u64 = 21 << 26; // log2(2MB)=21, shifted to MAP_HUGE_SHIFT
const MAP_HUGE_1GB: u64 = 30 << 26; // log2(1GB)=30, shifted to MAP_HUGE_SHIFT
const MAP_HUGE_MASK: u64 = 0x3F << 26;

const HUGE_PAGE_SIZE: u64 = pmm.HUGE_PAGE_SIZE; // 2 MiB
const GIGA_PAGE_SIZE: u64 = pmm.GIGA_PAGE_SIZE; // 1 GiB

const process = @import("../proc/process.zig");

fn allocMmapRegion(proc: *process.Process, len: u64) u64 {
    proc.mmap_hint -= len;
    proc.mmap_hint &= ~@as(u64, PAGE_SIZE - 1); // page-align down
    return proc.mmap_hint;
}

fn allocMmapRegionHuge(proc: *process.Process, len: u64) u64 {
    proc.mmap_hint -= len;
    proc.mmap_hint &= ~@as(u64, HUGE_PAGE_SIZE - 1); // 2MB-align down
    return proc.mmap_hint;
}

fn alignUpHuge(len: u64) u64 {
    return (len + HUGE_PAGE_SIZE - 1) & ~@as(u64, HUGE_PAGE_SIZE - 1);
}

/// Align length up to page boundary.
fn alignUp(len: u64) u64 {
    return (len + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);
}

/// Convert Linux prot flags to VMA flags.
fn protToVmaFlags(prot: u64) u32 {
    var flags: u32 = vma.VMA_USER;
    if (prot & PROT_READ != 0) flags |= vma.VMA_READ;
    if (prot & PROT_WRITE != 0) flags |= vma.VMA_WRITE;
    if (prot & PROT_EXEC != 0) flags |= vma.VMA_EXEC;
    return flags;
}

/// mmap(addr, length, prot, flags, fd, offset) — nr 9
/// Args: rdi=addr, rsi=length, rdx=prot, r10=flags, r8=fd, r9=offset
pub fn sysMmap(frame: *idt.InterruptFrame) void {
    const addr = frame.rdi;
    const length = frame.rsi;
    const prot = frame.rdx;
    const flags = frame.r10;
    const fd_val = frame.r8;
    const offset = frame.r9;

    // Validate length
    if (length == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const aligned_len = alignUp(length);

    // W^X enforcement: reject simultaneous write+execute
    if ((prot & PROT_WRITE) != 0 and (prot & PROT_EXEC) != 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    var vma_flags = protToVmaFlags(prot);

    if (flags & MAP_ANONYMOUS != 0) {
        // Anonymous mapping — no file backing
        vma_flags |= vma.VMA_ANON;

        // Huge page path: pre-allocate physically contiguous pages and map immediately.
        // Supports both 2MB (MAP_HUGETLB) and 1GB (MAP_HUGETLB | MAP_HUGE_1GB) pages.
        // This is the DPDK/DMA path — returns pinned contiguous physical memory with
        // known physical addresses, queryable via virt_to_phys syscall (nr 510).
        if (flags & MAP_HUGETLB != 0) {
            const use_giga = (flags & MAP_HUGE_MASK) == MAP_HUGE_1GB;
            const page_sz: u64 = if (use_giga) GIGA_PAGE_SIZE else HUGE_PAGE_SIZE;
            const aligned_huge_len = (length + page_sz - 1) & ~(page_sz - 1);
            const page_count = aligned_huge_len / page_sz;

            var mapped_addr: u64 = undefined;
            if (flags & MAP_FIXED != 0) {
                if (addr & (page_sz - 1) != 0) {
                    frame.rax = @bitCast(@as(i64, -errno.EINVAL));
                    return;
                }
                mapped_addr = addr;
            } else {
                // Align the mmap hint to the page size
                current.mmap_hint -= aligned_huge_len;
                current.mmap_hint &= ~(page_sz - 1);
                mapped_addr = current.mmap_hint;
            }

            // Allocate contiguous physical pages
            const phys = if (use_giga)
                pmm.allocGigaPage() // Single 1GB allocation
            else
                pmm.allocHugePages(page_count); // N contiguous 2MB pages

            const phys_addr = phys orelse {
                frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
                return;
            };

            // Map each page
            const map_flags = vmm.MapFlags{
                .writable = (prot & PROT_WRITE) != 0,
                .user = true,
                .no_execute = (prot & PROT_EXEC) == 0,
            };

            var i: u64 = 0;
            while (i < page_count) : (i += 1) {
                const virt = mapped_addr + i * page_sz;
                const phys_i = phys_addr + i * page_sz;
                if (use_giga) {
                    vmm.mapGigaPage(current.page_table, virt, phys_i, map_flags) catch {
                        var j: u64 = 0;
                        while (j < i) : (j += 1) vmm.unmapGigaPage(current.page_table, mapped_addr + j * page_sz);
                        pmm.freeGigaPage(phys_addr);
                        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
                        return;
                    };
                } else {
                    vmm.mapHugePage(current.page_table, virt, phys_i, map_flags) catch {
                        var j: u64 = 0;
                        while (j < i) : (j += 1) vmm.unmapHugePage(current.page_table, mapped_addr + j * page_sz);
                        pmm.freeHugePage(phys_addr);
                        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
                        return;
                    };
                }
            }

            // Create VMA with hugepage metadata
            vma_flags |= if (use_giga) vma.VMA_GIGAPAGE else vma.VMA_HUGEPAGE;
            if (vma.addMmapVmaHuge(&current.vmas, mapped_addr, mapped_addr + aligned_huge_len, vma_flags, phys_addr) == null) {
                i = 0;
                while (i < page_count) : (i += 1) {
                    if (use_giga) vmm.unmapGigaPage(current.page_table, mapped_addr + i * page_sz)
                    else vmm.unmapHugePage(current.page_table, mapped_addr + i * page_sz);
                }
                if (use_giga) pmm.freeGigaPage(phys_addr) else pmm.freeHugePage(phys_addr);
                frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
                return;
            }

            frame.rax = mapped_addr;
            return;
        }

        var mapped_addr: u64 = undefined;
        if (flags & MAP_FIXED != 0) {
            // MAP_FIXED: use provided address (must be page-aligned)
            if (addr & (PAGE_SIZE - 1) != 0) {
                frame.rax = @bitCast(@as(i64, -errno.EINVAL));
                return;
            }
            mapped_addr = addr;
            // Remove/trim any existing VMAs that overlap the MAP_FIXED range
            _ = vma.handleMapFixedOverlap(&current.vmas, mapped_addr, mapped_addr + aligned_len);
        } else {
            mapped_addr = allocMmapRegion(current, aligned_len);
        }

        // Create VMA (pages allocated on demand via fault handler)
        if (vma.addMmapVma(&current.vmas, mapped_addr, mapped_addr + aligned_len, vma_flags, null, 0) == null) {
            {
                var count: u64 = 0;
                for (0..vma.MAX_VMAS) |vi| {
                    if (current.vmas[vi].in_use) count += 1;
                }
                serial.writeString("[mmap-FAIL] used=");
                serial.writeByte(@as(u8, @truncate((count / 100) % 10)) + '0');
                serial.writeByte(@as(u8, @truncate((count / 10) % 10)) + '0');
                serial.writeByte(@as(u8, @truncate(count % 10)) + '0');
                serial.writeString("\n");
            }
            frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
            return;
        }

        // Debug: log mmap returns
        if (current.pid >= 2) {
            serial.writeString("[mmap] pid=");
            serial.writeByte(@truncate((current.pid / 10) + '0'));
            serial.writeByte(@truncate((current.pid % 10) + '0'));
            serial.writeString(" addr=0x");
            var hbuf: [16]u8 = undefined;
            var hv = mapped_addr;
            var hi: usize = 16;
            while (hi > 0) { hi -= 1; hbuf[hi] = "0123456789abcdef"[@as(usize, @truncate(hv & 0xf))]; hv >>= 4; }
            serial.writeString(&hbuf);
            serial.writeString(" len=0x");
            hv = aligned_len;
            hi = 16;
            while (hi > 0) { hi -= 1; hbuf[hi] = "0123456789abcdef"[@as(usize, @truncate(hv & 0xf))]; hv >>= 4; }
            serial.writeString(&hbuf);
            serial.writeString("\n");
        }

        frame.rax = mapped_addr;
    } else {
        // File-backed mapping
        const fd_signed: i64 = @bitCast(fd_val);
        if (fd_signed < 0) {
            frame.rax = @bitCast(@as(i64, -errno.EBADF));
            return;
        }

        const desc = fd_table.fdGet(&current.fds, fd_val) orelse {
            frame.rax = @bitCast(@as(i64, -errno.EBADF));
            return;
        };

        var mapped_addr: u64 = undefined;
        if (flags & MAP_FIXED != 0) {
            if (addr & (PAGE_SIZE - 1) != 0) {
                frame.rax = @bitCast(@as(i64, -errno.EINVAL));
                return;
            }
            mapped_addr = addr;
            // Remove/trim any existing VMAs that overlap the MAP_FIXED range
            _ = vma.handleMapFixedOverlap(&current.vmas, mapped_addr, mapped_addr + aligned_len);
        } else {
            mapped_addr = allocMmapRegion(current, aligned_len);
        }

        // Store inode pointer (as anyopaque) — cast back in fault handler
        const inode_ptr: *anyopaque = @ptrCast(desc.inode);

        if (vma.addMmapVma(&current.vmas, mapped_addr, mapped_addr + aligned_len, vma_flags, inode_ptr, offset) == null) {
            frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
            return;
        }

        frame.rax = mapped_addr;
    }
}

/// munmap(addr, length) — nr 11
/// Args: rdi=addr, rsi=length
pub fn sysMunmap(frame: *idt.InterruptFrame) void {
    const addr = frame.rdi;
    const length = frame.rsi;

    // Validate: addr must be page-aligned, length > 0
    if (addr & (PAGE_SIZE - 1) != 0 or length == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const aligned_len = alignUp(length);
    const unmap_end = addr + aligned_len;

    // Walk pages in [addr, addr+aligned_len): unmap and free each mapped page
    var page = addr;
    while (page < unmap_end) : (page += PAGE_SIZE) {
        if (vmm.translate(current.page_table, page)) |phys| {
            vmm.unmapPage(current.page_table, page);
            pmm.freePage(phys);
        }
    }

    // Remove/trim/split VMAs that overlap with the munmap range
    _ = vma.handleRangeRemoval(&current.vmas, addr, unmap_end);

    frame.rax = 0;
}

/// mprotect(addr, length, prot) — nr 10
/// Args: rdi=addr, rsi=length, rdx=prot
pub fn sysMprotect(frame: *idt.InterruptFrame) void {
    const addr = frame.rdi;
    const length = frame.rsi;
    const prot = frame.rdx;

    // Validate
    if (addr & (PAGE_SIZE - 1) != 0 or length == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const aligned_len = alignUp(length);
    const prot_end = addr + aligned_len;

    // Verify there is a VMA covering the start of the range
    const v = vma.findVma(&current.vmas, addr) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    };

    // Compute new VMA flags
    var new_flags = protToVmaFlags(prot);
    if (v.inode == null) new_flags |= vma.VMA_ANON;

    // Split/update VMA flags only for the requested range
    if (!vma.splitForProtect(&current.vmas, addr, prot_end, new_flags)) {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    }

    // Walk pages in range, update PTE permissions for any already-mapped pages
    const writable = (prot & PROT_WRITE) != 0;
    const no_execute = (prot & PROT_EXEC) == 0;

    // W^X enforcement: reject simultaneous write+execute
    if (writable and !no_execute) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    var page = addr;
    while (page < prot_end) : (page += PAGE_SIZE) {
        if (vmm.getPTE(current.page_table, page)) |pte| {
            // Atomic u64 write to avoid packed struct field modification issues
            var raw: u64 = @bitCast(pte.*);
            if (writable) raw |= @as(u64, 2) else raw &= ~@as(u64, 2);
            if (no_execute) raw |= @as(u64, 1) << 63 else raw &= ~(@as(u64, 1) << 63);
            // Also update user bit based on new flags
            if (new_flags & vma.VMA_USER != 0) raw |= @as(u64, 4) else raw &= ~@as(u64, 4);
            pte.* = @bitCast(raw);
            vmm.invlpg(page);
        }
    }

    frame.rax = 0;
}

// Linux mremap flags
const MREMAP_MAYMOVE: u64 = 1;

/// mremap(old_addr, old_size, new_size, flags, new_addr) — nr 25
/// Args: rdi=old_addr, rsi=old_size, rdx=new_size, r10=flags, r8=new_addr
pub fn sysMremap(frame: *idt.InterruptFrame) void {
    const old_addr = frame.rdi;
    const old_size = frame.rsi;
    const new_size = frame.rdx;
    const flags = frame.r10;

    // Validate page alignment
    if (old_addr & (PAGE_SIZE - 1) != 0 or old_size == 0 or new_size == 0) {
        frame.rax = @bitCast(@as(i64, -errno.EINVAL));
        return;
    }

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const aligned_old = alignUp(old_size);
    const aligned_new = alignUp(new_size);

    // Find the VMA covering old_addr
    const v = vma.findVma(&current.vmas, old_addr) orelse {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    };

    if (aligned_new <= aligned_old) {
        // --- Shrink ---
        // Unmap and free excess pages
        var page = old_addr + aligned_new;
        while (page < old_addr + aligned_old) : (page += PAGE_SIZE) {
            if (vmm.translate(current.page_table, page)) |phys| {
                vmm.unmapPage(current.page_table, page);
                pmm.freePage(phys);
            }
        }
        // Update VMA end
        v.end = old_addr + aligned_new;
        frame.rax = old_addr;
        return;
    }

    // --- Grow ---
    const new_end = old_addr + aligned_new;

    // Check if we can grow in place (no adjacent VMA conflict)
    var can_grow = true;
    for (0..vma.MAX_VMAS) |i| {
        const other = &current.vmas[i];
        if (!other.in_use) continue;
        // Skip ourselves
        if (other.start == v.start and other.end == v.end) continue;
        // Check overlap: other overlaps with [old_addr+aligned_old, new_end)
        if (other.start < new_end and other.end > old_addr + aligned_old) {
            can_grow = false;
            break;
        }
    }

    if (can_grow) {
        // Extend VMA end (pages demand-faulted)
        v.end = new_end;
        frame.rax = old_addr;
        return;
    }

    // --- Move (MAYMOVE) ---
    if (flags & MREMAP_MAYMOVE == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    }

    // Allocate new region
    const new_addr = allocMmapRegion(current, aligned_new);

    // Create new VMA
    if (vma.addMmapVma(&current.vmas, new_addr, new_addr + aligned_new, v.flags, v.inode, v.file_offset) == null) {
        frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
        return;
    }

    // Copy mapped pages from old to new via HHDM
    var offset: u64 = 0;
    while (offset < aligned_old) : (offset += PAGE_SIZE) {
        if (vmm.translate(current.page_table, old_addr + offset)) |old_phys| {
            // Allocate new page and copy
            const new_phys = pmm.allocPage() orelse break;
            const src: [*]const u8 = @ptrFromInt(hhdm.physToVirt(old_phys));
            const dst: [*]u8 = @ptrFromInt(hhdm.physToVirt(new_phys));
            for (0..PAGE_SIZE) |i| {
                dst[i] = src[i];
            }
            // Map new page
            const map_flags = vmm.MapFlags{
                .writable = (v.flags & vma.VMA_WRITE) != 0,
                .user = (v.flags & vma.VMA_USER) != 0,
                .no_execute = (v.flags & vma.VMA_EXEC) == 0,
            };
            vmm.mapPage(current.page_table, new_addr + offset, new_phys, map_flags) catch {
                pmm.freePage(new_phys);
                break;
            };

            // Unmap and free old page
            vmm.unmapPage(current.page_table, old_addr + offset);
            pmm.freePage(old_phys);
        }
    }

    // Remove old VMA
    _ = vma.removeVma(&current.vmas, old_addr);

    frame.rax = new_addr;
}

// --- Output helpers ---

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}

fn writeDecimal(value: u64) void {
    if (value == 0) {
        serial.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    serial.writeString(buf[i..]);
}
