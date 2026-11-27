#!/usr/bin/env python3
# 核对传递名义的审计身份、直接依赖闭集和普通构建不变性。
from pathlib import Path
from struct import error as StructError, pack, unpack_from
import hashlib
import sys

from test_error_set_remap import digest, interface, require, section


def type_sigs(data, offsets, allowed_external=None):
    result = []
    externals = []
    cursor = 0

    def take(count):
        nonlocal cursor
        require(count >= 0 and cursor + count <= len(data), "TypeSig 截断")
        value = data[cursor:cursor + count]
        cursor += count
        return value

    def visit(depth=0):
        nonlocal cursor
        require(depth <= 64, "TypeSig 嵌套过深")
        start = cursor
        opcode = take(1)[0]
        if opcode == 1:
            take(4)
        elif opcode == 2:
            take(6)
        elif opcode == 3:
            take(8)
        elif opcode == 4:
            take(2)
        elif opcode == 5:
            take(8)
            visit(depth + 1)
        elif opcode == 6:
            visit(depth + 1)
        elif opcode in (7, 8):
            take(1)
            visit(depth + 1)
        elif opcode == 9:
            count = unpack_from("<H", take(2))[0]
            for _ in range(count + 1):
                visit(depth + 1)
        elif opcode == 10:
            visit(depth + 1)
            count = unpack_from("<I", take(4))[0]
            for _ in range(count):
                visit(depth + 1)
        elif opcode == 11:
            visit(depth + 1)
        elif opcode in (12, 13):
            count = unpack_from("<I", take(4))[0]
            for _ in range(count):
                visit(depth + 1)
        elif opcode == 14:
            take(4)
            take(1)
            argc = unpack_from("<H", take(2))[0]
            for _ in range(argc):
                visit(depth + 1)
        elif opcode == 15:
            target = take(32)
            kind = take(1)[0]
            export_id = unpack_from("<I", take(4))[0]
            argc = unpack_from("<H", take(2))[0]
            identity = (target, kind, export_id)
            externals.append(identity)
            require(allowed_external is not None and identity in allowed_external,
                    "TypeSig 含未由声明接口绑定的外部名义")
            for _ in range(argc):
                visit(depth + 1)
        else:
            raise ValueError(f"未知 TypeSig opcode {opcode}")
        if depth == 0:
            result.append(data[start:cursor])

    for offset in offsets:
        require(offset < len(data), "TypeSig 偏移越界")
        cursor = offset
        visit()
    return result, externals


