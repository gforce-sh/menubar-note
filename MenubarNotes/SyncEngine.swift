import Foundation

enum SyncStatus: Equatable {
    case notConfigured
    case needsAuth
    case syncing
    case synced(Date)
    case pendingPush
    case conflict
    case offline
    case failed(String)

    /// Whether the local note is known to be safely on the server. Anything that
    /// isn't a clean sync reads as "not pushed", since that's the state worth
    /// noticing at a glance.
    enum Light {
        case green, red, amber, grey
    }

    var light: Light {
        switch self {
        case .synced: return .green
        case .offline, .pendingPush, .failed, .needsAuth: return .red
        case .conflict: return .amber
        case .notConfigured, .syncing: return .grey
        }
    }

    var label: String {
        switch self {
        case .notConfigured: return "Local only"
        case .needsAuth: return "Sign in to sync"
        case .syncing: return "Syncing…"
        case .synced(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "Synced \(formatter.string(from: date))"
        case .pendingPush: return "Unsynced changes"
        case .conflict: return "Conflict — both versions kept"
        case .offline: return "Offline — saved locally"
        case .failed(let message): return message
        }
    }
}

/// Pull on popover open, push on popover close.
///
/// The popover is the only way to edit locally, so local text cannot drift while
/// it's closed. That means at open time local normally equals what we last
/// pushed, and adopting the remote body is safe. The one case that genuinely
/// diverges is editing while offline, then coming back online with the remote
/// also changed — that's the conflict path.
@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var status: SyncStatus = .notConfigured
    @Published var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            config.save()
            client.update(config: config)
            refreshIdleStatus()
        }
    }

    private let store: NoteStore
    private let client: SyncClient
    private var state: SyncState

    init(store: NoteStore) {
        let loaded = AppConfig.load()
        self.store = store
        self.config = loaded
        self.state = SyncState.load()
        self.client = SyncClient(config: loaded)
        refreshIdleStatus()
    }

    private func refreshIdleStatus() {
        guard config.isConfigured else { status = .notConfigured; return }
        guard client.hasSession else { status = .needsAuth; return }
        status = store.text == state.lastSyncedBody ? .synced(Date()) : .pendingPush
    }

    var needsPasscode: Bool { config.isConfigured && !client.hasSession }

    /// True when local text hasn't reached the server yet, so quitting would
    /// lose it until the next open.
    var hasPendingPush: Bool {
        config.isConfigured && client.hasSession && store.text != state.lastSyncedBody
    }

    // MARK: - Sync

    func pullOnOpen() async {
        guard config.isConfigured else { status = .notConfigured; return }
        guard client.hasSession else { status = .needsAuth; return }

        status = .syncing
        do {
            let remote = try await client.fetchNote()
            let localDirty = store.text != state.lastSyncedBody
            let remoteMoved = remote.updatedAt != state.lastSyncedUpdatedAt
            let firstSync = state.lastSyncedUpdatedAt == 0

            if firstSync {
                // Nothing has ever synced, so there's no baseline to diff against
                // and every local byte would otherwise read as an edit. Remote is
                // treated as the truth; whatever was in the local note is replaced.
                store.text = remote.body
                commit(body: remote.body, updatedAt: remote.updatedAt)
                status = .synced(Date())
            } else if !localDirty {
                // Local is exactly what we last pushed, so remote always wins.
                store.text = remote.body
                commit(body: remote.body, updatedAt: remote.updatedAt)
                status = .synced(Date())
            } else if !remoteMoved {
                // Only we changed; the close handler will push it.
                status = .pendingPush
            } else {
                store.text = ConflictMerge.merge(
                    local: store.text,
                    localDate: Date(),
                    remote: remote.body,
                    remoteDate: Date(timeIntervalSince1970: TimeInterval(remote.updatedAt) / 1000)
                )
                // Deliberately not committed: the merged body is now a local edit
                // that must be pushed on close so both sides end up identical.
                status = .conflict
            }
        } catch {
            status = describe(error)
        }
    }

    func pushOnClose() async {
        guard config.isConfigured, client.hasSession else { return }
        guard store.text != state.lastSyncedBody else { return }

        status = .syncing
        do {
            let remote = try await client.pushBody(store.text)
            commit(body: remote.body, updatedAt: remote.updatedAt)
            status = .synced(Date())
        } catch {
            status = describe(error)
        }
    }

    /// Exchanges a passcode for a session, then pulls. Never called automatically:
    /// five failed passcodes lock every user out of the server for an hour, so
    /// this only ever runs in response to the user pressing the button.
    func signIn(passcode: String) async {
        status = .syncing
        do {
            try await client.login(passcode: passcode)
            await pullOnOpen()
        } catch {
            status = describe(error)
        }
    }

    private func commit(body: String, updatedAt: Int) {
        state = SyncState(lastSyncedBody: body, lastSyncedUpdatedAt: updatedAt)
        state.save()
    }

    private func describe(_ error: Error) -> SyncStatus {
        guard let error = error as? SyncError else { return .failed("Sync failed") }
        switch error {
        case .offline: return .offline
        case .unauthorized: return .needsAuth
        case .badPasscode: return .failed("Wrong passcode — not retried")
        case .locked: return .failed("Server locked out — try later")
        case .notFound: return .failed("Note not found on server")
        case .server(let code): return .failed("Server error \(code)")
        case .malformedResponse: return .failed("Unexpected server response")
        }
    }
}
