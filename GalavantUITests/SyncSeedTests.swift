import XCTest

final class SyncSeedTests: XCTestCase {
  @MainActor
  func testSeedIdeaForSyncProof() {
    let app = XCUIApplication()
    app.launch()

    app.buttons["Add Idea"].tap()
    let nameField = app.textFields["Name"]
    XCTAssert(nameField.waitForExistence(timeout: 5))
    nameField.tap()
    nameField.typeText("Sync Proof Bravo")
    app.buttons["Save"].tap()
    XCTAssert(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", "Sync Proof Bravo"))
        .firstMatch
        .waitForExistence(timeout: 5)
    )

    sleep(20)
  }
}
