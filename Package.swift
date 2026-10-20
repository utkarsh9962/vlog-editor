// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VlogEditor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VlogEditor", targets: ["VlogEditor"]),
    ],
    targets: [
        // Pure Swift: reads the user's description, picks shots, writes FCPXML.
        .target(name: "VlogEditorCore"),
        // The Mac app: SwiftUI screens, AVFoundation probing/rendering, Final Cut Pro hand-off.
        .executableTarget(name: "VlogEditor", dependencies: ["VlogEditorCore"]),
        .testTarget(name: "VlogEditorCoreTests", dependencies: ["VlogEditorCore"]),
    ]
)
