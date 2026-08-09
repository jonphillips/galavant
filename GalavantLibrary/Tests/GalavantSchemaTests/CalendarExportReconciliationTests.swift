import Foundation
import GalavantSchema
import Testing

/// `CalendarExportReconciliation.plan` is the "reconcile, don't duplicate" core
/// of the calendar-export re-export requirement (BACKLOG "Export itinerary to
/// Apple Calendar / iCal"). Pure — no EventKit, no `UserDefaults` — so the
/// create/update/delete decision is fully unit-testable without a real
/// calendar or a mock store.
@Suite struct CalendarExportReconciliationTests {
  func item(_ id: TripIdea.ID = UUID(), title: String = "Stop") -> CalendarExportItem {
    CalendarExportItem(id: id, title: title, notes: nil, start: .now, end: .now, isAllDay: false)
  }

  @Test func firstExportCreatesEverythingWithNoPriorMapping() {
    let a = item(title: "A")
    let b = item(title: "B")
    let plan = CalendarExportReconciliation.plan(items: [a, b], existingMapping: [:])
    #expect(plan.toCreate.map(\.title) == ["A", "B"])
    #expect(plan.toUpdate.isEmpty)
    #expect(plan.toDeleteIdentifiers.isEmpty)
  }

  @Test func reExportWithUnchangedStopsUpdatesInPlace() {
    let a = item(title: "A")
    let b = item(title: "B")
    let mapping: [TripIdea.ID: String] = [a.id: "event-a", b.id: "event-b"]
    let plan = CalendarExportReconciliation.plan(items: [a, b], existingMapping: mapping)
    #expect(plan.toCreate.isEmpty)
    #expect(plan.toDeleteIdentifiers.isEmpty)
    #expect(Set(plan.toUpdate.map(\.identifier)) == ["event-a", "event-b"])
    let identifierByItemID = Dictionary(uniqueKeysWithValues: plan.toUpdate.map { ($0.item.id, $0.identifier) })
    #expect(identifierByItemID[a.id] == "event-a")
    #expect(identifierByItemID[b.id] == "event-b")
  }

  @Test func removedStopIsQueuedForDeletionAndDroppedFromCreateOrUpdate() {
    let a = item(title: "A")
    let removedID = TripIdea.ID()
    let mapping: [TripIdea.ID: String] = [a.id: "event-a", removedID: "event-removed"]
    let plan = CalendarExportReconciliation.plan(items: [a], existingMapping: mapping)
    #expect(plan.toCreate.isEmpty)
    #expect(plan.toUpdate.map(\.identifier) == ["event-a"])
    #expect(plan.toDeleteIdentifiers == ["event-removed"])
  }

  @Test func mixedPassCreatesUpdatesAndDeletesTogether() {
    let existing = item(title: "Existing")
    let new = item(title: "New")
    let removedID = TripIdea.ID()
    let mapping: [TripIdea.ID: String] = [existing.id: "event-existing", removedID: "event-removed"]
    let plan = CalendarExportReconciliation.plan(items: [existing, new], existingMapping: mapping)
    #expect(plan.toCreate.map(\.title) == ["New"])
    #expect(plan.toUpdate.map(\.item.title) == ["Existing"])
    #expect(plan.toDeleteIdentifiers == ["event-removed"])
  }

  @Test func emptyItemsDeletesEverythingPreviouslyMapped() {
    let mapping: [TripIdea.ID: String] = [TripIdea.ID(): "event-a", TripIdea.ID(): "event-b"]
    let plan = CalendarExportReconciliation.plan(items: [], existingMapping: mapping)
    #expect(plan.toCreate.isEmpty)
    #expect(plan.toUpdate.isEmpty)
    #expect(Set(plan.toDeleteIdentifiers) == ["event-a", "event-b"])
  }
}
