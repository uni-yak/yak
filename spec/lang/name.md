# name

## 元信息

- 名称：name（名字、作用域与可见性）
- 级别：base
- 状态：草案
- 依赖：`lex.md`、`symbol.md`、`base.md`、`parse.md`

## 一、范围

1.1 本文规定名字的构成、作用域层次、可见性规则、遮蔽规则与名字解析。

1.2 名字到 id 的映射由 `symbol.md` 第三节承载：`NameId` 标识名称拼写，`ScopeId` 标识词法可见性上下文，`DefId` 标识具体声明实体。本文只规定语义规则，不重复表结构与分配机制。

1.3 名字的字节构成由 `lex.md` 规定；本文不重复词法产生式。

## 二、名字构成

2.1 标识符为 UTF-8 字节序列；首字符为字母或下划线，后续字符为字母、下划线或数字。

2.2 保留字不得作标识符（`lex.md` 唯一真源）。

2.3 `Read` / `Write` / `ReadWrite` 为上下文关键字，仅在 `&T:` 后缀位与参数能力位具有关键字语义；其余位置可作标识符。

2.4 `move` 为普通标识符（转移动作写作 `@move(e)`），不是参数前缀；`out` 为保留字（`lex.md` 5.1），不是上下文关键字——它在槽位声明位与调用点前缀位具有关键字语义，不可作标识符。

2.5 `@` 前缀记号（`@move` / `@copy` / `@clone` / `@drop` / `@push` / `@len` / `@wrap_add` / `@wrap_sub` / `@wrap_mul`）不是用户标识符，是原语调用，由 `lex.md` 词法分流为 token；它不进入 `NameTable`，在适用表达式位置直接解析为 `BuiltinId`。

2.6 `HashName`（`#foo`）只允许在 `function` / `foreign` 的 `CallableName` 位，底层名称仍为 `foo` 的 `NameId`。它设置 declaration 的 `declared_no_alloc` 标记，不引入第二名称、第二 `DefId` 或第二可见性实体；`#foo` 与 `foo` 因同一 `NameId` 不能在同一作用域共存。

## 三、作用域层次

3.1 每个词法作用域对应一个 `ScopeId`，并拥有从 `NameId` 到 `DefId` 的绑定表。作用域自外向内可为下列种类：

| 种类 | 宿主 | 登记绑定 |
|:---|:---|:---|
| module | 模块文件 | `function`、`enum`、`struct`、`const`、`foreign`、`import` |
| generic | full 层泛型声明 | 泛型参数 |
| function | 函数体 | 参数、`out` 槽位、函数体顶层 `let` / `var` |
| block | `{ }` 块 | 块内 `let` / `var` / `const` / `out` |
| arm | `match` 单个臂 | payload 绑定 |

3.2 模块根 `ScopeId` 是单元内唯一父作用域为零的作用域。full 泛型声明的 generic 作用域位于所属模块域与函数 / enum / struct 声明体之间；未声明泛型时不创建该作用域。

3.3 函数、块与 match 臂分别创建独立 `ScopeId`。块退出时按声明逆序析构（遵守 `owner.md`）；臂域生命周期仅限于该臂块体。

3.4 `for` / `while` 循环体为 block 作用域；循环变量（如有）属于循环体作用域，不提升到函数域。作用域不可跨函数；函数返回后函数域与其所有子作用域一并失效。

3.5 enum 标签与 struct 字段不是词法绑定，不创建 `ScopeId`；它们仅进入宿主的成员表，分别由 `VariantId` 与 `FieldId` 标识。普通变量、参数、const 与 out 槽位也不拥有子符号空间；它们只是其所属 `ScopeId` 中的一个 `DefId` 绑定。

## 四、可见性

4.1 模块内可见性：

| 声明 | 模块内 | 跨模块 |
|:---|:---|:---|
| `export function` / `export enum` / `export struct` | 可见 | 可见（经 `import`；enum 标签随 enum 一并可见） |
| 未加 `export` 的 `function` / `enum` / `struct` | 可见 | 不可见 |
| `foreign` | 可见 | 不可见（模块私有，不进 `.iface`） |
| `const` | 可见 | 不可见（base 期） |

4.2 `import` 的首段在导入方 module `ScopeId` 中登记为 `DefKind=import` 的 `DefId`，并持有一个 `DependencyId`。限定路径解析到依赖公开成员时，resolver 建立并缓存 `(import DefId, NameId) → ExportId` bridge；语义引用固定为 `ImportRef=(DependencyId, ExportId)`，不保留 import 名称字节。

4.3 嵌套作用域可见外层名称；同名遮蔽时取最内层绑定（第五节）。

4.4 `import` 引入的名称在导入方模块域不可被重新声明（拒绝形态 N-6）。

4.5 base 期无 `pub` / `priv` 修饰符；可见性仅由 `export` 关键字控制。full 层可见性扩展登记于 `sugar.md`。

## 五、遮蔽

5.1 同一作用域内禁止重复声明（拒绝形态 N-1）。

5.2 嵌套作用域允许遮蔽外层名称：内层声明与外层同名时，内层绑定在外层同名者的作用域内不可见，直到内层退出。

5.3 遮蔽不触发析构；外层绑定在其自身作用域退出时按 `owner.md` 析构。

5.4 `let` / `var` / `const` 不可遮蔽同作用域已有声明；但内层块可遮蔽外层 `let` / `var` / `const` / 参数 / 模块域名。

5.5 `match` 臂绑定不可遮蔽同臂内已有绑定；各臂可按各自标签独立决定是否绑定 payload（`base.md` 6.3）。

5.6 参数不可遮蔽同函数域的其他参数；但可遮蔽模块域名。

