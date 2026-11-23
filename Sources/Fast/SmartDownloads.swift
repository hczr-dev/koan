import AppKit
import Combine
import SwiftUI
import WebKit

struct SmartDownloadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Smart Downloads: what a page's own downloads can't do, done by aria2
/// (https://aria2.github.io), run here and driven over its JSON-RPC on this
/// Mac only: torrents and magnet links, and links fetched over sixteen
/// connections at once. With a debrid service (Settings › General), a
/// magnet or a hoster's link becomes direct links on the service's servers
/// first, fetched the same way. aria2 is looked for in the app, then where
/// Homebrew puts it; it quits with Yab.
@MainActor
final class SmartDownloads: ObservableObject {
    static let shared = SmartDownloads()
    enum Status: String { case resolving, waiting, active, paused, complete, error, removed }
    enum Kind: String { case torrent, link, debrid }

    struct Job: Identifiable, Equatable {
        var id: String
        var name: String
        var kind: Kind
        var status: Status
        var total: Int64 = 0
        var done: Int64 = 0
        var speed: Int64 = 0
        var seeders = 0
        var connections = 0
        var path: URL?
        var note = ""

        var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }
        var finished: Bool { status == .complete || status == .error || status == .removed }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var engineMissing = false

    private var process: Process?
    private var port = 0
    private var secret = ""
    private var ticking: Timer?
    private var refreshing = false
    /// aria2's own ids for a magnet's metadata, hidden once it has led to the files.
    private var hidden: Set<String> = []

    static var binary: URL? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("aria2/aria2c"),
                          Bundle.main.resourceURL?.appendingPathComponent("aria2c"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/aria2c"),
                          URL(fileURLWithPath: "/usr/local/bin/aria2c")].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var available: Bool { binary != nil }

    static var downloads: URL {
        BrowserWindows.shared.activeBrowser?.prefs.downloads
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Settings › General › Download with Smart Downloads (Prefs.smartDownloads).
    static let defaultKey = "downloads.smart"
    /// The least a file must say it weighs to be taken from the page's engine.
    static let least: Int64 = 1_000_000

    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    // MARK: - adding

    /// Words pasted into the list: magnets and links, one a line.
    func add(text: String, show browser: Browser? = nil) {
        for line in text.split(whereSeparator: \.isNewline) {
            let word = line.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: word), let scheme = url.scheme?.lowercased() else { continue }
            if scheme == "magnet" { add(magnet: url, show: browser) } else if scheme == "http" || scheme == "https" { add(link: url, show: browser) }
        }
    }

    /// `browser` is the window whose downloads list shows the row: the one
    /// the link came from, or the one in front.
    func add(magnet: URL, show browser: Browser? = nil) {
        let name = Self.magnetName(magnet)
        let again: () -> Void = { [weak self, weak browser] in self?.add(magnet: magnet, show: browser) }
        if Debrid.service != .none, Debrid.key != nil {
            let id = "debrid-" + UUID().uuidString
            let note = "Sending to \(Debrid.service.title)…"
            jobs.insert(Job(id: id, name: name, kind: .debrid, status: .resolving, note: note), at: 0)
            let fetch = mirror(id, name: name, source: magnet, origin: Debrid.service.title, kind: .debrid, browser: browser, again: again)
            fetch?.note = note
            let text = magnet.absoluteString
            debridTasks[id] = Task { await viaDebrid(id) { note in try await Debrid.links(magnet: text, progress: note) } }
            return
        }
        let place = Self.place(.torrent, name: nil).path
        Task { await start("aria2.addUri", [[magnet.absoluteString], ["dir": place]], name: name, kind: .torrent,
                           source: magnet, origin: "Magnet link", browser: browser, again: again) }
    }

    func add(torrentFile file: URL, show browser: Browser? = nil) {
        guard let data = try? Data(contentsOf: file) else { return }
        let name = file.deletingPathExtension().lastPathComponent
        let place = Self.place(.torrent, name: nil).path
        Task { await start("aria2.addTorrent", [data.base64EncodedString(), [String](), ["dir": place]], name: name, kind: .torrent,
                           source: file, origin: "Torrent file", browser: browser,
                           again: { [weak self, weak browser] in self?.add(torrentFile: file, show: browser) }) }
    }

