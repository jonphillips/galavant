import Foundation
import GalavantSchema
import MapKit

/// An as-you-type completion: just the text Maps suggests, not yet a place. It
/// becomes a `Place` only when tapped (`PlaceSearchModel.resolve`), so typing never
/// spends a full `MKLocalSearch` per suggestion.
public struct PlaceSuggestion: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var subtitle: String
  /// The live completion to resolve; `nil` for test fixtures.
  let completion: CompletionHandle?

  init(id: UUID, title: String, subtitle: String, completion: CompletionHandle? = nil) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.completion = completion
  }

  var searchIdentity: String { "\(title)|\(subtitle)" }
}

/// Carries MapKit's completion object across the client's `Sendable` boundary. It is
/// only ever read (handed back to `MKLocalSearch.Request(completion:)`), never mutated.
final class CompletionHandle: @unchecked Sendable, Equatable {
  let value: MKLocalSearchCompletion
  init(_ value: MKLocalSearchCompletion) { self.value = value }
  static func == (lhs: CompletionHandle, rhs: CompletionHandle) -> Bool { lhs === rhs }
}

/// One row in a place-search list: a type-ahead suggestion still to be resolved, or a
/// fully resolved natural-language hit.
public enum PlaceSearchResult: Identifiable, Equatable, Sendable {
  case suggestion(PlaceSuggestion)
  case place(Place)

  public var id: UUID {
    switch self {
    case .suggestion(let suggestion): suggestion.id
    case .place(let place): place.id
    }
  }

  public var title: String {
    switch self {
    case .suggestion(let suggestion): suggestion.title
    case .place(let place): place.name
    }
  }

  public var subtitle: String {
    switch self {
    case .suggestion(let suggestion): suggestion.subtitle
    case .place(let place): place.subtitle
    }
  }

  /// Known only once resolved; a suggestion carries no category.
  public var kind: IdeaKind? {
    switch self {
    case .suggestion: nil
    case .place(let place): place.kind
    }
  }

  /// Suggestions first (they match what's half-typed), then natural-language hits
  /// the completer didn't suggest — the fallback for a full "Noma Copenhagen" query
  /// it handles poorly. A suggestion the natural-language search also found by name
  /// is shown as that resolved hit instead: a completion carries no category, so this
  /// is what gives a hotel its bed icon (and skips the lookup on tap).
  static func merged(
    suggestions: [PlaceSuggestion],
    places: [Place],
    limit: Int = 12
  ) -> [PlaceSearchResult] {
    var unclaimed = places
    let leading = suggestions.prefix(8).map { suggestion -> PlaceSearchResult in
      let title = suggestion.title.searchFolded
      guard let index = unclaimed.firstIndex(where: { $0.name.searchFolded == title }) else {
        return .suggestion(suggestion)
      }
      return .place(unclaimed.remove(at: index))
    }
    return Array((leading + unclaimed.map(PlaceSearchResult.place)).prefix(limit))
  }
}

private extension String {
  /// "Château la Commaraine" and "chateau La Commaraine" are the same name.
  var searchFolded: String {
    folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// One-shot async bridge over the delegate-based `MKLocalSearchCompleter`: set the
/// fragment, take the first result set it reports. A fresh completer per query keeps
/// cancellation trivial; the model's debounce keeps the count low.
@MainActor
final class CompletionRequest: NSObject, MKLocalSearchCompleterDelegate {
  private let completer = MKLocalSearchCompleter()
  private var continuation: CheckedContinuation<[PlaceSuggestion], any Error>?

  func results(
    for query: String,
    region: MKCoordinateRegion,
    required: Bool
  ) async throws -> [PlaceSuggestion] {
    completer.delegate = self
    // No `.query` ("coffee — search nearby") rows: those resolve to many places, and
    // a row here must mean one.
    completer.resultTypes = [.pointOfInterest, .address, .physicalFeature]
    completer.region = region
    if required {
      completer.regionPriority = .required
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        completer.queryFragment = query
        // Never let a completer that goes quiet hold up the merged results.
        Task { [weak self] in
          try? await Task.sleep(for: .seconds(3))
          self?.finish(.failure(MKError(.loadingThrottled)))
        }
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }

  private func finish(_ result: Result<[MKLocalSearchCompletion], any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    completer.cancel()
    // Wrap MapKit's completions before they leave the main actor.
    continuation.resume(with: result.map { completions in
      completions.map {
        PlaceSuggestion(
          id: UUID(), title: $0.title, subtitle: $0.subtitle, completion: CompletionHandle($0)
        )
      }
    })
  }

  nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
    Task { @MainActor in self.finish(.success(self.completer.results)) }
  }

  nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
    Task { @MainActor in self.finish(.failure(error)) }
  }
}
