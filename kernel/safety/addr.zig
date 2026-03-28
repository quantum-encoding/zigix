// addr.zig — Comptime-parameterized kernel address type system
//
// This is the Mars Climate Orbiter prevention for kernel addresses.
// Wrong address space = compile error. Not a runtime check. Not a convention.
//
// The Zigix kernel debugged for weeks: physical addresses passed where virtual
// addresses were expected, HHDM offsets applied twice, PCI MMIO addresses
// confused with RAM addresses. A type system makes that structurally impossible.
//
// Pattern from zig_chaos_rocket/src/units/units.zig:
//   Quantity(Newton) ≠ Quantity(PoundForce)  →  Address(.physical) ≠ Address(.virtual)

/// Address space tags — each produces a distinct type via Address().
pub const Space = enum {
    /// Physical: real hardware addresses (0 to RAM_SIZE).
    /// Used by PMM, DMA buffers, page table entries, device BARs.
    physical,

    /// Virtual/kernel: higher-half kernel addresses (0xFFFFFFFF80xxxxxx).
    /// Used by kernel code, .text/.data/.bss pointers.
    virtual,
};

/// Comptime-parameterized address type.
/// Address(.physical) and Address(.virtual) are DIFFERENT TYPES.
/// You cannot pass, compare, or assign between them without explicit conversion.
pub fn Address(comptime space: Space) type {
    return struct {
        raw: u64,

        const Self = @This();
        pub const address_space = space;

        // --- Construction ---

        pub inline fn from(raw: u64) Self {
            return .{ .raw = raw };
        }

        pub inline fn zero() Self {
            return .{ .raw = 0 };
        }

        /// Extract the raw u64. Named to be greppable — every .toInt() call
        /// is a point where type safety is deliberately bypassed.
        pub inline fn toInt(self: Self) u64 {
            return self.raw;
        }

        // --- Page operations ---

        pub inline fn pageAligned(self: Self) Self {
            return .{ .raw = self.raw & ~@as(u64, PAGE_SIZE - 1) };
        }

        pub inline fn isPageAligned(self: Self) bool {
            return self.raw & (PAGE_SIZE - 1) == 0;
        }

        pub inline fn pageIndex(self: Self) u64 {
            return self.raw >> PAGE_SHIFT;
        }

        pub inline fn pageOffset(self: Self) u12 {
            return @truncate(self.raw & 0xFFF);
        }

        pub inline fn fromPage(page: u64) Self {
            return .{ .raw = page << PAGE_SHIFT };
        }

        // --- Arithmetic (stays within the same address space) ---

        pub inline fn add(self: Self, offset: u64) Self {
            return .{ .raw = self.raw + offset };
        }

        pub inline fn sub(self: Self, offset: u64) Self {
            return .{ .raw = self.raw - offset };
        }

        pub inline fn diff(self: Self, other: Self) u64 {
            return self.raw - other.raw;
        }

        // --- Comparisons ---

        pub inline fn eql(self: Self, other: Self) bool {
            return self.raw == other.raw;
        }

        pub inline fn lessThan(self: Self, other: Self) bool {
            return self.raw < other.raw;
        }

        pub inline fn greaterThanOrEql(self: Self, other: Self) bool {
            return self.raw >= other.raw;
        }

        // --- Null/validity ---

        pub inline fn isNull(self: Self) bool {
            return self.raw == 0;
        }

        // --- PTE operations (physical addresses only) ---

        /// Extract PML4/PDPT/PD/PT indices from a virtual address.
        /// Only meaningful for virtual addresses but works on any for flexibility.
        pub inline fn pml4Index(self: Self) u9 {
            return @truncate((self.raw >> 39) & 0x1FF);
        }

        pub inline fn pdptIndex(self: Self) u9 {
            return @truncate((self.raw >> 30) & 0x1FF);
        }

        pub inline fn pdIndex(self: Self) u9 {
            return @truncate((self.raw >> 21) & 0x1FF);
        }

        pub inline fn ptIndex(self: Self) u9 {
            return @truncate((self.raw >> 12) & 0x1FF);
        }

        const PAGE_SIZE: u64 = 4096;
        const PAGE_SHIFT: u6 = 12;
    };
}

// --- Concrete types ---

/// Physical address — real hardware bus address.
/// Used by: PMM allocations, DMA, page table entries, device BARs, MMIO.
pub const Phys = Address(.physical);

