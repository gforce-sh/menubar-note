import SwiftUI

@main
struct MenubarNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app has no windows: everything lives in the status item's popover.
        // `Settings` is the only scene type that doesn't create a window on launch.
        Settings {
            EmptyView()
        }
    }
}
