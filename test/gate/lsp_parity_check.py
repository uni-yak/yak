"""同一份源码在正式驱动和实际 stdio LSP 之间对拍。"""

import argparse
import json
from pathlib import Path
import subprocess
import sys

from lsp_frame_check import open_pipe, require, wire


CASES = (
    # 阶段、原样文本、错误码、正式驱动字节偏移、可信跨度字节长度、线上消息类别。
    ("lex", "//中😀", "E1018", 9, 0, "词法诊断"),
    ("parse", "; function main(): void {}\n", "E2001", 0, 1, "解析诊断"),
    ("name", "//中😀\nfunction main(): void { return missing; }\n", "E4002", 41, 7, "名称诊断"),
    ("type", "function main(): void { let n: bool = 1u32; if n { return; } }\n",
     "E5001", 24, len("let n: bool = 1u32;"), "类型或布局诊断"),
    ("layout", "struct Bad {}\nfunction main(): void {}\n", "E5502", 0, None, ""),
    ("owner", "struct S { v: u32[] }\nfunction f(s: S, b: bool): void { if b { @drop(s); } @drop(s); }\n"
     "function main(): void {}\n", "E6003", 75, len("@drop"), "所有权诊断"),
    ("valid", "function main(): void {}\n", None, 0, None, ""),
)
MISSING = "import absent;\nimport other_missing;\nfunction main(): void { return; }\n"
EXTENSIONS = ("obj", "iface", "ysm")


def run(args):
    return subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, timeout=60)


def batch(work, command, shell, runner):
    work.mkdir()
    for name, source, code, offset, _, _ in CASES:
        path = work / f"{name}.yak"
        path.write_bytes(source.encode("utf-8"))
        products = [work / f"{name}.{ext}" for ext in EXTENSIONS]
        outputs = [arg for ext, target in zip(EXTENSIONS, products) for arg in ("--output", f"{ext}={target}")]
        result = run(command + ["--input", f"src={path}", *outputs, "--", "src", name, "root", "--emit-ysm"])
        (work / f"{name}.stdout").write_bytes(result.stdout)
        (work / f"{name}.stderr").write_bytes(result.stderr)
        expected = f"错误 {code} @ off={offset}\n构建失败：1 个错误\n".encode("utf-8") if code else b""
        require((result.returncode, result.stdout, result.stderr) == (int(code is not None), expected, b""),
                f"{name} 正式驱动退出与终端字节不符：{result!r}")
        if code:
            require(not any(p.exists() for p in products), f"{name} 拒绝后写出产物")
        else:
            require(all(p.stat().st_size > 0 for p in products), "正例缺少正式驱动产物")

    def build(source, suffix):
        out, audit = work / f"out-{suffix}", work / f"audit-{suffix}"
        result = run([shell, "compiler/min/build.sh", source.as_posix(), "--out-dir", out.as_posix(),
                      "--audit-dir", audit.as_posix()])
        (work / f"build-{suffix}.stdout").write_bytes(result.stdout)
        (work / f"build-{suffix}.stderr").write_bytes(result.stderr)
        return result, out, audit

    result, out, audit = build(work / "valid.yak", "valid")
    require(result.returncode == 0 and not result.stderr, f"正例正式构建失败：{result!r}")
    for ext in EXTENSIONS:
        plain = (work / f"valid.{ext}").read_bytes()
        require((audit / "valid" / f"valid.{ext}").read_bytes() == plain, f"正式构建与直接驱动的 .{ext} 字节不一致")
    exe = (out / "valid.exe").as_posix()
    result = run(([runner] if runner else []) + [exe])
    require((result.returncode, result.stdout, result.stderr) == (0, b"", b""), f"正例执行不符：{result!r}")

    missing = work / "missing.yak"
    missing.write_bytes(MISSING.encode("utf-8"))
    expected = "错误 E4002 @ off=0\n错误 E4002 @ off=15\n构建失败：2 个错误\n错误：模块图验证失败\n".encode("utf-8")
    for suffix in ("missing-first", "missing-second"):
        result, out, audit = build(missing, suffix)
        require((result.returncode, result.stdout, result.stderr) == (1, b"", expected),
                f"双缺失导入终端字节或退出不符：{result!r}")
        require(not out.exists() and not audit.exists(), "双缺失导入不应发布任何产物目录")
    print("正式驱动：六阶段拒绝、终端精确字节、正例产物与双缺失不发布通过")


def position(source, offset):
    prefix = source[:offset].decode("utf-8")
    return {"line": prefix.count("\n"), "character": len(prefix.rsplit("\n", 1)[-1].encode("utf-16-le")) // 2}


def exchange(work, send, receive, quiet):
    uri = "file:///C:/Yak%20Parity/unit.yak"

    def packet(**content):
        return wire(json.dumps({"jsonrpc": "2.0", **content}, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))

    def method(name, **params):
        return packet(method=name, params=params)

    def publication(diagnostics, version=None):
        params = {"uri": uri}
        if version is not None:
            params["version"] = version
        params["diagnostics"] = diagnostics
        return method("textDocument/publishDiagnostics", **params)

    client = {"textDocument": {"publishDiagnostics": {"versionSupport": True}}}
    send(packet(id=1, method="initialize", params={"capabilities": client}))
    receive(packet(id=1, result={"capabilities": {}}), "对拍握手")
    send(packet(method="initialized"))
    for version, (name, _, code, offset, length, category) in enumerate(CASES):
        source = (work / f"{name}.yak").read_bytes()
        doc = {"uri": uri, "version": version}
        if version == 0:
            send(method("textDocument/didOpen", textDocument=dict(doc, languageId="yak", text=source.decode("utf-8"))))
        else:
            send(method("textDocument/didChange", textDocument=doc, contentChanges=[{"text": source.decode("utf-8")}]))
        diagnostics = []
        log = b""
        if code and length is not None:
            diagnostics.append({"range": {"start": position(source, offset), "end": position(source, offset + length)},
                                "severity": 1, "source": "yak", "code": code, "message": f"Yak {category} {code}"})
        elif code:
            # 没有可信源码位置的布局错误只能明确降级，不能伪造第零行诊断。
            log = method("window/logMessage", type=2, message="Yak: 有诊断无法定位或超出发布上限")
        receive(log + publication(diagnostics, version), f"{name} 同源诊断对拍")
    send(method("textDocument/didClose", textDocument={"uri": uri}))
    receive(publication([]), "对拍关闭文档")
    send(packet(id=2, method="shutdown"))
    receive(packet(id=2, result=None), "对拍关闭会话")
    send(packet(method="exit"))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bash", default="bash")
    parser.add_argument("--runner", default="")
    parser.add_argument("label", choices=("batch", "seed", "win64"))
    parser.add_argument("work", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("缺少待测命令")
    try:
        if args.label == "batch":
            batch(args.work, args.command, args.bash, args.runner)
        else:
            open_pipe(args.command, lambda *pipe: exchange(args.work, *pipe))
            print(f"{args.label}：开放管道同源诊断对拍通过")
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"前端对拍：{args.label} 失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
