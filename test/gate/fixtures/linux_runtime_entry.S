# 独立的 System V 观察器，不使用 Yak 后端或 C 运行时。
.macro invoke service
    movl $0x12345678, %ecx
    movl $0x24681357, %r11d
    call \service
    cmpq $0x12345678, %rcx
    jne .Lbad_syscall
    cmpq $0x24681357, %r11
    jne .Lbad_syscall
    cmpq $71, %rbx
    jne .Lbad
    cmpq $72, %rbp
    jne .Lbad
    cmpq $73, %r12
    jne .Lbad
    cmpq $74, %r13
    jne .Lbad
    cmpq $75, %r14
    jne .Lbad
    cmpq $76, %r15
    jne .Lbad
    cmpq .Lsaved_stack(%rip), %rsp
    jne .Lbad
.endm

.text
.globl yak$entry
.type yak$entry,@function
yak$entry:
    movq %rsp, %rax
    andl $15, %eax
    cmpl $8, %eax
    jne .Lbad
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $8, %rsp
    movq %rsp, .Lsaved_stack(%rip)
    movl $71, %ebx
    movl $72, %ebp
    movl $73, %r12d
    movl $74, %r13d
    movl $75, %r14d
    movl $76, %r15d

.if test_mode == 0
    # 父进程等到回显才关写端，因此读满缓冲的实现会失败。
    movb $93, .Lbuffer+1(%rip)
    leaq .Lbuffer(%rip), %rdi
    movl $32, %esi
    invoke yak_rt_read
    cmpl $1, %eax
    jne .Lbad
    cmpb $90, .Lbuffer(%rip)
    jne .Lbad
    cmpb $93, .Lbuffer+1(%rip)
    jne .Lbad
    leaq .Lbuffer(%rip), %rdi
    movl $1, %esi
    invoke yak_rt_write
    leaq .Lbuffer(%rip), %rdi
    movl $32, %esi
    invoke yak_rt_read
    testl %eax, %eax
    jne .Lbad
    movl $1, %edi
    invoke yak_rt_assert

    # 分配跨三页，覆盖末字节；释放后首末页均不能再查询驻留状态。
    movl $8193, %edi
    invoke yak_rt_alloc
    testq %rax, %rax
    je .Lbad
    cmpb $0, (%rax)
    jne .Lbad
    cmpb $0, 8192(%rax)
    jne .Lbad
    movb $31, (%rax)
    movb $47, 8192(%rax)
    cmpb $31, (%rax)
    jne .Lbad
    cmpb $47, 8192(%rax)
    jne .Lbad
    movq %rax, .Lallocated(%rip)
    movq %rax, %rdi
    movl $8193, %esi
    invoke yak_rt_free
    movq .Lallocated(%rip), %rdi
    call .Lcheck_unmapped
    movq .Lallocated(%rip), %rdi
    addq $8192, %rdi
    call .Lcheck_unmapped
    xorl %edi, %edi
    invoke yak_rt_alloc
    testq %rax, %rax
    jne .Lbad
    movq $-1, %rdi
    invoke yak_rt_alloc
    testq %rax, %rax
    jne .Lbad
    xorl %edi, %edi
    xorl %esi, %esi
    invoke yak_rt_free
.elseif test_mode == 1
    leaq .Lbuffer(%rip), %rdi
    movl $1, %esi
    invoke yak_rt_read
    jmp .Lbad
.elseif test_mode == 2
    leaq .Lbuffer(%rip), %rdi
    movl $1, %esi
    invoke yak_rt_write
    jmp .Lbad
.elseif test_mode == 3
    xorl %edi, %edi
    invoke yak_rt_assert
    jmp .Lbad
.elseif test_mode == 4
    movl $0x123456ff, %edi
    invoke yak_rt_exit
    jmp .Lbad
.elseif test_mode == 5
    # 尝试入口失败后仍能执行清理；空切片不访问无效描述符。
    leaq .Lbuffer(%rip), %rdi
    movl $1, %esi
    invoke yak_rt_try_read
    cmpq $-1, %rax
    jne .Lbad
    leaq .Lbuffer(%rip), %rdi
    movl $1, %esi
    invoke yak_rt_try_write
    cmpq $-1, %rax
    jne .Lbad
    xorl %edi, %edi
    invoke yak_rt_try_assert
    cmpq $-1, %rax
    jne .Lbad
    movq $-1, %rdi
    xorl %esi, %esi
    invoke yak_rt_read
    testl %eax, %eax
    jne .Lbad
    movq $-1, %rdi
    xorl %esi, %esi
    invoke yak_rt_write
.elseif test_mode == 6
    leaq .Llarge(%rip), %rdi
    movl $.Llarge_size, %esi
    invoke yak_rt_write
.elseif test_mode == 7
    invoke yak_rt_abort_service
    jmp .Lbad
.elseif test_mode == 8
    movl $64, %edi
    invoke yak_rt_alloc
    testq %rax, %rax
    je .Lbad
    movq %rax, %rdi
    movl $64, %esi
    invoke yak_rt_free
.else
    .error "未登记的运行时观察器模式"
.endif

    # 正常 void 返回的 rax 不决定进程退出状态。
    movl $57, %eax
    xorl %r11d, %r11d
    addq $8, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret
.size yak$entry, .-yak$entry

.Lcheck_unmapped:
    movl $1, %esi
    leaq .Lbuffer(%rip), %rdx
    movl $27, %eax
    syscall
    cmpq $-12, %rax
    jne .Lbad
    ret

.Lbad:
    movl $91, %edi
    movl $231, %eax
    syscall
    ud2

.Lbad_syscall:
    movl $92, %edi
    movl $231, %eax
    syscall
    ud2

.bss
.p2align 3
.Lsaved_stack:
    .zero 8
.Lallocated:
    .zero 8
.Lbuffer:
    .zero 32
.if test_mode == 6
.section .rodata
.Llarge:
    .fill 262145, 1, 77
.equ .Llarge_size, .-.Llarge
.endif
.section .note.GNU-stack,"",@progbits
