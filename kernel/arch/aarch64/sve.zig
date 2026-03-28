/// ARM64 SVE/SVE2 (Scalable Vector Extension) support
///
/// SVE registers have variable length (128-2048 bits depending on implementation).
/// Neoverse N2 implements 128-bit SVE2 (same width as NEON but with SVE2 instructions).
///
/// Register state per context:
///   Z0-Z31  — 32 scalable vector registers (VL bytes each)
///   P0-P15  — 16 predicate registers (VL/8 bytes each)
///   FFR     — First Fault Register (VL/8 bytes)
///   ZCR_EL1 — SVE Control Register (vector length control)
///   FPCR/FPSR — shared with NEON (already saved)
///
/// Memory layout for context save (at VL=128 bits = 16 bytes):
///   Z regs:  32 * 16 = 512 bytes
///   P regs:  16 * 2  = 32 bytes
///   FFR:     2 bytes (padded to 8)
///   Total:   552 bytes (at VL=128)
///
/// At VL=256 (Neoverse V1/V2):
///   Z regs:  32 * 32 = 1024 bytes
///   P regs:  16 * 4  = 64 bytes
///   FFR:     4 bytes (padded to 8)
///   Total:   1096 bytes
///
/// Strategy:
///   - Lazy save/restore: only save SVE state if the process used SVE.
///   - On context switch, if outgoing process has sve_dirty=true, save full SVE state.
///   - On restore, if incoming process has SVE state, restore it.
///   - If incoming process never used SVE, just enable trapping so first SVE
///     instruction triggers a sync exception → we allocate SVE state on demand.

const uart = @import("uart.zig");
const pmm = @import("pmm.zig");
const cpu_features = @import("cpu_features.zig");

/// Maximum supported SVE vector length in bytes.
/// Neoverse N2 = 16 (128-bit), Neoverse V2 = 16 or 32 (128/256-bit).
/// We support up to 256 bytes (2048-bit) for future-proofing.
pub const MAX_VL_BYTES: usize = 256;

/// SVE context storage — sized for maximum possible vector length.
/// Allocated per-process only when the process first uses SVE.
pub const SveContext = struct {
    /// Z0-Z31 vector registers, each MAX_VL_BYTES
    z_regs: [32][MAX_VL_BYTES]u8 = [_][MAX_VL_BYTES]u8{[_]u8{0} ** MAX_VL_BYTES} ** 32,

    /// P0-P15 predicate registers, each MAX_VL_BYTES/8
    p_regs: [16][MAX_VL_BYTES / 8]u8 = [_][MAX_VL_BYTES / 8]u8{[_]u8{0} ** (MAX_VL_BYTES / 8)} ** 16,

    /// FFR (First Fault Register), MAX_VL_BYTES/8
    ffr: [MAX_VL_BYTES / 8]u8 = [_]u8{0} ** (MAX_VL_BYTES / 8),

    /// Actual vector length this context was saved with
    vl_bytes: u16 = 0,
};

/// Total size of SveContext
pub const SVE_CONTEXT_SIZE = @sizeOf(SveContext);

/// Enable SVE access for EL1 and EL0.
/// Sets CPACR_EL1.ZEN = 0b11 (no trapping).
/// Must be called after cpu_features.probe() confirms SVE support.
pub fn enable() void {
    if (!cpu_features.features.sve) return;

    var cpacr = asm volatile ("mrs %[ret], CPACR_EL1"
        : [ret] "=r" (-> u64),
    );
    cpacr |= (3 << 16);  // ZEN = 0b11 (SVE access from EL0 and EL1)
    asm volatile ("msr CPACR_EL1, %[val]" :: [val] "r" (cpacr));
    asm volatile ("isb");

    uart.writeString("[cpu] SVE access enabled (CPACR_EL1.ZEN=11)\n");
}

/// Enable SVE trapping for a process that hasn't used SVE yet.
/// Sets CPACR_EL1.ZEN = 0b00 so first SVE instruction traps.
pub fn enableTrapping() void {
    var cpacr = asm volatile ("mrs %[ret], CPACR_EL1"
        : [ret] "=r" (-> u64),
    );
    cpacr &= ~@as(u64, 3 << 16);  // ZEN = 0b00
    asm volatile ("msr CPACR_EL1, %[val]" :: [val] "r" (cpacr));
    asm volatile ("isb");
}

/// Disable SVE trapping (allow SVE access).
pub fn disableTrapping() void {
    var cpacr = asm volatile ("mrs %[ret], CPACR_EL1"
        : [ret] "=r" (-> u64),
    );
    cpacr |= (3 << 16);  // ZEN = 0b11
    asm volatile ("msr CPACR_EL1, %[val]" :: [val] "r" (cpacr));
    asm volatile ("isb");
}

