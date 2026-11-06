import ChatAccessKit
import Foundation
import GalavantMCPServer
import LLMHandoffKit
import MCPServerKit
import Testing

struct GalavantMCPTests {
  @Test func stagesValidatedTextAndRefusesBadReturns() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let container = ChatAccessHelperFolder.containerURL(for: "iCloud.com.jonphillips.galavant", home: home)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let server = GalavantMCPServer.make(home: home, now: { date })
    let trip = UUID()
    let text = "GV-CONTRACT: v2\n[{\"name\":\"Museum\"}]"
    let response = try #require(await server.handle(line: call(trip: trip.uuidString, text: text)))
    #expect(try result(response)["isError"] != .bool(true))
    let inbox = HandoffInbox(root: ChatAccessFolder(containerURL: container, isDevelopment: false).inboxURL, fileExtension: "gvreturn")
    let staged = try #require(try inbox.list().first)
    #expect(staged.slug == trip.uuidString.lowercased())
    #expect(try inbox.read(staged) == text)
    let bad = try #require(await server.handle(line: call(trip: trip.uuidString, text: "[]")))
    #expect(try result(bad)["isError"] == .bool(true))
    #expect(try inbox.list().count == 1)
  }

  @Test func seedAndMissingTripAreRejected() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let container = ChatAccessHelperFolder.containerURL(for: "iCloud.com.jonphillips.galavant", home: home)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    let server = GalavantMCPServer.make(home: home)
    let seed = try #require(await server.handle(line: call(trip: UUID().uuidString, text: "{\"places\":[{\"name\":\"Museum\"}]}")))
    #expect(try result(seed)["isError"] == .bool(true))
    let invalid = try #require(await server.handle(line: call(trip: "", text: "[]")))
    #expect(try result(invalid)["isError"] == .bool(true))
    let inbox = ChatAccessFolder(containerURL: container, isDevelopment: false).inboxURL
    #expect(!FileManager.default.fileExists(atPath: inbox.path))
  }

  @Test func missingContainerIsNotCreated() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let container = ChatAccessHelperFolder.containerURL(for: "iCloud.com.jonphillips.galavant", home: home)
    let server = GalavantMCPServer.make(home: home)
    let response = try #require(await server.handle(line: call(trip: UUID().uuidString, text: "[{\"name\":\"Museum\"}]")))
    #expect(try result(response)["isError"] == .bool(true))
    #expect(!FileManager.default.fileExists(atPath: container.path))
  }

  private func call(trip: String, text: String) -> String {
    let request: MCPValue = .object([
      "jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("tools/call"),
      "params": .object(["name": .string("stage_trip_return"), "arguments": .object(["trip": .string(trip), "text": .string(text)])]),
    ])
    return String(decoding: try! JSONEncoder().encode(request), as: UTF8.self)
  }

  private func result(_ response: String) throws -> [String: MCPValue] {
    try JSONDecoder().decode(MCPValue.self, from: Data(response.utf8)).objectValue?["result"]?.objectValue ?? [:]
  }
}
