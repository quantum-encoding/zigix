/// RISC-V CPU feature detection stub.
///
/// RISC-V ISA extension discovery is done via the misa CSR (M-mode only)
/// or via device tree / ACPI RHCT table. Since we run in S-mode and don't
/// parse DTB extensions yet, all features default to false.

pub var features: Features = .{};

pub const Features = struct {
    has_atomics: bool = false,    // A extension
    has_compressed: bool = false, // C extension
    has_float: bool = false,      // F extension
    has_double: bool = false,     // D extension
    has_vector: bool = false,     // V extension
    has_bitmanip: bool = false,   // Zba/Zbb/Zbs extensions
    has_crypto: bool = false,     // Zkn/Zks extensions
    has_sstc: bool = false,       // Sstc extension (S-mode timer compare)
};

/// Probe CPU features. Stub for now -- assumes baseline RV64GC.
pub fn probe() void {
    // On QEMU virt, we can assume A + C + F + D are present (RV64GC).
    // Real hardware detection would parse the DTB /cpus node's
    // "riscv,isa" or "riscv,isa-extensions" properties.
    features.has_atomics = true;
    features.has_compressed = true;
    features.has_float = true;
    features.has_double = true;
}
