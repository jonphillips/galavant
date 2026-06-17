// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GalavantLibrary",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [
    .library(name: "GalavantSchema", targets: ["GalavantSchema"]),
    .library(name: "GalavantPlaces", targets: ["GalavantPlaces"]),
    .library(name: "GalavantCapture", targets: ["GalavantCapture"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
    .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.0"),
  ],
  targets: [
    .target(
      name: "GalavantSchema",
      dependencies: [
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "GalavantSchemaTests",
      dependencies: [
        "GalavantSchema",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "GalavantPlaces",
      dependencies: [
        "GalavantSchema",
        "GalavantCapture",
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "GalavantPlacesTests",
      dependencies: [
        "GalavantPlaces",
        "GalavantSchema",
        "GalavantCapture",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    // The pure web-capture parser engine: HTML → ParsedPage. No SwiftUI, no
    // CloudKit, never sees Idea/Trip — the portfolio-extraction seam (ADR-0009 /
    // BACKLOG "Portfolio extraction seams"). Depends only on SwiftSoup + Foundation.
    .target(
      name: "GalavantCapture",
      dependencies: [
        .product(name: "SwiftSoup", package: "SwiftSoup"),
      ]
    ),
    .testTarget(
      name: "GalavantCaptureTests",
      dependencies: ["GalavantCapture"]
    ),
  ]
)
