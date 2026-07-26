import Foundation

struct AppMetadata: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var createdAt: Date
    var updatedAt: Date
    var preferredLanguage: String

    static let empty = AppMetadata(
        schemaVersion: 1,
        createdAt: .now,
        updatedAt: .now,
        preferredLanguage: "de"
    )
}

struct LibraryValues: Codable, Hashable, Sendable {
    var valuesByKey: [String: [String]]

    static let empty = LibraryValues(valuesByKey: [:])
}

struct InventoryCounts: Codable, Hashable, Sendable {
    var boards: Int
    var keycapSets: Int
    var artisanSets: Int
    var switchSets: Int
    var photos: Int

    var totalItems: Int { boards + keycapSets + artisanSets + switchSets }

    func value(for kind: InventoryItemKind) -> Int {
        switch kind {
        case .board: boards
        case .keycapSet: keycapSets
        case .artisanSet: artisanSets
        case .switchSet: switchSets
        }
    }
}

struct InventorySnapshot: Codable, Hashable, Sendable {
    var metadata: AppMetadata
    var libraryValues: LibraryValues
    var boards: [Board]
    var keycapSets: [KeycapSet]
    var artisanSets: [ArtisanSet]
    var switchSets: [SwitchSet]
    var switchInstallations: [SwitchInstallation]
    var photos: [PhotoRecord]

    static let empty = InventorySnapshot(
        metadata: .empty,
        libraryValues: .empty,
        boards: [],
        keycapSets: [],
        artisanSets: [],
        switchSets: [],
        switchInstallations: [],
        photos: []
    )

    var counts: InventoryCounts {
        InventoryCounts(
            boards: boards.count,
            keycapSets: keycapSets.count,
            artisanSets: artisanSets.count,
            switchSets: switchSets.count,
            photos: photos.count
        )
    }
}
