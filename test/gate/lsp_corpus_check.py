"""在原生宿主直启候选，测量万行文档和百文件分批周转。"""

from hashlib import sha256
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from time import perf_counter_ns

from lsp_frame_check import candidate_capabilities, open_pipe, require
from lsp_stress_check import Memory, PEAK_WORKING_SET_LIMIT, encoded, notice, percentile


LINES = 10_000
EDIT_COUNT = 40
STARTUP_COUNT = 20
ANALYSIS_BYTES = 16_384
DOCUMENT_BYTES = 4 * 1024 * 1024
ACTIVE_TEXT_BYTES = 4 * DOCUMENT_BYTES
SLOTS = 32
FILES = 100
CORPUS = (
    "flow/if_branch.yak", "flow/labeled_break.yak", "flow/match_enum_payload.yak", "flow/while_sum.yak",
    "owner/carrier_question.yak", "type/dyn_array_grow.yak", "type/slice_len.yak", "emit/out_slot_roundtrip.yak",
)
SUFFIX = "function lsp_corpus_tail(): u32 { return "
SYNC_LIMIT = notice("window/logMessage", type=2, message="Yak: 文档同步超出预算，保留原快照")
SOURCE_LIMIT = notice("window/logMessage", type=2, message="Yak: 源码超出候选分析字节上限，未执行前端")


def sha(data):
    return sha256(data).hexdigest()


def opened(uri, text, version=0):
    return notice("textDocument/didOpen", textDocument={"uri": uri, "languageId": "yak", "version": version, "text": text})


def changed(uri, text, version):
    return notice("textDocument/didChange", textDocument={"uri": uri, "version": version}, contentChanges=[{"text": text}])


def published(uri, diagnostics, version=None):
    params = {"uri": uri}
    if version is not None:
        params["version"] = version
    return notice("textDocument/publishDiagnostics", **params, diagnostics=diagnostics)


def unknown(line):
    col = len(SUFFIX)
    return [{"range": {"start": {"line": line, "character": col}, "end": {"line": line, "character": col + 7}},
             "severity": 1, "source": "yak", "code": "E4002", "message": "Yak 名称诊断 E4002"}]


def instrument(source, expression):
    return source + SUFFIX + expression + "; }\n"


def make_workspace(gate, work, report):
    workspace = work / "workspace"
    workspace.mkdir()
    originals = [(name, (gate.parent / "ok" / name).read_bytes()) for name in CORPUS]
    # 只规范测量副本的换行，避免工作区检出格式改变协议字节和诊断坐标。
    sources = [(name, data.decode("utf-8").replace("\r\n", "\n")) for name, data in originals]
    require(all(text.endswith("\n") and "\r" not in text for _, text in sources), "固定语料须有末尾换行且无裸 CR")
    report["corpus"] = [{"path": "test/ok/" + name, "original_sha256": sha(data),
                         "normalized_bytes": len(text.encode("utf-8")), "normalized_sha256": sha(text.encode("utf-8"))}
                        for (name, data), (_, text) in zip(originals, sources)]
    prefix = sources[4][1]
    tail = instrument("", "missing")
    padding = "\n" * (LINES - prefix.count("\n") - 1)
    spaces = " " * (ANALYSIS_BYTES - len((prefix + padding + tail).encode("utf-8")))
    bad = instrument(prefix + spaces + padding, "missing")
    good = instrument(prefix + spaces + padding, "1u32")
    over = " " + bad
    for name, text, length in (("bad", bad, ANALYSIS_BYTES), ("good", good, ANALYSIS_BYTES - 3),
                               ("over", over, ANALYSIS_BYTES + 1)):
        data = text.encode("utf-8")
        require(len(data) == length and text.count("\n") == LINES, "万行或字节边界夹具漂移")
        report["long_sources"][name] = {"lines": LINES, "bytes": length, "sha256": sha(data)}
    large = work / "万行 样本.yak"
    large.write_bytes(bad.encode("utf-8"))
    docs = []
    for i in range(FILES):
        name, source = sources[i % len(sources)]
        path = workspace / f"{i:03}-{Path(name).name}"
        path.write_bytes(source.encode("utf-8"))
        docs.append((path.as_uri(), source))
    return large.as_uri(), bad, good, over, docs


def initialize_frames():
    caps = {"textDocument": {"publishDiagnostics": {"versionSupport": True}}}
    result = {"capabilities": candidate_capabilities()}
    return encoded(id=1, method="initialize", params={"capabilities": caps}), encoded(id=1, result=result)


