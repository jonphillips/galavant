import Dependencies
import GalavantSchema
import SQLiteData
import Sharing
import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct TasteNotesView: View {
  let travelPartyID: TravelParty.ID
  @FetchAll(TasteNote.order { $0.notedAt.desc() }) private var allNotes
  @FetchAll(Planner.all) private var planners
  @State private var model = TasteNotesModel()
  @State private var searchText = ""
  @State private var editing: TasteNote?
  @State private var isAdding = false
  @State private var deleting: TasteNote?
  @State private var confirmsDelete = false
  @State private var importReview: TasteNoteImport.Result?
  @State private var importError: String?

  private var notes: [TasteNote] {
    allNotes.filter { note in
      guard note.travelPartyID == travelPartyID else { return false }
      guard !searchText.isEmpty else { return true }
      return note.body.localizedCaseInsensitiveContains(searchText)
        || (note.placeName?.localizedCaseInsensitiveContains(searchText) ?? false)
    }
  }

  var body: some View {
    List {
      if notes.isEmpty {
        ContentUnavailableView(
          searchText.isEmpty ? "No Taste Notes" : "No Matching Notes",
          systemImage: "quote.bubble",
          description: Text(searchText.isEmpty ? "Keep what you learn about places, in your own words." : "Try another search.")
        )
      } else {
        ForEach(notes) { note in
          Button { editing = note } label: {
            VStack(alignment: .leading, spacing: 5) {
              if let placeName = note.placeName, !placeName.isEmpty {
                Text(placeName).font(.headline)
              }
              Text(note.body).foregroundStyle(.primary).lineLimit(4)
              HStack {
                Text(note.notedAt, format: .dateTime.year().month(.abbreviated))
                Text("·")
                Text(note.plannerID.flatMap { id in planners.first { $0.id == id }?.displayName } ?? "Both of us")
                if note.source == .conversation { Text("· Imported") }
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
              deleting = note
              confirmsDelete = true
            }
          }
        }
      }
    }
    .navigationTitle("Taste Notes")
    .searchable(text: $searchText, prompt: "Search notes and places")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { isAdding = true } label: { Label("Add Note", systemImage: "plus") }
      }
      ToolbarItem(placement: .secondaryAction) {
        Menu {
          Button("Copy Prompt") { copyImportPrompt() }
          PasteButton(supportedContentTypes: [.plainText]) { providers in
            Task { await pasteConversation(providers.first) }
          }
        } label: { Label("Import from Conversation", systemImage: "square.and.arrow.down") }
      }
    }
    .sheet(isPresented: $isAdding) {
      TasteNoteEditorSheet(travelPartyID: travelPartyID, planners: planners)
    }
    .sheet(item: $editing) { note in
      TasteNoteEditorSheet(travelPartyID: travelPartyID, planners: planners, existing: note)
    }
    .sheet(isPresented: Binding(
      get: { importReview != nil }, set: { if !$0 { importReview = nil } }
    )) {
      if let importReview { TasteNoteImportReviewView(travelPartyID: travelPartyID, result: importReview) }
    }
    .alert("Couldn’t import notes", isPresented: Binding(
      get: { importError != nil }, set: { if !$0 { importError = nil } }
    )) { Button("OK", role: .cancel) {} } message: { Text(importError ?? "") }
    .confirmationDialog("Delete this taste note?", isPresented: $confirmsDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { deleteNote() }
      Button("Cancel", role: .cancel) { deleting = nil }
    } message: {
      Text("This note will be removed from the shared travel library.")
    }
  }

  private func deleteNote() {
    guard let deleting else { return }
    do { try model.delete(id: deleting.id) }
    catch { importError = error.localizedDescription }
    self.deleting = nil
  }

  private func copyImportPrompt() {
    #if canImport(UIKit)
    UIPasteboard.general.string = TasteNoteImport.prompt
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(TasteNoteImport.prompt, forType: .string)
    #endif
  }

  private func pasteConversation(_ provider: NSItemProvider?) async {
    guard let provider else { return }
    let text = await withCheckedContinuation { continuation in
      provider.loadObject(ofClass: NSString.self) { object, _ in
        continuation.resume(returning: object as? String)
      }
    }
    guard let text else { importError = TasteNoteImportError.malformedJSON.localizedDescription; return }
    do { importReview = try TasteNoteImport.decode(text) }
    catch { importError = error.localizedDescription }
  }
}