/// Virtual address — CPU-visible address translated through page tables.
/// Used by: kernel pointers, user pointers, HHDM addresses, stack addresses.
pub const Virt = Address(.virtual);

// --- Cross-space conversions (the ONLY way to go between types) ---
// These are defined here, not in the Address struct, because conversion
// requires knowledge of the HHDM offset — an external runtime value.
// Like Chaos Rocket's convertTo(), each conversion is explicit and auditable.

var hhdm_offset: u64 = 0;

/// Initialize the conversion layer with the HHDM base address.
/// Must be called during early boot before any phys↔virt conversions.
pub fn initHHDM(offset: u64) void {
    hhdm_offset = offset;
}

/// Convert physical → virtual via HHDM (add offset).
/// The kernel equivalent of Chaos Rocket's convertTo().
pub inline fn toVirt(phys: Phys) Virt {
    return Virt.from(phys.raw +% hhdm_offset);
}

/// Convert virtual (HHDM) → physical (subtract offset).
pub inline fn toPhys(virt: Virt) Phys {
    return Phys.from(virt.raw - hhdm_offset);
}

/// Convert physical address to a typed pointer via HHDM.
/// The most common pattern: physToPtr(PageTable, phys) → *PageTable.
pub inline fn toPtr(comptime T: type, phys: Phys) *T {
    return @ptrFromInt(toVirt(phys).raw);
}

/// Convert physical address to a const typed pointer via HHDM.
pub inline fn toConstPtr(comptime T: type, phys: Phys) *const T {
    return @ptrFromInt(toVirt(phys).raw);
}

// --- Tests ---

const testing = @import("std").testing;

test "physical and virtual are distinct types" {
    const p = Phys.from(0x1000);
    const v = Virt.from(0xFFFF800000001000);

    // These are different types — cannot be compared directly
    // p == v; // COMPILE ERROR: type mismatch

    // Must use explicit conversion
    // (test assumes HHDM offset is 0xFFFF800000000000)
    hhdm_offset = 0xFFFF800000000000;
    const converted = toVirt(p);
    try testing.expectEqual(converted.raw, 0xFFFF800000001000);
    try testing.expectEqual(toPhys(v).raw, 0x1000);
}

test "page alignment operations" {
    const addr = Phys.from(0x12345678);
    try testing.expectEqual(addr.pageAligned().raw, 0x12345000);
    try testing.expectEqual(addr.pageOffset(), 0x678);
    try testing.expectEqual(addr.pageIndex(), 0x12345);
    try testing.expect(!addr.isPageAligned());
    try testing.expect(Phys.from(0x12345000).isPageAligned());
}

test "arithmetic stays in same space" {
    const p1 = Phys.from(0x1000);
    const p2 = p1.add(0x2000);
    try testing.expectEqual(p2.raw, 0x3000);
    try testing.expectEqual(p2.diff(p1), 0x2000);

    // Cannot add Phys to Virt:
    // const bad = p1.add(v1); // COMPILE ERROR
}

test "PTE index extraction" {
    // Virtual address 0xFFFF800000200000 (HHDM + 2MB)
    const v = Virt.from(0xFFFF800000200000);
    try testing.expectEqual(v.pml4Index(), 256); // HHDM PML4 entry
    try testing.expectEqual(v.pdptIndex(), 0);
    try testing.expectEqual(v.pdIndex(), 1); // 2MB / 2MB = index 1
    try testing.expectEqual(v.ptIndex(), 0);
}

// ============================================================================
// Edge case tests — Chaos Rocket safety validation
// ============================================================================

test "zero and null semantics" {
    try testing.expectEqual(Phys.zero().raw, 0);
    try testing.expectEqual(Virt.zero().raw, 0);
    try testing.expect(Phys.zero().isNull());
    try testing.expect(Virt.zero().isNull());
    try testing.expect(!Phys.from(1).isNull());
    try testing.expect(!Virt.from(0x1000).isNull());
    // zero() == from(0)
    try testing.expect(Phys.zero().eql(Phys.from(0)));
    try testing.expect(Virt.zero().eql(Virt.from(0)));
}

