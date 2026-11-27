#!/usr/bin/env python3
"""按诊断协议与符号域宽度核对非空的拒绝用例 JSONL。"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


FIELDS = {"unit", "code", "severity", "span", "refs", "args"}
REF_WIDTHS = {"def": 32, "builtin": 16, "field": 16, "variant": 16, "local": 32}
SEVERITIES = ("error", "warning", "info")
HOST_KEYS = {"absolutepath", "abspath", "host", "hostpath", "hostpointer", "pointer",
             "time", "timestamp"}
ABSOLUTE = re.compile(r"^(?:[A-Za-z]:[\\/]|[/\\]|file:/)", re.IGNORECASE)


class Failure(ValueError):
    """诊断不符合门禁断言。"""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def unsigned(value: object, width: int) -> bool:
    return type(value) is int and 0 <= value < 1 << width


def object_fields(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        require(key not in result, f"重复 JSON 字段 {key!r}")
        result[key] = value
    return result


def reject_constant(value: str) -> None:
    raise Failure(f"非法 JSON 常量 {value}")


def check_args(value: object) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = re.sub(r"[^a-z]", "", key.lower())
            require(normalized not in HOST_KEYS and not ABSOLUTE.match(key),
                    f"参数含宿主字段 {key!r}")
            check_args(child)
    elif isinstance(value, list):
        for child in value:
            check_args(child)
    elif isinstance(value, str):
        require(not ABSOLUTE.match(value), "参数含绝对路径")


def check_ref(ref: object) -> None:
    require(isinstance(ref, dict) and ref.keys() == {"kind", "id"}, "引用必须只含 kind/id")
    kind, identity = ref["kind"], ref["id"]
    if kind == "import":
        require(isinstance(identity, list) and len(identity) == 2 and
                unsigned(identity[0], 16) and unsigned(identity[1], 32),
                "ImportRef 必须是 [u16 依赖序号, u32 导出序号]")
    else:
        require(isinstance(kind, str) and kind in REF_WIDTHS, f"不允许的引用域 {kind!r}")
        require(unsigned(identity, REF_WIDTHS[kind]), f"引用 {kind} 超出其整数域")


def check_line(row: object) -> tuple[int, int]:
    require(isinstance(row, dict) and row.keys() == FIELDS, "诊断字段集合不符")
    unit = row["unit"]
    require(isinstance(unit, str) and unit != "" and
            not any(char in unit for char in ("/", "\\", "\x00")) and
            not re.match(r"^[A-Za-z]:(?!:)", unit), "unit 必须是单元模块名，不能是宿主路径")
    code = row["code"]
    require(unsigned(code, 16), "code 必须是 u16")
    require(row["severity"] in SEVERITIES, "未知诊断级别")
    span = row["span"]
    require(isinstance(span, dict) and span.keys() == {"off", "len"}, "span 必须只含 off/len")
    require(all(type(span[k]) is int and span[k] >= 0 for k in ("off", "len")),
            "span 必须是非负字节偏移和长度")
    require(isinstance(row["refs"], list), "refs 必须是数组")
    for ref in row["refs"]:
        check_ref(ref)
    require(isinstance(row["args"], dict), "args 必须是对象")
    check_args(row["args"])
    return span["off"], code


def parse_jsonl(raw: bytes) -> list[dict[str, object]]:
    require(bool(raw) and raw.endswith(b"\n") and b"\r" not in raw,
            "拒绝用例必须输出非空的 LF 结尾 JSONL")
    rows = []
    previous: tuple[int, int] | None = None
    for number, line in enumerate(raw[:-1].decode("utf-8").split("\n"), 1):
        try:
            row = json.loads(line, object_pairs_hook=object_fields, parse_constant=reject_constant)
            key = check_line(row)
            require(previous is None or previous <= key, "诊断未按 (off, code) 升序")
        except (ValueError, RecursionError) as exc:
            raise Failure(f"第 {number} 行：{exc}") from exc
        previous = key
        rows.append(row)
    return rows


def check_duplicate_decl(rows: list[dict[str, object]], unit: str) -> None:
    # 精确核对该拒绝源的可观察内容；数字形状本身不能证明引用身份正确。
    require([row["code"] for row in rows] == [4009, 4001, 4009], "重复声明诊断序列不符")
    for row in rows:
        require(row["unit"] == unit and row["severity"] == "error" and row["args"] == {},
                "重复声明夹具的模块名、级别或参数不符")
    require(rows[0]["refs"] == rows[2]["refs"] == [], "非重复声明行带有非预期引用")
    # 该夹具的定义表顺序是 main、首个 x、第二个 x；引用顺序必须为旧定义、新定义。
    require(rows[1]["refs"] == [{"kind": "def", "id": 2}, {"kind": "def", "id": 3}],
            "重复声明必须按旧、新顺序引用 DefId 2、3")
    require([row["span"] for row in rows] ==
            [{"off": 184, "len": 0}, {"off": 207, "len": 18}, {"off": 207, "len": 0}],
            "重复声明夹具的诊断偏移或长度不符")


def check_arm_collision(rows: list[dict[str, object]], unit: str) -> None:
    require(len(rows) == 1 and rows[0]["code"] == 4010, "同臂重名必须只产生 E4010")
    row = rows[0]
    require(row["unit"] == unit and row["severity"] == "error" and row["args"] == {},
            "同臂重名夹具的模块名、级别或参数不符")
    # 模式载荷先入定义表，被拒局部随后预留；诊断指向完整的局部声明。
    require(row["refs"] == [{"kind": "def", "id": 5}, {"kind": "def", "id": 6}],
            "同臂重名必须依次引用载荷 DefId 5、被拒局部 DefId 6")
    require(row["span"] == {"off": 353, "len": 22}, "同臂重名夹具的诊断偏移或长度不符")


def main() -> None:
    parser = argparse.ArgumentParser(description="诊断 JSONL 协议契约检查")
    parser.add_argument("--jsonl", action="append", required=True, type=Path, help="拒绝用例的诊断文件")
    case = parser.add_mutually_exclusive_group()
    case.add_argument("--duplicate-decl-unit", metavar="MODULE", help="校验指定模块的重复声明夹具")
    case.add_argument("--arm-collision-unit", metavar="MODULE", help="校验指定模块的同臂重名夹具")
    args = parser.parse_args()
    for path in args.jsonl:
        try:
            rows = parse_jsonl(path.read_bytes())
            if args.duplicate_decl_unit is not None:
                check_duplicate_decl(rows, args.duplicate_decl_unit)
            elif args.arm_collision_unit is not None:
                check_arm_collision(rows, args.arm_collision_unit)
        except (OSError, ValueError) as exc:
            parser.exit(1, f"错误：{path}：{exc}\n")
    print("诊断 JSONL：字段、引用域、宿主信息和排序断言通过")


if __name__ == "__main__":
    main()
