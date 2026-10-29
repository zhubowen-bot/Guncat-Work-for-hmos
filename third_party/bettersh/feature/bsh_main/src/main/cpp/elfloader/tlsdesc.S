    .text
    .align  4
    .globl  bsh_tlsdesc_entry
    .type   bsh_tlsdesc_entry,@function
// uintptr_t bsh_tlsdesc_entry(void *desc /*x0*/)
//
// AArch64 TLSDESC 的 resolver 入口。**它不是普通 C 函数**：TLSDESC 的约定是
// "除 x0（返回值）外，所有寄存器都不许改" —— 编译器会把线程指针缓存在一个**临时**
// 寄存器里跨这次调用继续用，实测（@napi-rs/uuid-linux-arm64-musl）：
//     12284: mrs  x11, TPIDR_EL0     ; 缓存 TP
//     12298: blr  x1                 ; 调 resolver
//     1229c: str  x8, [x11, x0]      ; 还在用那个 x11
// 而 C 体要调 pthread_getspecific / calloc / fprintf，按 AAPCS64 会糊掉
// x1..x18 与 v0-v7/v16-v31，于是下一次访问就用被污染的基址、直接 SIGSEGV
// （崩溃现场的 addr 恰好等于 resolver 的返回值 —— x11 已经是 0 了）。
// glibc 的 __tlsdesc_dynamic 也是这个道理：进函数先把 x1..x4 存起来再调
// __tls_get_addr。
//
// 所以外壳只做一件事：存 → 调 C 体 → 原样恢复；**x0 是返回值，不恢复**。
// x19..x28 不用存（C 约定里它们是 callee-saved，C 体自己会保）。
// 栈帧 352 字节 = 10 对 x（160B）+ 12 对 q（192B），16 字节对齐。
// C 体 bsh_tlsdesc_resolver_c 定义在 elf_dl.cpp（同一个 .so）。
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
