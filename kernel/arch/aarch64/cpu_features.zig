/// ARM64 CPU Feature Detection
///
/// Runtime probing of CPU capabilities via ID registers.
/// The kernel always probes at boot — never assumes features based on build target.
/// This allows a single binary to adapt to Cortex-A72 (QEMU), Neoverse N1/N2/V2,
/// Apple M-series, or any future ARMv8/v9 core.
///
/// ID register reference (Arm ARM D17.2):
///   ID_AA64PFR0_EL1  — Processor Feature Register 0 (SVE, FP, AdvSIMD, EL levels)
///   ID_AA64PFR1_EL1  — Processor Feature Register 1 (MTE, SME, RAS)
///   ID_AA64ISAR0_EL1 — Instruction Set Attribute Register 0 (AES, SHA, CRC32, atomics, RNG)
///   ID_AA64ISAR1_EL1 — Instruction Set Attribute Register 1 (PAuth, FCMA, JSCVT, BTI)
///   ID_AA64MMFR0_EL1 — Memory Model Feature Register 0 (PA range, granule support)
///   ID_AA64MMFR1_EL1 — Memory Model Feature Register 1 (PAN, VH, HPDS)
///   ID_AA64MMFR2_EL1 — Memory Model Feature Register 2 (VARANGE, UAO, E0PD)
///   MIDR_EL1         — Main ID Register (implementer, part number, variant, revision)

const uart = @import("uart.zig");

/// CPU feature flags — populated once at boot by probe().
pub var features: Features = .{};

/// CPU identification — populated by probe().
pub var cpu_id: CpuId = .{};

pub const CpuId = struct {
    implementer: u8 = 0,    // MIDR[31:24]
    variant: u4 = 0,        // MIDR[23:20]
    architecture: u4 = 0,   // MIDR[19:16]
    part_number: u12 = 0,   // MIDR[15:4]
    revision: u4 = 0,       // MIDR[3:0]

    // Known implementer codes
    pub const IMPL_ARM: u8 = 0x41;
    pub const IMPL_APPLE: u8 = 0x61;
    pub const IMPL_QUALCOMM: u8 = 0x51;
    pub const IMPL_NVIDIA: u8 = 0x4E;
    pub const IMPL_AMPERE: u8 = 0xC0;

    // Known ARM part numbers
    pub const PART_CORTEX_A53: u12 = 0xD03;
    pub const PART_CORTEX_A57: u12 = 0xD07;
    pub const PART_CORTEX_A72: u12 = 0xD08;
    pub const PART_CORTEX_A76: u12 = 0xD0B;
    pub const PART_NEOVERSE_N1: u12 = 0xD0C;
    pub const PART_NEOVERSE_N2: u12 = 0xD49;
    pub const PART_NEOVERSE_V1: u12 = 0xD40;
    pub const PART_NEOVERSE_V2: u12 = 0xD4F;
    pub const PART_CORTEX_X2: u12 = 0xD48;
    pub const PART_CORTEX_X3: u12 = 0xD4E;

    pub fn implementerName(self: CpuId) []const u8 {
        return switch (self.implementer) {
            0 => "QEMU",    // QEMU -cpu max sets MIDR to 0
            IMPL_ARM => "ARM",
            IMPL_APPLE => "Apple",
            IMPL_QUALCOMM => "Qualcomm",
            IMPL_NVIDIA => "NVIDIA",
            IMPL_AMPERE => "Ampere",
            else => "Unknown",
        };
    }

    pub fn partName(self: CpuId) []const u8 {
        // QEMU -cpu max: MIDR is all zeros
        if (self.implementer == 0 and self.part_number == 0) return "max (virtual)";
        if (self.implementer != IMPL_ARM) return "core";
        return switch (self.part_number) {
            PART_CORTEX_A53 => "Cortex-A53",
            PART_CORTEX_A57 => "Cortex-A57",
            PART_CORTEX_A72 => "Cortex-A72",
            PART_CORTEX_A76 => "Cortex-A76",
            PART_NEOVERSE_N1 => "Neoverse-N1",
            PART_NEOVERSE_N2 => "Neoverse-N2",
            PART_NEOVERSE_V1 => "Neoverse-V1",
            PART_NEOVERSE_V2 => "Neoverse-V2",
            PART_CORTEX_X2 => "Cortex-X2",
            PART_CORTEX_X3 => "Cortex-X3",
            else => "Unknown ARM core",
        };
    }

    pub fn isNeoverseN2(self: CpuId) bool {
        return self.implementer == IMPL_ARM and self.part_number == PART_NEOVERSE_N2;
    }
};

