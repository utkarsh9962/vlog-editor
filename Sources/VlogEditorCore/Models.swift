import Foundation

/// A video or audio file the user dropped in, with the facts the editor needs.
public struct MediaClip: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    /// Seconds.
    public var duration: Double
    public var frameRate: Double
    /// Display size, after the file's rotation is applied.
    public var width: Int
    public var height: Int
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var audioChannels: Int
    public var audioRate: Int
    /// Seconds of embedded start timecode (0 when the file has none).
    public var timecodeStart: Double
    public var creationDate: Date?

    public init(
        id: UUID = UUID(),
        url: URL,
        duration: Double,
        frameRate: Double = 30,
        width: Int = 1920,
        height: Int = 1080,
        hasVideo: Bool = true,
        hasAudio: Bool = true,
        audioChannels: Int = 2,
        audioRate: Int = 48_000,
        timecodeStart: Double = 0,
        creationDate: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.duration = duration
        self.frameRate = frameRate
        self.width = width
        self.height = height
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.audioChannels = audioChannels
        self.audioRate = audioRate
        self.timecodeStart = timecodeStart
        self.creationDate = creationDate
    }

    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var isAudioOnly: Bool { !hasVideo && hasAudio }
    public var isPortrait: Bool { height > width }
}

/// Loudness of a clip's audio, one value per window. Louder windows usually hold talking or action.
public struct AudioEnergy: Sendable, Equatable {
    public var windowSeconds: Double
    public var values: [Float]

    public init(windowSeconds: Double, values: [Float]) {
        self.windowSeconds = windowSeconds
        self.values = values
    }

    /// Mean energy over a time range, in seconds.
    public func mean(from start: Double, duration: Double) -> Float {
        guard !values.isEmpty, windowSeconds > 0 else { return 0 }
        let first = max(0, Int(start / windowSeconds))
        let last = min(values.count - 1, Int((start + duration) / windowSeconds))
        guard first <= last else { return 0 }
        let slice = values[first...last]
        return slice.reduce(0, +) / Float(slice.count)
    }
}

// MARK: - Export questions

public enum Platform: String, CaseIterable, Identifiable, Sendable {
    case youtube, youtubeShorts, instagramReels, instagramFeed, tiktok, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .youtubeShorts: return "YouTube Shorts"
        case .instagramReels: return "Instagram Reels"
        case .instagramFeed: return "Instagram Feed"
        case .tiktok: return "TikTok"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .youtube: return "play.rectangle"
        case .youtubeShorts, .instagramReels, .tiktok: return "iphone"
        case .instagramFeed: return "square.grid.3x3"
        case .other: return "film"
        }
    }

    public var recommendedAspect: AspectRatio {
        switch self {
        case .youtube, .other: return .landscape
        case .youtubeShorts, .instagramReels, .tiktok: return .vertical
        case .instagramFeed: return .portrait4x5
        }
    }

    public var recommendedQuality: Quality {
        self == .youtube ? .uhd4k : .hd1080
    }

    /// Longest video the platform takes in this format, in seconds.
    public var maxDuration: Double? {
        switch self {
        case .youtubeShorts, .instagramReels: return 180
        case .tiktok: return 600
        case .instagramFeed: return 3600
        case .youtube, .other: return nil
        }
    }
}

public enum AspectRatio: String, CaseIterable, Identifiable, Sendable {
    case landscape, vertical, square, portrait4x5

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .landscape: return "16:9"
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .portrait4x5: return "4:5"
        }
    }

    public var subtitle: String {
        switch self {
        case .landscape: return "Wide"
        case .vertical: return "Vertical"
        case .square: return "Square"
        case .portrait4x5: return "Portrait"
        }
    }

    var ratio: (w: Int, h: Int) {
        switch self {
        case .landscape: return (16, 9)
        case .vertical: return (9, 16)
        case .square: return (1, 1)
        case .portrait4x5: return (4, 5)
        }
    }

    /// Canvas size where the shorter side equals `shortSide`, rounded to even pixels.
    public func canvas(shortSide: Int) -> (width: Int, height: Int) {
        let (w, h) = ratio
        func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
        if w >= h {
            return (even(Double(shortSide) * Double(w) / Double(h)), shortSide)
        } else {
            return (shortSide, even(Double(shortSide) * Double(h) / Double(w)))
        }
    }
}

public enum Quality: String, CaseIterable, Identifiable, Sendable {
    case hd720, hd1080, uhd4k

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4k: return "4K"
        }
    }

    public var subtitle: String {
        switch self {
        case .hd720: return "Small file"
        case .hd1080: return "Standard"
        case .uhd4k: return "Best"
        }
    }

    public var shortSide: Int {
        switch self {
        case .hd720: return 720
        case .hd1080: return 1080
        case .uhd4k: return 2160
        }
    }
}

public struct ExportSettings: Equatable, Sendable {
    public var platform: Platform
    public var aspect: AspectRatio
    public var quality: Quality

    public init(platform: Platform = .youtube, aspect: AspectRatio? = nil, quality: Quality? = nil) {
        self.platform = platform
        self.aspect = aspect ?? platform.recommendedAspect
        self.quality = quality ?? platform.recommendedQuality
    }

    public var canvas: (width: Int, height: Int) { aspect.canvas(shortSide: quality.shortSide) }
}
