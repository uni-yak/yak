# struct

## 元信息

- 名称：struct（结构体）
- 级别：base / full（base 为非泛型 struct；full 追加泛型实例与 `@align`）
- 状态：草案
- 依赖：`../base.md`、`../parse.md`、`../name.md`、`../layout.md`、`../owner.md`、`../symbol.md`、`../generic.md`、`enum.md`

## 定义

- 取值范围：名义记录类型；不同 struct 即使字段、类型与布局相同也不是同一类型，无隐式转换。
- 字段集合固定：声明后无增删；字段名在 struct 内唯一；字段顺序固定。
- 字段身份：`FieldId` 从 0 开始按声明顺序编号，是成员表序号，不是字节偏移（`layout.md` 6.6）。
- 内存布局：字段按声明顺序布局，禁止自动重排（`layout.md` 6.1）；`align = max(natural_align, @align 或 1)`，`size = align_up(末字段尾, align)`；padding 非语义值（`layout.md` 6.3）。
- 字段数：至少一个字段；不得超过 65536（`layout.md` 6.5、6.7、LY-10）。
- 默认值：无；绑定必须显式初始化。

## 字面量

- 形式：struct 无字面量；值由构造表达式产生，产生式见 `../parse.md`。
- 拒绝：零字段 struct（`layout.md` 6.5）；字段缺失或重复。

## 操作

- 允许：字段访问 `s.f`；若 `s` 为 `&struct` 引用，字段访问自动解引用一层（`base.md` 7.12）。
- 允许：经 owning 可写 place 或 `&struct:ReadWrite` 修改字段值（`base.md` 4.8）。
- 允许：`@clone`、`@drop`、`@move`（按所有权规则）。
- 禁止：隐式 `==` / `!=`（比较须逐字段显式）；隐式转换；字段重排。

## 转换

- 隐式：无
- 显式 `as`：无
- 溢出行为：不适用

## 所有权

- 复制 / 移动：Copy 当且仅当全部字段为 Copy（`base.md` 7.9、`owner.md` 5.1）；非 Copy struct 按 owning 规则移动，`@move(e)` 转移唯一析构责任。
- 借用形态：`&struct:Read` / `&struct:ReadWrite`；`&struct` 不得作 struct 字段、enum payload、数组元素、泛型实参或函数返回（`base.md` 4.4）。
- 析构：非 Copy struct 在作用域出口逆序析构字段（`owner.md` 6.2）；`@drop(e);` 显式析构。

## 拒绝形态

| 编号 | 条件 | 码 |
|:---|:---|:---|
| LY-10 | struct 字段数超过 65536 | E5510 |
| — | 零字段 struct（`layout.md` 6.5） | — |
| — | `&struct` 出现在字段 / payload / 元素 / 泛型实参 / 返回位（`base.md` 4.4） | — |
| — | 读取、比较或传播 padding（LY-6） | — |

## 关联

- 布局：`../layout.md` 六
- 所有权：`../owner.md` 二、五、六
- 产生式：`../parse.md`
- 字段解析：`../name.md` 6.5
