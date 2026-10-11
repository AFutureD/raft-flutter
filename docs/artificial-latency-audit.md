# 不必要交互等待复查（2026-10-11）

基于 `ff6e87f`；Kevin 在 #raft-flutter:5eb81aac 的 db8c7116 批准即时预览，f108f60b 要求全 App 复查。此次修复 Activity 首击固定等待和搜索手动重试的等待。下表给出仍值得处理的串行加载；这不是整 App 已无卡顿的结论。

## 已修复

| 入口 | 原因及原行为 | 新行为及验证 |
| --- | --- | --- |
| 桌面 Activity → 详情 | `ResourceView.activateActivity` 的 220ms Timer 先阻止详情选择，再阻止热缓存和 HTTP；每次都等。 | 首击同步选择预览、立即开始读取。识别第二次点击的 Timer 只保留行结构，不延迟预览。实际 WorkspaceView 在下一帧前已选择 thread，三主题逐帧检查独立详情、焦点和请求；Home 不受影响。 |
| 首击后的原鼠标位置 | `DesktopMasterDetail` 从全宽列表变成列表/详情两列，双击的第二下可能落入详情；Unread 的首击还会移走行。 | 桌面 Activity 从首帧保留预览列。识别期间固定列表顺序和被点行最低高度，已读徽章立即消失；同一坐标的第二下使用首击原始 DTO 打开主页面。超时后 Unread 行正常移除。筛选、账号、服务器、权限或导航变化立即使旧手势失效。 |
| QuickSwitcher 的 Retry | `fetch(retry: true)` 仍走输入专用的 200ms 防抖；按钮已点下却多等一次。 | 手动重试立即调用请求；输入继续合并 200ms 内的编辑。实际 Retry 点击检查请求立即开始，改查询后的晚到重试答案被丢弃。 |

macOS 通过只读 MethodChannel 获取 `NSEvent.doubleClickInterval`，默认值/不可用时用 Flutter 的 300ms。设置读取不阻塞首击；识别中的手势保持其捕获的时间窗。SDK 组件不依赖原生系统服务，由业务宿主传入时长。第二下只升级当前同一行的预览；原 DTO 保留首次未读/提及焦点。首击使用 REPLACE，第二下替换掉临时预览的 URL 槽并增加一个 canonical PUSH，Back 返回 Activity 列表；两次 URL 更新在通知前完成，不绘制中间空页。冷预览已经发出的请求由既有导航/权限 fences 拒绝晚到结果。

## 接下来真正值得优化的方向

| 优先级 | 代码与证据 | 建议与验收 |
| --- | --- | --- |
| 高 | `WorkspaceController.selectChannel`：先 `await _restoreDraft(next.id)`，再读 window 磁盘缓存，之后才 `client.messagePage`。草稿中共享附件还按文件串行恢复，最后读取发送 attempt。已用真实 controller + 缓存 fixture 复现：把 draft 读取挂起 300ms，期间消息 GET 为 0；释放后才开始 GET。 | 将独立的网络消息读取、磁盘窗口恢复和草稿恢复分别启动。不要只改成 `unawaited(_restoreDraft)`：缓存 FIFO 仍会排队，且需要保留撤权顺序。磁盘结果只能在新网络窗口尚未接受时补位；草稿必须拒绝覆盖用户已开始编辑的内容。覆盖慢附件、慢缓存、快速切频道、权限变化及晚到磁盘结果。 |
| 高 | 冷启动 `WorkspaceController.bootstrap` 在已经读出 channels 后，仍等 `restoredEntities` 和 `restoredTranslations`，又等 selection/window/draft，才通知第一批目录和消息呈现。这是代码依赖链证据，未测原生耗时。 | 先发布已接受、已通过权限验证的目录/窗口；独立目录和翻译静默补充。不能删除身份、角色和撤权验证。用三条独立挂起任务确认消息首帧不等待无关恢复；native profile 比较首次可交互时间。 |
| 中 | `loadServerDirectory` 与 `refreshServers` 的新目录先写 `_save('servers',...)` 再最终通知界面；慢磁盘可能延迟服务器菜单更新或后续选服。已有 channel 消息刷新在 `notifyListeners()` 后才保存，说明并非所有路径都必须等待落盘。未测此入口耗时。 | 先完成新目录的撤权/选择决策，再发布结果，普通缓存写入后台排队。涉及目录消失和 purge 的路径要维持当前顺序；不能将所有 `_save` 一律取消 await。测试慢写入、被移除服务器与角色变化。 |
| 低 | `SourceActivityUnreadStore` 首次后台 inbox badge 读取等 2 秒。页面本身独立读取，打开 Activity 不等它；已有已接受数据即时使用。 | 这是 Source 的后台启动错峰策略。仅在“冷启动铃铛两秒无数字”确实影响用户时比较 idle 调度与主动访问立即拉取，不能当作此次 thread 220ms 的另一来源。 |