    /// A link over many connections at once, with the page's cookies for its
    /// site; through the debrid service when there is one and the link is a
    /// file host's.
    func add(link: URL, referer: URL? = nil, store: WKWebsiteDataStore? = nil, show browser: Browser? = nil) {
        let again: () -> Void = { [weak self, weak browser] in self?.add(link: link, referer: referer, store: store, show: browser) }
        Task {
            if Debrid.service != .none, Debrid.key != nil, Debrid.hoster(link) {
                let id = "debrid-" + UUID().uuidString
                let note = "Unlocking with \(Debrid.service.title)…"
                jobs.insert(Job(id: id, name: link.lastPathComponent, kind: .debrid, status: .resolving, note: note), at: 0)
                mirror(id, name: link.lastPathComponent, source: link, origin: Debrid.service.title, kind: .debrid, browser: browser, again: again)?.note = note
                await viaDebrid(id) { _ in [try await Debrid.unlock(link)] }
                return
            }
            var headers: [String] = []
            if let referer, referer.scheme?.hasPrefix("http") == true { headers.append("Referer: \(referer.absoluteString)") }
            if let store, let host = link.host() {
                let cookies = await store.httpCookieStore.allCookies().filter { cookie in
                    let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                    return host == domain || host.hasSuffix("." + domain)
                }
                if !cookies.isEmpty { headers.append("Cookie: " + cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")) }
            }
            let name = link.lastPathComponent
            var options: [String: Any] = ["dir": Self.place(.link, name: name).path]
            if !headers.isEmpty { options["header"] = headers }
            await start("aria2.addUri", [[link.absoluteString], options], name: name.isEmpty ? (link.host() ?? "Download") : name, kind: .link,
                        source: link, origin: link.host() ?? "", browser: browser, again: again)
        }
    }

    private func viaDebrid(_ id: String, _ resolve: (@escaping @MainActor (String) -> Void) async throws -> [Debrid.File]) async {
        do {
            let files = try await resolve { [weak self] note in self?.update(id) { $0.note = note } }
            guard !Task.isCancelled else { return }
            jobs.removeAll { $0.id == id }
            debridTasks[id] = nil
            // The files take the row's place, each with its own.
            let was = taken.removeValue(forKey: id)
            if let was { was.browser?.hoard.withdraw(was.fetch) }
            if files.isEmpty { throw SmartDownloadError("\(Debrid.service.title) gave no files") }
            for file in files {
                await start("aria2.addUri", [[file.url.absoluteString], ["dir": Self.place(.link, name: file.name).path, "out": file.name]],
                            name: file.name, kind: .debrid, source: was?.source ?? file.url, origin: Debrid.service.title,
                            browser: was?.browser, again: was?.fetch.onAgain ?? {})
            }
        } catch {
            guard !Task.isCancelled else { return }
            debridTasks[id] = nil
            if jobs.contains(where: { $0.id == id }) {
                update(id) { $0.status = .error; $0.note = error.localizedDescription }
            } else {
                jobs.insert(Job(id: id, name: "Debrid", kind: .debrid, status: .error, note: error.localizedDescription), at: 0)
            }
            failed(id, error.localizedDescription)
        }
    }

    /// A job that never got to aria2, its row said so.
    private func failed(_ id: String, _ message: String) {
        guard let entry = taken.removeValue(forKey: id) else { return }
        entry.fetch.status = .error
        entry.fetch.note = message
        entry.browser?.download(entry.fetch, didFailWithError: SmartDownloadError(message), resumeData: nil)
    }

    private func start(_ method: String, _ params: [Any], name: String, kind: Kind, source: URL, origin: String,
                       browser: Browser?, again: @escaping () -> Void) async {
        func refuse(_ message: String) {
            let id = UUID().uuidString
            jobs.insert(Job(id: id, name: name, kind: kind, status: .error, note: message), at: 0)
            mirror(id, name: name, source: source, origin: origin, kind: kind, browser: browser, again: again)
            failed(id, message)
        }
        guard ensureEngine() else { return refuse("aria2 isn't installed: brew install aria2") }
        do {
            let gid = try await call(method, params) as? String ?? UUID().uuidString
            jobs.insert(Job(id: gid, name: name, kind: kind, status: .waiting), at: 0)
            let fetch = mirror(gid, name: name, source: source, origin: origin, kind: kind, browser: browser, again: again)
            fetch?.status = .waiting
            tick()
        } catch {
            refuse(error.localizedDescription)
        }
    }

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        guard let at = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[at])
        if let entry = taken[id], jobs[at].status == .resolving {
            entry.fetch.note = jobs[at].note
            entry.browser?.hoard.nudge(entry.fetch)
        }
    }

