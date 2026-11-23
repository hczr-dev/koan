import AppKit
import QuickLookThumbnailing
import SwiftUI

// The column's downloads, as a stack. The button at the column's foot
// doesn't open a list over the window: the files come up out of it, one
// plain row each, in the column's own width, the way a stack opens from the
// Dock. A file is a thing you came for and will take somewhere, so it is
// drawn as one, its own picture (the first page, the photo, a frame of the
// film) and its name, and it can be dragged out to wherever it goes. The
// rows under it hush while it is up; the page isn't touched.
//
// As Arc's does, it comes with the pointer: resting on the button brings
// the cards up, and leaving the button and the cards puts them away. A
// click on the button is for all of them, the downloads place (⇧⌘J), and
// the pointer staying on the button says so beside it, in a tip with its
// keys.
//
// It is a panel of its own over the column, as the Tray is: a download's
// numbers change ten times a second, and in the window's one hosting view
// that would work the whole window out again each time. The strip's button
// and the chip keep the Tray's list (HoardList).

@MainActor
final class HoardStack: NSPanel {
    /// Between the button and the lowest card.
    static let gap: CGFloat = 6
    /// Room round the cards for their shadow, which the panel has to hold.
    /// Under them is the button's own row, which the panel covers.
    static let air = EdgeInsets(top: 24, leading: 24, bottom: 0, trailing: 24)
    /// How long the pointer may be off the button and the cards before
    /// they go, and how long it rests on the button before the tip.
    static let linger: CFTimeInterval = 0.18
    /// How long cards wait for the column going over the page to take them.
    static let waitForColumn: CFTimeInterval = 1
    static let tipAfter: CFTimeInterval = 1.1
    /// The cards fan up together from the button; their ink appears from
    /// bottom to top, 15 ms apart. The pictures keep their size.
    static let rise = Animation.spring(response: 0.18, dampingFraction: 0.88)
    /// The ink's own rise, quicker than the cards', each card's a beat
    /// after they start to move (`inkLag`) and its place's `stagger` on.
    static let inkRise = Animation.spring(response: 0.12, dampingFraction: 0.88)
    static let inkLag: Double = 0.02
    static let stagger: Double = 0.015
    /// The most cards the stack shows at once (`entries`).
    static let most = 4
    // The tab fade trails the lift slightly; its return keeps the quicker
    // curve measured in the reference's closing cycles.
    static let hush = Animation.spring(response: 0.30, dampingFraction: 0.88).delay(0.02)
    static let unhush = Animation.spring(response: 0.25, dampingFraction: 0.88)
    static let card: CGFloat = 56
    /// A file's picture, its curve, and the plate under the pointer: 4
    /// points round the picture, curved concentric with it (Arc's,
    /// measured: 40, ≈5.5, 4, ≈9.5).
    static let picture: CGFloat = 40
    static let pictureCurve = Radius.small
    static let hug: CGFloat = 4
    static let plate = pictureCurve + hug
    static let between: CGFloat = 0
    /// Down and out, each card its place's `stagger` after the one under it.
    static let lowerTime: Double = 0.12
    static let lower = Animation.easeInOut(duration: lowerTime)
    /// The tabs come back once the cards have dropped: as the last one
    /// starts to fade, so two sets of words never overlap.
    static let unhushAfter: Double = lowerTime
    /// The window goes once the highest card has finished dropping, its
    /// stagger and two frames' grace on top, so no card's last frame is cut.
    static let goneAfter: Double = lowerTime + Double(most - 1) * stagger + 2.0 / 60

    /// Up or on its way down, for the cards to go out and come back by.
    final class Phase: ObservableObject {
        @Published var out = false
        /// A fresh opening starts with every row at the button. Departure
        /// is shorter: each visible row drops and fades from its own place.
        var returning = false
        /// The column's width, which the cards take.
        @Published var width: CGFloat = 200
        /// On screen, or on its way off. Put away, the panel holds no
        /// cards: a hidden card would still be worked out with every step
        /// of a download (measured: 2.6% of the main thread at ten steps a
        /// second).
        @Published var live = false
        /// The button, under the cards: how far in from their left edge,
        /// and its size.
        @Published var buttonX: CGFloat = 0
        @Published var button: CGSize = .zero
        /// The pointer has rested on the button: what a click there does.
        @Published var tip = false
        /// Up by itself for one file (Hoard.peek): only its row, by path.
        @Published var only: String?
        var nameFrame: CGRect?
        /// The badge or the file rides into a row: the list goes on its curve.
        var riding = false
    }

