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
    .library(name: "GalavantChat", targets: ["GalavantChat"]),
    .library(name: "GalavantCaptureUI", targets: ["GalavantCaptureUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
    .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.0"),
    // The app-agnostic in-app browser, lifted out to jon-platform as a shared
    // package (jon-platform ADR-0002); consumed by local path.
    .package(path: "../../../jon-platform/packages/WebExtractorKit"),
    // The app-agnostic model-access boundary, lifted out to jon-platform as a
    // shared package; consumed by local path.
    .package(path: "../../../jon-platform/packages/LLMClientKit"),
    // The app-agnostic CloudKit sync-control surface (gate, start, redrain, pending
    // poll, SyncHealth reducer), lifted to jon-platform per ADR-0003; consumed by
    // local path. GalavantCloudSync is now a thin facade over it.
    .package(path: "../../../jon-platform/packages/CloudSyncKit"),
  ],
  targets: [
    .target(
      name: "GalavantSchema",
      dependencies: [
        .product(name: "CloudSyncKit", package: "CloudSyncKit"),
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
        .product(name: "LLMClientKit", package: "LLMClientKit"),
        .product(name: "WebExtractorKit", package: "WebExtractorKit"),
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
        .product(name: "LLMClientKit", package: "LLMClientKit"),
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
    // The context-aware chat (ADR-0017): an `@Observable` `ChatModel` over the
    // tiered `ModelClient`, seeded with a per-screen `ChatContext`, with pool
    // verbs as tools over the tested `GalavantSchema` core. App-internal name
    // (ADR-0006). No SwiftUI; the dispatch + serialization logic is the testable
    // core, the app target is the thin panel.
    .target(
      name: "GalavantChat",
      dependencies: [
        "GalavantSchema",
        .product(name: "LLMClientKit", package: "LLMClientKit"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "GalavantChatTests",
      dependencies: [
        "GalavantChat",
        "GalavantSchema",
        .product(name: "LLMClientKit", package: "LLMClientKit"),
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    // The app-agnostic in-app browser (ADR-0022) was lifted out of this package into
    // jon-platform's shared `WebExtractorKit` (jon-platform ADR-0002) once Yes Chef
    // became a second consumer; GalavantPlaces and the app target now depend on it by
    // local path. See galavant ADR-0027.
    // The shared capture confirm-and-tweak UI (ADR-0023): the sheet shown after a page
    // is captured — from the share extension *or* the app's in-app browser. Lifted out
    // of the extension target so both hosts present the same vet-at-source sheet
    // (ADR-0019 dedup included). Unlike WebExtractorKit it deliberately carries domain
    // UI (CaptureModel/Idea), so it's the app's, not a cross-app lift.
    .target(
      name: "GalavantCaptureUI",
      dependencies: ["GalavantPlaces", "GalavantSchema"]
    ),
  ]
)
