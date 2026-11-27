# 分开核对生成函数入口和外部调用出口，不共享生成器的栈槽算法。
.text
.globl _start
.type _start,@function
_start:
    andq $-16, %rsp
    subq $16, %rsp
    movq %rsp, .Lstack(%rip)
    movl $71, %ebx
    movl $72, %ebp
    movl $73, %r12d
    movl $74, %r13d
    movl $75, %r14d
    movl $76, %r15d
    movl $11, %edi
    movl $22, %esi
    movl $33, %edx
    movl $44, %ecx
    movl $55, %r8d
    leaq .Lpayload(%rip), %r9
    movq $4, 0(%rsp)
    movq $77, 8(%rsp)
    call yak$abiprobe$f1
    movabsq $0x123456789abcdef0, %r10
    cmpq %r10, %rax
    jne .Lbad
    cmpq .Lstack(%rip), %rsp
    jne .Lbad
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
    cmpq $4, 0(%rsp)
    jne .Lbad
    cmpq $77, 8(%rsp)
    jne .Lbad
    addq $16, %rsp
    xorl %edi, %edi
    jmp .Lexit
.size _start, .-_start

.globl abi_probe_callee
.type abi_probe_callee,@function
abi_probe_callee:
    movq %rsp, %rax
    andl $15, %eax
    cmpl $8, %eax
    jne .Lbad_call
    cmpq $77, %rdi
    jne .Lbad_call
    cmpq $44, %rsi
    jne .Lbad_call
    cmpq $33, %rdx
    jne .Lbad_call
    cmpq $22, %rcx
    jne .Lbad_call
    cmpq $55, %r8
    jne .Lbad_call
    leaq .Lpayload(%rip), %rax
    cmpq %rax, %r9
    jne .Lbad_call
    cmpq $4, 8(%rsp)
    jne .Lbad_call
    cmpq $11, 16(%rsp)
    jne .Lbad_call
    movabsq $0x123456789abcdef0, %rax
    ret
.size abi_probe_callee, .-abi_probe_callee

.Lbad:
    movl $91, %edi
    jmp .Lexit
.Lbad_call:
    movl $92, %edi
.Lexit:
    movl $231, %eax
    syscall
    ud2

.section .rodata
.Lpayload:
    .ascii "Yak!"
.bss
.p2align 3
.Lstack:
    .zero 8
.section .note.GNU-stack,"",@progbits
