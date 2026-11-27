'use strict';

// Yak 语言扩展宿主（兼容 CodeBuddy CN 与 VS Code）：负责启动 yak_lsp.exe、同步工作区文件并提供运维命令。
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

// 与 compiler/lsp/workspace_index.yak 中的服务端上限保持一致。
const SERVER_MAX_FILES = 64;
const SERVER_MAX_FILE_BYTES = 65536;
const DEFAULT_EXCLUDES = [
    '**/.git/**',
    '**/node_modules/**',
    '**/tmp/**',
    '**/out/**',
    '**/seed/test/**',
    '**/test/gate/tmp/**',
];

let client = null;
let statusBar = null;
let outputChannel = null;
let watcher = null;
let activeServerProc = null;

// 按优先级定位 yak_lsp.exe：用户配置 > 扩展内置 bin/ > 当前工作区构建产物。
function resolveServerPath(context, config) {
    const configured = (config.get('lsp.path') || '').trim();
    if (configured) {
        if (path.isAbsolute(configured)) {
            return fs.existsSync(configured) ? configured : null;
        }
        const folders = vscode.workspace.workspaceFolders || [];
        for (const folder of folders) {
            const candidate = path.join(folder.uri.fsPath, configured);
            if (fs.existsSync(candidate)) return candidate;
        }
        const extRel = path.join(context.extensionPath, configured);
        if (fs.existsSync(extRel)) return extRel;
        return null;
    }

    const bundled = path.join(context.extensionPath, 'bin', 'yak_lsp.exe');
    if (fs.existsSync(bundled)) return bundled;

    const workspaceFallbacks = [
        path.join('compiler', 'lsp', 'out', 'yak_lsp.exe'),
        path.join('test', 'gate', 'tmp', 'lsp-p4-out', 'yak_lsp.exe'),
        path.join('out', 'yak_lsp.exe'),
    ];
    for (const folder of vscode.workspace.workspaceFolders || []) {
        for (const rel of workspaceFallbacks) {
            const candidate = path.join(folder.uri.fsPath, rel);
            if (fs.existsSync(candidate)) return candidate;
        }
    }
    return null;
}

// 构造 glob 排除表达式，用于在大型仓库下避免被测试文件挤占 64 文件索引槽位。
function buildExcludeGlob(config) {
    const raw = config.get('workspace.exclude');
    const patterns = Array.isArray(raw) && raw.length > 0 ? raw : DEFAULT_EXCLUDES;
    if (patterns.length === 1) return patterns[0];
    return `{${patterns.join(',')}}`;
}

// 计算工作区文件相对当前活动编辑器的优先级，优先保留同目录及核心源码模块。
function scoreWorkspaceUri(uri, activeDir) {
    const fsPath = uri.fsPath.toLowerCase();
    if (activeDir && fsPath.startsWith(activeDir)) return 0;
    if (fsPath.includes(`${path.sep}examples${path.sep}`)) return 1;
    if (fsPath.includes(`${path.sep}pkg${path.sep}`)) return 2;
    if (fsPath.includes(`${path.sep}compiler${path.sep}lsp${path.sep}`)) return 3;
    return 4;
}

