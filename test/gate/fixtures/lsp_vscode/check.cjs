'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const path = require('node:path');
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

const bad = '//中😀';
const fixed = 'function f(): void {}\n';
const badAgain = '//中😀x';
const eof = column => [{ code: 'E1018', severity: vscode.DiagnosticSeverity.Error,
    source: 'yak', message: 'Yak 词法诊断 E1018', range: [0, column, 0, column] }];

function diagnostics(uri) {
    return vscode.languages.getDiagnostics(uri).map(d => ({
        code: d.code, severity: d.severity, source: d.source, message: d.message,
        range: [d.range.start.line, d.range.start.character, d.range.end.line, d.range.end.character],
    }));
}

function waitFor(event, predicate, label) {
    return new Promise((resolve, reject) => {
        const finish = () => {
            const value = predicate();
            if (!value) return;
            clearTimeout(timer);
            sub.dispose();
            resolve(value);
        };
        const sub = event(finish);
        const timer = setTimeout(() => {
            sub.dispose();
            reject(new Error('等待超时：' + label));
        }, 20000);
        finish();
    });
}

async function replace(editor, text) {
    const doc = editor.document;
    assert.equal(await editor.edit(edit => edit.replace(
        new vscode.Range(doc.positionAt(0), doc.positionAt(doc.getText().length)), text)), true);
    assert.equal(doc.isDirty, true);
    assert.equal(doc.getText(), text);
}

// 扫描工作区中的 .yak 文件，作为宿主工作区索引材料随初始化参数提交给服务端。
async function scanWorkspaceYakFiles(workspaceDir) {
    const entries = await fs.readdir(workspaceDir, { withFileTypes: true });
    const files = [];
    for (const entry of entries) {
        if (entry.isFile() && entry.name.endsWith('.yak')) {
            const full = path.join(workspaceDir, entry.name);
            const text = await fs.readFile(full, 'utf8');
            files.push({ uri: vscode.Uri.file(full).toString(), text });
        }
    }
    return files;
}

