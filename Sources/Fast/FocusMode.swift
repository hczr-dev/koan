import AppKit
import SwiftUI

/// A site Focus kept a tab from, and where the tab was going.
struct FocusBlock: Equatable {
    let site: String
    let url: URL
}

/// Focus: while it is on, a tab going to one of the sites on its list stops
/// at a page of Yab's own instead (FocusBlockedPage), which lets it through
/// for five minutes if asked. Off and on from ⌘T, the View menu, the bar's
/// moon and Settings › Tabs, where the list is kept.
///
/// Locked, it stays on until its time is up: no switch, menu or command
/// turns it off, no site is let through for five minutes, and the list can
/// only grow. Another app can turn it on, lock it and unlock a lock of its
/// own (an app blocker, a script, Shortcuts, the Mac's own Focus), with
/// the same words three ways (`perform`):
///
///     open -g "yab-focus://lock?minutes=50&key=SECRET&by=Opal"
///     open -g "yab-focus://unlock?key=SECRET"
///     the distributed notification "<bundle id>.focus", object "lock?minutes=50"
///     Shortcuts: Turn On, Turn Off, Lock and Unlock Focus in Yab (SystemIntents)
@MainActor
final class FocusMode: ObservableObject {
    static let shared = FocusMode()
    static let onKey = "focus.on"
    static let sitesKey = "focus.sites"
    static let lockUntilKey = "focus.lock.until"
    static let lockByKey = "focus.lock.by"
    static let lockSecretKey = "focus.lock.key"
    /// The Mac's Focus turned it on (FocusControl.filter), so it turns it off.
    static let filterKey = "focus.filter"
    static let defaults = ["youtube.com", "x.com", "twitter.com", "reddit.com", "instagram.com", "facebook.com", "tiktok.com", "twitch.tv"]
    /// No lock outlasts a week, a key's included: the way out of a lock
    /// whose app never came back to end it.
    static let longest: TimeInterval = 7 * 24 * 3600
    /// What the menus offer, in minutes; 0 is until tomorrow morning.
    static let lengths: [(title: String, minutes: Double)] = [
        ("25 Minutes", 25), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240), ("Until Tomorrow", 0),
    ]

    @Published var on: Bool {
        didSet {
            // Locked, it stays on, whatever asked: a switch, a menu, a command.
            if !on, locked {
                on = true
                return
            }
            Store.settings.set(on, forKey: Self.onKey)
            if !on {
                passes = [:]
                Store.settings.removeObject(forKey: Self.filterKey)
            }
        }
    }
    @Published private(set) var sites: [String]
    /// Until when it is locked, while it is.
    @Published private(set) var lockedUntil: Date?
    /// Who locked it: Yab, or the app that asked.
    @Published private(set) var lockedBy: String?
    /// The key an app locked it with, which ends that lock early.
    private var secret: String?
    /// Sites let through for a while, and until when.
    private var passes: [String: Date] = [:]
    private var expiry: Timer?
    private var listener: FocusListener?

    var locked: Bool { (lockedUntil ?? .distantPast) > Date() }

    private init() {
        on = Store.settings.bool(forKey: Self.onKey)
        sites = Store.settings.stringArray(forKey: Self.sitesKey) ?? Self.defaults
        let until = Store.settings.double(forKey: Self.lockUntilKey)
        if until > Date().timeIntervalSince1970 {
            lockedUntil = Date(timeIntervalSince1970: until)
            lockedBy = Store.settings.string(forKey: Self.lockByKey)
            secret = Store.settings.string(forKey: Self.lockSecretKey)
            on = true
            Store.settings.set(true, forKey: Self.onKey)
            scheduleExpiry()
        } else if until > 0 {
            forgetLock()
        }
        if !Store.unitTests { listener = FocusListener() }
    }

    /// The site on the list this address is on, while Focus keeps it away.
    func blocked(_ url: URL) -> String? {
        guard on, let host = url.host()?.lowercased() else { return nil }
        guard let site = sites.first(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        if !locked, let until = passes[site], until > Date() { return nil }
        return site
    }

    func allow(_ site: String, minutes: Double = 5) {
        guard !locked else { return }
        passes[site] = Date().addingTimeInterval(minutes * 60)
    }

    func add(_ text: String) {
        guard let site = AwakeSites.site(from: text), !sites.contains(site) else { return }
        sites.append(site)
        save()
    }

    func remove(_ site: String) {
        guard !locked else { return }
        sites.removeAll { $0 == site }
        save()
    }

    private func save() { Store.settings.set(sites, forKey: Self.sitesKey) }

    // MARK: - on, off and locked

    func turnOn() { on = true }

    /// False, with a beep, while it is locked: it stays on.
    @discardableResult
    func turnOff() -> Bool {
        guard !locked else {
            NSSound.beep()
            return false
        }
        on = false
        return true
    }

    /// Locked for `minutes` (0: until tomorrow at six), or with a key and
    /// no time, until whoever locked it unlocks it with that key, a week at
    /// most. A lock never makes one already running end sooner.
    func lock(minutes: Double?, by owner: String = "Yab", key: String? = nil) {
        let now = Date()
        let end: Date
        if let minutes, minutes > 0 {
            end = now.addingTimeInterval(min(minutes * 60, Self.longest))
        } else if minutes == 0 {
            end = Self.tomorrowMorning(after: now)
        } else {
            end = now.addingTimeInterval(key?.isEmpty == false ? Self.longest : 3600)
        }
        if !on { on = true }
        passes = [:]
        if !locked || end > (lockedUntil ?? now) { lockedUntil = end }
        lockedBy = owner
        if let key, !key.isEmpty { secret = key }
        Store.settings.set(lockedUntil?.timeIntervalSince1970 ?? 0, forKey: Self.lockUntilKey)
        Store.settings.set(owner, forKey: Self.lockByKey)
        if let secret { Store.settings.set(secret, forKey: Self.lockSecretKey) }
        scheduleExpiry()
    }

    /// An app's lock ended before its time with the key it locked with.
    /// Yab's own locks, and a key that doesn't match, end with their time.
    @discardableResult
    func unlock(key: String?) -> Bool {
        guard locked else { return true }
        guard let secret, let key, key == secret else { return false }
        endLock()
        return true
    }

    private func endLock() {
        expiry?.invalidate()
        expiry = nil
        lockedUntil = nil
        lockedBy = nil
        secret = nil
        forgetLock()
    }

    private func forgetLock() {
        for key in [Self.lockUntilKey, Self.lockByKey, Self.lockSecretKey] { Store.settings.removeObject(forKey: key) }
    }

    private func scheduleExpiry() {
        expiry?.invalidate()
        guard let lockedUntil else { return }
        let timer = Timer(fire: lockedUntil.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.locked else { return }
                self.endLock()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    static func tomorrowMorning(after date: Date) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// "until 17:30", or with the day when it isn't today.
    var lockWords: String {
        guard let lockedUntil else { return "" }
        let style: Date.FormatStyle = Calendar.current.isDateInToday(lockedUntil)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return "until " + lockedUntil.formatted(style)
    }

    // MARK: - from other apps

    /// A command from another app: `yab-focus://lock?minutes=50&key=…&by=…`,
    /// or the same without the scheme. on, off, toggle, lock (minutes, key,
    /// by, sites), unlock (key), add (site or sites, comma separated).
    /// True when it did what was asked.
    @discardableResult
    func perform(_ url: URL, from caller: String) -> Bool {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let verb = (url.host() ?? parts?.path ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var items: [String: String] = [:]
        for item in parts?.queryItems ?? [] where items[item.name.lowercased()] == nil {
            items[item.name.lowercased()] = item.value ?? ""
        }
        let listed = (items["sites"] ?? items["site"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        switch verb {
        case "on":
            listed.forEach(add)
            turnOn()
            return true
        case "off":
            return turnOff()
        case "toggle":
            if on { return turnOff() }
            turnOn()
            return true
        case "lock":
            listed.forEach(add)
            let by = items["by"].flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } ?? caller
            lock(minutes: items["minutes"].flatMap(Double.init), by: by, key: items["key"])
            return true
        case "unlock":
            return unlock(key: items["key"])
        case "add":
            listed.forEach(add)
            return !listed.isEmpty
        default:
            return false
        }
    }

    /// The same words, as Shortcuts and the notification hand them over.
    @discardableResult
    func perform(command: String, from caller: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains(":") ? text : "yab-focus://" + text) else { return false }
        return perform(url, from: caller)
    }

    /// The Mac's own Focus with Yab's filter (YabFocusFilter): on, and
    /// locked until that Focus ends if asked, or, as it ends, off again
    /// if it was the one that turned it on.
    func filter(on wanted: Bool, lock locking: Bool) {
        let key = "macos-focus"
        if wanted {
            if !on { Store.settings.set(true, forKey: Self.filterKey) }
            if locking { lock(minutes: nil, by: "Mac Focus", key: key) } else { turnOn() }
        } else {
            unlock(key: key)
            if Store.settings.bool(forKey: Self.filterKey), !locked {
                on = false
            }
        }
    }

    /// The name another app posts to: `dev.serafim.fast.focus`, or this
    /// build's own id, `dev.serafim.fast.dev.focus`.
    nonisolated static var notificationName: Notification.Name {
        Notification.Name((Bundle.main.bundleIdentifier ?? "dev.serafim.fast") + ".focus")
    }
}

/// What Shortcuts calls (SystemIntents.swift): the same as a URL or a
/// notification would do.
enum FocusControl {
    @MainActor static func run(_ command: String) -> Bool {
        FocusMode.shared.perform(command: command, from: "Shortcuts")
    }

    @MainActor static func filter(on: Bool, lock: Bool) {
        FocusMode.shared.filter(on: on, lock: lock)
    }
}

/// Hears `<bundle id>.focus` from any app on this Mac, delivered at once
/// rather than held until Yab is in front, as AppKit would hold it.
private final class FocusListener: NSObject {
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(heard(_:)), name: FocusMode.notificationName, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @objc private func heard(_ note: Notification) {
        let command = note.object as? String ?? ""
        DispatchQueue.main.async {
            MainActor.assumeIsolated { _ = FocusMode.shared.perform(command: command, from: "Another app") }
        }
    }
}

/// What a tab shows in place of a site Focus keeps away: the site, Go Back
/// as the one dark button, five minutes of it, or Focus off; locked, only
/// Go Back, and until when.
struct FocusBlockedPage: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var focus = FocusMode.shared
    let block: FocusBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            shape.fill(Palette.ink.opacity(0.05))
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                .overlay { Symbol(focus.locked ? "lock.fill" : "moon.fill", size: 17).foregroundStyle(Palette.ink) }
                .frame(width: CardFrame.well, height: CardFrame.well)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(block.site) can wait")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(focus.locked
                     ? "Focus is locked \(focus.lockWords)\(focus.lockedBy.map { $0 == "Yab" ? "" : " by " + $0 } ?? "")."
                     : "You're focusing. Sites on your Focus list stay closed until you turn Focus off.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Go Back") { tab.focusBlocked = nil }
                    .buttonStyle(.yab(.primary, .regular))
                if !focus.locked {
                    Button("Open for 5 Minutes") {
                        FocusMode.shared.allow(block.site)
                        tab.focusBlocked = nil
                        tab.go(to: block.url)
                    }
                    .buttonStyle(.yab(.quiet, .regular))
                    Button("Turn Off Focus") {
                        guard FocusMode.shared.turnOff() else { return }
                        tab.focusBlocked = nil
                        tab.go(to: block.url)
                    }
                    .buttonStyle(.yab(.quiet, .regular))
                }
            }
        }
        .frame(width: 440, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }
}

