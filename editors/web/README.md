# Yak 网页语法高亮

将 `yak.mjs` 和 `yak.css` 放到站点的静态资源目录，通过 HTTP(S) 加载。模块可直接用于文档、代码示例和前端预览，无需 npm、构建步骤或语言服务。

```html
<link rel="stylesheet" href="./yak.css">
<pre><code class="language-yak">function main(): void {
    let n: u32 = 0x2Au32;
}</code></pre>
<script type="module">
    import { highlightYak } from "./yak.mjs";

    for (const block of document.querySelectorAll("code.language-yak")) {
        highlightYak(block);
    }
</script>
```

从编辑器或网络收到源码时，调用 `highlightYak(block, source)`。模块用文本节点保留空格、换行和 `<`、`&` 等字符。直接在 HTML 的 `<code>` 中写源码时，用 `&lt;` 和 `&amp;` 转义。样式随浏览器深浅色偏好切换，站点可覆盖 `.yak-code` 下的颜色变量。

`tokenizeYak(source)` 返回包含 `kind` 和 `text` 的片段，可用于自定义渲染。模块支持嵌套块注释、整数进制与后缀、能力修饰、原语及注解、原始字符串和模板插值。高亮按 [词法规格](../../spec/lang/lex.md) 和 [固有符号配置](../../spec/lang/symbol.def) 区分保留项与当前词法形态。语言能力和完整诊断由编译器决定。

从仓库根目录运行定向测试：

```sh
node --test editors/web/test_highlight.mjs
```
