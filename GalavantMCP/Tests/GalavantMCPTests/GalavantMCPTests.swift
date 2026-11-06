import ChatAccessKit
import Foundation
import GalavantSchema
import GalavantMCPServer
import LLMHandoffKit
import MCPServerKit
import Testing

struct GalavantMCPTests {
  @Test func listsReadsAndStagesAChatStartedWithoutABrief() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let tripID = UUID()
    let export = GalavantChatExport(generatedAt: Date(timeIntervalSince1970: 1_800_000_000), device: "iPhone", trips: [
      GalavantChatExport.Trip(id: tripID, name: "Copenhagen", startDate: nil, lengthInDays: 5, notes: "", planLines: [],
        ruledOutLines: ["Already ruled out (don't suggest again):", "- Tower"], tasteLines: [], consideringTitles: [], shortlistedTitles: [])
    ])
    try write(export, home: home)
    let server = GalavantMCPServer.make(home: home)
    let listed = try #require(await server.handle(line: toolCall("list_trips", arguments: [:])))
    #expect(listed.contains("Copenhagen"))
    #expect(listed.contains(tripID.uuidString))
    let firstList = try result(listed)
    let listedAgain = try #require(await server.handle(line: toolCall("list_trips", arguments: [:])))
    #expect(try result(listedAgain) == firstList)

