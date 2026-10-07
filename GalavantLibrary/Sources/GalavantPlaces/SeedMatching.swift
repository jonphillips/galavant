import Foundation

public enum SeedMatching {
  /// Returns the sole Maps result whose name covers every significant word in a
  /// seed match key. This only preselects a result; the review still needs a tap.
  public static func obviousChoice(keys: [String], results: [Place]) -> Place? {
    let significantKeys = keys.map(significantWords).filter { !$0.isEmpty }
    let covering = results.filter { result in
      let words = significantWords(result.name)
      let resultWords = Set(words)
      let compactName = words.joined()
        .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
      return significantKeys.contains { key in
        key.allSatisfy(resultWords.contains) || key.joined().count > 3 && compactName.contains(key.joined())
      }
    }
    return covering.count == 1 ? covering[0] : nil
  }

  private static func significantWords(_ value: String) -> [String] {
    let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    return PlaceMatching.words(in: folded).filter(PlaceMatching.isSignificant)
  }
}
