// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beamly",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "BeamlyKit", targets: ["BeamlyKit"]),
        .executable(name: "beamly", targets: ["BeamlyCLI"]),
        .executable(name: "BeamlyApp", targets: ["BeamlyApp"]),
    ],
    targets: [
        .target(name: "BeamlyKit"),
        .executableTarget(name: "BeamlyCLI", dependencies: ["BeamlyKit"]),
        .executableTarget(name: "BeamlyApp", dependencies: ["BeamlyKit"]),
        .testTarget(name: "BeamlyKitTests", dependencies: ["BeamlyKit"]),
    ],
    swiftLanguageModes: [.v5]
)
