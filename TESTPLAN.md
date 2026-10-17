# StickyDocs — Manual Test Plan

A checklist for walking the app end-to-end. Run through it whenever you want to
shake out regressions. Prerequisites: signed into Google with the test account,
fresh launch from Xcode build (or installed app), at least one available Space
on macOS.

---

## 0. First-run onboarding

**Resetting to a first-run state.** The app is sandboxed, so its data lives in the container, *not* in `~/Library/Application Support`. A stale empty `~/Library/Application Support/StickyDocs/stickies.sqlite` may exist from pre-sandbox builds — deleting that one does nothing. Quit the app first (menu bar → Quit; a running app rewrites its state on exit), then:

```bash
# Local state: stickies, onboarding flag, cached folder id, prefs (incl. FeatureTour.seenVersion), OAuth cookies
rm -rf ~/Library/Containers/com.baleware.StickyDocs
# Refresh token (note the service is com.balenet, not com.baleware)
security delete-generic-password -s "com.balenet.StickyDocs.GoogleOAuth" -a default
```

The onboarding gate is `onboarding_complete` in the DB's `app_state` table (`AppController.swift:70`), so deleting the sqlite alone is enough to re-trigger onboarding; the wider wipe above also clears Sparkle's state and the signed-in session.

**This does not reset Drive.** `discoverRemoteStickies()` re-imports every Doc tagged `appProperties.stickydocs=v1`, so a local wipe plus the same Google account reproduces *"reinstall with existing data"* — not a new user. For a true new-user run, sign in with a Google account that has never used StickyDocs. Both are worth testing; they differ (a real new user sees no import, an existing one gets stickies restored with `isOpen=false`).

**Gatekeeper first-open** is only exercised on a freshly *downloaded* DMG — the quarantine attribute is what triggers it. Testing a locally built or already-unquarantined copy skips that step entirely.

