"""校验链接产物（AMD64 PE 或静态 x86-64 ELF）中可装载的静态摘要。"""
import struct

ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
ELF_PROGRAM = struct.Struct("<IIQQQQQQ")
ELF_SECTION = struct.Struct("<IIQQQQIIQQ")


class PETimestampError(ValueError):
    """PE 文件头时间戳不符合确定性约束。"""


def require(condition, message):
    """用调用方可报告的错误中止校验。"""
    if not condition:
        raise ValueError(message)


def check_digest_record(image, data, expected, prefix, suffix, kind, label):
    """核对只读数据区内的唯一摘要记录及前后界标。"""
    index = data.find(prefix)
    require(index >= 0 and image.count(prefix) == 1, f"{kind} {label}摘要标识缺失或重复")
    start = index + len(prefix)
    expected_bytes = expected.encode("ascii")
    finish = start + len(expected_bytes)
    require(data[finish:finish + len(suffix)] == suffix, f"{kind} {label}摘要记录截断或无效")
    require(data[start:finish] == expected_bytes, f"{kind} {label}摘要与配置源不一致")


def check_pe_image_digest(image, expected, prefix, suffix, label):
    """核对 AMD64 PE 字节镜像中单一、只读且可装载的生成表摘要。"""
    require(len(image) >= 64 and image[:2] == b"MZ", "缺少 PE 文件头")
    pe = struct.unpack_from("<I", image, 60)[0]
    require(64 <= pe <= len(image) - 24 and image[pe:pe + 4] == b"PE\0\0", "PE 文件头无效")
    machine, sections = struct.unpack_from("<HH", image, pe + 4)
    opt_size = struct.unpack_from("<H", image, pe + 20)[0]
    opt = pe + 24
    first = opt + opt_size
    end = first + 40 * sections
    require(machine == 0x8664 and opt_size >= 112 and 1 <= sections <= 96 and end <= len(image),
          "AMD64 PE 节表无效")
    require(struct.unpack_from("<H", image, opt)[0] == 0x20B, "不是 PE32+ 产物")
    if struct.unpack_from("<I", image, pe + 8)[0] != 0:
        raise PETimestampError("E8010 PE TimeDateStamp 非零")
    data_sections = []
    for section in range(first, end, 40):
        if image[section:section + 8].rstrip(b"\0") != b".rdata":
            continue
        virtual_size, _, raw_size, raw_start = struct.unpack_from("<IIII", image, section + 8)
        flags = struct.unpack_from("<I", image, section + 36)[0]
        require(flags & 0x40000040 == 0x40000040 and not flags & 0xA2000000,
              "PE .rdata 不是保留的只读初始化数据")
        require(end <= raw_start <= len(image) and 0 < raw_size <= len(image) - raw_start and virtual_size > 0,
              "PE .rdata 数据区越界")
        data_sections.append(image[raw_start:raw_start + min(raw_size, virtual_size)])
    require(len(data_sections) == 1, "PE 必须含唯一的 .rdata 数据区")
    check_digest_record(image, data_sections[0], expected, prefix, suffix, "PE", label)


def check_elf_image_digest(image, expected, prefix, suffix, label):
    """核对静态 x86-64 ELF 字节镜像中单一、只读且可装载的生成表摘要。"""
    size = len(image)
    require(size >= ELF_HEADER.size and image[:4] == b"\x7fELF", "缺少 ELF 文件头")
    ident, kind, machine, version, entry, phoff, shoff, _, ehsize, phsize, phnum, shsize, shnum, shstrndx = (
        ELF_HEADER.unpack_from(image, 0)
    )
    require(
        (ident[:7], kind, machine, version, ehsize) == (b"\x7fELF\x02\x01\x01", 2, 62, 1, ELF_HEADER.size),
        "ELF64 类别、文件类型或机器类型不匹配",
    )
    require(
        entry != 0 and phsize == ELF_PROGRAM.size and phnum > 0 and ELF_HEADER.size <= phoff <= size - phsize * phnum,
        "ELF 可执行入口或程序头无效",
    )
    require(
        shsize == ELF_SECTION.size and shnum > 0 and shstrndx < shnum and ELF_HEADER.size <= shoff <= size - shsize * shnum,
        "ELF 节表越界",
    )
    has_entry = False
    readonly_loads = []
    for index in range(phnum):
        program, flags, offset, start, _, file_bytes, memory_bytes, _ = ELF_PROGRAM.unpack_from(
            image, phoff + index * phsize
        )
        require(program != 3, "静态 ELF 含解释器入口")
        if program == 1:
            require(offset <= size and file_bytes <= size - offset and file_bytes <= memory_bytes, "ELF 加载段越界")
            if flags & 1 and start <= entry < start + file_bytes:
                has_entry = True
            if (flags & 2) == 0:
                readonly_loads.append((offset, offset + file_bytes))
    require(has_entry, "ELF 入口不在可执行加载段内")

    _, str_type, _, _, str_off, str_size, _, _, _, _ = ELF_SECTION.unpack_from(image, shoff + shstrndx * shsize)
    require(str_type == 3 and str_off <= size and str_size <= size - str_off, "ELF 节名字符串表无效")
    shstrtab = image[str_off:str_off + str_size]

    data_sections = []
    for index in range(shnum):
        name_off, sec_type, sec_flags, _, sec_off, sec_size, _, _, _, _ = ELF_SECTION.unpack_from(
            image, shoff + index * shsize
        )
        if name_off >= len(shstrtab):
            continue
        nul = shstrtab.find(b"\0", name_off)
        require(nul >= 0, "ELF 节名缺少终结符")
        if shstrtab[name_off:nul] != b".rodata":
            continue
        require(sec_type == 1 and (sec_flags & 2) == 2 and (sec_flags & 1) == 0,
                "ELF .rodata 不是保留的只读初始化数据")
        require(0 < sec_size and sec_off <= size - sec_size, "ELF .rodata 数据区越界")
        in_readonly_load = any(start <= sec_off and sec_off + sec_size <= end for start, end in readonly_loads)
        require(in_readonly_load, "ELF .rodata 不在只读加载段内")
        data_sections.append(image[sec_off:sec_off + sec_size])
    require(len(data_sections) == 1, "ELF 必须含唯一的 .rodata 数据区")
    check_digest_record(image, data_sections[0], expected, prefix, suffix, "ELF", label)


def check_pe_digest(artifact, expected, prefix, suffix, label):
    """核对 AMD64 PE 中单一、只读且可装载的生成表摘要。"""
    check_pe_image_digest(artifact.read_bytes(), expected, prefix, suffix, label)


def check_elf_digest(artifact, expected, prefix, suffix, label):
    """核对静态 x86-64 ELF 中单一、只读且可装载的生成表摘要。"""
    check_elf_image_digest(artifact.read_bytes(), expected, prefix, suffix, label)


def check_artifact_digest(artifact, expected, prefix, suffix, label):
    """按文件头自动识别 AMD64 PE 或静态 x86-64 ELF 并核对内嵌生成表摘要。"""
    image = artifact.read_bytes()
    if image[:2] == b"MZ":
        check_pe_image_digest(image, expected, prefix, suffix, label)
    elif image[:4] == b"\x7fELF":
        check_elf_image_digest(image, expected, prefix, suffix, label)
    else:
        raise ValueError("缺少有效 PE 或 ELF 文件头")

