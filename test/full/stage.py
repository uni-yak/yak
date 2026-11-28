"""构建并定向验证首批 full 待确认候选，不生成确认或发布收据。"""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

OK = {
    'batch_drop': b'ok\n', 'chained_actions': b'33\n',
    'closed_range': b'24\n', 'loop_basic': b'10\n',
}
BAD = {
    'chain_arity': 2001, 'drop_arity': 2001, 'drop_expr_in_value': 2001,
    'if_let_fallible': 3004, 'closed_range_u8_max': 3005, 'if_let_non_fallible': 3008,
}
BASE = Path('test/ok/flow/labeled_break.yak')
OWNED = (
    Path('compiler/min/build.sh'), Path('compiler/min/lib'), Path('compiler/min/src'),
    Path('compiler/min/host/stream'), Path('compiler/full/build.sh'),
    Path('compiler/full/selfhost.sh'), Path('compiler/full/src/driver'),
    Path('compiler/full/src/desugar'), Path('spec'), Path('tools/target.sh'),
    Path('tools/native_stream.sh'),
    Path('tools/link.sh'), Path('tools/coff_sections.py'), Path('tools/elf_headers.py'),
    Path('tools/error_codes.py'), Path('tools/pe_digest.py'), Path('tools/symgen'), Path('versions.lock'), BASE,
)


def require(condition, context):
    if not condition:
        raise RuntimeError(context)


def copy_source(source, destination):
    if source.is_dir():
        shutil.copytree(source, destination, ignore=shutil.ignore_patterns('__pycache__'))
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def run(root, args, data=None, *, env=None):
    return subprocess.run(args, cwd=root, input=data, env=env, capture_output=True, timeout=120)


def success(proc, label):
    require(proc.returncode == 0, f'{label}: 退出 {proc.returncode}\n{proc.stdout!r}\n{proc.stderr!r}')


def frame(data):
    return struct.pack('<I', len(data)) + data


def tool(root, executable, args, src):
    argv = b''.join(a.encode('ascii') + b'\0' for a in args)
    return run(root, [str(executable)], b'YKH1' + frame(argv) + frame(b'src') + frame(src))


def frames(raw):
    def field(pos):
        require(pos + 4 <= len(raw), 'YKH1 帧长度截断')
        end = pos + 4 + struct.unpack_from('<I', raw, pos)[0]
        require(end <= len(raw), 'YKH1 帧载荷截断')
        return raw[pos + 4:end], end

    result = {}
    pos = 0
    while pos < len(raw):
        name, pos = field(pos)
        payload, pos = field(pos)
        require(name and name not in result, f'无效响应帧名 {name!r}')
        result[name] = payload
    return result


def compile_source(root, executable, target, name, source):
    args = ['--diag=jsonl']
    if target == 'linux-x64':
        args.append('--target=linux-x64')
    return tool(root, executable, args + ['src', name, 'root'], source)


def reject(proc, name, codes=None):
    require(proc.returncode == 1, f'{name}：预期诊断退出 1，实际 {proc.returncode}: {proc.stderr!r}')
    rows = [json.loads(line) for line in frames(proc.stdout).get(b'diag', b'').splitlines()]
    actual = [row['code'] for row in rows if row['severity'] == 'error']
    require(actual and (codes is None or actual == codes), f'{name}：预期 {codes}，实际 {actual}')
    return actual


