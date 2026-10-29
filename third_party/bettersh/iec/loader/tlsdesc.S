    .text
    .align  4
    .globl  bsh_tlsdesc_entry
    .type   bsh_tlsdesc_entry,@function
// uintptr_t bsh_tlsdesc_entry(void *desc /* x0 */)
//
// Entry point for an AArch64 TLSDESC resolver. This is not an ordinary C
// function: the TLSDESC contract says that only x0 (the return value) may
// change. The compiler may keep the thread pointer in a temporary register
// across the call. Measured in @napi-rs/uuid-linux-arm64-musl:
//
//     12284: mrs  x11, TPIDR_EL0     ; cache TP in x11
//     12298: blr  x1                 ; call the resolver
//     1229c: str  x8, [x11, x0]      ; still using x11
//
// The C body calls pthread_getspecific, calloc and fprintf, which under
// AAPCS64 may clobber x1..x18 and v0-v7/v16-v31. Without this shell the next
// access uses a contaminated base and faults (the fault address is exactly
// the resolver's return value, because x11 has become zero).
//
// The shell saves, calls the C body in elf_dl.cpp, and restores everything
// except x0. x19..x28 are callee-saved and the C body preserves them itself.
// The 352-byte frame holds 10 pairs of x registers (160 bytes) and 12 pairs of
// q registers (192 bytes), and stays 16-byte aligned.
bsh_tlsdesc_entry:
    sub  sp, sp, #352
    stp  x1,  x2,  [sp, #0]
    stp  x3,  x4,  [sp, #16]
    stp  x5,  x6,  [sp, #32]
    stp  x7,  x8,  [sp, #48]
    stp  x9,  x10, [sp, #64]
    stp  x11, x12, [sp, #80]
    stp  x13, x14, [sp, #96]
    stp  x15, x16, [sp, #112]
    stp  x17, x18, [sp, #128]
    stp  x29, x30, [sp, #144]
    stp  q0,  q1,  [sp, #160]
    stp  q2,  q3,  [sp, #176]
    stp  q4,  q5,  [sp, #192]
    stp  q6,  q7,  [sp, #208]
    stp  q16, q17, [sp, #224]
    stp  q18, q19, [sp, #240]
    stp  q20, q21, [sp, #256]
    stp  q22, q23, [sp, #272]
    stp  q24, q25, [sp, #288]
    stp  q26, q27, [sp, #304]
    stp  q28, q29, [sp, #320]
    stp  q30, q31, [sp, #336]
    bl   bsh_tlsdesc_resolver_c
    ldp  q30, q31, [sp, #336]
    ldp  q28, q29, [sp, #320]
    ldp  q26, q27, [sp, #304]
    ldp  q24, q25, [sp, #288]
    ldp  q22, q23, [sp, #272]
    ldp  q20, q21, [sp, #256]
    ldp  q18, q19, [sp, #240]
    ldp  q16, q17, [sp, #224]
    ldp  q6,  q7,  [sp, #208]
    ldp  q4,  q5,  [sp, #192]
    ldp  q2,  q3,  [sp, #176]
    ldp  q0,  q1,  [sp, #160]
    ldp  x29, x30, [sp, #144]
    ldp  x17, x18, [sp, #128]
    ldp  x15, x16, [sp, #112]
    ldp  x13, x14, [sp, #96]
    ldp  x11, x12, [sp, #80]
    ldp  x9,  x10, [sp, #64]
    ldp  x7,  x8,  [sp, #48]
    ldp  x5,  x6,  [sp, #32]
    ldp  x3,  x4,  [sp, #16]
    ldp  x1,  x2,  [sp, #0]
    add  sp, sp, #352
    ret
    .size bsh_tlsdesc_entry, .-bsh_tlsdesc_entry
    .section .note.GNU-stack,"",@progbits
