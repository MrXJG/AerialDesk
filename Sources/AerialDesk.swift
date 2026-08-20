import AppKit
import AVFoundation
import Foundation
import ServiceManagement

private final class PlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

private struct PlaybackStatus: Codable {
    let app: String
    let powerSource: String
    let playbackState: String
    let playerRate: Float
    let currentVideo: String?
    let currentVideoName: String?
    let currentVideoNameZh: String?
    let currentVideoNameEn: String?
    let availableVideos: Int
    let screenSleeping: Bool
    let loginItemStatus: String
    let applicationPath: String
    let applicationVersion: String
    let updatedAt: String
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windows: [NSWindow] = []
    private let player = AVPlayer()
    private var currentVideo: URL?
    private var powerTimer: Timer?
    private var testSwitchTimer: Timer?
    private var screenSleeping = false
    private var lastPowerSource = "Unknown"
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var loginItemMenuItem: NSMenuItem?
    private var videoCount = 0
    private var downloadManager: DownloadManagerWindowController?
    private let loginItemPreferenceKey = "LoginItemEnabledPreference"
    private let registeredLoginItemVersionKey = "RegisteredLoginItemVersion"

    private var statusDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AerialDesk", isDirectory: true)
    }

    private var statusFile: URL {
        statusDirectory.appendingPathComponent("status.json")
    }

    private var logFile: URL {
        statusDirectory.appendingPathComponent("AerialDesk.log")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .pause

        createStatusItem()
        configureLoginItemOnLaunch()
        createDesktopWindows()
        installObservers()
        switchToNextVideo(reason: "launch")
        applyPowerState(reason: "launch")

        powerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyPowerState(reason: "power-poll") }
        }

        if let secondsString = ProcessInfo.processInfo.environment["AERIALDESK_SWITCH_INTERVAL"],
           let seconds = Double(secondsString), seconds > 0 {
            testSwitchTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.switchToNextVideo(reason: "timed-switch") }
            }
        }

        if CommandLine.arguments.contains("--downloads") {
            DispatchQueue.main.async { [weak self] in
                self?.openDownloadManager()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        powerTimer?.invalidate()
        testSwitchTimer?.invalidate()
        player.pause()
        writeStatus(playbackState: "stopped")
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "✈︎"
        statusItem?.button?.toolTip = appName

        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu.addItem(statusMenuItem!)
        menu.addItem(.separator())

        let nextItem = NSMenuItem(title: "切换下一段航拍", action: #selector(nextVideo), keyEquivalent: "n")
        nextItem.target = self
        menu.addItem(nextItem)

        let downloadItem = NSMenuItem(title: "下载航拍视频…", action: #selector(openDownloadManager), keyEquivalent: "d")
        downloadItem.target = self
        menu.addItem(downloadItem)

        let folderItem = NSMenuItem(title: "打开 AerialDesk 下载目录", action: #selector(openVideoFolder), keyEquivalent: "o")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(.separator())
        loginItemMenuItem = NSMenuItem(
            title: "登录时自动启动",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItemMenuItem?.target = self
        menu.addItem(loginItemMenuItem!)

        let revealItem = NSMenuItem(
            title: "在“应用程序”中显示 AerialDesk",
            action: #selector(revealApplication),
            keyEquivalent: ""
        )
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 AerialDesk", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
        refreshLoginItemMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginItemMenu()
    }

    private func createDesktopWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false

            let playerView = PlayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            playerView.autoresizingMask = [.width, .height]
            playerView.playerLayer.player = player
            window.contentView = playerView
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        log("Created \(windows.count) desktop window(s)")
    }

    private func installObservers() {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, notification.object as AnyObject? === self.player.currentItem else { return }
                self.switchToNextVideo(reason: "video-ended")
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.createDesktopWindows() }
        }

        NotificationCenter.default.addObserver(
            forName: .aerialDeskDownloadsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                AerialCatalog.shared.reload()
                self?.videoCount = AerialCatalog.shared.videoFiles().count
                self?.applyPowerState(reason: "downloads-changed")
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = true
                self?.applyPowerState(reason: "screen-sleep")
            }
        }
        workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = false
                self?.applyPowerState(reason: "screen-wake")
            }
        }
    }

    private func availableVideos() -> [URL] {
        let videos = AerialCatalog.shared.videoFiles()
        videoCount = videos.count
        return videos
    }

    private func aerialName(for video: URL?) -> AerialName? {
        AerialCatalog.shared.name(for: video)
    }

    private func displayName(for video: URL?) -> String {
        AerialCatalog.shared.displayName(for: video)
    }

    private func switchToNextVideo(reason: String) {
        AerialCatalog.shared.reload()
        let videos = availableVideos()
        guard !videos.isEmpty else {
            player.pause()
            currentVideo = nil
            log("No videos found in system or AerialDesk video directories")
            writeStatus(playbackState: "no-videos")
            return
        }

        let candidates: [URL]
        if videos.count > 1, let currentVideo {
            candidates = videos.filter { $0 != currentVideo }
        } else {
            candidates = videos
        }

        guard let selected = candidates.randomElement() else { return }
        currentVideo = selected
        let item = AVPlayerItem(url: selected)
        player.replaceCurrentItem(with: item)
        log("Selected \(displayName(for: selected)) [\(selected.lastPathComponent)], reason=\(reason)")
        applyPowerState(reason: reason)
    }

    private func applyPowerState(reason: String) {
        let source = currentPowerSourceName()
        let shouldPlay = isOnACPower() && !screenSleeping && currentVideo != nil
        let sourceChanged = source != lastPowerSource
        lastPowerSource = source

        if shouldPlay {
            player.play()
        } else {
            player.pause()
        }

        let state = shouldPlay ? "playing" : (screenSleeping ? "paused-screen-sleep" : "paused-on-battery")
        if sourceChanged || reason != "power-poll" {
            log("State \(state), source=\(source), rate=\(player.rate), reason=\(reason)")
        }
        updateMenu(state: state, source: source)
        writeStatus(playbackState: state)
    }

    private func updateMenu(state: String, source: String) {
        let displayState: String
        switch state {
        case "playing": displayState = "播放中"
        case "paused-screen-sleep": displayState = "屏幕休眠，已暂停"
        case "paused-on-battery": displayState = "使用电池，已暂停"
        default: displayState = state
        }
        let videoName = displayName(for: currentVideo)
        statusMenuItem?.title = "\(displayState) · \(videoName) · 共 \(videoCount) 段"
        statusItem?.button?.toolTip = "AerialDesk：\(displayState)"
        refreshLoginItemMenu()
    }

    private func writeStatus(playbackState: String) {
        try? FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let readableName = aerialName(for: currentVideo)
        let status = PlaybackStatus(
            app: appName,
            powerSource: lastPowerSource,
            playbackState: playbackState,
            playerRate: player.rate,
            currentVideo: currentVideo?.path,
            currentVideoName: readableName?.displayName,
            currentVideoNameZh: readableName?.chinese,
            currentVideoNameEn: readableName?.english,
            availableVideos: videoCount,
            screenSleeping: screenSleeping,
            loginItemStatus: loginItemStatusName(),
            applicationPath: Bundle.main.bundleURL.path,
            applicationVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "未知",
            updatedAt: formatter.string(from: Date())
        )
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: statusFile, options: .atomic)
    }

    private func log(_ message: String) {
        try? FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path),
           let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Status reporting must never interrupt wallpaper playback.
            }
        } else {
            try? data.write(to: logFile, options: .atomic)
        }
    }

    private var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path == "/Applications/AerialDesk.app" || path.hasPrefix("/Applications/")
    }

    private func configureLoginItemOnLaunch() {
        guard isInstalledInApplications else {
            log("Login item not configured because app path is \(Bundle.main.bundleURL.path)")
            refreshLoginItemMenu()
            return
        }

        let defaults = UserDefaults.standard
        if defaults.object(forKey: loginItemPreferenceKey) == nil {
            defaults.set(true, forKey: loginItemPreferenceKey)
        }

        let loginStatus = SMAppService.mainApp.status
        let registeredVersion = defaults.string(forKey: registeredLoginItemVersionKey)
        if defaults.bool(forKey: loginItemPreferenceKey),
           loginStatus == .notRegistered
            || loginStatus == .notFound
            || (loginStatus == .enabled && registeredVersion != applicationBuildIdentity) {
            setLoginItemEnabled(true, showError: false)
        } else {
            refreshLoginItemMenu()
        }
    }

    private func setLoginItemEnabled(_ enabled: Bool, showError: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                let registeredVersion = UserDefaults.standard.string(
                    forKey: registeredLoginItemVersionKey
                )
                if service.status == .enabled, registeredVersion != applicationBuildIdentity {
                    try service.unregister()
                    try service.register()
                } else if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            UserDefaults.standard.set(enabled, forKey: loginItemPreferenceKey)
            if enabled {
                UserDefaults.standard.set(
                    applicationBuildIdentity,
                    forKey: registeredLoginItemVersionKey
                )
            } else {
                UserDefaults.standard.removeObject(forKey: registeredLoginItemVersionKey)
            }
            log("Login item \(enabled ? "enabled" : "disabled"), status=\(loginItemStatusName())")
        } catch {
            log("Login item change failed: \(error.localizedDescription)")
            if showError {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法修改登录启动设置"
                alert.informativeText = "\(error.localizedDescription)\n\n可以在“系统设置 → 通用 → 登录项与扩展”中检查 AerialDesk。"
                alert.addButton(withTitle: "打开登录项设置")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
        refreshLoginItemMenu()
        writeStatus(playbackState: player.rate > 0 ? "playing" : "paused")
    }

    private func refreshLoginItemMenu() {
        guard let loginItemMenuItem else { return }
        guard isInstalledInApplications else {
            loginItemMenuItem.title = "登录时自动启动（需安装到 /Applications）"
            loginItemMenuItem.state = .off
            loginItemMenuItem.isEnabled = false
            return
        }

        loginItemMenuItem.isEnabled = true
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItemMenuItem.title = "登录时自动启动"
            loginItemMenuItem.state = .on
        case .requiresApproval:
            loginItemMenuItem.title = "登录时自动启动（需要系统允许）"
            loginItemMenuItem.state = .mixed
        case .notRegistered, .notFound:
            loginItemMenuItem.title = "登录时自动启动"
            loginItemMenuItem.state = .off
        @unknown default:
            loginItemMenuItem.title = "登录时自动启动"
            loginItemMenuItem.state = .off
        }
    }

    private func loginItemStatusName() -> String {
        guard isInstalledInApplications else { return "not-installed-in-applications" }
        switch SMAppService.mainApp.status {
        case .notRegistered: return "not-registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires-approval"
        case .notFound: return "not-found"
        @unknown default: return "unknown"
        }
    }

    private var applicationBuildIdentity: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version) (\(build))"
    }

    @objc private func nextVideo() {
        switchToNextVideo(reason: "menu-next")
    }

    @objc private func openDownloadManager() {
        if downloadManager == nil {
            downloadManager = DownloadManagerWindowController()
        }
        downloadManager?.showWindow(nil)
        downloadManager?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openVideoFolder() {
        try? FileManager.default.createDirectory(at: aerialDeskVideoDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(aerialDeskVideoDirectory)
    }

    @objc private func toggleLoginItem() {
        guard isInstalledInApplications else { return }
        switch SMAppService.mainApp.status {
        case .enabled:
            setLoginItemEnabled(false, showError: true)
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        case .notRegistered, .notFound:
            setLoginItemEnabled(true, showError: true)
        @unknown default:
            setLoginItemEnabled(true, showError: true)
        }
    }

    @objc private func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

@main
private enum AerialDeskMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
