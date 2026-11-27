#!/usr/bin/env python3
"""直接验证候选交接、逐例对拍和发布包的摘要约束。"""

from argparse import Namespace
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import ci_artifacts as artifacts
import ci_bootstrap_stage as bootstrap_stage
import ci_release as release


COMMIT = "a" * 40
RUN = "42"


class CIArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_candidate_rejects_cross_run_and_changed_tool(self):
        source = self.root / "source"
        for name in artifacts.CANDIDATE_FILES:
            tool = source / name
            tool.parent.mkdir(parents=True, exist_ok=True)
            tool.write_text(name, encoding="ascii")
        candidate = self.root / "candidate"
        args = Namespace(root=source, output=candidate, commit=COMMIT, run=RUN)
        artifacts.publish_candidate(args)
        args.root = candidate
        artifacts.verify_candidate(args)
        args.run = "43"
        with self.assertRaisesRegex(ValueError, "运行编号"):
            artifacts.verify_candidate(args)
        args.run = RUN
        (candidate / artifacts.CANDIDATE_FILES[0]).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "工具摘要"):
            artifacts.verify_candidate(args)

    def test_bootstrap_stage_round_trip_and_rejects_tampering(self):
        source = self.root / "win64-src"
        for name in bootstrap_stage.WIN64_FILES:
            tool = source / name
            tool.parent.mkdir(parents=True, exist_ok=True)
            tool.write_text(name, encoding="ascii")
        for root_name in bootstrap_stage.ELF_ROOTS:
            obj_dir = source / "elf-c0-objects" / root_name
            obj_dir.mkdir(parents=True, exist_ok=True)
            (source / "elf-c0-objects" / f"{root_name}.order").write_text("a.o\nb.o\n", encoding="ascii")
            (obj_dir / "a.o").write_bytes(b"obj-a")
            (obj_dir / "b.o").write_bytes(b"obj-b")
        sealed = self.root / "win64-stage"
        bootstrap_stage.seal_stage(Namespace(root=source, output=sealed, commit=COMMIT, run=RUN))
        bootstrap_stage.verify_stage(Namespace(root=sealed, commit=COMMIT, run=RUN))
        (sealed / "elf-c0-objects" / "main" / "a.o").write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "文件摘要不一致"):
            bootstrap_stage.verify_stage(Namespace(root=sealed, commit=COMMIT, run=RUN))

    def test_collect_uses_real_exit_and_stdout_bytes(self):
        logfile = self.root / "semantic.log"
        logfile.write_text("\n".join(
            f"[通过] {kind} test/{branch}/{kind}.yak：通过"
            for kind, branch in (("positive", "ok"), ("negative", "bad"), ("graph", "bad"))
        ), encoding="utf-8")
        positive = self.root / "ok" / "positive"
        stream = positive / "c2" / "positive"
        stream.mkdir(parents=True)
        (stream / "stdout.txt").write_bytes(b"one\n")
        (stream / "stderr.txt").write_bytes(b"")
        (positive / "c2.rc").write_text("0\n", encoding="ascii")
        (positive / "c2-link.stdout").write_text("exe=foo.elf\nexit_code=7\n", encoding="ascii")
        for kind, suffix in (("negative", "link"), ("graph", "build")):
            path = self.root / "bad" / kind
            path.mkdir(parents=True)
            (path / "c2.rc").write_text("1\n", encoding="ascii")
            (path / f"c2-{suffix}.stderr").write_bytes(b"sample")
        frame = self.root / "bad" / "negative" / "jsonl" / "negative" / "negative.diag.jsonl"
        frame.parent.mkdir(parents=True)
        frame.write_bytes(b"validated frame\n")
        result = artifacts.collect_cases(self.root)["test/ok/positive.yak"]
        self.assertEqual((result["exit"], result["stdout"]), ("7", artifacts.digest(stream / "stdout.txt")))
        (positive / "c2-link.stdout").write_text("exit_code=7\nexit_code=8\n", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "唯一成功退出"):
            artifacts.collect_cases(self.root)

    def platform_manifests(self):
        for target, package in artifacts.PACKAGES.items():
            directory = self.root / target
            directory.mkdir()
            bundle = directory / package
            bundle.write_bytes(target.encode("ascii"))
            artifacts.write_json(directory / "platform.json",
                                 {"commit": COMMIT, "run": RUN, "candidate": "b" * 64, "target": target,
                                  "digest": artifacts.digest(bundle), "package": package,
                                  "cases": {"test/ok/flow/a.yak": {"kind": "positive", "exit": "0"}}})

    def test_release_assets_round_trip_and_reject_tampering(self):
        self.platform_manifests()
        output = self.root / "release"
        artifacts.assemble(Namespace(root=self.root, output=output, commit=COMMIT, run=RUN))
        self.assertEqual(len(release.checked_assets(output, COMMIT, RUN)), 4)
        (output / artifacts.PACKAGES["linux-x64"]).write_bytes(b"wrong")
        with self.assertRaisesRegex(ValueError, "发布包摘要"):
            release.checked_assets(output, COMMIT, RUN)

    def test_disagreeing_platforms_do_not_create_release_artifact(self):
        self.platform_manifests()
        manifest = self.root / "linux-x64" / "platform.json"
        value = artifacts.read_json(manifest)
        value["cases"]["test/ok/flow/a.yak"]["exit"] = "1"
        artifacts.write_json(manifest, value)
        output = self.root / "release"
        with self.assertRaisesRegex(ValueError, "跨目标"):
            artifacts.assemble(Namespace(root=self.root, output=output, commit=COMMIT, run=RUN))
        self.assertFalse(output.exists())

    def test_run_must_come_from_the_expected_workflow(self):
        workflow = ".github/workflows/release.yml"
        with patch.object(release, "REPOSITORY", "owner/yak"), patch.object(release, "api") as api:
            reply = dict(id=42, head_sha=COMMIT, head_branch="main", event="workflow_dispatch", path=workflow,
                         conclusion="success", head_repository={"full_name": "owner/yak"})
            api.return_value = reply
            release.check_run(RUN, COMMIT, workflow)
            for unsafe in ({"conclusion": "failure"}, {"head_branch": "other"}, {"path": "wrong.yml"},
                           {"head_sha": "b" * 40}, {"head_repository": {"full_name": "fork/yak"}}):
                api.return_value = reply | unsafe
                with self.subTest(unsafe=unsafe), self.assertRaises(ValueError):
                    release.check_run(RUN, COMMIT, workflow)

    def test_tag_protection_rejects_excluded_tag(self):
        tag = "v1.0.0"
        summary = [[{"id": 1, "target": "tag", "enforcement": "active"}]]
        condition = {"include": ["refs/tags/v*"], "exclude": []}
        ruleset = {"conditions": {"ref_name": condition}, "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}]}
        with patch.object(release, "api", side_effect=[summary, ruleset]):
            release.check_tag_protection(tag)
        condition["exclude"] = ["refs/tags/v1.0.0"]
        with patch.object(release, "api", side_effect=[summary, ruleset]), self.assertRaisesRegex(ValueError, "保护规则"):
            release.check_tag_protection(tag)

    def test_draft_upload_resumes_only_missing_assets(self):
        hashes = {"one.zip": "1" * 64, "two.tar.gz": "2" * 64}
        one, two = [{"name": name, "digest": f"sha256:{value}", "state": "uploaded"}
                    for name, value in hashes.items()]
        draft = {"id": 5, "tag_name": "v1.0.0", "draft": True, "assets": [one]}
        completed = draft | {"assets": [one, two], "html_url": "https://example.test/draft"}
        with (patch.object(release, "release_plan", return_value=COMMIT),
              patch.object(release, "checked_assets", return_value=hashes),
              patch.object(release, "releases", return_value=[draft]),
              patch.object(release, "api", return_value=completed),
              patch.object(release, "gh") as github):
            release.draft("v1.0.0", RUN, self.root)
            github.assert_called_once_with("release", "upload", "v1.0.0", str(self.root / "two.tar.gz"))
            github.reset_mock()
            one["digest"] = "sha256:" + "9" * 64
            with self.assertRaisesRegex(ValueError, "不同摘要"):
                release.draft("v1.0.0", RUN, self.root)
            github.assert_not_called()


if __name__ == "__main__":
    unittest.main()
