#!/usr/bin/env python3
"""封存与核验 Windows 原生冷启动向 Linux 原生自举交接的中间产物。"""

import argparse
import re
import shutil
import sys
from pathlib import Path

from ci_artifacts import digest, read_json, write_json

WIN64_FILES = tuple(
    f"{stage}/out/{tool}.exe" for stage in ("c2", "c3") for tool in ("main", "imports")
) + ("runtime.obj",)
ELF_ROOTS = ("main", "imports")
OBJ_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\.o$")


def read_order(path: Path) -> list[str]:
    names = [line.strip() for line in path.read_text(encoding="ascii").splitlines() if line.strip()]
    if not names or len(set(names)) != len(names):
        raise ValueError(f"ELF 链接顺序清单为空或含重复项：{path}")
    for name in names:
        if not OBJ_NAME.fullmatch(name):
            raise ValueError(f"ELF 链接顺序清单含非法对象名：{name}")
    return names


def collect_stage_files(root: Path) -> list[str]:
    files = list(WIN64_FILES)
    for name in ELF_ROOTS:
        order_rel = f"elf-c0-objects/{name}.order"
        order_path = root / order_rel
        files.append(order_rel)
        for obj in read_order(order_path):
            files.append(f"elf-c0-objects/{name}/{obj}")
    return files


def seal_stage(args: argparse.Namespace) -> None:
    args.output.mkdir(parents=True, exist_ok=False)
    hashes = {}
    for rel in collect_stage_files(args.root):
        source = args.root / rel
        hashes[rel] = digest(source)
        target = args.output / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    write_json(args.output / "stage.json", {"commit": args.commit, "run": args.run, "files": hashes})


def verify_stage(args: argparse.Namespace) -> None:
    manifest = read_json(args.root / "stage.json")
    expected_files = collect_stage_files(args.root)
    expected = {
        "commit": args.commit,
        "run": args.run,
        "files": {rel: digest(args.root / rel) for rel in expected_files},
    }
    if manifest != expected:
        raise ValueError("Win64 冷启动交接产物的提交、运行编号或文件摘要不一致")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("seal", "verify"))
    parser.add_argument("root", type=Path)
    parser.add_argument("commit")
    parser.add_argument("run")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit) or not re.fullmatch(r"[1-9][0-9]*", args.run):
        parser.error("提交或运行编号无效")
    if args.operation == "seal" and args.output is None:
        parser.error("seal 需要 --output")
    try:
        if args.operation == "seal":
            seal_stage(args)
        else:
            verify_stage(args)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
