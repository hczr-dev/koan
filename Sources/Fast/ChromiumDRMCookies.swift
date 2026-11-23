import CryptoKit
import Foundation
import WebKit
import YabCoreClient

/// Cookie equality excludes Chromium's access timestamps and source port.
/// Partitioned cookies are skipped rather than copied into a different partition.
struct ChromiumDRMCookie: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var expires: Double?
    var sameSite: String?
    var key: String { domain.lowercased() + "\n" + path + "\n" + name }

    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
        expires = cookie.isSessionOnly ? nil : cookie.expiresDate?.timeIntervalSince1970
        let policy = cookie.sameSitePolicy?.rawValue.lowercased()
        sameSite = policy == "strict" ? "Strict" : policy == "lax" ? "Lax" : cookie.isSecure ? "None" : "Lax"
        // CEF uses seconds; avoid a permanent diff from subsecond Foundation dates.
        expires = expires.map { floor($0) }
    }

    init(_ json: JSONValue) throws {
        guard let name = json["name"].string, let value = json["value"].string,
              let domain = json["domain"].string, let path = json["path"].string,
              json["partitionKey"] == .null, json["partitionKeyOpaque"] != .bool(true) else {
            throw YabCoreError.remote("Partitioned or malformed DRM cookie cannot be synchronized")
        }
        self.name = name; self.value = value; self.domain = domain; self.path = path
        secure = json["secure"] == .bool(true); httpOnly = json["httpOnly"] == .bool(true)
        expires = json["session"] == .bool(true) ? nil : json["expires"].number.map { floor($0) }
        sameSite = json["sameSite"].string ?? "Lax"
        if sameSite == "None" && !secure {
            sameSite = "Lax"
            NSLog("DRM cookies: insecure Chromium SameSite=None cookie mapped to Lax")
        }
    }

    static func partitioned(_ cookie: HTTPCookie) -> Bool {
        (cookie.properties ?? [:]).contains { key, value in
            let name = key.rawValue.lowercased()
            return (name.contains("partition") && String(describing: value).lowercased() != "false" && String(describing: value) != "0")
        }
    }

    var webKit: HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { p[.secure] = "TRUE" }
        if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { p[.expires] = Date(timeIntervalSince1970: expires) } else { p[.discard] = "TRUE" }
        // WebKit expresses SameSite=None by omitting the policy.
        if let sameSite, sameSite != "None" { p[.sameSitePolicy] = sameSite.lowercased() }
        return HTTPCookie(properties: p)
    }

    var chromium: JSONValue {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        var p: [String: JSONValue] = ["name": .string(name), "value": .string(value), "path": .string(path),
            "url": .string((secure ? "https://" : "http://") + host + path),
            "secure": .bool(secure), "httpOnly": .bool(httpOnly)]
        // Omitting domain preserves a host-only cookie and __Host- prefixes.
        if domain.hasPrefix(".") { p["domain"] = .string(domain) }
        if let expires { p["expires"] = .number(expires) }
        if let sameSite { p["sameSite"] = .string(sameSite) }
        return .object(p)
    }

    /// Chromium ends a cookie after 400 days at most, so a far date on one
    /// side and its cap on the other are one cookie, not an edit to carry back.
    static func same(_ a: ChromiumDRMCookie?, _ b: ChromiumDRMCookie?, now: Date = Date()) -> Bool {
        guard var a, let b else { return a == nil && b == nil }
        let far = now.timeIntervalSince1970 + 300 * 86_400
        if let first = a.expires, let second = b.expires, first > far, second > far { a.expires = second }
        return a == b
    }

    var deletion: JSONValue { .object(["name": .string(name), "domain": .string(domain), "path": .string(path)]) }
}

/// Reconcile additions, edits and deletions with both previous snapshots.
/// The maps and the ledger are one host's slice (ChromiumCookieBook), never a
/// whole profile. With nothing known yet the existing WebKit sign-in wins a
/// same-key conflict. Afterwards a value that changed on one side goes to the
/// other, and when both changed the engine that used the host last wins: a
/// session cookie a site rotates must never go back to an older value, and
/// sites end a session that shows one (Google does). A cookie Chromium refused
/// is in the ledger on the WebKit side alone, so it is neither tried again nor
/// taken for a Chromium sign-out.
enum ChromiumDRMCookieMerge {
    struct Change { let key: String; let cookie: ChromiumDRMCookie? }
    struct Plan {
        var toWebKit: [Change] = []; var toChromium: [Change] = []
        /// A host whose clearing Chromium still owes: nothing of Chromium's
        /// goes to WebKit, or the account cleared there comes back. Deletions still do.
        func owingClearing() -> Plan { Plan(toWebKit: toWebKit.filter { $0.cookie == nil }, toChromium: toChromium) }
    }
    static func plan(webKit: [String: ChromiumDRMCookie], chromium: [String: ChromiumDRMCookie],
                     previousWebKit: [String: ChromiumDRMCookie], previousChromium: [String: ChromiumDRMCookie]) -> Plan {
        plan(webKit: webKit, chromium: chromium,
             previous: ChromiumSwitchCookieLedger(webKit: ChromiumSwitchCookieLedger.fingerprint(previousWebKit),
                                                  chromium: ChromiumSwitchCookieLedger.fingerprint(previousChromium)))
    }

