import AppKit
import CRTRendering
import Testing
@testable import CRTerminal

struct TitlebarControlsTests {
    @Test @MainActor func degaussButtonOnlyExistsOnCRTPresets() {
        let crt = CRTPreset(name: "Tube", effects: true)
        let cluster = TitlebarControlCluster(
            presets: [crt, .darkStandard], currentPreset: crt)
        let degauss = cluster.subviews.compactMap { $0 as? DegaussButton }.first
        #expect(degauss != nil)
        #expect(degauss?.isHidden == false)

        cluster.update(preset: .darkStandard)
        #expect(degauss?.isHidden == true)

        cluster.update(preset: crt)
        #expect(degauss?.isHidden == false)
    }

    @Test @MainActor func degaussButtonHidesWhenTheMonitorLacksOne() {
        let autoDegauss = CRTPreset(name: "Self-degaussing", effects: true,
                                    degaussButton: false)
        let cluster = TitlebarControlCluster(
            presets: [autoDegauss, .darkStandard], currentPreset: autoDegauss)
        let degauss = cluster.subviews.compactMap { $0 as? DegaussButton }.first
        #expect(degauss?.isHidden == true)
    }

    @Test @MainActor func chipNamesTheChosenThemeNotTheResolvedOne() {
        // An Auto session draws the Dark standard but the chip says "Auto",
        // so the user can tell it will follow the system.
        let cluster = TitlebarControlCluster(
            presets: [AutoTheme.catalogEntry, .darkStandard, .lightStandard],
            currentPreset: .darkStandard, themeName: AutoTheme.name)
        let chip = cluster.subviews.compactMap { $0 as? ThemeSwitcherButton }.first
        #expect(chip?.accessibilityTitle() == "Theme: Auto")

        cluster.update(preset: .lightStandard, themeName: AutoTheme.name)
        #expect(chip?.accessibilityTitle() == "Theme: Auto")

        cluster.update(preset: .lightStandard)
        #expect(chip?.accessibilityTitle() == "Theme: Light")
    }

    @Test @MainActor func clusterShrinksWhenDegaussHides() {
        let crt = CRTPreset(name: "Tube", effects: true)
        let cluster = TitlebarControlCluster(
            presets: [crt, .darkStandard], currentPreset: crt)
        let withDegauss = cluster.frame.width
        cluster.update(preset: .darkStandard)
        #expect(cluster.frame.width < withDegauss)
    }
}