pub const Features = struct {
    // --- ARMv8.0 baseline ---
    fp: bool = false,           // Floating-point
    asimd: bool = false,        // Advanced SIMD (NEON)
    aes: bool = false,          // AES instructions
    sha1: bool = false,         // SHA-1 instructions
    sha256: bool = false,       // SHA-256 instructions
    crc32: bool = false,        // CRC32 instructions
    pmull: bool = false,        // Polynomial multiply long

    // --- ARMv8.1 ---
    pan: bool = false,          // Privileged Access Never
    lor: bool = false,          // Limited Ordering Regions
    lse: bool = false,          // Large System Extensions (atomics)
    vh: bool = false,           // Virtualization Host Extensions

    // --- ARMv8.2 ---
    sve: bool = false,          // Scalable Vector Extension
    ras: bool = false,          // Reliability, Availability, Serviceability
    dot_prod: bool = false,     // Dot Product instructions
    fp16: bool = false,         // Half-precision FP

    // --- ARMv8.3 ---
    pauth: bool = false,        // Pointer Authentication
    fcma: bool = false,         // Floating-point complex multiply-add
    jscvt: bool = false,        // JavaScript conversion instructions

    // --- ARMv8.5 ---
    bti: bool = false,          // Branch Target Identification
    mte: bool = false,          // Memory Tagging Extension
    rng: bool = false,          // Hardware Random Number Generator (RNDR/RNDRRS)
    flagm: bool = false,        // Flag manipulation instructions v2
    sb: bool = false,           // Speculation Barrier

    // --- ARMv9.0 ---
    sve2: bool = false,         // SVE2 (superset of SVE)

    // --- SVE details ---
    sve_vl_bytes: u16 = 0,      // SVE vector length in bytes (16 = 128-bit, 32 = 256-bit, etc.)

    // --- MTE details ---
    mte_version: u4 = 0,        // 0 = none, 1 = MTE (insn only), 2 = full MTE, 3 = MTE3

    // --- Physical address range ---
    pa_range_bits: u8 = 0,      // Physical address width: 32, 36, 40, 44, 48, 52
};

/// Read a system register by name (compile-time string).
inline fn readSysReg(comptime name: []const u8) u64 {
    return asm volatile ("mrs %[ret], " ++ name
        : [ret] "=r" (-> u64),
    );
}

