import Foundation

// Koan: with WebKit the default engine, Chromium runs only for what is sent
// to it. Left with nothing to show for a few minutes, its helper and the
// processes under it (GPU, network, storage, renderers: about 250 MB) are
// put down (ChromiumProcess.restIfUnused), and the next page that wants
// Chromium starts it again, as at a cold launch. With Chromium the default
// engine it stays up, as Yab has it.
@MainActor
enum ChromiumRest {
    /// How long nothing of Chromium's is in use before it is put down;
    /// `chromium.rest.after` in seconds, for a test world.
    static var after: TimeInterval {
        let set = Store.settings.double(forKey: "chromium.rest.after")
        return set > 0 ? set : 3 * 60
    }

    /// How often that is looked at.
    static var look: TimeInterval { min(30, max(1, after / 6)) }

    /// Not while Chromium is the default engine, in unit tests or headless,
    /// nor with `chromium.rest` set to false.
    static var allowed: Bool {
        !PageEngineFactory.chromiumEnabled && !Store.unitTests && !Headless.on
            && (Store.settings.object(forKey: "chromium.rest") as? Bool ?? true)
    }
}
