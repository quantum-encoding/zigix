/// PS/2 Keyboard driver — IRQ 1, scancode Set 1 to ASCII.
///
/// Reads scancodes from I/O port 0x60, translates to ASCII via scancode table,
/// and pushes bytes into the shared serial input ring buffer. This means keyboard
/// and serial input are unified — the shell reads from one stream.

const io = @import("../arch/x86_64/io.zig");
const serial = @import("../arch/x86_64/serial.zig");
const pic = @import("../arch/x86_64/pic.zig");

const DATA_PORT: u16 = 0x60;
const STATUS_PORT: u16 = 0x64;

// Modifier state
var shift_held: bool = false;
var ctrl_held: bool = false;
var caps_lock: bool = false;

pub fn init() void {
    // Flush any pending data from the keyboard controller
    while ((io.inb(STATUS_PORT) & 0x01) != 0) {
        _ = io.inb(DATA_PORT);
    }

    // Unmask IRQ 1 (keyboard)
    pic.setIrqMask(1, false);

    serial.writeString("[kb]   PS/2 keyboard enabled (IRQ 1)\n");
}

/// Called from IRQ 1 handler in idt.zig.
pub fn irqHandler() void {
    // Check that data is actually available (status bit 0)
    if ((io.inb(STATUS_PORT) & 0x01) == 0) return;

    const scancode = io.inb(DATA_PORT);

    // Extended scancode prefix (0xE0) — skip for now
    if (scancode == 0xE0) return;

    // Key release (break code): bit 7 set
    if (scancode & 0x80 != 0) {
        const make = scancode & 0x7F;
        switch (make) {
            0x2A, 0x36 => shift_held = false, // Left/Right Shift release
            0x1D => ctrl_held = false, // Ctrl release
            else => {},
        }
        return;
    }

    // Key press (make code)
    switch (scancode) {
        0x2A, 0x36 => {
            shift_held = true;
            return;
        },
        0x1D => {
            ctrl_held = true;
            return;
        },
        0x3A => {
            caps_lock = !caps_lock;
            return;
        },
        else => {},
    }

    // Translate scancode to ASCII
    const ascii = translateScancode(scancode);
    if (ascii == 0) return;

    // Handle Ctrl+letter (produce control codes 1-26)
    if (ctrl_held and ascii >= 'a' and ascii <= 'z') {
        serial.pushInputByte(ascii - 'a' + 1);
        return;
    }
    if (ctrl_held and ascii >= 'A' and ascii <= 'Z') {
        serial.pushInputByte(ascii - 'A' + 1);
        return;
    }

    serial.pushInputByte(ascii);
}

fn translateScancode(code: u8) u8 {
    if (code >= scancode_normal.len) return 0;

    var c = scancode_normal[code];
    if (c == 0) return 0;

    // Apply shift
    if (shift_held) {
        if (code < scancode_shifted.len and scancode_shifted[code] != 0) {
            c = scancode_shifted[code];
        }
    }

    // Apply caps lock (toggle case for letters only)
    if (caps_lock) {
        if (c >= 'a' and c <= 'z') {
            c = c - 'a' + 'A';
        } else if (c >= 'A' and c <= 'Z') {
            c = c - 'A' + 'a';
        }
    }

    return c;
}

// Scancode Set 1 → ASCII (unshifted)
// Index = scancode, value = ASCII character (0 = no mapping)
const scancode_normal = [_]u8{
    0,    // 0x00
    0x1B, // 0x01 Esc
    '1',  // 0x02
    '2',  // 0x03
    '3',  // 0x04
    '4',  // 0x05
    '5',  // 0x06
    '6',  // 0x07
    '7',  // 0x08
    '8',  // 0x09
    '9',  // 0x0A
    '0',  // 0x0B
    '-',  // 0x0C
    '=',  // 0x0D
    0x08, // 0x0E Backspace
    '\t', // 0x0F Tab
    'q',  // 0x10
    'w',  // 0x11
    'e',  // 0x12
    'r',  // 0x13
    't',  // 0x14
    'y',  // 0x15
    'u',  // 0x16
    'i',  // 0x17
    'o',  // 0x18
    'p',  // 0x19
    '[',  // 0x1A
    ']',  // 0x1B
    '\n', // 0x1C Enter
    0,    // 0x1D Left Ctrl (modifier)
    'a',  // 0x1E
    's',  // 0x1F
    'd',  // 0x20
    'f',  // 0x21
    'g',  // 0x22
    'h',  // 0x23
    'j',  // 0x24
    'k',  // 0x25
    'l',  // 0x26
    ';',  // 0x27
    '\'', // 0x28
    '`',  // 0x29
    0,    // 0x2A Left Shift (modifier)
    '\\', // 0x2B
    'z',  // 0x2C
    'x',  // 0x2D
    'c',  // 0x2E
    'v',  // 0x2F
    'b',  // 0x30
    'n',  // 0x31
    'm',  // 0x32
    ',',  // 0x33
    '.',  // 0x34
    '/',  // 0x35
    0,    // 0x36 Right Shift (modifier)
    '*',  // 0x37 Keypad *
    0,    // 0x38 Left Alt
    ' ',  // 0x39 Space
    0,    // 0x3A Caps Lock (handled separately)
};

// Shifted scancode mappings (same indices, shifted characters)
const scancode_shifted = [_]u8{
    0,    // 0x00
    0x1B, // 0x01 Esc
    '!',  // 0x02
    '@',  // 0x03
    '#',  // 0x04
    '$',  // 0x05
    '%',  // 0x06
    '^',  // 0x07
    '&',  // 0x08
    '*',  // 0x09
    '(',  // 0x0A
    ')',  // 0x0B
    '_',  // 0x0C
    '+',  // 0x0D
    0x08, // 0x0E Backspace
    '\t', // 0x0F Tab
    'Q',  // 0x10
    'W',  // 0x11
    'E',  // 0x12
    'R',  // 0x13
    'T',  // 0x14
    'Y',  // 0x15
    'U',  // 0x16
    'I',  // 0x17
    'O',  // 0x18
    'P',  // 0x19
    '{',  // 0x1A
    '}',  // 0x1B
    '\n', // 0x1C Enter
    0,    // 0x1D Left Ctrl
    'A',  // 0x1E
    'S',  // 0x1F
    'D',  // 0x20
    'F',  // 0x21
    'G',  // 0x22
    'H',  // 0x23
    'J',  // 0x24
    'K',  // 0x25
    'L',  // 0x26
    ':',  // 0x27
    '"',  // 0x28
    '~',  // 0x29
    0,    // 0x2A Left Shift
    '|',  // 0x2B
    'Z',  // 0x2C
    'X',  // 0x2D
    'C',  // 0x2E
    'V',  // 0x2F
    'B',  // 0x30
    'N',  // 0x31
    'M',  // 0x32
    '<',  // 0x33
    '>',  // 0x34
    '?',  // 0x35
    0,    // 0x36 Right Shift
    '*',  // 0x37
    0,    // 0x38 Left Alt
    ' ',  // 0x39 Space
    0,    // 0x3A Caps Lock
};
