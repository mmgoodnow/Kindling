// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "KindlingUI",
  platforms: [
    .iOS("26.0"),
    .macOS("26.0"),
  ],
  products: [
    .library(
      name: "KindlingUI",
      targets: ["KindlingUI"]
    ),
    .executable(
      name: "KindlingUISnapshots",
      targets: ["KindlingUISnapshots"]
    ),
  ],
  targets: [
    .target(name: "KindlingUI"),
    .executableTarget(
      name: "KindlingUISnapshots",
      dependencies: ["KindlingUI"]
    ),
    .testTarget(
      name: "KindlingUITests",
      dependencies: ["KindlingUI"]
    ),
  ]
)
