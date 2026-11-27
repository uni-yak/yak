# Yak Language Extension（CodeBuddy CN / VS Code）

面向 **CodeBuddy CN** 与 **VS Code** 的 Yak 语言官方扩展，提供：

- **词法级语法高亮**（`syntaxes/yak.tmLanguage.json`，严格对齐 `spec/lang/lex.md` 与 `spec/lang/symbol.def`）：支持嵌套块注释、保留字与占位字、`:Read`/`:Write`/`:ReadWrite` 能力修饰、`@` 原语与注解、`#callable` 零分配名、整型进制与后缀、字符串/字符转义及非法转义标红。
- **语言编辑配置**（`language-configuration.json`）：注释切换、括号自动闭合与高亮、自动缩进与词边界。
- **完整 Yak LSP 支持**（内置 Win64 `yak_lsp.exe`）：实时诊断、增量同步、同文件/跨文件跳转定义与悬停、`.` 结构体字段与 `::` 枚举/模块导出补全、语义着色、文档大纲与代码折叠、工作区符号、文档格式化、DefId 安全重命名、`E1018`/`E4009`/`E6201`/`E4002` 自动导入快速修复。

## 一键构建与安装到本机 CodeBuddy CN

在仓库根目录执行：

```powershell
python editors/vscode/scripts/build_vsix.py --install-codebuddy
```

脚本会自动：
1. 复制最新构建的 `yak_lsp.exe` 到 `editors/vscode/bin/yak_lsp.exe`；
2. 确认 `editors/vscode/node_modules` 依赖已安装；
3. 生成标准 `.vsix` 安装包（`editors/vscode/dist/yak-lang-0.1.0.vsix`）；
4. 调用本机 `I:\Program\CodeBuddy CN\bin\buddycn.cmd --install-extension` 完成安装。

## 常用配置项

- `yak.lsp.enabled`：是否启用 Yak LSP（默认 `true`）。
- `yak.lsp.path`：自定义 `yak_lsp.exe` 路径；留空时默认使用扩展内置 `bin/yak_lsp.exe`。
- `yak.semanticHighlighting.enabled`：是否叠加 LSP 语义着色（默认 `true`）。
- `yak.workspace.maxFiles`：工作区同步最大文件数（1–64，默认 `64`）。
- `yak.workspace.exclude`：扫描工作区 `.yak` 文件时的忽略 glob 列表。
- `yak.trace.server`：协议消息追踪级别（`off` / `messages` / `verbose`）。
