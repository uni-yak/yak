"""只读校验 Yak Win64 的 COFF 对象、链接重定位和运行期符号边界。"""
import argparse
from collections import Counter
import hashlib
import os
from pathlib import Path
import re
import struct
import sys


COFF_HEADER_SIZE = 20
SECTION_HEADER_SIZE = 40
SECTION_FLAGS = {b".text": 0x60000020, b".rdata": 0x40000040, b".data": 0xC0000040}
SECTION_TABLE_END = COFF_HEADER_SIZE + len(SECTION_FLAGS) * SECTION_HEADER_SIZE
SYMBOL_SIZE = 18
RELOCATION = struct.Struct("<IIH")
ADDR64 = 0x0001
ADDR32NB = 0x0003
REL32 = 0x0004
RELOCATION_WIDTHS = {ADDR64: 8, ADDR32NB: 4, REL32: 4}
MAP_SECTION = re.compile(rb"^[ \t]+(\.(?:text|rdata|data))[ \t]+(0x[0-9a-fA-F]+)[ \t]+(0x[0-9a-fA-F]+)[ \t]+(.+)$")
MAP_SYMBOL = re.compile(rb"^[ \t]+(0x[0-9a-fA-F]+)[ \t]+(\S+)[ \t]*$")
# 和 runtime/src/win/runtime.c 的平台服务声明保持一致。
RUNTIME_IMPORTS = frozenset((
    b"ExitProcess", b"GetLastError", b"GetProcessHeap", b"GetStdHandle",
    b"HeapAlloc", b"HeapFree", b"ReadFile", b"WriteFile",
))
SYMBOL_LOOKUP = (b"GetProcAddress", b"LdrGetProcedureAddress", b"SymFrom", b"SymGet", b"SymInitialize")
SYMBOL_CONTAINER = struct.Struct("<4sHHIHHII")
SYMBOL_SECTION = struct.Struct("<HHIII")


class CoffSectionError(ValueError):
    """对象的节名或属性违反 PE-2。"""


class CoffRelocationError(ValueError):
    """对象的重定位类型、字段宽度或可判定的加数违反 PE-3。"""


class CoffSymbolOrderError(ValueError):
    """已知符号集合的链接顺序违反 PE-4。"""


class RuntimeSymbolError(ValueError):
    """发布产物违反运行期符号边界。"""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def check_coff_sections(header: bytes) -> None:
    """只检查 AMD64 COFF 文件头与节表，不读取节数据或最终 PE。"""
    if len(header) < COFF_HEADER_SIZE:
        raise ValueError("COFF 文件头截断")
    machine, count = struct.unpack_from("<HH", header)
    optional_header_size, = struct.unpack_from("<H", header, 16)
    if machine != 0x8664 or optional_header_size != 0:
        raise ValueError("不是 Yak Win64 AMD64 COFF 对象")
    if count != len(SECTION_FLAGS):
        raise CoffSectionError(f"节数 {count}，应为 {len(SECTION_FLAGS)}")
    if len(header) < SECTION_TABLE_END:
        raise ValueError("COFF 节表截断")

    seen = set()
    for offset in range(COFF_HEADER_SIZE, SECTION_TABLE_END, SECTION_HEADER_SIZE):
        name = header[offset:offset + 8].rstrip(b"\0")
        expected = SECTION_FLAGS.get(name)
        if expected is None:
            raise CoffSectionError(f"未知节名 {name!r}")
        if name in seen:
            raise CoffSectionError(f"重复节名 {name!r}")
        seen.add(name)
        flags, = struct.unpack_from("<I", header, offset + 36)
        if flags != expected:
            raise CoffSectionError(f"节 {name!r} 属性 {flags:#010x}，应为 {expected:#010x}")


