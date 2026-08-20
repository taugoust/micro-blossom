.syntax unified
.cpu cortex-r5
.arm

.section .vectors, "ax", %progbits
.align 5
.global _start
.type _start, %function
_start:
    b reset_handler
    b undefined_handler
    b svc_handler
    b prefetch_abort_handler
    b data_abort_handler
    b reserved_handler
    b irq_handler
    b fiq_handler
.size _start, . - _start

.section .text.startup, "ax", %progbits
.align 4
.global reset_handler
.type reset_handler, %function
reset_handler:
    cpsid if
    setend le

    /* Delayed handoff must release a cold, cache-disabled R5. */
    dsb sy
    mrc p15, 0, r0, c1, c0, 0
    bic r0, r0, #0x0001
    bic r0, r0, #0x0004
    bic r0, r0, #0x0800
    bic r0, r0, #0x1000
    bic r0, r0, #0x2000
    bic r0, r0, #0x02000000
    bic r0, r0, #0x40000000
    mcr p15, 0, r0, c1, c0, 0
    mov r0, #0
    mcr p15, 0, r0, c12, c0, 0
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0
    mcr p15, 0, r0, c7, c5, 6
    dsb sy
    isb sy

    /* Initialize all BTCM words before using ECC-protected stacks or status. */
    ldr r0, =0x00020000
    ldr r1, =0x00030000
    mov r2, #0
0:
    str r2, [r0], #4
    cmp r0, r1
    blo 0b
    dsb sy

    cps #0x17
    ldr sp, =__abt_stack_top
    cps #0x1b
    ldr sp, =__und_stack_top
    cps #0x12
    ldr sp, =__irq_stack_top
    cps #0x11
    ldr sp, =__fiq_stack_top
    cps #0x13
    ldr sp, =__svc_stack_top

    ldr r0, =__bss_start
    ldr r1, =__bss_end
    mov r2, #0
1:
    cmp r0, r1
    strlo r2, [r0], #4
    blo 1b

    bl r5_main
    b r5_internal_trap
.size reset_handler, . - reset_handler

.type undefined_handler, %function
undefined_handler:
    mov r0, #1
    mov r1, #0
    mov r2, #0
    b r5_exception_trap

.type svc_handler, %function
svc_handler:
    mov r0, #2
    mov r1, #0
    mov r2, #0
    b r5_exception_trap

.type prefetch_abort_handler, %function
prefetch_abort_handler:
    mov r0, #3
    mrc p15, 0, r1, c6, c0, 2
    mrc p15, 0, r2, c5, c0, 1
    b r5_exception_trap

.type data_abort_handler, %function
data_abort_handler:
    mov r0, #4
    mrc p15, 0, r1, c6, c0, 0
    mrc p15, 0, r2, c5, c0, 0
    b r5_exception_trap

.type reserved_handler, %function
reserved_handler:
    mov r0, #5
    mov r1, #0
    mov r2, #0
    b r5_exception_trap

.type irq_handler, %function
irq_handler:
    mov r0, #6
    mov r1, #0
    mov r2, #0
    b r5_exception_trap

.type fiq_handler, %function
fiq_handler:
    mov r0, #7
    mov r1, #0
    mov r2, #0
    b r5_exception_trap
