"""隔离验证 Win64 COFF 相对与绝对重定位的链接边界。"""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from coff_sections import ADDR32NB, ADDR64, REL32, CoffRelocationError, check_coff_relocations, check_linked_absolute_relocation


CROSS_SITE = b"YakCrossRel32Site"
EXTERN_SITE = b"YakExternRel32Site"
CROSS_TARGET = b"YakCrossTargetBytes"
EXTERN_TARGET = b"YakExternTargetBytes"


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def make_object(text, rdata, symbols, relocations):
    """按 Yak 普通对象的节布局生成短名符号和重定位记录。"""
    first = 140
    relptr = first + len(text) + len(rdata)
    symptr = relptr + 10 * len(relocations)
    image = bytearray(struct.pack("<HHIIIHH", 0x8664, 3, 0, symptr, len(symbols), 0, 0))
    for name, flags, size, raw, table, count in (
        (b".text", 0x60000020, len(text), first, relptr, len(relocations)),
        (b".rdata", 0x40000040, len(rdata), first + len(text), 0, 0),
        (b".data", 0xC0000040, 0, 0, 0, 0),
    ):
        image += struct.pack("<8sIIIIIIHHI", name, 0, 0, size, raw, table, 0, count, 0, flags)
    image += text + rdata
    for site, symbol, kind in relocations:
        image += struct.pack("<IIH", site, symbol, kind)
    strings = bytearray()
    for name, value, section in symbols:
        if len(name) > 8:
            field = struct.pack("<II", 0, 4 + len(strings))
            strings += name + b"\0"
        else:
            field = name
        image += struct.pack("<8sIhHBB", field, value, section, 0, 2, 0)
    image += struct.pack("<I", 4 + len(strings)) + strings
    check_coff_relocations(bytes(image))
    return bytes(image)


def pe_sections(image):
    """读取实际链接地址，不把链接器布局常量写入断言。"""
    pe, = struct.unpack_from("<I", image, 60)
    check(image[:2] == b"MZ" and image[pe:pe + 4] == b"PE\0\0", "链接器未生成 PE")
    machine, count, stamp = struct.unpack_from("<HHI", image, pe + 4)
    opt_size, = struct.unpack_from("<H", image, pe + 20)
    check(machine == 0x8664 and stamp == 0 and image[pe + 24:pe + 26] == b"\x0b\x02", "PE 头不符")
    result = {}
    for head in range(pe + 24 + opt_size, pe + 24 + opt_size + 40 * count, 40):
        name = image[head:head + 8].rstrip(b"\0")
        _, rva, size, raw = struct.unpack_from("<IIII", image, head + 8)
        check(raw + size <= len(image) and name not in result, "PE 节无效")
        result[name] = rva, image[raw:raw + size]
    return result


def marker(section, token):
    rva, data = section
    check(data.count(token) == 1, f"标记缺失或重复：{token!r}")
    index = data.index(token)
    return rva + index, data[index + len(token):]


def read_result(path):
    sections = pe_sections(path.read_bytes())
    result = []
    for site, target, target_section in ((CROSS_SITE, CROSS_TARGET, b".rdata"),
                                         (EXTERN_SITE, EXTERN_TARGET, b".text")):
        origin, following = marker(sections[b".text"], site)
        destination, _ = marker(sections[target_section], target)
        signed, = struct.unpack_from("<i", following)
        result.append((destination - origin - len(site) - 4, signed))
    return tuple(result)