    /// Opening is acknowledged by layout, never by a guessed run-loop turn.
    struct Opening {
        private(set) var pending = false
        mutating func begin() { pending = true }
        mutating func cancel() { pending = false }
        mutating func mount(visible: Bool, hasRows: Bool) -> Bool {
            guard pending, visible, hasRows else { return false }
            pending = false
            return true
        }
    }
    private var opening = Opening()
    private var ready: (() -> Void)?
    let phase = Phase()
    /// Bodies worked out, for the bench to see what a download's steps
    /// cost: the stack's, its cards', and the rows' hush in the window.
    static var bodies = 0
    static var cards = 0
    static var hushes = 0
    /// Test runs: the cards' and the tip's frames in the panel (StackMeasure).
    static var measured: [String: CGRect] = [:]
    private weak var hoard: Hoard?
    private let host: StackHost
    private let heightChanged: (CGFloat) -> Void
    private weak var parentWindowRef: NSWindow?
    private var anchor: NSRect = .zero
    private var closed: (() -> Void)?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var leaving = false
    /// Up for the bench: the pointer doesn't put it away.
    private var held = false
    private var pointer: Timer?
    /// The column is out over the page as a card, so it goes when the
    /// pointer leaves it, and takes the cards along (Hoard.columnWent).
    var floating: () -> Bool = { false }
    private var awaySince: CFTimeInterval?
    private var onButtonSince: CFTimeInterval?

