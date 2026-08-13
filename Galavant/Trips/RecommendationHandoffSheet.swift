import GalavantAI
import SwiftUI
import UIKit

/// The everyday external-LLM door for one recommendation handoff. It intentionally
/// stops at candidate review; resolution and the ADR-0037 workspace arrive later.
struct RecommendationHandoffSheet: View {
  let model: TripPlanningModel
  let session: HandoffSession
  @Environment(\.dismiss) private var dismiss
  @State private var copiedBrief = false

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Group {
        if model.recommendationReview.isEmpty {
          RecommendationHandoffDoor(
            copiedBrief: copiedBrief,
            copyBrief: copyBrief,
            pasteResult: { values in model.pasteRecommendationResult(values, for: session) }
          )
        } else {
          RecommendationCandidateReview(
            candidates: $model.recommendationReview,
            commit: { candidate in model.commitRecommendationCandidate(candidate, from: session) }
          )
        }
      }
      .navigationTitle(model.recommendationReview.isEmpty ? "Get Recommendations" : "Review Candidates")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.recommendationReview.isEmpty ? "Done" : "Close") { dismiss() }
        }
        if model.recommendationWorkspaceIsAvailable(for: session.id) {
          ToolbarItem(placement: .primaryAction) {
            Button("Evaluate") {
              model.recommendationWorkspaceButtonTapped(sessionID: session.id)
            }
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .alert(
      "Can’t import recommendations",
      isPresented: Binding(
        get: { model.recommendationHandoffError != nil },
        set: { if !$0 { model.recommendationHandoffError = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.recommendationHandoffError ?? "")
    }
  }

  private func copyBrief() {
    UIPasteboard.general.string = session.exportedPrompt
    copiedBrief = true
  }
}

private struct RecommendationHandoffDoor: View {
  let copiedBrief: Bool
  let copyBrief: () -> Void
  let pasteResult: ([String]) -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Ask ChatGPT or Claude", systemImage: "sparkles")
    } description: {
      Text("Copy this trip’s brief, have the conversation in your project, then paste the returned candidate JSON here.")
    } actions: {
      VStack(spacing: 12) {
        Button(action: copyBrief) {
          Label(copiedBrief ? "Brief Copied" : "Copy Brief", systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderedProminent)

        PasteButton(payloadType: String.self, onPaste: pasteResult)
          .labelStyle(.titleAndIcon)
      }
    }
  }
}

private struct RecommendationCandidateReview: View {
  @Binding var candidates: [RecommendationCandidateDraft]
  let commit: (RecommendationCandidateDraft) -> Void

  var body: some View {
    List {
      Section {
        Text("Review each proposal before adding it to this trip. Placement hints remain advisory.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach($candidates) { $candidate in
        RecommendationCandidateReviewRow(candidate: $candidate, commit: commit)
      }
    }
  }
}

private struct RecommendationCandidateReviewRow: View {
  @Binding var candidate: RecommendationCandidateDraft
  let commit: (RecommendationCandidateDraft) -> Void

  var body: some View {
    Section(candidate.name.isEmpty ? "Unnamed recommendation" : candidate.name) {
      TextField("Place name", text: $candidate.name)
      TextField("Locality", text: $candidate.locality)
      TextField("Search hint", text: $candidate.searchHint)
      TextField("Why it fits", text: $candidate.why, axis: .vertical)
        .lineLimit(2...5)
      TextField("Fit", text: $candidate.fit, axis: .vertical)
        .lineLimit(2...5)
      TextField("Rough time", text: $candidate.visit)
      if let dayRef = candidate.dayRef {
        LabeledContent("Suggested day", value: dayRef)
      }
      if let placementAfter = candidate.placementAfter {
        LabeledContent("Suggested after", value: placementAfter)
      }
      Button("Add to Considering") {
        commit(candidate)
      }
      .disabled(!candidate.canCommit)
    }
  }
}
