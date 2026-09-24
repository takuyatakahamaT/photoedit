import Foundation

/// Locates the Adobe-installed `.dcp` (DNG Camera Profile) and
/// "Adobe Color.xmp" look assets this project's base rendering needs, in
/// the search order specified by `docs/PHASE1_BASE_RENDERING.md` §"プロファ
/// イル資産の解決". Assets are never copied into the repository; this type
/// only locates them on disk at runtime. Returns `nil` (never throws) when
/// nothing is found, so callers can fall back to the existing Core Image
/// path per the design doc.
public struct AdobeProfileLocator: Sendable {
    /// One install location to search, pairing a `.dcp` search location
    /// with that same installation's "Adobe Color.xmp" path.
    ///
    /// Verified layouts: root 3 (Lightroom CC) on a development machine, and
    /// root 2 from the Adobe DNG Converter 18.6 installer (2026-09-25): its
    /// `com.adobe.CameraRawProfiles` package installs into root 2 both
    /// `CameraProfiles/Adobe Standard/*.dcp` and
    /// `Settings/Adobe/Profiles/Adobe Raw/Adobe Color.xmp`, byte-identical to
    /// Lightroom's copies. Roots 1/4 are still inferred by analogy. If a
    /// future install differs, only `defaultSearchRoots()` needs adjusting --
    /// callers only depend on the injectable `init(searchRoots:)`.
    public struct InstallRoot: Sendable, Equatable {
        public var baseDirectory: URL
        /// Where under `baseDirectory` to look for `.dcp` files.
        public var dcpSubdirectory: String
        /// Whether to search `dcpSubdirectory` recursively (root 3's
        /// design-doc entry names a single non-recursive subfolder,
        /// `CameraProfiles/Adobe Standard`; the others are `**`).
        public var recursive: Bool
        /// Where under `baseDirectory` "Adobe Color.xmp" lives.
        public var lookXMPRelativePath: String
        /// Which Adobe install this root is, for `status()`.
        public var source: Source

        public init(
            baseDirectory: URL,
            dcpSubdirectory: String = "CameraProfiles",
            recursive: Bool = true,
            lookXMPRelativePath: String = "Settings/Adobe/Profiles/Adobe Raw/Adobe Color.xmp",
            source: Source = .custom
        ) {
            self.baseDirectory = baseDirectory
            self.dcpSubdirectory = dcpSubdirectory
            self.recursive = recursive
            self.lookXMPRelativePath = lookXMPRelativePath
            self.source = source
        }
    }

    /// The Adobe install a search root belongs to.
    public enum Source: String, Sendable, Equatable, CaseIterable {
        /// `~/Library/Application Support/Adobe/CameraRaw`.
        case userCameraRaw
        /// `/Library/Application Support/Adobe/CameraRaw`: Adobe DNG Converter
        /// (its `com.adobe.CameraRawProfiles` package) and Camera Raw install here.
        case sharedCameraRaw
        /// Inside the Lightroom (cloud) app.
        case lightroom
        /// Inside the Lightroom Classic app.
        case lightroomClassic
        /// A root passed to `init(searchRoots:)` (tests).
        case custom
    }

    /// What `status()` found, without opening a photo.
    public struct Status: Sendable, Equatable {
        /// The install whose "Adobe Color.xmp" `locateAdobeColorLookXMP()`
        /// uses; `nil` when there is none.
        public var lookSource: Source?
        /// Installs with at least one `.dcp` where `locateDCP` searches, in
        /// search order.
        public var dcpSources: [Source]

        public init(lookSource: Source?, dcpSources: [Source]) {
            self.lookSource = lookSource
            self.dcpSources = dcpSources
        }

        /// Both halves exist, so a RAW whose camera Adobe supports opens with
        /// the Adobe base rendering. A camera newer than the install still
        /// falls back (`locateDCP` finds no matching model).
        public var isAvailable: Bool { lookSource != nil && !dcpSources.isEmpty }
    }

    public struct LocatedDCP: Sendable {
        public var url: URL
        public var profile: DCPProfile
    }

    public let searchRoots: [InstallRoot]

    public init(searchRoots: [InstallRoot]? = nil) {
        self.searchRoots = searchRoots ?? Self.defaultSearchRoots()
    }