    static func plan(webKit: [String: ChromiumDRMCookie], chromium: [String: ChromiumDRMCookie],
                     previous: ChromiumSwitchCookieLedger, usedLast: PageEngineKind? = nil, now: Date = Date()) -> Plan {
        typealias Ledger = ChromiumSwitchCookieLedger
        var result = Plan()
        let wHashes = Ledger.fingerprint(webKit), cHashes = Ledger.fingerprint(chromium)
        let keys = Set(webKit.keys).union(chromium.keys).union(previous.webKit.keys).union(previous.chromium.keys)
        for key in keys.sorted() {
            let w = webKit[key], c = chromium[key]
            guard !ChromiumDRMCookie.same(w, c, now: now) else { continue }
            let pw = previous.webKit[key], pc = previous.chromium[key]
            let wChanged = Ledger.whole(wHashes[key]) != Ledger.whole(pw), cChanged = Ledger.whole(cHashes[key]) != Ledger.whole(pc)
            if cChanged, !wChanged { result.toWebKit.append(Change(key: key, cookie: c)); continue }
            if wChanged, !cChanged { result.toChromium.append(Change(key: key, cookie: w)); continue }
            guard wChanged, cChanged else { continue }
            let known = pw != nil || pc != nil
            // Changed on both. A value a side moved away from (deleted it, or
            // signed in to another account) never comes back from the other
            // side, renewed or not: that session has ended.
            var ended = Set<String>()
            if let was = Ledger.value(pw), was != w.map({ Ledger.valuePrint($0.value) }) { ended.insert(was) }
            if let was = Ledger.value(pc), was != c.map({ Ledger.valuePrint($0.value) }) { ended.insert(was) }
            let wEnded = w.map { ended.contains(Ledger.valuePrint($0.value)) } ?? false
            let cEnded = c.map { ended.contains(Ledger.valuePrint($0.value)) } ?? false
            if wEnded != cEnded {
                if wEnded { result.toWebKit.append(Change(key: key, cookie: c)) } else { result.toChromium.append(Change(key: key, cookie: w)) }
                continue
            }
            // One side deleted a value the other no longer holds: what that side
            // holds is a sign-in nobody ended.
            if known, !ended.isEmpty, (w == nil) != (c == nil) {
                if let c { result.toWebKit.append(Change(key: key, cookie: c)) } else { result.toChromium.append(Change(key: key, cookie: w)) }
                continue
            }
            if known && usedLast == .chromium { result.toWebKit.append(Change(key: key, cookie: c)) }
            else { result.toChromium.append(Change(key: key, cookie: w)) }
        }
        return result
    }
}

/// One first import of the WebKit jar, then one host at a time, only when
/// something says that host changed or is about to be used: a WebKit store's
/// change event, or Chromium's navigations, since CEF has no cookie observer.
/// Whole-profile passes took 2.3 s on the main thread on a real profile, held
/// every navigation behind thousands of round trips, and their list came to
/// more than the helper's wire takes.
@MainActor
final class ChromiumDRMCookies: NSObject, WKHTTPCookieStoreObserver {
    private static var sessions: [String: ChromiumDRMCookies] = [:]
    static var hasSessions: Bool { !sessions.isEmpty }
    /// Whether Chromium still owes the clearing of a site this host is on, in
    /// a profile (ChromiumClearingDebt.owes(host:profile:), where it exists).
    static var owesClearing: @MainActor (String, String) -> Bool = { ChromiumClearingDebt.owes(host: $0, profile: $1) }
    /// The first request waits this long for its own host, and the import none.
    private static let shortWait: TimeInterval = 0.75
    /// As long, when the other engine had the host last: what leaves now must
    /// carry what that engine holds, or a site's rotated session is sent old.
    private static let crossingWait: TimeInterval = 5
    /// Chromium doesn't say when a cookie changes, a response to any request
    /// can rotate one, and WebKit says so late. A site open on both engines is
    /// read this often, and every this many passes the hosts of Chromium's pages,
    /// this many of them.
    private static let stepEvery: UInt64 = 3_000_000_000
    private static let stepRound = 5
    private static let stepHosts = 12
    private static let batch = 100
    private static let remembered = 64

    static func synchronizeBeforeQuit() async {
        var seen = Set<ObjectIdentifier>()
        let bridges = Array(sessions.values).filter { seen.insert(ObjectIdentifier($0)).inserted }
        await withTaskGroup(of: Void.self) { group in
            for bridge in bridges {
                group.addTask { @MainActor in
                    do { try await bridge.synchronizeForSwitching() }
                    catch { DebugLog.note("engine-switch-quit", ["error": String(describing: error)]) }
                    try? await bridge.saveNow()
                    bridge.carry?.saveNow()
                }
            }
        }
    }

    /// Counts only, for a probe of a real profile.
    static var statsForTesting: [String: Any] {
        ["bridges": sessions.count, "sessions": sessions.values.map(\.stats)]
    }

