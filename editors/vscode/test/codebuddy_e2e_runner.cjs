'use strict';

// 运行在 CodeBuddy CN 扩展宿主内部的端到端验证用例，检验已安装扩展 yak-lang.yak-lang。
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const vscode = require('vscode');

function waitFor(event, predicate, label, timeoutMs = 20000) {
    return new Promise((resolve, reject) => {
        const check = () => {
            const val = predicate();
            if (!val) return;
            clearTimeout(timer);
            sub.dispose();
            resolve(val);
        };
        const sub = event(check);
        const timer = setTimeout(() => {
            sub.dispose();
            reject(new Error(`等待超时：${label}`));
        }, timeoutMs);
        check();
    });
}

async function replaceText(editor, text) {
    const doc = editor.document;
    const ok = await editor.edit(eb => eb.replace(
        new vscode.Range(doc.positionAt(0), doc.positionAt(doc.getText().length)),
        text
    ));
    assert.equal(ok, true);
}

exports.run = async function run() {
    const work = process.env.YAK_CODEBUDDY_E2E_WORK;
    assert(work, '缺少 YAK_CODEBUDDY_E2E_WORK');
    const workspaceDir = path.join(work, 'workspace');
    const mainUri = vscode.Uri.file(path.join(workspaceDir, 'main.yak'));
    const mathUri = vscode.Uri.file(path.join(workspaceDir, 'math.yak'));
    const report = { editor: vscode.version, status: 'failed', checks: {} };

    try {
        // 1. 确认已安装扩展 yak-lang.yak-lang 存在并激活。
        const ext = vscode.extensions.getExtension('yak-lang.yak-lang');
        assert(ext, '未在 CodeBuddy CN 中检测到已安装的扩展 yak-lang.yak-lang');
        const doc = await vscode.workspace.openTextDocument(mainUri);
        const editor = await vscode.window.showTextDocument(doc);
        assert.equal(doc.languageId, 'yak', '打开 .yak 文件后 languageId 应为 yak');
        if (!ext.isActive) await ext.activate();
        report.extensionVersion = ext.packageJSON.version;
        report.checks.languageId = doc.languageId;

        // 2. 确认初始 E1018 诊断出现（证明扩展自动启动了内置 yak_lsp.exe）。
        const e1018 = await waitFor(
            vscode.languages.onDidChangeDiagnostics,
            () => {
                const ds = vscode.languages.getDiagnostics(mainUri);
                return ds.some(d => d.code === 'E1018') && ds;
            },
            '初始 E1018 诊断'
        );
        report.checks.initialE1018 = e1018.length;

        // 3. 验证 E1018 Quick Fix。
        const ca1018 = await vscode.commands.executeCommand(
            'vscode.executeCodeActionProvider', mainUri, new vscode.Range(0, 5, 0, 5)
        );
        assert(Array.isArray(ca1018) && ca1018.some(a => a.title.includes('E1018')), '应返回 E1018 修复');
        report.checks.codeActionE1018 = true;

        // 4. 切入完整多特性代码并确认诊断清空。
        const richCode = [
            'struct Point { x: u32, y: u32 }',
            'function sum(pt: Point): u32 {',
            '    let total: u32 = pt.x + pt.y;',
            '    return total;',
            '}',
            '',
        ].join('\n');
        await Promise.all([
            waitFor(
                vscode.languages.onDidChangeDiagnostics,
                () => vscode.languages.getDiagnostics(mainUri).length === 0,
                '修复后清空诊断'
            ),
            replaceText(editor, richCode),
        ]);

        // 定义跳转、悬停、文档符号、工作区符号、安全重命名
        const defs = await vscode.commands.executeCommand('vscode.executeDefinitionProvider', mainUri, new vscode.Position(3, 12));
        assert(Array.isArray(defs) && defs.length === 1 && defs[0].range.start.line === 2, '同文件定义跳转异常');
        const hovers = await vscode.commands.executeCommand('vscode.executeHoverProvider', mainUri, new vscode.Position(3, 12));
        assert(Array.isArray(hovers) && hovers.length >= 1, '悬停提示异常');
        const docSyms = await vscode.commands.executeCommand('vscode.executeDocumentSymbolProvider', mainUri);
        assert(Array.isArray(docSyms) && docSyms.length === 2, '文档符号异常');
        const wsSyms = await vscode.commands.executeCommand('vscode.executeWorkspaceSymbolProvider', 'triple');
        assert(
            Array.isArray(wsSyms) && wsSyms.some(s => s.name === 'triple' && s.location.uri.toString() === mathUri.toString()),
            '工作区符号应检索到 math.yak::triple'
        );
        const renameEdit = await vscode.commands.executeCommand(
            'vscode.executeDocumentRenameProvider', mainUri, new vscode.Position(3, 12), 'acc'
        );
        assert(renameEdit && renameEdit.get(mainUri).length === 2, '安全重命名应覆盖 2 处');

        // 5. `.` 结构体字段补全
        await replaceText(editor, 'struct Point { x: u32, y: u32 }\nfunction f(pt: Point): u32 { return pt.; }\n');
        const dotList = await vscode.commands.executeCommand(
            'vscode.executeCompletionItemProvider', mainUri, new vscode.Position(1, 39), '.'
        );
        const dotLabels = dotList.items.map(i => (typeof i.label === 'string' ? i.label : i.label.label));
        assert(dotLabels.includes('x') && dotLabels.includes('y'), '`.` 字段补全异常');

        // 6. `::` 跨文件模块导出补全与跨文件跳转
        await replaceText(editor, 'import math;\nfunction f(): u32 { return math::triple(2); }\n');
        const modList = await vscode.commands.executeCommand(
            'vscode.executeCompletionItemProvider', mainUri, new vscode.Position(1, 33), ':'
        );
        const modLabels = modList.items.map(i => (typeof i.label === 'string' ? i.label : i.label.label));
        assert(modLabels.includes('triple'), '`::` 模块导出补全异常');
        const xDefs = await vscode.commands.executeCommand('vscode.executeDefinitionProvider', mainUri, new vscode.Position(1, 35));
        assert(Array.isArray(xDefs) && xDefs.length === 1 && xDefs[0].uri.toString() === mathUri.toString(), '跨文件跳转异常');

        // 7. 格式化与幂等
        await replaceText(editor, 'function f(): u32 {\nlet x: u32 = 1;  \nreturn x;\n}');
        const fmtEdits = await vscode.commands.executeCommand(
            'vscode.executeFormatDocumentProvider', mainUri, { tabSize: 4, insertSpaces: true }
        );
        assert(Array.isArray(fmtEdits) && fmtEdits.length >= 1, '格式化未返回编辑');
        const wsEdit = new vscode.WorkspaceEdit();
        wsEdit.set(mainUri, fmtEdits);
        assert.equal(await vscode.workspace.applyEdit(wsEdit), true);
        assert.equal(doc.getText(), 'function f(): u32 {\n    let x: u32 = 1;\n    return x;\n}\n');

        report.checks = {
            ...report.checks,
            definition: true,
            crossFileDefinition: true,
            hover: true,
            docSymbols: docSyms.length,
            workspaceSymbols: wsSyms.length,
            rename: true,
            dotCompletion: dotLabels,
            modCompletion: modLabels,
            formatting: true,
        };
        report.status = 'passed';
    } catch (err) {
        report.error = err && err.stack ? err.stack : String(err);
        throw err;
    } finally {
        await fs.writeFile(path.join(work, 'report.json'), JSON.stringify(report, null, 2) + '\n', 'utf8');
    }
};
