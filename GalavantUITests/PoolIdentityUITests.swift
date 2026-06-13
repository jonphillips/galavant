import XCTest

final class PoolIdentityUITests: XCTestCase {
  /// ADR-0008: a device that has synced planners but no local identity should
  /// offer to *pick* an existing planner, not silently create a duplicate.
  @MainActor
  func testSecondDeviceBindsToExistingPlanner() {
    let app = XCUIApplication()
    app.launch()

    // First run on this install: no planners yet, so we capture a name.
    let nameField = app.textFields["Your name"]
    XCTAssert(nameField.waitForExistence(timeout: 5))
    nameField.tap()
    nameField.typeText("Jon")
    app.buttons["Continue"].tap()
    XCTAssert(app.buttons["Add Idea"].waitForExistence(timeout: 5))

    // Simulate a freshly synced second device: the planner row still exists in
    // the (shared) database, but this "device" no longer knows who it is.
    app.terminate()
    app.launchArguments = ["--reset-identity"]
    app.launch()

    // The identity sheet must now offer the existing "Jon" to pick…
    let pickJon = app.descendants(matching: .button)
      .matching(NSPredicate(format: "label CONTAINS %@", "Jon"))
      .firstMatch
    XCTAssert(pickJon.waitForExistence(timeout: 5), "should offer the existing planner to pick")

    // …and there should be no name field demanding a new planner.
    XCTAssertFalse(
      app.textFields["Your name"].exists,
      "a synced device should bind, not re-create"
    )

    pickJon.tap()
    XCTAssert(
      app.buttons["Add Idea"].waitForExistence(timeout: 5),
      "picking an existing planner should bind and dismiss to the list"
    )
  }
}
