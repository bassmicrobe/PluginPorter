import Foundation

// The CLI tests exercise argument handling without reading the host's plug-ins.
enum Inventory {
    static func scan(home: URL, includeData: Bool) throws -> [TransferItem] {
        try JSONDecoder().decode([TransferItem].self, from: Data(contentsOf: home.appendingPathComponent("inventory-fixture.json")))
    }
}
