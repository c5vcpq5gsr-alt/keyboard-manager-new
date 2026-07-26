import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ThumbnailService {
    static let maximumPixelSize = 640
    static let memoryEntryLimit = 128

    private let layout: MigrationStorageLayout
    private let fileManager: FileManager
    private var memoryCache: [String: Data] = [:]

    init(layout: MigrationStorageLayout = .default, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    func thumbnailData(for record: PhotoRecord) -> Data? {
        if let data = memoryCache[record.id] {
            return data
        }

        guard let sourceURL = safeSourceURL(for: record),
              let cacheURL = safeCacheURL(for: record) else {
            return nil
        }

        if let cached = try? Data(contentsOf: cacheURL, options: [.mappedIfSafe]) {
            remember(cached, for: record.id)
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        let data = mutableData as Data
        do {
            try fileManager.createDirectory(
                at: layout.currentThumbnailsDirectoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            return nil
        }
        remember(data, for: record.id)
        return data
    }

    func remove(_ records: [PhotoRecord]) {
        for record in records {
            memoryCache.removeValue(forKey: record.id)
            guard let url = safeCacheURL(for: record) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func remember(_ data: Data, for id: String) {
        if memoryCache.count >= Self.memoryEntryLimit,
           let firstKey = memoryCache.keys.first {
            memoryCache.removeValue(forKey: firstKey)
        }
        memoryCache[id] = data
    }

    private func safeSourceURL(for record: PhotoRecord) -> URL? {
        guard let fileName = record.managedFileName, isSafeFileName(fileName) else { return nil }
        return layout.currentPhotosDirectoryURL.appendingPathComponent(fileName)
    }

    private func safeCacheURL(for record: PhotoRecord) -> URL? {
        guard !record.id.isEmpty,
              record.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        return layout.currentThumbnailsDirectoryURL.appendingPathComponent("\(record.id).jpg")
    }

    private func isSafeFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && URL(fileURLWithPath: fileName).lastPathComponent == fileName
            && !fileName.contains("/")
    }
}
