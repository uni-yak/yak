"""拒绝形态语料覆盖审计。

从规格与常驻夹具自动建立映射：
- spec/**/*.md 中标题含“拒绝形态”的章节表格，提取形如 R-1 的形态编号；
- spec/proc/error.def 中 entry 的 ref 锚点，以及拒绝表格中显式登记且已注册的错误码；
- test/bad/**/*.yak 头部的 spec / expected_code / expected_diagnostics / dependency / module_graph 标记；
- test/gate/test_seed_host_rejections.sh 的 cover 与 reject 分组，用于必须经 Seed 宿主入口触发的拒绝。
- test/gate/test_c0_cross_frame_cleanup.sh 的运行期陷阱声明及读写失败断言。
- test/gate/test_native_iface_rejection.sh 的原生接口拒绝声明及各项破坏输入。
- tools/test_contracts.py 中工具负例的 rejection_spec 声明。
- Seed 词法与脱糖回归中，扩展字面量和生产脱糖边界的唯一诊断断言。
- Seed 驱动的发射器回归中，链接身份和位宽的精确错误码断言。
- MIR 镜像读写回归中的 YSM 容器与操作数拒绝断言。

审计只做静态读取：不编译、不写回规格或生成物。--check 在存在完整性错误、
需夹具形态缺口、full 层待映射形态或缺失规格时以非零退出码报告未完成。
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC_REL = "spec"
BAD_REL = "test/bad"
HOST_SUITE = "test/gate/test_seed_host_rejections.sh"
FOREIGN_TRAP_SUITE = "test/gate/test_c0_cross_frame_cleanup.sh"
SYSV_SYSCALL_SUITE = "test/gate/test_sysv_syscall_rejection.sh"
INTERFACE_SUITE = "test/gate/test_native_iface_rejection.sh"
IFACE_WRITE_SUITE = "seed/test/t234_min_iface_descriptors.yak"
IFACE_READ_SUITE = "seed/test/t233_min_iface_load.yak"
IFACE_BRIDGE_SUITE = "seed/test/t236_min_iface_bridge.yak"
RESOLVE_SUITE = "seed/test/t227_min_resolve_refs.yak"
MIR_VERIFY_SUITE = "seed/test/t238_min_mir.yak"
LITERAL_LEX_SUITE = "seed/test/t427_min_lex_literal_forms.yak"
DESUGAR_SUITE = "seed/test/t237_min_desugar.yak"
INITIALIZER_SUITE = "seed/test/t431_min_initializer_order.yak"
CLOSED_RANGES_SUITE = "seed/test/t432_min_closed_ranges.yak"
RESERVED_IF_LET_SUITE = "seed/test/t433_min_reserved_if_let.yak"
MONOMORPH_SUITE = "seed/test/t434_min_monomorph_signature.yak"
NULLABLE_SUITE = "seed/test/t435_min_nullable_frontend.yak"
PLAIN_UNION_SUITE = "seed/test/t436_min_plain_union_frontend.yak"
TEXT_SUITE = "seed/test/t437_min_text_frontend.yak"
TYPED_SOURCE_CONTRACTS = (
    (NULLABLE_SUITE, "invalid_nullable_contract",
     {f"E{5812 + i}": f"spec/lang/type/option.md#OP-{i}" for i in range(1, 5)}),
    (PLAIN_UNION_SUITE, "invalid_plain_union_contract",
     {f"E{5816 + i}": f"spec/lang/type/union.md#UN-{i}" for i in range(1, 5)}),
    (TEXT_SUITE, "invalid_text_contract", {"E6204": "spec/lang/type/string.md#STR-1"}),
)
TOOL_SUITE = "tools/test_contracts.py"
LINK_CONTRACT_SUITE = "seed/test/t241_min_emit_coff.yak"
ELF_CONTRACT_SUITE = "test/gate/fixtures/elf_object_emit.yak"
YSM_CONTRACT_SUITE = "seed/test/t240_min_ysm.yak"

FORMAT_RE = re.compile(r"^format\s+2\s*$", re.MULTILINE)
ENTRY_RE = re.compile(
    r'^entry\s+(E\d{2})\s+code\s+(\d{2})\s+ref\s+(\S+)\s+desc\s+"([^"]*)"\s*$'
)
SECTION_RE = re.compile(
    r"^##[^\n]*拒绝形态[^\n]*\n(.*?)(?=^## |\Z)", re.MULTILINE | re.DOTALL
)
ROW_RE = re.compile(r"^\|\s*([A-Z]+-\d+)\s*\|([^\n]*)$", re.MULTILINE)
STATUS_RE = re.compile(r"^-\s*状态：\s*(\S.*?)\s*$", re.MULTILINE)
CLASS_RE = re.compile(r"^-\s*拒绝形态类别：\s*(\S.*?)\s*$", re.MULTILINE)
INDEX_ROW_RE = re.compile(
    r"^\|\s*\x60([^\x60]+)\x60\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|"
)
MARKER_RE = re.compile(r"^\s*//\s*([a-z_]+)\s*:\s*(.*?)\s*$")
EXPECTED_CODE_RE = re.compile(r"^E\d{4}$")
DEPENDENCY_RE = re.compile(r"^[A-Za-z0-9_.-]+\.yak$")
E_CODE_RE = re.compile(r"\bE\d{4}\b")
HASH_REF_RE = re.compile(r"^(?P<doc>[^\s#]+?\.md)#(?P<anchor>[A-Z]+-\d+)$")
SPACE_REF_RE = re.compile(
    r"^(?P<doc>[^\s#]+?\.md)(?:\s+(?P<section>\d+(?:\.\d+)*))?\s+(?P<anchor>[A-Z]+-\d+)$"
)
BARE_ANCHOR_RE = re.compile(r"^[A-Z]+-\d+$")
SEP_RE = re.compile(r"[、,，;；]")
KNOWN_MARKERS = {"spec", "expected_code", "expected_diagnostics", "dependency", "module_graph"}
GRAPH_AMBIGUITY_RE = re.compile(r"^ambiguous ([a-zA-Z_][a-zA-Z_0-9]*)$")
HOST_COVER_RE = re.compile(r"^cover (E\d{4}) (spec/proc/host\.md#HS-\d+)$")
HOST_REJECT_RE = re.compile(r"^reject ([a-z][a-z0-9_]*) '(E\d{4}) host: [^']+'(?: |$)")
RUNTIME_SPEC_RE = re.compile(r"^# runtime_spec: (E\d{4}) (spec/lang/foreign\.md#F-4)$")
FOREIGN_TRAP_CASE_RE = re.compile(
    r"^\s+check_foreign_trap (\d+) (read|write) 70 'yak: (read|write) failed'$"
)
TOOL_SPEC_RE = re.compile(r"^rejection_spec: (E\d{4}) (spec/lang/symbol\.md#S-\d+|spec/target/pe\.md#PE-[1-4])$")
LINK_SPEC_RE = re.compile(
    r"^rejection_spec: (E\d{4}) (spec/lang/symbol\.md#S-\d+|spec/target/abi-win\.md#AW-[1-4]"
    r"|spec/target/abi-linux\.md#AL-[124]|spec/target/emitter\.md#EM-[1-6]|spec/target/x86\.md#X-[1-3])$"
)
INTERFACE_SPEC_RE = re.compile(r"^# interface_spec: (E\d{4}) (spec/lang/symbol\.md#S-12)$")
BAD_INTERFACE_RE = re.compile(r"^check_bad_interface (directory|digest|profile|signature) (E\d{4})$")


@dataclass
class ErrorEntry:
    """error.def 中的一条错误码登记，保留解析后的目标文档与锚点。"""

    code: str
    ref: str
    target: str | None
    anchor: str
    line: int


@dataclass
class SpecRow:
    """一条拒绝形态及其自动推导出的错误码映射与覆盖路线。"""

    spec: str
    anchor: str
    content: str
    mapping: str = "unmapped"
    codes: tuple[str, ...] = ()
    route: str = "fixture"
    covered_by: list[str] = field(default_factory=list)


@dataclass
class SpecDoc:
    """一份规格文档的元信息与拒绝形态表。"""

    path: str
    status: str | None
    rejection_class: str | None
    text: str = field(default="", repr=False)
    rows: list[SpecRow] = field(default_factory=list)

    @property
    def rows_by_anchor(self) -> dict[str, SpecRow]:
        return {row.anchor: row for row in self.rows}


@dataclass
class FixtureRef:
    """负例头部中一条严格的规格锚点引用。"""

    raw: str
    spec: str
    anchor: str


@dataclass
class Fixture:
    """一个负例源文件的头部解析结果。"""

    path: str
    directory: str
    name: str
    expected_code: str | None
    diagnostics: list[str]
    dependencies: list[str]
    refs: list[FixtureRef]
    is_root: bool
    code_ok: bool = False

    @property
    def dir_name(self) -> str:
        return Path(self.directory).name


@dataclass
class ExecutableFixture:
    """由实际驱动或目标进程执行的拒绝夹具。"""

    path: str
    expected_code: str
    refs: list[FixtureRef]
    code_ok: bool
    cases: list[str]


@dataclass
class ToolFixture:
    """与可直接调用的 unittest 方法关联的工具负例。"""

    path: str
    expected_code: str
    refs: list[FixtureRef]
    code_ok: bool
    test: str


def make_error(code: str, path: str = "", detail: str = "", line: int | None = None) -> dict:
    """构造一条确定性的完整性错误。"""
    item = {"code": code, "path": path, "detail": detail}
    if line is not None:
        item["line"] = line
    return item


def read_utf8(path: Path, rel: str, errors: list[dict]) -> str:
    """读取 UTF-8 文本；失败时记录错误并返回空串，让审计继续收集其余问题。"""
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        errors.append(make_error("read_error", rel, str(exc)))
    except UnicodeDecodeError as exc:
        errors.append(make_error("read_error", rel, f"非 UTF-8 文本：{exc}"))
    return ""


def anchor_key(anchor: str) -> tuple[str, int]:
    """按前缀和数值排序锚点，避免 R-10 排在 R-2 之前。"""
    match = re.fullmatch(r"([A-Z]+)-(\d+)", anchor)
    if match:
        return (match.group(1), int(match.group(2)))
    return (anchor, 0)


def normalize_doc_path(raw: str) -> str | None:
    """把规格路径规范为相对 spec/ 的 POSIX 路径；拒绝绝对路径和目录穿越。"""
    value = raw.strip().replace("\\", "/")
    if value.startswith("spec/"):
        value = value[len("spec/") :]
    if not value.endswith(".md"):
        return None
    if value.startswith("/") or re.match(r"^[A-Za-z]:", value):
        return None
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return None
    return value


def resolve_ref(spec_dir: Path, origin: Path, target: str) -> str | None:
    """解析 error.def 的 ref 目标；允许相对 error.def 或回退到 spec/lang/。"""
    raw = target.replace("\\", "/")
    candidates = [origin.parent / raw, spec_dir / "lang" / raw]
    for candidate in candidates:
        normalized = Path(os.path.normpath(str(candidate)))
        try:
            rel = normalized.relative_to(spec_dir)
        except ValueError:
            continue
        if normalized.is_file():
            return rel.as_posix()
    return None


def load_spec_docs(spec_dir: Path, errors: list[dict]) -> dict[str, SpecDoc]:
    """读取全部规格文档，抽取状态、拒绝形态类别与拒绝表行。"""
    docs: dict[str, SpecDoc] = {}
    if not spec_dir.is_dir():
        errors.append(make_error("missing_spec_dir", SPEC_REL, "规格目录不存在"))
        return docs
    paths = sorted(spec_dir.rglob("*.md"), key=lambda p: p.relative_to(spec_dir).as_posix())
    for path in paths:
        rel = path.relative_to(spec_dir).as_posix()
        text = read_utf8(path, f"{SPEC_REL}/{rel}", errors)
        status_match = STATUS_RE.search(text)
        class_match = CLASS_RE.search(text)
        doc = SpecDoc(
            path=rel,
            status=status_match.group(1) if status_match else None,
            rejection_class=class_match.group(1) if class_match else None,
            text=text,
        )
        seen: set[str] = set()
        for section in SECTION_RE.finditer(text):
            body = section.group(1)
            base_offset = section.start(1)
            for row_match in ROW_RE.finditer(body):
                anchor = row_match.group(1)
                content = row_match.group(2)
                line = text.count("\n", 0, base_offset + row_match.start()) + 1
                if anchor in seen:
                    errors.append(
                        make_error(
                            "duplicate_spec_row",
                            f"{SPEC_REL}/{rel}",
                            f"拒绝形态锚点 {anchor} 在同一规格中重复登记",
                            line,
                        )
                    )
                    continue
                seen.add(anchor)
                doc.rows.append(SpecRow(spec=rel, anchor=anchor, content=content))
        doc.rows.sort(key=lambda row: anchor_key(row.anchor))
        docs[rel] = doc
    return docs


def load_error_def(
    spec_dir: Path, docs: dict[str, SpecDoc], errors: list[dict]
) -> tuple[dict[str, ErrorEntry], dict[tuple[str, str], list[str]]]:
    """解析 error.def，返回码位表与（规格, 锚点）到码位的映射。"""
    entries: dict[str, ErrorEntry] = {}
    mapping: dict[tuple[str, str], list[str]] = {}
    source = spec_dir / "proc/error.def"
    rel = "spec/proc/error.def"
    if not source.is_file():
        errors.append(make_error("missing_error_def", rel, "错误码真源不存在"))
        return entries, mapping
    text = read_utf8(source, rel, errors)
    if not FORMAT_RE.search(text):
        errors.append(make_error("invalid_error_def", rel, "缺少 format 2 声明"))
    for line_no, line in enumerate(text.splitlines(), 1):
        if not line.startswith("entry"):
            continue
        match = ENTRY_RE.match(line)
        if not match:
            errors.append(make_error("invalid_error_entry", rel, f"无法解析：{line}", line_no))
            continue
        code = match.group(1) + match.group(2)
        ref = match.group(3)
        if code in entries:
            errors.append(make_error("duplicate_error_code", rel, f"错误码 {code} 重复登记", line_no))
            continue
        target_text, sep, anchor = ref.rpartition(":")
        target: str | None = None
        if not sep or not target_text or not anchor:
            errors.append(make_error("invalid_error_ref", rel, f"ref 缺少文档或锚点：{ref}", line_no))
        else:
            target = resolve_ref(spec_dir, source, target_text)
            if target is None:
                errors.append(
                    make_error("unresolved_error_ref", rel, f"ref 目标不存在：{ref}", line_no)
                )
            elif target not in docs:
                errors.append(
                    make_error("unresolved_error_ref", rel, f"ref 目标不是已读取的规格：{ref}", line_no)
                )
            elif not re.search(
                r"(?<![\w.-])" + re.escape(anchor) + r"(?![\w.-])", docs[target].text
            ):
                errors.append(
                    make_error(
                        "dangling_error_ref",
                        rel,
                        f"ref 锚点 {anchor} 未出现在 {target} 中",
                        line_no,
                    )
                )
        entry = ErrorEntry(code=code, ref=ref, target=target, anchor=anchor, line=line_no)
        entries[code] = entry
        if target is not None and re.fullmatch(r"[A-Z]+-\d+", anchor):
            mapping.setdefault((target, anchor), []).append(code)
    return entries, mapping


def index_missing_specs(
    spec_dir: Path, docs: dict[str, SpecDoc], errors: list[dict]
) -> list[dict]:
    """从 index.md 的“缺失”行和文档自身状态自动汇总缺失规格。"""
    missing: dict[str, dict] = {}
    index_path = spec_dir / "index.md"
    if index_path.is_file():
        text = read_utf8(index_path, "spec/index.md", errors)
        for line in text.splitlines():
            match = INDEX_ROW_RE.match(line)
            if not match:
                continue
            raw_path, layer, status = match.group(1), match.group(2).strip(), match.group(3).strip()
            if status != "缺失":
                continue
            doc = normalize_doc_path(raw_path)
            if doc is None:
                continue
            missing[doc] = {"spec": doc, "layer": layer or None}
    for doc in docs.values():
        if doc.status == "缺失":
            missing.setdefault(doc.path, {"spec": doc.path, "layer": None})
    return sorted(missing.values(), key=lambda item: item["spec"])


def parse_spec_value(
    value: str, path: str, line: int, errors: list[dict]
) -> list[FixtureRef]:
    """严格解析 spec 标记：必须写成 文档#锚点 或 文档 [节号] 锚点。"""
    refs: list[FixtureRef] = []
    for segment in SEP_RE.split(value):
        raw = segment.strip()
        if not raw:
            errors.append(make_error("empty_spec_ref", path, "spec 标记含空引用", line))
            continue
        match = HASH_REF_RE.fullmatch(raw) or SPACE_REF_RE.fullmatch(raw)
        if not match:
            if BARE_ANCHOR_RE.fullmatch(raw):
                errors.append(
                    make_error(
                        "bare_anchor",
                        path,
                        f"裸锚点 {raw} 跨文档不唯一，必须写成 spec/<文档>.md#<锚点>",
                        line,
                    )
                )
            else:
                errors.append(
                    make_error(
                        "malformed_spec_ref",
                        path,
                        f"无法解析的 spec 引用：{raw}",
                        line,
                    )
                )
            continue
        doc = normalize_doc_path(match.group("doc"))
        if doc is None:
            errors.append(
                make_error("invalid_spec_path", path, f"非法规格路径：{match.group('doc')}", line)
            )
            continue
        refs.append(FixtureRef(raw=raw, spec=doc, anchor=match.group("anchor")))
    return refs


