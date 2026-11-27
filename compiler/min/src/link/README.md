# 链接符号构造（link）

## 职责

本目录把 MIR 模块和解析器认证过的 foreign 服务映射成 COFF 链接符号，交给
`coff::emit_object` 生成可被目标链接器合并的目标文件。它不参与语法、类型或 MIR
合法性判定，也不自行构造名字哈希。

调用链（`tools/link.sh` 为每个单元按依赖顺序重复一次，最后一个为根）：

```
main.yak
  → iface::load_interface + add_binary_dependency   （加载前序单元 .iface，建立 DependencySet）
  → mir::build_mir                                 （ImportRef 降为 0x91 call_far）
  → iface::build_export_map                        （与 .iface 共用同一套导出编号）
  → link_names::build                              （本目录 names.yak，接收 DependencySet）
  → coff::emit_object(module, table, coff::profile_win64_pe())
  → iface::write_interface_with_dependencies       （写出规范依赖表与 MIR 推导事实）
```

直接调用驱动时，第一个位置参数是源输入登记名，随后可传模块名和单元角色。
模块名缺省为 `main`，单元角色缺省为 `root`；显式角色必须精确匹配 `root` 或 `dep`。
无效角色在读取源输入前作为用法错误退出（状态码 2），不写对象和接口。角色之后的位置参数登记候选接口。
驱动校验候选接口，以源码中的完整模块路径筛选直接依赖，再按接口摘要、模块名字节排序；解析和写出 `.iface` 使用同一依赖编号，候选参数顺序不参与编号。

## 符号规则与依据

`LinkSymbol.kind` 的取值与 COFF 存储类对应关系（`emit/coff.yak` 的
`build_symbols`）：

| kind | 含义 | 节号 | 存储类 |
|:---:|:---|:---:|:---|
| 0 | 本对象内部函数 | 1（.text） | STATIC |
| 1 | 未定义外部函数（运行时服务或跨单元导入） | 0（无节引用） | EXTERNAL |
| 2 | 数据符号 | 1 | EXTERNAL |
| 3 | 导出函数或入口别名 | 1（.text） | EXTERNAL |

### 对外可见名

- 根模块的 `function main(): void` 产出唯一别名 `yak$entry`，必须 EXTERNAL，
  由运行时 `start` 调用（`spec/target/abi-win.md` 5.1、`spec/target/pe.md` 3.4）。
  驱动在 MIR 降级前拒绝缺失或签名不符的根入口，且不写出该单元的对象和接口。
  非根模块不产出该别名。
- 导出函数为 `yak$<module>$f<ExportId>`（`spec/target/abi-win.md` 5.1）。
  `<module>` 直接使用调用方传入的模块名字节，不查询、不猜测、不做哈希。
  `ExportId` 来自 `iface::build_export_map`，与 `.iface` 导出表、YSM 导出编号
  使用同一实现，保证编号唯一来源。
- 模块名按已验证的模块身份拼接，允许由 `::` 分隔的合法标识符段。根单元也校验模块身份。
  COFF 和 ELF 在装配前核对保留的 `yak$` 名字，包括段分隔、类别标记、无前导零的十进制编号与 u32 范围。
  base 的链接表没有单态化签名证据，直接传入带 `$i` 后缀的名字时失败关闭。

### 非导出函数

规格只冻结对外可见的修饰名（`spec/target/abi-win.md` 5.1 的普通函数、泛型实例、
enum 标签与入口别名），没有为内部函数规定链接名。因此非导出函数使用
`yak$<module>$l<DefId>` 作为确定性名称，并以 STATIC 存储类写入 COFF：
STATIC 符号不参与目标文件间的外部解析，不会被链接器当作对外 ABI。
这只是本对象内部的确定性命名，不是新增的对外命名方案。

### foreign 服务

`spec/lang/foreign.md` 3.1/3.2/3.4 规定的标准服务映射：

| 服务（`ForeignService.kind`） | 运行时符号 |
|:---:|:---|
| 1 | `yak_rt_exit` |
| 2 | `yak_rt_assert` |
| 3 | `yak_rt_read` |
| 4 | `yak_rt_write` |

只有被 `call_foreign`（MIR 指令 147）实际引用的服务才写入未定义符号；声明而未
调用的 foreign 不产生符号，避免死声明导致链接失败。5/6（内部堆分配/释放）在当前
前端不会从用户源码直接降为 foreign 调用，本目录也没有自行伪造该映射；16–21 是
种子解释器的宿主服务，不属于目标运行时链接符号。上述情况被调用时拒绝为 E80-01。

## 拒绝路径

`link_names::build` 返回 `LinkBuild { ok, table, code }`，`main.yak` 在
`ok == false` 时以 `链接符号 E<code>` 打印结构化诊断并退出 1：

- E80-01（8001）：调用了未登记或不属于目标运行时的 foreign 服务。
- E80-09（8009）和 E80-17（8017）：Win64 和 System V 上的非法修饰名或无签名依据的实例后缀（AW-4／AL-4）。
- COFF 发射的拒绝码原样透传：E80-02/03/04/05/22（`e_em1`–`e_em5`），见
  `spec/proc/error.def` 与 `emit/README.md`。

对象发射失败（`EmitResult.ok == false`）同样拒绝并退出非零，不产出空对象文件。

## 已知边界

