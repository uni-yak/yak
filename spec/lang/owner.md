# owner

## 元信息

- 名称：owner（所有权、借用与析构）
- 级别：base / full（base 完成所有权与能力模型；full 仅追加已登记类型）
- 状态：草案-可实施
- 依赖：`base.md`、`parse.md`、`name.md`、`layout.md`、`type/enum.md`、`type/union.md`、`type/option.md`、`type/result.md`、`type/array.md`、`type/struct.md`、`type/slice.md`、`foreign.md`、`../proc/error.md`、`../proc/error.def`

## 一、范围

1.1 本文规定 owning 值的状态、移动、复制、借用、`out` 槽位、析构、clone 与不正常完成路径。

1.2 类型的对象布局由 `layout.md` 规定；本文件只规定何时拥有、访问、转移或销毁其语义值。

## 二、owning place 状态

2.1 普通 owning place 处于 `live`、`moved` 或 `dropped` 之一：声明完成后为 `live`；发生移动后为 `moved`；显式 `@drop`、作用域析构或覆盖旧值后为 `dropped`。`const` 不是 owning place，不进入该状态机；每次使用按 `const.md` 取得常量值。

2.2 `moved` 与 `dropped` place 不携带值；除重新初始化可写 `var` 外，读取、借用、再次移动、复制、析构或作为 enum payload 使用均拒绝。

2.3 非 Copy owning 值进入 `let` / `var` 初始化、赋值、`return`、enum payload、普通联合成员、可空或可错 carrier 的活动 payload、数组元素、struct 字段或显式 `@move` 时转移所有权；调用 owning 参数必须显式写 `@move(e)`。

2.4 Copy 值在普通值位置复制，源 place 保持 `live`；`@copy(e)` 是同一复制语义的显式形式。Copy 判定按 `base.md` 7.9 递归完成，不允许用户实现或覆盖。

2.5 不提供部分移动：移动 struct 字段、数组元素、普通联合 / `T?` / `T!E`（内部 `Fallible`）的 inactive payload、ErrorSet inactive payload 或 enum 的一部分均拒绝。enum `match` 的 payload 绑定是唯一例外：它消费整个 enum 后将 active payload 转入臂域绑定。

2.6 `var` 重新赋值前，旧 `live` 值按第六节析构；新 RHS 完成移动 / 复制后该 place 重新为 `live`。`let` 不得重新赋值。

## 三、借用与能力

3.1 `&place` 建立 `Read`；`&place:ReadWrite` 只可从可写 `var` place 建立。`Write` 只由 `out` 参数通道建立。

3.2 临时借用的区域为其完整表达式；绑定到 `let` / `var` 的引用区域为该绑定所在块域。引用不得越出宿主 place 的作用域，不得作为返回值、字段、enum payload、数组元素或泛型实参。

3.3 活跃 `Read` 区域内可建立更多 `Read`，但不得移动、析构、重新赋值或建立 `ReadWrite` 于同一或重叠 place。

3.4 活跃 `ReadWrite` 区域内，原 place、其重叠 projection 与其他引用均不得读取、写入、移动、复制、借用或析构；只能通过该 `ReadWrite` 引用访问。

3.5 当前 base 检查器保守地将同一根 place 的任意 projection 视为重叠；未来允许字段级不相交借用时必须增加新规格与错误码，不能改变当前判断。

3.6 capability 只可 `ReadWrite → Read` 收窄。引用值可复制其视图表示，但每个副本携带相同 capability 约束；复制引用不转移或复制目标 owning 值。

3.7 `&function(P): R` 是 Copy 静态值，不建立借用区域；`ptr<T>` / `cptr<T>` 的 full 层规则由 `unsafe.md` 与 `foreign.md` 规定。

## 四、`out` 槽位

4.1 `out` 遵守 `base.md` 7.12 的 `empty → lent → full → consumed` 状态机；普通 owning place 不可代替 out 的 empty 状态。

4.2 `out` 只可作为 `&T:Write` 调用参数；同一调用的 out 实参必须指向不同槽位。被调方不得转发 `Write`。