    // MARK: - rows in the downloads list

    /// A job's row in a window's downloads list, beside the files its
    /// pages download: the button, the list, All Downloads, the Dock's bar.
    @discardableResult
    private func mirror(_ id: String, name: String, source: URL, origin: String, kind: Kind, browser: Browser?,
                        again: @escaping () -> Void) -> SmartFetch? {
        guard let browser = browser ?? BrowserWindows.shared.activeBrowser else { return nil }
        let fetch = SmartFetch(source: source, page: nil, pageURL: nil, pageTitle: nil)
        fetch.origin = origin
        fetch.kind = kind
        fetch.gid = id
        fetch.status = .resolving
        fetch.onAgain = again
        wire(fetch)
        known[ObjectIdentifier(fetch)] = fetch
        browser.hoard.begin(fetch, name: name, from: origin)
        taken[id] = Taken(fetch: fetch, browser: browser, tab: nil, source: source, expected: 0, fromPage: false)
        return fetch
    }

    /// What the row's buttons do, by the job's id as it stands then (a
    /// magnet's changes once its files are known).
    private func wire(_ fetch: SmartFetch) {
        fetch.onCancel = { [weak self, weak fetch] in if let id = fetch?.gid { self?.dropTaken(id) } }
        fetch.onPause = { [weak self, weak fetch] in if let id = fetch?.gid { self?.pause(gid: id) } }
        fetch.onResume = { [weak self, weak fetch] in if let id = fetch?.gid { self?.resume(gid: id) } }
    }

    /// The row's own fetch, while the list has it.
    func live(_ id: ObjectIdentifier) -> SmartFetch? { known[id] }

    func forgetFetch(_ id: ObjectIdentifier) { known[id] = nil }

    private var known: [ObjectIdentifier: SmartFetch] = [:]
    private var debridTasks: [String: Task<Void, Never>] = [:]

    /// Clipboard words that are a magnet or a link to fetch.
    static func link(in text: String?) -> Bool {
        guard let text else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            guard let url = URL(string: line.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "magnet" || ((scheme == "http" || scheme == "https") && url.host() != nil)
        }
    }

    // MARK: - taken from the page's engine

    /// A download Smart Downloads took from a page: the row it has in the
    /// downloads button, and what to fall back on.
    private struct Taken {
        let fetch: SmartFetch
        weak var browser: Browser?
        weak var tab: Tab?
        let source: URL
        /// What the page's engine was told the file weighs.
        let expected: Int64
        /// False for a magnet, a pasted link: nothing to hand back to a page.
        var fromPage = true
    }
    private var taken: [String: Taken] = [:]
    /// Addresses handed back to the page's engine: not taken again.
    private var handedBack: Set<URL> = []

