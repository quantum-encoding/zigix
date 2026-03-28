/// EL2 → EL1 Exception Level Drop
///
/// UEFI on real ARM64 hardware hands off at EL2 (hypervisor level).
/// The Zigix kernel expects EL1 (kernel level). This module handles
/// the transition by configuring EL2 system registers and executing ERET.
///
/// On QEMU UEFI, the handoff may already be at EL1, in which case
/// we simply branch directly to the kernel entry.

/// Read current exception level from CurrentEL register.
/// Returns 1 (EL1), 2 (EL2), or 3 (EL3).
pub fn getCurrentEl() u2 {
    var el: u64 = undefined;
    asm volatile ("mrs %[ret], CurrentEL"
        : [ret] "=r" (el),
    );
    return @truncate((el >> 2) & 0x3);
}

/// Jump to the kernel entry point, dropping from EL2 to EL1 if needed.
///
/// After ExitBootServices, this function:
/// 1. Disables the MMU (kernel expects MMU off at entry)
/// 2. If at EL2: configures HCR_EL2 for AArch64 EL1, sets up SPSR/ELR, erets
/// 3. If at EL1: branches directly to kernel with x0 = boot_info_addr
///
/// Does not return.
pub fn jumpToKernel(entry: u64, boot_info_addr: u64) noreturn {
    const el = getCurrentEl();

    if (el == 2) {
        // At EL2: configure and drop to EL1
        asm volatile (
        // Disable EL1 MMU (kernel enables it fresh)
            \\mov x2, xzr
            \\msr SCTLR_EL1, x2
            \\isb

            // HCR_EL2: RW=1 (EL1 is AArch64), all traps disabled
            \\mov x2, #(1 << 31)
            \\msr HCR_EL2, x2

            // Enable FP/SIMD: CPTR_EL2.TFP = 0 (no trapping)
            \\msr CPTR_EL2, xzr

            // Enable FP/SIMD at EL1: CPACR_EL1.FPEN = 0b11
            \\mov x2, #(3 << 20)
            \\msr CPACR_EL1, x2

            // SPSR_EL2: DAIF masked (0xF << 6) + EL1h mode (0x5)
            // = 0b0000_0000_0000_0000_0000_0011_1100_0101 = 0x3c5
            \\mov x2, #0x3c5
            \\msr SPSR_EL2, x2

            // ELR_EL2 = kernel entry point
            \\msr ELR_EL2, %[entry]

            // Set x0 = BootInfo pointer for kernel kmain(x0)
            \\mov x0, %[boot_info]
            // Clear x1-x3 per ARM64 boot protocol
            \\mov x1, xzr
            \\mov x2, xzr
            \\mov x3, xzr

            // Data synchronization barrier + instruction barrier
            \\dsb sy
            \\isb

            // Drop to EL1
            \\eret
            :
            : [entry] "r" (entry),
              [boot_info] "r" (boot_info_addr),
        );
    } else {
        // Already at EL1 (or unexpectedly EL3): direct branch
        asm volatile (
        // Disable MMU at EL1 (kernel enables it fresh)
            \\mrs x2, SCTLR_EL1
            \\bic x2, x2, #1
            \\msr SCTLR_EL1, x2
            \\isb

            // Set x0 = BootInfo pointer
            \\mov x0, %[boot_info]
            \\mov x1, xzr
            \\mov x2, xzr
            \\mov x3, xzr

            // Branch to kernel entry
            \\br %[entry]
            :
            : [entry] "r" (entry),
              [boot_info] "r" (boot_info_addr),
        );
    }

    unreachable;
}
