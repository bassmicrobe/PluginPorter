import Foundation
import Darwin

func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

func jsonWrite<T: Encodable>(_ value: T, path: String?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    if let path = path { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    else { FileHandle.standardOutput.write(data); print("") }
}

let help = """
PluginPorter 1.2 — Macのプラグインをコピーで移行・プリセット整理

pluginporter scan [--include-data] [--match TEXT] [--output PLAN.json]
pluginporter export NEW.pluginporter [--plan PLAN.json] [--match TEXT]
pluginporter inspect PACKAGE.pluginporter
pluginporter verify PACKAGE.pluginporter
pluginporter restore PACKAGE.pluginporter --home /Users/USER [--ids ID,ID] [--dry-run] [--report RESULT.json]
pluginporter preset-plan FOLDER [FOLDER ...] [--serum-target serum1|serum2] --output PLAN.json
pluginporter preset-install PLAN.json [--report RESULT.json]

scan: AU / VST / VST3 / AAXを一覧化。--include-data は関連フォルダ候補も含めます。
export: --plan省略時はプラグイン本体のみ。既存パッケージへの追記・上書きはしません。
        関連データを移す場合、scanのJSONを編集して不要項目を削除し --plan で指定。
inspect: パッケージの一覧・移行元OS・注意点を表示。
verify: SHA-256でパッケージ内の全項目を検証。
restore: 元と同じ区分・相対パスに復元。既存項目は常にスキップ。
         --dry-run は保存先だけを表示（検証・コピーを実行しません）。
         システム領域の復元には sudo が必要です。--home は移行先の一般ユーザー。
         外部フォルダは --home 内の Music/PluginPorter Libraries/ に復元。
preset-plan: 解凍済みパックから対応プリセットと付属素材を解析。コピーしません。
preset-install: 整理プランで選択した項目をコピー。既存ファイルは上書きしません。

ライセンス認証、ドライバ・常駐サービスのインストールは別途必要です。
メーカー管理アプリの登録や全製品の動作は保証しません。自分で作成したパッケージを使用してください。
"""

func cli(_ args: [String]) throws -> Int32 {
    guard let command = args.first, command != "--help", command != "help" else { print(help); return 0 }
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags = Set<String>()
    let valueOptions: Set<String> = ["--home", "--ids", "--report", "--plan", "--output", "--match", "--serum-target"]
    let flagOptions: Set<String> = ["--include-data", "--dry-run"]
    var i = 1
    while i < args.count {
        let arg = args[i]
        if valueOptions.contains(arg) {
            guard i + 1 < args.count else { throw porterFail("引数が不足しています: \(arg)") }
            options[arg] = args[i + 1]; i += 2
        } else if flagOptions.contains(arg) { flags.insert(arg); i += 1 }
        else if arg.hasPrefix("--") { throw porterFail("不明なオプション: \(arg)") }
        else { positionals.append(arg); i += 1 }
    }
    let home = options["--home"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    func package() throws -> URL {
        guard positionals.count == 1 else { throw porterFail("パッケージのパスを1つ指定してください。") }
        return URL(fileURLWithPath: positionals[0])
    }
    func matching(_ items: [TransferItem]) -> [TransferItem] {
        guard let text = options["--match"], !text.isEmpty else { return items }
        return items.filter { ($0.name + " " + $0.sourcePath).localizedCaseInsensitiveContains(text) }
    }
    switch command {
    case "preset-plan":
        guard !positionals.isEmpty, let output = options["--output"] else { throw porterFail("パックフォルダと --output PLAN.json を指定してください。") }
        let libraries = PresetOrganizer.defaultLibraries(home: home)
        let plan = try PresetOrganizer.analyze(folders: positionals.map { URL(fileURLWithPath: $0) }, libraries: libraries, serumFXPTarget: options["--serum-target"] ?? "serum1", progress: log)
        try PresetOrganizer.savePlan(plan, to: URL(fileURLWithPath: output))
        log("\(plan.items.count) 項目を解析、\(plan.items.filter(\.selected).count) 項目が保存可能。まだコピーしていません。")
    case "preset-install":
        let plan = try PresetOrganizer.loadPlan(at: package())
        let report = try PresetOrganizer.install(plan, progress: log)
        try jsonWrite(report, path: options["--report"])
        return report.failed.isEmpty ? 0 : 2
    case "scan":
        guard positionals.isEmpty else { throw porterFail("scanに位置引数は不要です。") }
        let items = matching(try Inventory.scan(home: home, includeData: flags.contains("--include-data")))
        try jsonWrite(items, path: options["--output"])
        log("\(items.count) 項目、論理サイズ合計 \(formattedBytes(items.reduce(0) { $0 + $1.bytes }))。一覧には認証情報の内容を含めません。")
    case "export":
        let destination = try package()
        let items: [TransferItem]
        if let plan = options["--plan"] {
            items = matching(try JSONDecoder().decode([TransferItem].self, from: Data(contentsOf: URL(fileURLWithPath: plan))))
        } else {
            let scanned = matching(try Inventory.scan(home: home, includeData: false))
            for blocked in scanned where blocked.exportBlockReason != nil {
                log("書き出し除外: \(blocked.name) — \(blocked.exportBlockReason!)")
            }
            items = scanned.filter { $0.exportBlockReason == nil }
        }
        let result = try TransferEngine.export(items: items, to: destination, progress: log)
        print("書き出し完了: \(result.entries.count) 項目 → \(destination.path)")
    case "inspect":
        let manifest = try TransferEngine.readManifest(at: package())
        print("作成日時: \(manifest.createdAt)\n移行元: \(manifest.sourceOS) / \(manifest.sourceArchitecture)\n項目数: \(manifest.entries.count)")
        for entry in manifest.entries {
            let item = entry.item
            print("\(item.id)  [\(item.kind)] \(item.name)  \(formattedBytes(item.bytes))  \(item.architectures.joined(separator: ","))\n  \(item.scope)/\(item.relativePath)")
            for note in item.notes { print("  注意: \(note)") }
        }
    case "verify": try TransferEngine.verify(at: package(), progress: log)
    case "restore":
        let archive = try package()
        guard options["--home"] != nil else { throw porterFail("restoreには --home /Users/移行先ユーザー を必ず指定してください。") }
        let ids = options["--ids"].map { Set($0.split(separator: ",").map(String.init)) }
        if flags.contains("--dry-run") {
            let manifest = try TransferEngine.readManifest(at: archive)
            let known = Set(manifest.entries.map { $0.item.id })
            if let ids = ids, !ids.isSubset(of: known) { throw porterFail("パッケージに存在しない項目IDです。") }
            for entry in manifest.entries where ids == nil || ids!.contains(entry.item.id) {
                let target = try scopeRoot(entry.item.scope, home: home).appendingPathComponent(entry.item.relativePath)
                let action = TransferEngine.exists(target) ? "SKIP（既存）" : "COPY"
                print("\(action)  \(entry.item.name) → \(target.path)")
            }
            print("確認のみ。ファイルは変更していません。内容検証は verify を実行してください。")
        } else {
            let report = try TransferEngine.restore(from: archive, home: home, selectedIDs: ids, progress: log)
            try jsonWrite(report, path: options["--report"])
            return report.failed.isEmpty ? 0 : 2
        }
    default: throw porterFail("不明なコマンド: \(command)\n\(help)")
    }
    return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--cli" {
    do { exit(try cli(Array(arguments.dropFirst()))) }
    catch { log("エラー: \(error.localizedDescription)"); exit(1) }
} else if !arguments.isEmpty && !arguments[0].hasPrefix("-psn_") {
    do { exit(try cli(arguments)) }
    catch { log("エラー: \(error.localizedDescription)"); exit(1) }
} else { runGUI() }
