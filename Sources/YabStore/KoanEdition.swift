import Foundation

/// Koan's edition of the app. False in this repository, where the code is
/// still Yab's; scripts/custom/brand.py turns it on in the copy Koan is built
/// from (build/branded), and the edits it lays over Yab's files ask it
/// (scripts/custom/koan-edits.json). Yab's own builds never see it on.
public enum KoanEdition {
    public static let on = false
    public static let home = URL(string: "https://github.com/hczr-dev/koan")!
    public static let releases = URL(string: "https://github.com/hczr-dev/koan/releases")!
    public static let issues = URL(string: "https://github.com/hczr-dev/koan/issues/new")!
    /// GitHub's word on the newest release, asked only from Check Now.
    public static let latestRelease = URL(string: "https://api.github.com/repos/hczr-dev/koan/releases/latest")!
}
