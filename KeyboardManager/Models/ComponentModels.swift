import Foundation

struct KeycapSet: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var manufacturer: String
    var profile: String
    var material: String
    var status: String
    var kits: [String]
    var sourceURL: String
    var sourceShop: String
    var mountedBoardID: String?
    var notes: String
    var photoIDs: [String]
    var mainPhotoID: String?
    var coverURL: String
    var externalImageURLs: [String]
    var trelloCardID: String
    var trelloListName: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "",
        manufacturer: String = "",
        profile: String = "",
        material: String = "",
        status: String = "owned",
        kits: [String] = [],
        sourceURL: String = "",
        sourceShop: String = "",
        mountedBoardID: String? = nil,
        notes: String = "",
        photoIDs: [String] = [],
        mainPhotoID: String? = nil,
        coverURL: String = "",
        externalImageURLs: [String] = [],
        trelloCardID: String = "",
        trelloListName: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.profile = profile
        self.material = material
        self.status = status
        self.kits = kits
        self.sourceURL = sourceURL
        self.sourceShop = sourceShop
        self.mountedBoardID = mountedBoardID
        self.notes = notes
        self.photoIDs = photoIDs
        self.mainPhotoID = mainPhotoID
        self.coverURL = coverURL
        self.externalImageURLs = externalImageURLs
        self.trelloCardID = trelloCardID
        self.trelloListName = trelloListName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ArtisanSet: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var manufacturer: String
    var profile: String
    var material: String
    var status: String
    var tags: [String]
    var sourceURL: String
    var sourceShop: String
    var mountedBoardID: String?
    var notes: String
    var photoIDs: [String]
    var mainPhotoID: String?
    var coverURL: String
    var externalImageURLs: [String]
    var trelloCardID: String
    var trelloListName: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "",
        manufacturer: String = "",
        profile: String = "",
        material: String = "",
        status: String = "owned",
        tags: [String] = [],
        sourceURL: String = "",
        sourceShop: String = "",
        mountedBoardID: String? = nil,
        notes: String = "",
        photoIDs: [String] = [],
        mainPhotoID: String? = nil,
        coverURL: String = "",
        externalImageURLs: [String] = [],
        trelloCardID: String = "",
        trelloListName: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.profile = profile
        self.material = material
        self.status = status
        self.tags = tags
        self.sourceURL = sourceURL
        self.sourceShop = sourceShop
        self.mountedBoardID = mountedBoardID
        self.notes = notes
        self.photoIDs = photoIDs
        self.mainPhotoID = mainPhotoID
        self.coverURL = coverURL
        self.externalImageURLs = externalImageURLs
        self.trelloCardID = trelloCardID
        self.trelloListName = trelloListName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ImportedBoardAllocation: Codable, Hashable, Sendable {
    var boardName: String
    var quantity: Int
    var inferred: Bool
}

struct SwitchSet: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var switchType: String
    var topHousingMaterial: String
    var bottomHousingMaterial: String
    var stemMaterial: String
    var springLength: String
    var springType: String
    var preTravel: String
    var totalTravel: String
    var operatingForce: String
    var bottomOutForce: String
    var pins: SwitchPins
    var hasLEDDiffuser: Bool
    var isFactoryLubed: Bool
    var quantity: Int
    var importedBoardText: String
    var importedBoardAllocations: [ImportedBoardAllocation]
    var importSource: String
    var importRow: Int
    var importKey: String
    var importWarnings: [String]
    var notes: String
    var photoIDs: [String]
    var mainPhotoID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "",
        switchType: String = "",
        topHousingMaterial: String = "",
        bottomHousingMaterial: String = "",
        stemMaterial: String = "",
        springLength: String = "",
        springType: String = "",
        preTravel: String = "",
        totalTravel: String = "",
        operatingForce: String = "",
        bottomOutForce: String = "",
        pins: SwitchPins = .five,
        hasLEDDiffuser: Bool = false,
        isFactoryLubed: Bool = false,
        quantity: Int = 0,
        importedBoardText: String = "",
        importedBoardAllocations: [ImportedBoardAllocation] = [],
        importSource: String = "",
        importRow: Int = 0,
        importKey: String = "",
        importWarnings: [String] = [],
        notes: String = "",
        photoIDs: [String] = [],
        mainPhotoID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.switchType = switchType
        self.topHousingMaterial = topHousingMaterial
        self.bottomHousingMaterial = bottomHousingMaterial
        self.stemMaterial = stemMaterial
        self.springLength = springLength
        self.springType = springType
        self.preTravel = preTravel
        self.totalTravel = totalTravel
        self.operatingForce = operatingForce
        self.bottomOutForce = bottomOutForce
        self.pins = pins
        self.hasLEDDiffuser = hasLEDDiffuser
        self.isFactoryLubed = isFactoryLubed
        self.quantity = max(quantity, 0)
        self.importedBoardText = importedBoardText
        self.importedBoardAllocations = importedBoardAllocations
        self.importSource = importSource
        self.importRow = max(importRow, 0)
        self.importKey = importKey
        self.importWarnings = importWarnings
        self.notes = notes
        self.photoIDs = photoIDs
        self.mainPhotoID = mainPhotoID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func installedQuantity(in installations: [SwitchInstallation]) -> Int {
        installations
            .filter { $0.switchSetID == id }
            .reduce(0) { $0 + max($1.quantity, 0) }
    }

    func availableQuantity(in installations: [SwitchInstallation]) -> Int {
        max(quantity - installedQuantity(in: installations), 0)
    }
}

struct SwitchInstallation: Identifiable, Codable, Hashable, Sendable {
    var switchSetID: String
    var boardID: String
    var quantity: Int

    var id: String { "\(switchSetID)::\(boardID)" }

    init(switchSetID: String, boardID: String, quantity: Int) {
        self.switchSetID = switchSetID
        self.boardID = boardID
        self.quantity = max(quantity, 0)
    }
}
