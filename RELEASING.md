# Releasing StickyDocs

Releases are cut by pushing a `v<version>` tag. CI
(`.github/workflows/release.yml`) does the rest: build, sign, notarize,
package, publish the GitHub Release, and add the Sparkle update to
`docs/appcast.xml`.

## Before you release

1. All unit tests pass (Xcode ⌘U, or see `CLAUDE.md` for the `xcodebuild`
   command).
2. The live round-trip test actually ran: it silently passes in a few
   milliseconds when it can't find credentials. Run the Debug build, sign in,
   click **Save creds for tests** in the "StickyDocs (Debug)" window, then run
   `RoundTripIntegrationTests`. It should take tens of seconds.
3. The `TESTPLAN.md` sections touched by this release have been run by hand.

## Cutting the release

From the repo root, on `main`, with a clean working tree:

```bash
scripts/release.sh 1.2.0-alpha.7     # or e.g. 1.2.0 for a stable release
git show v1.2.0-alpha.7              # review the tagged commit
git push origin main
git push origin v1.2.0-alpha.7       # this triggers the release workflow
```

`scripts/release.sh`:

- fetches `origin` and rebases `main` if it's behind (CI commits the appcast
  to `main` after every release, so local `main` is always one commit behind
  right after a release);
- refuses to run if the tag already exists, the tree is dirty, or you're not
  on `main`;
- sets `MARKETING_VERSION` in the Xcode project, commits that, and creates an
  annotated tag. Nothing is pushed.

Watch the run under the repo's **Actions** tab (`gh run watch`). Recent runs
took about 4–5 minutes.

## Versions and channels

| Tag | Sparkle channel | Who gets it |
| --- | --- | --- |
| `v1.2.0` | stable (no channel) | everyone |
| `v1.2.0-alpha.7` (anything with a `-`) | `alpha` | only users with **Receive Alpha Updates** on (menu bar) |

- `CFBundleShortVersionString` comes from the tag.
- `CFBundleVersion` (what Sparkle compares to decide "newer") is the GitHub
  Actions run number, so it always increases. Don't reuse or hand-edit it.

## What CI does

1. Writes `Secrets.swift` from repo secrets.
2. Archives and exports with Developer ID signing.
3. Notarizes and staples the app, packages a zip and a DMG, then notarizes
   the DMG.
4. Creates the GitHub Release with the zip, the versioned DMG, and a
   stable-named DMG, plus auto-generated release notes.
5. Signs the zip with the Sparkle EdDSA key and commits a new `<item>` to
   `docs/appcast.xml` on `main` ("Publish vX to appcast").

**After a release, `git pull` before doing anything else on `main`.**

## Required repo secrets

| Secret | Used for |
| --- | --- |
| `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` | `Secrets.swift` in the shipped build |
| `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` | Developer ID signing |
| `MACOS_PROVISIONING_PROFILE_BASE64` | provisioning profile embedded in the signed app (required when signing) |
| `AC_API_KEY_BASE64`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID` | App Store Connect API key for notarization |
| `SPARKLE_PRIVATE_KEY_BASE64` | signing the update for the appcast |

If the signing or notarization secrets are missing, the workflow still builds
and creates a GitHub Release, but **skips the appcast**, so no one is
offered the update.

## Troubleshooting

- **Wrong or broken tag, nothing published yet:** delete it with
  `git tag -d vX && git push origin :refs/tags/vX`, fix, and re-run
  `scripts/release.sh`.
- **Already in the appcast:** don't delete the entry. Ship a new version
  instead, because users may already have updated.
- **Manual run (`workflow_dispatch`):** builds a workflow artifact only. The
  GitHub Release and appcast steps run only for tag pushes.
- **Xcode can't write into `DerivedData/.../Debug/StickyDocs.app` after a
  release:** the Debug build updated itself through Sparkle, and macOS now
  protects the bundle. Quit the app and delete the project's DerivedData
  folder (Xcode → Settings → Locations).
