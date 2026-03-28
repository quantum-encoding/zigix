/* RISC-V 64-bit Linker Script for Zigix
 *
 * QEMU virt machine: OpenSBI loads kernel at 0x80200000.
 * OpenSBI occupies 0x80000000-0x801FFFFF (2 MB).
 */

ENTRY(_start)

SECTIONS
{
    . = 0x80200000;

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
