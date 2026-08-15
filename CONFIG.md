# Configuration and stored files

MenubarNotes keeps everything it persists in one directory, in plain files, so it
can be inspected and edited by hand. This documents where that directory is, what
each file contains, and which parts are safe to edit.

## Where the files live

The app is sandboxed (`com.apple.security.app-sandbox` in
`MenubarNotes/MenubarNotes.entitlements`), so "Application Support" resolves
inside the app's container:

```
~/Library/Containers/com.local.MenubarNotes/Data/Library/Application Support/MenubarNotes/
```

To open it:

```sh
open ~/Library/Containers/com.local.MenubarNotes/Data/Library/Application\ Support/MenubarNotes/
```

The `com.local.MenubarNotes` component is the bundle identifier
(`PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project). **Changing the bundle
identifier changes the container path**, which orphans every file below — the app
will start up looking unconfigured, with the old data still on disk under the old
identifier. Move the directory by hand if you ever rename it.

The path is built in `AppPaths` (`MenubarNotes/AppStorage.swift`).

## The files

| File | Written by | Hand-editable | Purpose |
|---|---|---|---|
| `config.json` | You, and the settings pane | **Yes** | Server address, note id, autosync delay |
| `note.txt` | The app | Yes | The note body itself |
| `session.txt` | The app | No (delete only) | Session cookie for the sync server |
| `sync-state.json` | The app | No | What both sides looked like at the last sync |

---

## `config.json`

The only file you are expected to edit. It is the single source of truth for how
the app syncs.

```json
{
  "autoSyncSeconds": 2,
  "loginPath": "/api/v1/login",
  "noteID": "3544cc9e-f7eb-4198-8958-6c5f28359d70",
  "notePath": "/api/v1/notes/{noteID}",
  "serverURL": "https://gaurvsh.com"
}
```

| Key | Type | Meaning |
|---|---|---|
| `serverURL` | string | Scheme, host, and optionally a path prefix. Everything below is appended to it. |
| `loginPath` | string | Full path of the passcode-exchange route, including any API prefix. |
| `notePath` | string | Full path of the note route. Must contain `{noteID}`, which is substituted per request. |
| `noteID` | string | Id of the single remote note this app mirrors. Empty means "not configured" — the app runs local-only and never touches the network. |
| `autoSyncSeconds` | number | Seconds of idle typing before the note is pushed automatically. `0` turns autosync off; the note still pushes on popover close and on quit. Settings caps input at `300`. |

### Routes are configuration, but only the routes

The paths live here so that a server which renames or re-versions its endpoints
doesn't need a new build. Bumping `/api/v1` to `/api/v2` is two edits and a
relaunch.

That is the limit of it. Still hard-coded in `MenubarNotes/SyncClient.swift`:

- **HTTP methods** — `POST` to log in, `GET` and `PATCH` on the note.
- **Payload shapes** — the request bodies `{"passcode": …}` and `{"body": …}`, and
  the response fields `id`, `body`, `updatedAt`.
- **Auth** — a `session=` cookie read from `Set-Cookie` by that exact name.
- **Status codes** — `401` unauthorized, `404` gone, `429` locked out.

So a server that renames a response field is still a code change. The paths cover
route drift, not payload drift.

### Every key is required

Decoding is all-or-nothing. If any key is missing or has the wrong type, the file
is **not** partially adopted — it is discarded whole and the built-in defaults
stand in:

```
serverURL       http://localhost:3001
loginPath       /api/v1/login
notePath        /api/v1/notes/{noteID}
noteID          ""            (i.e. not configured, local-only)
autoSyncSeconds 2
```

### And every value is checked

Decoding proves the shape, not the meaning — every key can be present and
correctly typed while still describing a route that can't be built. So a second
pass runs after decoding:

| Rule | Why |
|---|---|
| `serverURL` has a scheme and a host | `URL(string:)` accepts almost anything; `"not a url"` parses fine and yields no host. |
| `noteID` contains no `/` | It is substituted into a single path segment. A slash is the one character that isn't escaped, so it would silently invent extra segments and change the route. |
| `noteID` is not `.` or `..` | Also survives unescaped, and normalises a segment away. |
| `loginPath`, `notePath` non-empty | Blank or all-slashes leaves nothing to request. |
| `notePath` contains `{noteID}` | Without it every sync hits the collection endpoint instead of the note. |
| `autoSyncSeconds` not negative | Nothing sensible to do with a negative delay. |

An **empty `noteID` passes** on purpose: that's a fresh install with nothing set
up yet, which shows as *Local only* rather than as an error about a file you've
never opened.

The settings pane runs the same check before writing, and refuses to save an edit
that fails it — the reason appears in red at the bottom of the pane and the field
keeps what you typed so you can fix it. This means **the app never writes a
`config.json` that it would reject on the next launch**.

A file that is present but unusable is **not** treated as a fresh install. The
status line names the problem instead of quietly reading *Local only*:

```
config.json — missing "notePath"
config.json — wrong type for "noteID"
config.json — not valid JSON
config.json — notePath must contain {noteID}
config.json — noteID must not contain "/"
config.json — serverURL needs a scheme and a host
```

The same message goes to the unified log at launch, with the full path:

```sh
log show --last 5m --predicate 'process == "MenubarNotes"' --info
```

The broken file is left alone. The app only rewrites `config.json` when a setting
actually changes value, and after a rejected load the in-memory config already
equals the defaults — so nothing overwrites your file until you deliberately
change something in settings, at which point the complaint clears. Nothing else
is touched either: `note.txt`, `session.txt` and `sync-state.json` survive, so
correcting the config and reopening resumes syncing where it left off.

Still worth keeping a backup before editing (`cp config.json config.json.bak`).

### Editing while the app is running

The app holds `config.json` in memory and rewrites the whole file whenever
settings change. Edit the file with the app running and your change will be
silently overwritten. **Quit the app first**, then edit, then relaunch.

### How a URL is built

`SyncClient.url(_:)` splits the path on `/`, substitutes `{noteID}` inside each
component, and appends them to `serverURL` one at a time.

Two consequences worth knowing:

- **Leading and trailing slashes don't matter.** `/api/v1/login`, `api/v1/login`
  and `api/v1/login/` are the same route.
- **A path in `serverURL` is kept.** A server mounted under a prefix works:

  | `serverURL` | `notePath` | Request |
  |---|---|---|
  | `https://example.com` | `/api/v1/notes/{noteID}` | `https://example.com/api/v1/notes/abc` |
  | `https://example.com/quick-note` | `/api/v1/notes/{noteID}` | `https://example.com/quick-note/api/v1/notes/abc` |
  | `https://example.com` | `/n/{noteID}.json` | `https://example.com/n/abc.json` |

  (This was previously broken — the old builder used a root-relative reference,
  which discarded any path in `serverURL` without an error.)

Each segment is percent-encoded, so spaces and non-ASCII are handled. Query-string
routes such as `/notes?id={noteID}` are **not** supported — the `?` is escaped and
becomes part of the path.

### Local HTTP

`Info.plist` sets `NSAllowsLocalNetworking`, which permits cleartext `http://` to
`localhost` and `.local` hosts for testing against a locally-run server. TLS is
still enforced for every other host, so a remote `serverURL` must be `https://`.

---

## `note.txt`

The note body, as plain UTF-8 text. Safe to read or edit with the app quit.

Writes are debounced by 0.5s while you type, and forced immediately when the
popover closes or the app terminates, so the file is never more than half a second
behind the window.

Editing this file by hand does not itself push to the server. On the next popover
open the app pulls, sees local text that differs from `lastSyncedBody`, and treats
your edit as a pending change — it will be pushed on close (or by autosync). If
the remote also moved in the meantime, you get the conflict-merge path instead.

---

## `session.txt`

The `session` cookie value from the server, stored as an opaque string with
permissions `0600`.

This is a **bearer credential** — anything holding it can read and write your
remote note. Do not commit it, copy it into issues, or share it.

- Deleting the file is a sign-out. It is exactly what the "Sign out" button does;
  the server has no logout route, so the session stays valid server-side until it
  expires.
- The app also clears it automatically on any `401` from the server.
- Absent or empty means "not signed in": the app shows *Sign in to sync* and makes
  no sync requests until you enter the passcode.

Re-authenticating needs the 4-digit passcode. **Five wrong attempts lock the
server for every user for an hour**, and the app never retries automatically —
by design.

---

## `sync-state.json`

Generated. What the app believes both sides looked like at the end of the last
successful sync — divergence from this is the only way a local or remote edit is
detected, since the server exposes no ETag or version column.

```json
{
  "lastSyncedAt": 807711793.417316,
  "lastSyncedBody": "…the full note text as of the last sync…",
  "lastSyncedUpdatedAt": 1786018276127
}
```

| Key | Meaning |
|---|---|
| `lastSyncedBody` | Full copy of the note as it stood after the last sync. Compared against `note.txt` to decide whether there is anything to push. |
| `lastSyncedUpdatedAt` | The **server's** timestamp, in milliseconds since the Unix epoch. Compared against the remote's to decide whether the remote moved. |
| `lastSyncedAt` | When *we* last completed a sync, in seconds since **2001-01-01 UTC** — Swift's reference date, not the Unix epoch. Optional; a file written before this field existed still decodes. Only used to render "Synced 14:02". |

Do not hand-edit this. Two traps in particular:

- **Deleting the file resets `lastSyncedUpdatedAt` to `0`**, which the app reads as
  "nothing has ever synced". On the next open it takes the remote as truth and
  **overwrites `note.txt` wholesale**. Any local-only text is gone. If you need to
  reset sync state, copy `note.txt` somewhere first.
- Editing `lastSyncedBody` to match `note.txt` will convince the app there is
  nothing to push, and your real edit will never reach the server.

---

## Resetting

| Goal | Do this (with the app quit) |
|---|---|
| Sign out | `rm session.txt` |
| Point at a different note or server | Edit `config.json`, then `rm sync-state.json` — the old baseline is meaningless against a different note, and leaving it causes a spurious conflict merge. Back up `note.txt` first, since the new remote will win. |
| Change `loginPath` or `notePath` | Same as above if the routes now point at a different note. A pure version bump against the same note needs no reset. |
| Full reset | Remove the whole directory. The app recreates it on next launch. |
