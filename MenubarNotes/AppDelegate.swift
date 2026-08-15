import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = NoteStore()
    private lazy var engine = SyncEngine(store: store)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hostingController: NSHostingController<NoteView>!

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var escapeMonitor: Any?
    private var focusToken = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside LSUIElement: no Dock tile, no ⌘-Tab entry.
        NSApp.setActivationPolicy(.accessory)

        hostingController = NSHostingController(rootView: makeNoteView())
        popover.contentViewController = hostingController
        // .applicationDefined means AppKit never auto-dismisses on an outside
        // click or app deactivation — closing is entirely up to us, via the
        // status item click, the hotkey, or Escape.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let icon = NSImage(named: "MenubarIcon")
            icon?.size = NSSize(width: 18, height: 18)
            // Template rendering lets AppKit invert the glyph for light/dark
            // menu bars and highlight it on click, so no per-appearance artwork.
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        registerHotKey()
    }

    /// Holds the quit open long enough to finish an outstanding push. Without
    /// this the PATCH is fire-and-forget: closing the popover and immediately
    /// quitting kills the request mid-flight, and the edit sits unsynced until
    /// the next open.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.flush()
        guard engine.hasPendingPush else { return .terminateNow }

        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        Task {
            await engine.pushOnClose()
            reply()
        }

        // A hung or very slow server must not make the app un-quittable, so the
        // wait is capped well below URLSession's own 10s timeout.
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            reply()
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
        unregisterHotKey()
    }

    // MARK: - Popover

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        // Deferred, not `togglePopover` directly: menu items fire while the menu
        // is still tracking, and showing the popover inside that nested run loop
        // leaves it on screen but not receiving events.
        menu.addItem(withTitle: "Open Notes", action: #selector(togglePopoverDeferred), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MenubarNotes", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }

        // Attaching the menu makes the next click open it; detach immediately
        // afterwards so left-clicks keep going to our action instead.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePopoverDeferred() {
        DispatchQueue.main.async { [weak self] in self?.togglePopover() }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func makeNoteView() -> NoteView {
        NoteView(store: store, engine: engine, focusToken: focusToken)
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }

        focusToken += 1
        hostingController.rootView = makeNoteView()

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the popover appears but keyboard input goes elsewhere,
        // since an accessory app isn't frontmost when the status item is clicked.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        // Any monitor from a previous show must go first: re-entering this method
        // without a close in between would otherwise stack them and leak.
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            self?.closePopover()
            return nil
        }

        // Pull after the popover is on screen so the fetch never delays it
        // appearing; on failure the local text simply stays as it was.
        Task { await engine.pullOnOpen() }
    }

    private func closePopover() {
        // Teardown lives in the `NSPopoverDelegate` callback rather than here
        // so it still runs if the popover is ever dismissed by some path other
        // than this method.
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        store.flush()
        Task { await engine.pushOnClose() }
        removeEscapeMonitor()
    }

    private func removeEscapeMonitor() {
        guard let monitor = escapeMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escapeMonitor = nil
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Global hotkey (⌥⇧N)

    /// Carbon's hot key API is the only way to get a system-wide shortcut without
    /// requiring the user to grant Accessibility permission. It's ancient but
    /// undeprecated, and the modern replacements all need that entitlement.
    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePopover() }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D42_4E54), id: 1) // 'MBNT'
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            UInt32(optionKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            // Most likely another app already owns ⌥⇧N. The status item still works.
            NSLog("MenubarNotes: could not register ⌥⇧N hotkey (OSStatus \(status))")
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
    }
}
