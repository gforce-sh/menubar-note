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

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(engine: engine) { closeSettings() }
                    // Pinned to the top; the form is shorter than the popover.
                    .frame(maxHeight: .infinity, alignment: .top)
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
            TextEditor(text: $store.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                // TextEditor carries a ~5pt internal inset on the leading edge only,
                // so trim the leading pad to keep the text visually centred.
                .padding(.top, 12)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .padding(.bottom, 4)
                .focused($editorFocused)

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
