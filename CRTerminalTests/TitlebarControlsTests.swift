import AppKit
import CRTRendering
import Testing
@testable import CRTerminal

struct TitlebarControlsTests {
    @Test @MainActor func degaussButtonOnlyExistsOnCRTPresets() {
        let crt = CRTPreset(name: "Tube", effects: true)
        let cluster = TitlebarControlCluster(
            presets: [crt, .museumOff], currentPreset: crt)
        let degauss = cluster.subviews.compactMap { $0 as? DegaussButton }.first
        #expect(degauss != nil)
        #expect(degauss?.isHidden == false)

        cluster.update(preset: .museumOff)
        #expect(degauss?.isHidden == true)

        cluster.update(preset: crt)
        #expect(degauss?.isHidden == false)
    }

    @Test @MainActor func degaussButtonHidesWhenTheMonitorLacksOne() {
        let autoDegauss = CRTPreset(name: "Self-degaussing", effects: true,
                                    degaussButton: false)
        let cluster = TitlebarControlCluster(
            presets: [autoDegauss, .museumOff], currentPreset: autoDegauss)
        let degauss = cluster.subviews.compactMap { $0 as? DegaussButton }.first
        #expect(degauss?.isHidden == true)
    }

    @Test @MainActor func clusterShrinksWhenDegaussHides() {
        let crt = CRTPreset(name: "Tube", effects: true)
        let cluster = TitlebarControlCluster(
            presets: [crt, .museumOff], currentPreset: crt)
        let withDegauss = cluster.frame.width
        cluster.update(preset: .museumOff)
        #expect(cluster.frame.width < withDegauss)
    }
}