    /// Whether this download, about to be written by the page's engine, is
    /// Smart Downloads' instead (Browser.download(_:decideDestinationUsing:)):
    /// a plain GET for a file of a megabyte or more, from a tab that is
    /// neither private nor an agent's. It gets a row in the downloads
    /// button as any download, fed by aria2, and lands in the list the same
    /// way; the page's engine fetches it after all when aria2 can't, or
    /// gets something else than the page did (a sign-in page).
    func takes(_ download: any PageDownload, response: URLResponse, name: String, in browser: Browser, tab: Tab?) -> Bool {
        guard browser.prefs.smartDownloads, Self.available, !download.isExtensionDownload,
              let url = response.url ?? download.originalRequest?.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !handedBack.contains(url),
              (download.originalRequest?.httpMethod ?? "GET").uppercased() == "GET", download.originalRequest?.httpBody == nil,
              response.expectedContentLength >= Self.least,
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return false }
        if let tab, tab.shy || tab.agent != nil { return false }
        let fetch = SmartFetch(source: url, page: download.page, pageURL: download.pageURL, pageTitle: download.pageTitle)
        fetch.progress.totalUnitCount = response.expectedContentLength
        let file = name.isEmpty ? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent) : name
        browser.hoard.begin(fetch, name: file, from: url.host() ?? "")
        let store = tab?.builtPage?.webKit?.configuration.websiteDataStore
        let referer = download.pageURL
        let expected = response.expectedContentLength
        Task { [weak browser, weak tab] in
            var headers: [String] = []
            if let referer, referer.scheme?.hasPrefix("http") == true { headers.append("Referer: \(referer.absoluteString)") }
            if let store, let cookies = await store.httpCookieStore.cookies(for: url), !cookies.isEmpty {
                headers.append("Cookie: " + cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
            }
            var options: [String: Any] = ["dir": Self.place(.link, name: file).path, "out": file]
            if !headers.isEmpty { options["header"] = headers }
            guard self.ensureEngine(), let gid = try? await self.call("aria2.addUri", [[url.absoluteString], options]) as? String else {
                self.handBack(Taken(fetch: fetch, browser: browser, tab: tab, source: url, expected: expected), gid: nil)
                return
            }
            fetch.gid = gid
            fetch.origin = url.host() ?? ""
            fetch.kind = .link
            fetch.status = .waiting
            self.wire(fetch)
            self.known[ObjectIdentifier(fetch)] = fetch
            self.taken[gid] = Taken(fetch: fetch, browser: browser, tab: tab, source: url, expected: expected)
            self.jobs.insert(Job(id: gid, name: file, kind: .link, status: .waiting), at: 0)
            self.tick()
        }
        return true
    }

    /// What aria2 says of one it took, told to its row: on its way, landed,
    /// or handed back to the page's engine.
    private func follow(_ job: Job) {
        guard let taken = taken[job.id] else { return }
        let fetch = taken.fetch
        if job.total > 0 { fetch.progress.totalUnitCount = job.total }
        fetch.progress.completedUnitCount = job.done
        fetch.status = job.status
        fetch.speed = job.speed
        fetch.connections = job.connections
        fetch.path = job.path
        fetch.note = job.note
        taken.browser?.hoard.smartChanged(fetch, name: job.name, paused: job.status == .paused)
        // Not what the page was sent: a sign-in page, an error page.
        if taken.fromPage, job.total > 0, taken.expected > 0, job.total != taken.expected {
            handBack(taken, gid: job.id)
            return
        }
        switch job.status {
        case .complete:
            self.taken[job.id] = nil
            guard let file = job.path else { return }
            taken.browser?.smartLanded(fetch, file: file, source: taken.source)
        case .error:
            if taken.fromPage, job.done == 0 {
                handBack(taken, gid: job.id)
            } else {
                self.taken[job.id] = nil
                taken.browser?.download(fetch, didFailWithError: SmartDownloadError(job.note), resumeData: nil)
            }
        case .removed:
            self.taken[job.id] = nil
        default:
            break
        }
    }

    /// Fetched by the page's engine after all, from the tab that asked: the
    /// row goes, and the engine's own comes.
    private func handBack(_ taken: Taken, gid: String?) {
        if let gid {
            self.taken[gid] = nil
            dropTaken(gid)
            jobs.removeAll { $0.id == gid }
        }
        handedBack.insert(taken.source)
        taken.browser?.hoard.withdraw(taken.fetch)
        guard let page = taken.tab?.builtPage ?? taken.browser?.active?.builtPage else { return }
        if let chromium = page as? ChromiumPage {
            chromium.startDownload(taken.source)
        } else if let web = page.webKit {
            web.startDownload(using: URLRequest(url: taken.source)) { [weak browser = taken.browser] download in browser?.keep(download) }
        }
    }

    private func dropTaken(_ gid: String) {
        taken[gid] = nil
        debridTasks.removeValue(forKey: gid)?.cancel()
        let job = jobs.first { $0.id == gid }
        jobs.removeAll { $0.id == gid }
        guard !gid.hasPrefix("debrid-"), process?.isRunning == true else { return }
        Task {
            _ = try? await call("aria2.forceRemove", [gid])
            _ = try? await call("aria2.removeDownloadResult", [gid])
            // What a canceled one wrote goes with it, not left in Downloads
            // as a file that opens broken (a torrent's folder stays).
            if let job, job.kind != .torrent, !job.finished, let path = job.path {
                try? await Task.sleep(for: .milliseconds(300))
                try? FileManager.default.removeItem(at: path)
                try? FileManager.default.removeItem(atPath: path.path + ".aria2")
            }
        }
    }

    // MARK: - controls

    func pause(gid: String) {
        guard !gid.hasPrefix("debrid-") else { return }
        Task { _ = try? await call("aria2.pause", [gid]); tick() }
    }

    func resume(gid: String) {
        guard !gid.hasPrefix("debrid-") else { return }
        Task { _ = try? await call("aria2.unpause", [gid]); tick() }
    }

    // MARK: - aria2

    private func ensureEngine() -> Bool {
        if let process, process.isRunning { return true }
        guard let binary = Self.binary else {
            engineMissing = true
            return false
        }
        engineMissing = false
        port = Int.random(in: 46_800...46_999)
        secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let task = Process()
        task.executableURL = binary
        task.arguments = [
            "--enable-rpc", "--rpc-listen-all=false", "--rpc-listen-port=\(port)", "--rpc-secret=\(secret)",
            "--dir=\(Self.downloads.path)", "--continue=true", "--max-concurrent-downloads=5",
            "--max-connection-per-server=16", "--split=16", "--min-split-size=1M", "--file-allocation=none",
            "--seed-time=0", "--bt-save-metadata=false", "--rpc-save-upload-metadata=false", "--follow-torrent=mem", "--bt-remove-unselected-file=true",
            "--auto-file-renaming=true", "--allow-overwrite=false", "--quiet=true",
            "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)", "--user-agent=\(Self.agent)",
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch {
            engineMissing = true
            return false
        }
        process = task
        return true
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    private func call(_ method: String, _ params: [Any] = []) async throws -> Any? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/jsonrpc") else { throw SmartDownloadError("No engine") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": "yab", "method": method, "params": ["token:\(secret)"] + params]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var last: Error = SmartDownloadError("The download engine didn't answer")
        // The first call waits for aria2 to come up, a few tenths of a second.
        for _ in 0..<25 {
            do {
                let (data, _) = try await Self.session.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SmartDownloadError("aria2 said nothing") }
                if let error = json["error"] as? [String: Any] { throw SmartDownloadError(error["message"] as? String ?? "aria2 refused it") }
                return json["result"]
            } catch let error as SmartDownloadError {
                throw error
            } catch {
                last = error
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        throw last
    }

    private func tick() {
        guard ticking == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        ticking = timer
        refresh()
    }

    private func refresh() {
        guard !refreshing, process?.isRunning == true else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            let keys = ["gid", "status", "totalLength", "completedLength", "downloadSpeed", "numSeeders", "connections",
                        "dir", "files", "bittorrent", "errorMessage", "followedBy"]
            var rows: [[String: Any]] = []
            let asks: [(String, [Any])] = [("aria2.tellActive", [keys]), ("aria2.tellWaiting", [0, 200, keys]), ("aria2.tellStopped", [0, 200, keys])]
            for (method, params) in asks {
                if let list = try? await call(method, params) as? [[String: Any]] { rows += list }
            }
            apply(rows)
            if !jobs.contains(where: { !$0.finished && $0.status != .resolving }), taken.isEmpty {
                ticking?.invalidate()
                ticking = nil
            }
        }
    }

    private func apply(_ rows: [[String: Any]]) {
        for row in rows {
            guard let gid = row["gid"] as? String else { continue }
            if let followed = row["followedBy"] as? [String], !followed.isEmpty {
                // A magnet's metadata, fetched: the files it describes take its place.
                hidden.insert(gid)
                if let at = jobs.firstIndex(where: { $0.id == gid }) {
                    let old = jobs.remove(at: at)
                    for next in followed where !jobs.contains(where: { $0.id == next }) {
                        jobs.insert(Job(id: next, name: old.name, kind: old.kind, status: .waiting), at: min(at, jobs.count))
                    }
                    // Its row goes on as the first of them.
                    if let entry = taken.removeValue(forKey: gid), let next = followed.first {
                        entry.fetch.gid = next
                        taken[next] = entry
                    }
                }
                continue
            }
            guard !hidden.contains(gid), let at = jobs.firstIndex(where: { $0.id == gid }) else { continue }
            var job = jobs[at]
            job.status = Status(rawValue: row["status"] as? String ?? "") ?? job.status
            job.total = Int64(row["totalLength"] as? String ?? "") ?? job.total
            job.done = Int64(row["completedLength"] as? String ?? "") ?? job.done
            job.speed = Int64(row["downloadSpeed"] as? String ?? "") ?? 0
            job.seeders = Int(row["numSeeders"] as? String ?? "") ?? 0
            job.connections = Int(row["connections"] as? String ?? "") ?? 0
            if let torrent = row["bittorrent"] as? [String: Any], let info = torrent["info"] as? [String: Any],
               let name = info["name"] as? String, !name.isEmpty {
                job.name = name
                if let dir = row["dir"] as? String { job.path = URL(fileURLWithPath: dir).appendingPathComponent(name) }
            } else if let files = row["files"] as? [[String: Any]], let first = files.first?["path"] as? String, !first.isEmpty {
                job.path = URL(fileURLWithPath: first)
                if job.kind != .torrent { job.name = job.path?.lastPathComponent ?? job.name }
            }
            if job.status == .error { job.note = row["errorMessage"] as? String ?? "Failed" }
            jobs[at] = job
            follow(job)
        }
    }

    // MARK: - places

    static func magnetName(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dn" }?.value ?? "Magnet link"
    }

    /// Torrents into Torrents, a file by what it is (DownloadSorting).
    static func place(_ kind: Kind, name: String?) -> URL {
        let root = downloads
        if kind == .torrent {
            return DownloadSorting.on ? DownloadSorting.ensure(root.appendingPathComponent("Torrents", isDirectory: true)) ?? root : root
        }
        guard let name, !name.isEmpty else { return root }
        return DownloadSorting.place(name, in: root)
    }
}

