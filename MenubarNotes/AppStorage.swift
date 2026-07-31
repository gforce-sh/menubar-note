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

/// Server address and the id of the single remote note we mirror.
struct AppConfig: Codable, Equatable {
    var serverURL: String = "http://localhost:3001"
    var noteID: String = ""

    var isConfigured: Bool { !noteID.isEmpty && URL(string: serverURL) != nil }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: AppPaths.config),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: AppPaths.config, options: .atomic)
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
