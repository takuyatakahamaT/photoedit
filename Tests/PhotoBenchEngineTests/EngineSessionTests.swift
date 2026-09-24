import Foundation
import PhotoCore
import Testing
@testable import PhotoBenchEngine

/// `EngineSession` over a fake backend: dispatch, error codes, render
/// cancellation, drag sessions, the working-copy LRU, close and shutdown.
@Suite(.serialized)
struct EngineSessionTests {
    private func renderParams(
        _ photoID: String, _ settings: EditSettings = .neutral, maxDimension: Int? = 1_600,
        drag: Bool? = nil, original: Bool? = nil
    ) -> [String: Any] {
        var params: [String: Any] = ["photoId": photoID, "settings": settingsJSON(settings)]
        if let maxDimension { params["maxDimension"] = maxDimension }
        if let drag { params["drag"] = drag }
        if let original { params["original"] = original }
        return params
    }

    // MARK: - Basic methods

    @Test func helloAndBuiltinPresets() throws {
        let harness = SessionHarness()
        let hello = try harness.call("hello")
        #expect(hello.ok)
        #expect(hello.result?["protocolVersion"] as? Int == 1)
        #expect((hello.result?["engineVersion"] as? String)?.hasPrefix("0.1.0+") == true)

        let presets = try harness.call("builtinPresets")
        let list = try #require(presets.result?["presets"] as? [[String: Any]])
        #expect(list.map { $0["id"] as? String } == ["niho-bluesky2", "niho-colorful", "niho-night", "niho-pastel"])
        #expect(list.map { $0["name"] as? String } == ["bluesky2", "colorful", "night", "pastel"])
        #expect(list.allSatisfy { ($0["xmp"] as? String)?.hasPrefix("<x:xmpmeta") == true })
    }

    @Test func profileStatusReportsWhereTheAdobeProfilesComeFrom() throws {
        let harness = SessionHarness(profileStatus: .init(
            lookSource: .sharedCameraRaw, dcpSources: [.sharedCameraRaw, .lightroom]
        ))
        let found = try harness.call("profileStatus")
        #expect(found.ok)
        #expect(found.result?["available"] as? Bool == true)
        #expect(found.result?["lookSource"] as? String == "sharedCameraRaw")
        #expect(found.result?["dcpSources"] as? [String] == ["sharedCameraRaw", "lightroom"])

        let missing = try SessionHarness().call("profileStatus")
        #expect(missing.ok)
        #expect(missing.result?["available"] as? Bool == false)
        #expect(missing.result?["lookSource"] is NSNull)
        #expect(missing.result?["dcpSources"] as? [String] == [])
    }

    @Test func profileStatusDoesNotWaitForTheWorkQueue() throws {
        let harness = SessionHarness(profileStatus: .init(lookSource: .lightroom, dcpSources: [.lightroom]))
        let gate = harness.holdQueue()
        defer { gate.signal() }
        let response = try harness.call("profileStatus")
        #expect(response.ok)
        #expect(response.result?["available"] as? Bool == true)
    }

    @Test func openReportsThePhotoAndNeutralSettings() throws {
        let harness = SessionHarness()
        let response = try harness.call("open", ["path": "/photos/P1.RW2"])
        #expect(response.ok)
        let result = try #require(response.result)
        #expect((result["photoId"] as? String)?.isEmpty == false)
        #expect(result["kind"] as? String == "raw")
        #expect(result["fileName"] as? String == "P1.RW2")
        #expect(result["width"] as? Int == 6_000)
        #expect(result["height"] as? Int == 4_000)
        #expect(result["profile"] as? String == "adobe")
        #expect((result["asShotWhiteBalance"] as? [String: Any])?["tint"] as? Int == 3)
        #expect(try decodeSettings(result["settings"]) == .neutral)

        let jpeg = try #require(try harness.call("open", ["path": "/photos/a.jpg"]).result)
        #expect(jpeg["kind"] as? String == "raster")
        #expect(jpeg["profile"] is NSNull)
        #expect(jpeg["asShotWhiteBalance"] is NSNull)
        #expect(jpeg["photoId"] as? String != result["photoId"] as? String)
    }