    init(hoard: Hoard, loot: Loot, browser: Browser, fits: @escaping () -> Int, heightChanged: @escaping (CGFloat) -> Void) {
        self.hoard = hoard
        self.heightChanged = heightChanged
        host = StackHost(rootView: AnyView(EmptyView()))
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // The cards cast their own: a shadow worked out from the whole
        // panel's pixels would be drawn again with every step.
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        host.rootView = AnyView(
            HoardStackView(hoard: hoard, loot: loot, browser: browser, phase: phase, fits: fits)
                .focusEffectDisabled()
        )
        host.sizingOptions = [.intrinsicContentSize]
        host.resized = { [weak self] in
            guard let self else { return }
            self.fit(hushing: self.phase.out)
            self.rowsMounted()
        }
        contentView = WindowHosting.measured(host)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    /// Up from `anchor`, the button on screen, its cards' left edge on
    /// `left` and as wide as `width`, the column's. `held`: the pointer
    /// leaving doesn't put it away (the bench's pictures).
    func present(over window: NSWindow, from anchor: NSRect, left: CGFloat, width: CGFloat, held: Bool = false, only: String? = nil, ready: @escaping () -> Void = {}, closed: @escaping () -> Void) {
        // Back from going with the column: drawn where it stands again.
        if let carried = contentView?.layer, carried.animation(forKey: Self.withColumn) != nil || !CATransform3DIsIdentity(carried.sublayerTransform) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            carried.removeAnimation(forKey: Self.withColumn)
            carried.sublayerTransform = CATransform3DIdentity
            CATransaction.commit()
            orderOut(nil)
        }
        // Reverse a closing stack from its current presentation. Resetting
        // it to the button here made a quick return of the pointer jump.
        let continuing = isVisible && phase.live && phase.only == only && parentWindowRef === window
        if !continuing {
            hoard?.rowSpot = nil
            phase.returning = false
            phase.out = false
        }
        opening.begin()
        self.ready = ready
        self.anchor = anchor
        self.closed = closed
        self.held = held
        awaySince = nil
        onButtonSince = nil
        phase.tip = false
        phase.only = only
        phase.nameFrame = nil
        phase.buttonX = anchor.minX - left
        phase.button = anchor.size
        appearance = window.effectiveAppearance
        generation += 1
        let generation = generation
        leaving = false
        WindowHosting.attach(self, to: window)
        parentWindowRef = window
        self.left = left
        phase.width = width
        phase.live = true
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        fit()
        host.layoutSubtreeIfNeeded()
        watch()
        alphaValue = 1
        orderFront(nil)
        if !continuing {
            host.displayIfNeeded()
            CATransaction.flush()
        }
        // First mount can still report the EmptyView's size. Both layout
        // and the row reader retry this acknowledgement when rows exist.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.rowsMounted()
        }
    }

    func rowsMounted() {
        guard !leaving, let spot = hoard?.rowSpot,
              spot.panel() === self, spot.icon.width > 0 else { return }
        let size = host.intrinsicContentSize
        guard opening.mount(visible: isVisible && phase.live,
                            hasRows: size.height > Self.air.top + phase.button.height + Self.gap
                                && size.width > 1) else { return }
        fit(hushing: true)
        phase.out = true
        let done = ready
        ready = nil
        done?()
    }

    private var left: CGFloat = 0
    /// The tip held up by the bench, whatever the pointer does.
    private var tipHeld = false

    func holdTip(_ on: Bool) {
        tipHeld = on
        phase.tip = on
    }

    /// Its file's old name to dust (Rename.swift), over the panel.
    func dustName() -> Bool {
        guard isVisible, !leaving, let rect = phase.nameFrame else { return false }
        return Dust.shared.play(rows: [DustRow(rect: rect, start: 0, fold: 0)], host: host, over: host, renaming: true)
    }

    /// Up alone by itself no longer: the pointer has it, or it goes.
    func release() {
        held = false
        awaySince = CACurrentMediaTime() - Self.linger + 0.05
        follow()
        if isVisible, !leaving { phase.only = nil }
    }

    func dismiss() {
        guard isVisible, !leaving else { return }
        opening.cancel()
        ready = nil
        unwatch()
        generation += 1
        let generation = generation
        leaving = true
        let done = closed
        closed = nil
        done?()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            leaving = false
            orderOut(nil)
            phase.live = false
            heightChanged(0)
            return
        }
        phase.returning = true
        phase.out = false
        // Arc keeps the tabs hushed until the last card is fading; bringing
        // them back at the first card's departure overlaps two sets of text.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unhushAfter) { [weak self] in
            guard let self, self.generation == generation, self.leaving else { return }
            self.heightChanged(0)
        }
        // Let every row finish dropping and fading before removing its
        // window. Fading the whole panel cut the old animation short.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.goneAfter) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.leaving = false
            self.orderOut(nil)
            self.phase.live = false
        }
    }

    private static let withColumn = "stack.withColumn"

    /// The column carried past its edge with the cards up: they are its
    /// rows, so they go with it, as far and on its curve, at once. Left to
    /// the pointer they hung over the page, white names on a white page,
    /// for 0.18 s and then fell (recording of 2026-11-01, 23.00.18).
    func leave(by distance: CGFloat, _ slide: CABasicAnimation) {
        guard isVisible, !leaving else { return }
        contentView?.wantsLayer = true
        guard let carried = contentView?.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            dismiss()
            return
        }
        opening.cancel()
        ready = nil
        unwatch()
        generation += 1
        let generation = generation
        leaving = true
        let done = closed
        closed = nil
        done?()
        slide.keyPath = "sublayerTransform.translation.x"
        slide.fromValue = 0
        slide.toValue = distance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.leaving = false
                self.orderOut(nil)
                self.phase.live = false
                self.phase.out = false
                self.phase.returning = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                carried.removeAnimation(forKey: Self.withColumn)
                carried.sublayerTransform = CATransform3DIdentity
                CATransaction.commit()
                self.heightChanged(0)
            }
        }
        carried.setValue(distance, forKeyPath: "sublayerTransform.translation.x")
        carried.add(slide, forKey: Self.withColumn)
        CATransaction.commit()
    }

    /// As tall as the cards ask, its foot the button's, the cards' edges
    /// the column's.
    private func fit(hushing: Bool = false) {
        let size = host.intrinsicContentSize
        guard phase.live, size.width > 1, size.height > 1 else { return }
        let origin = NSPoint(x: left - Self.air.leading, y: anchor.minY)
        let frame = NSRect(origin: origin, size: size)
        // A closing stack's mask is timed by dismiss(), not a layout pass.
        if hushing, !leaving { heightChanged(size.height - Self.air.top) }
        guard frame != self.frame else { return }
        setFrame(frame, display: false)
    }

    /// The pointer off the button and the cards a moment, a press
    /// anywhere else, Escape, the app put away, the window resized: it
    /// goes.
    private func watch() {
        unwatch()
        let presses = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window !== self, !ActionMenu.isOpen(in: self) else { return event }
            let at = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
            if !anchor.contains(at) { dismiss() }
            return event
        }
        // The reference starts closing within one or two display frames
        // of leaving. The panel can cover a pointer that hasn't moved, so
        // tracking the original button alone misses its departure.
        let pointer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(pointer, forMode: .common)
        self.pointer = pointer
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self || event.window === parentWindowRef,
                  event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            dismiss()
            return nil
        }
        let away = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        let resized = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: parentWindowRef, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        monitors = [presses, keys].compactMap { $0 }
        observers = [away, resized]
    }

    /// The files and the button's row under them, across the column, or
    /// the button itself: while the pointer is there, or a button is held
    /// down (a card on its way out of the window), it stays.
    private func follow() {
        guard !opening.pending else { return }
        let at = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        let cards = NSRect(x: frame.minX + Self.air.leading, y: frame.minY,
                           width: frame.width - Self.air.leading - Self.air.trailing, height: frame.height - Self.air.top)
        let onButton = anchor.contains(at)
        if onButton {
            onButtonSince = onButtonSince ?? now
        } else {
            onButtonSince = nil
        }
        let tip = tipHeld || (onButtonSince.map { now - $0 >= Self.tipAfter } ?? false)
        if phase.tip != tip { withAnimation(Motion.quick) { phase.tip = tip } }
        // A file's menu hangs outside the cards. Keep its owner in place
        // while moving into that menu and across close -> action dispatch.
        guard !held, !ActionMenu.isOpen(in: self) else { awaySince = nil; return }
        if onButton || cards.contains(at) || NSEvent.pressedMouseButtons != 0 {
            awaySince = nil
        } else if let since = awaySince {
            // Off the column that is out over the page: it is about to go,
            // and the cards go with it rather than falling on their own
            // first. A column that stays lets them go a little later.
            let column = cards.insetBy(dx: -Self.air.leading, dy: 0)
            if floating(), !(column.minX...column.maxX).contains(at.x), now - since < Self.waitForColumn { return }
            if now - since >= Self.linger { dismiss() }
        } else {
            awaySince = now
        }
    }

    private func unwatch() {
        pointer?.invalidate()
        pointer = nil
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
        monitors = []
        observers = []
    }
}

