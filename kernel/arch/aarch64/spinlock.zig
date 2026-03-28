/// ARM64 Spinlock primitives for SMP.
///
/// Uses atomic compare-and-swap via Zig builtins for the lock operation,
/// with WFE/SEV for power-efficient spinning. Two variants:
///   - Spinlock: basic lock (caller must ensure IRQs are appropriate)
///   - IrqSpinlock: masks IRQ before acquiring to prevent deadlock
///     when an IRQ handler might contend for the same lock.

pub const Spinlock = struct {
    locked: u32 = 0,

    /// Acquire the lock. Spins with WFE on contention.
    pub fn acquire(self: *Spinlock) void {
        while (true) {
            // Try to atomically swap 0 → 1 (acquire semantics)
            if (@cmpxchgWeak(u32, &self.locked, 0, 1, .acquire, .monotonic) == null) {
                // Successfully acquired (old value was 0, now 1)
                return;
            }

            // Lock is held — wait for event rather than spinning hot
            while (@atomicLoad(u32, &self.locked, .monotonic) != 0) {
                asm volatile ("wfe");
            }
        }
    }

    /// Release the lock. Uses release store + SEV to wake waiters.
    pub fn release(self: *Spinlock) void {
        @atomicStore(u32, &self.locked, 0, .release);
        // Wake any CPUs in WFE
        asm volatile ("sev");
    }
};

pub const IrqSpinlock = struct {
    inner: Spinlock = .{},
    saved_daif: u64 = 0,

    /// Save DAIF, mask IRQ, then acquire inner lock.
    pub fn acquire(self: *IrqSpinlock) void {
        // Read current DAIF (interrupt mask state)
        const daif = asm volatile ("mrs %[ret], DAIF"
            : [ret] "=r" (-> u64),
        );
        // Mask IRQ (set DAIF.I bit)
        asm volatile ("msr DAIFSet, #2");

        self.inner.acquire();
        self.saved_daif = daif;
    }

    /// Release inner lock, then restore previous DAIF state.
    pub fn release(self: *IrqSpinlock) void {
        const daif = self.saved_daif;
        self.inner.release();

        // Restore previous interrupt state
        asm volatile ("msr DAIF, %[daif]"
            :
            : [daif] "r" (daif),
        );
    }
};
