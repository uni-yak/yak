# T1 编译管线与入口

[`build.sh`](../build.sh) 从根模块发现依赖：使用 [`imports.yak`](imports.yak) 的真实词法、语法和模块图检查稳定取得拓扑序，再交给 [`tools/link.sh`](../../../tools/link.sh) 逐单元编译与链接。根模块身份按源根相对路径确定；前序接口作为候选，驱动只给实际直接依赖分配编号。

[`main.yak`](main.yak) 编排编译阶段。[`driver_front.yak`](driver_front.yak) 处理词法、解析和 base 校验。[`driver_deps.yak`](driver_deps.yak) 装载依赖接口，[`driver_ir.yak`](driver_ir.yak) 顺序执行引用解析、类型检查、布局、所有权检查和 MIR 降级，[`driver_emit.yak`](driver_emit.yak) 发射产物。驱动先校验产物，再写 `.iface`、`.obj`；正式构建同时以真实 MIR、导出映射和直接接口摘要生成 format 4 `.ysm`。无法编码的形态先诊断并退出，不发布半套产物。

正式构建在隔离暂存目录完成发射和链接后发布 `.exe`，可选审计目录保留每个单元的三类产物。根模块必须定义 `function main(): void`；仅该入口发射 `yak$entry` 别名。

[`verify.sh`](../verify.sh) 检查规格结构、词表与真实构建入口子集，不代替 T1 整体门禁。流程与发布约束以 [`build.md`](../../../spec/proc/build.md) 为准。