/// Takes the first click though the panel isn't key, and says when the
/// stack changes height, once a pass.
private final class StackHost: NSHostingView<AnyView> {
    var resized: (() -> Void)?
    private var asked = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !asked else { return }
        asked = true
        DispatchQueue.main.async { [weak self] in
            self?.asked = false
            self?.resized?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - the cards

/// The latest files and transfers, newest nearest the button; as many as
/// stand between the button and the pins, without separate card surfaces.
struct HoardStackView: View {
    @ObservedObject var hoard: Hoard
    @ObservedObject var loot: Loot
    let browser: Browser
    @ObservedObject var phase: HoardStack.Phase
    /// How many cards there is room for.
    let fits: () -> Int

    private enum Item: Identifiable {
        case fetch(Hoard.Fetch)
        case keep(Keep)

        var id: String {
            switch self {
            case .fetch(let fetch): "fetch-\(fetch.id.hashValue)"
            case .keep(let keep): keep.id
            }
        }
    }

    /// A row, with its place counted up from the button.
    private struct Entry: Identifiable {
        let id: String
        let item: Item
        var place = 0
    }

    private var entries: [Entry] {
        let room = max(1, min(HoardStack.most, fits()))
        var items: [(Date, Item)] = hoard.fetches.map { ($0.started, .fetch($0)) }
        items += loot.kept.map { ($0.date, .keep($0)) }
        // Up for one file: that one alone.
        if let only = phase.only, items.contains(where: { $0.1.id == only }) { items = items.filter { $0.1.id == only } }
        // Keep the most recent files, with the newest nearest the button,
        // as in the reference. There are no day headers or card surfaces.
        let shown = Array(items.sorted { $0.0 > $1.0 }.prefix(room).reversed())
        return shown.enumerated().map { index, entry in
            Entry(id: entry.1.id, item: entry.1, place: shown.count - index - 1)
        }
    }

    var body: some View {
        let _ = HoardStack.bodies += 1
        if phase.live { stack } else { Color.clear.frame(width: 1, height: 1) }
    }

    @ViewBuilder private var stack: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: HoardStack.gap) {
            VStack(alignment: .leading, spacing: HoardStack.between) {
                ForEach(entries) { entry in
                    card(entry.item, lowest: entry.place == 0)
                        .modifier(Rise(phase: phase, place: entry.place))
                        // Past the rise: where the row ends up, not where it is.
                        .modifier(HoardRowSpot(hoard: hoard, on: entry.place == 0, inset: 0, side: HoardStack.picture))
                }
            }
            .modifier(StackMeasure(name: "cards"))
            button
        }
        .frame(width: phase.width, alignment: .leading)
        .onHover { if $0 { hoard.hover(.side, true) } }
        .padding(EdgeInsets(top: HoardStack.air.top, leading: HoardStack.air.leading, bottom: HoardStack.air.bottom, trailing: HoardStack.air.trailing))
        .fixedSize(horizontal: false, vertical: true)
        .toned(browser.chorus.tone)
        .animation(Motion.glide, value: entries.map(\.id))
    }

