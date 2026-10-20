import AVFoundation
import AppKit
import VlogEditorCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which free AI the app can use to plan edits, best first.
enum AIStatus: Equatable {
    /// Ollama is running and has the vision model: it sees frames from the clips.
    case ollama(model: String)
    /// Ollama is running but the model hasn't been downloaded yet.
    case ollamaMissingModel(model: String)
    /// Apple's on-device model (macOS 26, Apple Intelligence on). It reads the app's notes about each clip.
    case appleIntelligence
    /// Neither: the built-in keyword planner is used.
    case none

    var isReady: Bool {
        switch self {
        case .ollama, .appleIntelligence: return true
        case .ollamaMissingModel, .none: return false
        }
    }

    var label: String {
        switch self {
        case .ollama(let model): return "Ollama (\(model))"
        case .appleIntelligence: return "Apple Intelligence"
        case .ollamaMissingModel, .none: return "Basic planner"
        }
    }
}

enum LocalAI {
    static var ollamaModel: String {
        get { UserDefaults.standard.string(forKey: "ollamaModel").flatMap { $0.isEmpty ? nil : $0 } ?? OllamaPlanner.defaultModel }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "ollamaModel") }
    }

    static var appleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static func status() async -> AIStatus {
        let model = ollamaModel
        var request = URLRequest(url: OllamaPlanner.tagsURL, timeoutInterval: 2)
        request.httpMethod = "GET"
        if let reply = try? await URLSession.shared.data(for: request),
           (reply.1 as? HTTPURLResponse)?.statusCode == 200 {
            if OllamaPlanner.hasModel(model, inTags: reply.0) { return .ollama(model: model) }
            if !appleIntelligenceAvailable { return .ollamaMissingModel(model: model) }
        }
        return appleIntelligenceAvailable ? .appleIntelligence : .none
    }

    enum LocalAIError: LocalizedError {
        case ollama(String)
        var errorDescription: String? {
            switch self {
            case .ollama(let why): return "Ollama couldn't plan the edit: \(why)."
            }
        }
    }

    /// Plans the edit with whichever free AI is ready. Throws if it fails, so the caller can fall back.
    static func plan(
        status: AIStatus,
        brief: String,
        clips: [MediaClip],
        energy: [UUID: AudioEnergy],
        visual: [UUID: VisualProfile]
    ) async throws -> EditPlan? {
        switch status {
        case .ollama(let model):
            let frames = await FrameSampler.frames(for: clips, limit: 24)
            let body = try OllamaPlanner.requestBody(model: model, brief: brief, clips: clips,
                                                     energy: energy, visual: visual, frames: frames)
            var request = URLRequest(url: OllamaPlanner.chatURL, timeoutInterval: 900)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let why = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw LocalAIError.ollama(why ?? "it returned an error")
            }
            return try AIPlanner.plan(fromAnswer: OllamaPlanner.answer(fromResponse: data), clips: clips)

        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                // The on-device model has a small context window, so keep the clip notes short.
                let prompt = AIPlanner.prompt(brief: brief, clips: clips, energy: energy, visual: visual, maxCharacters: 6_000)
                let session = LanguageModelSession(instructions: AIPlanner.instructions)
                let response = try await session.respond(to: prompt)
                return try AIPlanner.plan(fromAnswer: response.content, clips: clips)
            }
            #endif
            return nil

        case .ollamaMissingModel, .none:
            return nil
        }
    }

    /// Downloads a model into Ollama. Can take a while: vision models are several gigabytes.
    static func pull(_ model: String) async throws {
        var request = URLRequest(url: OllamaPlanner.pullURL, timeoutInterval: 3 * 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": false])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let why = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw LocalAIError.ollama(why ?? "the download failed")
        }
    }
}

/// Pulls small still frames from each clip so a vision model can see the footage.
enum FrameSampler {
    /// Frames spread evenly over the footage, at most `limit` across all clips, at least one per clip.
    static func frames(for clips: [MediaClip], limit: Int) async -> [ClipFrame] {
        let video = clips.filter { $0.hasVideo && $0.duration >= 1 }
        let total = video.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return [] }

        var out: [ClipFrame] = []
        for clip in video {
            let count = max(1, Int((Double(limit) * clip.duration / total).rounded(.down)))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 384, height: 384)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            for k in 0..<count {
                let t = clip.duration * (Double(k) + 0.5) / Double(count)
                guard let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)),
                      let jpeg = NSBitmapImageRep(cgImage: result.image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
                else { continue }
                out.append(ClipFrame(clipID: clip.id, time: t, jpeg: jpeg))
            }
        }
        return out
    }
}
