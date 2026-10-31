import CustomDump
import Testing

@testable import Galavant

@Suite
struct TripHeaderCollapseTests {
  @Test
  func expandedHeaderCollapsesOnlyPastTheThreshold() {
    expectNoDifference(TripHeaderCollapse.next(collapsed: false, offset: -1), false)
    expectNoDifference(TripHeaderCollapse.next(collapsed: false, offset: 0), false)
    expectNoDifference(TripHeaderCollapse.next(collapsed: false, offset: 20), false)
    expectNoDifference(TripHeaderCollapse.next(collapsed: false, offset: 40), false)
    expectNoDifference(TripHeaderCollapse.next(collapsed: false, offset: 41), true)
  }

  @Test
  func collapsedHeaderExpandsOnlyAtTheTop() {
    expectNoDifference(TripHeaderCollapse.next(collapsed: true, offset: -1), false)
    expectNoDifference(TripHeaderCollapse.next(collapsed: true, offset: 0), false)
    expectNoDifference(TripHeaderCollapse.next(collapsed: true, offset: 20), true)
    expectNoDifference(TripHeaderCollapse.next(collapsed: true, offset: 40), true)
    expectNoDifference(TripHeaderCollapse.next(collapsed: true, offset: 41), true)
  }
}
