// swift-tools-version:5.9
// Story 1.3: first-party local package holding the testable core (host config,
// report validation, snapshot store, poll classification, poller). No
// third-party dependency (B1/B2). Tests run with `swift test` — no Xcode GUI
// target needed (the app project has none).
import PackageDescription

let package = Package(
    name: "MonobsKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MonobsKit", targets: ["MonobsKit"])
    ],
    targets: [
        .target(name: "MonobsKit"),
        .testTarget(
            name: "MonobsKitTests",
            dependencies: ["MonobsKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
