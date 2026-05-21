# First-run onboarding plan

Status: proposal — not yet implemented. v1 design locked elsewhere, this is a v1.x addition.

## Goal

When a user launches StickyDocs for the first time, walk them through:

1. A short explanation of how the app works.
2. Google sign-in.
3. Choosing which Drive folder will hold their stickies — either pick an existing folder, or create a new one (default name: `Stickies`).

After onboarding finishes the folder id is persisted to `app_state["stickies_folder_id"]` (the same key `FolderIdCache` already reads), and the app proceeds as today.

## Trigger

"First run" = `AuthService.shared.isSignedIn == false` **and** `app_state["stickies_folder_id"]` is unset. Showing the flow keyed on those two conditions (rather than a separate `did_onboard` flag) means `resetAllLocalData()` automatically re-triggers onboarding without extra wiring — the existing reset path already clears both.

## Proposed flow

A single window-modal SwiftUI sheet with three steps. Driven by an `@StateObject OnboardingModel` with a `Step` enum (`.intro`, `.signIn`, `.chooseFolder`, `.done`).

### Step 1 — Intro

- Title: "Welcome to StickyDocs".
- ~3 bullet points lifted from PRD: stickies on your desktop, each one is a Google Doc in your Drive, edits sync on blur / close / Sync Now.
- One primary button: "Continue".

No promises about offline behavior, no marketing copy. Keep it to what's actually true for v1.

### Step 2 — Sign in

- One button: "Sign in with Google" → `AuthService.shared.signIn()`.
- While the OAuth sheet is up, disable the button and show a spinner.
- On success, advance to step 3. On failure, show the error inline with a Retry button.
- "Skip for now" link → dismisses onboarding entirely; app opens in signed-out state, user can sign in later from the menu bar. Signed-out is a supported mode (engine tolerates it: `pullAllFromDrive` no-ops, pushes hold), so this is a first-class path, not just an escape hatch.

### Step 3 — Choose folder

Two radio options:

- **Create a new folder** (default selected). A text field pre-filled with `Stickies`. Validation: non-empty after trim, no slashes, ≤ 100 chars.
- **Use an existing folder**. Opens the Google Picker (see "Folder picker" below) to choose a Drive folder. Once picked, show its name + a "Change…" link.

Primary button "Finish":

- *Create*: call `GoogleDriveClient.findOrCreateFolder(named: <name>)`. Today this only matches by name globally, which is a bug for this flow — see "Behavior changes required" below.
- *Existing*: write the picked folder id straight into `app_state`.

On success the sheet closes, the menu bar app is fully usable, and `AppController` does its normal launch sync (`pullAllFromDrive` — vacuous on first run since there's nothing locally).

## Behavior changes required

1. **Folder picker for existing folders.** The OAuth scope is `drive.file` (`AuthService.swift:35`), which only lets the app see files *it* created. It cannot enumerate the user's existing Drive folders via `files.list`. Two options:
   - **Google Picker API** (recommended). Hosts a Drive folder picker in a `WKWebView`. Files chosen through Picker are granted to the app under `drive.file` scope automatically, so we keep our minimal scope.
   - **Broaden scope to `drive.readonly` or `drive`**. Simpler to implement, but a much bigger consent prompt and a real privacy regression. Not worth it.
2. **`FolderIdCache` bypasses `findOrCreateFolder` when an id is already cached** (`AppController.swift:199`), which is correct — onboarding just needs to populate that cache before first push. No change needed there.
3. **Custom folder names.** Today `FolderIdCache.folderName` is hardcoded `"Stickies"`. Either:
   - Store the chosen name in `app_state["stickies_folder_name"]` and have `FolderIdCache` read it, **or**
   - Skip `findOrCreateFolder` entirely once onboarding has set `stickies_folder_id` (the cache returns early anyway). The folder name then only matters at creation time.

   Second option is less code and avoids a stale-name footgun if the user renames the folder in Drive later.
4. **`findOrCreateFolder` name collision.** It matches the first folder of that name anywhere in the user's Drive. If the user already has a `Stickies/` folder for something else, we'd silently adopt it. Worth surfacing during the "create new" path: after creation, if the lookup returned an existing folder we didn't create, ask the user to confirm or rename. Low priority but should be tracked.
5. **Menu bar gate.** Until onboarding completes, "New Sticky" should be disabled (or trigger the onboarding sheet again). Otherwise a user who dismisses the window can still create stickies that pile up locally with `syncStatus = unprovisioned`.

## Signed-out path

Since signed-out is a supported mode, "Skip for now" on step 2 must short-circuit the rest of onboarding cleanly:

- Skip step 3 entirely — there's no Drive access to pick or create a folder.
- Mark onboarding complete (so it doesn't re-prompt every launch) but leave `stickies_folder_id` unset.
- When the user later signs in (via menu bar), run **step 3 as a deferred prompt** before the first push — either auto-create `Stickies/` silently, or show a one-step folder-choice sheet. Recommend the sheet: it keeps the "pick existing vs create new" affordance the user asked for, just deferred.
- Track completion with `app_state["onboarding_complete"] = "1"` rather than inferring from `isSignedIn + stickies_folder_id`, since both can legitimately be empty post-skip. This is the one place the simple inference rule breaks down.

## Open questions for review

- Should the intro step be skippable on subsequent re-runs (e.g. after `resetAllLocalData`)? Probably yes — if the user has reset they already know what the app does.

## Alternatives considered

- **No onboarding, infer everything lazily.** That's what we have today: first push triggers folder creation, sign-in is implicit when the user clicks "Sign in" in the debug pane. Problem: there is no real sign-in entry point in the *shipping* UI — only in `ContentView` which is the debug harness. A first-time user opening the menu bar has no obvious starting point. Onboarding fixes that.
- **Onboarding inside the menu bar popover.** Cramped, and the OAuth sheet doesn't anchor well to a menu bar popover that dismisses on focus loss. A dedicated window is cleaner.
- **Defer the folder choice — always create `Stickies/`, let the user move it later.** Simplest. But the user request explicitly asks for the picker, and "move folder in Drive" interacts awkwardly with our `findOrCreateFolder` cache (we cache the id, not the path, so a move is fine — but a user who *deletes* `Stickies/` and recreates one expects us to follow, which we don't). If we ship without the picker, document that limitation prominently.
- **Single-step onboarding (sign in + auto-create `Stickies/`).** Fewer clicks; loses the "pick existing" affordance. Reasonable v1.0 if Google Picker integration slips.

## Recommendation

Ship the three-step flow above, but gate "pick existing folder" on Google Picker integration landing first. If Picker is more work than expected, ship steps 1 + 2 + a name-only step 3 (create-new only) and add "pick existing" in a follow-up. That way the onboarding UI lands without being blocked on a sizeable Drive-API detour.

## Test plan additions (TESTPLAN.md)

- Fresh install → onboarding appears → walk through create-new → `Stickies` folder visible in Drive, first sticky pushes into it.
- Fresh install → onboarding → "Skip for now" → app usable signed-out, sign in later from menu bar → folder created on first push.
- Fresh install → existing folder named `Stickies` already in Drive → "create new" adopts it (or prompts, depending on collision policy).
- After `Reset All Local Data` → onboarding re-triggers.
- Pick existing folder via Picker → first sticky lands in chosen folder, not in `Stickies/`.
