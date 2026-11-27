'use strict';

// 在本机已安装的 CodeBuddy CN（VS Code 1.106.1 内核）中端到端验收已安装的 yak-lang 扩展。
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const CODEBUDDY_EXE = process.env.YAK_CODEBUDDY_EXE || 'I:\\Program\\CodeBuddy CN\\CodeBuddy CN.exe';
const CODEBUDDY_EXT_DIR = process.env.YAK_CODEBUDDY_EXT_DIR || path.join(os.homedir(), '.codebuddycn', 'extensions');
const RUNNER_PATH = path.join(__dirname, 'codebuddy_e2e_runner.cjs');

assert(fs.existsSync(CODEBUDDY_EXE), `未找到 CodeBuddy CN 主程序：${CODEBUDDY_EXE}`);
assert(fs.existsSync(CODEBUDDY_EXT_DIR), `未找到 CodeBuddy CN 扩展目录：${CODEBUDDY_EXT_DIR}`);

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'yak-codebuddy-e2e-'));
const workspaceDir = path.join(work, 'workspace');
const userDataDir = path.join(work, 'user-data');
const dummyDevExtDir = path.join(work, 'test-host-ext');
fs.mkdirSync(workspaceDir, { recursive: true });
fs.mkdirSync(userDataDir, { recursive: true });
fs.mkdirSync(dummyDevExtDir, { recursive: true });
// 提供空壳开发扩展目录以触发 CodeBuddy 扩展测试宿主，真实被测扩展从用户扩展目录加载。
fs.writeFileSync(
    path.join(dummyDevExtDir, 'package.json'),
    JSON.stringify({ name: 'yak-codebuddy-e2e-host', version: '0.0.1', engines: { vscode: '^1.90.0' } }, null, 2) + '\n',
    'utf8'
);

// 准备含多文件与中文路径的测试工作区。
fs.writeFileSync(
    path.join(workspaceDir, 'math.yak'),
    'export function triple(v: u32): u32 { return v * 3; }\n',
    'utf8'
);
fs.writeFileSync(
    path.join(workspaceDir, 'main.yak'),
    '//中😀',
    'utf8'
);

console.log(`CodeBuddy CN 实测目录：${work}`);

const result = spawnSync(
    CODEBUDDY_EXE,
    [
        workspaceDir,
        '--new-window',
        '--disable-workspace-trust',
        '--skip-welcome',
        '--skip-release-notes',
        `--user-data-dir=${userDataDir}`,
        `--extensions-dir=${CODEBUDDY_EXT_DIR}`,
        `--extensionDevelopmentPath=${dummyDevExtDir}`,
        `--extensionTestsPath=${RUNNER_PATH}`,
    ],
    {
        env: { ...process.env, YAK_CODEBUDDY_E2E_WORK: work },
        stdio: 'inherit',
        timeout: 90000,
    }
);

const reportPath = path.join(work, 'report.json');
assert(fs.existsSync(reportPath), `未生成验收报告：${reportPath}（exit=${result.status}）`);
const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
console.log(JSON.stringify(report, null, 2));
assert.equal(result.status, 0, 'CodeBuddy CN 扩展宿主测试退出非零');
assert.equal(report.status, 'passed', `验收未通过：${report.error || ''}`);
console.log('CodeBuddy CN 实测验收全部通过！');