// 扫描工作区 .yak 文件并裁剪到服务端允许的文件数与单文件字节数上限内。
async function collectWorkspaceFiles(config) {
    const rawMax = Number(config.get('workspace.maxFiles') || SERVER_MAX_FILES);
    const maxFiles = Math.max(1, Math.min(SERVER_MAX_FILES, Number.isFinite(rawMax) ? rawMax : SERVER_MAX_FILES));
    const exclude = buildExcludeGlob(config);
    const uris = await vscode.workspace.findFiles('**/*.yak', exclude, maxFiles * 4);

    const activeUri = vscode.window.activeTextEditor && vscode.window.activeTextEditor.document.languageId === 'yak'
        ? vscode.window.activeTextEditor.document.uri
        : null;
    const activeDir = activeUri ? (path.dirname(activeUri.fsPath).toLowerCase() + path.sep) : '';

    uris.sort((a, b) => {
        const diff = scoreWorkspaceUri(a, activeDir) - scoreWorkspaceUri(b, activeDir);
        if (diff !== 0) return diff;
        return a.fsPath.localeCompare(b.fsPath);
    });

    const files = [];
    for (const uri of uris) {
        if (files.length >= maxFiles) break;
        try {
            const stat = await fsp.stat(uri.fsPath);
            if (!stat.isFile() || stat.size > SERVER_MAX_FILE_BYTES) continue;
            const text = await fsp.readFile(uri.fsPath, 'utf8');
            if (Buffer.byteLength(text, 'utf8') > SERVER_MAX_FILE_BYTES) continue;
            files.push({ uri: uri.toString(), text });
        } catch {
            // 跳过读取失败或瞬时消失的文件，不阻塞主启动流程。
        }
    }
    return files;
}

function updateStatus(text, tooltip) {
    if (!statusBar) return;
    statusBar.text = text;
    statusBar.tooltip = tooltip;
    statusBar.show();
}

async function stopLanguageClient() {
    if (watcher) {
        watcher.dispose();
        watcher = null;
    }
    if (client) {
        const current = client;
        client = null;
        try {
            if (current.needsStop()) {
                await current.stop();
            }
        } catch (err) {
            if (outputChannel) {
                outputChannel.appendLine(`[Yak] 停止语言服务器时出错: ${err && err.message ? err.message : String(err)}`);
            }
        }
    }
    if (activeServerProc && activeServerProc.exitCode === null && activeServerProc.signalCode === null) {
        try {
            activeServerProc.kill();
        } catch {
            // 忽略已退出进程。
        }
    }
    activeServerProc = null;
}

// 将单个文件的变更或删除通过 yak/workspaceFiles 通知增量同步给服务端。
async function syncSingleFile(uri, removed) {
    if (!client || !client.isRunning()) return;
    try {
        if (removed) {
            await client.sendNotification('yak/workspaceFiles', { remove: [uri.toString()] });
            return;
        }
        const stat = await fsp.stat(uri.fsPath);
        if (!stat.isFile() || stat.size > SERVER_MAX_FILE_BYTES) return;
        const text = await fsp.readFile(uri.fsPath, 'utf8');
        if (Buffer.byteLength(text, 'utf8') > SERVER_MAX_FILE_BYTES) return;
        await client.sendNotification('yak/workspaceFiles', {
            files: [{ uri: uri.toString(), text }],
        });
    } catch {
        // 忽略瞬间删改产生的读取竞态。
    }
}

