#!/usr/bin/env python3
# 候选取证二进制审计助手：解析 YKIF/YKSM，交叉校验依赖摘要；夹具模式只写调用方指定目录。
# 只读审计产物；不接触 Seed、构建锁或生产输出位置。
import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

YKIF_MAGIC = b"YKIF"
YKIF_FORMAT = 2
YKIF_HEADER_SIZE = 56
YKIF_DIGEST_OFFSET = 24
YKIF_KINDS = tuple(range(1, 16))
# header flags bit 0：含 private_names 节；旧接口为 0，当前 profile 不接受。
YKIF_FLAGS = 1
YKSM_MAGIC = b"YKMI"
YKSM_HEADER_SIZE = 64
YKSM_DIGEST_OFFSET = 28
YKSM_KINDS = tuple(range(1, 8))
DIGEST_SIZE = 32
DEPENDENCY_SIZE = 40
MODULE_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*$")
NAMED_RECORDS = {
    4: (32, 0, 8),   # 导出记录
    8: (32, 4, 24),  # 枚举成员
    13: (32, 4, 24), # 结构体字段
    15: (16, 0, 8),  # 私有名
}


class AuditError(Exception):
    """审计失败：结构不可解析或证据不足。"""


class UsageError(Exception):
    """命令行参数错误。"""


def read_u16(data, offset):
    need(data, offset, 2, "u16 字段")
    return struct.unpack_from("<H", data, offset)[0]


def read_u32(data, offset):
    need(data, offset, 4, "u32 字段")
    return struct.unpack_from("<I", data, offset)[0]


def need(data, offset, size, label):
    if offset < 0 or size < 0 or offset + size > len(data):
        raise AuditError(f"{label}越界：偏移 {offset}，长度 {size}，文件 {len(data)}")


def digest_zeroed(data, offset):
    """把摘要字段置零后计算 SHA-256；返回小写十六进制。"""
    copy = bytearray(data)
    need(copy, offset, DIGEST_SIZE, "摘要字段")
    copy[offset:offset + DIGEST_SIZE] = b"\x00" * DIGEST_SIZE
    return hashlib.sha256(bytes(copy)).hexdigest()


def decode_module_name(raw, label):
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise AuditError(f"{label}不是合法 UTF-8：{exc}") from exc
    if not text:
        raise AuditError(f"{label}为空")
    if text != text.strip() or any(ord(ch) < 0x20 for ch in text):
        raise AuditError(f"{label}含空白或控制字符")
    if not MODULE_PATTERN.fullmatch(text):
        raise AuditError(f"{label}不是合法的 :: 分段模块身份：{text}")
    return text


def parse_section_table(data, header_size, section_count, table_offset, file_size, expected_kinds, label):
    """校验固定头之后的节目录；返回按 kind 索引的节表。"""
    if file_size != len(data):
        raise AuditError(f"文件长度与头部 file_size 不一致：实际 {len(data)}，头部 {file_size}")
    if table_offset != header_size:
        raise AuditError(f"{label} section_table_offset 不是 {header_size}：{table_offset}")
    if section_count != len(expected_kinds):
        raise AuditError(f"{label} 节数量不是 {len(expected_kinds)}：{section_count}")
    need(data, table_offset, section_count * 16, f"{label} 节目录")
    table_end = table_offset + section_count * 16
    sections = []
    for index, expected_kind in enumerate(expected_kinds):
        entry_offset = table_offset + index * 16
        kind, flags, offset, length, count = struct.unpack_from("<HHIII", data, entry_offset)
        if kind != expected_kind:
            raise AuditError(f"{label} 第 {index + 1} 节 kind 应为 {expected_kind}，实际 {kind}")
        if offset < table_end or offset > file_size:
            raise AuditError(f"{label} 第 {kind} 节偏移越界：{offset}，节目录结束 {table_end}，文件 {file_size}")
        if offset + length > file_size:
            raise AuditError(f"{label} 第 {kind} 节长度越界：偏移 {offset}，长度 {length}，文件 {file_size}")
        if count == 0 and length != 0:
            raise AuditError(f"{label} 第 {kind} 节 count 为 0 但长度为 {length}")
        if count > 0 and length == 0:
            raise AuditError(f"{label} 第 {kind} 节 count 为 {count} 但长度为 0")
        sections.append({"kind": kind, "flags": flags, "offset": offset, "length": length, "count": count})
    return sections


