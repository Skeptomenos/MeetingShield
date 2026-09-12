# Meeting Shield

Native macOS menu bar app that prevents missed meetings with full-screen Google Calendar alerts, safe snooze/dismiss, and correct browser/profile launch.

Ownership-ID: Personal

## Stack

- Swift 6, SwiftUI, AppKit, macOS.
- Google Calendar API with read-only calendar access.
- Keychain for OAuth tokens; local-only preferences/cache.

Read [index.md](index.md) at session start for the applicable plan, findings, and task-specific documentation.

## Commands

- Before implementation closeout after code, build, dependency, or test changes, run `script/validate.sh` in full — build, tests, assembled-app smoke, and drift checks. Use focused checks during development; reuse evidence while its inputs remain unchanged.
- For documentation-only changes, verify affected links and documented commands, then run `git diff --check`. Documentation or status updates alone do not require an app rebuild.
- For changed product behavior, follow the applicable verification row in `docs/QUALITY.md` — the automated gate does not establish live macOS behavior.
- Fast iteration: `swift build` and `swift test`.
- Build, install, and run the dev app bundle: `script/build_and_run.sh` (assembly shared via `script/assemble_app.sh`).

## Product Constraints

- Reliability beats visual novelty; missed-meeting prevention is the primary goal.
- Keep calendar access least-privilege and explainable.
- Prefer native macOS surfaces for menu bar, alerts, permissions, notifications, launch-at-login, and settings.
- Design for ADHD and time blindness: safe defaults, obvious actions, low configuration burden.
