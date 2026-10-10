# 移动端 section 横向切换调研

2026-10-11。五类页面已实现横向分页；局部组件检查已完成，Android 实机手势验收尚未完成。

## 证据范围

通过 ADB `10.77.0.24:38213` 只读获取手机上 `build.raft.app` 的已安装 APK：Raft 1.13.0，versionCode 11300008，targetSdk 36。APK SHA-256：`89ea95a3d2dbaf02eedda89408f1240726a19738ebe86541624afb9c52e7acf9`。反编译材料存放于忽略目录 `.local/android-navigation-audit/`，不作为产品源码提交。

检查 DEX 调用链，而非仅凭类名推断。`components.TabPagerKt.TabPager` 调用 Kuikly Compose `HorizontalPager`，滑动由 `TabPagerGesturePolicy.swipeEnabled` 控制，默认 true。产品调用入口为 `ThreadPageKt` 经 `SlockTabbedScaffold`、`SharedInboxPanelKt.SharedActivityPanelContent`、`MembersPageKt.MembersDetailContent`。该 Android 版本的平台 startEdgeInset 返回 0；组件具备边缘避让能力不代表此版本实际启用了非零边缘留白。

Computer Use 原生连接报错，无法在后台定向操作手机，因此以下是 APK 静态证据与 Flutter 源码核对，不代表实际手势、返回边缘冲突、帧率或无障碍验收通过。公开 source mirror 主要提供 Web 参照，不能代替上述 Android 证据。

## 已覆盖页面

| 页面 | Flutter 现有 section | 官方 Android 证据 | 实现 |
| --- | --- | --- | --- |
| 频道、私信会话 | Chat / Tasks / Files；支持用户排序 | `ThreadPageContentContent` 在 `showModeTabs` 时调用 `SlockTabbedScaffold` → `TabPager`；`KuiklyThreadTab` 为三个 section | 已支持；按当前显示顺序滑动，保留聊天编辑器、草稿和各页滚动位置 |
| Activity | All / Unread / Mentions / Saved / Done | `SharedActivityPanelContent` 调用 `TabPager`；该 APK 的 `InboxFilter` 为 All / Unread / Mentions | 已支持；Flutter 五个已启用视图保持一致交互，Saved / Done 属于 Flutter 扩展覆盖，不能声称在此 APK 验证过 |
| Agent 详情 | Profile / Activity / Chat / Reminders / Workspace / Apps / MCP，按权限显示 | `MembersDetailContent` 调用 `TabPager`；该 APK 的 `MembersAgentDetailTab` 为前六项 | 已支持；只滑动到当前有权限的 section，MCP 是 Flutter 额外覆盖 |
| 设置 → Connected Apps | Marketplace / Installed / My apps | 未发现此 APK 的直接 section pager 调用；不据此推断动态 WebView 内部行为 | 已支持；这是三个内容 section，非布局偏好 |
| 设置 → 反馈列表 | All / Active / Ended | 未发现此 APK 的直接 section pager 调用 | 已支持；保留每个列表的位置，详情/新建反馈仍走层级导航 |

Flutter 对应实现：`features/conversation_panel.dart`、`features/resource_view.dart`、`features/agent_detail_view.dart`、`features/integrations_views.dart`、`features/source_feedback_view.dart`。这些页面现接入共享 `RaftSectionPager`，点击与滑动更新原有 section 状态；桌面不启用横滑。

## 不纳入 section pager

- Task 的 Board / List 是同一数据的布局选择；看板横向拖动用于浏览任务列，不应被切页手势抢占。
- 搜索的频道、发送人、时间、附件类型等是组合筛选，不是互斥 section。当前 Flutter 搜索页没有需要分页的 section tab。
- 主题、翻译模式、订阅周期等分段按钮是设置值，不是页面。
- 分享页的服务器选择改变权限/数据范围，不是同一页面的 section。
- 底部 Home / Tasks / Members / Settings 属于主导航，不因本次 section 对齐顺带加入横向切换。桌面分栏和编辑器 tab 不纳入移动手势改造。

## 实现约束

