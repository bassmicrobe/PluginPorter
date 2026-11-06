import Foundation

/// Read-only discovery. Plug-in executables are inspected as Mach-O data and are never loaded.
enum Inventory {
    private static let fm = FileManager.default
    private static let plugInExtensions = ["component": "AU", "vst": "VST", "vst3": "VST3", "aaxplugin": "AAX"]
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]

    static func scan(home: URL, includeData: Bool) throws -> [TransferItem] {
        var items: [TransferItem] = []
        var evidence = ""
        let pluginRoots = [
            try scopeRoot("systemPlugins", home: home),
            try scopeRoot("userPlugins", home: home),
            URL(fileURLWithPath: "/Library/Application Support/Avid/Audio/Plug-Ins")
        ]
        for root in pluginRoots where fm.fileExists(atPath: root.path) {
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                              options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in iterator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if plugInExtensions[url.pathExtension.lowercased()] != nil {
                    iterator.skipDescendants()
                    do {
                        let item = try makeItem(url: url, home: home)
                        items.append(item)
                        let info = values?.isSymbolicLink == true ? [:] : bundleInfo(url)
                        evidence += " " + item.name.lowercased() + " " + url.lastPathComponent.lowercased()
                        evidence += " " + ((info["CFBundleIdentifier"] as? String) ?? "").lowercased()
                        evidence += " " + ((info["CFBundleName"] as? String) ?? "").lowercased()
                    } catch {
                        // One vanished or inaccessible product must not prevent inventorying the others.
                        continue
                    }
                } else if values?.isSymbolicLink == true || url.pathExtension.lowercased() == "app" {
                    iterator.skipDescendants()
                }
            }
        }
        if includeData { items += dataCandidates(home: home, plugins: items, evidence: evidence) }
        var seen = Set<String>()
        return items.filter { seen.insert($0.sourcePath).inserted }.sorted {
            if $0.kind != $1.kind { return $0.kind.localizedStandardCompare($1.kind) == .orderedAscending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func makeItem(url: URL, home: URL) throws -> TransferItem {
        let source = url.standardizedFileURL
        let home = home.standardizedFileURL
        let protected = ["/", "/Library", "/Library/Audio", "/System", "/Users", "/Users/Shared", "/Applications",
                         "/Volumes", "/private", "/private/var", "/private/tmp", "/tmp", "/var", "/usr", "/bin", "/sbin",
                         home.path, home.appendingPathComponent("Library").path,
                         home.appendingPathComponent("Library/Audio").path,
                         home.appendingPathComponent("Music").path]
        guard !protected.contains(source.path) else { throw porterFail("このフォルダ全体は移行対象にできません: \(source.path)") }
        let systemTrees = ["/System", "/usr", "/bin", "/sbin", "/dev", "/private/etc", "/private/var/db", "/etc", "/var/db"]
        guard !systemTrees.contains(where: { source.path == $0 || source.path.hasPrefix($0 + "/") }) else {
            throw porterFail("OSのシステムフォルダは移行対象にできません: \(source.path)")
        }
        let pathParts = source.pathComponents
        guard !(pathParts.count == 3 && pathParts[1] == "Volumes") else {
            throw porterFail("ディスク全体ではなく、音源ライブラリのフォルダを選択してください。")
        }
        let values = try source.resourceValues(forKeys: Set(keys))
        guard values.isDirectory == true || values.isRegularFile == true || values.isSymbolicLink == true else {
            throw porterFail("通常のファイルまたはフォルダを選択してください: \(source.path)")
        }
        // Match the narrowest root before the broad Application Support root.
        let scopes = ["systemPlugins", "userPlugins", "systemPresets", "userPresets", "systemSupport", "userSupport", "shared", "userDocuments", "external"]
        var scope = "external"
        var relative = source.lastPathComponent
        for key in scopes {
            let root = try scopeRoot(key, home: home).standardizedFileURL
            guard source.path != root.path else { throw porterFail("保存先のルート全体ではなく製品別フォルダを選択してください: \(source.path)") }
            if source.path.hasPrefix(root.path + "/") {
                scope = key
                relative = String(source.path.dropFirst(root.path.count + 1))
                break
            }
        }
        let kind = plugInExtensions[source.pathExtension.lowercased()] ??
            ((scope == "systemPresets" || scope == "userPresets") ? "プリセット" : "関連データ候補")
        var notes: [String] = []
        var exportBlocks: [String] = []
        if values.isSymbolicLink == true { notes.append("シンボリックリンク自体は書き出しできません。リンク先の実フォルダを別途選択してください。") }
        if values.isSymbolicLink == true { exportBlocks.append("リンク先の実フォルダを選択してください。") }
        let size = measure(source)
        if size.incomplete { notes.append("一部のファイルを読み取れないため、容量は概算です。") }
        if size.incomplete || !fm.isReadableFile(atPath: source.path) { exportBlocks.append("読み取れないファイルがあります。アクセス権を確認してください。") }
        if size.links > 0 && values.isSymbolicLink != true { notes.append("内部にリンクがあります。別の場所にあるリンク先データは含みません。") }
        if size.unsafeLinks > 0 { notes.append("絶対パスまたはフォルダ外を参照するリンクが\(size.unsafeLinks)個あります。この項目は書き出し対象から外し、メーカーの再インストール等を使用してください。") }
        if size.unsafeLinks > 0 { exportBlocks.append("絶対パスまたはフォルダ外へのリンクがあるため、公式インストーラ等を使用してください。") }
        var architectures: [String] = []
        if plugInExtensions[source.pathExtension.lowercased()] != nil && values.isSymbolicLink != true {
            let info = bundleInfo(source)
            let executableDirectory = source.appendingPathComponent("Contents/MacOS")
            if let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
               !executable.contains("/"), executable != ".", executable != ".." {
                architectures = machOArchitectures(executableDirectory.appendingPathComponent(executable))
            } else {
                // Some legitimate KORG/legacy bundles omit CFBundleExecutable.
                let conventional = executableDirectory.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
                architectures = machOArchitectures(conventional)
                if architectures.isEmpty,
                   let candidates = try? fm.contentsOfDirectory(at: executableDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                    let regularFiles = candidates.filter {
                        let properties = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        return properties?.isRegularFile == true && properties?.isSymbolicLink != true
                    }
                    if regularFiles.count == 1 { architectures = machOArchitectures(regularFiles[0]) }
                }
            }
            if architectures.isEmpty { notes.append("CPU対応を判別できませんでした。移行先で互換性を確認してください。") }
            else if !architectures.contains("arm64") && !architectures.contains("arm64e") {
                notes.append("Apple Siliconネイティブ対応は検出されませんでした。対応版またはホスト側の互換動作が必要です。")
            }
            notes.append("再認証やメーカー公式インストーラが必要になる場合があります。")
        } else if kind == "関連データ候補" {
            notes.append("製品との関連は候補です。プリセット・音源以外や認証関連ファイルを含む可能性があるため、内容を確認して選択してください。")
        }
        if scope == "external" {
            notes.append("移行先は ~/Music/PluginPorter Libraries/\(relative) です。音源の保存場所は製品側で再指定してください。")
        }
        return TransferItem(id: UUID().uuidString, name: source.lastPathComponent, kind: kind, scope: scope,
                            relativePath: relative, sourcePath: source.path, bytes: size.bytes,
                            architectures: architectures, notes: notes,
                            exportBlockReason: exportBlocks.isEmpty ? nil : exportBlocks.joined(separator: " "))
    }

    private static func bundleInfo(_ url: URL) -> [String: Any] {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        // Metadata is intentionally bounded; discovery never reads presets or license contents.
        guard let attributes = try? fm.attributesOfItem(atPath: plist.path),
              let length = attributes[.size] as? NSNumber, length.intValue < 2_000_000,
              let data = try? Data(contentsOf: plist),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return [:] }
        return value
    }

    private static func measure(_ url: URL) -> (bytes: Int64, links: Int, unsafeLinks: Int, incomplete: Bool) {
        guard let root = try? url.resourceValues(forKeys: Set(keys)) else { return (0, 0, 0, true) }
        if root.isSymbolicLink == true { return (Int64(root.fileSize ?? 0), 1, 0, false) }
        if root.isDirectory != true { return (Int64(root.fileSize ?? 0), 0, 0, false) }
        var bytes: Int64 = 0
        var links = 0
        var unsafeLinks = 0
        var incomplete = false
        let realRoot = url.resolvingSymlinksInPath()
        guard let iterator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                          errorHandler: { _, _ in incomplete = true; return true }) else { return (0, 0, 0, true) }
        for case let child as URL in iterator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { incomplete = true; continue }
            if values.isSymbolicLink == true {
                links += 1
                iterator.skipDescendants()
                if let link = try? fm.destinationOfSymbolicLink(atPath: child.path) {
                    let target = child.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL
                    let resolved = child.resolvingSymlinksInPath()
                    if link.hasPrefix("/") || !(target.path == url.path || target.path.hasPrefix(url.path + "/")) ||
                        !(resolved.path == realRoot.path || resolved.path.hasPrefix(realRoot.path + "/")) {
                        unsafeLinks += 1
                    }
                } else { incomplete = true }
            }
            if values.isDirectory != true || values.isSymbolicLink == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return (bytes, links, unsafeLinks, incomplete)
    }

    private static func machOArchitectures(_ url: URL) -> [String] {
        // Never traverse a link to an executable outside the bundle.
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 4096), bytes.count >= 8 else { return [] }
        func u32(_ offset: Int, little: Bool = false) -> UInt32? {
            guard offset >= 0 && offset + 4 <= bytes.count else { return nil }
            let a = UInt32(bytes[offset]), b = UInt32(bytes[offset + 1]), c = UInt32(bytes[offset + 2]), d = UInt32(bytes[offset + 3])
            return little ? a | b << 8 | c << 16 | d << 24 : a << 24 | b << 16 | c << 8 | d
        }
        func arch(_ cpu: UInt32) -> String {
            switch cpu {
            case 0x0100000c: return "arm64"
            case 0x01000007: return "x86_64"
            case 7: return "i386"
            case 12: return "arm"
            case 18: return "ppc"
            case 0x01000012: return "ppc64"
            default: return String(format: "cpu-%08x", cpu)
            }
        }
        guard let magic = u32(0) else { return [] }
        switch magic {
        case 0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe:
            guard let cpu = u32(4, little: magic == 0xcefaedfe || magic == 0xcffaedfe) else { return [] }
            return [arch(cpu)]
        case 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca:
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let stride = (magic == 0xcafebabf || magic == 0xbfbafeca) ? 32 : 20
            guard let count = u32(4, little: little), count > 0, count <= 64,
                  8 + Int(count) * stride <= bytes.count else { return [] }
            var result = Set<String>()
            for index in 0..<Int(count) {
                if let cpu = u32(8 + index * stride, little: little) { result.insert(arch(cpu)) }
            }
            return result.sorted()
        default: return []
        }
    }

    private struct Vendor {
        let hints: [String]
        let folders: [String]
    }

    private static func dataCandidates(home: URL, plugins: [TransferItem], evidence: String) -> [TransferItem] {
        let vendors: [Vendor] = [
            Vendor(hints: ["arturia"], folders: ["Arturia"]),
            Vendor(hints: ["native-instruments", "native instruments", "kontakt", "reaktor", "massive", "guitar rig", "battery"], folders: ["Native Instruments"]),
            Vendor(hints: ["waves", "waveshell"], folders: ["Waves", "Waves Audio"]),
            Vendor(hints: ["universalaudio", "uaudio", "uad", "universal audio"], folders: ["Universal Audio", "UAD", "UADx"]),
            Vendor(hints: ["spectrasonics", "omnisphere", "trilian", "keyscape", "stylus"], folders: ["Spectrasonics", "STEAM", "SAGE"]),
            Vendor(hints: ["fabfilter"], folders: ["FabFilter"]),
            Vendor(hints: ["valhalla"], folders: ["Valhalla DSP", "ValhallaDSP"]),
            Vendor(hints: ["u-he", "uhe", "zebra", "diva"], folders: ["u-he"]),
            Vendor(hints: ["xfer", "serum"], folders: ["Xfer", "Xfer Records", "Serum Presets", "Serum 2 Presets"]),
            Vendor(hints: ["izotope"], folders: ["iZotope"]),
            Vendor(hints: ["softube"], folders: ["Softube"]),
            Vendor(hints: ["plugin-alliance", "plugin alliance", "brainworx", "bx_"], folders: ["Plugin Alliance", "Plugin-Alliance", "Brainworx"]),
            Vendor(hints: ["solidstatelogic", "solid state logic", "ssl native", "ssl fusion"], folders: ["Solid State Logic", "SSL"]),
            Vendor(hints: ["ikmultimedia", "ik multimedia", "amplitube", "sampletank", "t-rack", "tonex"], folders: ["IK Multimedia"]),
            Vendor(hints: ["soundtoys"], folders: ["Soundtoys"]),
            Vendor(hints: ["toontrack", "superior drummer", "ezdrummer"], folders: ["Toontrack"]),
            Vendor(hints: ["xlnaudio", "xln audio", "addictive"], folders: ["XLN Audio"]),
            Vendor(hints: ["spitfire"], folders: ["Spitfire Audio"]),
            Vendor(hints: ["eastwest", "east west", "opus"], folders: ["East West", "EastWest"]),
            Vendor(hints: ["melda"], folders: ["MeldaProduction"]),
            Vendor(hints: ["kilohearts"], folders: ["Kilohearts"]),
            Vendor(hints: ["sonnox"], folders: ["Sonnox"]),
            Vendor(hints: ["tokyodawn", "tokyo dawn", "tdr "], folders: ["Tokyo Dawn Labs", "Tokyo Dawn Records"]),
            Vendor(hints: ["eventide"], folders: ["Eventide"]),
            Vendor(hints: ["acustica"], folders: ["Acustica", "Acustica Audio"]),
            Vendor(hints: ["goodhertz"], folders: ["Goodhertz"]),
            Vendor(hints: ["audiothing"], folders: ["AudioThing"]),
            Vendor(hints: ["output"], folders: ["Output"]),
            Vendor(hints: ["uvi", "falcon"], folders: ["UVI"]),
            Vendor(hints: ["baby audio", "babyaudio"], folders: ["BABY Audio"]),
            Vendor(hints: ["d16"], folders: ["D16 Group"]),
            Vendor(hints: ["robpapen", "rob papen"], folders: ["Rob Papen"]),
            Vendor(hints: ["sugarbytes", "sugar bytes"], folders: ["Sugar Bytes"]),
            Vendor(hints: ["korg"], folders: ["KORG"]),
            Vendor(hints: ["roland"], folders: ["Roland", "Roland Cloud"])
        ]
        let knownFolders = Set(vendors.filter { vendor in vendor.hints.contains { evidence.contains($0) } }
            .flatMap(\.folders).map { $0.lowercased() })
        let productNames = Set(plugins.map { URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent.lowercased() })
        // Documents is privacy-protected in a separately launched macOS app.
        // Access it only after the user explicitly selects a folder in NSOpenPanel.
        let scopes = ["systemPresets", "userPresets", "systemSupport", "userSupport", "shared"]
        var result: [TransferItem] = []
        for scope in scopes {
            guard let root = try? scopeRoot(scope, home: home),
                  let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                let name = child.lastPathComponent.lowercased()
                let isPreset = scope == "systemPresets" || scope == "userPresets"
                guard knownFolders.contains(name) || (isPreset && productNames.contains(name)) else { continue }
                guard let value = try? child.resourceValues(forKeys: Set(keys)),
                      value.isDirectory == true || value.isSymbolicLink == true else { continue }
                if let item = try? makeItem(url: child, home: home) { result.append(item) }
            }
        }
        return result
    }
}
