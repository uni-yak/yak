# ref

## 元信息

- 名称：ref（`&T` 引用视图）
- 级别：base
- 状态：草案
- 依赖：`../base.md`、`../parse.md`、`../layout.md`、`../owner.md`、`../symbol.md`、`slice.md`

## 定义

- 取值范围：单元素借用视图，8 字节地址值，非空（`layout.md` 四、4.3）。
- 不拥有目标；不触发析构；复制只复制地址，不转移或复制目标 owning 值。
- 能力三态（上下文关键字，`base.md` 3.5、7.2）：
  - `&T:Read`（默认，可并存多个）
  - `&T:ReadWrite`（独占，活跃期原 place 与其他引用不可访问，`owner.md` 3.4）
  - `&T:Write` 仅允许出现在普通（非 `foreign`）函数形参的类型位置，作为 `out` 槽位的调用通道：实参侧必须以 `out name` 槽位传入（`base.md` 5.x、7.12）。`Write` 能力只由 `out` 通道产生（`base.md` 7.2），不作普通引用能力使用（`owner.md` 四）。
- 默认值：无；引用不可为空。full 可借用可空 owning 值 `T?`，其借用形态为 `&T?`；`T?` 的 payload 类型范围见 [可空载体](option.md)。

## 字面量

- 形式：无字面量。`&x` 默认建立 `Read`，也可显式写 `&x:Read`。`&x:ReadWrite` 只在绑定和活跃借用允许时建立独占借用（`../base.md` 7.1–7.4）。
- 拒绝：对 `moved` / `dropped` place 取引用；取引用表达式书写 `&x:Write`；`&T:Write` 书写在普通函数形参以外的类型位置（局部绑定、`const`、`foreign` 形参、返回值）。

## 操作

- 允许：显式解引用 `*r`（base 无多级自动解引用）。
- 允许：字段 / 索引位置自动解引用一层：`r.f`、`r[i]`（`base.md` 7.14；方法接收者自动解引用属 full）。
- 允许：重借用 `&*r` / `&*r:ReadWrite`（按保守规则）。
- 禁止：算术、比较序；`==` / `!=` 比较地址（base 不提供）。
- 禁止：以引用表达环或自引用；一律改用 `u32` 句柄 + 数组（`base.md` 7.8）。

## 转换

- 隐式：`ReadWrite → Read` 收窄合法（`owner.md` 3.6）；反向拒绝。
- 显式 `as`：无
- 溢出行为：不适用

## 所有权

- 复制 / 移动：视图为 Copy 值表示；`@move` / `@drop` 不适用。
- 借用形态：`&T` 自身即视图；不得作 struct 字段、enum payload、数组元素、泛型实参或函数返回（`base.md` 4.4）。
- 析构：无。

## 拒绝形态

| 编号 | 条件 | 码 |
|:---|:---|:---|
| — | `&T` 出现在字段 / payload / 元素 / 泛型实参 / 返回位（`base.md` 4.4） | — |
| OW-3 | 引用逃逸宿主区域（含返回局部借用） | E6005 |
| — | 能力升级（`Read → ReadWrite`） | — |
| — | `ReadWrite` 活跃时访问重叠 place（OW-2） | — |
| R-13（`base.md`） | 取引用表达式书写 `&x:Write`；`let` / `var` 局部绑定或 `const` 声明 `&T:Write`（非 `out` 通道建立 `Write`） | E6101 |
| F-2（`foreign.md`） | `foreign` 函数形参声明 `&T:Write` | E9201 |
| P-9（`parse.md`） | 返回值位置书写 `&T:Write` 视图 | E2009 |
| — | `Write` 通道误用：读取、作普通实参、赋值或重复提交 | E6102 |

## 关联

- 布局：`../layout.md` 四
- 所有权与能力：`../owner.md` 三
- 切片：`slice.md`
- `out` 槽位与 `Write`：`../owner.md` 四
