import AppKit
import CRTRendering
import SwiftUI
import TerminalCore

/// Gallery previews go through the real pipeline at thumbnail size
/// (ARCHITECTURE.md) — a dedicated small renderer over a canned shell
/// session, re-rendered on a timeline so animated effects actually animate.
final class PresetPreviewRenderer {
    private let renderer: TerminalRenderer?
    private let state: TerminalState

    init() {
        renderer = TerminalRenderer(
            font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), scale: 2)
        var terminal = Terminal(columns: 38, rows: 11)
        let sample: [String] = [
            "$ make test",
            "\u{1B}[32m✓\u{1B}[0m 96 tests passed \u{1B}[2m(0.8s)\u{1B}[0m",
            "$ ls",
            "\u{1B}[34msrc\u{1B}[0m    \u{1B}[34mbuild\u{1B}[0m    README.md",
            "$ git log --oneline -2",
            "\u{1B}[33mf3a91c2\u{1B}[0m phosphor decay pass",
            "\u{1B}[33m08bd44e\u{1B}[0m degauss goes thunk",
            "$ \u{1B}[7m \u{1B}[0m",
        ]
        terminal.feed(Array(sample.joined(separator: "\r\n").utf8))
        state = terminal.state
    }

    func image(for preset: CRTPreset, time: TimeInterval) -> CGImage? {
        renderer?.renderImage(state, preset: preset, time: time)
    }
}

struct PresetGalleryView: View {
    let presets: [CRTPreset]
    let preview: PresetPreviewRenderer
    @State var selectedName: String
    let onSelect: (CRTPreset) -> Void

    var body: some View {
        // 5 Hz keeps noise/hum-bar previews alive at negligible cost.
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(presets, id: \.name) { preset in
                        card(for: preset, time: time)
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 580, idealWidth: 580, minHeight: 460, idealHeight: 540)
    }

    @ViewBuilder
    private func card(for preset: CRTPreset, time: TimeInterval) -> some View {
        let isSelected = preset.name == selectedName
        Button {
            selectedName = preset.name
            onSelect(preset)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let image = preview.image(for: preset, time: time) {
                        Image(decorative: image, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Color.black
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(preset.name).font(.headline)
                    if let year = preset.year {
                        Text(String(year)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if let blurb = preset.blurb {
                    Text(blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
