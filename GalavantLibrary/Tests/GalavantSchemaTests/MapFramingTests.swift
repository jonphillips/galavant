import Foundation
import GalavantSchema
import Testing

@Suite struct MapFramingTests {
  @Test func emptyInputHasNoBox() {
    #expect(MapFraming.box(for: []) == nil)
  }

  @Test func singlePointCentersWithDefaultSpan() {
    let box = MapFraming.box(for: [(latitude: 55.67, longitude: 12.57)])
    #expect(box?.centerLatitude == 55.67)
    #expect(box?.centerLongitude == 12.57)
    #expect(box?.latitudeDelta == MapFraming.singlePointDelta)
    #expect(box?.longitudeDelta == MapFraming.singlePointDelta)
  }

  @Test func multiplePointsCenterOnTheMidpointAndSpanTheExtent() throws {
    let points = [
      (latitude: 55.6, longitude: 12.5),
      (latitude: 55.8, longitude: 12.7),
    ]
    let box = try #require(MapFraming.box(for: points))
    #expect(box.centerLatitude == 55.7)
    #expect(box.centerLongitude == 12.6)
    // The raw extent is ~0.2 in each axis; padding grows it past that.
    #expect(box.latitudeDelta >= 0.2)
    #expect(box.longitudeDelta >= 0.2)
    #expect(abs(box.latitudeDelta - 0.2 * MapFraming.padding) < 1e-9)
  }

  @Test func allInputPointsFallInsideTheBox() throws {
    let points = [
      (latitude: 55.60, longitude: 12.50),
      (latitude: 55.72, longitude: 12.61),
      (latitude: 55.68, longitude: 12.40),
    ]
    let box = try #require(MapFraming.box(for: points))
    let latHalf = box.latitudeDelta / 2
    let lonHalf = box.longitudeDelta / 2
    for p in points {
      #expect(abs(p.latitude - box.centerLatitude) <= latHalf)
      #expect(abs(p.longitude - box.centerLongitude) <= lonHalf)
    }
  }

  @Test func nearIdenticalPointsAreFlooredToAMinimumSpan() throws {
    let box = try #require(
      MapFraming.box(for: [
        (latitude: 55.670, longitude: 12.570),
        (latitude: 55.670, longitude: 12.570),
      ])
    )
    #expect(box.latitudeDelta == MapFraming.minimumDelta)
    #expect(box.longitudeDelta == MapFraming.minimumDelta)
  }

  // MARK: - reveal (minimal pan)

  /// A 0.1×0.1 box centred at (10, 20): visible lat 9.95…10.05, lon 19.95…20.05.
  private var box: MapFraming.Box {
    MapFraming.Box(centerLatitude: 10, centerLongitude: 20, latitudeDelta: 0.1, longitudeDelta: 0.1)
  }

  @Test func revealNoMoveWhenTargetAlreadyVisible() {
    #expect(MapFraming.reveal(target: (latitude: 10.02, longitude: 19.98), in: box) == nil)
  }

  @Test func revealLeavesTheOnScreenAxisUntouched() throws {
    // Off-screen north, but the longitude is already in view — only latitude moves.
    let panned = try #require(
      MapFraming.reveal(target: (latitude: 10.20, longitude: 20.01), in: box))
    #expect(panned.longitude == 20)  // unchanged
    #expect(panned.latitude > 10)    // panned north
  }

  @Test func revealMovesTheMinimumToLandInsideTheMargin() throws {
    // 0.05 north of the top edge; new center puts the target margin·span below the
    // new top edge: center = target - half + inset = 10.10 - 0.05 + 0.015.
    let panned = try #require(
      MapFraming.reveal(target: (latitude: 10.10, longitude: 20), in: box))
    #expect(abs(panned.latitude - (10.10 - 0.05 + 0.1 * MapFraming.revealMargin)) < 1e-9)
    // The target now sits inside the shifted box.
    #expect(abs(panned.latitude - 10.10) <= 0.05)
  }

  @Test func revealPansBothAxesWhenOffScreenDiagonally() throws {
    let panned = try #require(
      MapFraming.reveal(target: (latitude: 9.80, longitude: 20.20), in: box))
    #expect(panned.latitude < 10)   // panned south
    #expect(panned.longitude > 20)  // panned east
    // Both axes now contain the target within the kept span.
    #expect(abs(panned.latitude - 9.80) <= 0.05)
    #expect(abs(panned.longitude - 20.20) <= 0.05)
  }

  // MARK: - reveal with a bottom inset (iPhone sheet)

  @Test func revealWithoutInsetLeavesALowTargetPut() {
    // 9.97 is geometrically on screen (9.95…10.05): no sheet, no move.
    #expect(MapFraming.reveal(target: (latitude: 9.97, longitude: 20), in: box) == nil)
  }

  @Test func revealLiftsATargetOutFromUnderTheSheet() throws {
    // Same low target, but the sheet covers the bottom 40% (below lat 9.99): it's
    // behind the sheet, so the map must pan north to bring it into the clear.
    let panned = try #require(
      MapFraming.reveal(target: (latitude: 9.97, longitude: 20), in: box, bottomInset: 0.4))
    #expect(panned.latitude < 10)  // panned south → content rises off the sheet
    // It now sits `margin`·span above the usable (sheet-lifted) bottom edge.
    let usableBottom = panned.latitude - 0.05 + 0.1 * 0.4
    #expect(abs(9.97 - (usableBottom + 0.1 * MapFraming.revealMargin)) < 1e-9)
  }

  @Test func revealWithInsetStillIgnoresATargetAboveTheSheet() {
    // A target up in the unobscured top half is unaffected by the bottom inset.
    #expect(
      MapFraming.reveal(target: (latitude: 10.02, longitude: 20), in: box, bottomInset: 0.4)
        == nil)
  }
}
