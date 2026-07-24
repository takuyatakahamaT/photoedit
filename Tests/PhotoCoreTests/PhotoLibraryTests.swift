import Foundation
import Testing
@testable import PhotoCore

struct PhotoLibraryTests {
    @Test func scansNestedPhotosAndSkipsEveryGeneratedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoLibraryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let included = [
            root.appendingPathComponent("root.JPG"),
            root.appendingPathComponent("album/nested.RW2"),
            root.appendingPathComponent("exported/legitimate.tiff")
        ]
        let excludedDirectoryNames = ["exports", "dist", ".build", ".photobench"]
        for url in included {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
        for name in excludedDirectoryNames {
            let url = root.appendingPathComponent("\(name)/must-not-appear.jpg")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }

        let assets = try PhotoLibrary.scan(root: root)
        #expect(Set(assets.map(\.url.standardizedFileURL)) == Set(included.map(\.standardizedFileURL)))
    }

    @Test func duplicateFilenamesHaveDeterministicPathOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoLibrarySortTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("A/same.jpg")
        let second = root.appendingPathComponent("B/same.jpg")
        for url in [second, first] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }

        let assets = try PhotoLibrary.scan(root: root)
        #expect(assets.map(\.url.standardizedFileURL) == [first, second].map(\.standardizedFileURL))
    }

    @Test func cancelledScanReturnsBeforeOpeningTheRoot() async {
        let impossibleRoot = URL(fileURLWithPath: "/this/path/must/not/be/opened")
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try PhotoLibrary.scan(root: impossibleRoot)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        #expect(await task.value)
    }
}