def iter_coff_relocations(image: bytes):
    """验证重定位记录并交出在对象中的位置。"""
    check_coff_sections(image)
    symtab, symbols = struct.unpack_from("<II", image, 8)
    for section, offset in enumerate(range(COFF_HEADER_SIZE, SECTION_TABLE_END, SECTION_HEADER_SIZE), 1):
        count, = struct.unpack_from("<H", image, offset + 32)
        if not count:
            continue
        name = image[offset:offset + 8].rstrip(b"\0")
        virtual, size, raw, table = struct.unpack_from("<IIII", image, offset + 12)
        end = table + count * RELOCATION.size
        if raw < SECTION_TABLE_END or raw + size > len(image):
            raise ValueError(f"节 {name!r} 原始数据超出对象")
        if table < SECTION_TABLE_END or end > len(image):
            raise ValueError(f"节 {name!r} 重定位表超出对象")
        if symtab < SECTION_TABLE_END or symtab + symbols * SYMBOL_SIZE > len(image):
            raise ValueError("COFF 符号表超出对象")
        records = RELOCATION.iter_unpack(memoryview(image)[table:end])
        for number, (address, symbol, kind) in enumerate(records, 1):
            context = f"节 {name!r} 重定位 {number}"
            width = RELOCATION_WIDTHS.get(kind)
            if width is None:
                raise CoffRelocationError(f"{context} 类型 {kind:#06x} 不受支持")
            site = address - virtual
            if site < 0 or site + width > size:
                raise CoffRelocationError(f"{context} 的 {width} 字节字段超出节范围（偏移 {site}，节长 {size}）")
            if symbol >= symbols:
                raise ValueError(f"{context} 的符号下标 {symbol} 超出符号表")
            yield section, name, context, site, raw + site, kind, symtab + symbol * SYMBOL_SIZE


def check_coff_relocations(image: bytes) -> bool:
    """检查对象内可判定的重定位，并报告是否需要最终绝对地址校验。"""
    absolute = False
    for section, _, context, site, field, kind, symbol in iter_coff_relocations(image):
        if kind != REL32:
            absolute = True
            continue
        value, target = struct.unpack_from("<Ih", image, symbol + 8)
        if target == section:
            # 同节的链接基址相消；字段内加数和最终位移均为有符号 32 位。
            addend, = struct.unpack_from("<i", image, field)
            delta = value + addend - (site + 4)
            if not -(1 << 31) <= delta < (1 << 31):
                raise CoffRelocationError(f"{context} 的同节 REL32 加数使位移 {delta} 超出 32 位有符号范围")
    return absolute


def check_linked_absolute_relocation(kind: int, target_va: int, image_base: int, addend: int, value: int) -> None:
    """按最终地址与已知语义加数核对绝对重定位，不使用链接器截断后的值判范围。"""
    if kind == ADDR64:
        origin = target_va
    elif kind == ADDR32NB:
        origin = target_va - image_base
    else:
        raise ValueError("只支持 ADDR64 与 ADDR32NB 的最终地址核对")
    expected = origin + addend
    width = RELOCATION_WIDTHS[kind] * 8
    if not 0 <= expected < 1 << width:
        raise CoffRelocationError(f"绝对重定位结果 {expected} 超出 {width} 位无符号范围")
    if value != expected:
        raise CoffRelocationError(f"绝对重定位读回 {value}，应为 {expected}")


def coff_string_range(image):
    symtab, count = struct.unpack_from("<II", image, 8)
    strings = symtab + count * SYMBOL_SIZE
    if symtab < SECTION_TABLE_END or strings + 4 > len(image):
        raise ValueError("COFF 符号表或字符串表头超出对象")
    size, = struct.unpack_from("<I", image, strings)
    end = strings + size
    if size < 4 or end > len(image):
        raise ValueError("COFF 字符串表长度无效")

    return symtab, strings, end


def coff_symbol_name(image, at, strings, end):
    name = image[at:at + 8]
    if name[:4] == b"\0\0\0\0":
        offset, = struct.unpack_from("<I", name, 4)
        if not 4 <= offset < end - strings or (offset > 4 and image[strings + offset - 1] != 0):
            raise ValueError("COFF 符号长名偏移无效")
        first = strings + offset
        stop = image.find(b"\0", first, end)
        if stop <= first:
            raise ValueError("COFF 符号长名为空或未终止")
        return image[first:stop]
    return name.rstrip(b"\0")


def check_coff_symbol_order(image: bytes, expected: list[bytes]) -> None:
    """使用独立夹具给定的完整链接顺序；COFF 名称本身不携带 LinkId。"""
    check_coff_sections(image)
    symtab, strings, end = coff_string_range(image)
    names = []
    for at in range(symtab, strings, SYMBOL_SIZE):
        if image[at + 17] != 0:
            raise ValueError("Yak COFF 符号不应含辅助记录")
        names.append(coff_symbol_name(image, at, strings, end))

    if Counter(names) != Counter(expected):
        raise ValueError("COFF 符号集合与夹具给定的完整预期不符")
    for index, (actual, wanted) in enumerate(zip(names, expected), 1):
        if actual != wanted:
            raise CoffSymbolOrderError(f"符号 {index} 为 {actual!r}，应为 {wanted!r}")


