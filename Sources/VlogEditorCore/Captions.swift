import Foundation

/// A word heard in a clip, timed in seconds from the clip's start.
public struct SpokenWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var duration: Double

    public init(text: String, start: Double, duration: Double) {
        self.text = text
        self.start = start
        self.duration = duration
    }

    public var end: Double { start + duration }
}

/// One on-screen caption, timed in seconds on the finished edit.
public struct Caption: Equatable, Sendable {
    public var start: Double
    public var duration: Double
    public var text: String

    public init(start: Double, duration: Double, text: String) {
        self.start = start
        self.duration = duration
        self.text = text
    }

    public var end: Double { start + duration }
}

public enum CaptionBuilder {
    /// Groups the words that survive the edit into short captions, a few words at a time,
    /// breaking at pauses and at cuts.
    public static func captions(
        plan: EditPlan,
        words: [UUID: [SpokenWord]],
        maxWords: Int = 6,
        maxDuration: Double = 3,
        pause: Double = 0.6
    ) -> [Caption] {
        var out: [Caption] = []
        var cursor = 0.0
        for seg in plan.segments {
            let timed = (words[seg.clipID] ?? [])
                .filter { $0.start >= seg.sourceStart - 0.05 && $0.end <= seg.sourceEnd + 0.15 }
                .sorted { $0.start < $1.start }
                .map { (word: $0, t: cursor + $0.start - seg.sourceStart) }
            let segmentEnd = cursor + seg.duration

            var group: [(word: SpokenWord, t: Double)] = []
            func flush() {
                guard let first = group.first, let last = group.last else { return }
                let start = max(cursor, first.t)
                let end = min(segmentEnd, max(last.t + last.word.duration, start + 0.6))
                let text = group.map { $0.word.text }.joined(separator: " ")
                if end > start { out.append(Caption(start: start, duration: end - start, text: text)) }
                group = []
            }
            for item in timed {
                if let first = group.first, let last = group.last,
                   group.count >= maxWords
                    || item.t - (last.t + last.word.duration) > pause
                    || item.t + item.word.duration - first.t > maxDuration {
                    flush()
                }
                group.append(item)
            }
            flush()
            cursor = segmentEnd
        }
        // A caption stretched to its minimum length must not run into the next one.
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            out[i].duration = max(0.1, out[i + 1].start - out[i].start)
        }
        return out
    }
}
