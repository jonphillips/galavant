import Foundation
import GalavantSchema
import Testing

@Suite struct TripPlanSnapshotTests {
  private func baseInputs() -> TripPlanInputs {
    let tripID = UUID()
    let ideaID = UUID()
    let groupID = UUID()
    var entry = TripIdea.freeform(
      id: UUID(), tripID: tripID, title: "Stop", note: "Original", shortlistRank: 0)
    entry.apply(.day(1))
    let commitment = CalendarCommitment(
      temporal: .allDay(
        start: CalendarCivilDate(year: 2026, month: 11, day: 7)!,
        endExclusive: CalendarCivilDate(year: 2026, month: 11, day: 8)!),
      availability: .free)!
    let constraint = CalendarTripConstraint(
      id: UUID(), tripID: tripID, sourceIdentityHash: "hash", title: "Call",
      dayNumber: 1, startTime: nil, endTime: nil, commitment: commitment)!
    return TripPlanInputs(
      tripID: tripID,
      lengthInDays: 2,
      tripIdeas: [entry],
      ideas: [Idea(id: ideaID, name: "First")],
      tripStays: [TripStay(id: UUID(), tripID: tripID, ideaID: nil, inlineTitle: "Stay", inlineNote: "Original")],
      dayRegions: [TripDayRegion(id: UUID(), tripID: tripID, dayNumber: 1, regionID: UUID())],
      regions: [MapRegion(id: UUID(), name: "Region", centerLatitude: 1, centerLongitude: 2, latitudeDelta: 3, longitudeDelta: 4)],
      calendarConstraints: [constraint],
      alternativeGroups: [TripAlternativeGroup(id: groupID, tripID: tripID, label: "Options")])
  }

  @Test func sameAndEqualInputsBuildOnlyOnce() {
    let inputs = baseInputs()
    var snapshot = TripPlanSnapshot()
    let first = snapshot.plan(for: inputs)
    #expect(snapshot.plan(for: inputs) == first)
    #expect(snapshot.buildCount == 1)

    var republished = inputs
    republished.tripIdeas = inputs.tripIdeas.map { $0 }
    republished.ideas = inputs.ideas.map { $0 }
    #expect(snapshot.plan(for: republished) == first)
    #expect(snapshot.buildCount == 1)
  }

  @Test func everyInputInvalidatesTheSnapshot() {
    let mutations: [(String, (inout TripPlanInputs) -> Void)] = [
      ("tripID", { $0.tripID = UUID() }),
      ("lengthInDays", { $0.lengthInDays += 1 }),
      ("tripIdeas", { $0.tripIdeas[0].inlineNote = "Changed" }),
      ("ideas", { $0.ideas[0].name = "Changed" }),
      ("tripStays", { $0.tripStays[0].inlineNote = "Changed" }),
      ("dayRegions", { $0.dayRegions[0].regionID = UUID() }),
      ("regions", { $0.regions[0].name = "Changed" }),
      ("calendarConstraints", { $0.calendarConstraints[0].title = "Changed" }),
      ("alternativeGroups", { $0.alternativeGroups[0].label = "Changed" }),
    ]
    for (name, mutate) in mutations {
      var inputs = baseInputs()
      var snapshot = TripPlanSnapshot()
      _ = snapshot.plan(for: inputs)
      mutate(&inputs)
      _ = snapshot.plan(for: inputs)
      #expect(snapshot.buildCount == 2, "Expected \(name) to invalidate")
    }
  }

  @Test func inputInitializerMatchesTheFormerGetterSemantics() {
    var inputs = baseInputs()
    let tripEntry = inputs.tripIdeas[0]
    let otherTripEntry = TripIdea.freeform(
      id: UUID(), tripID: UUID(), title: "Other trip", shortlistRank: 0)
    inputs.tripIdeas.append(otherTripEntry)
    let firstIdea = inputs.ideas[0]
    var duplicateIdea = firstIdea
    duplicateIdea.name = "Duplicate"
    inputs.ideas.append(duplicateIdea)
    let oldGetterPlan = TripPlan(
      entries: inputs.tripIdeas.filter { $0.tripID == inputs.tripID },
      ideasByID: Dictionary(inputs.ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: inputs.lengthInDays,
      tripStays: inputs.tripStays.filter { $0.tripID == inputs.tripID },
      dayRegions: inputs.dayRegions.filter { $0.tripID == inputs.tripID },
      regionsByID: Dictionary(inputs.regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      calendarConstraints: inputs.calendarConstraints.filter { $0.tripID == inputs.tripID },
      alternativeGroups: inputs.alternativeGroups.filter { $0.tripID == inputs.tripID })

    #expect(TripPlan(inputs) == oldGetterPlan)
    #expect(TripPlan(inputs).entries.map(\.id) == [tripEntry.id])
    #expect(TripPlan(inputs).ideasByID[firstIdea.id]?.name == firstIdea.name)
  }

  @Test func arrayEqualitySkipsElementComparisonsForSharedStorage() {
    let counter = ComparisonCounter()
    let first = ComparisonProbe(value: 1, counter: counter)
    let array = [first]
    let shared = array
    counter.count = 0
    #expect(array == shared)
    #expect(counter.count == 0)
  }
}

private final class ComparisonCounter: @unchecked Sendable {
  nonisolated(unsafe) var count = 0
}

private struct ComparisonProbe: Equatable, Sendable {
  var value: Int
  let counter: ComparisonCounter

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.counter.count += 1
    return lhs.value == rhs.value
  }
}
