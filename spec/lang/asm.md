# asm

## 元信息

- 名称：asm（内联汇编）
- 级别：full
- 状态：草案
- 依赖：`base.md`、`unsafe.md`、`owner.md`、`foreign.md`、`effect.md`、`../ir/mir.md`、`../target/x86.md`、`../target/register.md`、`../target/select.md`

## 一、范围

1.1 本文规定 full 层内联汇编 `@asm` 的语法形态、操作数方向、寄存器约束、效应标注、与所有权/`#` 契约的交互及目标编码确定性。

1.2 内联汇编在 base 期禁用；仅可在 full 层的 `unsafe` 上下文内使用（AS-1）。

## 二、语法形式

延续 Yak `@`-原语调用风格，不引入新词法关键字：

```text
AsmExpr     ::= '@asm' '(' StringLit { ',' AsmOperand } { ',' AsmOption } ')'
AsmOperand  ::= AsmDir '(' RegSpec ')' Expr
              | 'const' ConstExpr
              | 'sym' QualifiedPath
AsmDir      ::= 'in' | 'out' | 'lateout' | 'inout' | 'inlateout'
AsmOption   ::= 'clobber' '(' RegList ')'
              | 'options' '(' OptItem { ',' OptItem } ')'
OptItem     ::= 'volatile' | 'nomem' | 'readonly' | 'noreturn' | 'preserves_flags' | 'no_alloc'
```

2.1 模板首参必须为编译期常量字符串字面量，使用 `{0}`、`{1}` 或具名占位符引用操作数；`{{` / `}}` 转义字面花括号（AS-2）。

2.2 操作数按源码顺序从左到右求值（`base.md` 6.5）；输入表达式在汇编模板执行前求值完成，输出目标在汇编模板执行后提交。

## 三、操作数与寄存器约束

3.1 **允许的操作数类型**：定宽整数（`u8`–`u64`、`i8`–`i64`）、`bool`、`f32`/`f64`（full 激活后）、`ptr<T>`/`cptr<T>` 与 `&function(P): R`；操作数宽度必须与目标寄存器类匹配（AS-3）。

3.2 **寄存器约束**（由目标规格进一步细化，见 `../target/x86.md`、`../target/register.md`）：
- 通用类约束（如 `reg`、`reg_byte`、`xmm_reg`）交由寄存器分配器确定性分配；
- 显式物理寄存器约束（如 `"rax"`、`"rcx"`）固定绑定至对应硬件寄存器。

3.3 **保留寄存器保护**：栈指针（如 x86_64 `rsp`）与活跃帧指针（如 `rbp`）不得作为可写输出或未恢复 clobber 破坏，否则为拒绝或违反目标 ABI（AS-5）。

3.4 **禁止 `Write` 槽位传入**：遵循 `base.md` 7.12，被调方与调用方均不得把 `&T:Write` 或 `out` 槽位直接传入 `@asm`（AS-3）。

## 四、内存效应、控制流与 `#` 契约

4.1 **默认保守内存效应**：未标注 `nomem` 或 `readonly` 时，`@asm` 视为可读写任意内存并 clobber 所有指针别名信息（与 `foreign.md` 5.3 同构），且不可被优化器消除或跨内存访问重排。

4.2 **易失性**：默认含可见副作用；仅当同时标注 `readonly` / `nomem` 且未标注 `volatile`、输出未被人使用时，优化器（`../target/optimize.md`）才可按纯计算消除。

4.3 **非返回控制流**：标注 `noreturn` 的 `@asm` 具有永不返回终结语义（如停机、上下文切换、系统调用退出），其后继不可达；若 `noreturn` 后存在可达正常路径或带输出操作数，按 AS-5 拒绝。

4.4 **与 `#` 无增契约交互**：编译器无法穿透任意汇编指令验证堆分配行为；在 `function #name` 内使用 `@asm` 时，必须显式在 `options(...)` 中声明 `no_alloc` 承担人工无增证明，否则按 AS-4 拒绝。

4.5 **MIR 与确定性**：`@asm` 在 MIR 中使用 `../ir/mir.md` `0xE0`–`0xFF` 预留号段编码；模板、操作数顺序与寄存器约束确定唯一目标机器码字节序列，禁止依赖外部汇编器的非确定性启发式选择。

## 五、拒绝形态

| 编号 | 条件 |
|:---|:---|
| AS-1 | 在非 `unsafe` 上下文使用 `@asm` |
| AS-2 | `@asm` 模板不是编译期常量字符串，或占位符索引/格式非法 |
| AS-3 | 寄存器约束非法、方向冲突、类型宽度不匹配，或传入 `&T:Write` / `out` 槽位 |
| AS-4 | 在 `#` 无增函数内使用未显式声明 `no_alloc` 选项的 `@asm` |
| AS-5 | 破坏目标保留寄存器约束，或 `noreturn` 与输出操作数/可达后继冲突 |

## 关联

- 不安全块：`unsafe.md`
- 外部接口内存效应：`foreign.md` 5.3
- 效果系统：`effect.md`
- 目标指令集与寄存器：`../target/x86.md`、`../target/register.md`、`../target/select.md`
- MIR 预留号段：`../ir/mir.md` 4.15
