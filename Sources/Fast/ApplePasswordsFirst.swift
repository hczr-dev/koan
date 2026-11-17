import Foundation

/// The custom build's passwords are Apple's. Once macOS lets this Yab run
/// Apple's helper (signed with the browser entitlement, see
/// scripts/custom/build-dev.sh and ~/.config/yab-dev/signing.env), Apple
/// Passwords is connected on the first launch that can, paired with the code
/// Passwords shows, Yab's own passwords are offered into it once
/// (PasswordsToApple), and Yab's own vault goes off: Apple Passwords alone
/// fills and saves, in WebKit and Chromium tabs alike.
@MainActor
enum ApplePasswordsFirst {
    static let doneKey = "custom.applePasswordsFirst"

    static func start() {
        guard !Store.testing, !Store.unitTests, ApplePasswords.mayRun else { return }
        let connections = PasswordManagers.Connections.shared
        if connections.connection(PasswordManagers.apple) == nil {
            connections.connect(PasswordManagers.apple, mode: .you, pair: true)
        }
        guard !Store.settings.bool(forKey: doneKey) else { return }
        Task { @MainActor in
            // As long as the code takes to be read off Passwords and typed.
            for _ in 0..<900 {
                if await ApplePasswords.shared.isPaired { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard await ApplePasswords.shared.isPaired else { return }
            for browser in BrowserWindows.shared.browsers where browser.prefs.usesYabPasswords {
                browser.prefs.usesYabPasswords = false
            }
            Store.settings.set(false, forKey: "passwords.yab")
            Store.settings.set(true, forKey: doneKey)
        }
    }
}