async function startLanguageClient(context) {
    await stopLanguageClient();
    const config = vscode.workspace.getConfiguration('yak');
    if (!config.get('lsp.enabled', true)) {
        updateStatus('$(circle-slash) Yak LSP', 'Yak LSP 已在配置中禁用（仅启用语法高亮）');
        return;
    }

    const serverPath = resolveServerPath(context, config);
    if (!serverPath) {
        updateStatus('$(warning) Yak LSP 缺失', '未找到 yak_lsp.exe，请在设置中配置 yak.lsp.path');
        outputChannel.appendLine('[Yak] 未找到 yak_lsp.exe，已仅启用语法高亮与编辑配置。');
        vscode.window.showWarningMessage('Yak 扩展未找到 yak_lsp.exe，请在设置中配置 yak.lsp.path 后重启语言服务器。');
        return;
    }

    updateStatus('$(sync~spin) Yak LSP', `正在启动 ${serverPath}`);
    outputChannel.appendLine(`[Yak] 启动语言服务器: ${serverPath}`);
    const workspaceFiles = await collectWorkspaceFiles(config);
    outputChannel.appendLine(`[Yak] 初始化同步工作区 .yak 文件数: ${workspaceFiles.length}`);

    const semanticEnabled = config.get('semanticHighlighting.enabled', true);
    const serverOptions = async () => {
        const proc = spawn(serverPath, [], { stdio: 'pipe', windowsHide: true });
        activeServerProc = proc;
        proc.stderr.setEncoding('utf8').on('data', chunk => {
            outputChannel.append(`[yak_lsp stderr] ${chunk}`);
        });
        proc.once('exit', (code, signal) => {
            outputChannel.appendLine(`[Yak] yak_lsp 退出 (code=${code}, signal=${signal})`);
            if (activeServerProc === proc) activeServerProc = null;
        });
        await new Promise((resolve, reject) => {
            proc.once('spawn', resolve);
            proc.once('error', reject);
        });
        return { reader: proc.stdout, writer: proc.stdin };
    };

    const clientOptions = {
        documentSelector: [{ scheme: 'file', language: 'yak' }],
        initializationOptions: { workspaceFiles },
        outputChannel,
        middleware: {
            provideDocumentSemanticTokens(document, token, next) {
                if (!semanticEnabled) return undefined;
                return next(document, token);
            },
        },
    };

    const nextClient = new LanguageClient('yak', 'Yak Language Server', serverOptions, clientOptions);
    client = nextClient;
    try {
        await nextClient.start();
        updateStatus('$(check) Yak LSP', `运行中：${serverPath}（已索引 ${workspaceFiles.length} 个工作区文件）`);
        outputChannel.appendLine('[Yak] 语言服务器就绪。');

        // 监听工作区 .yak 文件变动并增量同步至服务端。
        watcher = vscode.workspace.createFileSystemWatcher('**/*.yak');
        watcher.onDidCreate(uri => { void syncSingleFile(uri, false); });
        watcher.onDidChange(uri => { void syncSingleFile(uri, false); });
        watcher.onDidDelete(uri => { void syncSingleFile(uri, true); });
    } catch (err) {
        updateStatus('$(error) Yak LSP 错误', `启动失败：${err && err.message ? err.message : String(err)}`);
        outputChannel.appendLine(`[Yak] 语言服务器启动失败: ${err && err.stack ? err.stack : String(err)}`);
        await stopLanguageClient();
    }
}

async function activate(context) {
    outputChannel = vscode.window.createOutputChannel('Yak Language Server');
    statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    statusBar.command = 'yak.showOutput';
    context.subscriptions.push(outputChannel, statusBar);

    context.subscriptions.push(
        vscode.commands.registerCommand('yak.restartServer', async () => {
            await startLanguageClient(context);
        }),
        vscode.commands.registerCommand('yak.resyncWorkspace', async () => {
            if (!client || !client.isRunning()) {
                await startLanguageClient(context);
                return;
            }
            const config = vscode.workspace.getConfiguration('yak');
            const files = await collectWorkspaceFiles(config);
            await client.sendNotification('yak/workspaceFiles', { files });
            outputChannel.appendLine(`[Yak] 已重新同步工作区文件数: ${files.length}`);
            updateStatus('$(check) Yak LSP', `运行中（已同步 ${files.length} 个工作区文件）`);
        }),
        vscode.commands.registerCommand('yak.showOutput', () => {
            outputChannel.show(true);
        }),
        vscode.workspace.onDidChangeConfiguration(event => {
            if (
                event.affectsConfiguration('yak.lsp.enabled') ||
                event.affectsConfiguration('yak.lsp.path') ||
                event.affectsConfiguration('yak.semanticHighlighting.enabled') ||
                event.affectsConfiguration('yak.workspace.maxFiles') ||
                event.affectsConfiguration('yak.workspace.exclude')
            ) {
                void startLanguageClient(context);
            }
        })
    );

    await startLanguageClient(context);
}

async function deactivate() {
    await stopLanguageClient();
}

module.exports = {
    activate,
    deactivate,
    // 导出内部辅助函数便于自动化单元测试验证。
    _internal: {
        resolveServerPath,
        buildExcludeGlob,
        scoreWorkspaceUri,
        SERVER_MAX_FILES,
        SERVER_MAX_FILE_BYTES,
    },
};
