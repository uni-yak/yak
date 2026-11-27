import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { tokenizeYak } from "./yak.mjs";

function colored(source) {
    const tokens = tokenizeYak(source);
    assert.equal(tokens.map(({ text }) => text).join(""), source);
    return tokens.filter(({ kind }) => kind !== "plain").map(({ kind, text }) => [kind, text]);
}

test("词表覆盖规格登记的关键字、占位字、固有符号和最长运算符", () => {
    const lex = readFileSync(new URL("../../spec/lang/lex.md", import.meta.url), "utf8");
    const symbols = readFileSync(new URL("../../spec/lang/symbol.def", import.meta.url), "utf8");
    const keywordList = lex.match(/^5\.1 .+?\r?\n\r?\n```text\r?\n([^`]+)```/m)[1].trim().split(/\s+/);
    const reservedList = lex.match(/^5\.2 .+?\r?\n\r?\n```text\r?\n([^`]+)```/m)[1].trim().split(/\s+/);
    for (const word of keywordList) {
        const kind = word === "true" || word === "false" ? "literal" : "keyword";
        assert.deepEqual(colored(word), [[kind, word]]);
        assert.deepEqual(colored(`#${word}`), [["invalid", `#${word}`]]);
    }
    for (const word of reservedList) {
        assert.deepEqual(colored(word), [[word === "null" ? "literal" : "reserved", word]]);
    }
    const kinds = { type_symbols: "type", lang_items: "type", functions: "primitive", annotations: "annotation" };
    for (const match of symbols.matchAll(/^entry (\w+) .* name "([^"]+)"\r?$/gm)) {
        assert.deepEqual(colored(match[2]), [[kinds[match[1]], match[2]]]);
    }
    for (const word of ["..=", "..", "?.", "??", "=>", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>"]) {
        assert.deepEqual(colored(word), [["operator", word]]);
    }
    assert.deepEqual(colored("::"), [["punctuation", "::"]]);
});

test("嵌套注释与跨行原始字符串保留内部记号和原文", () => {
    const comment = '/* α /* " */ let */';
    const raw = 'r##"a\r\n"# // b"##';
    assert.deepEqual(colored(`${comment} ${raw} // 尾注释\r\nreturn`), [
        ["comment", comment], ["string", raw], ["comment", "// 尾注释"], ["keyword", "return"],
    ]);
    assert.deepEqual(colored('r#"未闭合"'), [["invalid", 'r#"未闭合"']]);
    assert.deepEqual(colored("/* 未闭合"), [["invalid", "/* 未闭合"]]);
});

test("识别普通和字节转义并从未闭合行恢复", () => {
    const source = 'b"\\xFF\\u{1f600}" "\\x00\\u{D800}\\u{110000}\\q"\r\n"未闭合\r\nreturn';
    const tokens = colored(source);
    assert.deepEqual(tokens.filter(([kind]) => kind === "escape"), [
        ["escape", "\\xFF"], ["escape", "\\u{1f600}"],
    ]);
    assert.deepEqual(tokens.filter(([kind]) => kind === "invalid"), [
        ["invalid", "\\x00"], ["invalid", "\\u{D800}"], ["invalid", "\\u{110000}"],
        ["invalid", "\\q"], ["invalid", '"未闭合'],
    ]);
    assert.deepEqual(tokens.at(-1), ["keyword", "return"]);
    assert.deepEqual(colored("'汉'"), [["string", "'汉'"]]);
});

test("模板插值可包含嵌套块、字符串和嵌套模板", () => {
    const source = '`{{字面}} { call({ "}" }, `内层{0x2Au32}`) } 尾部`';
    const tokens = colored(source);
    assert.deepEqual(tokens.filter(([kind]) => kind === "interpolation"), [
        ["interpolation", "{"], ["interpolation", "{"], ["interpolation", "}"], ["interpolation", "}"],
    ]);
    assert.ok(tokens.some(([kind, text]) => kind === "number" && text === "0x2Au32"));
    assert.ok(tokens.some(([kind, text]) => kind === "string" && text === '"}"'));
    assert.deepEqual(tokens.filter(([kind]) => kind === "escape"), [["escape", "{{"], ["escape", "}}"]]);
});

test("识别能力后缀、限定名、整数和未登记的原语", () => {
    const source = "function #scan(arg: &u8:ReadWrite) { pkg::item(0b10u8, 0o7, 0x2A, 42i16); @missing(0b102); }";
    const tokens = colored(source);
    for (const pair of [["function", "#scan"], ["capability", "ReadWrite"], ["namespace", "pkg"]]) {
        assert.ok(tokens.some(([kind, text]) => kind === pair[0] && text === pair[1]), pair.join(" "));
    }
    assert.deepEqual(tokens.filter(([kind]) => kind === "number").map(([, text]) => text), ["0b10u8", "0o7", "0x2A", "42i16"]);
    assert.deepEqual(tokens.filter(([kind]) => kind === "invalid").map(([, text]) => text), ["@missing", "0b102"]);
    assert.deepEqual(colored("left<&right\n"), [["operator", "<"], ["operator", "&"]]);
});
