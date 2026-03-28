/// Global Descriptor Table — own GDT replacing Limine's.
/// Standard selectors: kernel CS=0x08, DS=0x10, user CS=0x18, DS=0x20, TSS=0x28.

const tss_mod = @import("tss.zig");
const smp = @import("smp.zig");
const klog = @import("../../klog/klog.zig");

// Selector constants (byte offsets into GDT)
pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS: u16 = 0x18 | 3; // RPL 3
pub const USER_DS: u16 = 0x20 | 3; // RPL 3
pub const TSS_SEL: u16 = 0x28;

const GdtEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    flags_limit_high: u8, // flags[7:4] | limit_high[3:0]
    base_high: u8,
};

const GdtPtr = packed struct {
    limit: u16,
    base: u64,
};

// 7 entries: null, kernel code, kernel data, user code, user data, TSS low, TSS high
// TSS descriptor is 16 bytes (2 GDT slots) on x86_64.
var gdt_entries: [7]GdtEntry = [_]GdtEntry{.{
    .limit_low = 0,
    .base_low = 0,
    .base_mid = 0,
    .access = 0,
    .flags_limit_high = 0,
    .base_high = 0,
}} ** 7;
var gdt_ptr: GdtPtr = undefined;

fn makeEntry(base: u32, limit: u20, access: u8, flags: u4) GdtEntry {
    return .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = access,
        .flags_limit_high = (@as(u8, flags) << 4) | @as(u8, @truncate(limit >> 16)),
        .base_high = @truncate(base >> 24),
    };
}

pub fn init() void {
    // Null descriptor
    gdt_entries[0] = makeEntry(0, 0, 0, 0);

    // Kernel code: present, ring 0, code, readable, long mode
    // Access: P=1 DPL=00 S=1 E=1 DC=0 RW=1 A=0 = 0x9A
    // Flags: G=1 L=1 D=0 = 0xA (long mode: L=1, D must be 0)
    gdt_entries[1] = makeEntry(0, 0xFFFFF, 0x9A, 0xA);

    // Kernel data: present, ring 0, data, writable
    // Access: P=1 DPL=00 S=1 E=0 DC=0 RW=1 A=0 = 0x92
    // Flags: G=1 D=1 = 0xC
    gdt_entries[2] = makeEntry(0, 0xFFFFF, 0x92, 0xC);

    // User code: present, ring 3, code, readable, long mode
    // Access: P=1 DPL=11 S=1 E=1 DC=0 RW=1 A=0 = 0xFA
    gdt_entries[3] = makeEntry(0, 0xFFFFF, 0xFA, 0xA);

    // User data: present, ring 3, data, writable
    // Access: P=1 DPL=11 S=1 E=0 DC=0 RW=1 A=0 = 0xF2
    gdt_entries[4] = makeEntry(0, 0xFFFFF, 0xF2, 0xC);

    // Entries 5-6 reserved for TSS (loaded later via loadTss)

    gdt_ptr = .{
        .limit = @sizeOf(@TypeOf(gdt_entries)) - 1,
        .base = @intFromPtr(&gdt_entries),
    };

    // Load GDT and reload segment registers
    asm volatile (
        \\lgdt (%[gdt_ptr])
        \\
        \\// Reload CS via far return
        \\pushq $0x08
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\
        \\// Reload data segments
        \\movw $0x10, %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%fs
        \\movw %%ax, %%gs
        \\movw %%ax, %%ss
        :
        : [gdt_ptr] "r" (&gdt_ptr),
    );

    const log = klog.scoped(.cpu);
    log.info("gdt_loaded", .{});
}

