// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "tailscale-route",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TailscaleRouteCore",
            targets: ["TailscaleRouteCore"]
        ),
        .executable(
            name: "tailscale-route-diagnose",
            targets: ["TailscaleRouteDiagnose"]
        ),
        .executable(
            name: "tailscale-route-cli",
            targets: ["TailscaleRouteCLI"]
        ),
        .executable(
            name: "tailscale-route",
            targets: ["TailscaleRouteApp"]
        ),
        .executable(
            name: "tailscale-route-helper",
            targets: ["TailscaleRouteHelper"]
        )
    ],
    targets: [
        .target(
            name: "RouteSocket",
            path: "Sources/RouteSocket",
            publicHeadersPath: "include"
        ),
        .target(
            name: "TailscaleRouteCore",
            dependencies: ["RouteSocket"]
        ),
        .executableTarget(
            name: "TailscaleRouteDiagnose",
            dependencies: ["TailscaleRouteCore"]
        ),
        .executableTarget(
            name: "TailscaleRouteCLI",
            dependencies: ["TailscaleRouteCore"]
        ),
        .executableTarget(
            name: "TailscaleRouteApp",
            dependencies: ["TailscaleRouteCore"]
        ),
        .executableTarget(
            name: "TailscaleRouteHelper",
            dependencies: ["TailscaleRouteCore"]
        ),
        .testTarget(
            name: "TailscaleRouteCoreTests",
            dependencies: ["TailscaleRouteCore"]
        )
    ]
)
