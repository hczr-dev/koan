import AppIntents
import Foundation

/// Actions for the macOS Shortcuts app. The app's URL and window handoff
/// already handles calls made before its first browser window exists.
struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Page in Yab"
    static let description = IntentDescription("Open a web address in Yab.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Web Address") var address: URL

    func perform() async throws -> some IntentResult {
        guard Bookmark.keepable(address) else { throw OpenPageError.invalidAddress }
        await MainActor.run { Links.take(address) }
        return .result()
    }
}

private enum OpenPageError: Error, LocalizedError {
    case invalidAddress
    var errorDescription: String? { "Enter an HTTP or HTTPS web address." }
}

struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab in Yab"
    static let description = IntentDescription("Open a new tab in Yab.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        await MainActor.run { Links.requestNewTab() }
        return .result()
    }
}

// MARK: - Focus, for app blockers, automations and the Mac's own Focus

private enum FocusIntentError: Error, LocalizedError {
    case locked, wrongKey
    var errorDescription: String? {
        switch self {
        case .locked: "Focus is locked in Yab."
        case .wrongKey: "That key doesn't unlock Focus."
        }
    }
}

struct TurnOnFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Focus in Yab"
    static let description = IntentDescription("Keep the sites on Yab's Focus list closed.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        _ = await MainActor.run { FocusControl.run("on") }
        return .result()
    }
}

struct TurnOffFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Focus in Yab"
    static let description = IntentDescription("Open the sites on Yab's Focus list again, unless Focus is locked.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        guard await MainActor.run(body: { FocusControl.run("off") }) else { throw FocusIntentError.locked }
        return .result()
    }
}

struct LockFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Focus in Yab"
    static let description = IntentDescription("Turn on Focus in Yab and keep it on for a while. With a key, Unlock Focus can end it sooner.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Minutes", default: 60, inclusiveRange: (1, 10080)) var minutes: Int
    @Parameter(title: "Unlock Key") var key: String?

    func perform() async throws -> some IntentResult {
        var command = "lock?minutes=\(minutes)"
        if let key, !key.isEmpty, let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { command += "&key=" + safe }
        _ = await MainActor.run { FocusControl.run(command) }
        return .result()
    }
}

struct UnlockFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Unlock Focus in Yab"
    static let description = IntentDescription("End a Focus lock made with this key.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Unlock Key") var key: String

    func perform() async throws -> some IntentResult {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard await MainActor.run(body: { FocusControl.run("unlock?key=" + safe) }) else { throw FocusIntentError.wrongKey }
        return .result()
    }
}

/// System Settings › Focus › Focus Filters › Yab: the Mac's Focus turns
/// Yab's on, locked until it ends if asked. The system runs this again
/// with the defaults when that Focus ends.
struct YabFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Yab Focus"
    static let description = IntentDescription("Keep the sites on Yab's Focus list closed during this Focus.")

    @Parameter(title: "Block Focus Sites", default: false) var blocks: Bool
    @Parameter(title: "Lock Until This Focus Ends", default: false) var locks: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: blocks ? (locks ? "Focus sites blocked, locked" : "Focus sites blocked") : "Off")
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run { FocusControl.filter(on: blocks, lock: locks) }
        return .result()
    }
}
