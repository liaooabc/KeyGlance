# 键览 KeyGlance

双击 ⌘，立刻把**当前前台 App 的全部菜单快捷键**铺在屏幕上 —— macOS 26（Tahoe）原生 + Liquid Glass 面板。

参考产品：FlyKey（键指如飞）。这是一个从零写的原生实现，不是套壳。

## 它现在能做什么

- **双击修饰键唤出**：默认双击 ⌘，可在设置里换成 ⌃ / ⌥ / ⇧，或彻底关闭双击触发。
- **读取真实菜单**：通过 Accessibility 读前台 App 的菜单栏，所以显示的快捷键和菜单里完全一致（含 ⌘⇧⌥⌃ 组合、⌫ ↩ ⇥ ⎋ ↑↓ 等符号键、F1–F12）。
- **一屏铺开的清单**（学「键指如飞」的排法）：菜单名当行内的小节标题，条目在等宽的列里自上往下流，一列满了就开下一列；**快捷键在左、标题在右**，一组键帽右对齐到统一的栏宽，于是整列标题排成一条直线。一个菜单长到跨列时，续列顶上再写一次菜单名。
- **靠长高而不是靠压缩**：面板从最矮（240）开始长，越长每列能放的条目越多、需要的列越少，取「刚好放得进屏宽」的那个高度（上限 = 屏高 − 80）；行高依次试 26 / 24 / 22，优先用最舒展的。条目多到满高、最紧行高都放不下时才允许横向滚动 —— 任何情况下都**不裁切、不压缩标题**。
- **小节标题不抢戏**：菜单名是 11pt 半粗的次要色，贴在它那一组条目上方（`NSCellView` 不是 flipped，所以画在行的底部），没有色块、没有分隔线。
- **尺寸贴合内容**：列宽 = 最长的一行（键帽栏 + 标题 + 内距），夹在 148–300 之间；面板宽 = 列数 × 列宽 + 列间距（10pt），上限 = 屏宽 − 60；末列留 14pt 给滚动条，键帽不会被遮挡。
- **「常用」分区**：统计你在这个 App 里最常按的组合键，排成第一列（只按次数计数，不记录任何文字）。
- **「系统」分区**：读取 `com.apple.symbolichotkeys`，显示调度中心、应用窗口、聚焦、强制退出、截屏等系统级快捷键，并跟随你在系统设置里的改动。
- **搜索**：打开即聚焦搜索框，输入即筛选（中英文、快捷键符号都能匹配）。
- **原生交互**：`esc` 关闭、面板外点一下关闭、再双击一次关闭；关闭后焦点回到原来的 App。
- **Liquid Glass**：面板用 `NSGlassEffectView`（macOS 26 的系统玻璃材质），边框、圆角、明暗全部交给 Apple 自己画，没有自绘描边。
- **明暗跟系统**：玻璃底色用 `NSGlassEffectView.tintColor`（不再手叠色块），并监听系统主题切换实时重算；面板开着时切换明暗也会立刻跟着变。
- **内容贴边**：窗口是隐藏标题栏的 `.titled` 窗口，`NSHostingView.safeAreaRegions = []` 去掉系统预留的标题栏安全区，否则面板顶部会空出一条。
- **图标日/夜两套**：用 Icon Composer 的 `.icon` 包（`Tools/makeicon.swift` 生成，`actool` 编译成 `Assets.car`）。浅色＝白底黑 ⌘，深色＝黑底白 ⌘，跟随系统自动切换。
- **窗口形状也是系统的**：面板窗口是 `.titled + .fullSizeContentView`（标题栏透明、红绿灯隐藏），不是 `.borderless`。borderless 窗口的阴影按矩形计算，圆角处会露出直角的黑影；带标题栏的窗口由系统直接给出圆角与圆角阴影。
- **进场动画**（学 Launchpad）：玻璃底板一次到位（先隐形上屏 50ms 让玻璃采样背景，再瞬间显示），内容用弹簧从 0.96 缩放 + 淡入到 1；收起时内容 0.12s 下沉淡出再移除窗口，全程没有整窗透明度动画，所以不闪也不卡。
- **横向完全锁死**：面板的表格从不启用横向滚动条（`hasHorizontalScroller = false`、弹性为 `.none`），表格宽度恒等于可视宽，并在滚动通知里把 `origin.x` 钉回 0，触控板横滑也推不动。
- **不会横向晃动**：内容装得下时表格宽度锁死等于可视区（`hasHorizontalScroller = false`、`horizontalScrollElasticity = .none`），只有列多到放不下才允许左右滚。
- **滚动条只在滚动时出现**：面板和设置页的滚动视图都强制 `scrollerStyle = .overlay` + `autohidesScrollers`，即便系统偏好是「始终显示」（接了鼠标时就是这种），也不会常驻一条。
- **不闪**：打开/关闭都不对窗口做透明度动画（partial alpha 的玻璃会透出亮底，看着像闪白），窗口带着内容一次性出现、收起时直接消失；冷启动时内容用 0.15s 淡入。明暗和玻璃底色取自系统偏好，避免首帧用了浅色 tint。
- **开得快**：常用 App 第二次起 ~12ms 出面板；首次也有内容缓存 + 预建窗口，见下面「性能」。
- **菜单栏常驻**：**左键单击图标开/关面板**（再点一次收起），**右键（或 ⌃ 单击）出菜单**：关于 / 设置 / 退出。触发方式、权限等其余设置都在设置面板里。
- **设置窗口（单页）**：没有侧边栏，通用 / 权限 / 更新 / 关于 依次排在一页里滚动；触发方式、双击间隔（0.20–0.60 秒）、显示搜索框、显示菜单栏图标、面板动画、登录时启动；「常用」分区 / 系统快捷键 / 使用记录三个开关和清除按钮。
- **更新在设置里**：显示当前版本，按钮手动检查 GitHub 上的 latest release（显示「已是最新」或「有新版本 x.y.z」），可以看发布说明，也可以一键「下载并安装」；「自动检查更新」默认开（启动时及每 24 小时最多一次），「自动下载并安装」默认关。菜单栏右键菜单里也有「检查更新…」，有新版本时标题会变成「有新版本 x.y.z…」。
- **首次引导**：申请辅助功能权限的欢迎窗口，带"已授权，重新检测"。

