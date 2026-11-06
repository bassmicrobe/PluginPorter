import Foundation

struct TransferItem: Codable, Identifiable {
    var id: String
    var name: String
    var kind: String
    var scope: String
    var relativePath: String
    var sourcePath: String
    var bytes: Int64
    var architectures: [String]
    var notes: [String]
    var exportBlockReason: String? = nil

    var cpuSupportLabel: String {
        guard ["AU", "VST", "VST3", "AAX"].contains(kind) else { return "—" }
        let appleSilicon = architectures.contains("arm64") || architectures.contains("arm64e")
        let intel = architectures.contains("x86_64") || architectures.contains("i386")
        if appleSilicon && intel { return "両対応" }
        if appleSilicon { return "Apple Silicon" }
        if architectures.contains("x86_64") { return "Intel専用" }
        if architectures.contains("i386") { return "Intel 32bit" }
        return architectures.isEmpty ? "未確認" : "その他"
    }

    var hasIntelOnlyCPU: Bool {
        cpuSupportLabel == "Intel専用" || cpuSupportLabel == "Intel 32bit"
    }
}

struct ArchiveEntry: Codable {
    var item: TransferItem
    var digest: String
    var fileCount: Int
}

struct TransferManifest: Codable {
    var formatVersion: Int
    var createdAt: String
    var sourceOS: String
    var sourceArchitecture: String
    var entries: [ArchiveEntry]
}

struct TransferReport: Codable {
    var completed: [String] = []
    var skipped: [String] = []
    var failed: [String] = []
}

enum PorterError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func porterFail(_ message: String) -> PorterError { .message(message) }

let porterScopes: [String: String] = [
    "systemPlugins": "/Library/Audio/Plug-Ins",
    "userPlugins": "Library/Audio/Plug-Ins",
    "systemPresets": "/Library/Audio/Presets",
    "userPresets": "Library/Audio/Presets",
    "systemSupport": "/Library/Application Support",
    "userSupport": "Library/Application Support",
    "shared": "/Users/Shared",
    "userDocuments": "Documents",
    "external": "Music/PluginPorter Libraries"
]

func scopeRoot(_ scope: String, home: URL) throws -> URL {
    guard let path = porterScopes[scope] else { throw porterFail("不明な保存先: \(scope)") }
    return path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
}

func formattedBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

// Shared API: implemented in Inventory.swift and Engine.swift.
// Inventory.scan(home: URL, includeData: Bool) throws -> [TransferItem]
// Inventory.makeItem(url: URL, home: URL) throws -> TransferItem
// TransferEngine.export(items: [TransferItem], to: URL, progress: (String) -> Void) throws -> TransferManifest
// TransferEngine.readManifest(at: URL) throws -> TransferManifest
// TransferEngine.verify(at: URL, progress: (String) -> Void) throws
// TransferEngine.restore(from: URL, home: URL, selectedIDs: Set<String>?, progress: (String) -> Void) throws -> TransferReport
