import Foundation

// Where everything this browser keeps is kept.
//
// One place, and one rule: a run started for testing never touches the folder
// or the settings of the browser somebody is actually using. Sharing them once
// cost a person their pinned tabs, which is not a mistake worth being able to
// make twice.

public enum Store {
    /// A run is a test run if it says so, or if it is being run straight out
    /// of the build folder rather than from an installed app. The second half
    /// is not belt and braces: a development build launched from a terminal
    /// once wrote over somebody's real session, and asking a person to
    /// remember a flag is not a safeguard. Nor is the build folder the only
    /// place a bare binary runs from: a renamed copy in a scratch folder
    /// once took the yab command for itself, so anything not inside an app
    /// bundle is a test run too.
    public static var testing: Bool {
        if ProcessInfo.processInfo.environment["YAB_PROBE"] != nil { return true }
        guard let path = Bundle.main.executablePath else { return true }
        return path.contains("/.build/") || !path.contains(".app/Contents/MacOS/")
    }

    /// A test world on a Mac with nobody at it: take macOS to have said yes
    /// about Yab, for the camera, the microphone and where you are.
    public nonisolated static var macSaysYes: Bool {
        testing && ProcessInfo.processInfo.environment["YAB_MAC_SAYS_YES"] == "1"
    }

    /// Which test world a test run lives in. YAB_PROBE=1, or a run from
    /// the build folder, is the test world, "Yab (test)". YAB_PROBE=
    /// <name> is a world of its own, "Yab (<name>)", with settings and
    /// WebKit stores of its own: two sessions testing at once, or a
    /// measurement that needs a browser nobody has installed anything in,
    /// never borrow each other's. Nil for the browser somebody is using.
    public static let world: String? = {
        guard testing else { return nil }
        let asked = (ProcessInfo.processInfo.environment["YAB_PROBE"] ?? "").lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        return asked.isEmpty || asked == "1" || asked == "test" ? "test" : asked
    }()

    /// The development build, `./build.sh`, "yab Dev", rather than the
    /// one that ships. It is an app of its own beside the other: its own
    /// bundle id, so its own settings, cookies and WebKit stores, and its
    /// own folder and keychain items, so both can be open at once and
    /// nothing tried in one reaches the other.
    public static let development = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        // A fork under its own id (Koan's com.hczr.koan) says so in its Info.plist.
        || Bundle.main.object(forInfoDictionaryKey: "YabDevelopmentBuild") as? Bool == true
    private static let prerelease = Bundle.main.bundleIdentifier?.hasSuffix(".prerelease.dev") == true

    /// What the app keeps its things under, its folder, its keychain
    /// items, its socket: "Yab", "Yab Dev", or a test world's "Yab (…)".
    /// A copy delivered for one task (Code.app) names its own folder in its
    /// Info.plist (YabDataName), so it runs beside the other dev copies.
    public static let name: String = world.map { "Yab (\($0))" } ?? delivered ?? (prerelease ? "Yab Prerelease" : development ? "Yab Dev" : "Yab")
    private static let delivered: String? = (Bundle.main.object(forInfoDictionaryKey: "YabDataName") as? String)
        .flatMap { name in development && name.hasPrefix("Yab ") ? name : nil }

    /// What it kept them under until October 2026, when it was still called
    /// Fast inside: looked for once, and moved (`folder`, Vault, Wallet).
    public static let oldName: String = world.map { "Fast (\($0))" } ?? delivered.map { "Fast" + $0.dropFirst(3) } ?? (prerelease ? "Fast Prerelease" : development ? "Fast Dev" : "Fast")

    /// Set by the browser before it touches anything: only the browser moves
    /// the old folder to the new name. The yab command uses whichever is there.
    public nonisolated(unsafe) static var movesOldFolder = false

    /// A test run there to be weighed and timed rather than driven
    /// (YAB_MEASURE beside YAB_PROBE). It keeps what the shipped
    /// browser does where test runs otherwise differ, hidden pages slowed
    /// the way WebKit slows them, App Nap left to macOS, so what gets
    /// measured is what people get.
    public static var measuring: Bool {
        testing && ProcessInfo.processInfo.environment["YAB_MEASURE"] != nil
    }

    /// A test world filmed for a demo (YAB_RECORDING beside YAB_PROBE,
    /// demos/world.py): the windows Yab keeps out of screen shares, a
    /// floating call and the frame around a shown tab, show in the film.
    public static let recording: Bool = testing && ProcessInfo.processInfo.environment["YAB_RECORDING"] == "1"

    /// A test copy of the app under a bundle id of its own has a WebKit
    /// container of its own too, so it can use WebKit's default store and
    /// extension configuration, the ones the real browser uses, which
    /// differ from stores made by identifier in how long extension workers
    /// are let live.
    public static var ownContainer: Bool {
        (Bundle.main.bundleIdentifier ?? "") != "dev.serafim.fast"
    }

