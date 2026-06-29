// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "KindlingUI",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "KindlingUI",
      targets: ["KindlingUI"]
    )
  ],
  targets: [
    .target(name: "KindlingUI"),
    .testTarget(
      name: "KindlingUITests",
      dependencies: ["KindlingUI"]
    ),
  ]
)
