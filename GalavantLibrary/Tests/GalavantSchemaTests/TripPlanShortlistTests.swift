import Foundation
import GalavantSchema
import Testing

@Suite struct TripPlanShortlistTests {
  private let tripID = UUID()

  private func entry(_ ideaID: Idea.ID, rank: Int = 0) -> TripIdea {
    TripIdea(
      id: UUID(), tripID: tripID, ideaID: ideaID, status: .shortlisted, shortlistRank: rank)
  }

  private func plan(entries: [TripIdea], ideas: [Idea], stays: [TripStay]) -> TripPlan {
    TripPlan(
      entries: entries,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: 3,
      tripStays: stays
    )
  }

  @Test func shortlistExcludesStayIdeaOnceItHasBecomeATripStay() {
    let hotelID = UUID()
    let otherHotelID = UUID()
    let restaurantID = UUID()
    let entries = [
      entry(hotelID),
      entry(otherHotelID, rank: 1),
      entry(restaurantID, rank: 2),
    ]
    let stays = [
      TripStay(id: UUID(), tripID: tripID, ideaID: hotelID),
      // A loose link must not hide a non-stay idea.
      TripStay(id: UUID(), tripID: tripID, ideaID: restaurantID),
    ]
    let p = plan(
      entries: entries,
      ideas: [
        Idea(id: hotelID, name: "Booked Hotel", kind: .stay),
        Idea(id: otherHotelID, name: "Other Hotel", kind: .stay),
        Idea(id: restaurantID, name: "Restaurant", kind: .food),
      ],
      stays: stays
    )

    #expect(p.shortlist.map { $0.idea!.id } == [otherHotelID, restaurantID])
  }
}
