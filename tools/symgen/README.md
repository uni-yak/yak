# tools/symgen

固有符号配置真源为 `spec/lang/symbol.def`。本目录目前只实现 min 参考词法器所需的静态分派生成，不宣称完整 ABI、派生常量、enum 成员和接口元数据生成器已完成。

## 词法表

```text
python tools/symgen/lex_tables.py
python tools/symgen/lex_tables.py --check
python tools/symgen/lex_tables.py --check-artifact compiler/min/out/main.exe
```

生成命令读取 symbol.def 的直接条目和 lex.md 的关键字闭集，输出 `compiler/min/src/lex/lextables.yak`。写出前检查分区、直接条目类别、依赖顺序、重复名称、码位与声明语法。分区越界发 E7003，普通模块名或占用保留槽发 E7004，重登关键字或占位字发 E7005，登记普通模块函数发 E7016，隐式码槽、执行式声明与未登记派生发 E7017。`--check` 逐字节比对已生成文件，失配时以 E7010 退出并保留文件。

生成结果包含配置摘要。正式构建在编译前核对生成文件，并在发布前校验主编译器与扫描器的 PE 只读节。节内摘要缺失、重复、越界或与配置失配时发 E7010。名称查询采用长度与原始字节比较，不 hash、不分配，也不在运行期解析配置。普通名称的固有类型分派只包含 stage=base；base `enum_variant` 生成 `builtin_variant(host, name)` 静态分派；@ 分派可识别保留的 full 编号，但 min 必须拒绝激活它们。普通用户名称和 foreign 服务不成为固有符号。

## 未实现部分

完整 symgen 的 derive/value_block、full 层 enum 成员元数据、保留区覆盖与 ABI 元数据校验/生成仍待实现。词法表生成器只验证其所消费的直接登记与 base `enum_variant`，不代替完整配置审计。相关负向门禁为 `tools/test_contracts.py`。
