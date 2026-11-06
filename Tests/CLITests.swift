import Foundation
import Darwin

struct CLITestFailure: Error, CustomStringConvertible {
    let description: String
}

struct CLITestSkipped: Error {}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CLITestFailure(description: message) }
}

struct CLIFixture {
    let base: URL
    let source: URL
    let home: URL
    let plan: URL
    let archive: URL
    let item: TransferItem
    let executable: URL

    init() throws {
        guard let root = ProcessInfo.processInfo.environment["PLUGIN_PORTER_TEST_ROOT"] else {
            throw CLITestFailure(description: "Missing isolated test directory")
        }
        base = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
        source = base.appendingPathComponent("source.txt")
        home = base.appendingPathComponent("receiving-home")
        plan = base.appendingPathComponent("plan.json")
        archive = base.appendingPathComponent("backup.pluginporter")
        executable = URL(fileURLWithPath: CommandLine.arguments[1])
        item = TransferItem(id: UUID().uuidString, name: "Fixture", kind: "data", scope: "userDocuments", relativePath: "fixture.txt", sourcePath: source.path, bytes: 7, architectures: [], notes: [])
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: source)
        try JSONEncoder().encode([item]).write(to: plan)
    }

    func run(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--cli"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func export() throws {
        let result = try run(["export", archive.path, "--plan", plan.path])
        try check(result.0 == 0, "Fixture export failed: \(result.1)")
    }

    var restored: URL { home.appendingPathComponent("Documents/fixture.txt") }

    func presetPlan() throws -> (PresetImportPlan, URL, URL) {
        let pack = base.appendingPathComponent("購入 Pack 🎹")
        let source = pack.appendingPathComponent("Lead.h2p")
        let library = base.appendingPathComponent("Diva")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("#AM=Diva\nfixture".utf8).write(to: source)
        let plan = try PresetOrganizer.analyze(folders: [pack], libraries: [PresetLibrary(id: "diva", name: "Diva", rootPath: library.path, presetFolder: "", detected: true)], serumFXPTarget: "serum1", progress: { _ in })
        let url = base.appendingPathComponent("preset-plan.json")
        try PresetOrganizer.savePlan(plan, to: url)
        return (plan, url, source)
    }
}

