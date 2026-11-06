import Foundation
import CryptoKit
import Darwin

enum TransferEngine {
    static let fm = FileManager.default

    static func export(items: [TransferItem], to destination: URL, progress: (String) -> Void) throws -> TransferManifest {
        guard !items.isEmpty else { throw porterFail("書き出す項目を選択してください。") }
        let destination = destination.standardizedFileURL
        guard !exists(destination) else { throw porterFail("書き出し先は既に存在します。新しい名前を指定してください。") }
        try validateItems(items)
        let parent = destination.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else { throw porterFail("書き出し先の親フォルダがありません。") }
        let realDestination = parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent)
        for (index, item) in items.enumerated() {
            if let reason = item.exportBlockReason { throw porterFail("\(item.name): \(reason)") }
            let source = URL(fileURLWithPath: item.sourcePath).standardizedFileURL
            guard !contains(source.resolvingSymlinksInPath(), realDestination) else { throw porterFail("書き出し先をコピー元の中には置けません。") }
            guard fm.isReadableFile(atPath: source.path) else { throw porterFail("読み取りできません: \(source.path)") }
            progress("[\(index + 1)/\(items.count)] コピー前確認: \(item.name)")
            try validateTree(source)
        }
        let stage = parent.appendingPathComponent(".PluginPorter-\(UUID().uuidString).partial")
        try fm.createDirectory(at: stage.appendingPathComponent("payload"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var finished = false
        defer { if !finished { try? fm.removeItem(at: stage) } }
        var entries: [ArchiveEntry] = []
        for (index, item) in items.enumerated() {
            progress("[\(index + 1)/\(items.count)] 書き出し: \(item.name)")
            let source = URL(fileURLWithPath: item.sourcePath)
            // Validate links and file types before invoking the copy utility.
            try validateTree(source)
            let payload = stage.appendingPathComponent("payload").appendingPathComponent(item.id)
            try copy(source, to: payload)
            let (digest, count) = try fingerprint(payload)
            entries.append(ArchiveEntry(item: item, digest: digest, fileCount: count))
        }
        let manifest = TransferManifest(formatVersion: 1, createdAt: ISO8601DateFormatter().string(from: Date()), sourceOS: ProcessInfo.processInfo.operatingSystemVersionString, sourceArchitecture: machineArchitecture(), entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.moveItem(at: stage, to: destination)
        finished = true
        progress("書き出し完了: \(entries.count) 項目。元のファイルは変更していません。")
        return manifest
    }

    static func readManifest(at archive: URL) throws -> TransferManifest {
        try requireDirectory(archive)
        let path = archive.appendingPathComponent("manifest.json")
        let attrs = try fm.attributesOfItem(atPath: path.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value ?? Int64.max < 32 * 1024 * 1024 else {
            throw porterFail("manifest.json が通常ファイルではないか、大きすぎます。")
        }
        let manifest = try JSONDecoder().decode(TransferManifest.self, from: Data(contentsOf: path))
        guard manifest.formatVersion == 1, !manifest.entries.isEmpty, manifest.entries.count <= 20000 else {
            throw porterFail("未対応または空の移行パッケージです。")
        }
        try validateItems(manifest.entries.map(\.item))
        try requireDirectory(archive.appendingPathComponent("payload"))
        for entry in manifest.entries {
            guard entry.digest.count == 64, entry.digest.allSatisfy({ $0.isHexDigit }), entry.fileCount >= 0 else {
                throw porterFail("検証情報が不正です: \(entry.item.name)")
            }
        }
        return manifest
    }

    static func verify(at archive: URL, progress: (String) -> Void) throws {
        let manifest = try readManifest(at: archive)
        for (index, entry) in manifest.entries.enumerated() {
            progress("[\(index + 1)/\(manifest.entries.count)] 検証: \(entry.item.name)")
            try verifyEntry(entry, archive: archive)
        }
        progress("検証完了: 全項目のSHA-256が一致しました。")
    }

    static func restore(from archive: URL, home: URL, selectedIDs: Set<String>?, progress: (String) -> Void) throws -> TransferReport {
        let home = home.standardizedFileURL
        guard home.path.hasPrefix("/"), home.path != "/", home.path != "/Users", fm.fileExists(atPath: home.path) else {
            throw porterFail("移行先ユーザーのホームフォルダを正しく指定してください。")
        }
        // A root process must be given the receiving user's real home, never /var/root.
        if geteuid() == 0 && home.path == "/var/root" { throw porterFail("管理者実行時は --home で移行先ユーザーのホームを指定してください。") }
        let manifest = try readManifest(at: archive)
        let knownIDs = Set(manifest.entries.map { $0.item.id })
        if let selectedIDs = selectedIDs, !selectedIDs.isSubset(of: knownIDs) { throw porterFail("パッケージに存在しない項目IDです。") }
        let entries = manifest.entries.filter { selectedIDs == nil || selectedIDs!.contains($0.item.id) }
        guard !entries.isEmpty else { throw porterFail("復元する項目を選択してください。") }
        // All selected payloads are verified before any destination is changed.
        for (index, entry) in entries.enumerated() {
            progress("[\(index + 1)/\(entries.count)] 復元前検証: \(entry.item.name)")
            try verifyEntry(entry, archive: archive)
        }
        var report = TransferReport()
        for (index, entry) in entries.enumerated() {
            let item = entry.item
            let root = try scopeRoot(item.scope, home: home)
            let target = root.appendingPathComponent(item.relativePath)
            progress("[\(index + 1)/\(entries.count)] 復元: \(item.name)")
            do {
                try validateDestination(target, home: home)
                if exists(target) {
                    report.skipped.append("\(item.name): 既存ファイルを保持 — \(target.path)")
                    continue
                }
                let parent = target.deletingLastPathComponent()
                let created = try createParents(parent, home: home)
                let stage = parent.appendingPathComponent(".PluginPorter-\(UUID().uuidString).partial")
                defer { try? fm.removeItem(at: stage) }
                try copy(archive.appendingPathComponent("payload").appendingPathComponent(item.id), to: stage)
                let (digest, count) = try fingerprint(stage)
                guard digest == entry.digest, count == entry.fileCount else { throw porterFail("復元コピーの検証に失敗しました。") }
                if !porterScopes[item.scope]!.hasPrefix("/") {
                    try assignUserOwner(stage, home: home)
                    for path in created { try assignOwner(path, home: home) }
                }
                // RENAME_EXCL prevents replacing a file created after the existence check.
                let result = stage.path.withCString { src in target.path.withCString { dst in renamex_np(src, dst, UInt32(RENAME_EXCL)) } }
                guard result == 0 else { throw porterFail("既存ファイルを上書きせず停止しました: \(String(cString: strerror(errno)))") }
                report.completed.append("\(item.name): \(target.path)")
            } catch {
                report.failed.append("\(item.name): \(error.localizedDescription)")
            }
        }
        progress("復元結果: 完了 \(report.completed.count)、既存のためスキップ \(report.skipped.count)、失敗 \(report.failed.count)")
        return report
    }

    static func verifyEntry(_ entry: ArchiveEntry, archive: URL) throws {
        let payload = archive.appendingPathComponent("payload").appendingPathComponent(entry.item.id)
        let (digest, count) = try fingerprint(payload)
        guard digest == entry.digest, count == entry.fileCount else {
            throw porterFail("データの破損または変更を検出しました: \(entry.item.name)。復元を中止しました。")
        }
    }

    static func validateItems(_ items: [TransferItem]) throws {
        var ids = Set<String>()
        var targets: [(String, String)] = []
        for item in items {
            guard UUID(uuidString: item.id) != nil, ids.insert(item.id).inserted else { throw porterFail("項目IDが不正または重複しています。") }
            guard porterScopes[item.scope] != nil else { throw porterFail("未対応の保存先です: \(item.scope)") }
            let parts = item.relativePath.components(separatedBy: "/")
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
                  !item.relativePath.hasPrefix("/"), item.relativePath.utf8.count < 4096 else { throw porterFail("保存先パスが不正です。") }
            if item.scope == "systemPlugins" || item.scope == "userPlugins" {
                guard parts.count >= 2, ["Components", "VST", "VST3"].contains(parts[0]),
                      ["component", "vst", "vst3"].contains(URL(fileURLWithPath: item.relativePath).pathExtension.lowercased()) else { throw porterFail("プラグインの保存先が不正です。") }
            }
            // Scope roots themselves are never replaceable. Refuse overlapping selections.
            for (scope, path) in targets where scope == item.scope {
                if path == item.relativePath || path.hasPrefix(item.relativePath + "/") || item.relativePath.hasPrefix(path + "/") {
                    throw porterFail("選択したフォルダが重複しています: \(item.relativePath)。親か子の一方を外してください。")
                }
            }
            targets.append((item.scope, item.relativePath))
        }
    }

    static func validateTree(_ root: URL) throws {
        _ = try tree(root)
    }

    static func tree(_ root: URL) throws -> [URL] {
        let root = root.standardizedFileURL
        let attrs = try fm.attributesOfItem(atPath: root.path)
        guard let type = attrs[.type] as? FileAttributeType, type == .typeDirectory || type == .typeRegular else { throw porterFail("コピー元の実体を選択してください（リンクは選べません）: \(root.path)") }
        if type == .typeRegular { return [root] }
        var failure: Error?
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in failure = error; return false }) else { throw porterFail("フォルダを読み取れません: \(root.path)") }
        var urls = [root]
        let realRoot = root.resolvingSymlinksInPath()
        for case let url as URL in iterator {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard let type = attrs[.type] as? FileAttributeType else { throw porterFail("ファイルの種類を判定できません。") }
            if type == .typeSymbolicLink {
                let link = try fm.destinationOfSymbolicLink(atPath: url.path)
                guard !link.hasPrefix("/"), !link.contains("\0") else { throw porterFail("絶対パスのリンクがあります。メーカーの再インストールを使用してください: \(url.path)") }
                let target = url.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL
                guard contains(root, target), contains(realRoot, url.resolvingSymlinksInPath()) else { throw porterFail("フォルダ外へのリンクがあります。リンク先を別途移行するか、メーカーの再インストールを使用してください: \(url.path)") }
            } else if type != .typeRegular && type != .typeDirectory {
                throw porterFail("通常ファイル以外の項目は移行できません: \(url.path)")
            }
            urls.append(url)
        }
        if let failure = failure { throw failure }
        return urls.sorted { $0.path < $1.path }
    }

    static func fingerprint(_ root: URL) throws -> (String, Int) {
        let root = root.standardizedFileURL
        let urls = try tree(root)
        var hash = SHA256()
        var files = 0
        for url in urls {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let type = attrs[.type] as! FileAttributeType
            let relative = url.path == root.path ? "" : String(url.path.dropFirst(root.path.count + 1))
            let length = type == .typeRegular ? (attrs[.size] as? NSNumber)?.int64Value ?? 0 : 0
            let link = type == .typeSymbolicLink ? try fm.destinationOfSymbolicLink(atPath: url.path) : ""
            let metadata = try JSONSerialization.data(withJSONObject: [relative, type.rawValue, String(length), link], options: [.sortedKeys, .withoutEscapingSlashes])
            hash.update(data: metadata)
            hash.update(data: Data([0]))
            if type == .typeRegular {
                files += 1
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    hash.update(data: data)
                }
            }
            hash.update(data: Data([0]))
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), files)
    }

    static func copy(_ source: URL, to target: URL) throws {
        guard !exists(target) else { throw porterFail("コピー先が既にあります: \(target.path)") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["--rsrc", "--extattr", "--noacl", source.path, target.path]
        let pipe = Pipe()
        task.standardError = pipe
        try task.run()
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw porterFail("コピーに失敗しました: \(String(data: errorData, encoding: .utf8) ?? "ditto error")") }
    }

    static func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    static func contains(_ root: URL, _ child: URL) -> Bool { child.path == root.path || child.path.hasPrefix(root.path + "/") }

    static func requireDirectory(_ url: URL) throws {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw porterFail("実体のフォルダを選択してください: \(url.path)") }
    }

    static func validateDestination(_ destination: URL, home: URL) throws {
        // Reject destination redirection through symlinks, including the target itself.
        var current = URL(fileURLWithPath: "/")
        for component in destination.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if exists(current) {
                let attrs = try fm.attributesOfItem(atPath: current.path)
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw porterFail("移行先にシンボリックリンクがあります。手動で確認してください: \(current.path)") }
            }
        }
    }

    static func createParents(_ parent: URL, home: URL) throws -> [URL] {
        var missing: [URL] = []
        var current = parent
        while !exists(current) {
            missing.append(current)
            current.deleteLastPathComponent()
        }
        for path in missing.reversed() {
            try fm.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            if contains(home, path) { try assignOwner(path, home: home) }
        }
        return missing
    }

    static func assignOwner(_ url: URL, home: URL) throws {
        guard geteuid() == 0 else { return }
        let attrs = try fm.attributesOfItem(atPath: home.path)
        guard let owner = attrs[.ownerAccountID] as? NSNumber, let group = attrs[.groupOwnerAccountID] as? NSNumber else { throw porterFail("移行先ユーザーを特定できません。") }
        guard lchown(url.path, uid_t(owner.uint32Value), gid_t(group.uint32Value)) == 0 else { throw porterFail("所有者の設定に失敗しました: \(url.path)") }
    }

    static func assignUserOwner(_ root: URL, home: URL) throws {
        guard geteuid() == 0 else { return }
        for path in try tree(root) { try assignOwner(path, home: home) }
    }
}

func machineArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