    /// The fixed identifiers of a test world's WebKit stores: 1 for websites,
    /// 2 for extensions. The test world's are 5E4C0000-0000-4000-8000-00000000000k,
    /// the ones fresh.sh wipes; a named world puts a hash of its name (FNV-1a,
    /// 32 bits) in place of the second and third groups of zeros, so each
    /// keeps its own from one run to the next.
    public static func probeStore(_ kind: UInt32) -> UUID {
        var hash: UInt32 = 0
        if let world, world != "test" {
            hash = 2_166_136_261
            for byte in world.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        }
        let text = String(format: "5E4C%04X-%04X-4000-8000-%012X", hash >> 16, hash & 0xFFFF, kind)
        return UUID(uuidString: text)!
    }

    /// Everything the app keeps, the session, the pins, the history, what
    /// is hidden on each site, in one folder of its own; a test world in
    /// one beside it.
    ///
    /// A folder still under the old name is moved to the new one by the
    /// browser, at launch, with one rename: everything in it keeps working,
    /// nothing is copied. Not while another browser holds the old one (an
    /// older yab still open), and not by the yab command: then this run uses
    /// the old folder where it is, and the next launch moves it.
    public static let folder: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let new = support.appendingPathComponent(name, isDirectory: true)
        let old = support.appendingPathComponent(oldName, isDirectory: true)
        let files = FileManager.default
        guard !files.fileExists(atPath: new.path), files.fileExists(atPath: old.path) else { return new }
        guard movesOldFolder, !held(old.appendingPathComponent("yab.lock")),
              (try? files.moveItem(at: old, to: new)) != nil
        else { return old }
        return new
    }()

    /// Whether a browser holds the lock in a folder (OneYab).
    private static func held(_ lock: URL) -> Bool {
        let fd = open(lock.path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    public static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// Restrict this profile's files and its WebKit container to this account.
    public static func harden() {
        harden(at: folder)
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
           let bundle = Bundle.main.bundleIdentifier {
            restrict(library.appendingPathComponent("WebKit/" + bundle, isDirectory: true), mode: 0o700, directory: true)
        }
    }

    /// Existing files may predate the private profile directory. Do not
    /// follow symlinks: tightening a profile must not chmod another target.
    public static func harden(at root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard restrict(root, mode: 0o700, directory: true) else { return }
        for name in ["session.json", "history.json", "bookmarks.json", "diary.sqlite",
                     "diary.sqlite-wal", "diary.sqlite-shm", "certificate-exceptions.json",
                     "snippets.json", "snippet-pastes.json", "kept.json", "spaces.json"] {
            restrict(root.appendingPathComponent(name), mode: 0o600, directory: false)
        }
    }

    @discardableResult private static func restrict(_ file: URL, mode: Int, directory: Bool) -> Bool {
        guard let info = try? FileManager.default.attributesOfItem(atPath: file.path),
              info[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular) else { return false }
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }

    /// A file that didn't decode is set aside rather than overwritten the
    /// next time something is saved over it, bookmarks, history and a
    /// session are the kind of thing nobody wants to lose to a bad read with
    /// no trace of what was there. Failing to move it is fine: the read
    /// already came back empty either way, and there's nothing further to
    /// do about a folder that won't take a rename.
    public static func quarantine(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        // Several unreadable versions can be found within the same second.
        // Each needs its own copy; an older one is never replaced.
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).unreadable-\(stamp)-\(UUID().uuidString).json")
        try? FileManager.default.moveItem(at: file, to: aside)
    }

    /// Settings live apart too: a test that changes what the tabs wear or
    /// where the tabs go must not change yours.
    public static let settings: UserDefaults = {
        guard testing else { return .standard }
        let suite = world == "test" ? "dev.serafim.fast.test" : "dev.serafim.fast.test.\(world ?? "")"
        guard let settings = UserDefaults(suiteName: suite) else {
            preconditionFailure("Cannot open isolated test settings: \(suite)")
        }
        // Unit tests share the test world with the probes, and a probe that
        // came up there as a new Mac left pins In Every Space (m4): every
        // test window then opened with whatever pin the last test left in
        // the shared row. The tests start In Each Space, as on a Mac in use,
        // and a test of the shared pins turns them on itself.
        if unitTests { settings.set(false, forKey: "pins.everySpace") }
        // The same for Today's tabs in every window: off as a choice, so a
        // test's import from Arc (KeptEverywhere.broughtIn) leaves it off
        // for the tests after it.
        if unitTests { settings.set(false, forKey: "tabs.todayEveryWindow") }
        return settings
    }()

    /// A run of the unit tests (`swift test`), not an app.
    public static let unitTests: Bool = {
        let name = ProcessInfo.processInfo.processName
        return name == "xctest" || name.hasPrefix("swiftpm-testing-helper") || Bundle.main.bundlePath.hasSuffix(".xctest")
    }()
}
