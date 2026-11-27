#!/usr/bin/env python3
"""核验可信运行及已验收资产，并写入待审核的 GitHub 草稿。"""

import argparse
from fnmatch import fnmatchcase
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

from ci_artifacts import PACKAGES, digest, read_json


REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "")
SEMVER = re.compile(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-rc\.[1-9]\d*)?")
COMMIT = re.compile(r"[0-9a-f]{40}")
RUN = re.compile(r"[1-9][0-9]*")


def git(*args):
    return subprocess.check_output(["git", *args], encoding="utf-8").strip()


def gh(*args):
    return subprocess.check_output(["gh", *args], encoding="utf-8")


def api(*args):
    return json.loads(gh("api", *args))


def check_run(run, commit, workflow):
    if not RUN.fullmatch(run) or not COMMIT.fullmatch(commit):
        raise ValueError("需要有效的 GitHub 运行编号和完整提交")
    result = api(f"repos/{REPOSITORY}/actions/runs/{run}")
    if (str(result["id"]), result["head_sha"], result["head_branch"], result["event"],
            result["path"].split("@", 1)[0], result["conclusion"], result["head_repository"]["full_name"]) != (
            run, commit, "main", "workflow_dispatch", workflow, "success", REPOSITORY):
        raise ValueError("归档必须来自同一仓库、可信 main、指定提交的成功运行")


def check_tag_protection(tag):
    ref = f"refs/tags/{tag}"
    endpoint = f"repos/{REPOSITORY}/rulesets"
    pages = api(f"{endpoint}?targets=tag&includes_parents=true&per_page=100", "--paginate", "--slurp")
    required = set()
    for summary in (entry for page in pages for entry in page):
        if summary["enforcement"] != "active" or summary["target"] != "tag":
            continue
        ruleset = api(f"{endpoint}/{summary['id']}?includes_parents=true")
        condition = ruleset.get("conditions", {}).get("ref_name", {})
        included = any(pattern == "~ALL" or fnmatchcase(ref, pattern) for pattern in condition.get("include", []))
        excluded = any(fnmatchcase(ref, pattern) for pattern in condition.get("exclude", []))
        if included and not excluded:
            required.update(rule["type"] for rule in ruleset["rules"])
    if "deletion" not in required or required.isdisjoint({"update", "non_fast_forward"}):
        raise ValueError("版本标签需要生效的删除和改写保护规则")


def release_plan(tag, run):
    if not SEMVER.fullmatch(tag):
        raise ValueError("标签须为 v主.次.修订 或 v主.次.修订-rc.序号")
    check_tag_protection(tag)
    remote = api(f"repos/{REPOSITORY}/git/ref/tags/{tag}")["object"]
    if git("rev-parse", "--verify", f"refs/tags/{tag}") != remote["sha"]:
        raise ValueError("本地标签与远端标签不一致")
    commit = git("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    git("merge-base", "--is-ancestor", commit, "refs/remotes/origin/main")
    check_run(run, commit, ".github/workflows/release.yml")
    return commit


def checked_assets(directory, commit, run):
    manifest = read_json(directory / "build-manifest.json")
    names = set(PACKAGES.values())
    if (manifest["commit"] != commit or manifest["run"] != run or manifest["compared_cases"] <= 0
            or not re.fullmatch(r"[0-9a-f]{64}", manifest["candidate"]) or set(manifest["assets"]) != names):
        raise ValueError("发布清单缺少双平台验收或归档身份不符")
    hashes = {name: digest(directory / name) for name in names}
    if hashes != manifest["assets"]:
        raise ValueError("发布包摘要与清单不一致")
    hashes["build-manifest.json"] = digest(directory / "build-manifest.json")
    expected = "".join(f"{value}  {name}\n" for name, value in sorted(hashes.items())).encode("ascii")
    if (directory / "SHA256SUMS").read_bytes() != expected:
        raise ValueError("SHA256SUMS 与实际资产不一致")
    hashes["SHA256SUMS"] = digest(directory / "SHA256SUMS")
    return hashes


def releases():
    pages = api("repos/" + REPOSITORY + "/releases?per_page=100", "--paginate", "--slurp")
    return [release for page in pages for release in page]


def create_notes(existing, commit, run):
    for release in existing:
        if release["draft"] or release["prerelease"]:
            continue
        ref = "refs/tags/" + release["tag_name"]
        result = subprocess.run(["git", "merge-base", "--is-ancestor", ref, commit],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if result.returncode == 0:
            commit = f"{ref}..{commit}"
            break
    notes = git("log", "--no-merges", "--format=- %s (%h)", commit)
    return f"## 变更\n\n{notes}\n\n验收运行 {run}\n"


def draft(tag, run, directory):
    commit = release_plan(tag, run)
    hashes = checked_assets(directory, commit, run)
    existing = releases()
    release = next((value for value in existing if value["tag_name"] == tag), None)
    if release is None:
        with tempfile.TemporaryDirectory() as tmp:
            notes = Path(tmp) / "release-notes.md"
            notes.write_text(create_notes(existing, commit, run), encoding="utf-8", newline="\n")
            flags = ["--prerelease"] if "-rc." in tag else []
            print(gh("release", "create", tag, "--verify-tag", "--draft", "--title", tag,
                     "--notes-file", str(notes), *flags).strip())
        for attempt in range(5):
            release = next((value for value in releases() if value["tag_name"] == tag), None)
            if release is not None:
                break
            if attempt < 4:
                time.sleep(2)
        if release is None:
            raise ValueError(f"草稿 Release 创建后未能从列表读回：{tag}")
    if not release["draft"]:
        raise ValueError("标签已发布")
    for entry in release["assets"]:
        name = entry["name"]
        if name not in hashes or entry["state"] != "uploaded" or entry.get("digest") != f"sha256:{hashes[name]}":
            raise ValueError(f"草稿存在意外、未完成或不同摘要的资产：{name}")
    remote_names = {entry["name"] for entry in release["assets"]}
    absent = sorted(hashes.keys() - remote_names)
    if absent:
        gh("release", "upload", tag, *(str(directory / name) for name in absent))
    release = api(f"repos/{REPOSITORY}/releases/{release['id']}")
    assets = {entry["name"]: entry.get("digest") for entry in release["assets"] if entry["state"] == "uploaded"}
    if not release["draft"] or assets != {name: f"sha256:{value}" for name, value in hashes.items()}:
        raise ValueError("草稿状态或最终资产摘要不符")
    print(release["html_url"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    check = sub.add_parser("check-run")
    check.add_argument("run")
    check.add_argument("commit")
    check.add_argument("workflow")
    plan = sub.add_parser("plan")
    plan.add_argument("tag")
    plan.add_argument("run")
    publish = sub.add_parser("draft")
    publish.add_argument("tag")
    publish.add_argument("run")
    publish.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "check-run":
            check_run(args.run, args.commit, args.workflow)
        elif args.operation == "plan":
            print(release_plan(args.tag, args.run))
        else:
            draft(args.tag, args.run, args.directory)
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        parser.exit(1, f"错误：{error}\n")


if __name__ == "__main__":
    main()
