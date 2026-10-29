    .text
    .align  4
    .globl  elf_switch_to_guest
    .type   elf_switch_to_guest,@function
// long elf_switch_to_guest(void *entry /*x0*/, void *guest_sp /*x1*/)
//
// guest_sp points at the guest's argc (process-start stack layout); the
// guest is entered with that sp and an LR pointing back to `0:`.
//
// The host sp/lr are saved in the process-global `elf_host_ctx` slot
// instead of callee-saved registers or the guest stack.  (Per-thread TLS
// slots were tried, but the OHOS toolchain lowers `__thread` through
// emulated TLS / __emutls_get_address, which must not run inside the switch
// and clobbers caller-saved registers.)  In-process guest runs are
// serialized with g_inproc_lock; fork-based child runs use per-process
// copies and are unaffected.
elf_switch_to_guest:
    adrp x2, elf_host_ctx
    add  x2, x2, :lo12:elf_host_ctx
    mov  x3, sp
    mov  x4, x30
    str  x3, [x2]
    str  x4, [x2, #8]
    mov  sp, x1
    adr  x30, 0f
    br   x0
0:  /* guest executed `ret`: restore host context from the global slot. */
    adrp x2, elf_host_ctx
    add  x2, x2, :lo12:elf_host_ctx
    ldr  x3, [x2]
    ldr  x4, [x2, #8]
    mov  sp, x3
    mov  x30, x4
    mov  x0, #0
    ret
    .size elf_switch_to_guest, .-elf_switch_to_guest
    .section .note.GNU-stack,"",@progbits
