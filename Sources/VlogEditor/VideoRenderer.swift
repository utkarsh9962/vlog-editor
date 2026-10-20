import AVFoundation
import AppKit
import QuartzCore
import VlogEditorCore

/// Renders the same edit that went to Final Cut Pro into a finished file, framed for the chosen platform.
/// Final Cut can't be told to export from outside the app, so the deliverable is made here.
enum VideoRenderer {
    enum RenderError: LocalizedError {
        case nothingToRender, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .nothingToRender: return "There's nothing in the edit to export."
            case .exportFailed(let why): return "The export didn't finish: \(why)"
            }
        }
    }

    static func render(
        plan: EditPlan,
        clips: [MediaClip],
        settings: ExportSettings,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        let canvas = CGSize(width: settings.canvas.width, height: settings.canvas.height)
        let fps = FCPXMLBuilder.dominantFrameRate(of: clips)
        let timescale: CMTimeScale = 60_000

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RenderError.nothingToRender }

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        var cursor = CMTime.zero

        for seg in plan.segments {
            guard let clip = byID[seg.clipID] else { continue }
            let asset = AVURLAsset(url: clip.url)
            guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: CMTime(seconds: seg.sourceStart, preferredTimescale: timescale),
                                    duration: CMTime(seconds: seg.duration, preferredTimescale: timescale))
            try videoTrack.insertTimeRange(range, of: srcVideo, at: cursor)
            if let srcAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(range, of: srcAudio, at: cursor)
            }
            let (natural, preferred) = try await srcVideo.load(.naturalSize, .preferredTransform)
            layer.setTransform(fillTransform(natural: natural, preferred: preferred, canvas: canvas), at: cursor)
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw RenderError.nothingToRender }
        if audioTrack.segments.isEmpty { composition.removeTrack(audioTrack) }
        let total = CMTimeRange(start: .zero, duration: cursor)

        // Music bed under the voices, faded out at the end.
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if !plan.music.isEmpty, let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            var placed = CMTime.zero
            for song in plan.music where placed < cursor {
                let asset = AVURLAsset(url: song.url)
                guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let songLength = try await asset.load(.duration)
                let length = CMTimeMinimum(songLength, cursor - placed)
                try musicTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: src, at: placed)
                placed = placed + length
            }
            let params = AVMutableAudioMixInputParameters(track: musicTrack)
            let volume = Float(pow(10, plan.style.musicVolumeDB / 20))
            let fade = CMTimeMinimum(CMTime(seconds: 2, preferredTimescale: timescale), placed)
            params.setVolume(volume, at: .zero)
            params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: placed - fade, duration: fade))
            mixParams.append(params)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = total
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: CMTimeValue(fps.numerator), timescale: CMTimeScale(fps.denominator))
        videoComposition.instructions = [instruction]
        let title = plan.style.title.flatMap { $0.isEmpty ? nil : $0 }
        if title != nil || !plan.captions.isEmpty {
            videoComposition.animationTool = overlay(title: title, captions: plan.captions, canvas: canvas,
                                                     titleDuration: min(4, cursor.seconds))
        }

        let preset = settings.quality == .uhd4k ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw RenderError.exportFailed("this Mac can't export at that quality")
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = videoComposition
        if !mixParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParams
            session.audioMix = mix
        }

        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { ticker.cancel() }

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        guard session.status == .completed else {
            throw RenderError.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }

    /// Scales and centers a shot so it fills the canvas, cropping what doesn't fit (like Final Cut's "Fill").
    static func fillTransform(natural: CGSize, preferred: CGAffineTransform, canvas: CGSize) -> CGAffineTransform {
        let rotated = CGRect(origin: .zero, size: natural).applying(preferred)
        let display = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        guard display.width > 0, display.height > 0 else { return preferred }
        let scale = max(canvas.width / display.width, canvas.height / display.height)
        return preferred
            .concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (canvas.width - display.width * scale) / 2,
                                             y: (canvas.height - display.height * scale) / 2))
    }

    /// The opening title, centered and fading in and out, plus burned-in captions in the lower part of the frame.
    static func overlay(title: String?, captions: [Caption], canvas: CGSize, titleDuration: Double) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: canvas)
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)
        if let title { parent.addSublayer(titleLayer(title, canvas: canvas, duration: titleDuration)) }
        for caption in captions { parent.addSublayer(captionLayer(caption, canvas: canvas)) }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }

    static func captionLayer(_ caption: Caption, canvas: CGSize) -> CALayer {
        let fontSize = min(canvas.width, canvas.height) * 0.055
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = fontSize * 0.15
        let text = CATextLayer()
        text.string = NSAttributedString(string: caption.text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0,
            .shadow: shadow,
        ])
        text.alignmentMode = .center
        text.isWrapped = true
        text.contentsScale = 2
        // Core Animation's origin is the bottom-left corner here, so this sits in the lower fifth.
        text.frame = CGRect(x: canvas.width * 0.08, y: canvas.height * 0.14,
                            width: canvas.width * 0.84, height: fontSize * 2.6)
        text.opacity = 0

        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [1, 1]
        show.keyTimes = [0, 1]
        show.duration = caption.duration
        show.beginTime = caption.start <= 0 ? AVCoreAnimationBeginTimeAtZero : caption.start
        show.isRemovedOnCompletion = false
        show.fillMode = .removed
        text.add(show, forKey: "show")
        return text
    }

    static func titleLayer(_ title: String, canvas: CGSize, duration: Double) -> CALayer {
        let fontSize = min(canvas.width, canvas.height) * 0.09
        let text = CATextLayer()
        text.string = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        text.alignmentMode = .center
        text.isWrapped = true
        text.contentsScale = 2
        text.shadowOpacity = 0.5
        text.shadowRadius = fontSize * 0.08
        text.shadowOffset = .zero
        text.frame = CGRect(x: canvas.width * 0.08, y: canvas.height / 2 - fontSize,
                            width: canvas.width * 0.84, height: fontSize * 2.4)
        text.opacity = 0

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.8, 1]
        fade.duration = duration
        fade.beginTime = AVCoreAnimationBeginTimeAtZero
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        text.add(fade, forKey: "fade")
        return text
    }
}
