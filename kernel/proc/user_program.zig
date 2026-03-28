/// Hardcoded user-mode program — raw x86_64 machine code.
/// Loaded at USER_CODE_BASE (0x400000) in the process address space.
///
/// Disassembly:
///
///   Offset  Bytes                   Instruction
///   ------  ----------------------  -----------
///   0x00    48 c7 c0 01 00 00 00    mov rax, 1          ; SYS_WRITE
///   0x07    48 c7 c7 01 00 00 00    mov rdi, 1          ; fd = stdout
///   0x0E    48 8d 35 17 00 00 00    lea rsi, [rip+0x17] ; buf = &msg (RIP after = 0x15, msg at 0x2C, delta = 0x17)
///   0x15    48 c7 c2 16 00 00 00    mov rdx, 22         ; len = 22
///   0x1C    cd 80                   int 0x80            ; syscall
///   0x1E    48 c7 c0 3c 00 00 00    mov rax, 60         ; SYS_EXIT
///   0x25    48 31 ff                xor rdi, rdi        ; status = 0
///   0x28    cd 80                   int 0x80            ; syscall
///   0x2A    eb fe                   jmp $               ; fallback infinite loop
///   0x2C    "Hello from userspace!\n"                   ; 22 bytes
///
/// Total: 66 bytes (fits in one 4 KiB page)

pub const user_code = [_]u8{
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (fd = stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x17] (pointer to message string)
    0x48, 0x8d, 0x35, 0x17, 0x00, 0x00, 0x00,
    // mov rdx, 22 (message length)
    0x48, 0xc7, 0xc2, 0x16, 0x00, 0x00, 0x00,
    // int 0x80 (syscall)
    0xcd, 0x80,
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (status = 0)
    0x48, 0x31, 0xff,
    // int 0x80 (syscall)
    0xcd, 0x80,
    // jmp $ (infinite loop fallback)
    0xeb, 0xfe,
    // "Hello from userspace!\n"
    'H', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm', ' ',
    'u', 's', 'e', 'r', 's', 'p', 'a', 'c', 'e', '!', '\n',
};

/// Looping user program A — prints "A\n" forever with busy-wait between prints.
/// Used to demonstrate preemptive scheduling (interleaves with program B).
///
///   Offset  Bytes                   Instruction
///   ------  ----------------------  -----------
///   0x00    48 c7 c0 01 00 00 00    mov rax, 1          ; SYS_WRITE
///   0x07    48 c7 c7 01 00 00 00    mov rdi, 1          ; fd = stdout
///   0x0E    48 8d 35 14 00 00 00    lea rsi, [rip+0x14] ; buf = &msg (RIP after = 0x15, msg at 0x29)
///   0x15    48 c7 c2 02 00 00 00    mov rdx, 2          ; len = 2
///   0x1C    cd 80                   int 0x80            ; syscall
///   0x1E    b9 40 4b 4c 00          mov ecx, 5000000    ; busy-wait counter
///   0x23    ff c9                   dec ecx
///   0x25    75 fc                   jnz -4 (→0x23)
///   0x27    eb d7                   jmp -0x29 (→0x00)   ; loop forever
///   0x29    'A', '\n'                                    ; message
///
/// Total: 43 bytes
pub const user_code_a = [_]u8{
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (fd = stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x14] (pointer to msg at offset 0x29)
    0x48, 0x8d, 0x35, 0x14, 0x00, 0x00, 0x00,
    // mov rdx, 2 (len = 2)
    0x48, 0xc7, 0xc2, 0x02, 0x00, 0x00, 0x00,
    // int 0x80 (syscall)
    0xcd, 0x80,
    // mov ecx, 5000000 (0x004C4B40) — busy-wait counter
    0xb9, 0x40, 0x4b, 0x4c, 0x00,
    // dec ecx
    0xff, 0xc9,
    // jnz -4 (back to dec ecx)
    0x75, 0xfc,
    // jmp -0x29 (back to start)
    0xeb, 0xd7,
    // "A\n"
    'A', '\n',
};

/// Heap test program — exercises brk syscall, then prints "Heap works!\n".
///
///   Offset  Bytes                   Instruction
///   ------  ----------------------  -----------
///   0x00    48 c7 c0 0c 00 00 00    mov rax, 12         ; SYS_BRK
///   0x07    48 31 ff                xor rdi, rdi        ; arg=0 (query current break)
///   0x0A    cd 80                   int 0x80            ; rax = current break
///   0x0C    48 89 c7                mov rdi, rax        ; rdi = current break
///   0x0F    48 81 c7 00 10 00 00    add rdi, 0x1000     ; request +4096 (one page)
///   0x16    48 c7 c0 0c 00 00 00    mov rax, 12         ; SYS_BRK
///   0x1D    cd 80                   int 0x80            ; rax = new break
///   0x1F    c6 40 ff 42             mov byte [rax-1], 0x42 ; write to new page (proves mapped)
///   0x23    48 c7 c0 01 00 00 00    mov rax, 1          ; SYS_WRITE
///   0x2A    48 c7 c7 01 00 00 00    mov rdi, 1          ; fd = stdout
///   0x31    48 8d 35 17 00 00 00    lea rsi, [rip+0x17] ; buf = &msg (RIP after = 0x38, msg at 0x4F)
///   0x38    48 c7 c2 0c 00 00 00    mov rdx, 12         ; len = 12
///   0x3F    cd 80                   int 0x80            ; syscall
///   0x41    48 c7 c0 3c 00 00 00    mov rax, 60         ; SYS_EXIT
///   0x48    48 31 ff                xor rdi, rdi        ; status = 0
///   0x4B    cd 80                   int 0x80            ; syscall
///   0x4D    eb fe                   jmp $               ; fallback infinite loop
///   0x4F    "Heap works!\n"                             ; 12 bytes
///
/// Total: 91 bytes
pub const user_code_heap = [_]u8{
    // mov rax, 12 (SYS_BRK)
    0x48, 0xc7, 0xc0, 0x0c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (arg=0: query current break)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // mov rdi, rax (rdi = current break)
    0x48, 0x89, 0xc7,
    // add rdi, 0x1000 (request +4096)
    0x48, 0x81, 0xc7, 0x00, 0x10, 0x00, 0x00,
    // mov rax, 12 (SYS_BRK)
    0x48, 0xc7, 0xc0, 0x0c, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // mov byte [rax-1], 0x42 (write to last byte of new page)
    0xc6, 0x40, 0xff, 0x42,
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (fd = stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x17] (pointer to msg at offset 0x4F)
    0x48, 0x8d, 0x35, 0x17, 0x00, 0x00, 0x00,
    // mov rdx, 12 (message length)
    0x48, 0xc7, 0xc2, 0x0c, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (status = 0)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // jmp $ (fallback infinite loop)
    0xeb, 0xfe,
    // "Heap works!\n"
    'H', 'e', 'a', 'p', ' ', 'w', 'o', 'r', 'k', 's', '!', '\n',
};

