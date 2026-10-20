import AVFoundation
import CoreMedia
import VlogEditorCore

enum MediaProbeError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "“\(name)” isn't a video or audio file this Mac can read."
        }
    }
}

/// Reads the facts about a dropped file that the planner and FCPXML need.
enum MediaProbe {
    static func probe(_ url: URL) async throws -> MediaClip {
        let asset = AVURLAsset(url: url)
        let name = url.lastPathComponent
        guard (try? await asset.load(.isReadable)) == true else { throw MediaProbeError.unreadable(name) }

        let duration = try await asset.load(.duration).seconds
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        guard videoTrack != nil || audioTrack != nil, duration.isFinite, duration > 0 else {
            throw MediaProbeError.unreadable(name)
        }

        var clip = MediaClip(url: url, duration: duration, hasVideo: videoTrack != nil, hasAudio: audioTrack != nil)

        if let videoTrack {
            let (size, transform, fps) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let display = CGRect(origin: .zero, size: size).applying(transform).size
            clip.width = Int(abs(display.width).rounded())
            clip.height = Int(abs(display.height).rounded())
            clip.frameRate = fps > 0 ? Double(fps) : 30
        }

        if let audioTrack {
            let descriptions = try await audioTrack.load(.formatDescriptions)
            if let desc = descriptions.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                clip.audioChannels = max(1, Int(asbd.mChannelsPerFrame))
                clip.audioRate = asbd.mSampleRate > 0 ? Int(asbd.mSampleRate) : 48_000
            }
        }

        if let item = try await asset.load(.creationDate) {
            clip.creationDate = try? await item.load(.dateValue)
        }
        if clip.creationDate == nil {
            clip.creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }

        clip.timecodeStart = (try? await startTimecode(of: asset)) ?? 0
        return clip
    }

    /// Camera files often start at a timecode such as 01:00:00:00. Final Cut Pro expects the asset to say so.
    static func startTimecode(of asset: AVAsset) async throws -> Double {
        guard let track = try await asset.loadTracks(withMediaType: .timecode).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return 0 }
        defer { reader.cancelReading() }

        let frameDuration = CMTimeCodeFormatDescriptionGetFrameDuration(format).seconds
        let frameNumber: Int64
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMTimeCodeFormatType_TimeCode32:
            var raw: Int32 = 0
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &raw)
            frameNumber = Int64(Int32(bigEndian: raw))
        case kCMTimeCodeFormatType_TimeCode64:
            var raw: Int64 = 0
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 8, destination: &raw)
            frameNumber = Int64(bigEndian: raw)
        default:
            return 0
        }
        let seconds = Double(frameNumber) * frameDuration
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    /// Loudness every half second, used to find the moments where something is happening.
    static func audioEnergy(of url: URL) async throws -> AudioEnergy? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let sampleRate = 8_000.0
        let window = 0.5
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }

        let perWindow = Int(sampleRate * window)
        var values: [Float] = []
        var sumSquares: Float = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            floats.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            for v in floats {
                sumSquares += v * v
                count += 1
                if count == perWindow {
                    values.append((sumSquares / Float(count)).squareRoot())
                    sumSquares = 0
                    count = 0
                }
            }
        }
        if count > 0 { values.append((sumSquares / Float(count)).squareRoot()) }
        return values.isEmpty ? nil : AudioEnergy(windowSeconds: window, values: values)
    }
}
