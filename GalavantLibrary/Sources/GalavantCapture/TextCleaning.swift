import Foundation

/// Light, deterministic de-marketing for description text — the **fallback** when
/// the on-device language model isn't available (simulator, unsupported device, or
/// Apple Intelligence off) and notes would otherwise be the raw `og:description`,
/// which is usually marketing copy ("Searching for a … hotel? … Find out more").
///
/// Deliberately conservative: it only drops whole sentences that are clearly
/// promotional (a hook question, or a call to action) and trims trailing CTA
/// fragments. It is **not** a rewrite — when the model is available, its neutral
/// summary supersedes this entirely (M4d). Pure string work; fully tested.
public enum TextCleaning {
  /// Phrases that mark a sentence as a call to action / marketing aside.
  private static let ctaPhrases = [
    "find out more", "book now", "book your", "discover", "learn more", "read more",
    "click here", "sign up", "subscribe", "contact us", "get in touch",
    "explore more", "see more", "request a", "enquire", "inquire",
    "reserve your", "plan your", "don't miss", "dont miss",
  ]

  /// Return `text` with promotional sentences removed, or `nil` when nothing
  /// meaningful survives (the caller then leaves notes empty rather than marketing).
  public static func demarketed(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let kept = sentences(in: trimmed).filter { sentence in
      let lower = sentence.lowercased()
      if ctaPhrases.contains(where: lower.contains) { return false }
      // A leading "Searching for …?" / "Looking for …?" style hook.
      if sentence.hasSuffix("?"), isMarketingQuestion(lower) { return false }
      return true
    }

    let result = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }

  /// Split into sentences, keeping their terminal punctuation. Naive (good enough
  /// for short descriptions): breaks on `.`/`!`/`?` followed by whitespace.
  private static func sentences(in text: String) -> [String] {
    var result: [String] = []
    var current = ""
    var iterator = text.makeIterator()
    var pending: Character? = iterator.next()
    while let char = pending {
      current.append(char)
      let next = iterator.next()
      if (char == "." || char == "!" || char == "?"),
        next == nil || next == " " || next == "\n"
      {
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        current = ""
      }
      pending = next
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { result.append(tail) }
    return result.filter { !$0.isEmpty }
  }

  /// A question that opens with a marketing hook ("Searching for …", "Looking for
  /// …", "Want to …", "Ready to …", "Why not …").
  private static func isMarketingQuestion(_ lower: String) -> Bool {
    let hooks = ["searching for", "looking for", "want to", "ready to", "why not", "in need of"]
    return hooks.contains { lower.hasPrefix($0) }
  }
}
