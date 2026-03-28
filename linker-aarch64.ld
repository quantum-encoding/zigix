/* ARM64 Linker Script for Zigix
 *
 * Load address is configurable via -Dload_addr= in build.zig:
 *   0x40080000 — QEMU virt (default)
 *   0x80000    — Raspberry Pi 4/5 (kernel8.img)
 *   0x40000000 — U-Boot standard load address
 *
 * Override: zig build -Darch=aarch64 -Dload_addr=0x80000
 */

ENTRY(_start)

/* Default load address — overridable via --defsym __load_addr=0xNNNN */
PROVIDE(__load_addr = 0x40080000);

SECTIONS
{
    . = __load_addr;

    .text : {
        *(.text._start)
        *(.text .text.*)
    }

    .rodata : ALIGN(4K) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4K) {
        *(.data .data.*)
    }

    .bss : ALIGN(4K) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    . = ALIGN(16);

    /* 64KB kernel stack */
    . += 64K;
    __stack_top = .;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
