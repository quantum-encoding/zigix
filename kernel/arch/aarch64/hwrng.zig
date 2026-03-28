/// ARM64 Hardware Random Number Generator
///
/// Uses FEAT_RNG (ARMv8.5+) instructions:
///   RNDR   — Random Number (MRS Xt, RNDR)    — may fail (retry needed)
///   RNDRRS — Random Number Reseeded (MRS Xt, RNDRRS) — guaranteed fresh seed
///
/// On CPUs without FEAT_RNG (e.g., Cortex-A72), falls back to
/// CNTVCT_EL0 + CNTPCT_EL0 mixing (NOT cryptographically secure,
/// but sufficient for ASLR and non-security uses).
///
/// Neoverse N2 supports FEAT_RNG — true hardware entropy.

const cpu_features = @import("cpu_features.zig");
const uart = @import("uart.zig");

/// Get a 64-bit random number from hardware RNG.
/// Returns the random value, or falls back to timer-based entropy.
pub fn random64() u64 {
    if (cpu_features.features.rng) {
        return rndr() orelse rndrFallback();
    }
    return timerEntropy();
}

/// Fill a buffer with random bytes from hardware RNG.
pub fn fillRandom(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const val = random64();
        const remaining = buf.len - i;
        const chunk = if (remaining >= 8) 8 else remaining;
        for (0..chunk) |j| {
            buf[i + j] = @truncate((val >> @intCast(j * 8)));
        }
        i += chunk;
    }
}

/// Try to read RNDR register. Returns null if the instruction fails
/// (NZCV.Z is set on failure, indicating entropy exhaustion).
fn rndr() ?u64 {
    var value: u64 = undefined;
    var flags: u64 = undefined;

    // MRS Xt, RNDR  — S3_3_C2_C4_0
    // If entropy unavailable, NZCV.Z=1
    asm volatile (
        \\mrs %[val], S3_3_C2_C4_0
        \\mrs %[flags], NZCV
        : [val] "=r" (value),
          [flags] "=r" (flags),
    );

    // Check Z flag (bit 30 of NZCV)
    if ((flags & (1 << 30)) != 0) return null;
    return value;
}

/// Retry RNDR with limited attempts, then fall back to timer entropy.
fn rndrFallback() u64 {
    // Retry a few times — entropy pool may refill quickly
    var attempt: u32 = 0;
    while (attempt < 16) : (attempt += 1) {
        if (rndr()) |val| return val;
        // Yield to let entropy accumulate
        asm volatile ("yield");
    }

    // Last resort: use RNDRRS (reseeded, blocks until entropy available)
    var value: u64 = undefined;
    var flags: u64 = undefined;
    asm volatile (
        \\mrs %[val], S3_3_C2_C4_1
        \\mrs %[flags], NZCV
        : [val] "=r" (value),
          [flags] "=r" (flags),
    );
    if ((flags & (1 << 30)) == 0) return value;

    // Truly exhausted — fall back to timer
    return timerEntropy();
}

/// Timer-based entropy (NOT cryptographically secure).
/// Mixes physical counter, virtual counter, and cycle count.
/// Used on CPUs without FEAT_RNG (Cortex-A72, etc.).
fn timerEntropy() u64 {
    const phys = asm volatile ("mrs %[ret], CNTPCT_EL0"
        : [ret] "=r" (-> u64),
    );
    const virt = asm volatile ("mrs %[ret], CNTVCT_EL0"
        : [ret] "=r" (-> u64),
    );

    // Simple mixing function (SplitMix64-style)
    var x = phys ^ (virt << 17) ^ (virt >> 13);
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

/// Initialize hardware RNG. Just logs availability.
pub fn init() void {
    if (cpu_features.features.rng) {
        uart.writeString("[rng] Hardware RNG available (FEAT_RNG)\n");
        // Test it
        if (rndr()) |val| {
            uart.print("[rng] RNDR test: {x}\n", .{val});
        } else {
            uart.writeString("[rng] RNDR test: entropy exhausted (will retry)\n");
        }
    } else {
        uart.writeString("[rng] No hardware RNG — using timer entropy (non-crypto)\n");
    }
}
