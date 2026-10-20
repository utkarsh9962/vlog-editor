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
    private var visual: [UUID: VisualProfile] = [:]
    private var words: [UUID: [SpokenWord]] = [:]
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
        visual[clip.id] = nil
        words[clip.id] = nil
    }

    // MARK: Step 2, edit in Final Cut Pro

    func makeEdit() {
        guard videoCount > 0 else { message = "Add at least one video first."; return }
        message = nil
        Task {
            do {
                stage = .working("Watching and listening through your clips")
                async let sound: Void = analyzeAudio()
                async let picture: Void = analyzeVideo()
                _ = await (sound, picture)

                var plan = try await choosePlan()
                let keywords = EditBriefParser.parse(brief)
                plan.style.captions = plan.style.captions || keywords.captions
                plan.style.cutToBeat = plan.style.cutToBeat && keywords.cutToBeat
                if plan.style.cutToBeat, let song = plan.music.first {
                    stage = .working("Finding the beat")
                    plan.segments = await snapToBeat(plan.segments, song: song)
                }
                if plan.style.captions {
                    stage = .working("Writing captions")
                    plan.captions = await makeCaptions(for: plan)
                }
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

    /// Claude plans the edit when an API key is set; otherwise, or if that fails, the keyword planner does.
    private func choosePlan() async throws -> EditPlan {
        if let key = APIKeyStore.key {
            do {
                stage = .working("Looking through your footage")
                let frames = await FrameSampler.frames(for: clips)
                stage = .working("Claude is planning your edit")
                let body = try ClaudePlanner.requestBody(brief: brief, clips: clips, energy: energy, frames: frames)
                let response = try await ClaudeClient.send(body, apiKey: key)
                return try ClaudePlanner.plan(fromResponse: response, clips: clips)
            } catch {
                message = "\(error.localizedDescription) Used the basic planner instead."
            }
        }
        stage = .working("Choosing the best moments")
        let plan = EditPlanner.plan(clips: clips, style: EditBriefParser.parse(brief), energy: energy, visual: visual)
        guard !plan.segments.isEmpty else { throw EditError.empty }
        return plan
    }

    // MARK: Anthropic API key

    @Published var hasAPIKey = APIKeyStore.key != nil
    /// The connect screen opens by itself the first time the app runs.
    @Published var showingConnect = !UserDefaults.standard.bool(forKey: "connectedOnce")

    var finalCutReady: Bool { FinalCutBridge.supportsFCPXML110 }

    func finishConnecting() {
        UserDefaults.standard.set(true, forKey: "connectedOnce")
        showingConnect = false
    }

    func saveAPIKey(_ key: String) {
        APIKeyStore.save(key)
        hasAPIKey = APIKeyStore.key != nil
    }

    func removeAPIKey() {
        APIKeyStore.remove()
        hasAPIKey = APIKeyStore.key != nil
    }

    private func analyzeVideo() async {
        let pending = clips.filter { $0.hasVideo && visual[$0.id] == nil }
        await withTaskGroup(of: (UUID, VisualProfile?).self) { group in
            for clip in pending {
                group.addTask { (clip.id, await VisualAnalyzer.profile(of: clip)) }
            }
            for await (id, result) in group {
                if let result { visual[id] = result }
            }
        }
    }

    private func snapToBeat(_ segments: [Segment], song: MediaClip) async -> [Segment] {
        guard let envelope = try? await MediaProbe.audioEnergy(of: song.url, window: 0.01),
              let grid = BeatDetector.detect(envelope: envelope.values, hop: envelope.windowSeconds)
        else { return segments }
        return BeatSnapper.snap(segments, to: grid.beats, clips: clips)
    }

    private func makeCaptions(for plan: EditPlan) async -> [Caption] {
        let used = Set(plan.segments.map(\.clipID))
        for clip in clips where used.contains(clip.id) && clip.hasAudio && words[clip.id] == nil {
            do { words[clip.id] = try await SpeechTranscriber.words(in: clip) }
            catch {
                message = "No captions: \(error.localizedDescription)"
                return []
            }
        }
        return CaptionBuilder.captions(plan: plan, words: words)
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
        visual = [:]
        words = [:]
        settings = ExportSettings()
        message = nil
        stage = .drop
    }

    enum EditError: LocalizedError {
        case empty
        var errorDescription: String? { "The clips are too short to cut a vlog from. Try adding longer videos." }
    }
}