def load_fixture(path: Path, root: Path, errors: list[dict]) -> Fixture:
    """解析一个 .yak 文件的头部标记，并记录头部语法错误。"""
    rel = path.relative_to(root).as_posix()
    text = read_utf8(path, rel, errors)
    lines = text.splitlines()
    header_end = 0
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "" or stripped.startswith("//"):
            header_end = index + 1
            continue
        break
    header = lines[:header_end]
    body = lines[header_end:]

    values: dict[str, list[tuple[str, int]]] = {name: [] for name in KNOWN_MARKERS}
    for index, line in enumerate(header, 1):
        match = MARKER_RE.match(line)
        if match and match.group(1) in KNOWN_MARKERS:
            values[match.group(1)].append((match.group(2), index))
    for index, line in enumerate(body, header_end + 1):
        match = MARKER_RE.match(line)
        if match and match.group(1) in KNOWN_MARKERS:
            errors.append(
                make_error(
                    "marker_after_header",
                    rel,
                    f"标记 {match.group(1)} 出现在源码头部之后",
                    index,
                )
            )

    for name in ("spec", "expected_code", "expected_diagnostics", "module_graph"):
        if len(values[name]) > 1:
            errors.append(
                make_error(
                    "duplicate_marker",
                    rel,
                    f"标记 {name} 出现了 {len(values[name])} 次，只允许一次",
                    values[name][1][1],
                )
            )

    refs: list[FixtureRef] = []
    for value, line in values["spec"]:
        if value == "":
            errors.append(make_error("empty_spec_marker", rel, "spec 标记为空", line))
            continue
        refs.extend(parse_spec_value(value, rel, line, errors))

    expected_code = values["expected_code"][0][0] if values["expected_code"] else None
    is_root = bool(values["expected_code"])
    if is_root and not values["spec"]:
        errors.append(
            make_error(
                "missing_spec_anchor",
                rel,
                "根用例缺少 // spec: 拒绝形态锚点",
                values["expected_code"][0][1],
            )
        )
    if expected_code is not None and not EXPECTED_CODE_RE.fullmatch(expected_code):
        errors.append(
            make_error("invalid_expected_code", rel, f"非法错误码：{expected_code}", values["expected_code"][0][1])
        )

    diagnostics: list[str] = []
    if values["expected_diagnostics"]:
        raw = values["expected_diagnostics"][0][0]
        if raw == "":
            errors.append(
                make_error(
                    "invalid_expected_diagnostics",
                    rel,
                    "expected_diagnostics 标记为空",
                    values["expected_diagnostics"][0][1],
                )
            )
        else:
            diagnostics = raw.split()

    dependencies: list[str] = []
    for value, line in values["dependency"]:
        if not DEPENDENCY_RE.fullmatch(value):
            errors.append(
                make_error("invalid_dependency_name", rel, f"非法依赖文件名：{value}", line)
            )
            continue
        dependencies.append(value)

    if values["module_graph"]:
        graph, line = values["module_graph"][0]
        ambiguity = GRAPH_AMBIGUITY_RE.fullmatch(graph)
        if not is_root or (graph != "scan" and ambiguity is None):
            errors.append(make_error("invalid_module_graph", rel, "模块图标记无效或不在负例根上", line))
        elif ambiguity is not None and (
            expected_code != "E4003"
            or (diagnostics and diagnostics != ["E4003"])
            or dependencies != [ambiguity.group(1) + ".yak"]
        ):
            errors.append(make_error("invalid_module_graph", rel, "模块歧义须声明唯一的同名依赖及单条 E4003", line))

    return Fixture(
        path=rel,
        directory=Path(rel).parent.as_posix(),
        name=path.name,
        expected_code=expected_code,
        diagnostics=diagnostics,
        dependencies=dependencies,
        refs=refs,
        is_root=is_root,
    )


