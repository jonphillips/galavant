import Foundation

/// One update: an export item whose stop already has a recorded EventKit
/// identifier from a previous export pass — update that event in place rather
/// than creating a duplicate.
public struct CalendarExportUpdate: Equatable, Sendable {
  public var item: CalendarExportItem
  public var identifier: String

  public init(item: CalendarExportItem, identifier: String) {
    self.item = item
    self.identifier = identifier
  }
}

/// The three actions a re-export must take against the previous pass's
/// stop→identifier mapping (BACKLOG "re-export should reconcile (update/delete)
/// rather than duplicate"). Pure — a plan, not an execution; the app-target
/// model (`CalendarExportModel`) carries this out against the injectable
/// EventKit client and only then persists the new mapping.
public struct CalendarExportPlan: Equatable, Sendable {
  /// Items with no prior mapping entry — create a fresh event for each.
  public var toCreate: [CalendarExportItem]
  /// Items with a prior mapping entry — update that event in place (or, if the
  /// live executor finds the event no longer exists, recreate it).
  public var toUpdate: [CalendarExportUpdate]
  /// Mapping entries whose stop is no longer exportable (unscheduled, removed
  /// from the trip, or the trip shortened past it) — delete these events.
  public var toDeleteIdentifiers: [String]

  public init(
    toCreate: [CalendarExportItem] = [],
    toUpdate: [CalendarExportUpdate] = [],
    toDeleteIdentifiers: [String] = []
  ) {
    self.toCreate = toCreate
    self.toUpdate = toUpdate
    self.toDeleteIdentifiers = toDeleteIdentifiers
  }
}

/// Pure diff between this export pass's items and the previous pass's
/// stop→EventKit-identifier mapping (`CalendarExportIdentityStore`) — the
/// "reconcile, don't duplicate" core of the re-export requirement. No EventKit,
/// no UserDefaults, no I/O: a plan in, a plan out, so it's testable with plain
/// values.
public enum CalendarExportReconciliation {
  public static func plan(
    items: [CalendarExportItem],
    existingMapping: [TripIdea.ID: String]
  ) -> CalendarExportPlan {
    var toCreate: [CalendarExportItem] = []
    var toUpdate: [CalendarExportUpdate] = []
    for item in items {
      if let identifier = existingMapping[item.id] {
        toUpdate.append(CalendarExportUpdate(item: item, identifier: identifier))
      } else {
        toCreate.append(item)
      }
    }
    let currentIDs = Set(items.map(\.id))
    let toDeleteIdentifiers = existingMapping
      .filter { !currentIDs.contains($0.key) }
      .map(\.value)
    return CalendarExportPlan(toCreate: toCreate, toUpdate: toUpdate, toDeleteIdentifiers: toDeleteIdentifiers)
  }
}
