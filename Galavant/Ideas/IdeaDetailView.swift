import GalavantSchema
import MapKit
import SwiftUI
import UIKit

/// The placement of an idea on the trip's itinerary — populated only when the
/// detail is drilled into from the **Itinerary** (a scheduled stop), nil for a
/// plain pool idea. Drives the "On the Itinerary" section.
struct StopDetailContext {
  /// "Day 2 · Wed, Jun 17" (dated) / "Day 2" (undated) / "To Be Scheduled".
  let dayLabel: String
  let schedule: Schedule
  /// Human-authored booking details from a Calendar event linked to this stop.
  let calendarNotes: String?
}

struct IdeaDetailView: View {
  @State private var model: IdeaDossierModel
  let stopContext: StopDetailContext?
  let tripRationale: TripRationale?
  let canEdit: Bool
  let chrome: Chrome

  enum Chrome {
    case navigationBar
    case panel(onClose: () -> Void)
  }

  init(
    ideaID: Idea.ID,
    stopContext: StopDetailContext? = nil,
    tripRationale: TripRationale? = nil,
    canEdit: Bool = false,
    chrome: Chrome = .navigationBar
  ) {
    _model = State(initialValue: IdeaDossierModel(ideaID: ideaID))
    self.stopContext = stopContext
    self.tripRationale = tripRationale
    self.canEdit = canEdit
    self.chrome = chrome
  }