def check_interface_name_hashes(data, names, sections):
    """按规格的固定 FNV-1a 64 初值独立复算所有接口名称哈希。"""
    for kind, (width, name_field, hash_field) in NAMED_RECORDS.items():
        section = sections[kind]
        if section["length"] != section["count"] * width:
            raise AuditError(f"YKIF 第 {kind} 节的名称记录宽度不符")
        for index in range(section["count"]):
            record = section["offset"] + index * width
            start, length = struct.unpack_from("<IH", data, record + name_field)
            need(names, start, length, f"YKIF 第 {kind} 节名称")
            value, = struct.unpack_from("<Q", data, record + hash_field)
            expected = 14695981039346656037
            for byte in names[start:start + length]:
                expected = ((expected ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
            if value != expected:
                raise AuditError(f"E7002 YKIF 第 {kind} 节记录 {index + 1} 的名称哈希不符合固定 FNV-1a 64")


def parse_ykif(path):
    """解析 YKIF format 2；结构错误抛出 AuditError，自身摘要不符记入 problems。"""
    data = path.read_bytes()
    if len(data) < 4:
        raise AuditError("文件不足 4 字节")
    if data[:4] != YKIF_MAGIC:
        raise AuditError("magic 不是 YKIF")
    need(data, 0, YKIF_HEADER_SIZE, "YKIF 固定头")
    fmt = read_u16(data, 4)
    if fmt != YKIF_FORMAT:
        raise AuditError(f"YKIF format 不是 2：{fmt}")
    flags = read_u16(data, 6)
    target_profile = read_u32(data, 8)
    section_count = read_u16(data, 12)
    reserved = read_u16(data, 14)
    table_offset = read_u32(data, 16)
    file_size = read_u32(data, 20)
    digest = data[24:56]
    problems = []
    if flags != YKIF_FLAGS:
        problems.append(f"YKIF flags 不是 {YKIF_FLAGS}（应声明含私有名节）：{flags}")
    if reserved != 0:
        problems.append("YKIF 保留字段非零")
    sections = parse_section_table(data, YKIF_HEADER_SIZE, section_count, table_offset, file_size, YKIF_KINDS, "YKIF")
    by_kind = {entry["kind"]: entry for entry in sections}
    for entry in sections:
        if entry["flags"] != 0:
            problems.append(f"YKIF 第 {entry['kind']} 节 flags 非零")
    if by_kind[1]["length"] != by_kind[1]["count"]:
        problems.append("YKIF name_bytes 节长度与 count 不一致")
    names = data[by_kind[1]["offset"]:by_kind[1]["offset"] + by_kind[1]["length"]]
    check_interface_name_hashes(data, names, by_kind)
    ident = by_kind[2]
    if ident["length"] != 8 or ident["count"] != 1:
        raise AuditError(f"YKIF module_identity 节应为 1 条 8 字节，实际 count={ident['count']} length={ident['length']}")
    name_offset, name_length, ident_reserved = struct.unpack_from("<IHH", data, ident["offset"])
    if ident_reserved != 0:
        problems.append("YKIF module_identity 保留字段非零")
    if name_length == 0 or name_offset + name_length > len(names):
        raise AuditError("YKIF 模块身份越出 name_bytes 节")
    identity = decode_module_name(names[name_offset:name_offset + name_length], "模块身份")
    deps_section = by_kind[3]
    if deps_section["length"] != deps_section["count"] * DEPENDENCY_SIZE:
        raise AuditError(f"YKIF dependencies 节长度不是 count*40：count={deps_section['count']} length={deps_section['length']}")
    deps = []
    seen = set()
    for index in range(deps_section["count"]):
        record_offset = deps_section["offset"] + index * DEPENDENCY_SIZE
        dep_offset, dep_length, dep_flags, dep_digest = struct.unpack_from("<IHH32s", data, record_offset)
        if dep_flags != 0:
            problems.append(f"YKIF 依赖 {index + 1} 的 flags 非零")
        if dep_length == 0 or dep_offset + dep_length > len(names):
            raise AuditError(f"YKIF 依赖 {index + 1} 的模块名越出 name_bytes 节")
        module = decode_module_name(names[dep_offset:dep_offset + dep_length], f"依赖 {index + 1} 的模块名")
        if module == identity:
            problems.append(f"YKIF 依赖 {index + 1} 的模块名与自身身份相同：{module}")
        if module in seen:
            problems.append(f"YKIF 依赖模块名重复：{module}")
        seen.add(module)
        deps.append({"module": module, "digest": dep_digest.hex(), "flags": dep_flags})
    computed = digest_zeroed(data, YKIF_DIGEST_OFFSET)
    digest_ok = computed == digest.hex()
    if not digest_ok:
        problems.append("YKIF 自身摘要不正确")
    return {
        "path": str(path),
        "size": len(data),
        "format": fmt,
        "flags": flags,
        "target_profile": target_profile,
        "section_count": section_count,
        "identity": identity,
        "deps": deps,
        "digest": digest.hex(),
        "computed_digest": computed,
        "digest_ok": digest_ok,
        "problems": problems,
    }


def parse_yksm(path):
    """解析 YKSM format 4、5、6；结构错误抛出 AuditError，自身摘要不符记入 problems。"""
    data = path.read_bytes()
    if len(data) < 4:
        raise AuditError("文件不足 4 字节")
    if data[:4] != YKSM_MAGIC:
        raise AuditError("magic 不是 YKMI")
    need(data, 0, YKSM_HEADER_SIZE, "YKSM 固定头")
    version = read_u16(data, 4)
    if version not in (4, 5, 6):
        raise AuditError(f"YKSM version 不是 4、5 或 6：{version}")
    flags = read_u16(data, 6)
    section_count = read_u16(data, 8)
    target_profile = read_u16(data, 10)
    table_offset = read_u32(data, 12)
    file_size = read_u32(data, 16)
    function_count = read_u32(data, 20)
    static_count = read_u32(data, 24)
    sha = data[28:60]
    reserved = read_u32(data, 60)
    problems = []
    expected_flags = 1 if version == 6 else 0
    if flags != expected_flags:
        problems.append(f"YKSM flags 与版本不匹配：版本 {version}，期望 {expected_flags}，实际 {flags}")
    if reserved != 0:
        problems.append("YKSM 保留字段非零")
    sections = parse_section_table(data, YKSM_HEADER_SIZE, section_count, table_offset, file_size, YKSM_KINDS, "YKSM")
    by_kind = {entry["kind"]: entry for entry in sections}
    for entry in sections:
        if entry["flags"] != 0:
            problems.append(f"YKSM 第 {entry['kind']} 节 flags 非零")
    deps_section = by_kind[7]
    if deps_section["length"] != deps_section["count"] * DEPENDENCY_SIZE:
        raise AuditError(f"YKSM dependencies 节长度不是 count*40：count={deps_section['count']} length={deps_section['length']}")
    deps = []
    for index in range(deps_section["count"]):
        record_offset = deps_section["offset"] + index * DEPENDENCY_SIZE
        dependency_id, reserved0, dep_digest, reserved1 = struct.unpack_from("<HH32sI", data, record_offset)
        if dependency_id != index + 1:
            raise AuditError(f"YKSM 依赖编号不是连续升序：第 {index + 1} 条为 {dependency_id}")
        if reserved0 != 0 or reserved1 != 0:
            problems.append(f"YKSM 依赖 {dependency_id} 的保留字段非零")
        deps.append({"id": dependency_id, "digest": dep_digest.hex()})
    computed = digest_zeroed(data, YKSM_DIGEST_OFFSET)
    digest_ok = computed == sha.hex()
    if not digest_ok:
        problems.append("YSM 自身摘要不正确")
    return {
        "path": str(path),
        "size": len(data),
        "version": version,
        "flags": flags,
        "target_profile": target_profile,
        "section_count": section_count,
        "function_count": function_count,
        "static_count": static_count,
        "deps": deps,
        "digest": sha.hex(),
        "computed_digest": computed,
        "digest_ok": digest_ok,
        "problems": problems,
    }


def fail(container, scope, kind, message):
    container["failures"].append({"scope": scope, "kind": kind, "message": message})


def profiles_match(interface_profile, mir_profile):
    """以无损方式把接口的 u16+u16 profile 与 MIR 的 u8+u8 对齐。"""
    layout, abi = divmod(interface_profile, 65536)
    return layout <= 255 and abi <= 255 and mir_profile == layout * 256 + abi


def verify_unit(audit_name, root_name, stem, iface, ysm, all_ifaces, by_identity, root_report):
    """校验一个单元的 YKIF/YKSM 配对与全部依赖摘要映射。"""
    scope = f"{audit_name}/{root_name}/{stem}"
    unit = {"unit": stem, "identity": iface["identity"], "status": "ok", "problems": [], "deps": []}
    seen_problems = set()

    def problem(kind, message):
        if message in seen_problems:
            return
        seen_problems.add(message)
        unit["problems"].append({"kind": kind, "message": message})
        fail(root_report, scope, kind, message)
        unit["status"] = "fail"

    for message in iface["problems"]:
        problem("iface_self", message)
    for message in ysm["problems"]:
        problem("ysm_self", message)
    if not profiles_match(iface["target_profile"], ysm["target_profile"]):
        problem("unit_profile", "E7030 同一单元的 YKIF 与 YSM profile 不匹配")

    expected_stem = iface["identity"].replace("::", ".")
    if expected_stem != stem:
        problem("identity_artifact", f"产物文件名 {stem} 与模块身份 {iface['identity']} 不一致（期望 {expected_stem}）")

    iface_deps = iface["deps"]
    ysm_deps = ysm["deps"]
    if len(iface_deps) != len(ysm_deps):
        problem("dep_count", f"依赖数量不一致：YKIF {len(iface_deps)} 条，YSM {len(ysm_deps)} 条")

    def candidates_for(digest_hex):
        return [
            other_stem for other_stem, other in all_ifaces.items()
            if other["digest_ok"] and other["digest"] == digest_hex
        ]

    for index, ysm_dep in enumerate(ysm_deps):
        dependency_id = index + 1
        if index >= len(iface_deps):
            problem("dep_missing", f"YSM 依赖 {dependency_id} 在 YKIF 依赖表中没有对应记录")
            continue
        iface_dep = iface_deps[index]
        module = iface_dep["module"]
        dep_record = {
            "id": dependency_id,
            "module": module,
            "ysm_digest": ysm_dep["digest"],
            "iface_digest": iface_dep["digest"],
            "target": None,
            "digest_only": {"count": 0, "identities": []},
            "mapping_required": True,
            "digest_only_misaccept": False,
        }
        unit["deps"].append(dep_record)

        digest_match = ysm_dep["digest"] == iface_dep["digest"]
        if not digest_match:
            problem("dep_digest", f"E7029 依赖 {dependency_id}（模块 {module}）的 YSM 依赖摘要与 YKIF 依赖摘要不一致")

        candidates = candidates_for(ysm_dep["digest"])
        candidate_identities = [all_ifaces[item]["identity"] for item in candidates]
        dep_record["digest_only"] = {"count": len(candidates), "identities": candidate_identities}

        target_stems = by_identity.get(module, [])
        if len(target_stems) > 1:
            problem("dep_ambiguous", f"依赖 {dependency_id} 的模块 {module} 对应多个 .iface：{', '.join(target_stems)}")
        elif len(target_stems) == 0:
            extra = ""
            if candidates:
                extra = f"；仅按摘要命中会选中 {', '.join(candidate_identities)}，但不能证明模块身份"
            problem("dep_unmapped", f"无法按模块名解析依赖 {dependency_id}（模块 {module}）到同根 .iface{extra}")
            dep_record["digest_only_misaccept"] = len(candidates) == 1
            continue
        else:
            target_stem = target_stems[0]
            target = all_ifaces[target_stem]
            dep_record["target"] = target_stem
            if not profiles_match(target["target_profile"], ysm["target_profile"]):
                problem("target_profile", f"E7030 依赖 {dependency_id}（模块 {module}）的 YKIF profile 与 YSM 不匹配")
            if not target["digest_ok"]:
                problem("target_self", f"依赖 {dependency_id} 的目标 {target_stem} 的 YKIF 自身摘要不正确")
            if target["identity"] != module:
                problem("target_identity", f"依赖 {dependency_id} 的目标身份 {target['identity']} 与模块名 {module} 不一致")
            if target["digest"] != ysm_dep["digest"]:
                extra = ""
                if len(candidates) == 1 and candidates[0] != target_stem:
                    extra = f"；仅按摘要命中会误选 {candidates[0]}，准确映射指向 {target_stem}"
                problem("target_digest", f"E7029 依赖 {dependency_id}（模块 {module}）的目标 YKIF content_digest 与 YSM 记录不一致{extra}")
            if iface_dep["digest"] != target["digest"]:
                problem("iface_dep_digest", f"依赖 {dependency_id}（模块 {module}）的 YKIF 依赖摘要与目标 YKIF content_digest 不一致")
            dep_record["mapping_required"] = not (len(candidates) == 1 and candidates[0] == target_stem)
            dep_record["digest_only_misaccept"] = len(candidates) == 1 and candidates[0] != target_stem

    for index in range(len(ysm_deps), len(iface_deps)):
        problem("dep_missing", f"YKIF 依赖 {index + 1}（模块 {iface_deps[index]['module']}）在 YSM 中没有记录")

    # 即使 YSM 缺失，也应证明 YKIF 的每个直接依赖都能按模块名落到同根 .iface。
    for index, iface_dep in enumerate(iface_deps):
        if iface_dep["module"] not in by_identity:
            problem("iface_dep_unmapped", f"YKIF 依赖 {index + 1}（模块 {iface_dep['module']}）无法按模块名解析到同根 .iface")

    return unit


def verify_fp3(audits, roots):
    report = {
        "tool": "base_selfhost_evidence.py",
        "scope": "fp3",
        "roots": list(roots),
        "audits": [],
        "summary": {},
        "status": "ok",
    }
    log_lines = ["base 自举候选 FP-3 摘要映射校验", ""]
    total_failures = 0
    total_ifaces = 0
    total_ysms = 0
    total_iface_deps = 0
    total_ysm_deps = 0
    total_units = 0
    total_roots = 0
    mapping_required = 0
    digest_only_unique = 0
    digest_only_ambiguous = 0
    digest_only_none = 0
    digest_only_misaccept = 0

    for audit_name, audit_path in audits:
        audit_report = {"name": audit_name, "path": str(audit_path), "roots": [], "failures": [], "status": "ok"}
        log_lines.append(f"审计 {audit_name}：{audit_path}")
        if not audit_path.is_dir():
            message = f"审计目录不存在：{audit_path}"
            fail(audit_report, audit_name, "audit_missing", message)
            audit_report["status"] = "fail"
            report["audits"].append(audit_report)
            total_failures += 1
            log_lines.append(f"[失败] {audit_name}：{message}")
            continue

        for root_name in roots:
            total_roots += 1
            root_dir = audit_path / root_name
            root_report = {"root": root_name, "ifaces": 0, "ysms": 0, "units": [], "failures": [], "status": "ok"}
            scope_root = f"{audit_name}/{root_name}"
            if not root_dir.is_dir():
                message = f"审计根目录不存在：{root_dir}"
                fail(root_report, scope_root, "root_missing", message)
                root_report["status"] = "fail"
                log_lines.append(f"[失败] {scope_root}：{message}")
                audit_report["roots"].append(root_report)
                audit_report["failures"].extend(root_report["failures"])
                audit_report["status"] = "fail"
                continue

            ifaces = {}
            ysms = {}
            for path in sorted(root_dir.glob("*.iface")):
                stem = path.stem
                try:
                    ifaces[stem] = parse_ykif(path)
                except (AuditError, OSError) as exc:
                    message = f"解析 .iface 失败：{exc}"
                    fail(root_report, f"{scope_root}/{stem}", "iface_parse", message)
                    log_lines.append(f"[失败] {scope_root}/{stem}：{message}")
            for path in sorted(root_dir.glob("*.ysm")):
                stem = path.stem
                try:
                    ysms[stem] = parse_yksm(path)
                except (AuditError, OSError) as exc:
                    message = f"解析 .ysm 失败：{exc}"
                    fail(root_report, f"{scope_root}/{stem}", "ysm_parse", message)
                    log_lines.append(f"[失败] {scope_root}/{stem}：{message}")

            for stem in sorted(ifaces):
                if stem not in ysms:
                    message = "缺少对应 .ysm"
                    fail(root_report, f"{scope_root}/{stem}", "missing_ysm", message)
                    log_lines.append(f"[失败] {scope_root}/{stem}：{message}")
            for stem in sorted(ysms):
                if stem not in ifaces:
                    message = "缺少对应 .iface"
                    fail(root_report, f"{scope_root}/{stem}", "missing_iface", message)
                    log_lines.append(f"[失败] {scope_root}/{stem}：{message}")

            by_identity = {}
            for stem, iface in ifaces.items():
                by_identity.setdefault(iface["identity"], []).append(stem)
            for identity, stems in sorted(by_identity.items()):
                if len(stems) > 1:
                    message = f"重复的模块身份 {identity}：{', '.join(stems)}"
                    fail(root_report, scope_root, "duplicate_identity", message)
                    log_lines.append(f"[失败] {scope_root}：{message}")

            paired = sorted(set(ifaces) & set(ysms))
            for stem in paired:
                unit = verify_unit(audit_name, root_name, stem, ifaces[stem], ysms[stem], ifaces, by_identity, root_report)
                root_report["units"].append(unit)
                total_units += 1
                for dep in unit.get("deps", []):
                    if dep["mapping_required"]:
                        mapping_required += 1
                    count = dep["digest_only"]["count"]
                    if count == 1:
                        digest_only_unique += 1
                    elif count > 1:
                        digest_only_ambiguous += 1
                    else:
                        digest_only_none += 1
                    if dep["digest_only_misaccept"]:
                        digest_only_misaccept += 1
                if unit["status"] == "ok":
                    dep_text = "、".join(f"{item['id']}→{item['module']}" for item in unit["deps"]) or "无依赖"
                    log_lines.append(f"[通过] {scope_root}/{stem}：YKIF/YSM 摘要有效；{dep_text}")
                else:
                    details = "；".join(item["message"] for item in unit["problems"])
                    log_lines.append(f"[失败] {scope_root}/{stem}：{details}")

            root_report["ifaces"] = len(ifaces)
            root_report["ysms"] = len(ysms)
            root_report["status"] = "fail" if root_report["failures"] else "ok"
            total_ifaces += len(ifaces)
            total_ysms += len(ysms)
            total_iface_deps += sum(len(iface["deps"]) for iface in ifaces.values())
            total_ysm_deps += sum(len(ysm["deps"]) for ysm in ysms.values())
            audit_report["roots"].append(root_report)
            audit_report["failures"].extend(root_report["failures"])
            if root_report["status"] != "ok":
                audit_report["status"] = "fail"

        total_failures += len(audit_report["failures"])
        report["audits"].append(audit_report)

    if total_failures:
        report["status"] = "fail"
    report["summary"] = {
        "audits": len(audits),
        "roots": total_roots,
        "ifaces": total_ifaces,
        "ysms": total_ysms,
        "units": total_units,
        "iface_deps": total_iface_deps,
        "ysm_deps": total_ysm_deps,
        "failures": total_failures,
        "mapping_required": mapping_required,
        "digest_only_unique": digest_only_unique,
        "digest_only_ambiguous": digest_only_ambiguous,
        "digest_only_none": digest_only_none,
        "digest_only_misaccept": digest_only_misaccept,
    }
    summary = report["summary"]
    log_lines.append("")
    log_lines.append(
        "摘要：审计 {audits}、根 {roots}、iface {ifaces}、ysm {ysms}、依赖 {ysm_deps}；"
        "失败 {failures}；仅摘要唯一命中 {digest_only_unique}、歧义 {digest_only_ambiguous}、"
        "无命中 {digest_only_none}、需模块名区分 {mapping_required}、仅摘要会误选 {digest_only_misaccept}。".format(**summary)
    )
    log_lines.append("结果：" + ("通过" if report["status"] == "ok" else "失败"))
    report["log"] = log_lines
    return report


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def build_ykif(identity, deps):
    """生成最小合法 YKIF format 2；deps 为 (模块名, 32 字节十六进制摘要) 列表。"""
    identity_raw = identity.encode("utf-8")
    name_bytes = bytearray(identity_raw)
    offsets = {identity: (0, len(identity_raw))}

    def add_name(text):
        raw = text.encode("utf-8")
        offsets[text] = (len(name_bytes), len(raw))
        name_bytes.extend(raw)
        return raw

    # 模块身份固定放在 name_bytes 起始处。
    for module, _digest in deps:
        if module not in offsets:
            add_name(module)
    # 若依赖重名，add_name 已存在时不会重复追加；fixture 不生成重名。
    ident = struct.pack("<IHH", 0, len(identity.encode("utf-8")), 0)
    dep_data = bytearray()
    for module, digest_hex in deps:
        offset, length = offsets[module]
        dep_data.extend(struct.pack("<IHH32s", offset, length, 0, bytes.fromhex(digest_hex)))
    sections = [
        (1, bytes(name_bytes), len(name_bytes)),
        (2, ident, 1),
        (3, bytes(dep_data), len(deps)),
    ]
    sections.extend((kind, b"", 0) for kind in range(4, 16))
    data_start = YKIF_HEADER_SIZE + len(sections) * 16
    entries = bytearray()
    body = bytearray()
    cursor = data_start
    for kind, payload, count in sections:
        entries.extend(struct.pack("<HHIII", kind, 0, cursor, len(payload), count))
        body.extend(payload)
        cursor += len(payload)
    file_size = cursor
    header = struct.pack(
        "<4sHHIHHII32s",
        YKIF_MAGIC, YKIF_FORMAT, YKIF_FLAGS, 0x00010001, len(sections), 0, YKIF_HEADER_SIZE, file_size, b"\x00" * DIGEST_SIZE
    )
    raw = bytearray(header + entries + body)
    digest = digest_zeroed(bytes(raw), YKIF_DIGEST_OFFSET)
    raw[24:56] = bytes.fromhex(digest)
    return bytes(raw), digest


def build_yksm(dep_digests, version=4, flags=None):
    """生成最小合法 YKSM；dep_digests 为按 dependency_id 排列的摘要十六进制列表。"""
    dep_data = bytearray()
    for index, digest_hex in enumerate(dep_digests):
        dep_data.extend(struct.pack("<HH32sI", index + 1, 0, bytes.fromhex(digest_hex), 0))
    sections = [(kind, b"", 0) for kind in range(1, 7)]
    sections.append((7, bytes(dep_data), len(dep_digests)))
    data_start = YKSM_HEADER_SIZE + len(sections) * 16
    entries = bytearray()
    body = bytearray()
    cursor = data_start
    for kind, payload, count in sections:
        entries.extend(struct.pack("<HHIII", kind, 0, cursor, len(payload), count))
        body.extend(payload)
        cursor += len(payload)
    file_size = cursor
    if flags is None:
        flags = 1 if version == 6 else 0
    header = struct.pack(
        "<4sHHHHIIII32sI",
        YKSM_MAGIC, version, flags, len(sections), 0x0101, YKSM_HEADER_SIZE, file_size, 0, 0, b"\x00" * DIGEST_SIZE, 0
    )
    raw = bytearray(header + entries + body)
    digest = digest_zeroed(bytes(raw), YKSM_DIGEST_OFFSET)
    raw[28:60] = bytes.fromhex(digest)
    return bytes(raw), digest


def fixture_modules_chain(root_version=4, root_flags=None):
    leaf_iface, leaf_digest = build_ykif("leaf", [])
    mid_iface, mid_digest = build_ykif("mid", [("leaf", leaf_digest)])
    root_iface, root_digest = build_ykif("root", [("mid", mid_digest), ("leaf", leaf_digest)])
    return {
        "leaf": (leaf_iface, build_yksm([])[0]),
        "mid": (mid_iface, build_yksm([leaf_digest])[0]),
        "root": (root_iface, build_yksm([mid_digest, leaf_digest], root_version, root_flags)[0]),
    }


def fixture_modules_swapped():
    a_iface, a_digest = build_ykif("a", [])
    b_iface, b_digest = build_ykif("b", [])
    root_iface, _root_digest = build_ykif("root", [("a", a_digest), ("b", b_digest)])
    return {
        "a": (a_iface, build_yksm([])[0]),
        "b": (b_iface, build_yksm([])[0]),
        # YSM 摘要按相反顺序写入；准确映射仍按 YKIF 的 a、b 顺序。
        "root": (root_iface, build_yksm([b_digest, a_digest])[0]),
    }


def fixture_modules_missing_target():
    leaf_iface, leaf_digest = build_ykif("leaf", [])
    # 依赖记录指向不存在的 ghost，但摘要等于真实 leaf；仅按摘要会误命中 leaf。
    root_iface, _root_digest = build_ykif("root", [("ghost", leaf_digest)])
    return {
        "leaf": (leaf_iface, build_yksm([])[0]),
        "root": (root_iface, build_yksm([leaf_digest])[0]),
    }


def fixture_modules_count_mismatch():
    leaf_iface, leaf_digest = build_ykif("leaf", [])
    mid_iface, mid_digest = build_ykif("mid", [("leaf", leaf_digest)])
    root_iface, _root_digest = build_ykif("root", [("mid", mid_digest), ("leaf", leaf_digest)])
    return {
        "leaf": (leaf_iface, build_yksm([])[0]),
        "mid": (mid_iface, build_yksm([leaf_digest])[0]),
        # YKIF 登记两条依赖，YSM 只发射一条。
        "root": (root_iface, build_yksm([mid_digest])[0]),
    }


def write_fixture_dir(directory, modules):
    directory = Path(directory)
    if directory.exists():
        if any(directory.iterdir()):
            raise AuditError(f"夹具目录非空：{directory}")
    else:
        directory.mkdir(parents=True)
    for root_name in ("main", "imports"):
        root_dir = directory / root_name
        root_dir.mkdir()
        for name, (iface, ysm) in modules.items():
            (root_dir / f"{name}.iface").write_bytes(iface)
            (root_dir / f"{name}.ysm").write_bytes(ysm)


def mutate_fixture(directory, kind):
    for root_name in ("main", "imports"):
        root_dir = Path(directory) / root_name
        if kind == "bad-ysm-sha":
            path = root_dir / "root.ysm"
            data = bytearray(path.read_bytes())
            data[28] ^= 0xFF
            path.write_bytes(bytes(data))
        elif kind == "bad-iface-digest":
            path = root_dir / "mid.iface"
            data = bytearray(path.read_bytes())
            data[24] ^= 0xFF
            path.write_bytes(bytes(data))
        elif kind == "truncated":
            path = root_dir / "root.ysm"
            data = path.read_bytes()
            path.write_bytes(data[:-4])
        elif kind == "no-ysm":
            (root_dir / "root.ysm").unlink()


def cmd_fixture(args):
    if args.kind in ("chain", "bad-ysm-sha", "bad-iface-digest", "truncated", "no-ysm"):
        modules = fixture_modules_chain()
    elif args.kind == "chain-v6":
        modules = fixture_modules_chain(root_version=6)
    elif args.kind == "bad-v6-flags":
        modules = fixture_modules_chain(root_version=6, root_flags=0)
    elif args.kind == "swapped":
        modules = fixture_modules_swapped()
    elif args.kind == "missing-target":
        modules = fixture_modules_missing_target()
    elif args.kind == "count-mismatch":
        modules = fixture_modules_count_mismatch()
    else:
        raise UsageError(f"未知夹具类型：{args.kind}")
    write_fixture_dir(args.dir, modules)
    if args.kind in ("bad-ysm-sha", "bad-iface-digest", "truncated", "no-ysm"):
        mutate_fixture(args.dir, args.kind)
    print(f"夹具：{args.kind} -> {args.dir}")
    return 0


def cmd_fp3(args):
    audits = []
    for spec in args.audit:
        if "=" not in spec:
            raise UsageError(f"--audit 需要 NAME=DIR 形式：{spec}")
        name, path = spec.split("=", 1)
        if not name or not path:
            raise UsageError(f"--audit 的 NAME 或 DIR 为空：{spec}")
        audits.append((name, Path(path)))
    roots = args.root or ["main", "imports"]
    report = verify_fp3(audits, roots)
    log_text = "\n".join(report["log"]) + "\n"
    if args.out_dir:
        out_dir = Path(args.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        with open(out_dir / "fp3.log", "w", encoding="utf-8", newline="\n") as handle:
            handle.write(log_text)
        with open(out_dir / "fp3.json", "w", encoding="utf-8", newline="\n") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        print(report["log"][-2])
        print(report["log"][-1])
    else:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["status"] == "ok" else 1


def cmd_name_hashes(args):
    for artifact in args.interfaces:
        result = parse_ykif(artifact)
        if result["problems"]:
            raise AuditError(f"{artifact}：" + "；".join(result["problems"]))
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description="base 自举候选 YKIF/YKSM 审计助手")
    subparsers = parser.add_subparsers(dest="command", required=True)
    fp3 = subparsers.add_parser("fp3", help="校验审计目录的 YSM 依赖摘要映射")
    fp3.add_argument("--audit", action="append", required=True, metavar="NAME=DIR", help="审计名与目录，可重复")
    fp3.add_argument("--root", action="append", metavar="NAME", help="审计根名，默认 main 与 imports，可重复")
    fp3.add_argument("--out-dir", help="写入 fp3.log 与 fp3.json 的目录")
    fp3.set_defaults(func=cmd_fp3)
    names = subparsers.add_parser("name-hashes", help="只读校验指定 YKIF 的固定名称哈希")
    names.add_argument("interfaces", nargs="+", type=Path, metavar="IFACE")
    names.set_defaults(func=cmd_name_hashes)
    fixture = subparsers.add_parser("fixture", help="生成最小合法或故意损坏的审计夹具")
    fixture.add_argument("--kind", required=True, choices=(
        "chain", "chain-v6", "bad-v6-flags", "swapped", "missing-target", "count-mismatch",
        "bad-ysm-sha", "bad-iface-digest", "truncated", "no-ysm",
    ))
    fixture.add_argument("--dir", required=True, help="夹具目录；必须不存在或为空")
    fixture.set_defaults(func=cmd_fixture)
    return parser


def main(argv):
    # Windows 管道默认使用本地代码页；统一为 UTF-8，保证 bash 端按 UTF-8 匹配日志。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except UsageError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 2
    except AuditError as exc:
        print(f"审计错误：{exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"文件错误：{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
