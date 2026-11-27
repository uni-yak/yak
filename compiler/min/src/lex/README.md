# compiler/min/src/lex

本目录提供可由 Seed 解释和由 min 编译的词法组件。词法行为以 [lex](../../../../spec/lang/lex.md) 为准。

## 已有文件

- `lex.yak`：编码/换行预检、扫描、NameTable、字面量静态池和结构化错误。
- `lextables.yak`：由 `tools/symgen/lex_tables.py` 从 `symbol.def` 与 `lex.md` 生成的只读分派表；禁止手改。

`lex_scan(src, file)` 返回 `LexResult!AllocError`。结果包含 token、names、statics、static_bytes 与 diagnostics。调用方先检查 diagnostics；有词法错误时 token 流为空，不提供 EOF。内存不足经 AllocError 传播。

TokenKind、KeywordId、OpId、整数后缀和静态池索引的唯一编号合同见 `spec/lang/lex.md` 4.5–4.8。字符串记录保存偏移和长度，可区分空串、内嵌 NUL、同长不同内容。NameId 从一开始；关键字、布尔、通配及 @ 项不进入名称表，HashName 与同名普通标识符共享 NameId。

全源编码通过预检后，普通字符串按原始 UTF-8 字节提交；转义先在临时缓冲解码，闭合后把末段直接接入静态池。字符字面量只保留标量，不分配静态载荷。解析器仍接收完整静态池。

## 扩展字面量

`lex_scan_literals(src, file)` 显式启用字节、字节串、原始串和模板。组件输出的 token kind 依次为 11、12、13、14。字节的 `payload` 是 `u8` 值，字节串和原始串的 `payload` 是静态池索引，模板的 `payload` 是 `templates` 索引。每个模板记录在 `template_pieces` 中的连续区间，文本片段指向静态池，插值片段记录原文件中不含外层花括号的字节范围。失败时清空 token、静态池和模板记录。

`lex_scan_literal_fragment(src, file, start, end)` 可重新扫描插值，`[start, end)` 取原文件物理字节偏移，无文件尾换行要求。记号、诊断和嵌套模板片段的位置仍相对原文件。默认编译、语言服务和带预算的入口使用 base 规则，这些前缀按 `E3008` 拒绝。扩展字面量的解析与脱糖由后续阶段接入。

`lex_scan_closed_ranges(src, file)` 仅扩展闭区间语法，将 `..=` 输出为运算符 34，位置长度为三个源字节。解析器把它降为使用检查型加法的半开切片。默认 base 入口继续返回 `E3008`。

`lex_scan_nullable(src, file)` 为可空前端输出 `null` 记号 15、`?.` 运算符 35 及 `??` 运算符 36。两个双字节运算符均按最长匹配扫描。默认 base 入口对 `null` 返回 `E1008`，对 `?.`、`??` 返回 `E3008`。

## 验证

`seed/test/t181_min_lex.yak` 与 `t216`–`t222` 覆盖基础集成、静态字节、Unicode 标量/转义、NameId 和固有编号、整数进制/幅值/后缀、错误码与字节位置、嵌套注释、全部 base 运算符，以及读取并扫描词法器自身源码。

`seed/test/t427_min_lex_literal_forms.yak` 覆盖 `E1012`–`E1015` 的唯一诊断及失败清空、字节载荷、界定符长短、嵌套插值与原文件偏移。

开发检查：

```text
python tools/audit_spec.py
python tools/symgen/lex_tables.py --check
python tools/test_contracts.py
```

Yak 用例随 `seed/build.sh` 进入双编译器门禁，也可由 `seed/test/run_tests.ps1` 独立执行。

## 后续边界

非 ASCII 标识符的字符分类尚待主管规格封闭；当前组件明确拒绝。需要类型或语法上下文的有符号正幅值、L-9 与 L-10 由后续 parse/check 判定。
