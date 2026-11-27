#!/usr/bin/env python3
# 核对三单元夹具的接口错误集与镜像依赖绑定，不代替编译器格式校验。
from hashlib import sha256
from pathlib import Path
from struct import error as StructError, pack, unpack_from
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def section(data, header, kind):
    actual, flags, start, length, count = unpack_from("<HHIII", data, header + 16 * (kind - 1))
    require(actual == kind and flags == 0 and start + length <= len(data), f"节 {kind} 无效")
    return data[start:start + length], count


def digest(data, offset):
    recorded = data[offset:offset + 32]
    require(recorded == sha256(data[:offset] + bytes(32) + data[offset + 32:]).digest(), "产物摘要无效")
    return recorded


def interface(path):
    data = path.read_bytes()
    require(data.startswith(b"YKIF\x02\x00"), f"{path} 不是 YKIF format 2")
    names, _ = section(data, 56, 1)
    deps, ndeps = section(data, 56, 3)
    exports, nexports = section(data, 56, 4)
    types, _ = section(data, 56, 5)
    require(len(deps) == 40 * ndeps and len(exports) == 32 * nexports, "接口记录长度不符")

    def name(off, length):
        require(length > 0 and off + length <= len(names), "接口名称越界")
        return names[off:off + length].decode("ascii")

    references = []
    for row in range(ndeps):
        off, length, flags, target = unpack_from("<IHH32s", deps, 40 * row)
        require(flags == 0, "接口依赖标记无效")
        references.append((name(off, length), target))
    exported = {}
    for row in range(nexports):
        off, length, kind, _, _, ident, sigoff, siglen, _ = unpack_from("<IHBBQIIII", exports, 32 * row)
        require(ident == row + 1 and sigoff + siglen <= len(types), "接口导出编号或签名无效")
        symbol = name(off, length)
        require(symbol not in exported, "夹具导出名重复")
        exported[symbol] = kind, ident, types[sigoff:sigoff + siglen]
    return digest(data, 24), references, exported


def image(path, expected):
    data = path.read_bytes()
    require(data.startswith(b"YKMI\x04\x00"), f"{path} 不是 YSM format 4")
    digest(data, 28)
    records, count = section(data, 64, 7)
    require(len(records) == 40 * count and count == len(expected), "YSM 依赖数不符")
    actual = [unpack_from("<HH32sI", records, 40 * index) for index in range(count)]
    require(actual == [(index, 0, target, 0) for index, (_, target) in enumerate(expected, 1)],
            f"{path} 的 YSM 依赖编号或摘要不符")


def builtin(ident):
    return pack("<BHH", 1, ident, 0)


def nominal(dep, ident):
    if dep == 0:
        return pack("<BIH", 2, ident, 0)
    return pack("<BHIH", 3, dep, ident, 0)


def fallible(success, errors):
    # 非泛型、一个 u32 参数、可错返回。
    return pack("<HH", 0, 1) + builtin(0x1003) + b"\x0a" + builtin(success) + pack("<I", len(errors)) + b"".join(errors)


def check(directory):
    dep, mid, root = ("imported_errors_dep", "imported_errors_mid", "imported_errors_remap")
    dep_digest, dep_refs, dep_exports = interface(directory / (dep + ".iface"))
    mid_digest, mid_refs, mid_exports = interface(directory / (mid + ".iface"))
    _, root_refs, root_exports = interface(directory / (root + ".iface"))
    require(dep_refs == [] and mid_refs == [(dep, dep_digest)] and
            root_refs == [(mid, mid_digest), (dep, dep_digest)], "底层模块没有从依赖编号 1 重映射到 2")
    z, width = dep_exports["Z"], dep_exports["Widthy"]
    require(z[0] == width[0] == 2 and z[1] > width[1], "夹具的导出编号未与规范错误身份顺序形成反差")
    for symbols, func, index, success, prefix in (
        (dep_exports, "value", 0, 0x1003, []),
        (mid_exports, "relay", 1, 0x1003, []),
        (root_exports, "widen", 2, 0x100B, [builtin(0x100C)]),
    ):
        kind, _, sig = symbols[func]
        require(kind == 1 and sig == fallible(success, prefix + [nominal(index, z[1]), nominal(index, width[1])]),
                f"{func} 的错误集规范顺序、依赖编号或枚举身份不符")
    # 同名、同形枚举仍按声明模块区分；依赖 2 的两个成员必须排在依赖 1 前。
    mid_z = mid_exports["Z"]
    kind, _, sig = root_exports["mixed"]
    require(mid_z[0] == 2 and kind == 1 and
            sig == fallible(0x1003, [nominal(2, z[1]), nominal(2, width[1]), nominal(1, mid_z[1])]),
            "mixed 的同名枚举身份合并或按依赖编号误排序")
    for module, refs in ((dep, dep_refs), (mid, mid_refs), (root, root_refs)):
        image(directory / (module + ".ysm"), refs)
    print("ErrorSet 接口和 YSM：底层依赖 1→2，两个声明模块的同名枚举保持独立")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("用法：test_error_set_remap.py 产物目录")
    try:
        check(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, StructError) as exc:
        sys.exit(f"错误：{exc}")
