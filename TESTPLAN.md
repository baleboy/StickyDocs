# StickyDocs — Manual Test Plan

A checklist for walking the app end-to-end. Run through it whenever you want to
shake out regressions. Prerequisites: signed into Google with the test account,
fresh launch from Xcode build (or installed app), at least one available Space
on macOS.

---

## 0. First-run onboarding

**Resetting to a first-run state.** The app is sandboxed, so its data lives in the container, *not* in `~/Library/Application Support`. A stale empty `~/Library/Application Support/StickyDocs/stickies.sqlite` may exist from pre-sandbox builds — deleting that one does nothing. Quit the app first (menu bar → Quit; a running app rewrites its state on exit), then:

```bash
# Local state: stickies, onboarding flag, cached folder id, prefs, OAuth cookies
rm -rf ~/Library/Containers/com.baleware.StickyDocs
# Refresh token (note the service is com.balenet, not com.baleware)
security delete-generic-password -s "com.balenet.StickyDocs.GoogleOAuth" -a default
```

The onboarding gate is `onboarding_complete` in the DB's `app_state` table (`AppController.swift:70`), so deleting the sqlite alone is enough to re-trigger onboarding; the wider wipe above also clears Sparkle's state and the signed-in session.

**This does not reset Drive.** `discoverRemoteStickies()` re-imports every Doc tagged `appProperties.stickydocs=v1`, so a local wipe plus the same Google account reproduces *"reinstall with existing data"* — not a new user. For a true new-user run, sign in with a Google account that has never used StickyDocs. Both are worth testing; they differ (a real new user sees no import, an existing one gets stickies restored with `isOpen=false`).

**Gatekeeper first-open** is only exercised on a freshly *downloaded* DMG — the quarantine attribute is what triggers it. Testing a locally built or already-unquarantined copy skips that step entirely.

- [ ] **Fresh install — intro appears.** Reset as above, then launch the app. An onboarding window appears titled "Welcome to StickyDocs" with three bullet points and a **Continue** button.
- [ ] **Continue → sign-in step.** Click Continue. View flips to "Sign in with Google" with **Skip for now** and **Sign in with Google** buttons.
- [ ] **Happy path — create new folder.** Click **Sign in with Google**, complete OAuth. View flips to "Choose your Stickies folder" with a text field pre-filled `Stickies`. Click **Finish**. Window closes. Open Drive — a folder named `Stickies` exists. Create a sticky and push — the Doc lands in `Stickies/`.
- [ ] **Custom folder name.** Repeat fresh install. On the folder step, change name to e.g. `Notes`. Finish. Drive contains a `Notes/` folder; pushed Docs land there.
- [ ] **Skip for now.** Fresh install. Continue → on sign-in step click **Skip for now**. Window closes. Menu bar: signed-out, **New Sticky** works (creates local-only sticky). No folder created in Drive. Relaunch: onboarding does NOT re-appear.
- [ ] **Sign-in after skip → folder prompt.** After skipping, sign in via menu bar "Sign In with Google...". A folder-choice window appears (jumps straight to the folder step). Pick `Stickies` and Finish. First push lands in `Stickies/`.
- [ ] **Close onboarding window mid-flow = skip.** Fresh install. Click the red close button on the intro window. Treated as skip: onboarding does NOT re-appear on relaunch; first push later auto-creates `Stickies/`.
- [ ] **New Sticky before onboarding finishes.** Fresh install — onboarding window visible. Click menu bar **New Sticky** instead of completing onboarding. Behavior: brings the onboarding window forward (does NOT create a sticky).
- [ ] **Reset re-triggers onboarding.** Complete onboarding. Run Debug → Reset All Local Data → relaunch. Onboarding window appears again. (The Debug submenu is `#if DEBUG` only — on an installed release build use the `rm -rf` reset above instead.)
- [ ] **Empty folder name rejected.** On the folder step, clear the text field and click Finish. Error message appears; window stays.

## 1. Auth

- [ ] **Cold launch, signed out.** Menu bar extra shows **Sign In with Google...**; "Sync Now" / "Open Stickies Folder" disabled. **New Sticky stays enabled** (stickies can be created offline, *once onboarding has been completed or skipped*). Auth/Harness window shows "Not signed in." (grey).
- [ ] **Sign-in auto-syncs pending edits.** Signed out, create a sticky and type content (or edit an existing one). Sign in. Without clicking Sync Now, the pending sticky pushes automatically — verify the Doc appears (or updates) in Drive within a few seconds.
- [ ] **Sign in.** Click **Sign In with Google...** from the menu bar. A system sign-in sheet appears in-app (no external browser); consent succeeds; the sheet dismisses itself. Menu flips to **Sign Out**; harness header turns green "Signed in.". Actions enable.
- [ ] **Sign out.** Click Sign Out. Menu flips back. Header reverts to "Not signed in.".
- [ ] **Token persistence.** Sign in. Quit (⌘Q from menu bar extra). Relaunch. App is still signed in (no sign-in sheet opens). Menu shows Sign Out.

