import Foundation
import GalavantSchema
import Testing

@testable import GalavantChat

@Suite struct ChatContextTests {
  @Test("idea context serializes faithfully — evaluations native, interest his/hers")
  func ideaContext() {
    let idea = Idea(
      id: UUID(), name: "Noma", kind: .food, regionName: "Copenhagen",
      visited: false, openingHours: "Tue–Sat 17:00–00:00")
    let evaluation = IdeaEvaluation(
      id: UUID(), travelPartyID: UUID(), ideaID: idea.id,
      sourceName: "Michelin", kind: .stars, nativeValueText: "3",
      nativeDisplay: "★★★", recordedAt: Date(), confidence: .official, staleness: .current)
    let context = ChatContext.idea(
      ResolvedIdeaContext(
        idea: idea,
        evaluations: [evaluation],
        interests: [
          PlannerInterest(plannerName: "Jon", level: .mustDo),
          PlannerInterest(plannerName: "Sam", level: .couldDo),
        ],
        tags: ["tasting menu"]))

    let text = context.serialized()
    #expect(text.contains("Noma"))
    #expect(text.contains("Food"))
    #expect(text.contains("Michelin: ★★★"))  // native, not normalized
    #expect(text.contains("Jon: Must Do"))
    #expect(text.contains("Sam: Could Do"))
    #expect(text.contains("tasting menu"))
    #expect(context.title == "Noma")
  }

  @Test("pool context lists visible ideas and names the lens")
  func poolContext() {
    let ideas = [
      Idea(id: UUID(), name: "Geranium", kind: .food, regionName: "Copenhagen", visited: true),
      Idea(id: UUID(), name: "Tivoli", kind: .activity, regionName: "Copenhagen"),
    ]
    let context = ChatContext.pool(PoolContext(lens: "Denmark · Food", ideas: ideas))
    let text = context.serialized()
    #expect(text.contains("Denmark · Food"))
    #expect(text.contains("Geranium"))
    #expect(text.contains("visited"))
    #expect(text.contains("Tivoli"))
    #expect(context.title == "Denmark · Food")
  }

  @Test("trip context lays out the scheduled itinerary by day")
  func tripContext() {
    let hotel = Idea(id: UUID(), name: "Hotel Sanders")
    let dinner = Idea(id: UUID(), name: "Noma", latitude: 1, longitude: 1)
    let entry = TripIdea(
      id: UUID(), tripID: UUID(), ideaID: dinner.id, status: .scheduled, dayNumber: 2)
    let plan = TripPlan(
      entries: [entry],
      ideasByID: [dinner.id: dinner, hotel.id: hotel],
      lengthInDays: 3)
    let text = ChatContext.trip(plan).serialized()
    #expect(text.contains("3 days"))
    #expect(text.contains("Day 2"))
    #expect(text.contains("Noma"))
  }
}
