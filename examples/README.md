# examples

## 职责

语言示例，面向展示与手工验证：[hello](hello.yak) 展示最小兼容基座；[echo](echo.yak) 展示通过 [标准流模块](../pkg/io/README.md) 逐块转发输入；[lines](lines.yak) 仅在 EOF 后输出 LF 字节计数，末尾没有 LF 的片段不计。原生构建命令见 [快速开始](../README.md#快速开始)；构建 `lines` 时将回显示例的源文件替换为 [lines.yak](lines.yak)。

## 约定

- 一例一特性，代码尽量短。
- 示例必须能在当前实现的编译器上实际运行，不能超前于 `../spec/lang/` 的已确认规格。
- 示例产物输出至 `../out/exe/`，源码目录保持干净。