/// The lengths a lock can have, as a menu's buttons.
struct FocusLockMenu: View {
    var body: some View {
        ForEach(FocusMode.lengths, id: \.title) { length in
            Button(length.title) { FocusMode.shared.lock(minutes: length.minutes) }
        }
    }
}

/// Settings › Tabs › Focus: the switch, the lock, and the sites it keeps away.
struct FocusSettings: View {
    @ObservedObject private var focus = FocusMode.shared
    @State private var draft = ""

    var body: some View {
        Section {
            SettingsSwitch("Focus", isOn: Binding(get: { focus.on }, set: { if $0 { focus.turnOn() } else { focus.turnOff() } }))
                .disabled(focus.locked)
                .settingsAnchor("focus")
            HStack {
                Text("Lock Focus")
                Spacer()
                if focus.locked {
                    Text(focus.lockWords)
                        .foregroundStyle(Palette.muted)
                } else {
                    Menu("Lock") { FocusLockMenu() }
                        .fixedSize()
                }
            }
            ForEach(focus.sites, id: \.self) { site in
                HStack {
                    Text(site)
                    Spacer()
                    if !focus.locked {
                        Button { focus.remove(site) } label: {
                            Symbol("minus.circle", size: 13).foregroundStyle(Palette.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(site)")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Add a site", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add") { add() }
                    .settingsButton()
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Blocked while focusing")
                .textCase(nil)
                .settingsAnchor("focus-sites")
        }
    }

    private func add() {
        focus.add(draft)
        draft = ""
    }
}
