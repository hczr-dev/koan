import Foundation

/// One tab plays at a time (Settings › Tabs › Pause other tabs when one
/// plays): a tab starting to make sound pauses the others that are, unless
/// they are muted or in a call, their camera or microphone on.
@MainActor
enum MediaSolo {
    static let key = "media.solo"
    static var on: Bool { Store.settings.object(forKey: key) as? Bool ?? true }

    static func started(_ tab: Tab) {
        guard on else { return }
        for other in Tab.every where other !== tab && other.noisy && !other.muted
            && other.camera == .none && other.microphone == .none {
            // WebKit's own pause reaches every video and sound in the page,
            // ones macOS doesn't list as Now Playing too; Chromium's goes
            // through its now playing session.
            if let web = other.builtPage?.webKit { web.pauseAllMediaPlayback(completionHandler: nil) }
            other.tuneWatch.want(playing: false)
        }
    }
}