test "page alignment boundary cases" {
    // Sub-page address → aligns to 0
    try testing.expectEqual(Phys.from(0xFFF).pageAligned().raw, 0);
    // Exact page → stays
    try testing.expectEqual(Phys.from(0x1000).pageAligned().raw, 0x1000);
    // Zero is page-aligned
    try testing.expect(Phys.from(0).isPageAligned());
    // 0x1000 is page-aligned
    try testing.expect(Phys.from(0x1000).isPageAligned());
    // 0x1001 is NOT page-aligned
    try testing.expect(!Phys.from(0x1001).isPageAligned());
    // Large address alignment
    try testing.expectEqual(Phys.from(0xFFFFFFFFFFFFFFFF).pageAligned().raw, 0xFFFFFFFFFFFFF000);
}

test "pageIndex and fromPage round-trip" {
    // fromPage(0) = address 0
    try testing.expectEqual(Phys.fromPage(0).raw, 0);
    // fromPage(1) = address 4096
    try testing.expectEqual(Phys.fromPage(1).raw, 4096);
    // Round-trip: fromPage(pageIndex(addr)) == pageAligned(addr)
    const a1 = Phys.from(0x12345678);
    try testing.expect(Phys.fromPage(a1.pageIndex()).eql(a1.pageAligned()));
    const a2 = Phys.from(0x1000);
    try testing.expect(Phys.fromPage(a2.pageIndex()).eql(a2.pageAligned()));
    const a3 = Phys.from(0);
    try testing.expect(Phys.fromPage(a3.pageIndex()).eql(a3.pageAligned()));
    // Large page number
    try testing.expectEqual(Phys.fromPage(0x100000).raw, 0x100000 << 12);
}

test "pageOffset edge cases" {
    try testing.expectEqual(Phys.from(0x12345ABC).pageOffset(), 0xABC);
    try testing.expectEqual(Phys.from(0x1000).pageOffset(), 0);
    try testing.expectEqual(Phys.from(0xFFF).pageOffset(), 0xFFF);
    try testing.expectEqual(Phys.from(0).pageOffset(), 0);
    // Max offset
    try testing.expectEqual(Phys.from(0xFFFFFFFFFFFFFFFF).pageOffset(), 0xFFF);
}

test "arithmetic: sub and diff" {
    const p1 = Phys.from(0x3000);
    const p2 = p1.sub(0x1000);
    try testing.expectEqual(p2.raw, 0x2000);
    // diff
    try testing.expectEqual(p1.diff(Phys.from(0x1000)), 0x2000);
    // sub to zero
    try testing.expectEqual(Phys.from(0x1000).sub(0x1000).raw, 0);
    // diff with equal values
    try testing.expectEqual(Phys.from(0x5000).diff(Phys.from(0x5000)), 0);
}

test "comparison edge cases" {
    // Self-equality
    try testing.expect(Phys.from(0).eql(Phys.from(0)));
    try testing.expect(Phys.from(0xDEADBEEF).eql(Phys.from(0xDEADBEEF)));
    // lessThan: not less than self
    try testing.expect(!Phys.from(0).lessThan(Phys.from(0)));
    try testing.expect(Phys.from(0).lessThan(Phys.from(1)));
    try testing.expect(!Phys.from(1).lessThan(Phys.from(0)));
    // greaterThanOrEql: includes equal
    try testing.expect(Phys.from(0).greaterThanOrEql(Phys.from(0)));
    try testing.expect(Phys.from(1).greaterThanOrEql(Phys.from(0)));
    try testing.expect(!Phys.from(0).greaterThanOrEql(Phys.from(1)));
    // Max value
    const max = Phys.from(0xFFFFFFFFFFFFFFFF);
    try testing.expect(max.greaterThanOrEql(Phys.from(0)));
    try testing.expect(max.greaterThanOrEql(max));
    try testing.expect(!max.lessThan(max));
}

test "PTE index extraction: user address 0x400000" {
    // Typical ELF entry point
    const v = Virt.from(0x400000);
    try testing.expectEqual(v.pml4Index(), 0);
    try testing.expectEqual(v.pdptIndex(), 0);
    try testing.expectEqual(v.pdIndex(), 2); // 0x400000 / 2MB = 2
    try testing.expectEqual(v.ptIndex(), 0);
    try testing.expectEqual(v.pageOffset(), 0);
}

test "PTE index extraction: max address" {
    const v = Virt.from(0xFFFFFFFFFFFFFFFF);
    try testing.expectEqual(v.pml4Index(), 511);
    try testing.expectEqual(v.pdptIndex(), 511);
    try testing.expectEqual(v.pdIndex(), 511);
    try testing.expectEqual(v.ptIndex(), 511);
    try testing.expectEqual(v.pageOffset(), 0xFFF);
}

