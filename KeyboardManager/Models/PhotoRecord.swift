import Foundation

enum PhotoOwnerType: String, Codable, CaseIterable, Hashable, Sendable {
    case board
    case keycapSet
    case artisanSet
    case switchSet
}

struct PhotoOwner: Codable, Hashable, Sendable {
    var type: PhotoOwnerType
    var id: String
}

enum PhotoMIMEType: String, Codable, CaseIterable, Hashable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case webP = "image/webp"
    case gif = "image/gif"
    case heic = "image/heic"

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .webP: "webp"
        case .gif: "gif"
        case .heic: "heic"
        }
    }
}

struct PhotoRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var owner: PhotoOwner
    var originalName: String
    var mimeType: PhotoMIMEType
    var pixelWidth: Int?
    var pixelHeight: Int?
    var addedAt: Date
    var relativeFileName: String

    /// The file name within V2's managed `Current/Photos` directory.
    ///
    /// Phase-1 imports stored an otherwise valid V1 path with a `Photos/`
    /// prefix. Accept that one legacy representation while keeping all callers
    /// confined to the managed photo directory.
    var managedFileName: String? {
        let components = relativeFileName.split(separator: "/", omittingEmptySubsequences: false)
        let fileName: String
        switch components.count {
        case 1:
            fileName = String(components[0])
        case 2 where components[0] == "Photos":
            fileName = String(components[1])
        default:
            return nil
        }

        guard fileName == "\(id).\(mimeType.fileExtension)",
              URL(fileURLWithPath: fileName).lastPathComponent == fileName,
              !fileName.contains("\\") else {
            return nil
        }
        return fileName
    }
}
