import Combine
import Foundation

enum SyncStatus: Equatable {
    case notConfigured
    /// config.json exists but couldn't be used, so the app is running on defaults
    /// rather than on what the file says. Distinct from `notConfigured`, which is
    /// the honest state of a fresh install.
    case configInvalid(String)
    case needsAuth
    case syncing
    /// Carries when the sync happened, or nil if we know we're in sync but have
    /// no record of when — a state file written before the timestamp existed.
    case synced(Date?)
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
        case .offline, .pendingPush, .failed, .needsAuth, .configInvalid: return .red
        case .conflict: return .amber
        case .notConfigured, .syncing: return .grey
        }
    }

    var label: String {
        switch self {
        case .notConfigured: return "Local only"
        case .configInvalid(let reason): return "config.json — \(reason)"
        case .needsAuth: return "Sign in to sync"
        case .syncing: return "Syncing…"
        case .synced(let date):
            guard let date else { return "Synced" }
            let formatter = DateFormatter()
            // A bare "HH:mm" on a sync from days ago reads as minutes ago, so
            // anything outside today gets a date too.
            if Calendar.current.isDateInToday(date) {
                formatter.dateFormat = "HH:mm"
            } else {
                formatter.dateStyle = .short
                formatter.timeStyle = .short
            }
            return "Synced \(formatter.string(from: date))"
        case .pendingPush: return "Unsynced changes"
        case .conflict: return "Conflict — both versions kept"
        case .offline: return "Offline — saved locally"
        case .failed(let message): return message
        }
    }
}

/// Pull on popover open, push on popover close, and push again whenever typing
/// goes idle for `config.autoSyncSeconds`.
///
/// The popover is the only way to edit locally, so local text cannot drift while
/// it's closed. That means at open time local normally equals what we last
/// pushed, and adopting the remote body is safe. The one case that genuinely
/// diverges is editing while offline, then coming back online with the remote
/// also changed — that's the conflict path.
@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var status: SyncStatus = .notConfigured
    /// Read-only from outside; `apply(_:)` is the only way in, so an invalid
    /// config can never be held in memory or reach disk.
    @Published private(set) var config: AppConfig

    /// Validates, then persists. Returns why the config was rejected, or nil if
    /// it was accepted — a no-op change counts as accepted.
    ///
    /// `AppConfig.validate()` is the same check `load()` runs, which is the point:
    /// the settings pane cannot write a file that the next launch would refuse.
    @discardableResult
    func apply(_ newConfig: AppConfig) -> String? {
        if let reason = newConfig.validate() { return reason }
        guard newConfig != config else { return nil }

        config = newConfig
        // A file we wrote ourselves is valid by construction, so a successful
        // write is what clears the complaint about the old one. A failed write
        // leaves it standing, because the bad file is still there.
        if config.save() { configError = nil }
        client.update(config: config)
        refreshIdleStatus()
        return nil
    }

    private let store: NoteStore
    private let client: SyncClient
    private var state: SyncState

    private var editObserver: AnyCancellable?
    private var autoSyncTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?

    /// Why config.json was rejected, if it was. Sticky rather than a one-off
    /// alert: the file is still broken on every subsequent status recomputation,
    /// and it stays broken until something writes a valid one over it.
    private var configError: String?

    init(store: NoteStore) {
        let loaded = AppConfig.load()
        self.store = store
        self.config = loaded.config
        self.configError = loaded.failureReason
        self.state = SyncState.load()
        self.client = SyncClient(config: loaded.config)
        refreshIdleStatus()
        observeEdits()
    }

    private func refreshIdleStatus() {
        // Ahead of `notConfigured`: running on defaults because the file was
        // rejected must not look like a fresh install that has none.
        if let configError { status = .configInvalid(configError); return }
        guard config.isConfigured else { status = .notConfigured; return }
        guard client.hasSession else { status = .needsAuth; return }
        // The persisted timestamp, not `Date()`: this runs on launch and on every
        // config edit, neither of which is a sync.
        status = store.text == state.lastSyncedBody ? .synced(state.lastSyncedAt) : .pendingPush
    }

    var needsPasscode: Bool { config.isConfigured && !client.hasSession }

    /// Whether we hold a session cookie. Not itself `@Published` — it's read
    /// during `body`, and every transition in or out of a session also moves
    /// `status`, which is what triggers the re-render.
    var isSignedIn: Bool { client.hasSession }

    func signOut() {
        client.signOut()
        refreshIdleStatus()
    }

    /// True when local text hasn't reached the server yet, so quitting would
    /// lose it until the next open.
    var hasPendingPush: Bool {
        config.isConfigured && client.hasSession && store.text != state.lastSyncedBody
    }

    // MARK: - Autosync

    /// `@Published` fires in `willSet`, so the hop onto the main actor is what
    /// makes `store.text` read as the value the user just typed rather than the
    /// one before it.
    private func observeEdits() {
        editObserver = store.$text
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.textDidChange() }
            }
    }

    private func textDidChange() {
        autoSyncTask?.cancel()

        guard config.isConfigured, client.hasSession else { return }
        guard store.text != state.lastSyncedBody else { return }

        // Say so immediately: leaving a stale "Synced 14:02" on screen for the
        // whole debounce window is the one moment the light is actively wrong.
        // Only a clean sync is overwritten — a conflict notice or a failure is
        // still true after a keystroke, and this also runs for the text a pull
        // just adopted, which must not stamp over the status the pull set.
        if case .synced = status { status = .pendingPush }

        let delay = config.autoSyncSeconds
        guard delay > 0 else { return }

        autoSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Re-read rather than trusting the captured delay: autosync may have
            // been switched off in settings while this one was waiting.
            guard let self, self.config.autoSyncSeconds > 0 else { return }
            await self.push()
        }
    }

    // MARK: - Sync

    func pullOnOpen() async {
        // Deferred to `refreshIdleStatus` rather than assigning `.notConfigured`
        // here, so opening the popover can't overwrite the config.json complaint
        // with a blander reason for the same silence.
        guard config.isConfigured, client.hasSession else { refreshIdleStatus(); return }

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
                status = .synced(state.lastSyncedAt)
            } else if !localDirty {
                // Local is exactly what we last pushed, so remote always wins.
                store.text = remote.body
                commit(body: remote.body, updatedAt: remote.updatedAt)
                status = .synced(state.lastSyncedAt)
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
        // A debounced push about to fire would duplicate this one.
        autoSyncTask?.cancel()
        await push()
    }

    /// Waits for any push already in flight before starting its own. Autosync,
    /// popover close and quit can all land within a moment of each other, and two
    /// overlapping PATCHes race on `commit`: the loser writes back a stale
    /// `updatedAt`, which the next open then reads as a remote edit and merges.
    private func push() async {
        let inFlight = pushTask
        let task = Task { @MainActor [weak self] in
            await inFlight?.value
            await self?.performPush()
        }
        pushTask = task
        await task.value
    }

    private func performPush() async {
        guard config.isConfigured, client.hasSession else { return }
        guard store.text != state.lastSyncedBody else { return }

        status = .syncing
        do {
            let remote = try await client.pushBody(store.text)
            commit(body: remote.body, updatedAt: remote.updatedAt)
            status = .synced(state.lastSyncedAt)
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
        state = SyncState(lastSyncedBody: body, lastSyncedUpdatedAt: updatedAt, lastSyncedAt: Date())
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
