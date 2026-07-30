import Foundation

/// The single persistent scratchpad. Writes are debounced so that typing doesn't
/// hit the disk on every keystroke; `flush()` forces a write at moments where we
/// might not get another chance (popover closing, app terminating).
final class NoteStore: ObservableObject {
    @Published var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            scheduleSave()
        }
    }

    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?
    private let saveDelay: TimeInterval = 0.5

    init() {
        fileURL = AppPaths.note
        load()
    }

    private func load() {
        guard let loaded = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        // Assigning here trips `didSet` and schedules a redundant save; harmless,
        // and cheaper than routing loads around the published property.
        text = loaded
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = text
        let work = DispatchWorkItem { [fileURL] in
            try? snapshot.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Write immediately, cancelling any debounced save.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
