import Foundation
import Darwin

enum PresetOrganizer {
    private static let fm = FileManager.default
    private static let presetExtensions: Set<String> = ["fxp", "fxb", "serumpreset", "serumfx", "serumfxrack", "xfershape", "xferpath", "vital", "h2p", "vitaltable", "vitallfo", "presetpack", "vitalbank"]
    private static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "flac", "sfz"]
    private static let supportedIDs: Set<String> = ["serum1", "serum2", "vital", "sylenth1", "diva", "hive", "zebra2", "zebrahz"]

    static func defaultLibraries(home: URL) -> [PresetLibrary] {
        func exists(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
        func preference(_ relative: String, key: String) -> String? {
            let url = home.appendingPathComponent(relative)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 2_000_000,
                  let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object[key] as? String else { return nil }
            let path = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            return path.hasPrefix("/") && exists(path) ? path : nil
        }
        func make(_ id: String, _ name: String, _ paths: [String], _ subfolder: String) -> PresetLibrary {
            let path = paths.first(where: exists) ?? paths[0]
            return PresetLibrary(id: id, name: name, rootPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, presetFolder: subfolder, detected: exists(path))
        }
        let serum1 = preference("Library/Preferences/SerumPrefs.json", key: "Serum Presets Path")
        let serum2 = preference("Library/Preferences/Serum2Prefs.json", key: "Serum Presets Path")
        let vital = preference("Library/Application Support/vital/Vital.config", key: "data_directory")
        var result = [
            make("serum1", "Serum", [serum1, "/Library/Audio/Presets/Xfer Records/Serum Presets", home.appendingPathComponent("Library/Audio/Presets/Xfer Records/Serum Presets").path].compactMap { $0 }, "Presets"),
            make("serum2", "Serum 2", [serum2, "/Library/Audio/Presets/Xfer Records/Serum 2 Presets", home.appendingPathComponent("Library/Audio/Presets/Xfer Records/Serum 2 Presets").path].compactMap { $0 }, "Presets/User"),
            make("vital", "Vital", [vital, home.appendingPathComponent("Music/Vital").path].compactMap { $0 }, "Presets"),
            make("sylenth1", "Sylenth1", [home.appendingPathComponent("Library/Application Support/LennarDigital/Sylenth1").path], "Presets")
        ]
        for (id, name) in [("diva", "Diva"), ("hive", "Hive"), ("zebra2", "Zebra2"), ("zebrahz", "ZebraHZ")] {
            result.append(make(id, name, [home.appendingPathComponent("Library/Audio/Presets/u-he/\(name)").path], ""))
        }
        return result
    }

    static func analyze(folders: [URL], libraries: [PresetLibrary], serumFXPTarget: String, progress: (String) -> Void) throws -> PresetImportPlan {
        guard !folders.isEmpty else { throw porterFail("解凍済みのパックフォルダを追加してください。") }
        guard ["serum1", "serum2"].contains(serumFXPTarget) else { throw porterFail("Serumの保存先が不正です。") }
        try validateLibraries(libraries)
        var roots: [URL] = []
        for root in folders.map({ $0.standardizedFileURL }).sorted(by: { $0.path.count < $1.path.count }) {
            try TransferEngine.requireDirectory(root)
            guard root.pathComponents.count > 2 else { throw porterFail("ディスク全体ではなく購入パックのフォルダを選択してください。") }
            if !roots.contains(where: { TransferEngine.contains($0, root) }) { roots.append(root) }
        }
        var items: [PresetImportItem] = []
        var audio: [PresetImportItem] = []
        var seen = Set<String>()
        var ignored = 0
        var notes: [String] = []
        var count = 0
        for root in roots {
            progress("解析中: \(root.lastPathComponent)")
            var readError: Error?
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, error in readError = error; return true }) else { throw porterFail("フォルダを読み取れません: \(root.path)") }
            for case let file as URL in iterator {
                count += 1
                guard count <= 200000 else { throw porterFail("項目が多すぎます。パックごとに分けて追加してください。") }
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                if values.isSymbolicLink == true { iterator.skipDescendants(); ignored += 1; continue }
                if values.isDirectory == true {
                    if ["app", "component", "vst", "vst3", "aaxplugin", "pluginporter"].contains(file.pathExtension.lowercased()) || file.lastPathComponent == "__MACOSX" { iterator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, seen.insert(file.path).inserted else { continue }
                let ext = file.pathExtension.lowercased()
                guard presetExtensions.contains(ext) || audioExtensions.contains(ext) else { ignored += 1; continue }
                let relative = String(file.path.dropFirst(root.path.count + 1))
                var item = PresetImportItem(id: UUID().uuidString, sourcePath: file.path, sourceRoot: root.path, packName: root.lastPathComponent, sourceRelativePath: relative, kind: "preset", detectedTargetID: nil, targetID: nil, destinationPath: nil, bytes: Int64(values.fileSize ?? 0), reason: "", selected: false)
                if audioExtensions.contains(ext) { audio.append(item); continue }
                let detected = try identify(file)
                item.detectedTargetID = detected.id
                item.kind = detected.kind
                item.reason = detected.reason
                let target = detected.id == "serum1" ? serumFXPTarget : detected.id
                if let target = target, let library = libraries.first(where: { $0.id == target }) { item = assign(item, to: library) }
                items.append(item)
            }
            if let error = readError { notes.append("\(root.lastPathComponent): 一部を読み取れませんでした — \(error.localizedDescription)") }
        }
        for var item in audio {
            let parts = sourceParts(item)
            guard let kind = audioKind(parts) else { ignored += 1; continue }
            if URL(fileURLWithPath: item.sourcePath).pathExtension.lowercased() == "sfz" && kind != "multisample" { ignored += 1; continue }
            item.kind = kind
            let context = parts.dropLast().joined(separator: "/").lowercased()
            let packTargets = Set(items.filter { $0.sourceRoot == item.sourceRoot }.compactMap(\.targetID))
            let target: String?
            if context.contains("serum 2") || context.contains("serum2") { target = "serum2" }
            else if context.contains("serum") { target = serumFXPTarget }
            else if context.contains("vital") { target = "vital" }
            else if packTargets.count == 1 { target = packTargets.first }
            else { target = nil }
            item.detectedTargetID = target
            item.reason = "付属素材の対象シンセを特定できません。保存先を指定してください。"
            if let target = target, let library = libraries.first(where: { $0.id == target }) { item = assign(item, to: library) }
            items.append(item)
        }
        let sourceRoots = roots.map { $0.resolvingSymlinksInPath() }
        for item in items {
            if let path = item.destinationPath {
                try requireOutsideSourceRoots(URL(fileURLWithPath: path), roots: sourceRoots)
            }
        }
        if items.contains(where: { $0.kind != "preset" && $0.kind != "unknown" }) {
            notes.append("付属素材はTables／Noises／Samplesなどの下の階層を維持します。プリセット内の参照先の書き換えは行いません。")
        }
        if ignored > 0 { notes.append("通常のループ・ドラム素材、画像、説明書、リンク等の \(ignored) ファイルは対象外です。") }
        return PresetImportPlan(formatVersion: 1, createdAt: ISO8601DateFormatter().string(from: Date()), libraries: libraries, items: items.sorted { $0.sourcePath.localizedStandardCompare($1.sourcePath) == .orderedAscending }, ignoredFileCount: ignored, notes: notes, sourceRoots: sourceRoots.map(\.path))
    }

    private static func identify(_ url: URL) throws -> (id: String?, kind: String, reason: String) {
        let ext = url.pathExtension.lowercased()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 65536) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if ext == "fxp" || ext == "fxb" {
            if data.count >= 20, String(decoding: data[0..<4], as: UTF8.self) == "CcnK" {
                let format = String(decoding: data[8..<12], as: UTF8.self)
                guard (ext == "fxp" && ["FPCh", "FxCk"].contains(format)) || (ext == "fxb" && ["FBCh", "FxBk"].contains(format)) else {
                    return (nil, "unknown", "FXP/FXBの形式ヘッダーが不正です。")
                }
                let id = String(decoding: data[16..<20], as: UTF8.self)
                if id == "XfsX" && ext == "fxp" { return ("serum1", "preset", "SerumのプラグインIDを確認しました。") }
                if id == "syl1" { return ("sylenth1", "preset", "Sylenth1のプラグインIDを確認しました。") }
                return (nil, "preset", "FXP/FXBの製品ID \(id) は自動判別対象外です。対象シンセを確認してください。")
            }
            return (nil, "unknown", "FXP/FXBのヘッダーを確認できません。元のファイルを確認してください。")
        }
        let xferTypes: [String: (String, String)] = ["serumpreset": ("SerumPreset", "preset"), "serumfx": ("SerumFX", "effect"), "serumfxrack": ("SerumFXRack", "effect"), "xfershape": ("XferShape", "shape"), "xferpath": ("XferPath", "path")]
        if let (expectedType, kind) = xferTypes[ext] {
            guard data.count >= 17, data.starts(with: Data("XferJson".utf8)), data[8] == 0 else { return (nil, "unknown", "Xfer形式のヘッダーを確認できません。") }
            let length = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[9 + $1]) << UInt64($1 * 8) }
            guard length > 0, length <= 1_048_576 else { return (nil, "unknown", "Xferヘッダーの長さが不正です。") }
            try file.seek(toOffset: 17)
            guard let header = try file.read(upToCount: Int(length)), header.count == Int(length),
                  let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
                  object["fileType"] as? String == expectedType else { return (nil, "unknown", "Xferファイルの種類を確認できません。") }
            return ("serum2", kind, "Serum 2の \(expectedType) 形式を確認しました。")
        }
        if ext == "vital" {
            guard text.contains("\"settings\"") || text.contains("\"synth_version\"") else { return (nil, "unknown", "Vitalのプリセット形式を確認できません。") }
            return ("vital", "preset", "Vitalのプリセットです。")
        }
        if ext == "vitaltable" { return ("vital", "wavetable", "VitalのWavetableです。") }
        if ext == "vitallfo" { return ("vital", "lfo", "VitalのLFOです。") }
        if ext == "h2p" {
            for (product, id) in [("Diva", "diva"), ("Hive", "hive"), ("Zebra2", "zebra2"), ("ZebraHZ", "zebrahz")] {
                if text.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "#AM=\(product)" }) { return (id, "preset", "u-heの製品名 \(product) を確認しました。") }
            }
            return (nil, "preset", "u-heの製品名を特定できません。対象シンセを指定してください。")
        }
        return (nil, "unknown", "このバンク形式はシンセ本体のインポート機能を使用してください。")
    }

    static func assign(_ original: PresetImportItem, to library: PresetLibrary) -> PresetImportItem {
        var item = original
        item.targetID = library.id
        item.destinationPath = nil
        item.selected = false
        guard supportedIDs.contains(library.id), item.kind != "unknown" else { item.reason = "この形式は自動保存に対応していません。"; return item }
        guard compatible(item, target: library.id) else { item.reason = "このファイル形式と選択したシンセは対応していません。"; return item }
        guard library.detected, !library.rootPath.isEmpty, fm.fileExists(atPath: library.rootPath) else { item.reason = "\(library.name) のライブラリルートを指定してください。"; return item }
        let root = URL(fileURLWithPath: library.rootPath).resolvingSymlinksInPath()
        guard validRoot(root) else { item.reason = "製品専用のライブラリフォルダを選択してください。"; return item }
        guard let relative = destinationRelative(item, library: library), validRelative(relative) else {
            item.reason = item.kind == "noise" && library.id == "serum2"
                ? "Serum 1のNoisesはSerum 2へ自動変換できません。Serum側へ保存するか、Serum 2で素材を読み込んでください。"
                : "付属素材の配置を特定できません。シンセのインポート機能で配置してください。"
            return item
        }
        let target = root.appendingPathComponent(relative).standardizedFileURL
        guard TransferEngine.contains(root, target), target.path != item.sourcePath else { item.reason = "既に保存先にあるか、保存先が不正です。"; return item }
        item.destinationPath = target.path
        item.selected = true
        item.reason = TransferEngine.exists(target) ? "同名ファイルあり：既存のファイルを保持してスキップ" : "保存可能"
        if item.kind != "preset" { item.reason += "（素材の階層を維持）" }
        return item
    }

    private static func compatible(_ item: PresetImportItem, target: String) -> Bool {
        let ext = URL(fileURLWithPath: item.sourcePath).pathExtension.lowercased()
        if item.kind == "preset" {
            switch ext {
            case "serumpreset": return target == "serum2"
            case "vital": return target == "vital"
            case "h2p": return ["diva", "hive", "zebra2", "zebrahz"].contains(target) && (item.detectedTargetID == nil || item.detectedTargetID == target)
            case "fxp":
                if item.detectedTargetID == "serum1" { return ["serum1", "serum2"].contains(target) }
                if item.detectedTargetID == "sylenth1" { return target == "sylenth1" }
                return ["serum1", "serum2", "sylenth1"].contains(target)
            case "fxb": return target == "sylenth1" && (item.detectedTargetID == nil || item.detectedTargetID == "sylenth1")
            default: return false
            }
        }
        if ext == "vitaltable" || ext == "vitallfo" { return target == "vital" }
        if ["serumfx", "serumfxrack", "xfershape", "xferpath"].contains(ext) { return target == "serum2" }
        guard audioExtensions.contains(ext) else { return false }
        return ["serum1", "serum2", "vital"].contains(target)
    }

    private static func sourceParts(_ item: PresetImportItem) -> [String] {
        [URL(fileURLWithPath: item.sourceRoot).lastPathComponent] + item.sourceRelativePath.components(separatedBy: "/")
    }

    private static func audioKind(_ parts: [String]) -> String? {
        // The outer content category owns the relative path. For example,
        // Samples/Factory Non-Tonal/Noises remains a Serum 2 Samples path.
        for component in parts.dropLast() {
            switch component.lowercased() {
            case "tables", "wavetables", "wave tables": return "wavetable"
            case "noise", "noises": return "noise"
            case "multisamples": return "multisample"
            case "samples": return "sample"
            default: continue
            }
        }
        return nil
    }

    private static func destinationRelative(_ item: PresetImportItem, library: PresetLibrary) -> String? {
        let parts = sourceParts(item)
        let pack = item.packName
        guard validRelative(pack), !pack.contains("/") else { return nil }
        if item.kind == "preset" {
            var suffix = item.sourceRelativePath.components(separatedBy: "/")
            if let marker = parts.dropLast().lastIndex(where: { ["presets", "serum presets", "serum 2 presets", "soundbanks"].contains($0.lowercased()) }) { suffix = Array(parts.dropFirst(marker + 1)) }
            if suffix.first?.lowercased() == "user" { suffix.removeFirst() }
            if suffix.first == pack { suffix.removeFirst() }
            guard !suffix.isEmpty else { return nil }
            let folder: String
            if library.id == "vital" { folder = pack + "/Presets" }
            else if library.id == "sylenth1" && URL(fileURLWithPath: item.sourcePath).pathExtension.lowercased() == "fxb" { folder = "SoundBanks/" + pack }
            else { folder = (library.presetFolder.isEmpty ? "" : library.presetFolder + "/") + pack }
            return folder + "/" + suffix.joined(separator: "/")
        }
        let markers: [String]
        let targetFolder: String
        switch item.kind {
        case "wavetable": markers = ["tables", "wavetables", "wave tables"]; targetFolder = library.id == "vital" ? "Wavetables" : "Tables"
        case "lfo": markers = ["lfos", "lfo shapes"]; targetFolder = "LFOs"
        case "effect": markers = ["effect chains"]; targetFolder = "Effect Chains"
        case "shape": markers = ["lfo shapes"]; targetFolder = "LFO Shapes"
        case "path": markers = ["lfo paths"]; targetFolder = "LFO Paths"
        case "noise":
            // Serum 1 noise paths are not silently converted to Serum 2 sample paths.
            guard library.id == "serum1" else { return nil }
            markers = ["noises", "noise"]; targetFolder = "Noises"
        case "sample":
            guard library.id != "serum1" else { return nil }
            markers = ["samples"]; targetFolder = "Samples"
        case "multisample":
            guard library.id == "serum2" else { return nil }
            markers = ["multisamples"]; targetFolder = "Multisamples"
        default: return nil
        }
        let suffix: [String]
        if let marker = parts.dropLast().firstIndex(where: { markers.contains($0.lowercased()) }) { suffix = Array(parts.dropFirst(marker + 1)) }
        else if ["vitaltable", "vitallfo", "serumfx", "serumfxrack", "xfershape", "xferpath"].contains(URL(fileURLWithPath: item.sourcePath).pathExtension.lowercased()) { suffix = [pack] + item.sourceRelativePath.components(separatedBy: "/") }
        else { return nil }
        guard !suffix.isEmpty else { return nil }
        return (library.id == "vital" ? pack + "/" : "") + targetFolder + "/" + suffix.joined(separator: "/")
    }

    static func install(_ plan: PresetImportPlan, progress: (String) -> Void) throws -> TransferReport {
        guard plan.formatVersion == 1 else { throw porterFail("未対応の整理プランです。") }
        try validateLibraries(plan.libraries)
        let selected = plan.items.filter(\.selected)
        guard !selected.isEmpty else { throw porterFail("保存できるファイルを選択してください。") }
        guard selected.count <= 200000 else { throw porterFail("項目が多すぎます。") }
        let recordedRoots = (plan.sourceRoots ?? []) + plan.items.map(\.sourceRoot)
        guard recordedRoots.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw porterFail("整理プランの元フォルダが不正です。") }
        let sourceRoots = Set(recordedRoots).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        var validated: [(PresetImportItem, URL, String, Int)] = []
        var ids = Set<String>()
        // Validate the entire plan, file type and source path before creating directories.
        for item in selected {
            guard ids.insert(item.id).inserted, UUID(uuidString: item.id) != nil,
                  let id = item.targetID, let library = plan.libraries.first(where: { $0.id == id }),
                  validRelative(item.sourceRelativePath), validRelative(item.packName), !item.packName.contains("/") else { throw porterFail("整理プランの項目が不正です。") }
            let root = URL(fileURLWithPath: item.sourceRoot).standardizedFileURL
            let source = URL(fileURLWithPath: item.sourcePath).standardizedFileURL
            guard root.appendingPathComponent(item.sourceRelativePath).standardizedFileURL.path == source.path,
                  TransferEngine.contains(root.resolvingSymlinksInPath(), source.resolvingSymlinksInPath()) else { throw porterFail("コピー元が選択フォルダの外を参照しています。") }
            let attrs = try fm.attributesOfItem(atPath: source.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw porterFail("通常ファイル以外は保存できません: \(source.path)") }
            let ext = source.pathExtension.lowercased()
            guard presetExtensions.contains(ext) || audioExtensions.contains(ext) else { throw porterFail("対象外のファイル形式です。") }
            if presetExtensions.contains(ext) {
                let fresh = try identify(source)
                guard fresh.kind == item.kind, fresh.id == item.detectedTargetID else { throw porterFail("解析後にファイル形式が変わりました。もう一度解析してください: \(source.lastPathComponent)") }
            }
            let recomputed = assign(item, to: library)
            guard let path = recomputed.destinationPath, path == item.destinationPath else { throw porterFail("保存先が不正または変更されています: \(source.lastPathComponent)") }
            let target = URL(fileURLWithPath: path)
            try TransferEngine.validateDestination(target, home: fm.homeDirectoryForCurrentUser)
            try requireOutsideSourceRoots(target, roots: sourceRoots)
            progress("コピー前検証: \(source.lastPathComponent)")
            let (hash, count) = try TransferEngine.fingerprint(source)
            validated.append((item, target, hash, count))
        }
        var report = TransferReport()
        for (index, tuple) in validated.enumerated() {
            let (item, target, hash, count) = tuple
            progress("[\(index + 1)/\(validated.count)] 保存: \(target.lastPathComponent)")
            do {
                try TransferEngine.validateDestination(target, home: fm.homeDirectoryForCurrentUser)
                if TransferEngine.exists(target) {
                    let existing = try? TransferEngine.fingerprint(target)
                    let why = existing?.0 == hash ? "同一ファイル" : "同名・内容違い（既存を保持）"
                    report.skipped.append("\(why): \(target.path)")
                    continue
                }
                let parent = target.deletingLastPathComponent()
                let created = try TransferEngine.createParents(parent, home: fm.homeDirectoryForCurrentUser)
                let libraryRoot = URL(fileURLWithPath: plan.libraries.first { $0.id == item.targetID }!.rootPath).resolvingSymlinksInPath()
                for directory in created { try TransferEngine.assignOwner(directory, home: libraryRoot) }
                let stage = parent.appendingPathComponent(".PluginPorter-preset-\(UUID().uuidString).partial")
                defer { try? fm.removeItem(at: stage) }
                try TransferEngine.copy(URL(fileURLWithPath: item.sourcePath), to: stage)
                let copied = try TransferEngine.fingerprint(stage)
                guard copied.0 == hash && copied.1 == count else { throw porterFail("コピー内容が一致しません。元のパックを変更せず再実行してください。") }
                try TransferEngine.assignOwner(stage, home: libraryRoot)
                let result = stage.path.withCString { src in target.path.withCString { dst in renamex_np(src, dst, UInt32(RENAME_EXCL)) } }
                guard result == 0 else { throw porterFail("既存ファイルを上書きせず停止しました: \(String(cString: strerror(errno)))") }
                report.completed.append(target.path)
            } catch { report.failed.append("\(target.path): \(error.localizedDescription)") }
        }
        progress("保存完了 \(report.completed.count) / スキップ \(report.skipped.count) / 失敗 \(report.failed.count)")
        return report
    }

    private static func requireOutsideSourceRoots(_ target: URL, roots: [URL]) throws {
        let resolved = target.resolvingSymlinksInPath()
        guard !roots.contains(where: { TransferEngine.contains($0, resolved) }) else {
            throw porterFail("選択した購入パックの元フォルダ内へは保存しません。別のライブラリルートを選択してください。")
        }
    }

    static func savePlan(_ plan: PresetImportPlan, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(plan).write(to: url, options: .atomic)
    }

    static func loadPlan(at url: URL) throws -> PresetImportPlan {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.int64Value ?? Int64.max < 100_000_000 else { throw porterFail("整理プランを読み取れません。") }
        let plan = try JSONDecoder().decode(PresetImportPlan.self, from: Data(contentsOf: url))
        guard plan.formatVersion == 1 else { throw porterFail("未対応の整理プランです。") }
        try validateLibraries(plan.libraries)
        return plan
    }

    private static func validateLibraries(_ libraries: [PresetLibrary]) throws {
        var ids = Set<String>()
        for library in libraries {
            guard supportedIDs.contains(library.id), ids.insert(library.id).inserted,
                  library.rootPath.hasPrefix("/"), !library.rootPath.contains("\0"),
                  validRoot(URL(fileURLWithPath: library.rootPath)), library.presetFolder.isEmpty || validRelative(library.presetFolder) else { throw porterFail("ライブラリ設定が不正です。") }
            let allowed: [String: String] = ["serum1": "Presets", "serum2": "Presets/User", "vital": "Presets", "sylenth1": "Presets", "diva": "", "hive": "", "zebra2": "", "zebrahz": ""]
            guard library.presetFolder == allowed[library.id] else { throw porterFail("製品のプリセット構造が不正です。") }
        }
    }

    private static func validRelative(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count < 4096 && !path.contains("\0") && path.components(separatedBy: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func validRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/") && url.pathComponents.count > 2 && !["/Library/Audio", "/Library/Audio/Presets", "/Library/Application Support", "/Users/Shared"].contains(path) && !path.hasPrefix("/System/") && !path.hasPrefix("/usr/") && !path.contains("\0")
    }
}
