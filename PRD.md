# StickyDocs — Product Requirements Document

**Status:** v1 design locked
**Last updated:** 2026-05-16

## Problem Statement

I keep ephemeral notes (todos, scratch text, snippets, things I want to glance at) on my Mac using Apple's Stickies because the always-on-top, floating-on-every-Space behavior is unmatched for ambient information. But Stickies notes are trapped on one Mac: they don't sync, they can't be opened on my phone, they can't be shared with anyone, and if the disk dies the notes are gone.

Conversely, Google Docs gives me durability, sync across every device, sharing, and revision history — but it lives inside a browser tab, behind tabs and windows, and is fundamentally a document app, not an ambient note surface.

I want both: the Stickies UX with the Google Docs backend.

## Solution

**StickyDocs** is a native macOS app that looks and behaves like Apple's Stickies — borderless colored floating windows, always on top, visible on every Space — where each sticky note is transparently backed by a Google Doc in the user's Drive. Editing the sticky edits the Doc. Editing the Doc in a browser updates the sticky. Notes persist across machines because they live in Drive.

The sticky is the foreground frontend; the Doc is the durable, shareable, cross-device backend.

## User Stories

1. As a Mac user, I want to sign in to Google once via my system browser, so that the app gains permission to read and write only the files it creates without seeing the rest of my Drive.
2. As a Mac user, I want to create a new sticky with ⌘N, so that I can capture a thought immediately without thinking about file management.
3. As a Mac user, I want each new sticky to automatically become a Google Doc in a "Stickies" folder in my Drive, so that my notes are durable from the moment I create them.
4. As a Mac user, I want the sticky window to float above every other app and appear on every Space, so that my notes are always visible no matter what I'm doing.
5. As a Mac user, I want to type in the sticky and have my changes pushed to the underlying Doc shortly after I stop typing, so that I never have to think about saving.
6. As a Mac user, I want my typing to never block or stutter on network activity, so that the editor always feels instant.
7. As a Mac user, I want to keep typing in a sticky while offline, so that losing wifi doesn't interrupt my work; the app should flush my changes when I reconnect.
8. As a Mac user, I want bold, italic, underline, bulleted lists, and numbered lists via Format menu and standard keyboard shortcuts, so that I can give my notes light structure without a toolbar.
9. As a Mac user, I want the editor to behave like a native Mac text field — spellcheck, system services, emoji picker, dictation — so that the app feels at home on my Mac.
10. As a Mac user, I want to edit my sticky's Doc in Google Docs on my phone or in a browser, so that I can update my notes from anywhere.
11. As a Mac user, I want changes I make in Google Docs to appear in the sticky shortly afterward, so that the sticky reflects the current state of the Doc.
12. As a Mac user, I want the app to pause pulling remote changes while I'm actively typing, so that incoming sync never wipes out characters I'm in the middle of writing.
13. As a Mac user, I want the app to detect when the Doc was edited remotely while I had unsynced local changes, so that the conflict is handled rather than silently lost.
14. As a Mac user, I want the remote (Doc) version to win on conflict but my local version to be stashed and recoverable via a "Restore my version" action, so that I never lose data even when remote takes priority.
15. As a Mac user, I want a small status indicator in the corner of each sticky showing synced / syncing / pending / error, so that I can see at a glance whether my note is safe in the cloud.
16. As a Mac user, I want to hover over the status indicator to see a tooltip explaining the current state, so that I understand what's happening when something is off.
17. As a Mac user, I want to pick from six sticky colors (yellow, blue, green, pink, purple, gray) matching Apple's Stickies palette, so that I can categorize notes visually.
18. As a Mac user, I want the sticky to have minimal chrome — borderless, with a title bar that only appears on hover or focus — so that the note feels ambient rather than appy.
19. As a Mac user, I want to double-click the title bar to collapse a sticky to a one-line strip, so that I can keep many notes visible without clutter.
20. As a Mac user, I want each sticky's position, size, color, and collapsed state to persist across app restarts, so that my workspace is exactly how I left it.
21. As a Mac user, I want every sticky window to be restored on app launch in its previous frame, so that I don't have to re-arrange my desktop.
22. As a Mac user, I want to right-click a sticky for color, delete, sync-now, open-in-Docs, and copy-link actions, so that I can manage notes without hunting through menus.
23. As a Mac user, I want closing a sticky window to delete the local sticky but leave the Doc in Drive by default, so that accidental closes don't lose my data permanently.
24. As a Mac user, I want a checkbox in the close confirmation to also delete the underlying Doc, so that I can fully purge a note when I really mean it.
25. As a Mac user, I want a Window → Show All Stickies command that opens a panel listing every sticky with title, preview, and sync status, so that I can find a note when I have many.
26. As a Mac user, I want a menu bar extra with shortcuts to New Sticky, Show All, Sync Now, Open Stickies Folder in Drive, Preferences, and Sign Out, so that I can reach the app even when all stickies are hidden.
27. As a Mac user, I want a Preferences window where I can see my signed-in account, change the default color, adjust sync interval, rename the Stickies folder, and view a sync log, so that I can configure the app and debug sync issues.
28. As a Mac user, I want an onboarding screen on first launch that signs me in to Google, creates a Stickies folder, and presents a welcome sticky, so that I'm productive within seconds.
29. As a Mac user, I want the app to support dark mode, with each sticky color having a darker variant, so that the app fits my system appearance.
30. As a Mac user, I want my Google OAuth tokens stored in the macOS Keychain, so that my credentials are protected by the OS security model.
31. As a Mac user, I want the app to automatically refresh expired access tokens, so that I stay signed in indefinitely without re-prompting.
32. As a Mac user, I want a clear "Sign in required" indicator if my token is revoked or refresh fails, so that I know exactly what to do to restore sync.
33. As a Mac user, I want the app to launch instantly with sticky content rendered from a local cache, so that I never wait on the network to see my notes.
34. As a Mac user, I want the app to discover existing stickies on a fresh Mac install by querying Drive for files my app previously tagged, so that signing in on a second machine restores my workspace.
35. As a Mac user, I want the app to keep tracking a sticky even if I move or rename its Doc in Drive, so that my Drive organization doesn't break the app.
36. As a Mac user, I want the app to detect when a Doc is deleted or trashed in Drive and ask whether to keep the sticky as a local-only note or remove it, so that external deletions don't surprise me.
37. As a Mac user, I want pushes to the Doc to be atomic, so that a crash mid-sync never leaves the Doc in a half-empty state.
38. As a Mac user, I want the app to retry transient sync failures with exponential backoff, so that brief network blips heal automatically without manual intervention.
39. As a Mac user, I want a "Restore previous version" right-click action that swaps in the last successfully-synced content, so that if a round-trip mangles my note I can recover instantly.
40. As a Mac user, I want the app to rebuild its local database from Drive if the local DB is corrupted, so that disk issues don't lose my notes.
41. As a Mac user, I want a Sync Log in Preferences showing recent push/pull events and errors, so that I can debug unexpected sync behavior.
42. As a Mac user, I want the app to receive updates automatically via a built-in updater, so that bug fixes reach me without manual reinstalls.
43. As a Mac user, I want the app to be signed and notarized by Apple, so that Gatekeeper installs it without security warnings.