上一轮 [Android 全树性能审计](android-performance-audit.md) 中的整工作区通知、重复深复制/投影、长列表全量构建仍是独立方向。它们需要 profile 数据和重建范围证据；组件嵌套层数本身不是缺陷，不能为减少“层数”牺牲权限、布局或语义边界。

## 保留的等待及排除项

- 搜索、转发目标输入的 200/250ms 防抖；实时目录/列表事件 150/500ms 合并；它们合并重复工作，已显示内容保留。Retry 已单独绕开输入防抖。
- HoverCard/Tooltip 的静止等待与 120ms 关闭宽限，复制/保存提示的 1.4–2 秒寿命、提及操作完成后 450/750ms 的状态展示/移除、消息高亮期限：结果先显示，这些 Timer 不挡导航。
- 后台字体和消息准备的空闲调度、翻译请求批处理、磁盘保存合并：避免把大批工作挤在交互帧。它们不是首击预览门槛；是否仍有 CPU 尖峰要单独采样。
- polling、重连/backoff、鉴权重试、网络超时和 Computer 重启超时；Android ADPF 的 400ms 空闲回收；共享文件寿命回收：不是人工延迟用户点击。
- 通知的 100ms 重试属于原生通知设施准备；消息图片导出的 50ms 等待与 `endOfFrame` 属于图片准备/绘制，不是打开消息页路径。
- fork 的 `flutter_chat_ui` EmptyChatList 延后淡入、ChatAnimatedList 首次滚动等待和键盘 100ms 合并，需按实际挂载判断。当前 `RaftChatView.chatAnimatedListBuilder` 使用 `RaftMessageTimeline`，不能把未挂载的旧默认列表 250ms 算作产品聊天延迟。
- App 自有 Swift/Kotlin/ObjC 包装源码没有找到 `asyncAfter/Thread.sleep/delay/sleep/Timer` 导航门槛；没有改系统输入设置、用户前台窗口、正式 App 数据或部署。

## 方法及边界

扫描 App 与全部本地 packages 的 406 个非生成 Dart 库文件，得到 103 个延时/防抖文本命中，分布在 46 个文件；排除 test/dev/previews/example/build；再复核 Timer、Future.delayed、防抖，以及频道、线程、详情、启动/缓存/目录恢复的 await 依赖。库存保留文件路径、行号和原文；命中包含注释、声明与 cancel，不把命中数当问题数。原生包装也作延时模式筛查。控制器草稿挂起实验和实际 widget 点击独立于 native 性能测量；它们证明控制流，不代表手机/真实磁盘的固定耗时。

只有经过实际调用链与可复现条件确认的前两项当场修复；未测候选明确标出。完整批次工程检查由 Cindy 执行。原生 profile 工具只使用本地假数据与后台 Computer Use；点击延迟、帧耗时、真实120fps覆盖是不同指标，不能相互替代。