def load_fixtures(bad_dir: Path, errors: list[dict]) -> tuple[list[Fixture], list[Fixture]]:
    """读取 test/bad 下全部 .yak，返回根与依赖两类夹具。"""
    fixtures: list[Fixture] = []
    if not bad_dir.is_dir():
        errors.append(make_error("missing_bad_dir", BAD_REL, "负例语料目录不存在"))
        return [], []
    for path in sorted(bad_dir.rglob("*.yak"), key=lambda p: p.as_posix()):
        fixtures.append(load_fixture(path, bad_dir.parents[1], errors))
    roots = [fixture for fixture in fixtures if fixture.is_root]
    return roots, fixtures


def validate_fixtures(
    fixtures: list[Fixture],
    roots: list[Fixture],
    registered_codes: set[str],
    errors: list[dict],
) -> None:
    """校验错误码、目录、依赖与孤儿文件等夹具结构规则。"""
    by_location = {(fixture.directory, fixture.name): fixture for fixture in fixtures}
    referenced: set[tuple[str, str]] = set()

    for fixture in roots:
        problems = 0
        code = fixture.expected_code or ""
        if not EXPECTED_CODE_RE.fullmatch(code):
            problems += 1
        else:
            if fixture.dir_name != code:
                errors.append(
                    make_error(
                        "directory_code_mismatch",
                        fixture.path,
                        f"目录名 {fixture.dir_name} 与 expected_code {code} 不一致",
                    )
                )
                problems += 1
            if code not in registered_codes:
                errors.append(
                    make_error(
                        "unregistered_expected_code",
                        fixture.path,
                        f"expected_code {code} 未在 spec/proc/error.def 登记",
                    )
                )
                problems += 1
        fixture.code_ok = problems == 0
        for name in fixture.dependencies:
            target = by_location.get((fixture.directory, name))
            if target is None:
                errors.append(
                    make_error("missing_dependency", fixture.path, f"依赖不存在：{name}")
                )
                continue
            if target.is_root:
                errors.append(
                    make_error("dependency_is_root", fixture.path, f"依赖同时是根用例：{name}")
                )
                continue
            referenced.add((fixture.directory, name))

    for fixture in fixtures:
        if not fixture.is_root and (fixture.directory, fixture.name) not in referenced:
            errors.append(
                make_error(
                    "orphan_fixture",
                    fixture.path,
                    "文件既不是根用例，也未被任何根声明为同目录依赖",
                )
            )
        if not fixture.is_root and fixture.refs:
            errors.append(
                make_error("nonroot_spec_marker", fixture.path, "依赖单元不得声明 spec 锚点")
            )

    for fixture in roots:
        if not fixture.diagnostics:
            continue
        if fixture.expected_code and fixture.expected_code not in fixture.diagnostics:
            errors.append(
                make_error(
                    "diagnostics_missing_primary",
                    fixture.path,
                    f"expected_diagnostics 未包含主错误码 {fixture.expected_code}",
                )
            )
        for code in fixture.diagnostics:
            if not EXPECTED_CODE_RE.fullmatch(code):
                errors.append(
                    make_error("invalid_diagnostic_code", fixture.path, f"非法诊断错误码：{code}")
                )
            elif code not in registered_codes:
                errors.append(
                    make_error(
                        "unregistered_diagnostic_code",
                        fixture.path,
                        f"诊断错误码 {code} 未在 error.def 登记",
                    )
                )


def assign_coverage(
    roots: list[Fixture | ExecutableFixture | ToolFixture],
    docs: dict[str, SpecDoc],
    errors: list[dict],
) -> dict[str, int]:
    """把夹具锚点映射到规格行；返回覆盖/重复等计数。"""
    claims: dict[tuple[str, str], str] = {}
    stats = {"claims": 0, "duplicates": 0}
    for fixture in sorted(roots, key=lambda item: item.path):
        for ref in fixture.refs:
            doc = docs.get(ref.spec)
            if doc is None:
                errors.append(
                    make_error("unknown_spec_doc", fixture.path, f"未知规格文档：{ref.spec}")
                )
                continue
            row = doc.rows_by_anchor.get(ref.anchor)
            if row is None:
                errors.append(
                    make_error(
                        "unknown_anchor",
                        fixture.path,
                        f"{ref.spec} 的拒绝形态表中不存在锚点 {ref.anchor}",
                    )
                )
                continue
            if row.route == "gate":
                errors.append(
                    make_error(
                        "gate_anchor_fixture",
                        fixture.path,
                        f"{ref.spec}#{ref.anchor} 是门禁断言，不能由语料夹具承担",
                    )
                )
                continue
            if row.route == "full_debt":
                errors.append(
                    make_error(
                        "unmapped_anchor",
                        fixture.path,
                        f"{ref.spec}#{ref.anchor} 尚未登记错误码，不能作为夹具断言",
                    )
                )
                continue
            if not fixture.code_ok:
                continue
            if fixture.expected_code not in row.codes:
                errors.append(
                    make_error(
                        "code_anchor_mismatch",
                        fixture.path,
                        f"{ref.spec}#{ref.anchor} 的已登记码位为 {','.join(row.codes)}，"
                        f"与 expected_code {fixture.expected_code} 不一致",
                    )
                )
                continue
            key = (ref.spec, ref.anchor)
            if key in claims:
                stats["duplicates"] += 1
                errors.append(
                    make_error(
                        "duplicate_anchor",
                        fixture.path,
                        f"{ref.spec}#{ref.anchor} 已由 {claims[key]} 覆盖，不能重复认领",
                    )
                )
                continue
            claims[key] = fixture.path
            row.covered_by.append(fixture.path)
            stats["claims"] += 1
    return stats


