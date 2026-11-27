"""校验链接产物中可装载的静态摘要。"""
import struct


class PETimestampError(ValueError):
    """PE 文件头时间戳不符合确定性约束。"""


def require(condition, message):
    """用调用方可报告的错误中止校验。"""
    if not condition:
        raise ValueError(message)


def check_pe_digest(artifact, expected, prefix, suffix, label):
    """核对 AMD64 PE 中单一、只读且可装载的生成表摘要。"""
    image = artifact.read_bytes()
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
    data, = data_sections
    index = data.find(prefix)
    require(index >= 0 and image.count(prefix) == 1, f"PE {label}摘要标识缺失或重复")
    start = index + len(prefix)
    expected_bytes = expected.encode("ascii")
    finish = start + len(expected_bytes)
    require(data[finish:finish + len(suffix)] == suffix, f"PE {label}摘要记录截断或无效")
    require(data[start:finish] == expected_bytes, f"PE {label}摘要与配置源不一致")