## Implementation Decisions

### Platform & Stack
- Native macOS application written in **Swift**, using **SwiftUI** for app shell, panels, and preferences, with **AppKit** (`NSViewRepresentable`-wrapped `NSTextView`) for the rich-text editor where SwiftUI's text affordances are insufficient.
- macOS-only. No cross-platform abstraction layer.

### Sticky ↔ Doc Mapping
- One sticky = one Google Doc.
- Stickies live in a dedicated Drive folder (default name "Stickies") created by the app on first run.
- Each sticky-Doc is tagged with Drive `appProperties` (`stickydocs=v1`) so identity survives renames and moves; discovery queries `appProperties`, not folder path.

### Authentication
- OAuth 2.0 PKCE installed-app flow with loopback redirect (`http://localhost:<random-port>/callback`).
- Scope: `https://www.googleapis.com/auth/drive.file` (least-privilege; access only to files the app creates or the user opens via picker).
- Tokens stored in the macOS Keychain.
- Refresh handled transparently; on refresh failure, app surfaces a "Sign in required" state and queues local edits until re-auth.

### Editor & Rich Text
- `NSTextView` editing an `NSAttributedString`.
- v1 feature set: bold, italic, underline, bulleted list, numbered list. No headings, no images, no tables, no text color, no font selector.
- No toolbar. Formatting via Format menu and keyboard shortcuts (`⌘B`, `⌘I`, `⌘U`, list shortcuts).
- Spellcheck, services menu, emoji picker, dictation: rely on `NSTextView` defaults.

