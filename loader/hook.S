#if defined(__aarch64__)
// Sentinel dispatcher for BetterDisplay 3.5.6's licence comparison helper.
//
// FUN_10043436c is a Swift string comparison helper with 385 call sites; the
// licence decision is one of them.  The operands observed in x2 for the licence
// checks of build 40870 are the four constants below; 0x3000000000 is the one
// that carries the decision.
//
// The dispatcher answers only those comparisons and forwards every other call
// to a trampoline that replays the overwritten instruction and resumes the
// original function at +4.
    .text
    .p2align 2
    .globl _bd_cmp_dispatch
_bd_cmp_dispatch:
    movz    x16, #0x70eb
    movk    x16, #0x0d13, lsl #16
    movk    x16, #0x88f8, lsl #32
    movk    x16, #0xb41e, lsl #48
    cmp     x2, x16
    b.eq    Lone

    movz    x16, #0x5a23
    movk    x16, #0x004f, lsl #16
    movk    x16, #0xac02, lsl #32
    movk    x16, #0xbbc3, lsl #48
    cmp     x2, x16
    b.eq    Lone

    movz    x16, #0xe5b0
    movk    x16, #0x6576, lsl #16
    movk    x16, #0xc876, lsl #32
    movk    x16, #0xc80b, lsl #48
    cmp     x2, x16
    b.eq    Lone

    mov     x16, #0x3000000000
    cmp     x2, x16
    b.eq    Lone

    // Not a licence comparison: run the original instruction from the trampoline.
    adrp    x16, _bd_tramp_ptr@PAGE
    ldr     x16, [x16, _bd_tramp_ptr@PAGEOFF]
    br      x16

Lone:
    mov     w0, #1
    ret

#else
// x86_64 slice: unused (the app runs arm64 on Apple silicon); keeps the
// universal build linkable.
    .text
    .globl _bd_cmp_dispatch
_bd_cmp_dispatch:
    ret
#endif
