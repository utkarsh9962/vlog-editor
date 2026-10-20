import Foundation

/// Beat times of a music track, in seconds from its start.
public struct BeatGrid: Equatable, Sendable {
    public var beats: [Double]
    public var bpm: Double

    public init(beats: [Double], bpm: Double) {
        self.beats = beats
        self.bpm = bpm
    }
}

/// Finds the beat of a song from its loudness envelope.
public enum BeatDetector {
    /// `envelope` is loudness sampled every `hop` seconds (about 0.01s works well).
    public static func detect(envelope: [Float], hop: Double) -> BeatGrid? {
        let n = envelope.count
        guard hop > 0, Double(n) * hop >= 6 else { return nil }

        // Onset strength: how sharply loudness rises at each step.
        var onset = [Double](repeating: 0, count: n)
        for i in 1..<n {
            onset[i] = max(0, log(1e-4 + Double(envelope[i])) - log(1e-4 + Double(envelope[i - 1])))
        }
        let mean = onset.reduce(0, +) / Double(n)
        onset = onset.map { max(0, $0 - mean) }
        guard onset.contains(where: { $0 > 0 }) else { return nil }

        // Tempo: the lag where the onsets line up best with themselves, between 70 and 180 BPM,
        // gently preferring tempos near 120 so we don't lock onto half or double time.
        let minLag = max(1, Int((60.0 / 180.0) / hop))
        let maxLag = min(n / 3, Int((60.0 / 70.0) / hop))
        guard minLag < maxLag else { return nil }
        func autocorrelation(_ lag: Int) -> Double {
            var sum = 0.0
            for i in 0..<(n - lag) { sum += onset[i] * onset[i + lag] }
            return sum / Double(n - lag)
        }
        let scores = (minLag...maxLag).map { lag -> Double in
            let bpm = 60 / (Double(lag) * hop)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.6, 2))
            return autocorrelation(lag) * prior
        }
        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[bestIndex] > 0 else { return nil }

        // Refine the period between samples so long songs don't drift off the beat.
        var period = Double(minLag + bestIndex)
        if bestIndex > 0, bestIndex < scores.count - 1 {
            let a = scores[bestIndex - 1], b = scores[bestIndex], c = scores[bestIndex + 1]
            let denom = a - 2 * b + c
            if denom != 0 { period += max(-0.5, min(0.5, 0.5 * (a - c) / denom)) }
        }

        // Phase: where in one period the beats fall.
        var bestPhase = 0.0, bestSum = -1.0
        var phase = 0.0
        while phase < period {
            var sum = 0.0
            var t = phase
            while Int(t.rounded()) < n {
                sum += onset[Int(t.rounded())]
                t += period
            }
            if sum > bestSum { bestSum = sum; bestPhase = phase }
            phase += 1
        }

        var beats: [Double] = []
        var t = bestPhase
        while t < Double(n) {
            beats.append(t * hop)
            t += period
        }
        return BeatGrid(beats: beats, bpm: 60 / (period * hop))
    }
}

/// Moves cuts onto beats.
public enum BeatSnapper {
    /// Shifts each cut to the nearest beat, by at most `maxShift` seconds, keeping every shot
    /// inside its clip and at least `minShot` long. The last shot's end is left alone.
    public static func snap(
        _ segments: [Segment],
        to beats: [Double],
        clips: [MediaClip],
        minShot: Double = 1,
        maxShift: Double = 0.75
    ) -> [Segment] {
        guard segments.count > 1, !beats.isEmpty else { return segments }
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var out = segments
        var cut = 0.0
        for i in 0..<(out.count - 1) {
            let seg = out[i]
            let natural = cut + seg.duration
            let available = (byID[seg.clipID]?.duration ?? seg.sourceEnd) - seg.sourceStart
            let candidates = beats
                .filter { abs($0 - natural) <= maxShift }
                .sorted { abs($0 - natural) < abs($1 - natural) }
            if let beat = candidates.first(where: { $0 - cut >= minShot && $0 - cut <= available }) {
                out[i].duration = beat - cut
            }
            cut += out[i].duration
        }
        return out
    }
}
