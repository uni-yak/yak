"""Yak 构建脚本的 shell 白名单静态审计（SH-1/SH-2/SH-3/SH-4 与 build.md B-1）。

定位：词法级、行级、保守。本工具不是完整的 shell 解析器，它只回答一个可复核的问题：
生产构建脚本里出现的每个命令词，能否追到 spec/proc/shell.md 的白名单条目；以及
规格明列的禁止形态（设备文件、flock、符号链接、复杂 find、时间戳/宿主名/随机数、
绝对 Windows 路径）是否出现在脚本的可执行文本里。

白名单不写死在代码里：允许命令从 spec/proc/shell.md 的表格解析得到。规格与内置
快照不一致时报告 drift，而不是静默采用其中一方。

范围界定（写入报告，不允许静默扩大或缩小）：
  生产入口    compiler/min/{build,selfhost,verify}.sh、seed/build.sh、runtime/build.sh
  被 source 库 tools/{link,native_stream,target}.sh（由上述入口 source 或正式调用）
  辅助脚本    生产入口实际调起的测试驱动：单独列出并统计白名单外命令，但不计入生产
              判定，因为规格的 B-1 约束的是构建脚本本身。
  排除        test/**、tmp/**、**/tmp/**、tools/test_*.sh：测试、证据与一次性 handoff
              工作区不进入生产清单。
  未分类      仓库内其他 .sh 会被逐个列出，需要登记，防止范围随文件增长而悄悄失效。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SHELL_SPEC = "spec/proc/shell.md"
BUILD_SPEC = "spec/proc/build.md"

# 生产构建入口。缺一个条目就报错，避免范围被悄悄缩小。
PRODUCTION_ENTRIES = {
    "compiler/min/build.sh": "正式 T1 入口：模块图、编译与发布",
    "compiler/min/selfhost.sh": "自举入口：按模块名选择源根后调用 build.sh",
    "compiler/min/verify.sh": "快速门禁：规格审计、词表、契约与入口用例",
    "seed/build.sh": "Seed 确定性构建与哈希冻结",
    "runtime/build.sh": "Windows x64 运行时对象确定性构建",
    "compiler/lsp/build.sh": "由正式编译入口产出的 Win64 诊断候选服务",
}

# 被生产入口 source 或正式调用的库。它们与入口同属构建脚本。
PRODUCTION_LIBS = {
    "tools/link.sh": "由 build.sh 与 seed/build.sh 正式调用的编译/链接驱动",
    "tools/native_stream.sh": "由 build.sh 与 link.sh source 的请求/响应封装",
    "tools/target.sh": "由 build.sh、link.sh、runtime/build.sh source 的宿主工具选择",
}

# 生产入口实际调起的测试驱动：单独统计，不并入生产判定。
AUXILIARY_SCRIPTS = {
    "tools/test_link_e2e.sh": ("seed/build.sh", "第 6.5 步链接端到端验证"),
    "test/gate/test_evidence_digest.sh": ("compiler/min/verify.sh", "隔离取证回归"),
    "test/gate/test_error_code_preflight.sh": ("compiler/min/verify.sh", "隔离错误码摘要预检回归"),
    "test/gate/test_runtime_toolchain.sh": ("compiler/min/verify.sh", "隔离运行时工具链预检回归"),
    "test/gate/test_c0_stream_host.sh": ("compiler/min/verify.sh", "诊断帧解析边界回归"),
    "test/gate/test_diag_native.sh": ("compiler/min/verify.sh", "Seed 诊断 JSONL 端到端回归"),
    "test/gate/t1_entry.sh": ("compiler/min/verify.sh", "T1 入口用例"),
    "seed/test/common.sh": ("seed/build.sh", "被 source 的回归用例助手"),
    "compiler/min/src/mir/run_probe.sh": ("（手工）", "MIR 探针的运行入口，不参与构建"),
}

# 排除模式：按仓库相对 POSIX 路径判断，先生效者优先。
EXCLUSIONS = (
    ("test/**", "测试与证据脚本：取证工具（grep/awk/nm/objdump 等）不在构建白名单约束内"),
    ("tmp/**", "一次性 handoff 工作区，不属于仓库脚本"),
    ("**/tmp/**", "构建临时目录与就地副本，不属于源码"),
    ("tools/test_*.sh", "测试驱动，由测试入口而非构建入口调用"),
    ("seed/test/**", "Seed 回归测试脚本：测试入口，不在 build.md B-1 的构建脚本范围"),
    ("**/node_modules/**", "外部依赖自带脚本"),
)

# 不允许依赖的展开：时间戳、宿主名、随机数（shell.md 5.3）。
NONDETERMINISTIC_VARS = (
    "RANDOM", "SRANDOM", "SECONDS", "EPOCHREALTIME", "EPOCHSECONDS", "BASH_MONOSECONDS",
    "HOSTNAME", "HOSTTYPE", "MACHTYPE",
)
# 非确定性命令：命令词命中即 SH-3，且同时是白名单外操作。
# mktemp 不在此列：它不读时钟，但同样引入随机名，由下面的专条判定。
NONDETERMINISTIC_COMMANDS = ("date", "hostname", "uname")

LIMITATIONS = (
    "不是完整 shell 解析器：不展开变量、不追踪 source 之后的函数别名、不求值条件分支。",
    "命令词为变量或命令替换时（如 \"$cc\"、\"$(yak_target_cc)\"）只登记为动态命令，无法静态判定。",
    "只审计生产入口及其被 source 的库；测试与证据脚本单独统计，不做白名单判定。",
    "heredoc 正文整体按数据跳过（不展开变量、不当作命令），每处仍登记为待复核构造。",
    "mv 是否覆盖在用文件、临时文件是否独占创建等运行期性质无法静态判定，未纳入本工具。",
)

# 从规格解析白名单时使用的行首类目名。
_SPEC_ROWS = {
    "shell": "bash",
    "文本工具": "coreutils",
    "汇编 / 链接": "binutils",
    "门禁生成与审计": "python",
}

# 规格表格行首类目名与正文里可能出现的类目词：它们不是命令。
_CATEGORY_WORDS = {"coreutils", "binutils", "shell", "seed", "gcc", "windows", "x64"}

_TOKEN_RE = re.compile(r"^[a-z][a-z0-9_+-]*$")
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=")
_ASSIGN_EXPAND_RE = re.compile(r"\+(?==)")
_DYNAMIC_RE = re.compile("^[\"']*[$" + chr(96) + "]")
# 绝对 Windows 路径：盘符后必须紧跟分隔符，避免把 case 模式里的 [A-Za-z]:* 误报。
_WIN_PATH_RE = re.compile(r"(?<![A-Za-z0-9_])[A-Za-z]:[\\/][^\s\"'|;)]*")
_UNC_PATH_RE = re.compile(r"\\\\[A-Za-z0-9_.-]+\\[A-Za-z0-9_.-]+")
_DEVICE_RE = re.compile(r"/dev/[A-Za-z0-9_.-]+")
# 规格禁止表（spec/proc/shell.md 第 36 行）明列的设备文件。
_SPEC_FORBIDDEN_DEVICES = {"/dev/full"}
_PROC_FD_RE = re.compile(r"/proc/self/fd\b")


# ── 词法 ──────────────────────────────────────────────────────────────

CODE, SQUOTE, DQUOTE, COMMENT, DATA = "c", "q", "d", "x", "t"


@dataclass(slots=True)
class Token:
    kind: str          # word | op | redirect | arith
    raw: str
    line: int
    col: int
    glob: bool = False


@dataclass(slots=True)
class Command:
    raw: str
    line: int
    col: int
    dynamic: bool


def _positions(text):
    """返回每个下标对应的 (行, 列)，行号从 1 开始。"""
    lines = [0] * len(text)
    cols = [0] * len(text)
    line = 1
    col = 1
    for index, ch in enumerate(text):
        lines[index] = line
        cols[index] = col
        if ch == "\n":
            line += 1
            col = 1
        else:
            col += 1
    return lines, cols


class Scanner:
    """把脚本文本切成词/操作符，同时记录命令替换与注释、引号区域。"""

    def __init__(self, text):
        self.text = text
        self.n = len(text)
        self.lines, self.cols = _positions(text)
        self.mask = [CODE] * self.n
        self.units = []
        self.notes = []

    def _mark(self, start, end, kind):
        for index in range(start, min(end, self.n)):
            self.mask[index] = kind

    def _skip_double(self, j, end):
        while j < end:
            ch = self.text[j]
            if ch == "\\" and j + 1 < end:
                j += 2
                continue
            if ch == "\"":
                return j + 1
            j += 1
        return end

    def _capture(self, i, opener, closer, end):
        """从 text[i] == opener 起找配对的 closer，返回闭合之后的下标。"""
        depth = 0
        j = i
        while j < end:
            ch = self.text[j]
            if ch == "\\" and j + 1 < end:
                j += 2
                continue
            if ch == "'":
                k = self.text.find("'", j + 1)
                j = end if k < 0 or k >= end else k + 1
                continue
            if ch == "\"":
                j = self._skip_double(j + 1, end)
                continue
            if ch == opener:
                depth += 1
            elif ch == closer:
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        return end

    def _skip_arith(self, i, end):
        depth = 0
        j = i
        while j < end:
            ch = self.text[j]
            if ch == "\\" and j + 1 < end:
                j += 2
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth <= 0:
                    return j + 1
            j += 1
        return end

    def run(self):
        tokens = []
        self.units.append(tokens)
        self._scan(0, self.n, tokens, 0)
        return self.units, self.notes, self.mask

    def _scan(self, start, end, out, depth):
        if depth > 12:
            self.notes.append("命令替换嵌套过深，已停止递归")
            return
        text = self.text
        buf = []
        word_start = -1
        i = start
        quote = ""
        heredocs = []

        def flush():
            nonlocal buf, word_start
            if not buf:
                return
            raw = "".join(ch for ch, _kind in buf)
            # 只有 * 与 ? 会做路径展开；${a[$i]} 这类引用里不可能触发 glob。
            glob = any(ch in "*?" and kind == CODE for ch, kind in buf)
            out.append(Token("word", raw, self.lines[word_start], self.cols[word_start], glob))
            buf = []
            word_start = -1

        def begin(index):
            nonlocal word_start
            if word_start < 0:
                word_start = index

        def push(ch, kind, index):
            begin(index)
            buf.append((ch, kind))
            self.mask[index] = kind

        def push_span(a, b, kind):
            begin(a)
            for index in range(a, min(b, end)):
                buf.append((text[index], kind))
                self.mask[index] = kind

        while i < end:
            ch = text[i]
            if quote == "'":
                push(ch, SQUOTE, i)
                if ch == "'":
                    quote = ""
                i += 1
                continue
            if quote == "\"":
                if ch == "\\" and i + 1 < end:
                    push(ch, DQUOTE, i)
                    push(text[i + 1], DQUOTE, i + 1)
                    i += 2
                    continue
                if ch == "\"":
                    push(ch, DQUOTE, i)
                    quote = ""
                    i += 1
                    continue
                if ch == "$" and i + 1 < end and text[i + 1] == "(":
                    j = self._capture(i + 1, "(", ")", end)
                    push_span(i, j, DQUOTE)
                    self._sub(i, j, depth)
                    i = j
                    continue
                push(ch, DQUOTE, i)
                i += 1
                continue
            if ch == "\\" and i + 1 < end:
                if text[i + 1] == "\n":
                    self.mask[i] = CODE
                    self.mask[i + 1] = CODE
                    i += 2
                    continue
                push(ch, CODE, i)
                push(text[i + 1], SQUOTE, i + 1)
                i += 2
                continue
            if ch in " \t\r":
                flush()
                i += 1
                continue
            if ch == "\n":
                flush()
                out.append(Token("op", "\n", self.lines[i], self.cols[i]))
                i += 1
                if heredocs:
                    i = self._skip_heredocs(i, heredocs)
                continue
            if ch == "#" and word_start < 0:
                j = text.find("\n", i, end)
                j = end if j < 0 else j
                self._mark(i, j, COMMENT)
                i = j
                continue
            if ch == "'":
                push(ch, SQUOTE, i)
                quote = "'"
                i += 1
                continue
            if ch == "\"":
                push(ch, DQUOTE, i)
                quote = "\""
                i += 1
                continue
            if ch == "$" and i + 1 < end and text[i + 1] in "({":
                opener = text[i + 1]
                closer = "}" if opener == "{" else ")"
                arithmetic = opener == "(" and text[i + 2:i + 3] == "("
                j = self._capture(i + 1, opener, closer, end)
                push_span(i, j, CODE)
                # $(( )) 是算术展开，内部只有变量与运算符，不存在命令。
                if opener == "(" and not arithmetic:
                    self._sub(i + 2, j - 1, depth)
                i = j
                continue
            if ch == chr(96):
                j = i + 1
                while j < end:
                    if text[j] == "\\" and j + 1 < end:
                        j += 2
                        continue
                    if text[j] == chr(96):
                        break
                    j += 1
                push_span(i, min(j + 1, end), CODE)
                self._sub(i + 1, j, depth)
                i = min(j + 1, end)
                continue
            if ch == "(" and text[i + 1:i + 2] == "(":
                flush()
                j = self._skip_arith(i, end)
                out.append(Token("arith", text[i:j], self.lines[i], self.cols[i]))
                i = j
                continue
            if ch == "<" and text[i:i + 2] == "<<":
                flush()
                if text[i:i + 3] == "<<<":
                    # herestring：右操作数仍是一个正常的词（含引号与展开）。
                    out.append(Token("redirect", "<<<", self.lines[i], self.cols[i]))
                    i += 3
                    continue
                marker = i
                i, delimiter = self._heredoc_delimiter(i)
                heredocs.append(delimiter)
                self.notes.append(
                    f"第 {self.lines[marker]} 行出现 heredoc，正文整体按数据跳过（不展开变量）")
                out.append(Token("redirect", "<<", self.lines[marker], self.cols[marker]))
                continue
            if ch in "|&;()<>":
                flush()
                i = self._operator(i, end, out)
                continue
            push(ch, CODE, i)
            i += 1
        flush()

    def _heredoc_delimiter(self, i):
        """解析 << 之后的定界符，返回 (正文起点下标, (定界符, 是否剥前导制表符))。"""
        text, n = self.text, self.n
        i += 2
        strip_tabs = text[i:i + 1] == "-"
        if strip_tabs:
            i += 1
        while i < n and text[i] in " \t":
            i += 1
        word = []
        while i < n and (text[i] not in " \t\n;|&()<>"):
            if text[i] in "'\"":
                closer = text[i]
                i += 1
                while i < n and text[i] != closer:
                    if text[i] == "\\" and i + 1 < n:
                        i += 1
                    word.append(text[i])
                    i += 1
                i += 1
                continue
            if text[i] == "\\" and i + 1 < n:
                i += 1
            word.append(text[i])
            i += 1
        # 定界符行本身结束于换行：正文从下一行开始。
        end = text.find("\n", i)
        start = n if end < 0 else end + 1
        return start, ("".join(word), strip_tabs)

    def _skip_heredocs(self, i, heredocs):
        """逐行比对定界符，把正文标记为数据后跳过。"""
        text, n = self.text, self.n
        for delimiter, strip_tabs in heredocs:
            while i < n:
                end = text.find("\n", i)
                end = n if end < 0 else end
                line = text[i:end]
                compare = line.lstrip("\t") if strip_tabs else line
                self._mark(i, end, DATA)
                i = min(end + 1, n)
                if compare == delimiter:
                    break
        heredocs.clear()
        return i

    def _sub(self, inner_start, inner_end, depth):
        if inner_end <= inner_start:
            return
        tokens = []
        self.units.append(tokens)
        self._scan(inner_start, inner_end, tokens, depth + 1)

    def _operator(self, i, end, out):
        text = self.text
        ch = text[i]
        line, col = self.lines[i], self.cols[i]
        two = text[i:i + 2]
        three = text[i:i + 3]
        if ch == ";":
            raw = ";;&" if three == ";;&" else (";;" if two == ";;" else (";&" if two == ";&" else ";"))
            out.append(Token("op", raw, line, col))
            return i + len(raw)
        if ch == "&":
            raw = "&&" if two == "&&" else ("&>" if two == "&>" else "&")
            out.append(Token("op", raw, line, col))
            return i + len(raw)
        if ch == "|":
            raw = "||" if two == "||" else ("|&" if two == "|&" else "|")
            out.append(Token("op", raw, line, col))
            return i + len(raw)
        if ch in "()":
            out.append(Token("op", ch, line, col))
            return i + 1
        j = i + 1
        if ch == ">":
            if text[j:j + 1] in (">", "&", "|"):
                j += 1
        else:
            if text[j:j + 1] in ("<", "&", ">"):
                j += 1
        raw = text[i:j]
        if text[j:j + 1] == "(":
            k = self._capture(j, "(", ")", end)
            out.append(Token("redirect", raw, line, col))
            self._sub(j + 1, k - 1, 0)
            return k
        k = j
        while k < end and text[k] in " \t":
            k += 1
        if k < end and text[k] not in "\n;|&()<>":
            if text[k] == "&":
                k += 1
            while k < end and text[k] not in " \t\n;|&()<>":
                if text[k] in "'\"":
                    closer = text[k]
                    k += 1
                    while k < end and text[k] != closer:
                        if text[k] == "\\" and k + 1 < end:
                            k += 2
                            continue
                        k += 1
                    k += 1
                    continue
                if text[k] == "\\" and k + 1 < end:
                    k += 2
                    continue
                k += 1
            out.append(Token("redirect", text[i:k], line, col))
            return k
        out.append(Token("redirect", raw, line, col))
        return j


# ── 命令提取 ──────────────────────────────────────────────────────────

KEYWORDS = {
    "if", "then", "elif", "else", "fi", "while", "until", "do", "done",
    "!", "{", "}", "function", "time", "coproc", "esac", "select",
}
SHELL_BUILTINS = {
    ":", ".", "source", "alias", "bg", "bind", "break", "builtin", "caller", "cd",
    "command", "compgen", "complete", "continue", "declare", "dirs", "disown",
    "echo", "enable", "eval", "exec", "exit", "export", "false", "fc", "fg",
    "getopts", "hash", "help", "history", "jobs", "kill", "let", "local", "logout",
    "mapfile", "popd", "printf", "pushd", "pwd", "read", "readarray", "readonly",
    "return", "set", "shift", "shopt", "suspend", "test", "times", "trap", "true",
    "type", "typeset", "ulimit", "umask", "unalias", "unset", "wait", "[", "[[",
}


def _skip_paren(tokens, index):
    depth = 0
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "op" and token.raw == "(":
            depth += 1
        elif token.kind == "op" and token.raw == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return index


def collect_commands(tokens):
    """返回 (命令词列表, 未排序 glob 遍历列表)。"""
    commands = []
    glob_loops = []
    expect = True
    case_modes = []
    index = 0
    total = len(tokens)
    prev = None
    while index < total:
        token = tokens[index]
        if token.kind == "op":
            raw = token.raw
            if raw in (";", "\n", "&", "|", "||", "&&", "|&", ";;", ";&", ";;&"):
                expect = True
                if case_modes and raw in (";;", ";&", ";;&"):
                    case_modes[-1] = "pattern"
                index += 1
                continue
            if raw == "(":
                if prev is not None and prev.kind == "word" and _ASSIGN_RE.match(prev.raw):
                    index = _skip_paren(tokens, index)
                    continue
                if case_modes and case_modes[-1] == "pattern":
                    index += 1
                    continue
                expect = True
                index += 1
                continue
            if raw == ")":
                if case_modes and case_modes[-1] == "pattern":
                    case_modes[-1] = "body"
                    expect = True
                index += 1
                continue
            prev = token
            index += 1
            continue
        if token.kind == "redirect":
            # 重定向可以独立成句（done < f），它既不开头也不改变期待命令的状态。
            prev = token
            index += 1
            continue
        if token.kind == "arith":
            expect = False
            prev = token
            index += 1
            continue
        if case_modes and case_modes[-1] == "subject":
            if token.raw == "in":
                case_modes[-1] = "pattern"
            prev = token
            index += 1
            continue
        if case_modes and case_modes[-1] == "pattern":
            if token.raw == "esac":
                case_modes.pop()
                expect = True
            prev = token
            index += 1
            continue
        if not expect:
            prev = token
            index += 1
            continue
        raw = token.raw
        if raw == "[[":
            # [[ ... ]] 内部是条件表达式：操作数是字面量与变量，不是命令。
            index += 1
            while index < total:
                inner = tokens[index]
                if inner.kind == "op" and inner.raw == "\n":
                    break
                if inner.kind == "word" and inner.raw == "]]":
                    index += 1
                    break
                index += 1
            expect = False
            prev = token
            continue
        if raw == "esac":
            if case_modes:
                case_modes.pop()
            expect = True
            prev = token
            index += 1
            continue
        if raw in KEYWORDS:
            index += 1
            continue
        if raw == "case":
            case_modes.append("subject")
            expect = False
            prev = token
            index += 1
            continue
        if raw == "function":
            index += 2
            continue
        if raw == "for":
            index += 1
            if index < total and tokens[index].kind == "word":
                index += 1
            if index < total and tokens[index].kind == "arith":
                expect = True
                prev = token
                continue
            if index < total and tokens[index].kind == "word" and tokens[index].raw == "in":
                index += 1
                while index < total and not (tokens[index].kind == "op" and tokens[index].raw in (";", "\n")):
                    word = tokens[index].raw
                    # 命令替换里的遍历顺序由被调命令决定（常见写法是管道接 sort），
                    # 静态无法判定，此处不报；裸 glob 才是真正的 readdir 依赖。
                    if tokens[index].kind == "word" and tokens[index].glob and "$(" not in word:
                        glob_loops.append((word, tokens[index].line, tokens[index].col))
                    index += 1
            expect = True
            prev = token
            continue
        if _ASSIGN_RE.match(raw):
            expect = True
            prev = token
            index += 1
            continue
        if (index + 2 < total and tokens[index + 1].kind == "op" and tokens[index + 1].raw == "("
                and tokens[index + 2].kind == "op" and tokens[index + 2].raw == ")"):
            index += 3
            expect = False
            prev = None
            continue
        dynamic = bool(_DYNAMIC_RE.match(raw))
        commands.append(Command(raw, token.line, token.col, dynamic))
        # 命令替换或参数展开的结果确实可能绕过静态白名单。只解析无展开、
        # 无重定向、单命令的纯字面量替换，确保常见的 $(clang ...) 不被漏掉；
        # 其他动态命令仍保留为限制，不猜测运行期取值。
        if dynamic:
            match = re.fullmatch(r"[\"']?\$\(([^()\n]+)\)[\"']?", raw)
            if match:
                nested = Scanner(match[1] + "\n")
                nested_units, _nested_notes, _nested_mask = nested.run()
                for nested_tokens in nested_units:
                    nested_commands, _nested_globs = collect_commands(nested_tokens)
                    if (len(nested_commands) == 1 and not nested_commands[0].dynamic and
                            _TOKEN_RE.fullmatch(nested_commands[0].raw)):
                        commands.append(Command(nested_commands[0].raw, token.line,
                                                token.col, False))
        expect = False
        prev = token
        index += 1
    return commands, glob_loops


def find_function_names(units):
    names = set()
    for tokens in units:
        for index, token in enumerate(tokens):
            if token.kind != "word":
                continue
            nxt = tokens[index + 1] if index + 1 < len(tokens) else None
            nxt2 = tokens[index + 2] if index + 2 < len(tokens) else None
            if (nxt is not None and nxt.kind == "op" and nxt.raw == "("
                    and nxt2 is not None and nxt2.kind == "op" and nxt2.raw == ")"):
                names.add(token.raw)
            if index > 0 and tokens[index - 1].kind == "word" and tokens[index - 1].raw == "function":
                names.add(token.raw)
    return names


# ── 规格契约 ──────────────────────────────────────────────────────────

def _cells(line):
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def load_contract(root):
    """从 spec/proc/shell.md 解析允许命令与禁止操作；解析失败返回 None。"""
    path = Path(root) / SHELL_SPEC
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8")
    allowed = set()
    forbidden = set()
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = _cells(line)
        if not cells:
            continue
        head, body = cells[0], (cells[1] if len(cells) > 1 else "")
        if head in _SPEC_ROWS:
            if head == "shell":
                if re.search(r"\bbash\b", body):
                    allowed.add("bash")
            elif head == "汇编 / 链接":
                allowed.update(t.lower() for t in re.findall(r"([A-Za-z][A-Za-z0-9_+-]*)", body)
                               if t.lower() in ("as", "ld", "gcc", "clang"))
                allowed.add("gcc")
            elif head == "门禁生成与审计":
                allowed.add("python")
            else:
                for token in re.findall(r"([a-z][a-z0-9_+]*)\b", body):
                    # 类目名（coreutils / binutils）只是分组标题，不是命令。
                    if token not in _CATEGORY_WORDS:
                        allowed.add(token)
        if "符号链接" in head:
            forbidden.add("ln")
    if not allowed:
        return None
    return {"allowed": allowed, "forbidden": forbidden}


# ── 判定 ──────────────────────────────────────────────────────────────

def _entry(rule, code, severity, path, line, col, command, text, message, decision=""):
    return {
        "rule": rule,
        "code": code,
        "severity": severity,
        "file": path,
        "line": line,
        "col": col,
        "command": command,
        "text": text,
        "message": message,
        "decision": decision,
    }


def audit_source(text, path, functions, contract):
    """审计单个脚本文本，返回 findings 与统计用的命令清单。"""
    scanner = Scanner(text)
    units, notes, mask = scanner.run()
    source_lines = text.splitlines()
    findings = []
    used = {}

    def snippet(line):
        if 1 <= line <= len(source_lines):
            return source_lines[line - 1].strip()[:160]
        return ""

    allowed = contract["allowed"] if contract else set()
    forbidden = contract["forbidden"] if contract else set()
    known = allowed | SHELL_BUILTINS | set(functions)

    for unit in units:
        commands, glob_loops = collect_commands(unit)
        for command in commands:
            raw = command.raw
            name = raw.strip("\"'")
            used[name] = used.get(name, 0) + 1
            if command.dynamic:
                continue
            if name in known:
                continue
            if name in NONDETERMINISTIC_COMMANDS:
                findings.append(_entry(
                    "SH-3", "nondeterministic-command", "error", path,
                    command.line, command.col, name, snippet(command.line),
                    f"命令 {name} 引入时间戳或宿主相关信息，违反 shell.md 5.3",
                    "需要规格或实现决策：把该命令移出构建入口，或先修订 shell.md 5.3。",
                ))
                findings.append(_entry(
                    "SH-1", "command-not-whitelisted", "error", path,
                    command.line, command.col, name, snippet(command.line),
                    f"命令 {name} 不在 shell.md 白名单内（build.md B-1）",
                    "需要规格或实现决策：加入白名单（须同时更新 shell.md）或改写脚本。",
                ))
                continue
            if name == "mktemp":
                findings.append(_entry(
                    "SH-1", "command-not-whitelisted", "error", path,
                    command.line, command.col, name, snippet(command.line),
                    "命令 mktemp 不在 shell.md 白名单内；随机临时名与 5.3 的确定性要求冲突",
                    "需要规格或实现决策：规格只给出 mkdir 持锁与独占创建临时文件；"
                    "是否允许 mktemp 必须由规格明确，不得由本工具默认放宽。",
                ))
                continue
            if name == "find":
                findings.append(_entry(
                    "SH-2", "find-traversal", "review", path,
                    command.line, command.col, name, snippet(command.line),
                    "find 的遍历序跨平台不一致；规格只禁止复杂表达式（shell.md 第 41 行）",
                    "需要复核：表达式是否简单且结果与顺序无关，否则改为固定列举或 sort 后处理。",
                ))
                findings.append(_entry(
                    "SH-1", "command-not-whitelisted", "error", path,
                    command.line, command.col, name, snippet(command.line),
                    "命令 find 不在 shell.md 白名单内",
                    "需要规格或实现决策：加入白名单或改写脚本。",
                ))
                continue
            code = "command-not-whitelisted"
            decision = "需要规格或实现决策：加入白名单（须同时更新 shell.md）或改写脚本。"
            if name in ("flock", "ln"):
                code = "forbidden-operation"
                decision = ("规格明列禁止：" + ("flock（第 38 行，NTFS 上不可靠）" if name == "flock"
                                                else "符号链接（第 40 行，NTFS 行为不一致）"))
            findings.append(_entry("SH-1", code, "error", path, command.line, command.col,
                                   name, snippet(command.line),
                                   f"命令 {name} 不在 shell.md 白名单内（build.md B-1）", decision))

        for raw, line, col in glob_loops:
            findings.append(_entry(
                "SH-2", "unsorted-glob-loop", "review", path, line, col, raw, snippet(line),
                f"for 循环直接遍历通配结果 {raw}，未显式 sort（shell.md 5.1）",
                "需要规格或实现决策：bash 路径展开按 LC_ALL=C 排序，但规格要求 sort 后处理；"
                "请确认是按规格补 sort，还是修订 5.1 明确接受 bash 展开序。",
            ))

    for match in re.finditer(r"\$\{?(" + "|".join(NONDETERMINISTIC_VARS) + r")\b", text):
        if mask[match.start()] in (SQUOTE, COMMENT, DATA):
            continue
        line = scanner.lines[match.start()]
        findings.append(_entry(
            "SH-3", "nondeterministic-variable", "error", path, line,
            scanner.cols[match.start()], match.group(0), snippet(line),
            f"{match.group(0)} 引入时间、宿主信息或随机数，违反 shell.md 5.3",
            "需要规格或实现决策：改用确定性输入。",
        ))

    for match in _WIN_PATH_RE.finditer(text):
        if mask[match.start()] in (COMMENT, DATA):
            continue
        line = scanner.lines[match.start()]
        findings.append(_entry(
            "SH-4", "absolute-windows-path", "error", path, line,
            scanner.cols[match.start()], match.group(0), snippet(line),
            "出现绝对 Windows 路径硬编码（shell.md 第 27 行）",
            "需要实现决策：改为相对路径或由调用方传入。",
        ))
    for match in _UNC_PATH_RE.finditer(text):
        if mask[match.start()] in (COMMENT, DATA):
            continue
        line = scanner.lines[match.start()]
        findings.append(_entry(
            "SH-4", "absolute-unc-path", "error", path, line,
            scanner.cols[match.start()], match.group(0), snippet(line),
            "出现 UNC 绝对路径硬编码（shell.md 第 27 行）",
            "需要实现决策：改为相对路径或由调用方传入。",
        ))
    for match in _PROC_FD_RE.finditer(text):
        if mask[match.start()] in (COMMENT, DATA):
            continue
        line = scanner.lines[match.start()]
        findings.append(_entry(
            "SH-1", "forbidden-proc-fd", "error", path, line,
            scanner.cols[match.start()], match.group(0), snippet(line),
            "/proc/self/fd 为 Linux 专有，规格明列禁止（shell.md 第 37 行）",
            "按规格改为 O_CREAT|O_EXCL 独占创建临时文件。",
        ))
    for match in _DEVICE_RE.finditer(text):
        if mask[match.start()] in (COMMENT, DATA):
            continue
        name = match.group(0)
        line = scanner.lines[match.start()]
        if name == "/dev/null":
            continue
        # 规格明列禁止的设备（第 36 行 /dev/full）判 error；其余设备只提示移植性风险。
        severity = "error" if name in forbidden or name in _SPEC_FORBIDDEN_DEVICES else "review"
        findings.append(_entry(
            "SH-1", "device-path", severity, path, line,
            scanner.cols[match.start()], name, snippet(line),
            f"使用设备文件 {name}；规格只禁止 /dev/full（第 36 行），其余设备同样不可移植",
            "需要规格或实现决策：改为只读文件写 + 断言失败，或由规格明确允许。",
        ))

    for note in notes:
        findings.append(_entry("SCOPE", "unsupported-construct", "review", path, 0, 0, "", "",
                               f"未解析构造：{note}", "本工具不是完整 shell 解析器，需人工复核该处。"))
    return findings, used


# ── 范围 ──────────────────────────────────────────────────────────────

def _matches(pattern, rel):
    from fnmatch import fnmatchcase
    if pattern.startswith("**/"):
        return fnmatchcase(rel, pattern[3:]) or fnmatchcase(rel, pattern)
    return fnmatchcase(rel, pattern)


def classify(rel):
    # 显式登记优先于排除模式：被生产入口 source 的测试助手仍要统计命令。
    if rel in PRODUCTION_ENTRIES:
        return "entry", "", PRODUCTION_ENTRIES[rel]
    if rel in PRODUCTION_LIBS:
        return "lib", "", PRODUCTION_LIBS[rel]
    if rel in AUXILIARY_SCRIPTS:
        return "auxiliary", "", AUXILIARY_SCRIPTS[rel][1]
    for pattern, why in EXCLUSIONS:
        if _matches(pattern, rel):
            return "excluded", pattern, why
    return "unclassified", "", ""


def discover(root):
    root = Path(root)
    found = []
    for path in root.rglob("*.sh"):
        rel = path.relative_to(root).as_posix()
        if any(part in (".git", "node_modules", "out") for part in rel.split("/")):
            continue
        found.append(rel)
    return sorted(found)


def load_scope(root):
    root = Path(root)
    scope = {"entry": [], "lib": [], "auxiliary": [], "excluded": [], "unclassified": [], "missing": []}
    for rel, purpose in list(PRODUCTION_ENTRIES.items()) + list(PRODUCTION_LIBS.items()):
        kind = "entry" if rel in PRODUCTION_ENTRIES else "lib"
        path = root / rel
        item = {"file": rel, "purpose": purpose, "exists": path.is_file(), "lines": 0}
        if item["exists"]:
            item["lines"] = len(path.read_text(encoding="utf-8").splitlines())
        else:
            scope["missing"].append(item)
        scope[kind].append(item)
    for rel, spec in AUXILIARY_SCRIPTS.items():
        caller, purpose = spec
        path = root / rel
        item = {"file": rel, "invokedBy": caller, "purpose": purpose,
                "exists": path.is_file(), "lines": 0}
        if item["exists"]:
            item["lines"] = len(path.read_text(encoding="utf-8").splitlines())
        else:
            scope["missing"].append(item)
        scope["auxiliary"].append(item)
    for rel in discover(root):
        kind, pattern, why = classify(rel)
        if kind == "excluded":
            scope["excluded"].append({"file": rel, "pattern": pattern, "rationale": why})
        elif kind == "unclassified":
            scope["unclassified"].append(rel)
    return scope


# ── 汇总 ──────────────────────────────────────────────────────────────

def _looks_like_command(name):
    """辅助统计用的保守过滤：命令替换、算术、纯数字与带空格/符号的词都不是命令名。"""
    if not name or name[0] in "$(" or name[0].isdigit():
        return False
    return bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.+-]*", name))


def spec_drift(contract):
    """规格解析结果与内置快照的差异；两边任一多出条目都要人工确认。"""
    if contract is None:
        return []
    embedded = {
        "cat", "cp", "mv", "rm", "mkdir", "rmdir", "sha256sum", "cmp", "diff", "xxd",
        "od", "timeout", "tr", "cut", "sort", "head", "tail", "wc", "as", "ld", "gcc",
        "bash", "clang", "python",
    }
    notes = []
    extra = contract["allowed"] - embedded
    if extra:
        notes.append("规格白名单新增 " + "、".join(sorted(extra)) + "，内置快照未跟进")
    gone = embedded - contract["allowed"]
    if gone:
        notes.append("规格白名单已不含 " + "、".join(sorted(gone)) + "，内置快照仍在使用")
    return notes


def audit(root=ROOT):
    root = Path(root)
    scope = load_scope(root)
    contract = load_contract(root)
    findings = []
    texts = {}
    for item in scope["entry"] + scope["lib"]:
        if item["exists"]:
            texts[item["file"]] = (root / item["file"]).read_text(encoding="utf-8")
    functions = set()
    for text in texts.values():
        units, _notes, _mask = Scanner(text).run()
        functions |= find_function_names(units)
    # 生产脚本 source 的助手把函数注入同一个 shell：这些函数名同样是命令词。
    for item in scope["auxiliary"]:
        if item["exists"]:
            units, _notes, _mask = Scanner((root / item["file"]).read_text(encoding="utf-8")).run()
            functions |= find_function_names(units)
    for rel, text in texts.items():
        hits, _used = audit_source(text, rel, functions, contract)
        findings.extend(hits)
    for item in scope["missing"]:
        findings.append(_entry(
            "SCOPE", "missing-entry", "error", item["file"], 0, 0, "", "",
            "登记的生产脚本不存在，审计范围失效",
            "需要实现决策：恢复文件或更新 tools/shell_contract.py 的范围声明。",
        ))
    for rel in scope["unclassified"]:
        findings.append(_entry(
            "SCOPE", "unclassified-script", "review", rel, 0, 0, "", "",
            "脚本未分类：既不在生产入口，也未命中排除模式",
            "需要实现决策：登记为生产脚本、辅助脚本或排除模式，避免范围悄悄失效。",
        ))
    if contract is None:
        findings.append(_entry(
            "SCOPE", "spec-unreadable", "error", SHELL_SPEC, 0, 0, "", "",
            "无法从规格解析白名单，白名单判定不可信",
            "需要实现决策：修复规格表格或本工具的解析。",
        ))
    for item in spec_drift(contract):
        findings.append(_entry(
            "SCOPE", "spec-drift", "error", SHELL_SPEC, 0, 0, "", "", item,
            "需要实现决策：白名单唯一真源是规格，先确认规格改动再改脚本。",
        ))
    auxiliary = {}
    allowed = contract["allowed"] if contract else set()
    for item in scope["auxiliary"]:
        if not item["exists"]:
            continue
        text = (root / item["file"]).read_text(encoding="utf-8")
        _hits, used = audit_source(text, item["file"], functions, contract)
        # 只保留真正的命令词：过滤命令替换/算术展开与纯参数词，避免噪声淹没结论。
        outside = {name: count for name, count in sorted(used.items())
                   if name not in allowed | SHELL_BUILTINS | functions
                   and _looks_like_command(name)}
        auxiliary[item["file"]] = {"invokedBy": item["invokedBy"], "outsideWhitelist": outside}
    findings.sort(key=lambda f: (f["file"], f["line"], f["col"], f["rule"], f["code"]))
    summary = {"errors": 0, "reviews": 0}
    by_rule = {}
    by_severity = {}
    for item in findings:
        by_rule[item["rule"]] = by_rule.get(item["rule"], 0) + 1
        by_severity[item["severity"]] = by_severity.get(item["severity"], 0) + 1
        if item["severity"] == "error":
            summary["errors"] += 1
        elif item["severity"] == "review":
            summary["reviews"] += 1
    summary["by_rule"] = dict(sorted(by_rule.items()))
    summary["by_severity"] = dict(sorted(by_severity.items()))
    return {
        "tool": "shell_contract",
        "root": str(root),
        "spec": {"shell": SHELL_SPEC, "build": BUILD_SPEC},
        "whitelist": sorted(allowed),
        "scope": scope,
        "findings": findings,
        "auxiliary": auxiliary,
        "summary": summary,
        "limitations": list(LIMITATIONS),
    }


# ── 报告 ──────────────────────────────────────────────────────────────

def render_text(result):
    scope = result["scope"]
    summary = result["summary"]
    out = []
    out.append("== shell 契约静态审计（SH-1/SH-2/SH-3/SH-4、build.md B-1）==")
    out.append(f"仓库根：{result['root']}")
    out.append(f"规格：{result['spec']['shell']}、{result['spec']['build']}")
    out.append("")
    out.append(f"生产入口 {len(scope['entry'])} 个、被 source 库 {len(scope['lib'])} 个：")
    for item in scope["entry"] + scope["lib"]:
        state = f"{item['lines']} 行" if item["exists"] else "缺失"
        out.append(f"  [{item.get('purpose', '')}] {item['file']}（{state}）")
    out.append(f"生产入口调起的辅助脚本 {len(scope['auxiliary'])} 个（不计入生产判定）：")
    for item in scope["auxiliary"]:
        mark = "" if item["exists"] else "（缺失）"
        out.append(f"  {item['file']}{mark} <- {item.get('invokedBy', '')}")
    out.append(f"排除入口：{len(scope['excluded'])} 个文件，模式 {len(EXCLUSIONS)} 条")
    for pattern, why in EXCLUSIONS:
        out.append(f"  {pattern}：{why}")
    out.append(f"未分类脚本：{len(scope['unclassified'])} 个")
    for rel in scope["unclassified"]:
        out.append(f"  {rel}")
    out.append("")
    status = "失败" if summary["errors"] else "通过"
    out.append(f"判定：{status}（错误 {summary['errors']} 处，待复核 {summary['reviews']} 处）")
    out.append(f"按规则：{summary['by_rule'] or '无'}")
    out.append("")
    if result["findings"]:
        out.append("明细：")
        for item in result["findings"]:
            where = f"{item['file']}:{item['line']}:{item['col']}" if item["line"] else item["file"]
            out.append(f"  [{item['rule']}/{item['code']}/{item['severity']}] {where}")
            out.append(f"    {item['message']}")
            if item["text"]:
                out.append(f"    > {item['text']}")
            if item["decision"]:
                out.append(f"    决策：{item['decision']}")
        out.append("")
    if result["auxiliary"]:
        out.append("辅助脚本的白名单外命令（只统计，不判定）：")
        for rel, info in sorted(result["auxiliary"].items()):
            counts = "、".join(f"{name}×{count}" for name, count in info["outsideWhitelist"].items()) or "无"
            out.append(f"  {rel}（由 {info['invokedBy']} 调用）：{counts}")
        out.append("")
    out.append("限制：")
    for note in result["limitations"]:
        out.append(f"  - {note}")
    return "\n".join(out) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description="审计构建脚本的 shell 白名单与确定性约束")
    parser.add_argument("--root", default=str(ROOT), help="仓库根（默认取本文件的上一层）")
    parser.add_argument("--report", action="store_true", help="输出完整文本报告")
    parser.add_argument("--json", dest="json_path", help="把完整结果写入 JSON 文件")
    parser.add_argument("--text", dest="text_path", help="把文本报告写入文件")
    parser.add_argument("--strict", action="store_true", help="把待复核项也视为失败")
    parser.add_argument("--quiet", action="store_true", help="只输出一行摘要")
    args = parser.parse_args(argv)
    result = audit(args.root)
    report = render_text(result)
    if args.json_path:
        Path(args.json_path).write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.text_path:
        Path(args.text_path).write_text(report, encoding="utf-8")
    if args.quiet:
        s = result["summary"]
        print(f"shell 契约审计：错误 {s['errors']}、待复核 {s['reviews']}")
    elif args.report:
        sys.stdout.write(report)
    else:
        s = result["summary"]
        print(f"shell 契约审计：错误 {s['errors']}、待复核 {s['reviews']}；规则 {s['by_rule']}")
        for item in result["findings"]:
            where = f"{item['file']}:{item['line']}" if item["line"] else item["file"]
            print(f"  [{item['rule']}/{item['severity']}] {where} {item['message']}")
    failed = result["summary"]["errors"] > 0 or (args.strict and result["summary"]["reviews"] > 0)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
