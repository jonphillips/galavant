import GalavantAI
import GalavantSchema
import SwiftUI
import UIKit

/// The everyday external-LLM door for one recommendation handoff. It intentionally
/// stops at candidate review; resolution and the ADR-0037 workspace arrive later.
struct RecommendationHandoffSheet: View {
  let model: TripPlanningModel
  let session: HandoffSession
  @Environment(\.dismiss) private var dismiss
  @State private var copiedBrief = false
  @State private var seedReviewModel: SeedReviewModel?

  init(model: TripPlanningModel, session: HandoffSession) {
    self.model = model
    self.session = session
    _seedReviewModel = State(
      initialValue: session.taskType == RecommendationHandoffTask.seedTrip ? SeedReviewModel() : nil
    )
  }

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Group {
        if let seedReviewModel, seedReviewModel.plan != nil {
          SeedReviewSheet(model: seedReviewModel, session: session, dismiss: dismiss)
        } else if model.recommendationReview.isEmpty {
          RecommendationHandoffDoor(
            copiedBrief: copiedBrief,
            copyBrief: copyBrief,
            pasteResult: pasteResult
          )
        } else {
          RecommendationCandidateReview(
            candidates: $model.recommendationReview,
            commit: { candidate in model.commitRecommendationCandidate(candidate, from: session) }
          )
        }
      }
      .navigationTitle(navigationTitle)
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
        get: { activeError != nil },
        set: { if !$0 { clearActiveError() } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(activeError ?? "")
    }
    .alert(
      "Recommendations imported",
      isPresented: Binding(
        get: { activeWarning != nil },
        set: { if !$0 { clearActiveWarning() } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(activeWarning ?? "")
    }
  }

  private var navigationTitle: String {
    if session.taskType == RecommendationHandoffTask.seedTrip {
      return seedReviewModel?.plan == nil ? "Seed from Conversation" : "Review Trip Seed"
    }
    return model.recommendationReview.isEmpty ? "Get Recommendations" : "Review Candidates"
  }

  private func copyBrief() {
    UIPasteboard.general.string = session.exportedPrompt
    copiedBrief = true
  }

  private func pasteResult(_ values: [String]) {
    model.pasteRecommendationResult(values, for: session, seedReviewModel: seedReviewModel)
  }

  private var activeError: String? {
    session.taskType == RecommendationHandoffTask.seedTrip
      ? seedReviewModel?.error
      : model.recommendationHandoffError
  }

  private var activeWarning: String? {
    session.taskType == RecommendationHandoffTask.seedTrip
      ? nil
      : model.recommendationHandoffWarning
  }

  private func clearActiveError() {
    if session.taskType == RecommendationHandoffTask.seedTrip {
      seedReviewModel?.error = nil
    } else {
      model.recommendationHandoffError = nil
    }
  }

  private func clearActiveWarning() {
    if session.taskType != RecommendationHandoffTask.seedTrip {
      model.recommendationHandoffWarning = nil
    }
  }
}

private struct SeedReviewSheet: View {
  @Bindable var model: SeedReviewModel
  let session: HandoffSession
  let dismiss: DismissAction

  private let verdicts: [SeedVerdict] = [.core, .considering, .declined, .deferred]

