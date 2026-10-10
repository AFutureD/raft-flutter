# Android 安装流程

正式 App 的更新只能走 `tool/android-install`，不使用 Flutter run/drive/test/install 的安装路径。Flutter 安装失败可能自动卸载重试；drive 默认结束时卸载，其 source 包名还可能取 Gradle namespace。2026-10-11 的 profile 测试只修改 applicationId，drive 清理阶段误卸载正式 App，随后重装导致登录数据丢失。安装前 dumpsys 已返回找不到正式包，但未被及时阻断。原日志保留在忽略的 `.local/`，此事件不能记录为无损更新成功。

## 更新已有 App

用 FVM 编译 ARM64 split APK，设置足够的 build number。split ARM64 的实际 versionCode 包含 ABI 偏移，以 APK 元数据为准。默认 build number 不一定能覆盖手机当前版本；脚本遇到降级会拒绝。

```sh
cd apps/raft_flutter
fvm flutter build apk --release --split-per-abi --target-platform android-arm64 --build-number <number>
cd ../..
python3 tool/android-install --device <serial> --apk apps/raft_flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk --check-only
python3 tool/android-install --device <serial> --apk apps/raft_flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk --launch
```

脚本在 macOS/Linux 宿主按设备持有自动释放的排他锁，只更新 user 0 已存在的正式包，验证 ARM64、target SDK >=37、版本不降级、签名一致。安装前从设备读取公开 APK 核验签名，不读取登录资料。唯一安装动作是 `adb install -r --user 0`；失败即停止，无卸载、清数据或重试分支。安装前后比较首次安装时间、CE/DE 数据目录 inode、versionCode 和实际 APK SHA-256；全部通过才启动。回执写入 `.local/android-installs/`，不进入提交。

这些检查验证安装身份和数据目录保留，不读取凭据，也不等于登录会话端到端验收。脚本拒绝缺失安装、签名更换、split 迁移等情况，不能通过重装来修复它们。

## 性能测试

另建命名隔离的测试工程，先编译 profile APK。`tool/performance/lab.py` 只接受实际包名 `app.raft.raft_flutter.linkperf` 的预编译 APK，通过 aapt 校验并复制成固定制品，避免并行构建替换待安装路径；强制 `--keep-app-running`，阻止 Flutter 结束时自动卸载。真机必须能核验正式包，测试前后自动比较其安装时间和数据目录，变化即失败；命名 emulator 可以从正式包不存在的状态开始，但前后状态也必须一致。正式包不能传入该入口，源配置中的 namespace/applicationId 不能替代 APK 身份核验。

```sh
python3 tool/performance/lab.py run --device <serial> --out .local/performance/<name> -- --use-application-binary=<absolute-test-apk>
```

仓库 `tool/flutter` 同时阻断 Android run/test/install 自动安装，以及未满足上述要求的 drive。Agent 必须使用这些入口，不能绕过工具直接调用 FVM 安装。宿主回归测试验证拒绝路径及完整更新事务，不通过在用户手机上故意降级、卸载或改签来验收脚本。

## 当前验证

安装脚本的 11 项宿主测试覆盖完整更新、只读检查、错误包名/架构/target、降级、签名不一致、包缺失/数据 inode 不可验证、安装失败不重试、更新后数据身份/制品不匹配、Flutter source drive 清理路径、同设备并发互斥与 SDK 37 签名输出。对实际设备先执行只读预检，再更新 ARM64 release：versionCode 4001、target 37、APK SHA-256 `62af0c844609cbe794b772d5a5b4a1c52bb90240f2ab99384886587e78964302`。前后 firstInstallTime 和 CE/DE inode 相同，实际安装 APK 哈希一致，完成后才启动；回执保留在 `.local/android-installs/`。

上述更新保护的是误卸载后当前 App 的数据，不能恢复此前被删除的登录资料。应用禁止备份 Keystore 会话及本地数据，没有找到可用的恢复来源。

同制品修复登录页系统栏：AuthView 使用共享 RaftSystemBarSurface，状态栏延续实际品牌栏颜色、底部延续 canvas；系统栏背景绘制在页面 Material 之后，避免被其覆盖。三主题的实际 Widget 像素及现有认证/系统栏共 8 项检查通过，分析器通过。Android ADB 截图确认 Brutal 登录页状态栏与品牌栏连续、底部 canvas 连续；未通过退出账号切换主题来扩大验收，没有修改登录信息。其余主题只具备 Widget 证据。

最终工具宿主检查 93 项通过，包括安装 11 项与性能工具 6 项。全工程诊断中 Dart 3189 项通过、3 项跳过、20 项失败，失败涉及桌面文件拖放、Activity 返回和旧导航头合同；分析器通过。该轮运行期间仍修改了安装工具及清理构建生成文件，sourceChanged=true，不能作为最终冻结工程 gate。初次结果及失败日志已保留；本次没有宣称全工程或消息下划线性能 gate 通过。
