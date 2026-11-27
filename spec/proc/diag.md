# diag

## 元信息

- 名称：diag（诊断协议）
- 级别：流程
- 拒绝形态类别：门禁断言
- 状态：草案
- 依赖：`error.md`、`../lang/symbol.md`、`../lang/name.md`、`../ir/ysm.md`

## 一、范围

1.1 本文规定诊断的内部表示、JSONL 输出协议与离线渲染的反查机制。

1.2 诊断是编译期产物；运行期不存在符号表（`symbol.md` 1.8、7.2）。运行期错误经 `trap`（`../ir/mir.md` 4.13）走不正常完成路径，不涉及反查。

## 二、内部表示

2.1 诊断内部只持有：`ErrorCode`(u16)、源位置、类型 / 符号 id 与结构化参数。

2.2 源位置由单元和源文件内的半开字节范围标识，`offset` 为起点，`length` 为字节长度。跨度字段及单 token 限制见 [词法规格](../lang/lex.md) 9.1。

2.3 符号引用：`DefId`、`BuiltinId`、`ImportRef`、`FieldId` / `VariantId`、`LocalId`——按 `symbol.md` 九节域宽度；不得保留 `NameId` / `ScopeId` 作为引用身份。

## 三、JSONL 协议

3.1 `--diag=jsonl` 将单向 JSONL 写给 IDE / CI；默认构建不生成诊断文件（`symbol.md` 7.6）。

3.2 输出为 UTF-8，每条记录以 LF 结束。每行是一个 JSON 对象，字段固定如下：

```text
{
  "unit"    : string,        // 单元模块名
  "code"    : number,        // ErrorCode
  "severity": "error" | "warning" | "info",
  "span"    : { "off": number, "len": number },
  "refs"    : [ Ref, ... ],  // 符号引用（id 域 + 值）
  "args"    : { ... }        // 结构化参数
}
```

3.3 `Ref` 对象只含 `kind` 和 `id`。`import` 的 `id` 为 `[DependencyId:u16, ExportId:u32]`，`def`、`local` 的 `id` 为 `u32`，`builtin`、`field`、`variant` 的 `id` 为 `u16`。全部使用 JSON 无符号整数值。`unit` 是规范模块名。

3.4 JSONL 是输出协议，不是编译器输入、模块接口或缓存格式（`symbol.md` 7.6）。

3.5 当前批处理协议的 `args` 固定为 `{}`。带未登记参数的内部诊断无法编码，写出入口须先完成校验，再写记录。扩展参数字段须先登记编码与验证规则。

## 四、离线渲染（反查）

4.1 渲染器加载单元 `.sym`（`symbol.md` 7.4）与源文件，将 id 反查为 UTF-8 名称字节。

4.2 反查步骤：

| 步 | 操作 |
|:---|:---|
| 1 | 由 `DefId` / `ImportRef` 等定位 `.sym` 条目 |
| 2 | 条目给出 `NameRef(offset, len)` |
| 3 | 切 arena 字节 `offset .. offset+len` |
| 4 | UTF-8 解码为名称字符串 |

4.3 跨单元名称经依赖 `.iface` 的 `ExportId` 反查（`symbol.md` 7.1）。

4.4 行 / 列由 `span.off` 反查源文件（源文件是字符串真源之一）。

4.5 反查在内存完成，不先写文件再读回（`symbol.md` 7.1）。

## 五、确定性

5.1 同一输入在同一目标 profile 下产生相同诊断集合（`gate.md` 2.1）。

5.2 单元内先按 `offset`、再按 `code` 升序。同键保持收集次序。内部合并多单元缓冲时，先按单元编号排序。

5.3 诊断不得含宿主指针、时间或绝对路径。

## 拒绝形态

| 编号 | 条件 |
|:---|:---|
| D-1 | 诊断保留 `NameId` / `ScopeId` 作为引用身份 |
| D-2 | JSONL 含宿主指针 / 时间 / 绝对路径 |
| D-3 | 诊断顺序不确定 |

## 关联

- 错误码：`error.md`、`error.def`
- 符号反查：`../lang/symbol.md` 七
- 名字解析：`../lang/name.md`
- 审计镜像：`../ir/ysm.md`
- 门禁：`gate.md`
