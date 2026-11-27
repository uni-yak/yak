"""针对 P4 阶段 LSP 新增协议与编辑能力的定向管道验证脚本。"""

import json
import subprocess
import sys
from pathlib import Path


def wire(obj: dict) -> bytes:
    body = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


class LspPipe:
    """管理单个 LSP 子进程的双向 JSON-RPC 管道。"""

    def __init__(self, cmd: list[str]) -> None:
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        assert self.proc.stdin is not None
        assert self.proc.stdout is not None
        assert self.proc.stderr is not None

    def send(self, obj: dict) -> None:
        data = wire(obj)
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def recv(self) -> dict:
        headers = b""
        while not headers.endswith(b"\r\n\r\n"):
            ch = self.proc.stdout.read(1)
            if not ch:
                err = self.proc.stderr.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"LSP 标准输出提前结束 (rc={self.proc.poll()}): {err}")
            headers += ch
        length = None
        for line in headers[:-4].split(b"\r\n"):
            k, _, v = line.partition(b":")
            if k.strip().lower() == b"content-length":
                length = int(v.strip())
        if length is None:
            raise RuntimeError(f"缺少 Content-Length 帧头：{headers!r}")
        body = b""
        while len(body) < length:
            chunk = self.proc.stdout.read(length - len(body))
            if not chunk:
                raise RuntimeError("LSP 帧正文读取不完整")
            body += chunk
        return json.loads(body.decode("utf-8"))

    def recv_response(self, req_id) -> dict:
        while True:
            msg = self.recv()
            if "id" in msg and msg["id"] == req_id:
                return msg

    def recv_diagnostics(self, uri: str, version: int | None = None) -> list:
        while True:
            msg = self.recv()
            if msg.get("method") == "textDocument/publishDiagnostics":
                params = msg.get("params", {})
                if params.get("uri") == uri:
                    if version is None or params.get("version") == version:
                        return params.get("diagnostics", [])

    def close(self) -> None:
        try:
            self.send({"jsonrpc": "2.0", "id": 9999, "method": "shutdown"})
            res = self.recv_response(9999)
            if res.get("result") is not None:
                raise RuntimeError(f"shutdown 返回非 null：{res!r}")
            self.send({"jsonrpc": "2.0", "method": "exit"})
            rc = self.proc.wait(timeout=5)
            err = self.proc.stderr.read()
            if rc != 0 or err:
                raise RuntimeError(f"退出异常：rc={rc} stderr={err!r}")
        finally:
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait(timeout=5)


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise RuntimeError(msg)


def check_encodings(cmd: list[str]) -> None:
    # 验证 utf-8 / utf-32 / 回退 utf-16 三种位置编码协商及同坐标增量修复。
    cases = [
        (["utf-8", "utf-32"], "utf-8", 9),
        (["utf-64", "utf-32", "utf-8"], "utf-32", 4),
        (["utf-64"], "utf-16", 5),
    ]
    for offered, expected_enc, expected_col in cases:
        pipe = LspPipe(cmd)
        try:
            uri = "file:///C:/YakP4/enc.yak"
            pipe.send({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "capabilities": {
                        "general": {"positionEncodings": offered},
                        "textDocument": {"publishDiagnostics": {"versionSupport": True}},
                    }
                },
            })
            init = pipe.recv_response(1)
            caps = init["result"]["capabilities"]
            require(caps["positionEncoding"] == expected_enc, f"编码协商不匹配：{caps}")
            require(caps["textDocumentSync"]["change"] == 2, f"增量同步能力缺失：{caps}")
            pipe.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
            pipe.send({
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": {"textDocument": {"uri": uri, "languageId": "yak", "version": 1, "text": "//中😀"}},
            })
            diags = pipe.recv_diagnostics(uri, 1)
            require(len(diags) == 1 and diags[0]["code"] == "E1018", f"未报告 E1018：{diags}")
            pos = diags[0]["range"]["start"]
            require(pos == {"line": 0, "character": expected_col}, f"{expected_enc} 列不匹配：{pos}")
            pipe.send({
                "jsonrpc": "2.0",
                "method": "textDocument/didChange",
                "params": {
                    "textDocument": {"uri": uri, "version": 2},
                    "contentChanges": [{"range": {"start": pos, "end": pos}, "text": "\n"}],
                },
            })
            cleared = pipe.recv_diagnostics(uri, 2)
            require(cleared == [], f"{expected_enc} 增量补齐换行后未清空诊断：{cleared}")
            pipe.close()
        except Exception:
            if pipe.proc.poll() is None:
                pipe.proc.kill()
            raise