/// A download Smart Downloads took from a page, as the downloads button
/// knows one (Hoard): its progress fed from aria2, Stop removing it there.
@MainActor
final class SmartFetch: PageDownload {
    let downloadID = UUID()
    let originalRequest: URLRequest?
    var isUserInitiated: Bool { true }
    let progress = Progress(totalUnitCount: -1)
    weak var page: (any PageHandle)?
    var sourceView: NSView? { nil }
    let pageURL: URL?
    let pageTitle: String?
    weak var downloadEvents: (any PageDownloadEvents)?
    var gid: String?
    var onCancel: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    /// Starts the whole of it again: a failed row's Try Again.
    var onAgain: (() -> Void)?

    // What aria2 last said of it, for the words and buttons of its row.
    var kind: SmartDownloads.Kind = .link
    var status: SmartDownloads.Status = .waiting
    var speed: Int64 = 0
    var connections = 0
    var path: URL?
    var note = ""
    /// Where it comes from, said for people: a host, "Magnet link".
    var origin = ""

    /// Its file, or the folder it goes to while there is none yet.
    func reveal() {
        if let path, FileManager.default.fileExists(atPath: path.path) {
            NSWorkspace.shared.activateFileViewerSelecting([path])
        } else {
            NSWorkspace.shared.open(SmartDownloads.downloads)
        }
    }

