/// execve(path, argv, envp) — nr 59
/// Replace the current process image with a new ELF binary.
///
/// Streaming ELF loader: reads only the first 4 KiB (ELF header + program headers),
/// creates file-backed VMAs for each PT_LOAD segment, and demand-pages the rest.
/// Supports binaries of any size (e.g. 165 MB Zig compiler).
///
/// Steps:
/// 1. Copy path, argv strings from old user space into kernel buffers
/// 2. Read ELF header (first 4 KiB) from VFS
/// 3. Tear down old user address space
/// 4. Create file-backed VMAs for each PT_LOAD segment (demand-paged)
/// 5. Allocate and map new user stack
/// 6. Set up initial stack with argc/argv/envp/auxv
/// 7. Update process state (VMAs, signals, heap)
/// 8. Set interrupt frame to new entry point — execve never returns

const idt = @import("../arch/x86_64/idt.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const vmm = @import("../mm/vmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const pmm = @import("../mm/pmm.zig");
const types = @import("../types.zig");
const vma = @import("../mm/vma.zig");
const vfs = @import("../fs/vfs.zig");
const elf = @import("elf.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const syscall = @import("syscall.zig");
const errno = @import("errno.zig");
const syscall_entry = @import("../arch/x86_64/syscall_entry.zig");
const ext2 = @import("../fs/ext2.zig");

// Small buffer for ELF header + program headers (64 + 70*56 = ~4 KiB max)
const ELF_HDR_BUF_SIZE: usize = 4096;
var elf_hdr_buf: [ELF_HDR_BUF_SIZE]u8 = undefined;

// Buffers for saving argv strings before address space teardown
const MAX_ARGS: usize = 256;
const ARG_BUF_SIZE: usize = 32768;
var arg_buf: [ARG_BUF_SIZE]u8 = undefined;

// Buffers for saving envp strings before address space teardown
const MAX_ENV_ARGS: usize = 256;
const ENV_BUF_SIZE: usize = 32768;
var env_buf: [ENV_BUF_SIZE]u8 = undefined;

// --- Global arrays for sysExecve (moved from stack to prevent kernel stack overflow) ---
// Safe as globals: int 0x80 disables interrupts, so execve is non-reentrant.
var g_arg_offsets: [MAX_ARGS]usize = undefined;
var g_arg_lens: [MAX_ARGS]usize = undefined;
var g_env_offsets: [MAX_ENV_ARGS]usize = undefined;
var g_env_lens: [MAX_ENV_ARGS]usize = undefined;
var g_user_argv_addrs: [MAX_ARGS]u64 = undefined;
var g_user_envp_addrs: [MAX_ENV_ARGS]u64 = undefined;

// Shebang handling globals (saves copying the arg_buf before modification)
var g_saved_args: [ARG_BUF_SIZE]u8 = undefined;
var g_saved_offsets: [MAX_ARGS]usize = undefined;
var g_saved_lens: [MAX_ARGS]usize = undefined;

pub fn sysExecve(frame: *idt.InterruptFrame) void {
    const path_addr = frame.rdi;
    const argv_addr = frame.rsi;
    const envp_addr = frame.rdx;

    const current = scheduler.currentProcess() orelse {
        frame.rax = @bitCast(@as(i64, -errno.ESRCH));
        return;
    };

    // Debug: verify kernel stack is correct at execve entry
    {
        const smp_mod = @import("../arch/x86_64/smp.zig");
        const cpu = smp_mod.current();
        var rsp_val: u64 = undefined;
        asm volatile ("movq %%rsp, %[rsp]" : [rsp] "=r" (rsp_val));
        if (rsp_val < 0xFFFF800000000000) {
            serial.writeString("[execve] DANGER: RSP in user space! rsp=0x");
            writeHex(rsp_val);
            serial.writeString(" gs:kstack=0x");
            writeHex(cpu.kernel_stack_top);
            serial.writeString(" pid=");
            writeHex(current.pid);
            serial.writeString("\n");
        }
    }

    // 1. Copy path from user space
    if (!syscall.validateUserBuffer(path_addr, 1)) {
        frame.rax = @bitCast(@as(i64, -errno.EFAULT));
        return;
    }

    var raw_path: [256]u8 = undefined;
    const raw_len = syscall.copyFromUser(current.page_table, path_addr, &raw_path, 255);
    if (raw_len == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    }

    // Resolve relative paths by prepending CWD
    var path_buf: [512]u8 = undefined;
    var path_len: usize = 0;
    if (raw_path[0] != '/') {
        // Relative path — prepend CWD
        if (current.cwd_len > 0) {
            @memcpy(path_buf[0..current.cwd_len], current.cwd[0..current.cwd_len]);
            path_len = current.cwd_len;
            if (path_len > 0 and path_buf[path_len - 1] != '/') {
                path_buf[path_len] = '/';
                path_len += 1;
            }
        } else {
            path_buf[0] = '/';
            path_len = 1;
        }
        @memcpy(path_buf[path_len .. path_len + raw_len], raw_path[0..raw_len]);
        path_len += raw_len;
    } else {
        @memcpy(path_buf[0..raw_len], raw_path[0..raw_len]);
        path_len = raw_len;
    }

    // 2. Copy argv strings from user space before we destroy the address space.
    var argc: usize = 0;
    var arg_total: usize = 0;

    if (argv_addr != 0 and syscall.validateUserBuffer(argv_addr, 8)) {
        var argv_ptr = argv_addr;
        while (argc < MAX_ARGS) {
            const str_addr = readUserU64(current.page_table, argv_ptr) orelse break;
            if (str_addr == 0) break;

            if (arg_total >= ARG_BUF_SIZE) break;
            g_arg_offsets[argc] = arg_total;
            const remaining = ARG_BUF_SIZE - arg_total;
            const len = syscall.copyFromUser(current.page_table, str_addr, arg_buf[arg_total..], remaining);
            g_arg_lens[argc] = len;
            arg_total += len + 1;
            if (arg_total <= ARG_BUF_SIZE) {
                arg_buf[arg_total - 1] = 0;
            }
            argc += 1;
            argv_ptr += 8;
        }
    }

    // 2b. Copy envp strings
    var envc: usize = 0;
    var env_total: usize = 0;

    if (envp_addr != 0 and syscall.validateUserBuffer(envp_addr, 8)) {
        var envp_ptr = envp_addr;
        while (envc < MAX_ENV_ARGS) {
            const str_addr = readUserU64(current.page_table, envp_ptr) orelse break;
            if (str_addr == 0) break;

            if (env_total >= ENV_BUF_SIZE) break;
            g_env_offsets[envc] = env_total;
            const remaining = ENV_BUF_SIZE - env_total;
            const len = syscall.copyFromUser(current.page_table, str_addr, env_buf[env_total..], remaining);
            g_env_lens[envc] = len;
            env_total += len + 1;
            if (env_total <= ENV_BUF_SIZE) {
                env_buf[env_total - 1] = 0;
            }
            envc += 1;
            envp_ptr += 8;
        }
    }

    // 3. Resolve executable inode and check permission
    var exec_inode = vfs.resolve(path_buf[0..path_len]) orelse {
        // Log failed execve for debugging (zig cc posix_spawn)
        serial.writeString("[execve] ENOENT: ");
        serial.writeString(path_buf[0..path_len]);
        serial.writeString("\n");
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };
    if (!checkExecPermission(exec_inode, current)) {
        frame.rax = @bitCast(@as(i64, -errno.EACCES));
        return;
    }

    // Read first 4 KiB of the file (ELF header + program headers)
    var hdr_bytes = readFileHead(exec_inode, &elf_hdr_buf) orelse {
        frame.rax = @bitCast(@as(i64, -errno.ENOENT));
        return;
    };

    if (hdr_bytes == 0) {
        frame.rax = @bitCast(@as(i64, -errno.ENOEXEC));
        return;
    }

    // 4. Validate ELF header — if not ELF, check for #! shebang
    if (elf.getHeader(elf_hdr_buf[0..hdr_bytes]) == null) {
        if (hdr_bytes >= 2 and elf_hdr_buf[0] == '#' and elf_hdr_buf[1] == '!') {
            // Parse interpreter path from first line
            var interp_start: usize = 2;
            while (interp_start < hdr_bytes and elf_hdr_buf[interp_start] == ' ') interp_start += 1;
            var interp_end: usize = interp_start;
            while (interp_end < hdr_bytes and elf_hdr_buf[interp_end] != '\n' and elf_hdr_buf[interp_end] != ' ' and elf_hdr_buf[interp_end] != '\r') interp_end += 1;

            const ipath_len = interp_end - interp_start;
            if (ipath_len == 0) {
                frame.rax = @bitCast(@as(i64, -errno.ENOEXEC));
                return;
            }

            // Build new argv: [interpreter, script_path, original_argv[1:]]
            var orig_path: [256]u8 = undefined;
            for (0..path_len) |k| orig_path[k] = path_buf[k];
            const orig_path_len = path_len;

            const saved_argc = argc;
            for (0..arg_total) |k| g_saved_args[k] = arg_buf[k];
            for (0..argc) |k| {
                g_saved_offsets[k] = g_arg_offsets[k];
                g_saved_lens[k] = g_arg_lens[k];
            }

            arg_total = 0;
            argc = 0;

            // argv[0] = interpreter path
            g_arg_offsets[0] = 0;
            g_arg_lens[0] = ipath_len;
            for (0..ipath_len) |k| arg_buf[k] = elf_hdr_buf[interp_start + k];
            arg_buf[ipath_len] = 0;
            arg_total = ipath_len + 1;
            argc = 1;

            // argv[1] = original script path
            if (arg_total + orig_path_len + 1 <= ARG_BUF_SIZE) {
                g_arg_offsets[argc] = arg_total;
                g_arg_lens[argc] = orig_path_len;
                for (0..orig_path_len) |k| arg_buf[arg_total + k] = orig_path[k];
                arg_buf[arg_total + orig_path_len] = 0;
                arg_total += orig_path_len + 1;
                argc += 1;
            }

            // argv[2:] = original argv[1:]
            var oi: usize = 1;
            while (oi < saved_argc and argc < MAX_ARGS) : (oi += 1) {
                const olen = g_saved_lens[oi];
                if (arg_total + olen + 1 > ARG_BUF_SIZE) break;
                g_arg_offsets[argc] = arg_total;
                g_arg_lens[argc] = olen;
                for (0..olen) |k| arg_buf[arg_total + k] = g_saved_args[g_saved_offsets[oi] + k];
                arg_buf[arg_total + olen] = 0;
                arg_total += olen + 1;
                argc += 1;
            }

            // Update path to interpreter
            path_len = ipath_len;
            for (0..ipath_len) |k| path_buf[k] = elf_hdr_buf[interp_start + k];

            // Re-resolve interpreter
            exec_inode = vfs.resolve(path_buf[0..path_len]) orelse {
                frame.rax = @bitCast(@as(i64, -errno.ENOENT));
                return;
            };
            hdr_bytes = readFileHead(exec_inode, &elf_hdr_buf) orelse {
                frame.rax = @bitCast(@as(i64, -errno.ENOENT));
                return;
            };
            if (hdr_bytes == 0 or elf.getHeader(elf_hdr_buf[0..hdr_bytes]) == null) {
                frame.rax = @bitCast(@as(i64, -errno.ENOEXEC));
                return;
            }
        } else {
            frame.rax = @bitCast(@as(i64, -errno.ENOEXEC));
            return;
        }
    }

    // Store executable path for /proc/self/exe
    for (0..path_len) |i| {
        current.exe_path[i] = path_buf[i];
    }
    current.exe_path_len = @truncate(path_len);

    // Debug: log execve path
    serial.writeString("[execve] ");
    serial.writeString(path_buf[0..path_len]);
    serial.writeString("\n");

    // === Point of no return — destroy old address space ===
    // If this process shares its page table with the parent (CLONE_VM/vfork),
    // we must NOT destroy the shared pages. Instead, create a new private
    // address space for this process. The parent keeps its original mappings.
    {
        var shared = false;
        for (0..process.MAX_PROCESSES) |pi| {
            if (process.getProcess(pi)) |p| {
                if (p != current and p.page_table == current.page_table) {
                    shared = true;
                    break;
                }
            }
        }
        if (shared) {
            // Shared address space (CLONE_VM) — create fresh page table
            const new_pml4 = vmm.createAddressSpace() catch {
                frame.rax = @bitCast(@as(i64, -errno.ENOMEM));
                return;
            };
            current.page_table = new_pml4;
            vmm.switchAddressSpace(new_pml4);
            serial.writeString("[execve] new PML4 (was CLONE_VM)\n");
        } else {
            vmm.destroyUserPages(current.page_table);
        }
    }

    // Clear old VMAs before adding new ELF VMAs. Without this, findVma may
    // return a stale anonymous VMA (inode=null) from the parent process,
    // causing demand paging to map zeroed pages instead of file data.
    vma.initVmaList(&current.vmas);

    // Unpin previously pinned executable inode (if any)
    if (current.exec_inode) |old_inode_ptr| {
        const old_inode: *vfs.Inode = @alignCast(@ptrCast(old_inode_ptr));
        ext2.unpinInode(old_inode);
        current.exec_inode = null;
    }

    // Parse ELF header and create demand-paged VMAs
    const header = elf.getHeader(elf_hdr_buf[0..hdr_bytes]).?;
    var highest_addr: u64 = 0;
    var lowest_addr: u64 = 0xFFFFFFFFFFFFFFFF;
    var segments_loaded: u32 = 0;

    var ph_i: u16 = 0;
    while (ph_i < header.e_phnum) : (ph_i += 1) {
        const phdr_off = header.e_phoff + @as(u64, ph_i) * @as(u64, header.e_phentsize);
        if (phdr_off + @sizeOf(elf.Elf64Phdr) > hdr_bytes) continue;

        const phdr: *align(1) const elf.Elf64Phdr = @ptrCast(&elf_hdr_buf[@as(usize, @truncate(phdr_off))]);
        if (phdr.p_type != 1) continue; // PT_LOAD only

        // Page-aligned segment boundaries
        const seg_start = phdr.p_vaddr & ~@as(u64, 0xFFF);
        const seg_end = pageAlignUp(phdr.p_vaddr + phdr.p_memsz);

        // VMA flags from ELF segment flags
        var vma_flags: u32 = vma.VMA_USER;
        if (phdr.p_flags & 4 != 0) vma_flags |= vma.VMA_READ; // PF_R
        if (phdr.p_flags & 2 != 0) vma_flags |= vma.VMA_WRITE; // PF_W
        if (phdr.p_flags & 1 != 0) vma_flags |= vma.VMA_EXEC; // PF_X

        // File offset aligned to page boundary
        const p_offset_aligned = phdr.p_offset & ~@as(u64, 0xFFF);
        // file_size = how many bytes of VMA are file-backed (includes page-offset padding)
        const file_size = phdr.p_filesz + (phdr.p_vaddr & 0xFFF);

        // Create file-backed VMA for this segment
        _ = vma.addElfVma(
            &current.vmas,
            seg_start,
            seg_end,
            vma_flags,
            @ptrCast(exec_inode),
            p_offset_aligned,
            file_size,
        );

        segments_loaded += 1;

        if (seg_end > highest_addr) highest_addr = seg_end;
        if (seg_start < lowest_addr) lowest_addr = seg_start;
    }

    if (segments_loaded == 0) {
        current.state = .zombie;
        current.exit_status = 127;
        scheduler.schedule(frame);
        return;
    }

    // Pin the executable inode so it doesn't get evicted from cache during demand paging
    ext2.pinInode(exec_inode);
    current.exec_inode = @ptrCast(exec_inode);

    // Allocate and map user stack
    var s: u64 = 0;
    while (s < process.USER_STACK_PAGES) : (s += 1) {
        const stack_page = pmm.allocPage() orelse {
            current.state = .zombie;
            current.exit_status = 127;
            scheduler.schedule(frame);
            return;
        };
        zeroPage(stack_page);
        const vaddr = process.USER_STACK_TOP - (process.USER_STACK_PAGES - s) * types.PAGE_SIZE;
        vmm.mapPage(current.page_table, vaddr, stack_page, .{
            .user = true,
            .writable = true,
            .no_execute = true,
        }) catch {
            current.state = .zombie;
            current.exit_status = 127;
            scheduler.schedule(frame);
            return;
        };
    }

    // Set up initial stack layout with argc/argv/envp/auxv
    var str_pos: u64 = process.USER_STACK_TOP;

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const slen = g_arg_lens[i] + 1;
        str_pos -= slen;
        _ = syscall.copyToUser(current.page_table, str_pos, arg_buf[g_arg_offsets[i] .. g_arg_offsets[i] + slen]);
        g_user_argv_addrs[i] = str_pos;
    }

    var ei: usize = 0;
    while (ei < envc) : (ei += 1) {
        const slen = g_env_lens[ei] + 1;
        str_pos -= slen;
        _ = syscall.copyToUser(current.page_table, str_pos, env_buf[g_env_offsets[ei] .. g_env_offsets[ei] + slen]);
        g_user_envp_addrs[ei] = str_pos;
    }

    // Write "x86_64\0" string for AT_PLATFORM
    str_pos -= 8; // "x86_64\0" = 7 bytes, aligned to 8
    const platform_addr = str_pos;
    _ = syscall.copyToUser(current.page_table, platform_addr, "x86_64\x00");

    // Write executable path for AT_EXECFN
    const exe_path_len: usize = current.exe_path_len;
    str_pos -= (exe_path_len + 1 + 7) & ~@as(u64, 7); // align to 8
    const execfn_addr = str_pos;
    if (exe_path_len > 0) {
        _ = syscall.copyToUser(current.page_table, execfn_addr, current.exe_path[0..exe_path_len]);
        var null_byte = [1]u8{0};
        _ = syscall.copyToUser(current.page_table, execfn_addr + exe_path_len, &null_byte);
    }

    // Write 16 random bytes for AT_RANDOM
    str_pos -= 16;
    const random_addr = str_pos;
    {
        var rand_buf: [16]u8 = undefined;
        // Use RDTSC-based PRNG for random bytes
        var seed: u64 = rdtsc();
        for (0..16) |ri| {
            seed = seed *% 6364136223846793005 +% 1;
            rand_buf[ri] = @truncate(seed >> 33);
        }
        _ = syscall.copyToUser(current.page_table, random_addr, &rand_buf);
    }

    // Align down to 16 bytes
    str_pos = str_pos & ~@as(u64, 0xF);

    // Calculate RSP: argc + argv ptrs + NULL + envp ptrs + NULL + auxv entries
    // auxv: AT_HWCAP, AT_PHDR, AT_PHENT, AT_PHNUM, AT_PAGESZ, AT_ENTRY,
    //        AT_UID, AT_EUID, AT_GID, AT_EGID, AT_RANDOM, AT_CLKTCK,
    //        AT_PLATFORM, AT_EXECFN, AT_NULL = 15 pairs = 30 u64s
    const auxv_count: usize = 30; // 15 key-value pairs
    const n_entries = 1 + argc + 1 + envc + 1 + auxv_count;
    var rsp = str_pos - n_entries * 8;
    rsp = rsp & ~@as(u64, 0xF);

    var pos: u64 = rsp;

    // argc
    writeToUser64(current.page_table, pos, argc);
    pos += 8;

    // argv[0..argc]
    var j: usize = 0;
    while (j < argc) : (j += 1) {
        writeToUser64(current.page_table, pos, g_user_argv_addrs[j]);
        pos += 8;
    }
    writeToUser64(current.page_table, pos, 0); // argv terminator
    pos += 8;

    // envp[0..envc]
    var ej: usize = 0;
    while (ej < envc) : (ej += 1) {
        writeToUser64(current.page_table, pos, g_user_envp_addrs[ej]);
        pos += 8;
    }
    writeToUser64(current.page_table, pos, 0); // envp terminator
    pos += 8;

    // Auxiliary vector
    // AT_HWCAP (16) = CPU feature bitmask from CPUID
    // Linux uses CPUID leaf 1 EDX for AT_HWCAP on x86_64
    const hwcap: u64 = blk: {
        var edx: u32 = undefined;
        asm volatile ("cpuid"
            : [edx] "={edx}" (edx),
            : [eax] "{eax}" (@as(u32, 1)),
            : .{ .ebx = true, .ecx = true }
        );
        break :blk edx;
    };
    writeToUser64(current.page_table, pos, 16); // AT_HWCAP
    pos += 8;
    writeToUser64(current.page_table, pos, hwcap);
    pos += 8;

    // AT_PHDR (3) = address of program headers in memory
    const at_phdr_addr = lowest_addr + header.e_phoff;
    writeToUser64(current.page_table, pos, 3); // AT_PHDR
    pos += 8;
    writeToUser64(current.page_table, pos, at_phdr_addr);
    pos += 8;

    // AT_PHENT (4) = size of program header entry
    writeToUser64(current.page_table, pos, 4); // AT_PHENT
    pos += 8;
    writeToUser64(current.page_table, pos, header.e_phentsize);
    pos += 8;

    // AT_PHNUM (5) = number of program headers
    writeToUser64(current.page_table, pos, 5); // AT_PHNUM
    pos += 8;
    writeToUser64(current.page_table, pos, header.e_phnum);
    pos += 8;

    // AT_PAGESZ (6) = page size
    writeToUser64(current.page_table, pos, 6); // AT_PAGESZ
    pos += 8;
    writeToUser64(current.page_table, pos, 4096);
    pos += 8;

    // AT_ENTRY (9) = entry point
    writeToUser64(current.page_table, pos, 9); // AT_ENTRY
    pos += 8;
    writeToUser64(current.page_table, pos, header.e_entry);
    pos += 8;

    // AT_UID (11) = real uid
    writeToUser64(current.page_table, pos, 11); // AT_UID
    pos += 8;
    writeToUser64(current.page_table, pos, current.uid);
    pos += 8;

    // AT_EUID (12) = effective uid
    writeToUser64(current.page_table, pos, 12); // AT_EUID
    pos += 8;
    writeToUser64(current.page_table, pos, current.euid);
    pos += 8;

    // AT_GID (13) = real gid
    writeToUser64(current.page_table, pos, 13); // AT_GID
    pos += 8;
    writeToUser64(current.page_table, pos, current.gid);
    pos += 8;

    // AT_EGID (14) = effective gid
    writeToUser64(current.page_table, pos, 14); // AT_EGID
    pos += 8;
    writeToUser64(current.page_table, pos, current.egid);
    pos += 8;

    // AT_CLKTCK (17) = clock ticks per second
    writeToUser64(current.page_table, pos, 17); // AT_CLKTCK
    pos += 8;
    writeToUser64(current.page_table, pos, 100);
    pos += 8;

    // AT_RANDOM (25) = pointer to 16 random bytes
    writeToUser64(current.page_table, pos, 25); // AT_RANDOM
    pos += 8;
    writeToUser64(current.page_table, pos, random_addr);
    pos += 8;

    // AT_PLATFORM (15) = "x86_64" string
    writeToUser64(current.page_table, pos, 15); // AT_PLATFORM
    pos += 8;
    writeToUser64(current.page_table, pos, platform_addr);
    pos += 8;

    // AT_EXECFN (31) = executable filename
    writeToUser64(current.page_table, pos, 31); // AT_EXECFN
    pos += 8;
    writeToUser64(current.page_table, pos, execfn_addr);
    pos += 8;

    // AT_NULL (0) = end of auxv
    writeToUser64(current.page_table, pos, 0); // AT_NULL
    pos += 8;
    writeToUser64(current.page_table, pos, 0);
    pos += 8;

    // Update process state
    current.heap_start = highest_addr;
    current.heap_current = highest_addr;

    // Reset VMAs — ELF VMAs already added above, add stack and heap
    _ = vma.addVma(&current.vmas, process.USER_STACK_TOP - process.USER_STACK_VMA_PAGES * types.PAGE_SIZE, process.USER_STACK_TOP + types.PAGE_SIZE, vma.VMA_READ | vma.VMA_WRITE | vma.VMA_USER);
    _ = vma.addVma(&current.vmas, highest_addr, highest_addr, vma.VMA_READ | vma.VMA_WRITE | vma.VMA_USER);

    // Reset signal handlers to SIG_DFL (per POSIX)
    for (0..process.MAX_SIGNALS) |si| {
        current.sig_actions[si] = .{};
    }
    current.sig_pending = 0;
    current.clear_child_tid = 0;
    current.fs_base = 0;
    // Clear FS_BASE MSR — old value points to parent's destroyed TLS/mmap region.
    // Without this, the new binary's musl accesses %fs:0x38 at the stale address → SIGSEGV.
    serial.writeString("[execve] FS_BASE clear\n");
    syscall_entry.wrmsrPub(0xC0000100, 0);
    current.mmap_hint = process.aslrMmapBase();

    // Wake vfork parent — execve completes the vfork contract.
    // The parent was blocked waiting for the child to exec or exit.
    wakeVforkParent(current);

    // Zee eBPF: drop capabilities on execve unless binary is whitelisted.
    // Root (euid==0) always retains all capabilities implicitly via hasCap().
    if (current.euid != 0) {
        const capability = @import("../security/capability.zig");
        if (!capability.retainsCapsOnExec(path_buf[0..path_len])) {
            current.capabilities = 0;
        }
    }

    // Debug: log successful exec + verify kernel half of page table
    serial.writeString("[execve] entry=0x");
    writeHex(header.e_entry);
    serial.writeString(" segs=");
    writeHex(segments_loaded);
    {
        // Verify PML4[256] (HHDM) is present — kernel stack lives here
        const pml4: *vmm.PageTable = hhdm.physToPtr(vmm.PageTable, current.page_table);
        const e256: u64 = @bitCast(pml4.entries[256]);
        serial.writeString(" pml4[256]=0x");
        writeHex(e256);
        // Also check TSS RSP0
        const tss_mod = @import("../arch/x86_64/tss.zig");
        serial.writeString(" rsp0=0x");
        writeHex(tss_mod.getRsp0());
        // Check if rsp0 is translatable
        if (vmm.translate(current.page_table, tss_mod.getRsp0() - 8)) |_| {
            serial.writeString(" (mapped)");
        } else {
            serial.writeString(" (UNMAPPED!)");
        }
    }
    serial.writeString("\n");

    // Set interrupt frame to new entry point
    frame.rip = header.e_entry;
    frame.rsp = rsp;
    frame.rax = 0;
    frame.rdi = 0;
    frame.rsi = 0;
    frame.rdx = 0;
    frame.rcx = 0;
    frame.rbx = 0;
    frame.r8 = 0;
    frame.r9 = 0;
    frame.r10 = 0;
    frame.r11 = 0;
    frame.r12 = 0;
    frame.r13 = 0;
    frame.r14 = 0;
    frame.r15 = 0;
    frame.rbp = 0;
    frame.cs = gdt.USER_CS;
    frame.ss = gdt.USER_DS;
    frame.rflags = 0x202;

    vmm.switchAddressSpace(current.page_table);
}

/// Wake the vfork parent if this process was a vfork child.
fn wakeVforkParent(current: *process.Process) void {
    if (current.parent_pid == 0) return;
    for (0..process.MAX_PROCESSES) |i| {
        if (process.getProcess(i)) |p| {
            if (p.pid == current.parent_pid and p.vfork_blocked) {
                p.vfork_blocked = false;
                p.state = .ready;
                break;
            }
        }
    }
}

// --- Helpers ---

/// Read the first `buf.len` bytes of a file via inode read op. Returns bytes read.
fn readFileHead(inode: *vfs.Inode, buf: []u8) ?usize {
    const read_fn = inode.ops.read orelse return null;

    var desc = vfs.FileDescription{
        .inode = inode,
        .offset = 0,
        .flags = vfs.O_RDONLY,
        .ref_count = 1,
        .in_use = true,
    };

    var total: usize = 0;
    while (total < buf.len) {
        const chunk = @min(buf.len - total, 4096);
        const ptr: [*]u8 = @ptrCast(&buf[total]);
        const n = read_fn(&desc, ptr, chunk);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

fn readUserU64(page_table: u64, addr: u64) ?u64 {
    if (vmm.translate(page_table, addr)) |phys| {
        const ptr: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
        var result: u64 = 0;
        for (0..8) |k| {
            result |= @as(u64, ptr[k]) << @as(u6, @truncate(k * 8));
        }
        return result;
    }
    return null;
}

fn writeToUser64(page_table: u64, addr: u64, val: u64) void {
    var buf: [8]u8 = undefined;
    var v = val;
    for (0..8) |k| {
        buf[k] = @truncate(v);
        v >>= 8;
    }
    _ = syscall.copyToUser(page_table, addr, &buf);
}

fn zeroPage(phys: types.PhysAddr) void {
    const ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    for (0..types.PAGE_SIZE) |k| {
        ptr[k] = 0;
    }
}

fn pageAlignUp(addr: u64) u64 {
    return (addr + types.PAGE_SIZE - 1) & ~(types.PAGE_SIZE - 1);
}

fn checkExecPermission(inode: *vfs.Inode, proc: *process.Process) bool {
    if (proc.euid == 0) return true;
    const mode = inode.mode & 0o7777;
    const bits: u32 = if (proc.euid == inode.uid)
        (mode >> 6) & 7
    else if (proc.egid == inode.gid)
        (mode >> 3) & 7
    else
        mode & 7;
    return (bits & 1) != 0;
}

fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
    );
    return @as(u64, high) << 32 | low;
}

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var k: usize = 16;
    while (k > 0) {
        k -= 1;
        buf[k] = hex[@as(usize, @truncate(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}