    /// The button's row, under the cards: the button itself, which the
    /// panel covers, so a click there is taken here, and beside it, once
    /// the pointer has rested on it, what that click does. Nothing in the
    /// row widens it past the column: laid out beside the button, the tip
    /// made the row, and so the stack, wider than the column, and the
    /// stack, centered on it, slid off it. With the column on the right,
    /// the button at its far end, the cards stood half over the page and
    /// the tip over the spaces, cut off at the panel's edge (a tester's
    /// picture, 2026-10-12). The tip goes on the side of the button with
    /// the room, toward the column's middle.
    private var button: some View {
        let toRight = phase.buttonX + phase.button.width / 2 <= phase.width / 2
        let step = phase.button.width + 6
        return Color.clear
            .frame(width: phase.button.width, height: phase.button.height)
            .contentShape(Rectangle())
            .onTapGesture { hoard.allDownloads() }
            .overlay(alignment: toRight ? .leading : .trailing) {
                KeyTipView(title: "All Downloads", keys: Keymap.shared.keys(.downloads)?.text)
                    .offset(x: toRight ? step : -step)
                    .modifier(StackMeasure(name: "tip"))
                    .opacity(phase.tip ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .offset(x: phase.buttonX)
            .frame(width: phase.width, height: phase.button.height, alignment: .leading)
    }

    @ViewBuilder private func card(_ item: Item, lowest: Bool) -> some View {
        switch item {
        case .fetch(let fetch):
            FetchCard(hoard: hoard, meter: hoard.meter, fetch: fetch, lowest: lowest)
        case .keep(let keep):
            KeptCard(hoard: hoard, keep: keep, loot: loot, browser: browser, phase: phase, lowest: lowest)
        }
    }

}

/// Where a part of the stack is in its panel, from the panel's top-left,
/// for the bench to hold against the column (`{"do": "files"}`); nothing
/// outside a test run.
struct StackMeasure: ViewModifier {
    let name: String

    @ViewBuilder func body(content: Content) -> some View {
        if Store.testing {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { HoardStack.measured[name] = $0 }
        } else {
            content
        }
    }
}

/// Every row starts at the lowest row's origin beside the button. Geometry
/// fans out together; the ink follows from bottom to top. On departure the
/// rows drop a short distance from their own places, as in the reference.
private struct Rise: ViewModifier {
    @ObservedObject var phase: HoardStack.Phase
    /// Counted up from the button.
    let place: Int

    func body(content: Content) -> some View {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let delay = Double(place) * HoardStack.stagger
        let origin = HoardStack.air.top + CGFloat(place) * (HoardStack.card + HoardStack.between)
        let curve = Hoard.rideCurve
        let riding = Animation.timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: Hoard.ride)
        let departure: CGFloat = place == 0 ? HoardStack.air.top : HoardStack.card
        content
            .compositingGroup()
            .modifier(StackInk(amount: phase.out ? 1 : 0))
            .animation(reduced ? nil : phase.out
                ? (phase.riding ? riding : HoardStack.inkRise.delay(HoardStack.inkLag + delay))
                : HoardStack.lower.delay(delay), value: phase.out)
            .modifier(StackLift(offset: phase.out ? 0 : phase.returning ? departure : origin))
            .animation(reduced ? nil : phase.out
                ? (phase.riding ? riding : HoardStack.rise)
                : HoardStack.lower.delay(delay), value: phase.out)
    }
}

/// The ink has its own clock so the faint upper cards remain in the pile
/// while the column starts to unfold. Contents always lay out immediately.
private struct StackInk: AnimatableModifier {
    var amount: CGFloat

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        let progress = min(1, max(0, amount))
        return content
            .opacity(Double(progress))
            .transaction { $0.animation = nil }
    }
}