def object_identity(path):
    # GNU ld 的映射可使用斜杠或反斜杠，并可保留带空格的相对路径。
    return os.path.normcase(os.path.abspath(path))


def read_link_map(data, objects):
    """只取实际链接地址，保留重名和重复映射供调用方检查。"""
    sections = {}
    symbols = {}
    for line in data.splitlines():
        match = MAP_SECTION.fullmatch(line)
        if match:
            name, address, size, filename = match.groups()
            identity = object_identity(os.fsdecode(filename.rstrip()))
            if identity in objects:
                sections.setdefault((identity, name), set()).add((int(address, 16), int(size, 16)))
            continue
        match = MAP_SYMBOL.fullmatch(line)
        if match:
            address, name = match.groups()
            symbols.setdefault(name, set()).add(int(address, 16))
    return sections, symbols


def pe_layout(image):
    """取得 AMD64 PE 头、可选头长度、映像基址和节中的文件可读范围。"""
    if len(image) < 64 or image[:2] != b"MZ":
        raise ValueError("最终映像缺少 DOS 头")
    pe, = struct.unpack_from("<I", image, 60)
    if pe < 64 or pe + 24 > len(image) or image[pe:pe + 4] != b"PE\0\0":
        raise ValueError("最终映像 PE 头无效")
    machine, count = struct.unpack_from("<HH", image, pe + 4)
    opt_size, = struct.unpack_from("<H", image, pe + 20)
    opt = pe + 24
    first = opt + opt_size
    if machine != 0x8664 or opt_size < 112 or not 1 <= count <= 96 or first + 40 * count > len(image):
        raise ValueError("最终映像 AMD64 节表无效")
    if struct.unpack_from("<H", image, opt)[0] != 0x20B:
        raise ValueError("最终映像不是 PE32+")
    base, = struct.unpack_from("<Q", image, opt + 24)
    spans = []
    for entry in range(first, first + 40 * count, 40):
        virtual, rva, size, raw = struct.unpack_from("<IIII", image, entry + 8)
        if raw + size > len(image):
            raise ValueError("最终映像节数据越界")
        if virtual and size:
            spans.append((base + rva, min(virtual, size), raw))
    return pe, opt_size, base, spans


def pe_address_sections(image):
    _, _, base, spans = pe_layout(image)
    return base, spans


def reject_symbol_containers(image):
    """完整容器同时具备已登记的头、节边界与摘要；普通字面量无需特殊处理。"""
    formats = ((b"YKIF", 1, 0x00010001, 1, (1, 8, 40, 32, 1, 16, 16, 32, 8, 16, 1, 16, 32, 8, 16)),
               (b"YKSM", 0, 0, 0x101, (1, 16, 20, 20, 12, 4)))
    for magic, flags, profile, first, sizes in formats:
        cursor = 0
        while (offset := image.find(magic, cursor)) >= 0:
            cursor = offset + len(magic)
            start = 56 + SYMBOL_SECTION.size * len(sizes)
            if offset + start > len(image):
                break
            _, version, header_flags, target, count, reserved, directory, total = SYMBOL_CONTAINER.unpack_from(image, offset)
            if (version, header_flags, target, count, reserved, directory) != (2, flags, profile, len(sizes), 0, 56):
                continue
            if not start <= total <= len(image) - offset:
                continue
            ranges = []
            for i, width in enumerate(sizes):
                kind, section_flags, at, size, rows = SYMBOL_SECTION.unpack_from(image, offset + 56 + i * SYMBOL_SECTION.size)
                if (kind != first + i or section_flags or at < start or at + size > total or size != rows * width
                        or (magic == b"YKIF" and i == 1 and rows != 1)):
                    break
                if size:
                    ranges.append((at, at + size))
            else:
                end = start
                for at, stop in sorted(ranges):
                    if at < end:
                        break
                    end = stop
                else:
                    digest = hashlib.sha256(image[offset:offset + 24])
                    digest.update(bytes(32))
                    digest.update(memoryview(image)[offset + 56:offset + total])
                    if digest.digest() == image[offset + 24:offset + 56]:
                        raise RuntimeSymbolError("E7007", f"产物内嵌完整 {magic.decode('ascii')} 容器")


def pe_file_span(spans, address, width):
    matches = [(raw + address - start, raw + size) for start, size, raw in spans
               if start <= address and address + width <= start + size]
    if len(matches) != 1:
        raise ValueError("PE 导入表引用不在唯一的文件节内")
    return matches[0]


