// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PrayerIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PrayerIsland", path: "Sources/PrayerIsland")
    ]
)