    let read = try #require(await server.handle(line: toolCall("get_trip", arguments: ["trip": .string(tripID.uuidString)])))
    #expect(read.contains("Already ruled out"))
    let readAgain = try #require(await server.handle(line: toolCall("get_trip", arguments: ["trip": .string(tripID.uuidString)])))
    #expect(try result(readAgain) == result(read))
    let unknown = try #require(await server.handle(line: toolCall("get_trip", arguments: ["trip": .string(UUID().uuidString)])))
    #expect(responseText(unknown).contains("list_trips"))
    let text = "GV-CONTRACT: v2\n[{\"name\":\"Museum\"}]"
    let rejectedID = UUID()
    let rejected = try #require(await server.handle(line: toolCall("stage_trip_return", arguments: ["trip": .string(rejectedID.uuidString), "text": .string(text)])))
    #expect(try result(rejected)["isError"] == .bool(true))
    #expect(responseText(rejected).contains("list_trips"))
    let staged = try #require(await server.handle(line: toolCall("stage_trip_return", arguments: ["trip": .string(tripID.uuidString), "text": .string(text)])))
    #expect(try result(staged)["isError"] != .bool(true))
    let inbox = HandoffInbox(root: ChatAccessFolder(containerURL: ChatAccessHelperFolder.containerURL(
      for: "iCloud.com.jonphillips.galavant", home: home), isDevelopment: false).inboxURL, fileExtension: "gvreturn")
    #expect(try inbox.list().count == 1)
  }

  @Test func listSortsTripsBeforeItsCapAndReportsTheOmittedOldTrip() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let trips = (0..<100).map { index in
      GalavantChatExport.Trip(id: UUID(), name: "Future \(index)", startDate: "2030-01-\(String(format: "%02d", index % 28 + 2))", lengthInDays: 3,
        notes: "", planLines: [], ruledOutLines: [], tasteLines: [], consideringTitles: [], shortlistedTitles: [])
    }
    let oldest = GalavantChatExport.Trip(id: UUID(), name: "Oldest", startDate: "2020-01-01", lengthInDays: 3,
      notes: "", planLines: [], ruledOutLines: [], tasteLines: [], consideringTitles: [], shortlistedTitles: [])
    try write(GalavantChatExport(generatedAt: Date(), device: "iPad", trips: [oldest] + trips), home: home)
    let fixedNow = ISO8601DateFormatter().date(from: "2030-01-01T12:00:00Z")!
    let response = try #require(await GalavantMCPServer.make(home: home, now: { fixedNow })
      .handle(line: toolCall("list_trips", arguments: [:])))
    let result = try jsonContent(response)
    #expect(result.objectValue?["truncated"] == .bool(true))
    #expect(result.objectValue?["omittedCount"] == .integer(1))
    let rows = try #require(array(result.objectValue?["trips"]))
    #expect(rows.count == 100)
    #expect(rows.compactMap { $0.objectValue?["name"]?.stringValue }.contains("Oldest") == false)
    #expect(rows.first?.objectValue?["name"] == MCPValue.string("Future 0"))
  }

  @Test func tokenReturnSkipsSuccessfulExportCheck() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let container = ChatAccessHelperFolder.containerURL(for: "iCloud.com.jonphillips.galavant", home: home)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    try write(GalavantChatExport(generatedAt: Date(), device: "iPhone", trips: []), home: home)
    let tripID = UUID()
    let text = "GV-HANDOFF: \(UUID())\nGV-CONTRACT: v2\n[{\"name\":\"Museum\"}]"
    let server = GalavantMCPServer.make(home: home)
    let response = try #require(await server.handle(line: toolCall("stage_trip_return", arguments: [
      "trip": .string(tripID.uuidString), "text": .string(text)])))
    #expect(try result(response)["isError"] != .bool(true))
    #expect(try HandoffInbox(root: ChatAccessFolder(containerURL: container, isDevelopment: false).inboxURL,
      fileExtension: "gvreturn").list().count == 1)
  }

  @Test func getTripUsesIndependentSectionAndNoteCapsAndReportsEveryOmission() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let tripID = UUID()
    let trip = GalavantChatExport.Trip(id: tripID, name: "Copenhagen", startDate: "2027-03-10", lengthInDays: 5,
      notes: String(repeating: "n", count: 20_001),
      planLines: [String(repeating: "p", count: 501)] + (0..<121).map { "Plan \($0)" },
      ruledOutLines: (0..<121).map { "Ruled out \($0)" }, tasteLines: ["Taste note"],
      consideringTitles: (0..<121).map { "Considering \($0)" },
      shortlistedTitles: [String(repeating: "s", count: 501)])
    try write(GalavantChatExport(generatedAt: Date(), device: "iPhone", trips: [trip]), home: home)
    let response = try #require(await GalavantMCPServer.make(home: home)
      .handle(line: toolCall("get_trip", arguments: ["trip": .string(tripID.uuidString)])))
    let result = try jsonContent(response)
    let value = try #require(result.objectValue?["trip"]?.objectValue)
    #expect(value["startDate"] == .string("2027-03-10"))
    #expect(value["notes"]?.stringValue?.count == 20_000)
    #expect(array(value["planLines"])?.count == 120)
    #expect(array(value["ruledOutLines"])?.count == 120)
    #expect(array(value["tasteLines"]) == [MCPValue.string("Taste note")])
    #expect(array(value["consideringTitles"])?.count == 120)
    #expect(array(value["shortlistedTitles"])?.first?.stringValue?.count == 500)
    #expect(value["truncated"] == .bool(true))
    #expect(value["omittedCount"] == .integer(7))
  }

  @Test func noExportNewerExportAndTimedOutExportHaveActionableErrors() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: ChatAccessHelperFolder.containerURL(
      for: "iCloud.com.jonphillips.galavant", home: home), withIntermediateDirectories: true)
    let noExport = GalavantMCPServer.make(home: home)
    let missing = try #require(await noExport.handle(line: toolCall("list_trips", arguments: [:])))
    #expect(responseText(missing).contains("No Galavant export yet"), "\(missing)")

    let newer = Data(#"{"version":99,"generatedAt":0,"device":"iPhone","trips":[]}"#.utf8)
    try write(newer, home: home)
    let newerResponse = try #require(await GalavantMCPServer.make(home: home).handle(line: toolCall("list_trips", arguments: [:])))
    #expect(responseText(newerResponse).contains("newer format"), "\(newerResponse)")
    #expect(responseText(newerResponse).lowercased().contains("reinstall"))

    let timeoutHome = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: timeoutHome) }
    try write(GalavantChatExport(generatedAt: Date(), device: "iPad", trips: []), home: timeoutHome)
    let timedOut = GalavantMCPServer.make(home: timeoutHome, exportMaterializer: { _ in
      try await Task.sleep(for: .seconds(2))
      return Data()
    }, materializationDeadline: .milliseconds(10))
    let timeoutResponse = try #require(await timedOut.handle(line: toolCall("list_trips", arguments: [:])))
    #expect(responseText(timeoutResponse).contains("still downloading from iCloud"), "\(timeoutResponse)")
  }

  @Test(arguments: ["newer", "timeout", "unreadable"])
  func aFailedExportReadNeverBlocksAChatStartedTrip(scenario: String) async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let data: Data
    if scenario == "newer" { data = Data(#"{"version":2,"generatedAt":0,"device":"iPad","trips":[]}"#.utf8) }
    else if scenario == "unreadable" { data = Data("not json".utf8) }
    else { data = try JSONEncoder().encode(GalavantChatExport(generatedAt: Date(), device: "iPhone", trips: [])) }
    try write(data, home: home)
    let materializer: ChatAccessExportReader.Materializer?
    if scenario == "timeout" {
      materializer = { _ in try await Task.sleep(for: .seconds(1)); return data }
    } else {
      materializer = nil
    }
    let server = GalavantMCPServer.make(home: home, exportMaterializer: materializer,
      materializationDeadline: .milliseconds(10))
    let text = "GV-CONTRACT: v2\n[{\"name\":\"Museum\"}]"
    let response = try #require(await server.handle(line: toolCall("stage_trip_return", arguments: [
      "trip": .string(UUID().uuidString), "text": .string(text)])))
    #expect(try result(response)["isError"] != .bool(true))
    let folder = ChatAccessFolder(containerURL: ChatAccessHelperFolder.containerURL(
      for: "iCloud.com.jonphillips.galavant", home: home), isDevelopment: false)
    #expect(try HandoffInbox(root: folder.inboxURL, fileExtension: "gvreturn").list().count == 1)
  }

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

  @Test func ambiguousSeedAndMissingTripAreRejected() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let container = ChatAccessHelperFolder.containerURL(for: "iCloud.com.jonphillips.galavant", home: home)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    let server = GalavantMCPServer.make(home: home)
    let seed = try #require(await server.handle(line: call(trip: UUID().uuidString, text: "{\"places\":[{\"name\":\"Museum\"}]}")))
    #expect(try result(seed)["isError"] == .bool(true))
    #expect(seed.contains("a line containing only GV-SEED before the JSON object"))
    #expect(seed.contains("one JSON array"))
    let invalid = try #require(await server.handle(line: call(trip: "Copenhagen", text: "[]")))
    #expect(try result(invalid)["isError"] == .bool(true))
    #expect(responseText(invalid).contains("list_trips"))
    let inbox = ChatAccessFolder(containerURL: container, isDevelopment: false).inboxURL
    #expect(!FileManager.default.fileExists(atPath: inbox.path))
  }

  @Test func stagesSeedAndCountsBasesAlongsidePlaces() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let container = ChatAccessHelperFolder.containerURL(for: "iCloud.com.jonphillips.galavant", home: home)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    let trip = UUID()
    let text = """
      GV-SEED
      {"bases":[{"name":"Inn","check_in_day":1,"check_out_day":2}],"places":[{"name":"Museum"}]}
      """
    let server = GalavantMCPServer.make(home: home)
    let response = try #require(await server.handle(line: call(trip: trip.uuidString, text: text)))
    #expect(try result(response)["isError"] != .bool(true))
    #expect(response.contains("Trip seed · 2 places"))
    #expect(response.contains("Review it in Galavant"))
    let inbox = HandoffInbox(root: ChatAccessFolder(containerURL: container, isDevelopment: false).inboxURL, fileExtension: "gvreturn")
    let staged = try #require(try inbox.list().first)
    #expect(staged.slug == trip.uuidString.lowercased())
    #expect(try inbox.read(staged) == text)
  }

  @Test func malformedSeedWritesNothing() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let container = ChatAccessHelperFolder.containerURL(for: "iCloud.com.jonphillips.galavant", home: home)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    let text = #"{"bases":[{"name":"Inn","check_in_day":1,"check_out_day":2}],"places":[{"name":"Museum","why":"the "best" one"}]}"#
    let server = GalavantMCPServer.make(home: home)
    let response = try #require(await server.handle(line: call(trip: UUID().uuidString, text: text)))
    #expect(try result(response)["isError"] == .bool(true))
    #expect(response.contains("trip seed with malformed JSON"))
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

  private func toolCall(_ name: String, arguments: [String: MCPValue]) -> String {
    let request: MCPValue = .object(["jsonrpc": .string("2.0"), "id": .integer(2), "method": .string("tools/call"),
      "params": .object(["name": .string(name), "arguments": .object(arguments)])])
    return String(decoding: try! JSONEncoder().encode(request), as: UTF8.self)
  }

  private func write(_ export: GalavantChatExport, home: URL) throws {
    try write(JSONEncoder().encode(export), home: home)
  }

  private func write(_ data: Data, home: URL) throws {
    let container = ChatAccessHelperFolder.containerURL(for: "iCloud.com.jonphillips.galavant", home: home)
    let folder = ChatAccessFolder(containerURL: container, isDevelopment: false)
    try FileManager.default.createDirectory(at: folder.exportsURL, withIntermediateDirectories: true)
    try data.write(to: folder.exportsURL.appending(path: "fixture.json"))
  }

  private func result(_ response: String) throws -> [String: MCPValue] {
    try JSONDecoder().decode(MCPValue.self, from: Data(response.utf8)).objectValue?["result"]?.objectValue ?? [:]
  }

  private func responseText(_ response: String) -> String {
    guard let result = try? result(response), case let .array(content)? = result["content"] else { return response }
    return content.compactMap { item in
      guard case let .object(values) = item, case let .string(text)? = values["text"] else { return nil }
      return text
    }.joined(separator: "\n")
  }

  private func jsonContent(_ response: String) throws -> MCPValue {
    try JSONDecoder().decode(MCPValue.self, from: Data(responseText(response).utf8))
  }

  private func array(_ value: MCPValue?) -> [MCPValue]? {
    guard case let .array(values) = value else { return nil }
    return values
  }
}
