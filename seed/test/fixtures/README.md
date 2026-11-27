# 测试夹具

本目录存放 seed 回归用例显式登记的模块依赖和输入数据，不包含构建产物。

- `helper.yak`：公开函数、私有函数和模块常量。
- `point.yak`：跨模块名义类型、返回值及引用参数。
- `recovery.yak`：跨模块恢复回调。
- `cycle_a.yak`、`cycle_b.yak`：依赖环负例。
- `bad_main.yak`：依赖模块定义 main 的负例。
- `input.txt`、`中文.txt`：相同内容的普通和 Unicode 路径输入。
- `bytes.bin`：包含 NUL、非 UTF-8 字节与换行的二进制输入。

所有授权、预期输出及失败判定均在父目录的 t*.yak 中登记；夹具本身不作为成功用例自动执行。
