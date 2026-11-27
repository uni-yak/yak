# gate

## 元信息

- 名称：gate（构建与规格验证门禁）
- 级别：流程
- 状态：草案
- 依赖：`status.md`、`build.md`、`fixpoint.md`、`error.md`、`../index.md`、`../lang/type/result.md`、`../lang/type/option.md`、`../lang/type/union.md`、`../lang/layout.md`、`../lang/symbol.md`

## 一、范围

1.1 本文规定快速门禁、完整门禁以及可错、可空与普通联合载体进入实现前必须具备的验证资产。

1.2 草案语言形态只能登记目标验证，不得因存在本文件的案例清单而视为已实现或确认。

1.3 草案-可实施形态进入快速门禁回归时，仅要求本次改动涉及的正例、负例与接口摘要案例枚举并满足预期（2.1）；不要求在每次参考态改动中执行完整门禁（2.2）。升为确认前须通过完整门禁；参考态的隔离候选取证见 `fixpoint.md`，不等同于完整门禁或正式发布。

## 二、通用门禁

2.1 快速门禁在每次规格或编译器修改后执行，至少验证：

- Markdown 链接与 `error.def` 的 `ref` 均可解析；
- `error.def` 的码位、引用与描述通过生成器校验；
- 本次改动涉及的正例、负例与接口摘要案例均被枚举；
- 同一输入在同一目标 profile 下产生相同诊断集合。

2.2 完整门禁在合入或升级规格状态前执行，至少验证：

- 快速门禁全部通过；
- 已实现的 `test/ok/`、`test/bad/`、`test/gate/` 与 `test/unit/` 用例全部通过；
- Windows x64 PE 与 Linux x86_64 ELF 的类型布局、ABI 摘要与诊断按各自目标规格通过（`abi-win.md` + `pe.md`；`abi-linux.md` + `elf.md`）；
- 固定点构建遵守 `fixpoint.md`；
- 工作目录不保留未登记产物。

2.3 `yakc-min` 的 T2 正式验收使用同一候选固定点 `C2` 验证两个目标。各目标须编译并链接适用的 base 正例，在对应目标系统原生运行并核对预期输出与退出码。负例须核对诊断、退出码及失败产物规则。Windows PE 与 Linux ELF 的目标结果分别归档，Linux ELF 须经 CI 复验。T1 的 Linux 宿主复验按 [构建规格](build.md) 2.4 构建和验证 Windows PE。

2.4 验收记录须列出源码身份、验证命令或常驻入口、目标与工具版本、覆盖范围、退出码和必要摘要。发布所需的原始命令、日志与校验材料由执行环境独立归档。仓库内的验收文档使用常驻规格、测试和脚本的链接，引用归档身份可用 CI 运行编号或内容摘要。

## 三、carrier 草案验证矩阵

| ID | 类别 | 最小验证 | 预期 |
|:---|:---|:---|:---|
| CAR-01 | 上下注入 | `T!E` 函数分别返回 `T` 与 `E` | 分别构造 success 与 error；不需要 `Ok` / `Err` |
| CAR-02 | 错误传播 | `T!E_src` 在返回 `U!E_dst` 的函数中使用 `?` | 仅当 `members(E_src) ⊆ members(E_dst)` 时通过；error 按目标规范序重封装 |
| CAR-03 | 传播拒绝 | 对普通值、`T?`、普通联合使用 `?`，或错误集不为子集 | 普通值 / 非子集为 `E6007`；`T?` 为 `E5815`；普通联合为 `E5819` |
| CAR-04 | 可空边界 | `T?` 使用 `??`、`?.`；`T!E` 使用 `??` 或 `?.` | 前者按可空规则通过；后者拒绝为 `E5814` |
| CAR-05 | 普通联合边界 | `A | B` 使用 `is`；对其分别使用 `?` 与 `??` | 显式 `is` 分流通过；`?` 为 `E5819`，`??` 为 `E5814` |
| CAR-06 | 嵌套区分 | 分别构造 `(T?)!E` 与 `(T!E)?` | 两个内部类型、布局递归树和 TypeSig 不相等；不得扁平为 `T | null | E` |
| CAR-07 | ErrorSet | 交换 `E1 | E2` 源码顺序、经不同 import 别名引用相同 enum | ErrorSet 身份、成员顺序、tag 与 `.iface` 摘要一致 |
| CAR-08 | 重叠拒绝 | 构造 `T!E` 且 `T` 与 `E` 重叠，或 ErrorSet 成员重叠 | 拒绝为 `E5802` 或 `E5801` |
| CAR-09 | 位置限制 | 在按值参数、字段、数组元素、普通联合成员与泛型实参放置直接 owning `T!E`；并在函数参数验证 `&T!E` | 前者拒绝为 `E5811`；后者仅为借用且不放宽 carrier 位置限制；显式 `(T!E)?` 仍继承内层限制 |
| CAR-10 | 所有权 | non-Copy success/error payload 经返回、`?`、作用域退出与恢复路径离开 | 仅 active payload 析构一次；不得读取或析构 inactive payload |
| CAR-11 | out 槽位 | 带 `out` 的 `T!E` 调用直连 `?` 与保存后判定 | 前者按状态机更新槽位；后者拒绝为 `E6105` |
| CAR-12 | 跨模块 | 导出 / 导入包含 `T!E`、ErrorSet 与显式嵌套 carrier 的函数签名 | `fallible` TypeSig 使用 `0x0A`；导入方验证 error enum 的规范序与 target profile |
| CAR-13 | AOT 布局 | 同一 carrier 在 PE 与 ELF 目标计算布局和 ABI 摘要 | 各目标均遵守 `layout.md`；未经 `foreign.md` 登记不得按原始布局穿越 foreign 边界 |
| CAR-14 | 多成员 `.catch` | `T!(E1\|E2).catch(E1=>&h1)` 部分覆盖与 `T!(E1\|E2).catch(E1=>&h1,E2=>&h2)` 全覆盖 | 部分覆盖未命中成员穿透为 `T!(remaining)`；全覆盖收敛为 `T`；表成员越界为 `E5821`、重复为 `E5822` |
| CAR-15 | `.unwrap()` 不正常完成 | `T!E.unwrap()` 在 error 路径触发；`Error` 实现与否；`T?` 上 null 路径 | 析构当前帧 live ownings 后非零退出；`Error` 实现走 `present`，未实现走合成 `<Enum>::<Variant>`；接收者非 carrier 为 `E5823` |
| CAR-16 | 恢复所有权 | `.then`/`.catch`/`.or` 在 success/error 两路径的 payload 析构 | handler 仅借用；命中/解包后析构原 payload 恰好一次；穿透路径 payload 随载体存活，不析构 |

