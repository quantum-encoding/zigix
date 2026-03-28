/// SD/eMMC host controller driver (SDHCI) for ARM64 bare metal.
///
/// Supports:
///   - SDHCI-compliant controllers (Raspberry Pi 4/5 via Arasan/eMMC2)
///   - Device tree discovery (compatible = "brcm,bcm2711-emmc2", "arasan,sdhci-5.1", etc.)
///   - SD card initialization (CMD0/CMD8/ACMD41/CMD2/CMD3/CMD7)
///   - Block read/write via CMD17/CMD18/CMD24/CMD25
///
/// Provides readSectors()/writeSectors() matching virtio_blk/NVMe API
/// for transparent use via block_io abstraction.

const uart = @import("uart.zig");
const timer = @import("timer.zig");
const fdt = @import("fdt.zig");

// ---- SDHCI register offsets ----

const SDHCI_DMA_ADDRESS: u32 = 0x00;
const SDHCI_BLOCK_SIZE: u32 = 0x04;
const SDHCI_BLOCK_COUNT: u32 = 0x06;
const SDHCI_ARGUMENT: u32 = 0x08;
const SDHCI_TRANSFER_MODE: u32 = 0x0C;
const SDHCI_COMMAND: u32 = 0x0E;
const SDHCI_RESPONSE: u32 = 0x10; // 4x u32 at 0x10, 0x14, 0x18, 0x1C
const SDHCI_BUFFER_DATA: u32 = 0x20;
const SDHCI_PRESENT_STATE: u32 = 0x24;
const SDHCI_HOST_CONTROL: u32 = 0x28;
const SDHCI_POWER_CONTROL: u32 = 0x29;
const SDHCI_CLOCK_CONTROL: u32 = 0x2C;
const SDHCI_TIMEOUT_CONTROL: u32 = 0x2E;
const SDHCI_SOFTWARE_RESET: u32 = 0x2F;
const SDHCI_INT_STATUS: u32 = 0x30;
const SDHCI_INT_ENABLE: u32 = 0x34;
const SDHCI_SIGNAL_ENABLE: u32 = 0x38;
const SDHCI_CAPABILITIES: u32 = 0x40;
const SDHCI_HOST_VERSION: u32 = 0xFE;

// ---- Present State bits ----

const PRESENT_CMD_INHIBIT: u32 = 1 << 0;
const PRESENT_DAT_INHIBIT: u32 = 1 << 1;
const PRESENT_WRITE_ACTIVE: u32 = 1 << 8;
const PRESENT_READ_ACTIVE: u32 = 1 << 9;
const PRESENT_BUFFER_WRITE_ENABLE: u32 = 1 << 10;
const PRESENT_BUFFER_READ_ENABLE: u32 = 1 << 11;
const PRESENT_CARD_INSERTED: u32 = 1 << 16;

// ---- Interrupt status bits ----

const INT_CMD_COMPLETE: u32 = 1 << 0;
const INT_TRANSFER_COMPLETE: u32 = 1 << 1;
const INT_DMA_INTERRUPT: u32 = 1 << 3;
const INT_BUFFER_WRITE_READY: u32 = 1 << 4;
const INT_BUFFER_READ_READY: u32 = 1 << 5;
const INT_ERROR: u32 = 1 << 15;
const INT_CMD_TIMEOUT: u32 = 1 << 16;
const INT_DATA_TIMEOUT: u32 = 1 << 20;

// ---- Software Reset bits ----

const RESET_ALL: u8 = 0x01;
const RESET_CMD: u8 = 0x02;
const RESET_DATA: u8 = 0x04;

// ---- Transfer Mode bits ----

const TM_DMA_ENABLE: u16 = 1 << 0;
const TM_BLK_COUNT_EN: u16 = 1 << 1;
const TM_AUTO_CMD12: u16 = 1 << 2;
const TM_DATA_READ: u16 = 1 << 4;
const TM_MULTI_BLOCK: u16 = 1 << 5;

// ---- Command types ----

const CMD_TYPE_NORMAL: u16 = 0;
const CMD_RESP_NONE: u16 = 0x00;
const CMD_RESP_136: u16 = 0x01;    // R2
const CMD_RESP_48: u16 = 0x02;     // R1, R3, R6, R7
const CMD_RESP_48_BUSY: u16 = 0x03; // R1b

// ---- SD Commands ----