@main
struct CLITests {
    static func main() {
        let tests: [(String, (CLIFixture) throws -> Void)] = [
            ("export rejects oversized and nonregular plans", { f in
                let oversized = f.base.appendingPathComponent("oversized.json")
                try Data().write(to: oversized)
                let handle = try FileHandle(forWritingTo: oversized)
                try handle.truncate(atOffset: 32 * 1024 * 1024 + 1)
                try handle.close()
                let alias = f.base.appendingPathComponent("plan-link.json")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.plan)
                let fifo = f.base.appendingPathComponent("plan-fifo.json")
                guard mkfifo(fifo.path, 0o600) == 0 else { throw CLITestFailure(description: "Cannot create FIFO fixture") }
                for input in [alias, oversized, fifo] {
                    let result = try f.run(["export", f.archive.path, "--plan", input.path])
                    try check(result.0 == 1, "Invalid plan did not fail promptly: \(input.lastPathComponent)")
                    try check(!TransferEngine.exists(f.archive), "Invalid plan exported data")
                }
            }),
            ("scan output protects entries hidden by the match filter", { f in
                if ProcessInfo.processInfo.environment["PLUGIN_PORTER_REAL_SCANNER"] == "1" {
                    throw CLITestSkipped()
                }
                try JSONEncoder().encode([f.item]).write(to: f.home.appendingPathComponent("inventory-fixture.json"))
                let before = try Data(contentsOf: f.source)
                let result = try f.run(["scan", "--home", f.home.path, "--match", "no fixture matches this", "--output", f.source.path])
                try check(result.0 == 1, "Hidden scanned source could be overwritten")
                try check(Data(contentsOf: f.source) == before, "Scanning changed source data")
            }),
            ("unsupported dry-run must not export", { f in
                let result = try f.run(["export", f.archive.path, "--plan", f.plan.path, "--dry-run"])
                try check(result.0 == 1, "Unsupported --dry-run was accepted")
                try check(!TransferEngine.exists(f.archive), "Rejected command created an archive")
                try check(Data(contentsOf: f.source) == Data("fixture".utf8), "Source changed")
            }),
            ("unsupported dry-run must not install presets", { f in
                let (plan, url, source) = try f.presetPlan()
                let before = try Data(contentsOf: source)
                let result = try f.run(["preset-install", url.path, "--dry-run"])
                try check(result.0 == 1, "Unsupported --dry-run was accepted")
                try check(!TransferEngine.exists(URL(fileURLWithPath: plan.items[0].destinationPath!)), "Rejected command installed a preset")
                try check(Data(contentsOf: source) == before, "Original preset changed")
            }),
            ("restore report cannot overwrite archive or destination", { f in
                try f.export()
                let manifest = f.archive.appendingPathComponent("manifest.json")
                let before = try Data(contentsOf: manifest)
                let original = try Data(contentsOf: f.source)
                for path in [manifest, f.restored, f.source] {
                    let result = try f.run(["restore", f.archive.path, "--home", f.home.path, "--report", path.path])
                    try check(result.0 == 1, "Protected report path was accepted")
                    try check(Data(contentsOf: manifest) == before, "Archive changed")
                    try check(Data(contentsOf: f.source) == original, "Original export source changed")
                    try check(!TransferEngine.exists(f.restored), "Rejected report path still restored data")
                }
            }),
            ("report cannot become a new ancestor of a restored item", { f in
                let item = TransferItem(id: f.item.id, name: f.item.name, kind: f.item.kind, scope: f.item.scope, relativePath: "Folder/item.txt", sourcePath: f.source.path, bytes: f.item.bytes, architectures: [], notes: [])
                try JSONEncoder().encode([item]).write(to: f.plan)
                try f.export()
                try FileManager.default.createDirectory(at: f.home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
                let report = f.home.appendingPathComponent("Documents/Folder")
                let result = try f.run(["restore", f.archive.path, "--home", f.home.path, "--report", report.path])
                try check(result.0 == 1, "Report ancestor of target was accepted")
                try check(!TransferEngine.exists(report), "Rejected report path still changed destination")
            }),
            ("preset report cannot overwrite source, plan or destination", { f in
                let (plan, url, source) = try f.presetPlan()
                let before = try Data(contentsOf: source)
                let planBefore = try Data(contentsOf: url)
                let target = URL(fileURLWithPath: plan.items[0].destinationPath!)
                for path in [source, url, target] {
                    let result = try f.run(["preset-install", url.path, "--report", path.path])
                    try check(result.0 == 1, "Protected report path was accepted")
                    try check(Data(contentsOf: source) == before, "Purchased preset changed")
                    try check(Data(contentsOf: url) == planBefore, "Import plan changed")
                    try check(!TransferEngine.exists(target), "Rejected report path still installed data")
                }
            }),
            ("preset plan output cannot overwrite purchased files", { f in
                let (_, _, source) = try f.presetPlan()
                let before = try Data(contentsOf: source)
                let result = try f.run(["preset-plan", source.deletingLastPathComponent().path, "--home", f.home.path, "--output", source.path])
                try check(result.0 == 1, "Output inside the purchased pack was accepted")
                try check(Data(contentsOf: source) == before, "Purchased preset was replaced by JSON")
            }),
            ("report source protection resolves ancestor symlinks", { f in
                let (plan, url, source) = try f.presetPlan()
                let alias = f.base.appendingPathComponent("alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.deletingLastPathComponent())
                let report = alias.appendingPathComponent("report.json")
                let result = try f.run(["preset-install", url.path, "--report", report.path])
                try check(result.0 == 1, "Symlink alias into source pack was accepted")
                try check(!TransferEngine.exists(report), "Report modified the source pack")
                try check(!TransferEngine.exists(URL(fileURLWithPath: plan.items[0].destinationPath!)), "Rejected report still installed data")
            }),
            ("report protects unrecognized input packs and case aliases", { f in
                let (plan, url, source) = try f.presetPlan()
                let emptyPack = f.base.appendingPathComponent("Unrecognized Pack")
                try FileManager.default.createDirectory(at: emptyPack, withIntermediateDirectories: true)
                let complete = PresetImportPlan(formatVersion: plan.formatVersion, createdAt: plan.createdAt, libraries: plan.libraries, items: plan.items, ignoredFileCount: plan.ignoredFileCount, notes: plan.notes, sourceRoots: (plan.sourceRoots ?? []) + [emptyPack.path])
                try PresetOrganizer.savePlan(complete, to: url)
                let output = emptyPack.appendingPathComponent("report.json")
                try check(f.run(["preset-install", url.path, "--report", output.path]).0 == 1, "Unrecognized pack was not protected")
                try check(!TransferEngine.exists(output), "Report was created inside input pack")
                let alias = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("購入 pACK 🎹")
                if TransferEngine.exists(alias) {
                    let before = try Data(contentsOf: source)
                    try check(f.run(["preset-install", url.path, "--report", alias.appendingPathComponent(source.lastPathComponent).path]).0 == 1, "Case alias was not protected")
                    try check(Data(contentsOf: source) == before, "Case alias overwrote source")
                }
                try check(!TransferEngine.exists(URL(fileURLWithPath: plan.items[0].destinationPath!)), "Rejected report still installed data")
            }),
            ("invalid report directory fails before restoring", { f in
                try f.export()
                for output in [f.base, f.base.appendingPathComponent("missing/report.json")] {
                    try check(f.run(["restore", f.archive.path, "--home", f.home.path, "--report", output.path]).0 == 1, "Invalid report destination was accepted")
                    try check(!TransferEngine.exists(f.restored), "Invalid report path still restored data")
                }
            }),
            ("missing and repeated option values fail before copying", { f in
                for extra in [["--match", "--dry-run"], ["--plan", f.plan.path], ["--match", ""]] {
                    let result = try f.run(["export", f.archive.path, "--plan", f.plan.path] + extra)
                    try check(result.0 == 1, "Invalid option values were accepted")
                    try check(!TransferEngine.exists(f.archive), "Invalid arguments exported data")
                }
            }),
            ("valid CLI export verify dry-run restore and collision", { f in
                try f.export()
                try check(f.run(["verify", f.archive.path]).0 == 0, "Verify failed")
                try check(f.run(["restore", f.archive.path, "--home", f.home.path, "--dry-run"]).0 == 0, "Valid dry-run failed")
                try check(!TransferEngine.exists(f.restored), "Dry-run wrote destination")
                let report = f.base.appendingPathComponent("report.json")
                try check(f.run(["restore", f.archive.path, "--home", f.home.path, "--report", report.path]).0 == 0, "Restore failed")
                try check(Data(contentsOf: f.restored) == Data(contentsOf: f.source), "Restored data differs")
                let first = try JSONDecoder().decode(TransferReport.self, from: Data(contentsOf: report))
                try check(first.completed.count == 1 && first.failed.isEmpty, "Restore report is incorrect")
                try check(f.run(["restore", f.archive.path, "--home", f.home.path, "--report", report.path]).0 == 0, "Repeated restore failed")
                let second = try JSONDecoder().decode(TransferReport.self, from: Data(contentsOf: report))
                try check(second.skipped.count == 1 && second.completed.isEmpty, "Collision did not skip")
            }),
            ("valid CLI preset install and repeat preserve purchased data", { f in
                let (plan, url, source) = try f.presetPlan()
                let before = try Data(contentsOf: source)
                let target = URL(fileURLWithPath: plan.items[0].destinationPath!)
                let report = f.base.appendingPathComponent("preset-report.json")
                try check(f.run(["preset-install", url.path, "--report", report.path]).0 == 0, "Preset install failed")
                try check(Data(contentsOf: target) == before && Data(contentsOf: source) == before, "Preset data changed")
                try check(f.run(["preset-install", url.path, "--report", report.path]).0 == 0, "Repeated preset install failed")
                let second = try JSONDecoder().decode(TransferReport.self, from: Data(contentsOf: report))
                try check(second.skipped.count == 1 && second.completed.isEmpty, "Preset collision did not skip")
            }),
            ("valid CLI preset-plan writes separate JSON without copying", { f in
                let (plan, _, source) = try f.presetPlan()
                let before = try Data(contentsOf: source)
                let output = f.base.appendingPathComponent("analyzed.json")
                try check(f.run(["preset-plan", source.deletingLastPathComponent().path, "--home", f.home.path, "--output", output.path]).0 == 0, "Preset plan failed")
                let result = try PresetOrganizer.loadPlan(at: output)
                try check(result.items.count == 1 && result.items[0].detectedTargetID == "diva", "CLI plan lost preset detection")
                try check(Data(contentsOf: source) == before, "Planning changed source")
                try check(!TransferEngine.exists(URL(fileURLWithPath: plan.items[0].destinationPath!)), "Planning installed a preset")
            })
        ]
        let outcomes = tests.map { name, test -> Bool? in
            do {
                let fixture = try CLIFixture()
                defer { try? FileManager.default.removeItem(at: fixture.base) }
                try test(fixture)
                print("PASS \(name)")
                return true
            } catch is CLITestSkipped {
                print("SKIP \(name) (isolated scanner fixture requires the test executable)")
                return nil
            } catch {
                print("FAIL \(name): \(error)")
                return false
            }
        }
        let executed = outcomes.compactMap { $0 }
        print("\(executed.filter { $0 }.count)/\(executed.count) CLI groups passed; \(outcomes.count - executed.count) skipped")
        exit(executed.allSatisfy { $0 } ? 0 : 1)
    }
}
