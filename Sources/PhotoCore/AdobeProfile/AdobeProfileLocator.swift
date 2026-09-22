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
    /// JUDGMENT CALL: only root 3 (Lightroom CC) has been directly verified
    /// to exist on a development machine; roots 1/2/4's exact
    /// `Settings/Adobe/Profiles/Adobe Raw/Adobe Color.xmp` sibling layout
    /// under their respective bases is inferred by analogy to root 3's
    /// (confirmed) `CameraProfiles` / `Settings` sibling structure under
    /// the same `Resources` directory, not independently confirmed. If a
    /// future machine's Camera Raw install differs, only
    /// `defaultSearchRoots()` needs adjusting -- callers only depend on the
    /// injectable `init(searchRoots:)`.
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

        public init(
            baseDirectory: URL,
            dcpSubdirectory: String = "CameraProfiles",
            recursive: Bool = true,
            lookXMPRelativePath: String = "Settings/Adobe/Profiles/Adobe Raw/Adobe Color.xmp"
        ) {
            self.baseDirectory = baseDirectory
            self.dcpSubdirectory = dcpSubdirectory
            self.recursive = recursive
            self.lookXMPRelativePath = lookXMPRelativePath
        }
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
            baseDirectory: home.appendingPathComponent("Library/Application Support/Adobe/CameraRaw")
        ))
        roots.append(InstallRoot(
            baseDirectory: URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw")
        ))
        roots.append(InstallRoot(
            baseDirectory: URL(
                fileURLWithPath: "/Applications/Adobe Lightroom CC/Adobe Lightroom.app/Contents/Resources"
            ),
            dcpSubdirectory: "CameraProfiles/Adobe Standard",
            recursive: false
        ))
        roots.append(InstallRoot(
            baseDirectory: URL(
                fileURLWithPath: "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/Resources"
            )
        ))
        return roots
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
