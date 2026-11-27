# function

## 元信息

- 名称：function（`&function(P): R` 函数静态引用）
- 级别：base
- 状态：草案
- 依赖：`../base.md`、`../parse.md`、`../layout.md`、`../owner.md`、`../symbol.md`

## 定义

- 取值范围：函数静态引用，8 字节地址值（`layout.md` 2.3、四）。
- 值类型，Copy；无所有权、无析构、无能力（`base.md` T-13、`owner.md` 3.7）。
- 签名 `&function(P): R`：`P` 为参数类型列表，`R` 为返回类型；签名是类型身份的一部分。
- 默认值：无；绑定必须显式初始化。

## 字面量

- 形式：无字面量；由取函数地址产生，产生式见 `../parse.md`。
- 匿名函数 `(ParamList) => Block`（`../sugar.md` S-21，full）产出 `&function(P): R` 值；无捕获，body 只引用参数与模块级名字。
- 拒绝：取非 function 实体的地址；签名不匹配的目标。

## 操作

- 允许：经引用调用 `fptr(args)`；参数按目标 ABI 与签名降级。
- 允许：`==` / `!=`（地址比较，同一目标为相等）。
- `#` 可达调用图中经引用调用为 `call_indirect`，运行期目标不可穷尽验证，故可达 callable 不得执行该调用（`mir.md` M-8）；接收、存储或比较 `&function` 值不受此限制。
- 禁止：算术、位运算、比较序；解引用为函数体。

## 转换

- 隐式：无
- 显式 `as`：无
- 溢出行为：不适用

## 所有权

- 复制 / 移动：Copy；普通值位置复制，源保持 live；`@move` / `@drop` 不适用。
- 借用形态：不建立借用区域（`owner.md` 3.7）。
- 析构：无。
- 位置限制：`&function(P): R` 不受 `base.md` 4.4 视图位置限制；可作 struct 字段、enum payload、数组元素、泛型实参与函数返回。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| — | 取非 function 实体地址 |
| — | 调用时签名不匹配 |
| — | foreign 边界传递 `&function`（`foreign.md` 5.2） |

## 关联

- 布局：`../layout.md` 四
- 所有权：`../owner.md` 3.7
- 产生式：`../parse.md`
- foreign 边界：`../foreign.md`
