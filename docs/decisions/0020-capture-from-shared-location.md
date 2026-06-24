# ADR-0020: Capture from a shared location (Apple Maps, vCard)

*Status: accepted — 2026-06-24*

## Context

First-use feedback: *"Can't share from Maps."* You share a place from Apple Maps,
and Galavant isn't in the share sheet. Two gates are closed:

1. **Activation.** The share extension's `NSExtensionActivationRule`
   ([project.yml]) is the dictionary form, allowing only
   `NSExtensionActivationSupportsWebPageWithMaxCount` +
   `…SupportsWebURLWithMaxCount` — a *web page or web URL*. Apple Maps shares a
   place as an `MKMapItem` (`com.apple.mapkit.map-item`) and/or a vCard
   (`public.vcard`), not a web URL, so the extension never activates.
2. **Extraction.** Even if it activated, `CaptureExtraction`
   ([GalavantShare/CaptureExtraction.swift]) only handles the JS-rendered DOM
   (`public.plist`) and a bare `public.url`. There is no path that turns a
   location into a capture.

The whole capture pipeline (ADR-0016, ADR-0019) is built around a domain-free
`ParsedPage` → `CapturedPlace` → `Idea`, with Apple Maps `match` resolving the
persistent `mapItemIdentifier` that ADR-0019 dedups on. A shared location is
*already* the thing that pipeline spends a network round-trip trying to recover
from a scraped page — so the cheapest, most consistent design is to **seed the
existing pipeline from the location** rather than build a parallel one.

## Decision

Accept location shares (Apple Maps place, vCard) and feed them through the
existing capture flow by synthesizing a `ParsedPage`.

### 1. Activation — predicate rule

Replace the dictionary activation rule with a predicate `NSExtensionActivationRule`
that matches a web URL **or** a map item **or** a vCard:

```
SUBQUERY(extensionItems, $item,
  SUBQUERY($item.attachments, $att,
    ANY $att.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url"      ||
    ANY $att.registeredTypeIdentifiers UTI-CONFORMS-TO "public.vcard"    ||
    ANY $att.registeredTypeIdentifiers UTI-CONFORMS-TO "com.apple.mapkit.map-item"
  ).@count > 0
).@count > 0
```

The dictionary form has no key for location content, so a predicate is the only
way to widen activation. **Risk, must be device-verified:** the dictionary
`…SupportsWebPageWithMaxCount` key is what historically hands Safari's *rendered*
DOM to `NSExtensionJavaScriptPreprocessingFile`. We keep the preprocessing file
declared and rely on the predicate's `public.url` arm to keep Safari activation,
but whether the rendered-DOM handshake still fires under a predicate rule is not
something we can prove off-device. `CaptureExtraction` already **prefers** the JS
results and **falls back** to fetching the URL's HTML itself, so the worst case is
a fidelity regression on JS-heavy pages (e.g. SPA menus), never a broken capture.
The first device check after this lands is: *share a JS-heavy page and confirm the
rendered DOM still arrives.* If it doesn't and the fallback fetch proves too lossy,
the fallback is to split web vs. location into two extensions.

### 2. Extraction — `SharedLocation`

The extension converts a map item / vCard into a domain-free `SharedLocation`
(name, optional coordinate, address parts, phone, website, `mapItemIdentifier`).
This conversion is the I/O part — `MKMapItem` decode (MapKit), vCard decode
(Contacts) — so it lives in the extension shell. Preference order: the
`com.apple.mapkit.map-item` (carries a real coordinate and, on iOS 26+, the
persistent `MKMapItem.identifier` — the ADR-0019 dedup key for free), then
`public.vcard` (name/address/phone; usually no coordinate — `match` geocodes it).

### 3. Seeding the pipeline

`CaptureModel` gains a location entry point. When seeded from a `SharedLocation`
it builds the `ParsedPage` from the location instead of parsing HTML
(`titleIsStructured: true` — a Maps name is authoritative, never a chrome guess),
then runs the **unchanged** rest of `prepare()`: on-device refine → `CapturedPlace`
→ Apple Maps `match` → evaluations → existing-match dedup banner → trip picker.

The match still runs because a vCard carries no Apple identity, and even a map
item benefits from corroboration; when the location already carried a
`mapItemIdentifier`, we seed it first so the ADR-0019 dedup banner works even if
the match comes back empty (offline). No new save path — `persistCapture()` is
untouched, so dedup/supplement/evaluations all apply identically.

## Consequences

- Sharing a place from Apple Maps (or anything that shares a vCard / map item) now
  lands in the pool as a fully-resolved idea, deduped on Maps identity like a web
  capture.
- The capture contract widens from "web pages" to "web pages **or** locations,"
  but the seam is one synthesized `ParsedPage` — the engine stays domain-free and
  the save path is shared.
- The synthesis (`SharedLocation` → `ParsedPage`) is a pure function, unit-tested
  in `GalavantPlacesTests`. The activation-rule / JS-preprocessing interaction is
  the one device-gated unknown, called out above.
- Does **not** address the Michelin Guide *app* (ADR-tracked separately): that
  depends on what UTIs that app vends, which needs a device check. If it shares a
  plain `guide.michelin.com` URL it already works post-ADR; if it shares a vCard it
  rides this; anything else is its own follow-up.
