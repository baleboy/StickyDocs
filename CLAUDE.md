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

`PRD.md` is the locked v1 spec. `TESTPLAN.md` is the canonical manual test plan. Dated `testrun-*.md` files are local, untracked execution logs — don't commit them and don't treat them as authoritative.

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

Push triggers: a **1.5s per-sticky debounce after each keystroke** (`SyncEngine.typingDebounce`), **immediate flush on blur and close** (which also cancels the pending debounce task), explicit **Sync Now** (menu bar / sticky context menu), the **post-sign-in transition** (`authCancellable` in `AppController`), and an **offline→online network transition** (`NWPathMonitor` in `AppController`, fires `syncNow()`). There is no `changes.list` polling and no exponential backoff — see the comment at the top of `SyncEngine.swift` for what's still deferred.

**Lazy Doc provisioning.** `createLocalSticky` never touches the network. `push()` provisions a Drive Doc on the first push *only if* the sticky has non-whitespace content (so empty discarded stickies leave no Drive litter). Once provisioned, `googleDocId` is set and the sticky's `syncStatus` transitions `unprovisioned → pending → synced`.

**Unlinked state.** If Drive returns 404/410 or the Doc is trashed, `push()` clears `googleDocId` and `lastRevisionId` but keeps `lastSyncedAt`. That sentinel means "was once synced, now broken" — subsequent automatic pushes hold (don't silently recreate a Doc); the user must invoke "Re-create Doc in Drive" from the context menu (`recreateDoc`).

**Conflict handling.** `pull()` compares `lastRevisionId` against Drive's current `revisionId`. If remote advanced *and* local had unsynced edits (`pendingPush` + content diverges from `lastSyncedHTML`), local content is stashed into `conflictBackupHTML` and remote wins. `restoreBackup` swaps it back. v1 has no UI toast for this yet.

**HTML round-trip.** `HTMLNormalizer` converts between `NSAttributedString` (what `NSTextView` produces) and a sanitized HTML subset that Google Docs accepts via `replaceDocumentBody`. All comparisons (`contentHTML` vs `lastSyncedHTML`) assume canonicalised HTML, so always route through the normalizer rather than comparing raw strings.

**Folder ID is cached in `app_state`.** `FolderIdCache` (in `AppController.swift`) memoises the Stickies/ folder ID after the first `findOrCreateFolder` call. `wipeAll()` (Debug → Reset All Local Data) clears it, so the next push re-creates the folder. Bugs in `findOrCreateFolder` only surface on fresh installs / after a reset, which is easy to miss.

**Dependency injection at the network boundary.** `SyncEngine.Dependencies` is a struct of closures (`createDoc`, `exportAsHTML`, `pushBody`, etc.) wired up once in `AppController.init`. Tests substitute fakes — see `SyncEngineTests.swift` and `RoundTripIntegrationTests.swift`. Don't make `SyncEngine` reach into `GoogleDocsClient`/`GoogleDriveClient` directly.

**Auth.** `AuthService` does OAuth via `ASWebAuthenticationSession` with PKCE. The callback URL scheme is derived from `Secrets.googleClientID` (reverse-DNS to `com.googleusercontent.apps.<prefix>`) and the redirect URI is `<scheme>:/oauth2redirect`. Tokens live in the Keychain via `KeychainStore`. Access tokens are refreshed lazily inside `accessToken()`. If the refresh itself fails with `tokenExchangeFailed` (Google revoked the grant, password changed, 6-month inactivity, etc.), `accessToken()` auto-signs-out, throws `notSignedIn`, and the per-sticky banner switches to the blue "Sign in to Google" variant with a Sign In button that re-runs the OAuth flow. The OAuth client in Google Cloud Console must be **iOS type** (which supports the custom-scheme redirect); a Desktop client will reject the redirect URI.

## Conventions worth knowing

- Call sites of `engine.push(...)` are still wrapped in `try?`, but `push` now persists any error to the sticky's `last_push_error_message` / `last_push_error_at` columns before re-throwing. The status dot flips to red and the tooltip shows the message, so failures are no longer silent. `pendingPush` stays `true` on error so blur, debounce, or Sync Now will retry; a successful push clears both error fields. For deeper debugging, check Console.app filtering on `StickyDocs`.
- All `SyncEngine` and UI controller code is `@MainActor`. GRDB `ValueObservation` callbacks hop back to the main actor via `Task { @MainActor in ... }`.
- Sticky window styling depends on `StickyKeyableWindow` overriding `canBecomeKey`/`canBecomeMain`; a borderless `NSWindow` is not key-eligible by default, which would break text input and (transitively) the blur-triggered push.
