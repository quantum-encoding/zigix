/// Memory syscalls — brk heap management.
///
/// Each process has a linear heap region [heap_start, heap_current).
/// brk(0) queries, brk(addr) expands/shrinks, page-aligned.
/// 1 GiB per-process limit (needed for Zig compiler self-hosting).

const types = @import("../types.zig");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const vma = @import("../mm/vma.zig");
const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const scheduler = @import("scheduler.zig");
const errno = @import("errno.zig");

const MAX_HEAP: u64 = 1024 * 1024 * 1024; // 1 GiB

pub fn sysBrk(frame: *idt.InterruptFrame) void {
    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    const requested = frame.rdi;

    // Debug: trace ALL brk calls
    {
        serial.writeString("[brk] pid=");
        writeHex(current.pid);
        serial.writeString(" req=0x");
        writeHex(requested);
        serial.writeString(" cur=0x");
        writeHex(current.heap_current);
        serial.writeString(" start=0x");
        writeHex(current.heap_start);
        serial.writeString("\n");
    }

    // Query current break
    if (requested == 0) {
        frame.rax = current.heap_current;
        return;
    }

    // Page-align the request upward
    const new_break = pageAlignUp(requested);

    // Reject below heap_start
    if (new_break < current.heap_start) {
        frame.rax = current.heap_current;
        return;
    }

    // Enforce heap limit
    if (new_break - current.heap_start > MAX_HEAP) {
        frame.rax = current.heap_current;
        return;
    }

    if (new_break > current.heap_current) {
        // Expand: extend or create a heap VMA — pages allocated on demand via page faults.
        //
        // Note: findHeapVma (match by start == heap_start) is unreliable because
        // mmap(MAP_FIXED) in the heap region can trim/replace the heap VMA, leaving
        // a different VMA (e.g. PROT_NONE mmap) at heap_start.
        // Instead, find the VMA at the current heap boundary and extend it, or
        // create a new VMA if the boundary is not covered.
        const heap_flags: u32 = vma.VMA_READ | vma.VMA_WRITE | vma.VMA_USER;
        var extended = false;

        if (current.heap_current > current.heap_start) {
            // Not the first expansion — find VMA at current heap boundary
            if (vma.findVma(&current.vmas, current.heap_current - 1)) |v| {
                // Only extend if it's a proper heap VMA (anonymous, read-write)
                if (v.inode == null and (v.flags & heap_flags) == heap_flags) {
                    vma.extendVma(v, new_break);
                    extended = true;
                }
            }
        } else {
            // First expansion from zero-size — use the VMA execve created at heap_start
            if (vma.findHeapVma(&current.vmas, current.heap_start)) |v| {
                if (v.inode == null) {
                    vma.extendVma(v, new_break);
                    extended = true;
                }
            }
        }

        if (!extended) {
            // Create a fresh VMA for this brk expansion
            const start = if (current.heap_current > current.heap_start) current.heap_current else current.heap_start;
            _ = vma.addVma(&current.vmas, start, new_break, heap_flags);
        }

        current.heap_current = new_break;

    } else if (new_break < current.heap_current) {
        // Shrink: unmap and free any pages in the shrunk range, then shrink VMA
        var addr = new_break;
        while (addr < current.heap_current) {
            // Only free pages that were actually faulted in
            if (vmm.translate(current.page_table, addr)) |phys| {
                vmm.unmapPage(current.page_table, addr);
                pmm.freePage(phys);
            }
            addr += types.PAGE_SIZE;
        }
        // Find VMA at the new break boundary and shrink it
        if (new_break > current.heap_start) {
            if (vma.findVma(&current.vmas, new_break - 1)) |v| {
                vma.shrinkVma(v, new_break);
            }
        }
        current.heap_current = new_break;

    }

    frame.rax = current.heap_current;
}

fn pageAlignUp(addr: u64) u64 {
    return (addr + types.PAGE_SIZE - 1) & ~(types.PAGE_SIZE - 1);
}

fn zeroPage(phys: types.PhysAddr) void {
    const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    for (0..types.PAGE_SIZE) |i| {
        ptr[i] = 0;
    }
}

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
