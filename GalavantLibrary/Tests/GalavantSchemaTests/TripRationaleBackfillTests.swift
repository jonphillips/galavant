import Foundation
import GalavantSchema
import Testing

@Suite struct TripRationaleBackfillTests {
  @Test func exactLegacyRationaleProducesSplitFieldsAndClearsThePackedNote() {
    let candidate = TripCandidate(why: "A quiet garden", fit: "Near the hotel", visit: "Tuesday morning")
    let stop = TripIdea(
      id: UUID(), tripID: UUID(), ideaID: nil,
      inlineNote: "A quiet garden\n\nNear the hotel"
    )

    let update = TripRationaleBackfill.update(for: stop, from: candidate)

    #expect(update == TripRationale(
      visit: "Tuesday morning", why: "A quiet garden", fit: "Near the hotel", note: nil
    ))
  }

  @Test func editedLegacyNoteIsLeftAlone() {
    let stop = TripIdea(id: UUID(), tripID: UUID(), ideaID: nil, inlineNote: "A note Jon edited")
    let candidate = TripCandidate(why: "Original reason", fit: "Original fit")

    #expect(TripRationaleBackfill.update(for: stop, from: candidate) == nil)
  }

  @Test func anyAlreadyFilledRationaleFieldLeavesTheStopAlone() {
    let stop = TripIdea(id: UUID(), tripID: UUID(), ideaID: nil, rationaleWhy: "Preserve this")
    let candidate = TripCandidate(why: "Original reason", fit: "Original fit")

    #expect(TripRationaleBackfill.update(for: stop, from: candidate) == nil)
  }

  @Test func aSecondRunDoesNotProduceAnotherUpdate() throws {
    let candidate = TripCandidate(why: "A quiet garden", fit: "Near the hotel", visit: "Tuesday morning")
    let stop = TripIdea(
      id: UUID(), tripID: UUID(), ideaID: nil,
      inlineNote: "A quiet garden\n\nNear the hotel"
    )
    let update = try #require(TripRationaleBackfill.update(for: stop, from: candidate))
    let afterFirstRun = TripIdea(
      id: stop.id, tripID: stop.tripID, ideaID: stop.ideaID,
      inlineNote: update.note,
      rationaleVisit: update.visit, rationaleWhy: update.why, rationaleFit: update.fit,
    )

    #expect(TripRationaleBackfill.update(for: afterFirstRun, from: candidate) == nil)
  }
}
