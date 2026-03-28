/// RISC-V RTC stub.
///
/// QEMU virt does not provide a Goldfish RTC at a standard MMIO address
/// accessible from S-mode. For now, return epoch 0 and rely on the timer
/// CSR for relative time.

pub fn init() void {}

pub fn getEpochSeconds() u32 {
    return 0;
}
