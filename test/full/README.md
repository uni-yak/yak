# full 首批候选验证

本目录验证首批待确认候选，不包含 tuple 正例，不代表规格确认或正式发布收据。各语法边界见 [语法糖索引](../../spec/lang/sugar.md) 和 [状态迁移条件](../../spec/proc/status.md)。

在目标原生宿主执行（目标选 `linux-x64` 或 `win-x64`）：

```sh
bash test/full/run.sh --target linux-x64 --native-compiler PATH_TO_MAIN --native-scanner PATH_TO_IMPORTS
```

使用仓库锁定的构建工具；Win64 从 `YAK_RUNTIME_OBJ` 或已有默认路径读取运行时对象，Linux 从源码构建运行时。入口在 `tmp/full-stage-*` 创建独占快照并保留产物，运行显式用例、检查 min 和 tuple 拒绝边界、基座字节差分以及批量析构顺序。专项负例同时校验诊断码、关键位置和不产生对象或接口，并原生复验动态闭区间上界加一的算术陷阱。
