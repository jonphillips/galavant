import Foundation
import GalavantCapture
import Testing

@testable import GalavantPlaces

@Suite struct PlaceMatcherTests {
  private func place(
    _ name: String, _ lat: Double, _ lon: Double, address: String? = nil,
    mapItemIdentifier: String? = nil
  ) -> Place {
    Place(
      id: UUID(), name: name, latitude: lat, longitude: lon, address: address,
      mapItemIdentifier: mapItemIdentifier
    )
  }

  @Test("Calendar events use the same PlaceMatcher ladder as capture")
  func calendarEventUsesPlaceMatcher() async {
    let matcher = PlaceMatcher(
      geocode: { _ in Issue.record("a structured coordinate wins"); return nil },
      search: { _ in Issue.record("a structured coordinate wins"); return [] },
      lookupNear: { _, _ in
        [self.place("The French Laundry", 38.4043, -122.3630)]
      }
    )

    let match = await matcher.match(
      calendarEventTitle: "French Laundry",
      latitude: 38.4043,
      longitude: -122.3630,
      location: "Yountville"
    )

    #expect(match?.coordinate == ParsedCoordinate(latitude: 38.4043, longitude: -122.3630))
  }

  @Test("Calendar event resolves its venue from the location, not a non-venue title")
  func calendarEventResolvesVenueFromLocation() async {
    let matcher = PlaceMatcher(
      geocode: { _ in Issue.record("a structured coordinate wins"); return nil },
      search: { _ in Issue.record("a structured coordinate wins"); return [] },
      lookupNear: { _, _ in
        [self.place("The French Laundry", 38.4043, -122.3630, mapItemIdentifier: "maps-tfl")]
      }
    )

    // The event's subject line ("Dinner reservation") is not the venue; the venue
    // lives in `location`. Resolution must adopt that POI's identity and name, or a
    // real reservation never links to its itinerary stop.
    let match = await matcher.match(
      calendarEventTitle: "Dinner reservation",
      latitude: 38.4043,
      longitude: -122.3630,
      location: "The French Laundry, 6640 Washington St, Yountville"
    )

    #expect(match?.name == "The French Laundry")
    #expect(match?.mapItemIdentifier == "maps-tfl")
  }

  @Test("Scraped coordinates are authoritative — no geocode or search")
  func coordinatesWinOutright() async {
    let matcher = PlaceMatcher(
      geocode: { _ in Issue.record("geocode should not run"); return nil },
      search: { _ in Issue.record("search should not run"); return [] }
    )
    let page = ParsedPage(
      title: "Noma",
      coordinate: ParsedCoordinate(latitude: 55.6839, longitude: 12.6109),
      address: ParsedAddress(street: "Refshalevej 96", locality: "Copenhagen")
    )
    let match = await matcher.match(page)
    #expect(match == LocationMatch(coordinate: ParsedCoordinate(latitude: 55.6839, longitude: 12.6109)))
  }

  @Test("No coordinates: geocode the address before falling to search")
  func geocodeBeforeSearch() async {
    let matcher = PlaceMatcher(
      geocode: { _ in self.place("X", 10, 20) },
      search: { _ in Issue.record("search should not run once geocode succeeds"); return [] }
    )
    let page = ParsedPage(title: "X", address: ParsedAddress(street: "A St", locality: "Town"))
    let match = await matcher.match(page)
    #expect(match?.coordinate == ParsedCoordinate(latitude: 10, longitude: 20))
  }

  @Test("Geocoding keeps the map item's detail, not just its coordinate (Tier A)")
  func geocodeCarriesDetail() async {
    let matcher = PlaceMatcher(
      geocode: { _ in
        Place(
          id: UUID(), name: "Alouette", latitude: 55.685, longitude: 12.583,
          regionName: "Copenhagen", kind: .food, url: "https://restaurantalouette.dk",
          phone: "+4531676606", address: "8 Kronprinsessegade, Copenhagen"
        )
      },
      search: { _ in Issue.record("geocode succeeded; no search"); return [] }
    )
    let page = ParsedPage(
      title: "Alouette", address: ParsedAddress(street: "8 Kronprinsessegade, Copenhagen")
    )
    let match = await matcher.match(page)
    #expect(match?.kind == .food)
    #expect(match?.phone == "+4531676606")
    #expect(match?.url == "https://restaurantalouette.dk")
  }

  @Test("A coordinate-only match is supplemented by a nearby Apple Maps POI (Tier B)")
  func enrichmentSupplementsCoordinateMatch() async {
    let matcher = PlaceMatcher(
      geocode: { _ in Issue.record("no address to geocode"); return nil },
      search: { _ in Issue.record("coordinates win; no search"); return [] },
      lookupNear: { _, _ in
        [
          Place(
            id: UUID(), name: "Noma", latitude: 55.6839, longitude: 12.6109,
            regionName: "Copenhagen", kind: .food, url: "https://noma.dk",
            phone: "+45 32 96 32 97"
          )
        ]
      }
    )
    // Page gave coordinates but no POI detail — enrichment fills it in.
    let page = ParsedPage(
      title: "Noma", coordinate: ParsedCoordinate(latitude: 55.6839, longitude: 12.6109)
    )
    let match = await matcher.match(page)
    #expect(match?.coordinate == ParsedCoordinate(latitude: 55.6839, longitude: 12.6109))
    #expect(match?.kind == .food)
    #expect(match?.phone == "+45 32 96 32 97")
    #expect(match?.regionName == "Copenhagen")
  }

