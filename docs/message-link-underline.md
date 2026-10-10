# 消息链接下划线（2026-10-11）

Flutter 原生 TextDecoration 的下划线位置取字体指标，decorationThickness 是字体厚度的乘数；中英混排的不同字体 run 因而可能产生不同位置与粗细。TextStyle 没有 underline offset。当前外部 Markdown 链接保持原 TextSpan、点击、语义及 SelectionArea；关闭原生 underline，使用既有强制 strut 行框定位统一的装饰线。

只为包含外部链接的消息增加绘制包装。复用 RenderParagraph 已排版的 selection boxes，不创建额外 TextPainter，不重复解析 Markdown；位置在布局或内容变化时缓存，普通重绘复用。横向表格滚动只更新变换与视口裁剪，不重测文字。内部 Raft 引用控件保持原有行为。

## 覆盖

| 项目 | 实际证据 | 边界 |
| --- | --- | --- |
| 中英混排、连续线段、跨行、点击、选区 | 三主题 × 1/2 倍文字缩放及两个真实字体的 Widget 像素回归通过 | 不是全部系统字体验收 |
| 重绘与表格横向滚动 | 8 次重绘仍仅一次几何收集；滚动后下划线跟随文字并留在视口内 | 缓存会在重新布局时失效 |
| 普通消息 | 不创建下划线 render object | 不宣称链接消息零开销 |
| 组件回归 | 40 项消息内容/成本/语义/Markdown 检查通过；分析器通过 | 非全工程测试全通过 |
| Android native 混排视觉 | 尚未完成正式会话中的截图复验 | 性能测试误卸载正式包导致原会话丢失，不能用合成 Widget 图替代原会话验收 |

## 性能原始结果

实际 ARM64 Android 设备，120Hz，platform semantics，elegant-light；steady-scroll 8 秒、移动 9600 逻辑像素；mount-markdown 共 24 步、47 新行。所有 run 被工具标记 NOISY HOST，不能作为合格基线。原始 JSON、首轮失败、重复和交叉对照均保留在 `.local/performance/link-underline-*`。

| Run | Scroll UI p99 ms | Raster p99 ms | Scroll >16.7ms UI/R | Stutter | Mount UI p99 ms | Mount >16.7ms UI | 每新行挂载 p50 µs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| before | 10.86 | 4.68 | 2/2 | 56 | 20.31 | 19 | 9072 |
| after（初版） | 11.39 | 4.85 | 2/1 | 59 | 20.64 | 21 | 9642 |
| after-repeat（同一初版 APK） | 11.14 | 4.75 | 5/2 | 54 | 20.70 | 20 | 9790 |
| before-repeat（恢复基线源码） | 11.27 | 4.78 | 4/2 | 53 | 20.51 | 18 | 9342 |
| final（当前下划线源码） | 11.52 | 4.55 | 5/2 | 54 | 21.00 | 17 | 9259 |

首轮比较标记滚动 stutter 和挂载超预算帧增加。最终方案移除了冗余查询，并修正表格变换/裁剪，但 compare 对两个基线仍分别标记 1 与 3 项退化：滚动超预算 UI 帧增加；相对第二基线还有 stutter +1、挂载 raster p99 增加。所有基线与候选本身均未达到 60Hz gate。结果不能表述为“性能验收通过”或“没有性能影响”；还需可靠基线验证并解决稳定复现的退化。

报告中的 Apple M1 Pro CPU/GPU 是驱动宿主元数据，不是手机 raster 硬件。性能 APK 与最终正式包不能互换；当前登录页系统栏的后续修改未包含在这些消息性能测量里。

## gpt_markdown 评估

[FlyerChat 的官方文本消息组件](https://pub.dev/packages/flyer_chat_text_message)采用 gpt_markdown；这说明它是官方默认文本组件的依赖，不证明所有定制渲染器都必须迁移。检查发布的 gpt_markdown 1.3.4，链接仍使用原生 TextDecoration.underline，LinkStyle 仅提供颜色、装饰、厚度及字重，无 offset，所以换库本身不能修复本问题。

[1.3 系列更新](https://pub.dev/packages/gpt_markdown/changelog)改进 parser、流式渲染和 TextSpan 链接选择/换行；其 parser 加速比较针对自己的旧版本，不能据此推断它比当前 Raft renderer 更快。若迁移，仍需覆盖 Raft 引用、代码/Mermaid、折叠、附件、选择/复制与缓存，并单独比较成本。本次未加入该依赖。

参考：[Flutter TextStyle](https://api.flutter.dev/flutter/painting/TextStyle-class.html)、[strut line boxes](https://api.flutter.dev/flutter/dart-ui/BoxHeightStyle.html)、[gpt_markdown LinkStyle](https://github.com/useval/gpt_markdown/blob/main/lib/styles/link_style.dart)。
