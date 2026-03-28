OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

PHDRS
{
    text    PT_LOAD FLAGS((1 << 0) | (1 << 2)) ;  /* R + X */
    rodata  PT_LOAD FLAGS((1 << 2)) ;              /* R     */
    data    PT_LOAD FLAGS((1 << 1) | (1 << 2)) ;   /* R + W */
}

SECTIONS
{
    /* Higher half kernel base address */
    . = 0xFFFFFFFF80000000;

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(4K);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(4K);

    .data : {
        *(.data .data.*)
        /* Limine request structs — must be in a writable, loadable segment */
        *(.limine_reqs)
    } :data

    . = ALIGN(4K);

    .bss : {
        __bss_start = .;
        *(COMMON)
        *(.bss .bss.*)
        __bss_end = .;
    } :data

    __kernel_end = .;

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
