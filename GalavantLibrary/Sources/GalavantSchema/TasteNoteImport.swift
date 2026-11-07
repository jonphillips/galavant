import Foundation

/// The conversation return boundary is lossless-or-loud: malformed input or an
/// unusable list fails; malformed individual rows are reported with their index.
public enum TasteNoteImport {
  public static let prompt = """
    Review this conversation and your available memory for durable travel taste about restaurants, hotels, and travel in general. Propose notes in the person's exact words whenever available. If you summarize, mark the row as a summary. Name the place when relevant and briefly say why. Do not invent details. Return only JSON in this shape:
    { "notes": [{ "note": "…", "words": "person", "who": "jon", "place": "…", "locality": "…", "date": "2026-03", "from": "…" }] }
    Use who=jon, wendy, or both; words=person or summary. Date may be year, year-month, or full date.
    """

  public struct Row: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var body: String
    public var isSummary: Bool
    public var who: String
    public var placeName: String?
    public var locality: String?
    public var notedAt: Date?
    public var sourceDetail: String?

    public init(id: UUID = UUID(), body: String, isSummary: Bool, who: String,
                placeName: String?, locality: String?, notedAt: Date?, sourceDetail: String?) {
      self.id = id
      self.body = body
      self.isSummary = isSummary
      self.who = who
      self.placeName = placeName
      self.locality = locality
      self.notedAt = notedAt
      self.sourceDetail = sourceDetail
    }
  }

  public struct Result: Equatable, Sendable {
    public var rows: [Row]
    public var warnings: [String]
  }

  public static func decode(_ text: String) throws -> Result {
    let payload = jsonObjectSlice(text)
    guard let data = payload.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw TasteNoteImportError.malformedJSON }
    guard let rawRows = root["notes"] as? [Any] else { throw TasteNoteImportError.missingNotes }
    var rows: [Row] = []
    var warnings: [String] = []
    for (index, raw) in rawRows.enumerated() {
      guard let object = raw as? [String: Any] else {
        warnings.append("Row \(index + 1) was not an object and was skipped.")
        continue
      }
      guard let body = (object["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
        warnings.append("Row \(index + 1) had no note text and was skipped.")
        continue
      }
      let rawDate = object["date"] as? String
      let notedAt = parseDate(rawDate)
      if rawDate != nil, notedAt == nil {
        warnings.append("Row \(index + 1) had an unrecognized date; it will use the save date.")
      }
      let words = (object["words"] as? String)?.lowercased()
      rows.append(Row(
        body: body, isSummary: words != "person",
        who: (object["who"] as? String).flatMap { ["jon", "wendy", "both"].contains($0.lowercased()) ? $0.lowercased() : nil } ?? "both",
        placeName: clean(object["place"] as? String), locality: clean(object["locality"] as? String),
        notedAt: notedAt, sourceDetail: clean(object["from"] as? String)
      ))
    }
    guard !rows.isEmpty else { throw TasteNoteImportError.noUsableNotes }
    return Result(rows: rows, warnings: warnings)
  }

  /// Extracts the first balanced JSON object from surrounding prose; GV-NOTES is a
  /// delimiter hint, never a validity gate (ADR-0048 Amendment 2).
  private static func jsonObjectSlice(_ text: String) -> String {
    let candidate: Substring
    if let marker = text.range(of: "GV-NOTES", options: .backwards) { candidate = text[marker.upperBound...] }
    else { candidate = text[...] }
    guard let start = candidate.firstIndex(of: "{") else { return "" }
    var depth = 0
    var inString = false
    var escaped = false
    var index = start
    while index < candidate.endIndex {
      let character = candidate[index]
      if inString {
        if escaped { escaped = false }
        else if character == "\\" { escaped = true }
        else if character == "\"" { inString = false }
      } else {
        switch character {
        case "\"": inString = true
        case "{": depth += 1
        case "}":
          depth -= 1
          if depth == 0 { return String(candidate[start...index]) }
        default: break
        }
      }
      candidate.formIndex(after: &index)
    }
    return ""
  }

  private static func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formats = ["yyyy-MM-dd", "yyyy-MM", "yyyy"]
    for format in formats {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value), formatter.string(from: date) == value { return date }
    }
    return nil
  }
}

public enum TasteNoteImportError: Error, Equatable {
  case malformedJSON
  case missingNotes
  case noUsableNotes
}
