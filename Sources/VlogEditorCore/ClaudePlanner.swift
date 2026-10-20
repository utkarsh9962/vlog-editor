import Foundation

/// A still frame from a clip, sent to Claude so it can see what's in the footage.
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

/// Plans the edit with Claude: it sees sample frames, loudness and timing for every clip,
/// reads the user's description, and returns the shots to use in playback order.
/// This file only builds the request and checks the answer; the app sends it.
public enum ClaudePlanner {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let model = "claude-opus-5-5"
    public static let headers = [
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
        // Lets the API retry on another model if a safety check declines the request.
        "anthropic-beta": "server-side-fallback-2026-07-01",
    ]

    public enum PlannerError: LocalizedError, Equatable {
        case declined
        case unreadableAnswer
        case noUsableShots

        public var errorDescription: String? {
            switch self {
            case .declined: return "Claude declined to plan this edit."
            case .unreadableAnswer: return "Claude's answer couldn't be read."
            case .noUsableShots: return "Claude's plan had no shots that fit the clips."
            }
        }
    }

    static let system = """
    You are a professional vlog editor. You are given raw clips (with sample frames, loudness per second, \
    length and recording time) and the creator's description of the vlog they want. Choose the shots for a \
    finished, watchable vlog and list them in playback order.

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
    - captions: true when the description asks for captions or subtitles, or the vlog is mostly someone talking to camera for a vertical platform.
    - cut_to_beat: true to move cuts onto the music's beats (when there is music), unless the description asks otherwise or the edit is slow and speech-led.
    - summary is one plain sentence to the creator describing the edit you made.
    """

    static let schema: [String: Any] = [
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
                        "clip": ["type": "integer", "description": "Clip number as listed"],
                        "start": ["type": "number", "description": "Seconds into the clip"],
                        "end": ["type": "number", "description": "Seconds into the clip"],
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

    /// The clips Claude can choose from, numbered from 1 in the order the user added them.
    static func videoClips(_ clips: [MediaClip]) -> [MediaClip] {
        clips.filter { $0.hasVideo && $0.duration >= 1 }
    }

    public static func requestBody(
        brief: String,
        clips: [MediaClip],
        energy: [UUID: AudioEnergy],
        frames: [ClipFrame]
    ) throws -> Data {
        let video = videoClips(clips)
        let music = clips.filter(\.isAudioOnly)
        let date = ISO8601DateFormatter()

        var lines = ["Description from the creator:", brief.isEmpty ? "(none, make a good general vlog)" : brief, "", "Clips:"]
        for (i, clip) in video.enumerated() {
            var line = "Clip \(i + 1): \(clip.name), \(String(format: "%.1f", clip.duration))s, \(clip.isPortrait ? "vertical" : "horizontal")"
            if let d = clip.creationDate { line += ", recorded \(date.string(from: d))" }
            if let e = energy[clip.id] { line += "\n  loudness per second (0 quiet to 9 loud): \(loudnessDigits(e))" }
            else if !clip.hasAudio { line += "\n  no sound" }
            lines.append(line)
        }
        if !music.isEmpty {
            lines.append("")
            lines.append("Music bed (plays under the whole edit): " + music.map { "\($0.name) (\(Int($0.duration))s)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append("Sample frames follow, each labeled with its clip and time.")

        var content: [[String: Any]] = [["type": "text", "text": lines.joined(separator: "\n")]]
        let index = Dictionary(uniqueKeysWithValues: video.enumerated().map { ($1.id, $0 + 1) })
        for frame in frames {
            guard let n = index[frame.clipID] else { continue }
            content.append(["type": "text", "text": "Clip \(n) at \(String(format: "%.1f", frame.time))s:"])
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": frame.jpeg.base64EncodedString()],
            ])
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "fallbacks": "default",
            "system": system,
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": content]],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Loudness as one digit per second, scaled to the clip's own range.
    static func loudnessDigits(_ energy: AudioEnergy) -> String {
        let perSecond = max(1, Int((1 / energy.windowSeconds).rounded()))
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

    /// Turns Claude's answer into an `EditPlan`, dropping or trimming any shot that doesn't fit its clip.
    public static func plan(fromResponse data: Data, clips: [MediaClip]) throws -> EditPlan {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlannerError.unreadableAnswer
        }
        if response["stop_reason"] as? String == "refusal" { throw PlannerError.declined }
        let blocks = response["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard let json = text.data(using: .utf8),
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
