// swift-tools-version: 6.2
import Foundation
import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
]
var remoteMicDependencies: [Target.Dependency] = [
    "AudioExceptionGuard",
    "AppleRemoteAudioCore",
    "AppleRemotePacketLogger",
    "AppleRemoteHCIProtocol",
    .product(name: "Sparkle", package: "Sparkle"),
]
var remoteMicTestDependencies: [Target.Dependency] = ["RemoteMic", "AppleRemoteHCIProtocol"]
let macOSPlatform: SupportedPlatform = ProcessInfo.processInfo.environment["RELEASE_VARIANT"] == "intel"
    ? .macOS(.v13)
    : .macOS(.v14)

if let hardwareSimulationPath = ProcessInfo.processInfo.environment[
    "REMOTE_MIC_HARDWARE_SIMULATION_PATH"
], !hardwareSimulationPath.isEmpty {
    packageDependencies.append(.package(path: hardwareSimulationPath))
    remoteMicTestDependencies.append(
        .product(name: "HardwareSimulation", package: "hardware-simulation")
    )
    remoteMicTestDependencies.append(
        .product(name: "XiaomiVoiceRemoteSimulation", package: "hardware-simulation")
    )
}

let package = Package(
    name: "RemoteMic",
    platforms: [macOSPlatform],
    products: [
        .executable(
            name: "RemoteMic",
            targets: ["RemoteMic"]
        )
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "RemoteMic",
            dependencies: remoteMicDependencies,
            path: "Sources/RemoteMic",
            linkerSettings: [
                .linkedFramework("Network"),
            ]
        ),
        .target(
            name: "AudioExceptionGuard",
            path: "Sources/AudioExceptionGuard",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AppleRemoteAudioCore",
            path: "Sources/AppleRemoteAudioCore"
        ),
        .target(
            name: "AppleRemoteHCIProtocol",
            path: "Sources/AppleRemoteHCIProtocol"
        ),
        .target(
            name: "AppleRemotePacketLogger",
            dependencies: ["AppleRemoteAudioCore", "AppleRemoteHCIProtocol"],
            path: "Sources/AppleRemoteAudioCapture",
            exclude: ["AppleRemoteVoiceController.swift", "main.swift"],
            sources: ["SayAllBTPacketLoggerClient.swift"],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "AppleRemoteAudioCapture",
            dependencies: ["AppleRemoteAudioCore", "AppleRemotePacketLogger"],
            path: "Sources/AppleRemoteAudioCapture",
            exclude: ["SayAllBTPacketLoggerClient.swift"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "AppleRemoteHCIService",
            dependencies: ["AppleRemoteHCIProtocol"],
            path: "Sources/AppleRemoteHCIService",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "RemoteMicTests",
            dependencies: remoteMicTestDependencies,
            path: "Tests/RemoteMicTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
