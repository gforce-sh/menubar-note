import Foundation

/// Everything the app persists lives in one directory, in plain files, so it can
/// be inspected and edited by hand.
enum AppPaths {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("MenubarNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static var note: URL { directory.appendingPathComponent("note.txt") }
    static var config: URL { directory.appendingPathComponent("config.json") }
    static var session: URL { directory.appendingPathComponent("session.txt") }
    static var syncState: URL { directory.appendingPathComponent("sync-state.json") }
}

/// Server address, the routes to reach it by, and the id of the single remote
/// note we mirror.
///
/// The routes are configuration rather than code so that a server that renames
/// or re-versions its endpoints doesn't require a new build. That only stretches
/// so far: the HTTP methods, the request and response payload shapes, and the
/// cookie-based auth are all still hard-coded in `SyncClient`. See CONFIG.md.
struct AppConfig: Codable, Equatable {
    var serverURL: String = "http://localhost:3001"
    var noteID: String = ""
    /// Full paths, including whatever API prefix the server uses. Kept whole
    /// rather than split into a shared prefix plus a suffix so that a server
    /// putting login outside its version prefix stays expressible.
    var loginPath: String = "/api/v1/login"
    /// Must contain `noteIDPlaceholder`, which is substituted per request.
    var notePath: String = "/api/v1/notes/\(AppConfig.noteIDPlaceholder)"
    /// Seconds of idle typing before the note is pushed automatically. Zero turns
    /// autosync off, leaving the original behaviour: push on close and on quit.
    var autoSyncSeconds: Double = 2

    static let noteIDPlaceholder = "{noteID}"

    /// Whether there is enough here to talk to a server at all. Distinct from
    /// `validate()`: an empty `noteID` is a fresh install, not a broken file.
    var isConfigured: Bool { !noteID.isEmpty && validate() == nil }

    /// The single definition of a usable config, shared by `load()` and by the
    /// settings pane so the two can't disagree about what "valid" means.
    /// Returns nil when the config is fine, or a short reason phrased to read
    /// after "config.json — ".
    ///
    /// An empty `noteID` passes deliberately. That is a fresh install with
    /// nothing set up yet, which `isConfigured` reports as *Local only*; calling
    /// it invalid would greet every new user with an error about a file they
    /// have never seen.
    func validate() -> String? {
        guard let url = URL(string: serverURL), url.scheme != nil, url.host != nil else {
            return "serverURL needs a scheme and a host"
        }
        if !noteID.isEmpty {
            // The one character `appendPathComponent` passes through unescaped,
            // so a slash here silently invents extra path segments. Rejected
            // rather than encoded, which keeps the URL builder free of special
            // cases and turns a mistyped id into a visible complaint.
            guard !noteID.contains("/") else { return #"noteID must not contain "/""# }
            // Survives unescaped too, and normalises away a path segment.
            guard noteID != ".", noteID != ".." else { return #"noteID must not be "\#(noteID)""# }
        }
        guard !Self.pathComponents(loginPath).isEmpty else { return "loginPath is empty" }
        guard !Self.pathComponents(notePath).isEmpty else { return "notePath is empty" }
        guard notePath.contains(Self.noteIDPlaceholder) else {
            return "notePath must contain \(Self.noteIDPlaceholder)"
        }
        guard autoSyncSeconds >= 0 else { return "autoSyncSeconds must not be negative" }
        return nil
    }

    /// Splitting on "/" and dropping the empties is what makes leading and
    /// trailing slashes irrelevant, so "/api/v1/login", "api/v1/login" and
    /// "api/v1/login/" are all the same route and none of them is worth
    /// complaining about.
    ///
    /// Blank components go too, so a hand-edited path of all spaces reads as
    /// empty here rather than as one segment that would be sent as "%20%20%20".
    /// Only wholly-blank components are dropped: a route with a space in it is
    /// unusual but legal, and percent-encodes correctly.
    static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// config.json is the single source of truth, so decoding is all-or-nothing:
    /// every key must be present. A file missing one is not partially adopted,
    /// it is rejected whole. See CONFIG.md.
    ///
    /// The absent and the unusable cases are kept apart deliberately. Both fall
    /// back to the defaults above, but only one of them is a fresh install worth
    /// saying nothing about; the other is a file the user is expected to edit by
    /// hand, where the complaint is the only clue to what went wrong.
    static func load() -> ConfigLoad {
        let url = AppPaths.config
        guard FileManager.default.fileExists(atPath: url.path) else { return .firstRun }

        let config: AppConfig
        do {
            config = try JSONDecoder().decode(AppConfig.self, from: try Data(contentsOf: url))
        } catch {
            return .invalid(Self.complain(Self.reason(for: error), about: url))
        }

        // Decoding proves the shape, not the meaning: every key can be present
        // and well-typed while still describing a route that can't be built.
        if let reason = config.validate() {
            return .invalid(Self.complain(reason, about: url))
        }
        return .loaded(config)
    }

    private static func complain(_ reason: String, about url: URL) -> String {
        NSLog("MenubarNotes: ignoring \(url.path) — \(reason)")
        return reason
    }

    /// `DecodingError` names the offending key, which is the whole point of
    /// reading the error rather than discarding it — but its `localizedDescription`
    /// is boilerplate, so the useful part is pulled out by hand.
    private static func reason(for error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .keyNotFound(let key, _):
            return "missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let key = context.codingPath.map(\.stringValue).joined(separator: ".")
            return key.isEmpty ? "wrong value type" : "wrong type for \"\(key)\""
        case .dataCorrupted:
            return "not valid JSON"
        @unknown default:
            return "unreadable"
        }
    }

    /// Reports whether the file was actually replaced, so callers don't clear a
    /// "config is broken" state on the strength of a write that never landed.
    @discardableResult
    func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        do {
            try data.write(to: AppPaths.config, options: .atomic)
            return true
        } catch {
            NSLog("MenubarNotes: could not write \(AppPaths.config.path) — \(error.localizedDescription)")
            return false
        }
    }
}

/// The outcome of reading config.json. `firstRun` and `invalid` both run on
/// `AppConfig()` defaults: a menubar app that refuses to launch leaves the user
/// with a crash dialog and no window, so the scratchpad stays usable local-only
/// either way. The difference is whether anyone is told.
enum ConfigLoad {
    case firstRun
    case loaded(AppConfig)
    case invalid(String)

    var config: AppConfig {
        guard case .loaded(let config) = self else { return AppConfig() }
        return config
    }

    var failureReason: String? {
        guard case .invalid(let reason) = self else { return nil }
        return reason
    }
}

/// The `session` cookie value, kept as an opaque string. Written 0600 because it
/// is a bearer credential for the remote server.
enum SessionStore {
    static func load() -> String? {
        guard let raw = try? String(contentsOf: AppPaths.session, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func save(_ token: String) {
        try? token.write(to: AppPaths.session, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AppPaths.session.path
        )
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppPaths.session)
    }
}

/// What we believe both sides looked like at the end of the last successful sync.
/// Divergence from this is how a local or remote edit is detected: there is no
/// ETag or version column on the server to compare against.
struct SyncState: Codable, Equatable {
    var lastSyncedBody: String = ""
    var lastSyncedUpdatedAt: Int = 0
    /// When we last completed a sync, as opposed to `lastSyncedUpdatedAt`, which
    /// is the server's own clock. Optional so state files written before this
    /// field existed still decode.
    var lastSyncedAt: Date?

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: AppPaths.syncState),
              let decoded = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return SyncState() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: AppPaths.syncState, options: .atomic)
    }
}
