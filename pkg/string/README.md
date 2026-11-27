# pkg/string

## 职责

字符串类型 `string` 的实现：UTF-8 校验包装、构造、拼接、边界切片、比较、查找。

base 期无 owning 字符串类型，字面量为 `&[u8]`；本模块随 full 层 `string` 类型登记而启用。

## 规格

- 类型规定：`../../spec/lang/type/string.md`
- 所有权规则：`../../spec/lang/owner.md`

## 约定

- UTF-8 编码，按字节偏移定位，切片必须落在字符边界。
- 所有操作必须给出容量超限与越界的明确返回形态。