def measure_startups(command, report):
    request, response = initialize_frames()
    durations = report["process_startup_ns"]

    def exchange(send, receive, _quiet):
        send(request)
        receive(response, "新进程握手")
        durations.append(perf_counter_ns() - started)
        send(encoded(method="initialized"))
        send(encoded(id=2, method="shutdown"))
        receive(encoded(id=2, result=None), "新进程正常关闭")
        send(encoded(method="exit"))
        return 0

    # 每次重新创建进程；不清空操作系统文件缓存。
    for _ in range(STARTUP_COUNT):
        started = perf_counter_ns()
        open_pipe(command, exchange)
    report["process_startup_summary"] = {"count": len(durations), "p50_ns": percentile(durations, 50),
                                         "p95_ns": percentile(durations, 95)}


class Experiment:
    def __init__(self, report, corpus):
        self.report = report
        self.uri, self.bad, self.good, self.over, self.docs = corpus
        self.memory = None
        self.started = perf_counter_ns()
        self.identifier = 1

    def start(self, proc):
        self.memory = Memory(proc.pid)
        self.report["pid"] = proc.pid

    def sample(self, phase):
        sample = self.memory.sample()
        require(0 < sample["working_set_bytes"] <= sample["peak_working_set_bytes"] and sample[self.memory.retained_key] > 0,
                "未采到有效进程内存计数")
        self.report["samples"].append({"phase": phase, **sample})

    def exchange(self, send, receive, _quiet):
        def measure(group, label, packet, want):
            start = perf_counter_ns()
            send(packet)
            receive(want, label)
            elapsed = perf_counter_ns() - start
            self.report["measurements"].setdefault(group, []).append(
                {"label": label, "ns": elapsed, "sent_bytes": len(packet), "received_bytes": len(want),
                 "request_sha256": sha(packet), "response_sha256": sha(want)})

        def barrier():
            self.identifier += 1
            send(encoded(id=self.identifier, method="textDocument/references",
                         params={"textDocument": {"uri": self.uri}, "position": {"line": 0, "character": 0}}))
            receive(encoded(id=self.identifier, error={"code": -32601, "message": "Method not found"}), "通知处理完成")

        def close(uri, group, label):
            measure(group, label, notice("textDocument/didClose", textDocument={"uri": uri}), published(uri, []))

        measure("initialize", "候选握手", *initialize_frames())
        self.report["spawn_to_initialize_ns"] = perf_counter_ns() - self.started
        send(encoded(method="initialized"))
        barrier()
        self.sample("initialized")

        diagnostic = unknown(LINES - 1)
        measure("long_open", "万行文档第 10000 行名称诊断", opened(self.uri, self.bad), published(self.uri, diagnostic, 0))
        for version in range(1, EDIT_COUNT + 1):
            source = self.good if version % 2 else self.bad
            expected = [] if version % 2 else diagnostic
            measure("long_edit", f"万行编辑 {version}", changed(self.uri, source, version), published(self.uri, expected, version))
        self.sample("long_edited")
        version = EDIT_COUNT + 1
        measure("long_reject", "字节上限多一字节", changed(self.uri, self.over, version),
                SOURCE_LIMIT + published(self.uri, [], version))
        measure("long_recover", "超限后恢复末行诊断", changed(self.uri, self.bad, version + 1),
                published(self.uri, diagnostic, version + 1))
        close(self.uri, "long_close", "关闭万行文档")
        barrier()
        self.sample("long_closed")

        for first in range(0, FILES, SLOTS):
            batch = self.docs[first:first + SLOTS]
            for i, (uri, src) in enumerate(batch, first):
                measure("workspace_open", f"打开文件 {i}", opened(uri, src), published(uri, [], 0))
            if first == 0:
                uri, src = self.docs[SLOTS]
                measure("workspace_reject", "拒绝第 33 份同时打开的文件", opened(uri, src, 77), SYNC_LIMIT)
                # 紧随拒绝使用真实诊断回包；多余回包会破坏这次或后续逐字节匹配。
            for i, (uri, src) in enumerate(batch, first):
                measure("workspace_error", f"文件 {i} 未保存名称错误", changed(uri, instrument(src, "missing"), 1),
                        published(uri, unknown(src.count("\n")), 1))
                measure("workspace_fix", f"文件 {i} 还原磁盘版本", changed(uri, src, 2), published(uri, [], 2))
            self.sample(f"workspace_open_{first + len(batch)}")
            for i, (uri, _) in enumerate(batch, first):
                close(uri, "workspace_close", f"关闭文件 {i}")
            barrier()
            self.sample(f"workspace_closed_{first + len(batch)}")

        # 留一份有真实诊断的小文档，用它验证超额更新不提交版本或发布清空。
        small_uri = "file:///C:/yak-lsp/active-small.yak"
        small = instrument("", "missing")
        small_bytes = len(small.encode("utf-8"))
        large_uris = [f"file:///C:/yak-lsp/active-{i}.yak" for i in range(4)]
        measure("active_reject", "单文档超出 4 MiB 一字节",
                opened(large_uris[0], "x" * (DOCUMENT_BYTES + 1)), SYNC_LIMIT)
        measure("active_open", "打开小文档并发布真实名称诊断",
                opened(small_uri, small), published(small_uri, unknown(0), 0))
        for i, uri in enumerate(large_uris):
            size = DOCUMENT_BYTES if i < 3 else ACTIVE_TEXT_BYTES - 3 * DOCUMENT_BYTES - small_bytes
            measure("active_open", f"打开大文档 {i}、累计占满活动文本额度",
                    opened(uri, "x" * size), SOURCE_LIMIT + published(uri, [], 0))
        barrier()
        self.sample("active_full")
        measure("active_reject", "满额时拒绝打开一字节文档",
                opened("file:///C:/yak-lsp/active-extra.yak", "x"), SYNC_LIMIT)
        updated = changed(small_uri, small[:-1] + " \n", 1)
        measure("active_reject", "满额时拒绝增大一字节的替换", updated, SYNC_LIMIT)
        close(large_uris[-1], "active_close", "关闭填充文档释放额度")
        measure("active_recover", "关闭后以同一版本重试并保留精确诊断",
                updated, published(small_uri, unknown(0), 1))
        for uri in [*large_uris[:-1], small_uri]:
            close(uri, "active_close", "释放剩余活动文本")
        barrier()
        self.sample("active_closed")

        self.identifier += 1
        send(encoded(id=self.identifier, method="shutdown"))
        receive(encoded(id=self.identifier, result=None), "正常关闭会话")
        send(encoded(method="exit"))
        return 0

    def summarize(self):
        samples = self.report["samples"]
        peak = max(s["peak_working_set_bytes"] for s in samples)
        self.report["peak_working_set_bytes"] = peak
        closed = [s[self.memory.retained_key] for s in samples if s["phase"].startswith("workspace_closed_")]
        spread_key = "workspace_closed_anonymous_spread_bytes" if sys.platform == "linux" else "workspace_closed_private_spread_bytes"
        self.report[spread_key] = max(closed) - min(closed)
        summary = {}
        for group, rows in self.report["measurements"].items():
            durations = [r["ns"] for r in rows]
            summary[group] = {"count": len(durations), "p50_ns": percentile(durations, 50), "p95_ns": percentile(durations, 95)}
        self.report["summary"] = summary
        require(summary["long_edit"]["count"] == EDIT_COUNT and len(closed) == 4, "万行编辑或关闭批次不足")
        require(all(summary[f"workspace_{step}"]["count"] == FILES for step in ("open", "error", "fix", "close")),
                "百文件操作覆盖不足")
        require(all(summary[group]["count"] == count for group, count in
                    (("active_open", 5), ("active_reject", 3), ("active_recover", 1), ("active_close", 5))),
                "活动文本字节边界或关闭恢复覆盖不足")
        require(peak <= PEAK_WORKING_SET_LIMIT, f"工作集峰值超过 128 MiB 候选观察上限：{peak} 字节")


