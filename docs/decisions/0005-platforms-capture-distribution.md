# ADR-0005: Platforms, capture, and distribution

*Status: accepted — 2026-06-10*

## Platforms

iPhone + iPad + Mac, native SwiftUI multiplatform (not Catalyst). Tab navigation on
iPhone, split view on iPad/Mac — reuse V2's `prefersTabNavigation` pattern.

**The iPad is the first-class design surface.** The trip lifecycle has two ends
with different primary devices:

- **Design/review end → iPad.** Trip planning, itinerary building, the map
  canvas, the start-day solver, shortlist negotiation — optimize these for iPad
  first (regular width: map + timeline side-by-side, drag-and-drop between
  pool/shortlist/days, pointer/pencil-friendly targets). iPhone gets a capable
  but compact rendering; iPad gets the optimized one.
- **On-the-ground end → iPhone.** In-trip consumption (today's stops, travel
  times, handoff to Maps, capture) is designed phone-first.
- Mac rides along via the iPad-optimized layouts.

## Capture

The **Safari share extension is essential** and treated as a primary capture flow,
not a nice-to-have. Consequences from day one:

- The SQLite database lives in an **app group container** so the extension can write
  to it directly (V1's pattern, minus the UserDefaults JSON-passing hacks).
- Capture also available via in-app browser with page scraping (SwiftSoup — port
  V1/V2's approach), MapKit search, and manual entry.
- Extension UI should be a thin reuse of the in-app idea form.

## Distribution

Not going to the App Store — this is a private app for two people. Distribution via
**TestFlight** (avoids 7-day free-signing expiry on the wife's devices). Requires the
paid Apple Developer membership, which CloudKit needs anyway.

**Open item:** Jon's membership may be lapsed — verify/renew before Roadmap M1.
Everything in M0 runs locally without it.
