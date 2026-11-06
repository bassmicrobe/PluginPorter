import Foundation
import Darwin

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() == false { throw TestFailure(description: message) }
}

func expectThrows(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw TestFailure(description: "Expected failure: \(message)")
}

struct Fixture {
    let base: URL
    let source: URL
    let archive: URL
    let home: URL
    let fm = FileManager.default

    init() throws {
        // macOS /var and /tmp are symlinks, intentionally disallowed as restore
        // ancestors by the engine. Keep disposable fixtures in this workspace.
        let scratchRoot = ProcessInfo.processInfo.environment["PLUGIN_PORTER_TEST_ROOT"]
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/PluginPorter/Tests").path
        base = URL(fileURLWithPath: scratchRoot).appendingPathComponent(".fixture-\(UUID().uuidString)")
        source = base.appendingPathComponent("source")
        archive = base.appendingPathComponent("fixture.pluginporter")
        home = base.appendingPathComponent("receiving-home")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func clean() { try? fm.removeItem(at: base) }

    func write(_ value: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    func plugin(_ name: String = "Example", symlink: Bool = true) throws -> TransferItem {
        let bundle = source.appendingPathComponent("\(name).vst3")
        try write("inert fixture, never execute", to: bundle.appendingPathComponent("Contents/MacOS/\(name)"))
        try write("{fixture:true}", to: bundle.appendingPathComponent("Contents/Info.plist"))
        try write("sample data \(name)", to: bundle.appendingPathComponent("Contents/Resources/音色 sample.dat"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appendingPathComponent("Contents/MacOS/\(name)").path)
        if symlink {
            try fm.createSymbolicLink(atPath: bundle.appendingPathComponent("CurrentResources").path, withDestinationPath: "Contents/Resources")
        }
        return TransferItem(id: UUID().uuidString, name: name, kind: "VST3", scope: "userPlugins", relativePath: "VST3/\(name).vst3", sourcePath: bundle.path, bytes: 100, architectures: ["arm64"], notes: [])
    }

    func target(_ item: TransferItem) -> URL {
        home.appendingPathComponent("Library/Audio/Plug-Ins").appendingPathComponent(item.relativePath)
    }

    func payload(_ item: TransferItem) -> URL {
        archive.appendingPathComponent("payload").appendingPathComponent(item.id)
    }

    func export(_ items: [TransferItem]) throws -> TransferManifest {
        try TransferEngine.export(items: items, to: archive, progress: { _ in })
    }

    func restore(_ selected: Set<String>? = nil) throws -> TransferReport {
        try TransferEngine.restore(from: archive, home: home, selectedIDs: selected, progress: { _ in })
    }

    func rewriteManifest(_ mutate: (inout TransferManifest) -> Void) throws {
        let url = archive.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(TransferManifest.self, from: Data(contentsOf: url))
        mutate(&manifest)
        try JSONEncoder().encode(manifest).write(to: url)
    }
}

func withFixture(_ body: (Fixture) throws -> Void) throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try body(fixture)
}

@discardableResult
func runCommand(_ executable: String, _ arguments: [String]) throws -> (Int32, Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

@main
struct EngineTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("export rejects more entries than the archive reader supports", {
                let items = (0..<20_001).map { index in
                    TransferItem(id: UUID().uuidString, name: "Fixture\(index)", kind: "関連データ候補",
                                 scope: "external", relativePath: "Fixture\(index)", sourcePath: "/inert-fixture/\(index)",
                                 bytes: 0, architectures: [], notes: [])
                }
                try expectThrows("oversized item list is rejected before reading source files") {
                    try TransferEngine.validateItems(items)
                }
            }),
            ("oversized export metadata cannot publish an unreadable archive", {
                try withFixture { f in
                    let original = try f.plugin("MetadataLimit")
                    let item = TransferItem(id: original.id, name: original.name, kind: original.kind,
                                            scope: original.scope, relativePath: original.relativePath,
                                            sourcePath: original.sourcePath, bytes: original.bytes,
                                            architectures: original.architectures,
                                            notes: [String(repeating: "x", count: 32 * 1024 * 1024)])
                    let before = try TransferEngine.fingerprint(URL(fileURLWithPath: original.sourcePath))
                    try expectThrows("export cannot exceed the reader metadata limit") { _ = try f.export([item]) }
                    try expect(!f.fm.fileExists(atPath: f.archive.path), "no unreadable archive is published")
                    try expect(try f.fm.contentsOfDirectory(atPath: f.base.path).filter { $0.hasPrefix(".PluginPorter-") }.isEmpty, "oversized temporary export is removed")
                    try expect(try TransferEngine.fingerprint(URL(fileURLWithPath: original.sourcePath)).0 == before.0, "source survives rejected export")
                }
            }),
            ("untrusted byte counts reject negative values and aggregate overflow", {
                for sizes in [[Int64(-1)], [Int64.max, Int64(1)]] {
                    try withFixture { f in
                        let items = try sizes.enumerated().map { index, bytes in
                            let original = try f.plugin("Size\(index)")
                            return TransferItem(id: original.id, name: original.name, kind: original.kind,
                                                scope: original.scope, relativePath: original.relativePath,
                                                sourcePath: original.sourcePath, bytes: bytes,
                                                architectures: original.architectures, notes: original.notes)
                        }
                        try expectThrows("invalid byte counts cannot be exported") { _ = try f.export(items) }
                        try expect(!f.fm.fileExists(atPath: f.archive.path), "invalid plan publishes no archive")
                        let valid = try f.plugin("Valid")
                        _ = try f.export([valid])
                        let manifest = try TransferEngine.readManifest(at: f.archive)
                        let invalid = TransferManifest(formatVersion: manifest.formatVersion,
                                                       createdAt: manifest.createdAt, sourceOS: manifest.sourceOS,
                                                       sourceArchitecture: manifest.sourceArchitecture,
                                                       entries: items.map { ArchiveEntry(item: $0, digest: manifest.entries[0].digest, fileCount: 0) })
                        try JSONEncoder().encode(invalid).write(to: f.archive.appendingPathComponent("manifest.json"))
                        try expectThrows("invalid byte counts cannot be loaded into the UI") {
                            _ = try TransferEngine.readManifest(at: f.archive)
                        }
                        try expect(try f.fm.contentsOfDirectory(atPath: f.home.path).isEmpty, "rejection leaves destination untouched")
                    }
                }
            }),
            ("inventory does not read metadata through an external symlink", {
                try withFixture { f in
                    let original = try f.plugin("Metadata")
                    let bundle = URL(fileURLWithPath: original.sourcePath)
                    let info = bundle.appendingPathComponent("Contents/Info.plist")
                    let external = f.base.appendingPathComponent("outside.plist")
                    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Alternate"], format: .xml, options: 0).write(to: external)
                    try f.fm.removeItem(at: info)
                    try f.fm.createSymbolicLink(atPath: info.path, withDestinationPath: external.path)
                    // Minimal read-only Mach-O headers; neither file is executed.
                    try Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0, 0, 0x01]).write(to: bundle.appendingPathComponent("Contents/MacOS/Metadata"))
                    try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 0x01]).write(to: bundle.appendingPathComponent("Contents/MacOS/Alternate"))
                    let item = try Inventory.makeItem(url: bundle, home: f.home)
                    try expect(item.architectures == ["x86_64"], "unsafe metadata is ignored in favor of the conventional in-bundle executable")
                    try expect(item.exportBlockReason != nil, "escaping metadata link remains blocked for export")
                    try f.fm.removeItem(at: info)
                    try expect(mkfifo(info.path, 0o600) == 0, "create inert FIFO metadata fixture")
                    let fifoItem = try Inventory.makeItem(url: bundle, home: f.home)
                    try expect(fifoItem.architectures == ["x86_64"], "FIFO metadata is ignored without blocking")
                    try f.fm.removeItem(at: info)
                    let internalInfo = bundle.appendingPathComponent("Contents/ActualInfo.plist")
                    try f.fm.copyItem(at: external, to: internalInfo)
                    try f.fm.createSymbolicLink(atPath: info.path, withDestinationPath: "ActualInfo.plist")
                    let linkedItem = try Inventory.makeItem(url: bundle, home: f.home)
                    try expect(linkedItem.architectures == ["arm64"], "safe internal metadata links remain supported")
                }
            }),
            ("inventory never inspects an executable outside its bundle through an ancestor link", {
                try withFixture { f in
                    let original = try f.plugin("LinkedExecutable")
                    let bundle = URL(fileURLWithPath: original.sourcePath)
                    let executableDirectory = bundle.appendingPathComponent("Contents/MacOS")
                    let external = f.base.appendingPathComponent("outside-executables")
                    try f.fm.createDirectory(at: external, withIntermediateDirectories: true)
                    try Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0, 0, 0x01]).write(to: external.appendingPathComponent("LinkedExecutable"))
                    try f.fm.removeItem(at: executableDirectory)
                    try f.fm.createSymbolicLink(atPath: executableDirectory.path, withDestinationPath: external.path)
                    let item = try Inventory.makeItem(url: bundle, home: f.home)
                    try expect(item.architectures.isEmpty, "external executable data is not inspected")
                    try expect(item.exportBlockReason != nil, "external executable link remains blocked for export")
                }
            }),
            ("roundtrip, source preservation, internal symlink and user home", {
                try withFixture { f in
                    let item = try f.plugin()
                    let source = URL(fileURLWithPath: item.sourcePath)
                    let before = try TransferEngine.fingerprint(source)
                    let metadataBefore = try f.fm.attributesOfItem(atPath: source.appendingPathComponent("Contents/MacOS/Example").path)
                    let manifest = try f.export([item])
                    try expect(manifest.entries.count == 1, "one entry exported")
                    try TransferEngine.verify(at: f.archive, progress: { _ in })
                    let report = try f.restore()
                    try expect(report.completed.count == 1 && report.failed.isEmpty && report.skipped.isEmpty, "roundtrip completed: \(report)")
                    let after = try TransferEngine.fingerprint(source)
                    try expect(before.0 == after.0 && before.1 == after.1, "source remains unchanged")
                    let restored = try TransferEngine.fingerprint(f.target(item))
                    try expect(restored.0 == before.0, "restored content and links match")
                    let link = try f.fm.destinationOfSymbolicLink(atPath: f.target(item).appendingPathComponent("CurrentResources").path)
                    try expect(link == "Contents/Resources", "relative symlink preserved")
                    let metadataAfter = try f.fm.attributesOfItem(atPath: f.target(item).appendingPathComponent("Contents/MacOS/Example").path)
                    try expect((metadataAfter[.posixPermissions] as? NSNumber) == (metadataBefore[.posixPermissions] as? NSNumber), "executable mode preserved")
                    let second = try f.restore()
                    try expect(second.completed.isEmpty && second.skipped.count == 1, "second restore is a skip")
                }
            }),
            ("existing bundles are skipped without merging or overwriting", {
                try withFixture { f in
                    let item = try f.plugin()
                    _ = try f.export([item])
                    try f.write("existing user's content", to: f.target(item).appendingPathComponent("keep.txt"))
                    let before = try TransferEngine.fingerprint(f.target(item))
                    let report = try f.restore()
                    let after = try TransferEngine.fingerprint(f.target(item))
                    try expect(report.skipped.count == 1 && report.completed.isEmpty, "existing bundle skipped")
                    try expect(before.0 == after.0, "existing bundle unchanged")
                    try expect(!f.fm.fileExists(atPath: f.target(item).appendingPathComponent("Contents").path), "bundle never merged")
                }
            }),
            ("existing regular file is skipped", {
                try withFixture { f in
                    let item = try f.plugin()
                    _ = try f.export([item])
                    try f.write("existing file", to: f.target(item))
                    let report = try f.restore()
                    let data = try String(contentsOf: f.target(item), encoding: .utf8)
                    try expect(report.skipped.count == 1 && data == "existing file", "file unchanged")
                }
            }),
            ("tampered later entry aborts before any destination writes", {
                try withFixture { f in
                    let first = try f.plugin("First")
                    let second = try f.plugin("Second")
                    _ = try f.export([first, second])
                    try f.write("tampered", to: f.payload(second).appendingPathComponent("Contents/Info.plist"))
                    try expectThrows("verify tampered package") { try TransferEngine.verify(at: f.archive, progress: { _ in }) }
                    try expectThrows("restore preflight abort") { _ = try f.restore() }
                    try expect(try f.fm.contentsOfDirectory(atPath: f.home.path).isEmpty, "home remains completely empty")
                }
            }),
            ("selection restores only the selected item", {
                try withFixture { f in
                    let first = try f.plugin("First")
                    let second = try f.plugin("Second")
                    _ = try f.export([first, second])
                    let report = try f.restore([first.id])
                    try expect(report.completed.count == 1, "exactly one restored")
                    try expect(f.fm.fileExists(atPath: f.target(first).path) && !f.fm.fileExists(atPath: f.target(second).path), "selection controls target")
                    try expectThrows("unknown ID") { _ = try f.restore([UUID().uuidString]) }
                    try expectThrows("empty selection") { _ = try f.restore([]) }
                }
            }),
            ("malformed manifest rejects traversal, invalid scopes and IDs", {
                for path in ["../Escape.vst3", "VST3/../../Escape.vst3", "/VST3/Escape.vst3", "VST3//Escape.vst3", "VST3/./Escape.vst3", "VST3/Escape\0.vst3", ""] {
                    try withFixture { f in
                        let item = try f.plugin()
                        _ = try f.export([item])
                        try f.rewriteManifest { $0.entries[0].item.relativePath = path }
                        try expectThrows("bad path \(path)") { _ = try f.restore() }
                        try expect(try f.fm.contentsOfDirectory(atPath: f.home.path).isEmpty, "bad path did not write")
                    }
                }
                for mutation in ["scope", "id", "duplicate", "overlap", "version"] {
                    try withFixture { f in
                        let item = try f.plugin()
                        _ = try f.export([item])
                        try f.rewriteManifest {
                            switch mutation {
                            case "scope": $0.entries[0].item.scope = "../../etc"
                            case "id": $0.entries[0].item.id = "../../escape"
                            case "duplicate": $0.entries.append($0.entries[0])
                            case "overlap":
                                var child = $0.entries[0]
                                child.item.id = UUID().uuidString
                                child.item.relativePath += "/Inner.vst3"
                                $0.entries.append(child)
                            default: $0.formatVersion = 99
                            }
                        }
                        try expectThrows("invalid \(mutation)") { _ = try f.restore() }
                    }
                }
            }),
            ("escaping payload link fails before destination writes", {
                try withFixture { f in
                    let item = try f.plugin()
                    _ = try f.export([item])
                    try f.fm.createSymbolicLink(atPath: f.payload(item).appendingPathComponent("escape").path, withDestinationPath: "../../../source")
                    try expectThrows("escaping package link") { _ = try f.restore() }
                    try expect(try f.fm.contentsOfDirectory(atPath: f.home.path).isEmpty, "link did not write outside")
                }
            }),
            ("absolute source links are rejected and partial archive removed", {
                try withFixture { f in
                    let item = try f.plugin()
                    try f.fm.createSymbolicLink(atPath: URL(fileURLWithPath: item.sourcePath).appendingPathComponent("absolute").path, withDestinationPath: f.home.path)
                    try expectThrows("absolute source link") { _ = try f.export([item]) }
                    try expect(!f.fm.fileExists(atPath: f.archive.path), "no published broken archive")
                    let hidden = try f.fm.contentsOfDirectory(atPath: f.base.path).filter { $0.hasPrefix(".PluginPorter-") }
                    try expect(hidden.isEmpty, "partial archive cleaned up")
                }
            }),
            ("payload root symlink is rejected", {
                try withFixture { f in
                    let item = try f.plugin()
                    _ = try f.export([item])
                    try f.fm.removeItem(at: f.payload(item))
                    try f.fm.createSymbolicLink(atPath: f.payload(item).path, withDestinationPath: item.sourcePath)
                    try expectThrows("payload root link") { _ = try f.restore() }
                }
            }),
            ("existing destination symlink blocks writing and reports partial result", {
                try withFixture { f in
                    let first = try f.plugin("First")
                    let second = try f.plugin("Second")
                    _ = try f.export([first, second])
                    let external = f.base.appendingPathComponent("unrelated-directory")
                    try f.fm.createDirectory(at: external, withIntermediateDirectories: true)
                    try f.write("unchanged", to: external.appendingPathComponent("keep.txt"))
                    let before = try TransferEngine.fingerprint(external)
                    try f.fm.createDirectory(at: f.target(first).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try f.fm.createSymbolicLink(atPath: f.target(first).path, withDestinationPath: external.path)
                    let report = try f.restore()
                    try expect(report.failed.count == 1 && report.completed.count == 1, "partial result recorded")
                    let after = try TransferEngine.fingerprint(external)
                    try expect(before.0 == after.0, "symlink target unchanged")
                    try expect(f.fm.fileExists(atPath: f.target(second).path), "independent valid item restored")
                }
            }),
            ("destination ancestor symlink blocks all related writes", {
                try withFixture { f in
                    let item = try f.plugin()
                    _ = try f.export([item])
                    let external = f.base.appendingPathComponent("unrelated-directory")
                    try f.fm.createDirectory(at: external, withIntermediateDirectories: true)
                    try f.fm.createSymbolicLink(atPath: f.home.appendingPathComponent("Library").path, withDestinationPath: external.path)
                    let report = try f.restore()
                    try expect(report.failed.count == 1, "ancestor symlink reports failure")
                    try expect(try f.fm.contentsOfDirectory(atPath: external.path).isEmpty, "ancestor link target untouched")
                }
            }),
            ("dangling destination symlink is retained", {
                try withFixture { f in
                    let item = try f.plugin()
                    _ = try f.export([item])
                    try f.fm.createDirectory(at: f.target(item).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try f.fm.createSymbolicLink(atPath: f.target(item).path, withDestinationPath: "missing-target")
                    let report = try f.restore()
                    try expect(report.failed.count == 1 && report.completed.isEmpty, "dangling destination blocks installation")
                    let link = try f.fm.destinationOfSymbolicLink(atPath: f.target(item).path)
                    try expect(link == "missing-target", "dangling symlink was not overwritten")
                }
            }),
            ("regular parent failure leaves completed independent entries intact", {
                try withFixture { f in
                    let first = try f.plugin("First")
                    var second = try f.plugin("Second")
                    second.relativePath = "VST3/Blocked/Second.vst3"
                    _ = try f.export([first, second])
                    try f.write("blocking file", to: f.home.appendingPathComponent("Library/Audio/Plug-Ins/VST3/Blocked"))
                    let report = try f.restore()
                    try expect(report.completed.count == 1 && report.failed.count == 1, "per-entry partial report")
                    try expect(f.fm.fileExists(atPath: f.target(first).path), "first remains installed")
                }
            }),
            ("source within export destination is blocked without source changes", {
                try withFixture { f in
                    let item = try f.plugin()
                    let source = URL(fileURLWithPath: item.sourcePath)
                    let before = try TransferEngine.fingerprint(source)
                    try expectThrows("recursive export") {
                        _ = try TransferEngine.export(items: [item], to: source.appendingPathComponent("nested.pluginporter"), progress: { _ in })
                    }
                    let after = try TransferEngine.fingerprint(source)
                    try expect(before.0 == after.0, "source untouched on invalid export")
                }
            }),
            ("export destination ancestor symlink cannot redirect into source", {
                try withFixture { f in
                    let item = try f.plugin()
                    let source = URL(fileURLWithPath: item.sourcePath)
                    let alias = f.base.appendingPathComponent("source-alias")
                    try f.fm.createSymbolicLink(atPath: alias.path, withDestinationPath: source.path)
                    let before = try TransferEngine.fingerprint(source)
                    try expectThrows("recursive export via symlink parent") {
                        _ = try TransferEngine.export(items: [item], to: alias.appendingPathComponent("nested.pluginporter"), progress: { _ in })
                    }
                    let after = try TransferEngine.fingerprint(source)
                    try expect(before.0 == after.0, "source untouched through symlink alias")
                    let hidden = try f.fm.contentsOfDirectory(atPath: source.path).filter { $0.hasPrefix(".PluginPorter-") }
                    try expect(hidden.isEmpty, "no temporary export stage inside source")
                }
            }),
            ("extended attributes and resource forks survive copy", {
                try withFixture { f in
                    let item = try f.plugin()
                    let sourceFile = URL(fileURLWithPath: item.sourcePath).appendingPathComponent("Contents/Resources/音色 sample.dat")
                    let custom = try runCommand("/usr/bin/xattr", ["-w", "org.pluginporter.fixture", "preserved-value", sourceFile.path])
                    try expect(custom.0 == 0, "can create fixture xattr")
                    let resource = try runCommand("/usr/bin/xattr", ["-wx", "com.apple.ResourceFork", "000102030405AABBCCDD", sourceFile.path])
                    try expect(resource.0 == 0, "can create fixture resource fork")
                    _ = try f.export([item])
                    let report = try f.restore()
                    try expect(report.completed.count == 1, "metadata fixture restored")
                    let target = f.target(item).appendingPathComponent("Contents/Resources/音色 sample.dat")
                    let copiedCustom = try runCommand("/usr/bin/xattr", ["-p", "org.pluginporter.fixture", target.path])
                    try expect(copiedCustom.0 == 0 && String(data: copiedCustom.1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "preserved-value", "custom xattr preserved")
                    let copiedFork = try runCommand("/usr/bin/xattr", ["-px", "com.apple.ResourceFork", target.path])
                    let originalFork = try runCommand("/usr/bin/xattr", ["-px", "com.apple.ResourceFork", sourceFile.path])
                    try expect(copiedFork.0 == 0 && copiedFork.1 == originalFork.1, "resource fork preserved")
                }
            })
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures += 1
                fputs("FAIL \(name): \(error)\n", stderr)
            }
        }
        print("\(tests.count - failures)/\(tests.count) test groups passed")
        exit(failures == 0 ? 0 : 1)
    }
}