采用 Flutter 标准 PageView/分页 controller，通过业务层已有 tab 状态同步点击与滑动，不增加第二份路由权威；同页切换不新增返回栈条目。共用分页交互只持有展示状态，raft_ui 不读取 API、账户或原生服务。

按需创建内容；已访问 section 保留必要草稿、过滤条件及滚动状态，隐藏页面暂停动画并排除焦点/语义。不能为滑动提前请求全部 Agent 工作区、Files 图片或全部 Activity 数据。频道、账户、服务器及权限变化时释放或撤销旧 section 状态。

重点局部验证：点击与滑动同步、反向滑动、动态权限删减 tab、用户排序、返回后位置、编辑器/键盘，以及与任务看板、图片缩放、横向代码块和 Android 系统返回手势的竞争。SDK Widget Preview/组件测试不能替代实机手势与生命周期验收。

## 实现与局部验证

共享组件使用标准 `PageView`，首次选中才创建业务内容；已访问页面保留元素，隐藏页面排除焦点、语义和指针输入并暂停动画。远距离点 tab 直接切换，不依次加载中间页面。频道 section 仍替换既有 URI 槽，不添加返回历史。权限或账户范围改变时销毁旧分页状态。

Activity 五个视图共享单个数据 owner；相邻页仅投影已接受的缓存窗口，不新增订阅或预取。每个视图保存独立滚动位置，切回后先展示缓存再原地重验，移动 tab 条跟随选中项滚动。Agent 隐藏数据页与频道 Tasks 延迟刷新，Files 重新进入时后台刷新；权限收缩清除旧内容。Connected Apps 和 Feedback 复用各自原有数据 owner 与本地投影。

保留页的 repaint boundary 可能在缺少有效屏幕变换时重绘。共享 CSS 文字和边框此时采用局部对齐，避免 NaN 绘制坐标；已挂载页面仍按原有屏幕坐标对齐，不新增逐帧文字测量。

- 业务局部测试 86 项通过，覆盖移动横滑、单一 Activity owner、缓存首帧、位置恢复、Files/Agent 原地刷新、权限撤销及设置/反馈回归。
- 共享组件局部测试 32 项通过，覆盖三种主题的 Widget Preview、编辑器草稿、列表位置、延迟创建、排序/删减 section、键盘/语义、横向子列表优先消费手势，以及原有文字基线。
- FVM 静态分析通过，设计系统审计未增加漂移。
- 未运行全量测试。Computer Use 原生连接不可用，因此未操作手机，也未以 ADB 输入代替；Android 返回边缘手势、IME、生命周期、无障碍和帧率仍待实机验收。组件测试通过不能推断这些平台结果。

## 频道切页的拖动帧修正（2026-10-11）

Flutter `PageView.onPageChanged` 在滚动位置越过半页时触发，原实现此时立即替换 `chatTab`、通知整个 workspace 并首次挂载 Tasks / Files。拖动或回弹尚未结束，聊天的 `Visibility` 又将仍有部分在屏幕内的消息页改成 Offstage；反向拖入聊天时也要重新激活布局。这把业务更新、目标页面初始化和聊天布局变化放进了滚动动画帧。

共享 pager 现在仅在自身水平滚动结束时提交选项；点 tab、键盘与语义切换仍立即接受原有选项。已访问页面沿用 PageView 的保留与绘制边界，未访问页面仍不提前读取。拖动越过半页后又拖回来不会提交中间 section；拖动中的外部路由 / tab 选择仍优先。频道聊天保留已布局内容供反滑直接绘制，presentation 由原有 `Visibility` 与 pager 的 `TickerMode` 共同控制；非活动聊天不能发送、翻译请求或发已读回执，并继续排除焦点、语义与指针输入。

定向组件检查覆盖半屏后的逐帧选项、构建、请求计数，取消拖动、外部选项覆盖、三主题聊天缓存反滑、草稿 / 游标与隐藏已读门禁。它验证动画期间不再触发这批业务工作，不是实机帧率数据。Computer Use 原生后台连接不可用，本次没有运行原生 profile 前后基准，不能据此声明 Android 或 macOS 的 60 / 120 Hz 帧率验收通过。
