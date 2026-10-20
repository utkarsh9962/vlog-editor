import Foundation

/// A frame rate expressed as FCPXML's rational frame duration, e.g. 1001/30000s for 29.97 fps.
public struct FrameRate: Equatable, Hashable, Sendable {
    public var numerator: Int
    public var denominator: Int

    public var fps: Double { Double(denominator) / Double(numerator) }
    public var frameDuration: String { "\(numerator)/\(denominator)s" }

    /// Snaps a measured rate (phones report things like 29.98) to the nearest broadcast rate.
    public static func nearest(to fps: Double) -> FrameRate {
        let standard: [(Double, FrameRate)] = [
            (23.976, FrameRate(numerator: 1001, denominator: 24000)),
            (24, FrameRate(numerator: 100, denominator: 2400)),
            (25, FrameRate(numerator: 100, denominator: 2500)),
            (29.97, FrameRate(numerator: 1001, denominator: 30000)),
            (30, FrameRate(numerator: 100, denominator: 3000)),
            (50, FrameRate(numerator: 100, denominator: 5000)),
            (59.94, FrameRate(numerator: 1001, denominator: 60000)),
            (60, FrameRate(numerator: 100, denominator: 6000)),
        ]
        let best = standard.min { abs($0.0 - fps) < abs($1.0 - fps) }!
        return abs(best.0 - fps) < 1.5 ? best.1 : FrameRate(numerator: 100, denominator: 3000)
    }

    public func frames(_ seconds: Double) -> Int { Int((seconds * fps).rounded()) }
    public func floorFrames(_ seconds: Double) -> Int { Int((seconds * fps + 0.0001).rounded(.down)) }

    /// A frame count as an FCPXML time value, reduced: "0s", "3003/1000s", "5s".
    public func time(frames: Int) -> String {
        if frames == 0 { return "0s" }
        var num = frames * numerator, den = denominator
        let g = gcd(abs(num), den)
        num /= g; den /= g
        return den == 1 ? "\(num)s" : "\(num)/\(den)s"
    }

    public func time(_ seconds: Double) -> String { time(frames: frames(seconds)) }
}

extension FrameRate {
    /// `a` frames at `ra` plus `b` frames at `rb`, as one exact FCPXML time value.
    static func sum(_ a: Int, _ ra: FrameRate, _ b: Int, _ rb: FrameRate) -> String {
        var num = a * ra.numerator * rb.denominator + b * rb.numerator * ra.denominator
        var den = ra.denominator * rb.denominator
        if num == 0 { return "0s" }
        let g = gcd(abs(num), den)
        num /= g; den /= g
        return den == 1 ? "\(num)s" : "\(num)/\(den)s"
    }
}

func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(a, 1) : gcd(b, a % b) }

/// Writes an FCPXML 1.10 document (Final Cut Pro 10.6 and later) for an `EditPlan`.
/// Importing it creates an event and a project with every cut, transition, title and music bed in place.
public struct FCPXMLBuilder {
    public var projectName: String
    public var eventName: String
    public var canvasWidth: Int
    public var canvasHeight: Int
    /// The project's frame rate. Defaults to the most common rate among the clips.
    public var frameRate: FrameRate?
    public var crossDissolveDuration: Double = 0.5
    public var titleDuration: Double = 4

    static let crossDissolveUID = "FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"
    static let basicTitleUID = ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"

    public init(projectName: String, eventName: String, canvasWidth: Int, canvasHeight: Int, frameRate: FrameRate? = nil) {
        self.projectName = projectName
        self.eventName = eventName
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.frameRate = frameRate
    }

