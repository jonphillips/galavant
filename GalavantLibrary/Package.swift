// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GalavantLibrary",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [
    .library(name: "GalavantSchema", targets: ["GalavantSchema"]),
    .library(name: "GalavantPlaces", targets: ["GalavantPlaces"]),
    .library(name: "GalavantCapture", targets: ["GalavantCapture"]),
    .library(name: "GalavantImaging", targets: ["GalavantImaging"]),
    .library(name: "GalavantAI", targets: ["GalavantAI"]),
    .library(name: "GalavantChat", targets: ["GalavantChat"]),
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
        "GalavantImaging",
        "GalavantAI",
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "GalavantPlacesTests",
      dependencies: [
        "GalavantPlaces",
        "GalavantSchema",
        "GalavantCapture",
        "GalavantAI",
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
    // Pure image processing: bytes → resized/compressed display + thumbnail.
    // ImageIO/CoreGraphics only — no SwiftUI, no CloudKit, no persistence
    // (ADR-0009 §2). The clean portfolio-extraction candidate; storage stays in
    // GalavantSchema. Tested with synthesized bytes (no fixture files).
    .target(
      name: "GalavantImaging"
    ),
    .testTarget(
      name: "GalavantImagingTests",
      dependencies: ["GalavantImaging"]
    ),
    // The tiered model-access boundary (ADR-0014): one injectable `ModelClient`
    // every AI feature calls through, with an on-device tier (FoundationModels)
    // and a BYO-key frontier tier (Anthropic over URLSession). App-internal, so a
    // Galavant-scoped name is fine (ADR-0006). No SwiftUI, no CloudKit; the API
    // key is device-local Keychain state, never a synced record (ADR-0014 §1).
    .target(
      name: "GalavantAI",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "GalavantAITests",
      dependencies: [
        "GalavantAI",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    // The context-aware chat (ADR-0017): an `@Observable` `ChatModel` over the
    // tiered `ModelClient`, seeded with a per-screen `ChatContext`, with pool
    // verbs as tools over the tested `GalavantSchema` core. App-internal name
    // (ADR-0006). No SwiftUI; the dispatch + serialization logic is the testable
    // core, the app target is the thin panel.
    .target(
      name: "GalavantChat",
      dependencies: [
        "GalavantSchema",
        "GalavantAI",
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "GalavantChatTests",
      dependencies: [
        "GalavantChat",
        "GalavantSchema",
        "GalavantAI",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
  ]
)
