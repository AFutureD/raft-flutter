# Android 启动图标

使用官方 `public/brand/raft-icon.svg` 的标记，与 `packages/raft_ui/lib/src/brand_marks.g.dart` 中 `RaftBrandMarkKind.icon` 的 path 完全相同。普通图标采用黑色标记、纸色 `#FFFAEF` 镂空填充与 Web 品牌黄 `#FFD440` 背景（`tool/design-source/raft-web-26f77ef/index.css` 的 `--color-brutal-yellow`）。

- Android 26+：`mipmap-anydpi-v26/ic_launcher.xml` 提供自适应前景与背景，由桌面决定圆形、圆角方形等裁切。
- Android 33+：`mipmap-anydpi-v33/ic_launcher.xml` 增加 `monochrome`，使用独立 `ic_launcher_monochrome.xml` 单色层，保留原标记的透明镂空。壁纸、系统深浅主题及桌面的主题图标开关决定最终颜色，不读取 Flutter 主题或动态修改应用图标。
- Android 24–25：五套传统密度 PNG 使用同一标记，替换 Flutter 默认图标。
- Manifest 的 `icon` 与 `roundIcon` 都引用同一资源，避免不同桌面选择不同品牌标记。

矢量层为 108×108dp，标记等比居中、宽 56dp。单色标记的 4 倍分辨率检查全部非透明像素距中心最多 32.19dp，位于 33dp 安全半径内；圆形和圆角方形及示例深浅主题预览均检查。普通前景以标记的外轮廓作纸色底层，上覆原黑色路径，纸色只填入镂空；背景仍为品牌黄。PNG 为 48/72/96/144/192px，从相同 SVG 路径用宿主现有 `rsvg-convert` 渲染，无新增 Flutter 依赖。

方案依据 [Android 自适应与主题图标文档](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)。本地渲染预览仅验证路径、留白和示例颜色，不等于设备桌面主题图标验收。

## 通知小图标

前台消息、测试通知与后台轮询共用 `drawable/ic_notification.xml`：24dp 矢量、20dp 居中白色 Raft 标记、透明背景与镂空，由 Android 着色。通知初始化默认图标和每次发送的 `icon` 均明确引用 `ic_notification`，不使用带背景的 adaptive launcher。`raw/keep.xml` 只保留这个通过名称查找的资源，避免 Release 资源缩减删除它。没有新增 Flutter 绘制或内存加载逻辑。

已验证通知服务的初始化、普通消息与测试通知配置，以及实际 Release APK 保留的矢量资源。Android ARM64 Release 6019 已通过保留数据的覆盖安装；从手机拉取的 APK 与构建制品 SHA-256 一致。2026-10-11，Kevin 手工确认状态栏与通知卡片图标显示正常；这不是自动化平台验收。