## 环境要求

- macOS 26.0 及以上（面板用 `NSGlassEffectView`，26 才有）
- 默认只编 arm64 原生二进制（Apple Silicon）；需要 Intel 机器也能跑时用 `./build.sh --universal` 出通用版

## 编译 / 安装

```bash
cd KeyGlance
./build.sh            # 编译到 build/KeyGlance.app，生成图标并 ad-hoc 签名
./build.sh --install  # 再安装到 /Applications
```

首次运行后在「系统设置 › 隐私与安全性 › 辅助功能」勾选「键览」，否则读不到别的 App 的菜单。

## 代码结构

```
Sources/
  main.swift                    入口（accessory 菜单栏 App）
  AppDelegate.swift             状态栏菜单、触发调度、窗口管理
  ModifierDoubleTapMonitor.swift 全局双击修饰键检测（含间隔、其它键干扰复位）
  ShortcutExtractor.swift       AX 菜单栏遍历 → 快捷键模型
  KeyCapFormatter.swift         三种来源（菜单/AX/系统热键/按键事件）统一成键帽
  SystemShortcuts.swift         读 com.apple.symbolichotkeys → 系统快捷键分区
  UsageTracker.swift            按 App 统计组合键次数 → 「常用」分区
  ShortcutPanelView.swift       面板 UI（SwiftUI：头部/页脚/搜索）+ 列/行/尺寸计算（PanelColumns）
  ShortcutTableView.swift       清单本体（AppKit NSTableView，一列 = 一列排好的行，自绘单元格）
  SampleShortcuts.swift         调试样张（KEYGLANCE_SAMPLE=1 时替代真实菜单，照 Final Cut 的形状）
  ShortcutPanelController.swift NSPanel + 玻璃容器 + 定位/进出场
  SettingsView.swift            设置窗口（含「更新」区）
  Updater.swift                 自更新：查 GitHub Release → 下载 → 验包 → 替换脚本
  Version.swift                 版本号比较（点分段按整数比）
  OnboardingWindowController.swift 首次权限引导
  SettingsStore.swift           UserDefaults 配置 + 登录项
Tools/makeicon.swift            图标生成（超椭圆 + ⌘，输出 iconset/icns）
Resources/Info.plist            LSUIElement = true，最低 macOS 26
```

调试用环境变量（可忽略）：

