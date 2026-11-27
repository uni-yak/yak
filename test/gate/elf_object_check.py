"""独立读取 ELF64 对象夹具；不调用发射器内部的偏移或常量。"""
from pathlib import Path
import struct
import sys


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def string_at(table, offset):
    require(0 <= offset < len(table), "字符串偏移越界")
    end = table.find(b"\0", offset)
    require(end >= 0, "字符串未终止")
    return table[offset:end].decode("ascii")


def validate(data):
    require(len(data) >= 64, "ELF 头截断")
    head = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    ident, etype, machine, ver, entry, phoff, shoff, flags, ehsize, phsize, phnum, shsize, shnum, shstr = head
    require(ident == b"\x7fELF\2\1\1" + bytes(9) and (etype, machine, ver, entry) == (1, 62, 1, 0), "ELF 头无效")
    require((phoff, flags, ehsize, phsize, phnum, shsize, shnum, shstr) == (0, 0, 64, 0, 0, 64, 10, 9), "ELF 表字段无效")
    require(64 <= shoff and shoff % 8 == 0 and shoff + shsize * shnum == len(data), "节表边界无效")
    rows = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shsize) for i in range(shnum)]
    require(rows[0] == (0,) * 10, "保留节非零")
    contents = []
    previous = ehsize
    for name, kind, attr, addr, offset, length, link, info, align, entsize in rows[1:]:
        require(addr == 0 and align in (1, 8, 16), "节地址或对齐无效")
        require(previous <= offset <= offset + length <= shoff and offset % align == 0, "数据节边界无效")
        require(not any(data[previous:offset]), "节间填充不为零")
        contents.append(data[offset:offset + length])
        previous = offset + length
    require(not any(data[previous:shoff]), "节表前填充不为零")
    names = contents[-1]
    require([string_at(names, item[0]) for item in rows] == ["", ".text", ".rodata", ".data", ".rela.text", ".rela.rodata", ".rela.data", ".symtab", ".strtab", ".shstrtab"], "节名不符")
    shape = [(r[1], r[2], r[5], r[6], r[7], r[8], r[9]) for r in rows[1:]]
    require(shape[:7] == [
        (1, 6, 26, 0, 0, 16, 0), (1, 2, 16, 0, 0, 8, 0), (1, 3, 12, 0, 0, 8, 0),
        (4, 64, 48, 7, 1, 8, 24), (4, 64, 24, 7, 2, 8, 24), (4, 64, 48, 7, 3, 8, 24),
        (2, 0, 168, 8, 3, 8, 24),
    ] and all((v[0], v[1], *v[3:]) == (3, 0, 0, 0, 1, 0) for v in shape[7:]), "节类型、属性或引用不符")
    syms, strings = contents[6:8]
    require(strings[0] == 0 and names[0] == 0, "字符串表没有保留空串")
    sym_rows = [(string_at(strings, offset), info, other, sec, value, size) for offset, info, other, sec, value, size in struct.iter_unpack("<IBBHQQ", syms)]
    require(sym_rows == [
        ("", 0, 0, 0, 0, 0), ("text_here", 0, 0, 1, 0, 0), ("payload", 0, 0, 2, 0, 3),
        ("yak$entry", 18, 0, 1, 0, 26), ("elf_probe_external", 18, 0, 0, 0, 0),
        ("elf_probe_abs", 16, 0, 3, 0, 8), ("elf_probe_small", 16, 0, 3, 8, 4),
    ], "符号索引、绑定或定义位置不符")
    decoded = [[(at, ident >> 32, ident & 0xffffffff, addend) for at, ident, addend in struct.iter_unpack("<QQq", sec)] for sec in contents[3:6]]
    require(decoded == [[(5, 4, 4, -4), (16, 2, 2, -4)], [(8, 3, 1, 0)], [(0, 2, 1, 2), (8, 4, 10, 0)]], "重定位索引、加数或顺序不符")
    require(contents[0][5:9] == contents[0][16:20] == bytes(4) and contents[1][8:] == bytes(8) and contents[2] == bytes(12), "重定位位置含非预期隐式加数")


def main():
    try:
        path, repeat = map(Path, sys.argv[1:])
        data = path.read_bytes()
        require(data == repeat.read_bytes(), "两次发射的字节不同")
        validate(data)
        # 对照检查不从发射器接收头字段；三项只损坏一个头字段。
        for offset, value in ((4, 1), (18, 3), (24, 1)):
            invalid = bytearray(data)
            invalid[offset] = value
            try:
                validate(bytes(invalid))
            except ValueError as err:
                require(str(err) == "ELF 头无效", "损坏头字段的拒绝原因不符")
            else:
                raise ValueError("损坏的 ELF 头未被独立观察器拒绝")
    except (ValueError, OSError, struct.error) as err:
        print(f"ELF64 对象夹具失败：{err}", file=sys.stderr)
        return 1
    print(f"ELF64 对象夹具：{len(data)} 字节，四种重定位，三个损坏头拒绝，重复发射一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
