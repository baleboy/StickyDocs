# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build / run / test

Open `StickyDocs/StickyDocs.xcodeproj` in Xcode and run the `StickyDocs` scheme. There is no SwiftPM or Makefile; everything goes through Xcode.

CLI equivalents (run from repo root):

```bash
# Build
xcodebuild -project StickyDocs/StickyDocs.xcodeproj -scheme StickyDocs build

# All unit tests (StickyDocsTests target)
xcodebuild -project StickyDocs/StickyDocs.xcodeproj -scheme StickyDocs \
  -destination 'platform=macOS' test

# A single test
xcodebuild -project StickyDocs/StickyDocs.xcodeproj -scheme StickyDocs \
  -destination 'platform=macOS' \
  -only-testing:StickyDocsTests/SyncEngineTests/testPushCreatesDoc test
```

`StickyDocsUITests` exists but the substantive coverage is in `StickyDocsTests` (unit + integration with in-memory store and fake Drive/Docs deps).

Releases: see `RELEASING.md` (tag via `scripts/release.sh`, CI does the rest). `PRD.md` is the locked v1 spec. `TESTPLAN.md` is the canonical manual test plan. Dated `testrun-*.md` files are local, untracked execution logs — don't commit them and don't treat them as authoritative.

**Whenever you change user-visible behavior, review `TESTPLAN.md` and update any steps or expected outcomes that no longer match.** This is easy to forget because nothing enforces it.

## Secrets

`StickyDocs/StickyDocs/Auth/Secrets.swift` is gitignored. To bring up a fresh checkout, copy `Secrets.example.swift` content into `Secrets.swift` and fill in a Google Cloud OAuth client (**iOS app type**, bundle id `com.baleware.StickyDocs`) with Drive + Docs APIs enabled. Leave `googleClientSecret` as an empty string — iOS clients are public and PKCE-only. The committed `Secrets.swift` is a stub; the example file's body is commented out so both can coexist without a duplicate `Secrets` enum.

## Architecture

Menu-bar macOS app (`MenuBarExtra`). Each sticky is a borderless floating `NSWindow` synced 1:1 with a Google Doc in a `Stickies/` folder in the user's Drive.

A debug `Window("StickyDocs (Debug)")` is compiled in via `#if DEBUG` in `StickyDocsApp.swift`. It hosts the auth/round-trip test harness (`ContentView`) and is the entry point for "Save creds for tests" + manual API smoke tests. Release builds have no such window — they're menu-bar-only. Launch-time work (onboarding prompt, sticky window restoration, initial Drive pull) lives in `AppDelegate.applicationDidFinishLaunching` so it fires in both configurations.

**Data flow (single source of truth = local SQLite):**

```
NSTextView edit
  → StickyContentView.onChange
  → SyncEngine.updateContent (writes HTML + pending_push=true to StickyStore)
  → SyncEngine.schedulePush (cancels prior debounce Task, starts a new 1.5s one)
  → GRDB ValueObservation → StickyViewModel republishes
windowDidResignKey / windowWillClose
  → StickyWindowController.flushPendingPush (cancels debounce, pushes now)
  → SyncEngine.push → GoogleDocsClient.replaceDocumentBody
```

Push triggers: a **1.5s per-sticky debounce after each keystroke** (`SyncEngine.typingDebounce`), **immediate flush on blur and close** (which also cancels the pending debounce task), explicit **Sync Now** (menu bar / sticky context menu), the **post-sign-in transition** (`authCancellable` in `AppController`), an **offline→online network transition** (`NWPathMonitor` in `AppController`, fires `syncNow()`), **launch** (pull, then `syncAllPending`, which also covers stickies whose windows are closed), and **quit** (`applicationShouldTerminate` waits up to 5s for `syncAllPending`). Overlapping `syncNow()` calls don't run concurrently: later callers wait for the running one and queue a single extra pass. There is no `changes.list` polling and no exponential backoff — see the comment at the top of `SyncEngine.swift` for what's still deferred.

**Lazy Doc provisioning.** `createLocalSticky` never touches the network. `push()` provisions a Drive Doc on the first push *only if* the sticky has non-whitespace content (so empty discarded stickies leave no Drive litter). Once a Doc exists, an emptied sticky does push an empty body. Soft-deleted stickies are never pushed (`deleteSticky` also cancels the debounce and waits for any in-flight push). Once provisioned, `googleDocId` is set and the sticky's `syncStatus` transitions `unprovisioned → pending → synced`.

