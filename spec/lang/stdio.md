# 标准流 io

## 元信息

- 名称：stdio
- 级别：base
- 状态：草案
- 依赖：`foreign.md`、`type/slice.md`、`type/struct.md`、`type/u32.md`、`type/bool.md`、`../proc/gate.md`

## 一、公开接口

```yak
export struct ReadResult { count: u32, ok: bool }
export function #read(buf: &[u8]:ReadWrite): ReadResult
export function #write(data: &[u8]): bool
```

1.1 模块 `io` 不分配堆内存；仅依赖 [标准流状态服务](foreign.md#三base-期服务集)。本接口不适用于冻结 Seed。

1.2 `read` 成功令 `ok` 为 `true`，并令 `count` 为写入缓冲区的字节数。非空缓冲区上，`count > 0` 是有效输入，即使少于缓冲区长度也不表示输入结束；只有成功且 `count == 0` 才表示输入结束。空缓冲区成功返回 0，不探测 EOF。调用方只能将成功结果的前 `count` 字节作为本次读取的数据。系统错误令 `ok` 为 `false`、`count` 为 0；缓冲区内容不得作为有效输入使用。

1.3 `write` 仅在全部字节交付给宿主后返回 `true`。系统错误或零进展返回 `false`；可能已有前缀交付给宿主，不回滚也不返回已交付的长度；调用方不得依赖重发整段而不产生重复字节。空切片写入成功且不访问宿主。

1.4 系统 I/O 失败由调用方处理；不写标准错误、不产生服务陷阱、不隐式退出。

## 二、验收

2.1 Win64 PE 与 Linux x86_64 ELF 均须经独立 Yak 单元导入 `io`、调用其接口并运行用例。验收覆盖正常回显、短读、EOF、跨块且仅消费有效字节的输入、空切片、不可读的标准输入、不可写的标准输出和断管。

2.2 旧签名的行为另由 [外部接口规格](foreign.md) 第三节规定；状态服务的签名错误按其 F-1 拒绝，不接受仅凭服务名的匹配。
