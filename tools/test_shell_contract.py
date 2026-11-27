"""Yak shell 契约审计器的单元测试：覆盖误报抑制与各条规则。"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
sys.dont_write_bytecode = True

import shell_contract as sc  # noqa: E402


def contract(allowed=None):
    """构造最小契约：允许命令由测试显式给出，避免依赖真实规格内容。"""
    return {"allowed": set(allowed or ("cat", "cp", "mv", "rm", "mkdir",
                                  "sha256sum", "sort", "cmp")), "forbidden": set()}


def audit(text, allowed=None, functions=()):
    findings, _used = sc.audit_source(text, "fixture.sh", set(functions), contract(allowed))
    return findings


def rules(findings, rule):
    return [f for f in findings if f["rule"] == rule]


class WhitelistGate(unittest.TestCase):
    """SH-1：白名单外命令。"""

    def test_allowed_command_is_quiet(self):
        self.assertEqual(audit("cat a > b\n"), [])

    def test_unknown_command_reports_sh1(self):
        found = audit("clang -o out in.c\n")
        self.assertEqual([f["rule"] for f in found], ["SH-1"])
        self.assertEqual(found[0]["line"], 1)
        self.assertIn("clang", found[0]["message"])

    def test_builtin_and_local_function_are_known(self):
        text = "run_case a b\nlocal x=1\nprintf '%s' \"$x\"\n"
        self.assertEqual(audit(text, functions=("run_case",)), [])

    def test_flock_and_ln_are_forbidden_operations(self):
        found = audit("flock /tmp/lock true\nln -s a b\n")
        codes = sorted(f["code"] for f in found)
        self.assertEqual(codes, ["forbidden-operation", "forbidden-operation"])
        self.assertTrue(all(f["rule"] == "SH-1" for f in found))

    def test_mktemp_is_sh1_with_spec_decision(self):
        found = audit("tmp=$(mktemp -d)\n")
        self.assertEqual([f["rule"] for f in found], ["SH-1"])
        self.assertIn("规格", found[0]["decision"])

    def test_dynamic_command_word_is_skipped(self):
        # 命令词是变量时静态不可判定：只登记，不报 SH-1。
        self.assertEqual(audit("\"$cc\" -c a.c\n"), [])

    def test_literal_command_substitution_cannot_bypass_whitelist(self):
        found = audit("$(clang -dumpversion) -c a.c\n")
        self.assertIn("SH-1", [f["rule"] for f in found])
        self.assertTrue(any(f["command"] == "clang" for f in found))
        self.assertEqual(audit("$(cat a) > b\n"), [])


class CommentAndQuoteFalsePositives(unittest.TestCase):
    """误报抑制：注释、单引号、双引号与条件表达式里的文本不是命令。"""

    def test_comment_windows_path_is_ignored(self):
        # 注释中的 E:/ 示例是文档，不是硬编码路径。
        text = "# 例：不写成 E:/project/Yak 这样的绝对路径\ncat a\n"
        self.assertEqual(audit(text), [])

    def test_trailing_comment_is_ignored(self):
        self.assertEqual(audit("cat a  # 参见 C:\\\\Yak\\\\out\n"), [])

    def test_windows_path_in_string_is_reported(self):
        # 引号内是真正的运行期取值，必须报 SH-4：注释与字符串不同。
        found = audit("cp a \"E:/project/Yak/out\"\n")
        self.assertEqual([f["rule"] for f in found], ["SH-4"])

    def test_single_quoted_text_is_not_a_command(self):
        self.assertEqual(audit("printf '%s' 'clang -o out'\n"), [])

    def test_comment_commands_are_ignored(self):
        text = "# find . -name '*.c' | xargs rm\ncat a\n"
        self.assertEqual(audit(text), [])

    def test_double_bracket_operands_are_not_commands(self):
        text = "if [[ -f \"$x\" && \"$y\" == *.c ]]; then cat a; fi\n"
        self.assertEqual(audit(text), [])

    def test_arithmetic_expansion_is_not_scanned_as_commands(self):
        self.assertEqual(audit("n=$(( 1 + 2 ))\necho \"$n\"\n"), [])


class DeterminismGate(unittest.TestCase):
    """SH-3：时间戳、宿主名、随机数。"""

    def test_time_and_random_variables(self):
        for expr in ("$RANDOM", "$SECONDS", "$EPOCHREALTIME", "${SRANDOM}",
                     "$EPOCHSECONDS", "$BASH_MONOSECONDS"):
            with self.subTest(expr=expr):
                found = audit("echo " + expr + "\n")
                self.assertEqual([f["rule"] for f in found], ["SH-3"])

    def test_host_variables_are_rejected_only_when_expanded(self):
        for expr in ("$HOSTNAME", "${HOSTNAME%%.*}", "$HOSTTYPE", "${MACHTYPE}"):
            with self.subTest(expr=expr):
                found = audit(f'printf "%s" "{expr}"\n')
                self.assertEqual([f["rule"] for f in found], ["SH-3"])
        self.assertEqual(audit("# $HOSTNAME\nprintf '%s' '${HOSTNAME}'\n"), [])

    def test_date_and_hostname_commands(self):
        found = audit("date +%s\nhostname\n")
        # 同一行同时命中 SH-3（非确定性）与 SH-1（白名单外），两条都保留。
        self.assertEqual([f["rule"] for f in found], ["SH-3", "SH-1", "SH-3", "SH-1"])

    def test_nondeterministic_text_in_comment_or_string_is_quiet(self):
        self.assertEqual(audit("# 不要用 $RANDOM\nprintf '%s' 'date +%s'\n"), [])


class TraversalGate(unittest.TestCase):
    """SH-2：未排序的 glob 遍历。"""

    def test_unsorted_glob_loop_is_reviewed(self):
        found = audit("for f in test/t*.yak; do cat \"$f\"; done\n")
        self.assertEqual([f["rule"] for f in found], ["SH-2"])
        self.assertEqual(found[0]["severity"], "review")

    def test_sorted_loop_is_quiet(self):
        # 显式 sort 后处理满足 5.1。
        self.assertEqual(
            audit("for f in $(printf '%s\\n' test/t*.yak | sort); do cat \"$f\"; done\n"), [])

    def test_find_reports_both_sh2_and_sh1(self):
        found = audit("find . -name '*.c' > list.txt\n")
        self.assertEqual(sorted(f["rule"] for f in found), ["SH-1", "SH-2"])

    def test_fixed_enumeration_is_quiet(self):
        self.assertEqual(audit("for f in a.c b.c; do cat \"$f\"; done\n"), [])


class ForbiddenFormGate(unittest.TestCase):
    """SH-1/SH-4：设备文件、/proc/self/fd、Windows 绝对路径。"""

    def test_dev_full_is_error_dev_null_is_allowed(self):
        found = audit("cat a > /dev/full\n")
        self.assertEqual([f["code"] for f in found], ["device-path"])
        self.assertEqual(found[0]["severity"], "error")
        self.assertEqual(audit("cat a > /dev/null\n"), [])

    def test_proc_self_fd_is_reported(self):
        found = audit("cat < /proc/self/fd/3\n")
        self.assertEqual([f["code"] for f in found], ["forbidden-proc-fd"])

    def test_drive_letter_path_and_unc(self):
        text = "cp a 'D:/Yak/out'\ncp b '\\\\host\\share\\f'\n"
        found = audit(text)
        self.assertEqual(sorted(f["code"] for f in found),
                         ["absolute-unc-path", "absolute-windows-path"])

    def test_case_pattern_with_colon_is_not_a_path(self):
        # case 模式里的 [A-Za-z]:* 是通配模式，不是盘符路径。
        text = "case \"$1\" in [A-Za-z]:*) cat a ;; esac\n"
        self.assertEqual(audit(text), [])


class ScopeDeclaration(unittest.TestCase):
    """范围界定本身要被测试锁定，避免为绿而放宽。"""

    def test_production_entries_cover_real_build_scripts(self):
        for rel in ("compiler/min/build.sh", "compiler/min/selfhost.sh",
                    "compiler/min/verify.sh", "seed/build.sh", "runtime/build.sh"):
            with self.subTest(rel=rel):
                self.assertEqual(sc.classify(rel)[0], "entry")

    def test_production_libs_are_formally_invoked(self):
        for rel in ("tools/link.sh", "tools/native_stream.sh"):
            with self.subTest(rel=rel):
                self.assertEqual(sc.classify(rel)[0], "lib")

    def test_tests_and_handoff_are_excluded(self):
        for rel in ("test/gate/other.sh", "tmp/handoff-x/build.sh",
                    "seed/test/run_tests.sh"):
            with self.subTest(rel=rel):
                self.assertEqual(sc.classify(rel)[0], "excluded")

    def test_formally_invoked_test_scripts_are_auxiliary(self):
        # 生产入口确实调起的测试驱动单独登记：可统计，但不并入生产判定。
        for rel in ("tools/test_link_e2e.sh", "test/gate/t1_entry.sh",
                    "seed/test/common.sh"):
            with self.subTest(rel=rel):
                self.assertEqual(sc.classify(rel)[0], "auxiliary")
                self.assertNotIn(rel, sc.PRODUCTION_ENTRIES)
                self.assertNotIn(rel, sc.PRODUCTION_LIBS)

    def test_whitelist_comes_from_spec_not_hardcoded(self):
        real = sc.load_contract(ROOT)
        self.assertIsNotNone(real)
        for name in ("bash", "sort", "sha256sum", "as", "ld"):
            with self.subTest(name=name):
                self.assertIn(name, real["allowed"])
        # 类目词只是表格分组标题，不得混进命令白名单。
        for name in ("coreutils", "binutils"):
            with self.subTest(name=name):
                self.assertNotIn(name, real["allowed"])

    def test_spec_matches_embedded_snapshot(self):
        # 规格与内置快照漂移会被报错；此测试保证当前仓库两者一致。
        self.assertEqual(sc.spec_drift(sc.load_contract(ROOT)), [])


class StrictCommandLine(unittest.TestCase):
    """从规格和隔离脚本树出发，核对门禁进程的实际退出码。"""

    def setUp(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        for name in (sc.SHELL_SPEC, *sc.PRODUCTION_ENTRIES, *sc.PRODUCTION_LIBS,
                     *sc.AUXILIARY_SCRIPTS):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)

    def run_audit(self, *options):
        report = self.root / "audit.json"
        proc = subprocess.run(
            [sys.executable, str(ROOT / "tools/shell_contract.py"), "--root", str(self.root),
             "--quiet", "--json", str(report), *options],
            capture_output=True, timeout=30, check=False,
        )
        self.assertEqual(proc.stderr, b"")
        return proc.returncode, json.loads(report.read_text(encoding="utf-8"))["findings"]

    def test_strict_gate_rejects_outside_command_and_unclassified_script(self):
        self.assertEqual(self.run_audit("--strict"), (0, []))
        entry = "compiler/min/selfhost.sh"
        base = (self.root / entry).read_bytes()
        (self.root / entry).write_bytes(base + b"\ncurl example.invalid\n")
        rc, rows = self.run_audit("--strict")
        self.assertEqual(rc, 1)
        self.assertEqual([(row["rule"], row["severity"], row["file"], row["command"])
                          for row in rows], [("SH-1", "error", entry, "curl")])
        (self.root / entry).write_bytes(base)

        (self.root / "unclassified.sh").write_bytes(b"printf '\n'\n")
        rc, rows = self.run_audit("--strict")
        self.assertEqual(rc, 1)
        self.assertEqual([(row["code"], row["severity"], row["file"]) for row in rows],
                         [("unclassified-script", "review", "unclassified.sh")])
        self.assertEqual(self.run_audit()[0], 0)

    def test_determinism_rules_fail_at_the_expected_gate(self):
        entry = "compiler/min/selfhost.sh"
        file = self.root / entry
        base = file.read_bytes()
        cases = (
            ("SH-2", "unsorted-glob-loop", "review", 0,
             b'for f in test/t*.yak; do cat "$f"; done'),
            ("SH-3", "nondeterministic-variable", "error", 1, b'printf "%s" "$HOSTNAME"'),
            ("SH-4", "absolute-windows-path", "error", 1, b"cp src 'D:/Yak/out'"),
        )
        for rule, code, severity, normal_rc, fragment in cases:
            with self.subTest(rule=rule):
                file.write_bytes(base + b"\n" + fragment + b"\n")
                for option, expected_rc in (((), normal_rc), (("--strict",), 1)):
                    rc, rows = self.run_audit(*option)
                    self.assertEqual(rc, expected_rc)
                    self.assertEqual([(row["rule"], row["severity"], row["file"])
                                      for row in rows], [(rule, severity, entry)])
                    self.assertEqual(rows[0]["code"], code)
        file.write_bytes(base + b"\n" +
                         b"for f in $(printf '%s\\n' test/t*.yak | sort); do cat \"$f\"; done\n" +
                         b"printf '%s' '$HOSTNAME' # D:/Yak/out\n")
        self.assertEqual(self.run_audit("--strict"), (0, []))


class RealRepository(unittest.TestCase):
    """真实仓库：结论必须可解释，不要求全绿。"""

    @classmethod
    def setUpClass(cls):
        cls.result = sc.audit(ROOT)

    def test_scope_is_not_empty_and_has_no_unclassified(self):
        self.assertGreaterEqual(len(self.result["scope"]["entry"]), 5)
        self.assertEqual(self.result["scope"]["unclassified"], [])

    def test_no_nondeterminism_or_windows_path_in_production(self):
        for rule in ("SH-3", "SH-4"):
            with self.subTest(rule=rule):
                self.assertEqual(rules(self.result["findings"], rule), [])

    def test_text_report_mentions_limitations(self):
        report = sc.render_text(self.result)
        self.assertIn("限制", report)
        self.assertIn("不是完整 shell 解析器", report)


if __name__ == "__main__":
    unittest.main()
