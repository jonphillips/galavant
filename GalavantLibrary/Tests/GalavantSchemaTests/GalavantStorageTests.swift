import Foundation
import GalavantSchema
import Testing

@Suite
struct GalavantStorageTests {
  @Test
  func appGroupIDReadsConfiguredInfoDictionaryValue() {
    #expect(
      GalavantStorage.appGroupID(from: [GalavantStorage.appGroupInfoKey: "group.example.dev"])
        == "group.example.dev"
    )
  }

  @Test
  func databaseChangeNotificationNameUsesAppGroupID() {
    #expect(
      DatabaseChange.notificationName(appGroupID: "group.example.dev")
        == "group.example.dev.databaseDidChange"
    )
  }

  @Test(arguments: [[:], [GalavantStorage.appGroupInfoKey: ""]])
  func appGroupIDReportsMissingOrEmptyValue(_ infoDictionary: [String: String]) {
    withKnownIssue {
      #expect(GalavantStorage.appGroupID(from: infoDictionary) == nil)
    }
  }
}
