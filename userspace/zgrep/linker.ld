OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS((1 << 0) | (1 << 2)) ;  /* R + X */
    data PT_LOAD FLAGS((1 << 1) | (1 << 2)) ;  /* R + W */
}

SECTIONS
{
    . = 0x400000;

    .text : { *(.text .text.*) } :text
    .rodata : { *(.rodata .rodata.*) } :text

    . = ALIGN(0x1000);

    .data : { *(.data .data.*) } :data
    .bss : { *(COMMON) *(.bss .bss.*) } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