  var body: some View {
    List {
      if let plan = model.plan {
        Section("Trip shape") {
          if plan.tripEdit.lengthDays != nil || plan.forcedLengthDays != nil {
            Toggle("Change length to \(plan.effectiveLengthDays) days", isOn: Binding(
              get: { model.plan?.shouldIncludeLength ?? false },
              set: { model.plan?.tripEdit.includeLength = $0 }
            ))
            .disabled(plan.forcedLengthDays != nil)
            if let forcedLength = plan.forcedLengthDays {
              Text("Stays run to day \(forcedLength)")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          let proposedYear = plan.tripEdit.knownYear
          let proposedQuarter = plan.tripEdit.quarter ?? plan.seed.trip.quarter
          let hasCertaintyEdit = plan.tripEdit.year != nil || plan.tripEdit.quarter != nil
          let certaintyLabel = proposedYear.map { year in
            "Target \(year)" + (proposedQuarter.map { " · Q\($0)" } ?? "")
          } ?? proposedQuarter.map { "Target Q\($0)" } ?? "Trip timing"
          if (hasCertaintyEdit || (plan.tripEdit.certaintyDisabled && (proposedYear != nil || proposedQuarter != nil)))
            && proposedYear != nil {
            Toggle(isOn: Binding(
              get: { model.plan?.tripEdit.includeCertainty ?? false },
              set: { model.plan?.tripEdit.includeCertainty = $0 }
            )) {
              Text(certaintyLabel)
            }
            .disabled(plan.tripEdit.certaintyDisabled)
            if plan.tripEdit.certaintyDisabled {
              Text("Trip has dates")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else if proposedQuarter != nil {
            Text("Quarter without a year — set in Edit Trip")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let summary = plan.seed.trip.summary {
            Text(summary).font(.footnote).foregroundStyle(.secondary)
          }
        }

        if !plan.stays.isEmpty {
          Section("Stays") {
            ForEach(Array(plan.stays.indices), id: \.self) { index in
              let row = plan.stays[index]
              VStack(alignment: .leading, spacing: 5) {
                Toggle(row.base.name, isOn: Binding(
                  get: { model.plan?.stays[index].include ?? false },
                  set: { model.plan?.stays[index].include = $0 }
                ))
                Text("Days \(row.base.checkInDay)–\(row.base.checkOutDay)")
                  .font(.caption).foregroundStyle(.secondary)
                if let note = row.note { Text(note).font(.caption).lineLimit(3).foregroundStyle(.secondary) }
                if row.base.bookAhead { Label("Book ahead", systemImage: "calendar.badge.clock").font(.caption) }
                if row.alreadyOnTrip { Text("Already on trip").font(.caption).foregroundStyle(.secondary) }
              }
            }
          }
        }

        ForEach([TripIdeaStatus.shortlisted, .considering, .declined], id: \.rawValue) { status in
          let indices = plan.places.indices.filter {
            plan.effectiveStatus(ofPlaceAt: $0) == status && !plan.places[$0].alreadyOnTrip
          }
          if !indices.isEmpty {
            Section(sectionTitle(for: status)) {
              ForEach(indices, id: \.self) { index in placeRow(index, plan: plan) }
            }
          }
        }

        let alreadyOnTrip = plan.places.indices.filter { plan.places[$0].alreadyOnTrip }
        if !alreadyOnTrip.isEmpty {
          Section("Already on trip") {
            ForEach(alreadyOnTrip, id: \.self) { index in placeRow(index, plan: plan) }
          }
        }

        if !plan.warnings.isEmpty || !plan.ignoredGroups.isEmpty {
          Section("Notes") {
            ForEach(plan.warnings, id: \.self) { Text($0).font(.footnote) }
            ForEach(plan.ignoredGroups, id: \.self) { Text("Choose one group ‘\($0)’ has fewer than two included options.").font(.footnote) }
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      Button {
        if model.commit(from: session) { dismiss() }
      } label: {
        Text("Import (\(includedCount))")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .padding()
      .background(.bar)
    }
  }

  @ViewBuilder
  private func placeRow(_ index: Int, plan: SeedPlan) -> some View {
    let row = plan.places[index]
    VStack(alignment: .leading, spacing: 7) {
      Toggle(row.title.isEmpty ? "Unnamed place" : row.title, isOn: Binding(
        get: { model.plan?.places[index].include ?? false },
        set: { model.plan?.places[index].include = $0 }
      ))
      Picker("Verdict", selection: Binding(
        get: { model.plan?.places[index].place.verdict ?? .considering },
        set: { model.plan?.places[index].place.verdict = $0 }
      )) {
        ForEach(verdicts, id: \.self) { verdict in Text(verdictLabel(verdict)).tag(verdict) }
        if case .unrecognized = row.place.verdict {
          Text("\(row.place.verdict.originalValue) · considering").tag(row.place.verdict)
        }
      }
      .font(.caption)
      if let note = row.note { Text(note).font(.caption).lineLimit(3).foregroundStyle(.secondary) }
      HStack(spacing: 10) {
        if let kind = row.place.candidate.kind {
          Text(row.place.normalizedKind.map { "\(kind) · \($0.label)" } ?? kind)
        }
        if plan.formsRing(at: index) {
          Label("Choose one · \(row.place.group ?? "")", systemImage: "circle.grid.2x2")
        }
        if row.place.candidate.bookAhead == true { Label("Book ahead", systemImage: "calendar.badge.clock") }
        if let day = row.place.candidate.dayRef { Text(day) }
        if row.existingTripIdeaID != nil { Text("Already on trip") }
        if row.statusUpdate { Text("Status update · off by default") }
      }
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var includedCount: Int {
    guard let plan = model.plan else { return 0 }
    return plan.stays.filter(\.include).count + plan.places.filter(\.include).count
  }

  private func sectionTitle(for status: TripIdeaStatus) -> String {
    switch status {
    case .shortlisted: "Shortlist"
    case .considering: "Considering"
    case .declined: "Ruled out"
    case .scheduled, .done, .skipped: status.label
    }
  }

  private func verdictLabel(_ verdict: SeedVerdict) -> String {
    switch verdict {
    case .core: "Core"
    case .considering: "Considering"
    case .declined: "Declined"
    case .deferred: "Deferred"
    case let .unrecognized(value): "\(value) · considering"
    }
  }
}

private struct RecommendationHandoffDoor: View {
  let copiedBrief: Bool
  let copyBrief: () -> Void
  let pasteResult: ([String]) -> Void

  var body: some View {
    // The CTAs live in a pinned bottom inset rather than `ContentUnavailableView`'s
    // centered `actions` slot: at the `.medium` detent that slot pushes the paste
    // control below the fold, where it reads as missing.
    ContentUnavailableView {
      Label("Ask ChatGPT or Claude", systemImage: "sparkles")
    } description: {
      Text("Copy this trip’s brief, have the conversation in your project, then paste the returned candidate JSON here.")
    }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 12) {
        Button(action: copyBrief) {
          Label(copiedBrief ? "Brief Copied" : "Copy Brief", systemImage: "doc.on.doc")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        PasteButton(payloadType: String.self, onPaste: pasteResult)
          .labelStyle(.titleAndIcon)
      }
      .padding()
      .background(.bar)
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
