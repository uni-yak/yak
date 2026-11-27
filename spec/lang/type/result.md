# result

## 元信息

- 名称：result（可错完成载体与错误集）
- 级别：base / full（base 为 `T!E`、ErrorSet 与 `?`；full 追加已登记的映射与恢复）
- 状态：草案
- 依赖：`../base.md`、`../parse.md`、`../layout.md`、`../owner.md`、`../symbol.md`、`../sugar.md`、`enum.md`、`option.md`、`union.md`、`../../proc/error.md`、`../../proc/error.def`

## 记号

- `T` 表示可错载体的成功 payload 类型；`U` 表示映射后的另一成功类型；`E` / `F` 表示单个 enum 错误类型或规范 ErrorSet。
- `T!E` 是唯一的可错载体表面记法；不存在名为 `Result` 的用户类型，也不提供 `Ok` / `Err` 构造器。
- 解析、名字解析、类型检查、所有权、MIR 与 ABI 使用 compiler-synthetic（编译器合成）、无名称的 `Fallible<T, ErrorSet<E...>>` 内部类型节点；它不是用户路径、BuiltinId、普通联合或可书写泛型类型。

## 定义

- 取值范围：
  - `T!E` 是完成状态 carrier（载体），不是用户 enum、不是普通联合 `T | E`、不是 ErrorSet，也不声明用户可见成功 / 错误标签。`T` 必须为可置于函数返回位的非 carrier、非普通联合 owning 值类型或 `void`；唯一 carrier 例外是显式 `(T?)!E` 的 success payload `T?`。分组括号不改变该限制。普通 `&T` / `&[T]` 不能借此绕过返回位限制。full 泛型声明中 `T` 可出现类型参数，但进入具体布局、MIR、YSM 或 ABI 前必须实例化；`E` 在泛型声明期也必须是名义 enum，不得以类型参数或类型别名作为 `E`。
  - `E` 必须为单个已实例化的名义 enum，或本节规定的规范 ErrorSet。`E` 不得是类型参数或类型别名；裸 `T!` 不存在，调用方必须写出错误类型。
  - ErrorSet 只允许出现在 `T!(E1 | E2 | ...)` 的错误位。它不是独立 `ValueType`、字段类型、数组元素、泛型实参、参数类型或可直接构造的表达式类型。
  - 直接 owning 的 `T!E` 只允许出现在函数返回、函数静态引用返回与局部 `let` / `var` carrier 绑定类型位。不得作为按值参数、`const`、`out`、struct 字段、enum payload、数组元素、普通联合成员或泛型实参。`&T!E` 仅可依一般视图规则出现在直接函数参数、函数静态引用的参数列表与局部引用绑定位；它不放宽直接 owning `T!E` 的位置限制。`&[T!E]` 仍因 carrier 位于切片元素位而拒绝。out 位置优先报 RE-6，其余非法直接 owning 位置报 RE-8。
  - 直接 owning 的 `(T!E)?` 是以 `T!E` 为 payload 的显式外层可空载体，且仍继承内部 `T!E` 的位置限制；`&(T!E)?` 仅可依一般视图规则出现在直接函数参数、函数静态引用的参数列表与局部引用绑定位。`&[(T!E)?]` 仍因内层 carrier 位于切片元素位而拒绝。`(T?)!E` 的 success payload 为 `T?`，外层 error 仅由 `E` 表示。两种组合不等价，且不得扁平化。
  - 每个 ErrorSet 操作数必须解析为已实例化的名义 enum（不得为类型参数或类型别名）：固有 enum 保存 `BuiltinId`，本地 enum 保存 `DefId`，导入 enum 保存 `ImportRef=(DependencyId, ExportId)`。名称、`NameId` 与 `ScopeId` 不得进入 ErrorSet、类型检查或 MIR。
  - ErrorSet 的规范身份 key 是无 hash、前缀无歧义的字节序列，在 enum 声明登记或 `.iface` 载入时构造并缓存。enum 根使用 `0x01 | BuiltinId:u16`（固有）或 `0x02 | module_len:u16 | module_bytes | name_len:u16 | name_bytes | arg_count:u16 | type_args...`（用户）；模块路径取 enum 的声明模块，不取 import 别名。type arg key 递归编码为：`0x10 | BuiltinId:u16 | arg_count:u16 | args...`（固有类型）、`0x11 | kind:u8 | module_len:u16 | module_bytes | name_len:u16 | name_bytes | arg_count:u16 | args...`（用户 enum / struct；`kind=0` 为 enum、`kind=1` 为 struct）、`0x12 | index:u16`（类型参数）、`0x13 | len:u64 | element`（定长数组）、`0x14 | element`（动态数组）、`0x15 | param_count:u16 | params... | result`（函数静态引用）、`0x16 | element`（Nullable）、`0x17 | member_count:u32 | members...`（PlainUnion，成员按完整 key 严格升序）。长度、数量与整数均 little-endian。
  - ErrorSet 操作数按规范身份 key 的字节序排序并去重。一个成员时 ErrorSet 等同该 enum 类型；两个及以上成员保持 ErrorSet。成员数必须在 `1`–`65536`，超过上限为 RE-7。
  - 不同规范 enum 身份的运行时成员必须互斥。该互斥性是本文“静态断言”一节的 RE-2，不是源码级拒绝形态。`T` 与 ErrorSet 任一成员也必须不重叠，违反时拒绝为 RE-3。
