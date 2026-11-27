#!/usr/bin/env python3
"""以隔离的 Neovim 内置 LSP 客户端验收正式候选。"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 3:
        raise SystemExit("用法：python test/gate/lsp_neovim_check.py <yak_lsp.exe> <nvim.exe>")
    server, nvim = (Path(arg).resolve(strict=True) for arg in sys.argv[1:])
    if not server.is_file() or not nvim.is_file():
        raise SystemExit("需要候选服务和 Neovim 可执行文件")
    gate = Path(__file__).resolve().parent
    scratch = gate / "tmp"
    scratch.mkdir(exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="lsp-neovim.", dir=scratch))
    workspace = evidence / "workspace"
    workspace.mkdir()
    (workspace / "Yak 中 文.yak").write_bytes("//中😀".encode("utf-8"))
    env = os.environ.copy()
    for name in ("CONFIG", "DATA", "STATE", "CACHE", "RUNTIME"):
        isolated = evidence / name.lower()
        isolated.mkdir()
        env[f"XDG_{name}_HOME" if name != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(isolated)
    env.update(YAK_NVIM_SERVER=str(server), YAK_NVIM_EVIDENCE=str(evidence), NVIM_APPNAME="yak-lsp-gate",
               NVIM_LOG_FILE=str(evidence / "nvim.log"))
    command = [str(nvim), "--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-l",
               str(gate / "fixtures" / "lsp_neovim_check.lua")]
    record = {
        "command": command,
        "repositoryHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=gate, text=True).strip(),
        "server": str(server),
        "serverSha256": hashlib.sha256(server.read_bytes()).hexdigest(),
        "neovim": str(nvim),
        "neovimSha256": hashlib.sha256(nvim.read_bytes()).hexdigest(),
    }
    with (evidence / "launcher.log").open("wb") as log:
        try:
            status = subprocess.run(command, cwd=workspace, env=env, stdin=subprocess.DEVNULL,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=120, check=False).returncode
        except subprocess.TimeoutExpired:
            status = 124
            record["error"] = "Neovim 验收超过 120 秒"
    record["status"] = status
    if status == 0:
        try:
            editor = json.loads((evidence / "editor.json").read_text(encoding="utf-8"))
            if editor["status"] != "passed" or not Path(editor["trace"]).is_file():
                raise ValueError("缺少成功记录或原始协议日志")
        except (OSError, ValueError, KeyError) as exc:
            record.update(status=1, error=str(exc))
    (evidence / "run.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n",
                                       encoding="utf-8", newline="\n")
    print(f"Neovim LSP evidence: {evidence}")
    return record["status"]


if __name__ == "__main__":
    sys.exit(main())