def main():
    if len(sys.argv) != 2 or (os.name != "nt" and sys.platform != "linux"):
        raise SystemExit("用法：python test/gate/lsp_corpus_check.py <宿主原生 yak_lsp 可执行文件>")
    exe = Path(sys.argv[1]).resolve(strict=True)
    if not exe.is_file() or exe.suffix.lower() != (".elf" if sys.platform == "linux" else ".exe"):
        raise SystemExit("需要正式的宿主目标候选可执行文件")
    gate = Path(__file__).resolve().parent
    scratch = gate / "tmp"
    scratch.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="lsp-corpus.", dir=scratch))
    command = [str(exe)]
    report = {"schema": 1, "status": "failed", "host": platform.platform(), "machine": platform.machine(),
              "repositoryHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=gate, text=True).strip(),
              "command": command, "executable_sha256": sha(exe.read_bytes()), "measurements": {}, "samples": [],
              "process_startup_ns": [],
              "long_sources": {}, "workspace_files": FILES, "simultaneous_documents": SLOTS,
              "document_limit_bytes": DOCUMENT_BYTES, "active_text_limit_bytes": ACTIVE_TEXT_BYTES,
              "peak_working_set_limit_bytes": PEAK_WORKING_SET_LIMIT}
    experiment = None
    try:
        experiment = Experiment(report, make_workspace(gate, work, report))
        open_pipe(command, experiment.exchange, on_start=experiment.start)
        experiment.summarize()
        measure_startups(command, report)
        report.update(status="passed", exit_code=0)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
        print(f"较大语料门禁未通过：{error}", file=sys.stderr)
    finally:
        if experiment is not None and experiment.memory is not None:
            experiment.memory.finish()
        (work / "run.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"较大语料记录：{work}")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
