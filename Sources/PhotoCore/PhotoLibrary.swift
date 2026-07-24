import Foundation

public enum PhotoKind: String, Codable, Sendable {
    case jpeg = "JPEG"
    case heic = "HEIC"
    case png = "PNG"
    case tiff = "TIFF"
    case raw = "RAW"

    public static func detect(url: URL) -> PhotoKind? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        case "png": .png
        case "tif", "tiff": .tiff
        case "rw2", "raw", "dng", "arw", "cr2", "cr3", "nef", "orf", "raf": .raw
        default: nil
        }
    }
}

public struct PhotoAsset: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let kind: PhotoKind

    public init(url: URL, kind: PhotoKind) {
        self.url = url
        self.kind = kind
        id = url.standardizedFileURL.path
    }

    public var filename: String { url.lastPathComponent }
}

public enum PhotoLibrary {
    private static let generatedDirectoryNames: Set<String> = [
        "exports", ".photobench", "dist", ".build"
    ]

    public static func scan(root: URL) throws -> [PhotoAsset] {
        // A cancelled folder switch must not start a new filesystem/TCC open.
        try Task.checkCancellation()

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        let keySet = Set(keys)
        let standardizedRoot = root.standardizedFileURL
        var rootReadError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { failedURL, error in
                if failedURL.standardizedFileURL == standardizedRoot {
                    rootReadError = error
                    return false
                }
                // An unreadable child album must not hide all readable photos.
                return true
            }
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var assets: [PhotoAsset] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: keySet)
            if values?.isDirectory == true,
               generatedDirectoryNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true, let kind = PhotoKind.detect(url: url) else { continue }
            assets.append(PhotoAsset(url: url, kind: kind))
        }

        if let rootReadError { throw rootReadError }

        return assets.sorted {
            let filenameOrder = $0.filename.localizedStandardCompare($1.filename)
            if filenameOrder != .orderedSame { return filenameOrder == .orderedAscending }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }
}
