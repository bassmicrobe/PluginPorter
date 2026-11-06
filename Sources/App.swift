import AppKit
import Foundation

private final class PorterPanel: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 12
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class PluginPorterDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let inventoryLoader: (URL, Bool) throws -> [TransferItem]
    private var window: NSWindow!
    private let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    private var items: [TransferItem] = []
    private var visibleItems: [TransferItem] = []
    private var selectedIDs = Set<String>()
    private var archiveURL: URL?
    private var busy = false
    private let table = NSTableView()
    private let search = NSSearchField()
    private let modeLabel = NSTextField(labelWithString: "このMacのプラグイン")
    private let subtitle = NSTextField(wrappingLabelWithString: "プラグイン・プリセット・音源を選んで、別のMacへ。元のファイルは残ります。")
    private let summary = NSTextField(labelWithString: "準備中…")
    private let status = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "項目をクリックすると、保存場所や注意事項が表示されます。")
    private let logView = NSTextView()
    private let spinner = NSProgressIndicator()
    private var scanButton: NSButton!
    private var addButton: NSButton!
    private var openButton: NSButton!
    private var allButton: NSButton!
    private var noneButton: NSButton!
    private var exportButton: NSButton!
    private var restoreButton: NSButton!
    private var verifyButton: NSButton!
    private var presetsButton: NSButton!
    private var presetOrganizer: PresetOrganizerWindowController?

    init(inventoryLoader: @escaping (URL, Bool) throws -> [TransferItem] = { try Inventory.scan(home: $0, includeData: $1) }) {
        self.inventoryLoader = inventoryLoader
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scan(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy || presetOrganizer?.isBusy == true {
            let alert = NSAlert()
            alert.messageText = "処理が終わるまでお待ちください"
            alert.informativeText = "コピーや検証を安全に完了するため、処理中は終了できません。"
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard busy else { return true }
        status.stringValue = "処理中です。完了してからウインドウを閉じてください。"
        return false
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "PluginPorterについて", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "PluginPorterを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(withTitle: "ウインドウを閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded
        value.controlSize = .regular
        if let symbol = symbol { value.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); value.imagePosition = .imageLeading }
        return value
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 810), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PluginPorter"
        window.subtitle = "Mac → Mac プラグイン移行"
        window.minSize = NSSize(width: 950, height: 780)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let content = window.contentView!
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 14
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemTeal
        icon.symbolConfiguration = .init(pointSize: 34, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let headings = NSStackView()
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = 4
        let title = NSTextField(labelWithString: "PluginPorter")
        title.font = .systemFont(ofSize: 27, weight: .bold)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        headings.addArrangedSubview(title)
        headings.addArrangedSubview(subtitle)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(headings)
        root.addArrangedSubview(header)

        let toolbar = NSStackView()
        toolbar.spacing = 8
        scanButton = button("このMacをスキャン", #selector(scan(_:)), symbol: "arrow.clockwise")
        addButton = button("音源フォルダを追加", #selector(addFolder(_:)), symbol: "folder.badge.plus")
        openButton = button("アーカイブを開く", #selector(openArchive(_:)), symbol: "shippingbox")
        presetsButton = button("プリセット整理…", #selector(openPresetOrganizer(_:)), symbol: "tray.and.arrow.down")
        [scanButton, addButton, openButton, presetsButton].forEach { toolbar.addArrangedSubview($0!) }
        root.addArrangedSubview(toolbar)

        let notePanel = PorterPanel(color: NSColor.controlAccentColor.withAlphaComponent(0.07))
        let note = NSTextField(wrappingLabelWithString: "本体のみを初期選択します。プリセット・音源などの関連データは候補を確認して追加してください。\n認証は移行先で行います。共有部品やドライバを使う製品は、公式インストーラでの再導入が必要な場合があります。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        notePanel.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: notePanel.leadingAnchor, constant: 13),
            note.trailingAnchor.constraint(equalTo: notePanel.trailingAnchor, constant: -13),
            note.topAnchor.constraint(equalTo: notePanel.topAnchor, constant: 11),
            note.bottomAnchor.constraint(equalTo: notePanel.bottomAnchor, constant: -11)
        ])
        root.addArrangedSubview(notePanel)
        notePanel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let filterRow = NSStackView()
        filterRow.spacing = 10
        modeLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        filterRow.addArrangedSubview(modeLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filterRow.addArrangedSubview(spacer)
        search.placeholderString = "名前・形式・CPU・パスで絞り込み"
        search.setAccessibilityLabel("名前・形式・CPU・パスで絞り込み")
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 260).isActive = true
        filterRow.addArrangedSubview(search)
        allButton = button("表示中を選択", #selector(selectVisible(_:)))
        noneButton = button("選択を解除", #selector(selectNone(_:)))
        filterRow.addArrangedSubview(allButton)
        filterRow.addArrangedSubview(noneButton)
        root.addArrangedSubview(filterRow)
        filterRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let columns: [(String, String, CGFloat)] = [("checked", "", 35), ("name", "プラグイン / データ", 245), ("kind", "形式", 80), ("cpu", "CPU対応", 135), ("size", "容量", 90), ("path", "保存場所", 380)]
        for (id, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = id == "checked" ? 35 : 60
            if id == "checked" { col.maxWidth = 35 }
            table.addTableColumn(col)
        }
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 29
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.borderType = .bezelBorder
        root.addArrangedSubview(tableScroll)
        tableScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byTruncatingTail
        root.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        detail.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let actionRow = NSStackView()
        actionRow.spacing = 10
        summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        actionRow.addArrangedSubview(summary)
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionRow.addArrangedSubview(actionSpacer)
        verifyButton = button("アーカイブを検証", #selector(verifyArchive(_:)), symbol: "checkmark.shield")
        restoreButton = button("このMacへ復元…", #selector(restoreArchive(_:)), symbol: "square.and.arrow.down")
        exportButton = button("バックアップを作成…", #selector(exportArchive(_:)), symbol: "square.and.arrow.up")
        exportButton.bezelColor = .controlAccentColor
        [verifyButton, restoreButton, exportButton].forEach { actionRow.addArrangedSubview($0!) }
        root.addArrangedSubview(actionRow)
        actionRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let statusRow = NSStackView()
        statusRow.spacing = 8
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(status)
        root.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.backgroundColor = .textBackgroundColor
        logView.textContainerInset = NSSize(width: 8, height: 5)
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        root.addArrangedSubview(logScroll)
        logScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        logScroll.heightAnchor.constraint(equalToConstant: 66).isActive = true
        updateControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visibleItems.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let item = visibleItems[row]
        if id == "checked" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleItem(_:)))
            check.state = selectedIDs.contains(item.id) ? .on : .off
            check.tag = row
            check.isEnabled = !busy && canSelect(item)
            check.toolTip = archiveURL == nil ? item.exportBlockReason : nil
            check.setAccessibilityLabel("\(item.name)を選択")
            return check
        }
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        switch id {
        case "name":
            field.stringValue = item.name
            if !canSelect(item) { field.textColor = .systemOrange }
        case "kind":
            field.stringValue = !canSelect(item) ? "要再導入" : (isPlugin(item) ? item.kind : "データ候補")
            field.textColor = !canSelect(item) || !isPlugin(item) ? .systemOrange : .secondaryLabelColor
        case "cpu":
            field.stringValue = item.cpuSupportLabel
            field.textColor = item.hasIntelOnlyCPU ? .systemOrange : .secondaryLabelColor
            if item.hasIntelOnlyCPU { field.font = .systemFont(ofSize: 12, weight: .semibold) }
        case "size": field.stringValue = formattedBytes(item.bytes); field.alignment = .right; field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        default:
            let displayedPath = archiveURL == nil ? item.sourcePath : ((try? scopeRoot(item.scope, home: home).appendingPathComponent(item.relativePath).path) ?? item.relativePath)
            field.stringValue = displayedPath.replacingOccurrences(of: home.path + "/", with: "~/")
        }
        field.toolTip = item.sourcePath + "\nCPU対応: " + item.cpuSupportLabel + (item.cpuSupportLabel == "両対応" ? "（Apple Silicon + Intel）" : "") + (item.architectures.isEmpty ? "" : " / " + item.architectures.joined(separator: ", ")) + (!canSelect(item) ? "\n書き出し対象外: " + (item.exportBlockReason ?? "") : "") + (item.notes.isEmpty ? "" : "\n" + item.notes.joined(separator: "\n"))
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < visibleItems.count else { return }
        let item = visibleItems[row]
        let arch = "CPU対応: " + item.cpuSupportLabel + (item.cpuSupportLabel == "両対応" ? "（Apple Silicon + Intel）" : "") + (item.architectures.isEmpty ? "" : " / " + item.architectures.joined(separator: ", "))
        let path = archiveURL == nil ? item.sourcePath : ((try? scopeRoot(item.scope, home: home).appendingPathComponent(item.relativePath).path) ?? item.relativePath)
        detail.stringValue = "\(path)\n" + (!canSelect(item) ? "書き出し対象外: " + (item.exportBlockReason ?? "") + "\n" : "") + arch + (item.notes.isEmpty ? "" : "  ·  " + item.notes.joined(separator: " / "))
        detail.toolTip = detail.stringValue
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !busy }

    func controlTextDidChange(_ obj: Notification) { guard !busy else { return }; applyFilter() }

    private func isPlugin(_ item: TransferItem) -> Bool {
        guard ["AU", "VST", "VST3", "AAX"].contains(item.kind) else { return false }
        return ["systemPlugins", "userPlugins"].contains(item.scope) ||
            (item.kind == "AAX" && item.scope == "systemSupport" && item.relativePath.hasPrefix("Avid/Audio/Plug-Ins/"))
    }

    private func canSelect(_ item: TransferItem) -> Bool {
        archiveURL != nil || item.exportBlockReason == nil
    }

    private func applyFilter() {
        let text = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleItems = text.isEmpty ? items : items.filter { "\($0.name) \($0.kind) \($0.sourcePath) \($0.cpuSupportLabel) \($0.architectures.joined(separator: " ")) \($0.cpuSupportLabel == "両対応" ? "Apple Silicon Intel" : "") \(canSelect($0) ? "" : "要再導入 " + ($0.exportBlockReason ?? ""))".localizedCaseInsensitiveContains(text) }
        table.reloadData()
        updateControls()
    }

    private func updateControls() {
        let chosen = items.filter { selectedIDs.contains($0.id) && canSelect($0) }
        let blockedCount = items.filter { !canSelect($0) }.count
        summary.stringValue = "\(chosen.count) / \(items.count) 件を選択 · \(formattedBytes(chosen.reduce(Int64(0)) { $0 + $1.bytes }))" + (blockedCount > 0 ? " · 除外 \(blockedCount) 件" : "")
        summary.toolTip = "AU・VST・VST3など、形式ごとのファイル数です。同じ製品でも形式が異なれば別の項目になります。" + (blockedCount > 0 ? "\n書き出せない \(blockedCount) 件は選択できません。オレンジ色の項目で理由を確認してください。" : "")
        scanButton?.isEnabled = !busy
        addButton?.isEnabled = !busy && archiveURL == nil
        openButton?.isEnabled = !busy
        allButton?.isEnabled = !busy && visibleItems.contains { canSelect($0) }
        noneButton?.isEnabled = !busy && !selectedIDs.isEmpty
        exportButton?.isEnabled = !busy && archiveURL == nil && !chosen.isEmpty
        restoreButton?.isEnabled = !busy && archiveURL != nil && !chosen.isEmpty
        verifyButton?.isEnabled = !busy && archiveURL != nil
        presetsButton?.isEnabled = !busy
        search.isEnabled = !busy
    }

    @objc private func openPresetOrganizer(_ sender: Any?) {
        if presetOrganizer == nil { presetOrganizer = PresetOrganizerWindowController() }
        presetOrganizer?.showWindow(nil)
        presetOrganizer?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleItem(_ sender: NSButton) {
        guard !busy, sender.tag >= 0, sender.tag < visibleItems.count, canSelect(visibleItems[sender.tag]) else { return }
        let id = visibleItems[sender.tag].id
        if sender.state == .on { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        updateControls()
    }

    @objc private func selectVisible(_ sender: Any?) {
        guard !busy else { return }
        visibleItems.filter { canSelect($0) }.forEach { selectedIDs.insert($0.id) }
        table.reloadData(); updateControls()
    }

    @objc private func selectNone(_ sender: Any?) {
        guard !busy else { return }
        selectedIDs.removeAll(); table.reloadData(); updateControls()
    }

    private func begin(_ text: String) {
        busy = true
        status.stringValue = text
        logView.string = ""
        appendLog(text)
        spinner.startAnimation(nil)
        updateControls()
        table.reloadData()
    }

    private func end(_ text: String) {
        busy = false
        status.stringValue = text
        appendLog(text)
        spinner.stopAnimation(nil)
        updateControls()
        table.reloadData()
    }

    private func appendLog(_ text: String) {
        logView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        logView.scrollToEndOfDocument(nil)
    }

    private func progress(_ text: String) {
        DispatchQueue.main.async { self.status.stringValue = text; self.appendLog(text) }
    }

    private func fail(_ error: Error) {
        end("完了できませんでした: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "処理を完了できませんでした"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    @objc private func scan(_ sender: Any?) {
        guard !busy else { return }
        begin("プラグインと関連データ候補を調べています… 大容量の音源は時間がかかる場合があります。")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let found = try self.inventoryLoader(self.home, true)
                DispatchQueue.main.async {
                    self.archiveURL = nil
                    self.items = found
                    self.selectedIDs = Set(found.filter { self.isPlugin($0) && self.canSelect($0) }.map(\.id))
                    self.modeLabel.stringValue = "このMacのプラグイン"
                    self.search.stringValue = ""
                    self.applyFilter()
                    let blockedCount = found.filter { !self.canSelect($0) }.count
                    self.end("スキャン完了。関連データは未選択です。" + (blockedCount > 0 ? "書き出せない \(blockedCount) 件を除外しました。オレンジ色の項目で理由を確認してください。" : "必要な項目を確認してください。"))
                }
            } catch { DispatchQueue.main.async { self.fail(error) } }
        }
    }

    @objc private func addFolder(_ sender: Any?) {
        guard !busy, archiveURL == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "追加する音源・プリセットフォルダを選択"
        panel.message = "関連データだけを選んでください。書き出し可能なフォルダは選択状態になります。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            self.begin("フォルダの容量と内容を調べています…")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let item = try Inventory.makeItem(url: url, home: self.home)
                    DispatchQueue.main.async {
                        if let index = self.items.firstIndex(where: { $0.sourcePath == item.sourcePath }) {
                            self.selectedIDs.remove(self.items[index].id)
                            self.items[index] = item
                        } else { self.items.append(item) }
                        if self.canSelect(item) { self.selectedIDs.insert(item.id) }
                        self.applyFilter()
                        self.end(self.canSelect(item) ? "フォルダを追加しました。外部の音源は移行先の Music/PluginPorter Libraries に復元されます。" : "追加したフォルダは書き出し対象外です: " + (item.exportBlockReason ?? ""))
                    }
                } catch { DispatchQueue.main.async { self.fail(error) } }
            }
        }
    }

    @objc private func openArchive(_ sender: Any?) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "PluginPorterアーカイブを開く"
        panel.message = "バックアップ時に作成した .pluginporter フォルダを選択してください。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            self.begin("アーカイブを読み込んでいます…")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let manifest = try TransferEngine.readManifest(at: url)
                    DispatchQueue.main.async {
                        self.archiveURL = url
                        self.items = manifest.entries.map(\.item)
                        self.selectedIDs = Set(self.items.map(\.id))
                        self.search.stringValue = ""
                        self.modeLabel.stringValue = "復元: \(url.lastPathComponent)"
                        self.modeLabel.toolTip = url.path
                        self.applyFilter()
                        self.end("アーカイブを開きました。保存場所の列は復元先です。既存のフォルダは中身を含めて丸ごとスキップします。")
                    }
                } catch { DispatchQueue.main.async { self.fail(error) } }
            }
        }
    }

    @objc private func exportArchive(_ sender: Any?) {
        guard !busy, archiveURL == nil else { return }
        let chosen = items.filter { selectedIDs.contains($0.id) && canSelect($0) }
        guard !chosen.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "バックアップの保存先"
        panel.message = "DAWとメーカーの更新アプリを終了してから、外付けSSDなどを選択してください。選択したデータのコピーと検証を行います。"
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Plugins-\(formatter.string(from: Date())).pluginporter"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let chosenURL = panel.url else { return }
            let url = chosenURL.pathExtension == "pluginporter" ? chosenURL : chosenURL.appendingPathExtension("pluginporter")
            self.begin("バックアップを作成しています… 元のファイルは変更しません。")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let manifest = try TransferEngine.export(items: chosen, to: url, progress: self.progress)
                    DispatchQueue.main.async {
                        self.end("バックアップ完了: \(manifest.entries.count) 件 → \(url.path)")
                        let alert = NSAlert()
                        alert.messageText = "バックアップを作成しました"
                        alert.informativeText = "\(manifest.entries.count) 件を保存しました。\n\n移行先のMacでPluginPorterを起動し、この .pluginporter フォルダを開いて復元してください。\n\n\(url.path)"
                        alert.addButton(withTitle: "OK")
                        alert.addButton(withTitle: "Finderで表示")
                        alert.beginSheetModal(for: self.window) { response in
                            if response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                } catch { DispatchQueue.main.async { self.fail(error) } }
            }
        }
    }

    @objc private func verifyArchive(_ sender: Any?) {
        guard !busy, let url = archiveURL else { return }
        begin("保存データの整合性を検証しています…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try TransferEngine.verify(at: url, progress: self.progress)
                DispatchQueue.main.async { self.end("検証完了。アーカイブの整合性を確認しました。") }
            } catch { DispatchQueue.main.async { self.fail(error) } }
        }
    }

    @objc private func restoreArchive(_ sender: Any?) {
        guard !busy, let url = archiveURL else { return }
        let chosen = items.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let ids = Set(chosen.map(\.id))
        let needsAdmin = chosen.contains { ["systemPlugins", "systemPresets", "systemSupport", "shared"].contains($0.scope) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "選択した項目をこのMacへ復元しますか？"
        alert.informativeText = "\(chosen.count) 件 / \(formattedBytes(chosen.reduce(Int64(0)) { $0 + $1.bytes }))\n\n• 自分で作成した信頼できるアーカイブを使用してください。\n• 既存のフォルダは中身を含めて丸ごとスキップします。結合・上書きはしません。\n• ライセンスは移行先で再認証してください。\n• 共有部品・ドライバが必要な製品は、公式インストーラで再導入してください。\n• 復元後はDAWを再起動してプラグインを再スキャンしてください。" + (needsAdmin ? "\n\nシステムのフォルダへ保存するため、macOSが管理者認証を求めます。" : "")
        alert.addButton(withTitle: "復元する")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.begin(needsAdmin ? "管理者認証を待っています。その後、検証と復元を行います…" : "アーカイブを検証して復元しています…")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let report = try needsAdmin ? self.privilegedRestore(url: url, ids: ids) : TransferEngine.restore(from: url, home: self.home, selectedIDs: ids, progress: self.progress)
                    DispatchQueue.main.async { self.showReport(report) }
                } catch { DispatchQueue.main.async { self.fail(error) } }
            }
        }
    }

    private func showReport(_ report: TransferReport) {
        let summary = "復元 \(report.completed.count) 件 / スキップ \(report.skipped.count) 件 / 失敗 \(report.failed.count) 件"
        end(summary)
        for item in report.completed { appendLog("復元: " + item) }
        for item in report.skipped { appendLog("スキップ: " + item) }
        for item in report.failed { appendLog("失敗: " + item) }
        let alert = NSAlert()
        alert.alertStyle = report.failed.isEmpty ? .informational : .warning
        alert.messageText = report.failed.isEmpty ? "復元処理が完了しました" : "一部の項目を復元できませんでした"
        let failures = report.failed.prefix(6).joined(separator: "\n")
        alert.informativeText = summary + "\n\n" + (failures.isEmpty ? "詳細はウインドウ下部のログで確認できます。" : failures + (report.failed.count > 6 ? "\nほかの失敗はログを確認してください。" : "")) + "\n\n移行した製品を再認証し、DAWで再スキャンしてください。"
        alert.beginSheetModal(for: window)
    }

    private func privilegedRestore(url: URL, ids: Set<String>) throws -> TransferReport {
        guard let executable = Bundle.main.executableURL else { throw porterFail("アプリの実行ファイルが見つかりません。") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PluginPorter-restore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? FileManager.default.removeItem(at: temp) }
        let reportURL = temp.appendingPathComponent("report.json")
        let args = [executable.path, "--cli", "restore", url.path, "--home", home.path, "--ids", ids.sorted().joined(separator: ","), "--report", reportURL.path]
        let command = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let scriptCommand = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(scriptCommand)\" with administrator privileges"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = String(data: output, encoding: .utf8) ?? ""
        if !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { progress(log) }
        if FileManager.default.fileExists(atPath: reportURL.path) {
            return try JSONDecoder().decode(TransferReport.self, from: Data(contentsOf: reportURL))
        }
        if process.terminationStatus != 0 {
            if log.contains("-128") { throw porterFail("管理者認証がキャンセルされました。") }
            throw porterFail("管理者権限での復元を完了できませんでした。\n" + log)
        }
        throw porterFail("復元レポートを読み込めませんでした。ログと復元先を確認してください。")
    }
}

func runGUI() {
    let application = NSApplication.shared
    let delegate = PluginPorterDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
