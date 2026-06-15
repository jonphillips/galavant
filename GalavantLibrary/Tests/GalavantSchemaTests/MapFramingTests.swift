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
}