def pe_import_name(image, spans, address, skip=0):
    start, limit = pe_file_span(spans, address, skip + 1)
    start += skip
    end = image.find(b"\0", start, limit)
    if end <= start or not image[start:end].isascii():
        raise ValueError("PE 导入名称无有效终止符或不是 ASCII")
    return image[start:end]


def check_pe_imports(image, spans, base, address, size, delayed):
    record = struct.Struct("<8I" if delayed else "<5I")
    at, _ = pe_file_span(spans, address, size)
    stop = at + size
    while at + record.size <= stop:
        fields = record.unpack_from(image, at)
        if not any(fields):
            return
        at += record.size
        if delayed:
            attributes, name_address, _, iat, lookup, *_ = fields
            if attributes != 1:
                raise RuntimeSymbolError("E7007", "发布映像含非 RVA 延迟导入")
        else:
            lookup, _, _, name_address, iat = fields
        if not name_address or not iat:
            raise ValueError("PE 导入项缺少名称或地址表")
        library = pe_import_name(image, spans, base + name_address).lower()
        if library in (b"dbghelp.dll", b"imagehlp.dll"):
            raise RuntimeSymbolError("E7008", f"发布映像依赖运行期符号查询库 {library!r}")
        if library.endswith((b".sym", b".iface")):
            raise RuntimeSymbolError("E7007", f"发布映像依赖未登记的运行期模块 {library!r}")
        entry, limit = pe_file_span(spans, base + (lookup or iat), 8)
        while entry + 8 <= limit:
            thunk, = struct.unpack_from("<Q", image, entry)
            if not thunk:
                break
            if thunk >> 31:
                raise RuntimeSymbolError("E7007", "发布映像含未经登记的序号导入")
            name = pe_import_name(image, spans, base + thunk, skip=2)
            if name.startswith(SYMBOL_LOOKUP):
                raise RuntimeSymbolError("E7008", f"发布映像导入运行期符号查询入口 {name!r}")
            if library == b"kernel32.dll" and name not in RUNTIME_IMPORTS:
                raise RuntimeSymbolError("E7007", f"发布映像导入未登记的运行期服务 {name!r}")
            entry += 8
        else:
            raise ValueError("PE 导入地址表缺少终止项")
        if library != b"kernel32.dll":
            raise RuntimeSymbolError("E7007", f"发布映像依赖未登记的运行期模块 {library!r}")
        if delayed:
            raise RuntimeSymbolError("E7007", "发布映像含延迟加载的运行期依赖")
    raise ValueError("PE 导入目录缺少终止项")


def check_runtime_pe(image):
    pe, opt_size, base, spans = pe_layout(image)
    if any(struct.unpack_from("<II", image, pe + 12)):
        raise RuntimeSymbolError("E7008", "发布映像仍携带 COFF 符号表")
    opt = pe + 24
    count, = struct.unpack_from("<I", image, opt + 108)
    if count > (opt_size - 112) // 8:
        raise ValueError("PE 数据目录超出可选头")
    for index in (1, 13):
        if index >= count:
            continue
        rva, size = struct.unpack_from("<II", image, opt + 112 + 8 * index)
        if bool(rva) != bool(size):
            raise ValueError("PE 导入目录地址与大小不一致")
        if rva:
            check_pe_imports(image, spans, base, base + rva, size, delayed=index == 13)
    reject_symbol_containers(image)


def checked_linked_value(image, spans, address, width):
    offsets = [raw + address - start for start, size, raw in spans
               if start <= address and address + width <= start + size]
    if len(offsets) != 1:
        raise CoffRelocationError("重定位站点在最终映像中缺失或不唯一")
    return int.from_bytes(image[offsets[0]:offsets[0] + width], "little")


