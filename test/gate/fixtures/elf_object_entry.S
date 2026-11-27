# 由系统汇编器构造的独立 Linux 入口；不代替 Yak 后端。
.text
.globl _start
.type _start,@function
_start:
    call yak$entry
    cmpl $42, %eax
    jne .Lbad
    movq elf_probe_abs(%rip), %rax
    cmpb $11, (%rax)
    jne .Lbad
    leaq elf_probe_external(%rip), %rax
    cmpl %eax, elf_probe_small(%rip)
    jne .Lbad
    xorl %edi, %edi
    jmp .Lexit
.Lbad:
    movl $1, %edi
.Lexit:
    movl $231, %eax
    syscall
.size _start, .-_start

.globl elf_probe_external
.type elf_probe_external,@function
elf_probe_external:
    movl $35, %eax
    ret
.size elf_probe_external, .-elf_probe_external
.section .note.GNU-stack,"",@progbits