/// Save SVE register state to memory.
/// Uses STR (SVE) instructions via raw encodings since Zig inline asm
/// doesn't support SVE mnemonics directly.
///
/// For each Z register: STR Zn, [base, #imm, MUL VL]
/// For each P register: STR Pn, [base, #imm, MUL VL]
pub fn saveState(ctx: *SveContext) void {
    const vl = cpu_features.features.sve_vl_bytes;
    if (vl == 0) return;
    ctx.vl_bytes = vl;

    // Save Z0-Z31 using STR (vector, SVE)
    // STR Zt, [Xn, #imm, MUL VL] encoding: 0xE5804000 | (imm9 << 10) | (Rn << 5) | Zt
    // We use a loop with computed offsets via x0 as base
    const z_base: [*]u8 = &ctx.z_regs[0];
    const p_base: [*]u8 = &ctx.p_regs[0];
    const ffr_ptr: [*]u8 = &ctx.ffr;

    asm volatile (
        // Save Z0-Z31 (unrolled for correctness — each STR Zn is a different encoding)
        \\str z0, [%[zb], #0, MUL VL]
        \\str z1, [%[zb], #1, MUL VL]
        \\str z2, [%[zb], #2, MUL VL]
        \\str z3, [%[zb], #3, MUL VL]
        \\str z4, [%[zb], #4, MUL VL]
        \\str z5, [%[zb], #5, MUL VL]
        \\str z6, [%[zb], #6, MUL VL]
        \\str z7, [%[zb], #7, MUL VL]
        \\str z8, [%[zb], #8, MUL VL]
        \\str z9, [%[zb], #9, MUL VL]
        \\str z10, [%[zb], #10, MUL VL]
        \\str z11, [%[zb], #11, MUL VL]
        \\str z12, [%[zb], #12, MUL VL]
        \\str z13, [%[zb], #13, MUL VL]
        \\str z14, [%[zb], #14, MUL VL]
        \\str z15, [%[zb], #15, MUL VL]
        \\str z16, [%[zb], #16, MUL VL]
        \\str z17, [%[zb], #17, MUL VL]
        \\str z18, [%[zb], #18, MUL VL]
        \\str z19, [%[zb], #19, MUL VL]
        \\str z20, [%[zb], #20, MUL VL]
        \\str z21, [%[zb], #21, MUL VL]
        \\str z22, [%[zb], #22, MUL VL]
        \\str z23, [%[zb], #23, MUL VL]
        \\str z24, [%[zb], #24, MUL VL]
        \\str z25, [%[zb], #25, MUL VL]
        \\str z26, [%[zb], #26, MUL VL]
        \\str z27, [%[zb], #27, MUL VL]
        \\str z28, [%[zb], #28, MUL VL]
        \\str z29, [%[zb], #29, MUL VL]
        \\str z30, [%[zb], #30, MUL VL]
        \\str z31, [%[zb], #31, MUL VL]
        // Save P0-P15
        \\str p0, [%[pb], #0, MUL VL]
        \\str p1, [%[pb], #1, MUL VL]
        \\str p2, [%[pb], #2, MUL VL]
        \\str p3, [%[pb], #3, MUL VL]
        \\str p4, [%[pb], #4, MUL VL]
        \\str p5, [%[pb], #5, MUL VL]
        \\str p6, [%[pb], #6, MUL VL]
        \\str p7, [%[pb], #7, MUL VL]
        \\str p8, [%[pb], #8, MUL VL]
        \\str p9, [%[pb], #9, MUL VL]
        \\str p10, [%[pb], #10, MUL VL]
        \\str p11, [%[pb], #11, MUL VL]
        \\str p12, [%[pb], #12, MUL VL]
        \\str p13, [%[pb], #13, MUL VL]
        \\str p14, [%[pb], #14, MUL VL]
        \\str p15, [%[pb], #15, MUL VL]
        // Save FFR
        \\rdffr p0.b
        \\str p0, [%[ffr], #0, MUL VL]
        // Restore p0 from its saved location
        \\ldr p0, [%[pb], #0, MUL VL]
        :
        : [zb] "r" (z_base),
          [pb] "r" (p_base),
          [ffr] "r" (ffr_ptr),
        : .{ .memory = true }
    );
}

/// Restore SVE register state from memory.
pub fn restoreState(ctx: *const SveContext) void {
    if (ctx.vl_bytes == 0) return;

    const z_base: [*]const u8 = &ctx.z_regs[0];
    const p_base: [*]const u8 = &ctx.p_regs[0];
    const ffr_ptr: [*]const u8 = &ctx.ffr;

    asm volatile (
        // Restore FFR first (uses p0 as temporary)
        \\ldr p0, [%[ffr], #0, MUL VL]
        \\wrffr p0.b
        // Restore P0-P15
        \\ldr p0, [%[pb], #0, MUL VL]
        \\ldr p1, [%[pb], #1, MUL VL]
        \\ldr p2, [%[pb], #2, MUL VL]
        \\ldr p3, [%[pb], #3, MUL VL]
        \\ldr p4, [%[pb], #4, MUL VL]
        \\ldr p5, [%[pb], #5, MUL VL]
        \\ldr p6, [%[pb], #6, MUL VL]
        \\ldr p7, [%[pb], #7, MUL VL]
        \\ldr p8, [%[pb], #8, MUL VL]
        \\ldr p9, [%[pb], #9, MUL VL]
        \\ldr p10, [%[pb], #10, MUL VL]
        \\ldr p11, [%[pb], #11, MUL VL]
        \\ldr p12, [%[pb], #12, MUL VL]
        \\ldr p13, [%[pb], #13, MUL VL]
        \\ldr p14, [%[pb], #14, MUL VL]
        \\ldr p15, [%[pb], #15, MUL VL]
        // Restore Z0-Z31
        \\ldr z0, [%[zb], #0, MUL VL]
        \\ldr z1, [%[zb], #1, MUL VL]
        \\ldr z2, [%[zb], #2, MUL VL]
        \\ldr z3, [%[zb], #3, MUL VL]
        \\ldr z4, [%[zb], #4, MUL VL]
        \\ldr z5, [%[zb], #5, MUL VL]
        \\ldr z6, [%[zb], #6, MUL VL]
        \\ldr z7, [%[zb], #7, MUL VL]
        \\ldr z8, [%[zb], #8, MUL VL]
        \\ldr z9, [%[zb], #9, MUL VL]
        \\ldr z10, [%[zb], #10, MUL VL]
        \\ldr z11, [%[zb], #11, MUL VL]
        \\ldr z12, [%[zb], #12, MUL VL]
        \\ldr z13, [%[zb], #13, MUL VL]
        \\ldr z14, [%[zb], #14, MUL VL]
        \\ldr z15, [%[zb], #15, MUL VL]
        \\ldr z16, [%[zb], #16, MUL VL]
        \\ldr z17, [%[zb], #17, MUL VL]
        \\ldr z18, [%[zb], #18, MUL VL]
        \\ldr z19, [%[zb], #19, MUL VL]
        \\ldr z20, [%[zb], #20, MUL VL]
        \\ldr z21, [%[zb], #21, MUL VL]
        \\ldr z22, [%[zb], #22, MUL VL]
        \\ldr z23, [%[zb], #23, MUL VL]
        \\ldr z24, [%[zb], #24, MUL VL]
        \\ldr z25, [%[zb], #25, MUL VL]
        \\ldr z26, [%[zb], #26, MUL VL]
        \\ldr z27, [%[zb], #27, MUL VL]
        \\ldr z28, [%[zb], #28, MUL VL]
        \\ldr z29, [%[zb], #29, MUL VL]
        \\ldr z30, [%[zb], #30, MUL VL]
        \\ldr z31, [%[zb], #31, MUL VL]
        :
        : [zb] "r" (z_base),
          [pb] "r" (p_base),
          [ffr] "r" (ffr_ptr),
        : .{ .memory = true }
    );
}

/// Allocate SVE context for a process. Returns pointer to kernel-allocated SveContext,
/// or null if allocation fails. The context lives in a dedicated physical page.
pub fn allocContext() ?*SveContext {
    // SveContext is ~9KB at MAX_VL=256 — needs 3 pages. At VL=16 it's ~600B (1 page).
    const pages_needed = (SVE_CONTEXT_SIZE + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
    const phys = pmm.allocPages(pages_needed) orelse return null;

    // Zero-initialize
    const ptr: [*]u8 = @ptrFromInt(phys);
    for (0..pages_needed * pmm.PAGE_SIZE) |i| {
        ptr[i] = 0;
    }

    return @ptrFromInt(phys);
}

/// Free SVE context pages.
pub fn freeContext(ctx: *SveContext) void {
    const pages = (SVE_CONTEXT_SIZE + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
    pmm.freePages(@intFromPtr(ctx), pages);
}

/// Enable SVE on secondary CPU (same CPACR_EL1 setup).
pub fn enableSecondary() void {
    if (!cpu_features.features.sve) return;

    var cpacr = asm volatile ("mrs %[ret], CPACR_EL1"
        : [ret] "=r" (-> u64),
    );
    cpacr |= (3 << 16);  // ZEN = 0b11
    asm volatile ("msr CPACR_EL1, %[val]" :: [val] "r" (cpacr));
    asm volatile ("isb");
}
