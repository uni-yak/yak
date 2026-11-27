"""FP-4、SD-2、SD-3 固定点与阶段切换门禁单元测试。"""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
GATE_SCRIPT = Path(__file__).with_name("t2_stage_fixpoint_gate.py").resolve()
AUDIT_SCRIPT = REPO_ROOT / "tools" / "audit_spec.py"


class StageFixpointGateTest(unittest.TestCase):
    def setUp(self) -> None:
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self._write("compiler/min/STAGE", "stage: T1\nignition: 由 yak-seed 解释执行\n")
        self._write("spec/proc/fixpoint.md", "# fixpoint\n\n- 状态：草案\n")
        self._write("spec/proc/seed.md", "# seed\n\n- 状态：草案\n")
        self._write("compiler/full/README.md", "# full\n")
        self._write("compiler/full/src/README.md", "# src\n")
        self._write("compiler/full/src/opt/README.md", "# opt\n")

    def _write(self, rel: str, content: str) -> Path:
        target = self.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8", newline="\n")
        return target

    def _run(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(GATE_SCRIPT), "--root", str(self.root), *extra],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )

    def test_real_repository_passes_and_freeze_still_rejects(self) -> None:
        res = subprocess.run(
            [sys.executable, str(GATE_SCRIPT), "--root", str(REPO_ROOT)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        freeze = subprocess.run(
            [sys.executable, str(AUDIT_SCRIPT), "--freeze"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )
        self.assertNotEqual(freeze.returncode, 0, "仍有未激活 full 条目时 --freeze 必须继续拒绝")

    def test_fp4_rejects_premature_confirmation(self) -> None:
        self._write("spec/proc/fixpoint.md", "# fixpoint\n\n- 状态：确认\n")
        res = self._run()
        self.assertEqual(res.returncode, 1)
        self.assertIn("FP-4", res.stderr)
        self.assertIn("spec/proc/fixpoint.md", res.stderr)

    def test_fp4_rejects_incomplete_receipt(self) -> None:
        self._write("spec/proc/fixpoint.md", "# fixpoint\n\n- 状态：确认\n")
        receipt = self._write(
            "receipt.json",
            json.dumps({
                "c2_eq_c3": True,
                "fp3_ok": True,
                "win64_matrix_ok": True,
                "linux_elf_matrix_ok": True,
                "ci_trusted": False,
                "c2_main_sha256": "a" * 64,
            }),
        )
        res = self._run("--fixpoint-receipt", str(receipt))
        self.assertEqual(res.returncode, 1)
        self.assertIn("FP-4", res.stderr)

    def test_sd2_rejects_seed_in_t2_plus_commands_and_stage(self) -> None:
        cmds = self._write(
            "commands.txt",
            "\n".join([
                "bash compiler/min/selfhost.sh --out-dir tmp/c0",
                "YAK_SEED_BIN=tmp/absent-seed.exe bash compiler/min/selfhost.sh --out-dir tmp/c1 --native-compiler c0/main.exe --native-scanner c0/imports.exe",
                "bash compiler/min/selfhost.sh --out-dir tmp/c2 --require-frozen-seed",
            ]) + "\n",
        )
        res = self._run("--commands", str(cmds))
        self.assertEqual(res.returncode, 1)
        self.assertIn("SD-2", res.stderr)

        cmds_direct = self._write(
            "commands_direct.txt",
            "./seed/out/yak-seed.exe compiler/min/src/main.yak\n",
        )
        res_direct = self._run("--commands", str(cmds_direct))
        self.assertEqual(res_direct.returncode, 1)
        self.assertIn("SD-2", res_direct.stderr)

        self._write("compiler/min/STAGE", "stage: T3\nignition: 由 yak-seed 解释执行\n")
        res_stage = self._run()
        self.assertEqual(res_stage.returncode, 1)
        self.assertIn("SD-2", res_stage.stderr)

    def test_sd3_rejects_t3_without_converged_receipt(self) -> None:
        self._write("compiler/min/STAGE", "stage: T3\nignition: 由 C2 固定点原生自举\n")
        res_stage = self._run()
        self.assertEqual(res_stage.returncode, 1)
        self.assertIn("SD-3", res_stage.stderr)

        self._write("compiler/min/STAGE", "stage: T1\nignition: 由 yak-seed 解释执行\n")
        self._write("compiler/full/STAGE", "stage: T3\n")
        res_full = self._run()
        self.assertEqual(res_full.returncode, 1)
        self.assertIn("SD-3", res_full.stderr)
        self.assertIn("compiler/full/STAGE", res_full.stderr)

    def test_valid_converged_receipt_allows_t3_without_seed(self) -> None:
        self._write("compiler/min/STAGE", "stage: T3\nignition: 由可信固定点 C2 原生编译\n")
        self._write("spec/proc/fixpoint.md", "# fixpoint\n\n- 状态：确认\n")
        self._write("spec/proc/seed.md", "# seed\n\n- 状态：确认\n")
        self._write("compiler/full/STAGE", "stage: T3\n")
        receipt = self._write(
            "receipt.json",
            json.dumps({
                "c2_eq_c3": True,
                "fp3_ok": True,
                "win64_matrix_ok": True,
                "linux_elf_matrix_ok": True,
                "ci_trusted": True,
                "c2_main_sha256": "0123456789abcdef" * 4,
            }),
        )
        cmds = self._write(
            "commands_clean.txt",
            "YAK_SEED_BIN=tmp/absent-seed.exe bash compiler/min/selfhost.sh --out-dir tmp/c2 --native-compiler c1/main.exe --native-scanner c1/imports.exe\n",
        )
        res = self._run("--fixpoint-receipt", str(receipt), "--commands", str(cmds))
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_default_receipt_auto_discovery_validates_strictly(self) -> None:
        self._write("compiler/min/STAGE", "stage: T2\nignition: 已完成 T2 固定点收敛\n")
        self._write("spec/proc/fixpoint.md", "# fixpoint\n\n- 状态：确认\n")
        self._write("spec/proc/seed.md", "# seed\n\n- 状态：确认\n")
        self._write(
            "test/gate/t2_fixpoint_receipt.json",
            json.dumps({
                "c2_eq_c3": True,
                "fp3_ok": True,
                "win64_matrix_ok": True,
                "linux_elf_matrix_ok": True,
                "ci_trusted": False,
                "c2_main_sha256": "a" * 64,
            }),
        )
        bad = self._run()
        self.assertEqual(bad.returncode, 1)
        self.assertIn("FP-4", bad.stderr)
        self._write(
            "test/gate/t2_fixpoint_receipt.json",
            json.dumps({
                "c2_eq_c3": True,
                "fp3_ok": True,
                "win64_matrix_ok": True,
                "linux_elf_matrix_ok": True,
                "ci_trusted": True,
                "c2_main_sha256": "a" * 64,
            }),
        )
        good = self._run()
        self.assertEqual(good.returncode, 0, good.stderr)


if __name__ == "__main__":
    unittest.main()
