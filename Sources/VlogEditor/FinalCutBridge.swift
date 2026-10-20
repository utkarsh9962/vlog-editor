import AppKit

/// Hands a project to Final Cut Pro. Final Cut has no scripting API, but it imports FCPXML when asked
/// to open the file, building the event and project with every edit already made.
enum FinalCutBridge {
    static let bundleIDs = ["com.apple.FinalCut", "com.apple.FinalCutTrial"]

    static var appURL: URL? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    static var isInstalled: Bool { appURL != nil }

    /// Where projects and exports go: ~/Movies/Vlog Editor/<project>/
    static func workspace(for projectName: String) throws -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let folder = movies.appendingPathComponent("Vlog Editor", isDirectory: true)
            .appendingPathComponent(safeFileName(projectName), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func write(fcpxml: String, name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(safeFileName(name)).appendingPathExtension("fcpxml")
        try fcpxml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func open(_ fcpxmlURL: URL) async throws {
        guard let app = appURL else { throw BridgeError.notInstalled }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.open([fcpxmlURL], withApplicationAt: app, configuration: config)
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Vlog" : cleaned
    }

    enum BridgeError: LocalizedError {
        case notInstalled
        var errorDescription: String? {
            "Final Cut Pro isn't installed on this Mac. You can still export the vlog directly from here."
        }
    }
}