test "PTE index round-trip reconstruction" {
    // Extract indices from a VA, reconstruct, verify bits [47:0] match
    const va: u64 = 0x0000_7F40_1234_5678;
    const v = Virt.from(va);
    const reconstructed: u64 =
        (@as(u64, v.pml4Index()) << 39) |
        (@as(u64, v.pdptIndex()) << 30) |
        (@as(u64, v.pdIndex()) << 21) |
        (@as(u64, v.ptIndex()) << 12) |
        @as(u64, v.pageOffset());
    // Bits [47:0] should match (bits [63:48] are sign extension, not in indices)
    try testing.expectEqual(reconstructed, va & 0x0000_FFFF_FFFF_FFFF);

    // Also verify kernel VA (high bits don't round-trip through 9-bit indices)
    const kva: u64 = 0xFFFF_8000_0020_0ABC;
    const kv = Virt.from(kva);
    const krecon: u64 =
        (@as(u64, kv.pml4Index()) << 39) |
        (@as(u64, kv.pdptIndex()) << 30) |
        (@as(u64, kv.pdIndex()) << 21) |
        (@as(u64, kv.ptIndex()) << 12) |
        @as(u64, kv.pageOffset());
    try testing.expectEqual(krecon, kva & 0x0000_FFFF_FFFF_FFFF);
}

test "HHDM conversion: identity mapping (ARM64)" {
    hhdm_offset = 0; // ARM64 identity
    // toVirt is identity
    try testing.expectEqual(toVirt(Phys.from(0x1000)).raw, 0x1000);
    try testing.expectEqual(toVirt(Phys.from(0)).raw, 0);
    try testing.expectEqual(toVirt(Phys.from(0xDEADBEEF)).raw, 0xDEADBEEF);
    // toPhys is identity
    try testing.expectEqual(toPhys(Virt.from(0x1000)).raw, 0x1000);
    try testing.expectEqual(toPhys(Virt.from(0)).raw, 0);
    // Round-trip
    const p = Phys.from(0x42000);
    try testing.expect(toPhys(toVirt(p)).eql(p));
    const v = Virt.from(0x42000);
    try testing.expect(toVirt(toPhys(v)).eql(v));
}

test "HHDM conversion: offset mapping (x86_64)" {
    hhdm_offset = 0xFFFF800000000000;
    // Phys 0x1000 → Virt 0xFFFF800000001000
    try testing.expectEqual(toVirt(Phys.from(0x1000)).raw, 0xFFFF800000001000);
    // Phys 0 → Virt at HHDM base
    try testing.expectEqual(toVirt(Phys.from(0)).raw, 0xFFFF800000000000);
    // Reverse: Virt 0xFFFF800000001000 → Phys 0x1000
    try testing.expectEqual(toPhys(Virt.from(0xFFFF800000001000)).raw, 0x1000);
    // Round-trip phys→virt→phys
    const p = Phys.from(0x12345000);
    try testing.expect(toPhys(toVirt(p)).eql(p));
    // Round-trip virt→phys→virt
    const v = Virt.from(0xFFFF800012345000);
    try testing.expect(toVirt(toPhys(v)).eql(v));
    // Restore for other tests
    hhdm_offset = 0;
}

test "toPtr matches toVirt" {
    hhdm_offset = 0; // identity for testability
    const phys = Phys.from(0x42000);
    const ptr_val = @intFromPtr(toPtr(u8, phys));
    const virt_val = toVirt(phys).raw;
    try testing.expectEqual(ptr_val, virt_val);
    // const ptr also matches
    const cptr_val = @intFromPtr(toConstPtr(u8, phys));
    try testing.expectEqual(cptr_val, virt_val);
}

test "type space preservation: add returns same type" {
    // Phys.add → Phys (not Virt) — verified via comptime type tag
    const p = Phys.from(0x1000);
    const p2 = p.add(0x100);
    try testing.expectEqual(@TypeOf(p2).address_space, .physical);
    // Virt.add → Virt (not Phys)
    const v = Virt.from(0x1000);
    const v2 = v.add(0x100);
    try testing.expectEqual(@TypeOf(v2).address_space, .virtual);
    // Sub also preserves space
    try testing.expectEqual(@TypeOf(p.sub(0x100)).address_space, .physical);
    try testing.expectEqual(@TypeOf(v.sub(0x100)).address_space, .virtual);
}
