# pkg/io

## 职责

[io.yak](io.yak) 是由 `.iface` 导入的标准流模块，接口见 [标准流规格](../../spec/lang/stdio.md)。文件流不属于本轮实现。

[逐块回显](../../examples/echo.yak) 展示如何区分 EOF、读失败和写失败；[LF 计数](../../examples/lines.yak) 展示如何消费实际返回的字节，并在全部输入读完后再写结果。[标准流门禁](../../test/gate/test_stdio.sh) 使用本轮原生编译器编译示例并对真实句柄运行断言，不使用冻结 Seed。
