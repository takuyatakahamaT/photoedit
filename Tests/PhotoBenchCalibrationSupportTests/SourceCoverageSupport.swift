import Foundation
import PhotoBenchCalibrationSupport

/// Every Swift file under `relativeDirectory`, recursively, as a root-relative
/// path. Production rendering code lives in subdirectories too (`Spatial/`,
/// `AdobeProfile/`, `Lens/`), so the calibration source fingerprint must cover
/// them, not just the directory's top level.
func swiftSourcePaths(under relativeDirectory: String, root: URL) throws -> Set<String> {
    let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
        throw CalibrationManifestError.missingFile(relativeDirectory)
    }
    var paths: Set<String> = []
    for case let relativePath as String in enumerator where relativePath.hasSuffix(".swift") {
        paths.insert("\(relativeDirectory)/\(relativePath)")
    }
    return paths
}
