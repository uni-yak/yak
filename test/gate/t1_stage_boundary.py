"""检查 T1 树没有提前出现 yakc-full 实现或默认输出。"""

from pathlib import Path
import stat
import sys


PLACEHOLDERS = {
    "compiler/full": stat.S_IFDIR,
    "compiler/full/README.md": stat.S_IFREG,
    "compiler/full/src": stat.S_IFDIR,
    "compiler/full/src/README.md": stat.S_IFREG,
    "compiler/full/src/opt": stat.S_IFDIR,
    "compiler/full/src/opt/README.md": stat.S_IFREG,
}
FULL_OUTPUTS = ("out/yakc-full", "out/yakc-full.exe", "out/.yakc-full.yak-root")


def entry_type(path):
    try:
        return stat.S_IFMT(path.lstat().st_mode)
    except FileNotFoundError:
        return None


def unexpected_entries(root):
    """只遍历已知的说明性目录，不跟随符号链接。"""
    for parent in ("compiler", "out"):
        if entry_type(root / parent) not in (None, stat.S_IFDIR):
            raise OSError(f"无法检查非普通目录：{parent}")
    pending = ["compiler/full"]
    while pending:
        name = pending.pop()
        path = root / name
        kind = entry_type(path)
        if kind is None:
            continue
        if kind != PLACEHOLDERS.get(name):
            yield name
        elif kind == stat.S_IFDIR:
            pending.extend(f"{name}/{child.name}" for child in path.iterdir())
    for name in FULL_OUTPUTS:
        if entry_type(root / name) is not None:
            yield name


def main(root):
    try:
        violations = sorted(unexpected_entries(root))
    except OSError as exc:
        print(f"错误：SD-1 检查未完成：{exc}", file=sys.stderr)
        return 2
    for name in violations:
        print(f"错误：SD-1：T1 树出现 yakc-full 实体：{name!r}", file=sys.stderr)
    return int(bool(violations))


if __name__ == "__main__":
    sys.exit(main(Path(__file__).resolve().parents[2]))
