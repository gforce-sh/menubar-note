import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: SyncEngine
    /// Returns to the note. Owned by the parent, which holds the flag deciding
    /// which of the two pages the popover is showing.
    let onDone: () -> Void

    @State private var serverURL: String = ""
    @State private var noteID: String = ""
    @State private var loginPath: String = ""
    @State private var notePath: String = ""
    @State private var autoSyncSeconds: String = ""
    @State private var passcode: String = ""
    @State private var signingIn = false

    /// Why the last save attempt was refused. Takes over the footer from the
    /// sync status, since a rejected edit is more urgent than how long ago the
    /// last push was.
    @State private var validationError: String?

    var body: some View {
        // Title and footer sit outside the scroll view: the Done button is the
        // primary action here, and one that scrolls out of sight is one the user
        // has to go looking for.
        VStack(alignment: .leading, spacing: 0) {
            Text("Sync settings")
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Server URL", placeholder: "https://example.com", text: $serverURL)
                    field("Note ID", placeholder: "paste the remote note id", text: $noteID)
                    autoSyncField
                    account
                    // Last because it's the section nobody touches twice. The
                    // fields above are the ones worth having above the fold.
                    apiPaths
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }

            Divider()

            HStack(spacing: 8) {
                Text(validationError ?? engine.status.label)
                    .font(.caption)
                    .foregroundStyle(validationError == nil ? Color.secondary : Color.red)
                    // Wraps rather than truncating: a rejected-config reason is
                    // the whole point of this line and is no use half-shown.
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                Text(Self.version)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button("Done") {
                    if save() { onDone() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .onAppear {
            serverURL = engine.config.serverURL
            noteID = engine.config.noteID
            loginPath = engine.config.loginPath
            notePath = engine.config.notePath
            // "%g" so a whole number of seconds shows as "2", not "2.0".
            autoSyncSeconds = String(format: "%g", engine.config.autoSyncSeconds)
        }
        // The popover can be dismissed by clicking outside, which never reaches
        // "Done", so persist here too. An invalid edit is simply dropped: there
        // is no longer any view on screen to show the reason in, and writing a
        // file the next launch would reject is worse than losing the keystrokes.
        .onDisappear { save() }
    }

    // MARK: - Sections

    private var autoSyncField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Autosync delay").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("2", text: $autoSyncSeconds)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                Text("seconds after you stop typing — 0 to sync on close only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Account")

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
                    // Signing in hits the routes being edited, so a rejected
                    // config must stop this before it spends one of five attempts.
                    guard save() else { return }
                    Task {
                        signingIn = true
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
    }

    private var apiPaths: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("API paths")

            field("Login path", placeholder: "/api/v1/login", text: $loginPath)
            field(
                "Note path",
                placeholder: "/api/v1/notes/\(AppConfig.noteIDPlaceholder)",
                text: $notePath
            )

            Text("Full paths, including any API prefix. \(AppConfig.noteIDPlaceholder) is replaced with the note id. Methods and payload shapes are fixed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Read from the bundle rather than written out here, so it can't drift from
    /// what was actually built. The build number is included because
    /// `CFBundleShortVersionString` alone can't tell two builds of the same
    /// version apart, which is exactly what you need when someone reports a bug —
    /// unless the two are identical, where showing both is just noise.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "" }
        guard let build = info?["CFBundleVersion"] as? String, build != short else {
            return "v\(short)"
        }
        return "v\(short) (\(build))"
    }

    // MARK: - Saving

    /// Returns whether the edit was accepted. A refusal leaves `engine.config`
    /// untouched and the reason on screen, so the fields keep what was typed and
    /// can be corrected in place.
    @discardableResult
    private func save() -> Bool {
        var updated = engine.config
        updated.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.noteID = noteID.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.loginPath = loginPath.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notePath = notePath.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.autoSyncSeconds = parsedDelay

        if let reason = engine.apply(updated) {
            validationError = reason
            return false
        }
        validationError = nil
        return true
    }

    /// Anything unparseable keeps the stored value rather than reading as zero,
    /// which would silently switch autosync off. Capped so a stray digit can't
    /// park the next push an hour away.
    private var parsedDelay: Double {
        guard let value = Double(autoSyncSeconds.trimmingCharacters(in: .whitespaces)) else {
            return engine.config.autoSyncSeconds
        }
        return min(max(value, 0), 300)
    }
}
