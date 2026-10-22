import Foundation
import Testing
@testable import HoverDict

@Suite struct RelaunchGuardTests {

    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func firstRelaunchIsAllowed() {
        #expect(RelaunchGuard.allow(history: [], now: now) == [now])
    }

    @Test func stopsAfterMaxRelaunchesInWindow() {
        let history = [now.addingTimeInterval(-40), now.addingTimeInterval(-20)]
        #expect(RelaunchGuard.allow(history: history, now: now) == nil)
    }

    @Test func oldRelaunchesAreForgotten() {
        let old = now.addingTimeInterval(-RelaunchGuard.window - 1)
        let recent = now.addingTimeInterval(-20)
        #expect(RelaunchGuard.allow(history: [old, recent], now: now) == [recent, now])
    }

    @Test func futureTimesFromAClockChangeAreDropped() {
        let future = now.addingTimeInterval(3600)
        #expect(RelaunchGuard.allow(history: [future, future], now: now) == [now])
    }
}
