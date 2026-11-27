# union

## 元信息

- 名称：union（普通联合）
- 级别：full
- 状态：草案
- 依赖：`../base.md`、`../parse.md`、`../layout.md`、`../owner.md`、`../symbol.md`、`result.md`、`option.md`、`../../proc/error.md`、`../../proc/error.def`

## 定义

- 取值范围：
  - `A | B | ...` 是普通联合，表示活动值属于一个成员类型。它没有 success（成功）、error（错误）、present（存在）或 null（缺失）极性。
  - 普通联合不是 ErrorSet。ErrorSet 只出现在 `T!(E1 | E2 | ...)` 的错误位，其成员、位置与转换规则只由 `result.md` 定义。
  - 普通联合不是 `T?` 或 `T!E` 的源级别别名。三者可复用 tagged payload（带标记载荷）布局与后端发射路径，但必须保留不同的语义类型身份。
  - 成员必须是可存储的非 carrier owning 类型，且在别名展开、泛型实例化与当前已登记类型规范化后两两不重叠。`void`、视图（含 `&T`、`&[T]`、`&T?`、`&T!E`、`&(T!E)?`）、函数静态引用、`T?`、`T!E`、ErrorSet 与未实例化类型参数不得成为成员；分组括号不改变该限制。
  - 成员规范身份是已解析成员的自描述 TypeSig（类型签名）字节序列；其编码由 `../symbol.md` 10.8 规定。成员按该字节序列的字典序排序并去重；源码书写顺序、import 别名、哈希遍历顺序与地址不得影响类型等价、tag 分配或 ABI。诊断可以保留源码顺序。
- 内存布局：
  - 普通联合使用 `layout.md` 第七节的一般 tagged union 算法。规范成员序决定逻辑 tag；tag 与 active payload 由编译器管理，不可由源代码读取、写入或转换。
  - inactive payload 与 padding 不是语义数据。
- 默认值：无。普通联合不因首成员、零值或任何成员默认值而自动构造。

## 字面量

- 形式：无独立联合字面量或用户标签。预期类型已知为 `A | B | ...` 时，定型为某唯一成员的表达式构造该成员状态。

```yak
function classify(flag: &bool): i64 | bool {
    if *flag {
        return 7i64;
    }
    return false;
}
```

- 拒绝：
  - 成员重叠、重复成员、未规范化成员或以整数 / `as` 构造 tag；
  - `Ok` / `Err` / `Some` / `None` 构造器；
  - 将普通联合误作 `T!E`、`T?`、ErrorSet 或 enum。

```yak
function invalid_propagate(move value: i64 | bool): i64 {
    return value?;
}

function invalid_coalesce(move value: i64 | bool): i64 {
    return value ?? 0i64;
}
```

## 操作

- 允许：
  - full 层 `value is Type` 检查活动成员并在受支配的成功分支内收窄为该成员类型。
  - full 层 `.on(Type, handler)` 与 `.else(handler)` 可作为普通联合的显式分流糖；它们的处理器、返回收敛与所有权规则必须在 `sugar.md` 登记后才接受。

```yak
function describe(move value: i64 | bool): i64 {
    if value is i64 {
        return value;
    }
    if value is bool {
        if value {
            return 1i64;
        }
        return 0i64;
    }
    return 0i64;
}
```

- 禁止：
  - 后缀 `?`、`?.`、`??`、`.then()`、`.catch()`、`.or()`、`.unwrap()`；其中普通联合上的后缀 `?` 按 UN-3 拒绝，`?.` 与 `??` 因接收者非 `T?` 按 `option.md` OP-2 拒绝；S-9 已激活，普通联合上的 `.then()`/`.catch()`/`.or()`/`.unwrap()` 因接收者非 `T!E`/`T?` 按 UN-3 拒绝（不再先经 E3008）；
  - 将成员位序解释为好值、坏值、存在或缺失；
  - 普通 enum `match` 直接作用于普通联合，除非未来独立的 union pattern 规格冻结。

## 转换

- 隐式：只允许已知目标类型中的唯一成员注入；联合之间无隐式宽化、缩窄或成员重排转换。
- 显式：`as` 不得用于普通联合、tag 或 inactive payload。
- 溢出行为：无。

## 所有权

- 复制 / 移动：普通联合当且仅当全部成员为 `Copy` 时为 `Copy`。非 Copy 联合移动时只转移 active payload 的析构责任。
- 借用形态：`&Union` 与 `&[Union]` 遵守一般视图规则；借用不暴露 tag 或 inactive payload。
- 析构：作用域退出、覆盖、显式 `@drop` 与分流操作只析构 active payload 一次。`@clone` 不适用于普通联合，非 Copy 联合只能移动、返回、分流或析构。

## 拒绝形态

| 编号 | 条件 | ErrorCode |
|:---|:---|:---:|
| UN-1 | 成员不是可存储 owning 类型，或成员在规范化后重叠 | E5817 |
| UN-2 | 以 tag、零值、未初始化存储或 `as` 构造 / 读取联合状态 | E5818 |
| UN-3 | 在普通联合上使用后缀 `?`、普通 union 分流或 S-9 激活后的 carrier 专用操作，或在非普通联合 / 非成员目标上使用 `is` | E5819 |
| UN-4 | 未冻结的 union pattern、`.on()` 或 `.else()` 形态 | E5820 |

## 关联

- 类型基座：`../base.md`
- 类型语法与 `is`：`../parse.md`
- full 层分流糖：`../sugar.md`
- 可空载体：`option.md`
- 可错载体与 ErrorSet：`result.md`
- 对象布局：`../layout.md`
- 所有权与析构：`../owner.md`
- 错误码数据：`../../proc/error.def`
- 错误码规则：`../../proc/error.md`
