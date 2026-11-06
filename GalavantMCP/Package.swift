// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "GalavantMCP",
  platforms: [.macOS(.v26)],
  products: [.executable(name: "galavant-mcp", targets: ["GalavantMCP"])],
  dependencies: [
    .package(path: "../GalavantLibrary"),
    .package(path: "../../../jon-platform/packages/ChatAccessKit"),
    .package(path: "../../../jon-platform/packages/MCPServerKit"),
    .package(path: "../../../jon-platform/packages/LLMHandoffKit"),
  ],
  targets: [
    .target(name: "GalavantMCPServer", dependencies: [
      .product(name: "GalavantSchema", package: "GalavantLibrary"),
      .product(name: "ChatAccessKit", package: "ChatAccessKit"),
      .product(name: "MCPServerKit", package: "MCPServerKit"),
      .product(name: "LLMHandoffKit", package: "LLMHandoffKit"),
    ]),
    .testTarget(name: "GalavantMCPTests", dependencies: [
      "GalavantMCPServer", .product(name: "ChatAccessKit", package: "ChatAccessKit"),
      .product(name: "LLMHandoffKit", package: "LLMHandoffKit"),
      .product(name: "MCPServerKit", package: "MCPServerKit"),
    ]),
    .executableTarget(name: "GalavantMCP", dependencies: [
      "GalavantMCPServer", .product(name: "ChatAccessKit", package: "ChatAccessKit"),
      .product(name: "MCPServerKit", package: "MCPServerKit"),
    ]),
  ],
  swiftLanguageModes: [.v6]
)
