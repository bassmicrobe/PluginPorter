import AppKit
import Foundation

private final class PresetDropArea: NSView {
    var onDrop: (([URL]) -> Void)?
    var allowsDrop = true
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 10
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func folders(_ sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []
        return objects.map { $0 as URL }.filter { url in
            var directory: ObjCBool = false
            return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = allowsDrop && !folders(sender).isEmpty
        return highlighted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = folders(sender)
        guard allowsDrop, !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlAccentColor.withAlphaComponent(0.06)).setFill()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        outline.fill()
        (highlighted ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.45)).setStroke()
        outline.lineWidth = highlighted ? 2 : 1
        let dash: [CGFloat] = [6, 4]
        outline.setLineDash(dash, count: dash.count, phase: 0)
        outline.stroke()
    }
}

final class PresetOrganizerWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    private var libraries: [PresetLibrary] = []
    private var inputFolders: [URL] = []
    private var plan: PresetImportPlan?
    private var busy = false
    var isBusy: Bool { busy }
    private let table = NSTableView()
    private let dropArea = PresetDropArea(frame: .zero)
    private let sourceLabel = NSTextField(labelWithString: "複数フォルダをまとめて追加できます。ZIPは先に解凍してください。")
    private let serumPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let libraryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let assignPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rootLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "フォルダを追加すると、保存先を一覧で確認できます。")
    private let detailLabel = NSTextField(wrappingLabelWithString: "判別できないプリセットは未選択です。行を選び、シンセを指定してから保存できます。")
    private let statusLabel = NSTextField(labelWithString: "準備完了")
    private let logView = NSTextView()
    private let spinner = NSProgressIndicator()
    private var folderButton: NSButton!
    private var clearButton: NSButton!
    private var rootButton: NSButton!
    private var allButton: NSButton!
    private var noneButton: NSButton!
    private var assignButton: NSButton!
    private var installButton: NSButton!
    private let rootDefaultsKey = "PluginPorter.PresetLibraryRoots"

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        libraries = PresetOrganizer.defaultLibraries(home: home)
        let overrides = UserDefaults.standard.dictionary(forKey: rootDefaultsKey) as? [String: String] ?? [:]
        for index in libraries.indices {
            if let path = overrides[libraries[index].id], path.hasPrefix("/") {
                libraries[index].rootPath = path
                libraries[index].detected = FileManager.default.fileExists(atPath: path)
            }
        }
        window.title = "プリセット整理"
        window.subtitle = "PluginPorter · 購入したパックをシンセごとのライブラリへ"
        window.minSize = NSSize(width: 1040, height: 800)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildWindow()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard busy else { return true }
        statusLabel.stringValue = "処理中です。完了してからウインドウを閉じてください。"
        return false
    }

    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        if let symbol = symbol {
            result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            result.imagePosition = .imageLeading
        }
        return result
    }
    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        return stack
    }
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    private func buildWindow() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        func addWide(_ view: NSView) {
            root.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        let title = NSTextField(labelWithString: "パックをまとめて、プリセットを整理。")
        title.font = .systemFont(ofSize: 23, weight: .bold)
        folderButton = button("フォルダを選択…", #selector(chooseFolders(_:)), symbol: "folder.badge.plus")
        clearButton = button("一覧をクリア", #selector(clearInputs(_:)))
        addWide(row([title, spacer(), folderButton, clearButton]))

        let dropTitle = NSTextField(labelWithString: "解凍済みのサンプルパック・プリセットフォルダをここにドロップ")
        dropTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        let dropText = NSStackView(views: [dropTitle, sourceLabel])
        dropText.orientation = .vertical
        dropText.alignment = .centerX
        dropText.spacing = 6
        dropText.translatesAutoresizingMaskIntoConstraints = false
        dropArea.addSubview(dropText)
        NSLayoutConstraint.activate([
            dropText.centerXAnchor.constraint(equalTo: dropArea.centerXAnchor),
            dropText.centerYAnchor.constraint(equalTo: dropArea.centerYAnchor),
            dropText.leadingAnchor.constraint(greaterThanOrEqualTo: dropArea.leadingAnchor, constant: 14),
            dropText.trailingAnchor.constraint(lessThanOrEqualTo: dropArea.trailingAnchor, constant: -14),
            dropArea.heightAnchor.constraint(equalToConstant: 78)
        ])
        dropArea.onDrop = { [weak self] urls in self?.addFolders(urls) }
        addWide(dropArea)

        serumPopup.addItems(withTitles: ["Serum", "Serum 2"])
        serumPopup.setAccessibilityLabel("Serum .fxp の保存先")
        libraryPopup.setAccessibilityLabel("保存先を確認・変更するライブラリ")
        assignPopup.setAccessibilityLabel("選んだ行の保存先シンセ")
        serumPopup.item(at: 0)?.representedObject = "serum1"
        serumPopup.item(at: 1)?.representedObject = "serum2"
        if libraries.first(where: { $0.id == "serum1" })?.detected != true,
           libraries.first(where: { $0.id == "serum2" })?.detected == true { serumPopup.selectItem(at: 1) }
        serumPopup.target = self
        serumPopup.action = #selector(serumDestinationChanged(_:))
        let serumHint = NSTextField(labelWithString: "Serum 2形式はSerum 2へ保存します。")
        serumHint.font = .systemFont(ofSize: 11)
        serumHint.textColor = .secondaryLabelColor
        addWide(row([NSTextField(labelWithString: "Serum .fxp の保存先"), serumPopup, serumHint, spacer()]))

        for library in libraries {
            libraryPopup.addItem(withTitle: library.name)
            libraryPopup.lastItem?.representedObject = library.id
            assignPopup.addItem(withTitle: library.name)
            assignPopup.lastItem?.representedObject = library.id
        }
        libraryPopup.target = self
        libraryPopup.action = #selector(libraryChanged(_:))
        libraryPopup.widthAnchor.constraint(equalToConstant: 125).isActive = true
        rootLabel.font = .systemFont(ofSize: 11)
        rootLabel.textColor = .secondaryLabelColor
        rootLabel.lineBreakMode = .byTruncatingMiddle
        rootLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rootButton = button("保存先を変更…", #selector(chooseLibraryRoot(_:)), symbol: "folder")
        addWide(row([NSTextField(labelWithString: "ライブラリ"), libraryPopup, rootLabel, spacer(), rootButton]))
        updateRootLabel()

        let rules = NSTextField(wrappingLabelWithString: "Serum / Serum 2を優先して自動判別。プリセットと付属のTables・Noisesなどを分けて保存します。\n保存前に一覧を確認してください。同名の既存ファイルはスキップし、元のパックは残ります。一般のループ素材は対象外です。")
        rules.font = .systemFont(ofSize: 11)
        rules.textColor = .secondaryLabelColor
        addWide(rules)

        allButton = button("保存可能な項目を選択", #selector(selectReady(_:)))
        noneButton = button("選択を解除", #selector(selectNone(_:)))
        assignPopup.widthAnchor.constraint(equalToConstant: 125).isActive = true
        assignButton = button("選んだ行に適用", #selector(assignSelectedRows(_:)))
        let assignLabel = NSTextField(labelWithString: "行の保存先:")
        assignLabel.font = .systemFont(ofSize: 11)
        addWide(row([allButton, noneButton, spacer(), assignLabel, assignPopup, assignButton]))

        for (id, label, width) in [("checked", "", CGFloat(30)), ("name", "ファイル", 205), ("kind", "種類", 90), ("target", "シンセ", 110), ("destination", "保存先", 350), ("state", "判定・理由", 260)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            column.minWidth = id == "checked" ? 30 : 65
            if id == "checked" { column.maxWidth = 30 }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.rowHeight = 27
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        addWide(tableScroll)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.heightAnchor.constraint(equalToConstant: 43).isActive = true
        addWide(detailLabel)
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        installButton = button("選択したプリセットを保存…", #selector(installSelected(_:)), symbol: "square.and.arrow.down")
        installButton.bezelColor = .controlAccentColor
        addWide(row([summaryLabel, spacer(), installButton]))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        addWide(row([spinner, statusLabel]))
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.textContainerInset = NSSize(width: 7, height: 5)
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        addWide(logScroll)
        updateControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { plan?.items.count ?? 0 }
    private func ready(_ item: PresetImportItem) -> Bool { item.destinationPath != nil && item.targetID != nil }
    private func kindName(_ kind: String) -> String {
        ["preset": "プリセット", "wavetable": "Wavetable", "noise": "Noise", "sample": "サンプル", "multisample": "Multisample", "lfo": "LFO", "effect": "FXチェーン", "shape": "LFO Shape", "path": "LFO Path", "unknown": "未判別"][kind] ?? kind
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let items = plan?.items, row >= 0, row < items.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        if id == "checked" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleItem(_:)))
            check.state = item.selected ? .on : .off
            check.tag = row
            check.isEnabled = !busy && ready(item)
            check.setAccessibilityLabel(URL(fileURLWithPath: item.sourcePath).lastPathComponent + "を保存対象にする")
            return check
        }
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle
        switch id {
        case "name": field.stringValue = URL(fileURLWithPath: item.sourcePath).lastPathComponent
        case "kind": field.stringValue = kindName(item.kind)
        case "target": field.stringValue = libraries.first(where: { $0.id == item.targetID })?.name ?? "要指定"
        case "destination": field.stringValue = (item.destinationPath ?? "保存先を指定してください").replacingOccurrences(of: home.path + "/", with: "~/")
        default: field.stringValue = item.reason
        }
        if !ready(item) { field.textColor = .systemOrange }
        else if id != "name" { field.textColor = .secondaryLabelColor }
        field.toolTip = "元: \(item.sourcePath)\n先: \(item.destinationPath ?? "未指定")\n\(item.reason)"
        return field
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !busy }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
        guard let items = plan?.items, table.selectedRow >= 0, table.selectedRow < items.count else { return }
        let item = items[table.selectedRow]
        detailLabel.stringValue = "元: \(item.sourcePath)\n先: \(item.destinationPath ?? "未指定 — 行の保存先を指定してください")\n\(item.reason)"
        detailLabel.toolTip = detailLabel.stringValue
    }

    private func updateControls() {
        let items = plan?.items ?? []
        let chosen = items.filter { $0.selected && ready($0) }
        summaryLabel.stringValue = "選択 \(chosen.count) / \(items.count) 件 · \(formattedBytes(chosen.reduce(Int64(0)) { $0 + $1.bytes }))" + (plan == nil ? "" : " · 対象外 \(plan?.ignoredFileCount ?? 0) 件")
        folderButton?.isEnabled = !busy
        clearButton?.isEnabled = !busy && !inputFolders.isEmpty
        serumPopup.isEnabled = !busy
        libraryPopup.isEnabled = !busy
        rootButton?.isEnabled = !busy
        assignPopup.isEnabled = !busy
        assignButton?.isEnabled = !busy && !table.selectedRowIndexes.isEmpty
        allButton?.isEnabled = !busy && items.contains(where: ready)
        noneButton?.isEnabled = !busy && items.contains(where: { $0.selected })
        installButton?.isEnabled = !busy && !chosen.isEmpty
        dropArea.allowsDrop = !busy
    }
    private func updateRootLabel() {
        let id = libraryPopup.selectedItem?.representedObject as? String
        guard let library = libraries.first(where: { $0.id == id }) else { return }
        rootLabel.stringValue = library.rootPath.replacingOccurrences(of: home.path + "/", with: "~/")
        rootLabel.toolTip = library.rootPath + "\nシンセのライブラリのルートフォルダです。"
    }
    private func begin(_ text: String) {
        busy = true
        statusLabel.stringValue = text
        logView.string = ""
        appendLog(text)
        spinner.startAnimation(nil)
        updateControls()
        table.reloadData()
    }
    private func end(_ text: String) {
        busy = false
        statusLabel.stringValue = text
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
        DispatchQueue.main.async { self.statusLabel.stringValue = text; self.appendLog(text) }
    }
    private func showError(_ error: Error) {
        end("処理を完了できませんでした: " + error.localizedDescription)
        guard let window = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "処理を完了できませんでした"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    @objc private func chooseFolders(_ sender: Any?) {
        guard !busy, let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = "プリセットを探すフォルダを選択"
        panel.message = "解凍済みのパックをフォルダごと選択してください。複数のフォルダをまとめて追加できます。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { result in
            if result == .OK { self.addFolders(panel.urls) }
        }
    }
    private func addFolders(_ urls: [URL]) {
        guard !busy else { return }
        var known = Set(inputFolders.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if known.insert(canonical.path).inserted { inputFolders.append(canonical) }
        }
        sourceLabel.stringValue = "\(inputFolders.count) フォルダ: " + inputFolders.map(\.lastPathComponent).joined(separator: " / ")
        sourceLabel.toolTip = inputFolders.map(\.path).joined(separator: "\n")
        analyze()
    }
    private func analyze() {
        guard !busy, !inputFolders.isEmpty else { return }
        let folders = inputFolders
        let destinations = libraries
        let serumTarget = serumPopup.selectedItem?.representedObject as? String ?? "serum1"
        begin("フォルダ内のプリセットと付属データを調べています…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let found = try PresetOrganizer.analyze(folders: folders, libraries: destinations, serumFXPTarget: serumTarget, progress: self.progress)
                DispatchQueue.main.async {
                    self.plan = found
                    self.table.deselectAll(nil)
                    self.detailLabel.stringValue = "判別できない項目は未選択です。保存先の確認後、下のボタンでコピーします。付属データも一覧に含まれます。"
                    self.end("解析完了: \(found.items.count) 件。保存先とチェックを確認してください。")
                    for note in found.notes { self.appendLog(note) }
                }
            } catch { DispatchQueue.main.async { self.plan = nil; self.showError(error) } }
        }
    }
    @objc private func clearInputs(_ sender: Any?) {
        guard !busy else { return }
        inputFolders = []
        plan = nil
        sourceLabel.stringValue = "複数フォルダをまとめて追加できます。ZIPは先に解凍してください。"
        sourceLabel.toolTip = nil
        detailLabel.stringValue = "判別できないプリセットは未選択です。行を選び、シンセを指定してから保存できます。"
        logView.string = ""
        end("一覧をクリアしました。")
    }
    @objc private func serumDestinationChanged(_ sender: Any?) { analyze() }
    @objc private func libraryChanged(_ sender: Any?) { updateRootLabel() }
    @objc private func chooseLibraryRoot(_ sender: Any?) {
        guard !busy, let window = window,
              let id = libraryPopup.selectedItem?.representedObject as? String,
              let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        let library = libraries[index]
        let panel = NSOpenPanel()
        panel.title = library.name + " のライブラリ保存先"
        panel.message = id.hasPrefix("serum") ? "「Serum Presets」または「Serum 2 Presets」など、Presets / Tables / Noises が入るルートフォルダを選んでください。Presets の中は選びません。" : "シンセのプリセットライブラリのルートフォルダを選んでください。一覧の保存先を確認してからコピーできます。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if FileManager.default.fileExists(atPath: library.rootPath) { panel.directoryURL = URL(fileURLWithPath: library.rootPath) }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            self.libraries[index].rootPath = path
            self.libraries[index].detected = true
            var saved = UserDefaults.standard.dictionary(forKey: self.rootDefaultsKey) as? [String: String] ?? [:]
            saved[id] = path
            UserDefaults.standard.set(saved, forKey: self.rootDefaultsKey)
            if var plan = self.plan {
                plan.libraries = self.libraries
                for row in plan.items.indices where plan.items[row].targetID == id {
                    let selected = plan.items[row].selected
                    plan.items[row] = PresetOrganizer.assign(plan.items[row], to: self.libraries[index])
                    plan.items[row].selected = selected && self.ready(plan.items[row])
                }
                self.plan = plan
            }
            self.updateRootLabel()
            self.table.reloadData()
            self.updateControls()
            self.statusLabel.stringValue = library.name + " の保存先を更新しました。まだコピーしていません。"
        }
    }
    @objc private func toggleItem(_ sender: NSButton) {
        guard !busy, var plan = plan, sender.tag >= 0, sender.tag < plan.items.count, ready(plan.items[sender.tag]) else { return }
        plan.items[sender.tag].selected = sender.state == .on
        self.plan = plan
        updateControls()
    }
    @objc private func selectReady(_ sender: Any?) {
        guard !busy, var plan = plan else { return }
        for index in plan.items.indices { plan.items[index].selected = ready(plan.items[index]) }
        self.plan = plan
        table.reloadData()
        updateControls()
    }
    @objc private func selectNone(_ sender: Any?) {
        guard !busy, var plan = plan else { return }
        for index in plan.items.indices { plan.items[index].selected = false }
        self.plan = plan
        table.reloadData()
        updateControls()
    }
    @objc private func assignSelectedRows(_ sender: Any?) {
        guard !busy, var plan = plan,
              let id = assignPopup.selectedItem?.representedObject as? String,
              let library = libraries.first(where: { $0.id == id }) else { return }
        for index in table.selectedRowIndexes where index < plan.items.count {
            plan.items[index] = PresetOrganizer.assign(plan.items[index], to: library)
            plan.items[index].selected = ready(plan.items[index])
        }
        self.plan = plan
        table.reloadData()
        updateControls()
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        statusLabel.stringValue = "選んだ行の保存先を更新しました。対応しない形式は未選択のままです。"
    }

    private func destinationNeedsAdmin(_ path: String) -> Bool {
        let fm = FileManager.default
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        while !fm.fileExists(atPath: parent.path), parent.path != "/" { parent.deleteLastPathComponent() }
        return !fm.isWritableFile(atPath: parent.path)
    }
    @objc private func installSelected(_ sender: Any?) {
        guard !busy, let plan = plan, let window = window else { return }
        let selected = plan.items.filter { $0.selected && ready($0) }
        guard !selected.isEmpty else { return }
        let needsAdmin = selected.contains { destinationNeedsAdmin($0.destinationPath!) }
        let alert = NSAlert()
        alert.messageText = "選択したプリセットと付属データを保存しますか？"
        alert.informativeText = "\(selected.count) 件 / \(formattedBytes(selected.reduce(Int64(0)) { $0 + $1.bytes }))\n\n• 一覧に表示した保存先へコピーします。\n• 同名の既存ファイルは上書きせずスキップします。\n• 元のパックのファイルは残ります。\n• 保存後、各シンセでプリセットを再スキャンしてください。" + (needsAdmin ? "\n\n共有ライブラリに保存するため、macOSが管理者認証を求めます。" : "")
        alert.addButton(withTitle: "保存する")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.begin(needsAdmin ? "管理者認証を待っています。その後、選択した項目を保存します…" : "プリセットと付属データを保存しています…")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let report = try needsAdmin ? self.privilegedInstall(plan) : PresetOrganizer.install(plan, progress: self.progress)
                    DispatchQueue.main.async { self.showReport(report) }
                } catch { DispatchQueue.main.async { self.showError(error) } }
            }
        }
    }
    private func showReport(_ report: TransferReport) {
        let summary = "保存 \(report.completed.count) 件 / スキップ \(report.skipped.count) 件 / 失敗 \(report.failed.count) 件"
        end(summary)
        for item in report.completed { appendLog("保存: " + item) }
        for item in report.skipped { appendLog("スキップ: " + item) }
        for item in report.failed { appendLog("失敗: " + item) }
        guard let window = window else { return }
        let alert = NSAlert()
        alert.alertStyle = report.failed.isEmpty ? .informational : .warning
        alert.messageText = report.failed.isEmpty ? "プリセットの保存が完了しました" : "一部の項目を保存できませんでした"
        alert.informativeText = summary + "\n\nシンセのプリセットブラウザを再スキャンするか、シンセを開き直してください。\nSerum / Serum 2で音が不足する場合は付属のWavetable・Noiseなどの保存先を確認してください。\n\n" + (report.failed.isEmpty ? "詳細はウインドウ下部のログに表示しています。" : report.failed.prefix(5).joined(separator: "\n"))
        alert.beginSheetModal(for: window)
    }
    private func privilegedInstall(_ plan: PresetImportPlan) throws -> TransferReport {
        guard let executable = Bundle.main.executableURL else { throw porterFail("アプリの実行ファイルが見つかりません。") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PluginPorter-presets-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? FileManager.default.removeItem(at: temp) }
        let planURL = temp.appendingPathComponent("plan.json")
        let reportURL = temp.appendingPathComponent("report.json")
        try PresetOrganizer.savePlan(plan, to: planURL)
        let args = [executable.path, "--cli", "preset-install", planURL.path, "--report", reportURL.path]
        let command = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let script = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(script)\" with administrator privileges"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { progress(output) }
        if FileManager.default.fileExists(atPath: reportURL.path) {
            return try JSONDecoder().decode(TransferReport.self, from: Data(contentsOf: reportURL))
        }
        if process.terminationStatus != 0 {
            if output.contains("-128") { throw porterFail("管理者認証がキャンセルされました。") }
            throw porterFail("管理者権限での保存を完了できませんでした。\n" + output)
        }
        throw porterFail("保存レポートを読み込めませんでした。ログと保存先を確認してください。")
    }
}
