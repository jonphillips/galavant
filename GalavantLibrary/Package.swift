// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GalavantLibrary",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [
    .library(name: "GalavantSchema", targets: ["GalavantSchema"]),
    .library(name: "GalavantPlaces", targets: ["GalavantPlaces"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
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
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "GalavantPlacesTests",
      dependencies: [
        "GalavantPlaces",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
  ]
)