def load_host_coverage(root: Path, registered: set[str], errors: list[dict]) -> list[Fixture]:
    """核对真实宿主专项中的分组、码位和至少一个精确拒绝断言。"""
    path = root / HOST_SUITE
    if not path.exists():
        return []
    groups: list[Fixture] = []
    seen: set[str] = set()
    current: Fixture | None = None
    lines = read_utf8(path, HOST_SUITE, errors).splitlines()
    for line_number, line in enumerate(lines, 1):
        if line.startswith("cover "):
            match = HOST_COVER_RE.fullmatch(line)
            if match is None:
                errors.append(make_error("invalid_host_cover", HOST_SUITE, "宿主分组需声明错误码与 HS 规格锚点", line_number))
                current = None
                continue
            code, ref = match.groups()
            location = f"{HOST_SUITE}:{line_number}"
            refs = parse_spec_value(ref, HOST_SUITE, line_number, errors)
            current = Fixture(location, "test/gate", code, code, [], [], refs, True, code in registered)
            if not current.code_ok:
                errors.append(make_error("unregistered_host_code", HOST_SUITE, f"宿主错误码未登记：{code}", line_number))
            groups.append(current)
        elif line.startswith("reject "):
            match = HOST_REJECT_RE.match(line)
            if match is None or current is None or match[2] != current.expected_code or match[1] in seen:
                errors.append(make_error("invalid_host_case", HOST_SUITE, "宿主用例必须有唯一名称并与所属分组的错误码一致", line_number))
                if current is not None:
                    current.code_ok = False
                continue
            seen.add(match[1])
            current.diagnostics.append(match[2])
    for group in groups:
        if not group.diagnostics:
            group.code_ok = False
            errors.append(make_error("empty_host_cover", group.path, "宿主分组至少需要一个拒绝断言"))
    return groups


def load_foreign_trap_coverage(
    root: Path, registered: set[str], errors: list[dict]
) -> list[ExecutableFixture]:
    """确认同一夹具精确断言读、写两条独立的陷阱退出。"""
    path = root / FOREIGN_TRAP_SUITE
    if not path.exists():
        return []
    lines = read_utf8(path, FOREIGN_TRAP_SUITE, errors).splitlines()
    markers = [(number, line) for number, line in enumerate(lines, 1)
               if line.startswith("# runtime_spec:")]
    if not markers:
        return []
    number, marker = markers[0]
    match = RUNTIME_SPEC_RE.fullmatch(marker)
    if match is None or len(markers) != 1:
        errors.append(make_error("invalid_runtime_spec", FOREIGN_TRAP_SUITE,
                                 "运行期夹具需要唯一的 foreign 拒绝锚点和错误码", number))
        return []
    code, ref = match.groups()
    refs = parse_spec_value(ref, FOREIGN_TRAP_SUITE, number, errors)
    code_ok = code in registered
    if not code_ok:
        errors.append(make_error("unregistered_runtime_code", FOREIGN_TRAP_SUITE,
                                 f"运行期锚点错误码未登记：{code}", number))
    services: set[str] = set()
    modes: set[int] = set()
    for case_number, line in enumerate(lines, 1):
        if not line.lstrip().startswith("check_foreign_trap "):
            continue
        case = FOREIGN_TRAP_CASE_RE.fullmatch(line)
        if case is None or case[2] != case[3] or case[2] in services or int(case[1]) in modes:
            code_ok = False
            errors.append(make_error("invalid_foreign_trap_case", FOREIGN_TRAP_SUITE,
                                     "读写失败必须使用不同模式、匹配服务诊断并退出 70", case_number))
            continue
        modes.add(int(case[1]))
        services.add(case[2])
    if services != {"read", "write"}:
        code_ok = False
        errors.append(make_error("incomplete_foreign_traps", FOREIGN_TRAP_SUITE,
                                 "需要读失败与写失败两个运行断言", number))
    return [ExecutableFixture(f"{FOREIGN_TRAP_SUITE}:{number}", code, refs, code_ok, sorted(services))]


def load_sysv_syscall_coverage(root: Path, registered: set[str], errors: list[dict]) -> list[ExecutableFixture]:
    """两个易失寄存器必须各有一条精确的原生拒绝断言。"""
    path = root / SYSV_SYSCALL_SUITE
    if not path.is_file():
        return []
    lines = read_utf8(path, SYSV_SYSCALL_SUITE, errors).splitlines()
    markers = [(i, line) for i, line in enumerate(lines, 1) if line.startswith("# runtime_spec:")]
    checks = [line for line in lines if line.startswith("check_syscall_variant ")]
    anchor = "spec/target/abi-linux.md#AL-3"
    if (len(markers) != 1 or markers[0][1] != f"# runtime_spec: E8016 {anchor}" or "E8016" not in registered
            or checks != ["check_syscall_variant rcx E8016", "check_syscall_variant r11 E8016"]):
        errors.append(make_error("invalid_sysv_syscall_contract", SYSV_SYSCALL_SUITE,
                                 "分别注入 rcx 和 r11 的泄漏并断言 E8016", markers[0][0] if markers else 1))
        return []
    number = markers[0][0]
    refs = parse_spec_value(anchor, SYSV_SYSCALL_SUITE, number, errors)
    return [ExecutableFixture(f"{SYSV_SYSCALL_SUITE}:{number}", "E8016", refs, True, ["rcx", "r11"])]


def load_interface_coverage(
    root: Path, registered: set[str], errors: list[dict]
) -> list[ExecutableFixture]:
    """核对真实接口驱动夹具的四条不同破坏路径。"""
    path = root / INTERFACE_SUITE
    if not path.exists():
        return []
    lines = read_utf8(path, INTERFACE_SUITE, errors).splitlines()
    markers = [(number, line) for number, line in enumerate(lines, 1)
               if line.startswith("# interface_spec:")]
    if not markers:
        return []
    number, marker = markers[0]
    match = INTERFACE_SPEC_RE.fullmatch(marker)
    if match is None or len(markers) != 1:
        errors.append(make_error("invalid_interface_spec", INTERFACE_SUITE,
                                 "接口专项需要唯一的拒绝锚点和错误码", number))
        return []
    code, ref = match.groups()
    refs = parse_spec_value(ref, INTERFACE_SUITE, number, errors)
    code_ok = code in registered
    if not code_ok:
        errors.append(make_error("unregistered_interface_code", INTERFACE_SUITE,
                                 f"接口错误码未登记：{code}", number))
    cases: set[str] = set()
    for case_number, line in enumerate(lines, 1):
        if not line.startswith("check_bad_interface "):
            continue
        case = BAD_INTERFACE_RE.fullmatch(line)
        if case is None or case[1] in cases or case[2] != code:
            code_ok = False
            errors.append(make_error("invalid_interface_case", INTERFACE_SUITE,
                                     "接口用例必须唯一且与登记错误码一致", case_number))
            continue
        cases.add(case[1])
    if cases != {"directory", "digest", "profile", "signature"}:
        code_ok = False
        errors.append(make_error("incomplete_interface_cases", INTERFACE_SUITE,
                                 "需要目录、摘要、profile 和签名四条拒绝断言", number))
    return [ExecutableFixture(f"{INTERFACE_SUITE}:{number}", code, refs, code_ok, sorted(cases))]


SYMBOL_CONTRACTS = (
    (IFACE_WRITE_SUITE, "iface::InterfaceResult = iface_write::write_interface", "E7011",
     "@len({0}.data.bytes) == 0 && @len({0}.digest) == 0 && {0}.export_count == 0", "invalid_iface_write_contract"),
    (IFACE_READ_SUITE, "iface::LoadedInterface = iface_load::load_interface", "E7015",
     "@len({0}.name_bytes) == 0 && @len({0}.exports) == 0 && @len({0}.digest) == 0", "invalid_iface_read_contract"),
    (IFACE_BRIDGE_SUITE, "resolve_refs::Resolution = resolve_unit::resolve_unit", "E7013",
     "@len({0}.refs.items) == 0 && @len({0}.bridges.items) == 0", "invalid_iface_bridge_contract"),
    (RESOLVE_SUITE, "resolve_refs::Resolution = resolve_unit::resolve_unit", "E7019",
     "@len({0}.refs.items) == 1 && {0}.refs.items[0].kind == 1", "invalid_name_cache_contract"),
)


