"""用最小二进制夹具复验 B-2 检查的拒绝边界。"""

from pathlib import Path
import struct
from tempfile import TemporaryDirectory
import unittest

from test_build_host_metadata import MetadataError, check_artifact, host_path_spellings


def coff(stamp=0):
    return struct.pack("<HHIIIHH", 0x8664, 3, stamp, 0, 0, 0, 0)


def pe(stamp=0):
    dos = bytearray(96)
    dos[:2] = b"MZ"
    struct.pack_into("<I", dos, 60, len(dos))
    return bytes(dos) + b"PE\0\0" + coff(stamp)


class BuildMetadataTest(unittest.TestCase):
    def check(self, name, data, words=()):
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / name
            path.write_bytes(data)
            check_artifact(path, set(words))

    def test_zero_timestamp_and_canonical_text(self):
        for name, data in (("a.obj", coff()), ("a.exe", pe()), ("a.ysm", b"module::root")):
            with self.subTest(name=name):
                self.check(name, data, ["/build/host"])

    def test_nonzero_timestamp_at_both_header_offsets(self):
        for name, data in (("a.obj", coff(1)), ("a.exe", pe(1))):
            with self.subTest(name=name), self.assertRaisesRegex(MetadataError, "TimeDateStamp"):
                self.check(name, data)

    def test_malformed_headers_and_empty_payload(self):
        for name, data in (("a.obj", coff()[:-1]), ("a.exe", pe()[:64]), ("a.iface", b"")):
            with self.subTest(name=name), self.assertRaises(MetadataError):
                self.check(name, data)

    def test_path_leak_in_either_encoding(self):
        source = Path("路径含空格 source").resolve()
        words = host_path_spellings(source)
        spellings = [source.as_posix()]
        if source.anchor == "/":
            spellings.append("Z:" + source.as_posix().replace("/", chr(92)))
        for spelling in spellings:
            self.assertIn(spelling, words)
            for suffix, head in (("obj", coff()), ("exe", pe()), ("ysm", b"YKMI"), ("iface", b"YKIF")):
                for encoding in ("utf-8", "utf-16-le"):
                    with self.subTest(suffix=suffix, encoding=encoding, spelling=spelling):
                        with self.assertRaisesRegex(MetadataError, "绝对宿主路径"):
                            self.check(f"a.{suffix}", head + spelling.encode(encoding), words)


if __name__ == "__main__":
    unittest.main()
