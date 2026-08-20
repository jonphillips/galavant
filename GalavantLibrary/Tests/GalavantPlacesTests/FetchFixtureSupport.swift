import Foundation
import GalavantPlaces

func fetchedDocument(_ html: String, at url: URL) -> FetchedDocument {
  FetchedDocument(html: html, effectiveURL: url)
}
