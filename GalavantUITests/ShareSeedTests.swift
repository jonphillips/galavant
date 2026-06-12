import XCTest

final class ShareSeedTests: XCTestCase {
  @MainActor
  func testCreateHouseholdShare() {
    let app = XCUIApplication()
    app.launch()

    app.buttons["Share Household"].tap()
    sleep(25)
  }
}
