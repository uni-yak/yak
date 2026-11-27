#!/usr/bin/env python3
# 对拍布局数量的相邻边界，不在仓库中保存大体积生成语料。
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
BOUNDARY = 65536
CODES = {"struct": "E5510", "enum": "E5503"}
ERROR_SET_MODULES = (
    "compiler/min/lib/buf.yak",
    "compiler/min/lib/hash.yak",
    "compiler/min/lib/hashmap.yak",
    "compiler/min/lib/types.yak",
    "compiler/min/src/lex/lextables.yak",
    "compiler/min/src/lex/lex.yak",
    "compiler/min/src/parse/ast.yak",
    "compiler/min/src/diag/diag.yak",
    "compiler/min/src/check/resolve.yak",
    "compiler/min/src/check/resolve_refs.yak",
    "compiler/min/src/check/consteval.yak",
    "compiler/min/src/check/typecheck.yak",
    "compiler/min/src/check/layout.yak",
)
ERROR_SET_FIXTURE = "test/gate/fixtures/error_set_layout.yak"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generate(source, kind, count):
    members = (f"    F{i}: u8" if kind == "struct" else f"    V{i}" for i in range(count))
    body = ",\n".join(members)
    source.write_bytes(f"{kind} Many {{\n{body}\n}}\nfunction main(): void {{ return; }}\n".encode("ascii"))


def check_side(compiler, name, source, rejected, code, case_dir, env, timeout):
    case_dir.mkdir()
    out = case_dir / "out"
    command = ["bash", "tools/link.sh", str(source), "--out-dir", str(out),
               "--native-compiler", str(compiler), "--no-run"]
    with (case_dir / "stdout").open("wb") as stdout, (case_dir / "stderr").open("wb") as stderr:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=stdout, stderr=stderr, timeout=timeout)
    (case_dir / "exit.txt").write_bytes(f"{result.returncode}\n".encode("ascii"))
    expected_rc = 1 if rejected else 0
    require(result.returncode == expected_rc, f"{case_dir}：退出 {result.returncode}，应为 {expected_rc}")
    unit = out / name
    require(unit.is_dir() and not unit.is_symlink() and set(out.iterdir()) == {unit},
            f"{case_dir}：链接输出根不符合预期")
    names = ("driver.request", "driver.response") if rejected else tuple(
        f"{name}.{ext}" for ext in ("obj", "iface", "exe"))
    files = {unit / item for item in names}
    require(set(unit.iterdir()) == files and all(
        path.is_file() and not path.is_symlink() and path.stat().st_size for path in files),
        f"{case_dir}：产物集合不符或存在空文件／链接")
    stdout = (case_dir / "stdout").read_bytes()
    stderr = (case_dir / "stderr").read_bytes()
    if rejected:
        expected = f"错误 {code} @ off=0\n构建失败：1 个错误\n".encode("utf-8")
        response = (unit / "driver.response").read_bytes()
        require(response == expected and not stdout and
                stderr == expected + f"错误：编译单元 {name} 失败：{source}\n".encode("utf-8"),
                f"{case_dir}：诊断响应、标准流或诊断序列不符")
        return (response, stderr)
    expected = f"obj={unit / (name + '.obj')}\nexe={unit / (name + '.exe')}\n".encode("utf-8")
    require(stdout == expected and not stderr, f"{case_dir}：成功输出或标准错误不符")
    return tuple((unit / item).read_bytes() for item in names)


def check_error_set_side(compiler, source, case_dir, env, timeout):
    case_dir.mkdir()
    out = case_dir / "out"
    command = ["bash", "tools/link.sh", *ERROR_SET_MODULES, str(source), "--out-dir", str(out),
               "--native-compiler", str(compiler), "--expect-exit", "0", "--expect-stdout", ""]
    with (case_dir / "stdout").open("wb") as stdout, (case_dir / "stderr").open("wb") as stderr:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=stdout, stderr=stderr, timeout=timeout)
    (case_dir / "exit.txt").write_bytes(f"{result.returncode}\n".encode("ascii"))
    require(result.returncode == 0 and not (case_dir / "stderr").read_bytes(),
            f"{case_dir}：错误集布局断言失败或产生标准错误，退出 {result.returncode}")
    name = source.stem
    unit = out / name
    outputs = [unit / f"{Path(path).stem}.obj" for path in (*ERROR_SET_MODULES, source)]
    expected = "".join(f"obj={path}\n" for path in outputs) + f"exe={unit / (name + '.exe')}\nexit_code=0\n"
    require((case_dir / "stdout").read_bytes() == expected.encode("utf-8"),
            f"{case_dir}：未得到预期的链接及运行回执")
    files = [unit / f"{name}.{ext}" for ext in ("obj", "iface", "exe")]
    require(all(path.is_file() and not path.is_symlink() and path.stat().st_size for path in files),
            f"{case_dir}：错误集布局探针缺少根产物")
    return tuple(path.read_bytes() for path in files)


