# shell

## 元信息

- 名称：shell（可移植 shell 白名单）
- 级别：流程
- 拒绝形态类别：门禁断言
- 状态：确认
- 依赖：`build.md`、`../../versions.lock`

## 一、范围

1.1 本文规定构建脚本允许使用的 shell 操作白名单，使同一脚本在 MSYS2 与 Linux CI 行为一致。

1.2 白名单外操作为拒绝形态（`build.md` B-1）。

## 二、允许操作

| 类别 | 允许 | 说明 |
|:---|:---|:---|
| shell | bash ≥ 5 | 版本钉死 `versions.lock` |
| 文本工具 | coreutils（`cat` `cp` `mv` `rm` `mkdir` `rmdir` `sha256sum` `cmp` `diff` `xxd` `od` `timeout` `tr` `cut` `sort` `head` `tail` `wc`） | 版本钉死 |
| 汇编 / 链接 | binutils `as`、`ld` 与同目标 GCC 驱动、Clang | 版本钉死；GCC 的目标三元组与实际选择的链接器须可核对；Clang 仅用于 Seed / 运行时的同版本复现与双编译器行为交叉验证，不替换规范 GCC 基线 |
| 门禁生成与审计 | `python` | 只用于仓库自带的确定性生成器、静态审计与单元测试；版本在 `versions.lock` 钉死，不进入 Yak 编译运行期或产物 |
| T1 构建输入 | 宿主可运行的 Seed、Windows x64 运行时对象 | 按 `build.md` 2.4 选择；Linux 执行冻结 PE Seed 时用 `YAK_PE_RUNNER`，构建入口不执行生成的目标程序 |
| 运行验证 | 原生执行或显式 `YAK_PE_RUNNER` | 只在需要验证目标程序时调用 |
| 变量 | 局部变量、`export LC_ALL=C TZ=UTC` | 禁止依赖宿主 locale / 时区 |
| 路径 | 相对路径 | 禁止绝对 Windows 路径硬编码 |
| 条件 | `if` / `case` / `for` / `while` | 确定性遍历，固定顺序 |
| 重定向 | `>` `>>` `<` `2>` | |
| 管道 | `\|` | |

## 三、禁止操作与替代

| 禁止 | 原因 | 可移植替代 |
|:---|:---|:---|
| `/dev/full` | Linux 专有，MSYS2 无 | 只读文件上写 + 断言失败（双平台同语义） |
| `/proc/self/fd` | Linux 专有 | 临时文件 `O_CREAT\|O_EXCL` 独占创建 |
| `flock` bash 文件锁 | NTFS 上不可靠 | `mkdir lock.dir` 原子锁（成功者持锁） |
| `mv` 覆盖在用文件 | MSYS2 失败 | 先删后移 + 回滚副本 |
| 符号链接 | NTFS 行为不一致 | 禁止；用拷贝 |
| `find` 复杂表达式 | 跨平台遍历序不一致 | 固定顺序显式列举或 `sort` 后处理 |

## 四、原子性与回滚

4.1 原子安装：`mkdir lock.dir` 持锁 → 写 `tmp/` → `mv` 到 `out/` → `rmdir lock.dir`。

4.2 回滚：任一步失败 → 删除已写产物 → `rmdir lock.dir` → 退出非零。

4.3 退出码：0 成功；非零失败，不写出 `out/` 产物。

## 五、确定性

5.1 遍历顺序固定：`sort` 后处理；禁止依赖 `readdir` 顺序。

5.2 `sha256sum` 输出按文件名升序比对。

5.3 脚本不得含时间戳、宿主名或随机数。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| SH-1 | 使用白名单外操作 |
| SH-2 | 依赖 `readdir` 顺序或未排序遍历 |
| SH-3 | 脚本含时间戳 / 宿主名 / 随机数 |
| SH-4 | 绝对 Windows 路径硬编码 |

## 关联

- 构建：`build.md`
- 版本锁定：`../../versions.lock`
- 固定点：`fixpoint.md`