4.3 `out` 槽位为 `full` 后只能以 `@move` 提取；作用域退出时，未消费的 full 槽位按第六节析构。错误、陷阱或提前退出时已提交 payload 必须先析构并使槽位回空。

4.4 控制流合流要求同一槽位状态一致；不以零值、未初始化字节、宿主异常或泄漏伪造状态转换。

## 五、Copy、clone 与移动

5.1 enum、普通联合、`T?`、ErrorSet 与 `T!E` 的 Copy 判定分别遵守 `type/enum.md`、`type/union.md`、`type/option.md` 与 `type/result.md`；struct、数组、切片与函数静态引用遵守各自类型文档及 `base.md` 7.9。

5.2 `@move(e)` 只接受 `live` owning place，零拷贝转移唯一析构责任并使源为 `moved`。视图与函数静态引用不可 `@move`。

5.3 `@copy(e)` 只接受 Copy 类型；复制结果为独立语义值或视图副本，源保持 `live`。`@copy` 为栈值 / 指针 / 视图的位拷贝，**不产生 Yak 运行时堆分配**；Copy 类型不得直接或递归拥有需析构资源（`base.md` 7.9）。不得把 `@copy` 自动改写为 `@clone`。

5.4 `@clone(e)` 只接受非 Copy owning 值且其递归 clone 契约完整；普通联合、`T?` 与 `T!E` 载体不适用 `@clone`（`type/union.md`、`type/option.md`、`type/result.md`）。源保持 `live`。若任一步 clone 分配或嵌套 clone 失败，必须逆序析构已构造的目标部分并返回 `AllocError`。

5.5 enum 的 clone 只处理 active payload；未激活 payload 与 padding 永不读取、复制或析构。ErrorSet 仅作为 `T!E` 内部错误位存在，`T!E` 不适用 clone。

## 六、析构与完成路径

6.1 每个 non-Copy owning `live` 值在其作用域的正常出口、运行期异常完成路径或显式 `@drop` 中恰好析构一次。non-Copy `return` payload 与在 carrier 返回函数中 `?` 的 error payload均转移析构责任至目标返回 carrier；二者不是对该 payload 的本地析构。Copy return payload 按 Copy 规则复制，源保持 live。`?` 位于非 carrier 返回函数为 RE-4，编译器不得生成隐式 runtime 终止路径。返回 / 传播后仍 live 的局部值按本节逆序清理。

6.2 同一作用域的析构按绑定声明逆序；复合值内部按以下顺序析构：struct 字段按声明逆序，定长数组和 `T[]` 元素按索引逆序，enum / 普通联合 / `T?` / ErrorSet / `T!E` 仅析构 active payload。

6.3 Copy 值无用户可观察析构；显式 `@drop` 仍消费该 owning place，但不产生递归析构工作。

6.4 `@drop(e);` 只接受 `live` owning 整 place（标识符形式）；成员、索引与切片投影一律拒绝（OW-11），不区分投影类型是否为 Copy。析构后源变为 `dropped`；再次析构或使用同一源均拒绝。

6.5 不正常完成路径必须以与正常路径相同的顺序清理所有已初始化、尚未移动的 owning 值；不得发生泄漏、双析构或对 inactive payload 的析构。

## 七、确定性

7.1 同一 AST、类型结果与控制流图必须产生相同的 place 状态转换、借用区域、析构序列与诊断集合。

7.2 检查器不得以哈希遍历、地址、时间、优化档位或宿主异常决定移动、借用、析构或槽位状态。

## 八、拒绝形态