    let profile: String
    private let store: WKWebsiteDataStore
    private let privateMode: Bool
    private let storeConflict: Bool
    private let automaticSynchronization: Bool
    private var control: String?
    private var core: YabCoreClient?
    private var book = ChromiumCookieBook()
    private var loaded = false
    private var queue: Task<Void, Error>?
    private var importing: Task<Void, Never>?
    private var importTried = false
    /// The helper is new: the session cookies the ledger names aren't in it.
    private var lostSession = false
    /// Hosts settled while the import runs: its older copy never goes over them.
    private var importSkip = Set<String>()
    private var visited: [String] = []
    private var framed: [String] = []
    private var dirty = Set<String>()
    private var webKitChanged = false
    private var paths: [String: Set<String>] = [:]
    private var settled: [String: (at: Date, engine: PageEngineKind?)] = [:]
    /// The engine each host's last first request was on.
    private var settledBy: [String: PageEngineKind] = [:]
    /// The engine the last first request of any host was on, and the hosts
    /// each engine has used since the one before it crossed over.
    private var activeEngine: PageEngineKind?
    private var usedSince: [PageEngineKind: Set<String>] = [:]
    private var stepping: Task<Void, Never>?
    private var flushing: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var retired = false
    /// localStorage and IndexedDB, for a persistent store: the cookies' fellow.
    private var carry: EngineStorageCarry?
    private var imported = (cookies: 0, refused: 0, partitioned: 0, seconds: 0.0)
    private var reconciles = 0
    private(set) var lastError: String?

    private var stats: [String: Any] {
        ["imported": book.ledger.imported == true, "importing": importing != nil, "importCookies": imported.cookies,
         "importRefused": imported.refused, "partitioned": imported.partitioned, "importSeconds": imported.seconds,
         "known": book.ledger.webKit.count, "reconciles": reconciles, "dirty": dirty.count, "failing": lastError != nil,
         "storageCarried": carry?.moved ?? 0]
    }

    /// A WebKit-default app need not start Chromium until this sign-in profile
    /// has actually used it. Existing contexts must be reconciled before the
    /// first destination request, including immediately after a global restart.
    static func needsPreparation(_ tab: Tab) -> Bool {
        if tab.chromiumDRMEnabled || sessions[tab.chromiumProfile] != nil { return true }
        guard !tab.shy else { return false }
        return FileManager.default.fileExists(atPath: Store.file("Chromium").appendingPathComponent("space-" + tab.chromiumProfile).path)
    }

    static func of(_ tab: Tab) throws -> ChromiumDRMCookies {
        let profile = tab.chromiumProfile
        try ChromiumPrivateProfiles.authorize(profile, store: tab.pageStore, privateMode: tab.shy || !tab.pageStore.isPersistent)
        if let current = sessions[profile], current.holds(tab.pageStore) { return current }
        // A mismatched store never reuses another space's live bridge.
        let key = profile + ":" + String(describing: ObjectIdentifier(tab.pageStore))
        if let current = sessions[key] { return current }
        let made = ChromiumDRMCookies(profile: profile, store: tab.pageStore, privateMode: tab.shy || !tab.pageStore.isPersistent, storeConflict: sessions[profile] != nil)
        if sessions[profile] == nil { sessions[profile] = made } else { sessions[key] = made }
        return made
    }

    private func holds(_ other: WKWebsiteDataStore) -> Bool {
        store === other || (store.isPersistent && store.identifier != nil && store.identifier == other.identifier)
    }

    /// The live bridge of a tab's profile. Hearing of a page never makes one.
    static func session(of tab: Tab?) -> ChromiumDRMCookies? {
        guard let tab, let current = sessions[tab.chromiumProfile], current.holds(tab.pageStore) else { return nil }
        return current
    }

    static func retirePrivate(_ profile: String) {
        for (key, bridge) in sessions where bridge.profile == profile && bridge.privateMode {
            retire(key, bridge)
        }
    }

    static func retireStore(_ identifier: UUID) {
        for (key, bridge) in sessions where bridge.store.identifier == identifier { retire(key, bridge) }
    }
    private static func retire(_ key: String, _ bridge: ChromiumDRMCookies) {
        bridge.retired = true
        bridge.queue?.cancel()
        bridge.importing?.cancel()
        bridge.flushing?.cancel(); bridge.saving?.cancel(); bridge.stepping?.cancel()
        bridge.carry?.retire()
        bridge.store.httpCookieStore.remove(bridge)
        if let core = bridge.core, let id = bridge.control, ChromiumProcess.shared.isCurrent(core) {
            Task { try? await core.closeTab(id) }
        }
        bridge.control = nil; bridge.core = nil
        sessions[key] = nil
    }

    private init(profile: String, store: WKWebsiteDataStore, privateMode: Bool, storeConflict: Bool) {
        self.profile = profile; self.store = store; self.privateMode = privateMode; self.storeConflict = storeConflict
        automaticSynchronization = !(Store.testing && ProcessInfo.processInfo.environment["YAB_SWITCH_COOKIE_SYNC"] == "manual")
        super.init()
        store.httpCookieStore.add(self)
        if !privateMode, store.isPersistent {
            carry = EngineStorageCarry(profile: profile, store: store, holds: { [weak self] in self?.holds($0) ?? false }, connect: { [weak self] in
                guard let self else { throw CancellationError() }
                return (try await self.connection(), self.profile)
            })
        }
    }

    // MARK: - what says a host changed

