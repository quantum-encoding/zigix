/// RISC-V Spinlock primitives for SMP.
///
/// Uses Zig's @cmpxchgWeak builtin for the lock operation, with
/// fence instructions for memory ordering. Two variants:
///   - Spinlock: basic lock (caller must ensure IRQs are appropriate)
///   - IrqSpinlock: saves/restores sstatus.SIE to prevent deadlock
///     when an IRQ handler might contend for the same lock.

pub const Spinlock = struct {
    locked: u32 = 0,

    /// Acquire the lock. Spins until CAS succeeds.
    pub fn acquire(self: *Spinlock) void {
        while (true) {
            // Try to atomically swap 0 -> 1 (acquire semantics)
            if (@cmpxchgWeak(u32, &self.locked, 0, 1, .acquire, .monotonic) == null) {
                // Successfully acquired (old value was 0, now 1)
                return;
            }

            // Lock is held -- spin-wait
            while (@atomicLoad(u32, &self.locked, .monotonic) != 0) {
                // RISC-V hint for spin-wait (pause/nop)
                asm volatile ("" ::: .{ .memory = true });
            }
        }
    }

    /// Release the lock. Uses release store + fence.
    pub fn release(self: *Spinlock) void {
        @atomicStore(u32, &self.locked, 0, .release);
        // Fence to ensure the store is visible to other harts
        asm volatile ("fence rw, rw" ::: .{ .memory = true });
    }
};

pub const IrqSpinlock = struct {
    inner: Spinlock = .{},
    saved_sie: u64 = 0,

    /// Save sstatus.SIE, disable S-mode interrupts, then acquire inner lock.
    pub fn acquire(self: *IrqSpinlock) void {
        // Read current sstatus
        const sstatus = asm volatile ("csrr %[ret], sstatus"
            : [ret] "=r" (-> u64),
        );
        // Clear SIE (bit 1) to disable S-mode interrupts
        asm volatile ("csrc sstatus, %[val]" :: [val] "r" (@as(u64, 1 << 1)));

        self.inner.acquire();
        self.saved_sie = sstatus & (1 << 1); // Save only the SIE bit
    }

    /// Release inner lock, then restore previous SIE state.
    pub fn release(self: *IrqSpinlock) void {
        const sie = self.saved_sie;
        self.inner.release();

        // Restore previous interrupt state (re-enable SIE if it was set)
        if (sie != 0) {
            asm volatile ("csrs sstatus, %[val]" :: [val] "r" (@as(u64, 1 << 1)));
        }
    }
};