/// Pipe writer — writes "Pipe works!\n" to fd 3 (pipe write end), then exits.
///
///   Offset  Bytes                   Instruction
///   ------  ----------------------  -----------
///   0x00    48 c7 c0 01 00 00 00    mov rax, 1          ; SYS_WRITE
///   0x07    48 c7 c7 03 00 00 00    mov rdi, 3          ; fd = 3 (pipe write end)
///   0x0E    48 8d 35 17 00 00 00    lea rsi, [rip+0x17] ; buf = &msg (at 0x2C)
///   0x15    48 c7 c2 0c 00 00 00    mov rdx, 12         ; len = 12
///   0x1C    cd 80                   int 0x80
///   0x1E    48 c7 c0 3c 00 00 00    mov rax, 60         ; SYS_EXIT
///   0x25    48 31 ff                xor rdi, rdi        ; status = 0
///   0x28    cd 80                   int 0x80
///   0x2A    eb fe                   jmp $               ; fallback
///   0x2C    "Pipe works!\n"                             ; 12 bytes
///
/// Total: 56 bytes
pub const user_code_pipe_writer = [_]u8{
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 3 (fd = pipe write end)
    0x48, 0xc7, 0xc7, 0x03, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x17] (msg at 0x2C)
    0x48, 0x8d, 0x35, 0x17, 0x00, 0x00, 0x00,
    // mov rdx, 12 (len)
    0x48, 0xc7, 0xc2, 0x0c, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (status = 0)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // jmp $ (fallback)
    0xeb, 0xfe,
    // "Pipe works!\n"
    'P', 'i', 'p', 'e', ' ', 'w', 'o', 'r', 'k', 's', '!', '\n',
};

