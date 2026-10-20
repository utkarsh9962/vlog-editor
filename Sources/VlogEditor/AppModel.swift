import AppKit
import SwiftUI
import VlogEditorCore

@MainActor
final class AppModel: ObservableObject {
    enum Stage: Equatable {
        case drop
        case working(String)
        case review
        case export
        case rendering
        case done(URL)
    }

    @Published var stage: Stage = .drop
    @Published var clips: [MediaClip] = []
    @Published var brief = ""
    @Published var settings = ExportSettings()
    @Published var progress = 0.0
    @Published var message: String?

    @Published private(set) var plan: EditPlan?
    @Published private(set) var projectURL: URL?
    @Published private(set) var openedInFinalCut = false

    private var energy: [UUID: AudioEnergy] = [:]
    private var folder: URL?

    var videoCount: Int { clips.filter(\.hasVideo).count }
    var finalCutInstalled: Bool { FinalCutBridge.isInstalled }

    var projectName: String {
        if let t = EditBriefParser.parse(brief).title, !t.isEmpty { return t }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return "Vlog \(f.string(from: Date()))"
    }

    // MARK: Step 1, drop

    func add(_ urls: [URL]) {
        let known = Set(clips.map(\.url))
        let fresh = urls.filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        Task {
            var unreadable: [String] = []
            for url in fresh {
                do { clips.append(try await MediaProbe.probe(url)) }
                catch { unreadable.append(url.lastPathComponent) }
            }
            if !unreadable.isEmpty {
                message = "Couldn't read \(unreadable.joined(separator: ", ")). Try MP4, MOV, M4V or common audio files."
            }
        }
    }

    func remove(_ clip: MediaClip) {
        clips.removeAll { $0.id == clip.id }
        energy[clip.id] = nil
    }

    // MARK: Step 2, edit in Final Cut Pro

    func makeEdit() {
        guard videoCount > 0 else { message = "Add at least one video first."; return }
        message = nil
        Task {
            do {
                stage = .working("Listening through your clips")
                await analyzeAudio()

                stage = .working("Choosing the best moments")
                let style = EditBriefParser.parse(brief)
                let plan = EditPlanner.plan(clips: clips, style: style, energy: energy)
                guard !plan.segments.isEmpty else { throw EditError.empty }
                self.plan = plan

                stage = .working("Building the Final Cut Pro project")
                let folder = try FinalCutBridge.workspace(for: projectName)
                self.folder = folder
                let canvas = footageCanvas()
                let xml = FCPXMLBuilder(projectName: projectName, eventName: "Vlog Editor",
                                        canvasWidth: canvas.width, canvasHeight: canvas.height)
                    .build(plan: plan, clips: clips)
                let url = try FinalCutBridge.write(fcpxml: xml, name: projectName, in: folder)
                projectURL = url

                openedInFinalCut = false
                if finalCutInstalled {
                    stage = .working("Opening Final Cut Pro")
                    try await FinalCutBridge.open(url)
                    openedInFinalCut = true
                }
                stage = .review
            } catch {
                message = error.localizedDescription
                stage = .drop
            }
        }
    }

    private func analyzeAudio() async {
        let pending = clips.filter { $0.hasVideo && $0.hasAudio && energy[$0.id] == nil }
        await withTaskGroup(of: (UUID, AudioEnergy?).self) { group in
            for clip in pending {
                group.addTask { (clip.id, try? await MediaProbe.audioEnergy(of: clip.url)) }
            }
            for await (id, result) in group {
                if let result { energy[id] = result }
            }
        }
    }

    /// Before the export questions, the project follows the footage: vertical if most clips are vertical.
    private func footageCanvas() -> (width: Int, height: Int) {
        let video = clips.filter(\.hasVideo)
        let portrait = video.filter(\.isPortrait).count
        return (portrait * 2 > video.count ? AspectRatio.vertical : .landscape).canvas(shortSide: 1080)
    }

    func reopenInFinalCut() {
        guard let projectURL else { return }
        Task {
            do { try await FinalCutBridge.open(projectURL); openedInFinalCut = true }
            catch { message = error.localizedDescription }
        }
    }

    // MARK: Step 3, export questions

    func choose(platform: Platform) {
        settings = ExportSettings(platform: platform)
    }

    var durationWarning: String? {
        guard let plan, let max = settings.platform.maxDuration, plan.duration > max else { return nil }
        return "\(settings.platform.displayName) takes up to \(EditStyle.format(seconds: max)) in this format. Your edit is \(EditStyle.format(seconds: plan.duration))."
    }

    func export() {
        guard let plan, let folder else { return }
        message = nil
        progress = 0
        stage = .rendering
        let name = "\(projectName) - \(settings.platform.displayName)"
        Task {
            do {
                // Keep a Final Cut Pro version in the export format too, for anyone who wants to fine-tune it.
                let canvas = settings.canvas
                let xml = FCPXMLBuilder(projectName: name, eventName: "Vlog Editor",
                                        canvasWidth: canvas.width, canvasHeight: canvas.height)
                    .build(plan: plan, clips: clips)
                projectURL = try FinalCutBridge.write(fcpxml: xml, name: name, in: folder)

                let output = folder.appendingPathComponent(FinalCutBridge.safeFileName(name)).appendingPathExtension("mp4")
                try await VideoRenderer.render(plan: plan, clips: clips, settings: settings, to: output) { value in
                    Task { @MainActor in self.progress = value }
                }
                stage = .done(output)
            } catch {
                message = error.localizedDescription
                stage = .export
            }
        }
    }

    func startOver() {
        clips = []
        brief = ""
        plan = nil
        projectURL = nil
        energy = [:]
        settings = ExportSettings()
        message = nil
        stage = .drop
    }

    enum EditError: LocalizedError {
        case empty
        var errorDescription: String? { "The clips are too short to cut a vlog from. Try adding longer videos." }
    }
}
