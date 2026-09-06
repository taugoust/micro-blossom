OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)
ENTRY(_start)

MEMORY
{
    ATCM (rx) : ORIGIN = 0x00000000, LENGTH = 0x00010000
    BTCM (rw) : ORIGIN = 0x00020000, LENGTH = 0x00010000
}

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    __atcm_start = ORIGIN(ATCM);
    __atcm_limit = ORIGIN(ATCM) + LENGTH(ATCM);
    __btcm_start = ORIGIN(BTCM);
    __btcm_limit = ORIGIN(BTCM) + LENGTH(BTCM);

    .vectors ORIGIN(ATCM) :
    {
        __vectors_start = .;
        KEEP(*(.vectors))
        __vectors_end = .;
    } > ATCM :text

    .text :
    {
        *(.text.startup)
        *(.text .text.*)
    } > ATCM :text

    .rodata :
    {
        *(.rodata .rodata.*)
    } > ATCM :text

    .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } > ATCM :text
    .ARM.exidx : { *(.ARM.exidx* .gnu.linkonce.armexidx.*) } > ATCM :text
    __atcm_end = .;

    .fixture_status ORIGIN(BTCM) (NOLOAD) : ALIGN(64)
    {
        __fixture_status_start = .;
        KEEP(*(.fixture_status))
        __fixture_status_end = .;
    } > BTCM :data

    .data (NOLOAD) :
    {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    } > BTCM :data

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.bss .bss.* COMMON)
        __bss_end = ALIGN(4);
    } > BTCM :data

    __stack_floor = 0x0002c800;
    __svc_stack_top = 0x0002f800;
    __abt_stack_top = 0x0002fa00;
    __und_stack_top = 0x0002fc00;
    __irq_stack_top = 0x0002fe00;
    __fiq_stack_top = 0x00030000;

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
    }
}

ASSERT(__vectors_start == 0x00000000, "vectors must begin at ATCM base")
ASSERT((__vectors_end - __vectors_start) == 0x20, "vector table must be 32 bytes")
ASSERT(__atcm_start == 0x00000000, "ATCM origin changed")
ASSERT(__atcm_limit == 0x00010000, "ATCM limit changed")
ASSERT(__atcm_end <= __atcm_limit, "ATCM overflow")
ASSERT(__btcm_start == 0x00020000, "BTCM origin changed")
ASSERT(__btcm_limit == 0x00030000, "BTCM limit changed")
ASSERT(__fixture_status_start == __btcm_start, "status must begin at BTCM base")
ASSERT((__fixture_status_end - __fixture_status_start) == 0x40, "status must be 64 bytes")
ASSERT((__data_end - __data_start) == 0, "initialized writable data is forbidden")
ASSERT(__bss_end <= __stack_floor, "BTCM data overlaps stacks")
ASSERT((__svc_stack_top - __stack_floor) == 0x3000, "SVC stack must be 12288 bytes")
ASSERT((__abt_stack_top - __svc_stack_top) == 0x200, "ABT stack must be 512 bytes")
ASSERT((__und_stack_top - __abt_stack_top) == 0x200, "UND stack must be 512 bytes")
ASSERT((__irq_stack_top - __und_stack_top) == 0x200, "IRQ stack must be 512 bytes")
ASSERT((__fiq_stack_top - __irq_stack_top) == 0x200, "FIQ stack must be 512 bytes")
ASSERT(__fiq_stack_top == __btcm_limit, "reserved stacks must end at BTCM limit")
ASSERT((__svc_stack_top & 7) == 0, "SVC stack alignment")
ASSERT((__abt_stack_top & 7) == 0, "ABT stack alignment")
ASSERT((__und_stack_top & 7) == 0, "UND stack alignment")
ASSERT((__irq_stack_top & 7) == 0, "IRQ stack alignment")
ASSERT((__fiq_stack_top & 7) == 0, "FIQ stack alignment")
