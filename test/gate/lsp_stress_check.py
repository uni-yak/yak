"""在原生进程上核对千次编辑、重复重开及资源平台。"""

import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
from time import perf_counter_ns

from lsp_frame_check import candidate_capabilities, open_pipe, require, wire


CYCLES = 10
EDITS = 100
MIB = 1024 * 1024
PEAK_WORKING_SET_LIMIT = 128 * MIB
CLOSED_PRIVATE_GROWTH_LIMIT = 2 * MIB
URI = "file:///C:/Yak%20Stress/%E4%B8%AD.yak"
VALID = "//中😀\nfunction f(): void {}\n"
BAD = "//中😀"
EOF = {"line": 0, "character": 5}
E1018 = {"range": {"start": EOF, "end": EOF}, "severity": 1, "source": "yak",
         "code": "E1018", "message": "Yak 词法诊断 E1018"}


if os.name == "nt":
    import ctypes
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("page_faults", wintypes.DWORD)] + [
            (key, ctypes.c_size_t) for key in (
                "peak_working_set", "working_set", "quota_peak_paged", "quota_paged",
                "quota_peak_nonpaged", "quota_nonpaged", "pagefile", "peak_pagefile", "private_usage")]


class Memory:
    def __init__(self, pid):
        self.retained_key = "private_commit_bytes"
        self.proc_status = None
        if sys.platform == "linux":
            self.retained_key = "anonymous_resident_bytes"
            self.proc_status = Path(f"/proc/{pid}/status")
            return
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.open = kernel.OpenProcess
        self.open.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        self.open.restype = wintypes.HANDLE
        self.close = kernel.CloseHandle
        self.close.argtypes = (wintypes.HANDLE,)
        self.close.restype = wintypes.BOOL
        self.info = kernel.K32GetProcessMemoryInfo
        self.info.argtypes = (wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD)
        self.info.restype = wintypes.BOOL
        # 查询与读取权限，不改变工作集或进程行为。
        self.handle = self.open(0x0410, False, pid)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())

    def sample(self):
        if self.proc_status is not None:
            fields = {"VmRSS": "working_set_bytes", "VmHWM": "peak_working_set_bytes",
                      "RssAnon": self.retained_key}
            values = {}
            for line in self.proc_status.read_text(encoding="utf-8").splitlines():
                key, _, value = line.partition(":")
                if key in fields:
                    amount, unit = value.split()
                    require(unit == "kB", f"未知内存采样单位：{unit}")
                    values[fields[key]] = int(amount) * 1024
            require(len(values) == len(fields), "缺少 Linux 进程内存计数")
            return values
        values = Counters()
        values.cb = ctypes.sizeof(values)
        if not self.info(self.handle, ctypes.byref(values), values.cb):
            raise ctypes.WinError(ctypes.get_last_error())
        return {"working_set_bytes": values.working_set, "peak_working_set_bytes": values.peak_working_set,
                "private_commit_bytes": values.private_usage}

    def finish(self):
        if self.proc_status is None and not self.close(self.handle):
            raise ctypes.WinError(ctypes.get_last_error())


