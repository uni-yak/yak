"""经正式链接入口验证 Win64 绝对重定位及发布回滚。"""
import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess

from test_coff_rel32_link import ADDR32NB, ADDR64, check, make_object, marker, pe_sections


SITE64 = b"YakExternalAbsoluteSite"
SITE32 = b"YakLocalAbsoluteSite"
TARGET64 = b"YakExternalAbsoluteTarget"
TARGET32 = b"YakLocalAbsoluteTarget"
WRAPPER = '''#!/usr/bin/env bash
# 保留真实 Seed 生成的接口，只替换指定夹具的 COFF 输出。
set -euo pipefail
source tools/target.sh
yak_seed_command "$YAK_ABSOLUTE_REAL_SEED" seed
"${seed[@]}" "$@"
while (( $# )); do
    if [[ $1 == --output && ${2:-} == obj=* ]]; then
        object=${2#obj=}
        case ${object##*/} in
            provider.obj) cp -- "$YAK_ABSOLUTE_PROVIDER" "$object" ;;
            consumer.obj) cp -- "$YAK_ABSOLUTE_CONSUMER" "$object" ;;
        esac
        break
    fi
    shift
done
'''


def consumer_object(addend64, addend32):
    head = b"\xc3"
    text = head + SITE64 + addend64.to_bytes(8, "little", signed=True) + SITE32 + addend32.to_bytes(4, "little", signed=True)
    offset64 = len(head) + len(SITE64)
    offset32 = offset64 + 8 + len(SITE32)
    return make_object(text, TARGET32,
                       ((b"yak$entry", 0, 1), (b"yak$provider$f1", 0, 0), (b"local", 0, 2)),
                       ((offset64, 1, ADDR64), (offset32, 2, ADDR32NB)))


def run_publication(cc, work):
    work.mkdir()
    wrapper = work / "seed-with-coff"
    wrapper.write_text(WRAPPER, encoding="utf-8", newline="\n")
    wrapper.chmod(0o755)
    (work / "provider.yak").write_bytes(b"export function target(): void { return; }\n")
    (work / "consumer.yak").write_bytes(b"import provider;\nfunction main(): void { provider::target(); }\n")
    provider = work / "fixture-provider.obj"
    provider.write_bytes(make_object(TARGET64, b"", ((b"yak$provider$f1", 0, 1),), ()))
    bash = shutil.which("bash")
    check(bash is not None, "当前工具链缺少 Bash")
    environment = dict(os.environ, YAK_TARGET_CC=cc,
                       YAK_ABSOLUTE_REAL_SEED=os.environ.get("YAK_SEED_BIN", "./seed/out/yak-seed.exe"),
                       YAK_SEED_BIN=wrapper.as_posix(), YAK_ABSOLUTE_PROVIDER=provider.as_posix())

    def compile_case(name, addends, rejected_width=None):
        fixture = work / f"{name}.obj"
        image = consumer_object(*addends)
        fixture.write_bytes(image)
        environment["YAK_ABSOLUTE_CONSUMER"] = fixture.as_posix()
        output = work / f"{name} output"
        result = subprocess.run(
            [bash, "tools/link.sh", (work / "provider.yak").as_posix(), (work / "consumer.yak").as_posix(),
             "--no-run", "--out-dir", output.as_posix()], env=environment, capture_output=True, check=False,
        )
        (work / f"{name}.stdout").write_bytes(result.stdout)
        (work / f"{name}.stderr").write_bytes(result.stderr)
        (work / f"{name}.exit").write_text(f"{result.returncode}\n", encoding="utf-8")
        root = output / "consumer"
        exe = root / "consumer.exe"
        check((root / "consumer.obj").is_file(), f"未编译出测试对象：{result.stderr!r}")
        check(fixture.read_bytes() == image and (root / "consumer.obj").read_bytes() == image,
              "链接未使用预期夹具对象或改写了对象")
        check(not (root / ".linked.exe").exists() and not (root / ".linked.map").exists(), "暂存件未清理")
        if rejected_width is not None:
            diagnostic = result.stderr.decode("utf-8")
            expected = f"绝对重定位结果 -1 超出 {rejected_width} 位无符号范围"
            check(result.returncode == 1 and not result.stdout and not exe.exists()
                  and diagnostic.startswith("E8012 ") and expected in diagnostic, f"错误的发布拒绝：{diagnostic}")
            print(f"{name}：退出 1，E8012，最终 EXE 数量为 0", flush=True)
            return None
        check(result.returncode == 0 and exe.is_file() and not result.stderr, f"合法链接失败：{result.stderr!r}")
        raw = exe.read_bytes()
        pe, = struct.unpack_from("<I", raw, 60)
        base, = struct.unpack_from("<Q", raw, pe + 48)
        sections = pe_sections(raw)
        extern_rva, _ = marker(sections[b".text"], TARGET64)
        local_rva, _ = marker(sections[b".rdata"], TARGET32)
        _, at64 = marker(sections[b".text"], SITE64)
        _, at32 = marker(sections[b".text"], SITE32)
        expected = (base + extern_rva, local_rva)
        values = (int.from_bytes(at64[:8], "little"), int.from_bytes(at32[:4], "little"))
        check(values == tuple(origin + addend for origin, addend in zip(expected, addends)), "最终 PE 的重定位值不符")
        print(f"{name}：退出 0，读回 {values}", flush=True)
        return expected

    origin64, origin32 = compile_case("base", (0, 0))
    compile_case("zero", (-origin64, -origin32))
    compile_case("under64", (-origin64 - 1, 0), 64)
    compile_case("under32", (0, -origin32 - 1), 32)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cc", help="Win64 GCC")
    parser.add_argument("out_dir", type=Path, help="父目录已存在的新回执目录")
    args = parser.parse_args()
    run_publication(args.cc, args.out_dir)