    public static func defaultSearchRoots() -> [InstallRoot] {
        var roots: [InstallRoot] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(InstallRoot(
            baseDirectory: home.appendingPathComponent("Library/Application Support/Adobe/CameraRaw"),
            source: .userCameraRaw
        ))
        roots.append(InstallRoot(
            baseDirectory: URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw"),
            source: .sharedCameraRaw
        ))
        roots.append(InstallRoot(
            baseDirectory: URL(
                fileURLWithPath: "/Applications/Adobe Lightroom CC/Adobe Lightroom.app/Contents/Resources"
            ),
            dcpSubdirectory: "CameraProfiles/Adobe Standard",
            recursive: false,
            source: .lightroom
        ))
        roots.append(InstallRoot(
            baseDirectory: URL(
                fileURLWithPath: "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/Resources"
            ),
            source: .lightroomClassic
        ))
        return roots
    }

    /// Which installs could supply the assets, from file existence only (no
    /// `.dcp` is parsed and no camera model is needed), for a settings screen
    /// to say where the base rendering comes from. Nothing is cached, here or
    /// in `locateDCP` / `locateAdobeColorLookXMP()`, so an install made while
    /// the engine runs shows up at once.
    public func status() -> Status {
        var lookSource: Source?
        var dcpSources: [Source] = []
        for root in searchRoots {
            let look = root.baseDirectory.appendingPathComponent(root.lookXMPRelativePath)
            if lookSource == nil, FileManager.default.fileExists(atPath: look.path) {
                lookSource = root.source
            }
            let dcpDirectory = root.baseDirectory.appendingPathComponent(root.dcpSubdirectory)
            if !dcpSources.contains(root.source),
               Self.containsDCPFile(under: dcpDirectory, recursive: root.recursive) {
                dcpSources.append(root.source)
            }
        }
        return Status(lookSource: lookSource, dcpSources: dcpSources)
    }

    /// Stops at the first `.dcp`, so a full install (about 1,500 of them) is
    /// not walked.
    private static func containsDCPFile(under directory: URL, recursive: Bool) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        if recursive {
            guard let enumerator = fm.enumerator(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return false }
            for case let url as URL in enumerator where url.pathExtension.caseInsensitiveCompare("dcp") == .orderedSame {
                return true
            }
            return false
        }
        guard let contents = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return contents.contains { $0.pathExtension.caseInsensitiveCompare("dcp") == .orderedSame }
    }

    /// Finds a `.dcp` whose `UniqueCameraModel` matches `uniqueCameraModel`
    /// case-insensitively, searching roots in order and returning the first
    /// root that has any match. Within a root, a DCP with
    /// `ProfileName == "Adobe Standard"` wins immediately; otherwise the
    /// first match (by sorted path, for determinism) is used.
    public func locateDCP(uniqueCameraModel: String) -> LocatedDCP? {
        for root in searchRoots {
            let searchDir = root.baseDirectory.appendingPathComponent(root.dcpSubdirectory)
            let candidates = Self.findDCPFiles(under: searchDir, recursive: root.recursive)

            var firstMatch: LocatedDCP?
            for url in candidates {
                guard let profile = try? DCPProfile(contentsOf: url) else { continue }
                guard profile.uniqueCameraModel.caseInsensitiveCompare(uniqueCameraModel) == .orderedSame
                else { continue }

                if profile.profileName == "Adobe Standard" {
                    return LocatedDCP(url: url, profile: profile)
                }
                if firstMatch == nil {
                    firstMatch = LocatedDCP(url: url, profile: profile)
                }
            }
            if let firstMatch { return firstMatch }
        }
        return nil
    }

    /// Finds "Adobe Color.xmp" at the first search root where it exists.
    public func locateAdobeColorLookXMP() -> URL? {
        for root in searchRoots {
            let candidate = root.baseDirectory.appendingPathComponent(root.lookXMPRelativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func findDCPFiles(under directory: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        var results: [URL] = []
        if recursive {
            guard let enumerator = fm.enumerator(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            for case let url as URL in enumerator where url.pathExtension.caseInsensitiveCompare("dcp") == .orderedSame {
                results.append(url)
            }
        } else {
            guard let contents = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            results = contents.filter { $0.pathExtension.caseInsensitiveCompare("dcp") == .orderedSame }
        }
        return results.sorted { $0.path < $1.path }
    }
}
