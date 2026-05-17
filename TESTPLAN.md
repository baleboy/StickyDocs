# StickyDocs — Manual Test Plan

A checklist for walking the app end-to-end. Run through it whenever you want to
shake out regressions. Prerequisites: signed into Google with the test account,
fresh launch from Xcode build (or installed app), at least one available Space
on macOS.

---

## 1. Auth

- [ ] **Cold launch, signed out.** Menu bar extra shows **Sign In with Google...**; "New Sticky" / "Sync Now" / "Open Stickies Folder" disabled. Auth/Harness window shows "Not signed in." (grey).
- [ ] **Sign in.** Click **Sign In with Google...** from the menu bar. Browser opens; consent succeeds; lands on `localhost:<port>/...` "Sign-in complete" page. Menu flips to **Sign Out**; harness header turns green "Signed in.". Actions enable.
- [ ] **Sign out.** Click Sign Out. Menu flips back. Header reverts to "Not signed in.".
- [ ] **Token persistence.** Sign in. Quit (⌘Q from menu bar extra). Relaunch. App is still signed in (no browser opens). Menu shows Sign Out.

## 2. Sticky creation

- [ ] **New from menu bar.** ⇧⌘N (or "New Sticky" menu item). A yellow borderless window appears instantly — no network delay.
- [ ] **No Doc yet.** Open Drive → Stickies/ folder. The newly-created empty sticky does **not** appear there.
- [ ] **First push provisions Doc.** Type "Hello world" in the sticky. Click another app (window blurs). Wait a moment, then refresh Drive Stickies folder: a Doc titled "Hello world" appears.
- [ ] **Title derivation — long first line.** Create a new sticky. Type a single line longer than 50 characters. Blur. Doc title is the leading whole words of the first line that fit in 50 characters (no mid-word truncation). If even the first word exceeds 50 chars, title falls back to `Sticky YYYY-MM-DD HH:MM`.
- [ ] **Title is stable after first sync.** In a synced sticky, edit so the first line is different ("Updated heading"). Blur. The Doc body updates, but the Drive file title does **not** change.

## 3. Window behavior

- [ ] **Always on top.** Open a sticky. Click another app window — sticky stays visible above it.
- [ ] **Across Spaces.** Switch to a different Space via Mission Control or trackpad. The sticky is still visible in the same screen position.
- [ ] **Drag to move.** Drag the sticky from anywhere in the top 16-pixel strip (above the text) or from a non-text area. The sticky moves smoothly. Frame persists across relaunch.
- [ ] **Resize.** Drag the bottom-right corner. Frame persists across relaunch.
- [ ] **Close button.** Hover over the sticky — small ✕ appears top-left. Click it; window closes. Doc remains in Drive. Sticky still exists in DB (re-opens via All Stickies → click).

## 4. Editing & formatting

- [ ] **Plain text.** Type text. No flicker. Cursor stays where expected.
- [ ] **Bold (⌘B).** Place cursor in word, ⌘B, type — new text is bold. Select existing text, ⌘B — selection toggles bold.
- [ ] **Italic (⌘I).** Same as bold.
- [ ] **Underline (⌘U).** Same as bold.
- [ ] **Format menu.** App menu bar → Format → Bold/Italic/Underline work the same as shortcuts.
- [ ] **Undo (⌘Z).** Type, then undo. Text reverts.
- [ ] **Emoji (⌃⌘Space).** System emoji picker works inside the sticky.
- [ ] **Spellcheck.** Misspelled word gets red underline; right-click suggests corrections.

## 5. Sync — push

- [ ] **Push on blur.** Type in sticky, click another app, refresh Drive. Doc body matches sticky.
- [ ] **Push on close.** Type in sticky, click ✕. Doc body updates (refresh Drive to verify).
- [ ] **Empty stickies don't sync.** Create new sticky, don't type, blur. No Doc appears in Drive.
- [ ] **Whitespace-only doesn't sync.** Type just spaces/newlines, blur. No Doc.
- [ ] **Sync Now.** Edit a sticky → menu bar extra → Sync Now. All pending stickies push.

## 6. Sync — pull

- [ ] **Pull after remote edit.** Open the Doc in browser. Edit content (add a paragraph). Save. Back in app, close and re-open the sticky (current build pulls on focus indirectly via app relaunch — pull triggers are not yet wired to the UI button beyond initial fetch). *Known gap: explicit pull trigger not in menu.*
- [ ] **Round-trip fidelity.** Type in sticky: bold, italic, underline, bulleted list, numbered list. Blur. Open the Doc in browser — formatting renders correctly. Close sticky in app, re-open via All Stickies — formatting still correct locally.

## 7. Conflict (manual provocation)