/// Install the TSS descriptor into GDT entries 5-6 and load the task register.
/// Must be called after init(). The TSS base address may be >4 GiB (kernel is
/// linked at 0xFFFFFFFF80000000), so the upper 32 bits go in entry 6.
pub fn loadTss(tss_ptr: *const tss_mod.TSS) void {
    const base: u64 = @intFromPtr(tss_ptr);
    const limit: u32 = @sizeOf(tss_mod.TSS) - 1; // 103

    // Entry 5: standard system segment descriptor for 64-bit TSS
    // Access: P=1 DPL=00 0 type=1001 (available 64-bit TSS) = 0x89
    // Flags: 0 (byte granularity, no L/D bits for system segments)
    gdt_entries[5] = .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = 0x89,
        .flags_limit_high = @truncate(limit >> 16),
        .base_high = @truncate(base >> 24),
    };

    // Entry 6: upper 32 bits of base address + 32 bits reserved
    // This is not a normal GDT entry — it encodes base[63:32] and zeros.
    const entry6_ptr: *[8]u8 = @ptrCast(&gdt_entries[6]);
    const base_upper: u32 = @truncate(base >> 32);
    entry6_ptr[0] = @truncate(base_upper);
    entry6_ptr[1] = @truncate(base_upper >> 8);
    entry6_ptr[2] = @truncate(base_upper >> 16);
    entry6_ptr[3] = @truncate(base_upper >> 24);
    entry6_ptr[4] = 0;
    entry6_ptr[5] = 0;
    entry6_ptr[6] = 0;
    entry6_ptr[7] = 0;

    // Reload GDT (entries 5-6 now filled)
    asm volatile ("lgdt (%[gdt_ptr])"
        :
        : [gdt_ptr] "r" (&gdt_ptr),
    );

    // Load task register with TSS selector
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (TSS_SEL),
    );

    const tss_log = klog.scoped(.cpu);
    tss_log.info("tss_loaded", .{});
}

// --- Per-CPU GDT/TSS for SMP ---

pub var per_cpu_gdt: [smp.MAX_CPUS][7]GdtEntry = [_][7]GdtEntry{[_]GdtEntry{.{
    .limit_low = 0, .base_low = 0, .base_mid = 0,
    .access = 0, .flags_limit_high = 0, .base_high = 0,
}} ** 7} ** smp.MAX_CPUS;

pub var per_cpu_gdt_ptr: [smp.MAX_CPUS]GdtPtr = undefined;
pub var per_cpu_tss: [smp.MAX_CPUS]tss_mod.TSS = [_]tss_mod.TSS{.{}} ** smp.MAX_CPUS;

/// Initialize GDT for a secondary CPU. Fills code/data/TSS descriptors,
/// loads the GDT, reloads segment registers, and loads the TSS.
pub fn initForCpu(cpu_id: u32) void {
    const i: usize = cpu_id;

    // Copy code/data descriptors from BSP
    per_cpu_gdt[i][0] = makeEntry(0, 0, 0, 0); // null
    per_cpu_gdt[i][1] = makeEntry(0, 0xFFFFF, 0x9A, 0xA); // kernel CS
    per_cpu_gdt[i][2] = makeEntry(0, 0xFFFFF, 0x92, 0xC); // kernel DS
    per_cpu_gdt[i][3] = makeEntry(0, 0xFFFFF, 0xFA, 0xA); // user CS
    per_cpu_gdt[i][4] = makeEntry(0, 0xFFFFF, 0xF2, 0xC); // user DS

    // TSS descriptor (entries 5-6)
    const tss_ptr = &per_cpu_tss[i];
    const base: u64 = @intFromPtr(tss_ptr);
    const limit: u32 = @sizeOf(tss_mod.TSS) - 1;

    per_cpu_gdt[i][5] = .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = 0x89,
        .flags_limit_high = @truncate(limit >> 16),
        .base_high = @truncate(base >> 24),
    };

    // Entry 6: upper 32 bits of TSS base
    const entry6_ptr: *[8]u8 = @ptrCast(&per_cpu_gdt[i][6]);
    const base_upper: u32 = @truncate(base >> 32);
    entry6_ptr[0] = @truncate(base_upper);
    entry6_ptr[1] = @truncate(base_upper >> 8);
    entry6_ptr[2] = @truncate(base_upper >> 16);
    entry6_ptr[3] = @truncate(base_upper >> 24);
    entry6_ptr[4] = 0;
    entry6_ptr[5] = 0;
    entry6_ptr[6] = 0;
    entry6_ptr[7] = 0;

    per_cpu_gdt_ptr[i] = .{
        .limit = @sizeOf(@TypeOf(per_cpu_gdt[i])) - 1,
        .base = @intFromPtr(&per_cpu_gdt[i]),
    };

    // Load GDT, reload CS via far return, reload data segments, load TSS
    asm volatile (
        \\lgdt (%[gdt_ptr])
        \\pushq $0x08
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\movw $0x10, %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%fs
        \\movw %%ax, %%ss
        :
        : [gdt_ptr] "r" (&per_cpu_gdt_ptr[i]),
    );

    // Load TSS
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (TSS_SEL),
    );
}
