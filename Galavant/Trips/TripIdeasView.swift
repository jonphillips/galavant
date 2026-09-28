import GalavantSchema
import SwiftUI

/// The trip's Ideas tab: the pulled ideas grouped into the planner's three
/// plain-language stages — Consider / Schedule / Scheduled (dogfood) — with
/// one-tap state icons (star/calendar) and swipe actions. "Schedule" is the
/// shortlist (committed, awaiting a day) plus anything already sent to be
/// scheduled but still dayless. A scheduled stop can't be removed here — it's
/// unscheduled back to Schedule first (ADR-0004). The Add button (in the parent
/// shell) opens the pool sheet.
struct TripIdeasView: View {
  let model: TripPlanningModel
  /// On compact layouts this is the first list section, so it scrolls with the
  /// pool instead of taking permanent vertical space above it.
  var showsInlineAdd = false
  /// Regular-width iPad uses the photo-forward scheduled-row treatment.
  var usesColumn = false

  var body: some View {
    let plan = model.plan
    let visibleStopIDs = visibleStopIDs(in: plan)
    List {
      if showsInlineAdd {
        Section {
          TripAddButton(model: model)
        }
      }
      if let trip = model.trip {
        Section {
          HStack(spacing: 6) {
            Text(trip.certaintySummary)
            Text("·")
            Text("^[\(trip.lengthInDays) day](inflect: true)")
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
      }
      if let session = model.mostRecentRecommendationWorkspaceSession {
        Section {
          Button {
            model.recommendationWorkspaceButtonTapped(sessionID: session.id)
          } label: {
            Label("Evaluate Recommendations", systemImage: "sparkles")
          }
        } footer: {
          Text("Open the most recent recommendation set for this trip.")
        }
      }
      // The three plain-language stages the planner thinks in (dogfood):
      // Consider (a maybe), Schedule (committed, awaiting a day — the shortlist,
      // plus anything already sent to be scheduled but still dayless), Scheduled
      // (placed on a day).
      if !plan.considering.isEmpty {
        Section("Consider") {
          ForEach(plan.considering) { resolved in
            PlanningRow(content: resolved.content, note: resolved.entry.inlineNote, subtitle: .category) {
              // Empty star = considering; tap moves it into Schedule.
              starButton(filled: false) {
                model.setStatus(.shortlisted, for: resolved.id)
              }
            }
            .contentShape(Rectangle())
            .onTapGesture {
              model.tripIdeaRowTapped(resolved, isDrawnOnCanvas: visibleStopIDs.contains(resolved.id))
            }
            .listRowBackground(rowBackground(for: resolved))
            .swipeActions(edge: .leading) {
              if resolved.idea?.kind == .stay {
                Button {
                  if let idea = resolved.idea { model.stayHere(idea) }
                } label: {
                  Icon.stay.label("Stay here")
                }
                .tint(.indigo)
              }
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                model.remove(resolved.id)
              } label: {
                Icon.delete.label("Remove")
              }
            }
          }
        }
      }
      if !plan.shortlist.isEmpty || !plan.toBeScheduled.isEmpty {
        Section("Schedule") {
          ForEach(plan.shortlist) { resolved in
            PlanningRow(content: resolved.content, note: resolved.entry.inlineNote, subtitle: .category) {
              HStack(spacing: 14) {
                // Lit star = in Schedule; tap demotes it back to Consider.
                starButton(filled: true) {
                  model.setStatus(.considering, for: resolved.id)
                }
                Button {
                  model.addAsAlternativeButtonTapped(sourceStopID: resolved.id)
                } label: {
                  Icon.alternatives.image.foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add as alternative to an itinerary stop")
              }
            }
            .contentShape(Rectangle())
            .onTapGesture {
              model.tripIdeaRowTapped(resolved, isDrawnOnCanvas: visibleStopIDs.contains(resolved.id))
            }
            .listRowBackground(rowBackground(for: resolved))
            .swipeActions(edge: .leading) {
              Button {
                model.sendToBeScheduled(resolved.id)
              } label: {
                Icon.schedule.label("Schedule")
              }
              .tint(.blue)
              if resolved.idea?.kind == .stay {
                Button {
                  if let idea = resolved.idea { model.stayHere(idea) }
                } label: {
                  Icon.stay.label("Stay here")
                }
                .tint(.indigo)
              }
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                model.remove(resolved.id)
              } label: {
                Icon.delete.label("Remove")
              }
            }
          }
          .reorderable()
          // Committed but not yet on a day — waiting to be placed on the itinerary.
          ForEach(plan.toBeScheduled) { resolved in
            scheduledIdeaRow(resolved, visibleStopIDs: visibleStopIDs)
          }
        }
      }
      let placedScheduled = plan.scheduled.filter { $0.entry.dayNumber != nil }
      if !placedScheduled.isEmpty {
        Section {
          ForEach(placedScheduled) { resolved in
            scheduledIdeaRow(resolved, visibleStopIDs: visibleStopIDs)
          }
        } header: {
          HStack(spacing: 6) {
            Text("Scheduled")
            Button {
              model.sheetTab = .itinerary
            } label: {
              Image(systemName: "calendar.badge.checkmark")
                .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Show scheduled itinerary")
          }
        }
      }
    }
    .reorderContainer(for: ResolvedStop.self) { difference in
      var entries = plan.shortlist
      difference.apply(to: &entries)
      model.reorderShortlist(entries.map(\.id))
    }
    .overlay {
      if plan.isEmpty {
        ContentUnavailableView {
          Icon.emptyPool.label("No ideas yet")
        } description: {
          Text("Tap + to pull ideas from the pool onto this trip.")
        } actions: {
          Button("Add Ideas") { model.addIdeasButtonTapped() }
        }
      }
    }
  }

  private func visibleStopIDs(in plan: TripPlan) -> Set<TripIdea.ID> {
    let visibleDays = plan.visibleDays(day: model.canvasSelectedDay, stayID: model.canvasSelectedStayID)
    return Set(
      visibleDays.flatMap(\.stops)
        .filter { $0.coordinate != nil }
        .map(\.id)
    )
  }

  private func rowBackground(for stop: ResolvedStop) -> Color? {
    model.canvasSelectedStopID == stop.id || model.canvasPreviewStopID == stop.id
      ? Color.accentColor.opacity(0.12)
      : nil
  }

  /// A lit (shortlisted) or outline (considering) star that flips the row's
  /// state in one tap.
  private func starButton(filled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: filled ? "star.fill" : "star")
        .foregroundStyle(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.borderless)
  }

  /// The lit indicator for a scheduled stop; tapping jumps to the Itinerary.
  /// Green + check once it's placed on a day, yellow + clock while it's still in
  /// the To-Be-Scheduled bucket (committed to the trip but dayless).
  private func scheduledBadge(_ schedule: Schedule) -> some View {
    let placed = schedule.dayNumber != nil
    return Button {
      model.sheetTab = .itinerary
    } label: {
      Image(systemName: placed ? "calendar.badge.checkmark" : "calendar.badge.clock")
        .foregroundStyle(placed ? AnyShapeStyle(.green) : AnyShapeStyle(.yellow))
    }
    .buttonStyle(.borderless)
  }

  /// A scheduled row can be returned to the shortlist (or removed when it is a
  /// freeform stop) from either the To-Be-Scheduled or placed Scheduled section.
  private func scheduledIdeaRow(
    _ resolved: ResolvedStop,
    visibleStopIDs: Set<TripIdea.ID>
  ) -> some View {
    scheduledRow(resolved)
      .contentShape(Rectangle())
      .onTapGesture {
        model.tripIdeaRowTapped(resolved, isDrawnOnCanvas: visibleStopIDs.contains(resolved.id))
      }
      .listRowBackground(rowBackground(for: resolved))
      .swipeActions(edge: .trailing) {
        if case .freeform = resolved.content {
          Button(role: .destructive) {
            model.remove(resolved.id)
          } label: {
            Icon.delete.label("Remove")
          }
        } else {
          Button {
            model.unschedule(resolved.id)
          } label: {
            Icon.unschedule.label("Unschedule")
          }
          .tint(.orange)
        }
      }
  }

  @ViewBuilder
  private func scheduledRow(_ resolved: ResolvedStop) -> some View {
    if usesColumn {
      PlanningRow(
        content: resolved.content,
        note: resolved.entry.inlineNote,
        subtitle: .none,
        marker: .image(resolved.idea.flatMap { model.headerThumbnailByIdea[$0.id] })
      ) {
        Image(systemName: resolved.idea?.kind?.systemImage ?? "mappin.and.ellipse")
          .foregroundStyle(.secondary)
          .frame(width: 26)
          .accessibilityLabel(resolved.idea?.kind?.label ?? "Place type")
      }
    } else {
      PlanningRow(content: resolved.content, note: resolved.entry.inlineNote, subtitle: .category) {
        scheduledBadge(resolved.entry.schedule)
      }
    }
  }
}
