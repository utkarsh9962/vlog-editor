import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VlogEditorCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.stage {
            case .drop: DropStage()
            case .working(let step): WorkingStage(step: step)
            case .review: ReviewStage()
            case .export: ExportStage()
            case .rendering: RenderingStage()
            case .done(let url): DoneStage(output: url)
            }
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 640, minHeight: 600)
        .animation(.easeInOut(duration: 0.2), value: model.stage)
    }
}

// MARK: - Step 1: drop clips and describe the vlog

struct DropStage: View {
    @EnvironmentObject var model: AppModel
    @State private var targeted = false
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Header(title: "New vlog", subtitle: "Drop your clips, say what you want, and Final Cut Pro does the rest.")

            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
                    .background(RoundedRectangle(cornerRadius: 18).fill(targeted ? Color.accentColor.opacity(0.06) : Color.clear))

                if model.clips.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 30, weight: .light))
                        Text("Drop videos here").font(.headline)
                        Button("or choose files") { choosing = true }.buttonStyle(.link)
                        Text("MP4, MOV, M4V. Drop a song too and it becomes the music.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ClipList()
                }
            }
            .frame(minHeight: 220)
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return true
            } isTargeted: { targeted = $0 }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.movie, .audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.add(urls) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Describe the edit").font(.headline)
                TextField("e.g. A fast 60 second travel vlog titled 'Lisbon Weekend' with smooth transitions",
                          text: $model.brief, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...6)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
            }

            HStack {
                if !model.finalCutInstalled {
                    Label("Final Cut Pro not found. You can still export from here.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.finalCutInstalled ? "Edit in Final Cut Pro" : "Make the edit") { model.makeEdit() }
                    .buttonStyle(PrimaryButton())
                    .disabled(model.videoCount == 0)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(32)
    }
}

struct ClipList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(model.clips) { clip in
                    HStack(spacing: 12) {
                        Image(systemName: clip.hasVideo ? "film" : "music.note")
                            .frame(width: 20).foregroundStyle(.secondary)
                        Text(clip.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(EditStyle.format(seconds: clip.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Button { model.remove(clip) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                }
                Text("Drop more to add them").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
            }
            .padding(14)
        }
    }
}

// MARK: - Working

struct WorkingStage: View {
    let step: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(step).font(.title3)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Review in Final Cut Pro

struct ReviewStage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Header(
                title: "Your edit is ready",
                subtitle: model.openedInFinalCut
                    ? "It's open in Final Cut Pro under the “Vlog Editor” event. Tweak anything you like there, then come back to export."
                    : "Your project file is saved. Export below, or open it in Final Cut Pro later."
            )
            if let plan = model.plan {
                VStack(alignment: .leading, spacing: 10) {
                    Stat(label: "Length", value: EditStyle.format(seconds: plan.duration))
                    Stat(label: "Shots", value: "\(plan.segments.count) from \(model.videoCount) clips")
                    Stat(label: "Style", value: plan.style.summary)
                    if !plan.music.isEmpty { Stat(label: "Music", value: plan.music.map(\.name).joined(separator: ", ")) }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.06)))
            }
            Spacer()
            HStack {
                Button("Start over") { model.startOver() }.buttonStyle(.borderless)
                if model.finalCutInstalled {
                    Button("Open in Final Cut Pro") { model.reopenInFinalCut() }.buttonStyle(.borderless)
                }
                if let url = model.projectURL {
                    Button("Show project file") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.borderless)
                }
                Spacer()
                Button("Continue to export") { model.stage = .export }.buttonStyle(PrimaryButton())
            }
        }
        .padding(32)
    }
}

// MARK: - Step 3: export questions

struct ExportStage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Header(title: "Export", subtitle: "Three quick questions and you're done.")

            Question(number: 1, title: "Where will you post it?") {
                Chips(items: Platform.allCases, selected: model.settings.platform,
                      label: { $0.displayName }, symbol: { $0.symbolName }) { model.choose(platform: $0) }
            }
            Question(number: 2, title: "Which shape?") {
                Chips(items: AspectRatio.allCases, selected: model.settings.aspect,
                      label: { "\($0.label)  \($0.subtitle)" }, symbol: { _ in nil }) { model.settings.aspect = $0 }
            }
            Question(number: 3, title: "What quality?") {
                Chips(items: Quality.allCases, selected: model.settings.quality,
                      label: { "\($0.label)  \($0.subtitle)" }, symbol: { _ in nil }) { model.settings.quality = $0 }
            }

            if let warning = model.durationWarning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Button("Back") { model.stage = .review }.buttonStyle(.borderless)
                Spacer()
                let c = model.settings.canvas
                Text("\(c.width) × \(c.height) MP4").font(.callout).foregroundStyle(.secondary)
                Button("Export") { model.export() }.buttonStyle(PrimaryButton())
            }
        }
        .padding(32)
    }
}

struct RenderingStage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Exporting for \(model.settings.platform.displayName)").font(.title3)
            ProgressView(value: model.progress).frame(width: 320)
            Text("\(Int(model.progress * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct DoneStage: View {
    @EnvironmentObject var model: AppModel
    let output: URL

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.green)
            Text("Your vlog is ready").font(.title2.weight(.semibold))
            Text(output.lastPathComponent).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    .buttonStyle(PrimaryButton())
                Button("Export another size") { model.stage = .export }
                Button("New vlog") { model.startOver() }
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Small pieces

struct Header: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value)
        }
    }
}

struct Question<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(number). \(title)").font(.headline)
            content
        }
    }
}

struct Chips<Item: Identifiable & Equatable>: View {
    let items: [Item]
    let selected: Item
    let label: (Item) -> String
    let symbol: (Item) -> String?
    let choose: (Item) -> Void

    var body: some View {
        FlowRow {
            ForEach(items) { item in
                let on = item == selected
                Button { choose(item) } label: {
                    HStack(spacing: 6) {
                        if let s = symbol(item) { Image(systemName: s) }
                        Text(label(item))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.1)))
                    .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays chips out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                y += rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Capsule().fill(Color.accentColor.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
            .foregroundStyle(.white)
    }
}