| 编号 | 条件 | ErrorCode |
|:---|:---|:---:|
| OW-1 | 使用、借用、移动、复制或析构 `moved` / `dropped` place | E6003 |
| OW-2 | `ReadWrite` 活跃时访问重叠 place 或其他引用 | E6004 |
| OW-3 | 引用逃逸宿主区域（含返回局部借用） | E6005 |
| OW-5 | capability 升级或对 `let` 请求 `ReadWrite` | E6008 / E6009 |
| OW-6 | 隐式所有权动作、非法 `@copy` 或不完整 clone 契约 | E6201 / E6202 / E6203 |
| OW-7 | 对非 owning 值执行 `@move` / `@drop` | E6204 |
| OW-8 | out 槽位读取、重复填充、借用、转发或合流状态不一致 | E6102 / E6103 |
| OW-9 | out 类型非法，或含 out 的 carrier 保存后再判定 | E6104 / E6105 |
| OW-10 | 对 struct 字段、数组元素或任何 owning place 的投影执行部分移动（违反 2.5） | E6205 |
| OW-11 | `@drop` 的参数是成员、索引或切片投影，而不是整 place（违反 6.4） | E6206 |

## 九、静态断言

下列条目在 base 下没有可书写的触发输入，不是源码级拒绝形态：不要求拒绝语料夹具，实现也不得为其发码。已登记的码位按 `../proc/error.md` 2.5 保留。每条断言由“保证方式”列出的源码级拒绝维持；这些前置拒绝的夹具一旦失效，断言即视为失效。

| 编号 | 断言 | 保证方式 |
|:---|:---|:---|
| OW-4 | 借用关系与类型布局均不存在经由引用或切片形成的环或自引用 | 视图不能进入字段、enum payload、数组元素或返回位（`parse.md` P-9）；引用与切片不建立按值布局边（`layout.md` 2.7） |

## 实施边界

本节封闭 owner.md 在种子期的可实施范围，满足 `../proc/status.md` 2.1：

- 合法形态：owning place 三态转换、`@move` / `@copy` / `@clone` / `@drop`、借用能力三态、`out` 槽位状态机、正常出口的逆序析构，规则已由第二至第六节完整规定。
- 拒绝形态：OW-1 至 OW-11 均已登记错误码，其中 OW-4 为第九节的静态断言；OW-10 对应决策4「维持禁止部分移动」，不以 drop flag 或运行期析构分支实现部分移动；OW-11 对应决策11「析构单位与所有权单位一致」。
- 析构顺序：第六节规定同一作用域逆序、复合值内部按字段/索引逆序、carrier 仅 active payload；种子期不做部分移动，因而每个 owning place 的析构叶唯一，顺序完全静态可判定。
- T1 正常退出：函数返回、`?` 传播、块落尾和带标签的 `break`／`continue` 按作用域退出计划清理；拥有型按值形参在退出函数时参与，借用和 `Write` 形参不是局部所有者。只有整值在合流后可能仍拥有时才需要守卫析构；守卫不恢复读取或再次移动的能力。
- T1 陷阱边界：算术、索引／切片检查及标准外部服务失败使用位点专属的 MIR 清理边（见 `../ir/mir.md` 4.13）。失败与显式退出从内层向外层清理。每帧先析构仍持有的局部，再回滚尚未消费的满槽和已提交的 `Write` 形参。已交接的按值实参由被调方负责清理。
- 依赖边界：`type/union.md`、`type/option.md` 在种子期仅提供 Copy 判定与 active payload 析构规则；本文件不依赖其未冻结的恢复语法。full 层 clone 失败回滚（5.4）的跨目标验证推迟到完整门禁。

## 用例

- `seed/test/t91_partial_move.yak`：struct 字段部分移动拒绝（OW-10）
- `seed/test/t276_partial_field.yak`：字段投影部分移动拒绝（OW-10）
- `seed/test/t277_partial_index.yak`：数组元素投影部分移动拒绝（OW-10）
- `seed/test/t126_drop_state.yak`：析构状态与逆序清理
- `seed/test/t260_aggregate_cleanup.yak`：聚合值析构顺序
- `seed/test/t246_min_owner.yak`：min 检查器的所有权状态机

## 关联

- 基座所有权规则：`base.md`
- 语法位置：`parse.md`
- 名字与块域：`name.md`
- enum：`type/enum.md`
- 失败载体：`type/result.md`
- 数组、slice、struct：`type/array.md`、`type/slice.md`、`type/struct.md`
- 对象布局：`layout.md`
- 错误码数据：`../proc/error.def`
- 错误码规则：`../proc/error.md`
