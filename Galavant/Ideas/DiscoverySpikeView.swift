import Dependencies
import GalavantPlaces
import SwiftUI

// DEV — M6e slice-0 spike (ADR-0018). A throwaway entry to eyeball web-search
// discovery quality before building dedup + persistence (slices 1–2). It only
// *dumps* the raw candidate list — it never saves anything to the pool. Delete this
// whole file (and the `showingDiscoverySpike` wiring in IdeasScreen) once the
// decision gate is passed.

@MainActor
@Observable
final class DiscoverySpikeModel {
  var query = "2- and 3-star Michelin restaurants"
  var region = "the Loire, France"
  var phase: Phase = .idle

  enum Phase {
    case idle
    case running
    case done([DiscoveredCandidate])
    case failed(String)
  }

  @ObservationIgnored @Dependency(\.placeDiscoveryClient) private var discover

  func run() async {
    phase = .running
    do {
      phase = .done(try await discover(query: query, region: region))
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}

struct DiscoverySpikeView: View {
  @State private var model = DiscoverySpikeModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Query", text: $model.query, axis: .vertical)
          TextField("Region", text: $model.region)
          Button("Discover") {
            Task { await model.run() }
          }
          .disabled(model.query.isEmpty || isRunning)
        } header: {
          Text("Discovery spike (dev)")
        } footer: {
          Text(
            "Runs one web-search-grounded frontier call (needs an Anthropic key in "
              + "Settings). Dumps raw candidates only — nothing is saved.")
        }

        switch model.phase {
        case .idle:
          EmptyView()
        case .running:
          Section { HStack { ProgressView(); Text("Searching…") } }
        case let .failed(message):
          Section("Error") { Text(message).foregroundStyle(.red) }
        case let .done(candidates):
          Section("\(candidates.count) candidate(s)") {
            if candidates.isEmpty {
              Text("No candidates returned.").foregroundStyle(.secondary)
            }
            ForEach(candidates) { candidate in
              VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name).font(.headline)
                if let subtitle = subtitle(for: candidate) {
                  Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if let note = candidate.note {
                  Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let source = candidate.sourceURL {
                  Text(source).font(.caption2).foregroundStyle(.tertiary)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Discover (dev)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var isRunning: Bool {
    if case .running = model.phase { return true }
    return false
  }

  private func subtitle(for candidate: DiscoveredCandidate) -> String? {
    [candidate.kind, candidate.locality, candidate.region]
      .compactMap { $0 }
      .joined(separator: " · ")
      .nilIfEmpty
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
