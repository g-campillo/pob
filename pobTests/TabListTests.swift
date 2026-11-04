import Foundation
import Testing
@testable import pob

@Suite struct TabListTests {
    func list(_ count: Int) -> (TabList, [UUID]) {
        var list = TabList()
        let records = (0..<count).map { _ in TabRecord() }
        records.forEach { list.add($0, activate: true) }
        list.activate(records[0].id)
        return (list, list.records.map(\.id))
    }

    @Test func newTabsLandRightAfterTheActiveTab() {
        var (list, ids) = list(3)
        let added = TabRecord()
        list.add(added, activate: false)
        #expect(list.records.map(\.id) == [ids[0], added.id, ids[1], ids[2]])
        #expect(list.activeID == ids[0])
    }
    @Test func closingTheActiveTabSelectsTheOneToItsRight() {
        var (list, ids) = list(3)
        list.close(ids[0])
        #expect(list.activeID == ids[1])
    }
    @Test func closingTheLastPositionSelectsTheOneToItsLeft() {
        var (list, ids) = list(3)
        list.activate(ids[2])
        list.close(ids[2])
        #expect(list.activeID == ids[1])
    }
    @Test func closingTheOnlyTabLeavesNothingActive() {
        var (list, ids) = list(1)
        list.close(ids[0])
        #expect(list.records.isEmpty)
        #expect(list.activeID == nil)
    }
    @Test func reopeningRestoresTheNewestClosedTab() {
        var (list, ids) = list(3)
        list.close(ids[1])
        list.close(ids[2])
        let reopened = list.reopenLast()
        #expect(reopened?.id == ids[2])
        #expect(list.activeID == ids[2])
        #expect(list.recentlyClosed.map(\.id) == [ids[1]])
    }
    @Test func recentlyClosedKeepsTwenty() {
        var list = TabList()
        for _ in 0..<25 {
            let record = TabRecord()
            list.add(record, activate: true)
            list.close(record.id)
        }
        #expect(list.recentlyClosed.count == 20)
    }
    @Test func numberShortcutsPickByPositionAndNineMeansLast() {
        var (list, ids) = list(3)
        list.activate(index: 1)
        #expect(list.activeID == ids[1])
        list.activate(index: 8)
        #expect(list.activeID == ids[2])
        list.activate(index: 5)
        #expect(list.activeID == ids[2])
    }
    @Test func nextAndPreviousWrap() {
        var (list, ids) = list(2)
        list.activatePrevious()
        #expect(list.activeID == ids[1])
        list.activateNext()
        #expect(list.activeID == ids[0])
    }
    @Test func movingKeepsTheActiveTab() {
        var (list, ids) = list(3)
        list.move(from: 0, to: 2)
        #expect(list.records.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(list.activeID == ids[0])
    }
    @Test func lifecycleStepsDownAsTabsGoIdle() {
        func next(_ current: TabPhase, active: Bool = false, capturing: Bool = false, idle: TimeInterval = 0, pressure: Bool = false) -> TabPhase {
            TabLifecycle.nextPhase(current: current, isActive: active, isCapturing: capturing, idleSeconds: idle, memoryPressure: pressure)
        }
        #expect(next(.background, active: true) == .active)
        #expect(next(.active) == .background)
        #expect(next(.background, idle: 599) == .background)
        #expect(next(.background, idle: 600) == .suspended)
        #expect(next(.suspended, pressure: true) == .saved)
        #expect(next(.background, pressure: true) == .background)
        #expect(next(.suspended, capturing: true, idle: 9000, pressure: true) == .background)
        #expect(next(.saved) == .saved)
    }
}
