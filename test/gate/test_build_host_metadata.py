#!/usr/bin/env python3
"""核对 B-2：禁止将本次构建的路径和时间写入目标产物。"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import struct
import sys


class MetadataError(ValueError):
    """产物缺失、格式不符或带有已知宿主信息。"""


def host_path_spellings(path: Path) -> set[str]:
    # 同时检查词法绝对路径与实际路径；Wine 的 Unix 根默认映射到 Z:。
    variants = set()
    for absolute in (Path(os.path.abspath(path)), path.resolve()):
        posix = absolute.as_posix()
        if absolute.anchor != "/":
            variants.update((posix, str(absolute)))
            if len(absolute.drive) == 2 and absolute.drive[1] == ":":
                variants.update((posix[0].swapcase() + posix[1:],
                                 str(absolute)[0].swapcase() + str(absolute)[1:]))
        elif len(posix) > 1:
            variants.add(posix)
            for drive in ("Z:", "z:"):
                variants.update((drive + posix, drive + posix.replace("/", chr(92))))
    return {s for s in variants if len(s) > 3}


def check_artifact(path: Path, words: set[str]) -> None:
    data = path.read_bytes()
    if not data:
        raise MetadataError(f"{path.name}：产物为空")
    if path.suffix in (".obj", ".exe"):
        off = 0
        if path.suffix == ".exe":
            if len(data) < 64 or data[:2] != b"MZ":
                raise MetadataError(f"{path.name}：缺少 DOS 头")
            pe = struct.unpack_from("<I", data, 60)[0]
            if pe < 64 or data[pe:pe + 4] != b"PE\0\0":
                raise MetadataError(f"{path.name}：缺少 PE 签名")
            off = pe + 4
        if len(data) < off + 20 or struct.unpack_from("<H", data, off)[0] != 0x8664:
            raise MetadataError(f"{path.name}：缺少 AMD64 COFF 头")
        if struct.unpack_from("<I", data, off + 4)[0] != 0:
            raise MetadataError(f"{path.name}：COFF TimeDateStamp 非零")
    for word in sorted(words):
        if any(word.encode(encoding) in data for encoding in ("utf-8", "utf-16-le")):
            raise MetadataError(f"{path.name}：含本次构建的绝对宿主路径")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host-path", type=Path, action="append", required=True)
    parser.add_argument("artifact", type=Path, nargs="+")
    args = parser.parse_args()
    words = set().union(*(host_path_spellings(path) for path in args.host_path))
    if not words:
        parser.error("没有可核对的绝对宿主路径")
    try:
        for artifact in args.artifact:
            check_artifact(artifact, words)
    except (MetadataError, OSError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1
    print(f"B-2：{len(args.artifact)} 件产物的适用 COFF 时间戳为零、无本次构建绝对宿主路径。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