def load_symbol_contract_coverage(root: Path, registered: set[str], errors: list[dict], contract: tuple[str, ...]) -> list[ToolFixture]:
    """登记符号入口返回精确诊断及受限结果的断言。"""
    suite, operation, expected_code, empty, invalid = contract
    path = root / suite
    if not path.is_file():
        return []
    lines = read_utf8(path, suite, errors).splitlines()
    producer = re.compile(rf"^let (\w+): {re.escape(operation)}\(.*, &(\w+):ReadWrite\)\?;$")
    fixtures = []
    for i, line in enumerate(lines):
        marker = line.strip()
        if not marker.startswith("// rejection_spec:"):
            continue
        ref_match = LINK_SPEC_RE.fullmatch(marker.removeprefix("// "))
        call = producer.fullmatch(lines[i - 1].strip()) if i > 0 else None
        if ref_match is not None and call is not None and i + 1 < len(lines):
            code, ref = ref_match.groups()
            result, diags = call.groups()
            expected = (f"assert(diag::diagbuf_count(&{diags}:Read) == 1 && {diags}.diags[0].code.raw == {code[1:]} "
                        f"&& {empty.format(result)});")
            if code == expected_code and code in registered and lines[i + 1].strip() == expected:
                refs = parse_spec_value(ref, suite, i + 1, errors)
                fixtures.append(ToolFixture(f"{suite}:{i + 1}", code, refs, True, result))
                continue
        errors.append(make_error(invalid, suite, "符号契约必须断言同一诊断缓冲的唯一错误和相应失败结果", i + 1))
    return fixtures


def load_tool_coverage(root: Path, registered: set[str], errors: list[dict]) -> list[ToolFixture]:
    """识别 unittest 方法中的工具拒绝锚点，不执行该文件。"""
    path = root / TOOL_SUITE
    if not path.exists():
        return []
    try:
        module = ast.parse(read_utf8(path, TOOL_SUITE, errors), filename=TOOL_SUITE)
    except SyntaxError as error:
        errors.append(make_error("invalid_tool_suite", TOOL_SUITE, error.msg, error.lineno))
        return []
    fixtures: list[ToolFixture] = []
    for cls in module.body:
        if not isinstance(cls, ast.ClassDef) or not any(
            ast.unparse(base) == "unittest.TestCase" for base in cls.bases
        ):
            continue
        for test in cls.body:
            if not isinstance(test, ast.FunctionDef) or not test.name.startswith("test_"):
                continue
            doc = ast.get_docstring(test) or ""
            markers = [line for line in doc.splitlines() if line.startswith("rejection_spec:")]
            if not markers:
                continue
            match = TOOL_SPEC_RE.fullmatch(markers[0])
            assertion = any(isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                            and isinstance(node.func.value, ast.Name) and node.func.value.id == "self"
                            and node.func.attr.startswith("assert") for node in ast.walk(test))
            if len(markers) != 1 or match is None or not assertion:
                errors.append(make_error("invalid_tool_spec", TOOL_SUITE,
                                         "工具负例需要唯一受支持的拒绝锚点、错误码与断言", test.lineno))
                continue
            code, ref = match.groups()
            code_ok = code in registered
            if not code_ok:
                errors.append(make_error("unregistered_tool_code", TOOL_SUITE,
                                         f"工具错误码未登记：{code}", test.lineno))
            refs = parse_spec_value(ref, TOOL_SUITE, test.lineno, errors)
            fixtures.append(ToolFixture(f"{TOOL_SUITE}:{test.lineno}", code, refs, code_ok,
                                        f"{cls.name}.{test.name}"))
    return fixtures


def load_link_contract_coverage(root: Path, registered: set[str], errors: list[dict]) -> list[ToolFixture]:
    """登记链接构造或对象发射结果紧邻的精确拒绝断言。"""
    path = root / LINK_CONTRACT_SUITE
    if not path.is_file():
        return []
    lines = read_utf8(path, LINK_CONTRACT_SUITE, errors).splitlines()
    build = re.compile(
        r"^let (\w+): (link_names::LinkBuild = link_names::build|coff::EmitResult = coff::emit_object)\(.*\)\?;$"
    )
    assemble = re.compile(r"^let (\w+): coff_code::Bytes = coff::assemble\(&(\w+):Read, &\w+:Read\)\?;$")
    check_reloc = re.compile(r"^let (\w+): u16 = coff::validate_reloc_sites\(&(\w+):Read\);$")
    frames = {"E8006": ("abi-win.md#AW-1", "win64_entry", 5), "E8007": ("abi-win.md#AW-2", "win64_entry", 5),
              "E8008": ("abi-win.md#AW-3", "win64_exit", 3), "E7102": ("x86.md#X-2", "win64_entry", 5),
              "E7103": ("x86.md#X-3", "win64_entry", 5), "E8014": ("abi-linux.md#AL-1", "sysv_entry", 5),
              "E8015": ("abi-linux.md#AL-2", "sysv_exit", 3)}
    fixtures = []
    for i, line in enumerate(lines):
        marker = line.strip()
        if not marker.startswith("// rejection_spec:"):
            continue
        ref_match = LINK_SPEC_RE.fullmatch(marker.removeprefix("// "))
        if ref_match is not None and ref_match[1] in registered and 0 < i < len(lines) - 1:
            code, ref = ref_match.groups()
            call = lines[i - 1].strip()
            producer = build.fullmatch(call)
            result = expected = ""
            if producer is not None:
                emitter = producer[2].startswith("coff::")
                allowed_codes = ({"E7001", "E8002", "E8003", "E8005", "E8022", "E8023"} if emitter
                                 else {"E7006", "E7009", "E8009"})
                if code in allowed_codes and (code != "E8009" or ref == "spec/target/abi-win.md#AW-4"):
                    result = producer[1]
                    payload = "bytes.data" if emitter else "table.symbols"
                    expected = (f"assert(!{result}.ok && {result}.code.raw == {code[1:]} "
                                f"&& @len({result}.{payload}) == 0);")
            elif code == "E8004" and i >= 2:
                assembled = assemble.fullmatch(call)
                status = check_reloc.fullmatch(lines[i - 2].strip())
                if assembled is not None and status is not None and assembled[2] == status[2]:
                    result = assembled[1]
                    expected = f"assert({status[1]} == 8004 && @len({result}.data) == 0);"
            elif code == "E7101" and ref == "spec/target/x86.md#X-1":
                check = re.fullmatch(r"let (\w+): u16 = x86_validate::validate\(&\w+:Read, \w+\)\?;", call)
                if check is not None:
                    result = check[1]
                    expected = f"assert({result} == 7101);"
            elif code == "E8017" and ref == "spec/target/abi-linux.md#AL-4":
                check = re.fullmatch(r"let (\w+): link_names::LinkBuild = link_names::build_target\(.*, true\)\?;", call)
                if check is not None:
                    result = check[1]
                    expected = f"assert(!{result}.ok && {result}.code.raw == 8017 && @len({result}.table.symbols) == 0);"
            elif code in frames:
                anchor, operation, arg_count = frames[code]
                check = re.fullmatch(rf"let (\w+): u16 = pe::validate_{operation}"
                                     rf"\(&\w+:Read(?:, \w+){{{arg_count}}}\);", call)
                if check is not None and ref == f"spec/target/{anchor}":
                    result = check[1]
                    expected = f"assert({result} == {code[1:]});"
            if expected and lines[i + 1].strip() == expected:
                refs = parse_spec_value(ref, LINK_CONTRACT_SUITE, i + 1, errors)
                fixtures.append(ToolFixture(f"{LINK_CONTRACT_SUITE}:{i + 1}", code, refs, True, result))
                continue
        errors.append(make_error("invalid_link_contract", LINK_CONTRACT_SUITE,
                                 "链接契约必须断言同一个生产结果与已登记码位；装配失败还须断言空产物", i + 1))
    return fixtures