    init(source: URL, page: (any PageHandle)?, pageURL: URL?, pageTitle: String?) {
        originalRequest = URLRequest(url: source)
        self.page = page
        self.pageURL = pageURL
        self.pageTitle = pageTitle
    }

    func cancelDownload(_ done: @escaping @MainActor (Data?) -> Void) {
        onCancel?()
        onCancel = nil
        DispatchQueue.main.async { done(nil) }
    }

    /// Try Again starts it in aria2 anew, as a row of its own (Hoard.retry).
    func restartDownload(from resumeData: Data?, fallback: (any PageHandle)?,
                         done: @escaping @MainActor ((any PageDownload)?) -> Void) {
        DispatchQueue.main.async { done(nil) }
    }
}

extension Browser {
    /// A file Smart Downloads fetched in a page's place: its row lands in
    /// the button, and it is kept with the others, as the page's would be.
    func smartLanded(_ download: SmartFetch, file: URL, source: URL) {
        hoard.finish(download)
        // A torrent's folder is not marked as a page's file is.
        if download.kind != .torrent {
            Browser.writeWhereFrom(file, [source, download.pageURL].compactMap { $0 })
            SiteDownloads.quarantine(file, from: source, page: download.pageURL)
        }
        loot.add(Keep(name: file.lastPathComponent, from: download.origin.isEmpty ? (source.host() ?? "") : download.origin, path: file.path, date: Date(),
                      page: download.pageURL, pageTitle: download.pageTitle.flatMap { $0.isEmpty ? nil : $0 }, source: source))
    }
}

// MARK: - debrid

enum DebridService: String, CaseIterable, Hashable {
    case none
    case realDebrid = "real-debrid"
    case allDebrid = "alldebrid"
    case premiumize

    var title: String {
        switch self {
        case .none: "None"
        case .realDebrid: "Real-Debrid"
        case .allDebrid: "AllDebrid"
        case .premiumize: "Premiumize"
        }
    }
}

/// A debrid service's API: a magnet or a file host's link in, direct links
/// on the service's own servers out. Its key is kept in debrid-keys.json in
/// Yab's folder, readable by you alone.
enum Debrid {
    struct File {
        let url: URL
        let name: String
    }

    static let serviceKey = "downloads.debrid"

