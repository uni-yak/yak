#!/usr/bin/env python3
"""封存共享候选、逐例验收结果与可发布的双目标资产。"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path

from test_diag_contract import Failure, parse_jsonl

TARGETS = ("win-x64", "linux-x64")
CANDIDATE_FILES = (
    tuple(f"{stage}/out/{tool}.exe" for stage in ("c2", "c3") for tool in ("main", "imports"))
    + tuple(f"elf-{stage}/out/{tool}.elf" for stage in ("c2", "c3") for tool in ("main", "imports"))
    + ("runtime.obj",)
)
PACKAGES = {"win-x64": "yak-windows-x64.zip", "linux-x64": "yak-linux-x86-64.tar.gz"}
CASE_RESULT = re.compile(r"^\[通过\] (positive|negative|graph) (test/[^：]+)：")


def digest(path):
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"缺少普通文件：{path}")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8", newline="\n")


def read_json(path):
    digest(path)
    return json.loads(path.read_bytes())


def publish_candidate(args):
    args.output.mkdir()
    hashes = {}
    for name in CANDIDATE_FILES:
        source = args.root / name
        hashes[name] = digest(source)
        target = args.output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if name.endswith(".elf"):
            os.chmod(target, 0o755)
    write_json(args.output / "candidate.json", {"commit": args.commit, "run": args.run, "files": hashes})


def verify_candidate(args):
    manifest = read_json(args.root / "candidate.json")
    expected = {"commit": args.commit, "run": args.run,
                "files": {name: digest(args.root / name) for name in CANDIDATE_FILES}}
    if manifest != expected:
        raise ValueError("候选提交、运行编号或工具摘要不一致")
    return digest(args.root / "candidate.json")


def collect_cases(semantic):
    results = {}
    for line in (semantic / "semantic.log").read_text(encoding="utf-8").splitlines():
        match = CASE_RESULT.match(line)
        if not match:
            raise ValueError(f"缺少通过的逐例回执：{line}")
        kind, source = match.groups()
        src = Path(source)
        if source in results or ".." in src.parts or src.suffix != ".yak":
            raise ValueError(f"无效或重复的语料回执：{source}")
        case = semantic.joinpath(*src.parts[1:]).with_suffix("")
        status = (case / "c2.rc").read_text(encoding="ascii").strip()
        result = {"kind": kind, "driver_exit": status}
        if kind == "positive":
            output = case / "c2" / src.stem
            exit_codes = re.findall(r"^exit_code=([0-9]+)$",
                                    (case / "c2-link.stdout").read_text(encoding="utf-8"), re.MULTILINE)
            if status != "0" or len(exit_codes) != 1:
                raise ValueError(f"无唯一成功退出记录：{source}")
            result.update(exit=exit_codes[0], stdout=digest(output / "stdout.txt"),
                          stderr=digest(output / "stderr.txt"))
        else:
            if status != "1":
                raise ValueError(f"驱动没有按预期拒绝：{source}")
            suffix = "build" if kind == "graph" else "link"
            result["diagnostics"] = digest(case / f"c2-{suffix}.stderr")
            if kind == "negative":
                result["jsonl"] = digest(case / "jsonl" / src.stem / f"{src.stem}.diag.jsonl")
        results[source] = result
    if {value["kind"] for value in results.values()} != {"positive", "negative", "graph"}:
        raise ValueError("缺少正例、普通负例或模块图负例")
    return results


def publish_platform(args):
    candidate = verify_candidate(args)
    semantic, = args.root.glob(f"platform-{args.target}.*/semantic")
    package = PACKAGES[args.target]
    write_json(args.output / "platform.json",
               {"commit": args.commit, "run": args.run, "candidate": candidate, "target": args.target,
                "package": package, "digest": digest(args.output / package), "cases": collect_cases(semantic)})


def verify_platform(root, target, commit, run):
    data = read_json(root / "platform.json")
    if (data["commit"], data["run"], data["target"], data["package"], data["digest"]) != (
            commit, run, target, PACKAGES[target], digest(root / PACKAGES[target])):
        raise ValueError(f"{target} 验收记录或分发包摘要不一致")
    return data


def assemble(args):
    win = verify_platform(args.root / "win-x64", "win-x64", args.commit, args.run)
    linux = verify_platform(args.root / "linux-x64", "linux-x64", args.commit, args.run)
    if win["candidate"] != linux["candidate"]:
        raise ValueError("两个平台未使用同一候选")
    if win["cases"].keys() != linux["cases"].keys():
        raise ValueError("两个平台的语料集合不一致")
    for case, result in win["cases"].items():
        if result != linux["cases"][case]:
            raise ValueError(f"跨目标退出、输出或诊断字节不一致：{case}")
    args.output.mkdir()
    assets = {}
    for data in (win, linux):
        name = data["package"]
        shutil.copyfile(args.root / data["target"] / name, args.output / name)
        assets[name] = data["digest"]
    write_json(args.output / "build-manifest.json",
               {"commit": args.commit, "run": args.run, "candidate": win["candidate"],
                "assets": assets, "compared_cases": len(win["cases"])})
    assets["build-manifest.json"] = digest(args.output / "build-manifest.json")
    (args.output / "SHA256SUMS").write_text("".join(f"{value}  {name}\n" for name, value in sorted(assets.items())),
                                          encoding="ascii", newline="\n")
    print(f"双平台逐例对拍通过：{len(win['cases'])} 案")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    if sys.argv[1:2] == ["jsonl"]:
        parser.add_argument("operation")
        parser.add_argument("diagnostic", type=Path)
        parser.add_argument("unit")
        parser.add_argument("codes", nargs="+")
        args = parser.parse_args()
        try:
            rows = parse_jsonl(args.diagnostic.read_bytes())
            if ([f"E{row['code']:04d}" for row in rows] != args.codes
                    or any(row["unit"] != args.unit or row["severity"] != "error" for row in rows)):
                raise ValueError("JSONL 错误码、模块或严重级别不符")
        except (OSError, Failure, ValueError) as error:
            parser.exit(1, f"错误：{error}\n")
        return
    parser.add_argument("operation", choices=("candidate", "check-candidate", "platform", "assemble"))
    parser.add_argument("root", type=Path)
    parser.add_argument("commit")
    parser.add_argument("run")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--target", choices=TARGETS)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit) or not re.fullmatch(r"[1-9][0-9]*", args.run):
        parser.error("提交或运行编号无效")
    if args.operation != "check-candidate" and args.output is None:
        parser.error("需要 --output")
    if args.operation == "platform" and args.target is None:
        parser.error("需要 --target")
    operations = {"candidate": publish_candidate, "check-candidate": verify_candidate,
                  "platform": publish_platform, "assemble": assemble}
    try:
        operations[args.operation](args)
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(1, f"错误：{error}\n")


if __name__ == "__main__":
    main()