/// Pipe reader — reads from fd 3 (pipe read end), prints to stdout,
/// calls wait4(-1) to reap child, prints "Wait OK\n", exits.
///
///   Offset  Bytes                   Instruction
///   ------  ----------------------  -----------
///   0x00    48 83 ec 40             sub rsp, 64         ; stack buffer
///   0x04    48 c7 c0 00 00 00 00    mov rax, 0          ; SYS_READ
///   0x0B    48 c7 c7 03 00 00 00    mov rdi, 3          ; fd = 3 (pipe read end)
///   0x12    48 89 e6                mov rsi, rsp        ; buf = stack
///   0x15    48 c7 c2 40 00 00 00    mov rdx, 64         ; count
///   0x1C    cd 80                   int 0x80
///   0x1E    48 89 c2                mov rdx, rax        ; len = bytes_read
///   0x21    48 c7 c0 01 00 00 00    mov rax, 1          ; SYS_WRITE
///   0x28    48 c7 c7 01 00 00 00    mov rdi, 1          ; fd = stdout
///   0x2F    48 89 e6                mov rsi, rsp        ; buf = stack
///   0x32    cd 80                   int 0x80
///   0x34    48 c7 c0 3d 00 00 00    mov rax, 61         ; SYS_WAIT4
///   0x3B    48 c7 c7 ff ff ff ff    mov rdi, -1         ; pid = any
///   0x42    48 31 f6                xor rsi, rsi        ; wstatus = NULL
///   0x45    48 31 d2                xor rdx, rdx        ; options = 0
///   0x48    4d 31 d2                xor r10, r10        ; rusage = NULL
///   0x4B    cd 80                   int 0x80
///   0x4D    48 c7 c0 01 00 00 00    mov rax, 1          ; SYS_WRITE
///   0x54    48 c7 c7 01 00 00 00    mov rdi, 1          ; fd = stdout
///   0x5B    48 8d 35 17 00 00 00    lea rsi, [rip+0x17] ; "Wait OK\n" (at 0x79)
///   0x62    48 c7 c2 08 00 00 00    mov rdx, 8          ; len = 8
///   0x69    cd 80                   int 0x80
///   0x6B    48 c7 c0 3c 00 00 00    mov rax, 60         ; SYS_EXIT
///   0x72    48 31 ff                xor rdi, rdi        ; status = 0
///   0x75    cd 80                   int 0x80
///   0x77    eb fe                   jmp $
///   0x79    "Wait OK\n"                                 ; 8 bytes
///
/// Total: 129 bytes
pub const user_code_pipe_reader = [_]u8{
    // sub rsp, 64 (stack buffer)
    0x48, 0x83, 0xec, 0x40,
    // mov rax, 0 (SYS_READ)
    0x48, 0xc7, 0xc0, 0x00, 0x00, 0x00, 0x00,
    // mov rdi, 3 (fd = pipe read end)
    0x48, 0xc7, 0xc7, 0x03, 0x00, 0x00, 0x00,
    // mov rsi, rsp (buf = stack)
    0x48, 0x89, 0xe6,
    // mov rdx, 64 (count)
    0x48, 0xc7, 0xc2, 0x40, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // mov rdx, rax (len = bytes_read)
    0x48, 0x89, 0xc2,
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (fd = stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // mov rsi, rsp (buf = stack)
    0x48, 0x89, 0xe6,
    // int 0x80
    0xcd, 0x80,
    // mov rax, 61 (SYS_WAIT4)
    0x48, 0xc7, 0xc0, 0x3d, 0x00, 0x00, 0x00,
    // mov rdi, -1 (any child)
    0x48, 0xc7, 0xc7, 0xff, 0xff, 0xff, 0xff,
    // xor rsi, rsi (wstatus = NULL)
    0x48, 0x31, 0xf6,
    // xor rdx, rdx (options = 0)
    0x48, 0x31, 0xd2,
    // xor r10, r10 (rusage = NULL)
    0x4d, 0x31, 0xd2,
    // int 0x80
    0xcd, 0x80,
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (fd = stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x17] ("Wait OK\n" at 0x79)
    0x48, 0x8d, 0x35, 0x17, 0x00, 0x00, 0x00,
    // mov rdx, 8 (len)
    0x48, 0xc7, 0xc2, 0x08, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (status = 0)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // jmp $ (fallback)
    0xeb, 0xfe,
    // "Wait OK\n"
    'W', 'a', 'i', 't', ' ', 'O', 'K', '\n',
};

/// Mmap test program — exercises mmap and munmap syscalls.
///
/// 1. mmap(NULL, 0x2000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
///    → allocates 2 pages of anonymous memory
/// 2. Write "Mmap OK\n" into the mapped region (triggers demand page fault)
/// 3. write(1, mapped_addr, 8) → print from mapped memory
/// 4. munmap(mapped_addr, 0x2000) → unmap
/// 5. write(1, "Unmap OK\n", 9) → print success
/// 6. exit(0)
///
/// Syscall args for mmap: rax=9, rdi=0, rsi=0x2000, rdx=3, r10=0x22, r8=-1, r9=0
/// Note: 4th arg is r10 (not rcx, which is clobbered by int 0x80)
///
///   Offset  Bytes                               Instruction
///   ------  ----------------------------------  -----------
///   0x00    48 c7 c0 09 00 00 00                mov rax, 9          ; SYS_MMAP
///   0x07    48 31 ff                            xor rdi, rdi        ; addr = NULL
///   0x0a    48 c7 c6 00 20 00 00                mov rsi, 0x2000     ; length
///   0x11    48 c7 c2 03 00 00 00                mov rdx, 3          ; PROT_READ|PROT_WRITE
///   0x18    49 c7 c2 22 00 00 00                mov r10, 0x22       ; MAP_PRIVATE|MAP_ANONYMOUS
///   0x1f    49 c7 c0 ff ff ff ff                mov r8, -1          ; fd = -1
///   0x26    4d 31 c9                            xor r9, r9          ; offset = 0
///   0x29    cd 80                               int 0x80
///   0x2b    49 89 c4                            mov r12, rax        ; save mapped addr
///   0x2e    41 c6 04 24 4d                      mov byte [r12], 'M'
///   0x33    41 c6 44 24 01 6d                   mov byte [r12+1], 'm'
///   0x39    41 c6 44 24 02 61                   mov byte [r12+2], 'a'
///   0x3f    41 c6 44 24 03 70                   mov byte [r12+3], 'p'
///   0x45    41 c6 44 24 04 20                   mov byte [r12+4], ' '
///   0x4b    41 c6 44 24 05 4f                   mov byte [r12+5], 'O'
///   0x51    41 c6 44 24 06 4b                   mov byte [r12+6], 'K'
///   0x57    41 c6 44 24 07 0a                   mov byte [r12+7], '\n'
///   0x5d    48 c7 c0 01 00 00 00                mov rax, 1          ; SYS_WRITE
///   0x64    48 c7 c7 01 00 00 00                mov rdi, 1          ; stdout
///   0x6b    4c 89 e6                            mov rsi, r12        ; buf = mapped
///   0x6e    48 c7 c2 08 00 00 00                mov rdx, 8          ; len
///   0x75    cd 80                               int 0x80
///   0x77    48 c7 c0 0b 00 00 00                mov rax, 11         ; SYS_MUNMAP
///   0x7e    4c 89 e7                            mov rdi, r12        ; addr
///   0x81    48 c7 c6 00 20 00 00                mov rsi, 0x2000     ; length
///   0x88    cd 80                               int 0x80
///   0x8a    48 c7 c0 01 00 00 00                mov rax, 1          ; SYS_WRITE
///   0x91    48 c7 c7 01 00 00 00                mov rdi, 1          ; stdout
///   0x98    48 8d 35 17 00 00 00                lea rsi, [rip+0x17] ; "Unmap OK\n" at 0xb6
///   0x9f    48 c7 c2 09 00 00 00                mov rdx, 9          ; len
///   0xa6    cd 80                               int 0x80
///   0xa8    48 c7 c0 3c 00 00 00                mov rax, 60         ; SYS_EXIT
///   0xaf    48 31 ff                            xor rdi, rdi        ; status = 0
///   0xb2    cd 80                               int 0x80
///   0xb4    eb fe                               jmp $               ; fallback
///   0xb6    "Unmap OK\n"                                            ; 9 bytes
///
/// Total: 191 bytes (0xBF)
pub const user_code_mmap_test = [_]u8{
    // mov rax, 9 (SYS_MMAP)
    0x48, 0xc7, 0xc0, 0x09, 0x00, 0x00, 0x00,
    // xor rdi, rdi (addr = NULL)
    0x48, 0x31, 0xff,
    // mov rsi, 0x2000 (length = 2 pages)
    0x48, 0xc7, 0xc6, 0x00, 0x20, 0x00, 0x00,
    // mov rdx, 3 (PROT_READ|PROT_WRITE)
    0x48, 0xc7, 0xc2, 0x03, 0x00, 0x00, 0x00,
    // mov r10, 0x22 (MAP_PRIVATE|MAP_ANONYMOUS)
    0x49, 0xc7, 0xc2, 0x22, 0x00, 0x00, 0x00,
    // mov r8, -1 (fd = -1, no file)
    0x49, 0xc7, 0xc0, 0xff, 0xff, 0xff, 0xff,
    // xor r9, r9 (offset = 0)
    0x4d, 0x31, 0xc9,
    // int 0x80 (mmap syscall)
    0xcd, 0x80,

    // mov r12, rax (save mapped address)
    0x49, 0x89, 0xc4,

    // Write "Mmap OK\n" byte-by-byte into mapped memory
    // mov byte [r12+0], 'M'
    0x41, 0xc6, 0x04, 0x24, 0x4d,
    // mov byte [r12+1], 'm'
    0x41, 0xc6, 0x44, 0x24, 0x01, 0x6d,
    // mov byte [r12+2], 'a'
    0x41, 0xc6, 0x44, 0x24, 0x02, 0x61,
    // mov byte [r12+3], 'p'
    0x41, 0xc6, 0x44, 0x24, 0x03, 0x70,
    // mov byte [r12+4], ' '
    0x41, 0xc6, 0x44, 0x24, 0x04, 0x20,
    // mov byte [r12+5], 'O'
    0x41, 0xc6, 0x44, 0x24, 0x05, 0x4f,
    // mov byte [r12+6], 'K'
    0x41, 0xc6, 0x44, 0x24, 0x06, 0x4b,
    // mov byte [r12+7], '\n'
    0x41, 0xc6, 0x44, 0x24, 0x07, 0x0a,

    // write(1, mapped_addr, 8)
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // mov rsi, r12 (buf = mapped memory)
    0x4c, 0x89, 0xe6,
    // mov rdx, 8 (len)
    0x48, 0xc7, 0xc2, 0x08, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,

    // munmap(mapped_addr, 0x2000)
    // mov rax, 11 (SYS_MUNMAP)
    0x48, 0xc7, 0xc0, 0x0b, 0x00, 0x00, 0x00,
    // mov rdi, r12 (addr)
    0x4c, 0x89, 0xe7,
    // mov rsi, 0x2000 (length)
    0x48, 0xc7, 0xc6, 0x00, 0x20, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,

    // write(1, "Unmap OK\n", 9)
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x17] ("Unmap OK\n" at offset 0xb6)
    0x48, 0x8d, 0x35, 0x17, 0x00, 0x00, 0x00,
    // mov rdx, 9 (len)
    0x48, 0xc7, 0xc2, 0x09, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,

    // exit(0)
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (status = 0)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // jmp $ (fallback)
    0xeb, 0xfe,

    // "Unmap OK\n" (9 bytes, at offset 0xb6)
    'U', 'n', 'm', 'a', 'p', ' ', 'O', 'K', '\n',
};

