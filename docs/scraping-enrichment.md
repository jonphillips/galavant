# Web capture: scraping, enrichment, and Apple Maps matching

*Design notes mined from the V1 server (`~/code/galavant/travelex`,
`apps/travel/lib/travel/web_scraping/`) — Elixir, but the design ports to
on-device Swift. Feeds Roadmap M4.*

## What the V1 server did (and why it worked)

Given a URL (from the share extension or in-app browser), it built a place by
layering progressively more authoritative extraction passes over the page:

1. **Source detection** — URL domain → a site-specific builder (Yelp, TripAdvisor,
   Airbnb, VRBO, OpenTable, Google, Travel+Leisure, generic). Each builder is the
   same pipeline with hooks: attributes to *omit*, OpenGraph tags to *blacklist*
   (e.g. Yelp's og:title is junk), metatags to *whitelist*, plus custom XPath
   scraping (e.g. Yelp's "Business website" link).
2. **Plain metatags** — `title`, `description`, `twitter:image`.
3. **OpenGraph** — `og:title/description/image(:url/:secure_url)`, plus the
   underused gold: `place:location:latitude/longitude`,
   `business:contact_data:*` (street, locality, postal code, country, phone,
   email, website), `og:locale`.
4. **schema.org Microdata** — the richest layer (~260-line mapping):
   `Organization`, `LocalBusiness`, `Place`, `FoodEstablishment`, `Restaurant`,
   `Hotel`, `BedAndBreakfast`, `ImageObject` → name, details, geo coordinates,
   PostalAddress fields, logo/images, and `sameAs` → facebook/twitter/instagram
   URLs. Types are processed in specificity order (WebSite → … → Hotel) so
   specific types out-vote generic ones.
5. **Custom scraping + fallbacks** — site XPaths, then page title/first
   paragraphs/body images as a last resort.

### The two key mechanisms

**Value voting.** Every pass *adds a candidate* per attribute into a
`value → count` map rather than overwriting; at the end the most-seen value wins
(`consolidate_scored_attrs`). Agreement between metatag, OpenGraph, and microdata
acts as a confidence signal. Cheap and surprisingly effective — port this as-is.

**Two-hop enrichment.** If extraction finds a `place_url` (the business's own
site) different from the origin URL — common when saving a blog post or a Yelp
page — it scrapes that second page with the full pipeline too. Related tricks: a
`facebook.com/sharer.php` link on the page yields the canonical URL behind
aggregator pages, and WordPress sites expose a JSON API worth hitting.

## Apple Maps mapping (both directions)

- **Scraped page → MKMapItem ("map magic"):** generate search tokens from scraped
  name + locality + region (stopwords filtered), run `MKLocalSearch`, then score
  each candidate by common-substring overlap between (candidate name vs scraped
  name) + (candidate street vs scraped street); best score wins. Already in
  Swift: V1's `Shared/Utils/PlaceSearchStrategy.swift` ports nearly verbatim.
- **MKMapItem → web enrichment (reverse):** when capture starts from an Apple
  Maps selection, MapKit's name/address/coordinates are **authoritative** — the
  builder omits those attributes and only enriches details, images, and social
  URLs by scraping the place's website (`MKMapItem.url`).

The merged result is what made V1 captures feel magical: Apple's clean canonical
place data + the web page's description, images, and links.

## V3 porting notes (on-device, no server)

- **Parser:** SwiftSoup (already proven in V1's iOS code) replaces Meeseeks/XPath;
  translate the XPath lookups to CSS selectors.
- **JS-heavy pages:** the server needed a headless-Chrome fallback (Wallaby) on
  403/503. On-device we get better for free: the share extension receives the
  *rendered* DOM from Safari (V1's `ExtensionPreProcessing.js` pattern), and the
  in-app browser can hand over `document.documentElement.outerHTML` from
  WKWebView. Plain `URLSession` fetch is only the fallback, with a
  Safari-like User-Agent.
- **Implement JSON-LD first.** *(Corrected 2026-06-12 after a Codex audit:
  an earlier version of this doc claimed travelex lacked JSON-LD support,
  based on the vendored microdata library's stale README. In fact
  `microdata_parsing.ex` parses with `Microdata.Strategy.JSONLD` — V1's
  pipeline already prioritized JSON-LD.)* JSON-LD
  (`<script type="application/ld+json">`) is how most sites ship schema.org
  data today and is the easiest format to parse in Swift (JSONSerialization
  against the same schema.org property mapping). V3 follows V1's own
  precedent: JSON-LD first, HTML microdata as the second source, both feeding
  the voting.
- Port the three tag-mapping tables (metatag/OpenGraph/schema.org) as data, not
  code — they're the distilled knowledge.
- **Capture `openingHours`.** The V1 server's restaurant/business mappers parsed
  past it with `# Include????` and dropped it. V3 keeps it (weekday granularity
  minimum) — it feeds the start-day solver (`docs/trip-time-model.md`). Record a
  captured-at date; hours rot.
- Site-specific builders: start with just Generic + the omit/blacklist hook
  mechanism; add per-site quirks (Yelp, TripAdvisor…) only when a real capture
  fails, since their 2021 XPaths have certainly rotted.
- Image handling: dedupe, filter irrelevant/invalid URLs, first survivor becomes
  the header image candidate (user can override; Unsplash as backup).

## Regions and matching: bias, not constraint

V1 hard-constrained MKLocalSearch to the associated board's region
(`PlaceBuilder` → `searchConstraintRegion` → completer + map-magic search) with
no automatic fallback. The disambiguation value was real ("Noma" needs a
Copenhagen prior), but the mechanism was too blunt (trip moves 10 miles east,
or a tightly drawn region, and matching breaks). V3 rules:

1. **Region is derived, not required.** Capture is pool-first, so resolve the
   location from page signals, then auto-assign regions by containment. The
   dependency is inverted from V1.
2. **Signal ladder for Apple Maps matching:** scraped coordinates (skip search;
   nearby-POI lookup + substring scoring) → scraped address (geocode) → text
   search *biased* by a candidate region (trip context if capturing from a trip;
   `MKLocalSearch.Request.region` is a hint, not a filter) → world.
3. **Auto-widen on low confidence.** `PlaceSearchStrategy`-style match scoring
   already yields a number; if the biased search's best score is below threshold,
   retry unconstrained instead of failing. V1 had the score but never did this.
4. **Regions are generous** (metro/area scale) for bucketing; the trip-planning
   lens filters by trip regions **plus an adjustable radius** (V2's
   `filterDistance`), never strict containment.
