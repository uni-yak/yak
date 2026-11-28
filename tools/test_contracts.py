"""规格审计与词法表生成器的负向门禁。"""
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ContractGates(unittest.TestCase):
    def setUp(self):
        # 沙箱落在系统临时目录：不依赖仓库根预建 tmp/，也不会写回工作树。
        scratch = tempfile.TemporaryDirectory(prefix="yak-contracts-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.assertFalse(self.root.is_relative_to(ROOT), f"沙箱不得落在仓库内：{self.root}")
        shutil.copytree(ROOT / "spec", self.root / "spec")
        shutil.copyfile(ROOT / "versions.lock", self.root / "versions.lock")
        # 规格审计还要核查仓库内的门禁文档和候选语料链接，复制实际目标。
        gate_doc = Path("test/gate/README.md")
        (self.root / gate_doc.parent).mkdir(parents=True)
        shutil.copyfile(ROOT / gate_doc, self.root / gate_doc)
        full_cases = Path("test/full")
        shutil.copytree(ROOT / full_cases, self.root / full_cases,
                        ignore=shutil.ignore_patterns("__pycache__"))
        self.audit = load("audit_spec_test", ROOT / "tools/audit_spec.py")
        self.audit.ROOT, self.audit.SPEC = self.root, self.root / "spec"
        self.generator = load("lex_tables_test", ROOT / "tools/symgen/lex_tables.py")
        self.generator.ROOT = self.root

    def run_audit(self, freeze=False):
        return self.run_audit_text(freeze=freeze)[0]

    def run_audit_text(self, freeze=False):
        # 捕获审计输出，供负向用例断言精确诊断文本。
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            failed = self.audit.audit(freeze=freeze)
        return failed, output.getvalue()

    def append_error(self, text):
        path = self.root / "spec/proc/error.def"
        with path.open("a", encoding="utf-8") as output:
            output.write(text + "\n")

    def rewrite_error(self, old, new):
        # 整体改写夹具配置源，用于构造 format 缺失、版本不符与错位场景。
        path = self.root / "spec/proc/error.def"
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def replace_error_ref(self, old, new):
        # 只改已有登记项的 ref；追加新 entry 会落入保留码位，掩盖被测错误。
        self.rewrite_error(old, new)

    def test_scratch_isolated_from_repository(self):
        # 沙箱只允许依赖系统临时目录；仓库根 tmp/ 缺失或被并发写入都不影响门禁。
        self.assertTrue(self.root.is_relative_to(Path(tempfile.gettempdir()).resolve()))
        self.assertFalse(self.root.is_relative_to(ROOT), f"沙箱不得落在仓库内：{self.root}")
        self.assertTrue((self.root / "spec/proc/error.def").is_file())

    def test_baseline_audit(self):
        self.assertFalse(self.run_audit())

    def test_freeze_rejects_unmapped_rule(self):
        # 用无欠账夹具验证严格模式，不依赖真实规格始终留有待冻结条目。
        spec = self.root / "fixture"
        (spec / "proc").mkdir(parents=True)
        # 隔离夹具同样需要显式 format 声明，否则语法门禁会先报缺 format。
        (spec / "proc/error.def").write_text("format 2\n", encoding="utf-8")
        (spec / "index.md").write_text("| `sample.md` | 草案 | 隔离夹具 |\n", encoding="utf-8")
        doc = spec / "sample.md"
        text = "- 状态：草案\n- 依赖：无\n"
        doc.write_text(text, encoding="utf-8")
        self.audit.SPEC = spec
        self.assertFalse(self.run_audit(freeze=True))
        doc.write_text(text + "\n## 拒绝形态\n\n| SAMPLE-1 | 未映射形态 |\n", encoding="utf-8")
        self.assertFalse(self.run_audit())
        self.assertTrue(self.run_audit(freeze=True))

    def inactive_full_fixture(self, note, status="草案", level="full", condition="未映射形态"):
        # 单文档沙箱不继承真实规格欠账，能单独验证冻结拒绝原因。
        spec = self.root / "fixture"
        (spec / "proc").mkdir(parents=True, exist_ok=True)
        errors = spec / "proc/error.def"
        errors.write_text("format 2\n", encoding="utf-8")
        (spec / "index.md").write_text(
            f"| `sample.md` | {level} | {status} | 不适用 | 未实现 | 夹具；{note} |\n",
            encoding="utf-8",
        )
        text = f"- 状态：{status}\n- 级别：{level}\n- 依赖：无\n"
        if status != "缺失":
            text += f"\n## 拒绝形态\n\n| SAMPLE-1 | {condition} |\n"
        (spec / "sample.md").write_text(text, encoding="utf-8")
        self.audit.SPEC = spec
        return errors

    def test_inactive_full_placeholder_remains_missing(self):
        self.inactive_full_fixture("full 未激活", status="缺失")
        failed, output = self.run_audit_text()
        self.assertFalse(failed)
        self.assertIn("1 missing specs (1 inactive full)", output)
        self.assertTrue(self.run_audit(freeze=True))

    def test_inactive_full_rule_still_blocks_freeze(self):
        self.inactive_full_fixture("full 未激活：SAMPLE-1")
        failed, output = self.run_audit_text()
        self.assertFalse(failed)
        self.assertIn("0 rejection rows need code mapping, 1 inactive full rows", output)
        self.assertTrue(self.run_audit(freeze=True))

    def test_invalid_inactive_full_declarations_rejected(self):
        for note, level, message in (
            ("full 未激活：SAMPLE-1", "base", "requires an unimplemented full spec"),
            ("full 未激活：SAMPLE-2", "full", "inactive full rule not found in rejection table"),
            ("full 未激活：SAMPLE-1、SAMPLE-1", "full", "duplicate inactive full rejection rule"),
            ("full 未激活 SAMPLE-1", "full", "invalid inactive full declaration"),
        ):
            with self.subTest(note=note, level=level):
                self.inactive_full_fixture(note, level=level)
                failed, output = self.run_audit_text()
                self.assertTrue(failed)
                self.assertIn(message, output)

    def test_inactive_full_rule_cannot_hide_code(self):
        errors = self.inactive_full_fixture("full 未激活：SAMPLE-1")
        errors.write_text(
            'format 2\nsegment E10 name "夹具"\nentry E10 code 01 ref ../sample.md:SAMPLE-1 desc "夹具"\n',
            encoding="utf-8",
        )
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("SAMPLE-1: inactive full rule must not claim an error code", output)
        self.inactive_full_fixture("full 未激活：SAMPLE-1", condition="显式引用 E1001")
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("SAMPLE-1: inactive full rule must not claim an error code", output)

    def test_duplicate_code_rejected(self):
        self.append_error('entry E10 code 01 ref lex.md:L-1 desc "duplicate"')
        self.assertTrue(self.run_audit())

    def test_reserved_code_rejected(self):
        self.append_error('entry E10 code 99 ref lex.md:L-1 desc "reserved"')
        self.assertTrue(self.run_audit())

    def test_comments_and_blank_lines_allowed(self):
        # 空行与既有注释不属于指令，追加后仍应保持零结构错误。
        self.append_error("")
        self.append_error("# 既有注释允许")
        failed, output = self.run_audit_text()
        self.assertFalse(failed)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 0 structural errors$")

    def test_unknown_directive_rejected(self):
        # 配置源只允许四类声明指令，执行型语句按 ER-5 直接拒绝。
        self.append_error('exec "print(1)"')
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: unknown directive", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_indented_directive_rejected(self):
        # 前置空白不能绕过指令识别：缩进的 entry 仍按意外格式行拒绝。
        self.append_error('  entry E10 code 02 ref lex.md:L-1 desc "indented"')
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: unexpected indented line", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_indented_format_rejected(self):
        # format 也不能借前置空白混入：缩进写法不参与指令识别。
        self.append_error("  format 2")
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: unexpected indented line", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_entry_without_explicit_code_rejected(self):
        # 序号必须显式书写；缺 code 字段等隐式编号按 ER-5 拒绝。
        self.append_error('entry E10 ref lex.md:L-1 desc "implicit"')
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: entry missing explicit code", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_format_missing_rejected(self):
        # 配置源必须显式声明唯一 format 版本。
        self.rewrite_error("format 2\n", "")
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: missing format directive", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_format_version_rejected(self):
        # 现行配置格式为 2，其他版本不得被静默接受。
        self.rewrite_error("format 2", "format 1")
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: unsupported format directive format 1", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_format_duplicate_rejected(self):
        # format 只允许声明一次。
        self.append_error("format 2")
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: duplicate format directive format 2", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_format_misplaced_rejected(self):
        # format 必须位于首个段/预留/条目声明之前。
        self.rewrite_error("format 2\n\n", "")
        self.append_error("format 2")
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: misplaced format directive format 2", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_missing_anchor_rejected(self):
        # 改已有登记项的 ref，避免追加 entry 同时触发保留码位错误。
        self.replace_error_ref("ref lex.md:L-1 ", "ref lex.md:L-999 ")
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: missing rule lex.md:L-999", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_missing_reference_rejected(self):
        # 引用不存在的规格文件应只产生一条缺失引用错误。
        self.replace_error_ref("ref lex.md:L-1 ", "ref absent.md:L-1 ")
        failed, output = self.run_audit_text()
        self.assertTrue(failed)
        self.assertIn("error.def: missing reference absent.md:L-1", output)
        self.assertRegex(output, r"(?m)^spec audit: .*?, 1 structural errors$")

    def test_status_mismatch_rejected(self):
        path = self.root / "spec/lang/lex.md"
        path.write_text(path.read_text(encoding="utf-8").replace("- 状态：草案", "- 状态：确认"), encoding="utf-8")
        self.assertTrue(self.run_audit())

    def test_missing_dependency_rejected(self):
        (self.root / "spec/lang/symbol.md").unlink()
        self.assertTrue(self.run_audit())

    def test_generator_matches_and_filters_stage(self):
        actual = self.generator.generate()
        self.assertEqual(actual.encode(), (ROOT / "compiler/min/src/lex/lextables.yak").read_bytes())
        name_table = actual.split("export function name_builtin", 1)[1].split("export function builtin", 1)[0]
        self.assertIn('"u32"', name_table)
        self.assertNotIn('"string"', name_table)
        active = actual.split("export function builtin_is_base", 1)[1]
        self.assertIn("id == 20495", active)
        self.assertIn("id == 20496", active)
        self.assertIn("id == 20497", active)
        self.assertNotIn("id == 20487", active)

    def test_generator_rejects_duplicate_slot(self):
        path = self.root / "spec/lang/symbol.def"
        with path.open("a", encoding="utf-8") as output:
            output.write('entry functions slot 0x001 stage base kind primitive name "@other"\n')
        with self.assertRaises(ValueError):
            self.generator.generate()

    def check_generator_cli(self, *args):
        """在隔离目录执行生成入口并捕获两个标准流。"""
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = self.generator.main(args)
        return status, stdout.getvalue(), stderr.getvalue()

    def test_generator_rejects_partition_and_slot_overflow(self):
        """拒绝超出固有分区范围的分区码和码槽。

        rejection_spec: E7003 spec/lang/symbol.md#S-3
        """
        symbol = self.root / "spec/lang/symbol.def"
        original = symbol.read_bytes()
        self.generator.OUTPUT = self.root / "lextables.yak"
        cases = [
            ("partition overflow code 0x0 depends -", "固有符号分区码超出范围"),
            ("partition overflow code 0x8 depends -", "固有符号分区码超出范围"),
            ('entry type_symbols slot 0x000 stage base kind type name "bad"', "固有符号码槽超出分区范围"),
            ('entry type_symbols slot 0x1000 stage base kind type name "bad"', "固有符号码槽超出分区范围"),
        ]
        for entry, reason in cases:
            with self.subTest(entry=entry):
                symbol.write_bytes(original + entry.encode() + b"\n")
                self.assertEqual(self.check_generator_cli(), (1, "", f"E7003 {reason}\n"))
                self.assertFalse(self.generator.OUTPUT.exists())

    def test_generator_refuses_changes_to_fixed_bit_fields(self):
        """拒绝越过固有编号分区和类型关联常量的块内位宽。

        rejection_spec: E7014 spec/lang/symbol.md#S-14
        """
        symbol = self.root / "spec/lang/symbol.def"
        original = symbol.read_text(encoding="utf-8")
        self.generator.OUTPUT = self.root / "lextables.yak"
        self.assertEqual(self.check_generator_cli()[0], 0)
        generated = self.generator.OUTPUT.read_bytes()
        cases = (
            ("code 0x1 depends -", "code 0x2 depends -", "固有符号分区码偏离固定布局"),
            ('value_slot 0x1 name "max"', 'value_slot 0x9 name "max"', "类型关联常量成员超出八槽布局"),
            ("block 0x001 enable", "block 0x200 enable", "类型关联常量超出块号或成员布局"),
            ("block 0x001 enable 0x1,0x2", "block 0x001 enable 0x1,0x9", "类型关联常量超出块号或成员布局"),
        )
        for valid, invalid, reason in cases:
            with self.subTest(invalid=invalid):
                self.assertIn(valid, original)
                symbol.write_text(original.replace(valid, invalid, 1), encoding="utf-8", newline="\n")
                status, stdout, stderr = self.check_generator_cli()
                self.assertEqual((status, stdout), (1, ""))
                self.assertTrue(stderr.startswith(f"E7014 {reason}（第 "), stderr)
                self.assertEqual(self.generator.OUTPUT.read_bytes(), generated)

    def test_generator_rejects_keywords_in_symbol_config(self):
        """拒绝向符号配置重复登记词法关键字和占位字。

        rejection_spec: E7005 spec/lang/symbol.md#S-5
        """
        symbol = self.root / "spec/lang/symbol.def"
        original = symbol.read_bytes()
        self.generator.OUTPUT = self.root / "lextables.yak"
        self.generator.OUTPUT.write_bytes(b"previous\n")
        cases = [
            ('entry type_symbols slot 0x012 stage base kind type name "function"', "固有符号配置登记了关键字或保留字：function"),
            ('entry type_symbols slot 0x012 stage full kind type name "null"', "固有符号配置登记了关键字或保留字：null"),
            ('enum_variant host "AllocError" id 1 stage base name "while"', "固有枚举标签登记了关键字或保留字：while"),
            ('value_slot 0x6 name "loop"', "固有值槽登记了关键字或保留字：loop"),
        ]
        for entry, reason in cases:
            with self.subTest(entry=entry):
                symbol.write_bytes(original + entry.encode() + b"\n")
                self.assertEqual(self.check_generator_cli(), (1, "", f"E7005 {reason}\n"))
                self.assertEqual(self.generator.OUTPUT.read_bytes(), b"previous\n")

    def test_interface_audit_rejects_randomized_hash_seed(self):
        """四类名称记录必须按规格固定初值计算。

        rejection_spec: E7002 spec/lang/symbol.md#S-2
        """
        tool = load("interface_audit_test", ROOT / "test/gate/base_selfhost_evidence.py")
        names = b"hello"
        initial = 14695981039346656037
        wrong = initial ^ 0xA5A55A5A55AA55AA
        for byte in names:
            wrong = ((wrong ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        for kind, (width, name_field, hash_field) in {
            4: (32, 0, 8), 8: (32, 4, 24), 13: (32, 4, 24), 15: (16, 0, 8),
        }.items():
            with self.subTest(kind=kind):
                records = {key: {"offset": 0, "length": 0, "count": 0} for key in (4, 8, 13, 15)}
                records[kind] = {"offset": 0, "length": width, "count": 1}
                image = bytearray(width)
                struct.pack_into("<IH", image, name_field, 0, len(names))
                struct.pack_into("<Q", image, hash_field, 11831194018420276491)
                self.assertIsNone(tool.check_interface_name_hashes(image, names, records))
                struct.pack_into("<Q", image, hash_field, wrong)
                with self.assertRaisesRegex(tool.AuditError, rf"^E7002 YKIF 第 {kind} 节记录 1 "):
                    tool.check_interface_name_hashes(image, names, records)

    def test_ykm_audit_rejects_unit_and_dependency_profile_mismatch(self):
        """同一单元和两种依赖 profile 宽度均需比较，不能截断高位。"""
        tool = load("profile_audit_test", ROOT / "test/gate/base_selfhost_evidence.py")
        clean_leaf, _ = tool.build_ykif("leaf", [])
        leaf_path = self.root / "leaf.iface"
        root_path = self.root / "root.iface"
        ysm_path = self.root / "root.ysm"
        for unit_profile, leaf_profile, mirror_profile, expected in (
            (0x00010001, 0x00010001, 0x0101, []),
            (0x00010001, 0x00010001, 0x0102, ["unit_profile", "target_profile"]),
            (0x00010001, 0x00010101, 0x0101, ["target_profile"]),
            (0x01010001, 0x00010001, 0x0101, ["unit_profile"]),
        ):
            with self.subTest(profile=(unit_profile, leaf_profile, mirror_profile)):
                leaf_data = bytearray(clean_leaf)
                struct.pack_into("<I", leaf_data, 8, leaf_profile)
                leaf_digest = tool.digest_zeroed(leaf_data, tool.YKIF_DIGEST_OFFSET)
                leaf_data[24:56] = bytes.fromhex(leaf_digest)
                leaf_path.write_bytes(leaf_data)
                root_data = bytearray(tool.build_ykif("root", [("leaf", leaf_digest)])[0])
                struct.pack_into("<I", root_data, 8, unit_profile)
                root_data[24:56] = bytes.fromhex(tool.digest_zeroed(root_data, tool.YKIF_DIGEST_OFFSET))
                root_path.write_bytes(root_data)
                ysm_data = bytearray(tool.build_yksm([leaf_digest])[0])
                struct.pack_into("<H", ysm_data, 10, mirror_profile)
                ysm_data[28:60] = bytes.fromhex(tool.digest_zeroed(ysm_data, tool.YKSM_DIGEST_OFFSET))
                ysm_path.write_bytes(ysm_data)
                report = {"failures": []}
                tool.verify_unit("fixture", "main", "root", tool.parse_ykif(root_path), tool.parse_yksm(ysm_path),
                                 {"leaf": tool.parse_ykif(leaf_path)}, {"leaf": ["leaf"]}, report)
                self.assertEqual([failure["kind"] for failure in report["failures"]], expected)
                self.assertTrue(all(failure["message"].startswith("E7030 ") for failure in report["failures"]))

    def test_generator_rejects_user_names_in_builtin_partitions(self):
        """拒绝限定用户名、普通模块名及试图直接占用保留槽的用户类型。

        rejection_spec: E7004 spec/lang/symbol.md#S-4
        """
        symbol = self.root / "spec/lang/symbol.def"
        original = symbol.read_bytes()
        self.generator.OUTPUT = self.root / "lextables.yak"
        generated = self.generator.generate().encode()
        self.generator.OUTPUT.write_bytes(generated)
        for entry, reason in (
            ('entry type_symbols slot 0x012 stage base kind type name "user::Record"',
             "普通模块名称不得登记为固有符号：user::Record"),
            ('entry modules slot 0x001 stage full kind module name "user"',
             "普通模块名称不得登记为固有符号：user"),
            ('entry type_symbols slot 0x012 stage base kind type name "UserRecord"',
             "名称占用了仍保留的固有符号码槽：UserRecord"),
            ('entry lang_items slot 0x005 stage full kind lang_item name "UserItem"',
             "名称占用了仍保留的固有符号码槽：UserItem"),
        ):
            with self.subTest(entry=entry):
                symbol.write_bytes(original + entry.encode() + b"\n")
                self.assertEqual(self.check_generator_cli(), (1, "", f"E7004 {reason}\n"))
                self.assertEqual(self.generator.OUTPUT.read_bytes(), generated)

    def test_generator_rejects_implicit_slots_and_executable_directives(self):
        """拒绝隐式码槽、执行式声明和未登记的派生规则。

        rejection_spec: E7017 spec/lang/symbol.md#S-17
        """
        symbol = self.root / "spec/lang/symbol.def"
        original = symbol.read_bytes()
        self.generator.OUTPUT = self.root / "lextables.yak"
        cases = [
            'entry type_symbols stage base kind type name "new_type"',
            'exec "run generator"',
            'derive kind_consts mode execute source type_symbols',
            'reserve functions from 0x010 to 0xFFF execute',
            'value_slot next name "new_value"',
        ]
        for entry in cases:
            with self.subTest(entry=entry):
                symbol.write_bytes(original + entry.encode() + b"\n")
                status, stdout, stderr = self.check_generator_cli()
                self.assertEqual((status, stdout), (1, ""))
                self.assertTrue(stderr.startswith("E7017 "))
                self.assertIn(f"第 {len(original.splitlines()) + 1} 行", stderr)
                self.assertFalse(self.generator.OUTPUT.exists())

    def test_generator_rejects_ordinary_standard_library_functions(self):
        """仅语言原语可进入函数分区，标准库成员走普通模块。

        rejection_spec: E7016 spec/lang/symbol.md#S-16
        """
        symbol = self.root / "spec/lang/symbol.def"
        original = symbol.read_bytes()
        self.generator.OUTPUT = self.root / "lextables.yak"
        generated = self.generator.generate().encode()
        self.generator.OUTPUT.write_bytes(generated)
        for name in ("swap", "std::mem::swap", "@std::mem::swap", "write"):
            with self.subTest(name=name):
                entry = f'entry functions slot 0x010 stage base kind primitive name "{name}"\n'
                symbol.write_bytes(original + entry.encode("utf-8"))
                result = self.check_generator_cli()
                self.assertEqual(result, (1, "", f"E7016 普通模块函数不得登记为固有原语：{name}\n"))
                self.assertEqual(self.generator.OUTPUT.read_bytes(), generated)

    def test_generator_check_refuses_stale_table(self):
        """配置漂移或生成字节损坏时，校验拒绝且保持已有文件。"""
        path = self.generator.OUTPUT = self.root / "lextables.yak"
        original = self.generator.generate().encode()
        path.write_bytes(original)
        self.assertEqual(self.check_generator_cli("--check")[0], 0)
        independent = original.replace(b"return 4099;", b"return 4999;", 1)
        self.assertNotEqual(independent, original)
        path.write_bytes(independent)
        status, stdout, stderr = self.check_generator_cli("--check")
        self.assertEqual((status, stdout), (1, ""))
        self.assertTrue(stderr.startswith("E7010 "))
        self.assertEqual(path.read_bytes(), independent)
        path.write_bytes(original)
        symbol = self.root / "spec/lang/symbol.def"
        symbols = symbol.read_bytes()
        changed = symbols.replace(b'name "@push"', b'name "@pushChanged"', 1)
        self.assertNotEqual(symbols, changed)
        symbol.write_bytes(changed)
        status, stdout, stderr = self.check_generator_cli("--check")
        self.assertEqual((status, stdout), (1, ""))
        self.assertTrue(stderr.startswith("E7010 "))
        self.assertEqual(path.read_bytes(), original)

    def prepare_symbol_artifact(self):
        """构造带正确符号表摘要的最小只读 PE32+ 产物。"""
        generator = self.generator
        generator.OUTPUT = self.root / "lextables.yak"
        text, digest = generator.build_table()
        generator.OUTPUT.write_bytes(text.encode())
        prefix = generator.ARTIFACT_DIGEST_PREFIX
        record = prefix + digest.encode("ascii") + generator.ARTIFACT_DIGEST_SUFFIX
        self.assertEqual(text.encode().count(record), 1)

        # 只设与加载边界有关的 PE32+ 头、只读节和原始数据。
        image = bytearray(1024)
        image[:2] = b"MZ"
        struct.pack_into("<I", image, 60, 128)
        image[128:132] = b"PE\0\0"
        struct.pack_into("<HH", image, 132, 0x8664, 1)
        struct.pack_into("<H", image, 148, 240)
        struct.pack_into("<H", image, 152, 0x20B)
        image[392:400] = b".rdata\0\0"
        struct.pack_into("<IIII", image, 400, 256, 4096, 512, 512)
        struct.pack_into("<I", image, 428, 0x40000040)
        image[512:512 + len(record)] = record
        artifact = self.root / "main.exe"
        artifact.write_bytes(image)
        return artifact, image, text, prefix, record

    def test_generator_check_artifact_refuses_drift(self):
        """产物只接受配置对应的唯一只读摘要，失败后保留原字节。

        rejection_spec: E7010 spec/lang/symbol.md#S-10
        """
        artifact, image, text, prefix, record = self.prepare_symbol_artifact()
        self.assertEqual(self.check_generator_cli("--check-artifact", str(artifact))[0], 0)

        changed = bytearray(image)
        changed[512 + len(prefix)] = ord("1") if changed[512 + len(prefix)] == ord("0") else ord("0")
        for payload, reason in (
            (changed, "与配置源不一致"),
            (image.replace(record, bytes(len(record))) + record, "标识缺失或重复"),
            (image + record, "标识缺失或重复"),
        ):
            with self.subTest(reason=reason):
                artifact.write_bytes(payload)
                status, stdout, stderr = self.check_generator_cli("--check-artifact", str(artifact))
                self.assertEqual((status, stdout), (1, ""))
                self.assertTrue(stderr.startswith("E7010 "))
                self.assertIn(reason, stderr)
                self.assertEqual(artifact.read_bytes(), payload)
                self.assertEqual(self.generator.OUTPUT.read_bytes(), text.encode())

    def test_generator_rejects_nonzero_pe_timestamp(self):
        """仅改变 PE 文件头时间戳就必须拒绝，不能改写原产物。

        rejection_spec: E8010 spec/target/pe.md#PE-1
        """
        artifact, image, text, _, _ = self.prepare_symbol_artifact()
        self.assertEqual(self.check_generator_cli("--check-artifact", str(artifact))[0], 0)
        pe = struct.unpack_from("<I", image, 60)[0]
        for stamp in (1, 0x80000000):
            with self.subTest(stamp=stamp):
                struct.pack_into("<I", image, pe + 8, stamp)
                artifact.write_bytes(image)
                status, stdout, stderr = self.check_generator_cli("--check-artifact", str(artifact))
                self.assertEqual((status, stdout, stderr), (1, "", "E8010 PE TimeDateStamp 非零\n"))
                self.assertEqual(artifact.read_bytes(), image)
                self.assertEqual(self.generator.OUTPUT.read_bytes(), text.encode())


    @staticmethod
    def make_coff_section_fixture():
        header = bytearray(140)
        struct.pack_into("<HH", header, 0, 0x8664, 3)
        for offset, name, flags in (
            (20, b".text", 0x60000020),
            (60, b".rdata", 0x40000040),
            (100, b".data", 0xC0000040),
        ):
            header[offset:offset + len(name)] = name
            struct.pack_into("<I", header, offset + 36, flags)
        return header

    def test_coff_sections_reject_unknown_name_or_flags(self):
        """单独改变一个节名或属性即拒绝，不改写输入对象。

        rejection_spec: E8011 spec/target/pe.md#PE-2
        """
        artifact = self.root / "unit.obj"
        original = self.make_coff_section_fixture()
        command = [sys.executable, "-X", "utf8", str(ROOT / "tools/coff_sections.py"), str(artifact)]
        artifact.write_bytes(original)
        result = subprocess.run(command, capture_output=True, encoding="utf-8", check=False)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertEqual(artifact.read_bytes(), original)
        for offset, patch, reason in (
            (2, struct.pack("<H", 2), "节数 2，应为 3"),
            (20, b".bss\0\0\0\0", "未知节名 b'.bss'"),
            (100, b".rdata\0\0", "重复节名 b'.rdata'"),
            (56, struct.pack("<I", 0x40000020), "节 b'.text' 属性 0x40000020，应为 0x60000020"),
            (96, struct.pack("<I", 0xC0000040), "节 b'.rdata' 属性 0xc0000040，应为 0x40000040"),
            (136, struct.pack("<I", 0xE0000040), "节 b'.data' 属性 0xe0000040，应为 0xc0000040"),
            (136, struct.pack("<I", 0xC0000041), "节 b'.data' 属性 0xc0000041，应为 0xc0000040"),
        ):
            with self.subTest(reason=reason):
                changed = original.copy()
                changed[offset:offset + len(patch)] = patch
                artifact.write_bytes(changed)
                result = subprocess.run(command, capture_output=True, encoding="utf-8", check=False)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (1, "", f"E8011 {artifact}: {reason}\n"))
                self.assertEqual(artifact.read_bytes(), changed)

    def test_coff_sections_reject_truncation_and_other_formats(self):
        checker = load("coff_sections_test", ROOT / "tools/coff_sections.py")
        header = self.make_coff_section_fixture()
        non_object = header.copy()
        struct.pack_into("<H", non_object, 16, 240)
        for image, reason in ((header[:19], "COFF 文件头截断"),
                              (header[:-1], "COFF 节表截断"),
                              (b"MZ" + header[2:], "不是 Yak Win64 AMD64 COFF 对象"),
                              (non_object, "不是 Yak Win64 AMD64 COFF 对象")):
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(ValueError, reason) as ctx:
                    checker.check_coff_sections(image)
                self.assertNotIsInstance(ctx.exception, checker.CoffSectionError)

    def test_coff_relocations_reject_type_width_and_local_addend(self):
        """分别篡改合法对象的一种重定位属性，只拒绝不改写。

        rejection_spec: E8012 spec/target/pe.md#PE-3
        """
        original = self.make_coff_section_fixture()
        raw, size = len(original), 24
        table, count = raw + size, 5
        symtab = table + count * 10
        struct.pack_into("<II", original, 8, symtab, 2)
        struct.pack_into("<III", original, 36, size, raw, table)
        struct.pack_into("<H", original, 52, count)
        original.extend(bytearray(size + count * 10 + 2 * 18 + 4))
        for index, fields in enumerate(((0, 0, 4), (4, 1, 1), (12, 0, 4), (16, 1, 4), (20, 1, 3))):
            struct.pack_into("<IIH", original, table + index * 10, *fields)
        struct.pack_into("<8sIhHBB", original, symtab, b"local", 8, 1, 0, 3, 0)
        struct.pack_into("<8sIhHBB", original, symtab + 18, b"external", 0, 0, 0, 2, 0)
        struct.pack_into("<I", original, symtab + 36, 4)
        # 两个同节位移分别贴住正、负边界；外部符号此时不能判定位移。
        struct.pack_into("<i", original, raw, 2147483643)
        struct.pack_into("<i", original, raw + 12, -2147483640)
        struct.pack_into("<i", original, raw + 16, 2147483647)
        artifact = self.root / "relocations.obj"
        command = [sys.executable, "-X", "utf8", str(ROOT / "tools/coff_sections.py"),
                   "--relocations", str(artifact)]
        artifact.write_bytes(original)
        result = subprocess.run(command, capture_output=True, encoding="utf-8", check=False)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertEqual(artifact.read_bytes(), original)
        for offset, fmt, value, reason in (
            (table + 8, "<H", 2, "重定位 1 类型 0x0002 不受支持"),
            (table, "<I", 21, "重定位 1 的 4 字节字段超出节范围（偏移 21，节长 24）"),
            (table + 10, "<I", 17, "重定位 2 的 8 字节字段超出节范围（偏移 17，节长 24）"),
            (raw, "<i", 2147483644, "重定位 1 的同节 REL32 加数使位移 2147483648 超出 32 位有符号范围"),
            (raw + 12, "<i", -2147483641, "重定位 3 的同节 REL32 加数使位移 -2147483649 超出 32 位有符号范围"),
        ):
            with self.subTest(reason=reason):
                changed = original.copy()
                struct.pack_into(fmt, changed, offset, value)
                artifact.write_bytes(changed)
                result = subprocess.run(command, capture_output=True, encoding="utf-8", check=False)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (1, "", f"E8012 {artifact}: 节 b'.text' {reason}\n"))
                self.assertEqual(artifact.read_bytes(), changed)

        checker = load("coff_relocations_test", ROOT / "tools/coff_sections.py")
        for offset, value, reason in (
            (40, len(original), "原始数据超出对象"),
            (44, len(original), "重定位表超出对象"),
            (8, len(original), "COFF 符号表超出对象"),
            (table + 4, 2, "符号下标 2 超出符号表"),
        ):
            with self.subTest(reason=reason):
                changed = original.copy()
                struct.pack_into("<I", changed, offset, value)
                with self.assertRaisesRegex(ValueError, reason) as ctx:
                    checker.check_coff_relocations(bytes(changed))
                self.assertNotIsInstance(ctx.exception, checker.CoffRelocationError)


    @staticmethod
    def make_coff_symbol_fixture():
        image = ContractGates.make_coff_section_fixture()
        strings = b"yak_rt_try_write\0yak$entry\0"
        struct.pack_into("<II", image, 8, len(image), 3)
        for name, section, kind, storage in (
            (struct.pack("<II", 0, 4), 0, 32, 2),
            (struct.pack("<II", 0, 4 + len(b"yak_rt_try_write\0")), 1, 32, 2),
            (b"$s0", 2, 0, 3),
        ):
            image.extend(struct.pack("<8sIhHBB", name, 0, section, kind, storage, 0))
        image.extend(struct.pack("<I", 4 + len(strings)) + strings)
        return image

    def test_coff_symbols_reject_reordered_link_ids(self):
        """交换两条完整记录即拒绝；长名、短名与原始文件保持不变。

        rejection_spec: E8013 spec/target/pe.md#PE-4
        """
        original = self.make_coff_symbol_fixture()
        artifact = self.root / "symbol-order.obj"
        command = [sys.executable, "-X", "utf8", str(ROOT / "tools/coff_sections.py"),
                   "--symbol-order", "yak_rt_try_write", "--symbol-order", "yak$entry",
                   "--symbol-order", "$s0", str(artifact)]
        artifact.write_bytes(original)
        result = subprocess.run(command, capture_output=True, encoding="utf-8", check=False)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertEqual(artifact.read_bytes(), original)

        symtab, = struct.unpack_from("<I", original, 8)
        changed = original.copy()
        changed[symtab:symtab + 36] = original[symtab + 18:symtab + 36] + original[symtab:symtab + 18]
        artifact.write_bytes(changed)
        result = subprocess.run(command, capture_output=True, encoding="utf-8", check=False)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, "", f"E8013 {artifact}: 符号 1 为 b'yak$entry'，应为 b'yak_rt_try_write'\n"))
        self.assertEqual(artifact.read_bytes(), changed)

    def test_coff_symbols_require_valid_table_and_complete_oracle(self):
        checker = load("coff_symbol_order_test", ROOT / "tools/coff_sections.py")
        image = self.make_coff_symbol_fixture()
        names = [b"yak_rt_try_write", b"yak$entry", b"$s0"]
        symtab, = struct.unpack_from("<I", image, 8)
        malformed = image.copy()
        struct.pack_into("<I", malformed, symtab + 4, 5)
        for content, expected, reason in (
            (image[:-1], names, "字符串表长度无效"),
            (malformed, names, "长名偏移无效"),
            (image, names[1:], "符号集合与夹具给定的完整预期不符"),
        ):
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(ValueError, reason) as ctx:
                    checker.check_coff_symbol_order(bytes(content), expected)
                self.assertNotIsInstance(ctx.exception, checker.CoffSymbolOrderError)

    @staticmethod
    def make_runtime_pe(library=b"KERNEL32.dll", function=b"WriteFile", *, delayed=False):
        pe, opt_size, raw, rva = 64, 240, 512, 0x1000
        opt = pe + 24
        section = opt + opt_size
        image = bytearray(1024)
        image[:2] = b"MZ"
        struct.pack_into("<I", image, 60, pe)
        image[pe:pe + 4] = b"PE\0\0"
        struct.pack_into("<HH", image, pe + 4, 0x8664, 1)
        struct.pack_into("<H", image, pe + 20, opt_size)
        struct.pack_into("<H", image, opt, 0x20B)
        struct.pack_into("<Q", image, opt + 24, 0x140000000)
        struct.pack_into("<I", image, opt + 108, 16)
        image[section:section + 6] = b".idata"
        struct.pack_into("<IIII", image, section + 8, 512, rva, 512, raw)
        if delayed:
            struct.pack_into("<II", image, opt + 112 + 8 * 13, rva, 64)
            struct.pack_into("<8I", image, raw, 1, rva + 0xA0, 0, rva + 0x80, rva + 0x60, 0, 0, 0)
        else:
            struct.pack_into("<II", image, opt + 112 + 8, rva, 40)
            struct.pack_into("<5I", image, raw, rva + 0x60, 0, 0, rva + 0xA0, rva + 0x80)
        for table in (raw + 0x60, raw + 0x80):
            struct.pack_into("<Q", image, table, rva + 0xC0)
        image[raw + 0xA0:raw + 0xA0 + len(library)] = library
        image[raw + 0xC2:raw + 0xC2 + len(function)] = function
        return image

    def run_runtime_artifact(self, path, mode, content, code=None):
        path.write_bytes(content)
        command = [sys.executable, "-X", "utf8", str(ROOT / "tools/coff_sections.py"), mode, str(path)]
        result = subprocess.run(command, capture_output=True, encoding="utf-8", check=False)
        self.assertEqual(path.read_bytes(), content)
        if code:
            self.assertEqual((result.returncode, result.stdout), (1, ""))
            self.assertTrue(result.stderr.startswith(code + " "), result.stderr)
        else:
            expected = "relative\n" if mode == "--link-plan" else ""
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, expected, ""))
        return result.stderr

    def test_runtime_symbol_containers_and_dependencies_rejected(self):
        """COFF 和 PE 均拒绝完整容器，PE 拒绝直接及延迟加载的接口依赖。

        rejection_spec: E7007 spec/lang/symbol.md#S-7
        """
        exe, obj = self.root / "image.exe", self.root / "unit.obj"
        image = self.make_runtime_pe()
        coff = self.make_coff_symbol_fixture()
        evidence = load("runtime_iface_fixture", ROOT / "test/gate/base_selfhost_evidence.py")
        interface, _ = evidence.build_ykif("fixture", [])
        head = struct.pack("<4sHHIHHII32s", b"YKSM", 2, 0, 0, 6, 0, 56, 152, bytes(32))
        audit = bytearray(head + b"".join(struct.pack("<HHIII", kind, 0, 152, 0, 0)
                                         for kind in range(0x101, 0x107)))
        audit[24:56] = hashlib.sha256(audit).digest()
        ordinary = b"fixture.sym fixture.iface YKIF YKSM GetProcAddress\0"
        for path, mode, base in ((exe, "--runtime-pe", image), (obj, "--link-plan", coff)):
            self.run_runtime_artifact(path, mode, base + ordinary)
            for magic, container in (("YKIF", interface), ("YKSM", audit)):
                with self.subTest(path=path, magic=magic):
                    self.assertIn(magic, self.run_runtime_artifact(path, mode, base + container, "E7007"))
                    damaged = bytearray(container)
                    damaged[24] ^= 1
                    self.run_runtime_artifact(path, mode, base + damaged)
                    struct.pack_into("<I", damaged, 60, 0)
                    damaged[24:56] = bytes(32)
                    damaged[24:56] = hashlib.sha256(damaged).digest()
                    self.run_runtime_artifact(path, mode, base + damaged)
        for pe, diagnostic in (
            (self.make_runtime_pe(b"fixture.SYM"), "fixture.sym"),
            (self.make_runtime_pe(b"types.iface", delayed=True), "types.iface"),
            (self.make_runtime_pe(function=b"CreateFileA"), "CreateFileA"),
            (self.make_runtime_pe(delayed=True), "延迟加载"),
        ):
            with self.subTest(diagnostic=diagnostic):
                self.assertIn(diagnostic, self.run_runtime_artifact(exe, "--runtime-pe", pe, "E7007"))

    def test_runtime_symbol_lookup_rejected(self):
        """发布映像拒绝查询 API 以及可供运行期使用的 COFF 符号表。

        rejection_spec: E7008 spec/lang/symbol.md#S-8
        """
        exe = self.root / "image.exe"
        image = self.make_runtime_pe()
        self.run_runtime_artifact(exe, "--runtime-pe", image)
        struct.pack_into("<II", image, 64 + 12, len(image), 1)
        image.extend(struct.pack("<8sIhHBBI", b"lookup", 0, 1, 0, 2, 0, 4))
        for pe, diagnostic in (
            (image, "COFF 符号表"),
            (self.make_runtime_pe(function=b"GetProcAddress"), "GetProcAddress"),
            (self.make_runtime_pe(b"DBGHELP.dll", b"SymFromAddr", delayed=True), "dbghelp.dll"),
            (self.make_runtime_pe(b"ntdll.dll", b"LdrGetProcedureAddress"), "LdrGetProcedureAddress"),
        ):
            with self.subTest(diagnostic=diagnostic):
                self.assertIn(diagnostic, self.run_runtime_artifact(exe, "--runtime-pe", pe, "E7008"))


if __name__ == "__main__":
    unittest.main()