def run_probe(cc: str, work: Path) -> None:
    work.mkdir()
    prefix = b"\xc3" * 16
    text = prefix + CROSS_SITE + bytes(4) + EXTERN_SITE + bytes(4) + b"\xc3" * 8
    cross_at = len(prefix) + len(CROSS_SITE)
    extern_at = cross_at + 4 + len(EXTERN_SITE)
    provider = make_object(EXTERN_TARGET + b"\xc3" * 48, b"", ((b"xdef", 0, 1),), ())
    consumer = make_object(text, CROSS_TARGET, ((b"start", 0, 1), (b"cross", 0, 2), (b"xdef", 0, 0)),
                           ((cross_at, 1, REL32), (extern_at, 2, REL32)))
    raw, = struct.unpack_from("<I", consumer, 40)
    other = work / "provider.obj"
    other.write_bytes(provider)
    print(f"目标提供者 SHA-256：{hashlib.sha256(provider).hexdigest()}", flush=True)

    def link(name, addends, expected=None, rejected=None):
        image = bytearray(consumer)
        for site, value in zip((cross_at, extern_at), addends):
            struct.pack_into("<i", image, raw + site, value)
        obj, exe = work / (name + ".obj"), work / (name + ".exe")
        artifact = bytes(image)
        check_coff_relocations(artifact)
        obj.write_bytes(artifact)
        command = [cc, "-nostartfiles", "-e", "start", "-Wl,--no-insert-timestamp", "-o", str(exe), str(other), str(obj)]
        result = subprocess.run(command, capture_output=True, check=False)
        (work / (name + ".stdout")).write_bytes(result.stdout)
        (work / (name + ".stderr")).write_bytes(result.stderr)
        print(f"{name} 加数={addends} 退出={result.returncode} 对象 SHA-256={hashlib.sha256(artifact).hexdigest()}",
              flush=True)
        check(obj.read_bytes() == artifact and other.read_bytes() == provider, "链接器改写了输入")
        if rejected is not None:
            diagnostic = result.stderr.decode("utf-8", "replace")
            failures = [line for line in diagnostic.splitlines() if "relocation truncated to fit" in line]
            site, symbol = rejected
            expected_error = (f"(.text+0x{site:x}): relocation truncated to fit: "
                              f"IMAGE_REL_AMD64_REL32 against symbol `{symbol}' ")
            check(result.returncode == 1 and not result.stdout and not exe.exists() and len(failures) == 1
                  and expected_error in failures[0], f"缺少目标重定位拒绝：{diagnostic}")
            print(failures[0], flush=True)
            return None
        check(result.returncode == 0 and exe.is_file() and not result.stdout and not result.stderr,
              f"有效对象链接失败：{result.stderr!r}")
        rows = read_result(exe)
        check(all(value == delta + addend for (delta, value), addend in zip(rows, addends)), "位移与实际地址差、加数不符")
        if expected is not None:
            check(tuple(value for _, value in rows) == expected, f"边界控制出错：{rows}")
        print(f"{name} 从 PE 读回（原位移，施加后位移）：{rows}", flush=True)
        return rows

    (cross, _), (external, _) = link("baseline", (0, 0))
    check(cross > 0 and external < 0, "探针未分离正、负位移")
    high, low = (1 << 31) - 1, -(1 << 31)
    link("cross-max", (high - cross, 0), (high, external))
    link("extern-min", (0, low - external), (cross, low))
    link("cross-over", (high + 1 - cross, 0), rejected=(cross_at, "cross"))
    link("extern-under", (0, low - 1 - external), rejected=(extern_at, "xdef"))


def run_absolute_probe(cc, work):
    """核对真实 PE 中的 RVA、VA 和加数；回绕样本只保留日志与输入对象。"""
    site = b"YakAbsoluteRelocation"
    target = b"YakAbsoluteTarget"
    provider = work / "absolute-provider.obj"
    provider.write_bytes(make_object(target + bytes(24), b"", ((b"target", 0, 1),), ()))
    for name, kind, width in (("addr32nb", ADDR32NB, 4), ("addr64", ADDR64, 8)):
        def link(label, addend, overflow=False):
            text = site + addend.to_bytes(width, "little", signed=True)
            image = make_object(text, b"", ((b"start", 0, 1), (b"target", 0, 0)), ((len(site), 1, kind),))
            obj, staged = work / (label + ".obj"), work / (label + ".staged.exe")
            obj.write_bytes(image)
            command = [cc, "-nostartfiles", "-e", "start", "-Wl,--no-insert-timestamp", "-o", str(staged), str(provider), str(obj)]
            result = subprocess.run(command, capture_output=True, check=False)
            (work / (label + ".stderr")).write_bytes(result.stderr)
            check(obj.read_bytes() == image, "链接器改写了绝对重定位输入")
            if result.returncode:
                diagnostic = result.stderr.decode("utf-8", "replace")
                check(overflow and result.returncode == 1 and not staged.exists()
                      and "relocation truncated to fit" in diagnostic, f"绝对重定位链接失败：{diagnostic}")
                print(f"{label} 链接器拒绝，退出 1", flush=True)
                return 0
            raw = staged.read_bytes()
            staged.unlink()
            sections = pe_sections(raw)
            pe, = struct.unpack_from("<I", raw, 60)
            image_base, = struct.unpack_from("<Q", raw, pe + 48)
            rva, _ = marker(sections[b".text"], target)
            _, following = marker(sections[b".text"], site)
            value = int.from_bytes(following[:width], "little")
            try:
                check_linked_absolute_relocation(kind, image_base + rva, image_base, addend, value)
            except CoffRelocationError as error:
                check(overflow, str(error))
                print(f"{label} E8012 {error}，链接器读回 {value}", flush=True)
            else:
                check(not overflow, "绝对重定位回绕被接受")
                print(f"{label} 地址读回 {value}，加数 {addend}", flush=True)
            return rva if kind == ADDR32NB else image_base + rva

        base = link(name + "-base", 0)
        link(name + "-zero", -base)
        # 比负的实际目标地址再小一位，任一符号解释都不能得到合法结果。
        link(name + "-under", -base - 1, overflow=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cc", help="实际使用的 Win64 GCC")
    parser.add_argument("out_dir", type=Path, help="父目录已存在的新回执目录")
    args = parser.parse_args()
    run_probe(args.cc, args.out_dir)
    run_absolute_probe(args.cc, args.out_dir)


if __name__ == "__main__":
    main()
