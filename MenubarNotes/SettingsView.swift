import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: SyncEngine
    /// Closes the settings window. Owned by the delegate, since AppKit windows
    /// aren't driven by SwiftUI presentation state.
    let onDone: () -> Void

    @State private var serverURL: String = ""
    @State private var noteID: String = ""
    @State private var passcode: String = ""
    @State private var signingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Server URL").font(.caption).foregroundStyle(.secondary)
                TextField("http://localhost:3001", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Note ID").font(.caption).foregroundStyle(.secondary)
                TextField("paste the remote note id", text: $noteID)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isSignedIn ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(engine.isSignedIn ? "Signed in" : "Not signed in")
                        .font(.caption)
                        .foregroundStyle(engine.isSignedIn ? .primary : .secondary)
                    Spacer()
                    if engine.isSignedIn {
                        Button("Sign out") { engine.signOut() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }

                Text("Passcode").font(.caption).foregroundStyle(.secondary)
                HStack {
                    SecureField("4 digits", text: $passcode)
                        .textFieldStyle(.roundedBorder)
                    Button("Sign in") {
                        Task {
                            signingIn = true
                            save()
                            await engine.signIn(passcode: passcode)
                            passcode = ""
                            signingIn = false
                        }
                    }
                    .disabled(passcode.count != 4 || signingIn)
                }
                // The server locks every user out for an hour after five failed
                // guesses, so this is worth saying out loud next to the field.
                Text("Five wrong attempts lock the server for an hour. Nothing is retried automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(engine.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") {
                    save()
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear {
            serverURL = engine.config.serverURL
            noteID = engine.config.noteID
        }
        // The window can also be closed with ⌘W or the red button, which never
        // reaches "Done", so persist here too. `save` is idempotent — the config
        // setter ignores a write that changes nothing.
        .onDisappear { save() }
    }

    private func save() {
        var updated = engine.config
        updated.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.noteID = noteID.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.config = updated
    }
}
