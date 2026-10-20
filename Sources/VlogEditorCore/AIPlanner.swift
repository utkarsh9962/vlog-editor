import Foundation

/// A still frame from a clip, sent to a vision model so it can see what's in the footage.
public struct ClipFrame: Sendable {
    public var clipID: UUID
    /// Seconds into the clip.
    public var time: Double
    public var jpeg: Data

    public init(clipID: UUID, time: Double, jpeg: Data) {
        self.clipID = clipID
        self.time = time
        self.jpeg = jpeg
    }
}

/// What every AI planner shares: the editing instructions, the answer format, the description
/// of the clips, and the checks that turn an answer into a safe `EditPlan`.
/// The planners themselves run free on the Mac (Ollama, or Apple's on-device model).
public enum AIPlanner {
    public enum PlannerError: LocalizedError, Equatable {
        case unreadableAnswer
        case noUsableShots

        public var errorDescription: String? {
            switch self {
            case .unreadableAnswer: return "The AI's answer couldn't be read."
            case .noUsableShots: return "The AI's plan had no shots that fit the clips."
            }
        }
    }

    public static let instructions = """
    You are a professional vlog editor. You are given raw clips (with loudness per second, picture notes, \
    length and recording time, and sometimes sample frames) and the creator's description of the vlog they want. \
    Choose the shots for a finished, watchable vlog and list them in playback order.

    How to edit:
    - Follow the description first: requested length, mood, which moments to open or end on, what to leave out.
    - If no length is requested, pick one that suits the footage, usually 30 to 40 percent of it, between 30 seconds and 10 minutes.
    - Keep moments where someone is speaking whole; don't cut mid-sentence. Loud stretches usually mean speech or action.
    - Skip shaky starts and ends, blurry or blank frames, and repeated near-identical shots.
    - Shots should be at least 1 second. Match shot length to the mood: about 2 seconds for fast and upbeat, 6 or more for calm.
    - Times are seconds from the start of each clip and must lie within that clip.
    - Use a title only if the description asks for one or names the vlog. Otherwise return an empty title.
    - Use cross dissolves for calm or cinematic edits, or when asked. Use straight cuts for fast edits, or when asked.
    - music_volume_db sets the music bed level under the voices: -14 is typical, -20 quiet, -8 loud.
    - captions: true when the description asks for captions or subtitles.
    - cut_to_beat: true to move cuts onto the music's beats, unless the description asks otherwise or the edit is slow and speech-led.
    - summary is one plain sentence to the creator describing the edit you made.
    Answer with JSON only, in exactly this shape:
    {"shots":[{"clip":1,"start":0.0,"end":3.0}],"cross_dissolves":false,"title":"","music_volume_db":-14,"captions":false,"cut_to_beat":true,"summary":""}
    """