/// Animate the actual offset, so reversing a partially open or closing
/// stack continues from its current position even with different endpoints.
private struct StackLift: AnimatableModifier {
    var offset: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(y: max(0, offset))
            .transaction { $0.animation = nil }
    }
}

/// One plain row: the file's picture, its name and a line under it. As
/// Arc's: name and line close together, and under the pointer a plate 4
/// points round the picture, its curve the picture's plus those 4, so the
/// two are concentric. The plate stands out past the column's edge, the
/// picture stays on it, and nothing moves.
private struct Card<Picture: View>: View {
    let title: String
    let detail: String
    var alarm = false
    /// The detail is the site's name Tidy Downloads replaced, struck
    /// through as Arc's card has it.
    var struck = false
    /// Its name just given by Tidy Downloads: in behind the old one's dust.
    var reveal: Date? = nil
    /// Tidy Downloads' name taken back.
    var undo: (() -> Void)? = nil
    /// Under way: a cross at its end, as Arc's row has, that cancels it.
    var cancel: (() -> Void)? = nil
    @ViewBuilder let picture: () -> Picture
    var act: (() -> Void)?
    @State private var hovering = false
    @Environment(\.tone) private var tone

    var body: some View {
        let _ = HoardStack.cards += 1
        HStack(spacing: 12) {
            picture().frame(width: HoardStack.picture, height: HoardStack.picture)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: SidebarTypography.current))
                    .foregroundStyle(Palette.strong(on: tone))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .modifier(RenameReveal(since: reveal, tint: Rename.tint(tone)))
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(alarm ? Color.red.opacity(0.8) : Palette.muted(on: tone))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(struck)
                        .accessibilityLabel(struck ? "Renamed from \(detail)" : detail)
                    if let undo {
                        Button("Undo", action: undo)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.strong(on: tone))
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
            if let cancel {
                FolderCross(close: cancel, label: "Cancel")
            }
        }
        .padding(.trailing, 6)
        .padding(HoardStack.hug)
        .background {
            RoundedRectangle(cornerRadius: HoardStack.plate, style: .continuous)
                .fill(hovering && act != nil ? Palette.hover(on: tone) : .clear)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: HoardStack.plate, style: .continuous))
        .onTapGesture { act?() }
        .onHover { hovering = $0 }
        .padding(.horizontal, -HoardStack.hug)
        .frame(height: HoardStack.card)
    }
}

private struct FetchCard: View {
    @ObservedObject var hoard: Hoard
    /// The numbers, watched here and only here.
    @ObservedObject var meter: Hoard.Meter
    let fetch: Hoard.Fetch
    /// Nearest the button: the row the badge rides into.
    var lowest = false

    var body: some View {
        let step = meter.steps[fetch.id] ?? Hoard.Step()
        Card(
            title: fetch.name,
            detail: fetch.paused || fetch.failed ? HoardList.detail(fetch, step: step) : left(step),
            alarm: fetch.failed && !fetch.paused,
            cancel: fetch.failed ? nil : { hoard.cancel(fetch) }
        ) {
            HoardRowDial(fraction: step.fraction, failed: fetch.failed, unknown: step.fraction == nil && step.got > 0,
                         side: Hoard.dialSide(rowIcon: HoardStack.picture), tone: hoard.browser?.chorus.tone)
                .opacity(lowest && hoard.carrying ? 0 : 1)
        } act: {
            if fetch.failed { hoard.retry(fetch) }
        }
        .steadyMenu(actions: true) {
            if fetch.failed {
                Button(fetch.paused ? "Resume" : "Try Again", mark: fetch.paused ? "play.fill" : "yab.download") { hoard.retry(fetch) }
                Button("Remove", mark: "trash") { hoard.dismiss(fetch) }
            } else {
                // Chrome's word for it, in its downloads' menu.
                if let smart = hoard.smart(fetch) {
                    if smart.status != .resolving { Button("Pause", mark: "pause.fill") { hoard.pauseSmart(fetch) } }
                    Button("Show in Finder", mark: "magnifyingglass") { smart.reveal() }
                }
                Button("Cancel", mark: "xmark") { hoard.cancel(fetch) }
            }
        }
    }