def check_error_set(compilers, inputs, out, env, timeout):
    source = inputs / "error_set_layout.yak"
    source.write_bytes((ROOT / ERROR_SET_FIXTURE).read_bytes())
    modules = {path: fingerprint(ROOT / path) for path in ERROR_SET_MODULES}
    source_hash = fingerprint(source)
    with (out / "inputs.sha256").open("a", encoding="ascii", newline="\n") as hashes:
        hashes.write(f"{source_hash}  inputs/{source.name}\n")
    (out / "error-set-modules.sha256").write_bytes(b"".join(
        f"{digest}  {path}\n".encode("ascii") for path, digest in modules.items()))
    case_dir = out / source.stem
    case_dir.mkdir()
    results = []
    sentinel = Path(env["YAK_SEED_BIN"])
    for side, compiler in compilers.items():
        results.append(check_error_set_side(compiler, source, case_dir / side, env, timeout))
        require(fingerprint(source) == source_hash and all(
            fingerprint(ROOT / path) == digest for path, digest in modules.items()),
            f"{side}：错误集探针或模块输入发生变化")
        require(not sentinel.exists() and not sentinel.is_symlink(), f"{side}：Seed 哨兵路径被占用")
    require(results[0] == results[1], "错误集布局断言的根产物两遍不一致")
    with (out / "summary.txt").open("a", encoding="utf-8", newline="\n") as summary:
        summary.write("error_set_layout：规范化后 65536 成员通过、65537 成员只发 E5503；两路运行退出 0，三件产物同字节\n")


def run(args):
    c2, c3 = (path.resolve(strict=True) for path in (args.c2, args.c3))
    require(c2 != c3 and c2.is_file() and c3.is_file(), "必须指定两个独立路径下的原生编译器")
    require(args.timeout > 0, "单次执行超时必须大于零")
    compilers = {"c2": c2, "c3": c3}
    compiler_hashes = {side: fingerprint(path) for side, path in compilers.items()}
    out = args.out_dir.resolve()
    out.mkdir()
    print(f"证据目录：{out}", flush=True)
    env = os.environ.copy()
    env.update(LC_ALL="C", TZ="UTC", YAK_SEED_BIN=str(out / "missing-seed.exe"))
    sentinel = Path(env["YAK_SEED_BIN"])
    inputs = out / "inputs"
    inputs.mkdir()
    for kind, code in CODES.items():
        for count in (BOUNDARY, BOUNDARY + 1):
            name = f"{kind}_{count}"
            source = inputs / f"{name}.yak"
            generate(source, kind, count)
            source_hash = fingerprint(source)
            with (out / "inputs.sha256").open("a", encoding="ascii", newline="\n") as hashes:
                hashes.write(f"{source_hash}  inputs/{source.name}\n")
            case_dir = out / name
            case_dir.mkdir()
            rejected = count > BOUNDARY
            results = []
            for side, compiler in compilers.items():
                results.append(check_side(compiler, name, source, rejected, code, case_dir / side, env, args.timeout))
                require(fingerprint(source) == source_hash, f"{name}/{side}：输入发生变化")
                require(not sentinel.exists() and not sentinel.is_symlink(), f"{name}/{side}：Seed 哨兵路径被占用")
            require(results[0] == results[1], f"{name}：两遍成功产物或拒绝诊断不同")
            message = f"退出 1，只发 {code}，诊断响应同字节，无根产物" if rejected else "退出 0，三件产物同字节"
            with (out / "summary.txt").open("a", encoding="utf-8", newline="\n") as summary:
                summary.write(f"{name}：两路{message}\n")
    check_error_set(compilers, inputs, out, env, args.timeout)
    require(all(fingerprint(path) == compiler_hashes[side] for side, path in compilers.items()),
            "有原生编译器在对拍期间发生变化")
    (out / "compilers.sha256").write_bytes(b"".join(
        f"{compiler_hashes[side]}  {path}\n".encode("utf-8") for side, path in compilers.items()))


def main():
    parser = argparse.ArgumentParser(description="本机原生 C2/C3 布局数量边界对拍")
    parser.add_argument("--c2", type=Path, required=True)
    parser.add_argument("--c3", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True, help="必须不存在，父目录须已存在")
    parser.add_argument("--timeout", type=int, default=180, help="每次链接的秒数上限")
    try:
        run(parser.parse_args())
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"布局数量专项失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
