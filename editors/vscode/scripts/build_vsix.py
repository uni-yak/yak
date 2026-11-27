"""将 editors/vscode 打包为标准 .vsix 并支持一键安装到本机 CodeBuddy CN。"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

EXT_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = EXT_DIR.parents[1]
DEFAULT_SERVER_CANDIDATES = [
    REPO_ROOT / "test/gate/tmp/lsp-p4-out/yak_lsp.exe",
    REPO_ROOT / "compiler/lsp/out/yak_lsp.exe",
    EXT_DIR / "bin/yak_lsp.exe",
]
DEFAULT_CODEBUDDY_CLI = Path(r"I:\Program\CodeBuddy CN\bin\buddycn.cmd")

CONTENT_TYPES_XML = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".cjs" ContentType="application/javascript"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".md" ContentType="text/markdown"/>
  <Default Extension=".txt" ContentType="text/plain"/>
  <Default Extension=".exe" ContentType="application/octet-stream"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
"""


def build_manifest_xml(pkg: dict) -> str:
    publisher = escape(pkg["publisher"])
    name = escape(pkg["name"])
    version = escape(pkg["version"])
    display = escape(pkg.get("displayName", pkg["name"]))
    desc = escape(pkg.get("description", ""))
    engine = escape(pkg["engines"]["vscode"])
    tags = escape(",".join(pkg.get("keywords", [])))
    categories = escape(",".join(pkg.get("categories", [])))
    return f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="{name}" Version="{version}" Publisher="{publisher}"/>
    <DisplayName>{display}</DisplayName>
    <Description xml:space="preserve">{desc}</Description>
    <Tags>{tags}</Tags>
    <Categories>{categories}</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="{engine}"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value=""/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value=""/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace"/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
    <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true"/>
  </Assets>
</PackageManifest>
"""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_server_binary(server_arg: str | None) -> Path:
    src = Path(server_arg) if server_arg else None
    if src is None:
        for cand in DEFAULT_SERVER_CANDIDATES:
            if cand.is_file():
                src = cand
                break
    if src is None or not src.is_file():
        raise FileNotFoundError(
            "未找到 yak_lsp.exe，请先执行 bash compiler/lsp/build.sh test/gate/tmp/lsp-p4-out 或传入 --server"
        )
    dst = EXT_DIR / "bin" / "yak_lsp.exe"
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.resolve() != dst.resolve():
        shutil.copy2(src, dst)
    print(f"已内置服务端：{dst} (SHA-256: {sha256_file(dst)})")
    return dst


def ensure_node_modules() -> None:
    nm = EXT_DIR / "node_modules" / "vscode-languageclient"
    if nm.is_dir():
        return
    npm = shutil.which("npm")
    if not npm:
        raise RuntimeError("未找到 npm，无法安装 vscode-languageclient 依赖")
    print("正在安装 editors/vscode 运行时依赖...")
    subprocess.run([npm, "install", "--omit=dev", "--no-audit", "--no-fund"], cwd=EXT_DIR, check=True)


def iter_package_files() -> list[tuple[Path, str]]:
    include_top = [
        "package.json",
        "language-configuration.json",
        "README.md",
        "syntaxes",
        "src",
        "bin",
        "node_modules",
    ]
    results: list[tuple[Path, str]] = []
    for item in include_top:
        p = EXT_DIR / item
        if p.is_file():
            results.append((p, f"extension/{item}"))
        elif p.is_dir():
            for root, dirs, files in os.walk(p):
                dirs.sort()
                # 排除 npm 缓存与无关测试目录以精简安装包体积。
                dirs[:] = [d for d in dirs if d not in (".bin", ".cache", "test", "tests", "__tests__")]
                for fn in sorted(files):
                    if fn.endswith((".map", ".ts")) and not fn.endswith(".d.ts"):
                        continue
                    full = Path(root) / fn
                    rel = full.relative_to(EXT_DIR).as_posix()
                    results.append((full, f"extension/{rel}"))
    return results


def pack_vsix(pkg: dict) -> Path:
    dist = EXT_DIR / "dist"
    dist.mkdir(parents=True, exist_ok=True)
    vsix = dist / f"{pkg['name']}-{pkg['version']}.vsix"
    files = iter_package_files()
    with zipfile.ZipFile(vsix, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", CONTENT_TYPES_XML.encode("utf-8"))
        zf.writestr("extension.vsixmanifest", build_manifest_xml(pkg).encode("utf-8"))
        for src, arc in files:
            zf.write(src, arc)
    print(f"已生成 VSIX：{vsix}（含 {len(files)} 个文件，{vsix.stat().st_size} 字节）")
    return vsix


def install_to_codebuddy(vsix: Path, cli: Path) -> None:
    if not cli.is_file():
        raise FileNotFoundError(f"未找到 CodeBuddy CLI：{cli}")
    print(f"正在通过 {cli} 安装扩展...")
    subprocess.run([str(cli), "--install-extension", str(vsix), "--force"], check=True)
    listed = subprocess.run([str(cli), "--list-extensions", "--show-versions"], capture_output=True, text=True, check=True)
    lines = [line.strip() for line in listed.stdout.splitlines() if "yak-lang" in line.lower()]
    if not lines:
        raise RuntimeError(f"安装后未在扩展列表中发现 yak-lang：{listed.stdout}")
    print(f"CodeBuddy CN 已安装扩展：{', '.join(lines)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", help="指定 yak_lsp.exe 路径")
    parser.add_argument("--install-codebuddy", action="store_true", help="打包后安装到本机 CodeBuddy CN")
    parser.add_argument("--codebuddy-cli", default=str(DEFAULT_CODEBUDDY_CLI), help="CodeBuddy CLI 路径")
    args = parser.parse_args()

    pkg = json.loads((EXT_DIR / "package.json").read_text("utf-8"))
    ensure_server_binary(args.server)
    ensure_node_modules()
    vsix = pack_vsix(pkg)
    if args.install_codebuddy:
        install_to_codebuddy(vsix, Path(args.codebuddy_cli))
    return 0


if __name__ == "__main__":
    sys.exit(main())
