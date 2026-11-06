import Foundation
import Darwin

struct PresetTestFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw PresetTestFailure(description: message) }
}

func mustThrow(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw PresetTestFailure(description: "Expected failure: \(message)")
}

struct PresetFixture {
    let fm = FileManager.default
    let base: URL
    let pack: URL
    let receiving: URL
    var libraries: [PresetLibrary]

    init() throws {
        // /tmp and /var are symlinks on macOS. Use an exact disposable workspace
        // directory so production symlink protection remains enabled in tests.
        let testsRoot = ProcessInfo.processInfo.environment["PLUGIN_PORTER_TEST_ROOT"]
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/PluginPorter/Tests").path
        base = URL(fileURLWithPath: testsRoot).appendingPathComponent(".preset-fixture-\(UUID().uuidString)")
        pack = base.appendingPathComponent("購入 Pack")
        receiving = base.appendingPathComponent("receiving-libraries")
        let specs = [("serum1", "Serum", "Presets"), ("serum2", "Serum 2", "Presets/User"), ("vital", "Vital", "Presets"), ("sylenth1", "Sylenth1", "Presets"), ("diva", "Diva", ""), ("hive", "Hive", ""), ("zebra2", "Zebra2", ""), ("zebrahz", "ZebraHZ", "")]
        let receivingRoot = receiving
        libraries = specs.map { PresetLibrary(id: $0.0, name: $0.1, rootPath: receivingRoot.appendingPathComponent($0.0).path, presetFolder: $0.2, detected: true) }
        try fm.createDirectory(at: pack, withIntermediateDirectories: true)
        for library in libraries { try fm.createDirectory(atPath: library.rootPath, withIntermediateDirectories: true) }
    }

    func clean() { try? fm.removeItem(at: base) }

    func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @discardableResult
    func file(_ path: String, _ data: Data) throws -> URL {
        let url = pack.appendingPathComponent(path)
        try write(data, to: url)
        return url
    }

    @discardableResult
    func file(_ path: String, _ text: String = "inert audio fixture") throws -> URL {
        try file(path, Data(text.utf8))
    }

    func library(_ id: String) -> PresetLibrary { libraries.first { $0.id == id }! }

    func target(_ id: String, _ relative: String) -> URL {
        URL(fileURLWithPath: library(id).rootPath).appendingPathComponent(relative)
    }

    func analyze(_ serumTarget: String = "serum1", roots: [URL]? = nil) throws -> PresetImportPlan {
        try PresetOrganizer.analyze(folders: roots ?? [pack], libraries: libraries, serumFXPTarget: serumTarget, progress: { _ in })
    }

    func item(_ plan: PresetImportPlan, _ relative: String) throws -> PresetImportItem {
        guard let item = plan.items.first(where: { $0.sourceRelativePath == relative }) else {
            throw PresetTestFailure(description: "Missing item: \(relative)")
        }
        return item
    }

    func snapshot(_ url: URL) throws -> String { try TransferEngine.fingerprint(url).0 }
}

func fixture(_ body: (PresetFixture) throws -> Void) throws {
    let value = try PresetFixture()
    defer { value.clean() }
    try body(value)
}

func fxp(_ id: String = "XfsX", chunk: String = "FPCh") -> Data {
    var bytes = Data("CcnK".utf8)
    bytes.append(contentsOf: [0, 0, 0, 32])
    bytes.append(Data(chunk.utf8))
    bytes.append(contentsOf: [0, 0, 0, 1])
    bytes.append(Data(id.utf8))
    bytes.append(Data("inert test payload".utf8))
    return bytes
}

func xferEnvelope(_ fileType: String) -> Data {
    let json = Data("{\"fileType\":\"\(fileType)\",\"name\":\"Fixture\"}".utf8)
    var envelope = Data("XferJson".utf8)
    envelope.append(0)
    let length = UInt64(json.count)
    envelope.append(contentsOf: (0..<8).map { UInt8((length >> ($0 * 8)) & 0xff) })
    envelope.append(json)
    return envelope
}

let serum2 = xferEnvelope("SerumPreset")

