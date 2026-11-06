import ChatAccessKit
import Foundation
import GalavantSchema
import MCPServerKit

struct ExportSnapshot: Sendable {
  var value: GalavantChatExport
  var ageMinutes: Int
}

actor GalavantExportStore {
  private let home: URL
  private let isDevelopment: Bool
  private let now: @Sendable () -> Date
  private let materialize: ChatAccessExportReader.Materializer?
  private let deadline: Duration
  private var reader: ChatAccessExportReader?
  private var cachedModifiedAt: Date?
  private var cachedData: Data?
  private var cached: ExportSnapshot?

  init(home: URL, isDevelopment: Bool, now: @escaping @Sendable () -> Date,
       materialize: ChatAccessExportReader.Materializer?, deadline: Duration) {
    self.home = home
    self.isDevelopment = isDevelopment
    self.now = now
    self.materialize = materialize
    self.deadline = deadline
  }

  func load() async throws -> ExportSnapshot {
    if reader == nil {
      let folder = try ChatAccessHelperFolder.existing(
        containerIdentifier: "iCloud.com.jonphillips.galavant", isDevelopment: isDevelopment, home: home)
      reader = ChatAccessExportReader(folder: folder, materializationDeadline: deadline, materialize: materialize)
    }
    let file: ChatAccessExportFile
    do { file = try await reader!.readLatest() }
    catch ChatAccessExportReaderError.noExport {
      throw ReadToolError("No Galavant export yet. Open Galavant on the iPhone or iPad and tap Refresh in Settings → Chat Access.")
    } catch ChatAccessExportReaderError.materializationTimedOut {
      throw ReadToolError("The Galavant export is still downloading from iCloud. Try again in a minute.")
    }
    if file.modifiedAt == cachedModifiedAt, file.data == cachedData, let cached {
      var result = cached
      result.ageMinutes = max(0, Int(now().timeIntervalSince(result.value.generatedAt) / 60))
      self.cached = result
      return result
    }
    let value: GalavantChatExport
    do { value = try GalavantChatExport.decode(file.data) }
    catch GalavantChatExport.DecodeError.unsupportedVersion {
      throw ReadToolError("This Galavant export uses a newer format. Reinstall the Galavant helper.")
    }
    let result = ExportSnapshot(value: value, ageMinutes: max(0, Int(now().timeIntervalSince(value.generatedAt) / 60)))
    cachedModifiedAt = file.modifiedAt
    cachedData = file.data
    cached = result
    return result
  }
}

private struct ReadToolError: LocalizedError {
  var errorDescription: String?
  init(_ text: String) { errorDescription = text }
}

enum ChatAccessReadTools {
  private static let maxTrips = 100
  private static let maxLinesPerSection = 120
  private static let maxLineCharacters = 500
  private static let maxNotesCharacters = 20_000

