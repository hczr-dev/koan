import AppKit
import Combine
import SwiftUI
import WebKit

/// A site kept as a panel, as Vivaldi's Web Panels are: its icon in a row
/// over the column's foot (WebPanelStrip), and a click puts the site in the
/// column beside the page, where the chat and extensions' panels open
/// (ChatColumnRoot), signed in with the space's own sign-ins.
struct WebPanel: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String

    var host: String { url.host() ?? url.absoluteString }
    var name: String { title.isEmpty ? host : title }
    var letter: String { String(name.prefix(1)).uppercased() }
}

/// Every window's panels: the list, one for the whole app, kept in
/// web-panels.json, and each window's open pages, made the first time a
/// panel is opened there and kept alive, so a panel opened again is where
/// it was left, until it is removed or its window goes.
@MainActor
final class WebPanels: ObservableObject {
    static let shared = WebPanels()
    /// `Browser.panelExtension` while a web panel is in the column.
    static let marker = "yab.web-panel"

    /// A panel's page in one window.
    @MainActor
    final class Live: Identifiable {
        let id = UUID()
        let panel: UUID
        let tab: Tab
        /// Links it opens go to an ordinary tab of the window, its downloads
        /// to the window's; nothing else from it is offered.
        let events = ChromiumSidePanel.Events()
        weak var browser: Browser?

        init(panel: UUID, tab: Tab, browser: Browser) {
            self.panel = panel
            self.tab = tab
            self.browser = browser
            events.browser = browser
            tab.delegate = events
        }
    }

    @Published private(set) var list: [WebPanel] = []
    @Published private(set) var live: [Live] = []
    private let file: URL?

    init(file: URL? = Store.unitTests ? nil : Store.file("web-panels.json")) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([WebPanel].self, from: data) {
            list = saved
        }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func pages(in browser: Browser) -> [Live] { live.filter { $0.browser === browser } }

    /// The panel in the window's column now, if one is.
    func front(in browser: Browser) -> UUID? {
        guard browser.chatOpen, browser.panelExtension == Self.marker, let id = browser.panelContextID else { return nil }
        return UUID(uuidString: id)
    }

    /// A panel for this address already: the same site and path.
    func panel(for url: URL?) -> WebPanel? {
        guard let url else { return nil }
        return list.first { $0.url.host() == url.host() && $0.url.path == url.path }
    }

    /// The page in front can become a panel: a web page, not one already.
    func canAdd(from browser: Browser) -> Bool {
        guard let url = browser.active?.address, url.scheme == "https" || url.scheme == "http" else { return false }
        return panel(for: url) == nil
    }

