# Linux x86-64 原生入口及登记的外部服务，不依赖 C 运行时。
.equ .Lio_limit, 0x7ffff000
.equ .Ltrap_status, 70

# 内核会改写 rcx 和 r11；桥接返回时保留二者。
.macro kernel_call
    pushq %rcx
    pushq %r11
    syscall
    popq %r11
    popq %rcx
.endm

.text
.globl _start
.type _start,@function
_start:
    xorl %ebp, %ebp
    andq $-16, %rsp
    # 进程不开放信号服务；屏蔽 SIGPIPE，让断管经写入失败路径处理。
    xorl %edi, %edi
    leaq .Lblocked_signals(%rip), %rsi
    xorl %edx, %edx
    movl $8, %r10d
    movl $14, %eax
    kernel_call
    testq %rax, %rax
    jne .Lstartup_failed
    call yak$entry
    # Yak 帧先完成清理，再经 r11 把异常状态交还进程入口。
    movl %r11d, %edi
    testl %edi, %edi
    je yak_rt_exit
    cmpl $1, %edi
    je .Lentry_arithmetic
    subl $256, %edi
    cmpl $255, %edi
    jbe yak_rt_exit
    jmp yak_rt_abort_service
.Lentry_arithmetic:
    int3
    jmp yak_rt_abort_service
.Lstartup_failed:
    leaq .Lstartup_message(%rip), %rsi
    movl $.Lstartup_length, %edx
    jmp .Lreport_and_trap
.size _start, .-_start

.globl yak_rt_exit
.type yak_rt_exit,@function
yak_rt_exit:
    movzbl %dil, %edi
    movl $231, %eax
    kernel_call
    # 正常内核不返回；若退出被拦截，绝不能续跑。
    ud2
.size yak_rt_exit, .-yak_rt_exit

# 尝试入口不做最终终止，留给编译器生成的清理边；全一表示服务失败。
.globl yak_rt_try_read, yak_rt_stdio_read
.type yak_rt_try_read,@function
.type yak_rt_stdio_read,@function
yak_rt_stdio_read:
yak_rt_try_read:
    testq %rsi, %rsi
    je .Lservice_ok
    movq %rsi, %rdx
    movq %rdi, %rsi
    xorl %edi, %edi
    cmpq $.Lio_limit, %rdx
    jbe .Lread_retry
    movl $.Lio_limit, %edx
.Lread_retry:
    xorl %eax, %eax
    kernel_call
    cmpq $-4, %rax
    je .Lread_retry
    testq %rax, %rax
    js .Lservice_failed
    # 短读正常返回，不能等缓冲填满或对端关闭。
    ret
.size yak_rt_try_read, .-yak_rt_try_read
.size yak_rt_stdio_read, .-yak_rt_stdio_read

.globl yak_rt_try_write, yak_rt_stdio_write
.type yak_rt_try_write,@function
.type yak_rt_stdio_write,@function
yak_rt_stdio_write:
yak_rt_try_write:
    testq %rsi, %rsi
    je .Lservice_ok
    movq %rdi, %r8
    movq %rsi, %r9
.Lwrite_next:
    movl $1, %edi
    movq %r8, %rsi
    movq %r9, %rdx
    cmpq $.Lio_limit, %rdx
    jbe .Lwrite_once
    movl $.Lio_limit, %edx
.Lwrite_once:
    movl $1, %eax
    kernel_call
    cmpq $-4, %rax
    je .Lwrite_once
    testq %rax, %rax
    jle .Lservice_failed
    addq %rax, %r8
    subq %rax, %r9
    jne .Lwrite_next
    jmp .Lservice_ok
.size yak_rt_try_write, .-yak_rt_try_write
.size yak_rt_stdio_write, .-yak_rt_stdio_write

.globl yak_rt_try_assert
.type yak_rt_try_assert,@function
yak_rt_try_assert:
    testb %dil, %dil
    je .Lservice_failed
.Lservice_ok:
    xorl %eax, %eax
    ret
.Lservice_failed:
    movq $-1, %rax
    ret