  var body: some View {
    let dossier = model.dossier
    return Group {
      if let dossier {
        switch chrome {
        case .navigationBar:
          dossierList(dossier)
            .navigationTitle(dossier.idea.name)
            .navigationBarTitleDisplayMode(.inline)
        case let .panel(onClose):
          VStack(spacing: 0) {
            panelHeader(dossier.idea, onClose: onClose)
            dossierList(dossier)
          }
        }
      } else {
        ContentUnavailableView("Place no longer available", systemImage: Icon.ideas.systemName)
      }
    }
    .toolbar {
      if case .navigationBar = chrome, canEdit, dossier != nil {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Edit", action: model.editButtonTapped)
        }
      }
    }
    .fullScreenCover(item: $model.destination.photo) { photo in
      NavigationStack {
        ZStack {
          Color.black.ignoresSafeArea()
          if let image = UIImage(data: photo.display) {
            Image(uiImage: image).resizable().scaledToFit()
          }
        }
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { model.destination = nil }
          }
        }
      }
    }
    .sheet(item: $model.destination.edit) { presentation in
      IdeaFormView(draft: presentation.draft, searchRegions: presentation.searchRegions)
    }
  }

  private func panelHeader(_ idea: Idea, onClose: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
      Text(idea.name)
        .font(.headline)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      if canEdit {
        Button("Edit", action: model.editButtonTapped)
      }

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.body.weight(.semibold))
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close")
    }
    .padding(.leading, 16)
    .padding(.trailing, 8)
  }

  private func dossierList(_ dossier: IdeaDossier) -> some View {
    return List {
      overviewSections(dossier)
      tripRationaleSection
      if dossier.notesPlacement == .top {
        notesSection(dossier)
        accoladesSection(dossier)
        interestsSection(dossier)
      } else {
        accoladesSection(dossier)
        interestsSection(dossier)
      }
      tripContextSections(dossier.idea)
      gallerySection(dossier)
      hoursSections(dossier.idea)
      locationAndReferenceSections(dossier.idea)
      tagsAndNotesSections(dossier)
      if dossier.notesPlacement == .bottom { notesSection(dossier) }
    }
  }

  @ViewBuilder private func overviewSections(_ dossier: IdeaDossier) -> some View {
    let idea = dossier.idea
    if let headerImage = model.headerImage, let image = UIImage(data: headerImage) {
      Section {
        Image(uiImage: image).resizable().scaledToFill()
          .frame(maxWidth: .infinity).frame(height: 220).clipped()
          .accessibilityLabel("Photo of \(idea.name)").listRowInsets(EdgeInsets())
      }
    }
    Section { identity(idea) }
    if idea.visited {
      Section { Label("Visited", systemImage: Icon.checkmark.systemName).foregroundStyle(.secondary) }
    }
  }

  @ViewBuilder private func tripContextSections(_ idea: Idea) -> some View {
    if !idea.description.isEmpty { Section("Description") { Text(idea.description) } }
    if let stopContext {
      Section("On the Itinerary") { placement(stopContext) }
      if let calendarNotes = stopContext.calendarNotes {
        Section("Calendar booking details") { Text(calendarNotes).textSelection(.enabled) }
      }
    }
  }

  @ViewBuilder private var tripRationaleSection: some View {
    if let tripRationale, !tripRationale.isEmpty {
      Section("On this trip") {
        rationaleRow("Chat’s pick", tripRationale.priorityListLabel)
        rationaleRow("Visit", tripRationale.visit)
        rationaleRow("Why", tripRationale.why)
        rationaleRow("Fit", tripRationale.fit)
        rationaleRow("Note", tripRationale.note)
      }
    }
  }

  @ViewBuilder private func rationaleRow(_ label: String, _ value: String?) -> some View {
    if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
      LabeledContent(label) { Text(value).textSelection(.enabled) }
    }
  }

  @ViewBuilder private func gallerySection(_ dossier: IdeaDossier) -> some View {
    if !dossier.photos.isEmpty {
      Section("Photos") {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(dossier.photos) { photo in
              if let image = UIImage(data: photo.thumbnail) {
                Button { Task { await model.photoTapped(photo) } } label: {
                  Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 100, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder private func hoursSections(_ idea: Idea) -> some View {
    if let hours = idea.openingHours, !hours.isEmpty {
      Section("Hours") {
        Text(hours)
        if let provenance = idea.hoursProvenance { Text(provenance.label).font(.caption).foregroundStyle(.secondary) }
      }
    }
    if let weekly = idea.weeklyHours, weekly.hasAnyAssertion {
      Section("Weekly hours") {
        ForEach(Weekday.allCases, id: \.self) { WeeklyHoursSummaryRow(weekday: $0, day: weekly[$0]) }
      }
    }
  }

  @ViewBuilder private func locationAndReferenceSections(_ idea: Idea) -> some View {
    if let coordinate = idea.coordinate {
      Section {
        StopMap(coordinate: coordinate, name: idea.name).frame(height: 170).listRowInsets(EdgeInsets())
        if let url = mapsURL(for: idea) { Link(destination: url) { Label("Open in Maps", systemImage: Icon.map.systemName) } }
      }
    }
    if let url = URL(string: idea.url), !idea.url.isEmpty {
      Section { Link(destination: url) { Label(url.host() ?? idea.url, systemImage: "link").lineLimit(1) } }
    }
  }

  @ViewBuilder private func tagsAndNotesSections(_ dossier: IdeaDossier) -> some View {
    if !dossier.tagNames.isEmpty {
      Section("Tags") { ForEach(dossier.tagNames, id: \.self) { Label($0, systemImage: Icon.tag.systemName) } }
    }
    if !dossier.idea.notes.isEmpty { Section("Notes") { Text(dossier.idea.notes) } }
  }

  private func identity(_ idea: Idea) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: idea.kind?.systemImage ?? "mappin.and.ellipse")
        .font(.title)
        .foregroundStyle(.tint)
        .frame(width: 40)
      VStack(alignment: .leading, spacing: 4) {
        if let kind = idea.kind {
          Text(kind.label).foregroundStyle(.secondary)
        }
        if let address = idea.address, !address.isEmpty {
          Label(address, systemImage: Icon.location.systemName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else if let regionName = idea.regionName, !regionName.isEmpty {
          Label(regionName, systemImage: Icon.location.systemName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if let phone = idea.phone, !phone.isEmpty {
          if let telURL = telURL(for: phone) {
            Link(destination: telURL) {
              Label(phone, systemImage: "phone").font(.subheadline)
            }
          } else {
            Label(phone, systemImage: "phone")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func telURL(for phone: String) -> URL? {
    let digits = phone.filter { $0.isNumber || $0 == "+" }
    return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
  }

  private func mapsURL(for idea: Idea) -> URL? {
    guard let coordinate = idea.coordinate, var components = URLComponents(string: "https://maps.apple.com/") else { return nil }
    components.queryItems = [
      URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
      URLQueryItem(name: "q", value: idea.name.isEmpty ? "Pinned location" : idea.name),
    ]
    return components.url
  }

  @ViewBuilder private func accoladesSection(_ dossier: IdeaDossier) -> some View {
    if !dossier.accolades.current.isEmpty || !dossier.accolades.historical.isEmpty {
      Section("Accolades") {
        ForEach(dossier.accolades.current) { EvaluationRow(evaluation: $0) }
        if !dossier.accolades.historical.isEmpty {
          DisclosureGroup("Historical") {
            ForEach(dossier.accolades.historical) { EvaluationRow(evaluation: $0) }
          }
        }
      }
    }
  }

  @ViewBuilder private func interestsSection(_ dossier: IdeaDossier) -> some View {
    if !dossier.interests.isEmpty {
      Section {
        ForEach(dossier.interests, id: \.planner.id) { entry in
          if entry.planner.id == UUID(uuidString: model.currentPlannerIDString) {
            InterestMenu(current: entry.level, onSelect: model.setMyInterest) {
              HStack { Text(entry.planner.displayName); Spacer(); InterestView(interest: entry.level) }
            }
          } else {
            HStack { Text(entry.planner.displayName); Spacer(); InterestView(interest: entry.level) }
          }
        }
        if dossier.standing == .match { MatchPill() }
      } header: { Text("Interest") }
    }
  }

  private func notesSection(_ dossier: IdeaDossier) -> some View {
    Section("Taste Notes") {
      ForEach(dossier.notes) { note in
        VStack(alignment: .leading, spacing: 3) {
          Text(note.body).textSelection(.enabled)
          Text("\(note.plannerID.flatMap { id in model.planners.first { $0.id == id }?.displayName } ?? "Both of us") · \(note.notedAt.formatted(date: .abbreviated, time: .omitted))")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let partyID = dossier.idea.travelPartyID {
        TasteNoteAddButton(travelPartyID: partyID, ideaID: dossier.idea.id, planners: model.planners)
      }
    }
  }

  /// Where the stop sits on the itinerary: its day + time, or the dayless bucket.
  @ViewBuilder private func placement(_ context: StopDetailContext) -> some View {
    if context.schedule.dayNumber == nil {
      Label("To Be Scheduled", systemImage: Icon.toBeScheduled.systemName)
    } else {
      LabeledContent("Day", value: context.dayLabel)
      LabeledContent("Time", value: context.schedule.display)
    }
  }
}

private struct TasteNoteAddButton: View {
  let travelPartyID: TravelParty.ID
  let ideaID: Idea.ID
  let planners: [Planner]
  @State private var isPresented = false

  var body: some View {
    Button { isPresented = true } label: { Label("Add Taste Note", systemImage: "plus") }
      .sheet(isPresented: $isPresented) {
        TasteNoteEditorSheet(travelPartyID: travelPartyID, planners: planners, initialIdeaID: ideaID)
      }
  }
}

/// One read-only weekday row of structured hours (ADR-0029): the weekday and its
/// compact status/sittings, with closed/unknown days de-emphasized.
private struct WeeklyHoursSummaryRow: View {
  let weekday: Weekday
  let day: DayHours

  var body: some View {
    HStack {
      Text(weekday.label)
      Spacer()
      Text(day.display)
        .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
    .font(.callout)
  }

  private var isMuted: Bool {
    switch day {
    case .closed, .unknown: true
    case .open: false
    }
  }
}

/// One source evaluation row — source name, native display, staleness/confidence
/// context — shown exactly as the source expressed it (ADR-0015: never normalized).
private struct EvaluationRow: View {
  let evaluation: IdeaEvaluation

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(evaluation.sourceName)
          .font(.subheadline)
          .foregroundStyle(.primary)
        if !contextText.isEmpty {
          Text(contextText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(evaluation.nativeDisplay)
        .font(.subheadline.bold())
        .foregroundStyle(.primary)
    }
    .padding(.vertical, 2)
  }

  /// Compact provenance: guide year or evaluation date + confidence badge when not
  /// official + a staleness note when not current.
  private var contextText: String {
    var parts: [String] = []
    if let year = evaluation.guideYear {
      parts.append(String(year))
    } else if let date = evaluation.evaluationDate {
      parts.append(date.formatted(.dateTime.year()))
    }
    if evaluation.confidence != .official {
      parts.append(evaluation.confidence.label)
    }
    if evaluation.staleness != .current {
      parts.append(evaluation.staleness.label)
    }
    return parts.joined(separator: " · ")
  }
}

/// A static thumbnail map centred on a stop's pin — non-interactive so it reads as
/// a header image and never steals the surrounding list's scroll.
private struct StopMap: View {
  let coordinate: CLLocationCoordinate2D
  let name: String

  var body: some View {
    Map(
      initialPosition: .region(
        MKCoordinateRegion(
          center: coordinate,
          span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
    ) {
      Marker(name.isEmpty ? "Stop" : name, coordinate: coordinate)
    }
    .allowsHitTesting(false)
  }
}