    @discardableResult
    func add(_ url: URL, title: String) -> WebPanel? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        if let same = panel(for: url) { return same }
        let panel = WebPanel(url: url, title: title)
        list.append(panel)
        save()
        Favicons.shared.fetch(host: panel.host)
        return panel
    }

    /// The page in front kept as a panel, and opened beside it.
    func addFront(of browser: Browser) {
        guard let tab = browser.active, let url = tab.address, let panel = add(url, title: tab.title) else { return }
        open(panel, in: browser)
    }

    func remove(_ panel: WebPanel) {
        for page in live where page.panel == panel.id {
            if let browser = page.browser, front(in: browser) == panel.id { close(in: browser) }
            page.tab.close()
        }
        live.removeAll { $0.panel == panel.id }
        list.removeAll { $0.id == panel.id }
        save()
    }

    /// One place along the row, -1 to the left, 1 to the right.
    func move(_ panel: WebPanel, by step: Int) {
        guard let at = list.firstIndex(of: panel) else { return }
        let to = at + step
        guard list.indices.contains(to) else { return }
        list.swapAt(at, to)
        save()
    }

    func canMove(_ panel: WebPanel, by step: Int) -> Bool {
        guard let at = list.firstIndex(of: panel) else { return false }
        return list.indices.contains(at + step)
    }

    /// The panel's page in this window, made the first time it is asked for.
    private func page(_ panel: WebPanel, in browser: Browser) -> Live {
        prune()
        if let page = live.first(where: { $0.panel == panel.id && $0.browser === browser }) { return page }
        let tab = Tab(configuration: Web.configuration(store: Spaces.store(for: Spaces.current)), engine: .webKit)
        let page = Live(panel: panel.id, tab: tab, browser: browser)
        tab.page.frame = CGRect(x: 0, y: 0, width: ChatLook.normal, height: 700)
        tab.go(to: panel.url)
        live.append(page)
        return page
    }

    func toggle(_ panel: WebPanel, in browser: Browser) {
        if front(in: browser) == panel.id { close(in: browser) } else { open(panel, in: browser) }
    }

    func open(_ panel: WebPanel, in browser: Browser) {
        let page = page(panel, in: browser)
        browser.panelTabID = nil
        browser.panelContextID = page.panel.uuidString
        browser.panelExtension = Self.marker
        browser.moveChat(open: true)
    }

    /// The column away with the panel in it; the page is kept. The chat is
    /// the column's own again once it has gone, not while it slides out.
    func close(in browser: Browser) {
        guard browser.panelExtension == Self.marker else { return }
        let context = browser.panelContextID
        browser.moveChat(open: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak browser] in
            guard let browser, !browser.chatOpen, browser.panelExtension == Self.marker,
                  browser.panelContextID == context else { return }
            browser.panelExtension = nil
            browser.panelContextID = nil
        }
    }

    func reload(_ panel: WebPanel, in browser: Browser) {
        live.first { $0.panel == panel.id && $0.browser === browser }?.tab.reload()
    }

    /// Where the panel is now, in an ordinary tab of the window.
    func openAsTab(_ panel: WebPanel, in browser: Browser) {
        let page = live.first { $0.panel == panel.id && $0.browser === browser }
        _ = browser.open(page?.tab.address ?? panel.url, foreground: true, atEnd: true)
    }

    private func prune() {
        for page in live where page.browser == nil { page.tab.close() }
        live.removeAll { $0.browser == nil }
    }
}

/// The panels' row, over the column's foot: each site's icon, lit while its
/// panel is open, and a plus for the page in front. Nothing at all with no
/// panels; the first comes from the foot's plus or ⌘T.
struct WebPanelStrip: View {
    let browser: Browser
    @ObservedObject private var panels = WebPanels.shared

    var body: some View {
        if !panels.list.isEmpty {
            HStack(spacing: 2) {
                ForEach(panels.list) { panel in
                    WebPanelButton(browser: browser, panel: panel)
                }
                WebPanelAdd(browser: browser)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SideBar.margin)
            .padding(.bottom, 4)
        }
    }
}

private struct WebPanelButton: View {
    @ObservedObject var browser: Browser
    let panel: WebPanel
    @State private var hovering = false
    @State private var icon: NSImage?
    @Environment(\.tone) private var tone

    private static let side: CGFloat = Door.side + 4

    var body: some View {
        let on = WebPanels.shared.front(in: browser) == panel.id
        Button { WebPanels.shared.toggle(panel, in: browser) } label: {
            Mark(icon: icon, letter: panel.letter, size: 16)
                .frame(width: Self.side, height: Self.side)
                .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .background(
            RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                .fill(on ? Palette.wash(on: tone) : (hovering ? Palette.hover(on: tone) : .clear))
        )
        .onHover { hovering = $0 }
        .keyTip(panel.name)
        .contextMenu {
            Button("Reload") { WebPanels.shared.reload(panel, in: browser) }
            Button("Open in New Tab") { WebPanels.shared.openAsTab(panel, in: browser) }
            Divider()
            Button("Move Left") { WebPanels.shared.move(panel, by: -1) }
                .disabled(!WebPanels.shared.canMove(panel, by: -1))
            Button("Move Right") { WebPanels.shared.move(panel, by: 1) }
                .disabled(!WebPanels.shared.canMove(panel, by: 1))
            Divider()
            Button("Remove Panel") { WebPanels.shared.remove(panel) }
        }
        .accessibilityLabel(panel.name)
        .onAppear {
            icon = Self.icon(panel.host)
            if icon == nil { Favicons.shared.fetch(host: panel.host) }
        }
        .onReceive(Favicons.shared.changes) { host in
            if host == panel.host || host == "www." + panel.host { icon = Self.icon(panel.host) }
        }
    }

    private static func icon(_ host: String) -> NSImage? {
        Favicons.shared.cached(host) ?? Favicons.shared.cached("www." + host)
    }
}

private struct WebPanelAdd: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false
    @Environment(\.tone) private var tone