- [ ] **Fresh install — intro appears.** Reset as above, then launch the app. An onboarding window appears titled "Welcome to StickyDocs" with two bullet points (what StickyDocs is, not how sync works) and a **Continue** button.
- [ ] **Continue → sign-in step.** Click Continue. View flips to "Sign in with Google" with **Skip for now** and **Sign in with Google** buttons.
- [ ] **Happy path — create new folder.** Click **Sign in with Google**, complete OAuth. View flips to "Choose your Stickies folder" with a text field pre-filled `Stickies`. Click **Finish**. The same window moves on to the feature tour (see 0b), starting with "You're all set". Open Drive — a folder named `Stickies` exists. Create a sticky and push — the Doc lands in `Stickies/`.
- [ ] **Custom folder name.** Repeat fresh install. On the folder step, change name to e.g. `Notes`. Finish. Drive contains a `Notes/` folder; pushed Docs land there.
- [ ] **Skip for now.** Fresh install. Continue → on sign-in step click **Skip for now**. The window moves on to the feature tour; on the Google Docs page a line reads "Once you sign in from the menu bar icon:". Finish or skip the tour. Menu bar: signed-out, **New Sticky** works (creates local-only sticky). No folder created in Drive. Relaunch: onboarding does NOT re-appear.
- [ ] **Sign-in after skip → folder prompt.** After skipping, sign in via menu bar "Sign In with Google...". A folder-choice window appears (jumps straight to the folder step). Pick `Stickies` and Finish. The window closes (no tour: it was already seen). First push lands in `Stickies/`.
- [ ] **Close onboarding window mid-flow = skip.** Fresh install. Click the red close button on the intro window. Treated as skip: setup does NOT re-appear on relaunch, but the feature tour does, on its own (it was never seen); first push later auto-creates `Stickies/`.
- [ ] **New Sticky before onboarding finishes.** Fresh install — onboarding window visible. Click menu bar **New Sticky** instead of completing onboarding. Behavior: brings the onboarding window forward (does NOT create a sticky).
- [ ] **Reset re-triggers onboarding.** Complete onboarding. Run Debug → Reset All Local Data → relaunch. Onboarding window appears again; after the folder step it closes without the tour (the tour record lives in UserDefaults, which the reset doesn't touch). (The Debug submenu is `#if DEBUG` only — on an installed release build use the `rm -rf` reset above instead.)
- [ ] **Empty folder name rejected.** On the folder step, clear the text field and click Finish. Error message appears; window stays.

## 0b. Feature tour

The tour is recorded per Mac in UserDefaults (`FeatureTour.seenVersion`), not in the DB. To see it again as a returning user: `defaults delete com.baleware.StickyDocs FeatureTour.seenVersion` with the app quit (sandboxed: the plist is in the container, so `rm -rf` of the container above resets it too).

- [ ] **After setup.** Fresh install, sign in, Finish the folder step → the same window shows a big "You're all set" title, "A few things worth knowing", and three rows with coloured icons: **Closing isn't deleting**, **Dates in a keystroke**, **Watch the dot**. One page, so no page dots or Back/Skip links; a small "Reopen any time from StickyDocs Tips…" line above a wide button.
- [ ] **Signed-out wording.** Skip sign-in → the tour's **Watch the dot** row starts "Once you sign in, …".
- [ ] **Create my first sticky.** New account with no stickies: the button reads **Create My First Sticky**. Click it → the window closes and an empty sticky opens, focused, ready to type.
- [ ] **Restored stickies → Done.** Fresh install with an account that already has stickies in Drive: after setup the button reads **Done** (it may switch once restored stickies arrive), and when the window closes the All Stickies panel opens (not over the tour).
- [ ] **Esc.** Esc closes the tour, creates no sticky, and the tour doesn't come back on relaunch. Return presses the wide button.
- [ ] **Existing user updating.** On a Mac that used a pre-tour build (setup already done, no `FeatureTour.seenVersion`): launch the new build → after restored stickies appear, the tour opens on its own titled "StickyDocs Tips", without setup steps, button **Done**. Relaunch → no tour.
- [ ] **What's New.** With `defaults write com.baleware.StickyDocs FeatureTour.seenVersion -int 0` (app quit), launch → titled "What's New in StickyDocs", subtitle "Since you last updated", showing every tip added since (all three while the tour is at version 1).
- [ ] **More than one page.** Only reachable once there are more than three tips (see the "What's New, page 2 of 2" preview in `OnboardingFlow.swift`): button reads **Continue** until the last page; Back · dots · Skip appear under it; ← → page; Skip is hidden on the last page.
- [ ] **StickyDocs Tips.** Menu bar icon → **StickyDocs Tips**, and Help → **StickyDocs Tips** (with a sticky focused): the full tour opens, button **Done**. With setup on screen, the item just brings the setup window forward.
- [ ] **Sign-out doesn't replay it.** Sign out (which wipes local data) and sign back in → setup runs again, the tour does not.
- [ ] **Stickies stay usable.** While the tour is open, click a sticky behind it and type → works.

## 1. Auth

- [ ] **Cold launch, signed out.** Menu bar extra shows **Sign In with Google...**; "Sync Now" / "Open Stickies Folder" disabled. **New Sticky stays enabled** (stickies can be created offline, *once onboarding has been completed or skipped*). Auth/Harness window shows "Not signed in." (grey).
- [ ] **Sign-in auto-syncs pending edits.** Signed out, create a sticky and type content (or edit an existing one). Sign in. Without clicking Sync Now, the pending sticky pushes automatically — verify the Doc appears (or updates) in Drive within a few seconds.
- [ ] **Sign in.** Click **Sign In with Google...** from the menu bar. A system sign-in sheet appears in-app (no external browser); consent succeeds; the sheet dismisses itself. Menu flips to **Sign Out...**; harness header turns green "Signed in.". Actions enable.
- [ ] **Sign out clears local data.** Click **Sign Out...**. A confirmation alert explains the local copies are removed (and, if any sticky has unsynced changes, says how many will be pushed first). Cancel → nothing happens. Confirm → all sticky windows and All Stickies close, the local list is empty, and the menu flips back to "Sign In with Google...". The Docs are still in Drive.
- [ ] **Sign out pushes unsynced edits first.** Type in a sticky and immediately Sign Out (before the 1.5s debounce fires). Confirm. The edit still lands in the Drive Doc — verify at docs.google.com.
- [ ] **Sign back in with the same account.** After the sign-out above, sign in again. The folder-choice step appears (onboarding state was cleared); pick the same folder name. All previous stickies are re-discovered from Drive and appear in All Stickies (closed, not auto-spawned as windows).
- [ ] **Account switch.** Signed in as account A with stickies, Sign Out and confirm, then sign in as account B. B sees **only** B's stickies — none of A's remain in All Stickies, before or after a quit-and-relaunch. Creating a sticky as B pushes successfully (no 404 against A's folder).
- [ ] **Token persistence.** Sign in. Quit (⌘Q from menu bar extra). Relaunch. App is still signed in (no sign-in sheet opens). Menu shows Sign Out....

## 2. Sticky creation

- [ ] **New from menu bar.** ⇧⌘N (or "New Sticky" menu item). A yellow borderless window appears instantly — no network delay.
- [ ] **Launch with no open stickies shows All Stickies.** Onboarding complete, at least one sticky exists but all are hidden (✕). Quit and relaunch → the All Stickies launcher appears centered. With at least one sticky window restored, it does not appear.
- [ ] **Launch with no stickies auto-creates one.** Onboarding already complete. Delete every sticky (trash icon on each, plus All Stickies for any hidden ones) so the store is empty. Quit (⌘Q) and relaunch. A single blank sticky appears on screen. (Skipped during first-run onboarding: a fresh install that hasn't completed onboarding does NOT auto-spawn a sticky.)
- [ ] **No Doc yet.** Open Drive → Stickies/ folder. The newly-created empty sticky does **not** appear there.
- [ ] **First push provisions Doc.** Type "Hello world" in the sticky. Click another app (window blurs). Wait a moment, then refresh Drive Stickies folder: a Doc titled "Hello world" appears.
- [ ] **Title derivation — long first line.** Create a new sticky. Type a single line longer than 50 characters. Blur. Doc title is the leading whole words of the first line that fit in 50 characters (no mid-word truncation). If even the first word exceeds 50 chars, title falls back to `Sticky YYYY-MM-DD HH:MM`.
- [ ] **Title is stable after first sync.** In a synced sticky, edit so the first line is different ("Updated heading"). Blur. The Doc body updates, but the Drive file title does **not** change.

## 3. Window behavior

- [ ] **Always on top.** With "Keep Stickies on Top" enabled (the default), open a sticky. Click another app window — sticky stays visible above it.
- [ ] **Keep on Top off.** Menu bar → untick "Keep Stickies on Top (⌥⌘S)". Click a Safari/Finder window — the sticky is now covered by it, but has **not** moved, closed, or changed size.
- [ ] **Keep on Top back on.** Tick it again. All open stickies come back to the front immediately, in their original positions.
- [ ] **Global hotkey.** With Safari frontmost (StickyDocs *not* active), press ⌥⌘S. Stickies drop behind Safari. Press ⌥⌘S again — they return to the front. Open the menu bar menu and confirm the checkmark matches the current state.
- [ ] **New sticky respects the setting.** With the toggle off, create a sticky (⇧⌘N). It appears but does **not** float above other apps.
- [ ] **Setting persists.** With the toggle off, quit (⌘Q) and relaunch. Restored stickies come back non-floating and the menu item is still unticked.
- [ ] **Across Spaces.** Switch to a different Space via Mission Control or trackpad. The sticky is still visible in the same screen position. Repeat with "Keep Stickies on Top" off — stickies still follow across Spaces.
- [ ] **Drag to move.** Drag the sticky from anywhere in the top 16-pixel strip (above the text) or from a non-text area. The sticky moves smoothly. Frame persists across relaunch.
- [ ] **Resize.** Drag the bottom-right corner. Frame persists across relaunch.
- [ ] **Tiling doesn't stick.** Drag a sticky to the menu bar so macOS fills the screen with it, then quit and relaunch. The sticky comes back at its last hand-dragged size, not screen-sized.
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
- [ ] **Format → Bulleted List / Numbered List.** Select one or more paragraphs → the item turns them into list items; choosing it again on an all-list selection turns them back into plain paragraphs.
- [ ] **List shortcut `- ` / `* `.** On an empty line, type `- ` → the line becomes a bullet and the `-` disappears. Same with `* `.
- [ ] **List shortcut `1. ` / `1) `.** On an empty line, type `1. ` → a numbered item. Same with `1) `. Return continues the list (2, 3…).
- [ ] **Shortcut only at start of line.** Typing `a - b`, `see 1. above`, `2. two` or `10. ten` leaves plain text. Typing `- ` inside an existing list item doesn't nest or convert.
- [ ] **Pasted markers stay text.** Paste a line beginning with `- ` → it stays plain text.
- [ ] **Undo the shortcut.** Type `- ` then ⌘Z immediately → the literal `- ` comes back as plain text (one undo step).
- [ ] **Return on an empty item ends the list.** In a list, press Return twice → the list ends and the new line is plain text.
- [ ] **Backspace removes the bullet.** Cursor at the start of a list item's text, Backspace → the bullet/number is gone, the text stays as a plain paragraph.
- [ ] **Shortcut lists sync like menu lists.** A list made with `- ` shows as a normal bulleted list in the Doc after blur, and the sticky goes pending (orange dot) right after the conversion.
- [ ] **Date shortcuts.** Type `@today` then a space → replaced with today's date in the system's medium style (e.g. `17 Oct 2026`), and the space is kept. Same with Return. Tab expands it without inserting a tab (it accepts the previewed date); with no date shortcut before the cursor, Tab inserts a tab as usual. `@tomorrow` / `@yesterday` → the next / previous day; `@week` → the ISO week number (e.g. `W42`). Case doesn't matter (`@Today`).
- [ ] **Date shortcut boundaries.** Typing `bob@today `, `@todays `, `@today. `, `@today.com ` or `@foo ` leaves the text as typed. `(@today ` expands.
- [ ] **Date shortcut hint.** Type `@today` → the keyword gets a grey tint and a small white box appears just below it showing today's date and `⇥`. It also appears mid-line, without covering the text after the cursor. On the sticky's last visible line the box appears above the keyword instead; near the right edge it shifts left to stay inside the sticky. Neither tint nor box is part of the text: they go away when you type another letter, move the cursor, or switch to another window, and come back when you return to just after the keyword. Partial keywords (`@tod`) show nothing. Typing `@today` right in front of a word (`@today|ok`) shows the hint too; Space or Tab gives `17 Oct 2026 ok`.
- [ ] **Esc dismisses a date shortcut.** Type `@today`, press Esc → the hint disappears and typing a space leaves `@today ` as typed. Pressing Tab instead of space inserts a tab and doesn't expand. Delete the `y` and retype it → the hint comes back and a space expands it. Esc with no hint showing behaves as before.
- [ ] **Undo a date shortcut.** Type `@today ` then ⌘Z immediately → the literal `@today ` comes back (one undo step).
- [ ] **Pasted date keywords stay text.** Paste `on @today ok` → it stays as pasted.
- [ ] **Date shortcut keeps formatting and syncs.** In a bold run or a list item, `@week ` expands to bold / stays in the item. The sticky goes pending right after, and after blur the Doc shows the date as plain text.
- [ ] **Typed URL becomes a link.** Type `https://example.com` then a space (or Return / Tab) → it turns blue and underlined. Nothing is linked mid-word (typing `www.apple.` doesn't link `www.apple`). Same for `www.apple.com` (links to `https://www.apple.com/`) and `me@example.com` (a `mailto:` link). A bare `example.com` or `notes.txt` stays plain.
- [ ] **Typed URL in a long existing sticky.** Open an old sticky with a lot of content (several screens, code snippets, quotes) and type `www.balenet.com` and a space at the end and in the middle → linked each time.
- [ ] **Trailing punctuation excluded.** Type `See https://example.com.` and `(https://example.com)` → the period and the closing paren aren't part of the link.
- [ ] **Pasted URL becomes a link.** Paste `visit https://example.org/x now` → only the URL is linked.
- [ ] **Undo detection.** Type a URL and a space, then ⌘Z → the link is removed, the text stays.
- [ ] **Clicking a link.** Hover a link → pointing-hand cursor. Click → opens in the default browser (`mailto:` opens the mail client).
- [ ] **Typing after a link.** Put the cursor right after a link and type → the new text is not part of the link. Select part of a URL link's text and retype it (e.g. `com` → `org`) → the link target follows the visible text; edit it into a non-URL and the link goes away.
- [ ] **Link context menu.** Right-click a link → **Open Link**, **Copy Link**, **Remove Link** at the top of the menu (no duplicates). Remove Link keeps the text and marks the sticky pending.
- [ ] **Existing stickies aren't rescanned.** A sticky that already contained a plain-text URL before upgrading still shows it as plain text after relaunch, and nothing pushes on launch because of it.
- [ ] **Undo (⌘Z).** Type, then undo. Text reverts.
- [ ] **Emoji (⌃⌘Space).** System emoji picker works inside the sticky.

## 5. Sync — push

- [ ] **Push on blur.** Type in sticky, click another app, refresh Drive. Doc body matches sticky.
- [ ] **Typing during an in-flight push isn't lost.** In a synced sticky, type a sentence, pause ~2s (debounce push starts), type a few more words, and within a second click another app. The sticky still shows every word after blur, and after a moment the Doc in Drive does too. Repeat on a brand-new sticky (first push creates the Doc, which is the slowest window).
- [ ] **Clearing a synced sticky syncs.** In a synced sticky, select all and delete. Blur. The Doc in Drive becomes empty and the status dot doesn't stay orange.
- [ ] **Typed-then-trashed sticky leaves no Doc.** Create a new sticky, type a word, and within a second click the trash icon and confirm. Wait a few seconds: no new Doc appears in the Stickies folder.
- [ ] **Push on close.** Type in sticky, click ✕. Doc body updates in Drive (refresh to verify).
- [ ] **Empty stickies don't sync.** Create new sticky, don't type, blur. No Doc appears in Drive.
- [ ] **Whitespace-only doesn't sync.** Type just spaces/newlines, blur. No Doc.
- [ ] **Sync Now.** Edit a sticky → menu bar extra → Sync Now. All pending stickies push, and any remote edits are pulled in first.

## 6. Sync — pull

- [ ] **Pull after remote edit.** Open the Doc in browser. Edit content (add a paragraph). Save. Back in app, trigger pull either by relaunching the app or by clicking Sync Now in the menu bar. Sticky updates to show the remote content. *Pull-on-focus per-sticky is deferred to v2.*
- [ ] **Remote edit while typing applies immediately.** With a synced sticky focused and its Doc open in a browser, add a word in the browser. Back in the sticky, click into the text and turn wifi off and on (reconnect triggers Sync Now) without clicking away. The sticky's text updates in place to include the remote word. Typing afterwards keeps it; it isn't reverted to the pre-pull text.
- [ ] **Round-trip fidelity.** Type in sticky: bold, italic, underline, bulleted list, numbered list. Blur. Open the Doc in browser — formatting renders correctly. Quit and relaunch the app — sticky reappears with formatting intact locally.
- [ ] **Link: sticky → Doc.** Type a URL (and a bold one, via ⌘B over link text) in a sticky. Blur. In the Doc, both are working blue links; the bold one is still bold.
- [ ] **Link: Doc → sticky.** In the Doc, add a link via Insert link (on "click here") and one by auto-linking a typed URL. Sync Now → both are clickable in the sticky, pointing at the real target (not a `google.com/url?q=` redirect), and aren't shown as `<u>`-underlined text after the next push. Edit the sticky and blur → the links are still in the Doc.
- [ ] **Link without formatting stays clean.** After the link round trip, ⌘U-underlined text elsewhere in the sticky is still underlined and link text isn't; nothing shows as a conflict.

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

## 10. All Stickies launcher

- [ ] **Open from menu bar.** Menu bar → Show All Stickies. A fixed-size (about 800×480), borderless, rounded window opens centered and key, with an ✕ button top-left and no traffic lights. It can be dragged by its background and can't be resized.
- [ ] **Other triggers.** Clicking the Dock icon with no visible windows opens it. On a fresh install, Drive discovery importing stickies opens it once onboarding has finished — never on top of (or before) onboarding.
- [ ] **Left pane.** App icon, "StickyDocs", "Version <x>" matching About. Status line: signed in → green dot, `<account email> · Synced <relative time>`; during Sync Now → `Syncing…`; signed out → gray dot, `Not signed in`.
- [ ] **Buttons.** Signed in: New Sticky (⇧⌘N), Sync Now, Open Stickies Folder in Drive. Signed out: Sign In with Google… first, then New Sticky. Buttons highlight on hover.
- [ ] **Sync Now.** Click → the icon spins, the status says `Syncing…`, and the button can't be clicked again until it finishes. The launcher stays open; afterwards the status says `Synced just now`.
- [ ] **New Sticky / Open close it.** New Sticky creates a sticky and closes the launcher. Opening a row closes it too.
- [ ] **Rows.** Each row has a sticky-colored tile, a bold title (first line if untitled, else "(Untitled)"), a one-line preview and a date. Newest-edited first.
- [ ] **Dates.** Today → `2 min ago` / `1 hr ago`; then `Yesterday`; the weekday within the last week; then a short date (with the year if it isn't this year).
- [ ] **Sync status dot.** Only unsynced stickies show the dot (orange pending, red error/unlinked) next to the title; hover shows the usual tooltip.
- [ ] **Keyboard.** The first row is selected on open (accent highlight). ↑/↓ move the selection (the list scrolls to follow). Return opens the selected sticky and closes the launcher. Esc closes it.
- [ ] **Double-click.** Double-click a row → opens the sticky (brought to front if already open) and the launcher closes. A single click only selects.
- [ ] **Context menu.** Right-click a row → Open, Open in Google Docs, Copy Doc link, Delete…. The Docs items are disabled for a sticky without a Doc. Delete… shows the usual confirmation (with the "Also delete the Google Doc" checkbox) for open and closed stickies alike.
- [ ] **Live update.** With the launcher open, Sync Now imports a sticky made on another Mac (or edit a sticky via ⇧⌘N + typing from another window) → the list updates without reopening.
- [ ] **Empty state.** With no stickies, the right pane says "No stickies yet" / "Press ⇧⌘N to create one".
- [ ] **Light and dark mode.** Switch appearance with the launcher open → both panes follow; the right pane stays slightly darker than the left.

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
- [ ] **Quit flushes pending edits.** Type in a sticky and press ⌘Q within a second (before the 1.5s debounce). The app quits within a few seconds; the Doc in Drive has the typed text.
- [ ] **Launch pushes edits left pending.** Disconnect wifi, type in a sticky, close its window (✕), quit. Reconnect, relaunch. Without opening the sticky or clicking Sync Now, the Doc in Drive updates within a few seconds.
- [ ] **Auto-sync on reconnect.** Disconnect wifi. Type in a sticky and wait for the red banner. Reconnect wifi but do NOT touch the app. Within a few seconds the banner should clear on its own — the network-path monitor fires `syncNow` on the offline→online transition. Verify the Doc in Drive is updated.
- [ ] **Token revocation → re-auth banner.** Sign in normally, then revoke the app's access at https://myaccount.google.com/permissions (or sign out of Google in a way that invalidates the refresh token). Type in a sticky to trigger a push. Expected: a **blue "Sign in to Google to keep syncing." banner** with a `Sign In` button. Menu bar flips to "Sign In with Google..." (because `accessToken()` cleared the dead token). Click the banner's `Sign In`, complete OAuth. Banner clears, sticky syncs, every other sticky's banner clears too.
- [ ] **Re-auth banner outranks generic error.** If both an auth failure and a generic network error apply to a sticky, the blue Sign-In banner wins until OAuth completes.
- [ ] **Very long sticky.** Type ~2,000 chars including formatting. Push. Open Doc in browser — content intact. Pull on relaunch — content intact.
- [ ] **Many stickies.** Create 20 stickies. All restore on relaunch. All Stickies panel renders without lag.
- [ ] **Doc deleted in Drive UI.** Trash a sticky's Doc in Drive. Trigger a push from app on that sticky. Expected: push detects the 404, status flips to **unlinked** (red dot, tooltip "Doc was deleted in Drive"). Right-click → "Re-create Doc in Drive" provisions a fresh Doc with current content.
- [ ] **Cross-machine restore.** Install the app on a second Mac, sign in with the same Google account, finish onboarding. After the first `Sync Now` (or the automatic sign-in sync), every sticky from the first Mac appears in the All Stickies panel. Stickies are imported with `isOpen=false` so no floating windows pop up uninvited — click a row to open one. Verify content matches the Doc in Drive. Console log shows `Discovered N sticky/stickies from Drive`. Imported stickies keep Drive's last-modified time, so the All Stickies order on the second Mac matches the order on the first (not the arbitrary order they were imported in).
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
