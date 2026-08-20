import AppKit
import Foundation

private final class AerialNameCellView: NSTableCellView {
    let thumbnailView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    var representedItemID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageAlignment = .alignCenter
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 6
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumbnailView)
        addSubview(titleLabel)
        textField = titleLabel

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 82),
            thumbnailView.heightAnchor.constraint(equalToConstant: 50),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class DownloadManagerWindowController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate {

    private enum ItemState {
        case queued
        case downloading
        case failed(String)
    }

    private enum DownloadError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case missingTemporaryFile

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "服务器响应无效"
            case .httpStatus(let status): return "服务器返回 HTTP \(status)"
            case .missingTemporaryFile: return "下载完成但临时文件不存在"
            }
        }
    }

    private let searchField = NSSearchField()
    private let categoryPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let powerLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "尚未开始下载")
    private let progressIndicator = NSProgressIndicator()
    private let selectedButton = NSButton(title: "下载选中航拍", target: nil, action: nil)
    private let categoryButton = NSButton(title: "下载当前分类", target: nil, action: nil)
    private let allButton = NSButton(title: "下载全部航拍", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消下载队列", target: nil, action: nil)
    private let openFolderButton = NSButton(title: "打开下载目录", target: nil, action: nil)
    private let requiresACCheckbox = NSButton(checkboxWithTitle: "仅接通电源时下载", target: nil, action: nil)
    private let contentGlass = NSVisualEffectView()
    private let listPanel = NSVisualEffectView()
    private let previewPanel = NSVisualEffectView()
    private let previewImageView = NSImageView()
    private let previewTitleLabel = NSTextField(labelWithString: "选择一个航拍查看预览")
    private let previewCategoryLabel = NSTextField(labelWithString: "")
    private let previewStatusLabel = NSTextField(labelWithString: "")
    private let previewSourceLabel = NSTextField(labelWithString: "")
    private let previewDownloadButton = NSButton(title: "下载这段航拍", target: nil, action: nil)
    private var previewedItemID: String?
    private var previewSource: AerialPreviewSource?

    private var allItems: [AerialCatalogItem] = []
    private var filteredItems: [AerialCatalogItem] = []
    private var downloadedIDs: Set<String> = []
    private var states: [String: ItemState] = [:]
    private var pendingItems: [AerialCatalogItem] = []
    private var currentItem: AerialCatalogItem?
    private var currentTask: URLSessionDownloadTask?
    private var progressTimer: Timer?
    private var powerTimer: Timer?
    private var batchTotal = 0
    private var batchCompleted = 0
    private var isCancelling = false

    private var requiresACPower: Bool {
        requiresACCheckbox.state == .on
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AerialDesk 航拍下载管理器"
        window.minSize = NSSize(width: 980, height: 640)
        window.center()
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        super.init(window: window)

        configureUI()
        reloadCatalog()
        updatePowerState()

        powerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePowerState() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        progressTimer?.invalidate()
        powerTimer?.invalidate()
        currentTask?.cancel()
    }

    override func showWindow(_ sender: Any?) {
        reloadCatalog()
        super.showWindow(sender)
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        configureGlass(contentGlass, material: .windowBackground)
        contentGlass.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentGlass, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            contentGlass.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentGlass.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentGlass.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentGlass.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        searchField.placeholderString = "搜索中文或英文名称"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        categoryPopup.target = self
        categoryPopup.action = #selector(filterChanged)
        categoryPopup.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton(title: "刷新清单", target: self, action: #selector(refreshCatalog))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let topStack = NSStackView(views: [searchField, categoryPopup, refreshButton])
        topStack.orientation = .horizontal
        topStack.spacing = 10
        topStack.alignment = .centerY
        topStack.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        powerLabel.textColor = .secondaryLabelColor
        powerLabel.alignment = .right
        powerLabel.translatesAutoresizingMaskIntoConstraints = false

        let summaryStack = NSStackView(views: [summaryLabel, NSView(), powerLabel])
        summaryStack.orientation = .horizontal
        summaryStack.alignment = .centerY
        summaryStack.translatesAutoresizingMaskIntoConstraints = false

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "航拍名称"
        nameColumn.minWidth = 330
        nameColumn.width = 420

        let categoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        categoryColumn.title = "分类"
        categoryColumn.minWidth = 130
        categoryColumn.width = 160

        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = "状态"
        statusColumn.minWidth = 90
        statusColumn.width = 110

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(categoryColumn)
        tableView.addTableColumn(statusColumn)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 60

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        configureGlass(listPanel, material: .sidebar)
        listPanel.translatesAutoresizingMaskIntoConstraints = false

        configureGlass(previewPanel, material: .hudWindow)
        previewPanel.layer?.cornerRadius = 10
        previewPanel.layer?.borderWidth = 1
        previewPanel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        previewPanel.translatesAutoresizingMaskIntoConstraints = false

        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignCenter
        previewImageView.image = placeholderPreviewImage()
        previewImageView.contentTintColor = .tertiaryLabelColor
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 8
        previewImageView.layer?.masksToBounds = true
        previewImageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
        previewImageView.translatesAutoresizingMaskIntoConstraints = false

        previewTitleLabel.font = .boldSystemFont(ofSize: 15)
        previewTitleLabel.maximumNumberOfLines = 3
        previewTitleLabel.lineBreakMode = .byWordWrapping
        previewTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        for label in [previewCategoryLabel, previewStatusLabel, previewSourceLabel] {
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        previewSourceLabel.font = .systemFont(ofSize: 11)

        previewDownloadButton.target = self
        previewDownloadButton.action = #selector(downloadPreviewedItem)
        previewDownloadButton.isEnabled = false
        previewDownloadButton.translatesAutoresizingMaskIntoConstraints = false

        previewPanel.addSubview(previewImageView)
        previewPanel.addSubview(previewTitleLabel)
        previewPanel.addSubview(previewCategoryLabel)
        previewPanel.addSubview(previewStatusLabel)
        previewPanel.addSubview(previewSourceLabel)
        previewPanel.addSubview(previewDownloadButton)

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.lineBreakMode = .byTruncatingMiddle
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        requiresACCheckbox.state = UserDefaults.standard.object(forKey: "DownloadRequiresAC") == nil
            ? .on
            : (UserDefaults.standard.bool(forKey: "DownloadRequiresAC") ? .on : .off)
        requiresACCheckbox.target = self
        requiresACCheckbox.action = #selector(requiresACChanged)
        requiresACCheckbox.translatesAutoresizingMaskIntoConstraints = false

        selectedButton.target = self
        selectedButton.action = #selector(downloadSelected)
        categoryButton.target = self
        categoryButton.action = #selector(downloadCategory)
        allButton.target = self
        allButton.action = #selector(downloadAll)
        cancelButton.target = self
        cancelButton.action = #selector(cancelDownloads)
        openFolderButton.target = self
        openFolderButton.action = #selector(openDownloadFolder)

        let buttonStack = NSStackView(views: [
            selectedButton,
            categoryButton,
            allButton,
            cancelButton,
            NSView(),
            openFolderButton
        ])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(topStack)
        contentView.addSubview(summaryStack)
        contentView.addSubview(listPanel)
        contentView.addSubview(scrollView)
        contentView.addSubview(previewPanel)
        contentView.addSubview(progressLabel)
        contentView.addSubview(progressIndicator)
        contentView.addSubview(requiresACCheckbox)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            topStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            topStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            categoryPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            summaryStack.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 10),
            summaryStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            summaryStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: summaryStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: progressLabel.topAnchor, constant: -12),

            listPanel.topAnchor.constraint(equalTo: scrollView.topAnchor),
            listPanel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            listPanel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            listPanel.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            previewPanel.topAnchor.constraint(equalTo: scrollView.topAnchor),
            previewPanel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            previewPanel.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            previewPanel.widthAnchor.constraint(equalToConstant: 310),

            previewImageView.topAnchor.constraint(equalTo: previewPanel.topAnchor, constant: 16),
            previewImageView.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 16),
            previewImageView.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -16),
            previewImageView.heightAnchor.constraint(equalTo: previewImageView.widthAnchor, multiplier: 130.0 / 214.0),

            previewTitleLabel.topAnchor.constraint(equalTo: previewImageView.bottomAnchor, constant: 14),
            previewTitleLabel.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 16),
            previewTitleLabel.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -16),

            previewCategoryLabel.topAnchor.constraint(equalTo: previewTitleLabel.bottomAnchor, constant: 10),
            previewCategoryLabel.leadingAnchor.constraint(equalTo: previewTitleLabel.leadingAnchor),
            previewCategoryLabel.trailingAnchor.constraint(equalTo: previewTitleLabel.trailingAnchor),

            previewStatusLabel.topAnchor.constraint(equalTo: previewCategoryLabel.bottomAnchor, constant: 6),
            previewStatusLabel.leadingAnchor.constraint(equalTo: previewTitleLabel.leadingAnchor),
            previewStatusLabel.trailingAnchor.constraint(equalTo: previewTitleLabel.trailingAnchor),

            previewSourceLabel.topAnchor.constraint(equalTo: previewStatusLabel.bottomAnchor, constant: 10),
            previewSourceLabel.leadingAnchor.constraint(equalTo: previewTitleLabel.leadingAnchor),
            previewSourceLabel.trailingAnchor.constraint(equalTo: previewTitleLabel.trailingAnchor),
            previewSourceLabel.bottomAnchor.constraint(lessThanOrEqualTo: previewDownloadButton.topAnchor, constant: -12),

            previewDownloadButton.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 16),
            previewDownloadButton.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -16),
            previewDownloadButton.bottomAnchor.constraint(equalTo: previewPanel.bottomAnchor, constant: -16),

            progressLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            progressLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            progressLabel.bottomAnchor.constraint(equalTo: progressIndicator.topAnchor, constant: -6),

            progressIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            progressIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            progressIndicator.bottomAnchor.constraint(equalTo: requiresACCheckbox.topAnchor, constant: -10),

            requiresACCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            requiresACCheckbox.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -10),

            buttonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 32),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])


        updateButtons()
    }

    private func configureGlass(
        _ view: NSVisualEffectView,
        material: NSVisualEffectView.Material
    ) {
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
    }

    private func reloadCatalog() {
        AerialCatalog.shared.reload()
        allItems = AerialCatalog.shared.items
        downloadedIDs = AerialCatalog.shared.downloadedIDs()
        configureCategories()
        applyFilter()
    }

    private func configureCategories() {
        let previousID = categoryPopup.selectedItem?.representedObject as? String
        categoryPopup.removeAllItems()
        categoryPopup.addItem(withTitle: "全部分类")
        categoryPopup.lastItem?.representedObject = "all"

        var categories: [String: String] = [:]
        for item in allItems {
            categories[item.categoryID] = item.categoryDisplayName
        }
        for pair in categories.sorted(by: {
            $0.value.localizedStandardCompare($1.value) == .orderedAscending
        }) {
            categoryPopup.addItem(withTitle: pair.value)
            categoryPopup.lastItem?.representedObject = pair.key
        }

        if let previousID,
           let index = categoryPopup.itemArray.firstIndex(where: {
               ($0.representedObject as? String) == previousID
           }) {
            categoryPopup.selectItem(at: index)
        } else {
            categoryPopup.selectItem(at: 0)
        }
    }

    private func applyFilter() {
        let previouslySelectedIDs = Set(tableView.selectedRowIndexes.compactMap { index in
            index < filteredItems.count ? filteredItems[index].id : nil
        })
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedCategory = categoryPopup.selectedItem?.representedObject as? String ?? "all"
        filteredItems = allItems.filter { item in
            let categoryMatches = selectedCategory == "all" || item.categoryID == selectedCategory
            let textMatches = query.isEmpty
                || item.displayName.localizedCaseInsensitiveContains(query)
                || item.id.localizedCaseInsensitiveContains(query)
            return categoryMatches && textMatches
        }
        tableView.reloadData()
        var selection = IndexSet()
        for (index, item) in filteredItems.enumerated() where previouslySelectedIDs.contains(item.id) {
            selection.insert(index)
        }
        if selection.isEmpty, !filteredItems.isEmpty {
            selection.insert(0)
        }
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
        summaryLabel.stringValue = "共 \(allItems.count) 段航拍，已下载 \(downloadedIDs.count) 段，当前显示 \(filteredItems.count) 段"
        updateButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row >= 0, row < filteredItems.count, let tableColumn else { return nil }
        let item = filteredItems[row]
        let identifier = tableColumn.identifier

        if identifier.rawValue == "name" {
            let cell: AerialNameCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? AerialNameCellView {
                cell = reused
            } else {
                cell = AerialNameCellView()
                cell.identifier = identifier
            }
            cell.representedItemID = item.id
            cell.titleLabel.stringValue = item.displayName
            cell.titleLabel.toolTip = "\(item.displayName)\n\(item.id)"
            cell.thumbnailView.image = placeholderPreviewImage()
            cell.thumbnailView.contentTintColor = .tertiaryLabelColor

            AerialPreviewProvider.shared.loadPreview(for: item) { [weak cell] image, _ in
                guard let cell, cell.representedItemID == item.id else { return }
                cell.thumbnailView.image = image ?? self.placeholderPreviewImage()
                cell.thumbnailView.contentTintColor = image == nil ? .tertiaryLabelColor : nil
            }
            return cell
        }

        let cell: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        switch identifier.rawValue {
        case "category":
            cell.textField?.stringValue = item.categoryDisplayName
        case "status":
            cell.textField?.stringValue = statusText(for: item)
            cell.textField?.textColor = statusColor(for: item)
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    private func statusText(for item: AerialCatalogItem) -> String {
        if downloadedIDs.contains(item.id) { return "已下载" }
        switch states[item.id] {
        case .queued: return "等待下载"
        case .downloading:
            let percent = Int((currentTask?.progress.fractionCompleted ?? 0) * 100)
            return "下载中 \(percent)%"
        case .failed: return "下载失败"
        case nil: return "未下载"
        }
    }

    private func statusColor(for item: AerialCatalogItem) -> NSColor {
        if downloadedIDs.contains(item.id) { return .systemGreen }
        switch states[item.id] {
        case .downloading: return .systemBlue
        case .queued: return .systemOrange
        case .failed: return .systemRed
        case nil: return .labelColor
        }
    }

    private func updateButtons() {
        let selectedRows = tableView.selectedRowIndexes.filter { $0 < filteredItems.count }
        let selectedHasPending = selectedRows.contains {
            let item = filteredItems[$0]
            return canDownload(item)
        }
        selectedButton.isEnabled = selectedHasPending

        let categoryID = categoryPopup.selectedItem?.representedObject as? String ?? "all"
        categoryButton.isEnabled = categoryID != "all"
            && allItems.contains { $0.categoryID == categoryID && canDownload($0) }
        cancelButton.isEnabled = currentTask != nil || !pendingItems.isEmpty
        updatePreview()
    }

    private func canDownload(_ item: AerialCatalogItem) -> Bool {
        item.remoteURL != nil
            && !downloadedIDs.contains(item.id)
            && states[item.id] == nil
            && currentItem?.id != item.id
    }

    private func placeholderPreviewImage() -> NSImage? {
        NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "暂无预览")
    }

    private func updatePreview() {
        let selectedRows = tableView.selectedRowIndexes.filter { $0 < filteredItems.count }
        guard let row = selectedRows.first else {
            previewedItemID = nil
            previewSource = nil
            previewImageView.image = placeholderPreviewImage()
            previewImageView.contentTintColor = .tertiaryLabelColor
            previewTitleLabel.stringValue = filteredItems.isEmpty ? "没有符合条件的航拍" : "选择一个航拍查看预览"
            previewCategoryLabel.stringValue = ""
            previewStatusLabel.stringValue = ""
            previewSourceLabel.stringValue = ""
            previewDownloadButton.isEnabled = false
            return
        }

        let item = filteredItems[row]
        let isNewItem = previewedItemID != item.id
        previewedItemID = item.id
        previewTitleLabel.stringValue = item.displayName
        previewCategoryLabel.stringValue = "分类：\(item.categoryDisplayName)"
        previewStatusLabel.stringValue = "状态：\(statusText(for: item))"
        previewStatusLabel.textColor = statusColor(for: item)
        previewDownloadButton.isEnabled = selectedRows.count == 1 && canDownload(item)
        previewDownloadButton.title = downloadedIDs.contains(item.id) ? "已经下载" : "下载这段航拍"

        if !isNewItem {
            if let previewSource {
                let selectionPrefix = selectedRows.count > 1 ? "已选择 \(selectedRows.count) 段 · " : ""
                previewSourceLabel.stringValue = selectionPrefix + previewSource.rawValue
            }
            return
        }
        previewSource = nil
        previewImageView.image = placeholderPreviewImage()
        previewImageView.contentTintColor = .tertiaryLabelColor
        previewSourceLabel.stringValue = "正在载入预览…"

        AerialPreviewProvider.shared.loadPreview(for: item) { [weak self] image, source in
            guard let self, self.previewedItemID == item.id else { return }
            self.previewImageView.image = image ?? self.placeholderPreviewImage()
            self.previewImageView.contentTintColor = image == nil ? .tertiaryLabelColor : nil
            self.previewSource = source
            let selectionPrefix = selectedRows.count > 1 ? "已选择 \(selectedRows.count) 段 · " : ""
            self.previewSourceLabel.stringValue = selectionPrefix + source.rawValue
        }
    }

    private func enqueue(_ candidates: [AerialCatalogItem]) {
        let newItems = candidates.filter { item in
            canDownload(item)
        }
        guard !newItems.isEmpty else {
            progressLabel.stringValue = "所选航拍已经下载或已在队列中"
            return
        }

        for item in newItems {
            states[item.id] = .queued
            pendingItems.append(item)
        }
        batchTotal += newItems.count
        isCancelling = false
        tableView.reloadData()
        updateButtons()
        processNextDownload()
    }

    private func processNextDownload() {
        guard currentTask == nil else { return }
        guard !pendingItems.isEmpty else {
            if batchTotal > 0 {
                progressLabel.stringValue = "本次下载完成：\(batchCompleted)/\(batchTotal)"
                progressIndicator.doubleValue = 1
            }
            updateButtons()
            return
        }

        guard !requiresACPower || isOnACPower() else {
            progressLabel.stringValue = "等待接通电源后继续下载"
            updateButtons()
            return
        }

        let item = pendingItems.removeFirst()
        guard let remoteURL = item.remoteURL else {
            states[item.id] = nil
            batchCompleted += 1
            progressLabel.stringValue = "无法下载：\(item.displayName) 没有远程资源"
            processNextDownload()
            return
        }
        currentItem = item
        states[item.id] = .downloading
        progressIndicator.doubleValue = 0
        progressLabel.stringValue = "正在下载：\(item.displayName)（\(batchCompleted + 1)/\(batchTotal)）"
        tableView.reloadData()
        updateButtons()

        let destination = aerialDeskVideoDirectory.appendingPathComponent("\(item.id).mov")
        let task = URLSession.shared.downloadTask(with: remoteURL) { [weak self] temporaryURL, response, error in
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(DownloadError.httpStatus(http.statusCode))
            } else if let temporaryURL {
                do {
                    try FileManager.default.createDirectory(
                        at: aerialDeskVideoDirectory,
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: destination.path) {
                        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0 else { throw DownloadError.missingTemporaryFile }
                    } else {
                        try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    }
                    result = .success(destination)
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(DownloadError.invalidResponse)
            }

            Task { @MainActor in
                self?.finishDownload(item: item, result: result)
            }
        }
        currentTask = task
        task.resume()

        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
    }

    private func finishDownload(item: AerialCatalogItem, result: Result<URL, Error>) {
        progressTimer?.invalidate()
        progressTimer = nil
        currentTask = nil
        currentItem = nil

        switch result {
        case .success:
            states[item.id] = nil
            downloadedIDs.insert(item.id)
            batchCompleted += 1
            NotificationCenter.default.post(name: .aerialDeskDownloadsChanged, object: item.id)
        case .failure(let error):
            let nsError = error as NSError
            if isCancelling || nsError.code == NSURLErrorCancelled {
                states[item.id] = nil
            } else {
                states[item.id] = .failed(error.localizedDescription)
                batchCompleted += 1
                progressLabel.stringValue = "下载失败：\(item.displayName) — \(error.localizedDescription)"
            }
        }

        previewedItemID = nil
        applyFilter()
        processNextDownload()
    }

    private func updateProgress() {
        guard let currentTask, let currentItem else { return }
        let progress = currentTask.progress
        let fraction = max(0, min(1, progress.fractionCompleted))
        progressIndicator.doubleValue = fraction

        let received = ByteCountFormatter.string(
            fromByteCount: progress.completedUnitCount,
            countStyle: .file
        )
        let total = progress.totalUnitCount > 0
            ? ByteCountFormatter.string(fromByteCount: progress.totalUnitCount, countStyle: .file)
            : "未知大小"
        progressLabel.stringValue = "正在下载：\(currentItem.displayName) · \(received) / \(total) · \(batchCompleted + 1)/\(batchTotal)"
        tableView.reloadData()
        updatePreview()
    }

    private func updatePowerState() {
        let source = currentPowerSourceName()
        powerLabel.stringValue = source == "AC Power" ? "电源：已接通" : "电源：使用电池"

        if requiresACPower {
            if isOnACPower() {
                if currentTask?.state == .suspended {
                    currentTask?.resume()
                }
                processNextDownload()
            } else if currentTask?.state == .running {
                currentTask?.suspend()
                progressLabel.stringValue = "已切换到电池，下载暂停"
            }
        } else {
            if currentTask?.state == .suspended {
                currentTask?.resume()
            }
            processNextDownload()
        }
    }

    private func confirmLargeDownload(items: [AerialCatalogItem], scope: String) -> Bool {
        let pendingCount = items.filter { canDownload($0) }.count
        guard pendingCount > 0 else {
            progressLabel.stringValue = "\(scope)中的航拍已经全部下载"
            return false
        }

        let average = AerialCatalog.shared.averageDownloadedVideoBytes() ?? 600_000_000
        let estimated = average * Int64(pendingCount)
        let estimatedText = ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file)
        let capacity = (try? aerialDeskVideoDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let capacityText = capacity.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "未知"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "准备下载 \(pendingCount) 段航拍视频？"
        alert.informativeText = "范围：\(scope)\n按当前文件平均大小估算约需 \(estimatedText)，磁盘可用空间约 \(capacityText)。实际大小由 Apple 服务器资源决定。下载默认仅在接通电源时进行。"
        alert.addButton(withTitle: "开始下载")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func filterChanged() {
        applyFilter()
    }

    @objc private func refreshCatalog() {
        reloadCatalog()
        progressLabel.stringValue = "清单已刷新"
    }

    @objc private func requiresACChanged() {
        UserDefaults.standard.set(requiresACPower, forKey: "DownloadRequiresAC")
        updatePowerState()
    }

    @objc private func downloadSelected() {
        let items = tableView.selectedRowIndexes.compactMap { index in
            index < filteredItems.count ? filteredItems[index] : nil
        }
        enqueue(items)
    }

    @objc private func downloadPreviewedItem() {
        guard let previewedItemID,
              let item = filteredItems.first(where: { $0.id == previewedItemID }) else { return }
        enqueue([item])
    }

    @objc private func downloadCategory() {
        guard let categoryID = categoryPopup.selectedItem?.representedObject as? String,
              categoryID != "all" else { return }
        let items = allItems.filter { $0.categoryID == categoryID }
        let scope = categoryPopup.selectedItem?.title ?? "当前分类"
        guard confirmLargeDownload(items: items, scope: scope) else { return }
        enqueue(items)
    }

    @objc private func downloadAll() {
        guard confirmLargeDownload(items: allItems, scope: "全部分类") else { return }
        enqueue(allItems)
    }

    @objc private func cancelDownloads() {
        isCancelling = true
        currentTask?.cancel()
        for item in pendingItems {
            states[item.id] = nil
        }
        pendingItems.removeAll()
        batchTotal = 0
        batchCompleted = 0
        progressIndicator.doubleValue = 0
        progressLabel.stringValue = "下载队列已取消"
        tableView.reloadData()
        updateButtons()
    }

    @objc private func openDownloadFolder() {
        try? FileManager.default.createDirectory(at: aerialDeskVideoDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(aerialDeskVideoDirectory)
    }
}