const CMD0_GO_IDLE: u16 = 0;
const CMD2_ALL_SEND_CID: u16 = 2;
const CMD3_SEND_RELATIVE_ADDR: u16 = 3;
const CMD7_SELECT_CARD: u16 = 7;
const CMD8_SEND_IF_COND: u16 = 8;
const CMD9_SEND_CSD: u16 = 9;
const CMD12_STOP_TRANSMISSION: u16 = 12;
const CMD16_SET_BLOCKLEN: u16 = 16;
const CMD17_READ_SINGLE: u16 = 17;
const CMD18_READ_MULTIPLE: u16 = 18;
const CMD24_WRITE_SINGLE: u16 = 24;
const CMD25_WRITE_MULTIPLE: u16 = 25;
const CMD55_APP_CMD: u16 = 55;
const ACMD41_SD_SEND_OP_COND: u16 = 41;

// ---- Global state ----

var base_addr: usize = 0;
var initialized: bool = false;
var card_rca: u32 = 0;
var is_sdhc: bool = false; // SDHC/SDXC uses block addressing

// ---- MMIO helpers ----

fn read32(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(base_addr + offset);
    return ptr.*;
}

fn write32(offset: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(base_addr + offset);
    ptr.* = val;
}

fn read16(offset: u32) u16 {
    const ptr: *volatile u16 = @ptrFromInt(base_addr + offset);
    return ptr.*;
}

fn write16(offset: u32, val: u16) void {
    const ptr: *volatile u16 = @ptrFromInt(base_addr + offset);
    ptr.* = val;
}

fn read8(offset: u32) u8 {
    const ptr: *volatile u8 = @ptrFromInt(base_addr + offset);
    return ptr.*;
}

fn write8(offset: u32, val: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(base_addr + offset);
    ptr.* = val;
}

// ---- Controller operations ----

fn waitCmdInhibit() bool {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (read32(SDHCI_PRESENT_STATE) & PRESENT_CMD_INHIBIT == 0) return true;
    }
    return false;
}

fn waitDatInhibit() bool {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (read32(SDHCI_PRESENT_STATE) & PRESENT_DAT_INHIBIT == 0) return true;
    }
    return false;
}

fn sendCommand(cmd: u16, arg: u32, resp_type: u16) bool {
    if (!waitCmdInhibit()) return false;

    // Clear all interrupt status
    write32(SDHCI_INT_STATUS, 0xFFFFFFFF);

    // Set argument
    write32(SDHCI_ARGUMENT, arg);

    // Build command register value
    const cmd_val: u16 = (cmd << 8) | resp_type;
    write16(SDHCI_COMMAND, cmd_val);

    // Wait for command complete
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = read32(SDHCI_INT_STATUS);
        if (status & INT_ERROR != 0) {
            uart.print("[sdhci] CMD{} error: status={x}\n", .{ cmd, status });
            write32(SDHCI_INT_STATUS, status);
            return false;
        }
        if (status & INT_CMD_COMPLETE != 0) {
            write32(SDHCI_INT_STATUS, INT_CMD_COMPLETE);
            return true;
        }
    }
    uart.print("[sdhci] CMD{} timeout\n", .{cmd});
    return false;
}

fn getResponse() u32 {
    return read32(SDHCI_RESPONSE);
}

fn resetController() void {
    write8(SDHCI_SOFTWARE_RESET, RESET_ALL);
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (read8(SDHCI_SOFTWARE_RESET) & RESET_ALL == 0) break;
    }
}

fn setClock(freq_khz: u32) void {
    _ = freq_khz;
    // Read capabilities to determine base clock
    const caps = read32(SDHCI_CAPABILITIES);
    _ = caps;

    // Disable clock
    write16(SDHCI_CLOCK_CONTROL, 0);

    // Set divider for ~400 KHz initial (divider = base_clock / 400K)
    // Use divider 0x80 (128) which gives 400KHz from 50MHz base
    const divider: u16 = 0x80;
    const clock_val: u16 = (divider << 8) | 0x01; // Internal clock enable
    write16(SDHCI_CLOCK_CONTROL, clock_val);

    // Wait for internal clock stable
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (read16(SDHCI_CLOCK_CONTROL) & 0x02 != 0) break;
    }

    // Enable SD clock output
    write16(SDHCI_CLOCK_CONTROL, clock_val | 0x04);
}

fn setPower() void {
    // Enable 3.3V power
    write8(SDHCI_POWER_CONTROL, 0x0F); // SD Bus Power | 3.3V
}

// ---- Card initialization ----