    @Test func errorCodes() throws {
        let harness = SessionHarness()
        harness.sendRaw("{broken")
        #expect(try harness.sink.response(id: 0).errorCode == "invalidRequest")
        #expect(try harness.call("fly").errorCode == "invalidRequest")
        #expect(try harness.call("open", ["path": "relative/a.jpg"]).errorCode == "invalidRequest")
        #expect(try harness.call("open", ["path": "/photos/broken.jpg"]).errorCode == "decodeFailed")
        #expect(try harness.call("render", renderParams("no-such-photo")).errorCode == "notFound")
        #expect(try harness.call("close", ["photoId": "no-such-photo"]).errorCode == "notFound")
        #expect(try harness.call("presetSettings", ["xmp": "<x:xmpmeta"]).errorCode == "presetInvalid")
        #expect(try harness.call("presetSettings", ["xmp": "<a/>"]).errorCode == "presetInvalid")
        #expect(try harness.call("presetSettings", [:]).errorCode == "invalidRequest")

        let photoID = try harness.open("a.jpg")
        #expect(try harness.call("render", ["photoId": photoID]).errorCode == "invalidRequest", "settings is required")
        #expect(try harness.call("render", renderParams(photoID, maxDimension: 0)).errorCode == "invalidRequest")
        let export: [String: Any] = [
            "photoId": photoID, "settings": settingsJSON(.neutral), "destinationPath": "/out/unwritable.jpg"
        ]
        #expect(try harness.call("export", export).errorCode == "exportFailed")
        var relative = export
        relative["destinationPath"] = "out.jpg"
        #expect(try harness.call("export", relative).errorCode == "invalidRequest")
    }

    @Test func renderReturnsTheJPEGWithItsSize() throws {
        let harness = SessionHarness()
        let photoID = try harness.open("a.jpg")
        var settings = EditSettings.neutral
        settings.exposure = 0.5
        let response = try harness.call("render", renderParams(photoID, settings, maxDimension: 1_200))
        #expect(response.ok)
        #expect(response.mime == "image/jpeg")
        let body = try #require(response.binary)
        #expect(response.binaryLength == body.count)
        #expect(body.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(response.result?["width"] as? Int == 1_200)
        #expect(response.result?["height"] as? Int == 800)
        #expect(harness.backend.renders.last?.settings == settings)
    }

    @Test func maxDimensionDefaultsToAndIsCappedAt2560() throws {
        let harness = SessionHarness()
        let photoID = try harness.open("a.jpg")
        _ = try harness.call("render", renderParams(photoID, maxDimension: nil))
        _ = try harness.call("render", renderParams(photoID, maxDimension: 9_000))
        #expect(harness.backend.renders.map(\.maxDimension) == [2_560, 2_560])
    }

    @Test func originalRendersNeutralSettings() throws {
        let harness = SessionHarness()
        let photoID = try harness.open("a.jpg")
        var settings = EditSettings.neutral
        settings.contrast = 40
        #expect(try harness.call("render", renderParams(photoID, settings, original: true)).ok)
        // `settings` may be left out entirely for the original.
        #expect(try harness.call("render", ["photoId": photoID, "original": true]).ok)
        #expect(harness.backend.renders.map(\.settings) == [.neutral, .neutral])
        #expect(harness.backend.renders.allSatisfy { $0.drag == nil })
    }

    @Test func presetSettingsPatchesTheBase() throws {
        let harness = SessionHarness()
        var base = EditSettings.neutral
        base.exposure = 1.25
        base.clarity = 10
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
         crs:Contrast2012="+25" crs:Sharpness="40" crs:GrainAmount="10">
        <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">my preset</rdf:li></rdf:Alt></crs:Name>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let response = try harness.call("presetSettings", ["xmp": xmp, "base": settingsJSON(base)])
        #expect(response.ok)
        let result = try #require(response.result)
        #expect(result["name"] as? String == "my preset")
        let settings = try decodeSettings(result["settings"])
        #expect(settings.exposure == 1.25)
        #expect(settings.clarity == 10)
        #expect(settings.contrast == 25)
        let unsupported = try #require(result["unsupported"] as? [String])
        #expect(unsupported.contains("Sharpness"))
        #expect(unsupported.contains("GrainAmount"))
        #expect(!unsupported.contains("Contrast2012"))

        // Without `base`, the preset applies to the default settings.
        let fromDefault = try decodeSettings(
            try #require(try harness.call("presetSettings", ["xmp": xmp]).result)["settings"]
        )
        #expect(fromDefault.exposure == 0)
        #expect(fromDefault.contrast == 25)
    }