## 2. Sticky creation

- [ ] **New from menu bar.** ⇧⌘N (or "New Sticky" menu item). A yellow borderless window appears instantly — no network delay.
- [ ] **Launch with no stickies auto-creates one.** Onboarding already complete. Delete every sticky (trash icon on each, plus All Stickies for any hidden ones) so the store is empty. Quit (⌘Q) and relaunch. A single blank sticky appears on screen. (Skipped during first-run onboarding: a fresh install that hasn't completed onboarding does NOT auto-spawn a sticky.)
- [ ] **No Doc yet.** Open Drive → Stickies/ folder. The newly-created empty sticky does **not** appear there.
- [ ] **First push provisions Doc.** Type "Hello world" in the sticky. Click another app (window blurs). Wait a moment, then refresh Drive Stickies folder: a Doc titled "Hello world" appears.
- [ ] **Title derivation — long first line.** Create a new sticky. Type a single line longer than 50 characters. Blur. Doc title is the leading whole words of the first line that fit in 50 characters (no mid-word truncation). If even the first word exceeds 50 chars, title falls back to `Sticky YYYY-MM-DD HH:MM`.
- [ ] **Title is stable after first sync.** In a synced sticky, edit so the first line is different ("Updated heading"). Blur. The Doc body updates, but the Drive file title does **not** change.

## 3. Window behavior

- [ ] **Always on top.** Open a sticky. Click another app window — sticky stays visible above it.
- [ ] **Across Spaces.** Switch to a different Space via Mission Control or trackpad. The sticky is still visible in the same screen position.
- [ ] **Drag to move.** Drag the sticky from anywhere in the top 16-pixel strip (above the text) or from a non-text area. The sticky moves smoothly. Frame persists across relaunch.
- [ ] **Resize.** Drag the bottom-right corner. Frame persists across relaunch.
- [ ] **Close (✕) button = hide.** Hover over the sticky — a small ✕ appears top-left and a small trash icon top-right. Click ✕: window closes silently. Sticky still exists in All Stickies. Doc remains in Drive. Sticky does NOT auto-reopen on next launch (reopen via All Stickies → click row).
- [ ] **Delete (trash) button = remove.** Click the trash icon top-right. Confirmation dialog appears ("Delete this sticky?" with "Also delete the Google Doc in Drive" checkbox, default off). Click Delete: window closes, sticky disappears from All Stickies. Click Cancel: nothing changes.
- [ ] **Delete with also-delete-Doc.** On a synced sticky, click trash, tick the checkbox, click Delete. Sticky gone locally; Doc is removed from Drive.
- [ ] **Empty new sticky — trash skips confirmation.** Create a new sticky, don't type, click the trash icon. Window closes immediately with no dialog (nothing to lose).
- [ ] **Pending edits — hide still pushes.** Type in a sticky, immediately click ✕ (don't blur first). Window closes; verify in Drive that the Doc body reflects the typed content (push fires on hide).

## 4. Editing & formatting

- [ ] **Plain text.** Type text. No flicker. Cursor stays where expected.
- [ ] **Bold (⌘B).** Place cursor in word, ⌘B, type — new text is bold. Select existing text, ⌘B — selection toggles bold.
- [ ] **Italic (⌘I).** Same as bold.
- [ ] **Underline (⌘U).** Same as bold.
- [ ] **Format menu.** App menu bar → Format → Bold/Italic/Underline work the same as shortcuts.
- [ ] **Undo (⌘Z).** Type, then undo. Text reverts.
- [ ] **Emoji (⌃⌘Space).** System emoji picker works inside the sticky.

## 5. Sync — push

- [ ] **Push on blur.** Type in sticky, click another app, refresh Drive. Doc body matches sticky.
- [ ] **Push on close.** Type in sticky, click ✕. Doc body updates in Drive (refresh to verify).
- [ ] **Empty stickies don't sync.** Create new sticky, don't type, blur. No Doc appears in Drive.
- [ ] **Whitespace-only doesn't sync.** Type just spaces/newlines, blur. No Doc.
- [ ] **Sync Now.** Edit a sticky → menu bar extra → Sync Now. All pending stickies push, and any remote edits are pulled in first.

## 6. Sync — pull

- [ ] **Pull after remote edit.** Open the Doc in browser. Edit content (add a paragraph). Save. Back in app, trigger pull either by relaunching the app or by clicking Sync Now in the menu bar. Sticky updates to show the remote content. *Pull-on-focus per-sticky is deferred to v2.*
- [ ] **Round-trip fidelity.** Type in sticky: bold, italic, underline, bulleted list, numbered list. Blur. Open the Doc in browser — formatting renders correctly. Quit and relaunch the app — sticky reappears with formatting intact locally.

## 7. Conflict (manual provocation)

- [ ] **Setup.** Sign in. Create sticky, type "local". Blur (syncs). Open Doc in browser, type "remote", save.
- [ ] **Provoking the conflict.** Before triggering pull, also edit the sticky locally (e.g. append " edit") but do **not** blur — `pendingPush` must still be true with content diverged from `lastSyncedHTML`. Then trigger pull via Sync Now (or relaunch). Expected: remote wins; sticky shows the remote content; previous local edit is stashed in `conflict_backup_html`.
- [ ] **Conflict banner appears.** After the conflict resolves above, an **orange banner** between the title bar and the editor reads "Remote changes overwrote your unsynced edits." with **Restore mine** and **Discard** buttons. There is no × dismiss — the user must choose.
- [ ] **Banner persists across relaunch.** Quit and relaunch with the conflict unresolved. The banner is still there (driven by `conflict_backup_html` in the DB).
- [ ] **Restore mine.** Click **Restore mine** in the banner. Content reverts to the local edit; banner disappears; the Doc in Drive is **immediately** updated to match (Restore mine pushes right away — verify by refreshing the Doc in the browser).
- [ ] **Discard.** Re-create a conflict, then click **Discard** in the banner. Content stays on the remote version; banner disappears; `conflict_backup_html` is `nil`; no push is triggered.
- [ ] **Right-click fallback still works.** With a conflict active, the right-click menu also offers "Restore my version" / "Discard my backup" — they behave the same as the banner buttons.
- [ ] **Banner precedence.** With both a push error AND a conflict on the same sticky, the **red error banner** wins (the network problem has to clear before a conflict resolution can push).

## 8. Colors

- [ ] **Color picker via right-click.** Right-click a sticky → Color → pick blue. Background updates instantly.
- [ ] **Color persists.** Relaunch app. Sticky is still blue.
- [ ] **All six colors render.** Cycle through yellow, blue, green, pink, purple, gray.

## 9. Right-click menu

- [ ] **Open in Google Docs.** Right-click sticky → "Open in Google Docs". Browser opens at the Doc.
- [ ] **Copy Doc link.** Right-click → "Copy Doc link". Paste into anywhere — URL is `https://docs.google.com/document/d/<id>/edit`.
- [ ] **Sync now.** Right-click → "Sync now". Pending push (if any) drains.
- [ ] **Delete sticky.** Right-click → "Delete sticky". Same confirmation dialog as the trash icon. Click Delete: window closes, sticky disappears from All Stickies. Doc handling honors the checkbox.

## 10. All Stickies panel

- [ ] **Open from menu bar.** Menu bar → Show All Stickies. Panel opens.
- [ ] **Live update.** Open panel side-by-side with a sticky. Type in the sticky — preview text in panel row updates within ~1 second.
- [ ] **Click to focus.** Click a row → that sticky's window comes to the front (or opens if it was closed).
- [ ] **Color swatch matches.** Each row's swatch matches the sticky's color.
- [ ] **Sync status dot.** Stickies with pending changes show a small orange dot in the row. Synced stickies show no dot.

## 11. Menu bar extra

- [ ] **Icon visible.** Note icon appears in macOS menu bar.
- [ ] **Actions.** New Sticky (⇧⌘N), Show All Stickies, Sync Now, Open Stickies Folder in Drive, Sign In/Out, Quit StickyDocs (⌘Q).
- [ ] **Disabled state.** When signed out: Sync Now / Open Folder disabled. New Sticky remains enabled.

## 12. Persistence

- [ ] **Open stickies survive relaunch.** Open three stickies, position them at distinct points on screen. Quit. Relaunch. All three reappear at the same positions with the same content and colors.
- [ ] **Hidden stickies don't auto-open.** Click ✕ on a sticky. Quit. Relaunch. That sticky does not appear, but is still visible (and clickable to reopen) in All Stickies.
- [ ] **Deleted stickies don't come back.** Trash a sticky's window and confirm Delete. Quit. Relaunch. That sticky does not appear and is gone from All Stickies.
- [ ] **GRDB file location.** `~/Library/Containers/com.baleware.StickyDocs/Data/Library/Application Support/StickyDocs/stickies.sqlite` exists and grows with use.

## 13. Drive folder

- [ ] **First sync creates folder.** Sign in with a fresh Drive account → create + sync first sticky → "Stickies" folder appears in Drive root.
- [ ] **Subsequent syncs reuse folder.** Create more stickies → all land inside the same Stickies/ folder.
- [ ] **Cached folder id.** Quit/relaunch → check the app's `app_state.value` for `stickies_folder_id` (via DB inspector) — same id used.

## 14. Edge cases

- [ ] **Offline at push time.** Disconnect wifi. Type in a sticky, blur. Expected: push fails — a **red banner** appears between the title bar and the editor reading "Sync failed: The Internet connection appears to be offline." with a **Retry** button and an **×** dismiss. The status dot in the corner is also red. Sticky stays `pending_push=true`. Reconnect and click Retry (or just type to fire a debounced push) — banner disappears, dot clears.
- [ ] **Dismiss error.** While the red banner is showing, click the **×**. Banner disappears, dot turns orange (pending). On the next failed push the banner reappears with the latest error.
- [ ] **Push error survives relaunch.** Provoke a push error (disconnect wifi, edit, wait). Quit while offline. Relaunch (still offline). The sticky's banner is still there with the same text — the error is persisted. Reconnect and click Retry — banner clears.
- [ ] **Auto-sync on reconnect.** Disconnect wifi. Type in a sticky and wait for the red banner. Reconnect wifi but do NOT touch the app. Within a few seconds the banner should clear on its own — the network-path monitor fires `syncNow` on the offline→online transition. Verify the Doc in Drive is updated.
- [ ] **Token revocation → re-auth banner.** Sign in normally, then revoke the app's access at https://myaccount.google.com/permissions (or sign out of Google in a way that invalidates the refresh token). Type in a sticky to trigger a push. Expected: a **blue "Sign in to Google to keep syncing." banner** with a `Sign In` button. Menu bar flips to "Sign In with Google..." (because `accessToken()` cleared the dead token). Click the banner's `Sign In`, complete OAuth. Banner clears, sticky syncs, every other sticky's banner clears too.
- [ ] **Re-auth banner outranks generic error.** If both an auth failure and a generic network error apply to a sticky, the blue Sign-In banner wins until OAuth completes.
- [ ] **Very long sticky.** Type ~2,000 chars including formatting. Push. Open Doc in browser — content intact. Pull on relaunch — content intact.
- [ ] **Many stickies.** Create 20 stickies. All restore on relaunch. All Stickies panel renders without lag.
- [ ] **Doc deleted in Drive UI.** Trash a sticky's Doc in Drive. Trigger a push from app on that sticky. Expected: push detects the 404, status flips to **unlinked** (red dot, tooltip "Doc was deleted in Drive"). Right-click → "Re-create Doc in Drive" provisions a fresh Doc with current content.
- [ ] **Cross-machine restore.** Install the app on a second Mac, sign in with the same Google account, finish onboarding. After the first `Sync Now` (or the automatic sign-in sync), every sticky from the first Mac appears in the All Stickies panel. Stickies are imported with `isOpen=false` so no floating windows pop up uninvited — click a row to open one. Verify content matches the Doc in Drive. Console log shows `Discovered N sticky/stickies from Drive`.
- [ ] **Idempotent discovery.** Click Sync Now again. No duplicate stickies appear. Console doesn't log a second "Discovered" line (or logs 0).

## 15. Auth/round-trip harness window (DEBUG builds only)

The debug harness `Window("StickyDocs (Debug)")` only exists in DEBUG builds. In a Release build it should be **completely absent** — the app is menu-bar-only.

- [ ] **Debug build.** Build & run via Xcode (default = Debug). The "StickyDocs (Debug)" window opens on launch with the round-trip test buttons.
- [ ] **Round-trip test.** Click **Run Doc Round-Trip Test**. All 10 canned cases pass. Test Doc is created and trashed automatically.
- [ ] **List Drive files.** Click → returns files visible under `drive.file` scope (just StickyDocs-created ones).
- [ ] **Release build hides the harness.** Build with `-configuration Release` (Xcode: Product → Scheme → Edit Scheme → Run → Build Configuration = Release). Launch — no debug window appears. Menu bar icon is visible, "New Sticky" works, onboarding triggers on a fresh install. The `File → New Window` menu item is absent (no Window scene exists in release).

## 16. Sparkle auto-update

Updates ship via [Sparkle](https://sparkle-project.org/). The appcast lives at https://baleboy.github.io/StickyDocs/appcast.xml. Stable users only see items without a channel tag; alpha users see items tagged `<sparkle:channel>alpha</sparkle:channel>`. The git-tag convention drives the channel: bare semver (`v1.0.0`) → stable, pre-release (`v1.0.0-alpha.1`) → alpha.

**"Receive Alpha Updates" currently defaults to ON** (`Updater.swift`, registered default). Every published appcast item is alpha-tagged today, so with the toggle off a fresh install would never be offered anything. Flip the registered default back to `false` — and update the two channel steps below — once the first untagged stable item ships.

- [ ] **Check for Updates — no update available.** From the menu bar, click **Check for Updates...** when the installed version matches the latest applicable appcast item. Sparkle's "You're up to date" sheet appears.
- [ ] **Check for Updates — update available.** Install an older version (or temporarily bump the appcast version), click **Check for Updates...**. Sparkle's update sheet appears. Install → app relaunches on the new version. `CFBundleShortVersionString` in `Info.plist` matches the appcast item.
- [ ] **Background check.** Quit and relaunch. If `SUScheduledCheckInterval` (86400s) has elapsed since the last check and an update is available, Sparkle prompts on its own without user action.
- [ ] **Alpha channel — on by default on a fresh install.** Clear the pref (`defaults delete com.baleware.StickyDocs ReceiveAlphaUpdates`) and relaunch. **Receive Alpha Updates** shows ticked in the menu, and **Check for Updates...** offers the latest alpha-tagged item.
- [ ] **Alpha channel — opt out.** Untick **Receive Alpha Updates**, then click **Check for Updates...**. Alpha items are filtered out — with no untagged items published, Sparkle reports "You're up to date". Tick it again and the alpha item is offered on the next check.
- [ ] **Beta → alpha pref migration.** Set the old key only (`defaults delete com.baleware.StickyDocs ReceiveAlphaUpdates; defaults write com.baleware.StickyDocs ReceiveBetaUpdates -bool NO`) and relaunch. The toggle reads **off** — an explicit opt-out under the old name survives the rename and is not overridden by the new default-on. The old key is gone afterwards (`defaults read com.baleware.StickyDocs ReceiveBetaUpdates` errors).
- [ ] **Signature mismatch refuses install.** Replace the zip on a GitHub release with a corrupted copy (don't re-sign). Click **Check for Updates...**. Sparkle downloads it, fails EdDSA verification, and refuses to install. The installed version stays put.
- [ ] **Sandbox / XPC.** Confirm the install completes without Gatekeeper or sandbox warnings. The app is sandboxed; Sparkle's Installer Launcher XPC reaches its mach service via the `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki` temporary-exception entitlements.
- [ ] **Entitlement variables are expanded in the shipped build.** Must be run on a **CI-produced** artifact, not a local Xcode build — the two sign differently. Download the release zip, unpack, and run:

      codesign -d --entitlements - --xml StickyDocs.app | plutil -p - | grep spk

  Both entries must read `com.baleware.StickyDocs-spks` / `-spki`. A literal `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` means the update will download and verify and then fail to install with "failed to probe status service" in the Sparkle log. `release.yml` asserts this at sign time, but check it by hand after any change to the signing steps — `codesign`, `spctl`, and `notarytool` all pass on a build with this defect.
- [ ] **Read the Sparkle log when an update fails.** `/usr/bin/log show --last 1h --predicate 'subsystem == "org.sparkle-project.Sparkle"' --info --debug`. The UI error text is generic; the real cause is here.

---

## Known gaps (not bugs)

- Explicit pull trigger isn't wired to UI yet (pull happens implicitly only).
- No periodic Drive `changes.list` polling — remote changes only show on relaunch / focus / Sync Now.
- Preferences window not built.
- Dark mode color variants not tuned.
- No conflict toast UI yet (the conflict badge in §7 is the only signal).
- No re-auth UX when refresh token is revoked — pushes will turn the dot red on every sticky but there's no "Sign in required" affordance yet.
