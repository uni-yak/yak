# ptr

## 元信息

- 名称：ptr / cptr（裸指针，双形）
- 级别：full
- 状态：草案
- 依赖：`../unsafe.md`、`../foreign.md`、`../layout.md`、`../atomic.md`、`../../target/abi-win.md`、`../../target/abi-linux.md`

## 定义

- `ptr<T>`：可写裸指针，指向类型 `T` 的单个对象或不定长存储。
- `cptr<T>`：只读裸指针，附加"禁止通过本指针写"的点内承诺。
- 内存布局：平台指针宽度（x86_64 为 8 字节），单槽值。
- 默认值：无固有默认；可空。
- `T` 必须为已登记完整类型；不得为视图类型、载体或 `void`。
- 词法地位：`ptr`、`cptr` 为上下文关键字，仅在类型位且后随 `<` 时识别；用户不得定义同名类型。
- 与能力系统的关系：**能力是别名词汇表，指针在其外**；`ptr<T>:Cap`、`cptr<T>:Cap` 一律拒绝。

## 字面量

- 无指针字面量。
- `null` 在预期 `ptr<T>` / `cptr<T>` 的上下文中合法（`null` 上下文于 full 期扩展至本类型）。

## 操作

以下操作仅限 `unsafe` 块内；`foreign` 签名内自动获得：

- 解引用读：`*p`（要求地址非空、满足 `align(T)` 且指向有效已初始化 `T`）。
- 解引用写：`*p = e`（仅 `ptr<T>`，要求同上）。
- 位拷贝：`@copy(p)` 合法（任何上下文合法，指针本身为 `Copy`）。
- 指针算术与比较：延续 Yak `@`-原语风格，提供 `@ptr_add(p, count)`、`@ptr_sub(p, count)`（按 `stride(T)` 步进，乘积溢出或 `stride(T)==0` 按 P-10 拒绝）与 `@ptr_diff(a, b)`（返回两同类型指针的元素差）；地址相等/序比较（`==`/`!=`/`<`/`<=`/`>`/`>=`）作用于同类型指针。
- 易失与非对齐访问（MMIO / `@packed` 字段）：`@volatile_load(p)`、`@volatile_store(p, v)`、`@unaligned_load(p)`、`@unaligned_store(p, v)`（写形式仅接受 `ptr<T>`，对 `cptr<T>` 写按 P-9 拒绝；详见 `../unsafe.md` 三）。
- 未初始化内存提交：`@uninit_write(p, v)` 与 `@assume_init(p)`（仅 `ptr<T>`，见 `../unsafe.md` 三）。
- 原子访问：指向自然对齐标量的 `ptr<T>` / `cptr<T>` 可传入 `../atomic.md` 的 `@atomic_*` 原语。
- 位模式重解释：`@bitcast(e, TargetType)` 支持等宽标量/指针间的显式位重解释（`../unsafe.md` 三）。
- 空值判定：`@is_null(p)`（`../symbol.def` 0x00A，返回 `bool`，无需 `unsafe`）。

## 转换

- `ptr<T>` → `cptr<T>`：隐式收窄，任何上下文合法。
- `cptr<T>` → `ptr<T>`：显式转换，仅限 `unsafe` 块内。
- 指针与 `&T` / `&[T]` 之间：显式转换，仅限 `unsafe` 块内；借用转指针不转移检查责任，原借用仍受检查器管辖。
- 整数 ↔ 指针：显式 `as` 转换（支持 `u64` 及 full 指针宽度整数 `usize`），仅限 `unsafe` 块内，登记入 `as` 白名单（full 期扩充）；隐式转换拒绝。
- 不同元素类型指针之间：`ptr<A>` ↔ `ptr<B>`、`cptr<A>` ↔ `cptr<B>` 须显式转换且仅限 `unsafe` 块内。
- FFI 映射：C `const T*` ↔ `cptr<T>`，C `T*` ↔ `ptr<T>`；C `void*` / `const void*` 不映射为 `ptr<void>`，由 `foreign.md` 契约登记不透明字节指针或 opaque 句柄类型。物理映射登记于 `../../target/abi-win.md` / `abi-linux.md`。

## 所有权

- 不拥有目标：不触发析构，无 `@move` / `@drop` 语义。
- `@copy` 合法：位拷贝产生独立指针值，指向同一目标。
- 不参与能力系统；单写排他、能力型变、生命周期规则均不适用、不执行。
- 不受视图位置限制：可作 struct 字段、数组 / 元组元素、泛型实参、`foreign` 参数。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| P-1 | `ptr<T>:Cap`、`cptr<T>:Cap`（能力后缀） |
| P-2 | 对 `cptr<T>` 解引用赋值 |
| P-3 | 在非 `unsafe` 且非 `foreign` 上下文构造、解引用或转换指针 |
| P-4 | `cptr` → `ptr` 隐式转换 |
| P-5 | `T` 为视图类型、载体或 `void` |
| P-6 | 用户定义名为 `ptr` / `cptr` 的类型 |
| P-7 | 整数与指针之间的隐式转换 |
| P-8 | 将指针作为 owning 值 `@move`、`@drop` 或登记克隆契约 |
| P-9 | 对 `cptr<T>` 执行 `@volatile_store`、`@unaligned_store` 或 `@uninit_write`，或在编译期可证未对齐指针上执行普通解引用 |
| P-10 | 指针算术（`@ptr_add`/`@ptr_sub`/`@ptr_diff`）目标步长为 0 或偏移乘积溢出 |

## 关联

- unsafe 门禁：`../unsafe.md`
- FFI 契约：`../foreign.md`
- ABI 映射：`../../target/abi-win.md`、`../../target/abi-linux.md`
- 内联汇编内存效应声明：`../asm.md`（效应词汇与指针命名分立，各自可执行）