- 内存布局：
  - `T!E` 使用 `layout.md` 第八节的二标签 carrier：tag 0 为 success，payload 为 `T`；tag 1 为 error，payload 为 `E`。`void!E` 的 success payload 大小为 0、对齐为 1。
  - 单成员 ErrorSet 直接使用该 enum 的对象布局。多成员 ErrorSet 是内联 tagged union：tag `i` 选择规范成员序第 `i` 个 enum，payload 为该 enum 的完整对象。
  - ErrorSet 外层 tag、`T!E` 的 tag、inactive payload 与 padding 均不是源代码可读取、转换或构造的值。
- 默认值：无。`T!E`、ErrorSet 与其任一 enum 成员均无隐式默认值、零值或空值。

## 字面量

- 形式：无独立字面量、`Ok` / `Err` 构造器或 ErrorSet 标签。
  - 已知目标为 `T!E` 时，类型恰为 `T` 的表达式构造 success；类型为 ErrorSet 任一成员 enum 的表达式构造 error。
  - 多成员 ErrorSet 的 error 构造自动写入该成员的规范序 tag。
  - `return;` 只构造 `void!E` 的 success；其余返回位不得省略表达式。

```yak
enum IoError {
    Unavailable,
}

function open_port(ready: &bool): i64!IoError {
    if !*ready {
        return IoError::Unavailable;
    }
    return 8080i64;
}
```

- 拒绝：
  - `T!`、`Ok(value)`、`Err(value)`、手写 ErrorSet tag、手写 carrier tag；
  - 以整数、`as`、零值、未初始化存储或普通联合成员顺序伪造状态；
  - `T` 与错误成员重叠；
  - 裸组合后缀 `T?!E`、`T!?E`、`T?!`、`T!?`。

```yak
enum OverlapError {
    Broken,
}

function invalid_overlap(ready: &bool): OverlapError!OverlapError {
    if !*ready {
        return OverlapError::Broken;
    }
    return OverlapError::Broken;
}
```

## 操作

- base：
  - 后缀 `value?` 只接受 `T!E_src`。success 时产生 `T` 并继续当前求值；`void!E_src` 的 success 只继续，不产生可绑定值。error 时取得完整活动 `E_src` 并提前返回。
  - `?` 所在函数的返回类型必须为 `U!E_dst`，且 `members(E_src) ⊆ members(E_dst)`；成立时按 `E_dst` 的规范成员序重封装 error 后返回。非 carrier 返回函数、普通联合、`T?` 与普通值上的后缀 `?` 均拒绝。
  - 含 `out` 实参的 carrier 调用遵守 `base.md` 7.12：success 使关联槽位变满，error 使关联槽位回空。base 不允许保存此调用后再判定。

```yak
enum ParseError {
    Invalid,
}

function read_config(ready: &bool): i64!IoError {
    return open_port(ready);
}

function parse_config(valid: &bool): i64!ParseError {
    if !*valid {
        return ParseError::Invalid;
    }
    return 8080i64;
}

function load_config(ready: &bool, valid: &bool): i64!(IoError | ParseError) {
    let raw: i64 = read_config(ready)?;
    let port: i64 = parse_config(valid)?;
    return raw + port;
}
```

- full 草案（见 `../sugar.md` S-9）：
  - `value.then(&handler)` 是 success 映射糖。handler 以 `&T` 接收 success payload；handler 返回 `U` 时结果为 `U!E`，返回 `U!F` 时结果为 `U!(E | F)`。error 原样穿透。
  - `value.catch(&handler)` 是单 enum 错误恢复糖：handler 以 `&E` 接收活动 error 并返回 `T`；结果为 `T`。多成员 ErrorSet 用 handler 表 `value.catch(Ei => &hi, ...)` 按成员恢复：命中 `Ei` 调用 `&hi` 返回 `T`；未命中成员穿透，结果类型为 `T!(remaining)`；全覆盖时结果为 `T`。表成员须属于 `members(E)`（RE-10）、不得重复（RE-11）。
  - `value.or(fallback)` 是恢复糖。它只接受 `T!E`，error 时惰性求值 `T` 类型 fallback，并明确丢弃 error payload；结果为 `T`。
  - `value.unwrap()`：success 时产生 `T`；error 时进入不正常完成路径——析构当前帧已拥有值，经 `Error` 标记接口（S-15 机制，声明 `present: &self -> &[u8]`，enum 可选实现）或合成 `<Enum>::<Variant>` 文本呈现活动 error，非零退出码终止。接收者非 `T!E`/`T?` 为 RE-12。
  - 后缀 `value!` 永不属于 carrier 解包语法。
  - `T!E` 不接受 `?.`、`??`、普通 enum `match`、普通联合 `.on()` / `.else()` 或 raw tag 访问。