  static func make(home: URL, isDevelopment: Bool, now: @escaping @Sendable () -> Date,
                   exportMaterializer: ChatAccessExportReader.Materializer?,
                   materializationDeadline: Duration, store: GalavantExportStore? = nil) -> [MCPTool] {
    let store = store ?? GalavantExportStore(home: home, isDevelopment: isDevelopment, now: now,
      materialize: exportMaterializer, deadline: materializationDeadline)
    return [
      tool("list_trips", "List trips in the latest Galavant export. Start here when this chat has no GV-TRIP line.",
           schema: schema([:], required: [])) { _ in
        let snapshot = try await store.load()
        let trips = orderedTrips(snapshot.value.trips, today: dateString(now()))
        let rows = trips.prefix(maxTrips).map { trip in
          MCPValue.object(["id": .string(trip.id.uuidString), "name": .string(String(trip.name.prefix(maxLineCharacters))),
            "startDate": trip.startDate.map(MCPValue.string) ?? .null,
            "targetYear": trip.targetYear.map(MCPValue.integer) ?? .null,
            "targetQuarter": trip.targetQuarter.map(MCPValue.integer) ?? .null,
            "lengthInDays": .integer(trip.lengthInDays)])
        }
        let longNames = trips.prefix(maxTrips).filter { $0.name.count > maxLineCharacters }.count
        let omitted = max(0, trips.count - maxTrips) + longNames
        let result: [String: MCPValue] = ["generatedAt": .string(iso(snapshot.value.generatedAt)), "ageMinutes": .integer(snapshot.ageMinutes),
          "device": .string(snapshot.value.device), "trips": .array(rows), "truncated": .bool(omitted > 0),
          "omittedCount": .integer(omitted)]
        return .json(result)
      },
      tool("get_trip", "Read one trip by the UUID returned by list_trips.",
           schema: schema(["trip": .object(["type": .string("string")])], required: ["trip"])) { input in
        let snapshot = try await store.load()
        guard let rawID = input.objectValue?["trip"]?.stringValue, let id = UUID(uuidString: rawID),
              let trip = snapshot.value.trips.first(where: { $0.id == id }) else {
          throw ReadToolError("Unknown trip ID. Call list_trips and choose one of its IDs.")
        }
        let plan = boundedLines(trip.planLines)
        let ruledOut = boundedLines(trip.ruledOutLines)
        let taste = boundedLines(trip.tasteLines)
        let considering = boundedLines(trip.consideringTitles)
        let shortlisted = boundedLines(trip.shortlistedTitles)
        let notesTruncated = trip.notes.count > maxNotesCharacters
        let nameTruncated = trip.name.count > maxLineCharacters
        let omitted = plan.omitted + ruledOut.omitted + taste.omitted + considering.omitted + shortlisted.omitted
          + (notesTruncated ? 1 : 0) + (nameTruncated ? 1 : 0)
        let tripValue: [String: MCPValue] = [
          "id": .string(trip.id.uuidString), "name": .string(String(trip.name.prefix(maxLineCharacters))),
          "startDate": trip.startDate.map(MCPValue.string) ?? .null,
          "targetYear": trip.targetYear.map(MCPValue.integer) ?? .null,
          "targetQuarter": trip.targetQuarter.map(MCPValue.integer) ?? .null,
          "lengthInDays": .integer(trip.lengthInDays), "notes": .string(String(trip.notes.prefix(maxNotesCharacters))),
          "planLines": .array(plan.values), "ruledOutLines": .array(ruledOut.values), "tasteLines": .array(taste.values),
          "consideringTitles": .array(considering.values), "shortlistedTitles": .array(shortlisted.values),
          "truncated": .bool(omitted > 0), "omittedCount": .integer(omitted)
        ]
        let result: [String: MCPValue] = ["generatedAt": .string(iso(snapshot.value.generatedAt)),
          "ageMinutes": .integer(snapshot.ageMinutes), "device": .string(snapshot.value.device), "trip": .object(tripValue)]
        return .json(result)
      }
    ]
  }

  private static func schema(_ properties: [String: MCPValue], required: [String]) -> MCPValue {
    .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(MCPValue.string)), "additionalProperties": .bool(false)])
  }
  private static func boundedLines(_ lines: [String]) -> (values: [MCPValue], omitted: Int) {
    let included = lines.prefix(maxLinesPerSection)
    let values = included.map { MCPValue.string(String($0.prefix(maxLineCharacters))) }
    let omitted = max(0, lines.count - maxLinesPerSection)
      + included.filter { $0.count > maxLineCharacters }.count
    return (values, omitted)
  }
  private static func orderedTrips(_ trips: [GalavantChatExport.Trip], today: String) -> [GalavantChatExport.Trip] {
    trips.sorted { left, right in
      func category(_ trip: GalavantChatExport.Trip) -> Int {
        guard let date = trip.startDate else { return 1 }
        return date >= today ? 0 : 2
      }
      let leftCategory = category(left)
      let rightCategory = category(right)
      if leftCategory != rightCategory { return leftCategory < rightCategory }
      if let leftDate = left.startDate, let rightDate = right.startDate, leftDate != rightDate {
        return leftCategory == 2 ? leftDate > rightDate : leftDate < rightDate
      }
      let nameOrder = left.name.localizedCaseInsensitiveCompare(right.name)
      if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
      return left.id.uuidString < right.id.uuidString
    }
  }
  private static func dateString(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
  }
  private static func tool(_ name: String, _ description: String, schema: MCPValue,
                           handler: @escaping @Sendable (MCPValue) async throws -> MCPToolResult) -> MCPTool {
    MCPTool(name: name, description: description, inputSchema: schema,
      annotations: .init(readOnly: true, destructive: false, openWorld: false), handler: handler)
  }
  private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