def load_elf_contract_coverage(root: Path, registered: set[str], errors: list[dict]) -> list[ToolFixture]:
    """登记 ELF 生产头检查与对象容器精确拒绝结果。"""
    path = root / ELF_CONTRACT_SUITE
    if not path.is_file():
        return []
    lines = read_utf8(path, ELF_CONTRACT_SUITE, errors).splitlines()
    marker = re.compile(r"^// rejection_spec: (E801[89]|E802[01]) (spec/target/elf\.md#EL-([1-4]))$")
    head = re.compile(r"^let (\w+): u16 = elf::validate_header\(&\w+\.bytes\.data\[0\.\.\w+\]:Read\);$")
    emit = re.compile(r"^let (\w+): elf::ObjectResult = elf::emit_object\(&\w+:Read\)\?;$")
    fixtures = []
    for i, line in enumerate(lines):
        if not line.strip().startswith("// rejection_spec:"):
            continue
        ref = marker.fullmatch(line.strip())
        if ref is not None and ref[1] in registered and int(ref[1][1:]) == 8017 + int(ref[3]) and 0 < i < len(lines) - 1:
            code, anchor = ref[1], ref[2]
            check = (head if code == "E8018" else emit).fullmatch(lines[i - 1].strip())
            if check is not None:
                result = check[1]
                expected = (f"assert({result} == 8018);" if code == "E8018" else
                            f"assert({result}.code == {code[1:]} && @len({result}.bytes.data) == 0 && {result}.bytes.pos == 0);")
                if lines[i + 1].strip() == expected:
                    refs = parse_spec_value(anchor, ELF_CONTRACT_SUITE, i + 1, errors)
                    fixtures.append(ToolFixture(f"{ELF_CONTRACT_SUITE}:{i + 1}", code, refs, True, result))
                    continue
        errors.append(make_error("invalid_elf_contract", ELF_CONTRACT_SUITE,
                                 "ELF 契约必须核对生产拒绝码与对应锚点；容器装配拒绝还须核对空缓冲", i + 1))
    return fixtures


def load_mir_verify_coverage(root: Path, registered: set[str], errors: list[dict]) -> list[ToolFixture]:
    """登记 MIR 生产入口和验证器的精确拒绝断言。"""
    path = root / MIR_VERIFY_SUITE
    if not path.is_file():
        return []
    lines = read_utf8(path, MIR_VERIFY_SUITE, errors).splitlines()
    spec_marker = re.compile(r"^// rejection_spec: (E703[1-6]|E7018) (spec/ir/mir\.md#M-[1-6]|spec/lang/symbol\.md#S-18)$")
    verify = re.compile(r"^let (\w+): mir_verify::Validation = mir_verify::validate_module\(.*\)\?;$")
    lower = re.compile(r"^let (\w+): mir::MirResult = mir_lower::build_mir\(.*, &(\w+):ReadWrite\)\?;$")
    fixtures = []
    for i, line in enumerate(lines):
        marker = line.strip()
        if not marker.startswith("// rejection_spec:"):
            continue
        match = spec_marker.fullmatch(marker)
        if match is not None and 0 < i < len(lines) - 1:
            code, ref = match.groups()
            call_line = lines[i - 1].strip()
            call = lower.fullmatch(call_line) if code == "E7018" else verify.fullmatch(call_line)
            if call is not None and code in registered:
                result = call[1]
                if code == "E7018":
                    diags = call[2]
                    expected = (f"assert(!{result}.accepted && @len({result}.module.functions) == 0 "
                                f"&& diag::diagbuf_count(&{diags}:Read) == 1 && {diags}.diags[0].code.raw == 7018);")
                else:
                    expected = f"assert(!{result}.ok && {result}.code.raw == {code[1:]});"
                if lines[i + 1].strip() == expected:
                    refs = parse_spec_value(ref, MIR_VERIFY_SUITE, i + 1, errors)
                    fixtures.append(ToolFixture(f"{MIR_VERIFY_SUITE}:{i + 1}", code, refs, True, result))
                    continue
        errors.append(make_error("invalid_mir_verify_contract", MIR_VERIFY_SUITE,
                                 "MIR 契约必须断言生产验证器返回拒绝与已登记码位", i + 1))
    return fixtures


def load_literal_lex_coverage(root: Path, registered: set[str], errors: list[dict]) -> list[ToolFixture]:
    """登记显式字面量扫描入口的唯一诊断与空 token 结果。"""
    path = root / LITERAL_LEX_SUITE
    if not path.is_file():
        return []
    lines = read_utf8(path, LITERAL_LEX_SUITE, errors).splitlines()
    marker = re.compile(r"^// rejection_spec: (E10(1[2-5])) (spec/lang/lex\.md#L-\2)$")
    produce = re.compile(r"^let (\w+): lex::LexResult = lex::lex_scan_literals\(.+, \w+\)\?;$")
    fixtures = []
    for i, line in enumerate(lines):
        if not line.strip().startswith("// rejection_spec:"):
            continue
        ref = marker.fullmatch(line.strip())
        if ref is not None and ref[1] in registered and 0 < i < len(lines) - 1:
            call = produce.fullmatch(lines[i - 1].strip())
            if call is not None:
                name = call[1]
                expected = (f"assert(@len({name}.tokens) == 0 && @len({name}.diagnostics) == 1 "
                            f"&& {name}.diagnostics[0].code.raw == {ref[1][1:]});")
                if lines[i + 1].strip() == expected:
                    refs = parse_spec_value(ref[3], LITERAL_LEX_SUITE, i + 1, errors)
                    fixtures.append(ToolFixture(f"{LITERAL_LEX_SUITE}:{i + 1}", ref[1], refs, True, name))
                    continue
        errors.append(make_error("invalid_literal_lex_contract", LITERAL_LEX_SUITE,
                                 "字面量拒绝必须核对显式扫描器的同一结果、唯一诊断与空 token 流", i + 1))
    return fixtures


def load_desugar_coverage(root: Path, registered: set[str], errors: list[dict], suite: str) -> list[ToolFixture]:
    """登记生产脱糖边界的拒绝状态、失败产物与唯一诊断。"""
    path = root / suite
    if not path.is_file():
        return []
    lines = read_utf8(path, suite, errors).splitlines()
    if suite == INITIALIZER_SUITE:
        code_pattern = "6"
        produce = re.compile(r"^let (\w+): desugar::InitializerPlan = desugar::plan_initializers\(.+, &(\w+):ReadWrite\)\?;$")
        rejection = "!{name}.ok && @len({name}.order) == 0 && "
    elif suite == MONOMORPH_SUITE:
        code_pattern = "7"
        produce = re.compile(r"^let (\w+): monomorph::InstanceSignature = monomorph::instantiate_signature\(.+, &(\w+):ReadWrite\)\?;$")
        rejection = "!{name}.ok && @len({name}.arguments) == 0 && @len({name}.params) == 0 && {name}.result == 0 && "
    elif suite in (CLOSED_RANGES_SUITE, RESERVED_IF_LET_SUITE):
        code_pattern = "5" if suite == CLOSED_RANGES_SUITE else "4"
        produce = re.compile(
            r"^let (\w+): typecheck::TypeCheckResult = typecheck_driver::typecheck_unit"
            r"\(&(\w+)\.file:Read, &\2\.pool:Read, &\w+:Read, &(\w+):ReadWrite\)\?;$"
        )
        rejection = ""
    else:
        code_pattern = "[123]"
        produce = re.compile(
            r"^let (\w+): bool = desugar::verify_base\(&(\w+)\.file:Read, &\2\.pool:Read, &(\w+):ReadWrite\)\?;$"
        )
        rejection = "!{name} && "
    marker = re.compile(rf"^// rejection_spec: (E300({code_pattern})) (spec/lang/sugar\.md#SU-\2)$")
    fixtures = []
    for i, line in enumerate(lines):
        if not line.strip().startswith("// rejection_spec:"):
            continue
        ref = marker.fullmatch(line.strip())
        if ref is not None and ref[1] in registered and 0 < i < len(lines) - 1:
            call = produce.fullmatch(lines[i - 1].strip())
            if call is not None:
                result, *_, buf = call.groups()
                expected = (f"assert({rejection.format(name=result)}diag::diagbuf_count(&{buf}:Read) == 1 "
                            f"&& {buf}.diags[0].code.raw == {ref[1][1:]});")
                if lines[i + 1].strip() == expected:
                    refs = parse_spec_value(ref[3], suite, i + 1, errors)
                    fixtures.append(ToolFixture(f"{suite}:{i + 1}", ref[1], refs, True, result))
                    continue
        errors.append(make_error("invalid_desugar_contract", suite,
                                 "脱糖拒绝必须核对生产边界的失败返回、失败产物和同一缓冲区中的唯一诊断", i + 1))
    return fixtures