5.7 保留字不可被遮蔽（它们不是标识符）。上下文关键字在其关键语义位由语法位置解释，在其他标识符位进入普通 `NameId` / `DefId` 解析并遵守本节遮蔽规则。

## 六、名字解析

6.1 每个未解析标识符均先携带 `NameId + Span`。resolver 从当前 `ScopeId` 沿父指针向模块根逐层以 `NameId` 查绑定表，首个命中停止；普通绑定解析为 `DefId`，module import 解析为其 `DependencyId`。此查找只比较整数。

6.2 未命中词法绑定时，适用的类型或固有项语法位可读取 token 已缓存的 `BuiltinId`；无适用 `BuiltinId` 时为 N-2。若已命中普通 `DefId` 但其 kind 不适用于当前语法位，同样拒绝，不得回退为同名 `BuiltinId`。`@` 原语和注解不经过本节查找，词法 token 已直接携带其 `BuiltinId`。普通源码声明不会被隐式提升为固有项。

6.3 路径解析 `A::B::C` 从左到右逐段进行：首段按 6.1 解析；后续依赖接口段首次以 `(import DefId, NameId)` 建立 `ExportId` bridge 并缓存，后续同一对只查询整数 bridge 表。`::` 只表示编译期路径。

6.4 enum 构造或 pattern 位置的最后一个 `::Ident` 解析为标签，其前缀必须解析为所属 enum 类型；本地 enum 的 `(宿主 DefId, NameId)` 在成员整数表中解析为 `VariantId`，导入 enum 首次建立 `(DependencyId, ExportId, NameId) → VariantId` bridge。标签不是模块路径段或独立声明。`TypePath<Args>` 在类型位置解析为泛型类型实例；`FunctionPath::<Args>(...)` 在调用位置解析为显式泛型实例。

6.5 `.` 只解析为实例成员访问（字段或方法接收者），不解析为模块、类型或 enum 标签路径。本地 struct 的 `(宿主 DefId, NameId)` 在成员整数表中解析为 `FieldId`；导入 struct 首次建立 `(DependencyId, ExportId, NameId) → FieldId` bridge。

6.6 解析成功后，AST 只能保留本地 `DefId`、`BuiltinId`、`ImportRef`、`FieldId` 或 `VariantId`；`NameId` 和 `ScopeId` 只用于 resolver、审计与诊断反查。

6.7 解析失败为拒绝形态（N-2）；歧义（同名多路径可达）为拒绝形态（N-3）。

6.8 前向引用禁止：名字在声明之前不可被引用（拒绝形态 N-4）。唯一例外是模块级 `function` / `foreign`：按 `module.md` 3.5 的 callable header 收集，在解析任一函数体前已预绑定全部同模块 callable，因此允许自递归、互递归及对后声明 callable 的直接调用。此例外不适用于 const、类型、enum、struct、泛型参数、局部绑定或普通变量。

6.9 名字解析顺序是解析的确定函数；相同源码与相同依赖接口产生相同 `ScopeId`、`DefId` 与 bridge 集合。

6.10 显式 `break label` 和 `continue label` 从最内层向外查找当前函数中包围该语句的循环标签。标签独立于普通绑定；同名时选最近的包围循环，未命中按 N-2 拒绝。

## 七、模块域

7.1 模块名与文件路径一致（`base.md` 8.1）；一个文件一个模块。

7.2 模块依赖为 DAG；循环依赖为拒绝形态（`base.md` 8.2，N-5）。

7.3 base 期模块顶层只允许 `const` 绑定（`base.md` 8.4）；`let` / `var` 推迟至 full 层。

7.4 `import` 语句只允许出现在模块顶层；导入名进入模块域。

7.5 `import` 不允许自导入（拒绝形态 N-7）。

## 八、`DefId` 与作用域图

8.1 每个源码声明实体分配一个 `DefId`；同名遮蔽声明具有不同 `DefId`。`DefId` 在单元内全局唯一，但数值不编码模块、函数、块或父声明；归属由 `DefEntry.scope` 给出。

8.2 每个词法作用域分配一个 `ScopeId`。`ScopeEntry` 显式保存 parent、作用域种类和其绑定区间；作用域图为树结构，模块根是唯一 parent 为零的记录。不得从 id 数值、地址或位域推导父子关系。

8.3 每个作用域的绑定表以 `(NameId, DefId)` 保存。它是名字解析期的唯一可见性索引；同一作用域内相同 `NameId` 的第二次声明拒绝为 N-1，嵌套作用域中相同 `NameId` 对应的不同 `DefId` 按第五节遮蔽。

8.4 `NameId`、`ScopeId` 与 `DefId` 只在本单元有效；跨单元引用经 `.iface` 解析为 `ImportRef`，不得直接序列化或传递这些本地 id。

## 九、拒绝形态

| 编号 | 条件 |
|:---|:---|
| N-1 | 同一作用域内重复声明 |
| N-2 | 名字解析失败（无匹配声明） |
| N-3 | 名字解析歧义（多路径可达同名） |
| N-4 | 前向引用（声明之前引用） |
| N-5 | 循环模块依赖 |
| N-6 | `import` 引入名被本模块重新声明 |
| N-7 | 模块自导入 |
| N-8 | 未导出项被外部模块引用 |
| N-9 | 未使用绑定（`base.md` 5.6） |
| N-10 | `match` 臂绑定遮蔽同臂内已有绑定 |
| N-11 | 参数遮蔽同函数域其他参数 |

## 关联

- 词法与保留字：`lex.md`
- 符号 id 与桥接：`symbol.md`
- 基座语法：`base.md`
- 语法产生式：`parse.md`
- 模块细则：`module.md`
- 所有权与析构：`owner.md`
