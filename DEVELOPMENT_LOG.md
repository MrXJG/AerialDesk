# AerialDesk 开发日志

本文件用于记录可追溯的开发事实。每次改动建议记录：日期、目标、文件、验证命令、结果和遗留风险。未实际验证的内容必须标记为“未验证”。

## 2026-08-20

### 目标

为下载管理器加入 Liquid Glass 材质，并补充 AI 快速接手项目所需的上下文文档。

### 已发现的项目基线

- 项目为原生 AppKit Swift 菜单栏应用。
- 最低支持 macOS 14.0，构建目标为 Apple Silicon `arm64-apple-macos14.0`。
- 下载管理器位于 `Sources/DownloadManager.swift`。
- 播放、电源和菜单栏逻辑位于 `Sources/AerialDesk.swift`。
- 清单、媒体路径和电源工具位于 `Sources/AerialCatalog.swift`。
- 预览图加载/生成位于 `Sources/AerialPreviewProvider.swift`。

### 当前工作树状态

`git status --short` 显示：

```text
 M Sources/DownloadManager.swift
```

这表示 Liquid Glass 相关源码改动在本日志记录时仍是未提交状态。不要将其误认为已经提交、发布或经过完整用户验收。

### Liquid Glass 改动摘要

- 新增 `AerialGlassView` 包装组件。
- macOS 26+ 使用 `NSGlassEffectView`。
- 旧系统回退到 `NSVisualEffectView`。
- 根容器、列表面板和预览面板迁移到玻璃包装组件。
- 列表滚动视图和预览内容改为挂在各自的 `contentContainer` 上。

### 已执行验证

```text
zsh build.sh                 ✅ 通过
git diff --check             ✅ 无空白错误
```

构建产物：

```text
build/AerialDesk.app
```

构建使用 ad-hoc 签名。尚未将应用安装到 `/Applications`，也未进行正式签名、公证或发布验收。

### 尚未完成的验证

- 未在 macOS 14/15 旧系统上运行回退材质分支。
- 未完成下载管理器所有控件的人工交互回归。
- 未验证真实 Apple 清单、远程下载和电源切换下的完整流程。
- 未确认当前工作树改动是否需要拆分、提交或合并到其他分支。

### 后续建议

1. 启动 `build/AerialDesk.app --args --downloads`，检查窗口、列表和预览面板的实际层级与圆角。
2. 在 macOS 26 上确认 `NSGlassEffectView` 的渲染；在 macOS 14/15 上确认回退材质不崩溃。
3. 检查 `DownloadManager.swift` 中所有约束都挂在正确的容器上，并留意窗口尺寸变化时的布局。
4. 通过 `git diff` 审查后再决定是否提交。

## 日志模板

复制以下模板追加新记录：

```markdown
## YYYY-MM-DD

### 目标

### 修改文件

- `path/to/file`: 做了什么

### 验证

```text
command or UI check      ✅ / ❌ / 未验证
```

### 结果与风险

- 已确认：
- 未确认：
- 回滚方式：

### 下一步

```