    /// "144 of 452 MB · 2 min": the unit said once, and whole megabytes,
    /// so the line doesn't flicker ten times a second (a gigabyte keeps
    /// one figure after the point). The list's words before the numbers
    /// are known.
    private func left(_ step: Hoard.Step) -> String {
        let said = HoardList.said(fetch, step: step)
        guard step.total > 0, SmartDownloads.shared.live(fetch.id) == nil else { return said }
        let giga = step.total >= 1_000_000_000
        let unit = giga ? 1_000_000_000.0 : 1_000_000.0
        func figure(_ bytes: Int64) -> String {
            let value = Double(bytes) / unit
            return giga ? String(format: "%.1f", value) : String(Int(value.rounded()))
        }
        var line = "\(figure(step.got)) of \(figure(step.total)) \(giga ? "GB" : "MB")"
        if let time = said.components(separatedBy: " · ").dropFirst().first { line += " · " + time }
        return line
    }
}

private struct KeptCard: View {
    @ObservedObject var hoard: Hoard
    let keep: Keep
    let loot: Loot
    let browser: Browser
    /// Up by itself, alone (Hoard.peek): where its name is, for the dust.
    let phase: HoardStack.Phase
    /// Nearest the button: the row the file rides into.
    var lowest = false

    /// Arc's words, in full: "13 minutes ago", not When's "13 min. ago".
    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = When.words
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        let there = keep.stillThere
        let when = abs(keep.date.timeIntervalSinceNow) < 10 ? "just now" : Self.ago.localizedString(for: keep.date, relativeTo: Date())
        // Named by Tidy Downloads today: what it was, and the way back.
        let renamed = keep.was != nil && keep.renamed.map { Calendar.current.isDateInToday($0) } == true
        Card(title: keep.name, detail: !there ? "Moved or deleted" : renamed ? keep.was ?? "" : when, struck: there && renamed,
             reveal: keep.revealing, undo: renamed && there ? { browser.hoard.undoName(keep) } : nil) {
            Thumb(keep: keep)
                .opacity(there ? 1 : 0.4)
                .opacity(lowest && hoard.carrying ? 0 : 1)
                .modifier(HoardFileGrows(keep: keep, hoard: hoard))
        } act: {
            if there { loot.open(keep) }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            // The name's line: after the picture and its gap, its top half.
            guard phase.only == keep.id else { return }
            let x = frame.minX + HoardStack.picture + 12 - 4
            phase.nameFrame = CGRect(x: x, y: frame.minY + 8, width: max(0, frame.maxX - x - 6), height: 22)
        }
        // Taken out of the window, the file itself goes: into the Finder,
        // a message, a canvas.
        .onDrag { there ? NSItemProvider.file(keep.url) : NSItemProvider() }
        .steadyMenu(actions: true) {
            if there {
                Button("Open", mark: "doc") { loot.open(keep) }
                Button("Show in Finder", mark: "yab.folder.search") { loot.reveal(keep) }
                Divider()
                Button("Copy File", mark: "yab.copyframe.doc") {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.writeObjects([keep.url as NSURL])
                }
                Button("Copy Path", mark: "yab.copyframe.folder") {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(keep.path, forType: .string)
                }
                Divider()
            }
            Button("Open Downloads Folder", mark: "yab.folder.down") {
                browser.hoard.openAt = nil
                NSWorkspace.shared.open(browser.currentDownloadFolder)
            }
        }
    }
}

/// One request per file revision, shared by the badge, flight and cards.
@MainActor
final class HoardPictures {
    struct Key: Hashable {
        let url: URL
        let modified: Date?
        init(_ url: URL) {
            self.url = url.standardizedFileURL
            // Not URL resource values: a URL keeps the first ones it read.
            modified = (try? FileManager.default.attributesOfItem(atPath: self.url.path))?[.modificationDate] as? Date
        }
    }
    struct Made {
        let image: NSImage
        let icon: Bool
    }
    static let shared = HoardPictures()
    private var cache: [Key: Made] = [:]
    private var pending: [Key: [(Made) -> Void]] = [:]
    private var framed: [Key: NSImage] = [:]

    func cached(_ url: URL) -> Made? { cache[Key(url)] }

