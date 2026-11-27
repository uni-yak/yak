"""校验固定点与阶段迁移门禁断言：FP-4、SD-2、SD-3。"""

import argparse
import json
from pathlib import Path
import re
import stat
import sys


FIXPOINT_GUARDED_DOCS = (
    "spec/proc/fixpoint.md",
    "spec/proc/seed.md",
)
ALLOWED_FULL_PLACEHOLDERS = {
    "compiler/full",
    "compiler/full/README.md",
    "compiler/full/src",
    "compiler/full/src/README.md",
    "compiler/full/src/opt",
    "compiler/full/src/opt/README.md",
}
REQUIRED_RECEIPT_FLAGS = (
    "c2_eq_c3",
    "fp3_ok",
    "win64_matrix_ok",
    "linux_elf_matrix_ok",
    "ci_trusted",
)
STATUS_RE = re.compile(r"^- 状态：(确认|草案-可实施|草案|缺失)\s*$", re.M)
STAGE_LINE_RE = re.compile(r"^([a-zA-Z0-9_]+)\s*:\s*(.*)$")


def parse_stage_file(path: Path) -> dict[str, str]:
    """解析 STAGE 元数据键值。"""
    data: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = STAGE_LINE_RE.match(line)
        if match:
            data[match.group(1)] = match.group(2).strip()
    return data


def is_valid_fixpoint_receipt(receipt_path: Path | None) -> bool:
    """判定正式固定点归档收据是否完整且全部为真。"""
    if receipt_path is None or not receipt_path.is_file():
        return False
    try:
        payload = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    if not isinstance(payload, dict):
        return False
    for key in REQUIRED_RECEIPT_FLAGS:
        if payload.get(key) is not True:
            return False
    digest = payload.get("c2_main_sha256")
    return isinstance(digest, str) and bool(re.fullmatch(r"[0-9a-f]{64}", digest))


def check_fp4(root: Path, converged: bool) -> list[str]:
    """FP-4：收敛未达成不得将固定点/点火流程规格改标为确认。"""
    violations: list[str] = []
    if converged:
        return violations
    for rel in FIXPOINT_GUARDED_DOCS:
        doc = root / rel
        if not doc.is_file():
            continue
        match = STATUS_RE.search(doc.read_text(encoding="utf-8"))
        if match and match.group(1) == "确认":
            violations.append(f"错误：FP-4：固定点收敛未达成即改标确认：{rel}")
    return violations


def check_sd2_stage(stage_meta: dict[str, str]) -> list[str]:
    """SD-2：T2 之后阶段元数据不得继续声明由 yak-seed 参与构建。"""
    violations: list[str] = []
    stage = stage_meta.get("stage", "")
    ignition = stage_meta.get("ignition", "")
    if stage in ("T3", "T4") and "yak-seed" in ignition:
        violations.append(f"错误：SD-2：阶段 {stage} 的 STAGE 仍声明 yak-seed 参与构建")
    return violations


def check_sd2_commands(commands_path: Path) -> list[str]:
    """SD-2：检查 T2 原生遍次（C1–C3 或 T3+）命令记录是否混入 yak-seed 或回退参数。"""
    violations: list[str] = []
    lines = commands_path.read_text(encoding="utf-8").splitlines()
    for idx, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # 跳过显式 C0 点火行；仅检查 C1–C3 或无前缀的 T2+ 构建行。
        if re.match(r"^\[?C0\]?\b", line) or "--out-dir" in line and "/c0" in line and "--native-compiler" not in line:
            continue
        if "--require-frozen-seed" in line:
            violations.append(f"错误：SD-2：第 {idx} 行在 T2 后仍要求冻结 Seed")
            continue
        # 剔除用于阻断回退的哨兵环境变量赋值（YAK_SEED_BIN=...absent... 或 seed-must-not-exist）。
        sanitized = re.sub(
            r"YAK_SEED_BIN=\S*(?:absent|must-not-exist)\S*",
            "",
            line,
        )
        if "yak-seed" in sanitized:
            violations.append(f"错误：SD-2：第 {idx} 行在 T2 后仍调用 yak-seed")
            continue
        if ("selfhost.sh" in line or "compiler/min/build.sh" in line) and (
            "--native-compiler" not in line or "--native-scanner" not in line
        ):
            violations.append(f"错误：SD-2：第 {idx} 行缺少原生编译器/扫描器成对参数，存在 Seed 回退风险")
    return violations


def check_sd3(root: Path, stage_meta: dict[str, str], converged: bool) -> list[str]:
    """SD-3：固定点未达成不得进入 T3 阶段或落盘 yakc-full 实现实体。"""
    violations: list[str] = []
    if converged:
        return violations
    stage = stage_meta.get("stage", "")
    if stage in ("T3", "T4"):
        violations.append(f"错误：SD-3：固定点未达成即把 compiler/min/STAGE 推进至 {stage}")
    full_root = root / "compiler/full"
    if full_root.exists() or full_root.is_symlink():
        pending = ["compiler/full"]
        while pending:
            rel = pending.pop()
            target = root / rel
            mode = stat.S_IFMT(target.lstat().st_mode)
            if rel not in ALLOWED_FULL_PLACEHOLDERS:
                violations.append(f"错误：SD-3：固定点未达成即在 T3 目录写入实体：{rel}")
                continue
            if mode == stat.S_IFLNK:
                violations.append(f"错误：SD-3：固定点未达成且 T3 目录含符号链接：{rel}")
            elif mode == stat.S_IFDIR:
                for child in sorted(target.iterdir(), key=lambda item: item.name):
                    pending.append(f"{rel}/{child.name}")
    return violations


def run_gate(root: Path, receipt_path: Path | None, commands_path: Path | None) -> tuple[int, list[str]]:
    """执行 FP-4 / SD-2 / SD-3 联合校验。"""
    stage_file = root / "compiler/min/STAGE"
    if not stage_file.is_file():
        return 2, [f"错误：缺少阶段元数据文件：{stage_file}"]
    stage_meta = parse_stage_file(stage_file)
    converged = is_valid_fixpoint_receipt(receipt_path)
    violations: list[str] = []
    violations.extend(check_fp4(root, converged))
    violations.extend(check_sd2_stage(stage_meta))
    if commands_path is not None:
        if not commands_path.is_file():
            return 2, [f"错误：缺少命令记录文件：{commands_path}"]
        violations.extend(check_sd2_commands(commands_path))
    violations.extend(check_sd3(root, stage_meta, converged))
    return (1 if violations else 0), violations


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="检查 FP-4、SD-2、SD-3 固定点与阶段切换门禁")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2], help="仓库根目录")
    parser.add_argument("--fixpoint-receipt", type=Path, default=None, help="正式固定点归档收据 JSON 路径")
    parser.add_argument("--commands", type=Path, default=None, help="待审计的 T2+ 构建命令记录文件")
    args = parser.parse_args(argv)
    rc, messages = run_gate(args.root, args.fixpoint_receipt, args.commands)
    for msg in messages:
        print(msg, file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
