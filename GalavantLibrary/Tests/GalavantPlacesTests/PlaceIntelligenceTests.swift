import Foundation
import GalavantCapture
import GalavantSchema
import Testing

@testable import GalavantPlaces

/// The pure merge — `ParsedPage.applying(_:)` — exercised without the model.
/// Confirm-and-tweak: clean a chrome title, fill blanks, never clobber structured
/// data. (The live FoundationModels path needs an eligible device — not unit-tested.)
@Suite struct PlaceIntelligenceMergeTests {
  @Test("a chrome title is replaced by the cleaned name")
  func cleansChromeTitle() {
    let page = ParsedPage(
      title: "Forestis Dolomites | Boutique Wellness Hotel in Brixen",
      titleIsStructured: false
    )
    let merged = page.applying(PlaceRefinement(name: "Forestis"))
    #expect(merged.title == "Forestis")
    // Still a guess, so Apple Maps can override it later.
    #expect(merged.titleIsStructured == false)
  }

  @Test("a structured name is trusted and not replaced")
  func keepsStructuredTitle() {
    let page = ParsedPage(title: "Noma", titleIsStructured: true)
    let merged = page.applying(PlaceRefinement(name: "Something Else"))
    #expect(merged.title == "Noma")
  }

  @Test("locality and region are mined only when the page left them blank")
  func fillsMissingLocality() {
    let page = ParsedPage(title: "Koan")
    let merged = page.applying(PlaceRefinement(locality: "Copenhagen", region: "Denmark"))
    #expect(merged.address.locality == "Copenhagen")
    #expect(merged.address.region == "Denmark")
  }

  @Test("a known locality is not overwritten")
  func keepsKnownLocality() {
    let page = ParsedPage(address: ParsedAddress(locality: "København"))
    let merged = page.applying(PlaceRefinement(locality: "Copenhagen"))
    #expect(merged.address.locality == "København")
  }

  @Test("the model's neutral summary supersedes the page's own (often marketing) one")
  func summaryOverridesPageDescription() {
    // Notes are generated, not scraped — the de-marketed summary wins when present.
    let blank = ParsedPage(title: "Koan").applying(PlaceRefinement(summary: "Korean tasting menu."))
    #expect(blank.summary == "Korean tasting menu.")

    let marketing = ParsedPage(title: "Forestis", summary: "Searching for a hotel? Find out more.")
      .applying(PlaceRefinement(summary: "A wellness hotel in the Dolomites near Brixen."))
    #expect(marketing.summary == "A wellness hotel in the Dolomites near Brixen.")
  }

  @Test("the page's summary is kept when the model gives none")
  func keepsPageSummaryWhenModelSilent() {
    let page = ParsedPage(title: "Koan", summary: "Real description.")
      .applying(PlaceRefinement(locality: "Copenhagen"))
    #expect(page.summary == "Real description.")
  }

  @Test("blank/whitespace model values are ignored")
  func ignoresBlankValues() {
    let page = ParsedPage(title: "Bar | Tagline", titleIsStructured: false)
    let merged = page.applying(PlaceRefinement(name: "   ", locality: ""))
    #expect(merged.title == "Bar | Tagline")
    #expect(merged.address.locality == nil)
  }

  @Test("kind is not applied at the page level (it is domain, applied to the draft)")
  func kindNotOnPage() {
    // Sanity: applying a refinement carrying a kind doesn't touch the page —
    // ParsedPage has no kind. CaptureModel handles kind separately.
    let page = ParsedPage(title: "Koan")
    let merged = page.applying(PlaceRefinement(kind: .food))
    #expect(merged == page)
  }
}