def probe(root, target, suffix, bash, env):
    minimum = root / f'tmp/bootstrap/main.{suffix}'
    min_scan = root / f'tmp/bootstrap/imports.{suffix}'
    full = root / f'tmp/build/yakc_full.{suffix}'
    full_scan = root / f'tmp/build/full_imports.{suffix}'
    for name, code in BAD.items():
        fixture = root / f'test/full/variants_bad/E{code}/{name}.yak'
        reject(compile_source(root, full, target, name, fixture.read_bytes()), name, [code])
        print(f'通过：{name} E{code}', flush=True)
    for name, stdout in OK.items():
        rel = f'test/full/ok/{name}.yak'
        source = (root / rel).read_bytes()
        scan = tool(root, full_scan, ['scan'], source)
        success(scan, f'full 扫描 {name}')
        require(scan.stdout == b'', f'{name} 应独立且不导入其他模块')
        reject(compile_source(root, minimum, target, name, source), f'min 边界 {name}')
        linked = run(root, [bash, 'tools/link.sh', rel, '--no-run', '--target', target,
                            '--native-compiler', f'tmp/build/yakc_full.{suffix}', '--out-dir', 'tmp/runs'], env=env)
        success(linked, f'链接 {name}')
        executed = run(root, [str(root / f'tmp/runs/{name}/{name}.{suffix}')])
        success(executed, f'运行 {name}')
        require(executed.stdout.replace(b'\r\n', b'\n') == stdout,
                f'{name}：预期 stdout={stdout!r}，实际 {executed.stdout!r}')
        print(f'通过：{name} 编译、链接、运行和 min 拒绝', flush=True)

    tuple_source = b'function main(): void { let t: (u8, u8) = (1u8, 2u8); return; }\n'
    for native in (minimum, full):
        reject(compile_source(root, native, target, 'tuple_boundary', tuple_source), f'{native.name} tuple 边界')
    print('通过：min 与 full 均拒绝 tuple', flush=True)

    source = (root / BASE).read_bytes()
    scans = [tool(root, exe, ['scan'], source) for exe in (min_scan, full_scan)]
    compiled = [compile_source(root, exe, target, BASE.stem, source) for exe in (minimum, full)]
    for proc in scans + compiled:
        success(proc, '基座差分')
    require(scans[0].stdout == scans[1].stdout, '基座扫描输出不同')
    left, right = (frames(proc.stdout) for proc in compiled)
    for key in (b'obj', b'iface'):
        require(left.get(key) and left[key] == right.get(key), f'基座 {key!r} 缺失或不同')
    print('通过：基座样本扫描输出、obj 和 iface 逐字节一致', flush=True)

    source = (root / 'test/full/ok/batch_drop.yak').read_bytes()
    batch = b'@drop(a, b, c);'
    require(source.count(batch) == 1, '批量顺序样本缺失或不唯一')
    outputs = []
    for form in (batch, b'@drop(c); @drop(b); @drop(a);', b'@drop(a); @drop(b); @drop(c);'):
        proc = compile_source(root, full, target, 'batch_drop', source.replace(batch, form))
        success(proc, f'析构顺序 {form!r}')
        outputs.append(frames(proc.stdout).get(b'obj'))
    require(all(outputs) and outputs[0] == outputs[1] and outputs[0] != outputs[2],
            '批量产物必须等于逆序单参产物，且不同于正序')
    print('通过：批量 @drop 逆序产物对照', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bash-executable', required=True, type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--target', required=True, choices=('win-x64', 'linux-x64'))
    parser.add_argument('--native-compiler', required=True, type=Path)
    parser.add_argument('--native-scanner', required=True, type=Path)
    args = parser.parse_args()
    require(args.bash_executable.is_absolute() and args.bash_executable.is_file(),
            '候选入口须提供当前 Bash 的绝对可执行文件路径')
    bash = str(args.bash_executable)
    target = args.target
    suffix = 'elf' if target == 'linux-x64' else 'exe'
    require((os.name == 'nt') == (suffix == 'exe'), '候选仅支持在原生目标宿主运行')
    require(not os.environ.get('YAK_PE_RUNNER'), '候选不接受 YAK_PE_RUNNER')
    tmp = Path.cwd() / 'tmp'
    require(not tmp.is_symlink() and tmp.resolve() == tmp, 'tmp 必须是仓库内实际目录')
    tmp.mkdir(exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='full-stage-', dir=tmp))
    print(f'首批候选独占目录：{root}', flush=True)
    exports = tuple(Path(f'test/full/ok/{name}.yak') for name in OK)
    exports += tuple(Path(f'test/full/variants_bad/E{code}/{name}.yak') for name, code in BAD.items())
    inputs = tuple(p for p in OWNED if p != Path('tools/elf_headers.py') or suffix == 'elf')
    for path in inputs + exports:
        copy_source(path, root / path)
    bootstrap = root / 'tmp/bootstrap'
    bootstrap.mkdir(parents=True)
    for name, source in (('main', args.native_compiler), ('imports', args.native_scanner)):
        copy_source(source, bootstrap / f'{name}.{suffix}')
    env = dict(os.environ, LC_ALL='C', TZ='UTC')
    if suffix == 'elf':
        require(not env.get('YAK_RUNTIME_OBJ'), 'ELF 候选只使用源码构建运行时')
        copy_source(Path('runtime/src/linux'), root / 'runtime/src/linux')
        copy_source(Path('runtime/src/value_ops.inc'), root / 'runtime/src/value_ops.inc')
    else:
        runtime = Path(env.get('YAK_RUNTIME_OBJ') or 'runtime/out/win_x64/runtime.obj')
        copy_source(runtime, bootstrap / 'runtime.obj')
        env['YAK_RUNTIME_OBJ'] = 'tmp/bootstrap/runtime.obj'
    subprocess.run([bash, 'compiler/full/selfhost.sh', '--target', target,
                    '--out-dir', 'tmp/build', '--audit-dir', 'tmp/audit',
                    '--native-compiler', f'tmp/bootstrap/main.{suffix}',
                    '--native-scanner', f'tmp/bootstrap/imports.{suffix}'],
                   cwd=root, env=env, check=True)
    probe(root, target, suffix, bash, env)
    print('通过：首批 full 待确认候选定向验证', flush=True)


if __name__ == '__main__':
    main()
