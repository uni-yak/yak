// 词表与 spec/lang/lex.md、spec/lang/symbol.def 对拍。支持 base 与已登记的 full 词法形态。
const keywords = new Set("function let var const if else elseif while break continue return match enum struct true false import export foreign out as".split(" "));
const reserved = new Set("loop unsafe interface impl implements for in is type never null".split(" "));
const literals = new Set(["true", "false", "null", "OutOfMemory"]);
const types = new Set("u8 u16 u32 u64 i8 i16 i32 i64 bool char void AllocError string f32 f64 ptr cptr Copy Clone Drop Error".split(" "));
const primitives = new Set("@move @copy @clone @drop @push @len @size_of @align_of @offset_of @is_null @panic @breakpoint @wrap_add @wrap_sub @wrap_mul".split(" "));
const annotations = new Set(["@inline", "@align"]);
const capabilities = new Set(["Read", "Write", "ReadWrite"]);

const codeToken = /\/\/[^\r\n]*|\/\*|r(#{0,3})"|b?["']|`|[@#]?[A-Za-z_][A-Za-z0-9_]*|[0-9][A-Za-z0-9_]*|\.\.=|\.\.|\?\.|\?\?|::|=>|==|!=|<=|>=|&&|\|\||<<|>>|[+\-*/%<>=!&|^?()[\]{},;:.@#]/g;
const integer = /^(?:0x[0-9A-Fa-f]+|0b[01]+|0o[0-7]+|[0-9]+)(?:[ui](?:8|16|32|64))?$/;
const blockMarker = /\/\*|\*\//g;
const quotedSpecial = /["'\\\r\n]/g;
const quotedEscape = /\\(?:u\{([0-9A-Fa-f]{1,6})\}|x([0-9A-Fa-f]{2})|[nrt0\\'"])/y;
const templateToken = /\\[\\`]|\{\{|\}\}|[^\\`{}]+|[\\`{}]/y;
const callStart = /[ \t\r\n]*\(/y;
const punctuation = /^[()[\]{},;:.]$/;

function blockEnd(source, start) {
    blockMarker.lastIndex = start + 2;
    let depth = 1;
    for (let mark; (mark = blockMarker.exec(source));) {
        depth += mark[0] === "/*" ? 1 : -1;
        if (depth === 0) return blockMarker.lastIndex;
    }
    return -1;
}

function scanQuoted(source, start, opening, emit) {
    const quote = opening.at(-1);
    const byte = opening[0] === "b";
    let segment = start;
    quotedSpecial.lastIndex = start + opening.length;
    for (let match; (match = quotedSpecial.exec(source));) {
        const at = match.index;
        if (match[0] === quote) {
            emit("string", segment, at + 1);
            return at + 1;
        }
        if (match[0] === "\n" || match[0] === "\r") {
            emit("invalid", segment, at);
            return at;
        }
        if (match[0] !== "\\") continue;

        quotedEscape.lastIndex = at;
        const escape = quotedEscape.exec(source);
        let valid = escape !== null;
        if (escape?.[1]) {
            const scalar = Number.parseInt(escape[1], 16);
            valid = !(byte && quote === "'") && scalar <= 0x10ffff && (scalar < 0xd800 || scalar > 0xdfff);
        } else if (escape?.[2]) {
            valid = byte;
        }
        const next = source[at + 1];
        const end = escape ? quotedEscape.lastIndex : at + (next && next !== "\r" && next !== "\n" ? 2 : 1);
        emit("string", segment, at);
        emit(valid ? "escape" : "invalid", at, end);
        segment = end;
        quotedSpecial.lastIndex = end;
    }
    emit("invalid", segment, source.length);
    return source.length;
}

function classify(word, source, end, previous) {
    if (word[0] === "@") {
        if (annotations.has(word)) return "annotation";
        return primitives.has(word) ? "primitive" : "invalid";
    }
    if (word[0] === "#") {
        const name = word.slice(1);
        return !name || name === "_" || keywords.has(name) || reserved.has(name) ? "invalid" : "function";
    }
    if (literals.has(word)) return "literal";
    if (reserved.has(word)) return "reserved";
    if (keywords.has(word)) return "keyword";
    if (types.has(word) || previous === "struct" || previous === "enum") return "type";
    if (previous === ":" && capabilities.has(word)) return "capability";
    if (previous === "import" || previous === "::" || source.startsWith("::", end)) return "namespace";
    callStart.lastIndex = end;
    if (previous === "function" || previous === "foreign" || callStart.test(source)) return "function";
    return "plain";
}

export function tokenizeYak(source) {
    const tokens = [];
    const templates = [];
    let offset = 0;
    let copied = 0;
    let previous = "";
    function emit(kind, start, end) {
        if (end <= start) return;
        if (copied < start) tokens.push({ kind: "plain", text: source.slice(copied, start) });
        tokens.push({ kind, text: source.slice(start, end) });
        copied = end;
    }

    while (offset < source.length) {
        const template = templates.at(-1);
        if (template?.depth === 0) {
            templateToken.lastIndex = offset;
            const [text] = templateToken.exec(source);
            let kind = "string";
            if (text === "`") templates.pop();
            else if (text === "{") {
                template.depth = 1;
                previous = "";
                kind = "interpolation";
            } else if (text === "}" || text === "\\") kind = "invalid";
            else if (text === "{{" || text === "}}" || text.startsWith("\\")) kind = "escape";
            emit(kind, offset, templateToken.lastIndex);
            offset = templateToken.lastIndex;
            continue;
        }

        codeToken.lastIndex = offset;
        const match = codeToken.exec(source);
        if (!match) break;
        const [text, hashes] = match;
        const start = match.index;
        offset = codeToken.lastIndex;
        if (text.startsWith("//")) {
            emit("comment", start, offset);
            continue;
        }
        if (text === "/*") {
            const end = blockEnd(source, start);
            offset = end < 0 ? source.length : end;
            emit(end < 0 ? "invalid" : "comment", start, offset);
            continue;
        }

        let kind;
        if (hashes !== undefined) {
            const close = `"${hashes}`;
            const end = source.indexOf(close, offset);
            offset = end < 0 ? source.length : end + close.length;
            kind = end < 0 ? "invalid" : "string";
        } else if (text.endsWith('"') || text.endsWith("'")) {
            offset = scanQuoted(source, start, text, emit);
            previous = text;
            continue;
        } else if (text === "`") {
            templates.push({ depth: 0 });
            kind = "string";
        } else if (template && text === "}" && --template.depth === 0) {
            kind = "interpolation";
        } else if (/^[0-9]/.test(text)) {
            kind = integer.test(text) ? "number" : "invalid";
        } else if (/^[A-Za-z_@#]/.test(text)) {
            kind = classify(text, source, offset, previous);
        } else {
            if (template && text === "{") template.depth++;
            kind = punctuation.test(text) || text === "::" ? "punctuation" : "operator";
        }
        if (kind !== "plain") emit(kind, start, offset);
        previous = text;
    }
    emit("plain", copied, source.length);
    return tokens;
}

// 源码始终经 DOM 文本节点写入，保留空白与换行。
export function highlightYak(element, source = element.textContent) {
    const doc = element.ownerDocument;
    const fragment = doc.createDocumentFragment();
    for (const { kind, text } of tokenizeYak(source)) {
        if (kind === "plain") {
            fragment.append(doc.createTextNode(text));
        } else {
            const span = doc.createElement("span");
            span.className = `yak-${kind}`;
            span.textContent = text;
            fragment.append(span);
        }
    }
    element.classList.add("yak-code");
    element.replaceChildren(fragment);
}