    static var service: DebridService {
        get { DebridService(rawValue: Store.settings.string(forKey: serviceKey) ?? "") ?? .none }
        set { Store.settings.set(newValue.rawValue, forKey: serviceKey) }
    }

    private static var keysFile: URL { Store.file("debrid-keys.json") }

    static func keyFor(_ service: DebridService) -> String? {
        guard let data = try? Data(contentsOf: keysFile),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return keys[service.rawValue]
    }

    static func setKey(_ key: String, for service: DebridService) {
        var keys = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: keysFile))) ?? [:]
        keys[service.rawValue] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: keysFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysFile.path)
    }

    static var key: String? {
        guard service != .none, let key = keyFor(service), !key.isEmpty else { return nil }
        return key
    }

    /// File hosts a debrid service unlocks; anything else is fetched as it is.
    static let hosts = ["1fichier.com", "rapidgator.net", "rg.to", "turbobit.net", "nitroflare.com", "mega.nz", "mediafire.com",
                        "katfile.com", "ddownload.com", "filefactory.com", "uploaded.net", "hitfile.net", "pixeldrain.com",
                        "gofile.io", "fikper.com", "usersdrive.com", "uptobox.com", "dailyuploads.net", "drop.download",
                        "clicknupload.click", "frdl.io", "filestore.me", "send.cm", "worldbytez.com", "alfafile.net"]

    static func hoster(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func links(magnet: String, progress: @escaping @MainActor (String) -> Void) async throws -> [File] {
        guard let key = await MainActor.run(body: { Self.key }) else { throw SmartDownloadError("No debrid key in Settings") }
        switch await MainActor.run(body: { Self.service }) {
        case .none: throw SmartDownloadError("No debrid service")
        case .realDebrid: return try await realDebrid(magnet: magnet, key: key, progress: progress)
        case .allDebrid: return try await allDebrid(magnet: magnet, key: key, progress: progress)
        case .premiumize: return try await premiumize(magnet, key: key)
        }
    }

    static func unlock(_ link: URL) async throws -> File {
        guard let key = await MainActor.run(body: { Self.key }) else { throw SmartDownloadError("No debrid key in Settings") }
        switch await MainActor.run(body: { Self.service }) {
        case .none: throw SmartDownloadError("No debrid service")
        case .realDebrid:
            let json = try await request(URL(string: "https://api.real-debrid.com/rest/1.0/unrestrict/link")!, method: "POST",
                                         form: ["link": link.absoluteString], bearer: key) as? [String: Any]
            guard let direct = (json?["download"] as? String).flatMap(URL.init(string:)) else { throw SmartDownloadError("Real-Debrid couldn't unlock that link") }
            return File(url: direct, name: json?["filename"] as? String ?? direct.lastPathComponent)
        case .allDebrid:
            return try await allDebridUnlock(link.absoluteString, key: key)
        case .premiumize:
            guard let first = try await premiumize(link.absoluteString, key: key).first else { throw SmartDownloadError("Premiumize couldn't unlock that link") }
            return first
        }
    }

    // Real-Debrid: https://api.real-debrid.com
    private static func realDebrid(magnet: String, key: String, progress: @escaping @MainActor (String) -> Void) async throws -> [File] {
        let base = "https://api.real-debrid.com/rest/1.0"
        let added = try await request(URL(string: base + "/torrents/addMagnet")!, method: "POST", form: ["magnet": magnet], bearer: key) as? [String: Any]
        guard let id = added?["id"] as? String else { throw SmartDownloadError("Real-Debrid didn't take the magnet") }
        var selected = false
        for _ in 0..<1800 {
            let info = try await request(URL(string: base + "/torrents/info/\(id)")!, bearer: key) as? [String: Any] ?? [:]
            let status = info["status"] as? String ?? ""
            switch status {
            case "waiting_files_selection" where !selected:
                _ = try await request(URL(string: base + "/torrents/selectFiles/\(id)")!, method: "POST", form: ["files": "all"], bearer: key)
                selected = true
            case "downloaded":
                var files: [File] = []
                for link in info["links"] as? [String] ?? [] {
                    let json = try await request(URL(string: base + "/unrestrict/link")!, method: "POST", form: ["link": link], bearer: key) as? [String: Any]
                    if let direct = (json?["download"] as? String).flatMap(URL.init(string:)) {
                        files.append(File(url: direct, name: json?["filename"] as? String ?? direct.lastPathComponent))
                    }
                }
                return files
            case "magnet_error", "error", "virus", "dead":
                throw SmartDownloadError("Real-Debrid: " + status.replacingOccurrences(of: "_", with: " "))
            default:
                let percent = (info["progress"] as? Double) ?? Double(info["progress"] as? Int ?? 0)
                await progress("Real-Debrid: \(status.replacingOccurrences(of: "_", with: " ")) \(Int(percent))%")
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw SmartDownloadError("Real-Debrid took too long")
    }

    // AllDebrid: https://docs.alldebrid.com (v4)
    private static func allDebridURL(_ path: String, _ items: [URLQueryItem], key: String) -> URL {
        var parts = URLComponents(string: "https://api.alldebrid.com/v4" + path)!
        parts.queryItems = [URLQueryItem(name: "agent", value: "yab"), URLQueryItem(name: "apikey", value: key)] + items
        return parts.url!
    }

    private static func allDebrid(magnet: String, key: String, progress: @escaping @MainActor (String) -> Void) async throws -> [File] {
        let up = try await request(allDebridURL("/magnet/upload", [URLQueryItem(name: "magnets[]", value: magnet)], key: key)) as? [String: Any]
        guard let data = up?["data"] as? [String: Any], let first = (data["magnets"] as? [[String: Any]])?.first, let id = first["id"] else {
            throw SmartDownloadError(((up?["error"] as? [String: Any])?["message"] as? String) ?? "AllDebrid didn't take the magnet")
        }
        for _ in 0..<1800 {
            let status = try await request(allDebridURL("/magnet/status", [URLQueryItem(name: "id", value: "\(id)")], key: key)) as? [String: Any]
            let inner = status?["data"] as? [String: Any]
            let magnet = (inner?["magnets"] as? [String: Any]) ?? (inner?["magnets"] as? [[String: Any]])?.first ?? [:]
            let code = magnet["statusCode"] as? Int ?? -1
            if code == 4 {
                var files: [File] = []
                for link in magnet["links"] as? [[String: Any]] ?? [] {
                    if let url = link["link"] as? String { files.append(try await allDebridUnlock(url, key: key)) }
                }
                return files
            }
            if code >= 5 { throw SmartDownloadError("AllDebrid: " + (magnet["status"] as? String ?? "failed")) }
            let done = magnet["downloaded"] as? Double ?? 0, size = magnet["size"] as? Double ?? 0
            await progress("AllDebrid: \(magnet["status"] as? String ?? "working") \(size > 0 ? Int(done / size * 100) : 0)%")
            try await Task.sleep(for: .seconds(2))
        }
        throw SmartDownloadError("AllDebrid took too long")
    }

    private static func allDebridUnlock(_ link: String, key: String) async throws -> File {
        let json = try await request(allDebridURL("/link/unlock", [URLQueryItem(name: "link", value: link)], key: key)) as? [String: Any]
        let data = json?["data"] as? [String: Any]
        guard let direct = (data?["link"] as? String).flatMap(URL.init(string:)) else {
            throw SmartDownloadError(((json?["error"] as? [String: Any])?["message"] as? String) ?? "AllDebrid couldn't unlock that link")
        }
        return File(url: direct, name: data?["filename"] as? String ?? direct.lastPathComponent)
    }

    // Premiumize: https://www.premiumize.me/api (direct downloads of what it has ready)
    private static func premiumize(_ source: String, key: String) async throws -> [File] {
        var parts = URLComponents(string: "https://www.premiumize.me/api/transfer/directdl")!
        parts.queryItems = [URLQueryItem(name: "apikey", value: key)]
        let json = try await request(parts.url!, method: "POST", form: ["src": source]) as? [String: Any]
        guard json?["status"] as? String == "success", let content = json?["content"] as? [[String: Any]] else {
            throw SmartDownloadError((json?["message"] as? String) ?? "Premiumize has no copy of it ready")
        }
        return content.compactMap { item in
            guard let url = (item["link"] as? String).flatMap(URL.init(string:)) else { return nil }
            let name = (item["path"] as? String).map { ($0 as NSString).lastPathComponent } ?? url.lastPathComponent
            return File(url: url, name: name)
        }
    }

    private static func request(_ url: URL, method: String = "GET", form: [String: String]? = nil, bearer: String? = nil) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
                .joined(separator: "&").data(using: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.isEmpty ? [String: Any]() : ((try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]())
        if code >= 400 {
            let said = (json as? [String: Any])?["error"] as? String
            throw SmartDownloadError(said ?? "The debrid service answered \(code)")
        }
        return json
    }
}
