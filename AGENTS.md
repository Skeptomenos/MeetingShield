# Meeting Shield

Native macOS menu bar app that prevents missed meetings with full-screen Google Calendar alerts, safe snooze/dismiss, and correct browser/profile launch.

## Stack

- Swift 6, SwiftUI, AppKit, macOS.
- Google Calendar API with read-only calendar access.
- Keychain for OAuth tokens; local-only preferences/cache.

## Source Of Truth

- Product behavior: `_planning/product-brief.md`
- Detailed spec: `_planning/product-spec.md`
- Implementation plan: `_planning/plans/2026-05-22-build-meeting-shield-mvp.md`
- App catalog metadata: `../index.md`

## Engineering Law

- Quality and verification: `docs/QUALITY.md`
- Planning and handoff discipline: `docs/PLANNING.md`
- Swift/macOS technical constraints: `docs/TECH.md`

## Commands

- Validation gate (required before claiming any work done): `script/validate.sh` — build, tests, smoke on the assembled .app, drift checks. Never substitute a subset.
- Fast iteration: `swift build` and `swift test`.
- Build, install, and run the dev app bundle: `script/build_and_run.sh` (assembly shared via `script/assemble_app.sh`).

## Product Constraints

- Reliability beats visual novelty; missed-meeting prevention is the primary goal.
- Keep calendar access least-privilege and explainable.
- Prefer native macOS surfaces for menu bar, alerts, permissions, notifications, launch-at-login, and settings.
- Design for ADHD and time blindness: safe defaults, obvious actions, low configuration burden.
