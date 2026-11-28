"""构建并定向验证首批 full 待确认候选，不生成确认或发布收据。"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
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
DYNAMIC_RANGE = Path('test/full/ok/range_runtime.yak')
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
    outputs = frames(proc.stdout)
    require(not proc.stderr and set(outputs) == {b'diag'},
            f'{name}：拒绝只允许诊断帧，实际 {list(outputs)!r}，stderr={proc.stderr!r}')
    raw = outputs[b'diag']
    require(raw.endswith(b'\n') and b'\r' not in raw, f'{name}：预期 LF 结尾的 JSONL')
    rows = [json.loads(line) for line in raw.splitlines()]
    errors = [row for row in rows if row['severity'] == 'error']
    actual = [row['code'] for row in errors]
    require(actual and (codes is None or actual == codes), f'{name}：预期 {codes}，实际 {actual}')
    return errors


def reject_at(root, executable, target, name, source, code, marker, length=None):
    require(source.count(marker) == 1, f'{name}：诊断定位标记必须唯一：{marker!r}')
    row, = reject(compile_source(root, executable, target, name, source), name, [code])
    expected = {'off': source.index(marker), 'len': len(marker) if length is None else length}
    require(row['unit'] == name and row['span'] == expected,
            f"{name}：预期 E{code} 位置 {expected}，实际 {row!r}")
    print(f'通过：{executable.stem} {name} E{code}，位置精确且无编译产物', flush=True)


def closed_program(upper):
    return (b'function main(): void { let arr: [u8; 4] = [1u8, 2u8, 3u8, 4u8]; '
            b'let view: &[u8] = &arr[0u8..=' + upper + b']; @assert(@len(view) == 0u64); return; }\n')


def regressions(root, target, minimum, full):
    for name, upper in (
        ('range_cast_sum', b'((255u16 as u8) + 0u8)'),
        ('range_signed_max', b'((126i16 as i8) + 1i8)'),
        ('range_wide_max', b'(18446744073709551614u64 + 1u64)'),
    ):
        reject_at(root, full, target, name, closed_program(upper), 3005, upper)

    move_call = (b'function take(x: u8[]): void { @drop(x); return; } '
                 b'function main(): void { var x: u8[] = []; take((x.move())); return; }\n')
    reject_at(root, full, target, 'chain_grouped_move', move_call, 6201, b'(x.move())', 1)
    prefixed_move = move_call.replace(b'x.move()', b'@move(x)')
    reject_at(root, minimum, target, 'base_grouped_move', prefixed_move, 6201, b'(@move(x))', 1)

    for name, statement, marker in (
        ('chain_grouped_drop', b'(x.drop());', b'x.drop()'),
        ('chain_drop_target', b'x.drop() = x;', b'x.drop()'),
        ('chain_move_arity_target', b'x.move(1u8) = x;', b'x.move(1u8)'),
    ):
        source = b'function main(): void { var x: u8[] = []; ' + statement + b' return; }\n'
        reject_at(root, full, target, name, source, 2001, marker)

    batch = (b'function main(): void { let x: u8 = 0u8; let arr: [u8; 1] = [1u8]; '
             b'@drop(x, arr[0]); return; }\n')
    reject_at(root, full, target, 'batch_projection', batch, 6206, b'arr[0]')
    repeat = b'function main(): void { var x: u8[] = []; @drop(x, x); return; }\n'
    reject_at(root, full, target, 'batch_duplicate', repeat, 6003, b'x, x', 1)

    def borrowed(statement):
        return (b'function bad(r: &u8[]:ReadWrite): void { ' + statement +
                b' return; } function main(): void { return; }\n')

    base_drop = borrowed(b'@drop(*r);')
    reject_at(root, minimum, target, 'base_borrowed_drop', base_drop, 6204, b'@drop')
    reject_at(root, full, target, 'batch_borrowed_drop',
              borrowed(b'let x: u8 = 0u8; @drop(x, *r);'), 6204, b'*r')
    reject_at(root, full, target, 'chain_borrowed_drop', borrowed(b'(*r).drop();'), 6204, b'(*r).drop()')

    for name, compiler, loop, jump in (
        ('base_unknown_break', minimum, b'while true', b'break'),
        ('base_unknown_continue', minimum, b'while true', b'continue'),
        ('full_unknown_break', full, b'loop', b'break'),
        ('full_unknown_continue', full, b'loop', b'continue'),
    ):
        source = b'function main(): void { outer: ' + loop + b' { ' + jump + b' missing; } return; }\n'
        reject_at(root, compiler, target, name, source, 4002, jump)
    unreachable = b'function main(): void { while true { return; break missing; } return; }\n'
    reject_at(root, minimum, target, 'base_unreachable_label', unreachable, 4002, b'break')

    # 括号隔开点号成员和调用时，候选必须保留基座对普通字段调用的诊断。
    field = b'function main(): void { var x: u8[] = []; (x.drop)(); return; }\n'
    base = compile_source(root, minimum, target, 'grouped_field', field)
    candidate = compile_source(root, full, target, 'grouped_field', field)
    reject(base, '基座括号字段调用')
    reject(candidate, '候选括号字段调用')
    require(base.stdout == candidate.stdout, '候选不能把括号字段调用改写为所有权动作')
    print('通过：括号字段调用保留基座诊断', flush=True)


def link_case(root, target, suffix, bash, env, relative):
    name = Path(relative).stem
    built = run(root, [bash, 'tools/link.sh', relative, '--no-run', '--target', target,
                       '--native-compiler', f'tmp/build/yakc_full.{suffix}', '--out-dir', 'tmp/runs'], env=env)
    success(built, f'链接 {name}')
    return str(root / f'tmp/runs/{name}/{name}.{suffix}')


def runtime_range(root, target, suffix, bash, env):
    exe = link_case(root, target, suffix, bash, env, DYNAMIC_RANGE.as_posix())
    proc = run(root, [exe], b'\x02')
    success(proc, '运行时 u8 闭区间')
    require(proc.stdout == b'before\nthree\nafter\n' and not proc.stderr, '正常上界输出不符')
    # 只抑制宿主的崩溃对话框或转储，不改写子进程的退出状态。
    if target == 'win-x64':
        import ctypes
        kernel = ctypes.windll.kernel32
        old = kernel.GetErrorMode()
        kernel.SetErrorMode(old | 0x0002)
        try:
            proc = run(root, [exe], b'\xff')
        finally:
            kernel.SetErrorMode(old)
        trap = proc.returncode & 0xffffffff == 0x80000003
    else:
        import resource
        old = resource.getrlimit(resource.RLIMIT_CORE)
        resource.setrlimit(resource.RLIMIT_CORE, (0, old[1]))
        try:
            proc = run(root, [exe], b'\xff')
        finally:
            resource.setrlimit(resource.RLIMIT_CORE, old)
        trap = proc.returncode == -signal.SIGTRAP
    require(trap and proc.stdout == b'before\n' and not proc.stderr,
            f'预期上界加一触发原生算术陷阱，实际 {proc.returncode} {proc.stdout!r} {proc.stderr!r}')
    print('通过：同一运行产物按 u8 原宽度捕获上界加一溢出', flush=True)


def probe(root, target, suffix, bash, env):
    minimum = root / f'tmp/bootstrap/main.{suffix}'
    min_scan = root / f'tmp/bootstrap/imports.{suffix}'
    full = root / f'tmp/build/yakc_full.{suffix}'
    full_scan = root / f'tmp/build/full_imports.{suffix}'
    for name, code in BAD.items():
        fixture = root / f'test/full/variants_bad/E{code}/{name}.yak'
        source = fixture.read_bytes()
        if name == 'closed_range_u8_max':
            reject_at(root, full, target, name, source, code, b'255u8];', 5)
        else:
            reject(compile_source(root, full, target, name, source), name, [code])
            print(f'通过：{name} E{code}', flush=True)
    regressions(root, target, minimum, full)
    for name, stdout in OK.items():
        rel = f'test/full/ok/{name}.yak'
        source = (root / rel).read_bytes()
        scan = tool(root, full_scan, ['scan'], source)
        success(scan, f'full 扫描 {name}')
        require(scan.stdout == b'', f'{name} 应独立且不导入其他模块')
        reject(compile_source(root, minimum, target, name, source), f'min 边界 {name}')
        exe = link_case(root, target, suffix, bash, env, rel)
        executed = run(root, [exe])
        success(executed, f'运行 {name}')
        require(executed.stdout.replace(b'\r\n', b'\n') == stdout,
                f'{name}：预期 stdout={stdout!r}，实际 {executed.stdout!r}')
        print(f'通过：{name} 编译、链接、运行和 min 拒绝', flush=True)

    runtime_range(root, target, suffix, bash, env)

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
    exports += (DYNAMIC_RANGE,)
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
