/// SMP support — per-CPU state via GS_BASE + AP boot via INIT/SIPI/SIPI.
///
/// Each CPU has a CpuLocal struct accessed via GS_BASE (MSR 0xC0000101).
/// APs are booted using the Intel INIT/SIPI/SIPI sequence:
///   1. Place a real-mode trampoline at physical 0x8000
///   2. Send INIT IPI → AP enters known reset state
///   3. Send SIPI × 2 → AP begins executing at trampoline
///   4. Trampoline transitions real → protected → long mode → apEntry()
///
/// ACPI MADT provides the APIC IDs for each CPU.

const serial = @import("serial.zig");
const gdt = @import("gdt.zig");
const lapic = @import("lapic.zig");
const process = @import("../../proc/process.zig");
const pmm = @import("../../mm/pmm.zig");
const hhdm = @import("../../mm/hhdm.zig");
const types = @import("../../types.zig");
const acpi_parser = @import("../../acpi/acpi_parser.zig");
const vmm = @import("../../mm/vmm.zig");

pub const MAX_CPUS: usize = 16;

/// Per-CPU local data, accessed via GS_BASE.
/// Field offsets are used by assembly (syscall entry, commonStub).
/// DO NOT reorder without updating all assembly references.
pub const CpuLocal = struct {
    self_ptr: ?*CpuLocal = null,
    cpu_id: u32 = 0,
    apic_id: u32 = 0,
    kernel_stack_top: u64 = 0,
    scratch_rsp: u64 = 0,
    current_process: ?*process.Process = null,
    current_idx: ?usize = null,
    slice_remaining: u64 = TIMESLICE_TICKS,
    idle: bool = true,
    online: bool = false,
    dedicated_pid: u64 = 0,
    // Per-CPU SSE/FPU save area (512 bytes, 64-byte aligned for fxsave)
    fxsave_area: [512]u8 align(64) = [_]u8{0} ** 512,
};

/// Offsets for assembly access via GS segment override.
/// These MUST be used instead of hardcoded numbers — Zig reorders struct fields.
pub const KSTACK_OFFSET = @offsetOf(CpuLocal, "kernel_stack_top");
pub const SCRATCH_OFFSET = @offsetOf(CpuLocal, "scratch_rsp");

pub const TIMESLICE_TICKS: u64 = 10; // 100ms at 100 Hz

pub var cpu_locals: [MAX_CPUS]CpuLocal = [_]CpuLocal{.{}} ** MAX_CPUS;
pub var online_cpus: u32 = 1; // BSP is always online

/// MSR addresses
const MSR_GS_BASE: u32 = 0xC0000101;
const MSR_KERNEL_GS_BASE: u32 = 0xC0000102;
const IA32_EFER: u32 = 0xC0000080;
const IA32_STAR: u32 = 0xC0000081;
const IA32_LSTAR: u32 = 0xC0000082;
const IA32_SFMASK: u32 = 0xC0000084;

const AP_STACK_PAGES: u64 = 8; // 32KB kernel stack per AP

/// Trampoline physical address — must be below 1MB, page-aligned.
/// 0x8000 is safe (Limine/UEFI leave this region usable).
const TRAMPOLINE_PHYS: u64 = 0x8000;
const TRAMPOLINE_PAGE: u8 = 0x08; // TRAMPOLINE_PHYS >> 12

/// Read a Model-Specific Register.
inline fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

/// Write a Model-Specific Register.
pub inline fn wrmsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

