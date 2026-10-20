import Foundation

/// One shot on the timeline: a range of one source clip.
public struct Segment: Equatable, Sendable {
    public var clipID: UUID
    /// Seconds into the source clip.
    public var sourceStart: Double
    public var duration: Double

    public init(clipID: UUID, sourceStart: Double, duration: Double) {
        self.clipID = clipID
        self.sourceStart = sourceStart
        self.duration = duration
    }

    public var sourceEnd: Double { sourceStart + duration }
}

/// The finished edit decision list: what plays, in what order, with what music.
public struct EditPlan: Equatable, Sendable {
    public var segments: [Segment]
    public var music: [MediaClip]
    public var style: EditStyle
    /// The AI's one-line description of the edit, when an AI planned it.
    public var notes: String? = nil
    /// On-screen captions, timed on the finished edit.
    public var captions: [Caption] = []

    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }
}

public enum EditPlanner {
    /// Shortest shot worth keeping, in seconds.
    static let minimumShot = 1.0
    /// Gaps smaller than this between two shots of the same clip get closed, so there is no stutter cut.
    static let mergeGap = 0.4

    public static func plan(
        clips: [MediaClip],
        style: EditStyle,
        energy: [UUID: AudioEnergy] = [:],
        visual: [UUID: VisualProfile] = [:]
    ) -> EditPlan {
        let music = clips.filter(\.isAudioOnly)
        let video = order(clips.filter { $0.hasVideo && $0.duration >= minimumShot }, by: style.order)
        let total = video.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return EditPlan(segments: [], music: music, style: style) }

        let target = min(total, style.targetDuration ?? defaultTarget(total: total, style: style))
        if !style.trimToHighlights || target >= total * 0.98 {
            let whole = video.map { Segment(clipID: $0.id, sourceStart: 0, duration: $0.duration) }
            return EditPlan(segments: whole, music: music, style: style)
        }

        var segments: [Segment] = []
        for clip in video {
            let budget = target * clip.duration / total
            segments += shots(in: clip, budget: budget, pacing: style.pacing, energy: energy[clip.id], visual: visual[clip.id])
        }
        return EditPlan(segments: segments, music: music, style: style)
    }

    /// When the user names no length: about 40% of the footage, between 30 seconds and 10 minutes.
    static func defaultTarget(total: Double, style: EditStyle) -> Double {
        min(total, max(30, min(600, total * 0.4)))
    }

    static func order(_ clips: [MediaClip], by order: ClipOrder) -> [MediaClip] {
        guard order == .chronological else { return clips }
        return clips.enumerated().sorted { a, b in
            switch (a.element.creationDate, b.element.creationDate) {
            case let (da?, db?) where da != db: return da < db
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Picks the best `budget` seconds of one clip, split into shots that suit the pacing.
    static func shots(in clip: MediaClip, budget: Double, pacing: Pacing, energy: AudioEnergy?, visual: VisualProfile? = nil) -> [Segment] {
        // Skip the first and last moments, where the camera is usually still being raised or lowered.
        let lead = min(0.5, clip.duration * 0.1)
        let usableStart = lead
        let usableEnd = clip.duration - lead
        let usable = usableEnd - usableStart
        guard usable >= minimumShot, budget >= minimumShot * 0.5 else { return [] }

        let wanted = min(budget, usable)
        let count = max(1, Int((wanted / pacing.idealShot).rounded()))
        let shotLength = max(minimumShot, wanted / Double(count))

        var picks: [Segment]
        if let score = scorer(energy: energy, visual: visual) {
            picks = bestWindows(count: count, length: shotLength, from: usableStart, to: usableEnd, score: score, clipID: clip.id)
        } else {
            picks = evenlySpaced(count: count, length: shotLength, from: usableStart, to: usableEnd, clipID: clip.id)
        }
        picks.sort { $0.sourceStart < $1.sourceStart }
        return merge(picks)
    }

    static func evenlySpaced(count: Int, length: Double, from start: Double, to end: Double, clipID: UUID) -> [Segment] {
        let span = end - start
        let length = min(length, span / Double(count))
        let slack = span - length * Double(count)
        return (0..<count).map { k in
            let s = start + slack * (Double(k) + 0.5) / Double(count) + length * Double(k)
            return Segment(clipID: clipID, sourceStart: s, duration: length)
        }
    }

    /// Rates a window of a clip: sound counts for 60% (speech, action), picture for 40% (sharp, steady, faces).
    static func scorer(energy: AudioEnergy?, visual: VisualProfile?) -> ((Double, Double) -> Float)? {
        let energy = energy.flatMap { $0.values.isEmpty ? nil : $0 }
        let visual = visual.flatMap { $0.times.isEmpty ? nil : $0 }
        let peak = max(energy?.values.max() ?? 0, 1e-6)
        switch (energy, visual) {
        case (nil, nil): return nil
        case let (e?, nil): return { e.mean(from: $0, duration: $1) / peak }
        case let (nil, v?): return { v.mean(from: $0, duration: $1) ?? 0 }
        case let (e?, v?): return { 0.6 * e.mean(from: $0, duration: $1) / peak + 0.4 * (v.mean(from: $0, duration: $1) ?? 0) }
        }
    }

    static func bestWindows(count: Int, length: Double, from start: Double, to end: Double, score: (Double, Double) -> Float, clipID: UUID) -> [Segment] {
        let step = 0.25
        var candidates: [(start: Double, score: Float)] = []
        var s = start
        while s + length <= end + 0.0001 {
            candidates.append((s, score(s, length)))
            s += step
        }
        if candidates.isEmpty { return evenlySpaced(count: count, length: length, from: start, to: end, clipID: clipID) }

        var taken: [Segment] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            if taken.count == count { break }
            let overlaps = taken.contains { candidate.start < $0.sourceEnd && $0.sourceStart < candidate.start + length }
            if !overlaps { taken.append(Segment(clipID: clipID, sourceStart: candidate.start, duration: length)) }
        }
        return taken
    }

    /// Joins shots of the same clip that nearly touch.
    static func merge(_ sorted: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for seg in sorted {
            if var last = out.last, last.clipID == seg.clipID, seg.sourceStart - last.sourceEnd < mergeGap {
                last.duration = max(last.sourceEnd, seg.sourceEnd) - last.sourceStart
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        return out
    }
}
