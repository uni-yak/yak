"""通过真实二进制管道检验 Yak 分帧与握手探针。"""

import argparse
import json
from pathlib import Path
from queue import Empty, Queue
import subprocess
import sys
from threading import Thread
from time import monotonic


def wire(body: bytes) -> bytes:
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


# 精确比较序列化字节；字段顺序与候选的线协议一致。
def candidate_capabilities(encoding="utf-16"):
    return {
        "positionEncoding": encoding,
        "textDocumentSync": {"openClose": True, "change": 2},
        "definitionProvider": True,
        "hoverProvider": True,
        "completionProvider": {"triggerCharacters": [".", ":"]},
        "semanticTokensProvider": {
            "legend": {"tokenTypes": ["keyword", "string", "number", "operator"], "tokenModifiers": []},
            "full": True,
        },
        "documentSymbolProvider": True,
        "foldingRangeProvider": True,
        "documentFormattingProvider": True,
        "renameProvider": {"prepareProvider": True},
        "codeActionProvider": True,
        "workspaceSymbolProvider": True,
    }


def position_encoding_exchange(send, receive, quiet, *, offered, encoding, column, emoji_units):
    def encoded(**fields):
        return wire(json.dumps({"jsonrpc": "2.0", **fields}, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    def extent(line, character):
        point = {"line": line, "character": character}
        return {"start": point, "end": point}

    def publication(version, diagnostics):
        return encoded(method="textDocument/publishDiagnostics", params={"uri": uri, "version": version, "diagnostics": diagnostics})

    def missing_lf(character):
        return [{"range": extent(0, character), "severity": 1, "source": "yak", "code": "E1018",
                 "message": "Yak 词法诊断 E1018"}]

    def change(version, *changes):
        return encoded(method="textDocument/didChange", params={
            "textDocument": {**doc, "version": version}, "contentChanges": list(changes),
        })

    uri = "file:///C:/Yak/position-encoding.yak"
    doc = {"uri": uri}
    send(encoded(id=1, method="initialize", params={"capabilities": {
        "general": {"positionEncodings": offered},
        "textDocument": {"publishDiagnostics": {"versionSupport": True}},
    }}))
    receive(encoded(id=1, result={"capabilities": candidate_capabilities(encoding)}), "按客户端偏好协商 " + encoding)
    send(encoded(method="initialized") + encoded(method="textDocument/didOpen", params={"textDocument": {
        **doc, "languageId": "yak", "version": 1, "text": "//中😀",
    }}))
    receive(publication(1, missing_lf(column)), "末尾诊断列使用 " + encoding)
    send(change(2, {"text": "//bad"}, {"range": extent(9, 0), "text": "!"}))
    quiet("后项坐标无效时整批不提交、不发送诊断")
    send(change(2, {"range": extent(0, column), "text": "\n//😀"},
                {"range": extent(1, 2 + emoji_units), "text": "\n"}))
    receive(publication(2, []), "同版本重试，第二项定位到第一项插入的行")
    send(change(3, {"text": "//😀"}))
    receive(publication(3, missing_lf(2 + emoji_units)), "增量会话仍支持全量替换")
    send(encoded(id=2, method="shutdown"))
    receive(encoded(id=2, result=None), "关闭编码探针")
    send(encoded(method="exit"))
    return 0


def cancellation_exchange(send, receive, quiet) -> int:
    def encoded(**fields):
        return wire(json.dumps({"jsonrpc": "2.0", **fields}, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    def symbol(request_id):
        return encoded(id=request_id, method="workspace/symbol", params={"query": "missing"})

    send(encoded(id=1, method="initialize", params={}))
    receive(encoded(id=1, result={"capabilities": candidate_capabilities()}), "取消请求探针握手")
    send(encoded(method="initialized"))
    for target, other in ((77, "77"), ("77", 77)):
        send(encoded(method="$/cancelRequest", params={"id": target}))
        quiet("取消通知本身不发送响应")
        send(symbol(other) + symbol(target))
        receive(encoded(id=other, result=[]), "数值与字符串请求编号互不影响")
        receive(encoded(id=target, error={"code": -32800, "message": "Request cancelled"}), "仅匹配的请求返回取消错误")
        send(symbol(target))
        receive(encoded(id=target, result=[]), "同一编号后续正常请求不受影响")
    send(encoded(id=2, method="shutdown"))
    receive(encoded(id=2, result=None), "取消请求后可以正常关闭")
    send(encoded(method="exit"))
    return 0


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def next_byte(events: Queue, deadline: float, phase: str) -> bytes:
    try:
        return events.get(timeout=deadline)
    except Empty:
        raise RuntimeError(f"{phase}：在 {deadline:g} 秒内未读到输出") from None


def open_pipe(command: list[str], exercise, *, on_start=None, timeout=5) -> None:
    events: Queue = Queue()
    input_frames: Queue = Queue()
    writes: Queue = Queue()
    stderr = bytearray()
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, bufsize=0)
    assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None

    def read_output() -> None:
        try:
            while byte := proc.stdout.read(1):
                events.put(byte)
        finally:
            events.put(b"")

    def read_error() -> None:
        while chunk := proc.stderr.read(4096):
            # 持续排空以免阻塞探针，但只保留有界的失败证据。
            stderr.extend(chunk[:4096 - len(stderr)])

    def write_input() -> None:
        while (data := input_frames.get()) is not None:
            try:
                pending = memoryview(data)
                while pending:
                    count = proc.stdin.write(pending)
                    require(count is not None and count > 0, "管道输入未完整写入")
                    pending = pending[count:]
                writes.put(None)
            except (RuntimeError, OSError) as exc:
                writes.put(exc)
                return

    workers = [(Thread(target=target, daemon=True), stream) for target, stream in
               [(read_output, proc.stdout), (read_error, proc.stderr), (write_input, proc.stdin)]]
    for worker, _ in workers:
        worker.start()

    def send(data: bytes) -> None:
        input_frames.put(data)
        try:
            failure = writes.get(timeout=timeout)
        except Empty:
            raise RuntimeError(f"在 {timeout:g} 秒内未写完 {len(data)} 字节管道输入") from None
        if failure is not None:
            raise failure

    def receive(expected: bytes, phase: str) -> None:
        deadline = monotonic() + timeout
        for pos, want in enumerate(expected):
            got = next_byte(events, max(0, deadline - monotonic()), phase)
            if got != bytes((want,)):
                # 保留有界的已缓冲响应以区分诊断、降级及分帧失败。
                preview = bytearray(got)
                while len(preview) < 512:
                    try:
                        following = events.get(timeout=0.02)
                    except Empty:
                        break
                    if not following:
                        break
                    preview += following
                raise RuntimeError(f"{phase}：第 {pos} 字节应为 {want:#04x}，实际响应后缀：{preview.decode('utf-8', errors='replace')!r}")

    def quiet(phase: str) -> None:
        try:
            early = events.get(timeout=0.2)
        except Empty:
            return
        raise RuntimeError(f"{phase}：提前输出或退出：{early!r}")

    failure = None
    try:
        if on_start is not None:
            on_start(proc)
        code = exercise(send, receive, quiet)
        actual = proc.wait(timeout=timeout)
        require(actual == code, f"探针退出 {actual}，预期 {code}")
        require(next_byte(events, timeout, "探针退出") == b"", "退出后仍有额外输出")
        error_reader = workers[1][0]
        error_reader.join(timeout=timeout)
        require(not error_reader.is_alive(), "探针退出后标准错误未关闭")
        require(not stderr, "协议退出出现标准错误输出")
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        failure = exc
    finally:
        # 夹具本身抛出异常时也先结束探针，不能等待仍在读下一帧的子进程。
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=timeout)
        input_frames.put(None)
        deadline = monotonic() + timeout
        for worker, stream in workers:
            worker.join(timeout=max(0, deadline - monotonic()))
            if not worker.is_alive():
                stream.close()
    if failure is not None:
        raise RuntimeError(f"{failure}；退出 {proc.returncode}；标准错误 {bytes(stderr)!r}") from failure


def frame_exchange(send, receive, quiet) -> int:
    body = '{"text":"汉字😀"}'.encode("utf-8")
    send(b"cOnTeNt-LeNgTh: %d\r\nX-Test: 1\r\n\r\n{" % len(body))
    quiet("分片正文未收齐")
    send(body[1:])
    receive(wire(body), "分片正文")
    frames = wire(b"{}") + wire(b"[]")
    send(frames)
    receive(frames, "连续帧")
    long_frame = wire(bytes(range(256)) * 16 + b"Z")
    send(long_frame)
    receive(long_frame, "跨暂存块的二进制正文")
    # 零长帧仅用于回显探针主动退出，不是有效 JSON 消息。
    send(wire(b""))
    receive(wire(b""), "零长帧")
    return 0


def rpc_exchange(send, receive, quiet) -> int:
    prefix = b'{"jsonrpc":"2.0","id":'
    request = wire(prefix + b'-0,"method":"unknown"}')
    parse_error = wire(prefix + b'null,"error":{"code":-32700,"message":"Parse error"}}')
    not_ready = wire(prefix + b'-0,"error":{"code":-32002,"message":"Server not initialized"}}')
    send(request)
    receive(not_ready, "初始化前请求")
    raw_id = r'"汉😀\u0061"'.encode("utf-8")
    packet = wire(prefix + raw_id + b',"method":"initialize","params":{"capabilities":{}}}')
    cut = packet.index("😀".encode("utf-8")) + 1
    send(packet[:cut])
    quiet("初始化正文在 UTF-8 标量中间分片")
    send(packet[cut:])
    receive(wire(prefix + raw_id + b',"result":{"capabilities":{}}}'), "开放管道握手")
    send(request)
    receive(not_ready, "等待 initialized")
    initialized = wire(b'{"jsonrpc":"2.0","method":"initialized","params":{}}')
    ignored = wire(b'{"jsonrpc":"2.0","method":"unknown"}')
    send(initialized + ignored)
    quiet("有效通知静默")
    send(wire(b'{') + wire(b'') + request)
    unknown = wire(prefix + b'-0,"error":{"code":-32601,"message":"Method not found"}}')
    receive(parse_error + parse_error + unknown, "坏 JSON 与零长帧后恢复")
    shutdown = wire(prefix + b'2147483647,"method":"shutdown"}')
    send(shutdown + request)
    closed = wire(prefix + b'-0,"error":{"code":-32600,"message":"Invalid Request"}}')
    receive(wire(prefix + b'2147483647,"result":null}') + closed, "关闭及关闭后拒绝")
    send(wire(b'{"jsonrpc":"2.0","method":"exit"}'))
    return 0


def sync_exchange(send, receive, quiet) -> int:
    # 探针内部按帧断言快照与事件，线上只核对标准请求响应。
    prefix = b'{"jsonrpc":"2.0","id":'
    uri = "file:///C:/Yak%20Work/中.yak"
    item = {"uri": uri}

    def notice(method: str, params) -> bytes:
        obj = {"jsonrpc": "2.0", "method": f"textDocument/{method}", "params": params}
        return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    def opened(text: str, version: int) -> bytes:
        return notice("didOpen", {"textDocument": {**item, "languageId": "yak", "text": text, "version": version}})

    def changed(version: int, change: dict) -> bytes:
        return notice("didChange", {"textDocument": {**item, "version": version}, "contentChanges": [change]})

    initial = wire(opened("ok\n", -1))
    send(initial + wire(prefix + b'1,"method":"initialize","params":{}}'))
    receive(wire(prefix + b'1,"result":{"capabilities":{}}}'), "初始化前文档通知静默")
    send(initial + wire(b'{"jsonrpc":"2.0","method":"initialized"}') + initial)
    quiet("等待初始化时不更新；运行态打开不返回响应")
    send(wire(opened("bad", 9)) + wire(changed(-1, {"text": "old"}))
         + wire(changed(0, {"text": "increment", "range": None})) + wire(changed(0, {"text": "123456789"})))
    quiet("重复打开、倒退版本、增量和超预算通知静默")
    packet = wire(changed(1, {"text": "中😀\n"}).replace(b"didChange", br"didCh\u0061nge"))
    cut = packet.index("😀".encode("utf-8")) + 1
    send(packet[:cut])
    quiet("全量变更在非 BMP 标量中间分片")
    send(packet[cut:] + wire(prefix + b'2,"method":"textDocument/didClose","params":{}}'))
    receive(wire(prefix + b'2,"error":{"code":-32601,"message":"Method not found"}}'), "同名请求不得关闭文档")
    close = wire(notice("didClose", {"textDocument": item}))
    send(wire(notice("didClose", [])) + close + wire(opened("z\n", -1)))
    quiet("错误参数不提交，关闭和重开不返回响应")
    send(wire(prefix + b'3,"method":"shutdown"}') + close)
    receive(wire(prefix + b'3,"result":null}'), "关闭服务")
    quiet("已关闭状态忽略文档通知")
    send(wire(b'{"jsonrpc":"2.0","method":"exit"}'))
    return 0


def diagnostics_exchange(send, receive, quiet, capability="true", *, candidate=False, borrow_conflicts=False, place_merges=False, slice_assignments=False, place_lookups=False, place_exits=False, slot_jumps=False, slice_jumps=False, name_lookups=False, reservations=False, enum_lookups=False, reference_outputs=False, value_graphs=False, formal_layouts=False, decl_interns=False, body_interns=False, lex_interns=False, const_snapshots=False, const_inits=False, const_materials=False, const_folds=False, integer_probes=False, integer_scans=False, integer_shapes=False, array_inferences=False, ctor_fields=False, match_scans=False, match_paths=False, parse_recoveries=False, out_refs=False, projections=False, equalities=False, slice_budget=None, semantic_exchange=None) -> int:
    versions = capability == "true"
    uri = "file:///C:/Yak%20Work/中.yak"

    def packet(method, params=None, identifier=None):
        obj = {"jsonrpc": "2.0"}
        if identifier is not None:
            obj["id"] = identifier
        obj["method"] = method
        if params is not None:
            obj["params"] = params
        return encoded(obj)

    def encoded(obj):
        return wire(json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    def opened(src, version):
        return packet("textDocument/didOpen", {"textDocument": {
            "uri": uri, "languageId": "yak", "text": src, "version": version}})

    def changed(src, version):
        return packet("textDocument/didChange", {"textDocument": {"uri": uri, "version": version},
                                                "contentChanges": [{"text": src}]})

    def publication(version, diagnostics=None):
        params = {"uri": uri}
        if versions and version is not None:
            params["version"] = version
        params["diagnostics"] = diagnostics or []
        return packet("textDocument/publishDiagnostics", params)

    def log(message):
        return packet("window/logMessage", {"type": 2, "message": message})

    def eof(column):
        point = {"line": 0, "character": column}
        return [{"range": {"start": point, "end": point}, "severity": 1, "source": "yak",
                 "code": "E1018", "message": "Yak 词法诊断 E1018"}]

    # 保留既有诊断夹具的 UTF-16 坐标；其他编码另有独立交换。
    init = b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
    if candidate and capability == "true":
        send(packet("initialize", {"processId": None, "rootUri": None, "workspaceFolders": None,
                                   "clientInfo": {"name": "管道回归", "version": "1"},
                                   "capabilities": {"general": {"positionEncodings": ["utf-16", "utf-8"]},
                                                    "textDocument": {"publishDiagnostics": {"versionSupport": True}}}},
                    identifier=1))
    elif capability == "missing":
        send(wire(init + b'{}}'))
    else:
        # 直接写能力对象的原始字段，以便核对转义后的重复键。
        field = {
            "true": b'"versionSupport":true',
            "false": b'"versionSupport":false',
            "string": b'"versionSupport":"true"',
            "duplicate": br'"versionSupport":true,"version\u0053upport":true',
        }[capability]
        send(wire(init + b'{"capabilities":{"textDocument":{"publishDiagnostics":{' + field + b'}}}}}'))
    advertised = candidate_capabilities() if candidate else {}
    receive(encoded({"jsonrpc": "2.0", "id": 1, "result": {"capabilities": advertised}}), "诊断握手及能力精确声明")
    send(packet("initialized") + opened("//中😀", -2147483648))
    receive(publication(-2147483648, eof(5)), "原始 UTF-8 文本上的 EOF 零宽诊断")
    if candidate:
        send(packet("textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 1}},
                    identifier="hover"))
        receive(encoded({"jsonrpc": "2.0", "id": "hover", "result": None}), "错误版不返回悬停")
        send(packet("textDocument/references", {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 1}},
                    identifier="references"))
        receive(encoded({"jsonrpc": "2.0", "id": "references", "error": {"code": -32601,
                                                                           "message": "Method not found"}}),
                "未实现的引用查询仍被拒绝")
    send(changed("function f(): void {}\n", 0))
    receive(publication(0), "未保存修正清空原错误")
    error = "function bad(x: u32[]): void { @drop(x); @drop(x); }\n"
    if reservations:
        def members(n):
            return ", ".join(f"V{i:02d}" for i in range(n))

        # 90 个成员查重 4005 次，12 个模块绑定查重 66 次，四个形参查重 6 次。
        # 排序比较 19 次：15 个后续绑定各比较一次，末函数另外越过四个形参。
        exact = (f"enum E {{ {members(90)} }}\n" + "".join(f"function f{i}(): void {{}}\n" for i in range(9))
                 + "function f(a: bool, b: bool, c: bool, d: bool): void { if a {} if b {} if c {} if d {} }\nfunction tail(): void {}\n")
        wide = f"enum E {{ {members(91)} }}\n"
        limit = log("Yak: 声明预留超出上限，分析不完整")
        send(changed(exact, 1))
        receive(publication(1), "4096 次预留比较恰好完成全前端分析")
        # 91 个成员查重 4095 次，第二个模块声明消耗一步。
        for version, src, stage in (
            (2, wide + "function f(x: bool, y: bool): void {}\n", "同域形参绑定查重"),
            (3, wide + "function f(): void {}\n", "排序比较"),
            (4, f"enum E {{ {members(91)}, V00, V00 }}\n", "已有重名诊断的成员查重"),
        ):
            send(changed(src, version))
            receive(limit, f"{stage}第 4097 步前报告不完整")
            receive(publication(version), "不发布局部重名诊断，只清空当前版本")
        duplicate = "enum E { V00, V00 }\n"
        col = duplicate.rindex("V00")
        send(changed(duplicate, 5))
        receive(publication(5, [{"range": {"start": {"line": 0, "character": col},
                                            "end": {"line": 0, "character": col + len("V00")}},
                                 "severity": 1, "source": "yak", "code": "E5803",
                                 "message": "Yak 类型或布局诊断 E5803"}]), "预算内仍发布真实枚举成员重名")
        send(changed(exact, 6))
        receive(publication(6), "修正重名并回到精确边界后清空")
    elif name_lookups:
        def lookup_source(tail_depth: int, extra: bool = False, first: str = "x") -> str:
            tail = "if x {} " + "} " * tail_depth + ("if x {} " if extra else "")
            return ("function f(x: bool): void { " + "while false { " * 30
                    + f"if {first} {{}} " + "if x {} " * 126 + "} " * (30 - tail_depth) + tail + "}\n")

        # 两个签名内置类型各用两步；30 层内每次查找 x 用 31 帧加一次比较。
        # 收尾一次查找用 26+2 步；少一层时余一步，恰好访问最后一个作用域。
        lookup_exact = lookup_source(26)
        lookup_limit = log("Yak: 名称查找超出上限，分析不完整")
        send(changed(lookup_exact, 1))
        receive(publication(1), "恰好访问 4096 个作用域和绑定行，完成分析")
        for version, src, stage in (
            (2, lookup_source(26, True), "作用域读取"),
            (3, lookup_source(25, True), "绑定二分比较"),
            (4, lookup_source(26, True, "missing"), "已收集局部名称错误后的查找"),
        ):
            send(changed(src, version))
            receive(lookup_limit, f"{stage}超限时先报告不完整")
            receive(publication(version), "名称查找超限只清空本版，不发布局部错误")
        bad_name = "function f(): void { if missing {} }\n"
        col = bad_name.index("missing")
        send(changed(bad_name, 5))
        receive(publication(5, [{"range": {"start": {"line": 0, "character": col},
                                            "end": {"line": 0, "character": col + 7}},
                                 "severity": 1, "source": "yak", "code": "E4002",
                                 "message": "Yak 名称诊断 E4002"}]), "新版本重新计费并保留真实名称未定义")
        send(changed(lookup_exact, 6))
        receive(publication(6), "修正后恢复完整分析并清空旧诊断")
    elif place_lookups:
        def drops(name: str, n: int) -> str:
            args = ", ".join(f"a{i}: bool" for i in range(n))
            body = "".join(f"@drop(a{i}); " for i in range(n))
            return f"function {name}({args}): void {{ {body}}}\n"

        # n 个形参插入代价为 n(n-1)/2，逐个析构为 4×n(n+1)/2。
        # 两函数分别为 7924、265 行；末尾读取 3 行，析构则要 4 行。
        lookup_base = drops("wide", 56) + drops("narrow", 10)
        lookup_exact = lookup_base + "function tail(x: bool): bool { return x; }\n"
        lookup_over = lookup_base + "function tail(x: bool): void { @drop(x); }\n"
        lookup_limit = log("Yak: 所有权位置表查找超出上限，分析不完整")
        send(changed(lookup_exact, 1))
        receive(publication(1), "跨函数恰好比较 8192 行时完成所有权检查")
        send(changed(lookup_over, 2))
        receive(lookup_limit, "析构写回前第 8193 行查找超限")
        receive(publication(2), "位置表查找超限清空当前版本")
        send(changed(error + lookup_over, 3))
        receive(lookup_limit, "已记录所有权诊断时报告位置查找不完整")
        receive(publication(3), "查找超限不发布先前的局部诊断")
        send(changed(lookup_exact, 4))
        receive(publication(4), "缩短新快照后恢复完整检查")
    elif place_exits:
        def exit_probe(name: str, count: int, repeats: int, drop_first: bool = False) -> str:
            args = ", ".join(f"a{i}: bool" for i in range(count))
            before = "@drop(a0); " if drop_first else ""
            after = "".join(f"@drop(a{i}); " for i in range(int(drop_first), count))
            return f"function {name}({args}): void {{ " + before + "while false {} " * repeats + after + "}\n"

        # 死循环体检查从第零行开始；活位置的父链为函数域和模块域，已析构位置只计一行。
        exit_wide = exit_probe("wide", 32, 42)
        exit_exact = exit_wide + exit_probe("tail", 22, 1, drop_first=True)
        exit_over = exit_exact + exit_probe("extra", 1, 1, drop_first=True)
        exit_parent = exit_wide + exit_probe("tail", 21, 1) + exit_probe("extra", 1, 1)
        exit_limit = log("Yak: 所有权位置离块清理超出上限，分析不完整")
        send(changed(exit_exact, 1))
        receive(publication(1), "跨函数清理 4032 + 64 步时完成分析")
        send(changed(exit_over, 2))
        receive(exit_limit, "第 4097 个候选位置读取之前降级")
        receive(publication(2), "离块配额超限清空当前版本")
        send(changed(error + exit_over, 3))
        receive(exit_limit, "先前已产生所有权错误仍报告离块清理不完整")
        receive(publication(3), "离块清理超限不发布先前局部错误")
        send(changed(exit_parent, 4))
        receive(exit_limit, "剩余一步恰好扫描候选，访问第一个非零作用域之前降级")
        receive(publication(4), "作用域父链超限也清空当前版本")
        send(changed(exit_exact, 5))
        receive(publication(5), "新版本重新计量并恢复完整检查")
    elif slice_jumps:
        def slice_probe(count: int) -> str:
            return "".join(f"function plain{i}(): void {{ " + "while true { break; } " * n + "}\n"
                           for i, n in enumerate((84, 84, count - 168)))

        # 双层标签跳转计两个目标帧、一次记录写入、一次内层转交和一次外层收集。
        labeled = ("function labeled(): void { let a: [u8; 1] = [1u8]; "
                   "let v: &[u8] = &a[0..1]:Read; outer: while true { while true { break outer; } } "
                   "let n: u64 = @len(v); @drop(n); }\n")
        exact = slice_probe(251) + labeled
        one_more = exact + "function extra(): void { while true { break; } }\n"
        limit = log("Yak: 切片借用跳转超出上限，分析不完整")
        send(changed(exact, 1))
        receive(publication(1), "跨函数恰好 256 步，含带标签的切片借用转交")
        for version, src, stage in (
            (2, one_more, "读取目标循环"),
            (3, error + one_more, "已有局部诊断时读取目标循环"),
            (4, slice_probe(254) + labeled, "写入借用记录"),
            (5, slice_probe(253) + labeled, "读取内层转交记录"),
            (6, slice_probe(252) + labeled, "读取外层收集记录"),
        ):
            send(changed(src, version))
            receive(limit, f"第 257 步在{stage}前报告分析不完整")
            receive(publication(version), "超限清空该版本，不发布半成品诊断")
        send(changed(exact, 7))
        receive(publication(7), "改版重新计费并恢复完整检查")
    elif slot_jumps:
        def slot_probe(name: str, count: int, repeat: int = 1) -> str:
            args = ", ".join(f"a{i}: bool" for i in range(count))
            drops = "".join(f"@drop(a{i}); " for i in range(count))
            return f"function {name}({args}): void {{ " + "while true { break; } " * repeat + drops + "}\n"

        # 普通边计目标、每行位置、结束标记写入和归并；外层标签转交含一个已填充的槽位。
        labeled = ("function fill(x: &u32:Write): void { *x = 1u32; }\n"
                   "function labeled(): void { out r: u32; fill(out r); "
                   "outer: while true { while true { break outer; } } }\n")
        slot_base = slot_probe("wide", 9, 84) + labeled
        slot_exact = slot_base + slot_probe("tail", 3)
        slot_over = slot_exact + slot_probe("extra", 0)
        slot_limit = log("Yak: 输出槽位跳转超出上限，分析不完整")
        send(changed(slot_exact, 1))
        receive(publication(1), "跨函数恰好 1024 步，含带标签的槽位转交")
        send(changed(slot_over, 2))
        receive(slot_limit, "第 1025 步在读取目标循环前降级")
        receive(publication(2), "目标查找超限清空当前版本")
        send(changed(error + slot_over, 3))
        receive(slot_limit, "保留先前局部错误前报告跳转分析不完整")
        receive(publication(3), "超限后不发布先前的局部错误")
        send(changed(slot_base + slot_probe("tail", 2) + slot_probe("extra", 0), 4))
        receive(slot_limit, "写入结束标记之前降级")
        receive(publication(4), "记录超限清空当前版本")
        send(changed(slot_base + slot_probe("tail", 1) + slot_probe("extra", 0), 5))
        receive(slot_limit, "读取归并记录之前降级")
        receive(publication(5), "归并记录超限清空当前版本")
        send(changed(slot_exact, 6))
        receive(publication(6), "改版重新计费并恢复完整检查")
    elif place_merges:
        # 每个普通 if 含六次整表遍历；宽函数累计 21 × 6 × 32 = 4032 行。
        merge_base = ("function wide(b: bool): void { "
                      + "".join(f"let v{i}: u32 = 1; " for i in range(31))
                      + "if b {} " * 21
                      + "".join(f"@drop(v{i}); " for i in range(31))
                      + "}\nfunction tail(b: bool): void { " + "if b && true {} " * 7)
        # 尾函数每个 if 再含两次动态短路合流；不可达右侧仅合流普通位置。
        merge_exact = merge_base + "if b && true {} }\n"
        merge_over = merge_base + "if b && (true || (b && true)) {} }\n"
        send(changed(merge_exact, 1))
        receive(publication(1), "跨函数位置合流恰好走访 4096 行")
        merge_limit = log("Yak: 所有权位置表合流超出上限，分析不完整")
        send(changed(merge_over, 2))
        receive(merge_limit, "不可达短路多计一行导致位置合流中止")
        receive(publication(2), "位置合流超限只清空当前版本")
        send(changed(error + merge_over, 3))
        receive(merge_limit, "已有所有权错误时仍报告位置合流超限")
        receive(publication(3), "位置合流超限不发布先前的局部错误")
        send(changed(merge_exact, 4))
        receive(publication(4), "位置合流超限后随新版本重新分析")
    elif borrow_conflicts:
        # 35 个借用绑定共 595 次独占比较和 34 次共享命中。
        conflict_base = ("function use(v: &[u8]): void { let n: u64 = @len(v); @drop(n); }\n"
                         "function wide(): void { let a: [u8; 1] = [1u8]; "
                         + "".join(f"let v{i}: &[u8] = &a[0..1]:Read; " for i in range(35))
                         + "".join(f"use(v{i}); " for i in range(35)) + "use(v0); " * 14 + "}\n"
                         "function tail(): void { let a: [u8; 1] = [1u8]; let v: &[u8] = &a[0..1]:Read; ")
        # 普通切片实参先读位置再登记调用视图，每次各扫一遍借用表。宽函数共 629 + 49 × 70 = 4059 行。
        # 尾函数的 18 次调用各扫两行，@len 每次只读取一行。
        tail = "use(v); " * 18 + "@len(v); "
        conflict_exact = conflict_base + tail + "}\n"
        conflict_over = conflict_base + tail + "@len(v); }\n"
        send(changed(conflict_exact, 1))
        receive(publication(1), "跨函数借用冲突查询恰好比较 4096 行")
        conflict_limit = log("Yak: 借用冲突查询超出上限，分析不完整")
        send(changed(conflict_over, 2))
        receive(conflict_limit, "第 4097 个借用行读取前明确中止")
        receive(publication(2), "冲突查询超限只清空当前版本")
        send(changed(error + conflict_over, 3))
        receive(conflict_limit, "已有所有权错误时仍报告冲突查询超限")
        receive(publication(3), "冲突查询超限不发布先前的局部错误")
        send(changed(conflict_exact, 4))
        receive(publication(4), "冲突查询超限后随新版本重新分析")
    elif slice_assignments:
        # 15 次直接绑定共 240 步；82 次源绑定赋值各扫三遍表、检查根及本级域，共 3854 步。
        # 用 @len 读取各绑定以避免额外的调用视图扫描先耗尽独立的冲突查询额度。
        assign_base = ("function use(v: &[u8]): void { let n: u64 = @len(v); @drop(n); }\n"
                       "function wide(): void { let a: [u8; 1] = [1u8]; "
                       + "".join(f"var v{i}: &[u8] = &a[0..1]:Read; " for i in range(15))
                       + "v0 = v1; " * 82 + "".join(f"@len(v{i}); " for i in range(15)) + "}\n"
                       "function tail(): void { let a: [u8; 1] = [1u8]; ")
        # 末尾绑定的根与本级域耗两步；把绑定移进子块只增加一次父链访问。
        assign_tail = "let v: &[u8] = &a[0..1]:Read; use(v); "
        assign_exact = assign_base + assign_tail + "}\n"
        assign_over = assign_base + "if true { " + assign_tail + "} }\n"
        send(changed(assign_exact, 1))
        receive(publication(1), "跨函数切片赋值恰好 4096 步")
        assign_limit = log("Yak: 切片借用赋值超出上限，分析不完整")
        send(changed(assign_over, 2))
        receive(assign_limit, "第 4097 步父链访问前明确中止")
        receive(publication(2), "切片赋值超限只清空当前版本")
        send(changed(error + assign_over, 3))
        receive(assign_limit, "已有所有权错误时仍报告切片赋值超限")
        receive(publication(3), "赋值超限不发布先前的局部错误")
        send(changed(assign_exact, 4))
        receive(publication(4), "切片赋值超限后随新版本重新分析")
    elif enum_lookups: enum_lookup_exchange(send, receive, changed, publication, log)
    elif reference_outputs: reference_output_exchange(send, receive, changed, publication, log)
    elif value_graphs: value_graph_exchange(send, receive, changed, publication, log)
    elif formal_layouts: formal_layout_exchange(send, receive, changed, publication, log)
    elif decl_interns: decl_intern_exchange(send, receive, changed, publication, log)
    elif const_snapshots: const_snapshot_exchange(send, receive, changed, publication, log)
    elif body_interns: body_intern_exchange(send, receive, changed, publication, log)
    elif lex_interns: lex_intern_exchange(send, receive, changed, publication, log)
    elif const_inits: const_init_exchange(send, receive, changed, publication, log)
    elif const_materials: const_material_exchange(send, receive, changed, publication, log)
    elif const_folds: const_fold_exchange(send, receive, changed, publication, log)
    elif integer_probes: integer_probe_exchange(send, receive, changed, publication, log)
    elif integer_scans: integer_scan_exchange(send, receive, changed, publication, log)
    elif integer_shapes: integer_shape_exchange(send, receive, changed, publication, log)
    elif array_inferences: array_inference_exchange(send, receive, changed, publication, log)
    elif ctor_fields: ctor_fields_exchange(send, receive, changed, publication, log)
    elif match_scans: match_scan_exchange(send, receive, changed, publication, log)
    elif match_paths: match_path_exchange(send, receive, changed, publication, log)
    elif parse_recoveries: parse_recovery_exchange(send, receive, changed, publication, log)
    elif out_refs: out_ref_exchange(send, receive, changed, publication, log)
    elif projections: projection_exchange(send, receive, changed, publication, log)
    elif equalities: equality_exchange(send, receive, changed, publication, log)
    elif slice_budget is not None:
        slice_budget_exchange(send, receive, changed, publication, log, error, group=slice_budget)
    elif semantic_exchange is not None:
        semantic_exchange(send, receive, changed, publication, log)
    elif versions:
        send(changed("// stale", -1))
        quiet("倒退版本不发布")
        send(changed("import missing;\n", 1))
        receive(log("Yak: 缺少可信依赖，诊断分析不完整") + publication(1), "无可信依赖不伪造错误")
        send(changed("x" * 16385, 2))
        receive(log("Yak: 源码超出候选分析字节上限，未执行前端") + publication(2), "超限明确降级")
        send(changed("//x", 3))
        receive(publication(3, eof(3)), "降级后可以继续分析")
        text = "function f(): void { return missing; }\n"
        begin = text.index("missing")
        missing = [{"range": {"start": {"line": 0, "character": begin},
                              "end": {"line": 0, "character": begin + 7}},
                    "severity": 1, "source": "yak", "code": "E4002", "message": "Yak 名称诊断 E4002"}]
        send(changed(text, 4))
        receive(publication(4, missing), "真实名称诊断保留范围与错误码")
        flooded = "".join(f"function f{i:02}(): void {{ return missing; }}\n" for i in range(65))
        column = flooded.index("missing")
        retained = [dict(missing[0], range={"start": {"line": i, "character": column},
                                            "end": {"line": i, "character": column + 7}}) for i in range(16)]
        send(changed(flooded, 5))
        receive(log("Yak: 前端诊断收集超出上限，分析不完整") + publication(5, retained), "名称洪泛有界并保留真实顺序")
        parse_flood = "; function f(): void {}\n" * 65
        syntax = [{"range": {"start": {"line": i, "character": 0}, "end": {"line": i, "character": 1}},
                   "severity": 1, "source": "yak", "code": "E2001", "message": "Yak 解析诊断 E2001"}
                  for i in range(16)]
        send(changed(parse_flood, 6))
        receive(log("Yak: 前端诊断收集超出上限，分析不完整") + publication(6, syntax), "解析洪泛有界并保留真实顺序")
        unreachable = "function f(x: u32[]): void { while false { @drop(x);" + " @drop(x);" * 65 + " } @drop(x); }\n"
        send(changed(unreachable, 7))
        receive(log("Yak: 前端诊断收集超出上限，分析不完整") + publication(7), "暂存截断不发布被过滤的所有权错误")
        send(changed("function f(): void {}\n", 8))
        receive(publication(8), "收集截断后恢复分析")
        deep_sources = [
            "; function f(): u32 { return " + "(" * 256 + "1u32" + ")" * 256 + "; }\n",
            "function f(): bool { return " + "! " * 256 + "true; }\n",
            "const N: i32 = " + "- " * 256 + "1i32;\n",
            "function f(): void { " + "while false { " * 256 + "}" * 256 + "}\n",
            "struct S { v: " + "(" * 256 + "u32" + ")" * 256 + " }\n",
            "struct S { v: u32" + "[]" * 256 + " }\n",
            "function f(x: " + "&function(" * 256 + "&u32:Read" + "): void" * 256 + "): void {}\n",
        ]
        for version, deep in enumerate(deep_sources, 9):
            send(changed(deep, version))
            receive(log("Yak: 源码解析深度超出上限，分析不完整") + publication(version), f"解析深度超限形态 {version}")
        flat_trees = [
            "function f(): u32 { return 1u32" + " + 1u32" * 64 + "; }\n",
            "function f(x: u32): u32 { return x" + ".member" * 64 + "; }\n",
            "function f(x: u32): u32 { return x" + "[0u32]" * 64 + "; }\n",
            "function f(x: u32): u32 { return x" + "[0u32..1u32]" * 64 + "; }\n",
            "function f(x: u32): u32 { return x" + "()" * 64 + "; }\n",
            "function f(x: u32): u32 { return x" + " as u32" * 64 + "; }\n",
            "const N: u32 = 1u32" + " + 1u32" * 64 + ";\n",
        ]
        for version, deep in enumerate(flat_trees, 16):
            send(changed(deep, version))
            receive(log("Yak: 表达式树深度超出上限，分析不完整") + publication(version), f"浅解析深表达式树 {version}")
        send(changed("function f(): u32 { return 1u32" + " + 1u32" * 63 + "; }\n", 23))
        receive(publication(23), "表达式树深度 64 仍分析")
        def chain(count, fixed=False):
            declarations = []
            for at in range(count):
                child = "u32" if at + 1 == count else f"T{at + 1:02d}"
                field = f"[{child}; 1]" if fixed else child
                declarations.append(f"struct T{at:02d} {{ v: {field} }}\n")
            return "".join(reversed(declarations))

        deep_types = [chain(64), chain(33, fixed=True)]
        for version, deep in enumerate(deep_types, 24):
            send(changed(deep, version))
            receive(log("Yak: 按值类型链深度超出上限，分析不完整") + publication(version), f"按值类型链超限形态 {version}")
        send(changed(chain(63), 26))
        receive(publication(26), "按值类型链深度 64 仍分析")
        send(changed("struct A { v: A[] }\n", 28))
        receive(publication(28), "动态数组头不会把间接递归计作按值环")
        send(changed(text, 29))
        receive(publication(29, missing), "深度超限后仍可发布当前版真实诊断")
        # 每个函数有 8 个固定 token，六个空条件各 4 个，不放大声明预留成本。
        token_edge = "".join(f"function f{i:03}(): void {{ " + "if true {} " * 6 + "}\n" for i in range(64))
        send(changed(token_edge + ";\n", 30))
        receive(log("Yak: 源码 token 数量超出上限，分析不完整") + publication(30), "2049 个 token 不进入解析")
        send(changed(token_edge + "// 中😀尾注释\n", 31))
        receive(publication(31), "2048 个 token 仍检查，尾注释与 EOF 不占配额")
        send(changed("function " + "a" * 1025 + "(): void {}\n", 32))
        receive(log("Yak: 源码名称长度超出上限，分析不完整") + publication(32), "1025 字节名称明确降级")
        send(changed("function " + "a" * 1024 + "(): void {}\n", 33))
        receive(publication(33), "1024 字节名称正常分析")
        send(changed(text, 34))
        receive(publication(34, missing), "词法资源超限后仍能发布当前版的真实诊断")

        def shared_copy(levels):
            declarations = []
            for at in range(levels):
                child = "u32" if at == 0 else f"D{at - 1:02d}"
                declarations.append(f"struct D{at:02d} {{ left: {child}, right: {child} }}\n")
            root = f"D{levels - 1:02d}"
            return "".join(declarations) + f"function f(p: {root}): {root} {{ return p; }}\n"

        over_copy = log("Yak: Copy 分类的类型图展开超出上限，分析不完整")
        send(changed(shared_copy(9), 35))
        receive(publication(35), "单次展开 1023 个访问仍可检查 Copy 返回")
        send(changed(shared_copy(10), 36))
        receive(over_copy + publication(36), "浅层共享子图超过 Copy 展开配额")
        heavy = shared_copy(34)
        send(changed(heavy, 37))
        receive(over_copy + publication(37), "多层共享子图无需实际递归展开")
        send(changed(heavy + "struct Bad {}\n", 38))
        receive(log("Yak: 有诊断无法定位或超出发布上限") + publication(38), "先保留真正的布局错误")
        send(changed(text, 39))
        receive(publication(39, missing), "Copy 展开降级后下一版恢复真实诊断")
        repeated_copy = (
            "function f(x: S): void { let y: S = @copy(x); @drop(y); @drop(x); }\n"
            "function g(x: S): void { let y: S = @copy(x); @drop(y); @drop(x); }\n"
        )
        copy_column = repeated_copy.index("@copy(x)") + len("@copy(")
        mixed_rows = (
            "enum Before { Full(u32), Empty }\n"
            "struct Lead { row: u32[] }\n"
            "enum Middle { Empty, Full(PAYLOAD) }\n"
            "struct S { first: u32, last: Middle }\n"
            "enum After { Full(u32[]), Empty }\n"
            "struct Tail { row: u32[] }\n"
        )
        rejected_copy = [
            {"range": {"start": {"line": line, "character": copy_column},
                       "end": {"line": line, "character": copy_column + 1}},
             "severity": 1, "source": "yak", "code": "E6202", "message": "Yak 所有权诊断 E6202"}
            for line in (6, 7)
        ]
        scalar = mixed_rows.replace("PAYLOAD", "u32") + repeated_copy
        owning = mixed_rows.replace("PAYLOAD", "u32[]") + repeated_copy
        send(changed(scalar, 40))
        receive(publication(40), "夹在不相关字段和枚举间的结构体仍可 Copy")
        send(changed(owning, 41))
        receive(publication(41, rejected_copy), "枚举第二个载荷变为 owning 后重新分类并发布每处错误")
        send(changed(scalar, 42))
        receive(publication(42), "恢复 Copy 类型后再次重算并清空诊断")
        def write_work(extra: bool, repeated: bool = False) -> str:
            names = [chr(i) for i in range(ord("a"), ord("q"))]
            params = ", ".join(f"{name}: &u32:Write" for name in names)
            fills = "".join(f"*{name} = 1u32; " for name in names)
            # 每形参根块 1 次、提交 16 次、22 个循环各 5 次、末尾语句 1 次。
            loops = "while flag { ping(); } " * 22
            first_tail = "*a = 1u32; " if repeated else "ping(); "
            # 第二函数少 16 次；单形参函数补足 16 次，额外调用只增加一次。
            tail = "ping(); " * (15 if extra else 14)
            return ("function ping(): void {}\n"
                    f"function first(flag: bool, {params}): void {{ {fills}{loops}{first_tail}}}\n"
                    f"function second(flag: bool, {params}): void {{ {fills}{loops}}}\n"
                    f"function last(a: &u32:Write): void {{ *a = 1u32; {tail}}}\n")

        write_status = log("Yak: Write 槽位检查走访超出上限，分析不完整")
        send(changed(write_work(False), 43))
        receive(publication(43), "跨函数循环回放恰好 4096 次时完成检查")
        send(changed(write_work(True), 44))
        receive(write_status + publication(44), "第 4097 次走访中止并清空当前版本")
        repeated_write = [{"range": {"start": {"line": 1, "character": 957},
                                      "end": {"line": 1, "character": 958}},
                           "severity": 1, "source": "yak", "code": "E6102",
                           "message": "Yak 所有权诊断 E6102"}]
        send(changed(write_work(False, True), 45))
        receive(publication(45, repeated_write), "完成检查时保留重复提交的真实错误")
        send(changed(write_work(True, True), 46))
        receive(write_status + publication(46), "中止时不发布先前函数的局部错误")
        send(changed("function f(a: &u32:Write): void { *a = 1u32; }\n", 47))
        receive(publication(47), "走访降级后新版本恢复")

        def replay_work(extra: bool, first_error: bool = False) -> str:
            early = ("function bad(xs: u32[]): void { @drop(xs); @drop(xs); }\n"
                     if first_error else "")
            loop = "while true {} "
            return (early + "function left(flag: bool): void { " + "while flag {} " * 40
                    + loop * 32 + "}\nfunction right(): void { while false { "
                    + loop * (32 + int(extra)) + "} }\n")

        replay_status = log("Yak: 所有权循环回放超出上限，分析不完整")
        send(changed(replay_work(False), 48))
        receive(publication(48), "两函数中恰好 64 次回放，普通循环不扣配额")
        send(changed(replay_work(True), 49))
        receive(replay_status + publication(49), "不可达子块的第 65 次回放中止")
        early_drop = [{"range": {"start": {"line": 0, "character": 43},
                                  "end": {"line": 0, "character": 48}},
                       "severity": 1, "source": "yak", "code": "E6003",
                       "message": "Yak 所有权诊断 E6003"}]
        send(changed(replay_work(False, True), 50))
        receive(publication(50, early_drop), "预算内保留较早函数的真实诊断")
        send(changed(replay_work(True, True), 51))
        receive(replay_status + publication(51), "回放中止时不发布较早函数的局部诊断")
        send(changed("function f(): void {}\n", 52))
        receive(publication(52), "回放降级后新版本恢复")

        flow_head = "enum E { A, B }\n"
        flow_body = ("function f(e: E, s: u32[]): void { match e { "
                     "E::A => { @drop(s); %s }, E::B => { return; } } @drop(s); }\n")
        send(changed(flow_head + flow_body % "return;", 53))
        receive(publication(53), "两个匹配臂返回，跳过不可达的重复释放")
        fallthrough = flow_body % ""
        drop_col = fallthrough.rindex("@drop")
        flow_drop = [{"range": {"start": {"line": 1, "character": drop_col},
                                  "end": {"line": 1, "character": drop_col + 5}},
                      "severity": 1, "source": "yak", "code": "E6003",
                      "message": "Yak 所有权诊断 E6003"}]
        send(changed(flow_head + fallthrough, 54))
        receive(publication(54, flow_drop), "改版后一臂落尾，报告合流后的重复释放")
        send(changed(flow_head + flow_body % "return;", 55))
        receive(publication(55), "恢复必返回后清除上一版本诊断")
        def params(n: int) -> str:
            return ", ".join(f"a{i}: bool" for i in range(n))

        def consume(n: int) -> str:
            return "".join(f"@drop(a{i}); " for i in range(1, n))

        # 静态不可达循环只复制入口和死分支，不执行位置合流。
        first = f"function f({params(32)}): void {{ @drop(a0); " + consume(32) + "while false {} " * 63 + "}\n"
        first += f"function h({params(16)}): void {{ @drop(a0); {consume(16)}while false {{}} }}\n"

        def place_copy(n: int, left: str) -> str:
            return first + f"function g({params(n)}): bool {{ {consume(n)}return {left} && a0; }}\n"

        send(changed(place_copy(32, "false"), 56))
        receive(publication(56), "跨函数与不可达短路恰好复制 4096 行")
        copy_limit = log("Yak: 所有权位置表复制超出上限，分析不完整")
        send(changed(place_copy(33, "false"), 57))
        receive(copy_limit, "不可达短路第 4097 行复制前降级")
        receive(publication(57), "不可达短路超限仅清空当前版本")
        send(changed(place_copy(33, "a0"), 58))
        receive(copy_limit, "动态短路第 4097 行复制前降级")
        receive(publication(58), "动态短路超限仅清空当前版本")
        send(changed(error + place_copy(33, "false"), 59))
        receive(copy_limit, "超限前已产生所有权错误仍报告不完整")
        receive(publication(59), "超限后不发布局部所有权错误")
        send(changed(place_copy(32, "a0"), 60))
        receive(publication(60), "改版后重新计费并恢复完整分析")

        scope = "function f(x: u32[], b: bool): void { if b { let y: u32[] = [1u32]; let n: u64 = @len(y); @drop(n); } else { return; } let n: u64 = @len(x); @drop(n); }\n"
        send(changed(scope, 61))
        receive(publication(61), "不生成析构计划仍接受合法离块和返回")
        bad_exit = "function f(x: u32[]): void { @drop(x); @drop(x); return; }\n"
        second_drop = bad_exit.rindex("@drop")
        send(changed(bad_exit, 62))
        receive(publication(62, [{"range": {"start": {"line": 0, "character": second_drop},
                                                "end": {"line": 0, "character": second_drop + 5}},
                                  "severity": 1, "source": "yak", "code": "E6003",
                                  "message": "Yak 所有权诊断 E6003"}]), "跳过产物仍报告返回路径上的所有权错误")
        send(changed(scope, 63))
        receive(publication(63), "合法改版清除所有权诊断")

    send(packet("textDocument/didClose", {"textDocument": {"uri": uri}}))
    receive(publication(None), "关闭时清空且不发送旧版本")
    send(opened("//中😀", -2147483648))
    receive(publication(-2147483648, eof(5)), "重开可使用更小版本并重新分析")
    send(packet("shutdown", identifier=2))
    receive(encoded({"jsonrpc": "2.0", "id": 2, "result": None}), "诊断会话关闭")
    send(packet("exit"))
    return 0


def slice_budget_exchange(send, receive, changed, publication, log, error, *, group):
    def slice_join(name: str, loans: int, edges: str) -> str:
        bindings = "".join(f"let v{i}: &[u8] = &a[0..1]:Read; " for i in range(loans))
        reads = "".join(f"use(v{i}); " for i in range(loans))
        return (f"function {name}(b: bool): void {{ let a: [u8; 1] = [1u8]; "
                + bindings + edges + reads + "}\n")

    one_if = "if b {} "
    one_break = "while true { break; } "
    if group == "join":
        # 37 次八行 if（各 108），另加七行 if（84）、双行 if（9）、两次单行 if（各 3）和 break（1）。
        join_base = ("function use(v: &[u8]): void { let n: u64 = @len(v); @drop(n); }\n"
                     + slice_join("wide", 8, one_if * 37)
                     + slice_join("medium", 7, one_if)
                     + slice_join("small", 2, one_if))
        join_tail = one_if * 2 + one_break
        join_exact = join_base + slice_join("tail", 1, join_tail)
        send(changed(join_exact, 64))
        receive(publication(64), "跨函数切片合流恰好用完 4096 次工作量")
        join_limit = log("Yak: 切片借用合流超出上限，分析不完整")
        send(changed(join_base + slice_join("tail", 1, join_tail + one_break), 65))
        receive(join_limit, "下一条 break 的合流在插入前中止")
        receive(publication(65), "切片合流超限只清空当前版本")
        send(changed(error + join_base + slice_join("tail", 1, join_tail + "while b { continue; } "), 66))
        receive(join_limit, "continue 回边超限，即使之前已有所有权错误")
        receive(publication(66), "中止后不发布局部所有权错误")
        send(changed("enum E { A, B }\n" + join_exact +
                     "function matched(e: E): void { let a: [u8; 1] = [1u8]; let v: &[u8] = &a[0..1]:Read; "
                     "match e { E::A => {}, E::B => {} } use(v); }\n", 67))
        receive(join_limit, "匹配臂也使用跨函数共享的切片合流配额")
        receive(publication(67), "匹配臂超限只清空当前版本")
        send(changed(join_base + slice_join("tail", 1, join_tail + "while b {} "), 68))
        receive(join_limit, "普通循环体落尾也计入回边合流")
        receive(publication(68), "普通回边超限只清空当前版本")
        send(changed(join_exact, 69))
        receive(publication(69), "改版重新计费并完整分析切片借用")
    elif group == "copy":
        # 每个单分支 if 复制三次，提前返回的路径不合流；带 break 的常真循环只复制一次。
        copy_base = ("function use(v: &[u8]): void { let n: u64 = @len(v); @drop(n); }\n"
                     + slice_join("wide", 8, "if b { return; } " * 42))
        copy_tail = "if b { return; } " * 5 + one_break
        copy_exact = copy_base + slice_join("tail", 1, copy_tail)
        copy_over = copy_base + slice_join("tail", 1, copy_tail + one_break)
        send(changed(copy_exact, 70))
        receive(publication(70), "跨函数切片快照恰好复制 1024 行")
        slice_copy_limit = log("Yak: 切片借用快照复制超出上限，分析不完整")
        send(changed(copy_over, 71))
        receive(slice_copy_limit, "第 1025 行切片快照在分配前中止")
        receive(publication(71), "快照复制超限仅清空当前版本")
        send(changed(error + copy_over, 72))
        receive(slice_copy_limit, "先前所有权错误不阻止报告分析不完整")
        receive(publication(72), "不发布超限前的局部所有权错误")
        send(changed(copy_exact, 73))
        receive(publication(73), "新版本重新计费并恢复切片分析")
    elif group == "scope":
        # 深度 15 的单借用离块计 2 至 16 步；函数退出只走模块根域，共计 2 步。
        scope_base = ("function use(v: &[u8]): void { let n: u64 = @len(v); @drop(n); }\n"
                      + "".join(slice_join(f"deep{i}", 1, "if b { " * 15 + "} " * 15) for i in range(7)))
        # 七个深函数计 959；31 个 if 及一次加深计 63，函数退出计 2。
        scope_exact = scope_base + slice_join("tail", 1, one_if * 29 + "if b { if b {} } ")
        scope_over = scope_base + slice_join("tail", 1, one_if * 27 + "if b { if b {} } " * 2)
        send(changed(scope_exact, 74))
        receive(publication(74), "跨函数作用域过滤恰好 1024 步")
        scope_limit = log("Yak: 切片借用作用域过滤超出上限，分析不完整")
        send(changed(scope_over, 75))
        receive(scope_limit, "第 1025 次访问前明确中止")
        receive(publication(75), "作用域过滤超限只清空当前版本")
        send(changed(error + scope_base + slice_join("tail", 1, one_if * 27 + "if b { if b {} } " * 2 + one_break), 76))
        receive(scope_limit, "进入 break 时只剩一步，跳转父链过滤必须中止")
        receive(publication(76), "跳转过滤超限不发布先前的局部错误")
        send(changed(scope_exact, 77))
        receive(publication(77), "作用域过滤超限后随新版本重新分析")
    else:
        raise AssertionError(f"未知切片预算组：{group}")


def enum_lookup_exchange(send, receive, changed, publication, log):
    declaration = "enum E { " + ", ".join(f"T{i:02d}" for i in range(32)) + " }\n"
    values = "".join(f"function f{i}(): E {{ return E::T31; }}\n" for i in range(31))
    pattern = "function g(e: E): void { match e { E::T31 => {}, _ => {} } }\n"
    exact = declaration + values + pattern
    bad = exact.replace("E::T31", "E::Missing", 1)
    value_tail = "function tail(): E { return E::T00; }\n"
    pattern_tail = "function tail(e: E): void { match e { E::T00 => {}, _ => {} } }\n"
    stop = log("Yak: 本地枚举成员查找超出上限，分析不完整")
    # 跨函数共 31 个末行表达式和一个末行模式；通配臂不读成员表。
    send(changed(exact, 1))
    receive(publication(1), "跨表达式与模式恰好读取 1024 行")
    for version, src, stage in ((2, exact + value_tail, "表达式"),
                                (3, exact + pattern_tail, "匹配模式"),
                                (4, bad + value_tail, "已有未定义成员后")):
        send(changed(src, version))
        receive(stop, f"{stage}在读取第 1025 行前报告不完整")
        receive(publication(version), "超限丢弃本版局部错误并清空")
    col = bad.splitlines()[1].index("E::Missing")
    send(changed(bad, 5))
    receive(publication(5, [{"range": {"start": {"line": 1, "character": col},
                                        "end": {"line": 1, "character": col + 1}},
                             "severity": 1, "source": "yak", "code": "E4002",
                             "message": "Yak 名称诊断 E4002"}]), "预算内全表未命中仍报告真实错误")
    first = exact.replace("E::T31", "E::T00", 1)
    send(changed(first + value_tail, 6))
    receive(publication(6), "首行命中提前停止，改版后完整检查并清空")


def reference_output_exchange(send, receive, changed, publication, log):
    def source(n, literals, first="x"):
        return ("function f(x: bool): void { " + f"if {first} {{}} " + "if x {} " * (n - 1)
                + "if true {} " * literals + "}\n")

    stop = log("Yak: 引用输出整理超出上限，分析不完整")
    # 390 条引用的九轮归并和暂存共 7410 行；索引初始化 392 槽，回填 390 行。
    exact = source(388, 2)
    send(changed(exact, 1))
    receive(publication(1), "排序与索引恰好整理 8192 行")
    for version, src, stage in ((2, source(388, 3), "索引预扣第 8193 行"),
                                (3, source(430, 0), "归并轮预扣"),
                                (4, source(388, 23, "missing"), "已有局部错误后索引预扣")):
        send(changed(src, version))
        receive(stop, f"{stage}报告不完整")
        receive(publication(version), "超限丢弃本版局部诊断并清空")
    bad = source(2, 0, "missing")
    col = bad.index("missing")
    send(changed(bad, 5))
    receive(publication(5, [{"range": {"start": {"line": 0, "character": col},
                                        "end": {"line": 0, "character": col + len("missing")}},
                             "severity": 1, "source": "yak", "code": "E4002",
                             "message": "Yak 名称诊断 E4002"}]), "预算内仍发布真实名称错误")
    send(changed(exact, 6))
    receive(publication(6), "改版重新计费，完整分析并清空")


def layout_budget_source(structs, wide, enums, payloads, bad=False):
    fields = "a: u32, b: u32, c: u32, d: u32" + (", e: u32" if wide else "")
    records = "".join(f"struct T{i:02d} {{ {fields} }}\n" for i in range(structs))
    cases = "".join(f"enum ET{i:02d} {{ A" + ("(u32)" if i < payloads else "") + " }\n"
                    for i in range(enums))
    return ("struct Bad {}\n" if bad else "") + records + cases


def value_graph_exchange(send, receive, changed, publication, log):
    # 缓存和根 156，字段比较与定位 324 + 539，字段和类型访问 650 + 64。
    # 枚举行比较 297，载荷行 12，六次非空类型访问补足 2048。
    exact = layout_budget_source(65, True, 12, 6)
    stop = log("Yak: 按值类型布局预检超出上限，分析不完整")
    layout_stop = log("Yak: 正式类型布局超出上限，分析不完整")
    send(changed(exact, 1))
    receive(layout_stop + publication(1), "按值布局预检恰好 2048 步，进入独立正式布局")
    send(changed(layout_budget_source(65, True, 12, 7), 2))
    receive(stop, "第 2049 次预检访问前停止")
    receive(publication(2), "预检超限只清空当前版本")
    send(changed(layout_budget_source(65, True, 12, 6, bad=True), 3))
    receive(stop, "超限不进入会产生布局错误的正式布局")
    receive(publication(3), "预检不发布未执行阶段的布局诊断")
    send(changed("struct Bad {}\n", 4))
    receive(log("Yak: 有诊断无法定位或超出发布上限") + publication(4),
            "预算内仍走正式布局错误的无位置降级")
    send(changed("enum Ready { A(u32) }\n", 5))
    receive(publication(5), "按值布局预检改版恢复")


def formal_layout_exchange(send, receive, changed, publication, log):
    # 初始化、根和延后检查 228，字段比较与定位 243 + 486，两遍字段和类型访问 732 + 120。
    # 枚举行比较 289，载荷行 14；额外访问只让最后一批预扣超限。
    exact = layout_budget_source(61, False, 14, 0)
    stop = log("Yak: 正式类型布局超出上限，分析不完整")
    send(changed(exact, 1))
    receive(publication(1), "正式布局恰好 2112 步")
    send(changed(layout_budget_source(61, False, 14, 1), 2))
    receive(stop, "预检通过，正式布局延后检查预扣第 2113 步")
    receive(publication(2), "超限只清空当前版本")
    send(changed(layout_budget_source(61, False, 14, 0, bad=True), 3))
    receive(stop, "已有空结构体布局错误仍报告正式布局超限")
    receive(publication(3), "丢弃本版局部布局错误")
    send(changed("struct Bad {}\n", 4))
    receive(log("Yak: 有诊断无法定位或超出发布上限") + publication(4), "预算内仍执行正式布局诊断")
    send(changed(exact, 5))
    receive(publication(5), "正式布局改版重新计费")


def decl_intern_exchange(send, receive, changed, publication, log):
    def source(length):
        payloads = ", ".join(f"V{i:02d}([u32; {i + 1}])" for i in range(88))
        return f"enum E {{ {payloads}, Tail([u32; {length}]) }}\n"

    # 枚举索引访问及首槽用两步，首个数组用三步，其余 87 个各用两步查标量并扫描候选，共 4181 步。
    # 尾部命中第 41 或 42 个数组候选，另用两步查标量，故总数为 4224 或 4225。
    exact = source(39)
    over = source(40)
    stop = log("Yak: 声明类型驻留超出上限，分析不完整")
    send(changed(exact, 1))
    receive(publication(1), "声明类型驻留恰好 4224 步")
    send(changed(over, 2))
    receive(stop, "在第 4225 次候选比较前停止")
    receive(publication(2), "声明类型驻留超限只清空当前版本")
    bad = "function main(): void { let n: bool = 1u32; if n { return; } }\n"
    send(changed(over + bad, 3))
    receive(stop, "超限不进入会产生类型错误的函数体检查")
    receive(publication(3), "不发布未执行阶段的类型诊断")
    col = bad.index("let n:")
    send(changed(bad, 4))
    receive(publication(4, [{"range": {"start": {"line": 0, "character": col},
                                            "end": {"line": 0, "character": col + len("let n: bool = 1u32;")}},
                             "severity": 1, "source": "yak", "code": "E5001",
                             "message": "Yak 类型或布局诊断 E5001"}]), "预算内仍发布真实类型错误")
    send(changed(exact, 5))
    receive(publication(5), "改版恢复并重新计费")
    # 末尾字段反复引用靠后的本地类型：旧线性扫描超限，文档路径直接查槽。
    nominals = "".join(f"struct Nom{i:02d} {{ value: u32 }}\n" for i in range(48))
    repeated = ", ".join(f"f{i:02d}: Nom47" for i in range(72))
    nominals += f"struct Many {{ {repeated} }}\n"
    send(changed(nominals + bad, 6))
    receive(publication(6, [{"range": {"start": {"line": 49, "character": col},
                                            "end": {"line": 49, "character": col + len("let n: bool = 1u32;")}},
                             "severity": 1, "source": "yak", "code": "E5001",
                             "message": "Yak 类型或布局诊断 E5001"}]), "名义类型索引让旧扫描超限语料到达函数体检查")
    send(changed(nominals, 7))
    receive(publication(7), "名义类型索引语料修复后清空")


def const_init_exchange(send, receive, changed, publication, log):
    def globals_source(count, bad=False):
        return [f"const C{i:02d}: u32 = {'1 / 0' if bad and i == 0 else '1'};\n" for i in range(count)]

    def top_before(index, bad=False):
        rows = globals_source(63, bad)
        rows.insert(index, "function padding(): u32 { return 1; }\n")
        # 末尾引用不改变此前常量的命中位置。
        total = " + ".join(f"C{i:02d}" for i in range(63))
        return "".join(rows) + f"function use_all(): u32 {{ return {total}; }}\n"

    def local_after(count):
        rows = globals_source(62)
        rows.insert(37, "function padding(): u32 { return 1; }\n")
        names = [f"L{i:02d}" for i in range(count)]
        prefix = "".join(f"let {name}: u32 = 1; " for name in names)
        suffix = " + ".join(["Tail", *names])
        total = " + ".join(f"C{i:02d}" for i in range(62))
        return "".join(rows) + f"function local(): u32 {{ {prefix}const Tail: u32 = 1; return ({suffix}) + ({total}); }}\n"

    # 旧扫描恰好用 2048 或 2049 步；索引后两者都只读 63 条常量。
    for version, source in enumerate((top_before(31), top_before(30),
                                       local_after(5), local_after(6)), start=1):
        send(changed(source, version))
        receive(publication(version), "不再扫描常量之前的顶层或局部条目")

    top = top_before(30, bad=True)
    local = local_after(6).replace("const Tail: u32 = 1;", "const Tail: u32 = 1 / 0;")
    for version, source, label in ((5, top, "顶层"), (6, local, "局部")):
        pos = source.index("/")
        line = source.count("\n", 0, pos)
        col = pos - source.rfind("\n", 0, pos) - 1
        send(changed(source, version))
        receive(publication(version, [{"range": {"start": {"line": line, "character": col},
                                                   "end": {"line": line, "character": col + 1}},
                                        "severity": 1, "source": "yak", "code": "E5008",
                                        "message": "Yak 类型或布局诊断 E5008"}]), f"发布真实{label}常量错误")
    send(changed(local_after(6), 7))
    receive(publication(7), "更正局部常量后清空")
    # 改变顶层条目位置后仍使用本版记录。
    send(changed(top_before(0), 8))
    receive(publication(8), "重排后按新 DefId 顺序求值")


def const_material_exchange(send, receive, changed, publication, log):
    def source(extra=False, bad=False):
        rows = ["const Number: u32 = " + ("1 / 0" if bad else "1") + ";\n",
                "enum M0 { Zero, A(u32), B(u32) }\n"]
        for i in range(1, 6):
            rows.append(f"enum M{i} {{ Zero, A(M{i - 1}), B(M{i - 1}) }}\n")
        pads = ", ".join(f"Pad{i}" for i in range(2 + extra))
        rows.append(f"enum M6 {{ Zero, A(M5), B(M5), C(M2), D(M2), E(M1), F(M1), {pads} }}\n")
        return "".join(rows) + "const Value: M6 = M6::Zero;\nfunction f(): M6 { let n: u32 = Number; @drop(n); return Value; }\n"

    # 标量 1 步；M6 为自身 1、候选 7、空载荷 3、有载荷槽 6、子类型 2×(436+47+20)，共 1024 步。
    stop = log("Yak: 常量可物化检查超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "共享载荷及未选中分支恰好 1024 步")
    send(changed(source(extra=True), 2))
    receive(stop, "不读取第 1025 步的空载荷槽")
    receive(publication(2), "超限仅清空当前版本")
    send(changed(source(extra=True, bad=True), 3))
    receive(stop, "已有除零诊断时仍中止可物化检查")
    receive(publication(3), "不发布局部 E5008")
    bad = source(bad=True)
    col = bad.index("/")
    send(changed(bad, 4))
    receive(publication(4, [{"range": {"start": {"line": 0, "character": col},
                                        "end": {"line": 0, "character": col + 1}},
                             "severity": 1, "source": "yak", "code": "E5008",
                             "message": "Yak 类型或布局诊断 E5008"}]), "预算内仍发布真实常量错误")
    send(changed(source(), 5))
    receive(publication(5), "改版恢复并重新计费")


def const_fold_exchange(send, receive, changed, publication, log):
    def source(extra=False, bad=False):
        chain = "const C0: u32 = 1;\n" + "".join(f"const C{i}: u32 = C{i - 1};\n" for i in range(1, 43))
        number = "1 / 0" if bad else "1 + 0"
        return chain + f"const Number: u32 = {number};\nconst Last: u32 = C{30 + extra};\n" + \
            "function f(): u32 { return C42 + Number + Last; }\n"

    # 首常量 1 步，42 个引用各为两次节点或索引访问加 i 行绑定，共 987 步。
    # 独立算式 3 步；最后引用再付 2 步及 31 或 32 行绑定。
    stop = log("Yak: 正式常量折叠超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "正式折叠恰好 1024 步")
    send(changed(source(extra=True), 2))
    receive(stop, "不读取第 1025 步的常量绑定")
    receive(publication(2), "正式折叠超限只清空当前版本")
    send(changed(source(extra=True, bad=True), 3))
    receive(stop, "折叠超限覆盖已有除零诊断")
    receive(publication(3), "不发布局部 E5008")
    bad = source(bad=True)
    col = bad.splitlines()[43].index("/")
    send(changed(bad, 4))
    receive(publication(4, [{"range": {"start": {"line": 43, "character": col},
                                        "end": {"line": 43, "character": col + 1}},
                             "severity": 1, "source": "yak", "code": "E5008",
                             "message": "Yak 类型或布局诊断 E5008"}]), "预算内保留真实折叠错误")
    send(changed(source(), 5))
    receive(publication(5), "再次编辑后完整折叠")


def integer_probe_exchange(send, receive, changed, publication, log):
    def source(extra=False, bad=False):
        rows = [f"const K{i}: u32 = {55296 if i == 0 and bad else 1};\n" for i in range(40)]
        rows.append("function take(x: char): void { @drop(x); }\nfunction f(): u32 {\n")
        rows.extend(f"take(K{i} as char);\n" for i in range(40))
        rows.append("take(K38 as char);\nlet a: [u32; 2] = [0u32, 1u32];\n")
        rows.append(f"return a[K{38 + extra}];\n}}\n")
        return "".join(rows)

    # 前四十次转换共 940 步，再一次转换 42 步，下标查找为 42 或 43 步。
    stop = log("Yak: 整数诊断试算超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "转换与下标共享 1024 步试算额度")
    send(changed(source(extra=True), 2))
    receive(stop, "下标试算不读取第 1025 步的绑定")
    receive(publication(2), "超限先报告再清空")
    send(changed(source(extra=True, bad=True), 3))
    receive(stop, "已收集的转换诊断不阻止试算超限")
    receive(publication(3), "不发布局部 E5001")
    send(changed(source(bad=True), 4))
    receive(publication(4, [{"range": {"start": {"line": 42, "character": 8},
                                        "end": {"line": 42, "character": 10}},
                             "severity": 1, "source": "yak", "code": "E5001",
                             "message": "Yak 类型或布局诊断 E5001"}]), "预算内发布非 Unicode 标量诊断")
    send(changed(source(), 5))
    receive(publication(5), "编辑后恢复并重新计费")


def integer_scan_exchange(send, receive, changed, publication, log):
    def balanced(terms):
        if len(terms) == 1:
            return terms[0]
        mid = len(terms) // 2
        return f"({balanced(terms[:mid])} + {balanced(terms[mid:])})"

    def source(extra=False, bad=False, probes=True):
        terms = ["-0i32", "-0i32" if extra or not probes else "0i32 as i32"]
        terms += ["0i32 as i32" if probes else "-0i32"] * 2
        terms += ["2147483648i32" if bad else "0i32"] + ["0i32"] * 403
        return "function f(): i32 {\nreturn " + balanced(terms) + ";\n}\n"

    def range_error(text):
        at = text.splitlines()[1].index("2147483648i32")
        return [{"range": {"start": {"line": 1, "character": at},
                           "end": {"line": 1, "character": at + 13}},
                 "severity": 1, "source": "yak", "code": "E1004",
                 "message": "Yak 词法诊断 E1004"}]

    # 408 个叶子、407 个二元节点和 4 个单操作数节点：5 × 819 + 一元行数。
    # 交换一个转换和一个负号保留表达式数及试算消费者，只增加一次一元计费。
    exact = source()
    bad_exact = source(bad=True)
    stop = log("Yak: 整数诊断外围扫描超出上限，分析不完整")
    send(changed(exact, 1))
    receive(publication(1), "外围扫描恰好 4096 步")
    send(changed(source(extra=True), 2))
    receive(stop, "外围扫描拒绝第 4097 步")
    receive(publication(2), "外围扫描超限后清空")
    send(changed(source(extra=True, bad=True), 3))
    receive(stop, "已收集的整数范围诊断不阻止外围扫描超限")
    receive(publication(3), "外围扫描超限不发布局部 E1004")
    send(changed(bad_exact, 4))
    receive(publication(4, range_error(bad_exact)), "预算内发布真实的整数范围诊断")
    send(changed(source(probes=False), 5))
    receive(publication(5), "无消费者不分配试算缓存或空扫")
    no_probe_bad = source(bad=True, probes=False)
    send(changed(no_probe_bad, 6))
    receive(publication(6, range_error(no_probe_bad)), "无消费者仍发布整数范围错误")
    send(changed(exact, 7))
    receive(publication(7), "改版后外围扫描重新计费")


def integer_shape_exchange(send, receive, changed, publication, log):
    def tree(count):
        if count == 1:
            return "0"
        half = count // 2
        return f"({tree(half)} + {tree(count - half)})"

    bad_function = "function broken(): void { let n: bool = 1u32; if n { return; } }\n"

    def source(extra=False, bad=False):
        suffix = " + (0 as u32)" if extra else ""
        body = f"function f(): u32 {{ let xs: [u32; 1] = [0u32]; return ({tree(256)} as u32) + xs[0]{suffix}; }}\n"
        return (bad_function if bad else "") + body

    # 转换操作数 511 个节点，短下标再消耗一步；额外转换不应读取第 513 个节点。
    stop = log("Yak: 纯整数形态判定超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "转换与下标恰好共享 512 步")
    send(changed(source(extra=True), 2))
    receive(stop, "纯整数形态拒绝第 513 步")
    receive(publication(2), "纯整数形态超限先报告再清空")
    send(changed(source(extra=True, bad=True), 3))
    receive(stop, "已有类型诊断不阻止形态超限")
    receive(publication(3), "超限不发布局部 E5001")
    send(changed(source(bad=True), 4))
    col = bad_function.index("let n:")
    receive(publication(4, [{"range": {"start": {"line": 0, "character": col},
                                        "end": {"line": 0, "character": col + len("let n: bool = 1u32;")}},
                             "severity": 1, "source": "yak", "code": "E5001",
                             "message": "Yak 类型或布局诊断 E5001"}]), "预算内发布真实 E5001")
    send(changed(source(), 5))
    receive(publication(5), "改版后形态预算重新计费")


def array_inference_exchange(send, receive, changed, publication, log):
    bad_function = "function broken(): void { let n: bool = 1u32; if n { return; } }\n"

    def source(typed_slot=255, bad=False):
        elements = ["0"] * 257
        elements[typed_slot] = "0u32"
        body = "function f(): u32 { return ([" + ", ".join(elements) + "])[0u32]; }\n"
        return (bad_function if bad else "") + body

    # 257 个元素顺扫，首个定型元素前再回扫 255 或 256 步。
    stop = log("Yak: 数组元素推断扫描超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "数组顺扫和回填恰好共享 512 步")
    send(changed(source(256), 2))
    receive(stop, "数组推断拒绝第 513 步")
    receive(publication(2), "数组推断超限先报告再清空")
    send(changed(source(256, True), 3))
    receive(stop, "已有类型诊断不阻止数组推断超限")
    receive(publication(3), "超限不发布局部 E5001")
    send(changed(source(bad=True), 4))
    col = bad_function.index("let n:")
    receive(publication(4, [{"range": {"start": {"line": 0, "character": col},
                                        "end": {"line": 0, "character": col + len("let n: bool = 1u32;")}},
                             "severity": 1, "source": "yak", "code": "E5001",
                             "message": "Yak 类型或布局诊断 E5001"}]), "预算内发布真实 E5001")
    send(changed(source(), 5))
    receive(publication(5), "改版后数组推断预算重新计费")


def ctor_fields_exchange(send, receive, changed, publication, log):
    bad_function = "function broken(): void { let n: bool = 1u32; if n { return; } }\n"

    def source(extra=False, bad=False):
        def fields(count):
            return ", ".join(f"a{i}: u32" for i in range(count))

        def constructor(name, host, count):
            values = ", ".join(f"a{i}: 0u32" for i in range(count))
            return f"function {name}(): {host} {{ return {host} {{ {values} }}; }}\n"

        return (bad_function if bad else "") + (
            f"struct B {{ {fields(8)} }}\nstruct A {{ {fields(30)} }}\n"
            f"struct Pad {{ {fields(10 if extra else 9)} }}\n"
            + constructor("small", "B", 8) + constructor("large", "A", 30)
        )

    # 两个构造分别使用 72 和 930 步定位后工作；二分共 22 或 23 步。
    stop = log("Yak: 本地构造器字段检查超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "本地构造器检查恰好使用 1024 步")
    send(changed(source(True), 2))
    receive(stop, "本地构造器在第 1025 步前停止")
    receive(publication(2), "本地构造器超限先报告再清空")
    send(changed(source(True, True), 3))
    receive(stop, "已有类型诊断不阻止构造器超限")
    receive(publication(3), "超限不发布局部 E5001")
    send(changed(source(bad=True), 4))
    col = bad_function.index("let n:")
    receive(publication(4, [{"range": {"start": {"line": 0, "character": col},
                                        "end": {"line": 0, "character": col + len("let n: bool = 1u32;")}},
                             "severity": 1, "source": "yak", "code": "E5001",
                             "message": "Yak 类型或布局诊断 E5001"}]), "预算内发布真实 E5001")
    send(changed(source(), 5))
    receive(publication(5), "改版后本地构造器计费恢复")


def match_scan_exchange(send, receive, changed, publication, log):
    bad_function = "function broken(): void { let n: bool = 1u32; if n { return; } }\n"

    def source(over=False, bad=False, payload=False):
        names = [f"A{i}" for i in range(31)]
        variants = names.copy()
        branches = [f"{name} => {{}}" for name in names]
        if payload:
            variants[0] += "(u16)"
            branches[0] = "A0(v) => { let n: u16 = v; @drop(n); }"
        else:
            branches.append("_ => {}")
        tail = "function g(e: E): void { match e { _ => {} } }\n" if over else ""
        return (bad_function if bad else "") + (
            f"enum Pad {{ P }}\nenum E {{ {', '.join(variants)} }}\n"
            f"function f(p: Pad, e: E): void {{ @drop(p); match e {{ {', '.join(branches)} }} }}\n"
        ) + tail

    # 32 个臂，527 行裸标签查找和 465 行覆盖表判重；额外通配臂再加一步。
    stop = log("Yak: 匹配臂检查扫描超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "匹配扫描恰好使用 1024 步")
    send(changed(source(True), 2))
    receive(stop, "拒绝第 1025 个匹配扫描步骤")
    receive(publication(2), "匹配扫描超限先报告再清空")
    send(changed(source(True, True), 3))
    receive(stop, "已有类型诊断不阻止匹配扫描超限")
    receive(publication(3), "超限不发布局部 E5001")
    send(changed(source(bad=True), 4))
    col = bad_function.index("let n:")
    receive(publication(4, [{"range": {"start": {"line": 0, "character": col},
                                        "end": {"line": 0, "character": col + len("let n: bool = 1u32;")}},
                             "severity": 1, "source": "yak", "code": "E5001",
                             "message": "Yak 类型或布局诊断 E5001"}]), "预算内发布真实 E5001")
    send(changed(source(), 5))
    receive(publication(5), "改版后匹配扫描预算重置")
    # 用一步载荷定位替换一步通配臂，其余候选数保持不变。
    send(changed(source(payload=True), 6))
    receive(publication(6), "有载荷的匹配恰好使用 1024 步")
    send(changed(source(True, True, True), 7))
    receive(stop, "有载荷的版本仍拒绝第 1025 步")
    receive(publication(7), "有载荷超限时清空先前的类型诊断")
    send(changed(source(payload=True), 8))
    receive(publication(8), "改版后载荷绑定类型及配额恢复")


def match_path_exchange(send, receive, changed, publication, log):
    bad = "function broken(e: E): void { match e { _ => {}, _ => {} } }\n"
    names = [f"A{i}" for i in range(20)]
    enum = f"enum E {{ {', '.join(names)} }}\n"

    def matching(name, labels):
        arms = ", ".join(f"{label} => {{}}" for label in labels)
        return f"function {name}(e: E): void {{ match e {{ {arms}, _ => {{}} }} }}\n"

    # 每对限定标签先比较一行，再比较两个分段，共 3×(190+136+15) 步。
    # 不同路径长度只看一行，第四个匹配恰好使用第 1024 步。
    exact = enum + "".join(matching(f"f{n}", [f"E::{v}" for v in names[:n]]) for n in (20, 17, 6))
    exact += matching("f1", ("A0", "E::A1"))
    extra = matching("f2", ("A0", "E::A1"))
    stop = log("Yak: 匹配模式路径判重超出上限，分析不完整")
    send(changed(exact, 1))
    receive(publication(1), "模式路径判重恰好 1024 步")
    send(changed(bad + exact, 2))
    col = bad.rindex("_")
    receive(publication(2, [{"range": {"start": {"line": 0, "character": col},
                                        "end": {"line": 0, "character": col + 1}},
                             "severity": 1, "source": "yak", "code": "E2014",
                             "message": "Yak 解析诊断 E2014"}]), "预算内发布真实 E2014")
    send(changed(bad + exact + extra, 3))
    receive(stop, "第 1025 步前明确停止模式判重")
    receive(publication(3), "超限不发布部分 E2014")
    send(changed(exact + extra, 4))
    receive(stop, "合法模式也拒绝未获配额的比较")
    receive(publication(4), "模式判重超限先报告再清空")
    send(changed(exact, 5))
    receive(publication(5), "改版后模式判重配额重置")


def parse_recovery_exchange(send, receive, changed, publication, log):
    # 文件项与函数体各跳过 512 个右括号，常规声明和闭块不计步。
    tail = ") " * 512
    prefix = tail + "\nfunction f(): void { "
    exact = prefix + tail + "}\n"
    over = prefix + tail + ") }\n"

    def error(line, col):
        return {"range": {"start": {"line": line, "character": col},
                          "end": {"line": line, "character": col + 1}},
                "severity": 1, "source": "yak", "code": "E2001",
                "message": "Yak 解析诊断 E2001"}

    expected = [error(0, 0), error(1, len("function f(): void { "))]
    stop = log("Yak: 解析错误恢复跳过 token 超出上限，分析不完整")
    send(changed(exact, 1))
    receive(publication(1, expected), "1024 个恢复 token 仍发布两条真实 E2001")
    send(changed(over, 2))
    receive(stop, "第 1025 个恢复 token 前停止并报告不完整")
    receive(publication(2), "恢复超限清空本版，不发布已收集语法错误")
    send(changed(exact, 3))
    receive(publication(3, expected), "改版后恢复配额独立重置")
    send(changed("function f(): void {}\n", 4))
    receive(publication(4), "修复语法后正常清空诊断")


def out_ref_exchange(send, receive, changed, publication, log):
    # 分支复用槽位以控制预留成本；多一个填充调用只增加一条前缀引用。
    def source(over=False, bad=False):
        text = ("function fill4(a: &u32:Write, b: &u32:Write, c: &u32:Write, d: &u32:Write): void "
                "{ *a = 1u32; *b = 2u32; *c = 3u32; *d = 4u32; }\n"
                "function fill2(a: &u32:Write, b: &u32:Write): void { *a = 1u32; *b = 2u32; }\n"
                "function noop(): void {}\n"
                "function pad(): void { " + "noop(); " * (99 + int(over)) + "}\n")
        call = "fill4(out a, out b, out c, out d);"
        for suffix in "abcdefgh":
            text += (f"function f{suffix}(): void {{ out a: u32; out b: u32; out c: u32; out d: u32; "
                     f"if true {{ {call} }} elseif true {{ {call} }} elseif true {{ {call} }} else {{ {call} }} }}\n")
        ty = "bool" if bad else "u32"
        return (f"{text}function last(): void {{ out a: {ty}; out b: u32; out c: u32; out d: u32; "
                f"out e: u32; out f: u32; {call} fill2(out e, out f); }}\n")

    exact = source()
    invalid = source(bad=True)
    over = source(over=True)
    over_invalid = source(over=True, bad=True)
    lines = invalid.splitlines()
    line = len(lines) - 1
    col = lines[line].index("out a", lines[line].index("fill4("))
    error = {"range": {"start": {"line": line, "character": col},
                       "end": {"line": line, "character": col + 3}},
             "severity": 1, "source": "yak", "code": "E5001",
             "message": "Yak 类型或布局诊断 E5001"}
    stop = log("Yak: out 实参引用扫描超出上限，分析不完整")
    send(changed(exact, 1))
    receive(publication(1), "1000 次 out 二分读取仍完成")
    send(changed(invalid, 2))
    receive(publication(2, [error]), "1000 步仍发布真实 out 槽类型错误")
    send(changed(over_invalid, 3))
    receive(stop, "第 1001 次读取前停止并报告 out 引用分析不完整")
    receive(publication(3), "不发布先前 out 槽的局部类型诊断")
    send(changed(over, 4))
    receive(stop, "合法源码超限也明确报告")
    receive(publication(4), "合法源码超限仍只清空当前版本")
    send(changed(exact, 5))
    receive(publication(5), "改版后 out 引用预算重置")

    mixed = ("function fill(a: &u32:Write, flag: bool, b: &u32:Write): void!AllocError "
             "{ if flag {} *a = 1u32; *b = 2u32; return; }\n")
    shadow = (mixed + "function f(): void!AllocError { out x: u32; out y: u32; out z: u32; "
              "if true { out x: u32; fill(out x, true, out y)?; let v: u32 = @move(x); @drop(v); } "
              "let w: u32 = @move(y); @drop(w); fill(out x, false, out z)?; "
              "let v: u32 = @move(x); @drop(v); let w2: u32 = @move(z); @drop(w2); return; }\n")
    duplicate = mixed + "function f(): void!AllocError { out x: u32; fill(out x, true, out x)?; return; }\n"
    saved = (mixed + "function f(): void!AllocError { out x: u32; out y: u32; "
             "let r: void!AllocError = fill(out x, true, out y); r?; return; }\n")

    def ownership_error(code, col, width):
        return {"range": {"start": {"line": 1, "character": col},
                          "end": {"line": 1, "character": col + width}},
                "severity": 1, "source": "yak", "code": code,
                "message": f"Yak 所有权诊断 {code}"}

    send(changed(shadow, 6))
    receive(publication(6), "混合实参与内外同名槽位正常借出、提交及提取")
    send(changed(duplicate, 7))
    repeated = ownership_error("E6102", duplicate.splitlines()[1].rindex("out x"), 3)
    receive(publication(7, [repeated]), "保留同一调用第二次借出槽位的精确诊断")
    send(changed(saved, 8))
    saved_carrier = ownership_error("E6105", saved.splitlines()[1].index("); r?"), 1)
    receive(publication(8, [saved_carrier]), "保留保存错误载体的精确诊断")
    send(changed(shadow, 9))
    receive(publication(9), "改回逐调用传播后清空旧诊断")


def rpc_early_exit(send, receive, quiet) -> int:
    send(wire(b'{"jsonrpc":"2.0","method":"exit"}'))
    return 1


def check_eof(command: list[str], work: Path, eof_status: int) -> None:
    # 空文件和关闭的输入管道都是 EOF；真正的读陷阱不能被当成协议退出。
    expected = (eof_status, b"", b"")
    empty = work / "empty.in"
    empty.write_bytes(b"")
    with empty.open("rb") as source:
        file_eof = subprocess.run(command, stdin=source, capture_output=True, timeout=5)
    require((file_eof.returncode, file_eof.stdout, file_eof.stderr) == expected,
            f"空文件结束异常：{file_eof!r}")
    pipe_eof = subprocess.run(command, input=b"", capture_output=True, timeout=5)
    require((pipe_eof.returncode, pipe_eof.stdout, pipe_eof.stderr) == expected,
            f"关闭输入管道的结果异常：{pipe_eof!r}")


def reject_frames(command: list[str], work: Path) -> None:
    cases = {
        "missing": b"X: 1\r\n\r\n",
        "duplicate": b"Content-Length: 1\r\ncontent-length: 1\r\n\r\n",
        "overflow": b"Content-Length: 9999999999999999999999999999\r\n\r\n",
        "long": b"Content-Length: 0\r\nX:" + b" " * 8186 + b"\r\n\r\n",
        "bad-line": b"Content-Length: 1\n\n",
        "short-header": b"Content-Length: 3\r\n",
        "short-body": b"Content-Length: 3\r\n\r\nxy",
    }
    for name, data in cases.items():
        # 重定向文件使截断输入在所有宿主上都表现为普通 EOF。
        path = work / f"{name}.in"
        path.write_bytes(data)
        with path.open("rb") as source:
            r = subprocess.run(command, stdin=source, capture_output=True, timeout=10)
        require(r.returncode == 2 and not r.stdout and not r.stderr,
                f"{name}：退出 {r.returncode}，标准输出 {r.stdout!r}，标准错误 {r.stderr!r}")


def structure_exchange(send, receive, quiet, *, hierarchy) -> int:
    uri = "file:///C:/Yak%20Work/结构.yak"
    rows = ("export struct Pair {", "    left: u32,", "    right: u32", "}",
            "const K: u32 = 2;", "function f(flag: bool): u32 {", "    /* 中😀 { } */ if flag {",
            "        return 1;", "    }", "    return K;", "}")
    source = chr(10).join(rows) + chr(10)

    def encoded(**fields):
        return wire(json.dumps({"jsonrpc": "2.0", **fields}, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    def span(a, b, c, d):
        return {"start": {"line": a, "character": b}, "end": {"line": c, "character": d}}

    def symbol(name, kind, row, col, end_row):
        selection = span(row, col, row, col + len(name))
        if hierarchy:
            return {"name": name, "kind": kind, "range": span(row, 0, end_row, len(rows[end_row])),
                    "selectionRange": selection}
        return {"name": name, "kind": kind, "location": {"uri": uri, "range": selection}}

    def query(method, identifier, result=None, *, invalid=False):
        send(encoded(id=identifier, method=f"textDocument/{method}", params={"textDocument": {"uri": 1 if invalid else uri}}))
        if invalid:
            receive(encoded(id=identifier, error={"code": -32602, "message": "Invalid params"}), identifier)
        else:
            receive(encoded(id=identifier, result=result), identifier)

    def published(diagnostics=None):
        receive(encoded(method="textDocument/publishDiagnostics", params={"uri": uri, "diagnostics": diagnostics or []}),
                "结构用例版本已提交")

    caps = {"textDocument": {"documentSymbol": {"hierarchicalDocumentSymbolSupport": True}}} if hierarchy else {}
    send(encoded(id=1, method="initialize", params={"capabilities": caps}))
    receive(encoded(id=1, result={"capabilities": candidate_capabilities()}), "结构查询能力")
    send(encoded(method="initialized"))
    query("documentSymbol", "未打开无符号")
    query("foldingRange", "非法折叠 URI", invalid=True)
    send(encoded(method="textDocument/didOpen", params={"textDocument": {"uri": uri, "languageId": "yak", "version": 1, "text": source}}))
    published()
    query("documentSymbol", "名称和范围", [symbol("Pair", 23, 0, 14, 3), symbol("K", 14, 4, 6, 4), symbol("f", 12, 5, 9, 10)])
    query("foldingRange", "声明及嵌套块按源码排序", [{"startLine": 0, "endLine": 2},
                                                          {"startLine": 5, "endLine": 9}, {"startLine": 6, "endLine": 7}])
    send(encoded(method="textDocument/documentSymbol", params={"textDocument": {"uri": uri}}))
    quiet("无 id 文档符号保持静默")
    def change(version, text):
        send(encoded(method="textDocument/didChange", params={"textDocument": {"uri": uri, "version": version}, "contentChanges": [{"text": text}]}))

    change(2, source.replace("return K;", "return K + missing;"))
    published([{"range": span(9, 15, 9, 22), "severity": 1, "source": "yak", "code": "E4002", "message": "Yak 名称诊断 E4002"}])
    query("documentSymbol", "名称错误仍保留本版符号", [symbol("Pair", 23, 0, 14, 3), symbol("K", 14, 4, 6, 4), symbol("f", 12, 5, 9, 10)])
    query("foldingRange", "名称错误仍保留本版折叠", [{"startLine": 0, "endLine": 2}, {"startLine": 5, "endLine": 9}, {"startLine": 6, "endLine": 7}])
    change(3, "; " + source)
    published([{"range": span(0, 0, 0, 1), "severity": 1, "source": "yak", "code": "E2001", "message": "Yak 解析诊断 E2001"}])
    query("documentSymbol", "解析错误不返回恢复后的符号")
    query("foldingRange", "解析错误不返回恢复后的折叠")
    for version, text in ((4, chr(10)), (5, "//中😀")):
        change(version, text)
        if version == 4:
            published()
            query("documentSymbol", "空结构是空数组", [])
            query("foldingRange", "无折叠是空数组", [])
        else:
            published([{"range": span(0, 5, 0, 5), "severity": 1, "source": "yak", "code": "E1018", "message": "Yak 词法诊断 E1018"}])
            query("documentSymbol", "词法失败不复用旧符号")
            query("foldingRange", "词法失败不复用旧折叠")
    send(encoded(method="textDocument/didClose", params={"textDocument": {"uri": uri}}))
    published()
    query("documentSymbol", "关闭后无符号")
    query("foldingRange", "关闭后无折叠")
    send(encoded(id=10, method="shutdown"))
    receive(encoded(id=10, result=None), "关闭结构查询服务")
    send(encoded(method="exit"))
    return 0


def definition_exchange(send, receive, quiet) -> int:
    uri = "file:///C:/Yak%20Work/中.yak"

    def encoded(**fields):
        return wire(json.dumps({"jsonrpc": "2.0", **fields}, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    def query(identifier, line, column, *, expected=None, error=None):
        send(encoded(id=identifier, method="textDocument/definition", params={
            "textDocument": {"uri": uri}, "position": {"line": line, "character": column}}))
        if error is not None:
            receive(encoded(id=identifier, error={"code": error, "message": "Invalid params"}), "非法定义参数")
        else:
            receive(encoded(id=identifier, result=expected), "当前文档定义结果")

    def location(line, start, length):
        return {"uri": uri, "range": {"start": {"line": line, "character": start},
                                      "end": {"line": line, "character": start + length}}}

    def hover(identifier, line, column, *, text=None, start=0, length=0, invalid=False):
        send(encoded(id=identifier, method="textDocument/hover", params={
            "textDocument": {"uri": uri}, "position": {"line": line, "character": column}}))
        if invalid:
            receive(encoded(id=identifier, error={"code": -32602, "message": "Invalid params"}), "非法悬停参数")
        else:
            result = None if text is None else {"contents": {"kind": "plaintext", "value": text},
                                                "range": location(line, start, length)["range"]}
            receive(encoded(id=identifier, result=result), "当前文档悬停结果")

    def complete(identifier, line, column, items=None, *, start=None, end=None, incomplete=False, invalid=False):
        send(encoded(id=identifier, method="textDocument/completion", params={
            "textDocument": {"uri": uri}, "position": {"line": line, "character": column}}))
        if invalid:
            receive(encoded(id=identifier, error={"code": -32602, "message": "Invalid params"}), "非法补全参数")
            return
        result = None
        if items is not None:
            range_value = location(line, column if start is None else start,
                                   (column if end is None else end) - (column if start is None else start))["range"]
            result = {"isIncomplete": incomplete, "items": [
                {"label": name, "kind": kind, "textEdit": {"range": range_value, "newText": name}}
                for name, kind in items]}
        receive(encoded(id=identifier, result=result), "同版补全结果")

    def semantic(identifier, data=None, *, params=None, invalid=False):
        if params is None:
            params = {"textDocument": {"uri": uri}}
        send(encoded(id=identifier, method="textDocument/semanticTokens/full", params=params))
        if invalid:
            receive(encoded(id=identifier, error={"code": -32602, "message": "Invalid params"}), "非法语义记号参数")
        else:
            receive(encoded(id=identifier, result=None if data is None else {"data": data}), "当前版本完整语义记号")

    def opened(text, version):
        send(encoded(method="textDocument/didOpen", params={"textDocument": {
            "uri": uri, "languageId": "yak", "version": version, "text": text}}))

    def changed(text, version):
        send(encoded(method="textDocument/didChange", params={"textDocument": {"uri": uri, "version": version},
                                                               "contentChanges": [{"text": text}]}))

    def published(diagnostics=None):
        receive(encoded(method="textDocument/publishDiagnostics", params={"uri": uri, "diagnostics": diagnostics or []}),
                "文档状态已发布")

    send(encoded(id=1, method="initialize", params={"capabilities": {}}))
    receive(encoded(id=1, result={"capabilities": candidate_capabilities()}), "候选服务声明同版查询与完整语义记号")
    send(encoded(method="initialized"))
    send(encoded(id="空工作区", method="workspace/symbol", params={"query": "run"}))
    receive(encoded(id="空工作区", result=[]), "没有索引内容时返回空工作区符号列表")
    query("未打开", 0, 0)
    hover("悬停未打开", 0, 0)
    complete("补全未打开", 0, 0)
    semantic("记号未打开")
    semantic("非法记号 URI", params={"textDocument": {"uri": "not a uri"}}, invalid=True)
    semantic("非法记号文档", params={"textDocument": []}, invalid=True)
    for mode in ("range", "full/delta"):
        send(encoded(id=mode, method=f"textDocument/semanticTokens/{mode}", params={"textDocument": {"uri": uri}}))
        receive(encoded(id=mode, error={"code": -32601, "message": "Method not found"}), "不开放范围和增量记号")
    source = 'function f(arg: u32): u32 { let text: &[u8] = "中😀"; return arg + (@len(text) as u32); }\n'
    use = len(source[:source.rindex("arg")].encode("utf-16-le")) // 2
    decl = source.index("arg")
    opened(source, 1)
    published()
    query("定义😀", 0, use + 1, expected=location(0, decl, 3))
    hover("悬停😀", 0, use + 1, text="arg: u32", start=use, length=3)
    hover("参数声明", 0, decl, text="arg: u32", start=decl, length=3)
    hover("函数声明", 0, 9, text="function f(u32): u32", start=9, length=1)
    text_decl = source.index("text")
    hover("切片类型", 0, text_decl, text="text: &[u8]", start=text_decl, length=4)
    hover("空白", 0, use - 1)
    hover("半开区间", 0, use + 3)
    hover("非法参数", -1, use, invalid=True)
    query(2, 0, use - 1)
    query(3, -1, use, error=-32602)
    query(4, 0, 1.5, error=-32602)
    changed("\n" + source, 2)
    published()
    query(5, 0, use)
    query(6, 1, use, expected=location(1, decl, 3))
    hover("旧位置", 0, use)
    hover("新位置", 1, use, text="arg: u32", start=use, length=3)
    broken = "\n" + source + "//中😀"
    changed(broken, 3)
    eof = {"line": 2, "character": 5}
    published([{"range": {"start": eof, "end": eof}, "severity": 1, "source": "yak",
                "code": "E1018", "message": "Yak 词法诊断 E1018"}])
    query(7, 1, use)
    hover("错误版", 1, use)
    send(encoded(method="textDocument/didClose", params={"textDocument": {"uri": uri}}))
    published()
    query(8, 1, use)
    hover("关闭后", 1, use)
    opened(source, 1)
    published()
    query(9, 0, use, expected=location(0, decl, 3))
    send(encoded(method="textDocument/definition", params={"textDocument": {"uri": uri},
                                                          "position": {"line": 0, "character": use}}))
    send(encoded(method="textDocument/hover", params={"textDocument": {"uri": uri},
                                                      "position": {"line": 0, "character": use}}))
    quiet("定义和悬停通知静默")
    shadow = ('function shadow(arg: u32): u32 {\n'
              '    if arg > 0 {\n'
              '        let arg: bool = true;\n'
              '        if arg { return 1; }\n'
              '    }\n'
              '    return arg;\n'
              '}\n')
    changed(shadow, 2)
    published()
    hover("内层", 3, 12, text="arg: bool", start=11, length=3)
    hover("外层", 5, 12, text="arg: u32", start=11, length=3)
    typed = 'function typed(a: [u32; 2], b: &[u8]): u32!AllocError { return a[0] + (@len(b) as u32); }\n'
    changed(typed, 3)
    published()
    hover("复合签名", 0, 9, text="function typed([u32; 2], &[u8]): u32!AllocError", start=9, length=5)
    long_name = "n" * 510
    long_label = f"function {long_name}(): u32 {{ return 1; }}\nfunction detail(): u32 {{ return {long_name}(); }}\n"
    changed(long_label, 4)
    published()
    call_at = long_label.splitlines()[1].index(long_name)
    query("超限仍可定义", 1, call_at, expected=location(0, 9, len(long_name)))
    hover("超限不显示部分签名", 1, call_at)
    hover("超限不影响其他签名", 1, 9, text="function detail(): u32", start=9, length=6)
    completed = ('function candidate(): u32 { return 1; }\n'
                 'function test(param: u32): u32 {\n'
                 '    if param > 0 {\n'
                 '        \n'
                 '        let candidate: u32 = param;\n'
                 '        /* 中😀 */ return candidate;\n'
                 '    }\n'
                 '    return candidate();\n'
                 '}\n')
    keywords = "as break const continue else elseif enum export false foreign function if import let match out return struct true var while".split()
    def candidates(*symbols):
        return sorted([(word, 14) for word in keywords] + list(symbols))

    changed(completed, 5)
    published()
    complete("前置遮蔽不回退全局", 3, 8, candidates(("param", 6), ("test", 3)))
    row = completed.splitlines()[5]
    start = len(row[:row.index("candidate")].encode("utf-16-le")) // 2
    complete("内层只保留变量", 5, start + 2, [("candidate", 6)], start=start, end=start + 9)
    complete("嵌套注释内无补全", 5, 13)
    complete("外层只保留函数", 7, 13, [("candidate", 3)], start=11, end=20)
    complete("关键字同源", 7, 6, [("return", 14)], start=4, end=10)
    complete("负数位置", 5, -1, invalid=True)
    complete("代理对中间", 5, len(row[:row.index("😀")].encode("utf-16-le")) // 2 + 1)
    complete("超行", 90, 0)
    send(encoded(method="textDocument/completion", params={"textDocument": {"uri": uri},
                                                          "position": {"line": 0, "character": 0}}))
    quiet("无 id 补全保持静默")

    def many(count):
        functions = [f"function z{i:02}(): u32 {{ return {i}; }}" for i in range(count)]
        return "\n" + "\n".join(reversed(functions)) + "\n"

    changed(many(11), 6)
    published()
    complete("恰好 32 项", 0, 0, candidates(*[(f"z{i:02}", 3) for i in range(11)]))
    changed(many(12), 7)
    published()
    complete("第 33 项截断", 0, 0, candidates(*[(f"z{i:02}", 3) for i in range(11)]), incomplete=True)
    complete("新版本不含旧名称", 0, 0, candidates(*[(f"z{i:02}", 3) for i in range(11)]), incomplete=True)
    members = ('struct Pair { unlisted: u32 }\n'
               'function project(pair: Pair): u32 { return pair.unlisted; }\n')
    changed(members, 8)
    published()
    projection = members.splitlines()[1]
    field = projection.index("unlisted")
    complete("结构体成员开头返回字段候选", 1, field, [("unlisted", 5)], start=field, end=field + 8)
    complete("结构体成员中途按前缀过滤字段候选", 1, field + 3, [("unlisted", 5)], start=field, end=field + 8)
    declaration = members.splitlines()[0].index("unlisted")
    complete("合法位置无匹配返回空列表", 0, declaration + 3, [], start=declaration, end=declaration + 8)
    literal = 'function literal(): u32 { let text: &[u8] = "中😀"; return text[0] as u32; }\n'
    changed(literal, 9)
    published()
    inside = len(literal[:literal.index("中") + 1].encode("utf-16-le")) // 2
    complete("字符串字面量中不返回候选", 0, inside)
    token_source = chr(10).join(('function f(): u32 {', '    let text: &[u8] = "中😀";',
                                 '    /* 中😀 */ return text[0] as u32 + 7u32;', '}', ''))
    token_data = [
        0, 0, 8, 0, 0, 0, 10, 1, 3, 0, 0, 1, 1, 3, 0, 0, 1, 1, 3, 0, 0, 6, 1, 3, 0,
        1, 4, 3, 0, 0, 0, 8, 1, 3, 0, 0, 2, 1, 3, 0, 0, 1, 1, 3, 0, 0, 3, 1, 3, 0,
        0, 2, 1, 3, 0, 0, 2, 5, 1, 0, 0, 5, 1, 3, 0,
        1, 14, 6, 0, 0, 0, 11, 1, 3, 0, 0, 1, 1, 2, 0, 0, 1, 1, 3, 0,
        0, 2, 2, 0, 0, 0, 7, 1, 3, 0, 0, 2, 4, 2, 0, 0, 4, 1, 3, 0, 1, 0, 1, 3, 0,
    ]
    changed(token_source, 10)
    published()
    semantic("同版 UTF-16 记号", token_data)
    send(encoded(method="textDocument/semanticTokens/full", params={"textDocument": {"uri": uri}}))
    quiet("无 id 记号请求保持静默")
    changed(token_source.replace("7u32", "oops"), 11)
    published([{"range": location(2, 38, 4)["range"], "severity": 1, "source": "yak",
                "code": "E4002", "message": "Yak 名称诊断 E4002"}])
    semantic("名称错误仍返回本版词法记号", token_data[:-15] + [0, 6, 1, 3, 0, 1, 0, 1, 3, 0])
    changed("// 仅注释" + chr(10), 12)
    published()
    semantic("词法成功的空记号表", [])
    changed(token_source + "//中😀", 13)
    eof = {"line": 4, "character": 5}
    published([{"range": {"start": eof, "end": eof}, "severity": 1, "source": "yak",
                "code": "E1018", "message": "Yak 词法诊断 E1018"}])
    complete("错误版无旧候选", 0, 0)
    semantic("词法失败没有局部或旧记号")
    changed(";" * 2049 + chr(10), 14)
    receive(encoded(method="window/logMessage", params={"type": 2, "message": "Yak: 源码 token 数量超出上限，分析不完整"}),
            "词法记号预算降级")
    published()
    semantic("词法记号超预算不返回前缀")
    changed(token_source, 15)
    published()
    semantic("词法修复后重建记号", token_data)
    send(encoded(method="textDocument/didClose", params={"textDocument": {"uri": uri}}))
    published()
    complete("关闭后无候选", 0, 0)
    semantic("关闭后无记号")
    send(encoded(id=10, method="shutdown"))
    receive(encoded(id=10, result=None), "关闭候选服务")
    send(encoded(method="exit"))
    return 0


def workspace_exchange(send, receive, quiet) -> int:
    consumer = "file:///z%20consumer.yak"
    service = "file:///a%20service.yak"
    alias = "file:///z%20consumer%2Eyak"
    source = "import service; function wrap(x: u32): u32 { return service::run(x); }" + chr(10)
    service_source = "export function run(x: u64): u64 { return x; }" + chr(10)

    def encoded(**fields):
        return wire(json.dumps({"jsonrpc": "2.0", **fields}, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    def opened(uri, text, version):
        send(encoded(method="textDocument/didOpen", params={"textDocument": {
            "uri": uri, "languageId": "yak", "text": text, "version": version}}))

    def changed(uri, text, version):
        send(encoded(method="textDocument/didChange", params={"textDocument": {"uri": uri, "version": version},
                                                              "contentChanges": [{"text": text}]}))

    def close(uri):
        send(encoded(method="textDocument/didClose", params={"textDocument": {"uri": uri}}))

    def publish(uri, version, diagnostics):
        params = {"uri": uri}
        if version is not None:
            params["version"] = version
        params["diagnostics"] = diagnostics
        receive(encoded(method="textDocument/publishDiagnostics", params=params), f"同版诊断或关闭清空：{uri}，版本 {version}")

    def clean(uri, version=None):
        publish(uri, version, [])

    def reference_failure(member, code, version):
        qualified = "service::" + member
        text = source.replace("service::run", qualified)
        start = text.index(qualified)
        changed(consumer, text, version)
        # 名称解析诊断沿用路径首段的 AST 跨度，协议层不扩张范围。
        publish(consumer, version, [{"range": {"start": {"line": 0, "character": start},
                  "end": {"line": 0, "character": start + len("service")}}, "severity": 1,
                  "source": "yak", "code": code, "message": f"Yak 名称诊断 {code}"}])

    def degraded(uri, version):
        receive(encoded(method="window/logMessage", params={"type": 2, "message": "Yak: 缺少可信依赖，诊断分析不完整"}),
                "未授权或已遮蔽的依赖降级")
        clean(uri, version)

    def definition(identifier, uri, result):
        send(encoded(id=identifier, method="textDocument/definition", params={"textDocument": {"uri": uri},
                     "position": {"line": 0, "character": 61}}))
        receive(encoded(id=identifier, result=result), "校验当前工作区定义")

    def symbols(identifier, params, result=None, error=None):
        send(encoded(id=identifier, method="workspace/symbol", params=params))
        fields = {"error": {"code": error[0], "message": error[1]}} if error else {"result": result}
        receive(encoded(id=identifier, **fields), "可信工作区符号：" + identifier)

    target = {"uri": service, "range": {"start": {"line": 0, "character": 16}, "end": {"line": 0, "character": 19}}}
    public = [{"name": "run", "kind": 12, "location": target}]
    invalid = (-32602, "Invalid params")
    send(encoded(id=1, method="initialize", params={"capabilities": {"textDocument": {
        "publishDiagnostics": {"versionSupport": True}}}}))
    receive(encoded(id=1, result={"capabilities": candidate_capabilities()}), "配置候选握手")
    send(encoded(method="initialized"))
    symbols("全部公开符号", {"query": ""}, public)
    symbols("不区分 ASCII 大小写的子序列", {"query": "RN"}, public)
    symbols("私有声明", {"query": "hidden"}, [])
    symbols("精确长度上限", {"query": "中" * 84 + "😀"}, [])
    symbols("超出长度上限", {"query": "中" * 84 + "😀a"}, error=invalid)
    symbols("缺少查询", {}, error=invalid)
    symbols("非字符串查询", {"query": 1}, error=invalid)
    symbols("非对象参数", [], error=invalid)
    opened(consumer, source, 1)
    clean(consumer, 1)
    definition(2, consumer, target)
    opened(alias, source, 1)
    degraded(alias, 1)
    definition(3, alias, None)
    definition(4, consumer, target)
    opened(service, service_source, 1)
    clean(service, 1)
    degraded(consumer, 1)
    definition(5, consumer, None)
    symbols("遮蔽时拒绝返回部分符号", {"query": ""}, error=(-32803, "Trusted workspace symbol coverage unavailable"))
    changed(service, service_source, 2)
    clean(service, 2)
    quiet("仍遮蔽时不重新发布同版消费者诊断")
    changed(consumer, source, 2)
    degraded(consumer, 2)
    close(service)
    clean(service)
    clean(consumer, 2)
    definition(6, consumer, target)
    symbols("关闭缓冲后恢复符号", {"query": "run"}, public)
    close(consumer)
    clean(consumer)
    opened(consumer, source, 1)
    clean(consumer, 1)
    definition(7, consumer, target)
    # 同一份可信接口区分私有名与未知名；修正源码后恢复跨文件定义。
    reference_failure("hidden", "E4008", 2)
    reference_failure("absent", "E4002", 3)
    changed(consumer, source, 4)
    clean(consumer, 4)
    definition(8, consumer, target)
    send(encoded(id=9, method="shutdown"))
    receive(encoded(id=9, result=None), "关闭配置候选")
    send(encoded(method="exit"))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("frame", "rpc", "sync", "diagnostics", "candidate", "definition", "workspace"), default="frame")
    parser.add_argument("label")
    parser.add_argument("work", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("缺少探针执行命令")
    try:
        if args.mode == "workspace":
            open_pipe(args.command, workspace_exchange)
            print(f"{args.label}：可信工作区诊断、定义、符号及遮蔽恢复验证通过")
            return 0
        if args.mode == "definition":
            open_pipe(args.command, definition_exchange)
            open_pipe(args.command, lambda *pipe: structure_exchange(*pipe, hierarchy=False))
            open_pipe(args.command, lambda *pipe: structure_exchange(*pipe, hierarchy=True))
            print(f"{args.label}：定义、悬停、补全、记号及文档结构定向验证通过")
            return 0
        check_eof(args.command, args.work, 0 if args.mode == "frame" else 1)
        if args.mode == "frame":
            open_pipe(args.command, frame_exchange)
        elif args.mode == "rpc":
            open_pipe(args.command, rpc_exchange)
            open_pipe(args.command, rpc_early_exit)
        elif args.mode == "sync":
            open_pipe(args.command, sync_exchange)
            open_pipe(args.command, rpc_early_exit)
        else:
            candidate = args.mode == "candidate"
            if candidate:
                # 既验证客户端顺序和不支持项的回退，也核对顺序编辑和失败回滚的坐标。
                encodings = ((["utf-8", "utf-32"], "utf-8", 9, 4),
                             (["utf-64", "utf-32", "utf-8"], "utf-32", 4, 1),
                             (["utf-64"], "utf-16", 5, 2))
                for offered, encoding, column, emoji_units in encodings:
                    open_pipe(args.command, lambda *pipe: position_encoding_exchange(
                        *pipe, offered=offered, encoding=encoding, column=column, emoji_units=emoji_units))
                print(f"{args.label}：三种位置编码的顺序增量、回滚与全量替换通过", flush=True)
                open_pipe(args.command, cancellation_exchange)
                print(f"{args.label}：取消通知静默、编号隔离及恢复通过", flush=True)
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate))
            # 解释器进程的步数和逐文档配额独立；每组仍连续验证超限与恢复。
            for group in ("join", "copy", "scope"):
                open_pipe(args.command, lambda *pipe, group=group: diagnostics_exchange(
                    *pipe, candidate=candidate, slice_budget=group))
            # 各语义场景保留组内连续版本，不共享解释器进程的累计步数。
            for exchange in (signature_index_exchange, function_scope_exchange, const_input_exchange):
                open_pipe(args.command, lambda *pipe, exchange=exchange: diagnostics_exchange(
                    *pipe, candidate=candidate, semantic_exchange=exchange))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, borrow_conflicts=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, place_merges=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, place_lookups=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, place_exits=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, slot_jumps=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, slice_jumps=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, name_lookups=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, reservations=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, enum_lookups=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, reference_outputs=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, value_graphs=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, formal_layouts=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, decl_interns=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, const_snapshots=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, body_interns=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, lex_interns=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, const_inits=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, const_materials=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, const_folds=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, integer_probes=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, integer_scans=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, integer_shapes=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, array_inferences=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, ctor_fields=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, match_scans=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, match_paths=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, parse_recoveries=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, out_refs=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, projections=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, equalities=True))
            open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, candidate=candidate, slice_assignments=True))
            for capability in ("false", "missing", "string", "duplicate"):
                open_pipe(args.command, lambda *pipe: diagnostics_exchange(*pipe, capability=capability, candidate=candidate))
            open_pipe(args.command, rpc_early_exit)
        reject_frames(args.command, args.work)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"管道探针：{args.label}/{args.mode} 失败：{exc}", file=sys.stderr)
        return 1
    print(f"管道探针：{args.label}/{args.mode} 开放管道、连续帧和异常边界通过")
    return 0


def signature_index_exchange(send, receive, changed, publication, _log):
    # 被调函数后声明；插入非函数定义后同名函数使用新的定义编号。
    caller = "function caller(): void { out r: u32; fill(out r); }\n"
    good_call = caller + "function fill(x: &u32:Write): void { *x = 1u32; }\n"
    bad_call = (caller + "struct Gap { value: u32 }\n"
                "function fill(x: &bool:Write): void { *x = true; }\n")
    call_col = caller.index("out r)")
    wrong_param = {"range": {"start": {"line": 0, "character": call_col},
                             "end": {"line": 0, "character": call_col + 3}},
                   "severity": 1, "source": "yak", "code": "E5001", "message": "Yak 类型或布局诊断 E5001"}
    send(changed(good_call, 78))
    receive(publication(78), "签名索引支持前向调用和 Write 槽提交")
    send(changed(bad_call, 79))
    receive(publication(79, [wrong_param]), "定义编号变动后仍检查当前版本的签名")
    send(changed(good_call, 80))
    receive(publication(80), "恢复参数签名后清空调用点错误")


def projection_exchange(send, receive, changed, publication, log):
    # 23 次末字段查询各用 43 步；末次查询分别用 35 或 36 步。
    def source(over=False, bad=False):
        text = "function broken(): void { let n: bool = 1u32; if n { return; } }\n" if bad else ""
        text += "struct S { " + ", ".join(f"a{i}: u32" for i in range(32)) + " }\n"
        for name in "fgh":
            fields = ["s.a31"] * (7 if name == "h" else 8)
            if name == "h":
                fields.append("s.a24" if over else "s.a23")
            expr = " + ".join(fields)
            text += f"function {name}(s: &S:Read): u32 {{ return {expr}; }}\n"
        return text

    col = len("function broken(): void { ")
    error = {"range": {"start": {"line": 0, "character": col},
                       "end": {"line": 0, "character": col + len("let n: bool = 1u32;")}},
             "severity": 1, "source": "yak", "code": "E5001",
             "message": "Yak 类型或布局诊断 E5001"}
    stop = log("Yak: 本地字段投影扫描超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "1024 行字段投影仍完成")
    send(changed(source(bad=True), 2))
    receive(publication(2, [error]), "1024 行仍发布真实类型错误")
    send(changed(source(over=True, bad=True), 3))
    receive(stop, "第 1025 行前停止并报告字段投影分析不完整")
    receive(publication(3), "不发布先前局部类型诊断")
    send(changed(source(over=True), 4))
    receive(stop, "合法源码字段投影超限也明确报告")
    receive(publication(4), "合法源码字段投影超限清空当前版本")
    send(changed(source(), 5))
    receive(publication(5), "改版后字段投影预算重置")


def equality_exchange(send, receive, changed, publication, log):
    # E 需两次比较和 30 个槽，Q 需一次比较和 31 或 32 个槽。
    def source(over=False, bad=False, prior=False):
        tags = [f"V{i}" for i in range(30)]
        extra = (["Pad"] if over else []) + ["Last([u32; 2])" if bad else "Last"]
        text = "function broken(): void { let n: bool = 1u32; if n { return; } }\n" if prior else ""
        text += "enum E { " + ", ".join(tags) + " }\n"
        text += "enum Q { " + ", ".join(tags + extra) + " }\n"
        text += "function consume(value: bool): void { if value { return; } }\n"
        for name, count in (("f", 8), ("g", 8), ("h", 8), ("k", 7)):
            op = "!=" if name == "k" else "=="
            text += f"function {name}(a: E, b: E): void {{ " + f"consume(a {op} b); " * count + "}\n"
        return text + "function last(a: Q, b: Q): bool { return a == b; }\n"

    col = len("function last(a: Q, b: Q): bool { return a ")
    error = {"range": {"start": {"line": 7, "character": col},
                       "end": {"line": 7, "character": col + len("==")}},
             "severity": 1, "source": "yak", "code": "E5809",
             "message": "Yak 类型或布局诊断 E5809"}
    stop = log("Yak: 本地等值比较扫描超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "1024 次等值扫描仍完成")
    send(changed(source(bad=True), 2))
    receive(publication(2, [error]), "恰好用完仍发布真实 E5809")
    send(changed(source(over=True, bad=True, prior=True), 3))
    receive(stop, "第 1025 次读取前停止并报告分析不完整")
    receive(publication(3), "不发布先前的 E5001 或未经确认的 E5809")
    send(changed(source(over=True), 4))
    receive(stop, "语义合法版本超限也明确报告")
    receive(publication(4), "合法版本超限仍只清空")
    send(changed(source(), 5))
    receive(publication(5), "改版后比较预算重置")

    # 旧路径每次扫描 36 条定义及一个槽，共 1147 步。
    pressure = "".join(f"enum P{i} {{ V }}\n" for i in range(35)) + "enum E { V }\n"
    pressure += "function consume(value: bool): void { if value { return; } }\n"
    for name, count in (("f", 8), ("g", 8), ("h", 8), ("k", 7)):
        pressure += f"function {name}(a: E, b: E): void {{ " + "consume(a == b); " * count + "}\n"
    send(changed(pressure, 6))
    receive(publication(6), "反复比较同一枚举不再遍历无关定义")


def function_scope_exchange(send, receive, changed, publication, _log):
    # 末尾函数跨过多层子作用域；早期函数的同名形参属于另一类型。
    first = "function first(x: bool): bool { if x { return true; } return false; }\n"
    first += "".join(f"function gap{i}(): void {{ if true {{}} if false {{}} }}\n" for i in range(24))
    last = "function last(x: u32[], z: bool): void { if z { let x: bool = z; if x {} } let n: u64 = @len(x); @drop(n); @drop(x); "
    good = first + last + "}\n"
    bad = first + "struct Gap { value: u32 }\n" + last + "@drop(x); }\n"
    line = bad.count("\n") - 1
    col = len(last)
    error = {"range": {"start": {"line": line, "character": col},
                       "end": {"line": line, "character": col + 5}},
             "severity": 1, "source": "yak", "code": "E6003",
             "message": "Yak 所有权诊断 E6003"}
    send(changed(good, 81))
    receive(publication(81), "末尾函数从自身块定位同名形参")
    send(changed(bad, 82))
    receive(publication(82, [error]), "定义编号变化后仍报告末尾函数的重复释放")
    send(changed(good, 83))
    receive(publication(83), "恢复单次释放后清空诊断")
    duplicate_params = "function duplicate(x: bool, x: bool): void { if x {} }\n"
    col = duplicate_params.rindex("bool")
    unused_param = {"range": {"start": {"line": 0, "character": col},
                              "end": {"line": 0, "character": col}},
                    "severity": 1, "source": "yak", "code": "E4009",
                    "message": "Yak 名称诊断 E4009"}
    duplicate_error = {"range": {"start": {"line": 0, "character": col},
                                 "end": {"line": 0, "character": col + len("bool")}},
                       "severity": 1, "source": "yak", "code": "E4011",
                       "message": "Yak 名称诊断 E4011"}
    send(changed(duplicate_params, 84))
    receive(publication(84, [unused_param, duplicate_error]), "重名形参在名称阶段拒绝，不进入直接寻址")
    send(changed(good, 85))
    receive(publication(85), "修正后重新分析形参并清空诊断")

    local = ("function locals(flag: bool): void { let x: bool = flag; if x { "
             "let x: u32[] = [1u32]; @drop(x); } let after: bool = x; if after {} }\n")
    bad_local = "struct Pad { item: u32 }\n" + local.replace("@drop(x);", "@drop(x); @drop(x);", 1)
    local_col = bad_local.splitlines()[1].rindex("@drop(x)")
    local_error = {"range": {"start": {"line": 1, "character": local_col},
                             "end": {"line": 1, "character": local_col + 5}},
                   "severity": 1, "source": "yak", "code": "E6003",
                   "message": "Yak 所有权诊断 E6003"}
    send(changed(local, 86))
    receive(publication(86), "内外同名局部具有各自的类型和所有权")
    send(changed(bad_local, 87))
    receive(publication(87, [local_error]), "局部 DefId 重排后仍只报告内层的重复释放")
    send(changed(local, 88))
    receive(publication(88), "局部声明索引按新版本重建并清空诊断")

    payload_match = ("enum E { A(u32[]), B(u32[]) }\n"
                     "function payload(e: E): void { match e { A(v) => { if true { "
                     "let v: bool = true; if v {} } @drop(v); }, B(v) => { @drop(v); } } }\n")
    bad_payload = "struct Pad { item: u32 }\n" + payload_match.replace(
        "B(v) => { @drop(v);", "B(v) => { @drop(v); @drop(v);", 1)
    payload_col = bad_payload.splitlines()[2].rindex("@drop(v)")
    payload_error = {"range": {"start": {"line": 2, "character": payload_col},
                               "end": {"line": 2, "character": payload_col + 5}},
                     "severity": 1, "source": "yak", "code": "E6003",
                     "message": "Yak 所有权诊断 E6003"}
    send(changed(payload_match, 89))
    receive(publication(89), "两个匹配臂的同名载荷和子块局部保持独立")
    send(changed(bad_payload, 90))
    receive(publication(90, [payload_error]), "匹配载荷重排后仍准确定位第二臂的重复释放")
    send(changed(payload_match, 91))
    receive(publication(91), "匹配载荷改版修正后清空诊断")

    first = "enum First { Full(bool), Empty }\n"
    gap = "struct Gap { item: u32 }\n"
    middle = "enum Middle { Full(u32), Empty }\n"
    last = "enum Last { Full(u16), Empty }\n"
    make = "function make(flag: bool): First { if flag { return First::Full(flag); } return First::Empty; }\n"
    extract = ("function extract(flag: bool): u16 { var e: Last = Last::Empty; "
               "if flag { e = Last::Full(1u16); } match e { Full(v) => { return v; }%s } }\n")
    end_arm = ", Last::Empty => { return 0u16; }"
    good = first + gap + middle + last + make + (extract % end_arm)
    reordered = last + gap + first + middle + make
    match_col = extract.index("match")
    match_line = reordered.count("\n")
    exhaustive_error = {"range": {"start": {"line": match_line, "character": match_col},
                                   "end": {"line": match_line, "character": match_col + 5}},
                        "severity": 1, "source": "yak", "code": "E2002",
                        "message": "Yak 解析诊断 E2002"}
    send(changed(good, 92))
    receive(publication(92), "不同宿主的同名变体仍获得各自的载荷类型")
    send(changed(reordered + (extract % ""), 93))
    receive(publication(93, [exhaustive_error]), "枚举 DefId 重排后仍准确报告匹配不穷尽")
    send(changed(reordered + (extract % end_arm), 94))
    receive(publication(94), "补齐重排枚举的限定标签后清空诊断")


def lex_intern_exchange(send, receive, changed, publication, log):
    def source(tail_size):
        # 第一个名称付 17 步，其后 12 次各付 1022；第二个名称在不同桶插入付 2，再复核 5 或 6 步。
        first = "a" * 1021
        tail = "b" * tail_size
        return (first + "\n") * 13 + (tail + "\n") * 2 + "@no_such_builtin\n"

    error = {"range": {"start": {"line": 15, "character": 0},
                       "end": {"line": 15, "character": len("@no_such_builtin")}},
             "severity": 1, "source": "yak", "code": "E1011", "message": "Yak 词法诊断 E1011"}
    send(changed(source(4), 1))
    receive(publication(1, [error]), "12288 步后仍发布真实词法错误")
    send(changed(source(5), 2))
    receive(log("Yak: 词法名称驻留超出上限，分析不完整") + publication(2), "第 12289 步前中止并按版清空")
    send(changed(source(4), 3))
    receive(publication(3, [error]), "新版本重新计费，恢复同一词法诊断")
    send(changed("function good(): void {}\n", 4))
    receive(publication(4), "改正后清空诊断")

    # 普通字节长串和转义后缀走同一个静态池，错误位置按 UTF-16 字符列计算。
    head = 'function size(a: &[u8]): u64 { return @len(a); } function literal(): u64 { return size("' + "a" * 8192 + "中😀"
    start = len(head.encode("utf-16-le")) // 2
    error = {"range": {"start": {"line": 0, "character": start},
                       "end": {"line": 0, "character": start + 1}},
             "severity": 1, "source": "yak", "code": "E1006", "message": "Yak 词法诊断 E1006"}
    send(changed(head + '"); }\n', 5))
    receive(publication(5), "长普通字符串进入完整文档检查")
    send(changed(head + '\\q"); }\n', 6))
    receive(publication(6, [error]), "长普通前缀不改变非法转义的范围")
    send(changed(head + '\\0尾\\u{1F600}末"); }\n', 7))
    receive(publication(7), "带多个转义与普通末段的字符串恢复诊断清空")


def body_intern_exchange(send, receive, changed, publication, log):
    def source(extra=False, bad=False):
        # 首行驻留 u32，之后 30 个名义类型，bool 的规范编号恰为 32。
        pad = "function pin(x: u32): u32 { return x; }\n"
        pad += "".join(f"struct S{i} {{ field: u32 }}\n" for i in range(30))
        pad += "function flag(x: bool): bool { return x; }\n"
        if bad:
            pad += "function bad(): void { return 1u32; }\n"
        pad += "function take(x: bool): void { @drop(x); }\nfunction take_u32(x: u32): void { @drop(x); }\n"
        prefix = "function first(): void { " + "take(true); " * 64 + "}\n"
        tail = "function last(): void { " + "take(true); " * 64
        return pad + prefix + tail + ("take_u32(1u32); " if extra else "") + "}\n"

    stop = log("Yak: 函数体类型驻留超出上限，分析不完整")
    send(changed(source(), 1))
    receive(publication(1), "跨函数 128 次查找恰好读取 4096 个候选")
    send(changed(source(extra=True), 2))
    receive(stop, "第 4097 个候选在读取前中止")
    receive(publication(2), "只清空当前版本")
    send(changed(source(extra=True, bad=True), 3))
    receive(stop, "已有返回错误不掩盖驻留超限")
    receive(publication(3), "不发布已收集的局部返回错误")
    bad = source(bad=True)
    line = 32
    col = bad.splitlines()[line].index("return")
    error = {"range": {"start": {"line": line, "character": col},
                       "end": {"line": line, "character": col + len("return")}},
             "severity": 1, "source": "yak", "code": "E2005", "message": "Yak 解析诊断 E2005"}
    send(changed(bad, 4))
    receive(publication(4, [error]), "改版重新计费并发布精确返回错误")
    send(changed(source(), 5))
    receive(publication(5), "再次修正后清空错误")


def const_snapshot_exchange(send, receive, changed, publication, log):
    def source(tail_params, mode):
        enums = "enum E { " + ", ".join(f"V{i}" for i in range(48)) + " }\n"
        structs = "".join(f"struct S{i} {{ field: u32 }}\n" for i in range(24))
        functions = []
        for index, count in enumerate([14] * 9 + [tail_params]):
            params = ", ".join(f"p{i}: u32" for i in range(count))
            used = " ".join(f"@drop(p{i});" for i in range(count))
            functions.append(f"function f{index}({params}): void {{ {used} }}\n")
        probe = "return 1u32;" if mode == "plain" else "return 1u32 as u32;"
        target = "void" if mode == "bad" else "u32"
        return enums + structs + f"function probe(): {target} {{ {probe} }}\n" + "".join(functions)

    # 类型 27，枚举行 1，载荷 48；定义 36 + 126 + 尾部形参数。
    # 18/19 个尾部形参分别使快照长度为 256/257。
    stop = log("Yak: 常量与整数诊断快照复制超出上限，分析不完整")
    send(changed(source(18, "cast"), 1))
    receive(publication(1), "256 条恰好可用")
    send(changed(source(19, "cast"), 2))
    receive(stop, "第 257 条在分配快照前明确降级")
    receive(publication(2), "只清空当前版本")
    send(changed(source(19, "plain"), 3))
    receive(publication(3), "相同大表没有消费者时跳过快照")
    send(changed(source(19, "bad"), 4))
    receive(stop, "类型错误不掩盖快照超限")
    receive(publication(4), "不发布已收集的局部类型错误")
    bad = source(18, "bad")
    line = 25
    col = bad.splitlines()[line].index("return")
    diagnostic = {"range": {"start": {"line": line, "character": col},
                             "end": {"line": line, "character": col + len("return")}},
                  "severity": 1, "source": "yak", "code": "E2005",
                  "message": "Yak 解析诊断 E2005"}
    send(changed(bad, 5))
    receive(publication(5, [diagnostic]), "预算内发布精确类型诊断")
    send(changed(source(18, "cast"), 6))
    receive(publication(6), "改版重新计费并清空诊断")


def const_input_exchange(send, receive, changed, publication, log):
    plain = "enum E { Full(u32), Empty } function f(): E { return E::Full(1u32); }\n"
    top = "const C: u32 = 1u32 / 0u32; function f(): u32 { return C; }\n"
    local = "function f(): u32 { const c: u32 = 1u32 / 0u32; return c; }\n"
    cast = "function f(): char { return (55295u32 + 1u32) as char; }\n"
    index = "function f(a: [u32; 2]): u32 { return a[1u32 + 1u32]; }\n"
    slice_ = "function f(a: [u32; 2]): u64 { return @len(&a[0u32..2u32 + 1u32]:Read); }\n"
    send(changed(plain, 95))
    receive(publication(95), "无快照消费者的文档仍完成分析")
    cases = [(top, "/", "E5008", "类型或布局诊断", "顶层常量"),
             (local, "/", "E5008", "类型或布局诊断", "局部常量"),
             (cast, "as", "E5001", "类型或布局诊断", "独立转换"),
             (index, "+", "E6002", "所有权诊断", "独立下标"),
             (slice_, "+", "E6002", "所有权诊断", "独立切片")]
    for version, (source, token, code, family, label) in enumerate(cases, 96):
        col = source.index(token)
        diagnostic = {"range": {"start": {"line": 0, "character": col},
                                 "end": {"line": 0, "character": col + len(token)}},
                      "severity": 1, "source": "yak", "code": code,
                      "message": f"Yak {family} {code}"}
        send(changed(source, version))
        receive(publication(version, [diagnostic]), f"按需快照保留{label}的精确诊断")
    send(changed(plain, 101))
    receive(publication(101), "去除快照消费者后清空上一版诊断")

    def nested_const(depth, element):
        initializer = "[" * depth + "1u32" + "]" * depth
        return "const C: " + "[" * depth + element + "; 1]" * depth + " = " + initializer + ";\n"

    for version, element, code, family in [(102, "&[u8]", "E2009", "解析诊断"),
                                           (103, "u32[]", "E5006", "类型或布局诊断")]:
        depth = 24
        col = len("const C: ") + depth
        diagnostic = {"range": {"start": {"line": 0, "character": col},
                                 "end": {"line": 0, "character": col + len(element)}},
                      "severity": 1, "source": "yak", "code": code,
                      "message": f"Yak {family} {code}"}
        send(changed(nested_const(depth, element), version))
        receive(publication(version, [diagnostic]), "常量定长数组链定位到首个受限元素")
    send(changed(nested_const(64, "u32"), 104))
    receive(log("Yak: 源码解析深度超出上限，分析不完整") + publication(104), "类型构造仍受解析限深约束")
    valid = nested_const(3, "u32") + "function value(): u32 { let a: [[[u32; 1]; 1]; 1] = C; return a[0][0][0]; }\n"
    send(changed(valid, 105))
    receive(publication(105), "改正嵌套元素类型后恢复分析")


if __name__ == "__main__":
    sys.exit(main())
