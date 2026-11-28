"""通过真实目标进程断言标准流；不以普通输出解释系统失败。"""
import os
from pathlib import Path
from queue import Empty, Queue
import subprocess
import sys
from threading import Thread


TIMEOUT = 15


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def expect(result, title, code, stdout=b''):
    got = (result.returncode, result.stdout, result.stderr)
    require(got == (code, stdout, b''), f'{title}：预期退出 {code}，实际 {got!r}')
    print(f'{title}：退出 {code}，输出符合预期', flush=True)


def run(binary, *, stdin=None, data=None, stdout=subprocess.PIPE):
    return subprocess.run([binary], stdin=stdin, input=data, stdout=stdout,
                          stderr=subprocess.PIPE, timeout=TIMEOUT, check=False)


def open_pipe(binary):
    # 一端保持打开；旧的填满缓冲区实现会在这一步超时。
    with subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, bufsize=0) as proc:
        received = Queue(maxsize=1)
        reader = Thread(target=lambda: received.put(proc.stdout.read(1)), daemon=True)
        try:
            proc.stdin.write(b'Z')
            reader.start()
            try:
                got = received.get(timeout=TIMEOUT)
            except Empty as exc:
                raise ValueError('输入管道保持打开时，短读没有返回') from exc
            require(got == b'Z', f'短读回显错误：{got!r}')
            out, error = proc.communicate(timeout=TIMEOUT)
            expect(subprocess.CompletedProcess(proc.args, proc.returncode, out, error), '开放管道短读', 0)
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=TIMEOUT)
            if reader.ident is not None:
                reader.join(timeout=TIMEOUT)


def main():
    if len(sys.argv) != 4:
        raise ValueError('用法：stdio_check.py echo emptyio lines')
    echo, empty, lines = (str(Path(path).resolve(strict=True)) for path in sys.argv[1:])
    data = bytes(range(256)) * 17
    expect(run(echo, data=data), '逐字节回显', 0, data)
    expect(run(echo, data=b''), '空输入 EOF', 0)
    open_pipe(echo)
    expect(run(lines, data=b''), '空输入计数', 0, b'0\n')
    expect(run(lines, data=b'no\r-lf\x00'), '无 LF 输入计数', 0, b'0\n')
    expect(run(lines, data=b'A\r\n\x00\nB' * 617 + b'C'), '跨缓冲且含二进制字节的 LF 计数', 0, b'1234\n')
    # 分别把管道的写端用作输入、读端用作输出；保留另一端来排除正常 EOF 或断管。
    fd_read, fd_write = os.pipe()
    with os.fdopen(fd_read, 'rb') as readable, os.fdopen(fd_write, 'wb') as writable:
        expect(run(echo, stdin=writable), '不可读的标准输入', 1)
        expect(run(echo, data=b'Z', stdout=readable), '不可写的标准输出', 2, None)
        expect(run(empty, stdin=writable, stdout=readable), '不可用句柄上的空切片', 0, None)
        expect(run(lines, stdin=writable), '读失败不输出计数', 1)
        expect(run(lines, data=b'Z\n', stdout=readable), '写计数失败', 2, None)
    fd_read, fd_write = os.pipe()
    os.close(fd_read)
    with os.fdopen(fd_write, 'wb') as broken:
        expect(run(echo, data=b'Z', stdout=broken), '写断管', 2, None)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        sys.exit(f'标准流专项失败：{exc}')