/// Signal test — prints "Sig test\n", then NULL dereference → SIGSEGV → terminate.
/// Proves unresolvable user page fault no longer halts the kernel.
///
///   Offset  Bytes                   Instruction
///   ------  ----------------------  -----------
///   0x00    48 c7 c0 01 00 00 00    mov rax, 1          ; SYS_WRITE
///   0x07    48 c7 c7 01 00 00 00    mov rdi, 1          ; fd = stdout
///   0x0e    48 8d 35 1d 00 00 00    lea rsi, [rip+0x1d] ; "Sig test\n" at 0x32
///   0x15    48 c7 c2 09 00 00 00    mov rdx, 9          ; len = 9
///   0x1c    cd 80                   int 0x80
///   0x1e    48 31 ff                xor rdi, rdi        ; rdi = 0 (NULL)
///   0x21    c6 07 42                mov byte [rdi], 0x42 ; → SIGSEGV
///   0x24    48 c7 c0 3c 00 00 00    mov rax, 60         ; SYS_EXIT (unreachable)
///   0x2b    48 31 ff                xor rdi, rdi
///   0x2e    cd 80                   int 0x80
///   0x30    eb fe                   jmp $               ; fallback
///   0x32    "Sig test\n"                                ; 9 bytes
///
/// Total: 59 bytes (0x3B)
pub const user_code_signal_test = [_]u8{
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (fd = stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x1d] ("Sig test\n" at offset 0x32)
    0x48, 0x8d, 0x35, 0x1d, 0x00, 0x00, 0x00,
    // mov rdx, 9 (len)
    0x48, 0xc7, 0xc2, 0x09, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // xor rdi, rdi (rdi = 0, NULL)
    0x48, 0x31, 0xff,
    // mov byte [rdi], 0x42 (NULL dereference → SIGSEGV)
    0xc6, 0x07, 0x42,
    // mov rax, 60 (SYS_EXIT — unreachable)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (status = 0)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // jmp $ (fallback)
    0xeb, 0xfe,
    // "Sig test\n"
    'S', 'i', 'g', ' ', 't', 'e', 's', 't', '\n',
};