def verify_linked_relocations(paths, exe, map_path):
    """按输入节贡献定位站点，以实际符号地址独立复算绝对重定位。"""
    image = exe.read_bytes()
    base, spans = pe_address_sections(image)
    contributions, symbols = read_link_map(map_path.read_bytes(), {object_identity(path) for path in paths})
    for path in paths:
        source = path.read_bytes()
        identity = object_identity(path)
        for _, name, context, site, field, kind, symbol in iter_coff_relocations(source):
            if kind == REL32:
                continue
            try:
                width = RELOCATION_WIDTHS[kind]
                locations = contributions.get((identity, name), ())
                if len(locations) != 1:
                    raise CoffRelocationError("重定位所在输入节的最终地址缺失或不唯一")
                address, length = next(iter(locations))
                if site + width > length:
                    raise CoffRelocationError("重定位站点越过链接后的输入节贡献")
                value = checked_linked_value(image, spans, address + site, width)
                offset, section = struct.unpack_from("<Ih", source, symbol + 8)
                if 1 <= section <= len(SECTION_FLAGS):
                    header = COFF_HEADER_SIZE + (section - 1) * SECTION_HEADER_SIZE
                    section_name = source[header:header + 8].rstrip(b"\0")
                    choices = contributions.get((identity, section_name), ())
                    if len(choices) != 1:
                        raise CoffRelocationError("局部目标所在输入节的地址缺失或不唯一")
                    target, length = next(iter(choices))
                    if offset > length:
                        raise CoffRelocationError("局部目标超出链接后的输入节贡献")
                    target += offset
                elif section == 0 and offset == 0 and source[symbol + 16] == 2:
                    _, strings, end = coff_string_range(source)
                    target_name = coff_symbol_name(source, symbol, strings, end)
                    choices = symbols.get(target_name, ())
                    if len(choices) != 1:
                        raise CoffRelocationError(f"外部目标 {target_name!r} 的最终地址缺失或不唯一")
                    target = next(iter(choices))
                else:
                    raise CoffRelocationError("绝对重定位目标不是已定义符号或外部引用")
                # COFF 节内保存二补码隐式加数。复算使用无截断的整数运算。
                addend = int.from_bytes(source[field:field + width], "little", signed=True)
                check_linked_absolute_relocation(kind, target, base, addend, value)
            except ValueError as error:
                raise CoffRelocationError(f"{path} {context}：{error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--relocations", action="store_true", help="同时检查对象内可判定的重定位")
    parser.add_argument("--symbol-order", action="append", metavar="SYMBOL",
                        help="按预期顺序重复指定一个对象的全部符号")
    parser.add_argument("--link-plan", action="store_true", help="校验对象并输出是否需要最终地址核对")
    parser.add_argument("--linked-pe", type=Path, metavar="EXE", help="校验暂存 PE 的最终绝对重定位")
    parser.add_argument("--link-map", type=Path, metavar="MAP", help="同次 GNU ld 链接产生的映射")
    parser.add_argument("--runtime-pe", action="store_true", help="检查待发布 PE 的运行期符号边界")
    parser.add_argument("objects", nargs="+", type=Path, metavar="OBJ")
    args = parser.parse_args()
    if args.symbol_order and len(args.objects) != 1:
        parser.error("--symbol-order 只接受一个待校验对象")
    if bool(args.linked_pe) != bool(args.link_map):
        parser.error("--linked-pe 与 --link-map 必须成对提供")
    if args.runtime_pe:
        if len(args.objects) != 1 or args.linked_pe or args.link_plan or args.relocations or args.symbol_order:
            parser.error("--runtime-pe 只接受一个 PE 文件")
        try:
            check_runtime_pe(args.objects[0].read_bytes())
        except RuntimeSymbolError as error:
            print(f"{error.code} {error}", file=sys.stderr)
            return 1
        except (OSError, ValueError) as error:
            print(f"错误：{error}", file=sys.stderr)
            return 1
        return 0
    if args.linked_pe:
        try:
            verify_linked_relocations(args.objects, args.linked_pe, args.link_map)
        except (OSError, ValueError) as error:
            print(f"E8012 {error}", file=sys.stderr)
            return 1
        return 0
    expected = [name.encode("utf-8") for name in args.symbol_order or []]
    absolute = False
    for path in args.objects:
        try:
            with path.open("rb") as artifact:
                if args.relocations or args.link_plan or expected:
                    image = artifact.read()
                    if args.relocations or args.link_plan:
                        absolute = check_coff_relocations(image) or absolute
                    if args.link_plan:
                        reject_symbol_containers(image)
                    if expected:
                        check_coff_symbol_order(image, expected)
                else:
                    check_coff_sections(artifact.read(SECTION_TABLE_END))
        except CoffSectionError as error:
            print(f"E8011 {path}: {error}", file=sys.stderr)
            return 1
        except CoffRelocationError as error:
            print(f"E8012 {path}: {error}", file=sys.stderr)
            return 1
        except CoffSymbolOrderError as error:
            print(f"E8013 {path}: {error}", file=sys.stderr)
            return 1
        except RuntimeSymbolError as error:
            print(f"{error.code} {path}: {error}", file=sys.stderr)
            return 1
        except (OSError, ValueError) as error:
            print(f"错误：{path}: {error}", file=sys.stderr)
            return 1
    if args.link_plan:
        print("absolute" if absolute else "relative")
    return 0


if __name__ == "__main__":
    sys.exit(main())