    public static func dominantFrameRate(of clips: [MediaClip]) -> FrameRate {
        let rates = clips.filter(\.hasVideo).map { FrameRate.nearest(to: $0.frameRate) }
        let counts = Dictionary(rates.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key ?? FrameRate(numerator: 100, denominator: 3000)
    }

    public func build(plan: EditPlan, clips: [MediaClip]) -> String {
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        let seqRate = frameRate ?? Self.dominantFrameRate(of: clips)
        var ids = IDAllocator()
        var resources: [String] = []

        let sequenceFormat = ids.next()
        resources.append(#"<format id="\#(sequenceFormat)" frameDuration="\#(seqRate.frameDuration)" width="\#(canvasWidth)" height="\#(canvasHeight)" colorSpace="1-1-1 (Rec. 709)"/>"#)

        // One <format> per distinct source format, one <asset> per file used.
        var formatIDs: [String: String] = [:]
        var assetIDs: [UUID: String] = [:]
        let usedClips = uniqueClips(plan: plan, byID: byID)
        for clip in usedClips {
            var formatRef = ""
            if clip.hasVideo {
                let rate = FrameRate.nearest(to: clip.frameRate)
                let key = "\(clip.width)x\(clip.height)@\(rate.frameDuration)"
                if formatIDs[key] == nil {
                    let fid = ids.next()
                    formatIDs[key] = fid
                    resources.append(#"<format id="\#(fid)" frameDuration="\#(rate.frameDuration)" width="\#(clip.width)" height="\#(clip.height)"/>"#)
                }
                formatRef = #" format="\#(formatIDs[key]!)""#
            }
            let aid = ids.next()
            assetIDs[clip.id] = aid
            let rate = clip.hasVideo ? FrameRate.nearest(to: clip.frameRate) : seqRate
            let start = rate.time(frames: rate.frames(clip.timecodeStart))
            let duration = rate.time(frames: rate.floorFrames(clip.duration))
            let audio = clip.hasAudio
                ? #" hasAudio="1" audioSources="1" audioChannels="\#(clip.audioChannels)" audioRate="\#(clip.audioRate)""#
                : ""
            resources.append("""
            <asset id="\(aid)" name="\(xml(clip.name))" start="\(start)" duration="\(duration)" hasVideo="\(clip.hasVideo ? 1 : 0)"\(formatRef)\(audio)>
                        <media-rep kind="original-media" src="\(xml(clip.url.absoluteString))"/>
                    </asset>
            """)
        }

        let dissolveID: String? = plan.style.crossDissolves ? ids.next() : nil
        if let dissolveID {
            resources.append(#"<effect id="\#(dissolveID)" name="Cross Dissolve" uid="\#(Self.crossDissolveUID)"/>"#)
        }
        let titleID: String? = plan.style.title.flatMap { $0.isEmpty ? nil : ids.next() }
        if let titleID {
            resources.append(#"<effect id="\#(titleID)" name="Basic Title" uid="\#(xml(Self.basicTitleUID))"/>"#)
        }

        // Spine: shots back to back, each snapped to the project's frame grid.
        var spine: [String] = []
        var cursorFrames = 0
        let segments = plan.segments.filter { byID[$0.clipID] != nil }
        let sequenceFrames = segments.reduce(0) { $0 + seqRate.frames($1.duration) }
        let halfDissolve = seqRate.frames(crossDissolveDuration / 2)

        for (index, seg) in segments.enumerated() {
            let clip = byID[seg.clipID]!
            let clipRate = FrameRate.nearest(to: clip.frameRate)
            let durFrames = seqRate.frames(seg.duration)
            guard durFrames > 0 else { continue }

            if index > 0, let dissolveID, halfDissolve > 0,
               canDissolve(from: segments[index - 1], to: seg, byID: byID, half: crossDissolveDuration / 2) {
                let offset = seqRate.time(frames: cursorFrames - halfDissolve)
                let duration = seqRate.time(frames: halfDissolve * 2)
                spine.append(#"<transition name="Cross Dissolve" offset="\#(offset)" duration="\#(duration)"><filter-video ref="\#(dissolveID)" name="Cross Dissolve"/></transition>"#)
            }

            let startSeconds = clip.timecodeStart + seg.sourceStart
            let start = clipRate.time(frames: clipRate.frames(startSeconds))
            var children = [#"<adjust-conform type="fill"/>"#]

            if index == 0 {
                if let titleID, let text = plan.style.title {
                    let tDur = seqRate.time(min(titleDuration, Double(durFrames) / seqRate.fps))
                    children.append(titleXML(ref: titleID, text: text, offset: start, duration: tDur))
                }
                children += musicXML(plan: plan, assetIDs: assetIDs, parentStartFrames: clipRate.frames(startSeconds), parentRate: clipRate, sequenceFrames: sequenceFrames, seqRate: seqRate)
            }

            let formatKey = "\(clip.width)x\(clip.height)@\(clipRate.frameDuration)"
            let formatAttr = clip.hasVideo ? " format=\"\(formatIDs[formatKey]!)\"" : ""
            spine.append("""
            <asset-clip ref="\(assetIDs[clip.id]!)" name="\(xml(clip.name))" offset="\(seqRate.time(frames: cursorFrames))" start="\(start)" duration="\(seqRate.time(frames: durFrames))"\(formatAttr) tcFormat="NDF">
                                    \(children.joined(separator: "\n                        "))
                                </asset-clip>
            """)
            cursorFrames += durFrames
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
            <resources>
                \(resources.joined(separator: "\n        "))
            </resources>
            <library>
                <event name="\(xml(eventName))">
                    <project name="\(xml(projectName))">
                        <sequence format="\(sequenceFormat)" duration="\(seqRate.time(frames: cursorFrames))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine>
                                \(spine.joined(separator: "\n                    "))
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>

        """
    }

    func uniqueClips(plan: EditPlan, byID: [UUID: MediaClip]) -> [MediaClip] {
        var seen = Set<UUID>()
        var out: [MediaClip] = []
        for id in plan.segments.map(\.clipID) + plan.music.map(\.id) where !seen.contains(id) {
            seen.insert(id)
            if let clip = byID[id] { out.append(clip) }
        }
        return out
    }

    /// A dissolve needs spare footage past the end of the outgoing shot and before the incoming one.
    func canDissolve(from a: Segment, to b: Segment, byID: [UUID: MediaClip], half: Double) -> Bool {
        guard let ca = byID[a.clipID], byID[b.clipID] != nil else { return false }
        let tailHandle = ca.duration - a.sourceEnd
        let headHandle = b.sourceStart
        return tailHandle >= half && headHandle >= half && a.duration > half * 2 && b.duration > half * 2
    }

    func titleXML(ref: String, text: String, offset: String, duration: String) -> String {
        """
        <title ref="\(ref)" lane="1" offset="\(offset)" name="\(xml(text))" duration="\(duration)">
                                    <text><text-style ref="ts1">\(xml(text))</text-style></text>
                                    <text-style-def id="ts1"><text-style font="Helvetica Neue" fontSize="110" fontFace="Bold" fontColor="1 1 1 1" alignment="center"/></text-style-def>
                                </title>
        """
    }

    /// Music files play one after another under the whole edit, lowered so voices stay clear.
    func musicXML(plan: EditPlan, assetIDs: [UUID: String], parentStartFrames: Int, parentRate: FrameRate, sequenceFrames: Int, seqRate: FrameRate) -> [String] {
        var out: [String] = []
        var placed = 0
        for track in plan.music {
            guard let aid = assetIDs[track.id], placed < sequenceFrames else { continue }
            let frames = min(seqRate.floorFrames(track.duration), sequenceFrames - placed)
            guard frames > 0 else { continue }
            // Connected clips are positioned in the parent clip's own time, which starts at its source start.
            let offset = FrameRate.sum(parentStartFrames, parentRate, placed, seqRate)
            let volume = String(format: "%.0f", plan.style.musicVolumeDB)
            out.append(#"<asset-clip ref="\#(aid)" lane="-1" name="\#(xml(track.name))" offset="\#(offset)" start="0s" duration="\#(seqRate.time(frames: frames))" audioRole="music"><adjust-volume amount="\#(volume)dB"/></asset-clip>"#)
            placed += frames
        }
        return out
    }
}

struct IDAllocator {
    private var n = 0
    mutating func next() -> String { n += 1; return "r\(n)" }
}

func xml(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default: out.append(ch)
        }
    }
    return out
}
