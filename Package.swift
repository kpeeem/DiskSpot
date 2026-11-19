// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskSpotMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "diskspotmcp", targets: ["diskspotmcp"]),
    ],
    targets: [
        .executableTarget(
            name: "diskspotmcp",
            path: ".",
            exclude: [
                "build",
                "build.sh",
                "build-mcp.sh",
                "project.yml",
                "DiskSpot.xcodeproj",
                "DiskSpot/Info.plist",
                "DiskSpot/Assets.xcassets",
                "DiskSpot/App",
                "DiskSpot/UI",
                "DiskSpot/Model/AppModel.swift",
                "DiskSpot/Scanning/ScanPlanner.swift",
            ],
            sources: [
                "MCP",
                "DiskSpot/Model/Node.swift",
                "DiskSpot/Model/FileKind.swift",
                "DiskSpot/Model/Format.swift",
                "DiskSpot/Scanning/ExactScanner.swift",
                "DiskSpot/Scanning/Spotlight.swift",
                "DiskSpot/Scanning/Volumes.swift",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
