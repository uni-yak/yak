"""只生成 min 参考词法器所需的分派表，不生成 ABI 表。"""
from pathlib import Path
import argparse
import hashlib
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "compiler/min/src/lex/lextables.yak"
ARTIFACT_DIGEST_PREFIX = b"YAK-SYMBOL-SHA256-V1:"
ARTIFACT_DIGEST_SUFFIX = b":END-YAK-SYMBOL"
PARTITION_CODES = {
    "type_symbols": 1, "lang_items": 2, "kind_consts": 3, "type_value_consts": 4,
    "functions": 5, "annotations": 6, "modules": 7,
}

# 从子目录直接执行时也复用产物摘要校验。
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pe_digest import PETimestampError, check_pe_digest

# 这些配置行不生成 min 分派项，但必须保留声明式语法和显式编号。
DECLARATIONS = re.compile(
    r'format\s+2|'
    r'reserve\s+(?P<reserved_part>\w+)\s+from\s+(?P<reserved_first>0x[0-9A-Fa-f]+)'
    r'\s+to\s+(?P<reserved_last>0x[0-9A-Fa-f]+)|'
    r'derive\s+kind_consts\s+mode\s+mirror\s+source\s+type_symbols|'
    r'value_slot\s+(?P<value_slot>0x[0-9A-Fa-f]+)\s+name\s+"(?P<value_name>[^"\n]+)"|'
    r'value_block\s+type\s+"[^"\n]+"\s+block\s+(?P<value_block>0x[0-9A-Fa-f]+)\s+'
    r'enable\s+(?P<value_members>0x[0-9A-Fa-f]+(?:,0x[0-9A-Fa-f]+)*)'
)