    // MARK: - Cancellation

    /// A render still waiting for the work queue answers `cancelled` as soon
    /// as a newer render for the same photo arrives.
    @Test func aQueuedRenderIsCancelledByANewerOne() throws {
        let harness = SessionHarness()
        let photoID = try harness.open("a.jpg")
        let gate = harness.holdQueue()
        let first = harness.send("render", renderParams(photoID))
        let second = harness.send("render", renderParams(photoID))
        let cancelled = try harness.sink.response(id: first)
        #expect(cancelled.errorCode == "cancelled")
        #expect(!harness.sink.hasResponse(id: second))
        gate.signal()
        #expect(try harness.sink.response(id: second).ok)
        harness.drainQueue()
        #expect(harness.sink.count(id: first) == 1)
        #expect(harness.backend.renders.count == 1, "the superseded render never ran")
    }

    /// A running render stops through its `PreviewCancellation` and answers
    /// `cancelled`; the newer one then renders.
    @Test func aRunningRenderIsCancelledByANewerOne() throws {
        let harness = SessionHarness()
        let photoID = try harness.open("a.jpg")
        harness.backend.blockRenders([0])
        let first = harness.send("render", renderParams(photoID))
        #expect(harness.backend.renderStarted.wait(timeout: .now() + 20) == .success)
        var newer = EditSettings.neutral
        newer.exposure = 1
        let second = harness.send("render", renderParams(photoID, newer))
        #expect(try harness.sink.response(id: first).errorCode == "cancelled")
        let rendered = try harness.sink.response(id: second)
        #expect(rendered.ok)
        #expect(harness.backend.renders.map(\.settings.exposure) == [0, 1])
        harness.drainQueue()
        #expect(harness.sink.count(id: first) == 1)
    }

    @Test func rendersOfOtherPhotosAreNotCancelled() throws {
        let harness = SessionHarness()
        let photoA = try harness.open("a.jpg")
        let photoB = try harness.open("b.jpg")
        harness.backend.blockRenders([0])
        let renderA = harness.send("render", renderParams(photoA))
        #expect(harness.backend.renderStarted.wait(timeout: .now() + 20) == .success)
        let renderB = harness.send("render", renderParams(photoB))
        let openC = harness.send("open", ["path": "/photos/c.jpg"])
        Thread.sleep(forTimeInterval: 0.05)
        #expect(!harness.sink.hasResponse(id: renderA), "photo A's render keeps running")
        harness.backend.renderGate.signal()
        #expect(try harness.sink.response(id: renderA).ok)
        #expect(try harness.sink.response(id: renderB).ok)
        #expect(try harness.sink.response(id: openC).ok)
    }

    @Test func exportsAreNeverCancelled() throws {
        let harness = SessionHarness()
        let photoID = try harness.open("a.jpg")
        harness.backend.blockExports()
        let export = harness.send("export", [
            "photoId": photoID, "settings": settingsJSON(.neutral), "destinationPath": "/out/a.jpg", "jpegQuality": 0.9
        ])
        #expect(harness.backend.exportStarted.wait(timeout: .now() + 20) == .success)
        let render = harness.send("render", renderParams(photoID))
        let newerRender = harness.send("render", renderParams(photoID))
        #expect(try harness.sink.response(id: render).errorCode == "cancelled")
        #expect(!harness.sink.hasResponse(id: export))
        harness.backend.exportGate.signal()
        let exported = try harness.sink.response(id: export)
        #expect(exported.ok)
        #expect(exported.result?["path"] as? String == "/out/a.jpg")
        #expect(exported.result?["bytes"] as? Int == 1_234)
        #expect(try harness.sink.response(id: newerRender).ok)
    }

    // MARK: - Drag sessions

