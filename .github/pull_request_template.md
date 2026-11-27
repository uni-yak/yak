## 变更说明

<!-- 简要说明本次 PR 的目的、关联规格或问题背景 -->

## 变更内容

<!-- 列出主要改动点 -->

## 验证记录

- [ ] 已运行相关定向测试与 `python tools/audit_spec.py`
- [ ] 修改 `spec/lang/symbol.def`、`spec/lang/lex.md` 或 `spec/proc/error.def` 时已同步生成表并通过 `--check`
- [ ] 修改脚本时已通过 `python tools/shell_contract.py --strict`
- [ ] 源码注释均为中文，且不含任务项编号或 `TODO` / `FIXME` 标记

---

> **PR 标题格式建议**（合并采用 Squash，PR 标题将作为 `main` 最终 commit 消息并进入 Release 变更列表）：
>
> 采用 [Conventional Commits](https://www.conventionalcommits.org) 风格，例如：
> - `feat(check): ...`
> - `fix(emit): ...`
> - `docs(spec): ...`
> - `test(gate): ...`
> - `ci: ...`
>
> 正式版本号由维护者在完整验收通过后通过受保护标签 `vX.Y.Z`（或 `vX.Y.Z-rc.N`）确定，不由 PR 标题自动递增。