@main
struct PresetTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("Serum and Sylenth1 FXP headers distinguish identical extensions", {
                try fixture { f in
                    try f.file("Serum/Lead.FXP", fxp())
                    try f.file("Sylenth/Lead.fxp", fxp("syl1"))
                    try f.file("Sylenth/Bank.fxb", fxp("syl1", chunk: "FBCh"))
                    let plan = try f.analyze()
                    try check(plan.items.count == 3, "three files detected")
                    try check(f.item(plan, "Serum/Lead.FXP").detectedTargetID == "serum1", "XfsX identified as Serum")
                    try check(f.item(plan, "Sylenth/Lead.fxp").targetID == "sylenth1", "syl1 identified as Sylenth1")
                    try check(f.item(plan, "Sylenth/Bank.fxb").destinationPath == f.target("sylenth1", "SoundBanks/購入 Pack/Sylenth/Bank.fxb").path, "bank uses SoundBanks")
                }
            }),
            ("Serum 2 mixed-case extension and native header", {
                try fixture { f in
                    try f.file("Presets/Keys/Piano.SeRuMpReSeT", serum2)
                    try f.file("Invalid.serumpreset", "not a Serum preset")
                    let plan = try f.analyze()
                    let good = try f.item(plan, "Presets/Keys/Piano.SeRuMpReSeT")
                    let bad = try f.item(plan, "Invalid.serumpreset")
                    try check(good.selected && good.targetID == "serum2", "native preset auto selected")
                    try check(good.destinationPath == f.target("serum2", "Presets/User/購入 Pack/Keys/Piano.SeRuMpReSeT").path, "Serum 2 path matches pack/category")
                    try check(!bad.selected && bad.kind == "unknown", "invalid header unresolved")
                }
            }),
            ("inconsistent FXP formats and spoofed Xfer metadata are rejected", {
                try fixture { f in
                    try f.file("WrongChunk.fxp", fxp("XfsX", chunk: "FBCh"))
                    try f.file("WrongType.serumpreset", xferEnvelope("SerumFX"))
                    try f.file("PlainMagic.serumpreset", "XferJson SerumPreset")
                    var truncated = serum2
                    truncated.removeLast(3)
                    try f.file("Truncated.serumpreset", truncated)
                    let plan = try f.analyze()
                    try check(plan.items.count == 4, "all candidates visible")
                    try check(plan.items.allSatisfy { $0.kind == "unknown" && !$0.selected && $0.destinationPath == nil }, "all invalid headers unresolved")
                }
            }),
            ("Serum 2 effect and LFO files use verified headers and category paths", {
                try fixture { f in
                    try f.file("Effect Chains/Brand/Delay.serumfx", xferEnvelope("SerumFX"))
                    try f.file("Effect Chains/Brand/Rack.serumfxrack", xferEnvelope("SerumFXRack"))
                    try f.file("LFO Shapes/Brand/Curve.xfershape", xferEnvelope("XferShape"))
                    try f.file("LFO Paths/Brand/Movement.xferpath", xferEnvelope("XferPath"))
                    let plan = try f.analyze()
                    try check(plan.items.count == 4 && plan.items.allSatisfy { $0.targetID == "serum2" && $0.selected }, "all native auxiliaries detected")
                    for item in plan.items {
                        try check(item.destinationPath == f.target("serum2", item.sourceRelativePath).path, "native auxiliary keeps full category suffix")
                        try check(!PresetOrganizer.assign(item, to: f.library("serum1")).selected, "Serum 2 auxiliary cannot target Serum 1")
                    }
                    let report = try PresetOrganizer.install(plan, progress: { _ in })
                    try check(report.completed.count == 4 && report.failed.isEmpty, "native auxiliaries pass install revalidation")
                }
            }),
            ("SFZ multisample definitions copy with samples while generic SFZ is ignored", {
                try fixture { f in
                    try f.file("Presets/Keys.serumpreset", serum2)
                    try f.file("Multisamples/Brand/Keys.sfz", "<region> sample=Notes/C4.wav key=60")
                    try f.file("Multisamples/Brand/Notes/C4.wav")
                    try f.file("Loose.sfz", "<region> sample=somewhere.wav")
                    let plan = try f.analyze()
                    try check(plan.items.count == 3, "only structured SFZ is included")
                    let sfz = try f.item(plan, "Multisamples/Brand/Keys.sfz")
                    let audio = try f.item(plan, "Multisamples/Brand/Notes/C4.wav")
                    try check(sfz.kind == "multisample" && audio.kind == "multisample", "definition and audio share category")
                    try check(sfz.destinationPath == f.target("serum2", "Multisamples/Brand/Keys.sfz").path, "SFZ reference base retained")
                    try check(audio.destinationPath == f.target("serum2", "Multisamples/Brand/Notes/C4.wav").path, "relative SFZ sample reference retained")
                    let report = try PresetOrganizer.install(plan, progress: { _ in })
                    try check(report.completed.count == 3 && report.failed.isEmpty, "all multisample components copied")
                }
            }),
            ("nested input roots deduplicate while preserving category directories", {
                try fixture { f in
                    try f.file("Presets/Bass/Analog/Low.fxp", fxp())
                    try f.file("Presets/Leads/High.fxp", fxp())
                    let plan = try f.analyze(roots: [f.pack.appendingPathComponent("Presets"), f.pack, f.pack])
                    try check(plan.items.count == 2, "parent and nested drop do not duplicate")
                    try check(f.item(plan, "Presets/Bass/Analog/Low.fxp").destinationPath == f.target("serum1", "Presets/購入 Pack/Bass/Analog/Low.fxp").path, "nested categories retained")
                }
            }),
            ("unknown FXP product requires explicit manual assignment", {
                try fixture { f in
                    try f.file("Mystery.fxp", fxp("othr"))
                    let plan = try f.analyze()
                    let original = try f.item(plan, "Mystery.fxp")
                    try check(original.targetID == nil && !original.selected && original.destinationPath == nil, "unknown ID not guessed")
                    let assigned = PresetOrganizer.assign(original, to: f.library("serum1"))
                    try check(assigned.selected && assigned.targetID == "serum1", "explicit assignment enabled")
                    var manual = plan
                    manual.items = [assigned]
                    let report = try PresetOrganizer.install(manual, progress: { _ in })
                    try check(report.completed.count == 1 && report.failed.isEmpty, "manual choice is honored")
                }
            }),
            ("malformed FXP cannot be enabled by manual assignment", {
                try fixture { f in
                    try f.file("Broken.fxp", "invalid")
                    let item = try f.item(f.analyze(), "Broken.fxp")
                    let assigned = PresetOrganizer.assign(item, to: f.library("serum1"))
                    try check(item.kind == "unknown" && !assigned.selected && assigned.destinationPath == nil, "unsupported malformed format remains unresolved")
                }
            }),
            ("u-he AM metadata detects actual synth and rejects incompatible choice", {
                try fixture { f in
                    try f.file("Wrong Hive Folder/Diva.h2p", "#AM=Diva\nfixture=true")
                    try f.file("Hive.h2p", "#AM=Hive\r\nfixture=true")
                    let plan = try f.analyze()
                    let item = try f.item(plan, "Wrong Hive Folder/Diva.h2p")
                    try check(item.targetID == "diva", "content wins over folder names")
                    try check(f.item(plan, "Hive.h2p").targetID == "hive", "CRLF supported")
                    try check(!PresetOrganizer.assign(item, to: f.library("hive")).selected, "wrong u-he target blocked")
                }
            }),
            ("generic audio loops documents and hidden files are not imported", {
                try fixture { f in
                    try f.file("Drum Loops/kick.wav")
                    try f.file("Bass Loop.aiff")
                    try f.file("readme.txt", "read me")
                    try f.file(".hidden.fxp", fxp())
                    try f.file("__MACOSX/Junk.fxp", fxp())
                    try f.file("Instrument.vst3/Contents/Hidden.fxp", fxp())
                    let plan = try f.analyze()
                    try check(plan.items.isEmpty, "no generic files become preset imports")
                    try check(plan.ignoredFileCount == 3, "ordinary audio and documents counted")
                }
            }),
            ("Serum 1 Tables and Noises preserve exact suffix without pack prefix", {
                try fixture { f in
                    try f.file("Presets/Lead.fxp", fxp())
                    try f.file("Tables/Brand/Tables.wav")
                    try f.file("Noises/Brand/Noises.wav")
                    let plan = try f.analyze()
                    try check(f.item(plan, "Tables/Brand/Tables.wav").destinationPath == f.target("serum1", "Tables/Brand/Tables.wav").path, "wavetable reference path preserved")
                    try check(f.item(plan, "Noises/Brand/Noises.wav").destinationPath == f.target("serum1", "Noises/Brand/Noises.wav").path, "noise reference path preserved")
                }
            }),
            ("Serum 2 Samples and Tables preserve exact suffix", {
                try fixture { f in
                    try f.file("Presets/Lead.serumpreset", serum2)
                    try f.file("Samples/Brand/Piano.wav")
                    try f.file("Tables/Brand/Shape.wav")
                    let plan = try f.analyze()
                    try check(f.item(plan, "Samples/Brand/Piano.wav").destinationPath == f.target("serum2", "Samples/Brand/Piano.wav").path, "sample reference path preserved")
                    try check(f.item(plan, "Tables/Brand/Shape.wav").destinationPath == f.target("serum2", "Tables/Brand/Shape.wav").path, "wavetable reference path preserved")
                }
            }),
            ("Serum 2 nested Noises within Samples remains a Samples path", {
                try fixture { f in
                    try f.file("Presets/Lead.serumpreset", serum2)
                    try f.file("Samples/Factory Non-Tonal/Noises/Texture.wav")
                    let item = try f.item(f.analyze(), "Samples/Factory Non-Tonal/Noises/Texture.wav")
                    try check(item.kind == "sample" && item.selected, "Noises content folder does not override Samples category")
                    try check(item.destinationPath == f.target("serum2", "Samples/Factory Non-Tonal/Noises/Texture.wav").path, "full Samples suffix retained")
                }
            }),
            ("Serum 1 noise stays unresolved when FXP is targeted to Serum 2", {
                try fixture { f in
                    try f.file("Presets/Lead.fxp", fxp())
                    try f.file("Noises/Brand/Texture.wav")
                    let plan = try f.analyze("serum2")
                    try check(f.item(plan, "Presets/Lead.fxp").targetID == "serum2", "FXP directed to Serum 2")
                    let noise = try f.item(plan, "Noises/Brand/Texture.wav")
                    try check(!noise.selected && noise.destinationPath == nil, "noise is not guessed into Samples")
                    try check(PresetOrganizer.assign(noise, to: f.library("serum1")).selected, "explicit original Serum 1 target remains available")
                }
            }),
            ("analysis does not mutate sources or receiving libraries", {
                try fixture { f in
                    try f.file("Presets/Lead.fxp", fxp())
                    try f.file("Noises/Brand/Texture.wav")
                    let source = try f.snapshot(f.pack)
                    let target = try f.snapshot(f.receiving)
                    let plan = try f.analyze()
                    try check(plan.items.count == 2, "analysis produces both items")
                    try check(f.snapshot(f.pack) == source, "source unchanged")
                    try check(f.snapshot(f.receiving) == target, "destination unchanged before install")
                }
            }),
            ("copy roundtrip preserves nested pack paths and sources", {
                try fixture { f in
                    try f.file("Presets/Keys/Piano.serumpreset", serum2)
                    try f.file("Samples/Brand/Sample.wav")
                    let before = try f.snapshot(f.pack)
                    let plan = try f.analyze()
                    let planURL = f.base.appendingPathComponent("reviewed-plan.json")
                    try PresetOrganizer.savePlan(plan, to: planURL)
                    let loaded = try PresetOrganizer.loadPlan(at: planURL)
                    try check(loaded.items.count == 2 && loaded.items.map(\.destinationPath) == plan.items.map(\.destinationPath), "saved plan restores exact destinations")
                    let report = try PresetOrganizer.install(loaded, progress: { _ in })
                    try check(report.completed.count == 2 && report.failed.isEmpty && report.skipped.isEmpty, "all files copied")
                    for item in loaded.items {
                        try check(Data(contentsOf: URL(fileURLWithPath: item.sourcePath)) == Data(contentsOf: URL(fileURLWithPath: item.destinationPath!)), "copied bytes equal originals")
                    }
                    try check(f.snapshot(f.pack) == before, "original pack preserved")
                }
            }),
            ("identical duplicates and conflicting contents both skip and report", {
                try fixture { f in
                    try f.file("Same.fxp", fxp())
                    try f.file("Conflict.fxp", fxp())
                    let plan = try f.analyze()
                    for item in plan.items {
                        let target = URL(fileURLWithPath: item.destinationPath!)
                        try f.write(item.sourceRelativePath == "Same.fxp" ? fxp() : Data("existing user preset".utf8), to: target)
                    }
                    let beforeSources = try f.snapshot(f.pack)
                    let beforeTargets = try f.snapshot(f.receiving)
                    let report = try PresetOrganizer.install(plan, progress: { _ in })
                    try check(report.completed.isEmpty && report.failed.isEmpty && report.skipped.count == 2, "both existing files skipped")
                    try check(report.skipped.contains(where: { $0.contains("同一ファイル") }), "identical content reported")
                    try check(report.skipped.contains(where: { $0.contains("同名・内容違い") }), "conflicting content reported")
                    try check(f.snapshot(f.pack) == beforeSources && f.snapshot(f.receiving) == beforeTargets, "all sources and existing targets unchanged")
                }
            }),
            ("later tampered destination aborts entire plan before any writes", {
                try fixture { f in
                    try f.file("A.fxp", fxp())
                    try f.file("Z.fxp", fxp())
                    var plan = try f.analyze()
                    let before = try f.snapshot(f.receiving)
                    plan.items[1].destinationPath = f.receiving.appendingPathComponent("../escaped.fxp").path
                    try mustThrow("tampered destination") { _ = try PresetOrganizer.install(plan, progress: { _ in }) }
                    try check(f.snapshot(f.receiving) == before, "first valid item also not installed")
                    try check(!f.fm.fileExists(atPath: f.base.appendingPathComponent("escaped.fxp").path), "no escaped destination created")
                }
            }),
            ("relative traversal in tampered plan is rejected", {
                try fixture { f in
                    try f.file("Lead.fxp", fxp())
                    var plan = try f.analyze()
                    let before = try f.snapshot(f.receiving)
                    plan.items[0].sourceRelativePath = "../Lead.fxp"
                    try mustThrow("relative source traversal") { _ = try PresetOrganizer.install(plan, progress: { _ in }) }
                    try check(f.snapshot(f.receiving) == before, "no destination changes")
                }
            }),
            ("source links and linked directories are ignored during analysis", {
                try fixture { f in
                    let external = f.base.appendingPathComponent("external/Outside.fxp")
                    try f.write(fxp(), to: external)
                    try f.fm.createSymbolicLink(at: f.pack.appendingPathComponent("Link.fxp"), withDestinationURL: external)
                    try f.fm.createSymbolicLink(at: f.pack.appendingPathComponent("linked-folder"), withDestinationURL: external.deletingLastPathComponent())
                    let plan = try f.analyze()
                    try check(plan.items.isEmpty, "linked files and subtrees not followed")
                    try check(plan.ignoredFileCount == 2, "both links counted as ignored")
                    try mustThrow("selected pack root must be real directory") {
                        _ = try f.analyze(roots: [f.pack.appendingPathComponent("linked-folder")])
                    }
                }
            }),
            ("source changed to symlink after analysis aborts without writes", {
                try fixture { f in
                    let source = try f.file("Lead.fxp", fxp())
                    let plan = try f.analyze()
                    let external = f.base.appendingPathComponent("external.fxp")
                    try f.write(fxp(), to: external)
                    try f.fm.removeItem(at: source)
                    try f.fm.createSymbolicLink(at: source, withDestinationURL: external)
                    let before = try f.snapshot(f.receiving)
                    try mustThrow("source replaced with symlink") { _ = try PresetOrganizer.install(plan, progress: { _ in }) }
                    try check(f.snapshot(f.receiving) == before, "no destination created")
                    try check(Data(contentsOf: external) == fxp(), "external source unchanged")
                }
            }),
            ("destination directory redirection is blocked before writes", {
                try fixture { f in
                    try f.file("Lead.fxp", fxp())
                    let plan = try f.analyze()
                    let outside = f.base.appendingPathComponent("outside-target")
                    try f.fm.createDirectory(at: outside, withIntermediateDirectories: true)
                    try f.fm.createSymbolicLink(at: f.target("serum1", "Presets"), withDestinationURL: outside)
                    let before = try f.snapshot(outside)
                    try mustThrow("destination directory symlink") { _ = try PresetOrganizer.install(plan, progress: { _ in }) }
                    try check(f.snapshot(outside) == before, "redirected destination untouched")
                }
            }),
            ("destination file symlink is not followed or overwritten", {
                try fixture { f in
                    try f.file("Lead.fxp", fxp())
                    let plan = try f.analyze()
                    let target = URL(fileURLWithPath: plan.items[0].destinationPath!)
                    let outside = f.base.appendingPathComponent("outside.fxp")
                    try f.write(Data("keep external".utf8), to: outside)
                    try f.fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try f.fm.createSymbolicLink(at: target, withDestinationURL: outside)
                    try mustThrow("destination file symlink") { _ = try PresetOrganizer.install(plan, progress: { _ in }) }
                    try check(String(contentsOf: outside, encoding: .utf8) == "keep external", "external contents preserved")
                }
            }),
            ("missing library root leaves recognized files unresolved", {
                try fixture { original in
                    var f = original
                    try f.file("Lead.fxp", fxp())
                    let index = f.libraries.firstIndex { $0.id == "serum1" }!
                    try f.fm.removeItem(atPath: f.libraries[index].rootPath)
                    f.libraries[index].detected = false
                    let plan = try f.analyze()
                    let item = try f.item(plan, "Lead.fxp")
                    try check(item.detectedTargetID == "serum1" && !item.selected && item.destinationPath == nil, "recognized but no root guessed")
                    try check(!f.fm.fileExists(atPath: f.libraries[index].rootPath), "analysis did not create missing root")
                    try mustThrow("no unresolved items installed") { _ = try PresetOrganizer.install(plan, progress: { _ in }) }
                }
            }),
            ("install inside source pack is rejected", {
                try fixture { original in
                    var f = original
                    try f.file("Lead.fxp", fxp())
                    let inside = f.pack.appendingPathComponent("SerumLibrary")
                    try f.fm.createDirectory(at: inside, withIntermediateDirectories: true)
                    let index = f.libraries.firstIndex { $0.id == "serum1" }!
                    var plan = try f.analyze()
                    f.libraries[index].rootPath = inside.path
                    plan.libraries = f.libraries
                    plan.items[0] = PresetOrganizer.assign(plan.items[0], to: f.libraries[index])
                    let before = try f.snapshot(f.pack)
                    try mustThrow("analysis rejects a library in the source pack") { _ = try f.analyze() }
                    try mustThrow("library contained in original pack") { _ = try PresetOrganizer.install(plan, progress: { _ in }) }
                    try check(f.snapshot(f.pack) == before, "source pack remains unchanged")
                }
            }),
            ("another input pack is protected even when its items are unselected", {
                try fixture { f in
                    try f.file("A.h2p", "#AM=Diva\nfixture")
                    try f.file("Z.fxp", fxp())
                    let otherPack = f.base.appendingPathComponent("Other Pack")
                    try f.write(Data("#AM=Hive\nkeep original".utf8), to: otherPack.appendingPathComponent("Keep.h2p"))
                    var plan = try f.analyze(roots: [f.pack, otherPack])
                    let index = plan.libraries.firstIndex { $0.id == "serum1" }!
                    plan.libraries[index].rootPath = otherPack.path
                    for row in plan.items.indices {
                        if plan.items[row].targetID == "serum1" {
                            plan.items[row] = PresetOrganizer.assign(plan.items[row], to: plan.libraries[index])
                        }
                        if plan.items[row].sourceRoot == otherPack.path { plan.items[row].selected = false }
                    }
                    let beforeSource = try f.snapshot(f.pack)
                    let beforeOther = try f.snapshot(otherPack)
                    let beforeReceiving = try f.snapshot(f.receiving)
                    try mustThrow("a selected destination is inside another unselected source pack") {
                        _ = try PresetOrganizer.install(plan, progress: { _ in })
                    }
                    try check(f.snapshot(f.pack) == beforeSource && f.snapshot(otherPack) == beforeOther, "both original input packs remain unchanged")
                    try check(f.snapshot(f.receiving) == beforeReceiving, "safe earlier item is not copied before preflight fails")
                }
            }),
            ("analysis protects an input pack with no recognized files", {
                try fixture { original in
                    var f = original
                    try f.file("Lead.fxp", fxp())
                    let otherPack = f.base.appendingPathComponent("Documents Only Pack")
                    try f.write(Data("keep original".utf8), to: otherPack.appendingPathComponent("README.txt"))
                    let index = f.libraries.firstIndex { $0.id == "serum1" }!
                    f.libraries[index].rootPath = otherPack.path
                    let before = try f.snapshot(otherPack)
                    try mustThrow("destination is within another input without any plan items") {
                        _ = try f.analyze(roots: [f.pack, otherPack])
                    }
                    try check(f.snapshot(otherPack) == before, "ignored-only input pack remains unchanged")
                }
            }),
            ("saved plans retain ignored-only input roots after library reassignment", {
                try fixture { f in
                    try f.file("Lead.fxp", fxp())
                    let otherPack = f.base.appendingPathComponent("Documents Only Pack")
                    try f.write(Data("keep original".utf8), to: otherPack.appendingPathComponent("README.txt"))
                    let original = try f.analyze(roots: [f.pack, otherPack])
                    let planURL = f.base.appendingPathComponent("reviewed-plan.json")
                    try PresetOrganizer.savePlan(original, to: planURL)
                    var plan = try PresetOrganizer.loadPlan(at: planURL)
                    try check(Set(plan.sourceRoots ?? []) == Set([f.pack.path, otherPack.path]), "all original input roots survive saving and loading")
                    let index = plan.libraries.firstIndex { $0.id == "serum1" }!
                    plan.libraries[index].rootPath = otherPack.path
                    plan.items[0] = PresetOrganizer.assign(plan.items[0], to: plan.libraries[index])
                    let before = try f.snapshot(otherPack)
                    try mustThrow("a library reassigned into an ignored-only source root") {
                        _ = try PresetOrganizer.install(plan, progress: { _ in })
                    }
                    try check(f.snapshot(otherPack) == before, "ignored-only original remains unchanged after reassignment")
                }
            }),
            ("legacy plans without sourceRoots still decode and install", {
                try fixture { f in
                    try f.file("Lead.fxp", fxp())
                    let original = try f.analyze()
                    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
                    object.removeValue(forKey: "sourceRoots")
                    let planURL = f.base.appendingPathComponent("legacy-plan.json")
                    try JSONSerialization.data(withJSONObject: object).write(to: planURL)
                    let plan = try PresetOrganizer.loadPlan(at: planURL)
                    try check(plan.sourceRoots == nil && plan.items.count == 1, "legacy plan decodes without the optional field")
                    let report = try PresetOrganizer.install(plan, progress: { _ in })
                    try check(report.completed.count == 1 && report.failed.isEmpty, "legacy plan retains existing valid install behavior")
                }
            })
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS \(name)") }
            catch { failures += 1; fputs("FAIL \(name): \(error)\n", stderr) }
        }
        print("\(tests.count - failures)/\(tests.count) preset test groups passed")
        exit(failures == 0 ? 0 : 1)
    }
}
