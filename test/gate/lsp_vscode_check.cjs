'use strict';

const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const fixture = path.join(__dirname, 'fixtures', 'lsp_vscode');
const [serverArg, codeArg] = process.argv.slice(2);
const windows = process.platform === 'win32';
assert(windows || process.platform === 'linux', '需要 Windows 或 Linux 原生客户端');
assert(serverArg && process.argv.length <= 4 && (windows || codeArg),
    '用法：node test/gate/lsp_vscode_check.cjs <语言服务> [VS Code 可执行文件]');
const server = fs.realpathSync(serverArg);
const code = fs.realpathSync(codeArg ?? path.join(process.env.ProgramFiles, 'Microsoft VS Code', 'Code.exe'));
const output = path.join(__dirname, 'tmp');
fs.mkdirSync(output, { recursive: true });
const evidence = fs.mkdtempSync(path.join(output, 'lsp-vscode.'));
console.log('编辑器验收记录：' + evidence);
const ext = path.join(evidence, 'extension');
const workspace = path.join(evidence, 'workspace');
const userData = path.join(evidence, 'user-data');
const extDir = path.join(evidence, 'extensions');
for (const dir of [ext, workspace, extDir, path.join(userData, 'User')]) fs.mkdirSync(dir, { recursive: true });
for (const filename of ['package.json', 'package-lock.json', 'check.cjs']) {
    fs.copyFileSync(path.join(fixture, filename), path.join(ext, filename));
}
fs.writeFileSync(path.join(workspace, 'Yak 中 文.yak'), '//中😀');
fs.writeFileSync(path.join(workspace, 'math.yak'), 'export function triple(v: u32): u32 {\n    return v * 3;\n}\n');
fs.writeFileSync(path.join(userData, 'User', 'settings.json'), JSON.stringify({
    'files.autoSave': 'off', 'files.eol': '\n', 'telemetry.telemetryLevel': 'off', 'workbench.startupEditor': 'none',
    'chat.disableAIFeatures': true,
    'extensions.autoCheckUpdates': false, 'extensions.autoUpdate': false, 'yak.trace.server': 'verbose',
}));
const hash = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const git = args => spawnSync('git', args, { cwd: root, encoding: 'utf8', windowsHide: true }).stdout?.trim();
const npmArgs = ['ci', '--ignore-scripts', '--no-audit', '--no-fund', '--prefer-offline'];
const install = spawnSync(windows ? process.env.ComSpec || 'cmd.exe' : 'npm',
    windows ? ['/d', '/c', ['npm', ...npmArgs].join(' ')] : npmArgs, {
    cwd: ext, stdio: 'inherit', timeout: 120000, windowsHide: true,
});
if (install.error) throw install.error;
assert.equal(install.status, 0, '安装固定客户端失败');
const args = ['--user-data-dir', userData, '--extensions-dir', extDir, '--new-window', '--disable-extensions',
    '--skip-welcome', '--skip-release-notes', '--disable-workspace-trust', '--extensionDevelopmentPath=' + ext,
    '--extensionTestsPath=' + path.join(ext, 'check.cjs'), workspace];
const env = { ...process.env, YAK_VSCODE_SERVER: server, YAK_VSCODE_EVIDENCE: evidence };
delete env.ELECTRON_RUN_AS_NODE;
const log = fs.openSync(path.join(evidence, 'launcher.log'), 'w');
const launch = spawnSync(code, args, { cwd: workspace, env, stdio: ['ignore', log, log], timeout: 120000 });
fs.closeSync(log);
fs.writeFileSync(path.join(evidence, 'run.json'), JSON.stringify({
    platform: process.platform, arch: process.arch, repositoryHead: git(['rev-parse', 'HEAD']),
    repositoryDirty: Boolean(git(['status', '--porcelain'])), client: 'vscode-languageclient@9.0.1',
    server, serverSha256: hash(server), lockSha256: hash(path.join(ext, 'package-lock.json')),
    code, args, status: launch.status, signal: launch.signal, error: launch.error?.message,
}, null, 2) + '\n');
if (launch.error) throw launch.error;
assert.equal(launch.status, 0, 'VS Code 扩展宿主测试失败');
assert.equal(JSON.parse(fs.readFileSync(path.join(evidence, 'editor.json'), 'utf8')).status, 'passed');
console.log('VS Code：握手、未保存诊断、清空及退出通过');
