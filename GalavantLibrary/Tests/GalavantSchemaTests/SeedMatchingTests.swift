import Foundation
import GalavantSchema
import Testing

@Suite struct SeedMatchingTests {
  @Test func keysStripBusinessSuffixesAndUseOnlyFirstHintSegment() {
    #expect(SeedMatchKeys.make(name: "DYVIG BADEHOTEL ApS", searchHint: "Dyvig Badehotel, Nordborg, Denmark") ==
      SeedMatchKeys(compact: ["dyvigbadehotel"], words: ["dyvig badehotel"]))
    #expect(SeedMatchKeys.make(name: "Ruth's Hotel", searchHint: nil) ==
      SeedMatchKeys(compact: ["ruthshotel"], words: ["ruth's hotel"]))
    #expect(SeedMatchKeys.make(name: "Cafe", searchHint: "Café") ==
      SeedMatchKeys(compact: ["cafe"], words: ["cafe"]))
  }

  @Test func poolMatchHonorsLocalityAndReportsAmbiguity() {
    let first = Idea(id: UUID(), name: "Dyvig Badehotel", address: "Dyvig, Nordborg, Denmark")
    let second = Idea(id: UUID(), name: "Dyvig Badehotel", address: "Dyvig, Copenhagen, Denmark")
    let keys = SeedMatchKeys.make(name: "Dyvig Badehotel ApS", searchHint: nil)

    #expect(SeedPoolMatch.match(keys: keys, locality: "Nordborg", ideas: [first, second]) == .idea(first))
    #expect(SeedPoolMatch.match(keys: keys, locality: "Aarhus", ideas: [first, second]) == .none)
    let expected = [first, second].sorted { $0.id.uuidString < $1.id.uuidString }
    #expect(SeedPoolMatch.match(keys: keys, locality: nil, ideas: [second, first]) == .ambiguous(expected))
  }

  @Test func poolMatchCanUseMapIdentity() {
    let idea = Idea(id: UUID(), name: "Restaurant ND122", mapItemIdentifier: "map.nd122")
    #expect(SeedPoolMatch.match(mapItemIdentifier: "map.nd122", ideas: [idea]) == idea)
    #expect(SeedPoolMatch.match(mapItemIdentifier: "other", ideas: [idea]) == nil)
  }
}
