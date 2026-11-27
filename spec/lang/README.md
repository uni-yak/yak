# spec/lang

## 职责

定义 **Yak 语言本身**：语法、语义、类型、所有权、模块与外部接口。与编译器实现、目标平台无关。

## 结构

- `base.md` —— 最小语法基座：核心形态全集（编写 `min` 所用的语言）
- `sugar.md` —— 脱糖规约：每条高阶语法到基座形态的唯一脱糖规则
- `lex.md` —— 词法：字符、记号、编码基线
- `parse.md` —— 语法结构与解析规则
- `name.md` —— 名字、作用域与可见性
- `symbol.md` —— 符号体系：分域 id、固有符号分区、接口桥接、二进制产物与反查
- `symbol.def` —— 固有 `BuiltinId` 配置源：显式 slot、阶段、kind 与派生项
- `owner.md` —— 所有权、借用、析构
- `effect.md` —— 效应标注与传播
- `generic.md` —— 泛型与编译期单态化
- `module.md` —— 模块与依赖
- `const.md` —— 常量与编译期求值
- `foreign.md` —— 外部接口（C-ABI 桥）
- `layout.md` —— 类型布局：字段偏移、大小、对齐
- `asm.md` —— 内联汇编：语法、约束、效应标注（full）
- `atomic.md` —— 并发原子操作、五级内存序与线程局部存储（full）
- `unsafe.md` —— 不安全块、MMIO、非对齐、bitcast 与未初始化内存契约（full）
- `type/` —— 数据类型：一类型一独立文档

## 边界

- 与 `spec/ir/`：`lang` 规定语言语义，`ir` 规定编译中间表示。
- 与 `spec/target/`：`lang/layout.md` 只定义命名对象布局 profile；具体目标与调用 ABI 对 profile 的绑定由 `spec/target/` 规定。除此以外，`lang` 不描述平台事实。 
- 与 `compiler/`：本目录是编译器要满足的契约，不是编译器的设计说明。

## 分级约定

- `base` 级文档描述最小基座，`min` 只实现这些。
- `full` 级文档描述高阶特性，由 `sugar.md` 规定其到基座的脱糖。
- 各编译器的支持状态记录于 `spec/index.md` 矩阵。
