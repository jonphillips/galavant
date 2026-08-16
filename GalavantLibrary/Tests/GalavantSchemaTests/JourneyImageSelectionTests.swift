import Foundation
import GalavantSchema
import Testing

struct JourneyImageSelectionTests {
  @Test("stay stop selection is limited to imaged stops in the stay's nights")
  func selectsStableCandidateFromLeg() {
    let stayID = UUID()
    let days = [
      JourneyProjection.DaySummary(
        dayNumber: 1,
        date: .now,
        locality: nil,
        stops: [
          .init(id: UUID(), ideaID: UUID(), title: "Outside leg", kind: .park),
        ],
        definingStop: nil,
        weatherAnchors: []),
      JourneyProjection.DaySummary(
        dayNumber: 2,
        date: .now,
        locality: nil,
        stops: [
          .init(id: UUID(), ideaID: nil, title: "No image", kind: .food),
          .init(id: UUID(), ideaID: UUID(), title: "In leg", kind: .activity),
        ],
        definingStop: nil,
        weatherAnchors: []),
      JourneyProjection.DaySummary(
        dayNumber: 3,
        date: .now,
        locality: nil,
        stops: [
          .init(id: UUID(), ideaID: UUID(), title: "Also in leg", kind: .beach),
        ],
        definingStop: nil,
        weatherAnchors: [])
    ]

    let first = JourneyImageSelection.stableStayStop(
      stayID: stayID,
      nights: 2..<4,
      days: days,
      hasImage: { $0 != nil })
    let second = JourneyImageSelection.stableStayStop(
      stayID: stayID,
      nights: 2..<4,
      days: days,
      hasImage: { $0 != nil })

    #expect(first != nil)
    #expect(first == second)
    #expect(first?.title == "In leg" || first?.title == "Also in leg")
  }

  @Test("stay stop selection returns nil when the leg has no images")
  func noImageCandidate() {
    let stop = JourneyProjection.StopDigest(
      id: UUID(), ideaID: nil, title: "No image", kind: .food)
    let day = JourneyProjection.DaySummary(
      dayNumber: 2,
      date: .now,
      locality: nil,
      stops: [stop],
      definingStop: nil,
      weatherAnchors: [])

    #expect(
      JourneyImageSelection.stableStayStop(
        stayID: UUID(), nights: 2..<3, days: [day], hasImage: { _ in false }) == nil)
  }
}