    public static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["shots", "cross_dissolves", "title", "music_volume_db", "captions", "cut_to_beat", "summary"],
        "properties": [
            "shots": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["clip", "start", "end"],
                    "properties": [
                        "clip": ["type": "integer"],
                        "start": ["type": "number"],
                        "end": ["type": "number"],
                    ],
                ],
            ],
            "cross_dissolves": ["type": "boolean"],
            "title": ["type": "string"],
            "music_volume_db": ["type": "number"],
            "captions": ["type": "boolean"],
            "cut_to_beat": ["type": "boolean"],
            "summary": ["type": "string"],
        ],
    ]

    /// The clips the AI can choose from, numbered from 1 in the order the user added them.
    static func videoClips(_ clips: [MediaClip]) -> [MediaClip] {
        clips.filter { $0.hasVideo && $0.duration >= 1 }
    }

    /// The description, the clip list and what the app measured about each clip, as plain text.
    /// With `maxCharacters`, loudness is averaged over longer stretches until the text fits.
    public static func prompt(
        brief: String,
        clips: [MediaClip],
        energy: [UUID: AudioEnergy],
        visual: [UUID: VisualProfile] = [:],
        maxCharacters: Int? = nil
    ) -> String {
        var step = 1
        var text = prompt(brief: brief, clips: clips, energy: energy, visual: visual, secondsPerDigit: step)
        while let limit = maxCharacters, text.count > limit, step < 64 {
            step *= 2
            text = prompt(brief: brief, clips: clips, energy: energy, visual: step <= 2 ? visual : [:], secondsPerDigit: step)
        }
        return text
    }

    static func prompt(
        brief: String,
        clips: [MediaClip],
        energy: [UUID: AudioEnergy],
        visual: [UUID: VisualProfile],
        secondsPerDigit step: Int
    ) -> String {
        let video = videoClips(clips)
        let music = clips.filter(\.isAudioOnly)
        let date = ISO8601DateFormatter()

        var lines = ["Description from the creator:", brief.isEmpty ? "(none, make a good general vlog)" : brief, "", "Clips:"]
        for (i, clip) in video.enumerated() {
            var line = "Clip \(i + 1): \(clip.name), \(String(format: "%.1f", clip.duration))s, \(clip.isPortrait ? "vertical" : "horizontal")"
            if let d = clip.creationDate { line += ", recorded \(date.string(from: d))" }
            if let e = energy[clip.id] {
                let unit = step == 1 ? "per second" : "per \(step) seconds"
                line += "\n  loudness \(unit) (0 quiet to 9 loud): \(loudnessDigits(e, secondsPerDigit: step))"
            }
            else if !clip.hasAudio { line += "\n  no sound" }
            if let v = visual[clip.id], !v.times.isEmpty {
                let notes = zip(v.times, v.scores).map { "\(String(format: "%.0f", $0))s:\(Int(($1 * 9).rounded()))" }
                line += "\n  picture quality at times (0 poor to 9 sharp, steady, people): " + notes.joined(separator: " ")
            }
            lines.append(line)
        }
        if !music.isEmpty {
            lines.append("")
            lines.append("Music bed (plays under the whole edit): " + music.map { "\($0.name) (\(Int($0.duration))s)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Loudness as one digit per `secondsPerDigit` seconds, scaled to the clip's own range.
    static func loudnessDigits(_ energy: AudioEnergy, secondsPerDigit: Int = 1) -> String {
        let perSecond = max(1, Int((Double(secondsPerDigit) / energy.windowSeconds).rounded()))
        var seconds: [Float] = []
        var i = 0
        while i < energy.values.count {
            let chunk = energy.values[i..<min(i + perSecond, energy.values.count)]
            seconds.append(chunk.reduce(0, +) / Float(chunk.count))
            i += perSecond
        }
        let peak = seconds.max() ?? 0
        guard peak > 0 else { return String(repeating: "0", count: seconds.count) }
        return seconds.map { String(min(9, Int(($0 / peak * 9).rounded()))) }.joined()
    }

    /// Turns the AI's JSON answer into an `EditPlan`, dropping or trimming any shot that doesn't fit its clip.
    /// Tolerates text around the JSON, which small local models sometimes add.
    public static func plan(fromAnswer text: String, clips: [MediaClip]) throws -> EditPlan {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let json = String(text[open...close]).data(using: .utf8),
              let answer = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let shots = answer["shots"] as? [[String: Any]] else {
            throw PlannerError.unreadableAnswer
        }

        let video = videoClips(clips)
        guard !video.isEmpty else { throw PlannerError.noUsableShots }
        var segments: [Segment] = []
        for shot in shots {
            guard let n = (shot["clip"] as? NSNumber)?.intValue, (1...video.count).contains(n),
                  let start = (shot["start"] as? NSNumber)?.doubleValue,
                  let end = (shot["end"] as? NSNumber)?.doubleValue else { continue }
            let clip = video[n - 1]
            let s = max(0, start), e = min(clip.duration, end)
            guard e - s >= 0.5 else { continue }
            segments.append(Segment(clipID: clip.id, sourceStart: s, duration: e - s))
        }
        guard !segments.isEmpty else { throw PlannerError.noUsableShots }

        let title = (answer["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let volume = (answer["music_volume_db"] as? NSNumber)?.doubleValue ?? -14
        let style = EditStyle(
            crossDissolves: answer["cross_dissolves"] as? Bool ?? false,
            title: title.isEmpty ? nil : title,
            musicVolumeDB: min(0, max(-30, volume)),
            captions: answer["captions"] as? Bool ?? false,
            cutToBeat: answer["cut_to_beat"] as? Bool ?? true
        )
        return EditPlan(segments: segments, music: clips.filter(\.isAudioOnly), style: style,
                        notes: answer["summary"] as? String)
    }
}

/// Ollama runs open models on the Mac for free (https://ollama.com). With a vision model it sees sample frames.
public enum OllamaPlanner {
    public static let baseURL = URL(string: "http://localhost:11434")!
    /// A vision model that fits in 16 GB Macs. `gemma3:4b` suits 8 GB Macs.
    public static let defaultModel = "qwen2.5vl:7b"

    public static var chatURL: URL { baseURL.appendingPathComponent("api/chat") }
    public static var tagsURL: URL { baseURL.appendingPathComponent("api/tags") }
    public static var pullURL: URL { baseURL.appendingPathComponent("api/pull") }

    public static func requestBody(
        model: String,
        brief: String,
        clips: [MediaClip],
        energy: [UUID: AudioEnergy],
        visual: [UUID: VisualProfile],
        frames: [ClipFrame]
    ) throws -> Data {
        let index = Dictionary(uniqueKeysWithValues: AIPlanner.videoClips(clips).enumerated().map { ($1.id, $0 + 1) })
        let shown = frames.filter { index[$0.clipID] != nil }
        var text = AIPlanner.prompt(brief: brief, clips: clips, energy: energy, visual: visual)
        if !shown.isEmpty {
            text += "\n\nThe attached images are sample frames, in this order: "
                + shown.map { "clip \(index[$0.clipID]!) at \(String(format: "%.1f", $0.time))s" }.joined(separator: "; ")
        }
        var user: [String: Any] = ["role": "user", "content": text]
        if !shown.isEmpty { user["images"] = shown.map { $0.jpeg.base64EncodedString() } }

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": AIPlanner.schema,
            "options": ["temperature": 0.2, "num_ctx": 32_768],
            "messages": [["role": "system", "content": AIPlanner.instructions], user],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The answer text from an /api/chat response.
    public static func answer(fromResponse data: Data) throws -> String {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = response["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIPlanner.PlannerError.unreadableAnswer
        }
        return content
    }

    /// Whether an /api/tags response lists the model (Ollama adds ":latest" when no tag is given).
    public static func hasModel(_ model: String, inTags data: Data) -> Bool {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = response["models"] as? [[String: Any]] else { return false }
        let names = models.compactMap { $0["name"] as? String }
        let wanted = model.contains(":") ? model : model + ":latest"
        return names.contains(wanted)
    }
}
