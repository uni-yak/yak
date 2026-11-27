# string

## 元信息

- 名称：string（拥有型 UTF-8 值）与 `&string`（借用的 UTF-8 视图）
- 级别：full
- 状态：草案-可实施
- 依赖：`array.md`、`slice.md`、`../owner.md`、`../sugar.md`

## 定义

- `string` 拥有始终为合法 UTF-8 的字节缓冲区。它是名义类型，存储布局沿用 `u8[]` 的数组头。
- `&string` 是只读 UTF-8 视图，携带有效的借用生命周期，布局沿用 `&[u8]`。视图两端须落在 UTF-8 码点边界。`&[u8]` 可表示任意字节序列。
- base 字符串字面量的类型仍为指向静态存储的 `&[u8]`。full 中，当唯一预期类型为 `&string` 时，词法已验证的字符串字面量可构造同一静态存储上的 UTF-8 视图。

## 转换

- `&value` 在 `value: string` 上建立只读 `&string`，沿用现有借用规则。
- `string` 或 `&string` 到 `&[u8]` 的显式转换只借用原字节，不分配、不延长源的生命周期。任意字节输入构造 UTF-8 值或视图之前须通过 UTF-8 验证；失败按受检构造的错误路径报告。
- `string` 与 `u8[]` 保持不同类型身份。字符边界不明确的原始字节子切片保留 `&[u8]` 类型。

## 所有权

- `string` 为非 Copy 的拥有值，按普通 owning 规则移动、显式克隆和析构。析构释放缓冲区，克隆可因分配失败而失败。
- `&string` 可复制视图描述符，借用不转移所有权。它遵守 `base.md` 的视图位置与生命周期规则。

## 拒绝形态

| 编号 | 条件 | ErrorCode |
|:---|:---|:---|
| STR-1 | 把 `&string` 当作拥有型值执行 `@move` / `@drop` / `@clone` | E6204 |

## 用例

- `seed/test/t06_string_output.yak`：字符串字面量（视图）输出
- `seed/test/t28_string_escapes.yak`：字符串转义与 UTF-8 字节视图

## 关联

- 基座字符串字面量：`../base.md` 3.7
- 切片视图：`slice.md`
- 错误码数据：`../../proc/error.def`
