import AppKit
import Testing
@testable import Fast

/// How long a tab waits before the timer puts it to sleep, as gentle as
/// Chrome's Memory Saver at its middle setting: four hours, one while saving
/// power, and never a tab you keep coming back to.
struct SleepTimerTests {
    /// A window with `count` hidden pages behind the one on screen, none of
    /// them among the last few used.
    @MainActor private func world(_ count: Int) async throws -> (Browser, [Tab], Tab, () -> Void) {
        let id = UUID(), browser = Browser(windowID: id)
        let hidden = (0..<count).map { browser.open(URL(string: "about:blank#hidden\($0)")!, foreground: true) }
        let front = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        for tab in hidden {
            for _ in 0..<100 where tab.loading { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(!tab.loading)
            #expect(browser.awake(because: tab) == nil)
        }
        browser.recent = []
        let done = {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        return (browser, hidden, front, done)
    }

    @MainActor @Test func halfAnHourOrAQuarterWhileSavingPower() {
        #expect(Browser.usualSleepAfter == 30 * 60)
        #expect(Browser.sleepAfter(set: 0, thrift: false) == 30 * 60)
        #expect(Browser.sleepAfter(set: 0, thrift: true) == 15 * 60)
        // The bench's own wait, shortened by saving power only past a quarter hour.
        #expect(Browser.sleepAfter(set: 60, thrift: false) == 60)
        #expect(Browser.sleepAfter(set: 60, thrift: true) == 60)
        #expect(Browser.sleepAfter(set: 7200, thrift: true) == 15 * 60)
    }

    @MainActor @Test func switchingToATabCountsAVisit() async throws {
        let (browser, hidden, front, done) = try await world(1)
        defer { done() }
        let tab = hidden[0]
        let before = tab.visits
        for _ in 0..<3 {
            browser.activeID = tab.id
            browser.activeID = front.id
        }
        #expect(tab.visits == before + 3)
    }

    @MainActor @Test func aTabComeBackToMoreThanFifteenTimesNeverSleepsOnTheTimer() async throws {
        let (browser, hidden, _, done) = try await world(1)
        defer { done() }
        let tab = hidden[0]
        tab.touch()
        let late = AwakeClock.now + 24 * 3600
        // Opened once and come back to fifteen times: still the timer's.
        tab.visits = 1 + Browser.keepRevisited
        #expect(!tab.revisited)
        #expect(browser.idleTabs(within: Browser.usualSleepAfter, now: late).map(\.id) == [tab.id])
        // The sixteenth time back: never on the timer.
        tab.visits = 2 + Browser.keepRevisited
        #expect(tab.revisited)
        #expect(browser.idleTabs(within: Browser.usualSleepAfter, now: late).isEmpty)
        // Memory out may still take it.
        #expect(browser.relief(now: late)?.id == tab.id)
    }

    @MainActor @Test func memoryOutTakesARevisitedTabAfterTheOthers() async throws {
        let (browser, hidden, front, done) = try await world(3)
        defer { done() }
        // Back and forth with hidden[2]: it is among the last used.
        browser.activeID = hidden[2].id
        browser.activeID = front.id
        for tab in hidden { tab.touch() }
        hidden[0].visits = 20
        hidden[2].visits = 20
        let now = AwakeClock.now + 3600
        // The one nobody comes back to first, the revisited one next, the
        // last used last of all.
        #expect(browser.relief(now: now)?.id == hidden[1].id)
        browser.passedOver = [hidden[1].id]
        #expect(browser.relief(now: now)?.id == hidden[0].id)
        browser.passedOver = [hidden[1].id, hidden[0].id]
        #expect(browser.relief(now: now)?.id == hidden[2].id)
    }
}
