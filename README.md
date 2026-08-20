# AerialDesk

原生 macOS 航拍动态壁纸播放器与下载管理器。

[English](#english)

## 功能

- 接通电源时持续播放航拍动态壁纸。
- 使用电池时自动暂停，接回电源后继续播放。
- 屏幕唤醒后自动恢复播放，一段视频结束后自动切换下一段航拍。
- 支持随机播放、顺序播放和单段循环三种模式。
- 下载管理器使用 macOS 原生玻璃材质，预览面板和列表保持清晰的层次感。
- 读取 macOS 航拍清单，显示中文名称和英文名称，不再只显示 UUID。
- 在下载管理器中预览航拍图片。
- 支持下载单独一段航拍、当前分类或全部航拍视频。
- 同时识别 Apple 系统航拍视频和 AerialDesk 下载的视频，不会自动移动或删除已有视频。
- 菜单栏提供“登录时自动启动”开关。
- 可以从菜单栏直接在“应用程序”中显示 AerialDesk。

## 系统要求

- macOS 14.0 或更高版本
- Apple Silicon Mac（当前构建目标为 `arm64-apple-macos14.0`）
- Xcode 或 Command Line Tools 提供的 Swift 工具链

AerialDesk 读取 Mac 上已有的 Apple 航拍清单和媒体文件。本仓库不包含 Apple 航拍视频、系统缩略图或缓存媒体。

## 构建和运行

```bash
zsh build.sh
open build/AerialDesk.app
```

开发构建使用 ad-hoc 签名，适合本机测试。正式分发时，应使用你自己的 Apple Developer 签名并完成公证。

## 运行数据

运行时数据默认保存在：

```text
~/Library/Application Support/AerialDesk/
```

其中：

- `Videos/`：AerialDesk 下载的视频。
- `Thumbnails/`：从 Apple 预览图或本地视频生成的缩略图。
- `status.json`：当前播放、电源和登录项状态。
- `AerialDesk.log`：运行日志。

Apple 系统航拍媒体仍保留在 Apple 自己的系统目录中。为了方便本地测试，可以使用以下环境变量覆盖目录：

```bash
export AERIALDESK_VIDEO_DIR="$PWD/runtime/Videos"
export AERIALDESK_THUMBNAIL_DIR="$PWD/runtime/Thumbnails"
```

## 注意事项

- Apple 航拍清单格式和系统路径属于系统实现细节，可能随 macOS 版本变化。
- Apple 航拍视频和缩略图属于 Apple 提供的媒体，本仓库不重新分发这些内容。
- 应用图标是本项目资产，不包含 Apple 标志或 Apple 系统壁纸。
- 当前版本主要针对 Apple Silicon；Intel 架构需要调整构建目标后再编译。

## 许可证

源代码使用 MIT License，详见 [LICENSE](LICENSE)。

---

## English

AerialDesk is a native macOS menu-bar app for playing aerial dynamic wallpapers and managing aerial video downloads.

### Features

- Keep aerial videos playing on AC power and pause on battery.
- Resume after screen wake and switch to the next video when playback ends.
- Display localized Chinese and English aerial names instead of UUIDs.
- Preview aerial images in the download manager.
- Download one selected aerial, a category, or all available aerial videos.
- Recognize Apple system videos and AerialDesk downloads without moving or deleting existing media.
- Choose random playback, sequential playback, or single-video loop from the menu bar.
- Use native macOS glass materials in the download manager and preview panel.
- Toggle launch at login and reveal the app in `/Applications` from the menu bar.

### Requirements and build

- macOS 14.0 or later
- Apple Silicon Mac
- Swift toolchain from Xcode or the Command Line Tools

```bash
zsh build.sh
open build/AerialDesk.app
```

The repository intentionally excludes Apple aerial videos, thumbnails, caches, logs, and local runtime data. Source code is licensed under the MIT License.
