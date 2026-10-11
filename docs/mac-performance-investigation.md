# macOS 页面与滚动性能调查

本调查仍在进行。已确认并修复了整表提前布局、重复历史高度扫描、引用目录逐项匹配、聊天返回时销毁重建，以及滚动后悬浮工具栏导致的无障碍节点断链。尚不能宣称全部页面达到 120fps：长消息首次显示、部分绘制与页面转场仍存在超过 8.33ms 的帧。

## 环境与证据边界

- MacBook Pro，ARM64，内屏实测 120Hz，DPR 2，诊断内容视图 2400×1600 像素，Flutter 3.47.6 / engine 692136cb65。
- 使用 Profile 独立应用 `app.raft.fpsLab`，固定本地模拟数据，不连接真实账号，不替换已安装的 Raft。窗口始终在后台；输入通过 Codex 内置 Computer Use 定向发送。
- 自动化开启了无障碍语义树。原始数据的 `ui` 是 `FrameTiming.buildDuration`，涵盖引擎记录的构建区间，**不等于包含提交后语义更新与 finalize/post-frame 的完整 UI 线程时间**。
- 输入是后台滚轮/点击；不是连续十秒的真实触控板手势。下面的单次峰值用于定位，不能据此宣布 P01、性能实验室门槛或日常 FPS 验收通过。
- 前后版本必须匹配诊断入口和 fixture 哈希，按 vsync 时间排除上一操作延迟上报的帧。失败数据与实验版本分别保留，不覆盖。当前主线其他改动也会影响前后结果，不能把整个差异都归因于一个补丁。

## 覆盖清单

| 页面/路径 | 固定数据 | 已执行的原生操作 | 行为保护 |
|---|---|---|---|
| 频道聊天 | 前三个频道各 600 条混合消息，80 个频道 | 进入、首次/短距滚动、实时到达、切频道、侧栏滚动 | 分页锚点、逐帧首帧稳定、草稿/光标、权限撤销 |
| 频道设置 | 120 人/120 agent 成员目录 | 打开、关闭、返回聊天 | 段落惰性布局，原 padding/border 与操作保持 |
| 全局设置 | 完整 workspace | 首次进入、三轮聊天往返；外观、语言地区、资料、账单、管理、反馈表单 | 一个聊天与最近设置页；隐藏焦点/语义/回执隔离，表单角色独立 |
| 任务 | 每个样本频道 30 项，接口按状态过滤 | 切任务页、列内滚动 | 1000 卡片挂载数量、拖拽、实时刷新、权限变化 |
| 文件 | 50 个有效源记录 | 切文件页、滚动、返回聊天 | 原记录身份与操作保持 |
| 消息串 | 60 条回复 | 打开、滚动、关闭 | 线程首帧、上下文接受、焦点、独立滚动位置 |
| 成员 | 120 人、120 agent、20 电脑分组 | 进入、实际左侧目录滚动 | 分组折叠、行菜单、后台刷新、稳定键 |
| 电脑 | 20 项 | 进入、实际目录滚动 | 保留既有行；不宣称已验证 1000 台电脑原生压力 |
| 动态 | 40 项 | 进入、滚动 | 原消息定位与阅读行为 |
| 搜索 | 90 个结果 | 快速搜索、完整结果、滚动 | 分组与消息串间距、结果操作、跨服务器引用 |
| 应用 | 50 项 | 空市场、已注册应用、滚动 | 1000 项 widget 覆盖，网格可见行保持等高 |
| MCP | 40 台、每台 4 个工具 | 进入、滚动 | 1000 项 widget 覆盖，加载/空/错误状态与使用说明 |
| 窗口/窄宽屏 | 多种主题、768/1024/1280 折叠边界 | widget 尺寸变化 | 后台原生 API 不提供 OS 窗口 resize；未把 widget 测试称作原生 resize 通过 |

Providers、Labs、Bridges 在该 fixture 的功能开关下未开启；空市场、已保存与关注消息串的空态不代表对应长列表性能。

## 修改与选择依据

