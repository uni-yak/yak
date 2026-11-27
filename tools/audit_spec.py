"""仓库内规格结构审计；不构成语义确认。"""
from pathlib import Path
import argparse
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "spec"


def resolve_ref(origin, ref):
    path = ref.split(":", 1)[0].split("#", 1)[0]
    direct = origin.parent / path
    if direct.exists():
        return direct.resolve()
    # error.def 历史上使用相对语言目录的短引用。
    if origin.name == "error.def" and (SPEC / "lang" / path).is_file():
        return (SPEC / "lang" / path).resolve()
    return None


def audit(report=False, freeze=False):
    errors = []
    docs = {}
    rejection_class = {}
    inactive_full_specs = []
    declared_inactive = {}
    index = (SPEC / "index.md").read_text(encoding="utf-8")
    for path in sorted(SPEC.rglob("*.md")):
        if path.name in {"README.md", "index.md"} or "tpl" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")
        status = re.search(r"^- 状态：(确认|草案-可实施|草案|缺失)\s*$", text, re.M)
        if not status:
            errors.append(f"{path.relative_to(ROOT)}: missing status metadata")
            continue
        docs[path.resolve()] = status[1]
        gate_assert = re.search(r"^- 拒绝形态类别：门禁断言\s*$", text, re.M)
        if gate_assert:
            rejection_class[path.resolve()] = "门禁断言"
        rel = path.relative_to(SPEC).as_posix()
        row = re.search(r"^\| `" + re.escape(rel) + r"` \|[^\n]+", index, re.M)
        if not row or f"| {status[1]} |" not in row[0]:
            errors.append(f"{rel}: index status missing or inconsistent")
        if row:
            cells = [c.strip() for c in row[0].strip().strip("|").split("|")]
            impl_states = cells[3:5] if len(cells) >= 5 else []
            if len(cells) >= 6 and "；full 未激活" in cells[-1]:
                note = re.search(r"；full 未激活(?:：([A-Z]+-\d+(?:、[A-Z]+-\d+)*))?$", cells[-1])
                if not note or cells[-1].count("；full 未激活") != 1:
                    errors.append(f"{rel}: invalid inactive full declaration")
                elif (cells[1] != "full" or impl_states != ["不适用", "未实现"]
                      or not re.search(r"^- 级别：full[ \t]*$", text, re.M)):
                    errors.append(f"{rel}: inactive full declaration requires an unimplemented full spec")
                elif not note[1] and status[1] == "缺失":
                    inactive_full_specs.append(rel)
                elif note[1] and status[1] == "草案" and not gate_assert:
                    anchors = note[1].split("、")
                    if len(anchors) != len(set(anchors)):
                        errors.append(f"{rel}: duplicate inactive full rejection rule")
                    declared_inactive[path.resolve()] = set(anchors)
                else:
                    errors.append(f"{rel}: invalid inactive full declaration")
            legal = {"契约态": {"确认"}, "参考态": {"草案-可实施"},
                     "未实现": {"确认", "草案-可实施", "草案", "缺失"},
                     "不适用": {"确认", "草案-可实施", "草案", "缺失"}}
            for impl in impl_states:
                if impl in legal and status[1] not in legal[impl]:
                    errors.append(f"{rel}: implementation state {impl} conflicts with spec status {status[1]}")
                elif impl not in legal:
                    errors.append(f"{rel}: unknown implementation state {impl}")
        deps = re.search(r"^- 依赖：(.+)$", text, re.M)
        if not deps:
            errors.append(f"{rel}: missing dependencies")
        else:
            for ref in re.findall(r"`([^`]+)`", deps[1]):
                if not resolve_ref(path, ref):
                    errors.append(f"{rel}: missing dependency {ref}")
        if status[1] != "确认" and re.search(r"^#+ .*（冻结）", text, re.M):
            errors.append(f"{rel}: subsection claims frozen inside draft")
        for link in re.findall(r"\[[^\]]*\]\(([^)]+)\)", text):
            if "://" not in link and not link.startswith("#"):
                if not resolve_ref(path, link):
                    errors.append(f"{rel}: broken link {link}")

    seen = set()
    registered = set()
    debt = []
    entries = 0
    segments = set()
    reserved = set()
    error_text = (SPEC / "proc/error.def").read_text(encoding="utf-8")
    # 配置源语法门禁：只允许 format/segment/entry/reserve 四类声明指令，
    # 空行与既有注释放行；未知指令、意外格式行与前置空白一律按 ER-5 拒绝。
    format_version = "2"
    format_count = 0
    saw_declaration = False
    for line in error_text.splitlines():
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        # 前置空白不得绕过指令识别：缩进行按意外格式行拒绝。
        if line[0].isspace():
            errors.append(f"error.def: unexpected indented line {line}")
            continue
        keyword = line.split(None, 1)[0]
        if keyword not in {"format", "segment", "reserve", "entry"}:
            errors.append(f"error.def: unknown directive {line}")
            continue
        if keyword == "format":
            format_count += 1
            matched = re.fullmatch(r"format (\S+)", line)
            if format_count > 1:
                errors.append(f"error.def: duplicate format directive {line}")
            elif not matched or matched[1] != format_version:
                errors.append(f"error.def: unsupported format directive {line}")
            elif saw_declaration:
                # format 必须位于首个段/预留/条目声明之前。
                errors.append(f"error.def: misplaced format directive {line}")
        else:
            saw_declaration = True
            if not line.startswith(keyword + " "):
                errors.append(f"error.def: unexpected directive line {line}")
    if format_count == 0:
        errors.append("error.def: missing format directive")
    for line in error_text.splitlines():
        if line.startswith("segment "):
            m = re.fullmatch(r'segment (E\d{1,2})\s+name "[^"]+"(?:\s+parent (E\d))?', line)
            if not m or m[1] in segments or (m[2] and m[2] not in segments):
                errors.append(f"error.def: invalid segment {line}")
            else:
                segments.add(m[1])
        elif line.startswith("reserve "):
            m = re.fullmatch(r"reserve (E\d{2}) from (\d{2}) to (\d{2})", line)
            if not m or m[1] not in segments or not 1 <= int(m[2]) <= int(m[3]) <= 99:
                errors.append(f"error.def: invalid reservation {line}")
            else:
                for slot in range(int(m[2]), int(m[3]) + 1):
                    code = m[1] + f"{slot:02d}"
                    if code in reserved:
                        errors.append(f"error.def: overlapping reservation {code}")
                    reserved.add(code)
    for line in error_text.splitlines():
        if not line.startswith("entry "):
            continue
        m = re.fullmatch(r'entry (E\d{2})\s+code (\d{2})\s+ref (\S+)\s+desc "([^"]+)"', line)
        if not m:
            # 序号必须显式书写；缺少 code 字段即视为隐式码位分配（ER-5）。
            if not re.search(r"(?<!\S)code(?!\S)", line):
                errors.append(f"error.def: entry missing explicit code {line}")
            else:
                errors.append(f"error.def: malformed entry {line}")
            continue
        code = m[1] + m[2]
        if code in seen or code in reserved or m[1] not in segments or not 1 <= int(m[2]) <= 99:
            errors.append(f"error.def: invalid/duplicate code {code}")
        seen.add(code)
        target = resolve_ref(SPEC / "proc/error.def", m[3])
        if not target:
            errors.append(f"error.def: missing reference {m[3]}")
        elif ":" not in m[3]:
            errors.append(f"error.def: missing rule anchor {m[3]}")
        else:
            anchor = m[3].split(":", 1)[1]
            registered.add((target, anchor))
            # 精确词边界，避免 L-1 误匹配 L-10。
            if not re.search(r"(?<![\w.-])" + re.escape(anchor) + r"(?![\w.-])", target.read_text(encoding="utf-8")):
                errors.append(f"error.def: missing rule {m[3]}")
        entries += 1
    aliases = 0
    gate_assertions = []
    inactive_full_rows = []
    for path in docs:
        rel = path.relative_to(SPEC).as_posix()
        remaining = declared_inactive.get(path, set()).copy()
        text = path.read_text(encoding="utf-8")
        for section in re.findall(r"^## [^\n]*拒绝形态[^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S):
            for row in re.findall(r"^\| ([A-Z]+-\d+) \|([^\n]*)", section, re.M):
                rule, content = row
                codes = re.findall(r"\bE\d{4}\b", content)
                if rule in declared_inactive.get(path, ()):
                    remaining.discard(rule)
                    if (path, rule) in registered or codes:
                        errors.append(f"{rel}:{rule}: inactive full rule must not claim an error code")
                    else:
                        inactive_full_rows.append(f"{rel}:{rule}")
                    continue
                if (path, rule) in registered:
                    continue
                if codes and all(code in seen for code in codes):
                    aliases += 1
                elif rejection_class.get(path) == "门禁断言":
                    gate_assertions.append(f"{path.relative_to(SPEC).as_posix()}:{rule}")
                else:
                    debt.append(f"{rel}:{rule}")
        for rule in sorted(remaining):
            errors.append(f"{rel}:{rule}: inactive full rule not found in rejection table")
    missing = [p.relative_to(SPEC).as_posix() for p, state in docs.items() if state == "缺失"]
    dependency_debt = []
    for path in docs:
        deps = re.search(r"^- 依赖：(.+)$", path.read_text(encoding="utf-8"), re.M)
        if not deps:
            continue
        for ref in re.findall(r"`([^`]+)`", deps[1]):
            target = resolve_ref(path, ref)
            candidates = sorted(target.rglob("*.md")) if target and target.is_dir() else [target]
            for dependency in candidates:
                if dependency in docs and docs[dependency] != "确认":
                    dependency_debt.append({"spec": path.relative_to(SPEC).as_posix(),
                                            "dependency": dependency.relative_to(SPEC).as_posix(),
                                            "status": docs[dependency]})
    snapshot = {"structural_errors": errors, "documents": len(docs), "error_entries": entries,
                "explicit_code_aliases": aliases, "missing_specs": missing,
                "inactive_full_specs": inactive_full_specs,
                "rejection_rows_requiring_code_mapping": debt,
                "inactive_full_rejection_rows": inactive_full_rows,
                "gate_assertion_rows_by_exit_code": gate_assertions,
                "unconfirmed_direct_dependencies": dependency_debt,
                "semantic_confirmation": False}
    if report:
        (SPEC / "audit.json").write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    for error in errors:
        print(error)
    print(f"spec audit: {len(docs)} documents, {entries} error entries, {len(errors)} structural errors")
    print(f"freeze debt: {len(missing)} missing specs ({len(inactive_full_specs)} inactive full), "
          f"{len(debt)} rejection rows need code mapping, {len(inactive_full_rows)} inactive full rows; "
          f"{aliases} explicit aliases")
    print(f"gate assertions: {len(gate_assertions)} rows by exit code (not counted in freeze debt)")
    return bool(errors or (freeze and (missing or debt or inactive_full_rows)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true")
    parser.add_argument("--freeze", action="store_true", help="同时拒绝未解决的语义审计欠账")
    args = parser.parse_args()
    sys.exit(audit(args.report, args.freeze))
