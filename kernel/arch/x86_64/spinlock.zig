/// Spinlock with IRQ disable — prevents deadlock from interrupt handlers
/// acquiring the same lock on the same CPU.
///
/// Usage:
///   const flags = lock.acquire();
///   defer lock.release(flags);
///   // ... critical section ...

pub const IrqSpinlock = struct {
    locked: u32 = 0,

    /// Acquire the lock. Disables interrupts and spins until the lock is free.
    /// Returns the saved RFLAGS (caller must pass to release).
    pub inline fn acquire(self: *IrqSpinlock) u64 {
        // Save RFLAGS (including IF bit) and disable interrupts
        var rflags: u64 = undefined;
        asm volatile (
            \\pushfq
            \\pop %[flags]
            \\cli
            : [flags] "=r" (rflags),
        );

        // Spin until we atomically swap 0 → 1
        while (true) {
            if (@atomicRmw(u32, &self.locked, .Xchg, 1, .acquire) == 0) break;
            // Spin on read (avoids bus-locking cache line bouncing)
            while (@atomicLoad(u32, &self.locked, .monotonic) != 0) {
                asm volatile ("pause");
            }
        }

        return rflags;
    }

    /// Release the lock and restore the saved RFLAGS (re-enabling interrupts
    /// if they were enabled before acquire).
    pub inline fn release(self: *IrqSpinlock, saved_rflags: u64) void {
        @atomicStore(u32, &self.locked, 0, .release);
        // Restore RFLAGS (re-enables IF if it was set before acquire)
        asm volatile (
            \\push %[flags]
            \\popfq
            :
            : [flags] "r" (saved_rflags),
        );
    }
};
