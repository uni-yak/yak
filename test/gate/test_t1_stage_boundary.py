"""用隔离目录调用真实 SD-1 命令行，不生成可执行产物。"""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from t2_stage_fixpoint_gate import DEFAULT_RECEIPT_REL, REQUIRED_RECEIPT_FLAGS


CHECK = Path(__file__).with_name("t1_stage_boundary.py").resolve()


class StageBoundary(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self.check = self.root / "test/gate" / CHECK.name
        self.check.parent.mkdir(parents=True)
        shutil.copyfile(CHECK, self.check)
        helper = CHECK.with_name("t2_stage_fixpoint_gate.py")
        shutil.copyfile(helper, self.check.with_name(helper.name))

    def put(self, path):
        entry = self.root / path
        entry.parent.mkdir(parents=True, exist_ok=True)
        entry.write_bytes(b"fixture\n")
        return entry

    def run_check(self):
        return subprocess.run([sys.executable, str(self.check)], cwd=self.root / "test",
                              capture_output=True, text=True, encoding="utf-8", check=False)

    def assert_rejected(self, path):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
        self.assertIn("SD-1", result.stderr)
        self.assertIn(repr(path), result.stderr)

    def test_no_full_or_only_documentation(self):
        for name in (None, "compiler/full/README.md", "compiler/full/src/README.md",
                     "compiler/full/src/opt/README.md", "out/yakc-min.exe",
                     "examples/yakc-full.yak"):
            if name is not None:
                self.put(name)
            result = self.run_check()
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_implementation_entries_and_default_outputs(self):
        for path in ("compiler/full", "compiler/full/src/check.yak", "compiler/full/STAGE",
                     "compiler/full/build.sh", "compiler/full/verify.sh",
                     "out/yakc-full", "out/yakc-full.exe", "out/.yakc-full.yak-root"):
            with self.subTest(path=path):
                entry = self.put(path)
                self.assert_rejected(path)
                self.assertEqual(entry.read_bytes(), b"fixture\n")
                entry.unlink()

    def test_candidate_requires_valid_t2_receipt(self):
        self.put("compiler/full/src/check.yak")
        receipt = self.put(DEFAULT_RECEIPT_REL)
        self.assert_rejected("compiler/full/src/check.yak")
        full_receipt = dict.fromkeys(REQUIRED_RECEIPT_FLAGS, True)
        full_receipt["c2_main_sha256"] = "0" * 64
        receipt.write_text(json.dumps({**full_receipt, "ci_trusted": False}), encoding="utf-8")
        self.assert_rejected("compiler/full/src/check.yak")
        receipt.write_text(json.dumps(full_receipt), encoding="utf-8")
        result = self.run_check()
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        for path in ("out/yakc-full.exe", "out/yakc_full.elf", "out/full_imports.elf"):
            self.put(path)
            self.assert_rejected(path)
            (self.root / path).unlink()

    def test_symlink_is_not_document_or_absence(self):
        name = "compiler/full/README.md"
        path = self.root / name
        path.parent.mkdir(parents=True)
        try:
            path.symlink_to("missing")
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"宿主不能创建符号链接：{exc}")
        self.assert_rejected(name)
        self.assertTrue(path.is_symlink())
        path.unlink()
        name = "out/yakc-full.exe"
        path = self.root / name
        path.parent.mkdir()
        path.symlink_to("missing")
        self.assert_rejected(name)
        self.assertTrue(path.is_symlink())

    def test_non_directory_parent_is_uninspectable(self):
        self.put("out")
        result = self.run_check()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("SD-1 检查未完成", result.stderr)


if __name__ == "__main__":
    unittest.main()
