# module

## 元信息

- 名称：module
- 级别：base / full
- 状态：草案
- 依赖：`base.md`、`parse.md`、`name.md`、`symbol.md`、`../proc/build.md`、`../proc/fixpoint.md`

## 一、范围

1.1 本文规定模块的文件映射、命名、依赖图、导入导出、跨单元接口产物与构建编排。名字解析的内部数据结构（`ScopeId` / `DefId` / bridge）见 `name.md`；`.iface` 二进制格式与符号 id 见 `symbol.md`；本文只规定模块层契约。

1.2 base 期模块为平面单文件模块；full 期不引入嵌套模块或包（推迟登记）。

## 二、文件与模块名

2.1 一个文件一个模块（`base.md` 8.1）。模块名由文件路径推导，规则见 `../proc/build.md` 的路径→模块名映射；模块名是规范身份，不得由构建目录或输入文件绝对路径决定（`symbol.md` 3.11）。

2.2 模块路径记法：以 `::` 分隔的路径段序列（`parse.md` `ModulePath`）。`import` 的首段在导入方模块域登记为 `DefKind=import` 的 `DefId`，并持有一个 `DependencyId`（`name.md` 4.2）。

2.3 base 期模块顶层允许：`function` / `enum` / `struct` / `const` / `foreign` / `import` 项；顶层 `let` / `var` 推迟 full（`base.md` 8.4、`name.md` 7.3）。

## 三、依赖图

3.1 模块依赖为有向无环图（`base.md` 8.2）。边由 `import` 语句定义。

3.2 循环依赖为拒绝形态 N-5；自导入为拒绝形态 N-7（`name.md`）。

3.3 构建按 DAG 拓扑序编译依赖单元（`../proc/build.md`）；同输入产生相同拓扑序与相同产物（`../proc/fixpoint.md`）。

3.4 单元依赖数不得超过 65535（`symbol.md` 3.12）。

3.5 同模块 callable header 收集：`symbol.md` 3.3 的 reservation prepass 先按完整 AST 源码前序预留 `DefId` / `ScopeId`；模块 header pass 仅使用已预留的 id 收集模块级 `function` / `foreign` 的名称、签名语法与 `#` 声明标记，不改变 id 顺序。函数签名中的类型路径仍按通常的前向引用规则解析。故函数体的**直接 callable 调用位**可调用同模块中任意先后位置、且签名已合法的 function / foreign，允许互递归；该例外不放宽 callable 的取地址、普通值位、类型位、const 初始化器，也不放宽 const、类型、enum、struct 或普通变量的前向引用规则，更不改变模块 DAG。

## 四、导入与导出

4.1 `import` 只允许出现在模块顶层（`parse.md` 2.2、`name.md` 7.4）；语法 `import ModulePath ;`。

4.2 `import` 引入名在导入方模块域登记，不可被本模块重新声明（N-6）。

4.3 `export` 前缀控制跨模块可见性（`parse.md` 3.3、`name.md` 4.1）：

| 声明 | 模块内 | 跨模块 |
|:---|:---|:---|
| `export function` / `export enum` / `export struct` | 可见 | 可见（经 `import`；enum 标签随 enum 一并可见） |
| 未加 `export` 的 `function` / `enum` / `struct` | 可见 | 不可见 |
| `foreign` | 可见 | 不可见（模块私有） |

4.4 base 期无 `pub` / `priv` 修饰符；可见性仅由 `export` 控制（`name.md` 4.5）。full 层扩展登记于 `sugar.md`。

4.5 跨单元引用经 `.iface` 解析为 `ImportRef=(DependencyId, ExportId)`，不传递 `NameId` / `ScopeId` / `DefId`（`name.md` 8.4、`symbol.md` 3.8）。

## 五、路径解析

5.1 模块与类型路径用 `::`（`parse.md` `ModulePath`、`name.md` 6.3）；`A::B::C` 从左到右逐段解析。

5.2 `.` 只解析为实例成员访问（字段或方法接收者），不解析为模块、类型或 enum 标签路径（`name.md` 6.5）。

5.3 enum 标签路径 `EnumType::Variant`：最后一段解析为标签，前缀必须解析为所属 enum 类型（`name.md` 6.4）。

5.4 解析失败为 N-2；歧义（同名多路径可达）为 N-3（`name.md`）。

## 六、跨单元接口产物

6.1 每个单元编译产出二进制 `.iface` 和对应目标对象。Windows PE 使用 COFF `.obj`，Linux ELF 使用 `.o`（`symbol.md` 3.13、7.3；`../proc/build.md` 6.1）。

6.2 `.iface` 含公开名称、公开签名、必要布局摘要、导出泛型 MIR，以及只记录名称与种类的私有名节；不含私有项的签名或布局、局部变量名、调试索引（`symbol.md` 7.3、10.8）。

6.3 导入方只加载其依赖的 `.iface`，不加载依赖模块完整 arena（`symbol.md` 7.3）；每个依赖接口只加载一次（`symbol.md` 3.13）。导入方引用依赖模块的顶层名字时，在导出表中找不到而在私有名节中找到的，报 N-8（E4008）；两处都找不到的才是 N-2（E4002）。

6.4 `.iface` 的 `module_identity` 存储声明模块完整路径字节，是导出用户 enum / struct 的规范身份（`symbol.md` 3.11）。

6.5 接口签名、接口摘要或目标 profile 不匹配时拒绝编译（`symbol.md` 3.14）。

6.6 `.iface` 只用于编译。目标对象与配套可执行文件不含完整的 `.iface` 或 `.sym`（`symbol.md` 7.7）。

## 七、构建编排

7.1 构建入口接收根模块路径，解析模块图，按拓扑序编译（`../proc/build.md`）。

7.2 依赖单元的 `.iface` 必须先于导入方编译就绪；缺失或哈希不匹配为构建失败（`../proc/fixpoint.md`）。

7.3 链接阶段合并各单元的目标对象与同 profile 的运行时（`../proc/build.md` 6.1）。修饰名与 `LinkId` 见 [Win64 ABI](../target/abi-win.md) 与 [Linux ABI](../target/abi-linux.md)。

## 拒绝形态

| 编号 | 条件 | 码 |
|:---|:---|:---|
| N-2 | 名字解析失败 | E4002 |
| N-3 | 名字解析歧义（多路径可达同名） | E4003 |
| N-5 | 循环模块依赖 | E4005 |
| N-6 | `import` 引入名被本模块重新声明 | E4006 |
| N-7 | 模块自导入 | E4007 |
| N-8 | 未导出项被外部模块引用 | E4008 |

## 关联

- 名字解析内部：`name.md`
- 符号 id 与 `.iface` 格式：`symbol.md`
- 产生式：`parse.md`
- 构建与拓扑序：`../proc/build.md`
- 固定点：`../proc/fixpoint.md`
