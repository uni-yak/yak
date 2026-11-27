    .text
    .globl abi_invoke
abi_invoke:
    # 保留 C 调用者的寄存器，并给被调函数独立的主目录。
    pushq %rbx
    pushq %rdi
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    pushq %rbp
    subq $40, %rsp
    movl $0x11, %ebx
    movl $0x22, %edi
    movl $0x33, %esi
    movl $0x44, %r12d
    movl $0x55, %r13d
    movl $0x66, %r14d
    movl $0x77, %r15d
    movl $0x88, %ebp
    call *%rcx
    cmpq $0x11, %rbx
    jne .Lregister
    cmpq $0x22, %rdi
    jne .Lregister
    cmpq $0x33, %rsi
    jne .Lregister
    cmpq $0x44, %r12
    jne .Lregister
    cmpq $0x55, %r13
    jne .Lregister
    cmpq $0x66, %r14
    jne .Lregister
    cmpq $0x77, %r15
    jne .Lregister
    cmpq $0x88, %rbp
    jne .Lregister
    movl %r11d, %eax
    jmp .Lrestore
.Lregister:
    movl $8008, %eax
.Lrestore:
    addq $40, %rsp
    popq %rbp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rsi
    popq %rdi
    popq %rbx
    ret

    .globl __wrap_yak_rt_try_assert
__wrap_yak_rt_try_assert:
    # 保存的帧指针在调用者帧顶；检查失败时从不碰主目录。
    incl abi_calls(%rip)
    leaq 8(%rsp), %r10
    testq $15, %r10
    jnz .Lalign
    cmpq %r10, %rbp
    jb .Lshadow
    movq %rbp, %r9
    subq %r10, %r9
    cmpq $32, %r9
    jb .Lshadow
    cmpb $1, %cl
    jne .Largument
    movq $0x11, 8(%rsp)
    movq $0x22, 16(%rsp)
    movq $0x33, 24(%rsp)
    movq $0x44, 32(%rsp)
    xorl %eax, %eax
    ret
.Lalign:
    movl $8006, abi_status(%rip)
    jmp .Lreturn
.Lshadow:
    movl $8007, abi_status(%rip)
    jmp .Lreturn
.Largument:
    movl $2, abi_status(%rip)
.Lreturn:
    movq $-1, %rax
    ret

    # 只有独立汇编夹具故意违反单条规则，不修改实际 Yak 对象。
    .macro frame_probe name, size, corrupt=0
    .globl \name
\name:
    pushq %rbp
    movq %rsp, %rbp
    subq $\size, %rsp
    movl $1, %ecx
    call __wrap_yak_rt_try_assert
    xorl %r11d, %r11d
    .if \corrupt
    movl $0x99, %ebx
    .endif
    leave
    ret
    .endm
    frame_probe abi_valid, 32
    frame_probe abi_misaligned, 40
    frame_probe abi_short_shadow, 16
    frame_probe abi_bad_register, 32, 1