- [ ] **Setup.** Sign in. Create sticky, type "local". Blur (syncs). Open Doc in browser, type "remote", save.
- [ ] **Triggering pull.** Currently the easiest way to trigger pull is to relaunch the app (pull-on-focus is partial). Expected: remote wins; sticky shows "remote"; previous "local" is stashed in `conflict_backup_html`. *Status dot does not yet surface conflicts visually — known gap.*

## 8. Colors

- [ ] **Color picker via right-click.** Right-click a sticky → Color → pick blue. Background updates instantly.
- [ ] **Color persists.** Relaunch app. Sticky is still blue.
- [ ] **All six colors render.** Cycle through yellow, blue, green, pink, purple, gray.

## 9. Right-click menu

- [ ] **Open in Google Docs.** Right-click sticky → "Open in Google Docs". Browser opens at the Doc.
- [ ] **Copy Doc link.** Right-click → "Copy Doc link". Paste into anywhere — URL is `https://docs.google.com/document/d/<id>/edit`.
- [ ] **Sync now.** Right-click → "Sync now". Pending push (if any) drains.
- [ ] **Delete sticky.** Right-click → "Delete sticky". Window closes. Sticky disappears from All Stickies. Doc remains in Drive (not auto-trashed in current build).

## 10. All Stickies panel

- [ ] **Open from menu bar.** Menu bar → Show All Stickies. Panel opens.
- [ ] **Live update.** Open panel side-by-side with a sticky. Type in the sticky — preview text in panel row updates within ~1 second.
- [ ] **Click to focus.** Click a row → that sticky's window comes to the front (or opens if it was closed).
- [ ] **Color swatch matches.** Each row's swatch matches the sticky's color.
- [ ] **Sync status dot.** Stickies with pending changes show a small orange dot in the row. Synced stickies show no dot.

## 11. Menu bar extra

- [ ] **Icon visible.** Note icon appears in macOS menu bar.
- [ ] **Actions.** New Sticky (⇧⌘N), Show All Stickies, Sync Now, Open Stickies Folder in Drive, Sign In/Out, Quit StickyDocs (⌘Q).
- [ ] **Disabled state.** When signed out: New Sticky / Sync Now / Open Folder all disabled.

## 12. Persistence

- [ ] **Open stickies survive relaunch.** Open three stickies, position them at distinct points on screen. Quit. Relaunch. All three reappear at the same positions with the same content and colors.
- [ ] **Closed stickies don't auto-open.** Close a sticky's window. Quit. Relaunch. That sticky does not appear (still in DB; visible via All Stickies).
- [ ] **GRDB file location.** `~/Library/Containers/com.baleware.StickyDocs/Data/Library/Application Support/StickyDocs/stickies.sqlite` exists and grows with use.

## 13. Drive folder

- [ ] **First sync creates folder.** Sign in with a fresh Drive account → create + sync first sticky → "Stickies" folder appears in Drive root.
- [ ] **Subsequent syncs reuse folder.** Create more stickies → all land inside the same Stickies/ folder.
- [ ] **Cached folder id.** Quit/relaunch → check the app's `app_state.value` for `stickies_folder_id` (via DB inspector) — same id used.

## 14. Edge cases

- [ ] **Offline at push time.** Disconnect wifi. Type in a sticky, blur. Expected: push silently fails (no error toast yet — known gap). Sticky stays `pending_push=true`. Reconnect, Sync Now from menu — push succeeds.
- [ ] **Very long sticky.** Type ~2,000 chars including formatting. Push. Open Doc in browser — content intact. Pull on relaunch — content intact.
- [ ] **Many stickies.** Create 20 stickies. All restore on relaunch. All Stickies panel renders without lag.
- [ ] **Doc deleted in Drive UI.** Trash a sticky's Doc in Drive. Trigger a push from app on that sticky. Expected: push fails (404). *Status not surfaced; sticky stays pending — known gap.*

## 15. Auth/round-trip harness window

- [ ] **Round-trip test.** Click **Run Doc Round-Trip Test**. All 10 canned cases pass. Test Doc is created and trashed automatically.
- [ ] **List Drive files.** Click → returns files visible under `drive.file` scope (just StickyDocs-created ones).

---

## Known gaps (not bugs)

- Explicit pull trigger isn't wired to UI yet (pull happens implicitly only).
- Conflict toast / "Restore my version" action not yet surfaced.
- Push failures don't show user-visible errors (status dot stays orange forever).
- "Delete Doc too" checkbox on close not implemented.
- No debounced background push — push only on blur / explicit Sync Now.
- No periodic Drive `changes.list` polling — remote changes only show after relaunch.
- Preferences window and onboarding screen not built.
- Dark mode color variants not tuned.
