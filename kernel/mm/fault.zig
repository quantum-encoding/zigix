/// Page fault resolution — demand paging and copy-on-write.
///
/// Called from the IDT exception handler before declaring a page fault fatal.
/// Returns true if the fault was resolved (caller should return to resume
/// the faulting instruction). Returns false for unresolvable faults.

const types = @import("../types.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const hhdm = @import("hhdm.zig");
const vma = @import("vma.zig");
const vfs = @import("../fs/vfs.zig");
const serial = @import("../arch/x86_64/serial.zig");
const scheduler = @import("../proc/scheduler.zig");
const swap = @import("swap.zig");
const spinlock = @import("../arch/x86_64/spinlock.zig");

/// SMP lock protecting page table modifications (CoW, demand paging, fork).
/// Prevents two CPUs from simultaneously modifying the same PTE when
/// processes share address spaces (fork without exec).
pub var pt_lock: spinlock.IrqSpinlock = .{};
const page_cache = @import("page_cache.zig");

const PAGE_SIZE = types.PAGE_SIZE;

var fault_count: u64 = 0;

/// Try to resolve a page fault. Returns true if resolved.
pub fn resolve(cr2: u64, error_code: u64) bool {
    const err: vmm.PageFaultError = @bitCast(error_code);

    // Kernel page faults are always fatal — indicates a kernel bug
    if (!err.user) return false;

    // Periodic page fault progress indicator
    fault_count += 1;
    if (fault_count % 5000 == 0) {
        const pid: u64 = if (scheduler.currentProcess()) |p| p.pid else 0;
        serial.writeString("[pf] #");
        writeHex(fault_count);
        serial.writeString(" pid=");
        writeHex(pid);
        serial.writeString(" cr2=0x");
        writeHex(cr2);
        serial.writeString("\n");
    }

    // Reserved-bit fault (err bit 3) — PTE corruption, cannot resolve.
    // Dump diagnostic page table walk to identify which level is corrupted.
    // Use serial_lock to prevent garbled output from concurrent CPUs.
    if (err.reserved_write) {
        const smp_mod = @import("../arch/x86_64/smp.zig");
        const sflags = serial.serial_lock.acquire();
        const w = serial.writeStringUnlocked;
        w("\n[RSVD-FAULT] CPU=");
        writeHexU(smp_mod.cpuId());
        w(" cr2=0x");
        writeHexU(cr2);
        w(" err=0x");
        writeHexU(error_code);
        if (scheduler.currentProcess()) |p| {
            w(" pid=");
            writeHexU(p.pid);
            w(" st=");
            writeHexU(@intFromEnum(p.state));
            w(" cr3=0x");
            writeHexU(p.page_table);
            // Check which CPUs have this cr3 loaded
            w(" cr3-owners:");
            for (0..smp_mod.MAX_CPUS) |ci| {
                if (smp_mod.cpu_locals[ci].online) {
                    if (smp_mod.cpu_locals[ci].current_process) |cp| {
                        if (cp.page_table == p.page_table) {
                            w(" C");
                            writeHexU(ci);
                        }
                    }
                }
            }
            dumpPageTableWalk(p.page_table, cr2);
        }
        w("\n");
        serial.serial_lock.release(sflags);
        return false;
    }

    // Get the current process
    const proc = scheduler.currentProcess() orelse return false;

    // Page-align the faulting address
    const fault_page = cr2 & ~@as(u64, PAGE_SIZE - 1);

    // Find VMA covering this address
    const v = vma.findVma(&proc.vmas, cr2) orelse {
        // Log unresolvable faults with VMA dump for debugging
        if (proc.pid >= 2) {
            serial.writeString("[no-vma] pid=");
            writeHex(proc.pid);
            serial.writeString(" cr2=0x");
            writeHex(cr2);
            serial.writeString(" vmas:");
            for (0..vma.MAX_VMAS) |vi| {
                if (proc.vmas[vi].in_use) {
                    serial.writeString(" [0x");
                    writeHex(proc.vmas[vi].start);
                    serial.writeString("-0x");
                    writeHex(proc.vmas[vi].end);
                    serial.writeString("]");
                }
            }
            serial.writeString("\n");
        }
        return false;
    };

    // Guard page check — bottom page(s) of stack VMAs are poisoned
    if (v.guard_pages > 0) {
        const guard_limit = v.start + @as(u64, v.guard_pages) * PAGE_SIZE;
        if (cr2 < guard_limit) {
            serial.writeString("[guard] Stack overflow PID=");
            writeHex(proc.pid);
            serial.writeString(" addr=0x");
            writeHex(cr2);
            serial.writeString(" guard=0x");
            writeHex(v.start);
            serial.writeString("-0x");
            writeHex(guard_limit);
            serial.writeString("\n");
            return false; // Triggers SIGSEGV in idt.zig
        }
    }

    if (!err.present) {
        // Check if this is a swapped-out page before demand paging
        if (swap.isActive()) {
            if (vmm.getPTE(proc.page_table, fault_page)) |pte| {
                if (swap.isSwapPte(pte.*)) {
                    const is_writable = (v.flags & vma.VMA_WRITE) != 0;
                    const is_user = (v.flags & vma.VMA_USER) != 0;
                    const is_nx = (v.flags & vma.VMA_EXEC) == 0;
                    return swap.swapIn(pte, fault_page, is_writable, is_user, is_nx);
                }
            }
        }

        // Not-present fault → demand paging
        const result = handleDemandPage(proc, v, fault_page);
        if (!result) {
            serial.writeString("[fault] demand page FAILED at 0x");
            writeHex(cr2);
            serial.writeString("\n");
        }
        return result;
    } else if (err.write) {
        // Write to read-only page → check CoW
        return handleCow(proc, fault_page);
    }

    // Other protection violations (e.g. exec on NX page) are fatal
    return false;
}

/// Kernel-callable demand paging for user addresses.
/// Called from sysWrite/sysRead when vmm.translate fails for a user buffer.
/// Checks VMAs and maps the page if it's a valid demand-page address.
/// Returns true if the page was successfully mapped.
pub fn demandPageUser(addr: u64) bool {
    const proc = scheduler.currentProcess() orelse return false;
    const fault_page = addr & ~@as(u64, PAGE_SIZE - 1);
    const v = vma.findVma(&proc.vmas, addr) orelse return false;
    // Guard page check
    if (v.guard_pages > 0) {
        const guard_limit = v.start + @as(u64, v.guard_pages) * PAGE_SIZE;
        if (addr < guard_limit) return false;
    }
    return handleDemandPage(proc, v, fault_page);
}

/// Demand paging: allocate a zero page and map it.
/// For file-backed VMAs, reads file data into the page.
/// BSS-aware: only reads min(PAGE_SIZE, file_size - page_offset_in_vma) bytes;
/// pages beyond file_size are pure BSS (already zeroed).
fn handleDemandPage(proc: anytype, v: *vma.Vma, fault_page: u64) bool {
    const dp_flags = pt_lock.acquire();
    defer pt_lock.release(dp_flags);

    // Check if page was already mapped by another CPU while we waited for the lock
    if (vmm.translate(proc.page_table, fault_page) != null) return true;

    // Allocate a physical page
    const phys = pmm.allocPage() orelse return false;

    // Zero the page via HHDM
    zeroPage(phys);

    // If file-backed VMA, read file data into the page
    if (v.inode) |inode_ptr| {
        const page_offset_in_vma = fault_page - v.start;

        // Check if this page is within the file-backed range
        // file_size > 0 means the VMA has BSS awareness (ELF segments)
        // file_size == 0 means read the full page (mmap file-backed)
        const should_read = if (v.file_size > 0)
            page_offset_in_vma < v.file_size
        else
            true;

        if (should_read) {
            const inode: *vfs.Inode = @alignCast(@ptrCast(inode_ptr));
            const file_pos = v.file_offset + page_offset_in_vma;
            const page_index: u32 = @truncate(file_pos / PAGE_SIZE);
            const ino: u32 = @truncate(inode.ino);

            // BSS boundary pages need special handling — the page cache is indexed
            // by (ino, page_index) and doesn't distinguish code vs data VMAs.
            // A cached page from one VMA might have wrong BSS zeroing for another.
            // Skip cache entirely for pages that straddle the file/BSS boundary.
            const is_bss_boundary = v.file_size > 0 and page_offset_in_vma + PAGE_SIZE > v.file_size and page_offset_in_vma < v.file_size;

            var used_cache = false;
            if (!is_bss_boundary) {
                if (page_cache.lookup(ino, page_index)) |cached_phys| {
                    const dst: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
                    const src: [*]const u8 = @ptrFromInt(hhdm.physToVirt(cached_phys));
                    for (0..PAGE_SIZE) |i| dst[i] = src[i];
                    used_cache = true;
                }
            }

            if (!used_cache) {
                const read_fn = inode.ops.read orelse {
                    pmm.freePage(phys);
                    return false;
                };

                // For BSS-aware VMAs, limit read to file_size boundary
                const read_len: usize = if (v.file_size > 0) blk: {
                    const remaining_file = v.file_size - page_offset_in_vma;
                    break :blk if (remaining_file < PAGE_SIZE) @as(usize, @truncate(remaining_file)) else PAGE_SIZE;
                } else PAGE_SIZE;

                var tmp_desc = vfs.FileDescription{
                    .inode = inode,
                    .offset = file_pos,
                    .flags = vfs.O_RDONLY,
                    .ref_count = 1,
                    .in_use = true,
                };
                const buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
                const bytes_read = read_fn(&tmp_desc, buf, read_len);
                if (bytes_read == 0 and read_len > 0) {
                    serial.writeString("[demand-page] read 0 bytes! ino=");
                    writeHex(ino);
                    serial.writeString(" fpos=0x");
                    writeHex(file_pos);
                    serial.writeString(" vma=0x");
                    writeHex(v.start);
                    serial.writeString("-0x");
                    writeHex(v.end);
                    serial.writeString(" fault=0x");
                    writeHex(fault_page);
                    serial.writeString("\n");
                }

                // Only cache full pages (no BSS boundary) to prevent cross-VMA contamination
                if (!is_bss_boundary) {
                    page_cache.insert(ino, page_index, phys);
                }
            }
        }
        // If !should_read, page is pure BSS — already zeroed
    }

    // Determine mapping flags from VMA
    const flags = vmm.MapFlags{
        .writable = (v.flags & vma.VMA_WRITE) != 0,
        .user = (v.flags & vma.VMA_USER) != 0,
        .no_execute = (v.flags & vma.VMA_EXEC) == 0,
    };

    // Map the page
    vmm.mapPage(proc.page_table, fault_page, phys, flags) catch {
        pmm.freePage(phys);
        return false;
    };

    return true;
}

/// Copy-on-Write: copy the page if shared, or just remap writable if last ref.
fn handleCow(proc: anytype, fault_page: u64) bool {
    const cow_flags = pt_lock.acquire();
    defer pt_lock.release(cow_flags);

    // Get the PTE
    const pte = vmm.getPTE(proc.page_table, fault_page) orelse return false;

    // Check the CoW bit
    if (pte.os_bits & vmm.PTE_COW == 0) return false; // Not a CoW page

    const old_phys = pte.getPhysAddr();
    const ref = pmm.getRef(old_phys);

    if (ref <= 1) {
        // Last reference — make writable and clear CoW via atomic u64 write.
        var raw: u64 = @bitCast(pte.*);
        raw |= @as(u64, 2); // Set writable (bit 1)
        raw &= ~(@as(u64, 1) << 9); // Clear CoW in os_bits (bit 9)
        pte.* = @bitCast(raw);
        vmm.invlpg(fault_page);
        // No tlbShootdown needed: stale read-only TLB on other CPUs just causes
        // a harmless re-fault that sees CoW already resolved and retries.

        return true;
    }

    // Multiple references — copy the page
    const new_phys = pmm.allocPage() orelse return false;

    // Copy page data via HHDM
    copyPage(new_phys, old_phys);

    // Drop our reference to the old page
    _ = pmm.decRef(old_phys);

    // Update PTE to point to new page, writable, no CoW.
    const nx = pte.no_execute;
    pte.* = .{
        .present = true,
        .writable = true,
        .user = true,
        .no_execute = nx,
    };
    pte.setPhysAddr(new_phys);
    vmm.invlpg(fault_page);
    // No tlbShootdown: other CPUs had the old read-only mapping cached.
    // They'll fault on write, re-enter CoW, see ref=1, and resolve cleanly.

    return true;
}

fn zeroPage(phys: types.PhysAddr) void {
    const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    for (0..PAGE_SIZE) |i| {
        ptr[i] = 0;
    }
}

fn copyPage(dst_phys: types.PhysAddr, src_phys: types.PhysAddr) void {
    const dst: [*]u8 = @ptrFromInt(hhdm.physToVirt(dst_phys));
    const src: [*]const u8 = @ptrFromInt(hhdm.physToVirt(src_phys));
    for (0..PAGE_SIZE) |i| {
        dst[i] = src[i];
    }
}

// --- Diagnostic: page table walk dump for reserved-bit faults ---
// NOTE: Caller must hold serial_lock. Uses writeStringUnlocked.

fn dumpPageTableWalk(pml4_phys: u64, virt: u64) void {
    const w = serial.writeStringUnlocked;
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    w("\n  PML4[");
    writeHexU(pml4_idx);
    w("]=");

    const pml4: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, pml4_phys);
    const pml4e_raw: u64 = @bitCast(pml4.entries[pml4_idx]);
    writeHexU(pml4e_raw);

    if (pml4e_raw & 1 == 0) { w(" NOT-PRESENT"); return; }
    const pdpt_phys = pml4e_raw & 0x000FFFFFFFFFF000;
    w("\n  PDPT[");
    writeHexU(pdpt_idx);
    w("]=");

    const pdpt: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, pdpt_phys);
    const pdpte_raw: u64 = @bitCast(pdpt.entries[pdpt_idx]);
    writeHexU(pdpte_raw);

    if (pdpte_raw & 1 == 0) { w(" NOT-PRESENT"); return; }
    if (pdpte_raw & 0x80 != 0) { w(" HUGE-1G"); return; }
    if (pdpte_raw & 0x000FC00000000000 != 0) { w(" <<<RSVD-BITS>>>"); }

    const pd_phys = pdpte_raw & 0x000FFFFFFFFFF000;
    w("\n  PD[");
    writeHexU(pd_idx);
    w("]=");

    const pd: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, pd_phys);
    const pde_raw: u64 = @bitCast(pd.entries[pd_idx]);
    writeHexU(pde_raw);

    if (pde_raw & 1 == 0) { w(" NOT-PRESENT"); return; }
    if (pde_raw & 0x80 != 0) { w(" HUGE-2M"); return; }
    if (pde_raw & 0x000FC00000000000 != 0) { w(" <<<RSVD-BITS>>>"); }

    const pt_phys = pde_raw & 0x000FFFFFFFFFF000;
    w("\n  PT[");
    writeHexU(pt_idx);
    w("]=");

    const pt: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, pt_phys);
    const pte_raw: u64 = @bitCast(pt.entries[pt_idx]);
    writeHexU(pte_raw);

    if (pte_raw & 0x000FC00000000000 != 0) { w(" <<<RSVD-BITS>>>"); }

    // Also dump nearby PT entries (±2) to see corruption pattern
    w("\n  PT-neighbors:");
    const start_idx: usize = if (pt_idx >= 2) pt_idx - 2 else 0;
    const end_idx: usize = if (pt_idx + 3 <= 512) pt_idx + 3 else 512;
    var ni: usize = start_idx;
    while (ni < end_idx) : (ni += 1) {
        const raw: u64 = @bitCast(pt.entries[ni]);
        if (ni == pt_idx) {
            w(" [*");
        } else {
            w(" [");
        }
        writeHexU(ni);
        w("]=");
        writeHexU(raw);
    }
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

/// writeHex that uses writeStringUnlocked — caller must hold serial_lock.
fn writeHexU(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeStringUnlocked(&buf);
}
