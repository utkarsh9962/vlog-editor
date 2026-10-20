import AppKit

/// Hands a project to Final Cut Pro. Final Cut has no scripting API, but it imports FCPXML when asked
/// to open the file, building the event and project with every edit already made.
enum FinalCutBridge {
    static let bundleIDs = ["com.apple.FinalCut", "com.apple.FinalCutApp", "com.apple.FinalCutTrial"]

    /// Finds Final Cut Pro by its bundle ID first, then by looking in the Applications folders,
    /// so copies Launch Services hasn't indexed (just installed, renamed, or on another volume) still count.
    static var appURL: URL? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).first { return url }
        }
        let fm = FileManager.default
        let folders = fm.urls(for: .applicationDirectory, in: .allDomainsMask)
            + [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")]
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasSuffix(".app") && name.localizedCaseInsensitiveContains("Final Cut Pro") {
                let url = folder.appendingPathComponent(name)
                let id = Bundle(url: url)?.bundleIdentifier ?? ""
                if id.hasPrefix("com.apple.FinalCut") { return url }
            }
        }
        return nil
    }

    static var isInstalled: Bool { appURL != nil }

    static var version: String? {
        appURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
    }

    /// The projects this app writes (FCPXML 1.10) open in Final Cut Pro 10.6 and later.
    static var supportsFCPXML110: Bool {
        guard let parts = version?.split(separator: ".").compactMap({ Int($0) }), parts.count >= 2 else { return isInstalled }
        return parts[0] > 10 || (parts[0] == 10 && parts[1] >= 6)
    }

    static func launch() {
        guard let app = appURL else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

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