/// Probe all CPU features. Call once on BSP boot, before enabling features.
/// Secondary CPUs should call probeSecondary() which only verifies consistency.
pub fn probe() void {
    // --- MIDR_EL1: CPU identification ---
    const midr = readSysReg("MIDR_EL1");
    cpu_id.implementer = @truncate((midr >> 24) & 0xFF);
    cpu_id.variant = @truncate((midr >> 20) & 0xF);
    cpu_id.architecture = @truncate((midr >> 16) & 0xF);
    cpu_id.part_number = @truncate((midr >> 4) & 0xFFF);
    cpu_id.revision = @truncate(midr & 0xF);

    uart.writeString("[cpu] ");
    uart.writeString(cpu_id.implementerName());
    uart.writeString(" ");
    uart.writeString(cpu_id.partName());
    uart.print(" r{}p{}\n", .{
        @as(u32, cpu_id.variant),
        @as(u32, cpu_id.revision),
    });

    // --- ID_AA64PFR0_EL1: FP, AdvSIMD, SVE, EL levels ---
    const pfr0 = readSysReg("ID_AA64PFR0_EL1");
    const fp_field: u4 = @truncate((pfr0 >> 16) & 0xF);
    const asimd_field: u4 = @truncate((pfr0 >> 20) & 0xF);
    const sve_field: u4 = @truncate((pfr0 >> 32) & 0xF);

    features.fp = (fp_field != 0xF);       // 0xF = not implemented
    features.asimd = (asimd_field != 0xF);  // 0xF = not implemented
    features.sve = (sve_field >= 1);         // 1 = SVE, 2 = SVE2

    // FP16 indicated by fp_field/asimd_field == 1
    features.fp16 = (fp_field == 1) and (asimd_field == 1);

    // --- ID_AA64PFR1_EL1: MTE, SME, RAS ---
    const pfr1 = readSysReg("ID_AA64PFR1_EL1");
    const mte_field: u4 = @truncate((pfr1 >> 8) & 0xF);
    features.mte = (mte_field >= 2);  // 2 = full MTE (allocation tags + check)
    features.mte_version = mte_field;

    const ras_field: u4 = @truncate((pfr0 >> 28) & 0xF);
    features.ras = (ras_field >= 1);

    // --- ID_AA64ISAR0_EL1: AES, SHA, CRC32, atomics, RNG ---
    const isar0 = readSysReg("ID_AA64ISAR0_EL1");
    const aes_field: u4 = @truncate((isar0 >> 4) & 0xF);
    features.aes = (aes_field >= 1);
    features.pmull = (aes_field >= 2);

    const sha1_field: u4 = @truncate((isar0 >> 8) & 0xF);
    features.sha1 = (sha1_field >= 1);

    const sha256_field: u4 = @truncate((isar0 >> 12) & 0xF);
    features.sha256 = (sha256_field >= 1);

    const crc32_field: u4 = @truncate((isar0 >> 16) & 0xF);
    features.crc32 = (crc32_field >= 1);

    const atomics_field: u4 = @truncate((isar0 >> 20) & 0xF);
    features.lse = (atomics_field >= 2);  // 2 = LSE atomics

    const rndr_field: u4 = @truncate((isar0 >> 60) & 0xF);
    features.rng = (rndr_field >= 1);

    const dp_field: u4 = @truncate((isar0 >> 44) & 0xF);
    features.dot_prod = (dp_field >= 1);

    // --- ID_AA64ISAR1_EL1: PAuth, BTI, FCMA, JSCVT ---
    const isar1 = readSysReg("ID_AA64ISAR1_EL1");
    const pauth_field: u4 = @truncate((isar1 >> 4) & 0xF);  // APA field
    const pauth_gpi: u4 = @truncate((isar1 >> 8) & 0xF);    // API field (QARMA or impl-defined)
    features.pauth = (pauth_field >= 1) or (pauth_gpi >= 1);

    const fcma_field: u4 = @truncate((isar1 >> 16) & 0xF);
    features.fcma = (fcma_field >= 1);

    const jscvt_field: u4 = @truncate((isar1 >> 12) & 0xF);
    features.jscvt = (jscvt_field >= 1);

    const sb_field: u4 = @truncate((isar1 >> 36) & 0xF);
    features.sb = (sb_field >= 1);

    // BTI is in ID_AA64PFR1_EL1 bits [3:0]
    const bti_field: u4 = @truncate(pfr1 & 0xF);
    features.bti = (bti_field >= 1);

    // --- ID_AA64MMFR1_EL1: PAN ---
    const mmfr1 = readSysReg("ID_AA64MMFR1_EL1");
    const pan_field: u4 = @truncate((mmfr1 >> 20) & 0xF);
    features.pan = (pan_field >= 1);

    const vh_field: u4 = @truncate((mmfr1 >> 8) & 0xF);
    features.vh = (vh_field >= 1);

    const lor_field: u4 = @truncate((mmfr1 >> 16) & 0xF);
    features.lor = (lor_field >= 1);

    // --- ID_AA64MMFR0_EL1: Physical address range ---
    const mmfr0 = readSysReg("ID_AA64MMFR0_EL1");
    const pa_range: u4 = @truncate(mmfr0 & 0xF);
    features.pa_range_bits = switch (pa_range) {
        0 => 32,
        1 => 36,
        2 => 40,
        3 => 42,
        4 => 44,
        5 => 48,
        6 => 52,
        else => 48,
    };

    // --- SVE vector length (if SVE supported) ---
    if (features.sve) {
        // Check if SVE2 via ID_AA64ZFR0_EL1 (accessible only when SVE is enabled)
        // We'll probe SVE VL after enabling it in boot.zig
        // For now, mark sve2 based on PFR0 SVE field
        features.sve2 = (sve_field >= 2);
    }

    // Print summary
    printFeatures();
}

