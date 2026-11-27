# seed

## 职责与阶段

`yak-seed` 是 C 编写的树遍历解释器，用于 T1 点火阶段解释执行 `compiler/min` 的 Yak 源码。它不生成 `.ysm`、`.iface` 或 `.obj`；目标代码由 min 编译器负责。

**退役状态（依据 [seed 规格](../spec/proc/seed.md) 3.1）**：T2 三遍固定点（`C2 == C3`）与双目标（Win64 PE + Linux x86-64 ELF，131/131 原生对拍）已在可信 GitHub CI 完整归档（Run `45997051559`，固定点收据见 [t2_fixpoint_receipt.json](../test/gate/t2_fixpoint_receipt.json)，预发布草稿标签 `v0.1.0-rc.1`）。`yak-seed` 现已退役：**不再更新语言语义，仅作为 T0/T1 历史点火与冷启动归档审计证据保留**；冻结二进制 `yak-seed.exe` 不入库，仅存留于仓库 Release `seed-9abd162e2713748ffb62d471e39c5703abb733b607bb6431dccef1e7b9fe30ec` 供冷启动审计复现。后续待办见 [TODO](../TODO.md)。

## 构建与验证

在 MSYS2 UCRT64 中执行：

```bash
bash seed/build.sh
bash seed/test/run_tests.sh
```

PowerShell 回归入口：

```powershell
./seed/test/run_tests.ps1
```

唯一正式产物为 `seed/out/yak-seed.exe`，冻结登记为 `seed/frozen.txt`。旧入口和上一正式版本保留于 `seed/out/archive/` 作审计，不参与构建。构建使用 versions.lock 的 GCC 与 Clang 版本，启用零警告门禁；每个编译器各构建两次并比较 SHA-256，再执行原生分配/回滚测试与全部 Yak 正负例，最后逐例比较两个编译器的 stdout、stderr 和退出码。行为一致不能替代测试预期，也不构成完整的编译器信任攻击证明。

全部检查成功后才替换正式产物和冻结登记；提交阶段失败恢复上一版本。构建锁在正常退出、失败和可捕获信号上释放。失败日志保留在 `seed/tmp/build/`；成功清除此目录。当前冻结记录末条为 SHA-256 `9abd162e2713748ffb62d471e39c5703abb733b607bb6431dccef1e7b9fe30ec`，对应 UCRT64 全量重基线的 434 个 Yak 回归与 375 项链接端到端检查；记录见 [证据](../test/gate/EVIDENCE.md)。

## 运行与受限宿主

```text
yak-seed ENTRY [--module NAME=PATH] [--input NAME=PATH] [--output NAME=PATH] [-- ARGS...]
```

模块和文件只按宿主显式登记的名称解析；无隐式搜索路径。参数、文件读写、输出提交和失败回滚的唯一契约见 [host 规格](../spec/proc/host.md)。该规格明确允许 seed 中的参考实现，仍保持草案状态，不代表 min/full 目标 ABI 已确认。

## 解释能力与边界

当前回归覆盖整数宽度及有符号/无符号运算、布尔/字符/UTF-8 文本、函数与静态函数引用、结构体、定长/动态数组、引用及切片、字段/索引读写、所有权转移、借用区域、out 槽位、错误载体恢复，以及可空载体的基本操作与显式嵌套。语义真源为 spec；具体证据和范围见 [测试说明](test/README.md)。

词法期拒绝 `#` 后的关键字、保留占位字、非 ASCII 名字与单独的 `_`，不与换行配对的回车，以及文件末尾缺少或多于一个换行（CRLF 算一个）。运行期检查覆盖枚举载荷构造、`match` 绑定与丢弃、活跃载荷比较、带标签循环跳转，以及普通 `return` 的已定型值与声明返回类型是否一致。`if` 条件非 `bool` 与赋值目标不可写只在执行到该语句时陷阱，未执行的函数不报；这类静态检查、静态所有权、控制流合流、ErrorSet 子集和 handler 表静态诊断仍属于 min。普通联合、泛型、闭包、浮点和裸指针尚未激活，相关输入必须明确拒绝。

可空和恢复操作是 seed 的有限 full 参考能力，不等于 min 已支持 full。S-9 子节已统一回草案状态；参考回归不自动升级任何语言规格。结构审计和待冻结条目见 `spec/audit.json`。

## 容量与预算

- 每模块最多 256 项顶层声明，每块最多 256 条语句；超限明确陷阱，不截断。
- 调用/参数/导入路径段最多 16 项，place 解析递归深度最多 16；数组字面量、结构体字段、enum 标签和 match 臂最多 64 项；ErrorSet 最多 32 项。
- 单源码最多 64 MiB，解析和调用深度上限为 512，Seed 每个进程的求值步数上限为 2 亿。Windows 产物预留 16 MiB 宿主栈，以容纳已登记的解释深度；它不计入有效载荷分配预算。
- 内存预算默认 256 MiB，可用严格正整数 `YAK_SEED_MEM` 覆盖。预算统计受控分配的有效载荷，不等于进程 RSS。
- 陷阱打印源码位置，清理活动帧、受控分配和本次未提交输出后非零退出。

源码组织见 [src](src/README.md)。冻结哈希是当前参考实现的构建基线，不是整个语言规格的完成证明。