def image(path, expected_dependencies, allow_external, expected_identity=None):
    data = path.read_bytes()
    require(data.startswith(b"YKMI"), f"{path} 不是 YSM")
    version, flags = unpack_from("<HH", data, 4)
    if allow_external:
        require(version == 6 and flags == 1, f"{path} 不是传递名义所需的 YSM format 6")
    else:
        require(version in (4, 5, 6) and flags == (1 if version == 6 else 0),
                f"{path} 的 YSM 版本或标记无效")
    digest(data, 28)
    types, _ = section(data, 64, 1)
    statics, static_count = section(data, 64, 2)
    functions, function_count = section(data, 64, 3)
    locals_, local_count = section(data, 64, 4)
    require(len(statics) >= 16 * static_count and len(functions) == 32 * function_count and
            len(locals_) == 16 * local_count, f"{path} 的记录长度不符")
    require(unpack_from("<HHIIII", data, 8) ==
            (7, 0x0101, 64, len(data), function_count, static_count) and data[60:64] == bytes(4),
            f"{path} 的头部或记录数与节目录不符")
    for index in range(static_count):
        static_index, _, byte_offset, byte_length = unpack_from("<4I", statics, 16 * index)
        require(static_index == index and 16 * static_count + byte_offset + byte_length <= len(statics),
                f"{path} 的静态记录序号或字节区间无效")
    for index in range(function_count):
        record = functions[32 * index:32 * (index + 1)]
        _, _, local_start, local_length = unpack_from("<4I", record)
        flags, reserved = unpack_from("<HH", record, 28)
        require(local_start + local_length <= local_count and flags & ~3 == 0 and reserved == 0,
                f"{path} 的函数局部区间或保留字段无效")
    for index in range(local_count):
        record = locals_[16 * index:16 * (index + 1)]
        require(record[4] <= 3 and record[6:] == bytes(10), f"{path} 的局部记录保留字段无效")
    function_offsets = [unpack_from("<I", functions, 32 * index + 4)[0]
                        for index in range(function_count)]
    type_offsets = [unpack_from("<I", statics, 16 * index + 4)[0]
                    for index in range(static_count)]
    type_offsets += [unpack_from("<I", locals_, 16 * index)[0]
                     for index in range(local_count)]
    records, count = section(data, 64, 7)
    require(len(records) == 40 * count and count == len(expected_dependencies),
            f"{path} 的直接依赖数不符")
    actual = [unpack_from("<HH32sI", records, 40 * index) for index in range(count)]
    require(actual == [(index, 0, target, 0)
                       for index, target in enumerate(expected_dependencies, 1)],
            f"{path} 的直接依赖编号或摘要不符")
    allowed = None
    if allow_external:
        allowed = {(expected_identity[0], expected_identity[1][0], expected_identity[1][1])}
    signatures, externals = type_sigs(types, type_offsets, allowed)
    for offset in function_offsets:
        require(offset + 4 <= len(types), f"{path} 的函数签名偏移越界")
        parameter_count = unpack_from("<H", types, offset + 2)[0]
        cursor = offset + 4
        function_types = []
        for _ in range(parameter_count + 1):
            # 函数头之后的参数与返回类型仍用同一递归 TypeSig 文法。
            parsed, nested = type_sigs(types[cursor:], [0], allowed)
            require(len(parsed) == 1, f"{path} 的函数签名无效")
            function_types.extend(parsed)
            externals.extend(nested)
            cursor += len(parsed[0])
        signatures.extend(function_types)
    if allow_external:
        require(externals, f"{path} 缺少所需的外部名义")
    return signatures


def check(audited, plain):
    dep, mid, root = "imported_struct_dep", "imported_members_mid", "imported_members_transitive"
    dep_digest, dep_refs, dep_exports = interface(audited / (dep + ".iface"))
    mid_digest, mid_refs, _ = interface(audited / (mid + ".iface"))
    _, root_refs, _ = interface(audited / (root + ".iface"))
    require(dep_refs == [] and mid_refs == [(dep, dep_digest)] and root_refs == [(mid, mid_digest)],
            "传递名义扩大了接口直接依赖闭集")
    pair_kind, pair_id, _ = dep_exports["Pair"]
    expected = b"\x0f" + dep_digest + bytes((pair_kind,)) + pack("<IH", pair_id, 0)
    signatures = image(audited / (root + ".ysm"), [mid_digest], True,
                       (dep_digest, (pair_kind, pair_id)))
    require(signatures.count(expected) >= 1, "根 YSM 缺少与声明接口绑定的 Pair 传递名义")
    image(audited / (dep + ".ysm"), [], False)
    image(audited / (mid + ".ysm"), [dep_digest], False)
    for module in (dep, mid, root):
        for suffix in (".iface", ".obj"):
            require((audited / (module + suffix)).read_bytes() == (plain / (module + suffix)).read_bytes(),
                    f"{module}{suffix} 因审计开关发生变化")
        require(not (plain / (module + ".ysm")).exists(), f"普通构建产生了 {module}.ysm")
    print("传递名义 YSM：声明摘要、导出身份、直接依赖与普通产物均一致")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("用法：test_ysm_transitive_nominal.py 审计产物目录 普通产物目录")
    try:
        check(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, KeyError, StructError) as exc:
        sys.exit(f"错误：{exc}")