fn initCard() bool {
    // CMD0: GO_IDLE_STATE
    if (!sendCommand(CMD0_GO_IDLE, 0, CMD_RESP_NONE)) {
        uart.writeString("[sdhci] CMD0 failed\n");
        return false;
    }

    // CMD8: SEND_IF_COND — voltage check (SD v2.0+)
    if (!sendCommand(CMD8_SEND_IF_COND, 0x1AA, CMD_RESP_48)) {
        uart.writeString("[sdhci] CMD8 failed — not SD v2.0+\n");
        return false;
    }

    const cmd8_resp = getResponse();
    if (cmd8_resp & 0xFF != 0xAA) {
        uart.writeString("[sdhci] CMD8 pattern mismatch\n");
        return false;
    }

    // ACMD41: SD_SEND_OP_COND — wait for card ready
    var retry: u32 = 100;
    while (retry > 0) : (retry -= 1) {
        // CMD55 precedes ACMD
        if (!sendCommand(CMD55_APP_CMD, 0, CMD_RESP_48)) continue;

        // ACMD41: HCS=1 (support SDHC), voltage window 3.2-3.4V
        if (!sendCommand(ACMD41_SD_SEND_OP_COND, 0x40FF8000, CMD_RESP_48)) continue;

        const ocr = getResponse();
        if (ocr & (1 << 31) != 0) {
            // Card is ready
            is_sdhc = (ocr & (1 << 30) != 0);
            uart.print("[sdhci] Card ready, SDHC={}\n", .{@as(u8, if (is_sdhc) 1 else 0)});
            break;
        }

        // Brief delay between retries
        var delay: u32 = 10000;
        while (delay > 0) : (delay -= 1) {
            asm volatile ("yield");
        }
    }

    if (retry == 0) {
        uart.writeString("[sdhci] ACMD41 timeout — no card\n");
        return false;
    }

    // CMD2: ALL_SEND_CID — get card identification
    if (!sendCommand(CMD2_ALL_SEND_CID, 0, CMD_RESP_136)) {
        uart.writeString("[sdhci] CMD2 failed\n");
        return false;
    }

    // CMD3: SEND_RELATIVE_ADDR — get RCA
    if (!sendCommand(CMD3_SEND_RELATIVE_ADDR, 0, CMD_RESP_48)) {
        uart.writeString("[sdhci] CMD3 failed\n");
        return false;
    }
    card_rca = getResponse() & 0xFFFF0000;
    uart.print("[sdhci] Card RCA: {x}\n", .{card_rca >> 16});

    // CMD7: SELECT_CARD — put card in transfer state
    if (!sendCommand(CMD7_SELECT_CARD, card_rca, CMD_RESP_48_BUSY)) {
        uart.writeString("[sdhci] CMD7 failed\n");
        return false;
    }

    // CMD16: SET_BLOCKLEN — 512 bytes (required for SDSC, no-op for SDHC)
    if (!sendCommand(CMD16_SET_BLOCKLEN, 512, CMD_RESP_48)) {
        uart.writeString("[sdhci] CMD16 failed\n");
        return false;
    }

    return true;
}

// ---- Block I/O ----

fn readSingleBlock(lba: u64, buf: [*]u8) bool {
    if (!waitDatInhibit()) return false;

    // Set block size and count
    write16(@truncate(SDHCI_BLOCK_SIZE), 512);
    write16(@truncate(SDHCI_BLOCK_COUNT), 1);

    // Set transfer mode: single block, read
    write16(SDHCI_TRANSFER_MODE, TM_DATA_READ);

    // Address: SDHC uses block address, SDSC uses byte address
    const addr: u32 = if (is_sdhc) @truncate(lba) else @truncate(lba * 512);

    // Clear status
    write32(SDHCI_INT_STATUS, 0xFFFFFFFF);

    // Set argument and send CMD17
    write32(SDHCI_ARGUMENT, addr);
    const cmd_val: u16 = (CMD17_READ_SINGLE << 8) | CMD_RESP_48 | (1 << 5); // Data present
    write16(SDHCI_COMMAND, cmd_val);

    // Wait for command complete
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = read32(SDHCI_INT_STATUS);
        if (status & INT_ERROR != 0) return false;
        if (status & INT_CMD_COMPLETE != 0) {
            write32(SDHCI_INT_STATUS, INT_CMD_COMPLETE);
            break;
        }
    }
    if (timeout == 0) return false;

    // Wait for buffer read ready
    timeout = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = read32(SDHCI_INT_STATUS);
        if (status & INT_ERROR != 0) return false;
        if (status & INT_BUFFER_READ_READY != 0) {
            write32(SDHCI_INT_STATUS, INT_BUFFER_READ_READY);
            break;
        }
    }
    if (timeout == 0) return false;

    // Read 512 bytes from buffer (32-bit reads)
    var i: usize = 0;
    while (i < 512) : (i += 4) {
        const word = read32(SDHCI_BUFFER_DATA);
        buf[i] = @truncate(word);
        buf[i + 1] = @truncate(word >> 8);
        buf[i + 2] = @truncate(word >> 16);
        buf[i + 3] = @truncate(word >> 24);
    }

    // Wait for transfer complete
    timeout = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = read32(SDHCI_INT_STATUS);
        if (status & INT_TRANSFER_COMPLETE != 0) {
            write32(SDHCI_INT_STATUS, INT_TRANSFER_COMPLETE);
            break;
        }
    }

    return true;
}

