# array

## 元信息

- 名称：array（`[T; N]` 定长数组与 `T[]` 动态数组）
- 级别：base
- 状态：草案
- 依赖：`../base.md`、`../parse.md`、`../layout.md`、`../owner.md`、`../symbol.md`、`slice.md`、`alloc-error.md`

## 定义

- `[T; N]`：定长数组，owning；`N` 为编译期正整数常量，是类型身份一部分。
  - `align = align(T)`；`size = N * stride(T)`；元素 `i` 偏移 `i * stride(T)`（`layout.md` 5.1、5.3）。
  - `N = 0` 为拒绝形态 LY-2；`stride(T) = 0` 为拒绝形态 LY-2。
- `T[]`：动态数组，owning；头部 `{ptr:u64, len:u64, cap:u64}`，`size = 24`，`align = 8`（`layout.md` 5.4）。
  - `len <= cap`；`cap * stride(T)` 不得溢出；空数组规范头部 `{0, 0, 0}`（`layout.md` 5.5）。
  - `cap > 0` 时 `ptr` 非空、`align(T)` 对齐、指向至少 `cap * stride(T)` 字节有效分配（`layout.md` 5.6）。
  - 非 Copy；编译器生成析构（`base.md` T-8）。
- 默认值：无；绑定必须显式初始化。

## 字面量

- 形式：数组构造表达式产生式见 `../parse.md`。
- `[]` 在预期类型为 `T[]` 时构造规范空头部 `{ptr=0, len=0, cap=0}`，不产生堆分配。
- 非空 `T[]` 字面量 `[e0, ...]` 产生初始堆缓冲，是增操作；`#` 函数可达调用图中禁止。`[T; N]` 定长数组字面量为栈构造，不是增操作。
- 拒绝：`[T; 0]`（LY-2）；零步长元素类型构造 `T[]`（LY-2）。

## 操作

- 允许：索引 `a[i]`（编译期可证越界为拒绝；运行期越界进入不正常完成路径，`base.md` 7.13）。
- 允许：`@push(目标: &T[]:ReadWrite, 值: T): void!AllocError`——向动态数组追加元素；失败返回 `AllocError::OutOfMemory`（`alloc-error.md`）。
- 允许：`@clone`、`@drop`、`@move`（按所有权规则）。
- 允许：取切片 `&a[a..b]` 产生 `&[T]`（`..=` 为 full；`slice.md`）。
- 禁止：隐式 `==` / `!=`；隐式转换；`[T; N]` 与 `T[]` 之间无隐式转换。

### 实施边界（种子期）

- `@push` 的降级形态由 `ir/mir.md` 4.14 的 178 承载：取头地址、元素槽地址与元素字节尺寸，调用运行时 `yak_rt_push`；运行时按 `cap == 0 ? 4 : cap * 2` 扩容，复制旧元素后释放旧缓冲，失败返回 1 并由调用点写入 `AllocError::OutOfMemory`。
- Copy 元素按值复制；非 Copy 元素按整值交接，已有 owning 绑定须显式移动，不能从投影部分移动（`../owner.md` 2.3、2.5）。失败时原数组不变，由操作析构已经接收的非 Copy 元素；成功时由数组取得析构责任。
- 索引读取头内 `len` 做运行期越界检查（含负索引），越界进入 trap 路径；跨步取元素类型尺寸。
- 函数出口析构对 `T[]` 调用 `yak_rt_free(ptr, cap * stride(T))`，`ptr == 0` 时跳过；成员含动态数组的本地聚合按字段偏移递归释放。
- `@clone` 的动态数组子集见 `owner.md` 的实施边界。

## 转换

- 隐式：无
- 显式 `as`：无
- 溢出行为：`cap * stride(T)` 只在运行期计算，溢出按分配失败处理，`@push` 返回 `AllocError::OutOfMemory`；它不是编译期拒绝形态。`[T; N]` 的总大小 `N * stride(T)` 在布局期计算，溢出为 LY-1。

## 所有权

- 复制 / 移动：`[T; N]` Copy 当且仅当 `T` 为 Copy；`T[]` 始终非 Copy（`base.md` 7.9）。
- 借用形态：`&[T; N]:Read` / `&[T; N]:ReadWrite`；`&T[]:Read` / `&T[]:ReadWrite`。
- 析构：非 Copy 数组在作用域出口按索引逆序析构元素（`owner.md` 6.2）；`T[]` 由编译器生成析构释放堆。

## 拒绝形态

| 编号 | 条件 | 码 |
|:---|:---|:---|
| LY-1 | `[T; N]` 的总大小 `N * stride(T)` 溢出 u64 | E5501 |
| LY-2 | `[T; 0]` 或零步长 `T[]` 元素 | E5502 |
| — | 运行期索引越界（进入不正常完成路径） | — |

## 关联

- 布局：`../layout.md` 五
- 所有权：`../owner.md` 二、五、六
- 切片：`slice.md`
- 失败载体：`alloc-error.md`
- `@push`：`../symbol.md` functions 分区