    @Test func dragSessionsStartWithTheFirstDragFrameAndEndWithAnExactRender() throws {
        let harness = SessionHarness()
        let photoID = try harness.open("a.jpg")
        var first = EditSettings.neutral
        first.shadows = 10
        var second = first
        second.shadows = 20
        #expect(try harness.call("render", renderParams(photoID, first, drag: true)).ok)
        #expect(try harness.call("render", renderParams(photoID, second, drag: true)).ok)
        // The "before" view in the middle of a drag leaves the session alone.
        #expect(try harness.call("render", renderParams(photoID, original: true)).ok)
        #expect(try harness.call("render", renderParams(photoID, second, drag: true)).ok)
        #expect(try harness.call("render", renderParams(photoID, second, drag: false)).ok)
        #expect(try harness.call("render", renderParams(photoID, second, drag: true)).ok)

        let calls = harness.backend.renders
        let session = try #require(calls[0].drag)
        #expect(session.startSettings == first)
        #expect(calls[1].drag === session)
        #expect(calls[2].drag == nil)
        #expect(calls[3].drag === session)
        #expect(calls[4].drag == nil)
        let next = try #require(calls[5].drag)
        #expect(next !== session)
        #expect(next.startSettings == second)
    }

    // MARK: - Working-copy LRU

    @Test func atMostFourWorkingCopiesAreKeptAndDroppedOnesReload() throws {
        let harness = SessionHarness()
        let names = ["1.jpg", "2.jpg", "3.jpg", "4.jpg"]
        var ids: [String] = []
        for name in names {
            ids.append(try harness.open(name))
        }
        // Use photo 1 so photo 2 becomes the least recently used.
        #expect(try harness.call("render", renderParams(ids[0])).ok)
        let fifth = try harness.open("5.jpg")
        #expect(harness.backend.openCount("2.jpg") == 1)

        // Photo 2 keeps its id; its render decodes it again.
        #expect(try harness.call("render", renderParams(ids[1])).ok)
        #expect(harness.backend.openCount("2.jpg") == 2)
        // Photos 1 and 5 were used more recently than 3, which was dropped.
        #expect(try harness.call("render", renderParams(ids[0])).ok)
        #expect(try harness.call("render", renderParams(fifth)).ok)
        #expect(harness.backend.openCount("1.jpg") == 1)
        #expect(harness.backend.openCount("5.jpg") == 1)
        #expect(try harness.call("render", renderParams(ids[2])).ok)
        #expect(harness.backend.openCount("3.jpg") == 2)
    }

    // MARK: - close / shutdown

    @Test func closeForgetsThePhotoAndAnswersItsQueuedRender() throws {
        let harness = SessionHarness()
        let photoID = try harness.open("a.jpg")
        let gate = harness.holdQueue()
        let render = harness.send("render", renderParams(photoID))
        let close = try harness.call("close", ["photoId": photoID])
        #expect(close.ok)
        #expect(close.result?.isEmpty == true)
        #expect(try harness.sink.response(id: render).errorCode == "notFound")
        gate.signal()
        harness.drainQueue()
        #expect(harness.backend.renders.isEmpty)
        #expect(try harness.call("render", renderParams(photoID)).errorCode == "notFound")
    }

    @Test func shutdownCancelsTheRunningRenderThenAnswersAndTerminates() throws {
        let harness = SessionHarness()
        let photoID = try harness.open("a.jpg")
        harness.backend.blockRenders([0])
        let render = harness.send("render", renderParams(photoID))
        #expect(harness.backend.renderStarted.wait(timeout: .now() + 20) == .success)
        let shutdown = harness.send("shutdown")
        #expect(try harness.sink.response(id: render).errorCode == "cancelled")
        #expect(try harness.sink.response(id: shutdown).ok)
        #expect(harness.terminated == 0)
        let responsesAfterShutdown = harness.sink.all.count
        harness.send("hello")
        #expect(harness.sink.all.count == responsesAfterShutdown, "requests after shutdown are ignored")
    }

    @Test func endOfInputTerminatesWithoutAnAnswer() throws {
        let harness = SessionHarness()
        _ = try harness.call("hello")
        harness.session.handleEndOfInput()
        #expect(harness.terminated == 0)
        #expect(harness.sink.all.count == 1)
    }
}