    /// WebKit says only that something changed, so the hosts its pages are on.
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard automaticSynchronization else { return }
        webKitChanged = true
        flushSoon(after: 2)
    }

    private var webKitHosts: [String] {
        BrowserWindows.shared.browsers.flatMap(\.everyTab).compactMap { tab in
            guard !tab.gone, let page = tab.builtPage, page.engine == .webKit, holds(tab.pageStore) else { return nil }
            return page.url.flatMap(Self.host)
        }
    }

    /// A page is going through this address: a main frame's hop needs looking
    /// at once it lands, a frame's when the engines next hand over.
    func touched(_ url: URL, mainFrame: Bool = true, by engine: PageEngineKind? = nil) {
        guard let host = Self.host(of: url) else { return }
        if !url.path.isEmpty { paths[host, default: []].insert(url.path) }
        if let engine { usedSince[engine, default: []].insert(host) }
        if mainFrame {
            visited.removeAll { $0 == host }; visited.insert(host, at: 0)
            if visited.count > Self.remembered { visited.removeLast() }
            dirty.insert(host)
        } else if !visited.contains(host) {
            framed.removeAll { $0 == host }; framed.insert(host, at: 0)
            if framed.count > Self.remembered { framed.removeLast() }
        }
    }

    /// A document finished: what its hops set is in the jar by now.
    func pageFinished(_ url: URL?) {
        if let url { touched(url) }
        flushSoon(after: 1)
    }

    private func flushSoon(after seconds: TimeInterval) {
        guard automaticSynchronization, flushing == nil, !retired else { return }
        flushing = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard let self, !Task.isCancelled else { return }
            self.flushing = nil
            if self.webKitChanged {
                self.webKitChanged = false
                self.dirty.formUnion(self.webKitHosts)
                self.dirty.formUnion(self.usedSince[.webKit] ?? [])
            }
            let hosts = Array(self.dirty.sorted().prefix(8))
            self.dirty.subtract(hosts)
            for host in hosts { self.serial { [weak self] in try await self?.reconcile(host) } }
            if !self.dirty.isEmpty { self.flushSoon(after: 1) }
        }
    }

    // MARK: - what wants a host now

    /// Before a first request to `url` on `engine`: this host's own cookies,
    /// the rest of the jar being the import's; then what the origin keeps, if
    /// the other engine used it last. A crossing, the other engine having been
    /// the last to use anything, settles every host that engine has used since
    /// the last one: a page reaches hosts by frames, redirects and requests
    /// nothing can hold back, and each must find the newest value here.
    func prepare(for url: URL, in engine: PageEngineKind) async throws {
        guard !retired else { throw CancellationError() }
        guard let host = Self.host(of: url) else { return }
        touched(url, by: engine)
        startImport()
        dirty.remove(host)
        await settle(host, for: engine)
        if retired { throw CancellationError() }
        await carry?.prepare(for: url, in: engine)
        if retired { throw CancellationError() }
    }

    private func settle(_ host: String, for engine: PageEngineKind) async {
        let crossing = activeEngine.map { $0 != engine } ?? false
        let last = settled[host]
        let fresh = last.map { $0.engine == engine && Date().timeIntervalSince($0.at) < 60 } ?? false
        settledBy[host] = engine
        var hosts = fresh && !webKitChanged ? [] : [host]
        if crossing {
            let other: PageEngineKind = engine == .webKit ? .chromium : .webKit
            hosts += (usedSince[other] ?? []).filter { $0 != host }.sorted()
            usedSince[other] = []
        }
        activeEngine = engine
        keepInStep()
        guard !hosts.isEmpty else { return }
        var ending: Task<Void, Error>?
        for one in hosts { ending = serial { [weak self] in try await self?.reconcile(one) } }
        guard let ending else { return }
        await Self.wait(for: ending, seconds: crossing || (last != nil && !fresh) ? Self.crossingWait : Self.shortWait)
    }

    /// A frame about to load on WebKit, whose navigation can wait: it sends
    /// what the jar holds for its host, whoever used that host last.
    func prepareFrame(_ url: URL) async {
        guard !retired, let host = Self.host(of: url) else { return }
        touched(url, mainFrame: false, by: .webKit)
        guard settled[host]?.engine != .webKit || webKitChanged else { return }
        settled[host]?.engine = .webKit
        await Self.wait(for: serial { [weak self] in try await self?.reconcile(host) }, seconds: Self.crossingWait)
    }

    /// Yab's own request with this store's cookies, a live folder's or an
    /// extension's: as much a first request as a page's.
    static func beforeSending(to url: URL, from store: WKWebsiteDataStore) async {
        guard let bridge = sessions.values.first(where: { $0.holds(store) }), let host = Self.host(of: url),
              !bridge.retired else { return }
        bridge.touched(url, mainFrame: false, by: .webKit)
        if let last = bridge.settled[host], last.engine == .webKit, Date().timeIntervalSince(last.at) < 5 { return }
        await Self.wait(for: bridge.serial { [weak bridge] in try await bridge?.reconcile(host) }, seconds: Self.crossingWait)
    }

    /// While Chromium has pages, WebKit's jar follows it: the jar is what Yab's
    /// own requests send, and the next WebKit page's frames and requests.
    private func keepInStep() {
        guard stepping == nil, automaticSynchronization else { return }
        stepping = Task { @MainActor [weak self] in
            var pass = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.stepEvery)
                guard let self, !self.retired else { return }
                let live = self.liveHosts
                guard !live.chromium.isEmpty else { self.stepping = nil; return }
                pass += 1
                var hosts = live.chromium.filter(live.webKit.contains)
                if pass % Self.stepRound == 0 {
                    // In turn: a frame's host, where sign-ins live, gets its go too.
                    let round = pass / Self.stepRound * Self.stepHosts
                    hosts += (0..<min(Self.stepHosts, live.chromium.count)).map { live.chromium[(round + $0) % live.chromium.count] }
                        .filter { !hosts.contains($0) }
                }
                for host in hosts { self.serial { [weak self] in try await self?.reconcile(host) } }
            }
        }
    }

    /// The hosts of each engine's pages: Chromium's the most recently used
    /// first, then the frames they have opened.
    private var liveHosts: (chromium: [String], webKit: Set<String>) {
        var chromium = Set<String>(), webKit = Set<String>()
        for tab in BrowserWindows.shared.browsers.flatMap(\.pagesHeld) {
            guard !tab.gone, let page = tab.builtPage, holds(tab.pageStore), let host = page.url.flatMap(Self.host) else { continue }
            if page.engine == .chromium { chromium.insert(host) } else { webKit.insert(host) }
        }
        var hosts = visited.filter(chromium.contains) + chromium.subtracting(visited).sorted()
        if !hosts.isEmpty { hosts += framed.filter { !hosts.contains($0) } }
        return (hosts, webKit)
    }

    /// A native request is about to read the jar for `url`, for a boost's tool
    /// or a userscript: what the page set a moment ago is in it by then.
    func current(for url: URL) async {
        guard !retired, let host = Self.host(of: url) else { return }
        touched(url)
        dirty.remove(host)
        await Self.wait(for: serial { [weak self] in try await self?.reconcile(host) }, seconds: Self.shortWait)
    }

    /// An engine hands over, or the app quits: every host this run has used.
    func synchronizeForSwitching() async throws {
        startImport()
        try await synchronize()
    }

    func synchronize() async throws {
        var hosts: [String] = []
        for host in visited + framed where !hosts.contains(host) { hosts.append(host) }
        dirty.subtract(hosts)
        guard !hosts.isEmpty else { try await serial { [weak self] in try await self?.load() }.value; return }
        var last: Task<Void, Error>?
        var failure: Error?
        for host in hosts { last = serial { [weak self] in try await self?.reconcile(host) } }
        // Each waits for the one before; the last one's end is everyone's.
        do { try await last?.value } catch { failure = error }
        if let failure { throw failure }
    }

    func include(_ url: URL) { touched(url) }

    private static func host(of url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// One at a time: a host's two reads and their writes are one step.
    @discardableResult
    private func serial(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        let previous = queue
        let task = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, !self.retired, !Task.isCancelled else { throw CancellationError() }
            do { try await operation(); self.lastError = nil }
            catch { self.lastError = String(describing: error); throw error }
        }
        queue = task
        return task
    }

    private final class Latch {
        var continuation: CheckedContinuation<Void, Never>?
        func open() { continuation?.resume(); continuation = nil }
    }

    static func wait(for task: Task<Void, Error>, seconds: TimeInterval) async {
        let latch = Latch()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            latch.continuation = continuation
            Task { @MainActor in _ = await task.result; latch.open() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                latch.open()
            }
        }
    }

    // MARK: - the two jars

    /// The helper with this profile open, in turn with the jars.
    private func connection() async throws -> YabCoreClient {
        var found: YabCoreClient?
        try await serial { [weak self] in found = try await self?.endpoint().0 }.value
        guard let found else { throw CancellationError() }
        return found
    }

    private func endpoint() async throws -> (YabCoreClient, String) {
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        try ChromiumPrivateProfiles.authorize(profile, store: store, privateMode: privateMode)
        let current = try await ChromiumProcess.shared.connection()
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        if let core, core === current, let control {
            if lostSession, loaded {
                lostSession = false
                await putBack(core, control)
            }
            return (core, control)
        }
        // A new helper has what reached the profile's disk: its session
        // cookies too (persist_session_cookies), less the last few seconds'
        // after a crash. WebKit's agreed copies go back at once, below.
        if core != nil { lostSession = true; settled = [:]; importTried = false }
        core = current
        try await ChromiumPrivateProfiles.open(profile, privateMode: privateMode, core: current)
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        let id = try await current.createTab(profile: profile)
        guard !retired, !Task.isCancelled else {
            try? await current.closeTab(id)
            throw CancellationError()
        }
        control = id
        _ = try await current.request("tab.visible", params: ["tab": .string(id), "visible": .bool(false)])
        if lostSession, loaded {
            lostSession = false
            await putBack(current, id)
        }
        return (current, id)
    }

    /// The session cookies a new helper lost, back from WebKit before any
    /// host is read, so the ledger stays true. Forgetting them instead left
    /// every one unknown until its host was read again: a sign-out Chromium
    /// made meanwhile (a provider's logout hop) looked like a cookie never
    /// seen, and the bootstrap rule wrote WebKit's copy of the ended session
    /// back, or WebKit's stale state cookie over a sign-in's fresh one.
    private func putBack(_ core: YabCoreClient, _ id: String) async {
        guard !(book.ledger.session ?? []).isEmpty else { return }
        let began = Date()
        let all = await store.httpCookieStore.allCookies()
        let book = book
        let (back, forget) = await Task.detached(priority: .userInitiated) { book.lostWithHelper(ChromiumCookieImportRow.rows(all)) }.value
        self.book.forget(forget)
        var refused = 0
        do {
            var at = 0
            while at < back.count {
                let part = Array(back[at..<min(at + Self.batch, back.count)])
                at += part.count
                let answer = try await core.request("drm.cookies.setBatch", params: ["tab": .string(id), "cookies": .array(part.map(\.payload))], timeout: 30)
                guard case .array(let results) = answer["results"], results.count == part.count else { throw YabCoreError.remote("Missing cookie batch results") }
                for (row, result) in zip(part, results) where result != .bool(true) { self.book.refused(row.cookie.key); refused += 1 }
            }
        } catch {
            // Not put back: unknown again, so WebKit's copies go over host by
            // host as before, rather than their absence reading as sign-outs.
            self.book.forget(book.ledger.session ?? [])
            NSLog("Cookie bridge: session cookies not put back in a new helper: %@", String(describing: type(of: error)))
            return
        }
        NSLog("Cookie bridge: %d session cookies put back in a new helper in %.2f s, %d refused, %d forgotten",
              back.count - refused, Date().timeIntervalSince(began), refused, forget.count)
        saveSoon()
    }

    private var ledgerFile: URL? {
        guard !privateMode, store.isPersistent else { return nil }
        return ChromiumSwitchCookieLedger.file(profile: profile, store: store.identifier)
    }

    private func load() async throws {
        guard !loaded else { return }
        guard !storeConflict else { throw YabCoreError.remote("DRM cookie store does not match its Chromium space") }
        // The jar isn't whole until launch has put the session cookies back
        // (KeptCookies): a first Chromium page would take their absence for
        // the truth, and a sign-in held in one would stay behind for good.
        let store = store
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            LastingSignIns.whenReady(store) { done.resume() }
        }
        if Store.testing, !privateMode, !automaticSynchronization, store.identifier != Store.probeStore(1) {
            throw YabCoreError.remote("Switch fixture requires its isolated WebKit store")
        }
        if let file = ledgerFile, FileManager.default.fileExists(atPath: file.path) {
            let read = await Task.detached(priority: .userInitiated) { () -> ChromiumSwitchCookieLedger? in
                try? JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: Data(contentsOf: file))
            }.value
            if let read {
                // This launch's helper never held the last one's session
                // cookies: they go back from WebKit before anything is read.
                book = ChromiumCookieBook(ledger: read)
                lostSession = true
            } else { Store.quarantine(file) }
        }
        loaded = true
    }

    /// Reads one host's cookies from both jars and settles them. Only what
    /// that host's addresses can see is compared, so nothing outside the read
    /// looks deleted.
    private func reconcile(_ host: String) async throws {
        try await load()
        let (core, id) = try await endpoint()
        let scope = book.scope(host: host, seen: paths[host] ?? [])
        importSkip.insert(host)
        var chromium = try await readChromium(core, id, scope)
        var webKit = await readWebKit(scope)
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        var plan = ChromiumDRMCookieMerge.plan(webKit: webKit, chromium: chromium, previous: book.slice(scope),
                                               usedLast: settledBy[host] ?? activeEngine)
        if Self.owesClearing(host, profile) { plan = plan.owingClearing() }
        let wrote = Set((plan.toWebKit + plan.toChromium).map(\.key))
        if !wrote.isEmpty { Self.log(host, plan) }
        var endedSession = false
        for change in plan.toWebKit {
            guard !retired, !Task.isCancelled else { throw CancellationError() }
            if let cookie = change.cookie {
                guard let made = cookie.webKit else { continue }
                await store.httpCookieStore.setCookie(made)
                webKit[change.key] = cookie
            } else if let held = webKit[change.key], let old = held.webKit {
                await store.httpCookieStore.deleteCookie(old)
                webKit[change.key] = nil
                if held.expires == nil { endedSession = true }
            }
        }
        for change in plan.toChromium {
            guard !retired, !Task.isCancelled else { throw CancellationError() }
            guard let cookie = change.cookie ?? chromium[change.key] else { continue }
            do {
                _ = try await core.request(change.cookie == nil ? "drm.cookies.delete" : "drm.cookies.set",
                    params: ["tab": .string(id), "cookie": change.cookie == nil ? cookie.deletion : cookie.chromium])
                chromium[change.key] = change.cookie
            } catch YabCoreError.remote {
                // One cookie Chromium refuses must not cost the page: the
                // ledger keeps what Chromium really holds, so it stays skipped.
                NSLog("DRM cookies: skipped one Chromium refused")
            }
        }
        if !wrote.isEmpty, !retired {
            // The ledger holds what each jar took, not what was sent: a write a
            // jar dropped, taken for the jar's own edit, would carry the old
            // value back next pass. Only the keys written are read again; a
            // page's change to another meanwhile stays a change.
            let nowChromium = try await readChromium(core, id, scope), nowWebKit = await readWebKit(scope)
            for key in wrote { chromium[key] = nowChromium[key]; webKit[key] = nowWebKit[key] }
        }
        // A session cookie WebKit no longer holds must not come back from the
        // keychain after a crash: the kept copy follows now, not half a minute on.
        if endedSession { KeptCookies.keepSoon() }
        book.record(scope, webKit: webKit, chromium: chromium)
        settled[host] = (Date(), settledBy[host])
        reconciles += 1
        saveSoon()
    }

    /// What a pass carried, by count: never a value. Test and dev runs name the cookies too.
    private static func log(_ host: String, _ plan: ChromiumDRMCookieMerge.Plan) {
        func counts(_ changes: [ChromiumDRMCookieMerge.Change]) -> String {
            let set = changes.filter { $0.cookie != nil }.count
            var said = "set \(set), deleted \(changes.count - set)"
            if Store.testing || Store.development {
                let names = changes.map { ($0.cookie == nil ? "-" : "+") + ($0.key.split(separator: "\n").last.map(String.init) ?? "") }
                said += " [" + names.prefix(12).joined(separator: " ") + "]"
            }
            return said
        }
        NSLog("Cookie bridge: %@ to WebKit %@; to Chromium %@", host, counts(plan.toWebKit), counts(plan.toChromium))
    }

    private func readChromium(_ core: YabCoreClient, _ id: String, _ scope: ChromiumCookieScope) async throws -> [String: ChromiumDRMCookie] {
        let answer = try await core.request("drm.cookies.get", params: ["tab": .string(id), "urls": .array(scope.urls.map { .string($0.absoluteString) })])
        guard case .array(let rows) = answer["cookies"] else { throw YabCoreError.remote("Missing Chromium cookies") }
        var found: [String: ChromiumDRMCookie] = [:]
        for row in rows {
            // Partitioned or malformed: never copied into another partition.
            guard let cookie = try? ChromiumDRMCookie(row), scope.covers(cookie.key) else { continue }
            found[cookie.key] = cookie
        }
        return found
    }

    private func readWebKit(_ scope: ChromiumCookieScope) async -> [String: ChromiumDRMCookie] {
        var found: [String: ChromiumDRMCookie] = [:]
        for url in scope.urls {
            guard let cookies = await store.httpCookieStore.cookies(for: url) else {
                // An OS without the scoped read: filter the jar for this one host.
                let all = await store.httpCookieStore.allCookies()
                for cookie in all where !ChromiumDRMCookie.partitioned(cookie) {
                    let made = ChromiumDRMCookie(cookie)
                    if scope.covers(made.key) { found[made.key] = made }
                }
                return found
            }
            for cookie in cookies where !ChromiumDRMCookie.partitioned(cookie) {
                let made = ChromiumDRMCookie(cookie)
                if scope.covers(made.key) { found[made.key] = made }
            }
        }
        return found
    }

    // MARK: - the import

    func startImport() {
        guard importing == nil, !importTried, !retired else { return }
        importing = Task { @MainActor [weak self] in
            await self?.importJar()
            self?.importing = nil
        }
    }

    private func importJar() async {
        importTried = true
        do {
            try await serial { [weak self] in try await self?.load() }.value
            guard book.ledger.imported != true else { return }
            let began = Date()
            // WebKit answers on the main thread; everything after it runs off it.
            let all = await store.httpCookieStore.allCookies()
            let rows = await Task.detached(priority: .utility) { ChromiumCookieImportRow.rows(all) }.value
            imported.partitioned = all.count - rows.count
            var at = 0
            while at < rows.count {
                let part = Array(rows[at..<min(at + Self.batch, rows.count)])
                at += part.count
                try await serial { [weak self] in try await self?.send(part) }.value
                if at % (Self.batch * 10) == 0 { saveSoon() }
                // Room for the pages: this is the helper's busy thread too.
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            book.finishImport()
            imported.seconds = (Date().timeIntervalSince(began) * 100).rounded() / 100
            importSkip = []
            try await saveNow()
            NSLog("Chromium cookies: imported %d of %d in %.2f s, refused %d, partitioned %d",
                  imported.cookies, rows.count, imported.seconds, imported.refused, imported.partitioned)
        } catch is CancellationError {
            return
        } catch {
            // The next helper, or the next launch, goes on from what is recorded.
            NSLog("Chromium cookies: import stopped: %@", String(describing: error))
        }
    }

    private func send(_ part: [ChromiumCookieImportRow]) async throws {
        let unsettled = part.filter { row in
            book.ledger.webKit[row.cookie.key] == nil && !importSkip.contains { ChromiumCookieScope.matches(host: $0, key: row.cookie.key) }
        }
        guard !unsettled.isEmpty else { return }
        let (core, id) = try await endpoint()
        let answer = try await core.request("drm.cookies.setBatch", params: ["tab": .string(id), "cookies": .array(unsettled.map(\.payload))], timeout: 30)
        guard case .array(let results) = answer["results"], results.count == unsettled.count else {
            throw YabCoreError.remote("Missing cookie batch results")
        }
        for (row, result) in zip(unsettled, results) {
            let accepted = result == .bool(true)
            book.note(row, accepted: accepted)
            imported.cookies += accepted ? 1 : 0
            imported.refused += accepted ? 0 : 1
        }
    }

    // MARK: - the ledger on disk

    private func saveSoon() {
        guard ledgerFile != nil, saving == nil, !retired else { return }
        saving = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saving = nil
            try? await self.saveNow()
        }
    }

    private func saveNow() async throws {
        guard let file = ledgerFile, loaded else { return }
        let ledger = book.ledger
        try await Task.detached(priority: .utility) { try ledger.save(to: file) }.value
    }

    /// A loopback fixture's host as each jar holds it now, settling nothing:
    /// each cookie's name, a short fingerprint of its value, and whether it ends with the session.
    func jarsForTesting(host: String) async throws -> [String: Any] {
        guard Store.testing, ["127.0.0.1", "localhost"].contains(host) else { throw CancellationError() }
        func short(_ jar: [String: ChromiumDRMCookie]) -> [String: Any] {
            var out: [String: Any] = [:]
            for cookie in jar.values {
                let digest = SHA256.hash(data: Data(cookie.value.utf8)).map { String(format: "%02x", $0) }.joined()
                out[cookie.name] = ["fp": String(digest.prefix(12)), "session": cookie.expires == nil]
            }
            return out
        }
        var found: [String: Any] = [:]
        try await serial { [weak self] in
            guard let self else { return }
            let (core, id) = try await self.endpoint()
            let scope = ChromiumCookieScope(host: host, paths: ["/"])
            found = ["chromium": short(try await self.readChromium(core, id, scope)), "webKit": short(await self.readWebKit(scope))]
        }.value
        return found
    }

    /// Synthetic cookies only, with no real profile values in the result.
    func roundTripForTesting(at url: URL) async throws -> [String: Bool] {
        guard Store.testing, let host = url.host, ["127.0.0.1", "localhost"].contains(host) else { throw CancellationError() }
        include(url)
        try await synchronize()
        let (core, id) = try await endpoint()
        let name = "yab_drm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let made = HTTPCookie(properties: [.name: name, .value: "chromium", .domain: host, .path: "/",
            .discard: "TRUE", .sameSitePolicy: "lax", HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
        let initial = ChromiumDRMCookie(made)
        func remote(_ tab: String) async throws -> JSONValue? {
            let result = try await core.request("drm.cookies.get", params: ["tab": .string(tab), "urls": .array([.string(url.absoluteString)])])
            guard case .array(let rows) = result["cookies"] else { return nil }
            return rows.first { $0["name"].string == name }
        }
        _ = try await core.request("drm.cookies.set", params: ["tab": .string(id), "cookie": initial.chromium])
        try await synchronize()
        let imported = await store.httpCookieStore.allCookies().first { $0.name == name }
        var checks = ["chromium_to_webkit": imported?.value == "chromium" && imported?.isHTTPOnly == true && imported?.isSessionOnly == true]
        var edited = initial
        edited.value = "webkit"
        await store.httpCookieStore.setCookie(edited.webKit!)
        try await synchronize()
        let exported = try await remote(id)
        checks["webkit_to_chromium"] = exported?["value"].string == "webkit" && exported?["httpOnly"] == .bool(true) && exported?["sameSite"] == .string("Lax")
        let otherProfile = "drm_isolation_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try await core.openProfile(otherProfile, privateMode: true)
        let other = try await core.createTab(profile: otherProfile)
        _ = try await core.request("tab.visible", params: ["tab": .string(other), "visible": .bool(false)])
        checks["other_profile_empty"] = try await remote(other) == nil
        try await core.closeTab(other)
        _ = try await core.request("drm.cookies.delete", params: ["tab": .string(id), "cookie": initial.deletion])
        try await synchronize()
        checks["chromium_signout"] = await store.httpCookieStore.allCookies().allSatisfy { $0.name != name }
        await store.httpCookieStore.setCookie(made)
        try await synchronize()
        await store.httpCookieStore.deleteCookie(made)
        try await synchronize()
        checks["webkit_signout"] = try await remote(id) == nil
        var none = initial
        none.secure = true; none.sameSite = "None"; none.value = "none"
        _ = try await core.request("drm.cookies.set", params: ["tab": .string(id), "cookie": none.chromium])
        try await synchronize()
        let importedNone = await store.httpCookieStore.allCookies().first { $0.name == name }
        checks["none_to_webkit"] = importedNone?.isSecure == true && [nil, "none"].contains(importedNone?.sameSitePolicy?.rawValue.lowercased())
        none.value = "none-edited"
        await store.httpCookieStore.setCookie(none.webKit!)
        try await synchronize()
        let exportedNone = try await remote(id)
        checks["none_to_chromium"] = exportedNone?["sameSite"] == .string("None") && exportedNone?["value"] == .string("none-edited")
        if let importedNone { await store.httpCookieStore.deleteCookie(importedNone) }
        try await synchronize()
        return checks
    }
}

extension Tab {
    var chromiumProfile: String {
        // A warm/adopted private page is still an owner of its exact store.
        // Never let a supplied warm profile bypass that ownership boundary.
        if shy || !pageStore.isPersistent { return ChromiumPrivateProfiles.profile(for: self) }
        // A page made for a hover card has no window yet: it keeps its source's.
        if let warmProfile { return warmProfile }
        let browser = delegate as? Browser
        let placement = browser?.spaceHolding(self) ?? browser?.spaceID ?? Space.firstID
        return ChromiumPersistentProfiles.profile(store: pageStore, placement: placement)
    }
}
