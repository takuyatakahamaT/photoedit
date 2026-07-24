import Foundation
import PhotoBenchCalibrationSupport
import Testing

@Suite("System load snapshot")
struct SystemLoadSnapshotTests {
    @Test func capturedValuesAreFiniteAndRoundTrip() throws {
        let snapshot = try SystemLoadSnapshot.capture()

        #expect(snapshot.loadAverage1Minute.isFinite)
        #expect(snapshot.loadAverage1Minute >= 0)
        #expect(snapshot.loadAverage5Minutes.isFinite)
        #expect(snapshot.loadAverage5Minutes >= 0)
        #expect(snapshot.loadAverage15Minutes.isFinite)
        #expect(snapshot.loadAverage15Minutes >= 0)
        #expect(snapshot.load1PerActiveProcessor.isFinite)
        #expect(snapshot.load1PerActiveProcessor >= 0)
        #expect(snapshot.processCPUTimeSeconds.isFinite)
        #expect(snapshot.processCPUTimeSeconds >= 0)
        #expect(!snapshot.capturedAtUTC.isEmpty)

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SystemLoadSnapshot.self, from: encoded)
        #expect(decoded == snapshot)
    }
}