## 四、`#` 无增验证矩阵

| ID | 类别 | 最小验证 | 预期 |
|:---|:---|:---|:---|
| NA-01 | 直接无增 | `function #add` 仅算术、借用、定长数组构造 | `no_alloc=true`，`#` 通过 |
| NA-02 | Copy / 减 | `#` 函数使用 `@copy`、`@move`、`@drop` 与空 `[]` | 通过；Copy 无堆分配，drop/free 为减 |
| NA-03 | 直接增 | `#` 函数含 `@push`、`@clone`、非空 `T[]` 字面量或 foreign 堆分配 | M-7 / E7020 |
| NA-04 | 非 `#` 被调方 | `#A → helper`，helper 未标 `#` 但无增 | 通过；helper 计算 `no_alloc=true` |
| NA-05 | 传递增 | `#A → grow`，grow 含 `@push` 或其可达函数含增 | `#A` 为 M-7 / E7020 |
| NA-06 | 递归 | 自递归、互递归 SCC：全体无增 / 任一含增 | 前者通过；后者全部相关 `#` 入口拒绝 |
| NA-07 | 跨模块 | 导入 format 2 `.iface` function `no_alloc=1` / `0`；另导入旧 format 1 | 1 通过；0 为 M-7 / E7020；format 1 在加载期为 S-12 / E7012 |
| NA-08 | 间接调用 | `#` 函数经 `&function` 参数 / 局部调用 | M-8 / E7021；接收或存储但不调用通过 |
| NA-09 | foreign | `foreign #read` / `#write` / `#exit` / `#assert`；另书写 `foreign #堆分配` | 前四通过；后者为未登记用户 foreign 服务 F-1 / E8001。`#` 图中的编译器内部堆分配由 NA-03 的非空 `T[]` 触发并报 M-7 |
| NA-10 | 泛型 | `function #f<T>` | M-9 / E7022（当前 profile） |
| NA-11 | 接口与镜像 | 导出 function 的 `.iface` flags、`.ysm` function flags、`#` 断言 | flags 一致；`declared_no_alloc=1` 必须蕴含 `no_alloc=1` |

## 五、资产登记

5.1 每个 CAR / NA 条目在实现时必须至少登记一个 `test/ok/` 或 `test/bad/` 用例；涉及拒绝的条目必须登记精确 `ErrorCode`。

5.2 CAR-06、CAR-07、CAR-10、CAR-12、CAR-13、CAR-14、CAR-15 与 CAR-16 必须另有 `test/gate/` 或 `test/unit/` 资产，验证类型身份、规范化、析构、接口、错误呈现与跨目标布局，而非只检查源程序退出码。

5.3 NA-05、NA-06、NA-07、NA-08 与 NA-11 必须另有 `test/gate/` 或 `test/unit/` 资产，验证 SCC 收敛、跨模块 `.iface` flags、间接调用拒绝与镜像一致性。

5.4 S-9 carrier 手动恢复为 full 草案（`../lang/sugar.md` S-9）。启用前，按 `../lang/type/result.md` 与 `../lang/type/option.md` 验证各方法的接收者类型。多成员 ErrorSet 恢复、`.unwrap()` 不正常完成路径及所有权门禁的目标验证见 CAR-14 至 CAR-16。

## 六、关联

- 状态与冻结：`status.md`
- 构建：`build.md`
- 固定点：`fixpoint.md`
- 错误码：`error.md`、`error.def`
- 类型矩阵：`../index.md`
- 可错、可空与普通联合：`../lang/type/result.md`、`../lang/type/option.md`、`../lang/type/union.md`
- 布局与接口：`../lang/layout.md`、`../lang/symbol.md`