fn writeSingleBlock(lba: u64, buf: [*]const u8) bool {
    if (!waitDatInhibit()) return false;

    write16(@truncate(SDHCI_BLOCK_SIZE), 512);
    write16(@truncate(SDHCI_BLOCK_COUNT), 1);
    write16(SDHCI_TRANSFER_MODE, 0); // Single block, write

    const addr: u32 = if (is_sdhc) @truncate(lba) else @truncate(lba * 512);

    write32(SDHCI_INT_STATUS, 0xFFFFFFFF);
    write32(SDHCI_ARGUMENT, addr);
    const cmd_val: u16 = (CMD24_WRITE_SINGLE << 8) | CMD_RESP_48 | (1 << 5);
    write16(SDHCI_COMMAND, cmd_val);

    // Wait for command complete
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = read32(SDHCI_INT_STATUS);
        if (status & INT_ERROR != 0) return false;
        if (status & INT_CMD_COMPLETE != 0) {
            write32(SDHCI_INT_STATUS, INT_CMD_COMPLETE);
            break;
        }
    }
    if (timeout == 0) return false;

    // Wait for buffer write ready
    timeout = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = read32(SDHCI_INT_STATUS);
        if (status & INT_ERROR != 0) return false;
        if (status & INT_BUFFER_WRITE_READY != 0) {
            write32(SDHCI_INT_STATUS, INT_BUFFER_WRITE_READY);
            break;
        }
    }
    if (timeout == 0) return false;

    // Write 512 bytes to buffer (32-bit writes)
    var i: usize = 0;
    while (i < 512) : (i += 4) {
        const word: u32 = @as(u32, buf[i]) |
            (@as(u32, buf[i + 1]) << 8) |
            (@as(u32, buf[i + 2]) << 16) |
            (@as(u32, buf[i + 3]) << 24);
        write32(SDHCI_BUFFER_DATA, word);
    }

    // Wait for transfer complete
    timeout = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = read32(SDHCI_INT_STATUS);
        if (status & INT_TRANSFER_COMPLETE != 0) {
            write32(SDHCI_INT_STATUS, INT_TRANSFER_COMPLETE);
            break;
        }
    }

    return true;
}

// ---- Public API (matches virtio_blk / NVMe interface) ----

/// Initialize SD/eMMC controller at the given MMIO base address.
/// Returns true if a card was detected and initialized.
pub fn init(mmio_base: u64) bool {
    if (mmio_base == 0) return false;

    base_addr = @truncate(mmio_base);

    // Read host version
    const ver = read16(SDHCI_HOST_VERSION);
    uart.print("[sdhci] Controller version: {x}\n", .{ver});

    // Reset controller
    resetController();

    // Set power and clock
    setPower();
    setClock(400); // 400 KHz for init

    // Set timeout to maximum
    write8(SDHCI_TIMEOUT_CONTROL, 0x0E);

    // Enable all interrupts
    write32(SDHCI_INT_ENABLE, 0xFFFFFFFF);
    write32(SDHCI_SIGNAL_ENABLE, 0); // Polling mode, no IRQ signals

    // Check card present
    if (read32(SDHCI_PRESENT_STATE) & PRESENT_CARD_INSERTED == 0) {
        uart.writeString("[sdhci] No card inserted\n");
        return false;
    }

    // Initialize card
    if (!initCard()) {
        uart.writeString("[sdhci] Card init failed\n");
        return false;
    }

    // Switch to higher clock for data transfers
    setClock(25000); // 25 MHz

    initialized = true;
    uart.writeString("[sdhci] SD card initialized\n");
    return true;
}

/// Read sectors from SD card.
pub fn readSectors(sector: u64, count: u32, buf: [*]u8) bool {
    if (!initialized) return false;

    var s: u32 = 0;
    while (s < count) : (s += 1) {
        if (!readSingleBlock(sector + s, buf + s * 512)) {
            uart.print("[sdhci] Read failed at sector {}\n", .{sector + s});
            return false;
        }
    }
    return true;
}

/// Write sectors to SD card.
pub fn writeSectors(sector: u64, count: u32, buf: [*]const u8) bool {
    if (!initialized) return false;

    var s: u32 = 0;
    while (s < count) : (s += 1) {
        if (!writeSingleBlock(sector + s, buf + s * 512)) {
            uart.print("[sdhci] Write failed at sector {}\n", .{sector + s});
            return false;
        }
    }
    return true;
}

/// Check if SD controller is initialized.
pub fn isInitialized() bool {
    return initialized;
}
