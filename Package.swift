// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CinqHeures",
    platforms: [.macOS(.v15), .iOS("26.0")],
    products: [
        // The engine shared with the iPhone and iPad app (iOS/), which builds the screens itself.
        .library(name: "CinqHeuresCore", targets: ["CinqHeuresCore"]),
    ],
    targets: [
        // Everything that doesn't need a window: the catalogue of episodes and segments, the
        // 5heures.be client, the search. Covered by `./test.sh`.
        .target(
            name: "CinqHeuresCore",
            path: "Sources/CinqHeuresCore"
        ),
        .executableTarget(
            name: "CinqHeures",
            dependencies: ["CinqHeuresCore"],
            path: "Sources/CinqHeures",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "CinqHeuresCoreTests",
            dependencies: ["CinqHeuresCore"],
            path: "Tests/CinqHeuresCoreTests",
            exclude: ["Fixtures"]
        ),
    ]
)
