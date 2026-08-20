import SwiftUI

struct NoteView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var engine: SyncEngine
    @FocusState private var editorFocused: Bool

    /// Settings replace the note in place rather than arriving as a sheet: a
    /// popover window can't host one properly, and a transient popover can be
    /// dismissed out from under it, leaving an invisible modal that swallows
    /// every click.
    @State private var showingSettings = false

    /// Set by the delegate each time the popover opens, so the editor can
    /// re-take focus on every show rather than only on first appearance.
    let focusToken: Int

    /// Whether outside clicks are ignored while the popover is open. Owned by
    /// the delegate, not local `@State`, so it survives this view being
    /// recreated on every open rather than resetting each time.
    @ObservedObject var pinState: PinState

    var body: some View {
        Group {
            if showingSettings {
                // Fills the popover rather than being pinned to the top: the
                // form now scrolls, so it needs to know how much height it has.
                SettingsView(engine: engine) { closeSettings() }
            } else {
                notePage
            }
        }
        .frame(width: 340, height: 420)
        .onAppear { editorFocused = true }
        .onChange(of: focusToken) {
            // This state outlives a popover dismissal, so a close while settings
            // were open would otherwise reopen straight back into them.
            showingSettings = false
            // Focus can't be taken while the popover is still animating in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                editorFocused = true
            }
        }
    }

    private func closeSettings() {
        showingSettings = false
        editorFocused = true
    }

    private var notePage: some View {
        VStack(spacing: 0) {
            InsetTextEditor(
                text: $store.text,
                font: .systemFont(ofSize: 13),
                horizontalInset: 16,
                isFocused: Binding(
                    get: { editorFocused },
                    set: { editorFocused = $0 }
                )
            )
            .padding(.top, 12)
            .padding(.bottom, 4)

            Divider()

            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(lightColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(engine.status.label)

                    Text(engine.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(engine.status.label)

                Spacer()

                Button {
                    pinState.isPinned.toggle()
                } label: {
                    Image(systemName: pinState.isPinned ? "pin.fill" : "pin")
                }
                .help(pinState.isPinned ? "Unpin (click outside to close)" : "Pin (stay open when clicking outside)")

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Sync settings")

                Button("Clear") {
                    store.text = ""
                    editorFocused = true
                }
                .disabled(store.text.isEmpty)

                Button("Quit") {
                    store.flush()
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private var lightColor: Color {
        switch engine.status.light {
        case .green: return .green
        case .red: return .red
        case .amber: return .orange
        case .grey: return .secondary
        }
    }
}
