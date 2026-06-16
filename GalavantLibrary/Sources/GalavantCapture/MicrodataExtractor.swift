import Foundation
import SwiftSoup

/// HTML microdata (`itemscope`/`itemtype`/`itemprop`) — the **second** schema.org
/// source, feeding the same vote as JSON-LD. A flat global `[itemprop]` sweep
/// (rather than strict tree-walking) is deliberately forgiving: nested
/// `PostalAddress`/`GeoCoordinates` sub-properties (`streetAddress`, `latitude`…)
/// are themselves `itemprop`s, so they're caught directly. Per-site precision is
/// added only if a real capture needs it (scraping-enrichment.md).
enum MicrodataExtractor {
  static func extract(from document: Document, into builder: inout ParseBuilder) {
    for scope in (try? document.select("[itemtype]").array()) ?? [] {
      if let itemtype = try? scope.attr("itemtype") {
        builder.addSchemaType(itemtype)
      }
    }

    for element in (try? document.select("[itemprop]").array()) ?? [] {
      guard let property = try? element.attr("itemprop"), !property.isEmpty else { continue }
      let value = propertyValue(of: element)
      guard let value, !value.isEmpty else { continue }

      if let attribute = SchemaOrg.scalarProperties[property]
        ?? SchemaOrg.addressProperties[property]
        ?? SchemaOrg.geoProperties[property]
      {
        builder.votes.add(attribute, value)
      } else if property == "image" {
        builder.addImage(value)
      } else if property == "sameAs" {
        builder.addSocial(value)
      } else if property == "openingHours" {
        builder.addOpeningHours(value)
      }
    }
  }

  /// The value an `itemprop` carries depends on its element: `<meta>` → content,
  /// links/media → the resolved URL, `<time>` → datetime, otherwise the text.
  private static func propertyValue(of element: Element) -> String? {
    let tag = element.tagName().lowercased()
    switch tag {
    case "meta":
      return try? element.attr("content")
    case "a", "link", "area":
      return try? element.absUrl("href")
    case "img", "audio", "video", "source", "iframe", "embed":
      return try? element.absUrl("src")
    case "object":
      return try? element.absUrl("data")
    case "time":
      let datetime = (try? element.attr("datetime")) ?? ""
      return datetime.isEmpty ? try? element.text() : datetime
    default:
      let content = (try? element.attr("content")) ?? ""
      return content.isEmpty ? try? element.text() : content
    }
  }
}
