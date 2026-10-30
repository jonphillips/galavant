import GalavantSchema
import Testing

@Suite("iCloud identity readout")
struct ICloudIdentityReadoutTests {
  @Test("matches a participant with the same record name")
  func matchingRecordName() {
    let participant = participant(recordName: "user-1")
    let readout = readout(device: .recordName("user-1"), participants: [participant])

    #expect(readout.matchStatus(for: participant) == .recordName)
    #expect(readout.summary == "This device is in the share as Jon")
  }

  @Test("matches the current user under the owner placeholder")
  func ownerPlaceholder() {
    let participant = participant(
      recordName: ICloudIdentityReadout.ownerPlaceholder,
      isCurrentUser: true
    )
    let readout = readout(device: .recordName("owner-record"), participants: [participant])

    #expect(readout.matchStatus(for: participant) == .ownerPlaceholder)
    #expect(readout.summary == "This device appears only as the owner placeholder")
    #expect(readout.text.contains("Record name: __defaultOwner__"))
    #expect(readout.text.contains("Owner placeholder: yes"))
  }

  @Test("does not match a participant when this device record name is unavailable")
  func unavailableDeviceIdentity() {
    let participant = participant(recordName: "user-1")
    let readout = readout(
      device: .unavailable("Account unavailable"),
      participants: [participant]
    )

    #expect(readout.matchStatus(for: participant) == .noMatch)
    #expect(readout.summary == "This device isn't in the share")
    #expect(readout.text.contains("This device record name: unavailable (Account unavailable)"))
  }

  @Test("reports an unshared travel party")
  func noShare() {
    let readout = ICloudIdentityReadout(
      deviceIdentity: .recordName("user-1"),
      shareSource: .notShared,
      participants: []
    )

    #expect(readout.summary == "The travel party isn't shared")
    #expect(readout.text.contains("Share: not shared"))
  }

  @Test("renders every participant field and placeholders for missing values")
  func participantText() {
    let participant = ICloudIdentityReadout.Participant(
      recordName: nil,
      formattedName: nil,
      lookupInfo: nil,
      role: .participant,
      permission: .readWrite,
      acceptanceStatus: .pending,
      hasICloudAccount: false,
      isCurrentUser: false
    )
    let readout = readout(device: .recordName("user-1"), participants: [participant])

    #expect(readout.text.contains("Name: —"))
    #expect(readout.text.contains("Record name: —"))
    #expect(readout.text.contains("Lookup info: —"))
    #expect(readout.text.contains("Role: participant"))
    #expect(readout.text.contains("Permission: readWrite"))
    #expect(readout.text.contains("Acceptance: pending"))
    #expect(readout.text.contains("Has iCloud account: no"))
    #expect(readout.text.contains("Current user: no"))
  }

  private func participant(
    recordName: String?,
    isCurrentUser: Bool = false
  ) -> ICloudIdentityReadout.Participant {
    ICloudIdentityReadout.Participant(
      recordName: recordName,
      formattedName: "Jon",
      lookupInfo: "jon@example.com",
      role: .owner,
      permission: .readWrite,
      acceptanceStatus: .accepted,
      hasICloudAccount: true,
      isCurrentUser: isCurrentUser
    )
  }

  private func readout(
    device: ICloudIdentityReadout.DeviceIdentity,
    participants: [ICloudIdentityReadout.Participant]
  ) -> ICloudIdentityReadout {
    ICloudIdentityReadout(
      deviceIdentity: device,
      shareSource: .server,
      participants: participants
    )
  }
}
