# option

## 元信息

- 名称：option（可空载体）
- 级别：full
- 状态：草案
- 依赖：`../base.md`、`../parse.md`、`../layout.md`、`../owner.md`、`../sugar.md`、`union.md`、`result.md`、`../../proc/error.md`、`../../proc/error.def`

## 定义

- 取值范围：
  - `T?` 是 `Nullable<T>` 可空载体，具有 present（存在，携带 `T`）与 null（缺失，不携带 payload）两个状态。它不是用户 enum，不是普通联合 `T | null`，不声明 `Some` / `None` 或其他用户可见标签。
  - `T` 必须是可存储的非 carrier owning 类型；`void`、视图、函数静态引用、普通联合、ErrorSet 与未实例化类型参数不得作为 `T`。`&T`、`&[T]`、`&T!E`、`&T?`、`&(T!E)?` 等视图类型也不得作为 `T`。未加括号的 `T!E` 不得作为 `T`；仅语法显式写出的 `(T!E)?` 允许其作为外层 nullable payload。
  - `T?` 作为 full 层 owning 值类型，可出现在完整 owning 类型允许的类型位；因此 `T?` 可为字段、数组元素、按值参数、返回或泛型实参，但不得为 `out` 槽位类型或含 `out` 调用的返回形态。其内部状态不改变这些位置的既有所有权或布局限制；直接 owning 的 `(T!E)?` 仍继承 `T!E` 的位置限制，`&(T!E)?` 则只可依一般视图规则出现在函数参数与局部引用绑定位。
  - 普通联合中的 `null` 成员不因此取得可空载体语义；只有写作 `T?` 的类型允许本文件登记的可空操作。
  - `T?` 与 `T!E` 的组合必须显式书写为 `(T?)!E` 或 `(T!E)?`。前者表示 success payload 为 `T?` 的可错载体；后者表示 payload 为 `T!E` 的可空载体。两者不等价，不扁平化为三标签对象。
- 内存布局：
  - `T?` 使用 `layout.md` 第八节的二标签 carrier：tag 0 为 present，payload 为 `T`；tag 1 为 null，无 payload。
  - tag、inactive payload 与 padding 不是源代码可读取、写入、比较、哈希或转换的值。
- 默认值：无。`T?` 没有零值、空字符串、空数组或未初始化存储形式的默认值。

## 字面量

- 形式：
  - `null` 只在预期类型为 `T?` 的位置构造 null。
  - 已知目标为 `T?` 的上下文中，类型恰为 `T` 的表达式构造 present。

```yak
function lookup_port(found: &bool): i64? {
    if !*found {
        return null;
    }
    return 8080i64;
}
```

- 拒绝：
  - `let value = null;`；
  - 将 `null` 作为普通联合、普通值、错误 payload、默认值或未初始化存储；
  - `Some(value)`、`None`、用户写入 carrier tag 或以 `as` 伪造状态；
  - 裸写 `T?!E`、`T!?E`、`T?!` 或 `T!?`。

```yak
enum CacheError {
    Offline,
}

function remote_port(online: &bool): i64!CacheError {
    if !*online {
        return CacheError::Offline;
    }
    return 8080i64;
}

function invalid_propagate(move value: i64?): i64? {
    return value?;
}

function invalid_error_default(online: &bool): i64 {
    let value: i64!CacheError = remote_port(online);
    return value ?? 80i64;
}
```

## 操作

- 允许：
  - `optional ?? fallback` 只接受 `T?`。present 时产生内部 `T` 且不得求值 fallback；null 时惰性求值 fallback，fallback 必须定型为 `T`。
  - `optional?.member` 与 `optional?.method(args)` 只接受 `T?`。null 时不得求值成员访问、调用实参及其副作用，结果为对应的 `U?`；present 时按普通成员规则求值后重包为 `U?`。
