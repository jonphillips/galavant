import Foundation
import GalavantSchema
import Testing

@Suite struct MichelinDistinctionTests {
  let partyID = UUID()
  let ideaID = UUID()

  func evaluation(
    _ distinction: MichelinDistinction,
    sourceName: String = MichelinDistinction.sourceName
  ) -> IdeaEvaluation? {
    guard let fields = distinction.evaluationFields else { return nil }
    return IdeaEvaluation(
      id: UUID(), travelPartyID: partyID, ideaID: ideaID, sourceName: sourceName,
      kind: fields.kind, nativeValueText: fields.text, nativeValueNumber: fields.number,
      nativeValueMax: fields.maximum, nativeDisplay: fields.display, recordedAt: .now,
      confidence: .manual, staleness: .current)
  }

  @Test func distinctionsRoundTripThroughNativeEvaluationFields() throws {
    for distinction in [
      MichelinDistinction.guide, .bibGourmand, .stars(1), .stars(2), .stars(3), .keys(1), .keys(2), .keys(3),
    ] {
      let stored = try #require(evaluation(distinction))
      #expect(MichelinDistinction(evaluation: stored) == distinction)
    }
    let guide = try #require(evaluation(.guide))
    #expect(guide.kind == .recommendation)
    #expect(guide.nativeValueText == "Recommended")
    #expect(guide.nativeDisplay == "Recommended")
    let bib = try #require(evaluation(.bibGourmand))
    #expect(bib.kind == .badge)
    #expect(bib.nativeValueText == "Bib Gourmand")
    #expect(bib.nativeDisplay == "Bib Gourmand")
    #expect(MichelinDistinction.sourceName == "Michelin Guide")
  }

  @Test func optionsDependOnWhetherTheIdeaIsAStay() {
    #expect(MichelinDistinction.choices(isStay: true) == [.none, .guide, .keys(1), .keys(2), .keys(3)])
    #expect(MichelinDistinction.choices(isStay: false) == [.none, .guide, .bibGourmand, .stars(1), .stars(2), .stars(3)])
    #expect(MichelinDistinction.choices(isStay: true).contains(.bibGourmand) == false)
    #expect(evaluation(.none) == nil)
  }

  @Test func readsTheOldManualSourceName() throws {
    let old = try #require(evaluation(.stars(2), sourceName: "Michelin"))
    #expect(MichelinDistinction(evaluation: old) == .stars(2))
    #expect(old.canonicalSourceName == MichelinDistinction.sourceName)
  }
}
