import GalavantSchema
import SQLiteData
import SwiftUI

/// The "You"/settings section, surfaced as a top-level destination in the sidebar /
/// tab bar (ADR-0014 slice 4 graduates here from the Ideas toolbar stub). Houses the
/// sync-health surface (ADR/M5-sync), the AI/chat model settings, and travel-party
/// sharing.
///
/// No `NavigationStack` of its own: the `AppContainer` detail column already provides
/// one (nesting another traps the split view — see the iPad nested-stack note).
struct SettingsScreen: View {
  @State private var model = SettingsModel()
  @State private var syncHealth = SyncHealthModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Form {
      // Above Sharing so "am I actually syncing?" is the first thing Settings answers
      // — silent degradation is fine for dev, not for two-person use (M5-sync).
      SyncStatusSection(model: syncHealth)

      AISettingsSections()

      Section {
        Button {
          Task { await model.shareTravelPartyButtonTapped() }
        } label: {
          Icon.travelParty.label("Share Travel Party")
        }
      } header: {
        Text("Travel Party")
      } footer: {
        Text("Invite your travel party to share the same ideas, trips, and ratings over iCloud.")
      }
    }
    .navigationTitle("Settings")
    .sheet(item: $model.sharedRecord) { sharedRecord in
      CloudSharingView(sharedRecord: sharedRecord)
    }
    // Refresh the sync signals on appear, on scene activation (the same hook that
    // drives the pending-change redrain), and on cross-process DB changes.
    .task { await syncHealth.refresh() }
    .task {
      for await _ in DatabaseChange.notifications {
        await syncHealth.refresh()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await syncHealth.refresh() }
    }
    // When a sync cycle finishes (the engine's observable activity flips), re-read the
    // pending count so "Syncing…" clears to "Up to date" as changes drain.
    .onChange(of: syncHealth.isSynchronizing) { _, _ in
      Task { await syncHealth.refresh() }
    }
  }
}
