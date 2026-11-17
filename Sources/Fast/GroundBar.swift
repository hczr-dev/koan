import SwiftUI

/// The address bar on the window's ground beside the column, in the
/// column's ink on the same backdrop, as Zen's toolbar stands over its
/// page: the page a card under it (Browser.barOnGround).
///
/// Folded away (Settings › Appearance › Auto-hide address bar), the page
/// takes its room. While the pointer rests at the page's top the bar comes
/// down from the window's top edge and the page is carried down under it
/// in the same beat (Browser.moveBar, BarSunk), so the bar always stands on
/// the window's own ground, never on a card of its own over the page, and
/// goes back up with the page a moment after the pointer has left.
struct GroundBar: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var peek: BarPeek
    let folded: Bool
    /// The bar's own height.
    let height: CGFloat
    /// The air over it: the card's inset.
    let top: CGFloat
    /// The page's leading inset, so the lights keep their window position.
    let leadingInset: CGFloat
    let tone: Tone?

    private var out: Bool { !folded || peek.out }

    var body: some View {
        ZenBar(browser: browser, tab: tab, height: height, leadingInset: leadingInset)
            .toned(tone)
            .padding(.top, top)
            .frame(maxWidth: .infinity, alignment: .top)
            // Folded and not out: up past the window's top, as far as the
            // page is carried down when it comes.
            .offset(y: out ? 0 : -(height + top))
            .opacity(out ? 1 : 0)
            .allowsHitTesting(out)
            .accessibilityHidden(!out)
    }
}

extension Browser {
    /// The folded address bar out over the page, or back up past the
    /// window's top: the bar on the arriving or departing curve, and the
    /// page carried down under it, or back up, by Core Animation
    /// (Reshape.slide), then offset there (BarSunk), never laid out again,
    /// as the band beside a column on the right carries it (moveHead).
    func moveBar(out: Bool) {
        let peek = barPeek
        guard out != peek.out || out != peek.sunk else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pace: Reshape.Pace = out ? .arrive : .depart
        let window = BrowserWindows.shared.window(for: self)
        // A slide still under way lands first, so the distance is from
        // where the page is now.
        Reshape.slide(in: nil, down: 0, pace: pace) {}
        let down = barFolded ? (out ? peek.sink : 0) - (peek.sunk ? peek.sink : 0) : 0
        withAnimation(reduce ? nil : pace.animation) { peek.out = out }
        var still = Transaction()
        still.disablesAnimations = true
        Reshape.slide(in: window, down: reduce ? 0 : down, pace: pace) {
            withTransaction(still) { peek.sunk = out }
        }
    }
}

/// The toolbar over the page, as Zen draws it: the lights, the column's
/// door and back, forward and reload stand over the column (its head, Side),
/// and over the page one wide field with the whole address, the link's door
/// at its start and the site's controls at its end, then "⋯". While the
/// column is put away the lights, its door and back, forward and reload
/// come here, as Zen's do with its sidebar collapsed.
struct ZenBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var focus = FocusMode.shared
    let height: CGFloat
    /// From the window's leading edge to the bar's.
    var leadingInset: CGFloat = 0
    @Environment(\.tone) private var tone
    @State private var hovering = false

    /// The address as Zen writes it: whole, but for the scheme and a lone
    /// slash, split where its site starts and ends, so the site can be
    /// drawn in ink and the rest quieter, as Firefox formats it.
    private var address: (lead: String, site: String, rest: String) {
        guard let url = tab.address else { return ("", tab.title, "") }
        var text = url.absoluteString
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
            break
        }
        if text.hasSuffix("/"), url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil { text.removeLast() }
        guard let host = url.host(percentEncoded: false), !host.isEmpty, let range = text.range(of: host) else {
            return ("", text, "")
        }
        var lead = String(text[..<range.lowerBound])
        var site = host
        if site.hasPrefix("www."), site.count > 4 {
            lead += "www."
            site.removeFirst(4)
        }
        return (lead, site, String(text[range.upperBound...]))
    }

    var body: some View {
        HStack(spacing: 6) {
            if browser.prefs.sideShut {
                if !browser.fullScreen {
                    Lights()
                        .frame(width: Lights.run, height: height)
                        .padding(.leading, max(0, Lights.first - Lights.lead - leadingInset)) // design: the lights' own place, Lights.first from the window's edge
                }
                ColumnDoor(browser: browser, prefs: browser.prefs)
                Helm(browser: browser, reads: false, still: true)
            }
            field
            if focus.on {
                Door(icon: focus.locked ? "lock.fill" : "moon.fill",
                     help: focus.locked ? "Focus Is Locked" : "Turn Off Focus") { focus.turnOff() }
            }
            Menu {
                AddressMenu(browser: browser, tab: tab)
            } label: {
                Symbol("ellipsis", size: 13, weight: .medium)
                    .foregroundStyle(Palette.muted(on: tone))
                    .frame(width: Door.side, height: Door.side)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .keyTip("More")
        }
        .frame(height: height)
    }

    private var field: some View {
        HStack(spacing: 2) {
            Door(icon: "link", help: "Copy URL", shortcut: "Copy URL") { browser.copyAddress(tab, door: true) }
            Button { browser.pressOpenAddress() } label: {
                let parts = address
                (Text(parts.lead).foregroundStyle(Palette.muted(on: tone))
                 + Text(parts.site).foregroundStyle(Palette.ink)
                 + Text(parts.rest).foregroundStyle(Palette.muted(on: tone)))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            if ReadingDoor.offered(tab) {
                ReadingDoor(browser: browser, tab: tab)
            }
            SiteControlsDoor(browser: browser, tab: tab)
        }
        .padding(.horizontal, 3)
        .frame(height: max(24, height - 4))
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous) // design: Zen's field, a little rounder than a row
                .fill(Palette.ink.opacity(hovering ? 0.08 : 0.055))
        )
        .onHover { hovering = $0 }
    }
}
