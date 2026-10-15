// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TVRemote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TVRemote", targets: ["TVRemote"]),
        .executable(name: "tvctl", targets: ["tvctl"]),
        .executable(name: "tvmcp", targets: ["tvmcp"]),
        .library(name: "TVKit", targets: ["TVKit"]),
    ],
    targets: [
        // Protocol layer: Samsung Tizen (2016+) MSF remote WebSocket, REST app API,
        // UPnP RenderingControl volume, SSDP discovery and Wake-on-LAN.
        .target(name: "TVKit"),
        // Menu bar app (SwiftUI MenuBarExtra).
        .executableTarget(name: "TVRemote", dependencies: ["TVKit"]),
        // Command line client for scripting / debugging the protocol.
        .executableTarget(name: "tvctl", dependencies: ["TVKit"]),
        // MCP server (stdio) exposing the TV tools to Claude Code / Claude Desktop.
        .executableTarget(name: "tvmcp", dependencies: ["TVKit"]),
        .testTarget(name: "TVKitTests", dependencies: ["TVKit"]),
    ]
)