def check_p4_features(cmd: list[str]) -> None:
    pipe = LspPipe(cmd)
    try:
        root_uri = "file:///C:/YakP4"
        math_uri = "file:///C:/YakP4/math.yak"
        main_uri = "file:///C:/YakP4/main.yak"
        math_src = "export function add(a: u32, b: u32): u32 { return a + b; }\nexport const SCALE: u32 = 10u32;\n"

        pipe.send({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "rootUri": root_uri,
                "initializationOptions": {
                    "workspaceFiles": [{"uri": math_uri, "module": "math", "text": math_src}]
                },
                "capabilities": {
                    "textDocument": {"publishDiagnostics": {"versionSupport": True}},
                },
            },
        })
        init = pipe.recv_response(1)
        caps = init["result"]["capabilities"]
        require(caps["workspaceSymbolProvider"] is True, f"缺少工作区符号能力：{caps}")
        require(caps["documentFormattingProvider"] is True, f"缺少格式化能力：{caps}")
        require(caps["renameProvider"] == {"prepareProvider": True}, f"缺少重命名能力：{caps}")
        require(caps["codeActionProvider"] is True, f"缺少 CodeAction 能力：{caps}")
        require(caps["completionProvider"] == {"triggerCharacters": [".", ":"]}, f"缺少触发字符：{caps}")
        pipe.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

        # 1. $/cancelRequest 验证 -32800 Request cancelled
        pipe.send({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": 77}})
        pipe.send({"jsonrpc": "2.0", "id": 77, "method": "workspace/symbol", "params": {"query": "add"}})
        cancelled = pipe.recv_response(77)
        require(
            cancelled.get("error", {}).get("code") == -32800,
            f"取消请求未返回 -32800：{cancelled}",
        )

        # 2. 工作区符号查询（含未打开磁盘文件 math.yak）
        pipe.send({"jsonrpc": "2.0", "id": 2, "method": "workspace/symbol", "params": {"query": "ad"}})
        ws_res = pipe.recv_response(2)["result"]
        require(
            any(s["name"] == "add" and s["location"]["uri"] == math_uri for s in ws_res),
            f"workspace/symbol 未检索到 math::add：{ws_res}",
        )

        # 3. 打开 main.yak，先通过增量同步拼接，再验证跨文件定义/悬停与 `.`/`::` 补全
        initial_src = (
            "struct Point { x: u32, y: u32 }\n"
            "function use_point(p: Point): u32 {\n"
            "    let base: u32 = p.x;\n"
            "    if base > 0u32 {\n"
            "        let base: bool = true;\n"
            "        if base { return p.y; }\n"
            "    }\n"
            "    return base + math::add(p.x, p.y);\n"
            "}\n"
        )
        pipe.send({
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {"textDocument": {"uri": main_uri, "languageId": "yak", "version": 1, "text": initial_src}},
        })
        pipe.recv_diagnostics(main_uri, 1)

        # 增量同步：在第一行前插入一行注释，再将其删掉（多编辑批量）
        pipe.send({
            "jsonrpc": "2.0",
            "method": "textDocument/didChange",
            "params": {
                "textDocument": {"uri": main_uri, "version": 2},
                "contentChanges": [
                    {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}, "text": "// head\n"},
                    {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 1, "character": 0}}, "text": ""},
                ],
            },
        })
        pipe.recv_diagnostics(main_uri, 2)

        # 跨文件定义跳转与悬停（math::add）
        add_col = initial_src.splitlines()[7].index("add")
        pipe.send({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "textDocument/definition",
            "params": {"textDocument": {"uri": main_uri}, "position": {"line": 7, "character": add_col + 1}},
        })
        def_res = pipe.recv_response(3)["result"]
        require(def_res is not None and def_res["uri"] == math_uri, f"跨文件定义未跳转到 math.yak：{def_res}")

        pipe.send({
            "jsonrpc": "2.0",
            "id": 4,
            "method": "textDocument/hover",
            "params": {"textDocument": {"uri": main_uri}, "position": {"line": 7, "character": add_col + 1}},
        })
        hov_res = pipe.recv_response(4)["result"]
        require(hov_res is not None and "add" in hov_res["contents"]["value"], f"跨文件悬停缺失：{hov_res}")

        # `.` 结构体字段成员补全（p.x -> x, y）
        px_col = initial_src.splitlines()[2].index("p.x") + 2
        pipe.send({
            "jsonrpc": "2.0",
            "id": 5,
            "method": "textDocument/completion",
            "params": {"textDocument": {"uri": main_uri}, "position": {"line": 2, "character": px_col}},
        })
        dot_items = [it["label"] for it in pipe.recv_response(5)["result"]["items"]]
        require("x" in dot_items and "y" in dot_items, f"`.` 结构体字段补全缺失：{dot_items}")

        # `::` 工作区模块导出补全（math::add -> add, SCALE）
        pipe.send({
            "jsonrpc": "2.0",
            "id": 6,
            "method": "textDocument/completion",
            "params": {"textDocument": {"uri": main_uri}, "position": {"line": 7, "character": add_col}},
        })
        mod_items = [it["label"] for it in pipe.recv_response(6)["result"]["items"]]
        require("add" in mod_items and "SCALE" in mod_items, f"`::` 模块导出补全缺失：{mod_items}")

        # 4. 格式化与幂等性验证
        messy_uri = "file:///C:/YakP4/messy.yak"
        messy_src = "function f(): u32 {   \r\nreturn 1u32;\r\n\r\n\r\n}"
        pipe.send({
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {"textDocument": {"uri": messy_uri, "languageId": "yak", "version": 1, "text": messy_src}},
        })
        pipe.recv_diagnostics(messy_uri, 1)
        pipe.send({
            "jsonrpc": "2.0",
            "id": 7,
            "method": "textDocument/formatting",
            "params": {"textDocument": {"uri": messy_uri}, "options": {"tabSize": 4, "insertSpaces": True}},
        })
        fmt_edits = pipe.recv_response(7)["result"]
        require(len(fmt_edits) == 1, f"格式化未返回编辑：{fmt_edits}")
        formatted = fmt_edits[0]["newText"]
        require(formatted == "function f(): u32 {\n    return 1u32;\n\n}\n", f"格式化结果不符合预期：{formatted!r}")

        pipe.send({
            "jsonrpc": "2.0",
            "method": "textDocument/didChange",
            "params": {"textDocument": {"uri": messy_uri, "version": 2}, "contentChanges": [{"text": formatted}]},
        })
        pipe.recv_diagnostics(messy_uri, 2)
        pipe.send({
            "jsonrpc": "2.0",
            "id": 8,
            "method": "textDocument/formatting",
            "params": {"textDocument": {"uri": messy_uri}, "options": {"tabSize": 4, "insertSpaces": True}},
        })
        require(pipe.recv_response(8)["result"] == [], "二次格式化未满足幂等性")

        # 5. prepareRename / rename（正向 + 遮蔽隔离 + 关键字与冲突拒绝）
        ren_uri = "file:///C:/YakP4/rename.yak"
        ren_src = (
            "function demo(p: u32): u32 {\n"
            "    let val: u32 = p;\n"
            "    let other: u32 = 1u32;\n"
            "    if val > 0u32 {\n"
            "        let val: bool = true;\n"
            "        if val { return other; }\n"
            "    }\n"
            "    return val + other;\n"
            "}\n"
        )
        pipe.send({
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {"textDocument": {"uri": ren_uri, "languageId": "yak", "version": 1, "text": ren_src}},
        })
        require(pipe.recv_diagnostics(ren_uri, 1) == [], "rename 用例应无诊断错误")
        pipe.send({
            "jsonrpc": "2.0",
            "id": 9,
            "method": "textDocument/prepareRename",
            "params": {"textDocument": {"uri": ren_uri}, "position": {"line": 1, "character": 9}},
        })
        prep = pipe.recv_response(9)["result"]
        require(prep is not None and prep["placeholder"] == "val", f"prepareRename 异常：{prep}")

        pipe.send({
            "jsonrpc": "2.0",
            "id": 10,
            "method": "textDocument/rename",
            "params": {"textDocument": {"uri": ren_uri}, "position": {"line": 1, "character": 9}, "newName": "total"},
        })
        ren_res = pipe.recv_response(10)["result"]
        edits = ren_res["changes"][ren_uri]
        # 外层 val 共有 3 处（第 1、3、7 行），内层遮蔽的 val（第 4、5 行）不得被改写。
        lines = sorted(e["range"]["start"]["line"] for e in edits)
        require(lines == [1, 3, 7], f"rename 范围未保持 DefId 遮蔽隔离：{edits}")

        # 非法关键字与作用域冲突拒绝
        for req_id, bad_name in ((11, "if"), (12, "other")):
            pipe.send({
                "jsonrpc": "2.0",
                "id": req_id,
                "method": "textDocument/rename",
                "params": {"textDocument": {"uri": ren_uri}, "position": {"line": 1, "character": 9}, "newName": bad_name},
            })
            err = pipe.recv_response(req_id)
            require(err.get("error", {}).get("code") == -32602, f"rename 未拒绝 {bad_name}：{err}")

        # 6. codeAction：E1018、E4009、E6201 与 E4002 自动导入
        ca_uri = "file:///C:/YakP4/fix.yak"
        # E1018 缺少末尾换行
        pipe.send({
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {"textDocument": {"uri": ca_uri, "languageId": "yak", "version": 1, "text": "function f(): void {}"}},
        })
        e1018_diags = pipe.recv_diagnostics(ca_uri, 1)
        require(any(d["code"] == "E1018" for d in e1018_diags), f"未产生 E1018：{e1018_diags}")
        pipe.send({
            "jsonrpc": "2.0",
            "id": 13,
            "method": "textDocument/codeAction",
            "params": {
                "textDocument": {"uri": ca_uri},
                "range": e1018_diags[0]["range"],
                "context": {"diagnostics": e1018_diags},
            },
        })
        ca1 = pipe.recv_response(13)["result"]
        require(any("换行" in a["title"] for a in ca1), f"缺少 E1018 快速修复：{ca1}")

        # E4002 自动导入工作区模块
        auto_src = "function call(): u32 { return add(1u32, 2u32); }\n"
        pipe.send({
            "jsonrpc": "2.0",
            "method": "textDocument/didChange",
            "params": {"textDocument": {"uri": ca_uri, "version": 2}, "contentChanges": [{"text": auto_src}]},
        })
        e4002_diags = pipe.recv_diagnostics(ca_uri, 2)
        require(any(d["code"] == "E4002" for d in e4002_diags), f"未产生 E4002：{e4002_diags}")
        pipe.send({
            "jsonrpc": "2.0",
            "id": 14,
            "method": "textDocument/codeAction",
            "params": {
                "textDocument": {"uri": ca_uri},
                "range": e4002_diags[0]["range"],
                "context": {"diagnostics": e4002_diags},
            },
        })
        ca2 = pipe.recv_response(14)["result"]
        require(
            any("import math;" in a["edit"]["changes"][ca_uri][0]["newText"] for a in ca2),
            f"缺少 E4002 自动导入：{ca2}",
        )

        # E6201 非 Copy 值实参隐式移动快速修复（包裹 @move(...)）
        move_src = "function take(v: u32[]): void { @drop(v); }\nfunction move_fix(): void { let a: u32[] = [1u32]; take(a); }\n"
        pipe.send({
            "jsonrpc": "2.0",
            "method": "textDocument/didChange",
            "params": {"textDocument": {"uri": ca_uri, "version": 3}, "contentChanges": [{"text": move_src}]},
        })
        e6201_diags = pipe.recv_diagnostics(ca_uri, 3)
        require(any(d["code"] == "E6201" for d in e6201_diags), f"未产生 E6201：{e6201_diags}")
        e6201 = next(d for d in e6201_diags if d["code"] == "E6201")
        pipe.send({
            "jsonrpc": "2.0",
            "id": 15,
            "method": "textDocument/codeAction",
            "params": {
                "textDocument": {"uri": ca_uri},
                "range": e6201["range"],
                "context": {"diagnostics": e6201_diags},
            },
        })
        ca3 = pipe.recv_response(15)["result"]
        require(
            any("@move" in a["title"] and a["edit"]["changes"][ca_uri][0]["newText"] == "@move(a)" for a in ca3),
            f"缺少 E6201 快速修复：{ca3}",
        )

        # yak/workspaceFiles 实时同步更新新模块
        util_uri = "file:///C:/YakP4/util.yak"
        pipe.send({
            "jsonrpc": "2.0",
            "method": "yak/workspaceFiles",
            "params": {
                "files": [{"uri": util_uri, "module": "util", "text": "export function helper(): u32 { return 7u32; }\n"}]
            },
        })
        pipe.send({"jsonrpc": "2.0", "id": 17, "method": "workspace/symbol", "params": {"query": "helper"}})
        ws2 = pipe.recv_response(17)["result"]
        require(
            any(s["name"] == "helper" and s["location"]["uri"] == util_uri for s in ws2),
            f"yak/workspaceFiles 未同步 util::helper：{ws2}",
        )

        pipe.close()
    except Exception:
        if pipe.proc.poll() is None:
            pipe.proc.kill()
        raise


def main() -> int:
    if len(sys.argv) < 2:
        print("用法：python test/gate/lsp_p4_check.py <yak_lsp.exe | seed 命令...>", file=sys.stderr)
        return 2
    cmd = sys.argv[1:]
    if len(cmd) == 1 and not Path(cmd[0]).is_file():
        print(f"找不到可执行文件：{cmd[0]}", file=sys.stderr)
        return 2
    check_encodings(cmd)
    check_p4_features(cmd)
    print(f"P4 定向协议验证全部通过：{' '.join(cmd)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
