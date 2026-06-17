import Foundation
import SwiftSoup

/// The `<meta>` and `<title>` passes: OpenGraph (`property=`) and plain metatags /
/// Twitter cards (`name=`). OpenGraph carries underused gold beyond title/image —
/// `place:location:*` coordinates and the `business:contact_data:*` block (street,
/// locality, region, postal code, country, phone, email, website).
enum MetaExtractor {
  /// OpenGraph `property` → how to feed the builder.
  private static let scalarOG: [String: PageAttribute] = [
    "og:title": .title,
    "og:url": .websiteURL,
    "og:description": .summary,
    "place:location:latitude": .latitude,
    "place:location:longitude": .longitude,
    "business:contact_data:street_address": .street,
    "business:contact_data:locality": .locality,
    "business:contact_data:region": .region,
    "business:contact_data:postal_code": .postalCode,
    "business:contact_data:country_name": .country,
    "business:contact_data:phone_number": .phone,
    "business:contact_data:email": .email,
    "business:contact_data:website": .websiteURL,
  ]

  private static let imageOG: Set<String> = [
    "og:image", "og:image:url", "og:image:secure_url",
  ]

  /// Plain `name` metatags / Twitter cards.
  private static let scalarMeta: [String: PageAttribute] = [
    "description": .summary,
    "twitter:title": .title,
    "twitter:description": .summary,
  ]

  private static let imageMeta: Set<String> = [
    "twitter:image", "twitter:image:src",
  ]

  static func extract(from document: Document, into builder: inout ParseBuilder) {
    for meta in (try? document.select("meta").array()) ?? [] {
      let content = (try? meta.attr("content")) ?? ""
      if content.isEmpty { continue }

      if let property = try? meta.attr("property"), !property.isEmpty {
        let key = property.lowercased()
        if let attribute = scalarOG[key] {
          builder.votes.add(attribute, content)
        } else if imageOG.contains(key) {
          builder.addImage(content)
        }
      }

      if let name = try? meta.attr("name"), !name.isEmpty {
        let key = name.lowercased()
        if let attribute = scalarMeta[key] {
          builder.votes.add(attribute, content)
        } else if imageMeta.contains(key) {
          builder.addImage(content)
        }
      }
    }

    // `<title>` is the weakest title candidate (chrome priority, like og:/twitter:),
    // so a structured schema.org `name` outranks it even though the page title is
    // echoed across og:title/twitter:title/<title>.
    if let title = try? document.title(), !title.isEmpty {
      builder.votes.add(.title, title)
    }
  }
}
