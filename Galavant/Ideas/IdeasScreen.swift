import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI
import SwiftUINavigation

struct IdeasScreen: View {
  @State private var model = IdeasListModel()
  @State private var mode: Mode = .list

  enum Mode: String, CaseIterable {
    case list, map
    var systemImage: String { self == .list ? "list.bullet" : "map" }
  }

  var body: some View {
    Group {
      switch mode {
      case .list:
        ideasList
      case .map:
        PoolMapView(ideas: model.ideas, onSelect: model.ideaTapped)
      }
    }
    .navigationTitle("Ideas")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("View", selection: $mode) {
          ForEach(Mode.allCases, id: \.self) { mode in
            Image(systemName: mode.systemImage).tag(mode)
          }
        }
        .pickerStyle(.segmented)
      }
      ToolbarItem {
        Button {
          Task { await model.shareTravelPartyButtonTapped() }
        } label: {
          Label("Share Travel Party", systemImage: "person.2")
        }
      }
      ToolbarItem {
        Button {
          model.addIdeaButtonTapped()
        } label: {
          Label("Add Idea", systemImage: "plus")
        }
      }
    }
    .task { await model.task() }
    .sheet(item: $model.destination.form, id: \.id) { draft in
      IdeaFormView(draft: draft)
    }
    .sheet(isPresented: Binding($model.destination.nameCapture)) {
      NameCaptureView(onSubmit: model.nameSubmitted)
        .interactiveDismissDisabled()
    }
    .sheet(item: $model.sharedRecord) { sharedRecord in
      CloudSharingView(sharedRecord: sharedRecord)
    }
  }

  private var ideasList: some View {
    List {
      ForEach(model.ideas) { idea in
        IdeaRow(
          idea: idea,
          interests: model.interests(for: idea),
          myInterest: model.myInterest(for: idea),
          onTap: { model.ideaTapped(idea) },
          onSetInterest: { model.setMyInterest($0, for: idea) }
        )
      }
      .onDelete { model.deleteIdeas(at: $0) }
    }
    .overlay {
      if model.ideas.isEmpty {
        ContentUnavailableView(
          "No ideas yet",
          systemImage: "lightbulb",
          description: Text("Tap + to capture your first travel idea.")
        )
      }
    }
  }
}

private struct IdeaRow: View {
  let idea: Idea
  let interests: [(planner: Planner, level: Interest)]
  let myInterest: Interest?
  let onTap: () -> Void
  let onSetInterest: (Interest?) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: idea.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 4) {
        Button(action: onTap) {
          VStack(alignment: .leading, spacing: 2) {
            Text(idea.name)
              .foregroundStyle(.primary)
            if let regionName = idea.regionName, !regionName.isEmpty {
              Text(regionName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
        }
        .buttonStyle(.plain)
        if !interests.isEmpty {
          HStack(spacing: 10) {
            ForEach(interests, id: \.planner.id) { entry in
              HStack(spacing: 3) {
                Text(entry.planner.displayName)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                InterestView(interest: entry.level)
              }
            }
          }
        }
      }
      Spacer()
      InterestMenu(current: myInterest, onSelect: onSetInterest) {
        Image(systemName: myInterest == nil ? "heart" : "heart.fill")
          .foregroundStyle(myInterest == nil ? Color.secondary : Color.red)
      }
    }
    .padding(.vertical, 2)
  }
}

private struct NameCaptureView: View {
  let onSubmit: (String) -> Void
  @State private var name = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Your name", text: $name)
        } header: {
          Text("Who's planning?")
        } footer: {
          Text("Your ratings and notes are labeled with this name so you and your travel party can tell them apart.")
        }
      }
      .navigationTitle("Welcome to Galavant")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Continue") { onSubmit(name) }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
  }
}

#Preview {
  let _ = prepareDependencies {
    try! $0.bootstrapDatabase()
  }
  NavigationStack {
    IdeasScreen()
  }
}
