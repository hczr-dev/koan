import Foundation

/// Where a slow page load spends its time. One line per step, to
/// ~/Library/Logs/Koan/load-times.log: the time, the seconds since the load
/// began (Return pressed, or the page's navigation asked for), the site's
/// host and what happened. Hosts only: no address, no search words.
///
///     10:57:03.412  +0.000  return
///     10:57:03.430  +0.018  www.google.com  policy asked
///     10:57:03.452  +0.040  www.google.com  sign-ins ready
///     10:57:08.431  +5.019  www.google.com  engine routed
///     10:57:08.480  +5.068  www.google.com  cookies prepared
///     10:57:08.510  +5.098  www.google.com  allowed
///     10:57:08.700  +5.288  www.google.com  started
///     10:57:08.900  +5.488  www.google.com  committed
///     10:57:09.400  +5.988  www.google.com  finished
///
/// A step that took more than a second is marked SLOW.
enum LoadTrace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var starts: [Int: Date] = [:]
    nonisolated(unsafe) private static var lastReturn: Date?
    nonisolated(unsafe) private static var lastStep: [Int: Date] = [:]
    private static let queue = DispatchQueue(label: "koan.load-trace", qos: .utility)
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private static let file: URL = {
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Koan", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("load-times.log")
    }()

    /// Return pressed in the field.
    static func returned() {
        let now = Date()
        lock.lock(); lastReturn = now; lock.unlock()
        write(now, since: now, text: "return")
    }

    /// A navigation of `page` began: the clock for its lines starts here,
    /// or at the last Return when that was just before.
    static func begin(_ page: AnyObject, _ url: URL?) {
        let now = Date()
        lock.lock()
        let start = lastReturn.flatMap { now.timeIntervalSince($0) < 10 ? $0 : nil } ?? now
        starts[ObjectIdentifier(page).hashValue] = start
        lastStep[ObjectIdentifier(page).hashValue] = now
        lastReturn = nil
        lock.unlock()
        write(now, since: start, text: "\(host(url))  policy asked")
    }

    static func mark(_ page: AnyObject, _ url: URL?, _ what: String) {
        let now = Date()
        let id = ObjectIdentifier(page).hashValue
        lock.lock()
        guard let start = starts[id] else { lock.unlock(); return }
        let step = now.timeIntervalSince(lastStep[id] ?? now)
        lastStep[id] = now
        lock.unlock()
        write(now, since: start, text: "\(host(url))  \(what)\(step > 1 ? "  SLOW (\(String(format: "%.1f", step)) s)" : "")")
    }

    private static func host(_ url: URL?) -> String {
        url?.host(percentEncoded: false) ?? url?.scheme ?? "?"
    }

    private static func write(_ now: Date, since start: Date, text: String) {
        let line = "\(stamp.string(from: now))  +\(String(format: "%.3f", now.timeIntervalSince(start)))  \(text)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: file)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
    }
}