private struct TasteNoteImportReviewView: View {
  let travelPartyID: TravelParty.ID
  let result: TasteNoteImport.Result
  @Environment(\.dismiss) private var dismiss
  @FetchAll(TasteNote.all) private var savedNotes
  @FetchAll(Idea.all) private var allIdeas
  @FetchAll(Planner.all) private var allPlanners
  @State private var model = TasteNotesModel()
  @State private var rows: [TasteNoteImport.Row] = []
  @State private var selected: Set<UUID> = []
  @State private var ideaByRow: [UUID: Idea.ID] = [:]
  @State private var whoByRow: [UUID: String] = [:]
  @State private var ambiguous = Set<UUID>()
  @State private var errorMessage: String?

  private var ideas: [Idea] { allIdeas.filter { $0.travelPartyID == travelPartyID } }
  private var planners: [Planner] { allPlanners.filter { $0.travelPartyID == travelPartyID } }

  var body: some View {
    NavigationStack {
      List {
        if !result.warnings.isEmpty {
          Section("Import warnings") { ForEach(result.warnings, id: \.self) { Text($0).font(.caption) } }
        }
        Section {
          Button("Select All") { selected = Set(rows.filter { !isSaved($0) }.map(\.id)) }
          ForEach($rows) { $row in
            HStack(alignment: .top) {
              Button { toggle(row) } label: {
                Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(selected.contains(row.id) ? Color.accentColor : Color.secondary)
                  .padding(.top, 2)
              }
              .buttonStyle(.plain)
              .disabled(isSaved(row))
              VStack(alignment: .leading, spacing: 8) {
                if row.isSummary { Label("Assistant summary", systemImage: "sparkles").font(.caption).foregroundStyle(.orange) }
                TextField("Taste note", text: $row.body, axis: .vertical)
                HStack(spacing: 4) {
                  Text(row.notedAt?.formatted(.dateTime.year().month(.abbreviated)) ?? "Date when saved")
                  Text("· Conversation")
                  if let sourceDetail = row.sourceDetail { Text("· \(sourceDetail)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                  Menu("Whose words: \(displayName(for: whoByRow[row.id, default: row.who]))") {
                    Button("Both of us") { whoByRow[row.id] = "both" }
                    ForEach(planners) { planner in
                      Button(planner.displayName) { whoByRow[row.id] = whoKey(planner) }
                    }
                  }
                  if let place = row.placeName { Text(place).font(.caption).foregroundStyle(.secondary) }
                }
                if ambiguous.contains(row.id) {
                  Picker("Match saved place", selection: $ideaByRow[row.id]) {
                    Text("Keep as typed place").tag(Idea.ID?.none)
                    ForEach(matchingIdeas(for: row)) { idea in Text(idea.name).tag(Idea.ID?.some(idea.id)) }
                  }
                }
                if isSaved(row) { Label("Already saved", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
              }
            }
            .padding(.vertical, 5)
          }
        } header: { Text("Choose the notes to keep") }
        if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
      }
      .navigationTitle("Review Notes")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save \(selected.count)") { saveSelected() }.disabled(selected.isEmpty)
        }
      }
      .task { prepareReview() }
    }
  }

  private func isSaved(_ row: TasteNoteImport.Row) -> Bool {
    savedNotes.contains { $0.travelPartyID == travelPartyID && $0.body == row.body && $0.placeName == row.placeName }
  }

  private func matchingIdeas(for row: TasteNoteImport.Row) -> [Idea] {
    let keys = SeedMatchKeys.make(name: row.placeName, searchHint: row.locality)
    if case let .ambiguous(matches) = SeedPoolMatch.match(keys: keys, locality: row.locality, ideas: ideas) { return matches }
    return []
  }

  private func prepareReview() {
    guard rows.isEmpty else { return }
    rows = result.rows
    for row in rows {
      guard let place = row.placeName else { continue }
      let keys = SeedMatchKeys.make(name: place, searchHint: row.locality)
      switch SeedPoolMatch.match(keys: keys, locality: row.locality, ideas: ideas) {
      case let .idea(idea): ideaByRow[row.id] = idea.id
      case .ambiguous: ambiguous.insert(row.id)
      case .none: break
      }
    }
  }

  private func whoKey(_ planner: Planner) -> String {
    planner.displayName.lowercased().contains("jon") ? "jon" : "wendy"
  }

  private func displayName(for who: String) -> String {
    planners.first { whoKey($0) == who }?.displayName ?? "Both of us"
  }

  private func toggle(_ row: TasteNoteImport.Row) {
    guard !isSaved(row) else { return }
    if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }
  }

