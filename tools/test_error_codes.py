"""错误码静态表生成器的定向测试：正向生成与负向拒绝。"""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


def load(name, path):
    """按路径加载生成器模块，避免依赖 sys.path。"""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ErrorCodes(unittest.TestCase):
    def setUp(self):
        # 沙箱落在系统临时目录：不写回工作树，也不依赖仓库根的 tmp/。
        scratch = tempfile.TemporaryDirectory(prefix="yak-error-codes-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.assertFalse(self.root.is_relative_to(ROOT), f"沙箱不得落在仓库内：{self.root}")
        shutil.copytree(ROOT / "spec", self.root / "spec")
        self.generator = load("error_codes_test", ROOT / "tools/error_codes.py")
        self.generator.ROOT = self.root
        self.generator.SPEC = self.root / "spec"
        self.generator.SOURCE = self.root / "spec/proc/error.def"
        self.generator.OUTPUT = self.root / "out/error_codes.yak"
        self.source = self.generator.SOURCE
        # 以真实配置源为基线，负向用例在其上做最小改写。
        self.base = (ROOT / "spec/proc/error.def").read_text(encoding="utf-8")

    def write_source(self, text):
        """写入一份改写后的配置源（LF 换行）。"""
        self.source.write_text(text, encoding="utf-8", newline="\n")

    def append_entry(self, entry, reserve_from=24):
        """在 E10 末尾追加一条条目，并把预留区间后移一位。

        配置源要求已登记序号之后紧接预留并覆盖到 99，追加条目必须同步收缩预留。
        """
        text = self.base.replace("reserve E10 from 23 to 99",
                                 entry + f"\nreserve E10 from {reserve_from} to 99")
        self.assertNotEqual(text, self.base, "夹具未命中 E10 的预留行")
        self.write_source(text)

    def expect_error(self, fragment):
        """断言生成失败，且错误信息包含指定片段。"""
        with self.assertRaises(self.generator.ConfigError) as caught:
            self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        self.assertIn(fragment, str(caught.exception))
        return str(caught.exception)

    # ── 正向：确定性与摘要 ──

    def test_generate_is_deterministic(self):
        """同一配置源两次生成必须逐字节一致。"""
        self.write_source(self.base)
        first = self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        second = self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        self.assertEqual(first, second)

    def test_embedded_digest_matches_source(self):
        """生成文件内嵌的摘要必须等于配置源 LF 规范化后的 SHA-256。"""
        self.write_source(self.base)
        text = self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        expected = hashlib.sha256(self.base.encode("utf-8")).hexdigest()
        self.assertIn("// 源摘要：" + expected, text)
        self.assertIn(expected, text)

    def test_pe_digest_requires_unique_loaded_read_only_record(self):
        """真实节表形状的最小样本覆盖摘要位置、完整性、唯一性与漂移。"""
        module = self.generator
        digest = hashlib.sha256(self.base.encode("utf-8")).hexdigest()
        prefix, suffix = module.ARTIFACT_DIGEST_PREFIX, module.ARTIFACT_DIGEST_SUFFIX
        record = prefix + digest.encode("ascii") + suffix
        pe, opt_size, raw_start, raw_size = 0x80, 240, 0x200, 0x200
        section = pe + 24 + opt_size

        def image(payload, flags=0x40000040, virtual_size=0x100, tail=b"", timestamp=0):
            """合成一个含 .rdata 的最小 PE 文件，体外附加内容不计入节。"""
            raw = bytearray(raw_start + raw_size)
            raw[:2] = b"MZ"
            struct.pack_into("<I", raw, 60, pe)
            raw[pe:pe + 4] = b"PE\0\0"
            struct.pack_into("<HHI", raw, pe + 4, 0x8664, 1, timestamp)
            struct.pack_into("<H", raw, pe + 20, opt_size)
            struct.pack_into("<H", raw, pe + 24, 0x20B)
            raw[section:section + 8] = b".rdata\0\0"
            struct.pack_into("<IIII", raw, section + 8, virtual_size, 0x1000, raw_size, raw_start)
            struct.pack_into("<I", raw, section + 36, flags)
            raw[raw_start:raw_start + len(payload)] = payload
            return bytes(raw) + tail

        artifact = self.root / "main.exe"
        artifact.write_bytes(image(b"prefix" + record))
        module.check_pe_digest(artifact, digest)
        for label, payload, error in (
            ("裸摘要", image(digest.encode("ascii")), "缺失或重复"),
            ("体外摘要", image(b"", tail=record), "缺失或重复"),
            ("重复", image(record, tail=record), "缺失或重复"),
            ("过期", image(prefix + b"0" * 64 + suffix), "与配置源不一致"),
            ("可写", image(record, flags=0xC0000040), "不是保留的只读"),
            ("虚拟边界", image(record, virtual_size=len(record) - 1), "截断或无效"),
            ("截断 PE", image(record)[:491], "数据区越界"),
            ("非零时间戳", image(record, timestamp=1), "^E8010 PE TimeDateStamp 非零$"),
        ):
            with self.subTest(label=label):
                artifact.write_bytes(payload)
                with self.assertRaisesRegex(module.ConfigError, error):
                    module.check_pe_digest(artifact, digest)

    def test_crlf_source_matches_lf_digest(self):
        """CRLF 检出物与 LF 存储物必须生成同一张表（拒绝形态 ER-2）。"""
        lf = self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        self.source.write_bytes(self.base.replace("\n", "\r\n").encode("utf-8"))
        crlf = self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        self.assertEqual(lf, crlf)

    def test_rejects_bom(self):
        """配置源带 BOM 必须拒绝，避免摘要随检出方式漂移。"""
        self.source.write_bytes(b"\xef\xbb\xbf" + self.base.encode("utf-8"))
        with self.assertRaises(self.generator.ConfigError) as caught:
            self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        self.assertIn("BOM", str(caught.exception))

    def test_generated_file_is_lf(self):
        """生成文件必须是 UTF-8 LF，且带"请勿手改"头。"""
        self.write_source(self.base)
        text = self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        self.assertEqual(text.count("\r"), 0)
        self.assertTrue(text.startswith("// 由 tools/error_codes.py 生成；请勿手改。\n"))

    # ── 负向：隐式码位与未知指令（拒绝形态 ER-5）──

    def test_rejects_unknown_directive(self):
        """未登记指令必须拒绝，配置源不得含执行代码。"""
        self.write_source(self.base + "\ninclude other.def\n")
        self.expect_error("未知指令")

    def test_rejects_indented_line(self):
        """缩进行不是合法指令。"""
        self.write_source(self.base + "\n  entry E10 code 23 ref lex.md:L-1 desc \"缩进\"\n")
        self.expect_error("缩进行")

    def test_rejects_implicit_code(self):
        """entry 缺少显式 code 必须按隐式码位分配拒绝。"""
        self.write_source(self.base + "\nentry E10 ref lex.md:L-1 desc \"无码位\"\n")
        self.expect_error("隐式码位分配")

    def test_rejects_duplicate_code(self):
        """同一码位重复登记必须拒绝（拒绝形态 ER-3）。"""
        self.write_source(self.base + "\nentry E10 code 01 ref lex.md:L-1 desc \"重复\"\n")
        self.expect_error("码位重复登记")

    def test_rejects_reserved_slot(self):
        """已预留码位不得再登记条目。"""
        self.write_source(self.base + "\nentry E10 code 23 ref lex.md:L-1 desc \"越界复用\"\n")
        self.expect_error("预留")

    def test_rejects_cross_segment_reuse(self):
        """跨段复用已登记码位必须拒绝。"""
        self.write_source(self.base + "\nentry E20 code 01 ref parse.md:P-1 desc \"跨段复用\"\n")
        self.expect_error("码位重复登记")

    def test_rejects_empty_desc(self):
        """描述不得为空。"""
        self.append_entry('entry E10 code 23 ref lex.md:L-1 desc ""')
        self.expect_error("描述不得为空")

    def test_rejects_missing_ref_file(self):
        """引用的规格文件不存在必须拒绝（拒绝形态 ER-4）。"""
        self.append_entry('entry E10 code 23 ref nosuch.md:L-1 desc "缺文件"')
        self.expect_error("引用文件不存在")

    def test_rejects_missing_anchor(self):
        """引用锚点在目标文件内不存在必须拒绝。"""
        self.append_entry('entry E10 code 23 ref lex.md:L-999 desc "缺锚点"')
        self.expect_error("引用的规则不存在")

    def test_rejects_ref_without_anchor(self):
        """引用缺少冒号锚点必须拒绝。"""
        self.append_entry('entry E10 code 23 ref lex.md desc "无锚点"')
        self.expect_error("缺少规则锚点")

    # ── 负向：段结构（拒绝形态 ER-3）──

    def test_rejects_unknown_parent(self):
        """子领域的父段必须已声明。"""
        self.write_source(self.base + "\nsegment E11 name \"未登记父段\" parent E3\n")
        self.expect_error("与父段")

    def test_rejects_segment_mismatch(self):
        """子领域千位必须与父段号一致，禁止跨段挂载。"""
        self.write_source(self.base + "\nsegment E77 name \"跨段\" parent E1\n")
        self.expect_error("大段不一致")

    def test_rejects_gap_in_sequence(self):
        """子领域序号必须是 01..n 连续前缀（只允许追加）。"""
        # 把最后一条从 22 挪到 23，留出 22 的空洞：序号不再是连续前缀。
        old = ('entry E10 code 22 ref lex.md:L-22 desc "字符标量数非法或字面量未闭合"\n'
               "reserve E10 from 23 to 99")
        new = ('entry E10 code 23 ref lex.md:L-22 desc "字符标量数非法或字面量未闭合"\n'
               "reserve E10 from 24 to 99")
        text = self.base.replace(old, new)
        self.assertNotEqual(text, self.base, "夹具未命中 E10 的末尾条目")
        self.write_source(text)
        self.expect_error("连续前缀")

    def test_rejects_missing_reservation(self):
        """已登记序号之后必须紧接预留并覆盖到 99。"""
        text = self.base.replace("reserve E10 from 23 to 99", "reserve E10 from 24 to 99")
        self.write_source(text)
        self.assertNotEqual(text, self.base)
        self.expect_error("预留必须紧接")

    # ── 负向：历史码位（拒绝形态 ER-3）──

    def test_rejects_removed_code(self):
        """已登记码位从配置源消失必须拒绝，禁止重编号或复用。"""
        self.write_source(self.base)
        text = self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        self.generator.OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        self.generator.OUTPUT.write_text(text, encoding="utf-8", newline="\n")
        # 删除最后一条登记码位，并把该槽位置回预留，使段结构本身仍然合法。
        trimmed = self.base.replace(
            'entry E92 code 09 ref host.md:HS-4 desc "受限文件服务执行失败"\n', "", 1).replace(
            "reserve E92 from 10 to 99", "reserve E92 from 09 to 99")
        self.assertNotEqual(trimmed, self.base)
        self.write_source(trimmed)
        with self.assertRaises(self.generator.ConfigError) as caught:
            self.generator.generate(self.source, self.generator.OUTPUT, history=True)
        self.assertIn("已登记码位缺失", str(caught.exception))

    def test_rejects_missing_history_baseline(self):
        """删除生成物不能旁路独立历史基线。"""
        self.write_source(self.base)
        history = self.root / "spec/proc/error_history.json"
        self.assertTrue(history.is_file(), "测试应复制真实历史基线")
        history.unlink()
        with self.assertRaises(self.generator.ConfigError) as caught:
            self.generator.generate(self.source, self.generator.OUTPUT, history=True)
        self.assertIn("缺少 ER-3 历史基线", str(caught.exception))

    def test_rejects_removal_without_previous_output(self):
        """既有生成物不存在时，独立基线仍拒绝码位删除。"""
        trimmed = self.base.replace(
            'entry E92 code 09 ref host.md:HS-4 desc "受限文件服务执行失败"\n', "", 1).replace(
            "reserve E92 from 10 to 99", "reserve E92 from 09 to 99")
        self.assertNotEqual(trimmed, self.base)
        self.write_source(trimmed)
        self.assertFalse(self.generator.OUTPUT.exists())
        with self.assertRaisesRegex(self.generator.ConfigError, "历史基线码位缺失.*E9209"):
            self.generator.generate(self.source, self.generator.OUTPUT)

    def test_rejects_reuse_without_previous_output(self):
        """号码集合不变、有合法新引用，也不得把旧码位换绑到另一条规则。"""
        self.assertIn("entry E92 code 09 ref host.md:HS-4", self.base)
        self.write_source(self.base.replace("entry E92 code 09 ref host.md:HS-4",
                                            "entry E92 code 09 ref host.md:HS-3", 1))
        self.assertFalse(self.generator.OUTPUT.exists())
        self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        with self.assertRaisesRegex(self.generator.ConfigError, "历史基线码位复用.*E9209"):
            self.generator.generate(self.source, self.generator.OUTPUT)

    def test_history_rejects_unrecorded_append(self):
        """新码位在生成前也必须登记，才能在删除生成表后保持绑定。"""
        self.append_entry('entry E10 code 23 ref lex.md:L-1 desc "新增码位"')
        with self.assertRaisesRegex(self.generator.ConfigError, "新码位尚未登记.*E1023"):
            self.generator.generate(self.source, self.generator.OUTPUT)

    def test_history_allows_registered_append(self):
        """新码位同步登记，且不改既有码位绑定时可以出表。"""
        self.append_entry('entry E10 code 23 ref lex.md:L-1 desc "新增码位"')
        history = self.root / "spec/proc/error_history.json"
        record = json.loads(history.read_text(encoding="utf-8"))
        record["entries"].append([1023, "lex.md:L-1"])
        record["entries"].sort()
        history.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8", newline="\n")
        text = self.generator.generate(self.source, self.generator.OUTPUT)
        self.assertIn("1023u16", text)

    def test_history_allows_description_revision(self):
        """历史身份是规格引用，不把自然语言说明冻结为号码身份。"""
        self.assertIn('desc "受限文件服务执行失败"', self.base)
        self.write_source(self.base.replace('desc "受限文件服务执行失败"',
                                            'desc "受限文件服务操作失败"', 1))
        text = self.generator.generate(self.source, self.generator.OUTPUT)
        self.assertIn("受限文件服务操作失败", text)

    # ── 负向：写入位置与漂移检测 ──

    def test_check_detects_drift(self):
        """生成文件被手改后 --check 必须失败。"""
        self.write_source(self.base)
        self.generator.OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        text = self.generator.generate(self.source, self.generator.OUTPUT, history=False)
        self.generator.OUTPUT.write_text(text + "\n// 手改\n", encoding="utf-8", newline="\n")
        with self.assertRaises(SystemExit) as caught:
            sys.argv = ["error_codes.py", "--check", "--source", str(self.source),
                        "--output", str(self.generator.OUTPUT), "--no-history"]
            self.generator.main()
        self.assertIn("陈旧", str(caught.exception))

    def test_output_writes_requested_path(self):
        """--output 必须写到指定位置，而不是仓库内的固定路径。"""
        self.write_source(self.base)
        target = self.root / "elsewhere/nested/table.yak"
        sys.argv = ["error_codes.py", "--source", str(self.source),
                    "--output", str(target), "--no-history"]
        self.generator.main()
        self.assertTrue(target.is_file())
        self.assertTrue(target.read_text(encoding="utf-8").startswith("// 由 tools/error_codes.py 生成"))

    def test_repository_table_is_current(self):
        """仓库内的生成文件必须与当前配置源一致（--check 的回归入口）。"""
        text = self.generator.generate(ROOT / "spec/proc/error.def",
                                       ROOT / "compiler/min/src/diag/error_codes.yak",
                                       history=True)
        current = (ROOT / "compiler/min/src/diag/error_codes.yak").read_text(encoding="utf-8")
        self.assertEqual(text, current)


if __name__ == "__main__":
    unittest.main()
