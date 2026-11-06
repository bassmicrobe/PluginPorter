import Foundation

struct PresetLibrary: Codable, Identifiable {
    var id: String
    var name: String
    var rootPath: String
    var presetFolder: String
    var detected: Bool
}

struct PresetImportItem: Codable, Identifiable {
    var id: String
    var sourcePath: String
    var sourceRoot: String
    var packName: String
    var sourceRelativePath: String
    // preset, wavetable, noise, sample, multisample, lfo, effect, shape, path, unknown
    var kind: String
    var detectedTargetID: String?
    var targetID: String?
    var destinationPath: String?
    var bytes: Int64
    var reason: String
    var selected: Bool
}

struct PresetImportPlan: Codable {
    var formatVersion: Int
    var createdAt: String
    var libraries: [PresetLibrary]
    var items: [PresetImportItem]
    var ignoredFileCount: Int
    var notes: [String]
}

// API implemented in PresetEngine.swift:
// PresetOrganizer.defaultLibraries(home: URL) -> [PresetLibrary]
// PresetOrganizer.analyze(folders: [URL], libraries: [PresetLibrary], serumFXPTarget: String, progress: (String) -> Void) throws -> PresetImportPlan
// PresetOrganizer.assign(_ item: PresetImportItem, to library: PresetLibrary) -> PresetImportItem
// PresetOrganizer.install(_ plan: PresetImportPlan, progress: (String) -> Void) throws -> TransferReport
// PresetOrganizer.savePlan(_ plan: PresetImportPlan, to url: URL) throws
// PresetOrganizer.loadPlan(at url: URL) throws -> PresetImportPlan
// The install engine copies only selected files, skips existing paths and never deletes sources.