exports.run = async function run() {
    const { YAK_VSCODE_SERVER: server, YAK_VSCODE_EVIDENCE: evidence } = process.env;
    assert(server && evidence);
    const workspaceDir = path.join(evidence, 'workspace');
    const uri = vscode.Uri.file(path.join(workspaceDir, 'Yak 中 文.yak'));
    const mathUri = vscode.Uri.file(path.join(workspaceDir, 'math.yak'));
    const workspaceFiles = await scanWorkspaceYakFiles(workspaceDir);
    const trace = [];
    const traceChannel = {
        name: 'Yak 协议记录', append: s => trace.push(s), appendLine: s => trace.push(s + '\n'),
        replace() {}, clear() {}, show() {}, hide() {}, dispose() {},
    };
    const output = vscode.window.createOutputChannel('Yak LSP 验收');
    const publications = [];
    let child;
    let serverExit;
    let serverStderr = '';
    // 直接交给标准客户端使用子进程的 stdio，不解析或复制协议帧。
    const launch = async () => {
        assert.equal(child, undefined, '候选服务不应重启');
        child = spawn(server, [], { stdio: 'pipe', windowsHide: true });
        child.stderr.setEncoding('utf8').on('data', chunk => { serverStderr += chunk; });
        serverExit = new Promise(resolve => {
            child.once('error', error => resolve({ error: error.message }));
            child.once('exit', (code, signal) => resolve({ code, signal }));
        });
        await new Promise((resolve, reject) => {
            child.once('spawn', resolve);
            child.once('error', reject);
        });
        return { reader: child.stdout, writer: child.stdin };
    };
    const client = new LanguageClient('yak', 'Yak', launch, {
        documentSelector: [{ scheme: 'file', language: 'yak' }],
        initializationOptions: { workspaceFiles },
        outputChannel: output, traceOutputChannel: traceChannel,
        middleware: {
            handleDiagnostics(target, entries, next) {
                publications.push({ uri: target.toString(), count: entries.length });
                next(target, entries);
            },
        },
    });
    const report = { editor: vscode.version, server, uri: uri.toString(), publications, status: 'failed' };
    const watched = expected => waitFor(vscode.languages.onDidChangeDiagnostics, () => {
        const actual = diagnostics(uri);
        return JSON.stringify(actual) === JSON.stringify(expected) && actual;
    }, JSON.stringify(expected));
    const received = text => trace.join('').includes(text);
    try {
        await client.start();
        const value = client.initializeResult.capabilities;
        // 校验全部 P4 声明能力（增量同步、位置编码、触发字符、工作区符号、格式化、重命名、Code Action）。
        assert.deepEqual(value.textDocumentSync, { openClose: true, change: 2 });
        assert.equal(value.positionEncoding, 'utf-16');
        assert.equal(value.definitionProvider, true);
        assert.equal(value.hoverProvider, true);
        assert.deepEqual(value.completionProvider, { triggerCharacters: ['.', ':'] });
        assert.deepEqual(value.semanticTokensProvider, {
            legend: { tokenTypes: ['keyword', 'string', 'number', 'operator'], tokenModifiers: [] }, full: true
        });
        assert.equal(value.documentSymbolProvider, true);
        assert.equal(value.foldingRangeProvider, true);
        assert.equal(value.workspaceSymbolProvider, true);
        assert.equal(value.documentFormattingProvider, true);
        assert.deepEqual(value.renameProvider, { prepareProvider: true });
        assert.equal(value.codeActionProvider, true);
        report.capabilities = value;

        // 1. 打开、未保存修复、增量插入与重新报错。
        const [first, doc] = await Promise.all([watched(eof(5)), vscode.workspace.openTextDocument(uri)]);
        const editor = await vscode.window.showTextDocument(doc);
        assert.equal(doc.languageId, 'yak');
        assert.equal(doc.getText(), bad);
        report.open = first;

        // 2. 验证 E1018 诊断的 Quick Fix Code Action。
        const actionsE1018 = await vscode.commands.executeCommand(
            'vscode.executeCodeActionProvider', uri, new vscode.Range(0, 5, 0, 5)
        );
        assert(Array.isArray(actionsE1018) && actionsE1018.some(a => a.title.includes('E1018')), '应返回 E1018 换行修复');

        const [cleared] = await Promise.all([watched([]), replace(editor, fixed)]);
        assert.equal(await fs.readFile(uri.fsPath, 'utf8'), bad);
        report.unsavedFix = { diagnostics: cleared, isDirty: doc.isDirty, diskUnchanged: true };

        // 3. 验证真实增量编辑：在有效文档末尾插字符使其缺换行。
        const [again] = await Promise.all([watched(eof(6)), replace(editor, badAgain)]);
        report.unsavedError = again;

        // 4. 切入完整多特性示例源码，验证定义、悬停、文档符号、工作区符号、安全重命名与格式化。
        const richCode = [
            'struct Point { x: u32, y: u32 }',
            'enum Color { Red, Blue }',
            'function sum(pt: Point): u32 {',
            '    let total: u32 = pt.x + pt.y;',
            '    return total;',
            '}',
            '',
        ].join('\n');
        await Promise.all([watched([]), replace(editor, richCode)]);

        // 同文件定义与悬停
        const defs = await vscode.commands.executeCommand('vscode.executeDefinitionProvider', uri, new vscode.Position(4, 12));
        assert(Array.isArray(defs) && defs.length === 1 && defs[0].range.start.line === 3, '同文件定义跳转应命中 total 声明');
        const hovers = await vscode.commands.executeCommand('vscode.executeHoverProvider', uri, new vscode.Position(4, 12));
        assert(Array.isArray(hovers) && hovers.length >= 1, '悬停应返回类型文本');

        // 文档符号与工作区符号（同时覆盖当前文档 sum 与工作区 math.yak 的 triple）
        const docSyms = await vscode.commands.executeCommand('vscode.executeDocumentSymbolProvider', uri);
        assert(Array.isArray(docSyms) && docSyms.length === 3, '文档符号应含 Point/Color/sum');
        const wsSyms = await vscode.commands.executeCommand('vscode.executeWorkspaceSymbolProvider', 'triple');
        assert(Array.isArray(wsSyms) && wsSyms.some(s => s.name === 'triple' && s.location.uri.toString() === mathUri.toString()),
            '工作区符号应找到 math.yak 的 triple');

        // 安全同文件重命名（total -> acc）及关键字/冲突拒绝
        const prep = await client.sendRequest('textDocument/prepareRename', {
            textDocument: { uri: uri.toString() },
            position: { line: 4, character: 12 },
        });
        assert.equal(prep.placeholder, 'total');
        const renameEdit = await vscode.commands.executeCommand(
            'vscode.executeDocumentRenameProvider', uri, new vscode.Position(4, 12), 'acc'
        );
        const renameTextEdits = renameEdit.get(uri);
        assert(Array.isArray(renameTextEdits) && renameTextEdits.length === 2, '重命名应覆盖声明与使用共 2 处');
        await assert.rejects(
            client.sendRequest('textDocument/rename', {
                textDocument: { uri: uri.toString() },
                position: { line: 4, character: 12 },
                newName: 'return',
            }),
            e => e.code === -32602
        );
        await assert.rejects(
            client.sendRequest('textDocument/rename', {
                textDocument: { uri: uri.toString() },
                position: { line: 4, character: 12 },
                newName: 'pt',
            }),
            e => e.code === -32602
        );

        // 5. 成员补全：`.` 结构体字段与 `::` 枚举变体 + 工作区模块导出 + 跨文件跳转/悬停
        const dotCode = 'struct Point { x: u32, y: u32 }\nfunction f(pt: Point): u32 { return pt.; }\n';
        await replace(editor, dotCode);
        const dotList = await vscode.commands.executeCommand('vscode.executeCompletionItemProvider', uri, new vscode.Position(1, 39), '.');
        const dotLabels = dotList.items.map(i => typeof i.label === 'string' ? i.label : i.label.label);
        assert(dotLabels.includes('x') && dotLabels.includes('y'), '`.` 补全应返回 Point 字段 x/y');

        const modCode = 'import math;\nfunction f(): u32 { return math::triple(2); }\n';
        await replace(editor, modCode);
        const modList = await vscode.commands.executeCommand('vscode.executeCompletionItemProvider', uri, new vscode.Position(1, 33), ':');
        const modLabels = modList.items.map(i => typeof i.label === 'string' ? i.label : i.label.label);
        assert(modLabels.includes('triple'), '`::` 补全应返回工作区模块 math 的导出 triple');
        const xDefs = await vscode.commands.executeCommand('vscode.executeDefinitionProvider', uri, new vscode.Position(1, 35));
        assert(Array.isArray(xDefs) && xDefs.length === 1 && xDefs[0].uri.toString() === mathUri.toString(),
            '跨文件定义应跳转到 math.yak');
        const xHovers = await vscode.commands.executeCommand('vscode.executeHoverProvider', uri, new vscode.Position(1, 35));
        assert(Array.isArray(xHovers) && xHovers.length >= 1, '跨文件悬停应返回 math::triple 签名');

        // 6. 自动导入 Code Action（E4002 命中工作区导出 triple）
        const autoImportCode = 'function f(): u32 { return triple(2); }\n';
        const [e4002Diags] = await Promise.all([
            waitFor(vscode.languages.onDidChangeDiagnostics, () => {
                const cur = diagnostics(uri);
                return cur.some(d => d.code === 'E4002') && cur;
            }, 'E4002'),
            replace(editor, autoImportCode),
        ]);
        assert(e4002Diags.some(d => d.code === 'E4002'));
        const autoActions = await vscode.commands.executeCommand(
            'vscode.executeCodeActionProvider', uri, new vscode.Range(0, 27, 0, 33)
        );
        assert(Array.isArray(autoActions) && autoActions.some(a => a.title.includes('math::triple')),
            '应提供自动导入 math::triple 的 Quick Fix');

        // 7. 文档格式化（VS Code 会把整文档替换拆为最小编辑集，应用后校验最终文本与二次格式化幂等）
        const messyCode = 'function f(): u32 {\nlet x: u32 = 1;  \nreturn x;\n}';
        const expectedFormatted = 'function f(): u32 {\n    let x: u32 = 1;\n    return x;\n}\n';
        await replace(editor, messyCode);
        const fmtEdits = await vscode.commands.executeCommand('vscode.executeFormatDocumentProvider', uri, { tabSize: 4, insertSpaces: true });
        assert(Array.isArray(fmtEdits) && fmtEdits.length >= 1, '格式化应返回非空编辑集');
        const wsEdit = new vscode.WorkspaceEdit();
        wsEdit.set(uri, fmtEdits);
        assert.equal(await vscode.workspace.applyEdit(wsEdit), true, '格式化编辑应成功应用');
        assert.equal(doc.getText(), expectedFormatted, '格式化输出应符合 4 空格缩进与末尾单 LF');
        const fmtAgain = await vscode.commands.executeCommand('vscode.executeFormatDocumentProvider', uri, { tabSize: 4, insertSpaces: true });
        assert(!fmtAgain || fmtAgain.length === 0, '二次格式化应保持幂等');

        report.p4Checks = {
            definition: true, crossFileDefinition: true, hover: true, crossFileHover: true,
            dotCompletion: dotLabels, modCompletion: modLabels,
            docSymbols: docSyms.length, workspaceSymbols: wsSyms.length,
            rename: true, codeActionE1018: true, codeActionAutoImport: true, formatting: true,
        };

        // 8. 切换语言脱离 Yak 文档，校验清空与退出
        const plain = await vscode.languages.setTextDocumentLanguage(doc, 'plaintext');
        assert.equal(plain.languageId, 'plaintext');
        // 用工作区符号请求作为屏障，确认关闭通知已处理完毕。
        const afterCloseSyms = await client.sendRequest('workspace/symbol', { query: 'triple' });
        assert(Array.isArray(afterCloseSyms) && afterCloseSyms.length >= 1);
        assert.equal(await fs.readFile(uri.fsPath, 'utf8'), bad);
        await client.stop();
        report.serverExit = await serverExit;
        assert.deepEqual(report.serverExit, { code: 0, signal: null });
        assert.equal(serverStderr, '');
        assert.equal(diagnostics(uri).length, 0);
        const wire = trace.join('');
        const closeAt = wire.lastIndexOf("Sending notification 'textDocument/didClose'");
        assert(closeAt >= 0);
        assert.match(wire.slice(closeAt), /Received notification 'textDocument\/publishDiagnostics'[\s\S]*?"diagnostics":\s*\[\]/);
        for (const marker of ["Sending request 'initialize ", "Sending notification 'initialized'",
            "Sending notification 'textDocument/didOpen'", "Sending notification 'textDocument/didChange'",
            "Received response 'shutdown ", "Sending notification 'exit'"]) assert(received(marker), marker);
        report.close = { languageAfterDetach: plain.languageId, diagnostics: diagnostics(uri), diskUnchanged: true };
        report.status = 'passed';
    } catch (failure) {
        report.error = failure.stack || String(failure);
        throw failure;
    } finally {
        if (client.needsStop()) await client.stop().catch(() => {});
        if (child && child.exitCode === null && child.signalCode === null) child.kill();
        report.serverStderr = serverStderr;
        output.dispose();
        await fs.writeFile(path.join(evidence, 'trace.log'), trace.join(''), 'utf8');
        await fs.writeFile(path.join(evidence, 'editor.json'), JSON.stringify(report, null, 2) + '\n', 'utf8');
    }
};
