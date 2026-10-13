# Raft Flutter 工程约定

- 本仓库为独立 Flutter 客户端；Web参照版本记录于 docs/source-reference.json。实现前阅读 docs/architecture.md 和当前用户指令。
- 合入与 PR：每个分支开 PR 指向 cindy/integration。PR 描述写清改了什么、怎么验证的（命令与结果、设备、哪些没验证）和 `tool/prepare-handoff` 输出的全量检查结果行；验证证据只放 PR 描述，不进 docs/（docs/README.md 是索引，新文档必须登记，见 tool/tests/test_docs_index.py）。仓库是公开的：PR 里不放私有 URL、服务器名、token、用户数据；真实 workspace 的截图/录屏留在 Raft。线性合入：rebase 到 origin/cindy/integration，跑全量检查，fast-forward 推送到 cindy/integration（GitHub 自动标记 PR 已合并）。`tool/prepare-handoff --pr --pr-body <文件>` 可在检查通过后推分支并创建/更新 PR。
- 设备/原生/播放器问题要在模拟器或真机复现并验证（widget 测试不算）；新增回归测试先在旧代码上跑红；结论只写测到的范围。
- 对没 @ 你的请求先读话题，看有没有人认领；打 tag、发布、推共享分支前先在话题里认领。
- raft_ui 只拥有设计tokens与交互组件，不依赖API/数据库/原生系统服务。每个新组件同时提供 SDK Widget Preview 和适用的主题、状态、键盘、语义验收。
- 客户端协议、同步reducer、持久化、平台服务与业务页面分离。Flutter chat UI 的 model/controller 是展示适配，不是Raft消息或同步权威。
- 公共 source mirror 的 experimental/未挂载合同不能当现网接口。以已挂载服务端路径与 Web 当前启用行为验证。
- 测试使用命名隔离本地环境，Web与Flutter共用fixture。保护其他服务/dirty files；不提交登录资料、token、私有URL或本地seed输出。
- Android 真机更新统一使用 `python3 tool/android-install --device <serial> --apk <arm64.apk> [--launch]`；先用 `--check-only` 验证制品。禁止用 `fvm flutter run/drive/test/install` 隐式安装正式 App，禁止卸载、清数据、降级或安装失败后的卸载重试。脚本核对实际 APK 的身份/架构/版本/签名与安装前后数据目录；任何失败立即停止。
- 首次安装只在用户明确要求时追加 `--first-install`，同样先做 `--check-only`；该模式必须确认设备上不存在此包（含其他用户与保留数据），禁止用作更新失败后的自动兜底。
- Android profile 测试只通过 `tool/performance/lab.py`，只接受预编译且实际包名为 `app.raft.raft_flutter.linkperf` 的 APK，并强制 `--keep-app-running`。只改 `applicationId` 不足以隔离：Flutter drive 的 source 包名可能取 namespace，结束时自动卸载。测试前后检查正式 App 仍在，不得把“找不到包”当成正常状态继续安装。
- 视觉对齐扩展套件（tool/parity-ext）的新增 / 修复流程见 docs/parity-ext-quickstart.md。
- 空闲 CPU：禁止 `scheduleTask`/`Priority.idle` 与零延迟自重排的 Timer（被拒绝的 idle 任务会经 `Timer.run` 热循环，见 docs/idle-cpu.md）；延后工作用 `RaftIdleTimer`，仅屏幕可见才有意义的轮询用 `RaftForegroundPeriodic`；常驻动画必须用 State vsync 并随 TickerMode/减弱动效停止。`test/idle_work_guard_test.dart` 扫描并要求白名单理由。
- 按功能矩阵报告实际覆盖；Widget Preview 不能替代Linux/Android平台无障碍、输入法、生命周期或通知测试。

- 原生流程遇到等待超时、点击未生效或未命中时，先用实际可见控件和真实指针输入复现，区分产品丢事件/延迟反馈与测试尚未完成布局，再决定修改产品或测试；保留初次失败。等待条件不能掩盖已经显示的控件丢点击。

## 产品体验原则（2026-10-10，Kevin 确认）

- 体验与 Web 一致，实现可以灵活：用户看到的行为对齐 Web；技术方案按 Flutter 最佳实践选择。滚动、打开、resize 的流畅度是硬门槛，优先于像素级一致。
- 对齐数据生命周期，不只对齐界面：移植任何功能时，同时对齐 Web 的加载时机、清空条件和事件更新方式。服务器级数据（Agent、成员等）只在账号 / 服务器 / 角色 / 权限变化时清空，不随频道切换清空；频道级缓存（消息窗口、任务列表、消息串）离开后保留；刷新保留旧数据并原地替换；实时事件按单条增量更新，不清空重拉。安全隔离放在 Web 对应的层级上，不擅自下沉到频道级。
- 首帧即最终：一行内容显示后，作者、头像、徽章、标签和布局不再变化；只允许真正异步的内容（如链接预览）和真实的实时更新改变它。不使用占位头像 / 昵称；必须占位时，占位与最终内容尺寸一致。优先使用消息自带字段完成首帧。
- 再次访问即时呈现：访问过的频道、消息串、动态 / 已保存 / 搜索 / 任务页再次打开时直接显示缓存，后台静默刷新，不出现加载态或整页刷新。
- tooltip 只补充看不到的信息（纯图标按钮、被截断的文字、头像状态等），不重复已可见的文字；列表滚动不得触发 tooltip；tooltip 与 hover card 只在指针静止时出现，任何滚动（滚轮、触控板、滚动条、键盘）立即关闭已打开的；应用 UI 一律用 RaftTooltip，不用原生 Tooltip 或 Material 的 tooltip: 参数。
- 验收必须覆盖：切换频道、打开消息串、收到实时事件时，已显示的行逐帧不变（widget 测试）；性能改动用 tool/performance 的 profile 基准对比前后数据。

## 并行开发与模型分工（2026-10-10，Kevin 确认；18:26Z 更新）

- 启动 subagent 时显式指定模型，不默认继承。
- 默认一律用 Sonnet 5.5：调研、视觉对齐、页面移植、底层绘制、功能开发都用 Sonnet。
- 只有 Kevin 明确要求时才用 Opus 5.5。
- subagent 只跑与改动相关的测试、`tool/flutter analyze` 和设计系统审计，不跑全量检查。
- 全量检查每个分支一次：负责人审核后用 `tool/prepare-handoff`（rebase + `tool/check-project`），通过后 fast-forward 推送到 cindy/integration，不再攒批次分支整批检查。