.size yak_rt_try_assert, .-yak_rt_try_assert

# 直接服务入口把失败映射成进程陷阱；未来的清理调用点使用尝试入口。
.macro direct_service name, attempt, message, length
.globl \name
.type \name,@function
\name:
    subq $8, %rsp
    call \attempt
    addq $8, %rsp
    cmpq $-1, %rax
    jne 1f
    leaq \message(%rip), %rsi
    movl $\length, %edx
    jmp .Lreport_and_trap
1:
    ret
.size \name, .-\name
.endm

direct_service yak_rt_read, yak_rt_try_read, .Lread_message, .Lread_length
direct_service yak_rt_write, yak_rt_try_write, .Lwrite_message, .Lwrite_length
direct_service yak_rt_assert, yak_rt_try_assert, .Lassert_message, .Lassert_length

# 编译器生成的检查调用报告诊断后返回失败标记，供各层 Yak 帧执行清理。
.macro checked_service name, attempt, message, length
.globl \name
.type \name,@function
\name:
    subq $8, %rsp
    call \attempt
    addq $8, %rsp
    cmpq $-1, %rax
    jne 1f
    leaq \message(%rip), %rsi
    movl $\length, %edx
    jmp .Lreport_and_return
1:
    ret
.size \name, .-\name
.endm

checked_service yak_rt_checked_read, yak_rt_try_read, .Lread_message, .Lread_length
checked_service yak_rt_checked_write, yak_rt_try_write, .Lwrite_message, .Lwrite_length
checked_service yak_rt_checked_assert, yak_rt_try_assert, .Lassert_message, .Lassert_length

.Lreport_and_return:
    movl $2, %edi
1:
    movl $1, %eax
    kernel_call
    cmpq $-4, %rax
    je 1b
    movq $-1, %rax
    ret

.Lreport_and_trap:
    # 只尽力写标准错误；诊断写失败不能掩盖原始陷阱。
    movl $2, %edi
1:
    movl $1, %eax
    kernel_call
    cmpq $-4, %rax
    je 1b
.globl yak_rt_abort_service
.type yak_rt_abort_service,@function
yak_rt_abort_service:
    movl $.Ltrap_status, %edi
    jmp yak_rt_exit
.size yak_rt_abort_service, .-yak_rt_abort_service

.globl yak_rt_alloc
.type yak_rt_alloc,@function
yak_rt_alloc:
    testq %rdi, %rdi
    je .Lalloc_failed
    movq %rdi, %rsi
    xorl %edi, %edi
    movl $3, %edx
    movl $0x22, %r10d
    movq $-1, %r8
    xorl %r9d, %r9d
    movl $9, %eax
    kernel_call
    cmpq $-4095, %rax
    jae .Lalloc_failed
    ret
.Lalloc_failed:
    # 按分配服务契约归一为空值，由调用方构造 AllocError。
    xorl %eax, %eax
    ret
.size yak_rt_alloc, .-yak_rt_alloc

.globl yak_rt_free
.type yak_rt_free,@function
yak_rt_free:
    testq %rdi, %rdi
    je .Lfree_done
    testq %rsi, %rsi
    je .Lfree_done
    # 内部调用携带原分配的指针和值域内字节数，释放无失败返回。
    movl $11, %eax
    kernel_call
.Lfree_done:
    ret
.size yak_rt_free, .-yak_rt_free

.section .rodata
.p2align 3
.Lblocked_signals:
    .quad 1 << (13 - 1)
.Lstartup_message:
    .ascii "yak: runtime startup failed\n"
.equ .Lstartup_length, .-.Lstartup_message
.Lread_message:
    .ascii "yak: read failed\n"
.equ .Lread_length, .-.Lread_message
.Lwrite_message:
    .ascii "yak: write failed\n"
.equ .Lwrite_length, .-.Lwrite_message
.Lassert_message:
    .ascii "yak: assertion failed\n"
.equ .Lassert_length, .-.Lassert_message
.section .note.GNU-stack,"",@progbits
