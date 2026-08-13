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
    .library(name: "GalavantCaptureUI", targets: ["GalavantCaptureUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.0.0"),
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
    // Declared even though no source here writes `import GRDB`: sqlite-data's
    // `Internal/Exports.swift` `@_exported`-re-exports `Database`,
    // `DatabaseWriter`, `Configuration` and `DatabaseMigrator`, and
    // GalavantSchema/GalavantPlaces use them throughout.
    //
    // `@_exported` is a *compile-time* re-export, not a `-reexport_framework`.
    // Under static linking every transitive archive shares one link line, so
    // omitting this is invisible — `swift test` and the plain `xcodebuild build`
    // are both static and stay green. It becomes a hard link failure the moment
    // Xcode rebuilds package products as **dynamic frameworks**, which it does
    // for the whole graph as soon as an Xcode *unit*-test target
    // (`bundle.unit-test`) enters the build: `SQLiteData.framework` does not
    // vend GRDB's symbols on a dependent's behalf.
    //
    // Galavant does not have such a target today — `GalavantUITests` is
    // `bundle.ui-testing`, runs out of process, and never flips the graph — so
    // this is inoculation, not a fix for a live break. YesChef hit the live
    // version of it (yes-chef#247) and lost a day to it; the cost of not being
    // able to hit it here is two lines. Floor matches sqlite-data's own.
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0"),
  ],
  targets: [
    .target(
      name: "GalavantSchema",
      dependencies: [
        "GalavantAI",
        .product(name: "CloudSyncKit", package: "CloudSyncKit"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "GalavantAI",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "GalavantAITests",
      dependencies: ["GalavantAI"]
    ),
    .testTarget(
      name: "GalavantSchemaTests",
      dependencies: [
        "GalavantSchema",
        "GalavantAI",
        "GalavantPlaces",
        .product(name: "CustomDump", package: "swift-custom-dump"),
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [.process("Fixtures")]
    ),
    .target(
      name: "GalavantPlaces",
      dependencies: [
        "GalavantSchema",
        "GalavantCapture",
        "GalavantImaging",
        .product(name: "GRDB", package: "GRDB.swift"),
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
        .product(name: "CustomDump", package: "swift-custom-dump"),
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
