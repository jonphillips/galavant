import CloudSyncKit
import Foundation

public struct SyncFailureRecordKey: Hashable, Sendable {
  public var recordType: String
  public var primaryKey: String

  public init(recordType: String, primaryKey: String) {
    self.recordType = recordType
    self.primaryKey = primaryKey
  }
}

/// The parent name resolved for one local row. The display builder stays pure; the
/// caller supplies these facts from the database.
public enum SyncFailureDisplayName: Equatable, Sendable {
  case idea(String)
  case trip(String)
}

public struct SyncFailureDisplayRow: Identifiable, Equatable, Sendable {
  public var recordType: String
  public var primaryKeys: [String]
  public var title: String
  public var detail: String

  public var id: String { "\(recordType):\(primaryKeys.sorted().joined(separator: ",")): \(title)" }
}

/// Pure naming and grouping for the bounded keys in a sync-failure report.
public enum SyncFailureDisplayRows {
  public static func build(
    from report: SyncFailureReport,
    names: [SyncFailureRecordKey: SyncFailureDisplayName]
  ) -> [SyncFailureDisplayRow] {
    var result: [SyncFailureDisplayRow] = []
    for group in report.notUploaded {
      var grouped: [String: [String]] = [:]
      var missingKeys: [String] = []

      for key in group.primaryKeys {
        let rowKey = SyncFailureRecordKey(recordType: group.recordType, primaryKey: key)
        if group.recordType == "ideas", case let .idea(name)? = names[rowKey] {
          grouped[name, default: []].append(key)
        } else if group.recordType == "trips", case let .trip(name)? = names[rowKey] {
          grouped[name, default: []].append(key)
        } else if let parent = names[rowKey], let title = childTitle(recordType: group.recordType, parent: parent) {
          grouped[title, default: []].append(key)
        } else {
          missingKeys.append(key)
        }
      }

      for title in grouped.keys.sorted() {
        let keys = grouped[title, default: []]
        result.append(SyncFailureDisplayRow(
          recordType: group.recordType,
          primaryKeys: keys,
          title: title,
          detail: readableTableName(group.recordType)
        ))
      }

      if !missingKeys.isEmpty {
        result.append(aggregateRow(recordType: group.recordType, count: missingKeys.count, keys: missingKeys))
      }
      let unlistedCount = group.count - group.primaryKeys.count
      if unlistedCount > 0 {
        result.append(SyncFailureDisplayRow(
          recordType: group.recordType,
          primaryKeys: [],
          title: "\(unlistedCount) more \(unlistedCount == 1 ? "row" : "rows")",
          detail: "\(readableTableName(group.recordType)) not listed"
        ))
      }
    }
    return result
  }

  public static func aggregateRow(
    recordType: String,
    count: Int,
    keys: [String]
  ) -> SyncFailureDisplayRow {
    SyncFailureDisplayRow(
      recordType: recordType,
      primaryKeys: keys,
      title: "\(count) \(count == 1 ? "row" : "rows")",
      detail: readableTableName(recordType)
    )
  }

  public static func parentColumns(for recordType: String) -> [String] {
    if recordType == "tripIdeas" { return ["ideaID", "tripID"] }
    if ideaChildTitles[recordType] != nil { return ["ideaID"] }
    if tripChildTitles[recordType] != nil { return ["tripID"] }
    return []
  }

  private static func childTitle(recordType: String, parent: SyncFailureDisplayName) -> String? {
    switch parent {
    case let .idea(name):
      guard let noun = ideaChildTitles[recordType] else { return nil }
      return "\(noun) for \(name)"
    case let .trip(name):
      guard let noun = tripChildTitles[recordType] else { return nil }
      return "\(noun) in \(name)"
    }
  }

  private static func readableTableName(_ name: String) -> String {
    let spaced = name.replacingOccurrences(
      of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression
    )
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
  }

  private static let ideaChildTitles = [
    "ideaInterests": "Interest", "ideaTags": "Tag", "imageAssets": "Photo",
    "ideaEvaluations": "Evaluation", "tripIdeas": "Stop"
  ]

  private static let tripChildTitles = [
    "tripIdeas": "Stop", "tripRegions": "Region", "tripStays": "Stay",
    "tripDocuments": "Document", "tripDayRegions": "Day region",
    "tripDayTimeZones": "Time zone", "tripDayNotes": "Day note",
    "tripAlternativeGroups": "Alternative group"
  ]
}

extension SyncFailureDisplayName {
  public enum Kind: Equatable, Sendable {
    case idea
    case trip
  }
}