    var body: some View {
        if WebPanels.shared.canAdd(from: browser) {
            Button { WebPanels.shared.addFront(of: browser) } label: {
                Symbol("plus", size: 11, weight: .medium)
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted(on: tone))
                    .frame(width: Door.side + 4, height: Door.side + 4)
                    .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
            }
            .buttonStyle(Door.Give())
            .focusable(false)
            .background(
                RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                    .fill(hovering ? Palette.hover(on: tone) : .clear)
            )
            .onHover { hovering = $0 }
            .keyTip("Add Page as Panel")
        }
    }
}

/// A web panel in the column: its site and the doors a panel needs, back,
/// reload, out into a tab and away, over its page on the column's card,
/// as an extension's panel stands there (ExtensionSidePanelColumn).
struct WebPanelColumn: View {
    let browser: Browser
    let page: WebPanels.Live
    let width: CGFloat
    @ObservedObject var tab: Tab
    @Environment(\.tabTitleSize) private var titleSize
    private static let inset: CGFloat = 4
    private static var pageCorner: CGFloat { Radius.surface - inset } // design: concentric with the column's own corner, the inset in

    init(browser: Browser, page: WebPanels.Live, width: CGFloat) {
        self.browser = browser
        self.page = page
        self.width = width
        self.tab = page.tab
    }

    private var panel: WebPanel? { WebPanels.shared.list.first { $0.id == page.panel } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Mark(icon: tab.displayIcon, letter: panel?.letter ?? "", size: SideBar.mark)
                    .frame(width: SideBar.mark, height: SideBar.mark)
                    .padding(.trailing, SideBar.markGap - 2) // design: the column's gap from mark to title
                Text(tab.title.isEmpty ? (panel?.name ?? "") : tab.title)
                    .font(.system(size: titleSize, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Door(icon: "chevron.left", help: "Back") { tab.back() }
                    .opacity(tab.canGoBack ? 1 : 0.35)
                    .allowsHitTesting(tab.canGoBack)
                Door(icon: "arrow.clockwise", help: "Reload") { tab.reload() }
                if let panel {
                    Door(icon: "arrow.up.right.square", help: "Open in New Tab") { WebPanels.shared.openAsTab(panel, in: browser) }
                }
                Door(icon: "xmark", help: "Close Panel") { WebPanels.shared.close(in: browser) }
            }
            .padding(.leading, (SideBar.row - SideBar.mark) / 2) // design: the mark's middle half a row in
            .padding(.trailing, 2) // design: the last door's plate a hair in from the card's edge
            .frame(height: SideBar.row)
            .padding([.horizontal, .top], Self.inset)
            WebPanelPage(tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Self.pageCorner, style: .continuous))
                .padding([.horizontal, .bottom], Self.inset)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .background { HUD.plate(Radius.surface, surface: .page) }
        .overlay(alignment: browser.chatLeads ? .trailing : .leading) {
            ChatEdge(browser: browser)
                .offset(x: browser.chatLeads ? Backdrop.inset : -Backdrop.inset)
        }
    }
}

/// The panel's page, the same view each time, moved into this container.
private struct WebPanelPage: NSViewRepresentable {
    let tab: Tab

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ container: NSView, context: Context) {
        guard let view = tab.page as? NSView, view.superview !== container else { return }
        view.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}