def encoded(**packet):
    return wire(json.dumps({"jsonrpc": "2.0", **packet}, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def notice(method, **params):
    return encoded(method=method, params=params)


def publication(diagnostics, version=None):
    params = {"uri": URI}
    if version is not None:
        params["version"] = version
    params["diagnostics"] = diagnostics
    return notice("textDocument/publishDiagnostics", **params)


def percentile(values, percent):
    return sorted(values)[(len(values) * percent + 99) // 100 - 1]


class Experiment:
    def __init__(self, report):
        self.report = report
        self.memory = None
        self.latencies = []

    def start(self, proc):
        self.memory = Memory(proc.pid)
        self.report["pid"] = proc.pid

    def sample(self, phase, cycle):
        sample = {"phase": phase, "cycle": cycle, "edits": len(self.latencies), **self.memory.sample()}
        require(0 < sample["working_set_bytes"] <= sample["peak_working_set_bytes"] and sample[self.memory.retained_key] > 0,
                "操作系统未返回有效进程内存计数")
        self.report["samples"].append(sample)

    def exchange(self, send, receive, _quiet):
        caps = {"textDocument": {"publishDiagnostics": {"versionSupport": True}}}
        start = perf_counter_ns()
        send(encoded(id=1, method="initialize", params={"capabilities": caps}))
        expected = {}
        if self.report["server_mode"] == "candidate":
            expected = candidate_capabilities()
        receive(encoded(id=1, result={"capabilities": expected}), "资源测量握手")
        self.report["initialize_round_trip_ns"] = perf_counter_ns() - start
        send(encoded(method="initialized"))

        def barrier(identifier):
            # 使用未注册的标准请求，确认上一次通知已离开会话循环的一轮。
            send(encoded(id=identifier, method="textDocument/references",
                         params={"textDocument": {"uri": URI}, "position": {"line": 0, "character": 0}}))
            receive(encoded(id=identifier, error={"code": -32601, "message": "Method not found"}), "通知处理完成")

        barrier(2)
        self.sample("baseline", 0)
        for cycle in range(1, CYCLES + 1):
            # 同一 URI 每次以低版本重开，旧的打开代不能携带任何历史结果。
            send(notice("textDocument/didOpen", textDocument={"uri": URI, "languageId": "yak", "version": 0, "text": BAD}))
            receive(publication([E1018], 0), f"第 {cycle} 轮重开诊断")
            for version in range(1, EDITS + 1):
                text = VALID if version % 2 else BAD
                packet = notice("textDocument/didChange", textDocument={"uri": URI, "version": version},
                                contentChanges=[{"text": text}])
                expected = publication([] if version % 2 else [E1018], version)
                start = perf_counter_ns()
                send(packet)
                receive(expected, f"第 {cycle} 轮版本 {version}")
                self.latencies.append(perf_counter_ns() - start)
                self.report["completed_edits"] = len(self.latencies)
                if version in (EDITS // 2, EDITS):
                    self.sample("editing", cycle)
            send(notice("textDocument/didClose", textDocument={"uri": URI}))
            receive(publication([]), f"第 {cycle} 轮关闭清空")
            barrier(cycle + 2)
            self.sample("closed", cycle)
        send(encoded(id=100, method="shutdown"))
        receive(encoded(id=100, result=None), "资源测量关闭会话")
        self.sample("shutdown", CYCLES)
        send(encoded(method="exit"))
        return 0

    def summarize(self):
        all_samples = self.report["samples"]
        closed = [x[self.memory.retained_key] for x in all_samples if x["phase"] == "closed"]
        peak = max((x["peak_working_set_bytes"] for x in all_samples), default=0)
        self.report["peak_working_set_bytes"] = peak
        if self.latencies:
            self.report["edit_round_trip_ns"] = {"p50": percentile(self.latencies, 50),
                                                  "p95": percentile(self.latencies, 95),
                                                  "raw": self.latencies}
        require(len(closed) == CYCLES and len(self.latencies) == CYCLES * EDITS, "闭合轮次或编辑次数不足")
        # 前三轮预热。Windows 使用私有提交，Linux 使用匿名驻留。
        spread = max(closed[3:]) - min(closed[3:])
        key = "closed_anonymous_spread_bytes" if sys.platform == "linux" else "closed_private_spread_bytes"
        self.report[key] = spread
        require(peak <= PEAK_WORKING_SET_LIMIT, f"工作集峰值超出小语料门禁：{peak} 字节")
        require(spread <= CLOSED_PRIVATE_GROWTH_LIMIT, f"关闭后内存波动超限：{spread} 字节")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", action="store_true", help="测量直启的正式候选")
    parser.add_argument("label", choices=("seed", "win64", "linux-x64"))
    parser.add_argument("work", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("缺少待测命令")
    linux = args.label == "linux-x64"
    if (linux and (sys.platform != "linux" or not args.candidate)) or (not linux and os.name != "nt"):
        parser.error("目标与原生测量宿主不符")
    if args.candidate and args.label == "seed":
        parser.error("正式候选模式需要独立可执行文件")
    executable = Path(args.command[0])
    if executable.suffix.lower() != (".elf" if linux else ".exe") or (args.label != "seed" and len(args.command) != 1):
        parser.error("必须直接启动对应目标的可执行文件")
    spread_key = "closed_anonymous_spread_bytes" if linux else "closed_private_spread_bytes"
    report = {"schema": 1, "host": platform.platform(), "machine": platform.machine(), "label": args.label,
              "server_mode": "candidate" if args.candidate else "probe",
              "command": args.command, "executable_sha256": sha256(executable.read_bytes()).hexdigest(),
              "corpus_utf8_sha256": [sha256(text.encode("utf-8")).hexdigest() for text in (VALID, BAD)],
              "cycles": CYCLES, "edits_per_cycle": EDITS, "completed_edits": 0, "samples": [], "status": "failed",
              "peak_working_set_limit_bytes": PEAK_WORKING_SET_LIMIT,
              ("closed_anonymous_spread_limit_bytes" if linux else "closed_private_spread_limit_bytes"):
                  CLOSED_PRIVATE_GROWTH_LIMIT}
    experiment = Experiment(report)
    try:
        open_pipe(args.command, experiment.exchange, on_start=experiment.start)
        experiment.summarize()
        report["status"] = "passed"
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
        print(f"{args.label}：资源门禁未通过：{error}", file=sys.stderr)
    finally:
        if experiment.memory is not None:
            experiment.memory.finish()
        suffix = "-candidate" if args.candidate else ""
        (args.work / f"stress-{args.label}{suffix}.json").write_bytes(
            (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    if report["status"] != "passed":
        return 1
    latency = report["edit_round_trip_ns"]
    print(f"{args.label}：{report['completed_edits']} 次全量编辑、{CYCLES} 次关闭重开通过；"
          f"工作集峰值 {report['peak_working_set_bytes'] / MIB:.2f} MiB，"
          f"关闭后内存波动 {report[spread_key] / MIB:.2f} MiB，"
          f"编辑往返 p50/p95 {latency['p50'] / 1e6:.2f}/{latency['p95'] / 1e6:.2f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