| 变量 | 作用 |
| --- | --- |
| `KEYGLANCE_DEMO=1` | 启动 1.2 秒后自动弹面板 |
| `KEYGLANCE_SHOW_SETTINGS=1` | 启动后直接开设置窗口 |
| `KEYGLANCE_ONBOARDING=1` | 强制显示首次引导 |
| `KEYGLANCE_APPEARANCE=light\|dark` | 强制面板明/暗 |
| `KEYGLANCE_DEBUG=1` | 打印双击触发日志与耗时 |
| `KEYGLANCE_NOAUTOHIDE=1` | 面板不因别的 App 激活而自动关闭（调试用） |
| `KEYGLANCE_FAKE_VERSION=0.9.0` | 假装本机是旧版，用来查看/测试「有新版本」状态 |
| `KEYGLANCE_SAMPLE=1` | 用内置样张（10 个菜单、132 条）代替真实菜单，不需要辅助功能权限就能看排版 |
| `KEYGLANCE_DEBUG_LAYOUT=1` | 打印列宽 / 列数 / 面板尺寸 |

## 更新（自更新）

版本信息只认 GitHub：`GET https://api.github.com/repos/liaooabc/KeyGlance/releases/latest`，tag 是版本号（去掉 v），附件优先取 `.zip`（将来换 `.dmg` 也能装）。比较版本号按点分段整数比，所以 1.10 > 1.9。

装新版的流程（Sparkle 那套的精简版，代码在 `Sources/Updater.swift`）：

1. 下载附件到临时目录（`URLSessionDownloadTask` 带进度，小于 100 KB 直接判定不对）。
2. 解包（`ditto -x -k`，dmg 则 `hdiutil attach`），在解出来的目录里找 `.app`。
3. **验包**：`CFBundleIdentifier` 必须等于自己的 bundle id，`CFBundleShortVersionString` 不能低于发布版本，否则中止。
4. 拷到 `~/Library/Application Support/KeyGlance/Update/新版.app` 暂存。
5. 写一个 shell 脚本并启动它，然后本进程退出；脚本等进程消失后「备份旧包 → `ditto` 放新包 → 去掉 quarantine → 重新打开」，任何一步失败都把旧包放回去再打开。

几个刻意这么做的点：

- **不覆盖正在运行的包**：运行中的 App 被换掉最容易留下半新半旧、一开就崩的包，所以替换一定发生在退出之后。
- **先检查写权限**：`/Applications` 不可写、或 App 是从 DMG/压缩包里直接运行（路径里有 `AppTranslocation`）时，在退出前就报错，不会出现「App 没了也没装上」。
- **失败一律弹系统警告框说清楚原因**（权限、磁盘、网络都可能挡），不静默失败。

调试用：`KEYGLANCE_FAKE_VERSION=0.9.0` 假装本机是旧版，可以直接看「有新版本」那一行并走完下载安装（会替换并重启真正运行的那个 App，建议先从副本目录启动再试）。

## 性能（实测，1512×982 屏）

| 场景 | 耗时 |
| --- | --- |
| 首次打开某 App（以访达 107 条为例） | 面板 90ms 出现，首行在其后 ~58ms 绘制 |
| 同一 App 再打开 | ~20ms（内容、列、单元格都复用，窗口尺寸不变） |
| 滚动 | 只绘制可见单元格（NSTableView 虚拟化），不再整棵树重排 |
| AX 菜单读取 | 139ms → 55ms（一次性多属性取值，1 次 IPC/条） |

做法：`AXUIElementCopyMultipleAttributeValues` 批读、按 App 缓存解析结果、启动时预建面板与玻璃视图、先按最终尺寸铺面板再填内容（不再有"先小后大"的窗口跳变）、`NSHostingView.sizingOptions = []` 防止 SwiftUI 反过来改窗口尺寸。

## 已知边界

- 「常用」只统计带 ⌘/⌃/⌥ 的组合，且只存"次数"，不存文字；可在设置里关掉并一键清除。
- 系统快捷键表来自固定 ID 映射，个别非常冷门的项若被系统改名可能对不上；用户自己改过的绑定会以 plist 里的值为准。
- 只显示走 **菜单栏** 的快捷键。没有菜单项的快捷键（如 App 自定义的全局热键、终端里的快捷键）读不到——这一点和 FlyKey 一样。
- 有些 App（游戏、部分 Electron/Unity 自绘界面）不暴露 AX 菜单，会显示"没有可显示的快捷键"。
- 与 FlyKey 同时运行会抢同一个双击 ⌘；把其中一个改成 ⌃ 或 ⌥ 即可。
- 图标目前是单套（深色下系统会自动压暗）；想要真正的日/夜/着色三套图标需要改用 Asset Catalog + `actool`（下一步可做）。
- 登录项用 `SMAppService`，ad-hoc 签名下若被系统拒绝，设置里会给出提示。