- **文本输出已可用**：`foreign write` 的 `&[u8]` 形参已经贯通——
  `compiler/min/src/mir/mir.yak` 的 `supported_type` 接受 `&[u8]` 切片，字符串字面量
  进 MIR 静态池并发射为 `const_bytes`；`compiler/min/src/emit/coff.yak` 把静态字节写入
  `.rdata`、生成 `$s<下标>` 数据符号，并按 (指针, 长度) 展开切片实参。
  `examples/hello.yak` 经 `tools/link.sh` 产出可执行文件，stdout 逐字节匹配。
  仍受限制的是：切片实参超出四个整型寄存器窗口时按未支持形态拒绝（EM-4）。
- **多单元链接已接线**：`tools/link.sh` 按给出顺序编译（最后一个为根），`main.yak` 每单元产出 `.obj` + `.iface` 并加载前序单元 `.iface` 建立 `DependencySet`。位置参数 2 下传单元角色：仅根单元为 `root`、其余为 `dep`；`main.yak` 只在根单元把 `main()` 的 DefId 交给 `link_names::build` 产出固定入口别名 `yak$entry`，依赖单元的 `entry_def` 恒为 0，且若定义无参 `main` 先以中文诊断结构化拒绝，避免两个对象同时定义同名全局入口。`link_names::build` 遍历模块内的 `0x91 call_far`（145）指令，按 `import_symbol_def(dep, export_id)` 合成内部 `u64` 键（高 32 位为非零依赖编号，低 32 位为完整导出编号）作为 `LinkSymbol.def`，再由 `DependencySet` 中对应依赖模块名生成 `yak$<依赖模块>$f<ExportId>` 的 kind 1 未定义外部符号；`coff.yak` 的 `lower_inst_call` 用同一个合成键记录 `CallSite.symbol`，COFF 重定位仍只写入实际发射的零基符号表序号。逆序或缺依赖由前端 N-2 拒绝，摘要损坏由 `load_interface` 报 `E7012` 并拒绝提交产物。
- **多单元编排的当前边界**：依赖顺序仍由命令行显式给出，`tools/link.sh` 不解析 `import` 图自动形成拓扑序，也不检测循环依赖 N-5（`spec/proc/build.md` 3.1/3.3、`spec/lang/module.md` 7.1）；脚本把前序单元的 `.iface` 作为候选传入，驱动只对源码直接依赖建立 ImportRef。编译驱动 `main.yak` 只调用 `coff::emit_object` 产出 `.obj` 与 `.iface`，尚未把 `DependencySet` 写入 YSM 依赖节，也未由编译入口产出 `.ysm`。已接通的多单元链接完成判据是「真实两单元程序经同一入口链接并运行、依赖顺序/导出符号/`.iface` 摘要校验都参与」，不含上述完整构建编排。
- 数据符号（kind 2）已实际发射：每个静态条目生成 `$s<下标>` 符号，节号 2、存储类 STATIC、值等于该条目在 `.rdata` 中的偏移。
- 泛型实例名 `yak$<module>$f<ExportId>$i<digest>` 依赖尚未进入 T1 的泛型实例化，
  当前不产出。
- 目标只支持 `coff::profile_win64_pe()`；其它 profile 由 emit 拒绝为 E80-05。

## 产物确定性

- 规格的定点门禁只要求 `.ysm` 与 `.obj` 逐字节一致（`spec/proc/fixpoint.md` 2.3、3.1–3.3）。
  本目录产出的 `.obj` 由 `emit_object` 确定性装配，`tools/test_link_e2e.sh` 用两次独立
  发射做逐字节比较；`.ysm` 的确定性由 YSM 模块自身覆盖，不在本目录职责内。
- `.exe` 不是定点门禁的比对对象。PE COFF 头的 TimeDateStamp 与 Optional Header 的
  CheckSum 默认取链接时刻，同一输入的两次链接会因此不同。`tools/link.sh` 显式传入
  GNU ld 的 `-Wl,--no-insert-timestamp` 关闭时间戳写入，使 `.exe` 在重复链接时可逐字节
  复现；这是为保证可复验而加的工程约束，不是规格对 `.exe` 的要求。
- 若工具链换成 lld，需要改用其等价开关（lld-link 的 `/Brepro` 或 `/timestamp:0`，
  MinGW 风格的 lld 驱动沿用 `--no-insert-timestamp`），不能假设换链接器后 `.exe`
  仍然确定。需要跨工具链比较时，应以 `.obj` 而非 `.exe` 为证据。

## 使用

```
# 发射对象并链接运行时，运行后检查退出码
tools/link.sh examples/exit_code.yak --expect-exit 42

# 只发射与链接，不运行
tools/link.sh examples/exit_code.yak --no-run

# 多单元：依赖单元在前，根单元在后，跨单元调用经 .iface 与 call_far 贯通
tools/link.sh examples/multi_dep.yak examples/multi_root.yak --expect-exit 42

# 构建门禁指定本次新构建的种子解释器（YAK_SEED_BIN，默认 ./seed/out/yak-seed.exe），
# 验证当前源码而非上次安装的旧二进制
YAK_SEED_BIN=<新构建的 yak-seed.exe> tools/link.sh examples/exit_code.yak --expect-exit 42

# 链接阶段端到端测试（需要 MSYS2 UCRT64 的 gcc）
bash tools/test_link_e2e.sh
```
