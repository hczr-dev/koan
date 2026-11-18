import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// What an odd label asks, "Where can we find you online?", "What do you
// do at your day job?", guessed by the Mac's own model (macOS 26 and on)
// once per label in your life, then remembered: the next form that asks
// it knows at once. The page's words never leave the Mac.
//
// A label comes back as a profile key, "question" for one only words
// answer (a draft), or "none". It runs after the list is up, never in
// front of it: a label learned while you look turns into one more box
// the row fills.
//
// Measured: on the main Mac (macOS 27) a label in 0.5 to 1 s; on adhd, an
// M1 Pro on macOS 26.4, either 0.5 s or 3.5 s, nothing between. Ten labels
// in one request took 2.2 s and dropped one, so it asks one at a time.

enum FormModel {
    /// What each label asks, by its plain words: a profile key, "question" or "none".
    nonisolated(unsafe) static var known: [String: String] = load()
    nonisolated(unsafe) private static var asking: Set<String> = []
    /// What the model last said or threw, for the bench.
    nonisolated(unsafe) static var last = ""

    static var file: URL { Store.file("form-labels.json") }

    private static func load() -> [String: String] {
        (try? Data(contentsOf: Store.file("form-labels.json"))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private static func save() {
        guard let data = try? JSONEncoder().encode(known) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Whether the Mac has a model to ask, read again at most every few
    /// seconds. Each read of the system's answer decodes a JSON asset
    /// (about 1 ms), and the column's kept line reads it in its body:
    /// with 287 tabs, 4 to 6% of the main thread's time picking a tab
    /// or a space went there (row 1123).
    static var ready: Bool {
        AppleModelAccess.permits { hardwareReady }
    }

    /// Tidy has its own switch; other AI choices do not disable its local model.
    /// With AI in Yab Off, no tidying either: Off means the Mac's model too.
    static var tidyReady: Bool { AIUse.allows(.asked) && permitsTidy { hardwareReady } }

    static func permitsTidy(availability: () -> Bool) -> Bool { availability() }

    private static var hardwareReady: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        readyLock.lock(); defer { readyLock.unlock() }
        if let known = readyKnown, now - known.at < 5 { return known.ready }
        let ready = readyNow
        readyKnown = (now, ready)
        return ready
    }
    private static let readyLock = NSLock()
    nonisolated(unsafe) private static var readyKnown: (at: TimeInterval, ready: Bool)?

    private static var readyNow: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why the Mac has no model to ask, in words; nil when it has one.
    static var why: String? {
        guard AIUse.level() != .off else { return "AI is off in Yab" }
        guard AppleModelAccess.enabled else { return "Apple Intelligence is disabled in Yab" }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This Mac can't run Apple Intelligence"
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off in System Settings"
            case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading"
            default: return "Apple Intelligence isn't available"
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26"
    }

    /// Asks about the labels nobody has asked about yet, one after another
    /// in one session (a session of its own per label got "Company size"
    /// as a company and "Pronouns" as a bio; one shared got all ten of the
    /// check's right, 0.6 to 1 s each), and calls `learned` each time one
    /// turns out to be something, so the row grows as it goes.
    @MainActor
    static func look(_ fields: [FormField], learned: @escaping () -> Void) {
        let labels = Array(Set(fields.map { FormAnswers.normal($0.label) }))
            .filter { !$0.isEmpty && $0.count <= 200 && known[$0] == nil && !asking.contains($0) }
        guard !labels.isEmpty, ready else { return }
        asking.formUnion(labels)
        Task.detached(priority: .utility) {
            let session = Asker()
            for label in labels {
                guard ready else {
                    await MainActor.run { asking.subtract(labels) }
                    return
                }
                let said = await session.ask(label)
                await MainActor.run {
                    asking.remove(label)
                    guard AppleModelAccess.usable() else { return }
                    known[label] = said
                    save()
                    if said != "none" { learned() }
                }
            }
        }
    }

    static let instructions = """
    A web form asks the person a question. Say what answers it: one key.
    name, headline, company, role (their job: title, occupation, what they do for a living, their day job), location, linkedin, x (Twitter), github, \
    website (their own site or where to find them online), telegram, instagram, bio (a line about them), \
    working (the project or product they are building now, not their job), languages (the languages they speak), timezone: \
    a fact about the person.
    question: it wants a few sentences only the person can write, a why or a what.
    none: anything else, a choice, a number, a date, money, an id, a size, a yes or no.
    Examples: "What do you do for a living" is role. "Employer" is company. "Personal site or portfolio" is website. \
    "Twitter handle" is x. "Short intro" is bio. "Why do you want to attend?" is question. "Shirt size" is none.
    """

    /// One session for a run of labels.
    final class Asker: @unchecked Sendable {
        #if canImport(FoundationModels)
        private let held: Any?
        init() {
            if #available(macOS 26, *), FormModel.ready { held = LanguageModelSession(instructions: FormModel.instructions) } else { held = nil }
        }
        #else
        init() {}
        #endif

        func ask(_ label: String) async -> String {
            guard FormModel.ready else { return "none" }
            #if canImport(FoundationModels)
            if #available(macOS 26, *), let session = held as? LanguageModelSession {
                do {
                    // Greedy: the same label gets the same key every time.
                    let answer = try await session.respond(to: "Question: \(label)", generating: Guess.self,
                                                           options: GenerationOptions(sampling: .greedy))
                    let key = answer.content.key.rawValue
                    FormModel.last = "\(label) → \(key)"
                    return Profile.keys.contains(key) || key == "question" ? key : "none"
                } catch {
                    FormModel.last = "\(label) → error \(error)"
                    return "none"
                }
            }
            #endif
            return "none"
        }
    }

    static func forget() {
        known = [:]
        try? FileManager.default.removeItem(at: file)
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct Guess {
    /// One of these and nothing else: generation is held to the cases.
    @Guide(description: "What answers the question")
    var key: Key
}

@available(macOS 26, *)
@Generable
enum Key: String {
    case name, headline, company, role, location, linkedin, x, github, website, telegram, instagram, bio, working, languages, timezone, question, none
}
#endif