```yak
function port_text(port: &i64): i64 {
    return *port;
}

function default_port(error: &IoError): i64 {
    if *error == IoError::Unavailable {
        return 80i64;
    }
    return 0i64;
}

function open_text(ready: &bool): i64!IoError {
    return open_port(ready).then(&port_text);
}

function open_or_default(ready: &bool): i64 {
    return open_port(ready).catch(&default_port);
}

function open_or_zero(ready: &bool): i64 {
    return open_port(ready).or(0i64);
}

function flush(ready: &bool): void!IoError {
    if !*ready {
        return IoError::Unavailable;
    }
    return;
}

function sync(ready: &bool): void!IoError {
    flush(ready)?;
    return;
}
```

## 转换

- 隐式：只允许已知目标 `T!E` 时的 success / error 上下文注入，以及 `?` 的规范 error 重封装。
- 显式：`as` 不得用于 `T!E`、ErrorSet、carrier tag 或 ErrorSet tag。普通联合、可空载体与可错载体之间无转换。
- 溢出行为：无。

## 所有权

- 复制 / 移动：ErrorSet 为 `Copy` 当且仅当全部规范成员 enum 均为 `Copy`；`T!E` 为 `Copy` 当且仅当 `T` 与 `E` 均为 `Copy`。
- 借用形态：`&T!E` 只遵守一般视图规则；借用不提供成功 / 错误 payload 的直接提取，不允许以借用绕过 carrier 分派。
- 析构：非 Copy `T!E` 与多成员 ErrorSet 移动时转移 active payload 的唯一析构责任；禁止部分移动 inactive payload。作用域退出、`?`、返回和 full 恢复操作只析构 active branch 一次。
- `@copy` 只复制 active branch 的语义值；不得复制 padding、inactive payload 或 raw tag。`@clone` 不适用于 `T!E`。

## 拒绝形态

| 编号 | 条件 | ErrorCode |
|:---|:---|:---:|
| RE-1 | ErrorSet 操作数不是 enum 类型 | E5807 |
| RE-3 | `T` 与 `E` 的运行时成员相交 | E5802 |
| RE-4 | 普通非 carrier 值使用 `?`、`T!E` 所在函数不返回 `U!E_dst`，或 `members(E_src) ⊄ members(E_dst)`；`T?` 与普通联合分别按 OP-3 与 UN-3 拒绝 | E6007 |
| RE-5 | 未登记的 carrier 手动恢复、ErrorSet 分派或 carrier 匹配 | E3008 |
| RE-6 | 含 `out` 的 carrier 调用保存后再判定 | E6105 |
| RE-7 | ErrorSet 成员数超过 65536 | E5503 |
| RE-8 | `T!E` 出现在非返回或局部 carrier 绑定位置 | E5811 |
| RE-9 | 裸组合 carrier 后缀，或把 carrier 伪装为普通联合 | E5812 |

## 静态断言

下列条目在 base 下没有可书写的触发输入，不是源码级拒绝形态：不要求拒绝语料夹具，实现也不得为其发码。已登记的码位按 `../../proc/error.md` 2.5 保留。每条断言由“保证方式”列出的规则维持。

| 编号 | 断言 | 保证方式 |
|:---|:---|:---|
| RE-2 | ErrorSet 展开后的运行时成员互斥 | ErrorSet 操作数按规范身份 key 排序去重，不同身份的运行时成员不重叠；别名与泛型实例化属 full 层，激活时由其自身规格规定源码级拒绝 |

## full 层未激活形态

下列条目只有在 full 层的 `T!E` 手动恢复糖（`../sugar.md` S-9）激活后才有可书写的触发输入。base 期 `.catch` 与 `.unwrap` 由 `../base.md` R-24 以 E3008 拒绝；下表已登记的码位按 `../../proc/error.md` 2.5 保留。

| 编号 | 条件 | ErrorCode |
|:---|:---|:---:|
| RE-10 | `.catch` handler 表的 `EnumPath` 不是 `members(E)` 的成员 | E5821 |
| RE-11 | `.catch` handler 表的 `EnumPath` 重复 | E5822 |
| RE-12 | `.unwrap()` 接收者非 `T!E` 或 `T?` | E5823 |

## 关联

- 类型基座：`../base.md`
- 类型、后缀与调用语法：`../parse.md`
- full 层恢复糖：`../sugar.md`
- 可空载体：`option.md`
- 普通联合：`union.md`
- enum 成员：`enum.md`
- 对象布局：`../layout.md`
- 所有权与析构：`../owner.md`
- 符号与 `.iface`：`../symbol.md`
- 错误码数据：`../../proc/error.def`
- 错误码规则：`../../proc/error.md`
