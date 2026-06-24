import SQLiteData
import SwiftUI

/// The "You"/settings section, surfaced as a top-level destination in the sidebar /
/// tab bar (ADR-0014 slice 4 graduates here from the Ideas toolbar stub). Houses the
/// AI/chat model settings and travel-party sharing — the two things that used to
/// crowd the Ideas toolbar.
///
/// No `NavigationStack` of its own: the `AppContainer` detail column already provides
/// one (nesting another traps the split view — see the iPad nested-stack note).
struct SettingsScreen: View {
  @State private var model = SettingsModel()

  var body: some View {
    Form {
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
  }
}
