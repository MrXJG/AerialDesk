# AerialDesk 项目上下文（AI Onboarding）

> 用途：给参与本项目的 AI、开发者和代码审查者提供一份可快速读取的事实基线。本文档只记录当前仓库能确认的内容；运行时状态、系统目录和用户媒体可能随机器环境变化。

## 1. 项目定位

AerialDesk 是一个原生 macOS 菜单栏应用，用 Apple 航拍（Aerial）视频作为动态桌面壁纸，并提供航拍清单浏览、预览和下载管理。

核心运行方式：

1. 以菜单栏应用运行，不显示普通 Dock 图标（`LSUIElement = true`）。
2. 为每个显示器创建桌面层级的无边框窗口，将同一个 `AVPlayer` 的画面铺满屏幕。
3. 接通电源时播放；电池供电或屏幕休眠时暂停。
4. 从系统航拍清单和 AerialDesk 自己的下载目录发现视频。
5. 通过菜单栏打开下载管理器，支持筛选、预览、单段/分类/全部下载和电源条件控制。

## 2. 技术基线

- 语言：Swift
- UI：AppKit（代码创建 UI，无 storyboard / SwiftUI）
- 媒体：AVFoundation / `AVPlayer` / `AVPlayerLayer`
- 系统能力：IOKit 电源状态、ServiceManagement 登录项
- 最低系统：macOS 14.0
- 当前构建目标：`arm64-apple-macos14.0`
- 构建方式：`zsh build.sh`
- 签名：本地 ad-hoc 签名；正式发布需要开发者签名和公证
- 当前 Info.plist 版本：`CFBundleShortVersionString = 1.6`，`CFBundleVersion = 7`

## 3. 目录与职责

| 路径 | 职责 |
| --- | --- |
| `Sources/AerialDesk.swift` | 应用入口、菜单栏状态项、桌面窗口、播放模式、电源/屏幕休眠响应、登录项、状态 JSON 和运行日志 |
| `Sources/AerialCatalog.swift` | 系统/下载清单解析、中文/英文名称解析、视频发现、下载目录和电源工具函数 |
| `Sources/DownloadManager.swift` | 下载管理窗口、搜索/分类筛选、表格、预览、下载队列、进度、电源暂停与取消 |
| `Sources/AerialPreviewProvider.swift` | Apple 预览图优先；没有时从本地视频异步生成缩略图，并做内存/磁盘缓存 |
| `assets/AppIcon.icns` | 应用图标 |
| `assets/AppIcon-source.png` | 图标源图 |
| `tools/make_icon.swift` | 图标生成辅助脚本 |
| `build.sh` | 编译、复制 Info.plist/图标、ad-hoc 签名 |
| `Info.plist` | Bundle 元数据、最低系统版本和菜单栏应用配置 |
| `README.md` | 面向用户的功能、构建、运行数据和许可证说明 |

## 4. 主要数据流

### 播放

`AppDelegate.applicationDidFinishLaunching` → 创建状态项/桌面窗口 → `AerialCatalog.reload()` → 选择下一个视频 → `AVPlayer.replaceCurrentItem` → 根据电源和屏幕状态调用 `play()` 或 `pause()`。

视频结束、屏幕唤醒、屏幕参数变化和下载完成都会触发相应的刷新或播放状态重新评估。

### 清单与媒体

清单来源按优先级读取：

- 系统清单：`~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json`
- 系统资源：`/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources`
- 下载清单：`~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json`

视频来源：

- Apple 系统视频：`~/Library/Application Support/com.apple.wallpaper/aerials/videos`
- AerialDesk 下载视频：`~/Library/Application Support/AerialDesk/Videos`

相同 ID 只保留优先发现的有效文件；支持 `.mov`、`.mp4`、`.m4v`，且文件必须是非空普通文件。

### 下载与预览

下载管理器先根据清单生成 `AerialCatalogItem`，然后将用户选择放入串行队列。默认仅接通电源时下载；切换到电池会暂停当前任务，接回电源后继续。

预览顺序：Apple 系统 PNG → 本地视频生成 JPEG → 占位图。缩略图缓存默认位于 `~/Library/Application Support/AerialDesk/Thumbnails`。

## 5. Liquid Glass 相关实现

`Sources/DownloadManager.swift` 中的 `AerialGlassView`：

- macOS 26 及以上使用 `NSGlassEffectView`，样式为 `.regular`。
- macOS 14/15 等受支持旧系统回退到 `NSVisualEffectView` 的 `.windowBackground`。
- 下载管理器根容器、列表面板和预览面板均使用该包装视图。
- 内容放在 `contentContainer` 中，避免遮挡玻璃材质本身。

修改该区域时要同时检查两件事：

1. `#available(macOS 26.0, *)` 分支仍能被最低系统目标编译。
2. 面板内容约束挂在 `contentContainer`，否则可能出现内容不可见或约束冲突。

## 6. 运行数据与测试覆盖口

默认运行数据：

```text
~/Library/Application Support/AerialDesk/
├── Videos/
├── Thumbnails/
├── status.json
└── AerialDesk.log
```

本地测试可使用环境变量隔离系统媒体：

```zsh
export AERIALDESK_VIDEO_DIR="$PWD/runtime/Videos"
export AERIALDESK_THUMBNAIL_DIR="$PWD/runtime/Thumbnails"
export AERIALDESK_FORCE_POWER=AC      # 或 Battery
export AERIALDESK_PLAYBACK_MODE=sequential
export AERIALDESK_SWITCH_INTERVAL=10
```

已知可验证命令：

```zsh
zsh build.sh
open build/AerialDesk.app
open build/AerialDesk.app --args --downloads
git diff --check
```

## 7. 修改边界与注意事项

- 不要把 Apple 航拍视频、系统缩略图、缓存媒体或运行日志提交到仓库。
- 不要自动移动或删除 Apple 已有媒体；下载器只写入 AerialDesk 自己的 `Videos` 目录。
- 系统清单格式和路径属于 macOS 实现细节，解析失败时应保留空结果或已有可用数据，不应阻塞应用启动。
- 下载是外部网络行为；改动下载逻辑时需要检查 HTTP 状态、临时文件、重复文件和取消边界。
- 登录项只在应用位于 `/Applications` 时配置；开发目录运行时不会自动注册。
- 这是 AppKit 单线程 UI 结构；涉及 UI 状态的异步回调要回到 `MainActor`。
- 当前工作树可能包含未提交的 UI 材质改动；开始新工作前先执行 `git status --short`，不要覆盖他人或上一轮未提交的编辑。

## 8. AI 推荐阅读顺序

1. 本文档。
2. `README.md`：用户可见功能和运行约束。
3. `Sources/AerialCatalog.swift`：先理解数据和路径，再看 UI。
4. `Sources/AerialDesk.swift`：播放、电源、生命周期。
5. `Sources/DownloadManager.swift`：下载器和玻璃材质 UI。
6. `Sources/AerialPreviewProvider.swift`：预览生成和缓存。
7. `DEVELOPMENT_LOG.md`：查看最近改动、验证和待办。

