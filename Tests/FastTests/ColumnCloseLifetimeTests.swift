import AppKit
import QuartzCore
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ColumnCloseLifetimeTests {
    enum Interruption: CaseIterable { case none, removed, paused }

    @Test(arguments: Interruption.allCases)
    func leaveFinishesOnceWithoutRestoringTheRow(_ interruption: Interruption) async throws {
        _ = NSApplication.shared
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 300))
        parent.wantsLayer = true
        let cell = ColumnCell(kind: .tab)
        cell.frame = CGRect(x: 0, y: 0, width: 240, height: 34)
        parent.addSubview(cell)
        let layer = try #require(cell.layer)
        if interruption == .paused { layer.speed = 0 }
        var completions = 0
        cell.leave {
            completions += 1
            cell.removeFromSuperview()
        }
        let fade = try #require(layer.animation(forKey: "column.leave.fade") as? CABasicAnimation)
        let give = try #require(layer.animation(forKey: "column.leave.give") as? CABasicAnimation)
        #expect(fade.duration == 0.11 && give.duration == 0.11)
        #expect((fade.fromValue as? Int) == 1 && (fade.toValue as? Int) == 0)
        let end = try #require(give.toValue as? NSValue).caTransform3DValue
        #expect(abs(end.m11 - 0.96) < 0.001 && abs(end.m22 - 0.96) < 0.001)
        #expect(layer.opacity == 0)
        if interruption == .removed { layer.removeAllAnimations() }
        #expect(layer.opacity == 0, "Dropping an animation cannot expose the old title")
        try await Task.sleep(for: .milliseconds(400))
        #expect(completions == 1)
        #expect(parent.subviews.isEmpty && cell.superview == nil && layer.superlayer == nil)
        layer.speed = 1
        layer.removeAllAnimations()
        try await Task.sleep(for: .milliseconds(100))
        #expect(completions == 1, "A late transaction completion cannot recycle a reused cell")
    }

    @Test func aClosedRowsHostLeavesTheDocumentAndCanBeReused() async throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        browser.lookForMailSignInLink = {}
        let tabs = (0..<40).map { number in
            let tab = Tab()
            tab.restore(url: URL(string: "https://close-row.invalid/\(number)")!, title: "Close row \(number)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.activeID = nil
        let page = ColumnPage(browser: browser, space: browser.spaceID)
        page.frame = CGRect(x: 0, y: 0, width: 240, height: 300)
        let window = NSWindow(contentRect: page.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        defer {
            page.hand.grip.watch(false)
            window.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            browser.dropSpare()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        func sync(_ tabs: [Tab]) {
            let items = tabs.enumerated().map { index, tab in
                ColumnItem(id: tab.id.uuidString, kind: .tab(tab), indent: 0,
                           y: CGFloat(index) * ColumnLayout.step, height: SideBar.row)
            }
            page.live(items, head: [], frame: .init(lead: 0, footRoom: 0, top: 0, foot: false),
                      look: .init(tone: nil, scheme: .light, titleSize: 13, grain: 0))
            page.layoutSubtreeIfNeeded()
        }
        sync(tabs)
        let document = try #require(page.scrollView.documentView)
        let cell = try #require(document.subviews.compactMap { $0 as? ColumnCell }.first { $0.itemID == tabs[1].id.uuidString })
        let layer = try #require(cell.layer)
        layer.speed = 0
        browser.close(tabs[1])
        sync(tabs.filter { $0 !== tabs[1] })
        try #require(layer.animation(forKey: "column.leave.fade") != nil,
                     "The fixture must exercise animated removal, with Reduce Motion off")
        page.scroll(to: 200)
        try await Task.sleep(for: .milliseconds(400))
        #expect(cell.superview == nil && layer.superlayer == nil)
        #expect(!document.subviews.contains { $0 === cell })
        #expect((layer.animationKeys() ?? []).isEmpty)
        #expect(layer.opacity == 1, "Recycling restores the next row's opacity")

        // Fresh rows use the pool, including the detached closing host.
        layer.speed = 1
        page.scroll(to: 700)
        try #require(cell.superview === document && !cell.isHidden)
        try #require(cell.itemID != tabs[1].id.uuidString)
        let reusedID = cell.itemID
        #expect(layer.opacity == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(cell.superview === document && !cell.isHidden && cell.itemID == reusedID)
        #expect(layer.opacity == 1)
    }
}
