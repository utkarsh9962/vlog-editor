import AVFoundation
import AppKit
import Security
import VlogEditorCore

/// Sends the edit-planning request to the Claude API.
enum ClaudeClient {
    enum ClientError: LocalizedError {
        case badKey, busy, server(String)
        var errorDescription: String? {
            switch self {
            case .badKey: return "Your Anthropic API key wasn't accepted. Check it in Settings."
            case .busy: return "Claude is busy right now. Try again in a minute."
            case .server(let why): return "Claude couldn't plan the edit: \(why)"
            }
        }
    }

    static func send(_ body: Data, apiKey: String) async throws -> Data {
        var request = URLRequest(url: ClaudePlanner.endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in ClaudePlanner.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 401, 403: throw ClientError.badKey
        case 429, 529: throw ClientError.busy
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            throw ClientError.server(message ?? "HTTP \(status)")
        }
    }
}

/// The user's Anthropic API key, kept in the macOS Keychain.
enum APIKeyStore {
    private static let service = "app.vlogeditor.mac.anthropic"
    private static let account = "api-key"

    static var key: String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        remove()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Pulls small still frames from each clip so Claude can see the footage.
enum FrameSampler {
    /// About one frame every few seconds, at most `limit` across all clips, at least two per clip.
    static func frames(for clips: [MediaClip], limit: Int = 80) async -> [ClipFrame] {
        let video = clips.filter { $0.hasVideo && $0.duration >= 1 }
        let total = video.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return [] }
        let spacing = max(2.0, total / Double(limit))

        var out: [ClipFrame] = []
        for clip in video {
            let count = max(2, min(Int(clip.duration / spacing), limit))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            for k in 0..<count {
                let t = clip.duration * (Double(k) + 0.5) / Double(count)
                guard let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)),
                      let jpeg = NSBitmapImageRep(cgImage: result.image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
                else { continue }
                out.append(ClipFrame(clipID: clip.id, time: t, jpeg: jpeg))
            }
        }
        return out
    }
}
