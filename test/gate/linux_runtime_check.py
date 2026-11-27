import os
from pathlib import Path
import selectors
import signal
import struct
import subprocess
import sys


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def executable(binary):
    # 脱离链接器输出解析头部，确认检查的确落在静态 Linux ELF 上。
    data = binary.read_bytes()
    ident, kind, machine, version, entry, phoff, _, _, ehsize, phsize, phnum, *_ = struct.unpack_from(
        '<16sHHIQQQIHHHHHH', data
    )
    require((ident[:7], kind, machine, version, ehsize, phsize) == (b'\x7fELF\x02\x01\x01', 2, 62, 1, 64, 56),
            f'{binary.name}：不是 ELF64 x86-64 可执行文件')
    require(phnum > 0 and phoff >= ehsize and phoff + phsize * phnum <= len(data), '程序头越界')
    records = [struct.unpack_from('<IIQQQQQQ', data, phoff + phsize * i) for i in range(phnum)]
    require(all(p[0] not in (2, 3) for p in records), '静态可执行文件含动态节或解释器')
    require([p[1] for p in records if p[0] == 0x6474E551] == [6], '栈缺少不可执行声明')
    require(any(t == 1 and flags & 1 and addr <= entry < addr + size
                for t, flags, _, addr, _, size, _, _ in records), '入口不在可执行文件映射内')


def expected(result, label, code, stdout=b'', stderr=b''):
    require((result.returncode, result.stdout, result.stderr) == (code, stdout, stderr),
            f'{label}：退出 {result.returncode}，标准输出 {(result.stdout or b"")[:80]!r}，'
            f'标准错误 {(result.stderr or b"")[:160]!r}')
    print(f'{label}：退出 {code}，标准输出和标准错误逐字节匹配')


def native_run(binary, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE):
    return subprocess.run([str(binary)], stdin=stdin, stdout=stdout, stderr=stderr, timeout=10, check=False)


def interactive(binary):
    with subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as proc:
        try:
            proc.stdin.write(b'Z')
            proc.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                require(bool(selector.select(10)), '保持输入端打开时没有收到短读回显')
                require(os.read(proc.stdout.fileno(), 1) == b'Z', '短读回显错误')
            stdout, stderr = proc.communicate(timeout=10)
            expected(subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr),
                     '开放管道短读、EOF、分配与释放、寄存器及栈', 0)
        finally:
            if proc.poll() is None:
                proc.kill()


def negative(binaries):
    unreadable = os.open(os.devnull, os.O_WRONLY)
    unwritable = os.open(os.devnull, os.O_RDONLY)
    try:
        expected(native_run(binaries[1], stdin=unreadable), '无效输入描述符', 70, stderr=b'yak: read failed\n')
        expected(native_run(binaries[2], stdout=unwritable), '无效输出描述符', 70, None, b'yak: write failed\n')
        expected(native_run(binaries[5], stdin=unreadable, stdout=unwritable), '可返回失败的服务入口与空切片', 0, None)
    finally:
        os.close(unreadable)
        os.close(unwritable)
    mask = signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGPIPE})
    pipe_read, pipe_write = os.pipe()
    os.close(pipe_read)
    try:
        expected(native_run(binaries[2], stdout=pipe_write), '断管映射为写入陷阱而非信号退出', 70, None,
                 b'yak: write failed\n')
        expected(native_run(binaries[3], stderr=pipe_write), '诊断断管仍保留陷阱退出码', 70, stderr=None)
    finally:
        os.close(pipe_write)
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
    expected(native_run(binaries[3]), '断言失败', 70, stderr=b'yak: assertion failed\n')
    expected(native_run(binaries[4]), '显式退出的 u8 值', 255)
    expected(native_run(binaries[7]), '清理后终止入口', 70)


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == '--syscall-boundary':
            binary = Path(sys.argv[2]).resolve()
            executable(binary)
            response = native_run(binary)
            if (response.returncode, response.stdout, response.stderr) == (92, b'', b''):
                print('E8016 syscall 易失寄存器泄漏')
                return 1
            expected(response, 'syscall 桥接边界', 0)
            return 0
        if len(sys.argv) != 2:
            raise ValueError('需要包含 8 份观察器的目录')
        root = Path(sys.argv[1]).resolve()
        binaries = [root / f'check-{i}' for i in range(8)]
        for binary in binaries:
            executable(binary)
        print('8 份静态 ELF64 观察器：入口、程序头和不可执行栈有效')
        interactive(binaries[0])
        negative(binaries)
        expected(native_run(binaries[6]), '真实管道完整写入 262145 字节', 0, b'M' * 262145)
    except (OSError, ValueError, struct.error, subprocess.TimeoutExpired) as exc:
        print(f'Linux 运行时断言失败：{exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
