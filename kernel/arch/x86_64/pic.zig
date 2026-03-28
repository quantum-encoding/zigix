/// 8259A PIC (Programmable Interrupt Controller) driver.
/// Remaps IRQ 0-7 → vectors 32-39, IRQ 8-15 → vectors 40-47.

const io = @import("io.zig");
const klog = @import("../../klog/klog.zig");

// PIC ports
const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

// ICW1 flags
const ICW1_INIT: u8 = 0x10;
const ICW1_ICW4: u8 = 0x01;

// ICW4 flags
const ICW4_8086: u8 = 0x01;

// EOI command
const EOI: u8 = 0x20;

// Vector offsets
pub const IRQ_BASE: u8 = 32;

pub fn init() void {
    // Save current masks
    const mask1 = io.inb(PIC1_DATA);
    const mask2 = io.inb(PIC2_DATA);

    // ICW1: begin initialization sequence
    io.outb(PIC1_CMD, ICW1_INIT | ICW1_ICW4);
    io.ioWait();
    io.outb(PIC2_CMD, ICW1_INIT | ICW1_ICW4);
    io.ioWait();

    // ICW2: vector offset
    io.outb(PIC1_DATA, IRQ_BASE); // IRQ 0-7 → 32-39
    io.ioWait();
    io.outb(PIC2_DATA, IRQ_BASE + 8); // IRQ 8-15 → 40-47
    io.ioWait();

    // ICW3: cascading
    io.outb(PIC1_DATA, 0x04); // Slave on IRQ2
    io.ioWait();
    io.outb(PIC2_DATA, 0x02); // Slave cascade identity
    io.ioWait();

    // ICW4: 8086 mode
    io.outb(PIC1_DATA, ICW4_8086);
    io.ioWait();
    io.outb(PIC2_DATA, ICW4_8086);
    io.ioWait();

    // Restore masks (will be overridden by setMask below)
    _ = mask1;
    _ = mask2;

    // Mask all IRQs except those we need:
    // IRQ0 (timer), IRQ2 (cascade), IRQ4 (COM1 serial RX)
    // Mask bits: 1 = disabled, 0 = enabled
    // ~(1<<0 | 1<<2 | 1<<4) = ~0x15 = 0b11101010 = 0xEA
    io.outb(PIC1_DATA, 0xEA); // IRQ0 + IRQ2 + IRQ4 enabled
    io.outb(PIC2_DATA, 0xFF); // All slave IRQs masked

    const log = klog.scoped(.cpu);
    log.info("pic_remapped", .{});
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        // Slave PIC needs EOI too
        io.outb(PIC2_CMD, EOI);
    }
    io.outb(PIC1_CMD, EOI);
}

pub fn setIrqMask(irq: u8, masked: bool) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const bit: u3 = @truncate(irq & 7);
    const val = io.inb(port);
    if (masked) {
        io.outb(port, val | (@as(u8, 1) << bit));
    } else {
        io.outb(port, val & ~(@as(u8, 1) << bit));
    }
}