长目录、侧栏、搜索组、任务列、应用和 MCP 目录改用有边界的惰性 sliver/builder。应用网格仍在每个可见行内使用等高计算，避免一次询问所有卡片的 intrinsic 尺寸。聊天历史使用 Fenwick 高度索引：每个展示版本初始化一次，实际行高增量更新，滚动查询不再扫描未显示历史。直接给图片提供透明度动画，保留原来的 120ms 淡入和图片缓存。[Flutter 性能建议](https://docs.flutter.dev/perf/best-practices)、[Image.opacity](https://api.flutter.dev/flutter/widgets/Image/opacity.html)。

引用匹配使用按目录投影持有的弱缓存前缀索引，保留原来的重叠名称、重复项次序、Unicode、结构化身份与权限隔离。空闲解析仅预热已有的不可变 Markdown/代码缓存，每次最多 64 项，输入静止 250ms 后才执行，逐项间隔 16ms，页面隐藏、权威或内容版本变化立即取消；不发网络请求。

没有保留实验性的 32 行额外 KeepAlive：它没有改善冷滚动，并增加屏幕外焦点生命周期。四屏预布局降低冷滚动峰值，却增加实时更新和设置返回成本，因此不能作为最终选择。当前候选限制为前后一屏，外部更新或隐藏时收回默认缓存。Flutter 在重建 delegate 时先更新现有缓存子项，再由布局回收；单纯收缩 `cacheExtent` 不能避免当次所有旧缓存行的重建。[shouldRebuild](https://api.flutter.dev/flutter/widgets/SliverChildBuilderDelegate/shouldRebuild.html)、[collectGarbage](https://api.flutter.dev/flutter/rendering/RenderSliverMultiBoxAdaptor/collectGarbage.html)。

滚动时立即退休行工具栏、tooltip，包括键盘打开的悬浮内容。给 OverlayPortal 宿主建立语义边界；键盘进入工具栏之前先显示实际消息行，避免只显示零高焦点代理却把悬浮内容留在裁剪范围外。compact 消息语义预算保持每行 3 节点，测试平均每个滚动帧更新 8.7 节点，未放宽这些门槛。[OverlayPortal 对屏幕外宿主语义的说明](https://api.flutter.dev/flutter/widgets/OverlayPortal-class.html)。

## 阶段性原生结果

早期匹配的 v3 29 路径测量，单次 UI 构建区间峰值如下。它验证了惰性布局的作用，但不是当前最终候选的验收。

| 操作 | 修改前 ms | 早期修改后 ms |
|---|---:|---:|
| 频道设置进入 | 12.539 | 6.925 |
| 任务进入 | 31.118 | 19.097 |
| 文件进入 | 23.574 | 11.460 |
| 搜索结果进入 | 46.036 | 24.127 |
| 成员进入 | 48.001 | 30.486 |
| 已注册应用进入 | 20.600 | 6.808 |
| MCP 进入 | 32.015 | 16.322 |

原始逐帧 JSON 和版本 manifest 随调查证据保存。惰性布局也把部分首次构建成本移动到首次滚动，不能只凭进入页面的改善宣布问题解决。

`caced57` 版本又完成了 37 段原生操作，全部没有未匹配接口或运行时错误。频道切换峰值 14.071ms、冷聊天三页滚动 38.301ms、已显示行的短距滚动 3.301ms；绘制分别为 3.348、21.637、14.315ms。进入设置时消息行重建数为零，但设置首次进入仍为 26.541ms，三次返回聊天为 17.854/25.178/25.831ms，因此仍需继续定位。

只保留最近设置页的 `b42e796` 候选通过了状态、隐藏与权限保护，但三轮进入设置仍为 18.407/23.145/17.205ms，返回聊天为 19.333/31.355/19.763ms。这项保留避免了表单状态销毁；单次原生测量没有证明它消除了切页峰值。继续进行调用栈分析，最终选择和完整证据附件待补。代码检查、行为测试、原生无障碍连接性与帧预算分别报告；任何一项通过均不能替代另一项。

## 当前可审查批次

生产代码已无冲突接上 `ccfa888`，当前代码修订为 `3838802`。诊断入口、固定数据与原生窗口身份只存在于独立实验目录，不进入产品提交。当前批次可以独立审查；任务仍在进行，不能据此关闭“解决所有掉帧”的目标。

折叠控件去除了内容未变时的重复布局：20 次父级更新，旧实现布局 21 次，修正后 1 次；首次高度判断、展开、禁用、宽度与语言变化仍在当帧正确呈现。设置页最多保留一个最近使用页面，并在输入完全相同时复用 Account 组件；账户资料、权限、标签页、外观、通知与回调变化会刷新，隐藏期间的资料更新在返回首帧展示。复用相同子组件是 Flutter 对减少重复构建的推荐方式。[Flutter 性能建议](https://docs.flutter.dev/perf/best-practices)。

`dde980c` 的干净 Profile 版本完成了 27 段操作，其中前 13 段与 v4 基线使用相同入口和数据。下表列出本次构建区间与绘制峰值，单位 ms；不是完整 UI 线程帧时间，也不是多轮统计结论。

| 操作 | 构建最高 | 绘制最高 |
|---|---:|---:|
| 冷聊天三页滚动 | 44.819 | 23.130 |
| 已访问内容短距滚动 | 2.888 | 20.243 |
| 阅读旧内容时新消息到达 | 25.138 | 6.256 |
| 首次切频道 | 13.631 | 5.542 |
| 频道设置打开 / 关闭 | 10.453 / 2.468 | 7.612 / 9.178 |
| Account 首次进入 | 27.750 | 9.080 |
| 三次返回聊天 | 19.045 / 19.262 / 22.631 | 10.078 / 11.014 / 8.215 |
| 三次返回 Account | 15.206 / 16.756 / 16.817 | 12.147 / 13.637 / 15.122 |
| 外观首次进入 / 滚动 | 13.561 / 1.313 | 13.138 / 13.942 |
| 语言地区首次进入 | 19.033 | 6.235 |
| 服务器资料首次进入 | 10.362 | 5.441 |
| 已注册应用进入 / 三页滚动 | 7.165 / 29.603 | 3.707 / 4.480 |
| MCP 进入 / 三页滚动 | 12.132 / 29.970 | 4.073 / 6.186 |

设置进入期间消息行构建数保持不变；返回聊天每次仍构建 5 行，是后续需要减少的工作。Account 往返相较 `66c0126` 候选的 20.349/21.225/17.417ms 降低，但原始 v4 基线部分原生语义节点存在断链，不能把与那份基线的差异当成等价无障碍条件下的最终验收。

设置子页检查发现已有的语义角色合并错误：ListView 把整张账单卡片合并为文本输入框，导致原生树只显示一个输入框；桌面 recipe 控件又会把周围内容标为按钮。给账单与反馈输入框建立边界，并为桌面 RaftInteractive 建立独立角色边界后，原生账单恢复内容容器、比较按钮、计费周期与独立输入框；反馈恢复标题、编辑器与操作按钮，输入计数正常。触摸模式仍由原来的 TouchTarget 提供扩大点击与语义区域。应用、管理输入框使用 RaftRecipeInput，没有同类额外 textField 包装。

当前修订的原生补充验证包括 Account、账单进入/实际滚动、反馈空态/新建/输入/取消，以及任务/文件进入与实际滚动。账单进入构建/绘制最高 7.781/7.529ms；反馈输入 3.155/3.976ms；这些单段数据不能替代全局 120fps 验收。任务/文件首次进入仍为 15.419/15.013ms，较大滚轮跳转仍为 33.051/30.139ms。

账单 fixture 没有完整计费权限投影，展示只读操作；管理 fixture 的 onboarding 配置字段不完整，出现加载提示。两者用于布局/语义问题定位，不作为完整业务数据验收。外观、Account 等字段已建模的测量以及 13 段主路径不受此影响。Providers/Labs/Bridges、真实账单写入、发布说明长列表、反馈会话长列表与后台原生窗口调整仍没有完整原生验收。

## 相关验证与仍需处理的工作

- 重建后相关 Settings/导航 46 项、消息语义预算 4 项、折叠/消息内容 43 项通过。新增控件与输入角色及原控件几何 31 项、反馈表单 40 项、账单/设置行为 26 项通过；这些套件有交叉，不相加声称唯一测试总数。
- app 与 raft_ui 静态分析无问题，设计系统审计通过。未放宽每行 3 个语义节点、滚动平均 8.7 次更新和不变内容 0 次语义更新的测试预算。
- 全项目检查由集成分支批次负责人在合并后统一执行，本批次没有重复跑。
- 可避免的整表布局、历史高度扫描、首次引用扫描、状态销毁、隐藏行重建、折叠重复布局和语义角色合并已有修复；尚需继续减少可见聊天返回重建和公共样式解析的重复工作，并补齐未建模页面与真实连续手势的验证。

原始证据按 `before-v3` / `after-v3`、`before-v4`、`collapse-v4`、`account-reused-v4`、`input-role-v4` 保存，源码 manifest 记录逐文件哈希。不要用不同 fixture、诊断入口或语义条件混算，也不要把三页瞬时跳转的峰值换算成日常平均 FPS。


## Full-suite review repair (after 7f65d36)

Cindy's full suite found 20 regressions against ccfa888. The listed seven test
files now pass locally: 53 application tests, plus 91 related design-system
tests (including the three listed design-system files). The review fixes:

- Preserve a tooltip portal's independent semantics anchor while expanding its
  boundary to the existing 48px touch target. A nested 28/32px boundary had
  split the accessible tap action from the expanded target. Ordinary desktop
  buttons still own a boundary, and sibling copy retains its original role.
- Use the existing local text/border alignment fallback while a retained
  repaint boundary has an ancestor awaiting layout. This prevents mobile
  Activity Back transitions from reading a missing ancestor size.
- Measure sidebar sliver scroll extent and actual header positions in the
  geometry tests, retaining the original 89/68/40px and adjacency assertions.
  Inspect the lazy channel-settings action region before checking offered and
  forbidden Stop Agents permissions. Read mobile sidebar inset from its
  SliverPadding, retaining the original layout and navigation assertions.
- Update the overlay lifetime test for the intended scroll-dismiss behavior;
  fresh reopening still tracks the current anchor, clips offscreen actions,
  and cannot survive route or owner removal.

No new native frame timings are claimed for these review repairs. The native
measurements above retain their recorded source identities. Full-project
revalidation remains owned by Cindy; the overall performance investigation is
still active.


## Generated recipe template cache (fa26284)

The cache reduces pure style computation, while the overall investigation remains active. The 32 matched native operations still contain cold-row and transition spikes above the 8.33ms budget. This change does not establish a stable improvement in every page transition.

`raftResolveRecipe`, the generated entry point, retains at most 512 tokenless cascade templates per engine. Keys snapshot the ordered class indices, sorted interaction flags, viewport width/height and container width. Each call returns fresh property/target maps and classes, recursively copies mutable CSS lists, and binds the current token resolver. The generated rule tables are immutable; direct `RaftRecipeEngine.resolveSlot` remains uncached for mutable/custom engines. No Widgets, controllers, permission projections or token values are retained in this cache.

Validation: 103 related recipe/mounted-component cases passed, with one pre-existing external generated-fixture skip; all six new cache unit cases passed and design-system analysis was clean. The tests cover token changes, state order, media/container thresholds, key input mutation, returned nested-value mutation, bounded eviction and direct mutable-engine behavior.

Native macOS Profile (AOT) attribution used a synthetic primary-hover-button cascade, 1,000 warmup pairs and seven alternating cached-first/uncached-first rounds of 5,000 resolutions each. The median was **42.548ms cached versus 110.420ms direct**. Every round favored the cache. This measures cascade/template work only: it excludes token getter evaluation, Widgets, layout and paint. The diagnostic iterations intentionally block their own UI and are excluded from application frame acceptance. The clean frame harness was restored afterwards. [Flutter profiling guidance](https://docs.flutter.dev/perf/ui-performance) and the local macOS AOT snapshot target were checked; a JIT test-loop result is not substituted for this native measurement.

Official 99 cases and 75 explicitly selected extension cases (14 areas, brutal/elegant/elegant-dark) produced **174 byte-identical Flutter PNG pairs**. The reference checkout was pinned to `26f77ef97c40d3d91aa2c5e42b0fd66b8bf39fe6`, remained clean, and used production fonts with headless Chromium. Both sides used the same Mac host, Flutter 3.47.6, Node 25.6.1 and single-shard configuration. Absolute Mac scores were 55/99 official and 18/75 extension, with 4/75 extension geometry passes; these are not Linux reference scores or a geometry-pass claim. The review lead explicitly accepted same-host before/after image identity for this Mac check. The original two-shard host attempt failed while preparing a native dependency; the corrected single-shard run exposed and repaired the tasks-case ListView finder. That one-line harness repair was delivered separately as `f385dff` and accepted by Cindy. The original complete 98 PNG pairs were preserved; the affected task case alone was recaptured on both sides after the identical repair.

The native comparison below is 426eddb versus b7eaf0e, captured with the same clean harness, fixture, routes, size, DPR and semantics. All 32 operations on each side had no fixture misses or runtime errors, and native accessibility remained usable. The reviewed cache commit fa26284 is rebased onto f385dff; all production library bytes match b7eaf0e. Pixel captures used the same production libraries plus the shared finder repair. These are sparse background-wheel/action passes, not continuous-gesture or native-window-resize acceptance. Engine build duration excludes semantics/finalize/post-frame work. Percentiles in the raw comparison use nearest rank. The first three operations show an approximately 8.333ms median vsync interval, independently of the reported 120Hz display capability.

| operation | baseline build max ms | cached build max ms | baseline raster max ms | cached raster max ms |
| --- | ---: | ---: | ---: | ---: |
| 01-cold-chat-scroll | 42.457 | 42.753 | 22.025 | 21.429 |
| 02-short-chat-scroll | 3.110 | 3.035 | 20.367 | 18.336 |
| 03-live-chat-update | 29.644 | 21.843 | 6.698 | 7.095 |
| 04-channel-entry | 15.640 | 14.997 | 6.341 | 4.113 |
| 05-channel-settings | 8.302 | 8.114 | 7.660 | 7.530 |
| 06-close-channel-settings | 2.648 | 2.341 | 14.680 | 11.607 |
| 07-settings-first | 22.789 | 20.941 | 9.872 | 10.063 |
| 08-chat-return | 26.080 | 30.527 | 13.559 | 5.792 |
| 09-settings-warm | 17.735 | 14.265 | 2.719 | 2.719 |
| 10-chat-return | 26.016 | 27.927 | 9.339 | 8.193 |
| 11-settings-warm | 17.584 | 13.901 | 2.855 | 2.744 |
| 12-chat-return | 36.839 | 30.083 | 6.032 | 8.870 |
| 13-settings-warm | 16.353 | 21.224 | 2.894 | 2.492 |
| 14-task-entry | 16.758 | 15.816 | 11.523 | 9.362 |
| 15-task-scroll | 26.895 | 27.378 | 11.496 | 6.522 |
| 16-files-entry | 20.928 | 10.496 | 13.044 | 10.432 |
| 17-files-scroll | 29.705 | 37.295 | 5.777 | 7.077 |
| 18-members-entry | 24.786 | 21.427 | 7.385 | 9.870 |
| 19-members-scroll | 32.548 | 31.355 | 8.515 | 9.818 |
| 20-computers-entry | 21.244 | 24.062 | 8.704 | 9.229 |
| 21-computers-scroll | 6.631 | 6.709 | 8.191 | 9.301 |
| 22-activity-entry | 13.367 | 12.184 | 9.166 | 4.347 |
| 23-activity-scroll | 34.325 | 40.323 | 4.151 | 6.347 |
| 24-marketplace-entry | 16.789 | 16.938 | 5.013 | 5.140 |
| 25-registered-apps-entry | 6.757 | 6.183 | 3.877 | 3.993 |
| 26-registered-apps-scroll | 19.848 | 20.677 | 7.603 | 6.304 |
| 27-mcp-entry | 12.096 | 18.362 | 4.385 | 4.324 |
| 28-mcp-scroll | 36.028 | 32.393 | 11.134 | 7.016 |
| 29-quick-search-entry | 9.830 | 8.048 | 8.654 | 10.314 |
| 30-search-query-input | 25.897 | 18.613 | 8.710 | 7.575 |
| 31-search-results-entry | 22.054 | 27.128 | 7.611 | 5.942 |
| 32-search-results-scroll | 38.297 | 37.051 | 5.452 | 3.907 |

Evidence packet: separate baseline/candidate native frames and source manifests, the full comparison, AOT attribution JSON and harness receipt, official/extension summaries, explicit extension selection and PNG hashes. No binaries, authenticated VM service addresses, CPU traces or credentials are included. Native background targeting exposes no window-resize API; widget width/fold regressions remain separate from a native resize measurement.


## Attachment retention history index (3d110da)

Unrelated WorkspaceController notifications previously invalidated the attachment retention metadata index because its stamp included `_stateStamp`. With a decoded image retained after its owner releases it, each Chat/Settings notification rescanned the admitted channels and every retained parent/thread message. The new admission projection still rechecks `can()` and revocations at every former invalidation boundary, including a ledger update before the next notification. It retains the admitted channel-id list identity when its contents are equal. The expensive history index now depends on ledger revision, image scope and that admitted id projection. Canonical metadata comparison and the active image authority path are unchanged.

The old implementation with the test-only scan counter failed two performance assertions: 20 navigation notifications performed 21 scans instead of one, and replacing channel records with the same ids performed a second scan. Its four lifecycle/security cases passed. The optimized implementation passes seven focused tests and 35 related attachment tests in total, with clean application analysis. Tests use a real decoded PNG and release its owner before checking canonical retention; they cover same-length in-place channel replacement, same-id metadata revision, actual channel removal, role/principal changes and direct ledger updates before notification. These counters prove work elimination, not an elapsed-time or FPS improvement.

Thirteen matching native background Profile actions compared clean b7eaf0e (production libraries byte-equivalent to aa7ffc6) with 3d110da. The clean harness/fixture, routes, 120Hz display, DPR 2, 2400x1600 physical view and enabled semantics match. All actions completed with usable native accessibility and no runtime errors or fixture misses. The source manifests enumerate 569 then 597 files: the extra 28 files are unchanged from the original lab checkout, and the sole changed previously enumerated source is workspace_controller.dart.

Results remain mixed. First Settings and two repeated Settings visits were slower in this pass; two Chat returns were faster and the third was slower. No stable whole-page benefit is claimed. Cold and transition peaks still exceed 8.33ms. Sparse wheel/action samples are not continuous-gesture or native window-resize acceptance; engine build duration excludes semantics/finalize/post-frame work.

| operation | before build max ms | after build max ms | before raster max ms | after raster max ms |
| --- | ---: | ---: | ---: | ---: |
| 01-chat-00-cold-scroll | 42.753 | 43.667 | 21.429 | 21.571 |
| 02-chat-00-small-scroll | 3.035 | 2.835 | 18.336 | 20.823 |
| 03-chat-live-event | 21.843 | 29.124 | 7.095 | 7.092 |
| 04-channel-01-entry | 14.997 | 14.752 | 4.113 | 5.293 |
| 05-channel-settings | 8.114 | 13.774 | 7.530 | 10.371 |
| 06-channel-settings-close | 2.341 | 1.941 | 11.607 | 13.407 |
| 07-settings-first | 20.941 | 27.378 | 10.063 | 9.242 |
| 08-chat-return | 30.527 | 23.243 | 5.792 | 9.290 |
| 09-settings-warm | 14.265 | 19.991 | 2.719 | 3.101 |
| 10-chat-return | 27.927 | 18.698 | 8.193 | 9.513 |
| 11-settings-warm | 13.901 | 21.422 | 2.744 | 2.669 |
| 12-chat-return | 30.083 | 31.074 | 8.870 | 9.552 |
| 13-settings-warm | 21.224 | 20.529 | 2.492 | 3.136 |

The review packet includes both sets of raw frames, source/build receipts, comparison, original failing assertions, final test/analysis/audit logs and this report. It excludes native binaries, CPU traces and authenticated VM endpoints.


## Visited desktop sidebar retention (36c820a, based on cdb0727)

Switching from Chat to Settings previously removed the sidebar subtree. Returning reconstructed the channel groups, list, controllers and menu anchors. The adaptive workspace now retains a visited desktop sidebar at the same child position, excludes its hidden layout width, painting, hit tests and semantics, and suspends focus/tickers. Initial hidden routes do not mount it, and entering the mobile layout discards it as before. The app keys the adaptive root by its existing authority identity so principal, server, role and channel-access reduction retire the retained state. Changing ordinary selected channels does not replace that root. Hosts using the public adaptive component must likewise change its key when the content authority changes.

The first retained implementation still passed fresh sidebar widget inputs on every hidden owner update. The final implementation holds the last input while hidden and applies the current input in the first visible build. A regression failed before this change: five hidden label updates caused six total sidebar builds rather than one. It passes afterwards and verifies that the final label appears immediately when shown, with the same mounted State. This eliminates those input-driven builds; inherited dependencies or the sidebar's own listeners can still rebuild it, and Offstage still lays out its child when dirty.

Retaining hidden controls exposed a menu lifecycle problem: open overlays and old callbacks could survive hiding. Dropdowns now observe the inherited TickerMode/Visibility presentation state, cancel pending focus work, close without restoring hidden focus, reject external reopening and reject saved item callbacks while inactive. Existing normal keyboard/focus behavior remains covered. The existing interactive SDK workspace preview now hides the sidebar off Chat and demonstrates returning to it.

Validation: 28 design-system cases and 55 application cases passed (83 total), with clean design-system analysis and no audit count regressions. Root analysis had already passed on the first retained revision; the final follow-up changes only adaptive-workspace internals and tests. New retention cases cover draft/scroll/State identity through three hide/show cycles, zero hidden width, hidden focus/semantics, initial lazy mounting, authority reset, immediate latest-input catch-up, and menu stale callbacks in brutal, elegant and elegant-dark. On the original implementation, the State-retention case and the two original menu-family cases failed; lazy mounting passed. The separate hidden-input repro ran against the first retained revision and failed before freezing inputs.

All three native passes below use the same clean Profile AOT harness, synthetic workspace-mac-v4 fixture, matching 13 actions/routes, 120Hz display, DPR 2, 2400x1600 physical view and enabled semantics. Each manifest enumerates and verifies all 597 tracked production library files. The controller/attachment index sources match the accepted baseline; only workspace_view, adaptive_workspace, design_primitives and previews library files differ. No widget/layout tracing flags or CPU profiler were enabled for these frame captures. All 39 captures have zero fixture misses/runtime errors. Native checks additionally confirmed that a message arriving with the sidebar hidden changes unread 1 to 2 immediately on return, no hidden channel controls appear in Settings accessibility, and sidebar channel-53 position survives a hide/show cycle. The lab window was closed in the background after verification.

The final pass has lower build peaks on all three Chat returns than the accepted baseline, but first Settings is slower and repeated Settings remain mixed. The intermediate retained-only pass is preserved to show that retention alone did not reliably improve returns. Foreground host load was uncontrolled and these are single sparse action passes, so no stable whole-page gain, aggregate percentage or 120fps acceptance is claimed. Build peaks still exceed 8.33ms and engine build duration excludes semantics/finalize/post-frame work. Continuous scrolling and actual native-window resize acceptance remain open.

| operation | baseline build max ms | retained-only build max ms | final build max ms | baseline raster max ms | final raster max ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 01-chat-00-cold-scroll | 43.667 | 47.721 | 41.844 | 21.571 | 22.891 |
| 02-chat-00-small-scroll | 2.835 | 3.038 | 2.980 | 20.823 | 16.582 |
| 03-chat-live-event | 29.124 | 28.138 | 28.881 | 7.092 | 5.802 |
| 04-channel-01-entry | 14.752 | 15.334 | 14.931 | 5.293 | 5.722 |
| 05-channel-settings | 13.774 | 14.672 | 11.011 | 10.371 | 6.712 |
| 06-channel-settings-close | 1.941 | 2.445 | 2.979 | 13.407 | 11.915 |
| 07-settings-first | 27.378 | 17.221 | 31.162 | 9.242 | 9.619 |
| 08-chat-return | 23.243 | 24.753 | 17.717 | 9.290 | 8.613 |
| 09-settings-warm | 19.991 | 19.017 | 24.730 | 3.101 | 2.839 |
| 10-chat-return | 18.698 | 23.024 | 14.523 | 9.513 | 12.489 |
| 11-settings-warm | 21.422 | 21.986 | 21.221 | 2.669 | 2.852 |
| 12-chat-return | 31.074 | 26.230 | 22.149 | 9.552 | 8.578 |
| 13-settings-warm | 20.529 | 15.600 | 20.042 | 3.136 | 2.946 |

The review packet includes all three sets of raw frames, matching source manifests, build receipts, comparison JSON, original failing regressions and final validation logs. Native binaries, CPU traces and authenticated VM endpoints stay local.


## Message extent preparation across native resize (baeaa8d, based on f0b3e07)

The remaining resize CPU sample identified the timeline extent index as a larger application hotspot than visible row layout: 487 inclusive samples reached the index constructor, 475 the guess cache, and 400 the full content estimator, out of 4,245 samples within the exact 10-second native action. These overlapping counts are not additive and this separate profiler-enabled pass is excluded from frame acceptance. A preceding responsive-style cache experiment reduced duplicate cascade work in regressions but did not produce a stable native frame improvement; that experiment remains parked and is excluded from this change.

Each changed width previously split and counted characters in roughly 600 message bodies again. The guess cache now prepares numeric per-line widths once per canonical message metadata revision and recalculates wrapping with the current width. It uses a bounded 4,000-entry numeric preparation pool and a bounded guess cache. Opaque keys in those bounded pools do not retain message Maps or body strings. Revision strings belong to weak canonical metadata keys. Body edits retire the old preparation; attachment count and reaction presence are checked on every estimate. Null metadata uses the existing default before consulting old estimates. Measured row heights, theme/host scopes and the original rough-height arithmetic remain in place.

The real chat model creates a fresh unmodifiable metadata wrapper on each getter call. The chat view therefore supplies the existing source record's canonical JSON Map to the estimator through its existing projection/source association. A mounted 600-message regression failed with the initial wrapper-keyed implementation: twelve width changes added 7,200 content preparations. The canonical-source implementation adds none. Eight pure cases cover the same reuse, same-width edits, metadata replacement, null/empty/non-list fallback, fences/blank lines/CJK/emoji/clipping, 4,000-entry bounds and repeated revision replacement. The old implementation failed four corrected repro cases. A separate initial repro used an incorrect clipping expectation and is excluded from the review evidence.

Validation: 35 related application cases passed, application static analysis reported no issues, and the design-system audit passed with unchanged counts (214 application files; 480 calls, comprising 221 widgets and 259 styles; 17 allow-list entries). Full repository validation remains with the integration reviewer. The code commit changes two production files and adds two test files. All 597 tracked production library files and the three local diagnostic sources were hash-verified in the native Lab before the build; production differences from accepted f0b3e07 are only chat_view.dart and row_extents.dart.

The clean Profile AOT comparison uses the same synthetic workspace-mac-v4 fixture, enabled semantics, reported 120Hz display and DPR 2. Both builds execute eight seconds of actual timeline animateTo scrolling at 1,200 logical pixels per second, followed by ten seconds of native NSWindow setFrame changes between 1200x800 and 900x700 logical points. The local diagnostic button is clicked through background Computer Use. Native resize guards verify that the app is inactive and the window non-key at every step, and restore its original size. This programmatic resize is not a human NSWindow.inLiveResize gesture. It requests 120 timer ticks per second but does not achieve that native step rate: baseline 349 steps/350 observed engine metrics; candidate 356 steps/357 metrics. See [Apple NSWindow setFrame documentation](https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:animate:)).

The frame files use the native CLOCK_MONOTONIC_RAW phase receipt to select only vsync timestamps inside each action, retain excluded frames separately, and use nearest-rank p99. No CPU sampling, widget/layout tracing or synthetic engine-size override was enabled. Both actions on both builds have no runtime errors or fixture misses. The window was closed in the background after verification. Source manifests, AOT binary hashes and the full local binaries are preserved; binaries and raw CPU/VM data are excluded from the review packet.

| phase / metric | accepted f0b3e07 | candidate baeaa8d |
| --- | ---: | ---: |
| scroll duration / frames | 8.001930s / 959 | 8.008229s / 959 |
| scroll build p99 / max ms | 6.121 / 10.536 | 5.699 / 7.900 |
| scroll build frames above 8.33ms | 3 | 0 |
| scroll raster p99 / max ms | 6.407 / 14.677 | 6.370 / 13.849 |
| scroll total p99 / max ms | 9.876 / 18.869 | 9.209 / 14.475 |
| scroll vsync gaps above 12.5ms | 1 | 2 |
| resize duration / frames | 10.029448s / 758 | 10.024366s / 832 |
| resize build p99 / max ms | 19.539 / 21.800 | 14.724 / 18.113 |
| resize build frames above 8.33ms | 327 | 195 |
| resize raster p99 / max ms | 3.844 / 12.574 | 3.956 / 12.073 |
| resize total p99 / max ms | 46.010 / 70.961 | 52.000 / 68.648 |
| resize vsync gaps above 12.5ms | 190 | 136 |

Content preparation reuse is proven by the pure and mounted regressions. In this matched native pair the resize build p99 and over-budget build count improve, while total p99 does not. Host foreground load is uncontrolled and these are single passes; no stable aggregate frame-rate gain or 120fps acceptance is claimed. Engine build timing excludes semantics/finalize/post-frame work, and total timing includes pipeline latency rather than measuring all UI-thread work directly. Broad transitions, resize, semantics and other page costs still require further investigation; task #3 remains open.