/// Initialize BSP's per-CPU data and set GS_BASE.
pub fn initBsp() void {
    cpu_locals[0].cpu_id = 0;
    cpu_locals[0].online = true;
    cpu_locals[0].idle = false;
    cpu_locals[0].self_ptr = &cpu_locals[0];
    cpu_locals[0].slice_remaining = TIMESLICE_TICKS;

    const addr = @intFromPtr(&cpu_locals[0]);
    wrmsr(MSR_GS_BASE, addr);
    wrmsr(MSR_KERNEL_GS_BASE, 0);

    serial.writeString("[smp] FXSAVE_OFFSET=0x");
    {
        var hbuf: [16]u8 = undefined;
        var hv: u64 = FXSAVE_OFFSET;
        var hi2: usize = 16;
        while (hi2 > 0) {
            hi2 -= 1;
            hbuf[hi2] = "0123456789abcdef"[@as(usize, @truncate(hv & 0xf))];
            hv >>= 4;
        }
        serial.writeString(&hbuf);
    }
    serial.writeString("\n");
    serial.writeString("[smp] BSP per-CPU state initialized (GS_BASE=0x");
    // Print the virtual and physical address of cpu_locals[0] for PMM overlap check
    var hex_buf: [16]u8 = undefined;
    var v = addr;
    var hi: usize = 16;
    while (hi > 0) {
        hi -= 1;
        hex_buf[hi] = "0123456789abcdef"[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&hex_buf);
    serial.writeString(" kstack_off=");
    // Print the offset of kernel_stack_top within CpuLocal
    v = @offsetOf(CpuLocal, "kernel_stack_top");
    hi = 16;
    while (hi > 0) {
        hi -= 1;
        hex_buf[hi] = "0123456789abcdef"[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&hex_buf);
    serial.writeString(")\n");
}

/// Get the current CPU's CpuLocal pointer via GS_BASE MSR.
pub inline fn current() *CpuLocal {
    return @ptrFromInt(rdmsr(MSR_GS_BASE));
}

pub inline fn cpuId() u32 {
    return current().cpu_id;
}

pub const FXSAVE_OFFSET = @offsetOf(CpuLocal, "fxsave_area");

// ============================================================
// AP boot data — shared between BSP and trampoline
// ============================================================

/// Data block placed at TRAMPOLINE_PHYS + 0x100, read by the trampoline.
/// Trampoline code is at TRAMPOLINE_PHYS + 0x000.
const TrampolineData = extern struct {
    kernel_pml4: u64, // offset 0: CR3 value (kernel page table)
    ap_entry_addr: u64, // offset 8: 64-bit address of apEntry
    ap_stack_top: u64, // offset 16: kernel stack for this AP
    cpu_local_addr: u64, // offset 24: &cpu_locals[ap_idx]
    gdt64_ptr: u64, // offset 32: virtual addr of trampoline GDT pointer
};

// ============================================================
// Real-mode trampoline (placed at physical 0x8000)
// ============================================================

/// The trampoline is raw machine code. AP wakes in 16-bit real mode at CS:IP = 0x0800:0x0000.
/// It must: load a GDT, enable protected mode, enable long mode (paging + LME), jump to 64-bit.
///
/// Memory layout at TRAMPOLINE_PHYS:
///   0x000-0x0FF: trampoline code (16→32→64 bit transition)
///   0x100-0x13F: TrampolineData struct
///   0x140-0x15F: GDT for trampoline (3 entries: null, code32, code64)
///   0x160-0x169: GDT pointer (limit + base)
/// Build trampoline code at runtime into the target buffer.
/// Uses generous alignment boundaries: 16-bit at 0x00, 32-bit at 0x40, 64-bit at 0x80.
fn buildTrampoline(buf: [*]u8) void {
    // Zero the entire trampoline region (0x000 - 0x0FF)
    for (0..256) |i| buf[i] = 0;

    var p: usize = 0;

    // ---- 16-bit real mode (AP wakes at CS:IP = 0x0800:0x0000 → phys 0x8000) ----
    buf[p] = 0xFA; p += 1; // cli
    buf[p] = 0xFC; p += 1; // cld
    buf[p] = 0x31; p += 1; buf[p] = 0xC0; p += 1; // xor ax, ax
    buf[p] = 0x8E; p += 1; buf[p] = 0xD8; p += 1; // mov ds, ax

    // lgdt [0x8160] — GDT pointer at TRAMPOLINE_PHYS + 0x160, DS=0
    buf[p] = 0x0F; p += 1; buf[p] = 0x01; p += 1; buf[p] = 0x16; p += 1;
    buf[p] = 0x60; p += 1; buf[p] = 0x81; p += 1; // addr = 0x8160

    // mov eax, cr0; or al, 1; mov cr0, eax — enable protected mode
    buf[p] = 0x0F; p += 1; buf[p] = 0x20; p += 1; buf[p] = 0xC0; p += 1; // mov eax, cr0
    buf[p] = 0x0C; p += 1; buf[p] = 0x01; p += 1; // or al, 1
    buf[p] = 0x0F; p += 1; buf[p] = 0x22; p += 1; buf[p] = 0xC0; p += 1; // mov cr0, eax

    // Far jump to 32-bit code at offset 0x40: jmp 0x08:0x00008040
    buf[p] = 0x66; p += 1; buf[p] = 0xEA; p += 1;
    buf[p] = 0x40; p += 1; buf[p] = 0x80; p += 1; // offset low
    buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1; // offset high
    buf[p] = 0x08; p += 1; buf[p] = 0x00; p += 1; // selector 0x08
    // p should be <= 0x40 here (25 bytes used)

    // ---- 32-bit protected mode at offset 0x40 ----
    p = 0x40;
    // Load data segments: mov ax, 0x10; mov ds/es/ss, ax
    buf[p] = 0x66; p += 1; buf[p] = 0xB8; p += 1;
    buf[p] = 0x10; p += 1; buf[p] = 0x00; p += 1; // mov ax, 0x10
    buf[p] = 0x8E; p += 1; buf[p] = 0xD8; p += 1; // mov ds, ax
    buf[p] = 0x8E; p += 1; buf[p] = 0xC0; p += 1; // mov es, ax
    buf[p] = 0x8E; p += 1; buf[p] = 0xD0; p += 1; // mov ss, ax

    // Enable PAE: mov eax, cr4; or eax, 0x20; mov cr4, eax
    buf[p] = 0x0F; p += 1; buf[p] = 0x20; p += 1; buf[p] = 0xE0; p += 1;
    buf[p] = 0x0D; p += 1; buf[p] = 0x20; p += 1; buf[p] = 0x00; p += 1;
    buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1;
    buf[p] = 0x0F; p += 1; buf[p] = 0x22; p += 1; buf[p] = 0xE0; p += 1;

    // Load CR3 from TrampolineData.kernel_pml4 at 0x8100
    buf[p] = 0xB8; p += 1; buf[p] = 0x00; p += 1; buf[p] = 0x81; p += 1;
    buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1; // mov eax, 0x8100
    buf[p] = 0x8B; p += 1; buf[p] = 0x00; p += 1; // mov eax, [eax]
    buf[p] = 0x0F; p += 1; buf[p] = 0x22; p += 1; buf[p] = 0xD8; p += 1; // mov cr3, eax

    // Enable LME: rdmsr/wrmsr on IA32_EFER
    buf[p] = 0xB9; p += 1; buf[p] = 0x80; p += 1; buf[p] = 0x00; p += 1;
    buf[p] = 0x00; p += 1; buf[p] = 0xC0; p += 1; // mov ecx, 0xC0000080
    buf[p] = 0x0F; p += 1; buf[p] = 0x32; p += 1; // rdmsr
    buf[p] = 0x0D; p += 1; buf[p] = 0x00; p += 1; buf[p] = 0x01; p += 1;
    buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1; // or eax, 0x100
    buf[p] = 0x0F; p += 1; buf[p] = 0x30; p += 1; // wrmsr

    // Enable paging (long mode activates): mov eax, cr0; or eax, 0x80000000; mov cr0, eax
    buf[p] = 0x0F; p += 1; buf[p] = 0x20; p += 1; buf[p] = 0xC0; p += 1;
    buf[p] = 0x0D; p += 1; buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1;
    buf[p] = 0x00; p += 1; buf[p] = 0x80; p += 1;
    buf[p] = 0x0F; p += 1; buf[p] = 0x22; p += 1; buf[p] = 0xC0; p += 1;

    // Far jump to 64-bit code at offset 0x80: jmp 0x18:0x00008080
    buf[p] = 0xEA; p += 1;
    buf[p] = 0x80; p += 1; buf[p] = 0x80; p += 1; // offset low
    buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1; // offset high
    buf[p] = 0x18; p += 1; buf[p] = 0x00; p += 1; // selector 0x18
    // p should be <= 0x80 here

    // ---- 64-bit long mode at offset 0x80 ----
    p = 0x80;
    // mov rsi, 0x8100 (TrampolineData address)
    buf[p] = 0x48; p += 1; buf[p] = 0xBE; p += 1;
    buf[p] = 0x00; p += 1; buf[p] = 0x81; p += 1; buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1;
    buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1; buf[p] = 0x00; p += 1;

    // mov rsp, [rsi+16] — load AP stack
    buf[p] = 0x48; p += 1; buf[p] = 0x8B; p += 1; buf[p] = 0x66; p += 1; buf[p] = 0x10; p += 1;

    // mov rdi, [rsi+24] — load CpuLocal pointer (arg to apEntry)
    buf[p] = 0x48; p += 1; buf[p] = 0x8B; p += 1; buf[p] = 0x7E; p += 1; buf[p] = 0x18; p += 1;

    // mov rax, [rsi+8] — load apEntry address
    buf[p] = 0x48; p += 1; buf[p] = 0x8B; p += 1; buf[p] = 0x46; p += 1; buf[p] = 0x08; p += 1;

    // jmp rax
    buf[p] = 0xFF; p += 1; buf[p] = 0xE0; p += 1;
}

/// GDT for the trampoline (placed at TRAMPOLINE_PHYS + 0x140).
/// 3 entries: null, 32-bit code, 64-bit code. Data uses code32 selector.
const trampoline_gdt = [_]u8{
    // Entry 0: Null (8 bytes)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // Entry 1 (0x08): 32-bit code — base=0, limit=4G, execute/read, present, ring 0
    0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9A, 0xCF, 0x00,
    // Entry 2 (0x10): 32-bit data — base=0, limit=4G, read/write, present, ring 0
    0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00,
    // Entry 3 (0x18): 64-bit code — long mode, execute/read, present, ring 0
    0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9A, 0xAF, 0x00,
};

/// Install trampoline code + GDT + data at TRAMPOLINE_PHYS.
fn installTrampoline(kernel_pml4: u64, stack_top: u64, cpu_local: *CpuLocal) void {
    const base: [*]u8 = @ptrFromInt(hhdm.physToVirt(TRAMPOLINE_PHYS));

    // Build trampoline code at offset 0x000
    buildTrampoline(base);

    // Write TrampolineData at offset 0x100
    const data: *TrampolineData = @alignCast(@ptrCast(base + 0x100));
    data.kernel_pml4 = kernel_pml4;
    data.ap_entry_addr = @intFromPtr(&apEntry);
    data.ap_stack_top = stack_top;
    data.cpu_local_addr = @intFromPtr(cpu_local);
    data.gdt64_ptr = TRAMPOLINE_PHYS + 0x160;

    // Copy GDT at offset 0x140
    for (0..trampoline_gdt.len) |i| {
        base[0x140 + i] = trampoline_gdt[i];
    }

    // GDT pointer at offset 0x160: limit (u16) + base (u32) for 16/32-bit lgdt
    base[0x160] = @truncate((trampoline_gdt.len - 1) & 0xFF);
    base[0x161] = @truncate(((trampoline_gdt.len - 1) >> 8) & 0xFF);
    // Base = TRAMPOLINE_PHYS + 0x140
    const gdt_base: u32 = @truncate(TRAMPOLINE_PHYS + 0x140);
    base[0x162] = @truncate(gdt_base);
    base[0x163] = @truncate(gdt_base >> 8);
    base[0x164] = @truncate(gdt_base >> 16);
    base[0x165] = @truncate(gdt_base >> 24);
}

// ============================================================
// Boot sequence
// ============================================================

/// Boot Application Processors using INIT/SIPI/SIPI via LAPIC.
/// Uses ACPI MADT for CPU topology.
pub fn bootAPs() void {
    const config = &acpi_parser.config;
    if (config.apic_count <= 1) {
        serial.writeString("[smp] Single CPU detected — skipping AP boot\n");
        return;
    }

    const bsp_apic_id = lapic.id();
    cpu_locals[0].apic_id = bsp_apic_id;

    // Get kernel CR3 for trampoline page table setup
    const kernel_cr3 = asm volatile ("movq %%cr3, %[cr3]"
        : [cr3] "=r" (-> u64),
    );

    serial.writeString("[smp] Booting APs: ");
    writeDecimal(config.apic_count);
    serial.writeString(" CPUs from MADT, BSP APIC=");
    writeDecimal(bsp_apic_id);
    serial.writeString("\n");

    // Identity-map the trampoline page so it's accessible after paging is enabled.
    // The trampoline runs at physical 0x8000, but the kernel PML4 only has HHDM
    // mappings (phys → phys+offset). We need virt 0x8000 → phys 0x8000 temporarily.
    //
    // Clear PML4[0] first — it may contain a stale UEFI identity-map entry that
    // points to freed boot memory. vmm.mapPage's ensureTable would follow it.
    const pml4: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, kernel_cr3);
    pml4.entries[0] = .{};

    vmm.mapPage(kernel_cr3, TRAMPOLINE_PHYS, TRAMPOLINE_PHYS, .{ .writable = true }) catch {
        serial.writeString("[smp] Failed to identity-map trampoline page\n");
        return;
    };

    var ap_idx: u32 = 1;
    var i: u8 = 0;
    while (i < config.apic_count) : (i += 1) {
        const target_apic_id = config.apic_ids[i];
        if (target_apic_id == bsp_apic_id) continue; // Skip BSP
        if (ap_idx >= MAX_CPUS) break;

        // Allocate kernel stack
        const stack_phys = pmm.allocPages(AP_STACK_PAGES) orelse {
            serial.writeString("[smp] Failed to allocate AP stack\n");
            break;
        };
        const stack_top = hhdm.physToVirt(stack_phys) + AP_STACK_PAGES * types.PAGE_SIZE;

        // Initialize per-CPU data
        cpu_locals[ap_idx].cpu_id = ap_idx;
        cpu_locals[ap_idx].apic_id = target_apic_id;
        cpu_locals[ap_idx].self_ptr = &cpu_locals[ap_idx];
        cpu_locals[ap_idx].kernel_stack_top = stack_top;
        cpu_locals[ap_idx].idle = true;
        cpu_locals[ap_idx].online = false;
        cpu_locals[ap_idx].slice_remaining = TIMESLICE_TICKS;

        // Install trampoline with this AP's stack and CpuLocal
        installTrampoline(kernel_cr3, stack_top, &cpu_locals[ap_idx]);

        // INIT/SIPI/SIPI sequence
        lapic.sendInitIpi(target_apic_id);
        busyWaitUs(10000); // 10ms delay after INIT

        lapic.sendSipi(target_apic_id, TRAMPOLINE_PAGE);
        busyWaitUs(200); // 200μs between SIPIs

        lapic.sendSipi(target_apic_id, TRAMPOLINE_PAGE);

        // Wait for this AP to come online (with timeout)
        var waited: u32 = 0;
        while (waited < 5_000_000) : (waited += 1) {
            if (@atomicLoad(bool, &cpu_locals[ap_idx].online, .acquire)) break;
            asm volatile ("pause");
        }

        if (cpu_locals[ap_idx].online) {
            serial.writeString("[smp] AP ");
            writeDecimal(ap_idx);
            serial.writeString(" online (APIC ");
            writeDecimal(target_apic_id);
            serial.writeString(")\n");
        } else {
            serial.writeString("[smp] AP ");
            writeDecimal(ap_idx);
            serial.writeString(" TIMEOUT\n");
        }

        ap_idx += 1;
    }

    // Count online CPUs
    var total: u32 = 1;
    for (1..MAX_CPUS) |j| {
        if (cpu_locals[j].online) total += 1;
    }
    online_cpus = total;

    serial.writeString("[smp] ");
    writeDecimal(total);
    serial.writeString(" CPUs online\n");
}

/// AP entry point — called from trampoline in 64-bit long mode.
/// RDI = address of this CPU's CpuLocal struct.
fn apEntry(cpu_local_addr: u64) callconv(.c) noreturn {
    const cpu_local: *CpuLocal = @ptrFromInt(cpu_local_addr);
    const idx = cpu_local.cpu_id;

    // Enable SSE (per-CPU CR0/CR4)
    enableSse();

    // Load per-CPU GDT + TSS
    gdt.initForCpu(idx);

    // Load shared IDT
    const idt = @import("idt.zig");
    idt.loadForAp();

    // Set GS_BASE to this CPU's CpuLocal
    wrmsr(MSR_GS_BASE, cpu_local_addr);
    wrmsr(MSR_KERNEL_GS_BASE, 0);

    // Configure syscall MSRs (same as BSP)
    // EFER bits: SCE (0) = syscall enable, NXE (11) = no-execute page support
    // NXE is CRITICAL — without it, bit 63 (NX) in PTEs is treated as reserved,
    // causing #PF with err=15 on any page with NX set (stack, data, etc.)
    const efer = rdmsr(IA32_EFER);
    wrmsr(IA32_EFER, efer | (1 << 0) | (1 << 11));
    wrmsr(IA32_STAR, (@as(u64, 0x08) << 32) | (@as(u64, 0x10) << 48));
    const syscall_entry = @import("syscall_entry.zig");
    wrmsr(IA32_LSTAR, syscall_entry.getLstarAddr());
    wrmsr(IA32_SFMASK, 0x200);

    // Start per-CPU LAPIC timer
    lapic.initSecondary();

    // Signal BSP
    @atomicStore(bool, &cpu_local.online, true, .release);

    // Idle loop — LAPIC timer will fire, scheduler can assign processes
    while (true) {
        asm volatile ("sti\nhlt" ::: .{ .memory = true });
    }
}

/// Enable SSE/SSE2 (per-CPU — CR0/CR4 are per-CPU registers)
fn enableSse() void {
    var cr0: u64 = asm volatile ("movq %%cr0, %[cr0]"
        : [cr0] "=r" (-> u64),
    );
    cr0 &= ~@as(u64, (1 << 2) | (1 << 3)); // Clear EM + TS
    cr0 |= (1 << 1); // Set MP
    asm volatile ("movq %[cr0], %%cr0"
        :
        : [cr0] "r" (cr0),
    );

    var cr4: u64 = asm volatile ("movq %%cr4, %[cr4]"
        : [cr4] "=r" (-> u64),
    );
    cr4 |= (1 << 9) | (1 << 10); // OSFXSR + OSXMMEXCPT
    asm volatile ("movq %[cr4], %%cr4"
        :
        : [cr4] "r" (cr4),
    );
}

/// Busy-wait for approximately `us` microseconds using a calibrated loop.
/// Uses LAPIC timer current count as a reference if available, else spin.
fn busyWaitUs(us: u32) void {
    // Simple calibrated spin — ~1000 iterations ≈ 1μs on modern x86
    var i: u64 = 0;
    const iters = @as(u64, us) * 1000;
    while (i < iters) : (i += 1) {
        asm volatile ("pause");
    }
}

fn writeDecimal(value: anytype) void {
    const v_u64: u64 = @intCast(value);
    var buf: [20]u8 = undefined;
    var v = v_u64;
    var i: usize = 20;
    if (v == 0) {
        serial.writeString("0");
        return;
    }
    while (v > 0) {
        i -= 1;
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
    }
    serial.writeString(buf[i..]);
}