  private func saveSelected() {
    do {
      let entries = rows.filter { selected.contains($0.id) }.map { row in
        TasteNoteImportSave(
          row: row,
          plannerID: planners.first { whoKey($0) == whoByRow[row.id, default: row.who] }?.id,
          ideaID: ideaByRow[row.id]
        )
      }
      try model.saveImported(entries, travelPartyID: travelPartyID)
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}

struct TasteNoteEditorSheet: View {
  let travelPartyID: TravelParty.ID
  let planners: [Planner]
  var existing: TasteNote? = nil
  var initialIdeaID: Idea.ID? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var model = TasteNotesModel()
  @FetchAll(Idea.order(by: \.name)) private var ideas
  @Shared(.appStorage("currentPlannerID")) private var currentPlannerIDString = ""
  @State private var bodyText = ""
  @State private var plannerID: Planner.ID?
  @State private var ideaID: Idea.ID?
  @State private var placeName = ""
  @State private var useSavedIdea = false
  @State private var errorMessage: String?

  private var partyPlanners: [Planner] { planners.filter { $0.travelPartyID == travelPartyID } }
  private var partyIdeas: [Idea] { ideas.filter { $0.travelPartyID == travelPartyID } }

  var body: some View {
    NavigationStack {
      Form {
        Section("What do you want to remember?") {
          TextEditor(text: $bodyText).frame(minHeight: 130)
          Picker("Whose words", selection: $plannerID) {
            Text("Both of us").tag(Planner.ID?.none)
            ForEach(partyPlanners) { planner in Text(planner.displayName).tag(Planner.ID?.some(planner.id)) }
          }
        }
        Section("About a place (optional)") {
          Toggle("Link a saved place", isOn: $useSavedIdea)
          if useSavedIdea {
            Picker("Saved place", selection: $ideaID) {
              Text("Choose a place").tag(Idea.ID?.none)
              ForEach(partyIdeas) { idea in Text(idea.name).tag(Idea.ID?.some(idea.id)) }
            }
          } else {
            TextField("Place name", text: $placeName)
              .textInputAutocapitalization(.words)
          }
        }
        if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
      }
      .navigationTitle(existing == nil ? "Add Taste Note" : "Edit Taste Note")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { saveButtonTapped() }
            .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .task { loadDraft() }
  }

  private func loadDraft() {
    guard let existing else {
      bodyText = ""
      ideaID = initialIdeaID
      useSavedIdea = initialIdeaID != nil
      if let currentID = UUID(uuidString: currentPlannerIDString), partyPlanners.contains(where: { $0.id == currentID }) {
        plannerID = currentID
      }
      return
    }
    bodyText = existing.body
    plannerID = existing.plannerID
    ideaID = existing.ideaID
    placeName = existing.placeName ?? ""
    useSavedIdea = existing.ideaID != nil
  }

  private func saveButtonTapped() {
    do {
      try model.save(existing: existing, travelPartyID: travelPartyID, plannerID: plannerID,
        ideaID: useSavedIdea ? ideaID : nil, placeName: useSavedIdea ? nil : placeName,
        body: bodyText, sourceDetail: existing?.sourceDetail)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
