'use strict';

// 验证 Yak 扩展清单、语言配置、TextMate 语法规则与宿主辅助逻辑。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');

const extDir = path.resolve(__dirname, '..');

function loadJson(rel) {
    const full = path.join(extDir, rel);
    return JSON.parse(fs.readFileSync(full, 'utf8'));
}

// 递归检查 TextMate 语法中的所有正则表达式可编译。
function collectRegexes(node, out) {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) {
        for (const item of node) collectRegexes(item, out);
        return;
    }
    for (const key of ['match', 'begin', 'end']) {
        if (typeof node[key] === 'string') {
            out.push({ key, pattern: node[key] });
        }
    }
    for (const val of Object.values(node)) {
        if (val && typeof val === 'object') collectRegexes(val, out);
    }
}

function testManifestAndGrammar() {
    const pkg = loadJson('package.json');
    const langCfg = loadJson('language-configuration.json');
    const grammar = loadJson('syntaxes/yak.tmLanguage.json');

    assert.equal(pkg.name, 'yak-lang');
    assert.equal(pkg.publisher, 'yak-lang');
    assert.equal(pkg.contributes.languages[0].id, 'yak');
    assert.deepEqual(pkg.contributes.languages[0].extensions, ['.yak']);
    assert.equal(pkg.contributes.grammars[0].scopeName, 'source.yak');
    assert.equal(langCfg.comments.lineComment, '//');
    assert.deepEqual(langCfg.comments.blockComment, ['/*', '*/']);

    const regexes = [];
    collectRegexes(grammar, regexes);
    assert(regexes.length >= 25, '语法规则数量过少');
    for (const entry of regexes) {
        // TextMate 支持的 \1 反向引用在 JS RegExp 下同样可编译（begin/end 跨规则除外）。
        if (entry.key === 'end' && entry.pattern.includes('\\1')) continue;
        new RegExp(entry.pattern, 'm');
    }

    // 针对关键 Yak 词法形态进行定向正则命中验证。
    const repo = grammar.repository;
    const matchRule = (group, idx, sample) => new RegExp(repo[group].patterns[idx].match).exec(sample);

    // 1. 文档注释与普通行注释
    assert(matchRule('comments', 0, '/// doc'), '应匹配 /// 文档注释');
    assert(matchRule('comments', 1, '// 注释'), '应匹配 // 行注释');
    assert(new RegExp(repo['block-comment'].begin).test('/* outer /* inner */ */'), '应匹配嵌套块注释起始');

    // 2. 转义与非法转义
    assert(matchRule('string-escapes', 0, '\\u{1F600}'), '应匹配 Unicode 标量转义');
    assert(matchRule('string-escapes', 1, '\\n'), '应匹配标准转义');
    assert(matchRule('string-escapes', 2, '\\q'), '应识别非法转义');

    // 3. @ 原语与注解
    assert(matchRule('annotations-and-primitives', 0, '@inline'), '应匹配 @inline 注解');
    for (const prim of ['@move', '@copy', '@clone', '@drop', '@push', '@len', '@wrap_add', '@wrap_sub', '@wrap_mul']) {
        assert(matchRule('annotations-and-primitives', 1, `${prim}(x)`), `应匹配原语 ${prim}`);
    }

    // 4. 声明与零分配 #callable
    const fnDecl = matchRule('declarations', 0, 'function #write(buf: &[u8]): u64');
    assert(fnDecl && fnDecl[1] === 'function' && fnDecl[2] === '#write', '应匹配 #write 零分配函数声明');
    const stDecl = matchRule('declarations', 1, 'struct Point { x: u32 }');
    assert(stDecl && stDecl[1] === 'struct' && stDecl[2] === 'Point', '应匹配结构体声明');
    const impDecl = matchRule('declarations', 3, 'import std::io;');
    assert(impDecl && impDecl[2] === 'std::io', '应匹配导入路径');

    // 5. 能力修饰后缀
    for (const cap of [':Read', ':Write', ':ReadWrite']) {
        const m = matchRule('capability-modifiers', 0, `&T${cap}`);
        assert(m && m[2] === cap.slice(1), `应匹配能力修饰 ${cap}`);
    }

    // 6. 数值字面量与显式后缀
    assert(matchRule('numbers', 0, '0xFFu8'), '应匹配十六进制带后缀');
    assert(matchRule('numbers', 1, '0b1010u16'), '应匹配二进制带后缀');
    assert(matchRule('numbers', 2, '0o755u32'), '应匹配八进制带后缀');
    assert(matchRule('numbers', 3, '42i64'), '应匹配十进制带后缀');

    // 7. 内建类型与路径
    for (const ty of ['u8', 'u32', 'i64', 'bool', 'char', 'void']) {
        assert(matchRule('builtin-types', 0, ty), `应匹配内建类型 ${ty}`);
    }
    assert(matchRule('builtin-types', 1, 'AllocError'), '应匹配 AllocError');
    const qp = matchRule('qualified-paths', 0, 'math::triple(2)');
    assert(qp && qp[1] === 'math' && qp[2] === '::', '应匹配限定路径');

    console.log(`语法与清单校验通过（已检验 ${regexes.length} 条规则）`);
}

function testExtensionHelpers() {
    // 注入最小 vscode 桩模块以在纯 Node 环境下验证路径解析与优先级逻辑。
    const origLoad = Module._load;
    const mockVscode = {
        workspace: { workspaceFolders: [{ uri: { fsPath: path.resolve(extDir, '../..') } }] },
        window: {},
        commands: {},
        StatusBarAlignment: { Right: 2 },
    };
    Module._load = function (request, parent, isMain) {
        if (request === 'vscode') return mockVscode;
        if (request === 'vscode-languageclient/node') return { LanguageClient: class {} };
        return origLoad.apply(this, arguments);
    };
    try {
        const ext = require(path.join(extDir, 'src', 'extension.cjs'));
        const { resolveServerPath, buildExcludeGlob, scoreWorkspaceUri } = ext._internal;

        const fakeConfig = (map) => ({ get: (k, def) => (k in map ? map[k] : def) });
        const found = resolveServerPath({ extensionPath: extDir }, fakeConfig({}));
        assert(found && fs.existsSync(found), `应自动探测到 yak_lsp.exe，实际: ${found}`);

        const glob = buildExcludeGlob(fakeConfig({ 'workspace.exclude': ['**/a/**', '**/b/**'] }));
        assert.equal(glob, '{**/a/**,**/b/**}');

        const activeDir = path.join('I:', 'project', 'Yak', 'examples') + path.sep;
        const sSame = scoreWorkspaceUri({ fsPath: path.join('I:', 'project', 'Yak', 'examples', 'a.yak') }, activeDir.toLowerCase());
        const sOther = scoreWorkspaceUri({ fsPath: path.join('I:', 'project', 'Yak', 'other', 'b.yak') }, activeDir.toLowerCase());
        assert(sSame < sOther, '当前打开目录的 .yak 文件应具有更高索引优先级');

        console.log(`扩展宿主辅助逻辑校验通过（探测到服务端：${found}）`);
    } finally {
        Module._load = origLoad;
    }
}

testManifestAndGrammar();
testExtensionHelpers();
