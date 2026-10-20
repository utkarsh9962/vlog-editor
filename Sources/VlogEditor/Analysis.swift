import AVFoundation
import CoreGraphics
import Speech
import Vision
import VlogEditorCore

/// Scores how good each moment of a clip looks: sharp, steady, and with people in it.
enum VisualAnalyzer {
    static func profile(of clip: MediaClip, spacing: Double = 1.5, maxSamples: Int = 40) async -> VisualProfile? {
        guard clip.hasVideo, clip.duration >= 1 else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let count = max(2, min(maxSamples, Int(clip.duration / spacing)))
        var times: [Double] = []
        var sharpness: [Float] = []
        var steadiness: [Float] = []
        var faces: [Float] = []
        for k in 0..<count {
            let t = min(clip.duration - 0.2, clip.duration * (Double(k) + 0.5) / Double(count))
            guard let a = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                  let b = try? await generator.image(at: CMTime(seconds: t + 0.15, preferredTimescale: 600)).image,
                  let grayA = gray(a, width: 96), let grayB = gray(b, width: 96) else { continue }
            times.append(t)
            sharpness.append(laplacianVariance(grayA, width: 96))
            // Big change between frames 0.15s apart means the camera is shaking or whipping around.
            let diff = zip(grayA, grayB).reduce(Float(0)) { $0 + abs(Float($1.0) - Float($1.1)) } / Float(grayA.count) / 255
            steadiness.append(max(0, 1 - diff / 0.12))
            faces.append(faceCount(a) > 0 ? 1 : 0)
        }
        guard !times.isEmpty else { return nil }
        let sharpPeak = max(sharpness.max() ?? 1, 1e-6)
        let scores = times.indices.map { i in
            0.45 * sharpness[i] / sharpPeak + 0.35 * steadiness[i] + 0.2 * faces[i]
        }
        return VisualProfile(times: times, scores: scores)
    }

    static func faceCount(_ image: CGImage) -> Int {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.count ?? 0
    }

    /// The image as 8-bit grayscale, `width` pixels wide.
    static func gray(_ image: CGImage, width: Int) -> [UInt8]? {
        let height = max(1, Int(Double(width) * Double(image.height) / Double(max(1, image.width))))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Edge strength: blurry frames have little variation in their second derivative.
    static func laplacianVariance(_ pixels: [UInt8], width: Int) -> Float {
        let height = pixels.count / width
        guard width > 2, height > 2 else { return 0 }
        var values: [Float] = []
        values.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let c = Float(pixels[y * width + x]) * 4
                let n = Float(pixels[(y - 1) * width + x]) + Float(pixels[(y + 1) * width + x])
                    + Float(pixels[y * width + x - 1]) + Float(pixels[y * width + x + 1])
                values.append(n - c)
            }
        }
        let mean = values.reduce(0, +) / Float(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
    }
}

/// Turns speech in a clip into timed words, on this Mac.
enum SpeechTranscriber {
    enum TranscribeError: LocalizedError {
        case needsPackagedApp, notAllowed, unavailable
        var errorDescription: String? {
            switch self {
            case .needsPackagedApp: return "Captions need the packaged app. Build it with scripts/make-app.sh."
            case .notAllowed: return "Captions need speech recognition. Allow it in System Settings > Privacy & Security > Speech Recognition."
            case .unavailable: return "Speech recognition isn't available for your language on this Mac."
            }
        }
    }

    static var canAsk: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    static var status: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    static func requestAccess() async -> Bool {
        guard canAsk else { return false }
        if status == .authorized { return true }
        return await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
    }

    static func words(in clip: MediaClip) async throws -> [SpokenWord] {
        guard canAsk else { throw TranscribeError.needsPackagedApp }
        guard await requestAccess() else { throw TranscribeError.notAllowed }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw TranscribeError.unavailable }

        // The recognizer reads audio files, so pull the sound out of the video first.
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: clip.url), presetName: AVAssetExportPresetAppleM4A) else { return [] }
        export.outputURL = audio
        export.outputFileType = .m4a
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in export.exportAsynchronously { done.resume() } }
        guard export.status == .completed else { return [] }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return try await withCheckedThrowingContinuation { done in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    done.resume(returning: result.bestTranscription.segments.map {
                        SpokenWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    })
                } else if let error {
                    finished = true
                    // "No speech detected" is not a failure, just an empty clip.
                    if (error as NSError).code == 1110 { done.resume(returning: []) } else { done.resume(throwing: error) }
                }
            }
        }
    }
}
