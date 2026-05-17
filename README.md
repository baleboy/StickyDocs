# StickyDocs

A native macOS app that behaves like Apple's Stickies, but every sticky note is
backed by a real Google Doc. Jot something on the desktop, and it shows up in
Drive.

## Status

Early in development. Core sync, formatting, lazy Doc provisioning, and
trashed/deleted-Doc handling work end-to-end. See `PRD.md` for the locked v1
design and `TESTPLAN.md` for the manual test plan.

## Requirements

- macOS 14+
- Xcode 15+
- A Google Cloud OAuth client (Installed-app type) with the Drive and Docs APIs
  enabled. Drop the client ID/secret into a gitignored
  `StickyDocs/StickyDocs/Auth/Secrets.swift`.

## Building

Open `StickyDocs/StickyDocs.xcodeproj` in Xcode and run the `StickyDocs` scheme.

## License

MIT — see [LICENSE](LICENSE).