- S-9 手动恢复草案（见 `../sugar.md` S-9）：
  - `optional.then(&handler)`：present 时以 `&T` 调用 handler，handler 返回 `U` 时结果为 `U?`，null 原样穿透。
  - `optional.unwrap()`：present 时产生 `T`；null 时进入不正常完成路径——析构当前帧已拥有值，经 `Error` 标记接口或合成文本呈现后非零退出码终止。
  - `T?` 不接受 `.catch()` / `.or()`（OP-3）；`.unwrap()` 接收者非 `T!E`/`T?` 为 RE-12。

```yak
function display_port(found: &bool): i64 {
    let port: i64? = lookup_port(found);
    return port ?? 80i64;
}

struct Port {
    number: i64,
}

function port_number(move port: Port?): i64? {
    return port?.number;
}

enum CacheError {
    Offline,
}

function cached_port(found: &bool, online: &bool): (i64?)!CacheError {
    if !*online {
        return CacheError::Offline;
    }
    var value: i64? = null;
    if *found {
        value = 8080i64;
    }
    return value;
}

function cached_port_or_default(found: &bool, online: &bool): i64!CacheError {
    let value: i64? = cached_port(found, online)?;
    return value ?? 80i64;
}

function remote_port(online: &bool): i64!CacheError {
    if !*online {
        return CacheError::Offline;
    }
    return 8080i64;
}

function queued_port(queued: &bool, online: &bool): (i64!CacheError)? {
    if !*queued {
        return null;
    }
    return remote_port(online);
}

function queued_or_default(queued: &bool, online: &bool): i64!CacheError {
    let pending: (i64!CacheError)? = queued_port(queued, online);
    let resolved: i64!CacheError = pending ?? remote_port(online);
    return resolved;
}
```

- 禁止：
  - 后缀 `optional?`；
  - `T?` 上的可错错误传播；S-9 激活后，`T?` 上的 `.catch()`、`.or()` 也按 OP-3 拒绝；
  - `T?` 上的普通 enum `match`、普通联合 `.on()` / `.else()` 或 ErrorSet 操作；
  - `T!E`、普通联合、指针、字符串、整数、bool 或其他非可空接收者上的 `?.` 与 `??`。`?.` / `??` 的接收者非 `T?` 时，始终优先按 OP-2 拒绝；即使接收者同时是普通联合或可错载体也不改用其类型专属诊断。S-9 的 `.then()` / `.unwrap()` 不属于 OP-2 的范围。

## 转换

- 隐式：只允许已知目标 `T?` 时的 present 注入与 typed `null` 注入。
- 显式：`as` 不得用于 `T?`、carrier tag 或 null 状态；可空与普通联合之间无转换。
- 溢出行为：无。

## 所有权

- 复制 / 移动：`T?` 当且仅当 `T` 为 `Copy` 时为 `Copy`。非 Copy `T?` 移动时只转移 active present payload 的析构责任。
- 借用形态：`&T?` 与 `&[T?]` 遵守一般视图规则；借用 carrier 不得提取、复制或伪造其 inactive payload。
- 析构：present 时恰好析构一次 `T`；null 无 payload 析构。`??`、`.then()`、`.unwrap()`、返回与作用域退出不得双析构或漏析构。`@clone` 不适用于 `T?`，非 Copy carrier 只能移动、返回、恢复或析构。

## 拒绝形态

| 编号 | 条件 | ErrorCode |
|:---|:---|:---:|
| OP-1 | `null` 没有唯一预期 `T?` 类型，或 `T?` 的内部类型非法 | E5813 |
| OP-2 | 在非 `T?` 接收者上使用 `?.` / `??` | E5814 |
| OP-3 | 对 `T?` 使用后缀 `?`、普通 union 分流，或在 S-9 激活后使用 `.catch()` / `.or()` | E5815 |
| OP-4 | 裸组合后缀、状态伪造或以零值 / 未初始化存储表达 null | E5816 |

## 关联

- 类型基座：`../base.md`
- 类型与后缀语法：`../parse.md`
- full 层恢复糖：`../sugar.md`
- 普通联合：`union.md`
- 可错载体：`result.md`
- 对象布局：`../layout.md`
- 所有权与析构：`../owner.md`
- 错误码数据：`../../proc/error.def`
- 错误码规则：`../../proc/error.md`
