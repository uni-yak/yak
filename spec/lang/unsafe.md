# unsafe

## 元信息

- 名称：unsafe（不安全块与底层受控操作）
- 级别：full
- 状态：草案
- 依赖：`base.md`、`owner.md`、`layout.md`、`foreign.md`、`asm.md`、`atomic.md`、`type/ptr.md`

## 一、范围

1.1 本文规定 full 层 `unsafe` 块与 `unsafe function` 的语法边界、受控操作闭集、与所有权/能力检查器的隔离关系，以及内存与表示不变量责任。

1.2 `unsafe` 为 `base.md` 3.3 保留占位字，base 期禁用；本规格只在 full 层激活。

1.3 `unsafe` 是**显式信任边界**，而非关闭类型检查或所有权检查的开关。除第三节列出的受控操作外，所有 Yak 类型规则、借用排他、`out` 槽位状态机与算术溢出检查在 `unsafe` 内保持有效。

## 二、语法形式

```text
UnsafeBlock ::= 'unsafe' Block
UnsafeFn    ::= ['export'] 'unsafe' 'function' CallableName '(' [ParamList] ')' ':' Type Block
```

2.1 `unsafe` 块作为普通语句或块表达式出现，形成独立词法作用域；退出块时按 `owner.md` 第六节逆序析构块内 owning 局部。

2.2 `unsafe function` 声明函数体存在必须由调用方保证的前置不变量：
- 函数体内部默认处于 `unsafe` 上下文，无需重复套写 `unsafe { ... }`（仍可显式缩小块范围以利审计）；
- 调用 `unsafe function` 本身属于受控操作，只能在 `unsafe` 上下文内执行（US-1）；
- `unsafe function` 可与 `#` 无增契约组合写作 `unsafe function #name(...)`，`#` 校验规则仍遵守 `base.md` 5.11 与 `../ir/mir.md` 6.5。

2.3 函数静态引用隔离：`unsafe function` 不得隐式转为安全函数引用 `&function(P): R`（US-5）；安全调用方必须通过显式安全包装函数承担前置不变量检查。

## 三、受控操作闭集

仅下列操作需要在 `unsafe` 上下文内执行（`foreign` 声明签名位对 `ptr<T>` / `cptr<T>` 类型的书写自动放行，`type/ptr.md`）：

1. **裸指针解引用与构造转换**：对 `ptr<T>` / `cptr<T>` 执行 `*p`、`*p = e`、指针算术、`cptr<T>` → `ptr<T>` 转换、视图 `&T`/`&[T]` ↔ 裸指针转换、整数 ↔ 裸指针转换（`type/ptr.md`）。
2. **易失内存访问（MMIO）**：`@volatile_load(p)` 与 `@volatile_store(p, v)`，保证访问不被优化器消除、合并或相对其他易失操作重排。
3. **非对齐内存访问**：`@unaligned_load(p)` 与 `@unaligned_store(p, v)`，允许在未满足 `align(T)` 的地址上按字节安全读写标量或 `@packed` 字段值。
4. **位模式重解释**：`@bitcast(e, TargetType)`，要求 `size(Src) == size(Target)`，按对象位模式原样重解释为目标类型；不执行数值转换或堆分配。
5. **未初始化内存原地提交**：`@uninit_write(p, v)`（向未初始化裸指针目标写入 owning 值且不析构旧值）与 `@assume_init(p)`（声明已初始化并移出 owning 值）。
6. **内联汇编**：调用 `@asm(...)`（`asm.md`）。
7. **开放外部调用与无标签联合读**：调用 full 层开放的外部 C-ABI `foreign` 函数（未持有静态安全证明者，`foreign.md` 七），以及读取无标签 `union` 字段（`layout.md` 9.9）。
8. **调用 `unsafe function`**。

## 四、不变量与不变边界

4.1 **检查器保持有效**：在 `unsafe` 块内，对普通 `&T` / `&T:ReadWrite` 的能力型变、单写排他、生命周期不逃逸、`out` 槽位状态机、整值移动禁止部分移动、以及默认 checked 算术与切片越界检查**全部继续执行**（US-2）。

4.2 **调用方必须维持的语言不变量**（违反即进入未定义行为边界）：
- 裸指针经转换还原为 `&T` / `&[T]` 时，必须非空、对齐满足 `align(T)`、指向已初始化有效表示，且在整个借用活跃期内满足 `Read` 共享或 `ReadWrite` 排他；
- 经 `@bitcast` 或裸指针读入的 `bool`（仅 `0`/`1`）、`char`（非代理对 Unicode 标量）、`enum` / carrier tag 必须落在 `layout.md` 规定的有效表示范围内；
- 经裸指针并发访问同一内存且至少一方为写时，必须经 `atomic.md` 原子原语或显式同步建立 happens-before 关系。

4.3 **与 `#` 无增契约正交**：`unsafe` 本身不影响 `no_alloc` 分类；`@volatile_*`、`@unaligned_*`、`@bitcast`、`@uninit_write` 与 `@assume_init` 均属中性（不增加 Yak 运行时堆分配）。

4.4 **禁止作用的类型**：`@volatile_*`、`@unaligned_*` 与 `@bitcast` 不得作用于视图类型、`void` 或内部 carrier（`T!E`、`T?`、`PlainUnion`）（US-4）。

## 五、拒绝形态

| 编号 | 条件 |
|:---|:---|
| US-1 | 在非 `unsafe` 上下文执行第三节受控操作或调用 `unsafe function` |
| US-2 | 在 `unsafe` 内对普通借用、`out` 槽位或 owning 值违反所有权与能力检查规则 |
| US-3 | `@bitcast` 源类型与目标类型字节大小不等 |
| US-4 | 对视图、`void` 或 carrier 执行 `@volatile_*`、`@unaligned_*` 或 `@bitcast` |
| US-5 | 将 `unsafe function` 直接赋给非 `unsafe` 函数静态引用类型 `&function(P): R` |

## 关联

- 裸指针双形：`type/ptr.md`
- 内联汇编：`asm.md`
- 并发与原子：`atomic.md`
- 外部接口：`foreign.md`
- 布局与有效表示：`layout.md`
- 所有权与能力：`owner.md`
