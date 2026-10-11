# Activity 即时预览原生对比（2026-10-11）

修复后，点击不再等待 220ms 的单/双击仲裁才选择详情。在 MacBook-Pro 的隔离 macOS profile 窗口中，5 次热缓存打开的「鼠标松开 → 详情选中」中位数从 226.602ms 降为 0.665ms，「鼠标松开 → 选中后首帧 raster 完成」中位数从 250.943ms 降为 14.955ms。此结果验证移除导航门槛；不代表真实服务器、冷磁盘或稳定 120fps。

## 数据

所有时间从 App 收到真实 PointerUp 开始计，不含系统投递前的输入延迟。第一帧按 FrameTiming 中 buildStart >= selectionUs 的首帧选择；UI 回调与 raster 线程完成先后可不同。

| 条件 / 指标 | Before 70bdfa0 | After e1d9cb1 |
| --- | ---: | ---: |
| 首次冷打开 → 选中（单次） | 222.894ms | 0.296ms |
| 首次冷打开 → 首次 UI 帧回调（单次） | 255.991ms | 39.559ms |
| 首次冷打开 → 首帧 raster 完成（单次） | 260.129ms | 60.274ms |
| 热缓存 → 选中（5 次中位数） | 226.602ms | 0.665ms |
| 热缓存 → 选中（最小–最大） | 222.172–246.154ms | 0.454–1.714ms |
| 热缓存 → 首次 UI 帧回调（5 次中位数） | 251.029ms | 16.801ms |
| 热缓存 → 首帧 raster 完成（5 次中位数） | 250.943ms | 14.955ms |
| 热缓存 → 首帧 raster 完成（最小–最大） | 246.189–262.929ms | 12.977–32.307ms |

冷打开的 After 首帧 build 30.434ms、raster 22.543ms，仍有初始化成本。没有测显示器 present / vblank，也没有用此次数据证明 8.33ms 帧预算。首帧指标是详情被选择后的首帧，不等于完整远端回复已下载和显示的时间。每次观察都确认 Fixture parent 与 Fixture reply 已实际显示；热缓存分类在 PointerUp 时检查真实 ledger 内的回复。

## 相同条件与原始证据

- Before：`70bdfa019bd518870ee93e6e8224edb1d153de6d`。After 产品：`e1d9cb187fa26b75c8f67c55986c41e99609c3fb`，基于同一提交；后续仅补报告。
- 两边复制同一 `tool/performance/activity_preview.dart`，SHA256 `6da2f98af5be508b11998cb0ffdb0f1b93f7afd704c8cbce2f672ac3e8ad8005`。真实 WorkspaceView / ResourceView / WorkspaceController；内存账号、目录和本地 HTTP adapter，不连接任何服务器、不读取正式账号。
- Flutter 3.47.6 / Dart 3.13.5，macOS 27.0.1 arm64。两个 Profile 构建所含 FlutterMacOS 二进制 SHA256 都为 `695f85ae21ae7ae46c51855e8c45496a2e882bd9631335eed38718aad6fd1339`；完整 SDK、App/AOT、源提交与协议回执在证据包。
- 窗口截图均 2400×1664 pixels，不改变窗口大小。每边新进程冷点击一次，随后 Reset Activity → 点击五次；重置只关详情，保留 ledger 热窗口。两边都点击截图坐标 `[400, 490]` 的同一行；修复后的列表从第一帧保留详情列，因此布局差异是本次产品改动的一部分。
- 输入和退出只使用内置 Computer Use 绑定的后台隔离 App，不激活窗口、不移动系统指针。原生 App ID 分别 `app.raft.activityPreviewBefore` / `app.raft.activityPreviewAfter`；正式 App 没有安装、更新、退出或写数据。测完两隔离进程已退出。
- 样本仅在点击 Export samples 后写盘，测量路径不写日志。证据包保留 before/after-native.json、native-summary.json、native-receipt.json、相同 harness 和构建/相关测试日志。

这是一组顺序运行的本机诊断样本，未控制后台负载、温度及显示器刷新率，样本量也有限。移除固定等待的结论同时由实际点击测试和调用链支持；后续帧耗时不能作严格单因素归因。

初次编译的 Timeline.now 写法与 FramePhase 导入问题已修正，保留失败记录。先前 ff6e87f 校准组的 fixture ledger 未绑定 server，且先点过 AX 语义操作，不能用于冷/热分类；该数据单独归档，未纳入上表。AX 语义点击不产生 PointerUp，正式组全部使用窗口绑定的坐标输入。

## 复测

在隔离 worktree 使用仓库的固定 SDK wrapper，从 `apps/raft_flutter` 执行：

```sh
RAFT_FLUTTER_BIN=/path/to/pinned/flutter ../../tool/flutter build macos --profile --no-pub \
  --target=../../tool/performance/activity_preview.dart \
  --dart-define=RAFT_ACTIVITY_PREVIEW_REVISION=reviewed-commit \
  --dart-define=RAFT_ACTIVITY_PREVIEW_OUT=/absolute/path/samples.json
```

仅将编译后的 App 复制到测试目录，使用独立 CFBundleIdentifier / 名称并重新 ad-hoc 签名。生命周期和指针输入仍使用内置 Computer Use 后台绑定；若绑定不可用，停止依赖窗口的动作，不用 CLI 启动或全局输入替代。观察可点击行后冷点击一次；每次 Reset 后观察列表，再点击同一行五次；确认回复实际显示，然后 Export。保存样本、源提交、harness/engine/AOT 的 SHA256，再退出测试 App。

## 回归与审计

同基线下 194 个相关测试通过，覆盖即时首击、500ms 系统双击窗、350ms 同坐标第二击、Unread 行高度/顺序、首次焦点、读状态、Back/Close、冷 metadata、三主题和权限/晚到响应；测量高度写法调整后另跑 5 个手势测试通过。根静态分析无问题，设计系统审计无增长。初次设计系统检查发现裸 minHeight 默认值新增一项，已用测量值 / 空约束替代并复核通过，失败日志保留。完整批次检查交由 Cindy。

全 App 人工等待筛查及尚未修改的串行加载候选见 [不必要交互等待复查](artificial-latency-audit.md)。
