# Galavant Roadmap

Vertical slices; each milestone ends with something that runs. Riskiest unknowns
first. Update this file when reality diverges — it's a living doc, not a contract.

## M0 — Skeleton that persists *(no dev account needed)*
- Xcode project: multiplatform SwiftUI app + share-extension target stub + local SPM package
- SQLiteData wired up; database in the **app group container** from day one
- Minimal `Idea` model (name, coordinate, region, notes) with CloudKit-legal schema (UUID PKs)
- List + add/edit form proving @FetchAll observation and swift-navigation Destination pattern
- ✅ Done when: add an idea on iPhone sim, relaunch, it's still there

## M1 — The CloudKit bet *(needs paid dev account — verify membership first)*
- Turn on SQLiteData CloudKit sync for the toy schema
- Prove sync across two devices on one account
- Prove the **household share**: second iCloud account (wife's) accepts one share and
  sees/edits everything — this is the project's #1 risk (ADR-0003)
- ✅ Done when: edit on Jon's phone appears on wife's device and vice versa

## M2 — The pool
- Full Idea model: kinds, **per-spouse flames ratings + notes** (Must Do…Decide Later; docs/recovered-requirements.md), visited state, tags, URLs, images, opening days/hours and reservable-from (manual entry)
- MapRegions (port V2's working implementation) + region/tag/category/distance filtering
- Capture via MapKit search + manual entry
- Pool map view (PowerMap descendant)
- ✅ Done when: the Denmark junk drawer works — collect, filter, browse on a map

## M3 — Trips
- Trip model: **certainty lifecycle** someday(rank) → targeted(year, quarter) → dated (docs/trip-time-model.md); duration in days; **day-number-relative itinerary** + **TripIdea join with status lifecycle** (ADR-0004)
- Trips list grouped by certainty; drag-rank the someday backlog; trip link bookmarks (label+URL)
- Planning view: pool filtered by trip lens → pull to shortlist
- Shortlist drag-to-rank ordering
- Itinerary: days, per-day regions (with percentDay splits), stops with the V2 Schedule enum; "bookable now / opens in N days" section on dated trips
- Post-trip: done/skipped feedback to pool
- Map-as-canvas trip view: day chips, numbered sequence pins, bottom-sheet timeline (docs/trip-canvas.md)
- Travel-time connectors between a day's stops (MKDirections ETAs, gap conflicts) + open-in-Maps handoff
- Stretch: start-day solver (slide start date → check key stops' open days; docs/trip-time-model.md)
- ✅ Done when: the Copenhagen scenario works end to end

## M4 — Capture from anywhere
- Share extension: URL in → scraped page (SwiftSoup, port V1) → idea form → saved to shared DB
- Enrichment pipeline per `docs/scraping-enrichment.md` (port of the V1 server's
  metatag/OpenGraph/schema.org layering, value voting, and MKLocalSearch matching; add JSON-LD and openingHours capture)
- In-app browser capture flow (port V2's WebSearch)
- ✅ Done when: share a restaurant page from Safari, it's in the pool with image and location, and it syncs

## M5 — Polish & distribution
- iPad/Mac split-view layouts properly done
- Weather chips on itinerary days: climate normals when far out/undated, WeatherKit forecast inside 10 days (docs/trip-canvas.md)
- Unsplash header images (port GalavantLibrary's UnsplashSearch) if still wanted
- TestFlight setup; app on wife's phone
- Future/backlog: booking-window local notifications with time-of-day precision (the 3 a.m. hard-to-get-restaurant alarm — docs/recovered-requirements.md Q2)
- ✅ Done when: both phones run it daily
