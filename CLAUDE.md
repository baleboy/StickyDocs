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

`StickyDocs/StickyDocs/Auth/Secrets.swift` is gitignored. To bring up a fresh checkout, copy `Secrets.example.swift` content into `Secrets.swift` and fill in a Google Cloud OAuth client (Desktop app type) with Drive + Docs APIs enabled. The committed `Secrets.swift` is a stub; the example file's body is commented out so both can coexist without a duplicate `Secrets` enum.

## Architecture

Menu-bar macOS app (`MenuBarExtra` + a hidden main `Window`). Each sticky is a borderless floating `NSWindow` synced 1:1 with a Google Doc in a `Stickies/` folder in the user's Drive.

**Data flow (single source of truth = local SQLite):**

```
NSTextView edit
  → StickyContentView.onChange
  → SyncEngine.updateContent (writes HTML + pending_push=true to StickyStore)
  → GRDB ValueObservation → StickyViewModel republishes
windowDidResignKey / windowWillClose
  → StickyWindowController.flushPendingPush
  → SyncEngine.push → GoogleDocsClient.replaceDocumentBody
```

There is **no debounced background sync, no polling, no timer.** Push happens only on blur, on close, or via explicit "Sync Now" (menu bar / sticky context menu). This is intentional for v1 — see the comment at the top of `SyncEngine.swift` listing deferred work.

**Lazy Doc provisioning.** `createLocalSticky` never touches the network. `push()` provisions a Drive Doc on the first push *only if* the sticky has non-whitespace content (so empty discarded stickies leave no Drive litter). Once provisioned, `googleDocId` is set and the sticky's `syncStatus` transitions `unprovisioned → pending → synced`.

**Unlinked state.** If Drive returns 404/410 or the Doc is trashed, `push()` clears `googleDocId` and `lastRevisionId` but keeps `lastSyncedAt`. That sentinel means "was once synced, now broken" — subsequent automatic pushes hold (don't silently recreate a Doc); the user must invoke "Re-create Doc in Drive" from the context menu (`recreateDoc`).

**Conflict handling.** `pull()` compares `lastRevisionId` against Drive's current `revisionId`. If remote advanced *and* local had unsynced edits (`pendingPush` + content diverges from `lastSyncedHTML`), local content is stashed into `conflictBackupHTML` and remote wins. `restoreBackup` swaps it back. v1 has no UI toast for this yet.

**HTML round-trip.** `HTMLNormalizer` converts between `NSAttributedString` (what `NSTextView` produces) and a sanitized HTML subset that Google Docs accepts via `replaceDocumentBody`. All comparisons (`contentHTML` vs `lastSyncedHTML`) assume canonicalised HTML, so always route through the normalizer rather than comparing raw strings.

**Folder ID is cached in `app_state`.** `FolderIdCache` (in `AppController.swift`) memoises the Stickies/ folder ID after the first `findOrCreateFolder` call. `wipeAll()` (Debug → Reset All Local Data) clears it, so the next push re-creates the folder. Bugs in `findOrCreateFolder` only surface on fresh installs / after a reset, which is easy to miss.

**Dependency injection at the network boundary.** `SyncEngine.Dependencies` is a struct of closures (`createDoc`, `exportAsHTML`, `pushBody`, etc.) wired up once in `AppController.init`. Tests substitute fakes — see `SyncEngineTests.swift` and `RoundTripIntegrationTests.swift`. Don't make `SyncEngine` reach into `GoogleDocsClient`/`GoogleDriveClient` directly.

**Auth.** `AuthService` does OAuth via a loopback redirect (`LoopbackServer` runs an in-process HTTP server on a random port) with PKCE. Tokens live in the Keychain via `KeychainStore`. Access tokens are refreshed lazily inside `accessToken()`.

## Conventions worth knowing

- Call sites of `engine.push(...)` are wrapped in `try?` (silent failure). When debugging missing syncs, replace with `do/catch + NSLog`; check Console.app filtering on `StickyDocs`.
- All `SyncEngine` and UI controller code is `@MainActor`. GRDB `ValueObservation` callbacks hop back to the main actor via `Task { @MainActor in ... }`.
- Sticky window styling depends on `StickyKeyableWindow` overriding `canBecomeKey`/`canBecomeMain`; a borderless `NSWindow` is not key-eligible by default, which would break text input and (transitively) the blur-triggered push.
