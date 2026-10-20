import Foundation

public enum Pacing: String, Sendable, CaseIterable {
    case relaxed, balanced, fast

    /// Typical length of one shot, in seconds.
    public var shotLength: ClosedRange<Double> {
        switch self {
        case .relaxed: return 5...8
        case .balanced: return 3...5
        case .fast: return 1.5...2.5
        }
    }

    public var idealShot: Double { (shotLength.lowerBound + shotLength.upperBound) / 2 }
}

public enum ClipOrder: String, Sendable {
    /// By the time each clip was recorded.
    case chronological
    /// In the order the user dropped them in.
    case asImported
}

/// What the user's description asks for, in terms the planner understands.
public struct EditStyle: Equatable, Sendable {
    public var targetDuration: Double?
    public var pacing: Pacing
    public var order: ClipOrder
    public var crossDissolves: Bool
    public var title: String?
    /// Cut quiet, uneventful stretches. Off means keep every clip whole.
    public var trimToHighlights: Bool
    public var musicVolumeDB: Double
    /// Burn spoken words in as on-screen captions.
    public var captions: Bool
    /// Move cuts onto the beats of the music, when there is music.
    public var cutToBeat: Bool

    public init(
        targetDuration: Double? = nil,
        pacing: Pacing = .balanced,
        order: ClipOrder = .chronological,
        crossDissolves: Bool = false,
        title: String? = nil,
        trimToHighlights: Bool = true,
        musicVolumeDB: Double = -14,
        captions: Bool = false,
        cutToBeat: Bool = true
    ) {
        self.targetDuration = targetDuration
        self.pacing = pacing
        self.order = order
        self.crossDissolves = crossDissolves
        self.title = title
        self.trimToHighlights = trimToHighlights
        self.musicVolumeDB = musicVolumeDB
        self.captions = captions
        self.cutToBeat = cutToBeat
    }

    /// One plain sentence describing the style, shown back to the user.
    public var summary: String {
        var parts: [String] = []
        if let t = targetDuration { parts.append("about \(EditStyle.format(seconds: t))") }
        parts.append("\(pacing.rawValue) pacing")
        parts.append(crossDissolves ? "cross dissolves" : "straight cuts")
        if !trimToHighlights { parts.append("clips kept whole") }
        if captions { parts.append("captions") }
        if let title { parts.append("title “\(title)”") }
        return parts.joined(separator: ", ")
    }

    public static func format(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) seconds" }
        let m = s / 60, r = s % 60
        return r == 0 ? "\(m) min" : "\(m) min \(r) s"
    }
}

/// Turns a free-text description ("a fast 60 second travel vlog titled 'Lisbon'") into an `EditStyle`.
public enum EditBriefParser {
    public static func parse(_ text: String) -> EditStyle {
        var style = EditStyle()
        let lower = text.lowercased()

        style.title = title(in: text)
        // Keep the title's words out of the keyword matching below.
        var searchable = lower
        if let t = style.title?.lowercased() { searchable = searchable.replacingOccurrences(of: t, with: " ") }

        style.targetDuration = duration(in: searchable)
        if style.targetDuration == nil, containsAny(searchable, ["short vlog", "quick vlog", "short video", "teaser", "recap"]) {
            style.targetDuration = 60
        }

        if containsAny(searchable, ["fast", "upbeat", "energetic", "quick cuts", "snappy", "punchy", "hype", "dynamic"]) {
            style.pacing = .fast
        } else if containsAny(searchable, ["slow", "calm", "relaxed", "chill", "cinematic", "peaceful", "moody", "laid back", "laid-back"]) {
            style.pacing = .relaxed
        }

        if containsAny(searchable, ["no transition", "hard cut", "jump cut", "straight cut", "no dissolve"]) {
            style.crossDissolves = false
        } else if containsAny(searchable, ["dissolve", "crossfade", "cross fade", "cross-fade", "smooth transition", "transitions", "cinematic"]) {
            style.crossDissolves = true
        }

        if containsAny(searchable, ["as uploaded", "order i dropped", "order i uploaded", "same order", "keep the order", "in order given"]) {
            style.order = .asImported
        }

        if containsAny(searchable, ["keep everything", "don't cut", "dont cut", "do not cut", "full clips", "whole clips", "no trimming", "just join", "just stitch"]) {
            style.trimToHighlights = false
        }

        if containsAny(searchable, ["quiet music", "soft music", "music low", "background music"]) {
            style.musicVolumeDB = -18
        } else if containsAny(searchable, ["loud music", "music loud", "music up"]) {
            style.musicVolumeDB = -8
        }

        if containsAny(searchable, ["no captions", "no subtitles", "without captions", "without subtitles"]) {
            style.captions = false
        } else if containsAny(searchable, ["caption", "subtitle", "subtitled"]) {
            style.captions = true
        }

        if containsAny(searchable, ["not on the beat", "ignore the beat", "no beat", "off beat", "off-beat"]) {
            style.cutToBeat = false
        }

        return style
    }

    static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// Text after "title", "titled", "called" or "named", in quotes.
    static func title(in text: String) -> String? {
        let pattern = #"(?i)\b(?:title[d]?|called|named|name it)\s*(?:it\s*)?[:\-]?\s*["“'‘]([^"”'’]{1,80})["”'’]"#
        return firstCapture(pattern, in: text).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "90 seconds", "2 min", "1.5 minutes", "1:30", "60s".
    static func duration(in text: String) -> Double? {
        if let mmss = firstMatch(#"\b(\d{1,2}):([0-5]\d)\b"#, in: text, groups: 2),
           let m = Double(mmss[0]), let s = Double(mmss[1]) {
            return m * 60 + s
        }
        let pattern = #"\b(\d+(?:\.\d+)?)\s*-?\s*(seconds?|secs?|s|minutes?|mins?|m)\b"#
        guard let parts = firstMatch(pattern, in: text, groups: 2), let value = Double(parts[0]) else { return nil }
        let seconds = parts[1].hasPrefix("m") ? value * 60 : value
        return seconds > 0 ? seconds : nil
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        firstMatch(pattern, in: text, groups: 1)?.first
    }

    static func firstMatch(_ pattern: String, in text: String, groups: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var out: [String] = []
        for i in 1...groups {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            out.append(String(text[r]))
        }
        return out
    }
}