/// Looping user program B — identical to A but prints "B\n".
pub const user_code_b = [_]u8{
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    0x48, 0x8d, 0x35, 0x14, 0x00, 0x00, 0x00,
    0x48, 0xc7, 0xc2, 0x02, 0x00, 0x00, 0x00,
    0xcd, 0x80,
    0xb9, 0x40, 0x4b, 0x4c, 0x00,
    0xff, 0xc9,
    0x75, 0xfc,
    0xeb, 0xd7,
    'B', '\n',
};

/// VFS file test — opens /hello.txt (pre-created by kernel), reads it, writes to stdout.
/// Exercises: open(2), read(0), write(1), close(3), exit(60).
///
///   Offset  Bytes                   Instruction
///   ------  ----------------------  -----------
///   0x00    48 83 ec 40             sub rsp, 64         ; stack buffer for read
///   0x04    48 c7 c0 02 00 00 00   mov rax, 2          ; SYS_OPEN
///   0x0B    48 8d 3d 52 00 00 00   lea rdi, [rip+0x52] ; path = "/hello.txt" (at 0x64)
///   0x12    48 31 f6               xor rsi, rsi        ; flags = O_RDONLY (0)
///   0x15    48 31 d2               xor rdx, rdx        ; mode = 0
///   0x18    cd 80                  int 0x80
///   0x1A    48 89 c7               mov rdi, rax        ; fd = open() result (3)
///   0x1D    48 c7 c0 00 00 00 00   mov rax, 0          ; SYS_READ
///   0x24    48 89 e6               mov rsi, rsp        ; buf = stack buffer
///   0x27    48 c7 c2 40 00 00 00   mov rdx, 64         ; count = 64
///   0x2E    cd 80                  int 0x80
///   0x30    48 89 c2               mov rdx, rax        ; len = bytes_read
///   0x33    48 c7 c0 01 00 00 00   mov rax, 1          ; SYS_WRITE
///   0x3A    48 c7 c7 01 00 00 00   mov rdi, 1          ; fd = stdout
///   0x41    48 89 e6               mov rsi, rsp        ; buf = stack buffer
///   0x44    cd 80                  int 0x80
///   0x46    48 c7 c0 03 00 00 00   mov rax, 3          ; SYS_CLOSE
///   0x4D    48 c7 c7 03 00 00 00   mov rdi, 3          ; fd = 3
///   0x54    cd 80                  int 0x80
///   0x56    48 c7 c0 3c 00 00 00   mov rax, 60         ; SYS_EXIT
///   0x5D    48 31 ff               xor rdi, rdi        ; status = 0
///   0x60    cd 80                  int 0x80
///   0x62    eb fe                  jmp $               ; fallback infinite loop
///   0x64    "/hello.txt\0"                             ; 11 bytes
///
/// Total: 111 bytes
pub const user_code_file_test = [_]u8{
    // sub rsp, 64 (stack buffer for read)
    0x48, 0x83, 0xec, 0x40,
    // mov rax, 2 (SYS_OPEN)
    0x48, 0xc7, 0xc0, 0x02, 0x00, 0x00, 0x00,
    // lea rdi, [rip+0x52] (path "/hello.txt" at offset 0x64)
    0x48, 0x8d, 0x3d, 0x52, 0x00, 0x00, 0x00,
    // xor rsi, rsi (flags = O_RDONLY)
    0x48, 0x31, 0xf6,
    // xor rdx, rdx (mode = 0)
    0x48, 0x31, 0xd2,
    // int 0x80
    0xcd, 0x80,
    // mov rdi, rax (fd = open() result)
    0x48, 0x89, 0xc7,
    // mov rax, 0 (SYS_READ)
    0x48, 0xc7, 0xc0, 0x00, 0x00, 0x00, 0x00,
    // mov rsi, rsp (buf = stack buffer)
    0x48, 0x89, 0xe6,
    // mov rdx, 64 (count)
    0x48, 0xc7, 0xc2, 0x40, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // mov rdx, rax (len = bytes_read)
    0x48, 0x89, 0xc2,
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (fd = stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // mov rsi, rsp (buf = stack buffer)
    0x48, 0x89, 0xe6,
    // int 0x80
    0xcd, 0x80,
    // mov rax, 3 (SYS_CLOSE)
    0x48, 0xc7, 0xc0, 0x03, 0x00, 0x00, 0x00,
    // mov rdi, 3 (fd = 3, the opened file)
    0x48, 0xc7, 0xc7, 0x03, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (status = 0)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // jmp $ (fallback infinite loop)
    0xeb, 0xfe,
    // "/hello.txt\0"
    '/', 'h', 'e', 'l', 'l', 'o', '.', 't', 'x', 't', 0,
};

/// Hand-crafted ELF64 binary — "Hello from ELF!\n" via write(1), then exit(0).
/// This is a complete, valid ELF executable: header + one PT_LOAD phdr + code + data.
/// Used to prove the ELF loader works end-to-end without any cross-compiler.
///
/// Layout:
///   Offset  Size  Content
///   ------  ----  -------
///   0x00    64    ELF64 header (ET_EXEC, EM_X86_64, entry=0x400078)
///   0x40    56    Program header (PT_LOAD, PF_R|PF_X, vaddr=0x400000)
///   0x78    44    Code (write + exit via int 0x80)
///   0xA4    16    "Hello from ELF!\n"
///
/// Code disassembly (virtual addresses 0x400078+):
///   0x400078  48 c7 c0 01 00 00 00    mov rax, 1          ; SYS_WRITE
///   0x40007F  48 c7 c7 01 00 00 00    mov rdi, 1          ; fd = stdout
///   0x400086  48 8d 35 17 00 00 00    lea rsi, [rip+0x17] ; buf = "Hello from ELF!\n"
///   0x40008D  48 c7 c2 10 00 00 00    mov rdx, 16         ; len = 16
///   0x400094  cd 80                   int 0x80             ; syscall
///   0x400096  48 c7 c0 3c 00 00 00    mov rax, 60         ; SYS_EXIT
///   0x40009D  48 31 ff                xor rdi, rdi         ; status = 0
///   0x4000A0  cd 80                   int 0x80             ; syscall
///   0x4000A2  eb fe                   jmp $                ; fallback
///   0x4000A4  "Hello from ELF!\n"                          ; 16 bytes
///
/// Total: 180 bytes (0xB4)
pub const test_elf_hello = [_]u8{
    // ===== ELF64 Header (64 bytes) =====
    // e_ident: magic + class + encoding + version + OS/ABI + padding
    0x7F, 'E', 'L', 'F', // magic
    0x02, // ELFCLASS64
    0x01, // ELFDATA2LSB (little-endian)
    0x01, // EV_CURRENT
    0x00, // ELFOSABI_NONE
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // padding
    // e_type = ET_EXEC (2)
    0x02, 0x00,
    // e_machine = EM_X86_64 (62)
    0x3E, 0x00,
    // e_version = 1
    0x01, 0x00, 0x00, 0x00,
    // e_entry = 0x400078 (code starts after headers)
    0x78, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    // e_phoff = 64 (program headers follow ELF header)
    0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // e_shoff = 0 (no section headers)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // e_flags = 0
    0x00, 0x00, 0x00, 0x00,
    // e_ehsize = 64
    0x40, 0x00,
    // e_phentsize = 56
    0x38, 0x00,
    // e_phnum = 1
    0x01, 0x00,
    // e_shentsize = 0, e_shnum = 0, e_shstrndx = 0
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    // ===== Program Header (56 bytes, offset 0x40) =====
    // p_type = PT_LOAD (1)
    0x01, 0x00, 0x00, 0x00,
    // p_flags = PF_R | PF_X (5)
    0x05, 0x00, 0x00, 0x00,
    // p_offset = 0 (load entire file)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // p_vaddr = 0x400000
    0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    // p_paddr = 0x400000
    0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    // p_filesz = 180 (0xB4)
    0xB4, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // p_memsz = 180 (0xB4)
    0xB4, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // p_align = 0x1000
    0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    // ===== Code (44 bytes, offset 0x78) =====
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (fd = stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x17] (msg at 0x4000A4, RIP after = 0x40008D, delta = 0x17)
    0x48, 0x8d, 0x35, 0x17, 0x00, 0x00, 0x00,
    // mov rdx, 16 (message length)
    0x48, 0xc7, 0xc2, 0x10, 0x00, 0x00, 0x00,
    // int 0x80 (syscall)
    0xcd, 0x80,
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (status = 0)
    0x48, 0x31, 0xff,
    // int 0x80 (syscall)
    0xcd, 0x80,
    // jmp $ (fallback infinite loop)
    0xeb, 0xfe,

    // ===== Data (16 bytes, offset 0xA4) =====
    // "Hello from ELF!\n"
    'H', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm', ' ', 'E', 'L', 'F', '!', '\n',
};

/// Demand paging test — requests 16 pages via brk (lazy), writes to first and last
/// page (triggers demand faults), prints "Demand OK\n", exits.
///
///   Offset  Bytes                         Instruction
///   ------  ----------------------------  -----------
///   0x00    48 c7 c0 0c 00 00 00          mov rax, 12          ; SYS_BRK
///   0x07    48 31 ff                      xor rdi, rdi         ; query current break
///   0x0a    cd 80                         int 0x80             ; rax = heap_start
///   0x0c    49 89 c4                      mov r12, rax         ; save heap_start in r12
///   0x0f    48 89 c7                      mov rdi, rax         ; rdi = heap_start
///   0x12    48 81 c7 00 00 01 00          add rdi, 0x10000     ; +64 KiB (16 pages)
///   0x19    48 c7 c0 0c 00 00 00          mov rax, 12          ; SYS_BRK
///   0x20    cd 80                         int 0x80             ; expand (lazy)
///   0x22    41 c6 04 24 41                mov byte [r12], 0x41 ; demand fault #1
///   0x27    41 c6 84 24 00 f0 00 00 42    mov byte [r12+0xF000], 0x42 ; demand fault #2
///   0x30    48 c7 c0 01 00 00 00          mov rax, 1           ; SYS_WRITE
///   0x37    48 c7 c7 01 00 00 00          mov rdi, 1           ; stdout
///   0x3e    48 8d 35 17 00 00 00          lea rsi, [rip+0x17]  ; "Demand OK\n" at 0x5c
///   0x45    48 c7 c2 0a 00 00 00          mov rdx, 10          ; len = 10
///   0x4c    cd 80                         int 0x80
///   0x4e    48 c7 c0 3c 00 00 00          mov rax, 60          ; SYS_EXIT
///   0x55    48 31 ff                      xor rdi, rdi         ; status = 0
///   0x58    cd 80                         int 0x80
///   0x5a    eb fe                         jmp $                ; fallback
///   0x5c    "Demand OK\n"                                      ; 10 bytes
///
/// Total: 102 bytes
pub const user_code_demand_test = [_]u8{
    // mov rax, 12 (SYS_BRK)
    0x48, 0xc7, 0xc0, 0x0c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (query current break)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // mov r12, rax (save heap_start)
    0x49, 0x89, 0xc4,
    // mov rdi, rax
    0x48, 0x89, 0xc7,
    // add rdi, 0x10000 (64 KiB = 16 pages)
    0x48, 0x81, 0xc7, 0x00, 0x00, 0x01, 0x00,
    // mov rax, 12 (SYS_BRK)
    0x48, 0xc7, 0xc0, 0x0c, 0x00, 0x00, 0x00,
    // int 0x80 (expand heap lazily)
    0xcd, 0x80,
    // mov byte [r12], 0x41 (write to first page → demand fault #1)
    0x41, 0xc6, 0x04, 0x24, 0x41,
    // mov byte [r12+0xF000], 0x42 (write to page 15 → demand fault #2)
    0x41, 0xc6, 0x84, 0x24, 0x00, 0xf0, 0x00, 0x00, 0x42,
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x17] ("Demand OK\n" at offset 0x5c)
    0x48, 0x8d, 0x35, 0x17, 0x00, 0x00, 0x00,
    // mov rdx, 10
    0x48, 0xc7, 0xc2, 0x0a, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (status = 0)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // jmp $ (fallback)
    0xeb, 0xfe,
    // "Demand OK\n"
    'D', 'e', 'm', 'a', 'n', 'd', ' ', 'O', 'K', '\n',
};

