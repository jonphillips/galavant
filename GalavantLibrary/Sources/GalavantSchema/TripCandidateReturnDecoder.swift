import Foundation

public struct TripCandidateReturn: Equatable, Sendable {
  public let candidates: [TripCandidate]
  public let note: String?
}

enum TripCandidateReturnDecoder {
  static func decode(_ text: String) throws -> TripCandidateReturn {
    let cleaned = removingCodeFenceLines(from: normalizeQuotes(in: text))
    if let entries = topLevelObjectEntries(in: cleaned),
      let places = entries.first(where: { $0.key == "places" })?.value,
      let candidates = decodeCandidates(places)
    {
      guard !candidates.isEmpty else { throw TripCandidateDecodeError.emptyCandidates }
      let notes = entries.compactMap { entry -> String? in
        guard entry.key != "places", let note = try? JSONDecoder().decode(String.self, from: Data(entry.value.utf8))
        else { return nil }
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : "\(entry.key): \(value)"
      }
      return TripCandidateReturn(candidates: candidates, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }

    guard let array = jsonArraySlice(in: cleaned) else { throw TripCandidateDecodeError.missingJSONArray }
    guard let candidates = decodeCandidates(array) else { throw TripCandidateDecodeError.malformedJSON }
    guard !candidates.isEmpty else { throw TripCandidateDecodeError.emptyCandidates }
    let surroundingText = String(cleaned.replacingOccurrences(of: array, with: ""))
    let note = removingJSONFragments(from: removingCodeFenceLines(from: surroundingText))
    return TripCandidateReturn(candidates: candidates, note: note.nonEmpty)
  }

  private static func decodeCandidates(_ json: String) -> [TripCandidate]? {
    try? JSONDecoder().decode([TripCandidate].self, from: Data(json.utf8))
  }

  private static func normalizeQuotes(in text: String) -> String {
    text
      .replacingOccurrences(of: "“", with: "\"")
      .replacingOccurrences(of: "”", with: "\"")
      .replacingOccurrences(of: "‘", with: "'")
      .replacingOccurrences(of: "’", with: "'")
  }

  private static func removingCodeFenceLines(from text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func removingJSONFragments(from text: String) -> String {
    let fragments: Set<String> = ["{", "}", ",", "[", "]"]
    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if fragments.contains(trimmed) { return "" }
        if trimmed.hasPrefix("{") && trimmed.contains("\"") && trimmed.hasSuffix(":") { return "" }
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix(":") { return "" }
        return String(line)
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Scanning source order preserves the order Chat used; nested values stay opaque.
  private static func topLevelObjectEntries(in text: String) -> [(key: String, value: String)]? {
    let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard source.first == "{", source.last == "}",
      (try? JSONSerialization.jsonObject(with: Data(source.utf8))) is [String: Any]
    else { return nil }

    var entries: [(key: String, value: String)] = []
    var cursor = source.index(after: source.startIndex)
    while cursor < source.endIndex {
      skipWhitespace(in: source, cursor: &cursor)
      guard cursor < source.endIndex, source[cursor] != "}" else { break }
      guard source[cursor] == "\"", let keyEnd = stringEnd(in: source, openingAt: cursor) else { return nil }
      let keyData = Data(source[cursor...keyEnd].utf8)
      guard let key = try? JSONDecoder().decode(String.self, from: keyData) else { return nil }
      cursor = source.index(after: keyEnd)
      skipWhitespace(in: source, cursor: &cursor)
      guard cursor < source.endIndex, source[cursor] == ":" else { return nil }
      cursor = source.index(after: cursor)
      skipWhitespace(in: source, cursor: &cursor)
      let valueStart = cursor
      guard let valueEnd = topLevelValueEnd(in: source, startingAt: cursor) else { return nil }
      entries.append((key, String(source[valueStart..<valueEnd]).trimmingCharacters(in: .whitespacesAndNewlines)))
      cursor = valueEnd
      if cursor < source.endIndex, source[cursor] == "," { cursor = source.index(after: cursor) }
    }
    return entries
  }

  private static func skipWhitespace(in text: String, cursor: inout String.Index) {
    while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
  }

  private static func stringEnd(in text: String, openingAt open: String.Index) -> String.Index? {
    var index = text.index(after: open)
    var escaped = false
    while index < text.endIndex {
      let character = text[index]
      if escaped { escaped = false }
      else if character == "\\" { escaped = true }
      else if character == "\"" { return index }
      index = text.index(after: index)
    }
    return nil
  }

  private static func topLevelValueEnd(in text: String, startingAt start: String.Index) -> String.Index? {
    var index = start
    var stack: [Character] = []
    var inString = false
    var escaped = false
    while index < text.endIndex {
      let character = text[index]
      if inString {
        if escaped { escaped = false }
        else if character == "\\" { escaped = true }
        else if character == "\"" { inString = false }
      } else if character == "\"" {
        inString = true
      } else if character == "[" || character == "{" {
        stack.append(character)
      } else if character == "]" || character == "}" {
        if stack.isEmpty { return index }
        stack.removeLast()
      } else if character == "," && stack.isEmpty {
        return index
      }
      index = text.index(after: index)
    }
    return index
  }

  private static func jsonArraySlice(in text: String) -> String? {
    var index = text.startIndex
    while index < text.endIndex {
      guard text[index] == "[" else {
        index = text.index(after: index)
        continue
      }
      let contentsStart = text.index(after: index)
      guard let firstContent = text[contentsStart...].firstIndex(where: { !$0.isWhitespace }),
        text[firstContent] == "{" || text[firstContent] == "]"
      else {
        index = contentsStart
        continue
      }
      if let close = matchingArrayClose(in: text, openingAt: index) {
        return String(text[index...close])
      }
      index = contentsStart
    }
    return nil
  }

  private static func matchingArrayClose(in text: String, openingAt open: String.Index) -> String.Index? {
    var depth = 0
    var inString = false
    var escaped = false
    var index = open
    while index < text.endIndex {
      let character = text[index]
      if inString {
        if escaped { escaped = false }
        else if character == "\\" { escaped = true }
        else if character == "\"" { inString = false }
      } else {
        switch character {
        case "\"": inString = true
        case "[": depth += 1
        case "]":
          depth -= 1
          if depth == 0 { return index }
        default: break
        }
      }
      index = text.index(after: index)
    }
    return nil
  }
}

private extension String {
  var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