def build_table():
    symbols = (ROOT / "spec/lang/symbol.def").read_text(encoding="utf-8")
    lex = (ROOT / "spec/lang/lex.md").read_text(encoding="utf-8")
    keywords = re.search(r"5\.1 .*?```text\n(.*?)```", lex, re.S)[1].split()
    reserved = re.search(r"5\.2 .*?```text\n(.*?)```", lex, re.S)[1].split()
    excluded_names = set(keywords) | set(reserved)
    if len(excluded_names) != len(keywords) + len(reserved):
        raise ValueError("E7005 关键字或保留字重复")
    partitions = {}
    entries = []
    reserves = {}
    raw_variants = []
    ids, names = set(), set()
    for number, raw in enumerate(symbols.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("partition "):
            m = re.fullmatch(r"partition (\w+)\s+code (0x[0-9A-Fa-f]+) depends (\S+)", line)
            if not m or m[1] in partitions:
                raise ValueError("invalid/duplicate partition")
            code = int(m[2], 16)
            if not 1 <= code <= 7:
                raise ValueError("E7003 固有符号分区码超出范围")
            if PARTITION_CODES.get(m[1]) != code:
                raise ValueError(f"E7014 固有符号分区码偏离固定布局（第 {number} 行）")
            if m[3] != "-" and any(dep not in partitions for dep in m[3].split(",")):
                raise ValueError("partition dependency order")
            partitions[m[1]] = code
        elif line.startswith("entry "):
            m = re.fullmatch(r'entry (\w+)\s+slot (0x[0-9A-Fa-f]+) stage (base|full) kind (\w+) name "([^"\n]+)"', line)
            if not m:
                raise ValueError(f"E7017 固有符号条目必须声明显式码槽（第 {number} 行）")
            if m[1] not in partitions:
                raise ValueError("invalid direct entry")
            if m[5] in excluded_names:
                raise ValueError(f"E7005 固有符号配置登记了关键字或保留字：{m[5]}")
            if m[1] == "functions" and (not m[5].startswith("@") or "::" in m[5]):
                raise ValueError(f"E7016 普通模块函数不得登记为固有原语：{m[5]}")
            if "::" in m[5] or m[1] == "modules":
                raise ValueError(f"E7004 普通模块名称不得登记为固有符号：{m[5]}")
            allowed = {"type_symbols": {"type", "enum"}, "lang_items": {"lang_item"},
                       "functions": {"primitive"}, "annotations": {"annotation"}}
            if m[4] not in allowed.get(m[1], set()) or ((m[4] in {"primitive", "annotation"}) != m[5].startswith("@")):
                raise ValueError("entry kind/name does not match partition")
            slot = int(m[2], 16)
            if not 1 <= slot <= 4095:
                raise ValueError("E7003 固有符号码槽超出分区范围")
            bid = (partitions[m[1]] << 12) | slot
            if bid in ids or m[5] in names:
                raise ValueError("duplicate name/id")
            ids.add(bid)
            names.add(m[5])
            entries.append((m[1], m[3], m[4], m[5], bid))
        elif line.startswith("enum_variant "):
            m = re.fullmatch(r'enum_variant host "([^"\n]+)" id (\d+) stage (base|full) name "([^"\n]+)"', line)
            if not m:
                raise ValueError("invalid enum_variant entry")
            raw_variants.append(m.groups())
        else:
            declaration = DECLARATIONS.fullmatch(line)
            if declaration is None:
                raise ValueError(f"E7017 未登记的符号配置声明（第 {number} 行）")
            reserved_part = declaration["reserved_part"]
            if reserved_part is not None:
                first = int(declaration["reserved_first"], 16)
                last = int(declaration["reserved_last"], 16)
                if reserved_part not in partitions or not 1 <= first <= last <= 4095:
                    raise ValueError(f"E7003 固有符号保留区超出分区范围（第 {number} 行）")
                reserves.setdefault(reserved_part, []).append((first, last))
            value_name = declaration["value_name"]
            if value_name in excluded_names:
                raise ValueError(f"E7005 固有值槽登记了关键字或保留字：{value_name}")
            slot = declaration["value_slot"]
            block = declaration["value_block"]
            if slot is not None and not 1 <= int(slot, 16) <= 8:
                raise ValueError(f"E7014 类型关联常量成员超出八槽布局（第 {number} 行）")
            if block is not None:
                members = [int(member, 16) for member in declaration["value_members"].split(",")]
                if not 1 <= int(block, 16) <= 511 or any(not 1 <= member <= 8 for member in members):
                    raise ValueError(f"E7014 类型关联常量超出块号或成员布局（第 {number} 行）")
    for part, _, _, name, bid in entries:
        slot = bid & 0xFFF
        if any(first <= slot <= last for first, last in reserves.get(part, ())):
            raise ValueError(f"E7004 名称占用了仍保留的固有符号码槽：{name}")
    name_to_bid = {name: bid for _, _, _, name, bid in entries}
    variants = []
    variant_keys = set()
    for host, variant_id, stage, variant_name in raw_variants:
        if host not in name_to_bid:
            raise ValueError("enum_variant host is not a registered type symbol")
        if variant_name in excluded_names:
            raise ValueError(f"E7005 固有枚举标签登记了关键字或保留字：{variant_name}")
        vid = int(variant_id)
        key = (host, variant_name)
        if not 0 <= vid <= 65535 or key in variant_keys:
            raise ValueError("duplicate/invalid enum_variant")
        variant_keys.add(key)
        if stage == "base":
            variants.append((name_to_bid[host], vid, variant_name))
    digest = hashlib.sha256((symbols + lex).encode()).hexdigest()
    lines = ["// 由 tools/symgen/lex_tables.py 生成；请勿手改。",
             "// 源摘要：" + digest, ""]
    marker = (ARTIFACT_DIGEST_PREFIX + digest.encode("ascii") + ARTIFACT_DIGEST_SUFFIX).decode("ascii")
    lines.extend([
        "// 生成源和链接产物共用同一份只读摘要。",
        f'const SOURCE_SHA256: &[u8] = "{marker}";',
        "",
        "export function symbol_source_sha256_at(at: u32): u8 {",
        "    if at >= 64u32 { return 0u8; }",
        f"    return SOURCE_SHA256[{len(ARTIFACT_DIGEST_PREFIX)}u32 + at];",
        "}",
        "",
    ])

    def dispatch(name, table, result, miss):
        lines.append(f"export function {name}(src: &[u8], off: u32, len: u32): {result} {{")
        for word, value in table:
            lines.append(f'    if len == {len(word.encode())} && matches(src, off, "{word}") {{ return {value}; }}')
        lines.extend([f"    return {miss};", "}", ""])

    dispatch("keyword", list(zip(keywords, range(len(keywords)))), "u8", "255")
    lines.extend(['export function completion_keywords(): u8[]!AllocError {',
                  '    let text: &[u8] = "' + ' '.join(sorted(keywords)) + '";',
                  '    var words: u8[] = [];',
                  '    var i: u32 = 0;',
                  '    while i < @len(text) as u32 { @push(words, text[i])?; i = i + 1u32; }',
                  '    return words;', '}', ''])
    dispatch("reserved", [(w, "true") for w in reserved], "bool", "false")
    dispatch("name_builtin", [(name, bid) for part, stage, kind, name, bid in entries
                              if part == "type_symbols" and stage == "base"], "u16", "0")
    dispatch("builtin", [(name[1:], bid) for part, stage, kind, name, bid in entries
                         if kind in {"primitive", "annotation"}], "u16", "0")
    lines.append("export function builtin_is_base(id: u16): bool {")
    for part, stage, kind, name, bid in entries:
        if kind == "primitive" and stage == "base":
            lines.append(f"    if id == {bid} {{ return true; }}")
    lines.extend(["    return false;", "}", ""])
    labels = {name: i for i, name in enumerate(sorted({name for _, _, name in variants}), 1)}
    dispatch("builtin_variant_name", labels.items(), "u32", "0")
    lines.append(f"export function builtin_variant_name_count(): u32 {{ return {len(labels)}; }}")
    lines.append("")
    lines.append("export function builtin_variant(host: u16, label: u32): u32 {")
    for host_bid, variant_id, variant_name in variants:
        lines.append(f"    if host == {host_bid} && label == {labels[variant_name]} {{ return {variant_id}; }}")
    lines.extend(["    return 4294967295u32;", "}", ""])
    lines.extend([
        "function matches(src: &[u8], off: u32, expected: &[u8]): bool {",
        "    let n: u32 = @len(src) as u32;",
        "    let size: u32 = @len(expected) as u32;",
        "    if off > n || size > n - off { return false; }",
        "    var i: u32 = 0;",
        "    while i < size {",
        "        if src[off + i] != expected[i] { return false; }",
        "        i = i + 1;",
        "    }", "    return true;", "}", ""])
    return "\n".join(lines), digest


def generate():
    """返回确定性生成的词法表正文。"""
    return build_table()[0]


def main(argv=None):
    """运行生成或只读校验，非法配置在写出前拒绝。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--check-artifact", type=Path, metavar="PE", help="校验生成表与 AMD64 PE 内嵌摘要")
    args = parser.parse_args(argv)
    try:
        text, digest = build_table()
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    if args.check or args.check_artifact is not None:
        if not OUTPUT.is_file() or OUTPUT.read_bytes() != text.encode():
            print("E7010 词法表与配置源不一致：运行 python tools/symgen/lex_tables.py", file=sys.stderr)
            return 1
        if args.check_artifact is not None:
            try:
                check_pe_digest(args.check_artifact, digest, ARTIFACT_DIGEST_PREFIX, ARTIFACT_DIGEST_SUFFIX, "符号表")
            except PETimestampError as error:
                print(error, file=sys.stderr)
                return 1
            except (ValueError, OSError) as error:
                print(f"E7010 符号表产物校验失败：{error}", file=sys.stderr)
                return 1
            print(f"符号表产物摘要一致：{digest}")
        else:
            print("lex tables: reproducible and current")
    else:
        OUTPUT.write_bytes(text.encode())
        print("generated compiler/min/src/lex/lextables.yak")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
