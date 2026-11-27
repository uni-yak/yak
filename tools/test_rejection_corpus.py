"""拒绝形态语料覆盖审计的定向测试。

全部用例在系统临时目录构造最小规格与负例，不读写仓库真实语料；
覆盖未知锚点、错误码错配、重复锚点、门禁断言、别名与多形态覆盖、
依赖规则、缺失规格、确定性和 --check 退出码。
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools/rejection_corpus.py"
sys.dont_write_bytecode = True


def load_tool():
    """按路径加载审计模块；注册 sys.modules 以兼容 dataclasses 解析注解。"""
    spec = importlib.util.spec_from_file_location("rejection_corpus_under_test", TOOL)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


MODULE = load_tool()


class CorpusCase(unittest.TestCase):
    """提供最小规格、错误码真源与负例夹具的构造辅助。"""

    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="yak-rejection-corpus-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.assertFalse(self.root.is_relative_to(ROOT), f"沙箱不得落在仓库内：{self.root}")
        self.write("spec/proc/error.def", "format 2\n")
        self.write("spec/index.md", "# spec/index\n")
        (self.root / "test/bad").mkdir(parents=True, exist_ok=True)

    def write(self, rel, text):
        """写入 UTF-8、LF 文本，并自动创建父目录。"""
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")

    def read(self, rel):
        """读取夹具文本，用于追加错误码条目。"""
        return (self.root / rel).read_text(encoding="utf-8")

    def add_doc(self, rel, rows=(), status="草案", rejection_class=None, extra=""):
        """构造一份含拒绝形态表的规格文档。"""
        lines = [f"# {rel}", "", f"- 状态：{status}", ""]
        if rejection_class:
            lines.extend([f"- 拒绝形态类别：{rejection_class}", ""])
        lines.extend(["## 12 拒绝形态", "", "| 编号 | 说明 |", "|:---|:---|"])
        for anchor, content in rows:
            lines.append(f"| {anchor} | {content} |")
        if extra:
            lines.extend(["", extra])
        self.write("spec/" + rel, "\n".join(lines) + "\n")

    def add_entry(self, code, ref):
        """向 error.def 追加一条登记；code 形如 E1001。"""
        line = f'entry {code[:3]} code {code[3:]} ref {ref} desc "拒绝形态"'
        current = self.read("spec/proc/error.def").rstrip("\n")
        self.write("spec/proc/error.def", current + "\n" + line + "\n")

    def add_fixture(
        self,
        code,
        name="case.yak",
        spec=None,
        diagnostics=None,
        deps=(),
        directory=None,
        body="fn main() {}\n",
    ):
        """构造一个负例根；directory 可与 expected_code 不同以测试错目录。"""
        folder = directory or code
        lines = []
        if spec is not None:
            lines.append(f"// spec: {spec}")
        if diagnostics is not None:
            lines.append("// expected_diagnostics: " + " ".join(diagnostics))
        for dep in deps:
            lines.append(f"// dependency: {dep}")
        lines.append(f"// expected_code: {code}")
        lines.append("// 触发：定向测试")
        self.write(f"test/bad/{folder}/{name}", "\n".join(lines) + "\n\n" + body)

    def add_dependency(self, directory, name, text="fn helper() {}\n"):
        """构造同目录成功依赖单元。"""
        self.write(f"test/bad/{directory}/{name}", text)

    def report(self):
        """构建审计报告。"""
        return MODULE.build_report(self.root)

    def test_seed_host_groups_cover_only_exact_diagnostics(self):
        self.add_doc("proc/host.md", [("HS-1", "登记非法"), ("HS-2", "实参越界")])
        self.add_entry("E9206", "host.md:HS-1")
        self.add_entry("E9207", "host.md:HS-2")
        self.write(MODULE.HOST_SUITE,
                   "cover E9206 spec/proc/host.md#HS-1\n"
                   "reject bad_option 'E9206 host: unknown option' \"$entry\"\n"
                   "cover E9207 spec/proc/host.md#HS-2\n")
        report = self.report()
        self.assertEqual(report["totals"]["covered"], 1)
        self.assertEqual(report["fixtures"]["host"][0]["cases"], 1)
        self.assertEqual([error["code"] for error in report["errors"]], ["empty_host_cover"])

    def test_seed_host_groups_reject_wrong_code_and_duplicate_case_name(self):
        self.add_doc("proc/host.md", [("HS-1", "登记非法")])
        self.add_entry("E9206", "host.md:HS-1")
        self.write(MODULE.HOST_SUITE,
                   "cover E9206 spec/proc/host.md#HS-1\n"
                   "reject bad_option 'E9206 host: unknown option' \"$entry\"\n"
                   "reject bad_option 'E9206 host: unknown option' \"$entry\"\n"
                   "reject wrong 'E9207 host: argument index out of bounds' \"$entry\"\n")
        report = self.report()
        self.assertEqual(report["totals"]["covered"], 0)
        self.assertEqual([error["code"] for error in report["errors"]], ["invalid_host_case"] * 2)

    def test_foreign_runtime_counts_only_both_exact_traps(self):
        self.add_doc("lang/foreign.md", [("F-4", "服务失败未陷阱")])
        self.add_entry("E9203", "../lang/foreign.md:F-4")
        suite = MODULE.FOREIGN_TRAP_SUITE
        valid = ("# runtime_spec: E9203 spec/lang/foreign.md#F-4\n"
                 "    check_foreign_trap 5 read 70 'yak: read failed'\n"
                 "    check_foreign_trap 6 write 70 'yak: write failed'\n")
        self.write(suite, valid)
        result = self.report()
        self.assertFalse(result["errors"])
        self.assertEqual(result["totals"]["covered"], 1)
        self.assertEqual(result["snapshot"]["fixture_roots"], 0)
        self.assertEqual(result["fixtures"]["runtime"][0]["services"], ["read", "write"])
        for changed in ("5 write 70 'yak: write failed'", "6 write 71 'yak: write failed'",
                        "6 write 70 'yak: read failed'"):
            with self.subTest(changed=changed):
                self.write(suite, valid.replace("6 write 70 'yak: write failed'", changed))
                result = self.report()
                self.assertEqual(result["totals"]["covered"], 0)
                self.assertIn("invalid_foreign_trap_case", [error["code"] for error in result["errors"]])

    def test_foreign_runtime_rejects_misregistered_spec_code(self):
        self.add_doc("lang/foreign.md", [("F-4", "服务失败未陷阱"), ("F-3", "实参非法")])
        self.add_entry("E9203", "../lang/foreign.md:F-4")
        self.add_entry("E9202", "../lang/foreign.md:F-3")
        self.write(MODULE.FOREIGN_TRAP_SUITE,
                   "# runtime_spec: E9202 spec/lang/foreign.md#F-4\n"
                   "    check_foreign_trap 5 read 70 'yak: read failed'\n"
                   "    check_foreign_trap 6 write 70 'yak: write failed'\n")
        result = self.report()
        self.assertEqual(result["totals"]["covered"], 0)
        self.assertEqual([error["code"] for error in result["errors"]], ["code_anchor_mismatch"])
        suite = MODULE.FOREIGN_TRAP_SUITE
        self.write(suite, self.read(suite).replace("foreign.md#F-4", "foreign.md#F-3"))
        result = self.report()
        self.assertEqual(result["totals"]["covered"], 0)
        self.assertEqual([error["code"] for error in result["errors"]], ["invalid_runtime_spec"])

    def test_tool_coverage_requires_registered_test_and_assertion(self):
        self.add_doc("lang/symbol.md", [("S-3", "分区越界"), ("S-5", "重登词法关键字")])
        self.add_entry("E7003", "../lang/symbol.md:S-3")
        self.add_entry("E7005", "../lang/symbol.md:S-5")
        self.write(MODULE.TOOL_SUITE,
                   "import unittest\n"
                   "class ContractGates(unittest.TestCase):\n"
                   "    def test_partition(self):\n"
                   '        """拒绝分区越界。\n\n'
                   "        rejection_spec: E7003 spec/lang/symbol.md#S-3\n"
                   '        """\n'
                   "        self.assertEqual(check(), 1)\n"
                   "    def test_keyword(self):\n"
                   '        """缺少断言时应拒绝。\n\n'
                   "        rejection_spec: E7005 spec/lang/symbol.md#S-5\n"
                   '        """\n'
                   "        pass\n")
        result = self.report()
        self.assertEqual(result["totals"]["covered"], 1)
        self.assertEqual(result["fixtures"]["tools"][0]["test"], "ContractGates.test_partition")
        self.assertEqual([error["code"] for error in result["errors"]], ["invalid_tool_spec"])

    def test_link_contract_coverage_requires_exact_api_result(self):
        self.add_doc("lang/symbol.md", [("S-6", "跨单元编号"), ("S-9", "统一位宽")])
        self.add_entry("E7006", "symbol.md:S-6")
        self.add_entry("E7009", "symbol.md:S-9")
        lines = (
            "let bad: link_names::LinkBuild = link_names::build(...)?;\n"
            "// rejection_spec: E7006 spec/lang/symbol.md#S-6\n"
            "assert(!bad.ok && bad.code.raw == 7006 && @len(bad.table.symbols) == 0);\n"
        )
        for sample, errors, covered in (
            (lines, [], 1),
            (lines.replace("== 7006", "== 7009"), ["invalid_link_contract"], 0),
            (lines.replace("spec/lang/symbol.md#S-6", "spec/lang/symbol.md#S-9"), ["code_anchor_mismatch"], 0),
            (lines.replace("!bad.ok", "!other.ok"), ["invalid_link_contract"], 0),
            (lines.replace("link_names::build(", "stub("), ["invalid_link_contract"], 0),
        ):
            with self.subTest(errors=errors):
                self.write(MODULE.LINK_CONTRACT_SUITE, sample)
                report = self.report()
                self.assertEqual([error["code"] for error in report["errors"]], errors)
                self.assertEqual(report["totals"]["covered"], covered)

    def test_win64_name_coverage_requires_exact_link_result(self):
        self.add_doc("target/abi-win.md", [("AW-3", "保存寄存器未恢复"), ("AW-4", "非法修饰名")])
        self.add_entry("E8009", "../target/abi-win.md:AW-4")
        lines = (
            "let bad: link_names::LinkBuild = link_names::build(...)?;\n"
            "// rejection_spec: E8009 spec/target/abi-win.md#AW-4\n"
            "assert(!bad.ok && bad.code.raw == 8009 && @len(bad.table.symbols) == 0);\n"
        )
        for sample, errors, covered in (
            (lines, [], 1),
            (lines.replace("== 8009", "== 8008"), ["invalid_link_contract"], 0),
            (lines.replace("#AW-4", "#AW-3"), ["invalid_link_contract"], 0),
            (lines.replace("table.symbols) == 0", "table.symbols) == 1"), ["invalid_link_contract"], 0),
            (lines.replace("link_names::LinkBuild = link_names::build", "coff::EmitResult = coff::emit_object")
                  .replace("table.symbols", "bytes.data"), ["invalid_link_contract"], 0),
        ):
            with self.subTest(sample=sample):
                self.write(MODULE.LINK_CONTRACT_SUITE, sample)
                report = self.report()
                self.assertEqual([error["code"] for error in report["errors"]], errors)
                self.assertEqual(report["totals"]["covered"], covered)

    def test_win64_frame_coverage_requires_matching_producer_code_and_anchor(self):
        cases = (("abi-win.md", "AW-1", "E8006", "entry"), ("abi-win.md", "AW-2", "E8007", "entry"),
                 ("abi-win.md", "AW-3", "E8008", "exit"), ("x86.md", "X-2", "E7102", "entry"),
                 ("x86.md", "X-3", "E7103", "entry"))
        for doc in ("abi-win.md", "x86.md"):
            self.add_doc(f"target/{doc}", [(anchor, "栈帧拒绝") for path, anchor, _, _ in cases if path == doc])
        for doc, anchor, code, producer in cases:
            self.add_entry(code, f"../target/{doc}:{anchor}")
            arguments = "0, 11, 64, 16, 2" if producer == "entry" else "0, 9, 64"
            lines = (f"let bad: u16 = pe::validate_win64_{producer}(&frame:Read, {arguments});\n"
                     f"// rejection_spec: {code} spec/target/{doc}#{anchor}\n"
                     f"assert(bad == {code[1:]});\n")
            alternate = "exit" if producer == "entry" else "entry"
            for sample, errors, covered in (
                (lines, [], 1),
                (lines.replace(f"_{producer}(", f"_{alternate}("), ["invalid_link_contract"], 0),
                (lines.replace(f"#{anchor}", "#AW-4"), ["invalid_link_contract"], 0),
                (lines.replace("assert(bad ==", "assert(other =="), ["invalid_link_contract"], 0),
            ):
                with self.subTest(anchor=anchor, sample=sample):
                    self.write(MODULE.LINK_CONTRACT_SUITE, sample)
                    report = self.report()
                    self.assertEqual([error["code"] for error in report["errors"]], errors)
                    self.assertEqual(report["totals"]["covered"], covered)

    def test_x86_instruction_coverage_requires_exact_instruction_result(self):
        self.add_doc("target/x86.md", [("X-1", "允许子集")])
        self.add_entry("E7101", "../target/x86.md:X-1")
        source = ("let status: u16 = x86_validate::validate(&code:Read, 0)?;\n"
                  "// rejection_spec: E7101 spec/target/x86.md#X-1\n"
                  "assert(status == 7101);\n")
        for fixture, errors in (
            (source, []),
            (source.replace(")?;", ");"), ["invalid_link_contract"]),
            (source.replace("x86_validate::validate", "probe"), ["invalid_link_contract"]),
            (source.replace("== 7101", "== 7102"), ["invalid_link_contract"]),
            (source.replace("#X-1", "#X-2"), ["invalid_link_contract"]),
            (source.replace("assert(status", "assert(other"), ["invalid_link_contract"]),
        ):
            with self.subTest(fixture=fixture):
                self.write(MODULE.LINK_CONTRACT_SUITE, fixture)
                report = self.report()
                self.assertEqual([item["code"] for item in report["errors"]], errors)
                self.assertEqual(report["totals"]["covered"], int(not errors))

    def test_sysv_coverage_requires_exact_producer_and_both_syscall_observers(self):
        self.add_doc("target/abi-linux.md", [(f"AL-{i}", "System V 拒绝") for i in range(1, 5)])
        for i in range(1, 5):
            self.add_entry(f"E{8013 + i}", f"../target/abi-linux.md:AL-{i}")
        cases = (
            (1, "let note: u16 = pe::validate_sysv_entry(&code:Read, 0, 8, 32, 8, 1);", "assert(note == 8014);", "sysv_entry", "win64_entry"),
            (2, "let note: u16 = pe::validate_sysv_exit(&code:Read, 8, 14, 32);", "assert(note == 8015);", "sysv_exit", "win64_exit"),
            (4, "let note: link_names::LinkBuild = link_names::build_target(..., true)?;",
             "assert(!note.ok && note.code.raw == 8017 && @len(note.table.symbols) == 0);", "true", "false"),
        )
        for anchor, producer, assertion, correct, wrong in cases:
            marker = f"// rejection_spec: E{8013 + anchor} spec/target/abi-linux.md#AL-{anchor}"
            for call, errors in ((producer, []), (producer.replace(correct, wrong), ["invalid_link_contract"])):
                with self.subTest(call=call):
                    self.write(MODULE.LINK_CONTRACT_SUITE, f"{call}\n{marker}\n{assertion}\n")
                    report = self.report()
                    self.assertEqual([item["code"] for item in report["errors"]], errors)
                    self.assertEqual(report["totals"]["covered"], int(not errors))
        self.write(MODULE.LINK_CONTRACT_SUITE, "")
        observers = ("# runtime_spec: E8016 spec/target/abi-linux.md#AL-3\n"
                     "check_syscall_variant rcx E8016\ncheck_syscall_variant r11 E8016\n")
        for body, errors in ((observers, []), (observers.replace("r11", "rcx"), ["invalid_sysv_syscall_contract"])):
            with self.subTest(body=body):
                self.write(MODULE.SYSV_SYSCALL_SUITE, body)
                report = self.report()
                self.assertEqual([item["code"] for item in report["errors"]], errors)
                self.assertEqual(report["totals"]["covered"], int(not errors))

    def test_literal_coverage_requires_exact_producer_count_and_empty_tokens(self):
        self.add_doc("lang/lex.md", [(f"L-{i}", "扩展字面量") for i in range(12, 16)])
        for i in range(12, 16):
            code = 1000 + i
            self.add_entry(f"E{code}", f"lex.md:L-{i}")
            source = ("let checked: lex::LexResult = lex::lex_scan_literals(input, 7)?;\n"
                      f"// rejection_spec: E{code} spec/lang/lex.md#L-{i}\n"
                      "assert(@len(checked.tokens) == 0 && @len(checked.diagnostics) == 1 "
                      f"&& checked.diagnostics[0].code.raw == {code});\n")
            for item, errors in (
                (source, []),
                (source.replace("lex_scan_literals", "lex_scan"), ["invalid_literal_lex_contract"]),
                (source.replace("tokens) == 0", "tokens) == 1"), ["invalid_literal_lex_contract"]),
                (source.replace("diagnostics) == 1", "diagnostics) > 0"), ["invalid_literal_lex_contract"]),
                (source.replace(f"#L-{i}", f"#L-{12 + ((i - 11) % 4)}"), ["invalid_literal_lex_contract"]),
            ):
                with self.subTest(item=item):
                    self.write(MODULE.LITERAL_LEX_SUITE, item)
                    report = self.report()
                    self.assertEqual([value["code"] for value in report["errors"]], errors)
                    self.assertEqual(report["totals"]["covered"], int(not errors))

    def test_desugar_coverage_requires_rejection_and_unique_diagnostic(self):
        self.add_doc("lang/sugar.md", [("SU-1", "未登记节点"), ("SU-2", "残留类型"), ("SU-3", "新增原语")])
        for i in (1, 2, 3):
            code = 3000 + i
            self.add_entry(f"E{code}", f"sugar.md:SU-{i}")
            source = ("let allowed: bool = desugar::verify_base(&ast.file:Read, &ast.pool:Read, &diag_buffer:ReadWrite)?;\n"
                      f"// rejection_spec: E{code} spec/lang/sugar.md#SU-{i}\n"
                      "assert(!allowed && diag::diagbuf_count(&diag_buffer:Read) == 1 "
                      f"&& diag_buffer.diags[0].code.raw == {code});\n")
            for body in (source, source.replace("!allowed", "allowed"), source.replace("== 1", "> 0"),
                         source.replace("diag_buffer.diags", "other.diags"), source.replace("&ast.pool", "&other.pool"),
                         source.replace(f"#SU-{i}", f"#SU-{1 + i % 3}")):
                with self.subTest(body=body):
                    self.write(MODULE.DESUGAR_SUITE, body)
                    report = self.report()
                    self.assertEqual([error["code"] for error in report["errors"]],
                                     [] if body == source else ["invalid_desugar_contract"])
                    self.assertEqual(report["totals"]["covered"], int(body == source))

    def test_initializer_coverage_requires_empty_order_on_cycle(self):
        self.add_doc("lang/sugar.md", [("SU-6", "初始化循环依赖")])
        self.add_entry("E3006", "sugar.md:SU-6")
        source = ("let plan: desugar::InitializerPlan = desugar::plan_initializers(4, edges, &diagnostics:ReadWrite)?;\n"
                  "// rejection_spec: E3006 spec/lang/sugar.md#SU-6\n"
                  "assert(!plan.ok && @len(plan.order) == 0 && diag::diagbuf_count(&diagnostics:Read) == 1 "
                  "&& diagnostics.diags[0].code.raw == 3006);\n")
        for body in (source, source.replace(" && @len(plan.order) == 0", ""),
                     source.replace("desugar::plan_initializers", "fake::plan_initializers"),
                     source.replace("== 1", "> 0"), source.replace("#SU-6", "#SU-5")):
            with self.subTest(body=body):
                self.write(MODULE.INITIALIZER_SUITE, body)
                report = self.report()
                self.assertEqual([error["code"] for error in report["errors"]],
                                 [] if body == source else ["invalid_desugar_contract"])
                self.assertEqual(report["totals"]["covered"], int(body == source))

    def test_typed_sugar_coverage_requires_producer_and_unique_diagnostic(self):
        self.add_doc("lang/sugar.md", [("SU-4", "可错载体绑定"), ("SU-5", "闭区间溢出")])
        for suite, index in ((MODULE.RESERVED_IF_LET_SUITE, 4), (MODULE.CLOSED_RANGES_SUITE, 5)):
            code = 3000 + index
            self.add_entry(f"E{code}", f"sugar.md:SU-{index}")
            source = ("let result: typecheck::TypeCheckResult = typecheck_driver::typecheck_unit("
                      "&parsed.file:Read, &parsed.pool:Read, &resolved:Read, &diagnostics:ReadWrite)?;\n"
                      f"// rejection_spec: E{code} spec/lang/sugar.md#SU-{index}\n"
                      f"assert(diag::diagbuf_count(&diagnostics:Read) == 1 && diagnostics.diags[0].code.raw == {code});\n")
            for body in (source, source.replace("typecheck_driver::", "probe::"),
                         source.replace("&parsed.pool", "&other.pool"), source.replace("== 1", "> 0"),
                         source.replace("&& diagnostics.diags", "&& other.diags"), source.replace(f"#SU-{index}", "#SU-6")):
                with self.subTest(body=body):
                    self.write(suite, body)
                    report = self.report()
                    self.assertEqual([error["code"] for error in report["errors"]],
                                     [] if body == source else ["invalid_desugar_contract"])
                    self.assertEqual(report["totals"]["covered"], int(body == source))
            self.write(suite, "")

    def test_monomorph_coverage_requires_empty_instance_on_rejection(self):
        self.add_doc("lang/sugar.md", [("SU-7", "无合法泛型实参")])
        self.add_entry("E3007", "sugar.md:SU-7")
        source = ("let bad: monomorph::InstanceSignature = monomorph::instantiate_signature("
                  "&tt:ReadWrite, &sig:Read, explicit, operands, 0, &constraints:Read, call, &diagnostics:ReadWrite)?;\n"
                  "// rejection_spec: E3007 spec/lang/sugar.md#SU-7\n"
                  "assert(!bad.ok && @len(bad.arguments) == 0 && @len(bad.params) == 0 && bad.result == 0 "
                  "&& diag::diagbuf_count(&diagnostics:Read) == 1 && diagnostics.diags[0].code.raw == 3007);\n")
        for body in (source, source.replace("monomorph::instantiate_signature", "test::instantiate_signature"),
                     source.replace(" && @len(bad.arguments) == 0", ""), source.replace(" && @len(bad.params) == 0", ""),
                     source.replace("bad.result == 0", "bad.result != 0"), source.replace("== 1", "> 0"),
                     source.replace("&& diagnostics.diags", "&& other.diags"), source.replace("#SU-7", "#SU-6")):
            with self.subTest(body=body):
                self.write(MODULE.MONOMORPH_SUITE, body)
                report = self.report()
                self.assertEqual([error["code"] for error in report["errors"]],
                                 [] if body == source else ["invalid_desugar_contract"])
                self.assertEqual(report["totals"]["covered"], int(body == source))

    def test_nullable_coverage_requires_matching_input_and_exact_diagnostic(self):
        self.add_doc("lang/type/option.md", [(f"OP-{i}", "可空载体拒绝") for i in range(1, 5)])
        for index in range(1, 5):
            code = 5812 + index
            self.add_entry(f"E{code}", f"../lang/type/option.md:OP-{index}")
            source = ("let rejected: typecheck::TypeCheckResult = typecheck_driver::typecheck_unit("
                      "&loaded.parsed.file:Read, &loaded.parsed.pool:Read, &loaded.resolved:Read, &diagnostics:ReadWrite)?;\n"
                      f"// rejection_spec: E{code} spec/lang/type/option.md#OP-{index}\n"
                      f"assert(diag::diagbuf_count(&diagnostics:Read) == 1 && diagnostics.diags[0].code.raw == {code});\n")
            for body in (source, source.replace("typecheck_driver::", "probe::"), source.replace("&loaded.resolved", "&other.resolved"),
                         source.replace("== 1", "> 0"), source.replace("&& diagnostics.diags", "&& other.diags"),
                         source.replace(f"#OP-{index}", f"#OP-{index % 4 + 1}")):
                with self.subTest(body=body):
                    self.write(MODULE.NULLABLE_SUITE, body)
                    report = self.report()
                    self.assertEqual([error["code"] for error in report["errors"]],
                                     [] if body == source else ["invalid_nullable_contract"])
                    self.assertEqual(report["totals"]["covered"], int(body == source))

    def test_union_and_text_coverage_requires_matching_input_and_exact_diagnostic(self):
        cases = (
            (MODULE.PLAIN_UNION_SUITE, "lang/type/union.md", "UN", range(5817, 5821), "invalid_plain_union_contract"),
            (MODULE.TEXT_SUITE, "lang/type/string.md", "STR", (6204,), "invalid_text_contract"),
        )
        for suite, spec, prefix, codes, invalid in cases:
            self.add_doc(spec, [(f"{prefix}-{i}", "类型拒绝") for i, _ in enumerate(codes, 1)])
            for i, code in enumerate(codes, 1):
                anchor = f"{prefix}-{i}"
                self.add_entry(f"E{code}", f"../{spec}:{anchor}")
                source = ("let rejected: typecheck::TypeCheckResult = typecheck_driver::typecheck_unit("
                          "&loaded.parsed.file:Read, &loaded.parsed.pool:Read, &loaded.resolved:Read, &diagnostics:ReadWrite)?;\n"
                          f"// rejection_spec: E{code} spec/{spec}#{anchor}\n"
                          f"assert(diag::diagbuf_count(&diagnostics:Read) == 1 && diagnostics.diags[0].code.raw == {code});\n")
                for body in (source, source.replace("typecheck_driver::", "probe::"), source.replace("&loaded.resolved", "&other.resolved"),
                             source.replace("== 1", "> 0"), source.replace("&& diagnostics.diags", "&& other.diags"),
                             source.replace(f"#{anchor}", f"#{prefix}-0")):
                    with self.subTest(suite=suite, body=body):
                        self.write(suite, body)
                        report = self.report()
                        self.assertEqual([error["code"] for error in report["errors"]], [] if body == source else [invalid])
                        self.assertEqual(report["totals"]["covered"], int(body == source))
            self.write(suite, "")

    def test_elf_coverage_requires_exact_producer_and_empty_object_result(self):
        self.add_doc("target/elf.md", [(f"EL-{i}", "容器拒绝") for i in range(1, 5)])
        for i in range(1, 5):
            raw = 8017 + i
            self.add_entry(f"E{raw}", f"../target/elf.md:EL-{i}")
            if i == 1:
                call = "let reason: u16 = elf::validate_header(&object.bytes.data[0..length]:Read);"
                assertion = "assert(reason == 8018);"
                wrong = assertion.replace("reason", "other")
            else:
                call = "let reason: elf::ObjectResult = elf::emit_object(&input:Read)?;"
                assertion = f"assert(reason.code == {raw} && @len(reason.bytes.data) == 0 && reason.bytes.pos == 0);"
                wrong = assertion.replace(".pos == 0", ".pos == 1")
            source = f"{call}\n// rejection_spec: E{raw} spec/target/elf.md#EL-{i}\n{assertion}\n"
            for fixture, errors in (
                (source, []),
                (source.replace("elf::", "other::"), ["invalid_elf_contract"]),
                (source.replace(assertion, wrong), ["invalid_elf_contract"]),
                (source.replace(f"#EL-{i}", f"#EL-{(i % 4) + 1}"), ["invalid_elf_contract"]),
            ):
                with self.subTest(fixture=fixture):
                    self.write(MODULE.ELF_CONTRACT_SUITE, fixture)
                    report = self.report()
                    self.assertEqual([item["code"] for item in report["errors"]], errors)
                    self.assertEqual(report["totals"]["covered"], int(not errors))

    def test_emitter_coverage_requires_exact_empty_object_result(self):
        cases = (("EM-1", "E8002", "未定义链接目标"), ("EM-2", "E8003", "重复定义"),
                 ("EM-4", "E8005", "不支持的目标"), ("EM-5", "E8022", "比较条件码不匹配"),
                 ("EM-6", "E8023", "不支持的值形态"))
        self.add_doc("target/emitter.md", [(anchor, text) for anchor, _, text in cases])
        for anchor, code, _ in cases:
            self.add_entry(code, f"../target/emitter.md:{anchor}")
        for anchor, code, _ in cases:
            lines = (
                "let bad: coff::EmitResult = coff::emit_object(...)?;\n"
                f"// rejection_spec: {code} spec/target/emitter.md#{anchor}\n"
                f"assert(!bad.ok && bad.code.raw == {code[1:]} && @len(bad.bytes.data) == 0);\n"
            )
            other_anchor = "EM-1" if anchor != "EM-1" else "EM-2"
            for sample, errors, covered in (
                (lines, [], 1),
                (lines.replace(f"== {code[1:]}", "== 8004"), ["invalid_link_contract"], 0),
                (lines.replace(f"#{anchor}", f"#{other_anchor}"), ["code_anchor_mismatch"], 0),
                (lines.replace("bytes.data) == 0", "bytes.data) == 1"), ["invalid_link_contract"], 0),
                (lines.replace("coff::emit_object(", "stub("), ["invalid_link_contract"], 0),
                (lines.replace("coff::EmitResult = coff::emit_object", "link_names::LinkBuild = link_names::build")
                      .replace("bytes.data", "table.symbols"), ["invalid_link_contract"], 0),
            ):
                with self.subTest(anchor=anchor, sample=sample):
                    self.write(MODULE.LINK_CONTRACT_SUITE, sample)
                    report = self.report()
                    self.assertEqual([error["code"] for error in report["errors"]], errors)
                    self.assertEqual(report["totals"]["covered"], covered)

    def test_emitter_relocation_requires_same_layout_for_check_and_assembly(self):
        self.add_doc("target/emitter.md", [("EM-3", "重定位失败")])
        self.add_entry("E8004", "../target/emitter.md:EM-3")
        fixture = ("let reason: u16 = coff::validate_reloc_sites(&layout:Read);\n"
                   "let broken: coff_code::Bytes = coff::assemble(&layout:Read, &table:Read)?;\n"
                   "// rejection_spec: E8004 spec/target/emitter.md#EM-3\n"
                   "assert(reason == 8004 && @len(broken.data) == 0);\n")
        for text, errors, covered in (
            (fixture, [], 1),
            (fixture.replace("assemble(&layout", "assemble(&other"), ["invalid_link_contract"], 0),
            (fixture.replace("reason == 8004", "reason == 8005"), ["invalid_link_contract"], 0),
            (fixture.replace("@len(broken.data)", "@len(other.data)"), ["invalid_link_contract"], 0),
        ):
            with self.subTest(text=text):
                self.write(MODULE.LINK_CONTRACT_SUITE, text)
                report = self.report()
                self.assertEqual([error["code"] for error in report["errors"]], errors)
                self.assertEqual(report["totals"]["covered"], covered)

    def test_iface_write_coverage_checks_producer_diagnostics_and_empty_result(self):
        self.add_doc("lang/symbol.md", [("S-11", "接口写出拒绝存储视图")])
        self.add_entry("E7011", "symbol.md:S-11")
        producer = ("let rejected: iface::InterfaceResult = "
                    "iface_write::write_interface(file, &diags:ReadWrite)?;\n")
        marker = "// rejection_spec: E7011 spec/lang/symbol.md#S-11\n"
        assertion = ("assert(diag::diagbuf_count(&diags:Read) == 1 && diags.diags[0].code.raw == 7011 "
                     "&& @len(rejected.data.bytes) == 0 && @len(rejected.digest) == 0 && rejected.export_count == 0);\n")
        for call, check, errors, covered in (
            (producer, assertion, [], 1),
            (producer.replace("&diags:", "&other:"), assertion, ["invalid_iface_write_contract"], 0),
            (producer, assertion.replace("== 7011", "== 7012"), ["invalid_iface_write_contract"], 0),
            (producer, assertion.replace(" && @len(rejected.digest) == 0", ""), ["invalid_iface_write_contract"], 0),
            (producer, assertion.replace("rejected.data", "other.data"), ["invalid_iface_write_contract"], 0),
        ):
            with self.subTest(call=call, check=check):
                self.write(MODULE.IFACE_WRITE_SUITE, call + marker + check)
                report = self.report()
                self.assertEqual([error["code"] for error in report["errors"]], errors)
                self.assertEqual(report["totals"]["covered"], covered)

    def test_symbol_read_bridge_and_cache_require_exact_results(self):
        self.add_doc("lang/symbol.md", [("S-13", "接口污染本地名称区"), ("S-15", "JSON 接口"), ("S-19", "驻留名称缓存")])
        for code, anchor in (("E7013", "S-13"), ("E7015", "S-15"), ("E7019", "S-19")):
            self.add_entry(code, f"symbol.md:{anchor}")
        cases = (
            (MODULE.IFACE_READ_SUITE, "iface::LoadedInterface = iface_load::load_interface", "E7015", "S-15",
             "@len(rejected.name_bytes) == 0 && @len(rejected.exports) == 0 && @len(rejected.digest) == 0", "invalid_iface_read_contract"),
            (MODULE.IFACE_BRIDGE_SUITE, "resolve_refs::Resolution = resolve_unit::resolve_unit", "E7013", "S-13",
             "@len(rejected.refs.items) == 0 && @len(rejected.bridges.items) == 0", "invalid_iface_bridge_contract"),
            (MODULE.RESOLVE_SUITE, "resolve_refs::Resolution = resolve_unit::resolve_unit", "E7019", "S-19",
             "@len(rejected.refs.items) == 1 && rejected.refs.items[0].kind == 1", "invalid_name_cache_contract"),
        )
        for suite, operation, code, anchor, empty, invalid in cases:
            first = f"let rejected: {operation}(bytes, &diags:ReadWrite)?;\n"
            marker = f"// rejection_spec: {code} spec/lang/symbol.md#{anchor}\n"
            assertion = (f"assert(diag::diagbuf_count(&diags:Read) == 1 && diags.diags[0].code.raw == {code[1:]} "
                         f"&& {empty});\n")
            for text, errors, covered in (
                (first + marker + assertion, [], 1),
                (first + marker + assertion.replace("@len(rejected.", "@len(other.", 1), [invalid], 0),
                (first.replace("&diags:", "&other:") + marker + assertion, [invalid], 0),
            ):
                with self.subTest(anchor=anchor, text=text):
                    self.write(suite, text)
                    report = self.report()
                    self.assertEqual([error["code"] for error in report["errors"]], errors)
                    self.assertEqual(report["totals"]["covered"], covered)
            (self.root / suite).unlink()

    def test_mir_lowering_coverage_requires_exact_name_leak_rejection(self):
        self.add_doc("lang/symbol.md", [("S-18", "泄漏名称编号")])
        self.add_entry("E7018", "symbol.md:S-18")
        producer = "let rejected: mir::MirResult = mir_lower::build_mir(file, &diags:ReadWrite)?;\n"
        marker = "// rejection_spec: E7018 spec/lang/symbol.md#S-18\n"
        assertion = ("assert(!rejected.accepted && @len(rejected.module.functions) == 0 "
                     "&& diag::diagbuf_count(&diags:Read) == 1 && diags.diags[0].code.raw == 7018);\n")
        for call, check, errors, covered in (
            (producer, assertion, [], 1),
            (producer.replace("&diags:", "&other:"), assertion, ["invalid_mir_verify_contract"], 0),
            (producer, assertion.replace(" && @len(rejected.module.functions) == 0", ""), ["invalid_mir_verify_contract"], 0),
        ):
            with self.subTest(call=call, check=check):
                self.write(MODULE.MIR_VERIFY_SUITE, call + marker + check)
                report = self.report()
                self.assertEqual([error["code"] for error in report["errors"]], errors)
                self.assertEqual(report["totals"]["covered"], covered)

    def test_mir_verify_coverage_requires_exact_production_result(self):
        self.add_doc("ir/mir.md", [("M-4", "不可达块"), ("M-5", "分派非穷尽")])
        self.add_entry("E7034", "../ir/mir.md:M-4")
        self.add_entry("E7035", "../ir/mir.md:M-5")
        producer = "let checked: mir_verify::Validation = mir_verify::validate_module(&mir:Read)?;\n"
        marker = "// rejection_spec: E7034 spec/ir/mir.md#M-4\n"
        assertion = "assert(!checked.ok && checked.code.raw == 7034);\n"
        for text, errors, covered in (
            (producer + marker + assertion, [], 1),
            (producer.replace("validate_module", "verify_module") + marker + assertion, ["invalid_mir_verify_contract"], 0),
            (producer + marker + assertion.replace("7034", "7035"), ["invalid_mir_verify_contract"], 0),
            (producer + marker.replace("#M-4", "#M-5") + assertion, ["code_anchor_mismatch"], 0),
            (producer + marker + assertion.replace("!checked.ok && ", ""), ["invalid_mir_verify_contract"], 0),
        ):
            with self.subTest(text=text):
                self.write(MODULE.MIR_VERIFY_SUITE, text)
                report = self.report()
                self.assertEqual([error["code"] for error in report["errors"]], errors)
                self.assertEqual(report["totals"]["covered"], covered)

    def test_ysm_contract_coverage_requires_matching_code(self):
        self.add_doc("ir/ysm.md", [("Y-1", "混入名称编号"), ("Y-2", "节目录错误")])
        self.add_entry("E7023", "../ir/ysm.md:Y-1")
        self.add_entry("E7024", "../ir/ysm.md:Y-2")
        marker = "// rejection_spec: E7023 spec/ir/ysm.md#Y-1\n"
        assertion = "expect_reject_signed(bytes, 81, 1, 7023)?;\n"
        for line, call, errors, count in (
            (marker, assertion, [], 1),
            (marker, assertion.replace("7023", "7024"), ["invalid_ysm_contract"], 0),
            (marker.replace("#Y-1", "#Y-2"), assertion, ["code_anchor_mismatch"], 0),
            (marker, "assert(true);\n", ["invalid_ysm_contract"], 0),
        ):
            with self.subTest(errors=errors):
                self.write(MODULE.YSM_CONTRACT_SUITE, line + call)
                result = self.report()
                self.assertEqual([error["code"] for error in result["errors"]], errors)
                self.assertEqual(result["totals"]["covered"], count)

    def test_tool_pe_coverage_requires_exact_code_and_anchor(self):
        self.add_doc("target/pe.md", [("PE-1", "时间戳非零"), ("PE-2", "节属性错误"),
                                     ("PE-3", "重定位错误"), ("PE-4", "符号顺序错误")])
        self.add_entry("E8010", "../target/pe.md:PE-1")
        self.add_entry("E8011", "../target/pe.md:PE-2")
        self.add_entry("E8012", "../target/pe.md:PE-3")
        self.add_entry("E8013", "../target/pe.md:PE-4")
        fixture = '''import unittest
class ContractGates(unittest.TestCase):
    def test_timestamp(self):
        """拒绝非零时间戳。

        rejection_spec: E8010 spec/target/pe.md#PE-1
        """
        self.assertEqual(check(), 1)
'''
        self.write(MODULE.TOOL_SUITE, fixture)
        result = self.report()
        self.assertFalse(result["errors"])
        self.assertEqual(result["totals"]["covered"], 1)
        self.assertEqual(result["fixtures"]["tools"][0]["test"], "ContractGates.test_timestamp")
        valid_marker = "E8010 spec/target/pe.md#PE-1"
        for name, marker in (("sections", "E8011 spec/target/pe.md#PE-2"),
                             ("relocations", "E8012 spec/target/pe.md#PE-3"),
                             ("symbols", "E8013 spec/target/pe.md#PE-4")):
            with self.subTest(marker=marker):
                sample = fixture.replace("test_timestamp", f"test_{name}").replace(valid_marker, marker)
                self.write(MODULE.TOOL_SUITE, sample)
                result = self.report()
                self.assertFalse(result["errors"])
                self.assertEqual(result["totals"]["covered"], 1)
                self.assertEqual(result["fixtures"]["tools"][0]["test"], f"ContractGates.test_{name}")
        for marker, code in (("E8011 spec/target/pe.md#PE-1", "code_anchor_mismatch"),
                             ("E8010 spec/target/pe.md#PE-2", "code_anchor_mismatch"),
                             ("E8011 spec/target/pe.md#PE-3", "code_anchor_mismatch"),
                             ("E8012 spec/target/pe.md#PE-4", "code_anchor_mismatch"),
                             ("E8013 spec/target/pe.md#PE-5", "invalid_tool_spec")):
            with self.subTest(marker=marker):
                self.write(MODULE.TOOL_SUITE, fixture.replace(valid_marker, marker))
                result = self.report()
                self.assertEqual(result["totals"]["covered"], 0)
                self.assertEqual([item["code"] for item in result["errors"]], [code])

    def test_interface_coverage_requires_four_distinct_exact_cases(self):
        self.add_doc("lang/symbol.md", [("S-12", "非法接口不能继续编译")])
        self.add_entry("E7012", "../lang/symbol.md:S-12")
        valid = ("# interface_spec: E7012 spec/lang/symbol.md#S-12\n"
                 "check_bad_interface directory E7012\n"
                 "check_bad_interface profile E7012\n"
                 "check_bad_interface signature E7012\n"
                 "check_bad_interface digest E7012\n")
        self.write(MODULE.INTERFACE_SUITE, valid)
        result = self.report()
        self.assertFalse(result["errors"])
        self.assertEqual(result["totals"]["covered"], 1)
        self.assertEqual(result["fixtures"]["interfaces"][0]["cases"],
                         ["digest", "directory", "profile", "signature"])
        self.write(MODULE.INTERFACE_SUITE, valid.replace("digest E7012", "profile E7012"))
        result = self.report()
        self.assertEqual(result["totals"]["covered"], 0)
        self.assertEqual({error["code"] for error in result["errors"]},
                         {"invalid_interface_case", "incomplete_interface_cases"})

    def codes(self, report):
        """收集完整性错误码集合。"""
        return {item["code"] for item in report["errors"]}

    def group(self, report, spec):
        """按规格路径取分组。"""
        return next(item for item in report["groups"] if item["spec"] == spec)

    def run_cli(self, *args):
        """以子进程运行命令行入口。"""
        return subprocess.run(
            [sys.executable, "-B", str(TOOL), "--root", str(self.root), *args],
            capture_output=True,
        )

    # ── 锚点与错误码 ──

    def test_unknown_anchor_and_wrong_document(self):
        """锚点不存在或引用错文档时必须拒绝，且不计覆盖。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_doc("lang/name.md", rows=[("N-1", "拒绝二")])
        self.add_entry("E4001", "name.md:N-1")
        self.add_entry("E1002", "base.md:R-1")
        self.add_fixture("E4001", spec="spec/lang/base.md#N-1")
        report = self.report()
        self.assertIn("unknown_anchor", self.codes(report))
        base = self.group(report, "lang/base.md")
        self.assertEqual(base["covered"], 0)
        self.assertEqual(base["missing_anchors"], ["R-1"])
        self.assertFalse(report["complete"])
        self.assertEqual(report["check"]["failures"][0]["category"], "integrity_errors")

    def test_code_anchor_mismatch(self):
        """expected_code 与锚点已登记码位不一致时必须拒绝。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一"), ("R-2", "拒绝二")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_entry("E1002", "base.md:R-2")
        self.add_fixture("E1002", spec="spec/lang/base.md#R-1")
        report = self.report()
        self.assertIn("code_anchor_mismatch", self.codes(report))
        self.assertEqual(report["totals"]["covered"], 0)
        self.assertEqual(report["totals"]["missing"], 2)

    def test_duplicate_anchor_rejected(self):
        """两个夹具认领同一锚点时，只允许首个有效认领。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_entry("E1002", "base.md:R-1")
        self.add_fixture("E1001", spec="spec/lang/base.md#R-1")
        self.add_fixture("E1002", spec="spec/lang/base.md#R-1")
        report = self.report()
        self.assertIn("duplicate_anchor", self.codes(report))
        self.assertEqual(report["totals"]["covered"], 1)
        row = next(item for item in report["groups"][0]["covered_anchors"])
        self.assertEqual(row, "R-1")
        covered = [item for item in report["fixtures"]["roots"] if item["covered"]]
        self.assertEqual(len(covered), 1)
        self.assertEqual(len(covered[0]["covered"]), 1)

    def test_bare_anchor_and_malformed_reference(self):
        """裸锚点与缺少锚点的引用都按严格语法拒绝。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_fixture("E1001", name="bare.yak", spec="P-9")
        self.add_fixture("E1001", name="prose.yak", spec="spec/lang/base.md 12")
        report = self.report()
        codes = self.codes(report)
        self.assertIn("bare_anchor", codes)
        self.assertIn("malformed_spec_ref", codes)
        self.assertEqual(report["totals"]["covered"], 0)

    def test_gate_assertion_not_misjudged(self):
        """门禁断言不得计入夹具缺口或 full 欠账。"""
        self.add_doc("proc/build.md", rows=[("B-1", "退出码断言")], rejection_class="门禁断言")
        report = self.report()
        self.assertEqual(report["snapshot"]["gate_assertion_rows"], 1)
        self.assertEqual(report["snapshot"]["gate_rows_total"], 1)
        self.assertEqual(report["totals"]["fixture_required"], 0)
        self.assertEqual(report["totals"]["full_debt_rows"], 0)
        self.assertEqual(report["totals"]["missing"], 0)
        self.assertTrue(report["complete"])
        self.assertTrue(report["check"]["ok"])
        group = self.group(report, "proc/build.md")
        self.assertEqual(group["gate_anchors"], ["B-1"])
        self.assertEqual(group["missing_anchors"], [])
        self.assertEqual(group["debt_anchors"], [])

    def test_gate_fixture_is_rejected(self):
        """门禁断言不能被 test/bad 夹具认领。"""
        self.add_doc("proc/build.md", rows=[("B-1", "退出码断言")], rejection_class="门禁断言")
        self.add_entry("E1001", "build.md:B-1")
        self.add_fixture("E1001", spec="spec/proc/build.md#B-1")
        report = self.report()
        self.assertIn("gate_anchor_fixture", self.codes(report))
        self.assertEqual(report["totals"]["covered"], 0)

    def test_unmapped_row_is_full_debt(self):
        """未登记码位的非门禁形态归 full 欠账，夹具不得认领。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_doc("lang/generic.md", rows=[("G-1", "泛型拒绝")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_fixture("E1001", spec="spec/lang/generic.md#G-1")
        report = self.report()
        self.assertIn("unmapped_anchor", self.codes(report))
        self.assertEqual(report["snapshot"]["full_debt_rows"], 1)
        self.assertEqual(report["totals"]["full_debt_rows"], 1)
        self.assertEqual(report["totals"]["covered"], 0)
        self.assertIn(
            "full_debt_rows",
            {item["category"] for item in report["check"]["failures"]},
        )

    def test_alias_and_multi_form_coverage(self):
        """显式别名可覆盖多个形态，同一夹具可认领多条锚点。"""
        self.add_doc(
            "lang/base.md",
            rows=[("A-1", "显式码 E1234"), ("A-2", "显式码 E1234")],
        )
        self.write(
            "spec/lang/other.md",
            "# other\n\n- 状态：草案\n\n## 7.15 说明\n\n无拒绝形态。\n",
        )
        self.add_entry("E1234", "other.md:7.15")
        self.add_fixture("E1234", spec="spec/lang/base.md#A-1、spec/lang/base.md#A-2")
        report = self.report()
        self.assertEqual(self.codes(report), set())
        self.assertEqual(report["snapshot"]["rows_explicit_alias"], 2)
        self.assertEqual(report["totals"]["fixture_required"], 2)
        self.assertEqual(report["totals"]["covered"], 2)
        self.assertEqual(report["totals"]["missing"], 0)
        self.assertTrue(report["complete"])
        group = self.group(report, "lang/base.md")
        self.assertEqual(group["covered_anchors"], ["A-1", "A-2"])

    # ── 夹具结构 ──

    def test_wrong_directory_rejected(self):
        """目录名与 expected_code 不一致时必须拒绝。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_fixture("E1001", directory="E2001", spec="spec/lang/base.md#R-1")
        report = self.report()
        self.assertIn("directory_code_mismatch", self.codes(report))
        self.assertEqual(report["totals"]["covered"], 0)
        self.assertEqual(report["totals"]["missing"], 1)

    def test_unregistered_expected_code(self):
        """expected_code 未在 error.def 登记时必须拒绝。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.write("spec/proc/error.def", "format 2\n")
        self.add_entry("E1001", "base.md:R-1")
        self.add_fixture("E9999", spec="spec/lang/base.md#R-1")
        report = self.report()
        self.assertIn("unregistered_expected_code", self.codes(report))
        row = self.group(report, "lang/base.md")
        self.assertEqual(row["covered"], 0)
        self.assertEqual(report["totals"]["full_debt_rows"], 0)

    def test_dependency_rules(self):
        """同目录依赖可被引用，孤儿或兼作根的依赖必须拒绝。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_dependency("E1001", "dep.yak")
        self.add_fixture("E1001", name="root.yak", spec="spec/lang/base.md#R-1", deps=["dep.yak"])
        report = self.report()
        self.assertEqual(self.codes(report), set())
        self.assertEqual(report["snapshot"]["fixture_roots"], 1)
        self.assertEqual(report["snapshot"]["fixture_dependencies"], 1)
        self.assertEqual(report["fixtures"]["dependencies"][0]["referenced_by"], ["test/bad/E1001/root.yak"])
        self.assertEqual(report["totals"]["covered"], 1)

    def test_missing_and_root_dependency_rejected(self):
        """缺失依赖与兼作根的依赖都必须拒绝。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_fixture("E1001", name="root.yak", spec="spec/lang/base.md#R-1", deps=["nope.yak"])
        self.add_fixture("E1001", name="dep.yak")
        self.add_fixture("E1001", name="other.yak", spec="spec/lang/base.md#R-1", deps=["dep.yak"])
        report = self.report()
        codes = self.codes(report)
        self.assertIn("missing_dependency", codes)
        self.assertIn("dependency_is_root", codes)

    def test_orphan_fixture_rejected(self):
        """既非根也未被引用的 .yak 视为孤儿。"""
        self.add_dependency("E1001", "stray.yak")
        report = self.report()
        self.assertIn("orphan_fixture", self.codes(report))
        self.assertEqual(report["snapshot"]["fixture_roots"], 0)

    def test_marker_after_header(self):
        """头部之后的标记必须拒绝。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "base.md:R-1")
        self.write(
            "test/bad/E1001/late.yak",
            "// spec: spec/lang/base.md#R-1\n// expected_code: E1001\n\nfn main() {}\n\n"
            "// spec: spec/lang/base.md#R-1\n",
        )
        report = self.report()
        self.assertIn("marker_after_header", self.codes(report))
        self.assertEqual(report["totals"]["covered"], 1)

    def test_expected_diagnostics_validation(self):
        """完整诊断序列必须含主码，且所有码位都已登记。"""
        self.add_doc(
            "lang/base.md",
            rows=[("R-1", "显式码 E1001"), ("R-2", "显式码 E1001"), ("R-3", "显式码 E1001")],
        )
        self.write(
            "spec/lang/other.md",
            "# other\n\n- 状态：草案\n\n## 1.1 说明\n\n无。\n\n## 2.2 说明\n\n无。\n",
        )
        self.add_entry("E1001", "other.md:1.1")
        self.add_entry("E1009", "other.md:2.2")
        self.add_fixture("E1001", name="ok.yak", spec="spec/lang/base.md#R-1", diagnostics=["E1009", "E1001"])
        self.add_fixture("E1001", name="noprimary.yak", spec="spec/lang/base.md#R-2", diagnostics=["E1009"])
        self.add_fixture("E1001", name="unknown.yak", spec="spec/lang/base.md#R-3", diagnostics=["E9999", "E1001"])
        report = self.report()
        codes = self.codes(report)
        self.assertIn("diagnostics_missing_primary", codes)
        self.assertIn("unregistered_diagnostic_code", codes)
        self.assertEqual(report["totals"]["covered"], 3)

    # ── 规格侧与完成性 ──

    def test_module_graph_metadata(self):
        self.add_doc("lang/module.md", [("N-3", "歧义")])
        self.add_entry("E4003", "module.md:N-3")
        self.add_fixture("E4003", spec="spec/lang/module.md N-3", deps=("leaf.yak",))
        path = "test/bad/E4003/case.yak"
        base = self.read(path)
        self.add_dependency("E4003", "leaf.yak")
        for marker in (
            "// module_graph: scan\n",
            "// module_graph: ambiguous leaf\n",
            "// module_graph: ambiguous leaf\n// expected_diagnostics: E4003\n",
        ):
            with self.subTest(marker=marker):
                self.write(path, marker + base)
                self.assertEqual(self.report()["errors"], [])
        for marker in (
            "// module_graph: arbitrary\n",
            "// module_graph: ambiguous other\n",
            "// module_graph: ambiguous leaf\n// expected_diagnostics: E4003 E4003\n",
        ):
            with self.subTest(marker=marker):
                self.write(path, marker + base)
                self.assertIn("invalid_module_graph", self.codes(self.report()))
        self.write(path, "// module_graph: scan\n// module_graph: scan\n" + base)
        self.assertIn("duplicate_marker", self.codes(self.report()))
        self.write(path, base + "// module_graph: scan\n")
        self.assertIn("marker_after_header", self.codes(self.report()))
        self.write(path, base)
        self.add_dependency("E4003", "leaf.yak", "// module_graph: scan\nfn helper() {}\n")
        self.assertIn("invalid_module_graph", self.codes(self.report()))

    def test_missing_specs_block_completion(self):
        """index.md 与文档状态声明的缺失规格都阻止完成。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_fixture("E1001", spec="spec/lang/base.md#R-1")
        self.write(
            "spec/index.md",
            "# spec/index\n\n| 规格 | 层级 | 状态 |\n|:---|:---|:---|\n"
            "| `lang/asm.md` | full | 缺失 |\n",
        )
        self.write("spec/lang/asm.md", "# asm\n\n- 状态：缺失\n")
        report = self.report()
        self.assertEqual(
            report["full_debt"]["missing_specs"], [{"spec": "lang/asm.md", "layer": "full"}]
        )
        self.assertFalse(report["complete"])
        self.assertIn(
            "missing_specs",
            {item["category"] for item in report["check"]["failures"]},
        )

    def test_duplicate_spec_row(self):
        """同一规格重复登记锚点属于完整性错误。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一"), ("R-1", "重复")])
        self.add_entry("E1001", "base.md:R-1")
        report = self.report()
        self.assertIn("duplicate_spec_row", self.codes(report))
        self.assertFalse(report["complete"])

    def test_unresolved_error_ref(self):
        """error.def 引用不存在的文档时记录错误，对应形态归 full 欠账。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "missing.md:R-1")
        report = self.report()
        self.assertIn("unresolved_error_ref", self.codes(report))
        self.assertEqual(report["snapshot"]["full_debt_rows"], 1)
        self.assertEqual(report["totals"]["covered"], 0)

    # ── 确定性与命令行 ──

    def test_report_is_deterministic(self):
        """同一输入两次构建的报告与 JSON 输出逐字节一致。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_fixture("E1001", spec="spec/lang/base.md#R-1")
        first = self.report()
        second = self.report()
        self.assertEqual(first, second)
        first_run = self.run_cli("--json")
        second_run = self.run_cli("--json")
        self.assertEqual(first_run.returncode, 0)
        self.assertEqual(first_run.stdout, second_run.stdout)
        json.loads(first_run.stdout.decode("utf-8"))

    def test_check_exit_codes(self):
        """完整语料 --check 退 0；存在缺口时退 1，报告模式仍退 0。"""
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一")])
        self.add_entry("E1001", "base.md:R-1")
        self.add_fixture("E1001", spec="spec/lang/base.md#R-1")
        self.assertEqual(self.run_cli("--check").returncode, 0)
        self.add_doc("lang/base.md", rows=[("R-1", "拒绝一"), ("R-2", "拒绝二")])
        self.add_entry("E1002", "base.md:R-2")
        failed = self.run_cli("--json", "--check")
        self.assertEqual(failed.returncode, 1)
        payload = json.loads(failed.stdout.decode("utf-8"))
        self.assertFalse(payload["complete"])
        self.assertEqual(
            {item["category"] for item in payload["check"]["failures"]},
            {"fixture_gaps"},
        )
        self.add_fixture("E1001", name="bad.yak", spec="spec/lang/base.md#R-9")
        self.assertEqual(self.run_cli().returncode, 0)
        failed = self.run_cli("--json", "--check")
        self.assertEqual(failed.returncode, 1)
        payload = json.loads(failed.stdout.decode("utf-8"))
        self.assertIn(
            "fixture_gaps",
            {item["category"] for item in payload["check"]["failures"]},
        )
        self.assertIn("integrity_errors", {item["category"] for item in payload["check"]["failures"]})


if __name__ == "__main__":
    unittest.main()
