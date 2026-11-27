"""从 spec/proc/error.def 确定性生成 min 诊断模块的静态错误码表。"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys

# 固定版本的嵌入式 Python 也能加载同目录的产物校验。
sys.path.insert(0, str(Path(__file__).resolve().parent))
from pe_digest import check_artifact_digest

# 仓库根由脚本位置推出，生成结果不受当前工作目录影响。
ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "spec"
SOURCE = SPEC / "proc/error.def"
OUTPUT = ROOT / "compiler/min/src/diag/error_codes.yak"

# 配置源只允许四类声明指令；其余一律按未知指令拒绝（拒绝形态 ER-5：不得含执行代码）。
DIRECTIVES = {"format", "segment", "reserve", "entry"}
FORMAT_VERSION = "2"

SEGMENT_RE = re.compile(r'segment (E\d{1,2})\s+name "([^"]+)"(?:\s+parent (E\d))?')
RESERVE_RE = re.compile(r"reserve (E\d{2}) from (\d{2}) to (\d{2})")
# 描述允许空串进入解析，由 parse_entry 给出专门的"描述不得为空"报错，避免与格式错误混淆。
ENTRY_RE = re.compile(r'entry (E\d{2})\s+code (\d{2})\s+ref (\S+)\s+desc "([^"]*)"')
CODE_FIELD_RE = re.compile(r"code(?!\S)")

# 引用种类（DiagRef.kind）唯一合法取值，登记于 src/diag/diag.yak 的 DiagRef 注释。
# NameId / ScopeId 不属于该域，因此任何 >=6 的取值都必须被拒绝（拒绝形态 ER-1：不得混域）。
REF_KIND_LABELS = ("DefId", "BuiltinId", "ImportRef", "FieldId", "VariantId", "LocalId")

# 未登记码位的查表结果；以 u32 最大值表示"没有这一条"。
NO_ENTRY = "4294967295u32"
# 静态字节区分块的最大字节数，避免单行字面量过长。
TEXT_CHUNK = 2048
# 并行表分块大小：base 子集的数组字面量上限为 64 项（seed/src/parse.c:386）。
TABLE_CHUNK = 60
# 摘要与界标属于同一静态字节区，运行时查询与产物检查不各持一份。
ARTIFACT_DIGEST_PREFIX = b"YAK-ERROR-DEF-SHA256-V1:"
ARTIFACT_DIGEST_SUFFIX = b":END-YAK-ERROR-DEF"
ARTIFACT_DIGEST_SIZE = 64


class ConfigError(Exception):
    """配置源或生成前置条件不满足。"""


def check(condition, message):
    """断言辅助：失败即抛出带中文说明的配置错误。"""
    if not condition:
        raise ConfigError(message)


def resolve_ref(origin, ref):
    """按"规格文件:锚点"定位引用目标。

    先在配置源同目录解析，再对 error.def 回退到 spec/lang（与规格审计同语义）；
    路径全部由仓库根推出，不读当前工作目录。
    """
    path = ref.split(":", 1)[0].split("#", 1)[0]
    direct = origin.parent / path
    if direct.is_file():
        return direct.resolve()
    if origin.name == "error.def" and (SPEC / "lang" / path).is_file():
        return (SPEC / "lang" / path).resolve()
    return None


def normalize(raw):
    """把配置源字节规范成 LF 文本。

    工作副本在 Windows 检出下可能带 CRLF，而仓库按 eol=lf 存储；解析与摘要都基于
    规范化文本，保证同一份提交在不同检出处生成同一张静态表（拒绝形态 ER-2）。
    """
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ConfigError("error.def 不得带 BOM")
    text_bytes = raw.replace(b"\r\n", b"\n")
    try:
        text = text_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ConfigError(f"error.def 不是合法 UTF-8：{error}") from error
    check("\r" not in text, "error.def 含孤立 CR，换行必须为 LF")
    return text


def parse(text, origin):
    """严格解析配置源文本，返回段、子领域、预留与条目。"""
    segments = {}
    sub_segments = []
    reserved = {}
    entries = []
    seen_codes = {}
    format_count = 0
    saw_declaration = False

    for number, line in enumerate(text.split("\n"), 1):
        if not line.strip():
            continue
        # 注释在缩进检查之前放行，与规格审计保持同一顺序。
        if line.lstrip().startswith("#"):
            continue
        check(not line[0].isspace(), f"error.def:{number}: 缩进行不是合法指令：{line}")
        keyword = line.split(None, 1)[0]
        check(keyword in DIRECTIVES, f"error.def:{number}: 未知指令：{line}")
        if keyword == "format":
            format_count += 1
            check(format_count == 1, f"error.def:{number}: format 指令重复")
            check(not saw_declaration, f"error.def:{number}: format 必须位于首个声明之前")
            matched = re.fullmatch(r"format (\S+)", line)
            check(matched is not None and matched[1] == FORMAT_VERSION,
                  f"error.def:{number}: 不支持的 format 指令：{line}")
            continue

        saw_declaration = True
        check(line.startswith(keyword + " "), f"error.def:{number}: 指令格式错误：{line}")
        if keyword == "segment":
            parse_segment(line, number, segments, sub_segments)
        elif keyword == "reserve":
            parse_reserve(line, number, segments, reserved)
        else:
            parse_entry(line, number, origin, segments, reserved, entries, seen_codes)

    check(format_count == 1, "error.def 缺少 format 指令")
    return segments, sub_segments, reserved, entries


def parse_segment(line, number, segments, sub_segments):
    """登记一个大段或子领域声明。"""
    matched = SEGMENT_RE.fullmatch(line)
    check(matched is not None, f"error.def:{number}: 段声明格式错误：{line}")
    name, parent = matched[1], matched[3]
    check(name not in segments, f"error.def:{number}: 段重复声明：{name}")
    if parent is None:
        check(len(name) == 2, f"error.def:{number}: 大段名必须是 E0-E9：{name}")
        segments[name] = parent
        return
    check(len(name) == 3, f"error.def:{number}: 子领域名必须是 E<千位><百位>：{name}")
    check(parent in segments, f"error.def:{number}: 父段未声明：{parent}")
    check(len(parent) == 2, f"error.def:{number}: 父段必须是大段：{parent}")
    # 跨段一致性：子领域的千位必须等于父段号，禁止把条目挂到别的大段下。
    check(name[1] == parent[1], f"error.def:{number}: 子领域 {name} 与父段 {parent} 的大段不一致")
    segments[name] = parent
    sub_segments.append(name)


def parse_reserve(line, number, segments, reserved):
    """登记一段预留码位，逐槽检查重叠。"""
    matched = RESERVE_RE.fullmatch(line)
    check(matched is not None, f"error.def:{number}: 预留声明格式错误：{line}")
    name, low, high = matched[1], int(matched[2]), int(matched[3])
    check(name in segments and len(name) == 3, f"error.def:{number}: 未声明的子领域：{name}")
    check(1 <= low <= high <= 99, f"error.def:{number}: 预留范围必须是 01-99：{line}")
    slots = reserved.setdefault(name, {})
    for slot in range(low, high + 1):
        check(slot not in slots, f"error.def:{number}: 预留区间重叠：{name}{slot:02d}")
        slots[slot] = number


def parse_entry(line, number, origin, segments, reserved, entries, seen_codes):
    """登记一条错误码条目，并强制显式码位。"""
    matched = ENTRY_RE.fullmatch(line)
    if matched is None:
        if not CODE_FIELD_RE.search(line):
            raise ConfigError(f"error.def:{number}: entry 缺少显式 code（隐式码位分配）：{line}")
        raise ConfigError(f"error.def:{number}: entry 格式错误：{line}")
    name, seq_text, ref, desc = matched[1], matched[2], matched[3], matched[4]
    check(name in segments and len(name) == 3, f"error.def:{number}: 未声明的子领域：{name}")
    seq = int(seq_text)
    check(1 <= seq <= 99, f"error.def:{number}: 序号必须是 01-99：{line}")
    parent = segments[name]
    code = int(parent[1]) * 1000 + int(name[2]) * 100 + seq
    check(code not in seen_codes, f"error.def:{number}: 码位重复登记（跨段复用）：E{code:04d}")
    check(seq not in reserved.get(name, {}), f"error.def:{number}: 码位落在预留区间：E{code:04d}")
    check(bool(desc.strip()), f"error.def:{number}: 描述不得为空：E{code:04d}")
    check(":" in ref, f"error.def:{number}: 引用缺少规则锚点：{ref}")
    target = resolve_ref(origin, ref)
    check(target is not None, f"error.def:{number}: 引用文件不存在：{ref}")
    anchor = ref.split(":", 1)[1]
    # 精确词边界，避免 L-1 命中 L-10。
    pattern = r"(?<![\w.-])" + re.escape(anchor) + r"(?![\w.-])"
    check(re.search(pattern, target.read_text(encoding="utf-8")) is not None,
          f"error.def:{number}: 引用的规则不存在：{ref}")
    seen_codes[code] = number
    entries.append({"code": code, "segment": name, "sub": int(name[2]), "seq": seq,
                    "ref": ref.encode("utf-8"), "desc": desc.encode("utf-8"),
                    "line": number})


def validate_append_only(entries, reserved, sub_segments):
    """校验码位只追加：序号连续前缀，预留紧接其后覆盖到 99。"""
    check([entry["code"] for entry in entries] == sorted(entry["code"] for entry in entries),
          "条目必须按码位升序书写")
    by_sub = {}
    for entry in entries:
        by_sub.setdefault(entry["segment"], []).append(entry["seq"])
    for name in sub_segments:
        used = sorted(by_sub.get(name, []))
        check(used == list(range(1, len(used) + 1)),
              f"子领域 {name} 的序号必须是 01..n 连续前缀（只允许追加）")
        check(sorted(reserved.get(name, {})) == list(range(len(used) + 1, 100)),
              f"子领域 {name} 的预留必须紧接已登记序号并覆盖到 99")


def previous_codes(path):
    """从既有生成文件读回已登记码位，用于发现删除与复用。

    并行表按块生成，故按块名顺序收集；块内顺序即登记顺序。
    """
    text = path.read_text(encoding="utf-8")
    blocks = re.findall(r"^const CODES_(\d+): \[u16; \d+\] = \[(.*)\];$", text, re.M)
    if not blocks:
        return None
    blocks.sort(key=lambda item: int(item[0]))
    codes = []
    for _, body in blocks:
        codes.extend(int(value) for value in re.findall(r"(\d+)u16", body))
    return codes


def check_history(path, entries, history_path=None):
    """同时核对既有生成物与独立历史基线，防止删码位或重建输出绕过 ER-3。"""
    present = {entry["code"] for entry in entries}
    if path.is_file():
        old = previous_codes(path)
        check(old is not None, f"{path} 不是本生成器的产出（缺少 CODES 声明）")
        missing = [code for code in old if code not in present]
        check(not missing, "已登记码位缺失（只允许追加）：" + ", ".join(f"E{code:04d}" for code in missing[:8]))
    if history_path is None:
        history_path = path.parent / "error_history.json"
    if history_path == Path("<none>"):
        return
    check(history_path.is_file(), f"缺少 ER-3 历史基线：{history_path}")
    try:
        record = json.loads(history_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ConfigError(f"ER-3 历史基线不可读：{history_path}：{error}") from error
    check(isinstance(record, dict) and type(record.get("format")) is int and
          record["format"] == 2 and
          set(record) == {"format", "description", "baseline_source_sha256", "entries"} and
          isinstance(record["description"], str) and
          isinstance(record["baseline_source_sha256"], str) and
          re.fullmatch(r"[a-f0-9]{64}", record["baseline_source_sha256"]) is not None,
          f"ER-3 历史基线格式无效：{history_path}")
    old = record["entries"]
    check(isinstance(old, list) and old and
          all(isinstance(row, list) and len(row) == 2 and
              type(row[0]) is int and 1 <= row[0] <= 9999 and
              isinstance(row[1], str) and re.fullmatch(r"[^:\s]+:[^:\s]+", row[1]) is not None
              for row in old), f"ER-3 历史基线条目无效：{history_path}")
    codes = [code for code, _ in old]
    check(codes == sorted(set(codes)), f"ER-3 历史基线码位必须升序且唯一：{history_path}")
    missing = [code for code in codes if code not in present]
    check(not missing, "历史基线码位缺失（只允许追加）：" +
          ", ".join(f"E{code:04d}" for code in missing[:8]))
    refs = {entry["code"]: entry["ref"].decode("utf-8") for entry in entries}
    rebound = [f"E{code:04d}：{ref} → {refs[code]}" for code, ref in old if refs[code] != ref]
    check(not rebound, "历史基线码位复用（不得换绑规格引用）：" + "；".join(rebound[:8]))
    unrecorded = sorted(present - set(codes))
    check(not unrecorded, "新码位尚未登记到 ER-3 历史基线：" +
          ", ".join(f"E{code:04d}" for code in unrecorded[:8]))


def split_utf8(blob, size):
    """把字节区切成若干块，块边界必须落在 UTF-8 字符起点。"""
    chunks = []
    start = 0
    while start < len(blob):
        end = min(start + size, len(blob))
        while end < len(blob) and (blob[end] & 0xC0) == 0x80:
            end -= 1
        chunks.append(blob[start:end])
        start = end
    return chunks


def yak_literal(raw):
    """把字节区转成 Yak 字符串字面量，转义不改变解码后的字节内容。"""
    pieces = []
    for char in raw.decode("utf-8"):
        if char == '"':
            pieces.append('\\"')
        elif char == "\\":
            pieces.append("\\\\")
        elif char == "\n":
            pieces.append("\\n")
        elif char == "\r":
            pieces.append("\\r")
        elif char == "\t":
            pieces.append("\\t")
        elif ord(char) < 0x20:
            pieces.append("\\u{%X}" % ord(char))
        else:
            pieces.append(char)
    return '"' + "".join(pieces) + '"'


def array_decl(name, element, values, suffix):
    """生成单行定长数组常量声明。"""
    body = ", ".join(f"{value}{suffix}" for value in values)
    return f"const {name}: [{element}; {len(values)}] = [{body}];"


def chunked_table(name, element, values, suffix):
    """把并行表切成若干定长数组，每块不超过字面量规模上限。"""
    lines = []
    for index in range(0, len(values), TABLE_CHUNK):
        piece = values[index:index + TABLE_CHUNK]
        lines.append(array_decl(f"{name}_{index // TABLE_CHUNK}", element, piece, suffix))
    return lines


def chunked_accessor(name, element, zero, count):
    """生成按块派发的取值函数，越界返回零值。"""
    lines = [f"function {name.lower()}_at(index: u32): {element} {{"]
    for chunk in range(0, count, TABLE_CHUNK):
        end = min(chunk + TABLE_CHUNK, count)
        tail = "" if chunk == 0 else f" - {chunk}u32"
        lines.append(f"    if index < {end}u32 {{ return {name}_{chunk // TABLE_CHUNK}[index{tail}]; }}")
    lines.append(f"    return {zero};")
    lines.append("}")
    return lines


def render(digest, segments, sub_segments, entries):
    """渲染生成文件正文。"""
    # 引用与描述共用一段静态字节区，先放全部 ref，再放全部 desc。
    ref_off, desc_off = [], []
    blob = bytearray()
    for entry in entries:
        ref_off.append(len(blob))
        blob += entry["ref"]
    for entry in entries:
        desc_off.append(len(blob))
        blob += entry["desc"]
    chunks = split_utf8(bytes(blob), TEXT_CHUNK)
    cumulative = []
    total = 0
    for chunk in chunks:
        total += len(chunk)
        cumulative.append(total)
    kind_offsets, kind_names, offset = [], [], 0
    for label in REF_KIND_LABELS:
        kind_offsets.append(offset)
        kind_names.append(label)
        offset += len(label)

    lines = [
        "// 由 tools/error_codes.py 生成；请勿手改。",
        "// 源摘要：" + digest,
        "// 源文件：spec/proc/error.def（" + str(len(entries)) + " 条登记码位，"
        + str(len(sub_segments)) + " 个子领域）；摘要对 LF 规范化后的字节取 SHA-256。",
        "//",
        "// 静态表形态：base 子集不允许结构体常量，因此条目字段拆成并行定长数组，",
        "// 引用与描述统一存进分块静态字节区，由 text_byte 按全局偏移取字节。",
        "",
        "// 单条登记码位的只读视图。",
        "export struct ErrorEntry {",
        "    code: u16,",
        "    segment: u8,       // 大段（千位，0-9）",
        "    sub: u8,           // 子领域（百位，0-9）",
        "    seq: u8,           // 序号（01-99）",
        "    ref_off: u32,      // 引用在静态字节区中的偏移",
        "    ref_len: u16,      // 引用字节数",
        "    desc_off: u32,     // 描述在静态字节区中的偏移",
        "    desc_len: u16,     // 描述字节数",
        "}",
        "",
        "// 未登记码位在查表接口中的返回值。",
        f"const NO_ENTRY: u32 = {NO_ENTRY};",
        "",
        f"// 登记码位总数（{len(entries)}）。",
        f"const ENTRY_COUNT: u32 = {len(entries)}u32;",
        "",
    ]
    # 并行表按块生成；数组字面量元素上限为 64，故每块不超过 60 项。
    lines.extend(chunked_table("CODES", "u16", [entry["code"] for entry in entries], "u16"))
    lines.extend(chunked_table("SEGMENTS", "u8", [int(entry["segment"][1]) for entry in entries], "u8"))
    lines.extend(chunked_table("SUBS", "u8", [entry["sub"] for entry in entries], "u8"))
    lines.extend(chunked_table("SEQS", "u8", [entry["seq"] for entry in entries], "u8"))
    lines.extend(chunked_table("REF_OFFS", "u32", ref_off, "u32"))
    lines.extend(chunked_table("REF_LENS", "u16", [len(entry["ref"]) for entry in entries], "u16"))
    lines.extend(chunked_table("DESC_OFFS", "u32", desc_off, "u32"))
    lines.extend(chunked_table("DESC_LENS", "u16", [len(entry["desc"]) for entry in entries], "u16"))
    for index, chunk in enumerate(chunks):
        lines.append(f"const TEXT{index}: &[u8] = {yak_literal(chunk)};")
    lines.extend([
        array_decl("KIND_OFFS", "u32", kind_offsets, "u32"),
        array_decl("KIND_LENS", "u8", [len(label) for label in kind_names], "u8"),
        f"const KIND_NAMES: &[u8] = {yak_literal(''.join(kind_names).encode())};",
        f"const SOURCE_SHA256_START: u32 = {len(ARTIFACT_DIGEST_PREFIX)}u32;",
        f"const SOURCE_SHA256: &[u8] = {yak_literal(ARTIFACT_DIGEST_PREFIX + digest.encode() + ARTIFACT_DIGEST_SUFFIX)};",
        "",
        "// ── 并行表按块派发 ──",
        "",
    ])
    lines.extend(chunked_accessor("CODES", "u16", "0u16", len(entries)))
    lines.extend(chunked_accessor("SEGMENTS", "u8", "0u8", len(entries)))
    lines.extend(chunked_accessor("SUBS", "u8", "0u8", len(entries)))
    lines.extend(chunked_accessor("SEQS", "u8", "0u8", len(entries)))
    lines.extend(chunked_accessor("REF_OFFS", "u32", "0u32", len(entries)))
    lines.extend(chunked_accessor("REF_LENS", "u16", "0u16", len(entries)))
    lines.extend(chunked_accessor("DESC_OFFS", "u32", "0u32", len(entries)))
    lines.extend(chunked_accessor("DESC_LENS", "u16", "0u16", len(entries)))
    lines.extend([
        "",
        "// ── 静态字节区取字节 ──",
        "",
        "// 按全局偏移读静态字节区；越界返回 0，长度判定由各接口负责。",
        "function text_byte(off: u32): u8 {",
    ])
    for index, end in enumerate(cumulative):
        base = 0 if index == 0 else cumulative[index - 1]
        tail = "" if index == 0 else f" - {base}u32"
        lines.append(f"    if off < {end}u32 {{ return TEXT{index}[off{tail}]; }}")
    lines.extend([
        "    return 0u8;",
        "}",
        "",
        "// ── 码位查询 ──",
        "",
        "export function error_count(): u32 { return ENTRY_COUNT; }",
        "",
        "// 线性查表；条目数量固定为一个错误码文件的规模，结果与顺序都确定。",
        "export function error_index(code: u16): u32 {",
        "    var i: u32 = 0u32;",
        "    while i < ENTRY_COUNT {",
        "        if codes_at(i) == code { return i; }",
        "        i = i + 1u32;",
        "    }",
        "    return NO_ENTRY;",
        "}",
        "",
        "// 码位是否已在 error.def 登记；组件发出未登记码位即构建失败。",
        "export function error_exists(code: u16): bool { return error_index(code) != NO_ENTRY; }",
        "",
        "// 越界索引返回全零条目，调用方须先用 error_exists 区分。",
        "export function error_entry_at(index: u32): ErrorEntry {",
        "    if index >= ENTRY_COUNT {",
        "        return ErrorEntry { code: 0u16, segment: 0u8, sub: 0u8, seq: 0u8, ref_off: 0u32, ref_len: 0u16, desc_off: 0u32, desc_len: 0u16 };",
        "    }",
        "    return ErrorEntry { code: codes_at(index), segment: segments_at(index), sub: subs_at(index), seq: seqs_at(index), ref_off: ref_offs_at(index), ref_len: ref_lens_at(index), desc_off: desc_offs_at(index), desc_len: desc_lens_at(index) };",
        "}",
        "",
        "export function error_entry(code: u16): ErrorEntry { return error_entry_at(error_index(code)); }",
        "",
        "// ── 引用与描述字节 ──",
        "",
        "export function error_ref_len(index: u32): u16 {",
        "    if index >= ENTRY_COUNT { return 0u16; }",
        "    return ref_lens_at(index);",
        "}",
        "",
        "export function error_ref_at(index: u32, at: u32): u8 {",
        "    if index >= ENTRY_COUNT { return 0u8; }",
        "    if at >= (ref_lens_at(index) as u32) { return 0u8; }",
        "    return text_byte(ref_offs_at(index) + at);",
        "}",
        "",
        "export function error_ref_eq(index: u32, expected: &[u8]): bool {",
        "    if index >= ENTRY_COUNT { return false; }",
        "    if (ref_lens_at(index) as u32) != (@len(expected) as u32) { return false; }",
        "    var i: u32 = 0u32;",
        "    while i < (@len(expected) as u32) {",
        "        if error_ref_at(index, i) != expected[i] { return false; }",
        "        i = i + 1u32;",
        "    }",
        "    return true;",
        "}",
        "",
        "export function error_desc_len(index: u32): u16 {",
        "    if index >= ENTRY_COUNT { return 0u16; }",
        "    return desc_lens_at(index);",
        "}",
        "",
        "export function error_desc_at(index: u32, at: u32): u8 {",
        "    if index >= ENTRY_COUNT { return 0u8; }",
        "    if at >= (desc_lens_at(index) as u32) { return 0u8; }",
        "    return text_byte(desc_offs_at(index) + at);",
        "}",
        "",
        "export function error_desc_eq(index: u32, expected: &[u8]): bool {",
        "    if index >= ENTRY_COUNT { return false; }",
        "    if (desc_lens_at(index) as u32) != (@len(expected) as u32) { return false; }",
        "    var i: u32 = 0u32;",
        "    while i < (@len(expected) as u32) {",
        "        if error_desc_at(index, i) != expected[i] { return false; }",
        "        i = i + 1u32;",
        "    }",
        "    return true;",
        "}",
        "",
        "// ── 生成源摘要（拒绝形态 ER-2：配置源、生成表与产物摘要必须一致）──",
        "",
        f"export function error_source_sha256_len(): u32 {{ return {ARTIFACT_DIGEST_SIZE}u32; }}",
        "",
        "export function error_source_sha256_at(at: u32): u8 {",
        "    if at >= error_source_sha256_len() { return 0u8; }",
        "    return SOURCE_SHA256[SOURCE_SHA256_START + at];",
        "}",
        "",
        "export function error_source_sha256_eq(expected: &[u8]): bool {",
        "    if (error_source_sha256_len() as u64) != @len(expected) { return false; }",
        "    var i: u32 = 0u32;",
        "    while i < error_source_sha256_len() {",
        "        if error_source_sha256_at(i) != expected[i] { return false; }",
        "        i = i + 1u32;",
        "    }",
        "    return true;",
        "}",
        "",
        "// ── 引用种类校验（独立于错误码域，拒绝形态 ER-1：不得混域）──",
        "",
        "// 合法种类数量：0=DefId，1=BuiltinId，2=ImportRef，3=FieldId，4=VariantId，5=LocalId。",
        "export function error_ref_kind_count(): u8 { return 6u8; }",
        "",
        "// NameId、ScopeId 等不在此域，任何 >=6 的取值一律拒绝。",
        "export function error_ref_kind_valid(kind: u8): bool { return kind < 6u8; }",
        "",
        "export function error_ref_kind_label_len(kind: u8): u8 {",
        "    if kind >= 6u8 { return 0u8; }",
        "    return KIND_LENS[kind as u32];",
        "}",
        "",
        "export function error_ref_kind_label_at(kind: u8, at: u32): u8 {",
        "    if kind >= 6u8 { return 0u8; }",
        "    if at >= (KIND_LENS[kind as u32] as u32) { return 0u8; }",
        "    return KIND_NAMES[KIND_OFFS[kind as u32] + at];",
        "}",
        "",
        "export function error_ref_kind_label_eq(kind: u8, expected: &[u8]): bool {",
        "    if kind >= 6u8 { return false; }",
        "    if (KIND_LENS[kind as u32] as u32) != (@len(expected) as u32) { return false; }",
        "    var i: u32 = 0u32;",
        "    while i < (@len(expected) as u32) {",
        "        if error_ref_kind_label_at(kind, i) != expected[i] { return false; }",
        "        i = i + 1u32;",
        "    }",
        "    return true;",
        "}",
        "",
    ])
    return "\n".join(lines)


def build_table(source, output, history, history_path):
    """读取并校验同一份配置源快照，返回生成正文和摘要。"""
    text = normalize(source.read_bytes())
    segments, sub_segments, reserved, entries = parse(text, source)
    validate_append_only(entries, reserved, sub_segments)
    if history:
        if history_path is None:
            history_path = source.parent / "error_history.json"
        check_history(output, entries, history_path)
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return render(digest, segments, sub_segments, entries), digest


def generate(source=SOURCE, output=OUTPUT, history=True, history_path=None):
    """只返回校验后的生成文件正文。"""
    return build_table(source, output, history, history_path)[0]


def check_pe_digest(artifact, expected):
    """核对编译产物中的错误码表摘要。"""
    try:
        check_artifact_digest(artifact, expected, ARTIFACT_DIGEST_PREFIX, ARTIFACT_DIGEST_SUFFIX, "错误码表")
    except ValueError as error:
        raise ConfigError(str(error)) from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只校验生成文件是否与配置源一致")
    parser.add_argument("--check-artifact", type=Path, metavar="ARTIFACT", help="校验生成表及 AMD64 PE / 静态 ELF 内嵌摘要")
    parser.add_argument("--output", type=Path, default=OUTPUT, help="生成文件写入位置")
    parser.add_argument("--source", type=Path, default=SOURCE, help="配置源位置（测试可用）")
    parser.add_argument("--history-file", type=Path, help="ER-3 独立历史基线（默认在配置源旁）")
    parser.add_argument("--no-history", action="store_true", help="仅用于隔离测试，跳过生成物与独立基线的历史核对")
    args = parser.parse_args()
    try:
        text, digest = build_table(args.source, args.output, not args.no_history, args.history_file)
    except (ConfigError, OSError) as error:
        raise SystemExit(f"错误码表生成失败：{error}")
    if args.check or args.check_artifact is not None:
        if not args.output.is_file() or args.output.read_bytes() != text.encode("utf-8"):
            raise SystemExit(f"错误码表陈旧：运行 python tools/error_codes.py --output {args.output}")
        if args.check_artifact is not None:
            try:
                check_pe_digest(args.check_artifact, digest)
            except (ConfigError, OSError) as error:
                raise SystemExit(f"错误码表产物校验失败：{error}")
            print(f"错误码表产物摘要一致：{digest}")
        else:
            print(f"error codes: reproducible and current ({args.output})")
        return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(text.encode("utf-8"))
    print(f"generated {args.output}")


if __name__ == "__main__":
    main()