    func load(_ url: URL, done: @escaping (Made) -> Void) {
        let key = Key(url)
        if let made = cache[key] { done(made); return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            done(Made(image: HoardList.icon(named: url.lastPathComponent), icon: true))
            return
        }
        if pending[key] != nil { pending[key]?.append(done); return }
        pending[key] = [done]
        let request = QLThumbnailGenerator.Request(fileAt: url,
            size: CGSize(width: 80, height: 80), scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all)
        Task { @MainActor in
            let best = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let made = best.map { Made(image: $0.nsImage, icon: $0.type == .icon) }
                ?? Made(image: HoardList.icon(named: url.lastPathComponent), icon: true)
            cache[key] = made
            let callbacks = pending.removeValue(forKey: key) ?? []
            callbacks.forEach { $0(made) }
        }
    }

    /// Bake the same square crop and Finder edge for Core Animation layers.
    func image(_ url: URL, done: @escaping (NSImage) -> Void) {
        let key = Key(url)
        if let image = framed[key] { done(image); return }
        load(url) { made in
            if made.icon { done(made.image); return }
            let renderer = ImageRenderer(content: HoardPicture(made: made, side: 80))
            renderer.scale = 2
            let image = renderer.nsImage ?? made.image
            self.framed[key] = image
            done(image)
        }
    }
}

private struct HoardPicture: View {
    let made: HoardPictures.Made
    var side: CGFloat = HoardStack.picture
    var body: some View {
        Group {
            if made.icon {
                Image(nsImage: made.image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: made.image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: HoardStack.pictureCurve * side / HoardStack.picture, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: HoardStack.pictureCurve * side / HoardStack.picture, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 0.5 * side / HoardStack.picture) // design: Finder's file edge, not a floating card plate
                    }
            }
        }.frame(width: side, height: side)
    }
}

struct Thumb: View {
    let keep: Keep
    var side: CGFloat = HoardStack.picture
    @State private var made: (key: HoardPictures.Key, picture: HoardPictures.Made)?
    var body: some View {
        let key = HoardPictures.Key(keep.url)
        Group {
            if let picture = HoardPictures.shared.cached(keep.url) ?? (made?.key == key ? made?.picture : nil) {
                HoardPicture(made: picture, side: side)
            } else if keep.stillThere {
                // A quiet square while Quick Look draws: the kind's icon
                // first and the picture after read as two different files.
                RoundedRectangle(cornerRadius: HoardStack.pictureCurve * side / HoardStack.picture, style: .continuous)
                    .fill(Palette.wash)
                    .frame(width: side, height: side)
            } else {
                HoardPicture(made: .init(image: HoardList.icon(named: keep.name), icon: true), side: side)
            }
        }
        .task(id: key) {
            HoardPictures.shared.load(keep.url) { made = (key, $0) }
        }
    }
}

/// The rows and pins under the stack, hushed while it is up.
struct HoardHush: ViewModifier {
    @ObservedObject var hoard: Hoard

    func body(content: Content) -> some View {
        let _ = HoardStack.hushes += 1
        content
            .mask {
                GeometryReader { geo in
                    let frame = geo.frame(in: .global)
                    // The reference measurements start at the thumbnail,
                    // centered eight points below its 56-point row's top.
                    let top = (hoard.frames[.side]?.maxY ?? frame.maxY) - hoard.stackExtent - frame.minY
                        + (HoardStack.card - HoardStack.picture) / 2
                    StackFade(amount: hoard.stackHeight > 0 ? 1 : 0, top: top, height: frame.height)
                }
            }
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil
                       : (hoard.stackHeight > 0 ? HoardStack.hush : HoardStack.unhush),
                       value: hoard.stackHeight)
    }
}

/// Animate only the fade's progress. Its geometry is already in place on
/// the first opening, just as on later ones after stackExtent is known.
private struct StackFade: View, Animatable {
    var amount: CGFloat
    let top: CGFloat
    let height: CGFloat

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    var body: some View {
        let progress = min(1, max(0, amount))
        // The measured 130-point gradient strengthens as it rises 80 points.
        let start = top - 64 - 80 * progress
        LinearGradient(colors: [.white, .white.opacity(Double(1 - progress))],
                       startPoint: UnitPoint(x: 0.5, y: start / max(1, height)),
                       endPoint: UnitPoint(x: 0.5, y: (start + 130) / max(1, height)))
            .transaction { $0.animation = nil }
    }
}
