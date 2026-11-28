"""检查固定点收敛前的 full 实体与 min 默认输出边界。"""

from pathlib import Path
import stat
import sys

from t2_stage_fixpoint_gate import DEFAULT_RECEIPT_REL, is_valid_fixpoint_receipt


PLACEHOLDERS = {
    "compiler/full": stat.S_IFDIR,
    "compiler/full/README.md": stat.S_IFREG,
    "compiler/full/src": stat.S_IFDIR,
    "compiler/full/src/README.md": stat.S_IFREG,
    "compiler/full/src/opt": stat.S_IFDIR,
    "compiler/full/src/opt/README.md": stat.S_IFREG,
}
FULL_OUTPUTS = tuple(
    f"out/{name}{suffix}"
    for name in ("yakc-full", "yakc_full", "full_imports")
    for suffix in ("", ".exe", ".elf")
) + ("out/.yakc-full.yak-root", "out/.yakc_full.yak-root", "out/.full_imports.yak-root")


def entry_type(path):
    try:
        return stat.S_IFMT(path.lstat().st_mode)
    except FileNotFoundError:
        return None


def unexpected_entries(root):
    """固定点前只允许已知说明；默认输出始终禁止 full 候选。"""
    for parent in ("compiler", "out"):
        if entry_type(root / parent) not in (None, stat.S_IFDIR):
            raise OSError(f"无法检查非普通目录：{parent}")
    receipt = root / DEFAULT_RECEIPT_REL
    converged = entry_type(receipt) == stat.S_IFREG and is_valid_fixpoint_receipt(receipt)
    pending = [] if converged else ["compiler/full"]
    if converged and entry_type(root / "compiler/full") not in (None, stat.S_IFDIR):
        yield "compiler/full"
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
        print(f"错误：SD-1：固定点或默认输出边界出现 yakc-full 实体：{name!r}", file=sys.stderr)
    return int(bool(violations))


if __name__ == "__main__":
    sys.exit(main(Path(__file__).resolve().parents[2]))
