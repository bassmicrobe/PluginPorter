import Foundation

/// Disposable 256 MiB transfer workload. Run separately from correctness tests.
@main
struct EnginePerformance {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent(".build/audit-engine/fixture-\(UUID().uuidString)")
        let source = base.appendingPathComponent("source")
        let home = base.appendingPathComponent("home")
        let archive = base.appendingPathComponent("fixture.pluginporter")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let fileCount = 256
        let contents = Data(repeating: 0x5a, count: 1024 * 1024)
        for index in 0..<fileCount {
            try contents.write(to: source.appendingPathComponent("音色-\(index).dat"))
        }
        let item = TransferItem(id: UUID().uuidString, name: "Fixture", kind: "関連データ候補",
                                scope: "external", relativePath: "Fixture", sourcePath: source.path,
                                bytes: Int64(fileCount * contents.count), architectures: [], notes: [])
        let started = Date()
        _ = try TransferEngine.export(items: [item], to: archive, progress: { _ in })
        let exported = Date()
        try TransferEngine.verify(at: archive, progress: { _ in })
        let verified = Date()
        let report = try TransferEngine.restore(from: archive, home: home, selectedIDs: nil, progress: { _ in })
        let restored = Date()
        guard report.completed.count == 1, report.failed.isEmpty else {
            throw porterFail("Performance fixture did not restore")
        }
        print(String(format: "export=%.6f verify=%.6f restore=%.6f total=%.6f",
                     exported.timeIntervalSince(started), verified.timeIntervalSince(exported),
                     restored.timeIntervalSince(verified), restored.timeIntervalSince(started)))
    }
}