### Local Storage
- **GRDB + SQLite** at `~/Library/Application Support/<bundle-id>/stickies.sqlite`.
- Single-table schema (v1):

```
stickies(
  id TEXT PRIMARY KEY,             -- local UUID
  google_doc_id TEXT UNIQUE,       -- nullable until first push succeeds
  title TEXT,                      -- mirrors Doc title
  content_html TEXT,               -- current local content
  last_synced_html TEXT,           -- snapshot for "Restore previous version" + dirty diff
  conflict_backup_html TEXT,       -- local stash when remote wins a conflict
  last_revision_id TEXT,           -- Doc headRevisionId at last sync
  frame_x, frame_y, frame_w, frame_h REAL,
  color TEXT,                      -- yellow|blue|green|pink|purple|gray
  collapsed INTEGER,
  created_at, updated_at, last_synced_at INTEGER,
  pending_push INTEGER,            -- 0/1 dirty flag
  deleted_locally INTEGER
)
```

- Separate table for app-level state: `app_state(key, value)` storing Drive `changes.list` pageToken, signed-in user id, etc.

### Sync Model
- **Two-way**, last-write-wins with revisionId-based conflict detection.
- **Push triggers:** debounce 2s after the last keystroke; flush immediately on window blur and on app quit; periodic safety retry every 30s for pending entries.
- **Push mechanism:** single atomic Docs API `batchUpdate` call combining `deleteContentRange` (over entire body) + `insertText` + style updates. No partial state possible.
- **Pull triggers:** Drive `changes.list` on app launch, network reconnect, app foreground, and every 60s while the app is active and not on battery in the background. Per-Doc `files.get` opportunistically on sticky window focus.
- **Pull mechanism:** Drive API `files.export` as HTML → normalize → import into `NSAttributedString`.
- **Conflict policy:** if pull finds a newer remote revision and local has unpushed changes (and user hasn't typed in the last 5s), remote wins; previous local content moves to `conflict_backup_html` and a non-modal toast offers "Restore my version".
- **Pause-while-typing:** pulls are suppressed while the user is actively typing; resume after idle.
- **Backoff:** exponential backoff per-sticky on 429s and 5xx, capped at 60s.

### Window & Lifecycle
- Each sticky is its own `NSWindow` at `.floating` level, with `collectionBehavior = [.canJoinAllSpaces, .stationary]`.
- App shows a Dock icon **and** a menu bar extra.
- Window restoration: all sticky frames + colors + collapsed state restored on launch from GRDB.
- Close button = soft-delete the local sticky (with confirmation dialog). Confirmation includes a "Also delete the Google Doc" checkbox; default unchecked.

### Chrome
- Borderless windows; the colored background is the sticky's surface.
- Title bar (with close + collapse buttons) appears on hover or focus only.
- Resize handle in bottom-right corner; small permanent sync-status dot adjacent to it.
- Six colors matching Apple's Stickies palette; each has a dark-mode variant.
- Default font: system font (SF) at ~13pt; user can override globally via Preferences (not per-sticky in v1).
- Double-click on title bar collapses sticky to one-line height.
- Minimum window size: ~150×80.

### Surface Beyond Stickies
- Standard app menu bar (File/Edit/Format/Window/Help).
- Menu bar extra (status icon) with: New Sticky, Show All Stickies, Sync Now, Open Stickies Folder in Drive, Preferences, Sign Out.
- "All Stickies" panel: floating window with a `List` view bound to a GRDB query, showing title, preview, color swatch, and sync status per row.
- Preferences window: signed-in account, default color, sync interval, folder name, sync log viewer.
- Right-click context menu on each sticky: color picker, delete, sync now, open in Google Docs (browser), copy Doc link.
- Onboarding: one-screen welcome → OAuth consent → folder bootstrap → welcome sticky.

### Error Handling
- Token-refresh failure: red status dots everywhere + menu bar badge + re-auth on click.
- Long offline: pending pushes coalesce on the latest content (no per-edit queue table needed).
- Rate limit (429): exponential backoff per-sticky.
- Doc deleted/trashed externally: surface as soft-unlink with user choice (keep local, recreate, or remove).
- Round-trip HTML corruption: never auto-correct; user-invoked "Restore previous version" swaps `last_synced_html` into `content_html`.
- GRDB corruption: rename DB file aside, recreate, full pull from Drive using `appProperties` query, show one-time notification.
- Critical errors (auth lost, DB rebuilt): macOS user notification.

### Distribution
- Direct download (project website or GitHub Releases).
- Signed with a Developer ID certificate and notarized via `notarytool`.
- Auto-updates via **Sparkle** with a signed appcast.
- App sandboxed; required entitlements: `network.client`, `network.server` (for loopback OAuth), Keychain access group.

### Modules

1. **AuthService** — OAuth PKCE loopback flow, Keychain token storage, transparent refresh, sign-in/sign-out events. Deep, isolatable.
2. **GoogleDriveClient** — Typed wrapper around Drive REST: `files.list` (with `appProperties` query), `files.get`, `files.export` (HTML), `files.create` (Doc inside Stickies folder), folder ensure/create, `changes.getStartPageToken` + `changes.list`.
3. **GoogleDocsClient** — Typed wrapper around Docs API: a single `replaceDocumentBody(docId, attributedString)` method that emits the atomic `batchUpdate` (delete-all + insertText + style ops).
4. **HTMLNormalizer** — Pure, bidirectional. `NSAttributedString → canonicalHTML` (subset: `<p>`, `<br>`, `<b>`, `<i>`, `<u>`, `<ul>`, `<ol>`, `<li>`) for push; `Drive-exported HTML → canonicalHTML → NSAttributedString` for pull. The single biggest technical risk; built first with a round-trip test harness.
5. **StickyStore** — GRDB-backed repository. CRUD on stickies; observable queries for SwiftUI; transactional update of `content_html` + dirty flag; snapshotting `last_synced_html` and `conflict_backup_html`.
6. **SyncEngine** — Orchestrates AuthService + GoogleDriveClient + GoogleDocsClient + StickyStore + HTMLNormalizer. Owns push debounce, pull triggers, pause-while-typing, conflict resolution, backoff, pageToken cursor. Subscribes to `NWPathMonitor`, app-lifecycle, and editor-activity events.
7. **StickyWindowController / StickyView** — One per sticky; hosts `NSTextView`, applies chrome (color, hover title bar, status dot, collapse), persists frame changes back to StickyStore.
8. **AllStickiesPanel** — SwiftUI list bound to a StickyStore observable query.
9. **MenuBarExtraController** — `NSStatusItem` and its menu.
10. **PreferencesView** — SwiftUI settings scene; reads/writes `app_state` and reads sync log.
11. **AppCoordinator** — App lifecycle, onboarding flow, restoring sticky windows on launch.

### Build Order
1. AuthService + a smoke `files.list` call (validates auth + scope).
2. HTMLNormalizer + round-trip test harness against a real test Doc (validates the riskiest assumption before any UI work).
3. StickyStore + SyncEngine (driven by tests with faked clients).
4. One StickyWindowController rendering a hardcoded sticky.
5. Multi-window + persistence + frame restoration.
6. Chrome polish (hover title bar, collapse, color picker, status dot).
7. AllStickiesPanel, MenuBarExtraController, PreferencesView, onboarding.
8. Error UX edge cases (token revoked, DB corrupt, Doc deleted, conflict toast).

## Testing Decisions

Good tests here exercise **observable behavior** — what the user sees, what shows up in Drive, what survives a crash — not internal call sequences. They run hermetically without network where possible, and against a real test Google account where the seam genuinely requires it.

### Modules with the highest test ROI

- **HTMLNormalizer** (highest priority). Pure functions, no I/O. Test as a round-trip suite: given a curated set of `NSAttributedString` inputs (plain, bold, mixed, nested lists, mixed-style runs, edge cases like trailing newlines, empty docs), assert that `normalize(toAttributed(normalize(fromAttributed(input))))` is structurally equivalent to `input`. Also test the import path with captured real-world Drive HTML export fixtures (snapshot a Doc with each supported feature once, commit the HTML, assert the conversion). This module is the single biggest correctness risk; over-test it.

- **SyncEngine**. Test with in-memory fakes for AuthService, GoogleDriveClient, GoogleDocsClient. Scenarios:
  - Edit → 2s debounce → exactly one push, with normalized HTML.
  - Edit during pending push → push coalesces to latest content.
  - Remote change with clean local → local content updated, revisionId advanced.
  - Remote change with dirty local → `conflict_backup_html` set, toast event emitted.
  - Active-typing flag suppresses pull; idle resumes it.
  - 429 → exponential backoff observed; eventual success.
  - Offline → pushes queue; reconnect drains queue.
  - PageToken persisted across "restart" (re-init from same store).
  - Atomicity: if push fails, `last_synced_html` and `last_revision_id` are not advanced.

- **StickyStore**. Test against an in-memory SQLite DB (GRDB makes this trivial). Scenarios:
  - CRUD round-trips preserve all fields including the four HTML columns.
  - Dirty flag transitions on edit / on successful push.
  - Observable queries emit on relevant changes only.
  - Schema migration v0→v1 leaves data intact (forward-looking, even if v1 is the first).

### Modules covered lightly or via integration

- **AuthService**: smoke-test the Keychain wrapper; the OAuth flow itself is exercised by manual integration against a real Google account during development. Not unit-tested end-to-end.
- **GoogleDriveClient / GoogleDocsClient**: thin wrappers; verified via a small integration suite that hits a real test account behind a build flag (`STICKYDOCS_INTEGRATION=1`). Not part of regular CI.
- **Window controllers, panels, menu bar, preferences**: manual UX testing. Snapshot tests if SwiftUI snapshotting proves stable for the chrome.

### Prior art

Greenfield project — no in-repo prior art yet. The HTMLNormalizer round-trip pattern is the standard approach used by serializers in projects like Tiptap (TS) and Notion's content layer; for Swift specifically, treat `NSAttributedString`'s own HTML round-tripping as the *baseline behavior to compensate for*, not as ground truth.

## Out of Scope

The following are explicitly **not** in v1 and should not creep in:

- Adopting an existing arbitrary Google Doc as a sticky (requires Drive Picker or broader scope).
- Global system-wide hotkey to create a new sticky (in-app ⌘N only).
- Search across all stickies (cmd-F inside a sticky is in scope via `NSTextView` defaults; global search is not).
- Drag-and-drop export of a sticky to Finder as `.rtf`.
- Headings (H1/H2/H3).
- Inline images, tables, text color, font color, font selector per-sticky.
- True concurrent / operational-transform editing on the same Doc; we accept last-write-wins.
- Drive push notifications / webhooks (requires a server backend the project deliberately avoids).
- Mac App Store distribution.
- iOS or iPadOS companion app.
- Windows or Linux support.
- Multi-account support (one Google account per app instance in v1).
- Sharing UI inside the app (user can open the Doc in the browser to share via Google's own UI).
- Comments and suggestions (will be destroyed by nuke-and-replace pushes; acceptable v1 tradeoff).
- End-to-end encryption (content is at rest in Google Drive under Google's standard protections).

## Further Notes

**Top technical risk** is HTML round-trip fidelity across three boundaries: `NSAttributedString` HTML serialization, Google Docs HTML export, and Google Docs API `batchUpdate` input. The recommended build order (HTMLNormalizer + round-trip harness *before* any UI work) exists specifically to validate this risk early. If round-trip cannot be made reliable for the v1 feature set, the fallback is to ship plain-text-only and reassess.

**Second risk** is the interaction of the `drive.file` scope with `changes.list`. The scope restricts the view to files the app created or opened, which is the desired behavior, but the precise semantics across the Changes API need empirical validation during build step 1. If it doesn't work as expected, fall back to per-file `files.get` polling for the small N of stickies the app tracks.

**Working directory** is `/Users/baleboy/Projects/StickyDocs2`; the `2` is an artifact of an earlier abandoned attempt. The product name is **StickyDocs** (no suffix).

**Distribution prerequisites:** Apple Developer Program membership ($99/yr), a Google Cloud project with an OAuth consent screen configured for `drive.file` scope, and (before exceeding 100 users) Google's OAuth verification process.