/// Probe SVE vector length. Must be called AFTER SVE is enabled in CPACR_EL1.
pub fn probeSveVectorLength() void {
    if (!features.sve) return;

    // RDVL Xd, #1 — returns vector length in bytes.
    // Encoding: 0x04BF5020 for RDVL X0, #1
    // We use .inst since Zig's LLVM backend may not accept SVE mnemonics in
    // freestanding mode without +sve target feature.
    var vl_bytes: u64 = undefined;
    asm volatile (
        \\.inst 0x04BF5020
        : [ret] "={x0}" (vl_bytes),
    );
    features.sve_vl_bytes = @truncate(vl_bytes);

    uart.print("[cpu] SVE vector length: {} bits ({} bytes)\n", .{
        @as(u32, features.sve_vl_bytes) * 8,
        @as(u32, features.sve_vl_bytes),
    });
}

/// Print detected features to UART.
fn printFeatures() void {
    uart.print("[cpu] PA range: {}-bit\n", .{@as(u32, features.pa_range_bits)});

    // Print feature lines
    uart.writeString("[cpu] Features:");
    if (features.fp) uart.writeString(" FP");
    if (features.asimd) uart.writeString(" ASIMD");
    if (features.fp16) uart.writeString(" FP16");
    if (features.aes) uart.writeString(" AES");
    if (features.pmull) uart.writeString(" PMULL");
    if (features.sha1) uart.writeString(" SHA1");
    if (features.sha256) uart.writeString(" SHA256");
    if (features.crc32) uart.writeString(" CRC32");
    if (features.lse) uart.writeString(" LSE");
    if (features.dot_prod) uart.writeString(" DotProd");
    uart.writeString("\n");

    uart.writeString("[cpu] Security:");
    if (features.pan) uart.writeString(" PAN");
    if (features.pauth) uart.writeString(" PAuth");
    if (features.bti) uart.writeString(" BTI");
    if (features.mte) {
        uart.writeString(" MTE");
        uart.writeDec(@as(u32, features.mte_version));
    }
    if (features.rng) uart.writeString(" RNG");
    if (features.sb) uart.writeString(" SB");
    if (features.ras) uart.writeString(" RAS");
    uart.writeString("\n");

    if (features.sve) {
        uart.writeString("[cpu] Vector:");
        if (features.sve2) {
            uart.writeString(" SVE2");
        } else {
            uart.writeString(" SVE");
        }
        uart.writeString("\n");
    }
}

/// Verify secondary CPU has compatible features. Called on each secondary boot.
pub fn probeSecondary(cpu_id_num: u32) void {
    const midr = readSysReg("MIDR_EL1");
    const part: u12 = @truncate((midr >> 4) & 0xFFF);

    // Warn if heterogeneous (big.LITTLE) — scheduler doesn't handle it yet
    if (part != cpu_id.part_number) {
        uart.print("[cpu] WARNING: CPU {} is part 0x{x}, BSP is 0x{x} (heterogeneous)\n", .{
            cpu_id_num,
            @as(u32, part),
            @as(u32, cpu_id.part_number),
        });
    }
}
