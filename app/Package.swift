// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CodexTurnrail",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "CodexTurnrailCore",
      targets: ["CodexTurnrailCore"]
    ),
    .executable(
      name: "CodexTurnrailApp",
      targets: ["CodexTurnrailApp"]
    ),
  ],
  targets: [
    .target(name: "CodexTurnrailCore"),
    .executableTarget(
      name: "CodexTurnrailApp",
      dependencies: ["CodexTurnrailCore"]
    ),
    .testTarget(
      name: "CodexTurnrailCoreTests",
      dependencies: ["CodexTurnrailCore"]
    ),
    .testTarget(
      name: "CodexTurnrailAppTests",
      dependencies: ["CodexTurnrailApp"]
    ),
  ]
)
