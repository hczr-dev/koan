import AppKit
import SwiftUI

/// Koan's updates are its releases on GitHub. Yab's updater has no feed in
/// Koan's builds, so Settings › General asks GitHub, only when Check Now is
/// pressed, and a newer release opens its page to download.
@MainActor
final class KoanUpdates: ObservableObject {
    static let shared = KoanUpdates()

    enum State: Equatable {
        case idle, checking, failed
        case upToDate(Date)
        case available(version: String, page: URL)
    }

    @Published private(set) var state: State = .idle

    func check() {
        guard state != .checking else { return }
        state = .checking
        Task {
            var request = URLRequest(url: KoanEdition.latestRelease, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                state = .failed
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? KoanEdition.releases
            state = Self.newer(version, than: Updater.version) ? .available(version: version, page: page) : .upToDate(Date())
        }
    }

    /// Dotted numbers, compared part by part: 0.48.1 is newer than 0.47.19.
    nonisolated static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Settings › General's first row in Koan: the version, and GitHub's newest.
struct KoanUpdateRow: View {
    @ObservedObject private var updates = KoanUpdates.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .settingsAnchor("updates")
    }

    private var title: String {
        if case .available(let version, _) = updates.state { return "Koan \(version) is available" }
        return "Koan \(Updater.version)"
    }

    private var detail: String {
        switch updates.state {
        case .idle: return "New versions come out on GitHub."
        case .checking: return "Asking GitHub…"
        case .failed: return "GitHub didn't answer. Try again in a moment."
        case .upToDate(let at): return "Up to date. Checked \(at.formatted(.relative(presentation: .named)))."
        case .available: return "Download it, then put it in Applications in place of this one."
        }
    }

    @ViewBuilder private var control: some View {
        if case .available(_, let page) = updates.state {
            Button("Download") { NSWorkspace.shared.open(page) }
                .settingsButton()
        } else {
            Button(updates.state == .checking ? "Checking…" : "Check Now") { updates.check() }
                .settingsButton()
                .disabled(updates.state == .checking)
        }
    }
}