/// Thread test program — exercises clone(CLONE_VM|CLONE_THREAD) and futex.
///
/// 1. brk(0) → save heap_start in r12
/// 2. brk(heap_start + 0x3000) → 3 pages (2 for child stack, 1 for futex word)
/// 2b. mov dword [r12+0x2FF0], 0 → pre-fault the futex word page (demand paging)
/// 3. clone(CLONE_VM|FS|FILES|SIGHAND|THREAD, r12+0x2000) → parent gets TID, child gets 0
/// 4. Parent: futex_wait(&futex_word, 0, 0) → blocks if word==0, EAGAIN if child already done
///    Then print "Futex OK\n", exit(0)
/// 5. Child: print "Thread OK\n", store 1 to futex_word, futex_wake(1), exit(0)
///
///   Offset  Bytes                                     Instruction
///   ------  ----------------------------------------  -----------
///   0x00    48 c7 c0 0c 00 00 00                      mov rax, 12
///   0x07    48 31 ff                                  xor rdi, rdi
///   0x0a    cd 80                                     int 0x80
///   0x0c    49 89 c4                                  mov r12, rax
///   0x0f    48 89 c7                                  mov rdi, rax
///   0x12    48 81 c7 00 30 00 00                      add rdi, 0x3000
///   0x19    48 c7 c0 0c 00 00 00                      mov rax, 12
///   0x20    cd 80                                     int 0x80
///   0x22    41 c7 84 24 f0 2f 00 00 00 00 00 00       mov dword [r12+0x2FF0], 0  ; pre-fault
///   0x2e    48 c7 c7 00 0f 01 00                      mov rdi, 0x10F00
///   0x35    49 8d b4 24 00 20 00 00                   lea rsi, [r12+0x2000]
///   0x3d    48 c7 c0 38 00 00 00                      mov rax, 56
///   0x44    cd 80                                     int 0x80
///   0x46    48 85 c0                                  test rax, rax
///   0x49    74 43                                     jz 0x8e (child)
///   --- Parent ---
///   0x4b    49 8d bc 24 f0 2f 00 00                   lea rdi, [r12+0x2FF0]
///   0x53    48 31 f6                                  xor rsi, rsi
///   0x56    48 31 d2                                  xor rdx, rdx
///   0x59    48 c7 c0 ca 00 00 00                      mov rax, 202
///   0x60    cd 80                                     int 0x80
///   0x62    48 c7 c0 01 00 00 00                      mov rax, 1
///   0x69    48 c7 c7 01 00 00 00                      mov rdi, 1
///   0x70    48 8d 35 78 00 00 00                      lea rsi, [rip+0x78]  ; 0xef
///   0x77    48 c7 c2 09 00 00 00                      mov rdx, 9
///   0x7e    cd 80                                     int 0x80
///   0x80    48 c7 c0 3c 00 00 00                      mov rax, 60
///   0x87    48 31 ff                                  xor rdi, rdi
///   0x8a    cd 80                                     int 0x80
///   0x8c    eb fe                                     jmp $
///   --- Child ---
///   0x8e    48 c7 c0 01 00 00 00                      mov rax, 1
///   0x95    48 c7 c7 01 00 00 00                      mov rdi, 1
///   0x9c    48 8d 35 42 00 00 00                      lea rsi, [rip+0x42]  ; 0xe5
///   0xa3    48 c7 c2 0a 00 00 00                      mov rdx, 10
///   0xaa    cd 80                                     int 0x80
///   0xac    41 c7 84 24 f0 2f 00 00 01 00 00 00       mov dword [r12+0x2FF0], 1
///   0xb8    49 8d bc 24 f0 2f 00 00                   lea rdi, [r12+0x2FF0]
///   0xc0    48 c7 c6 01 00 00 00                      mov rsi, 1
///   0xc7    48 c7 c2 01 00 00 00                      mov rdx, 1
///   0xce    48 c7 c0 ca 00 00 00                      mov rax, 202
///   0xd5    cd 80                                     int 0x80
///   0xd7    48 c7 c0 3c 00 00 00                      mov rax, 60
///   0xde    48 31 ff                                  xor rdi, rdi
///   0xe1    cd 80                                     int 0x80
///   0xe3    eb fe                                     jmp $
///   0xe5    "Thread OK\n"                             ; 10 bytes
///   0xef    "Futex OK\n"                              ; 9 bytes
///
/// Total: 248 bytes (0xF8)
pub const user_code_thread_test = [_]u8{
    // === Step 1: brk(0) → r12 ===
    // mov rax, 12 (SYS_BRK)
    0x48, 0xc7, 0xc0, 0x0c, 0x00, 0x00, 0x00,
    // xor rdi, rdi (query current break)
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // mov r12, rax (save heap_start)
    0x49, 0x89, 0xc4,

    // === Step 2: brk(heap_start + 0x3000) ===
    // mov rdi, rax
    0x48, 0x89, 0xc7,
    // add rdi, 0x3000
    0x48, 0x81, 0xc7, 0x00, 0x30, 0x00, 0x00,
    // mov rax, 12 (SYS_BRK)
    0x48, 0xc7, 0xc0, 0x0c, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,

    // === Step 2b: Pre-fault the futex word page (demand paging) ===
    // mov dword [r12+0x2FF0], 0
    0x41, 0xc7, 0x84, 0x24, 0xf0, 0x2f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    // === Step 3: clone(0x10F00, r12+0x2000) ===
    // mov rdi, 0x10F00 (CLONE_VM|FS|FILES|SIGHAND|THREAD)
    0x48, 0xc7, 0xc7, 0x00, 0x0f, 0x01, 0x00,
    // lea rsi, [r12+0x2000] (child stack top)
    0x49, 0x8d, 0xb4, 0x24, 0x00, 0x20, 0x00, 0x00,
    // mov rax, 56 (SYS_CLONE)
    0x48, 0xc7, 0xc0, 0x38, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,

    // === Step 4: test rax / jz child ===
    // test rax, rax
    0x48, 0x85, 0xc0,
    // jz +0x43 (child path at 0x8e)
    0x74, 0x43,

    // === PARENT path ===
    // lea rdi, [r12+0x2FF0] (futex word address)
    0x49, 0x8d, 0xbc, 0x24, 0xf0, 0x2f, 0x00, 0x00,
    // xor rsi, rsi (FUTEX_WAIT = 0)
    0x48, 0x31, 0xf6,
    // xor rdx, rdx (expected val = 0)
    0x48, 0x31, 0xd2,
    // mov rax, 202 (SYS_FUTEX)
    0x48, 0xc7, 0xc0, 0xca, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // (returns 0 on wake, or -EAGAIN if value changed — either way continue)

    // Print "Futex OK\n"
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x78] ("Futex OK\n" at 0xef, RIP after = 0x77)
    0x48, 0x8d, 0x35, 0x78, 0x00, 0x00, 0x00,
    // mov rdx, 9
    0x48, 0xc7, 0xc2, 0x09, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,

    // exit(0)
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // jmp $ (fallback)
    0xeb, 0xfe,

    // === CHILD path (offset 0x8e) ===
    // Print "Thread OK\n"
    // mov rax, 1 (SYS_WRITE)
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1 (stdout)
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+0x42] ("Thread OK\n" at 0xe5, RIP after = 0xa3)
    0x48, 0x8d, 0x35, 0x42, 0x00, 0x00, 0x00,
    // mov rdx, 10
    0x48, 0xc7, 0xc2, 0x0a, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,

    // Store 1 to futex word: mov dword [r12+0x2FF0], 1
    0x41, 0xc7, 0x84, 0x24, 0xf0, 0x2f, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,

    // futex_wake(&futex_word, FUTEX_WAKE=1, count=1)
    // lea rdi, [r12+0x2FF0]
    0x49, 0x8d, 0xbc, 0x24, 0xf0, 0x2f, 0x00, 0x00,
    // mov rsi, 1 (FUTEX_WAKE)
    0x48, 0xc7, 0xc6, 0x01, 0x00, 0x00, 0x00,
    // mov rdx, 1 (count)
    0x48, 0xc7, 0xc2, 0x01, 0x00, 0x00, 0x00,
    // mov rax, 202 (SYS_FUTEX)
    0x48, 0xc7, 0xc0, 0xca, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,

    // exit(0)
    // mov rax, 60 (SYS_EXIT)
    0x48, 0xc7, 0xc0, 0x3c, 0x00, 0x00, 0x00,
    // xor rdi, rdi
    0x48, 0x31, 0xff,
    // int 0x80
    0xcd, 0x80,
    // jmp $ (fallback)
    0xeb, 0xfe,

    // === Data ===
    // "Thread OK\n" (10 bytes, at offset 0xe5)
    'T', 'h', 'r', 'e', 'a', 'd', ' ', 'O', 'K', '\n',
    // "Futex OK\n" (9 bytes, at offset 0xef)
    'F', 'u', 't', 'e', 'x', ' ', 'O', 'K', '\n',
};
