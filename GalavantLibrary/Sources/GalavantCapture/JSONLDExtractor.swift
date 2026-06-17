import Foundation
import SwiftSoup

/// JSON-LD (`<script type="application/ld+json">`) — run **first**, because it's
/// how most sites ship schema.org data today and it's the cleanest to parse
/// (JSONSerialization against the schema.org property map). V1's pipeline already
/// prioritized JSON-LD; V3 follows that precedent (scraping-enrichment.md).
enum JSONLDExtractor {
  static func extract(from document: Document, into builder: inout ParseBuilder) {
    let scripts = (try? document.select("script[type=application/ld+json]").array()) ?? []
    for script in scripts {
      // `.data()` returns the script's raw text node verbatim (no entity encoding),
      // which is what we need to feed JSONSerialization.
      guard let data = cleanedJSON(script.data()) else { continue }
      guard let top = try? JSONSerialization.jsonObject(with: data) else { continue }
      for node in placeNodes(in: top) {
        mine(node, into: &builder)
      }
    }
  }

  // MARK: Node discovery

  /// Recursively find every dictionary whose `@type` is a place-ish schema.org
  /// type, descending through arrays and `@graph`. Nested `address`/`geo` objects
  /// (PostalAddress/GeoCoordinates — not place types) are mined inline by their
  /// parent, not returned here, so they're never double-counted.
  private static func placeNodes(in value: Any) -> [[String: Any]] {
    switch value {
    case let dict as [String: Any]:
      var found: [[String: Any]] = []
      if isPlaceNode(dict) { found.append(dict) }
      // Keep walking for sibling/nested place nodes (e.g. @graph members).
      for (_, child) in dict {
        found.append(contentsOf: placeNodes(in: child))
      }
      return found
    case let array as [Any]:
      return array.flatMap(placeNodes(in:))
    default:
      return []
    }
  }

  private static func isPlaceNode(_ dict: [String: Any]) -> Bool {
    let types = typeStrings(dict["@type"])
    return types.contains { SchemaOrg.placeTypes.contains($0) }
  }

  // MARK: Mining one node

  private static func mine(_ node: [String: Any], into builder: inout ParseBuilder) {
    for type in typeStrings(node["@type"]) {
      builder.addSchemaType(type)
    }
    for (property, attribute) in SchemaOrg.scalarProperties {
      if let value = node[property] {
        builder.votes.add(attribute, firstString(value))
      }
    }
    for image in imageStrings(node["image"]) {
      builder.addImage(image)
    }
    for social in flatStrings(node["sameAs"]) {
      builder.addSocial(social)
    }
    mineAddress(node["address"], into: &builder)
    mineGeo(node["geo"], into: &builder)
    mineOpeningHours(node, into: &builder)
  }

  private static func mineAddress(_ value: Any?, into builder: inout ParseBuilder) {
    guard let dict = value as? [String: Any] else { return }
    for (property, attribute) in SchemaOrg.addressProperties {
      if let raw = dict[property] {
        builder.votes.add(attribute, firstString(raw))
      }
    }
  }

  private static func mineGeo(_ value: Any?, into builder: inout ParseBuilder) {
    guard let dict = value as? [String: Any] else { return }
    for (property, attribute) in SchemaOrg.geoProperties {
      if let raw = dict[property] {
        builder.votes.add(attribute, firstString(raw))
      }
    }
  }

  private static func mineOpeningHours(_ node: [String: Any], into builder: inout ParseBuilder) {
    // Plain `openingHours`: already human-ish strings ("Mo-Fr 09:00-17:00").
    for hours in flatStrings(node["openingHours"]) {
      builder.addOpeningHours(hours)
    }
    // Structured `openingHoursSpecification`: array (or one) of dicts.
    let specs: [Any]
    switch node["openingHoursSpecification"] {
    case let array as [Any]: specs = array
    case let single?: specs = [single]
    case nil: specs = []
    }
    for case let spec as [String: Any] in specs {
      let days = flatStrings(spec["dayOfWeek"])
        .map { $0.split(whereSeparator: { $0 == "/" || $0 == "#" }).last.map(String.init) ?? $0 }
      let opens = firstString(spec["opens"])
      let closes = firstString(spec["closes"])
      let dayPart = days.joined(separator: ",")
      let timePart = [opens, closes].compactMap { $0 }.joined(separator: "-")
      let line = [dayPart, timePart].filter { !$0.isEmpty }.joined(separator: " ")
      builder.addOpeningHours(line)
    }
  }

  // MARK: JSON value coercion

  /// `@type` may be a string or an array of strings.
  private static func typeStrings(_ value: Any?) -> [String] {
    flatStrings(value).map { $0.split(whereSeparator: { $0 == "/" || $0 == "#" }).last.map(String.init) ?? $0 }
  }

  /// Flatten a JSON value to its string leaves: String, number, or array thereof.
  /// Dictionaries resolve to their `url` / `@id` / `name` if present.
  private static func flatStrings(_ value: Any?) -> [String] {
    switch value {
    case let string as String:
      return [string]
    case let number as NSNumber:
      return [number.stringValue]
    case let array as [Any]:
      return array.flatMap { flatStrings($0) }
    case let dict as [String: Any]:
      if let resolved = firstString(dict["url"] ?? dict["@id"] ?? dict["name"]) {
        return [resolved]
      }
      return []
    default:
      return []
    }
  }

  /// The first/only string for a scalar property.
  private static func firstString(_ value: Any?) -> String? {
    flatStrings(value).first
  }

  /// Image values: strings, `ImageObject` dicts (`url`/`contentUrl`), or arrays.
  private static func imageStrings(_ value: Any?) -> [String] {
    switch value {
    case let string as String:
      return [string]
    case let array as [Any]:
      return array.flatMap { imageStrings($0) }
    case let dict as [String: Any]:
      return flatStrings(dict["url"] ?? dict["contentUrl"] ?? dict["@id"])
    default:
      return []
    }
  }

  /// V1 stripped curly quotes and escaped stray quotes before JSON parsing —
  /// some CMSs emit invalid JSON-LD. Mirror that light cleanup.
  private static func cleanedJSON(_ raw: String) -> Data? {
    let cleaned =
      raw
      .replacingOccurrences(of: "[\u{201C}\u{201D}\u{2019}]", with: "", options: .regularExpression)
    return cleaned.data(using: .utf8)
  }
}
