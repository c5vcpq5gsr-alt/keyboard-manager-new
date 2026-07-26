import Foundation

struct Board: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var manufacturer: String
    var format: String
    var plate: String
    var pcb: String
    var stabilizers: String
    var remark: String

    // V1 compatibility fields remain until migration has resolved relations.
    var legacyKeycapsName: String
    var keycapSetID: String?
    var legacySwitchesName: String

    var photoIDs: [String]
    var mainPhotoID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "",
        manufacturer: String = "",
        format: String = "",
        plate: String = "",
        pcb: String = "",
        stabilizers: String = "",
        remark: String = "",
        legacyKeycapsName: String = "",
        keycapSetID: String? = nil,
        legacySwitchesName: String = "",
        photoIDs: [String] = [],
        mainPhotoID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.format = format
        self.plate = plate
        self.pcb = pcb
        self.stabilizers = stabilizers
        self.remark = remark
        self.legacyKeycapsName = legacyKeycapsName
        self.keycapSetID = keycapSetID
        self.legacySwitchesName = legacySwitchesName
        self.photoIDs = photoIDs
        self.mainPhotoID = mainPhotoID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var hasValidMainPhoto: Bool {
        guard let mainPhotoID else { return true }
        return photoIDs.contains(mainPhotoID)
    }
}
