/// Higher Half Direct Map — Limine maps all physical RAM at a fixed virtual offset.
/// This module stores that offset and provides phys<->virt conversion.

const types = @import("../types.zig");
const serial = @import("../arch/x86_64/serial.zig");

var offset: u64 = 0;
var initialized = false;

pub fn init(hhdm_offset: u64) void {
    offset = hhdm_offset;
    initialized = true;

    serial.writeString("[mem]  HHDM offset: 0x");
    writeHex(offset);
    serial.writeString("\n");
}

/// Convert a physical address to its kernel virtual address via HHDM.
pub fn physToVirt(phys: types.PhysAddr) types.VirtAddr {
    // Debug: detect overflow before it triggers safety check panic
    const result = @addWithOverflow(phys, offset);
    if (result[1] != 0) {
        serial.writeString("\n[HHDM] BAD physToVirt! phys=0x");
        writeHex(phys);
        serial.writeString(" offset=0x");
        writeHex(offset);
        // Print return address from stack (caller of physToVirt)
        const rbp = asm volatile ("movq %%rbp, %[rbp]"
            : [rbp] "=r" (-> u64),
        );
        // Return address is at [rbp + 8]
        const ret_addr_ptr: *const u64 = @ptrFromInt(rbp + 8);
        serial.writeString(" caller=0x");
        writeHex(ret_addr_ptr.*);
        // Also print caller's caller at [[rbp] + 8]
        const prev_rbp: *const u64 = @ptrFromInt(rbp);
        const caller2_ptr: *const u64 = @ptrFromInt(prev_rbp.* + 8);
        serial.writeString(" caller2=0x");
        writeHex(caller2_ptr.*);
        serial.writeString("\n");
    }
    return phys +% offset; // Use wrapping add to avoid double-panic
}

/// Convert a kernel HHDM virtual address back to physical.
pub fn virtToPhys(virt: types.VirtAddr) types.PhysAddr {
    return virt - offset;
}

/// Convert a physical address to a typed pointer via HHDM.
pub fn physToPtr(comptime T: type, phys: types.PhysAddr) *T {
    return @ptrFromInt(physToVirt(phys));
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
