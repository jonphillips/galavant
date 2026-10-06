import Foundation
import GalavantSchema
import Testing

struct SeedReturnTests {
  @Test func decodesTheDenmarkFixtureWithoutDroppingItsNarrativeOrDecisions() throws {
    let fixture = try #require(Bundle.module.url(forResource: "seed-denmark", withExtension: "txt"))
    let text = try String(contentsOf: fixture, encoding: .utf8)
    let seed = try SeedReturn.decode(text)

    #expect(seed.narrative.contains("Why 3 + 3 instead of 2 + 2 + 2"))
    #expect(seed.trip.lengthDays == 13)
    #expect(seed.trip.year == 2027)
    #expect(seed.bases.map(\.checkInDay) == [1, 4, 7])
    #expect(seed.bases.map(\.checkOutDay) == [4, 7, 13])
    #expect(seed.places.count == 37)
    #expect(seed.places.filter { $0.verdict == .core }.count == 4)
    #expect(seed.places.filter { $0.verdict == .deferred }.count == 16)
    #expect(seed.places.first(where: { $0.candidate.name == "Spodsbjerg–Tårs ferry" })?.candidate.bookAhead == true)
    #expect(seed.warnings.isEmpty)
  }

  @Test func reportsInvalidBasesAndAcceptsNumberDayReferenceAndUnknownVerdict() throws {
    let seed = try SeedReturn.decode("""
      Notes
      GV-SEED
      {"bases":[{"name":"Bad","check_in_day":0,"check_out_day":1}],"places":[{"name":"Train","day_ref":4,"verdict":"maybe"}]}
      """)
    #expect(seed.bases.isEmpty)
    #expect(seed.warnings.count == 1)
    #expect(seed.places.first?.candidate.dayRef == "4")
    #expect(seed.places.first?.verdict == .unrecognized("maybe"))
  }

  @Test func fallsBackToSummaryAndFailsLoudlyForIncompleteSeeds() throws {
    let seed = try SeedReturn.decode("GV-SEED\n{\"summary\":\"A useful summary\",\"places\":[{}]}")
    #expect(seed.narrative == "A useful summary")
    #expect(throws: SeedReturnDecodeError.missingSeedMarker) { try SeedReturn.decode("{}") }
    #expect(throws: SeedReturnDecodeError.missingJSONObject) { try SeedReturn.decode("GV-SEED\nNo JSON") }
    #expect(throws: SeedReturnDecodeError.malformedJSON) { try SeedReturn.decode("GV-SEED\n{bad}") }
    #expect(throws: SeedReturnDecodeError.emptySeed) { try SeedReturn.decode("GV-SEED\n{}") }
    let tripSummary = try SeedReturn.decode("GV-SEED\n{\"trip\":{\"summary\":\"Trip fallback\"},\"places\":[{}]}")
    #expect(tripSummary.narrative == "Trip fallback")
  }

  @Test func keepsCRLFPastesAndWarnsForNonObjectArrayElements() throws {
    let seed = try SeedReturn.decode(
      "Notes\r\nGV-SEED\r\n{\"bases\":[{\"name\":\"Base\",\"check_in_day\":1,\"check_out_day\":2},7],\"places\":[{\"name\":\"Place\"},false]}"
    )
    #expect(seed.narrative == "Notes")
    #expect(seed.bases.count == 1)
    #expect(seed.places.count == 1)
    #expect(seed.warnings == ["Base 2 was omitted: not an object.", "Place 2 was omitted: not an object."])
  }

  @Test func rejectsPresentBaseOrPlaceKeysThatAreNotArrays() {
    #expect(throws: SeedReturnDecodeError.malformedJSON) {
      try SeedReturn.decode("GV-SEED\n{\"bases\":{},\"places\":[{}]}")
    }
    #expect(throws: SeedReturnDecodeError.malformedJSON) {
      try SeedReturn.decode("GV-SEED\n{\"bases\":[{}],\"places\":null}")
    }
  }

  @Test func normalizesSeedKindSynonymsAndUnrecognizedKindsStayNil() {
    #expect(IdeaKind(seedKind: "hotel") == .stay)
    #expect(IdeaKind(seedKind: "restaurant") == .food)
    #expect(IdeaKind(seedKind: "walk") == .outdoorTrail)
    #expect(IdeaKind(seedKind: "Ferry") == .transit)
    #expect(IdeaKind(seedKind: "something else") == nil)
  }
}
