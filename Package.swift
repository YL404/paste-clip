// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PasteClip",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "PasteClip",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]
}