def load_typed_source_coverage(
    root: Path, registered: set[str], errors: list[dict], suite: str, error: str, anchors: dict[str, str],
) -> list[ToolFixture]:
    """登记从完整源码进入类型检查的唯一诊断。"""
    path = root / suite
    if not path.is_file():
        return []
    lines = read_utf8(path, suite, errors).splitlines()
    marker = re.compile(r"^// rejection_spec: (E\d{4}) (\S+)$")
    produce = re.compile(
        r"^let (\w+): typecheck::TypeCheckResult = typecheck_driver::typecheck_unit"
        r"\(&(\w+)\.parsed\.file:Read, &\2\.parsed\.pool:Read, &\2\.resolved:Read, &(\w+):ReadWrite\)\?;$"
    )
    fixtures = []
    for i, line in enumerate(lines):
        if not line.strip().startswith("// rejection_spec:"):
            continue
        ref = marker.fullmatch(line.strip())
        if ref is not None and ref[1] in registered and anchors.get(ref[1]) == ref[2] and 0 < i < len(lines) - 1:
            call = produce.fullmatch(lines[i - 1].strip())
            if call is not None:
                result, _, buf = call.groups()
                expected = (f"assert(diag::diagbuf_count(&{buf}:Read) == 1 "
                            f"&& {buf}.diags[0].code.raw == {ref[1][1:]});")
                if lines[i + 1].strip() == expected:
                    refs = parse_spec_value(ref[2], suite, i + 1, errors)
                    fixtures.append(ToolFixture(f"{suite}:{i + 1}", ref[1], refs, True, result))
                    continue
        errors.append(make_error(error, suite, "类型拒绝必须核对同一源码的生产类型检查结果与唯一诊断", i + 1))
    return fixtures


def load_ysm_contract_coverage(root: Path, registered: set[str], errors: list[dict]) -> list[ToolFixture]:
    """登记真实读写或指令扫描入口的精确 YSM 拒绝断言。"""
    path = root / YSM_CONTRACT_SUITE
    if not path.is_file():
        return []
    lines = read_utf8(path, YSM_CONTRACT_SUITE, errors).splitlines()
    marker = re.compile(r"^// rejection_spec: (E\d{4}) (spec/ir/ysm\.md#Y-[1-8])$")
    producer = re.compile(r"^let (\w+): ysm::Ysm(?:Load)?Result = (ysm::read_module_for|ysm_write::write_module)\(.*\)\?;$")
    fixtures = []
    for i, line in enumerate(lines):
        if not line.strip().startswith("// rejection_spec:"):
            continue
        match = marker.fullmatch(line.strip())
        assertion = lines[i + 1].strip() if i + 1 < len(lines) else ""
        if match is not None and match[1] in registered:
            code, ref = match.groups()
            raw = code[1:]
            helper = re.fullmatch(rf"(expect_reject(?:_signed)?)\(.*, {raw}\)\?;", assertion)
            scan = re.fullmatch(rf"assert\(ysm_validate::validate_inst_stream\(.*\)\? == {raw}\);", assertion)
            call = producer.fullmatch(lines[i - 1].strip()) if i > 0 else None
            test = helper[1] if helper else ""
            if scan:
                test = "ysm_validate::validate_inst_stream"
            if call and assertion == f"assert(!{call[1]}.accepted && {call[1]}.code.raw == {raw});":
                test = call[2]
            if test:
                refs = parse_spec_value(ref, YSM_CONTRACT_SUITE, i + 1, errors)
                fixtures.append(ToolFixture(f"{YSM_CONTRACT_SUITE}:{i + 1}", code, refs, True, test))
                continue
        errors.append(make_error("invalid_ysm_contract", YSM_CONTRACT_SUITE,
                                 "YSM 契约需要真实读写或扫描入口与精确错误码", i + 1))
    return fixtures


def build_report(root: Path) -> dict:
    """构建完整审计报告；不抛异常，所有问题都进入 errors。"""
    root = root.resolve()
    spec_dir = root / SPEC_REL
    bad_dir = root / BAD_REL
    errors: list[dict] = []
    docs = load_spec_docs(spec_dir, errors)
    entries, mapping = load_error_def(spec_dir, docs, errors)
    registered_codes = set(entries)
    missing_specs = index_missing_specs(spec_dir, docs, errors)

    for doc in docs.values():
        for row in doc.rows:
            registered = mapping.get((doc.path, row.anchor), [])
            explicit = E_CODE_RE.findall(row.content)
            if registered:
                row.mapping = "registered"
                row.codes = tuple(sorted(set(registered), key=lambda code: (code[:3], int(code[3:]))))
            elif explicit and all(code in registered_codes for code in explicit):
                row.mapping = "alias"
                row.codes = tuple(sorted(set(explicit), key=lambda code: (code[:3], int(code[3:]))))
            else:
                row.mapping = "unmapped"
                row.codes = ()
            if doc.rejection_class == "门禁断言":
                row.route = "gate"
            elif row.mapping == "unmapped":
                row.route = "full_debt"
            else:
                row.route = "fixture"

    roots, fixtures = load_fixtures(bad_dir, errors)
    validate_fixtures(fixtures, roots, registered_codes, errors)
    host_fixtures = load_host_coverage(root, registered_codes, errors)
    runtime_fixtures = load_foreign_trap_coverage(root, registered_codes, errors)
    runtime_fixtures.extend(load_sysv_syscall_coverage(root, registered_codes, errors))
    interface_fixtures = load_interface_coverage(root, registered_codes, errors)
    tool_fixtures = load_tool_coverage(root, registered_codes, errors)
    for contract in SYMBOL_CONTRACTS:
        tool_fixtures.extend(load_symbol_contract_coverage(root, registered_codes, errors, contract))
    tool_fixtures.extend(load_link_contract_coverage(root, registered_codes, errors))
    tool_fixtures.extend(load_elf_contract_coverage(root, registered_codes, errors))
    tool_fixtures.extend(load_mir_verify_coverage(root, registered_codes, errors))
    tool_fixtures.extend(load_literal_lex_coverage(root, registered_codes, errors))
    for suite in (DESUGAR_SUITE, INITIALIZER_SUITE, CLOSED_RANGES_SUITE, RESERVED_IF_LET_SUITE, MONOMORPH_SUITE):
        tool_fixtures.extend(load_desugar_coverage(root, registered_codes, errors, suite))
    for suite, error, anchors in TYPED_SOURCE_CONTRACTS:
        tool_fixtures.extend(load_typed_source_coverage(root, registered_codes, errors, suite, error, anchors))
    tool_fixtures.extend(load_ysm_contract_coverage(root, registered_codes, errors))
    assign_coverage([*roots, *host_fixtures, *runtime_fixtures, *interface_fixtures, *tool_fixtures], docs, errors)

    all_rows = [row for doc in docs.values() for row in doc.rows]
    fixture_rows = [row for row in all_rows if row.route == "fixture"]
    covered_rows = [row for row in fixture_rows if row.covered_by]
    missing_rows = [row for row in fixture_rows if not row.covered_by]
    gate_rows = [row for row in all_rows if row.route == "gate"]
    debt_rows = [row for row in all_rows if row.route == "full_debt"]

    groups: list[dict] = []
    for doc in sorted(docs.values(), key=lambda item: item.path):
        if not doc.rows:
            continue
        doc_fixture = [row for row in doc.rows if row.route == "fixture"]
        doc_covered = [row for row in doc_fixture if row.covered_by]
        doc_missing = [row for row in doc_fixture if not row.covered_by]
        doc_gate = [row for row in doc.rows if row.route == "gate"]
        doc_debt = [row for row in doc.rows if row.route == "full_debt"]
        groups.append(
            {
                "spec": doc.path,
                "status": doc.status,
                "rejection_class": doc.rejection_class,
                "rows": len(doc.rows),
                "fixture_required": len(doc_fixture),
                "covered": len(doc_covered),
                "missing": len(doc_missing),
                "gate": len(doc_gate),
                "debt": len(doc_debt),
                "covered_anchors": [row.anchor for row in doc_covered],
                "missing_anchors": [row.anchor for row in doc_missing],
                "gate_anchors": [row.anchor for row in doc_gate],
                "debt_anchors": [row.anchor for row in doc_debt],
            }
        )

    dependency_refs: dict[str, list[str]] = {}
    referenced_dependencies: set[tuple[str, str]] = set()
    for fixture in roots:
        for name in fixture.dependencies:
            target = next(
                (
                    item
                    for item in fixtures
                    if item.directory == fixture.directory and item.name == name and not item.is_root
                ),
                None,
            )
            if target is not None:
                referenced_dependencies.add((target.directory, target.name))
                dependency_refs.setdefault(target.path, []).append(fixture.path)

    fixture_roots = []
    for fixture in sorted(roots, key=lambda item: item.path):
        fixture_roots.append(
            {
                "path": fixture.path,
                "expected_code": fixture.expected_code,
                "specs": [f"{ref.spec}#{ref.anchor}" for ref in fixture.refs],
                "covered": [
                    f"{row.spec}#{row.anchor}"
                    for row in fixture_rows
                    if fixture.path in row.covered_by
                ],
            }
        )
    dependencies = []
    for fixture in sorted(fixtures, key=lambda item: item.path):
        if fixture.is_root:
            continue
        dependencies.append(
            {
                "path": fixture.path,
                "referenced_by": sorted(dependency_refs.get(fixture.path, [])),
            }
        )

    errors.sort(
        key=lambda item: (
            item.get("path", ""),
            item.get("line", 0),
            item["code"],
            item.get("detail", ""),
        )
    )
    failures = []
    if errors:
        failures.append({"category": "integrity_errors", "count": len(errors)})
    if missing_rows:
        failures.append({"category": "fixture_gaps", "count": len(missing_rows)})
    if debt_rows:
        failures.append({"category": "full_debt_rows", "count": len(debt_rows)})
    if missing_specs:
        failures.append({"category": "missing_specs", "count": len(missing_specs)})

    rows_registered = sum(1 for row in all_rows if row.mapping == "registered")
    rows_alias = sum(1 for row in all_rows if row.mapping == "alias")
    rows_unmapped = sum(1 for row in all_rows if row.mapping == "unmapped")
    snapshot = {
        "spec_documents": len(docs),
        "documents_with_rejection_tables": len(groups),
        "rejection_rows": len(all_rows),
        "rows_registered": rows_registered,
        "rows_explicit_alias": rows_alias,
        "rows_unmapped": rows_unmapped,
        "gate_assertion_rows": sum(
            1 for row in gate_rows if row.mapping == "unmapped"
        ),
        "gate_rows_total": len(gate_rows),
        "full_debt_rows": len(debt_rows),
        "missing_specs": len(missing_specs),
        "fixture_roots": len(roots),
        "fixture_dependencies": len(fixtures) - len(roots),
        "host_fixture_groups": len(host_fixtures),
        "runtime_fixture_groups": len(runtime_fixtures),
        "interface_fixture_groups": len(interface_fixtures),
        "tool_fixture_groups": len(tool_fixtures),
    }
    totals = {
        "fixture_required": len(fixture_rows),
        "covered": len(covered_rows),
        "missing": len(missing_rows),
        "gate_assertions": snapshot["gate_assertion_rows"],
        "gate_rows": len(gate_rows),
        "full_debt_rows": len(debt_rows),
        "missing_specs": len(missing_specs),
        "integrity_errors": len(errors),
    }
    return {
        "tool": "rejection_corpus",
        "schema": 1,
        "scope": "常驻源码、Seed 宿主、运行期、接口及工具夹具覆盖；门禁断言不计入夹具完成性",
        "snapshot": snapshot,
        "totals": totals,
        "errors": errors,
        "groups": groups,
        "gate_assertions": [
            {
                "spec": row.spec,
                "anchor": row.anchor,
                "mapping": row.mapping,
                "codes": list(row.codes),
            }
            for row in sorted(gate_rows, key=lambda item: (item.spec, anchor_key(item.anchor)))
        ],
        "full_debt": {
            "rows": [
                {"spec": row.spec, "anchor": row.anchor}
                for row in sorted(debt_rows, key=lambda item: (item.spec, anchor_key(item.anchor)))
            ],
            "missing_specs": missing_specs,
        },
        "fixtures": {
            "roots": fixture_roots,
            "dependencies": dependencies,
            "host": [
                {"path": item.path, "expected_code": item.expected_code,
                 "specs": [f"{ref.spec}#{ref.anchor}" for ref in item.refs],
                 "cases": len(item.diagnostics)}
                for item in host_fixtures
            ],
            "runtime": [
                {"path": item.path, "spec_code": item.expected_code,
                 "specs": [f"{ref.spec}#{ref.anchor}" for ref in item.refs],
                 "services": item.cases}
                for item in runtime_fixtures
            ],
            "interfaces": [
                {"path": item.path, "expected_code": item.expected_code,
                 "specs": [f"{ref.spec}#{ref.anchor}" for ref in item.refs], "cases": item.cases}
                for item in interface_fixtures
            ],
            "tools": [
                {"path": item.path, "expected_code": item.expected_code,
                 "specs": [f"{ref.spec}#{ref.anchor}" for ref in item.refs], "test": item.test}
                for item in tool_fixtures
            ],
        },
        "complete": not failures,
        "check": {"ok": not failures, "failures": failures},
    }


