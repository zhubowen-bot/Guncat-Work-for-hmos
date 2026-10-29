.text
    .align  16
    .globl  elf_switch_to_guest
    .type   elf_switch_to_guest,@function

// long elf_switch_to_guest(void *entry in rdi, void *guest_sp in rsi)
//
// Save the host rsp and return address in elf_host_ctx[2], switch to the
// guest stack, put a pseudo return address on it, and jump to entry.
// SysV ABI: rbx/rbp/r12-r15 are callee-saved and are preserved here.
elf_switch_to_guest:
    /* 保存 callee-saved + 返回地址 */
    push    %rbp
    mov     %rsp, %rbp
    push    %rbx
    push    %r12
    push    %r13
    push    %r14
    push    %r15

    /* 把宿主 rsp 存进 elf_host_ctx[0]，返回落点存进 elf_host_ctx[1] */
    lea     elf_host_ctx(%rip), %rax
    mov     %rsp, (%rax)
    lea     1f(%rip), %rcx
    mov     %rcx, 8(%rax)

    /* 切到 guest 栈 */
    mov     %rsi, %rsp

    /* Enter the guest with the process-start stack layout:
     *   (%rsp) = argc, above it argv/envp/auxv
     *   rdx    = fini callback (0 is fine for ld.so)
     * Do not push a pseudo return address here: it would move argc by 8
     * bytes and break the 16-byte alignment the dynamic linker relies on.
     * A normal guest exits; it never returns. The restore path below is
     * only reachable if a guest returns with the stack it was given. */
    xor     %rdx, %rdx
    jmp     *%rdi

1:  /* guest executed `ret`: restore the host stack from the global slot */
    lea     elf_host_ctx(%rip), %rax
    mov     (%rax),  %rsp
    /* 这里不需要跳到 elf_host_ctx[1]，因为我们已经回到宿主栈，
     * callee-saved 还在栈上。pop 回去然后 ret 到调用方即可。 */
    pop     %r15
    pop     %r14
    pop     %r13
    pop     %r12
    pop     %rbx
    pop     %rbp
    xor     %eax, %eax
    ret
    .size elf_switch_to_guest, .-elf_switch_to_guest
    .section .note.GNU-stack,"",@progbits