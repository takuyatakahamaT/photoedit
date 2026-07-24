import Testing
@testable import PhotoCore

@Suite("Metal presentation probe configuration")
struct MetalPresentationProbeTests {
    @Test func absentConfigurationUsesProductionOnDemand() {
        let configuration = MetalPresentationProbeConfiguration(environment: [:])

        #expect(configuration.mode == .productionOnDemand)
        #expect(!configuration.isExplicit)
        #expect(configuration.invalidValue == nil)
    }

    @Test func everyDocumentedModeParsesExactly() {
        for mode in MetalPresentationProbeMode.allCases {
            let configuration = MetalPresentationProbeConfiguration(environment: [
                MetalPresentationProbeConfiguration.environmentKey: mode.rawValue
            ])

            #expect(configuration.mode == mode)
            #expect(configuration.isExplicit)
            #expect(configuration.invalidValue == nil)
        }
    }

    @Test func invalidValueFailsClosedToProduction() {
        let configuration = MetalPresentationProbeConfiguration(environment: [
            MetalPresentationProbeConfiguration.environmentKey: "metal-clear"
        ])

        #expect(configuration.mode == .productionOnDemand)
        #expect(!configuration.isExplicit)
        #expect(configuration.invalidValue == "metal-clear")
    }

    @Test func modesChangeOnlyTheirDeclaredAxis() {
        #expect(MetalPresentationProbeMode.metalClearOnDemand.payload == .metalClear)
        #expect(MetalPresentationProbeMode.metalClearOnDemand.drawingMode == .onDemand)
        #expect(MetalPresentationProbeMode.metalClearContinuous.payload == .metalClear)
        #expect(MetalPresentationProbeMode.metalClearContinuous.drawingMode == .continuous)
        #expect(MetalPresentationProbeMode.ciSolidOnDemand.payload == .ciSolid)
        #expect(MetalPresentationProbeMode.ciSolidOnDemand.drawingMode == .onDemand)
        #expect(MetalPresentationProbeMode.productionOnDemand.payload == .production)
        #expect(MetalPresentationProbeMode.productionOnDemand.drawingMode == .onDemand)
    }
}