def render_text(report: dict) -> str:
    """把报告渲染为按规格分组的可读文本。"""
    snapshot = report["snapshot"]
    totals = report["totals"]
    lines: list[str] = []
    lines.append("拒绝形态常驻语料覆盖审计")
    lines.append(
        "快照：{} 份规格文档，{} 份含拒绝形态表，共 {} 条；"
        "已登记 {}，显式别名 {}，待映射 {}".format(
            snapshot["spec_documents"],
            snapshot["documents_with_rejection_tables"],
            snapshot["rejection_rows"],
            snapshot["rows_registered"],
            snapshot["rows_explicit_alias"],
            snapshot["rows_unmapped"],
        )
    )
    lines.append(
        "分类：需夹具 {} 条，门禁断言 {} 条（其中待码位 {} 条），"
        "full/未实现欠账 {} 条".format(
            totals["fixture_required"],
            totals["gate_rows"],
            totals["gate_assertions"],
            totals["full_debt_rows"],
        )
    )
    lines.append(
        "覆盖：{}/{}，缺失 {}；源码根 {}，源码依赖 {}，宿主组 {}，运行期组 {}，接口组 {}，工具组 {}；完整性错误 {}".format(
            totals["covered"],
            totals["fixture_required"],
            totals["missing"],
            snapshot["fixture_roots"],
            snapshot["fixture_dependencies"],
            snapshot["host_fixture_groups"],
            snapshot["runtime_fixture_groups"],
            snapshot["interface_fixture_groups"],
            snapshot["tool_fixture_groups"],
            totals["integrity_errors"],
        )
    )
    lines.append("")
    lines.append("按规格分组：")
    for group in report["groups"]:
        head = "{}（{}".format(group["spec"], group["status"] or "状态未登记")
        if group["rejection_class"]:
            head += "，{}".format(group["rejection_class"])
        head += "）：拒绝形态 {} 条；需夹具 {}，覆盖 {}，缺失 {}".format(
            group["rows"], group["fixture_required"], group["covered"], group["missing"]
        )
        if group["gate"]:
            head += "；门禁断言 {} 条".format(group["gate"])
        if group["debt"]:
            head += "；full 待映射 {} 条".format(group["debt"])
        lines.append(head)
        if group["covered_anchors"]:
            lines.append("  已覆盖：" + ", ".join(group["covered_anchors"]))
        if group["missing_anchors"]:
            lines.append("  缺失：" + ", ".join(group["missing_anchors"]))
        if group["gate_anchors"]:
            lines.append("  门禁断言（不计入夹具缺口）：" + ", ".join(group["gate_anchors"]))
        if group["debt_anchors"]:
            lines.append("  full 待映射（欠账）：" + ", ".join(group["debt_anchors"]))

    lines.append("")
    lines.append(
        "门禁断言：共 {} 条，其中待码位 {} 条；不能仅靠 test/bad 覆盖，"
        "本工具不判定其完成。".format(totals["gate_rows"], totals["gate_assertions"])
    )
    for item in report["gate_assertions"]:
        lines.append("  {}#{}（{}）".format(item["spec"], item["anchor"], item["mapping"]))
    lines.append("")
    lines.append(
        "full/未实现欠账：待映射拒绝形态 {} 条；缺失规格 {} 份。".format(
            totals["full_debt_rows"], totals["missing_specs"]
        )
    )
    for item in report["full_debt"]["rows"]:
        lines.append("  {}#{}".format(item["spec"], item["anchor"]))
    for item in report["full_debt"]["missing_specs"]:
        lines.append("  {}（{}）".format(item["spec"], item["layer"] or "层级未知"))

    if report["errors"]:
        lines.append("")
        lines.append("完整性错误：")
        for item in report["errors"]:
            location = item["path"] or "."
            if "line" in item:
                location += ":{}".format(item["line"])
            lines.append("  [{}] {} {}".format(item["code"], location, item["detail"]))

    lines.append("")
    if report["complete"]:
        lines.append("结论：夹具覆盖完整（门禁断言与 full 层欠账按上方单列口径处理）。")
    else:
        parts = []
        for failure in report["check"]["failures"]:
            parts.append("{}={}".format(failure["category"], failure["count"]))
        lines.append("结论：未完成（" + "，".join(parts) + "）。")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    """命令行入口：默认输出文本报告，--check 对任何未完成项返回 1。"""
    parser = argparse.ArgumentParser(description="拒绝形态语料覆盖审计")
    parser.add_argument("--root", type=Path, default=ROOT, help="仓库根目录")
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    parser.add_argument("--check", action="store_true", help="未完成时返回非零退出码")
    args = parser.parse_args(argv)
    if not args.root.is_dir():
        print("根目录不存在：{}".format(args.root), file=sys.stderr)
        return 2
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass
    report = build_report(args.root)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(render_text(report))
    if args.check and not report["complete"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
