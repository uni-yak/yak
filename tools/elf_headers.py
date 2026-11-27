#!/usr/bin/env python3
"""校验正式链接入口交付的 x86-64 ELF 对象或可执行文件。"""

import argparse
from pathlib import Path
import struct
import sys


HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
PROGRAM = struct.Struct("<IIQQQQQQ")


def validate(path: Path, executable: bool) -> None:
    with path.open("rb") as stream:
        size = path.stat().st_size
        ident, kind, machine, version, entry, phoff, shoff, _, ehsize, phsize, phnum, shsize, shnum, _ = (
            HEADER.unpack(stream.read(HEADER.size))
        )
        if (ident[:7], kind, machine, version, ehsize) != (b"\x7fELF\x02\x01\x01", 2 if executable else 1, 62, 1, HEADER.size):
            raise ValueError("ELF64 类别、文件类型或机器类型不匹配")
        if shsize != 64 or shnum == 0 or not HEADER.size <= shoff <= size - shsize * shnum:
            raise ValueError("ELF 节表越界")
        if not executable:
            if entry or phoff or phnum:
                raise ValueError("可重定位对象含入口或程序头")
            return
        if not entry or phsize != PROGRAM.size or not phnum or not HEADER.size <= phoff <= size - phsize * phnum:
            raise ValueError("ELF 可执行入口或程序头无效")
        stream.seek(phoff)
        has_entry = False
        for _ in range(phnum):
            program, flags, offset, start, _, file_bytes, memory_bytes, _ = PROGRAM.unpack(stream.read(phsize))
            if program == 3:
                raise ValueError("静态 ELF 含解释器入口")
            if program == 1:
                if offset > size or file_bytes > size - offset or file_bytes > memory_bytes:
                    raise ValueError("ELF 加载段越界")
                has_entry |= bool(flags & 1 and start <= entry < start + file_bytes)
        if not has_entry:
            raise ValueError("ELF 入口不在可执行加载段内")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("object", "executable"))
    parser.add_argument("path", type=Path, nargs="+")
    args = parser.parse_args()
    for path in args.path:
        try:
            validate(path, args.kind == "executable")
        except (OSError, ValueError, struct.error) as error:
            print(f"E8018 {path.name}: {error}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