  @Test("Geocode-first match adopts the nearby POI's identity (Forestis regression)")
  func enrichmentAdoptsMapItemIdentifier() async {
    // A JSON-LD `Hotel` page (forestis.it, das-achental.com) resolves via its
    // scraped address: forward geocoding returns an address-level point with no
    // POI identity, so the match has no `mapItemIdentifier`. The nearby-POI pass is
    // the only place to recover it — without that, capture lands undeduplicatable.
    let matcher = PlaceMatcher(
      geocode: { _ in self.place("Forestis", 46.706, 11.667, address: "Palmschoß 22, Brixen") },
      search: { _ in Issue.record("geocode succeeded; no search"); return [] },
      lookupNear: { _, _ in
        [
          Place(
            id: UUID(), name: "Forestis Dolomites", latitude: 46.706, longitude: 11.667,
            regionName: "Brixen", kind: .stay, url: "https://forestis.it",
            phone: "+39 0472 521008", address: "Palmschoß 22, Brixen",
            mapItemIdentifier: "I1234567890ABCDEF"
          )
        ]
      }
    )
    let page = ParsedPage(
      title: "FORESTIS", address: ParsedAddress(street: "Palmschoß 22", locality: "Brixen")
    )
    let match = await matcher.match(page)
    #expect(match?.mapItemIdentifier == "I1234567890ABCDEF")
  }

  @Test("Enrichment runs to recover identity even when kind/phone/url are filled")
  func enrichmentRecoversIdentityWhenOtherwiseComplete() async {
    // The resolving step (here a rich geocode) filled kind/phone/url but carried no
    // POI identity. Enrichment must still run on the missing `mapItemIdentifier`.
    let matcher = PlaceMatcher(
      geocode: { _ in
        Place(
          id: UUID(), name: "Forestis", latitude: 46.706, longitude: 11.667,
          regionName: "Brixen", kind: .stay, url: "https://forestis.it",
          phone: "+39 0472 521008", address: "Palmschoß 22, Brixen"
        )
      },
      search: { _ in Issue.record("geocode succeeded; no search"); return [] },
      lookupNear: { _, _ in
        [self.place("Forestis", 46.706, 11.667, mapItemIdentifier: "IFEEDFACE")]
      }
    )
    let page = ParsedPage(
      title: "Forestis", address: ParsedAddress(street: "Palmschoß 22", locality: "Brixen")
    )
    let match = await matcher.match(page)
    #expect(match?.mapItemIdentifier == "IFEEDFACE")
  }

  @Test("Enrichment ignores a nearby POI whose name doesn't match")
  func enrichmentNameGated() async {
    let matcher = PlaceMatcher(
      geocode: { _ in nil },
      search: { _ in [] },
      lookupNear: { _, _ in [self.place("Starbucks", 55.68, 12.61)] }
    )
    let page = ParsedPage(
      title: "Noma", coordinate: ParsedCoordinate(latitude: 55.6839, longitude: 12.6109)
    )
    let match = await matcher.match(page)
    #expect(match?.kind == nil)  // Starbucks ≠ Noma → no hijack
  }

  @Test("Text search picks the best-scoring hit, not just the first")
  func textSearchScores() async {
    let matcher = PlaceMatcher(
      geocode: { _ in Issue.record("no address to geocode"); return nil },
      search: { _ in
        [
          self.place("Random Cafe", 1, 1),
          self.place("Noma", 55.6839, 12.6109),
        ]
      }
    )
    let page = ParsedPage(title: "Noma Restaurant")
    let match = await matcher.match(page)
    #expect(match?.name == "Noma")
    #expect(match?.coordinate == ParsedCoordinate(latitude: 55.6839, longitude: 12.6109))
  }

  @Test("A search match carries the hit's full detail, not just the coordinate")
  func matchCarriesEnrichment() async {
    let matcher = PlaceMatcher(
      geocode: { _ in nil },
      search: { _ in
        [
          Place(
            id: UUID(), name: "Alouette", latitude: 55.685, longitude: 12.583,
            regionName: "Copenhagen", kind: .food, url: "https://restaurantalouette.dk",
            phone: "+4531676606", address: "8 Kronprinsessegade, Copenhagen"
          )
        ]
      }
    )
    let match = await matcher.match(ParsedPage(title: "Alouette"))
    #expect(match?.regionName == "Copenhagen")
    #expect(match?.kind == .food)
    #expect(match?.phone == "+4531676606")
    #expect(match?.url == "https://restaurantalouette.dk")
  }

  @Test("A best hit below the confidence floor is rejected")
  func belowThresholdRejected() async {
    let matcher = PlaceMatcher(
      geocode: { _ in nil },
      search: { _ in [self.place("Pizza Hut", 1, 1)] }
    )
    let page = ParsedPage(title: "Noma")
    #expect(await matcher.match(page) == nil)
  }

  @Test("A page with no signal resolves to nil")
  func noSignal() async {
    let matcher = PlaceMatcher(geocode: { _ in nil }, search: { _ in [] })
    #expect(await matcher.match(ParsedPage()) == nil)
  }

  @Test("Name-only page rejects a junk worldwide hit (koancph.dk regression)")
  func koanRegression() async {
    // The real failure: koancph.dk gave only og:title "Koan 23" (no JSON-LD,
    // address, geo, or locality), the worldwide search was device-biased to the
    // US, and the matcher auto-accepted "23 Koa Ln, Statesville, NC" because the
    // numeric "23" cleared minimumScore: 1. The honest-confidence gate now scores
    // that hit 0, so the location is left empty for the user to fill in.
    let matcher = PlaceMatcher(
      geocode: { _ in nil },
      search: { _ in
        [self.place("23 Koa Ln", 35.78, -80.88, address: "23 Koa Ln, Statesville, NC")]
      }
    )
    #expect(await matcher.match(ParsedPage(title: "Koan 23")) == nil)
  }
}