**Unlinked state.** If Drive returns 404/410 or the Doc is trashed, `push()` clears `googleDocId` and `lastRevisionId` but keeps `lastSyncedAt`. That sentinel means "was once synced, now broken" — subsequent automatic pushes hold (don't silently recreate a Doc); the user must invoke "Re-create Doc in Drive" from the context menu (`recreateDoc`).

**Conflict handling.** `pull()` compares `lastRevisionId` against Drive's current `revisionId`. If remote advanced *and* local had unsynced edits (`pendingPush` + content diverges from `lastSyncedHTML`), local content is stashed into `conflictBackupHTML` and remote wins; the sticky shows an orange conflict banner, and `restoreBackup` swaps it back. `push()` never overwrites remote edits: `replaceDocumentBody` takes the expected revision, throws `RemoteRevisionChangedError` instead of writing if the Doc moved, pins the `batchUpdate` with `writeControl.requiredRevisionId`, and returns the revision of our own write (from the response, not a follow-up GET). On that error the engine diverts to pull.

**Editor vs. engine-replaced content.** `StickyTextEditor.updateNSView` deliberately ignores store updates while the text view is focused (they're usually lagging echoes of the user's own typing). Content the engine replaces — a pull bringing in remote text, `restoreBackup` — is instead posted synchronously as `SyncEngine.contentReplacedExternally` and applied straight to the text view via `StickyViewModel.externalContent`, even while focused; otherwise the next keystroke would write the stale editor text back over it. Any new engine path that rewrites `contentHTML` must post it too.

**HTML round-trip.** `HTMLNormalizer` converts between `NSAttributedString` (what `NSTextView` produces) and a sanitized HTML subset that Google Docs accepts via `replaceDocumentBody`. All comparisons (`contentHTML` vs `lastSyncedHTML`) assume canonicalised HTML, so always route through the normalizer rather than comparing raw strings.

**Folder ID is cached in `app_state`.** `FolderIdCache` (in `AppController.swift`) memoises the Stickies/ folder ID after the first `findOrCreateFolder` call. `wipeAll()` (Debug → Reset All Local Data) clears it, so the next push re-creates the folder. Concurrent first lookups share one in-flight `findOrCreateFolder` (list-then-create isn't atomic, so two would create two folders), and a lookup that finishes after `invalidate()` isn't cached. Bugs in `findOrCreateFolder` only surface on fresh installs / after a reset, which is easy to miss.

**Cross-machine restore.** `SyncEngine.discoverRemoteStickies()` queries Drive for files tagged with `appProperties.stickydocs=v1` and creates a local row for any whose Doc id isn't in the store yet. `drive.file` scope is per OAuth client (not per device), so the same Google account on a second Mac sees the first Mac's stickies. Called from `syncNow()` before pull/push; idempotent. Imported stickies land with `isOpen=false` so a fresh install doesn't auto-spawn N floating windows — the user opens them selectively from All Stickies.

**Dependency injection at the network boundary.** `SyncEngine.Dependencies` is a struct of closures (`createDoc`, `exportAsHTML`, `pushBody`, etc.) wired up once in `AppController.init`. Tests substitute fakes — see `SyncEngineTests.swift` and `RoundTripIntegrationTests.swift`. Don't make `SyncEngine` reach into `GoogleDocsClient`/`GoogleDriveClient` directly.

**Auth.** `AuthService` does OAuth via `ASWebAuthenticationSession` with PKCE. The callback URL scheme is derived from `Secrets.googleClientID` (reverse-DNS to `com.googleusercontent.apps.<prefix>`) and the redirect URI is `<scheme>:/oauth2redirect`. Tokens live in the Keychain via `KeychainStore`. Access tokens are refreshed lazily inside `accessToken()`. If the refresh itself fails with `tokenExchangeFailed` (Google revoked the grant, password changed, 6-month inactivity, etc.), `accessToken()` auto-signs-out, throws `notSignedIn`, and the per-sticky banner switches to the blue "Sign in to Google" variant with a Sign In button that re-runs the OAuth flow. Explicit **Sign Out** (menu bar / Stickies menu) goes through `AppController.confirmAndSignOut` → `signOutAndReset`, which flushes pending pushes, closes all windows and wipes the local store — the local DB is a per-account cache, and keeping it across a sign-out leaks the old account's stickies, `stickies_folder_id` (invisible to the new account under `drive.file`, so pushes 404) and `onboarding_complete` into the next account. `SyncEngine.isAuthError` also signs out on a 401 from Drive/Docs, but on a 403 only when Google says the token lacks a scope — rate limits and per-file denials are ordinary push errors (red banner, retry). The *automatic* sign-out inside `accessToken()` on a rejected refresh is deliberately non-destructive: it only clears tokens so the re-auth banner can appear. The OAuth client in Google Cloud Console must be **iOS type** (which supports the custom-scheme redirect); a Desktop client will reject the redirect URI.

## Conventions worth knowing

- Call sites of `engine.push(...)` are still wrapped in `try?`, but `push` now persists any error to the sticky's `last_push_error_message` / `last_push_error_at` columns before re-throwing. The status dot flips to red and the tooltip shows the message, so failures are no longer silent. `pendingPush` stays `true` on error so blur, debounce, or Sync Now will retry; a successful push clears both error fields. For deeper debugging, check Console.app filtering on `StickyDocs`.
- `StickyStore.upsert` saves the whole row. `updateContent` runs on every keystroke while a push/pull is awaiting the network, so any write after an `await` must re-fetch the row and change only sync fields — writing back a `Sticky` read before the await silently reverts the user's typing. `push` and `pull` are serialized per sticky via `SyncEngine.serialized`; inside that chain call `pullInner`, not `pull`.
- All `SyncEngine` and UI controller code is `@MainActor`. GRDB `ValueObservation` callbacks hop back to the main actor via `Task { @MainActor in ... }`.
- Sticky window styling depends on `StickyKeyableWindow` overriding `canBecomeKey`/`canBecomeMain`; a borderless `NSWindow` is not key-eligible by default, which would break text input and (transitively) the blur-triggered push.
