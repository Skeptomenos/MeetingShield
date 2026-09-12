# Meeting Shield

Meeting Shield is a native macOS app that connects to Google Calendar and shows high-visibility, full-screen alerts before meetings start. It is designed for people who miss regular notifications because they are hyper-focused, switching context, or dealing with time blindness.

## Product Direction

The app should run quietly from the menu bar, watch upcoming Google Calendar events, detect video meeting links, and interrupt the screen when a meeting is close. The alert should make the next action obvious: join, snooze, or dismiss.

This is inspired by "In Your Face", but should evolve as its own app with native macOS polish, privacy-conscious calendar access, and a calmer workflow for ADHD-heavy workdays.

## Initial Scope

- Google Calendar OAuth sign-in.
- Read upcoming calendar events from one or more selected calendars.
- Detect meeting URLs for Google Meet, Zoom, Microsoft Teams, Webex, and common conferencing links.
- Show a menu bar countdown to the next meeting.
- Trigger a full-screen alert a configurable number of minutes before the meeting.
- Provide one-click join, snooze, and dismiss actions.
- Store preferences locally.
- Launch at login.

## Early Technical Shape

- **App:** Swift 6 native macOS app.
- **UI:** SwiftUI for settings and alert content; AppKit where needed for menu bar and full-screen window control.
- **Calendar:** Google Calendar API with OAuth.
- **Storage:** Keychain for tokens; app preferences for calendar selections, timing, snooze defaults, and disabled events.
- **Scheduling:** A local event watcher that refreshes calendar data, maintains the next alert time, and survives sleep/wake transitions.

## Key Design Questions

- How aggressive should the full-screen takeover be across multiple displays and Spaces?
- Which Google Calendar OAuth scopes are sufficient for read-only event detection?
- Should snooze operate per event, globally, or both?
- How should all-day events, declined meetings, tentative meetings, focus time, and duplicate calendar entries be filtered?
- What is the safest path for shipping OAuth credentials if this becomes a public split app?

## Suggested First Milestone

Build a small native prototype that:

1. Runs in the menu bar.
2. Uses mock calendar events.
3. Shows a full-screen alert with join, snooze, and dismiss.
4. Extracts meeting links from sample event descriptions and locations.
5. Stores alert timing preferences.

After that works, wire in Google Calendar OAuth and real event polling.

## Current MVP

Historical readiness check, 2026-09-07: all 18 core reliability steps and 46 installed-app acceptance cases passed independent verification on September 4. The later legacy-token catalog correction passes the complete 507-test gate and CI. Its fresh signed installation, relaunch refreshes, and visible Protection read-back pass; [focused installed evidence](_planning/2026-09-07-installed-healthcheck.md) records the exact artifact, preservation checks, and limits.

Current review correction, 2026-09-12: notification latency must not delay acquisition or revive scheduling after Stop. See [focused repair evidence](_planning/2026-09-12-stale-preflight-repair.md) for current validation and the boundary between synthetic lifecycle proof and historical installed-app evidence. The September 7 artifact is not evidence for later code changes.

See the [repair and acceptance plan](_planning/plans/2026-08-31-close-capability-and-reliability-gaps.md) for the core proof and delivery status. Broader customization, extended dogfood, and full-spec sign-off remain in DEV-153 through DEV-161.

The app now has a SwiftPM-first native macOS implementation:

- Menu bar app shell with cached agenda, next-meeting title/countdown, Presentation mode toggle, settings, Google reconnect, and new-event action.
- Full-screen AppKit alert windows on every connected display, with SwiftUI Join/Open, Snooze, overlap controls, keyboard shortcuts, stale-cache warning, and long-press dismiss.
- Slim fallback alert after Join/Open with Open Again, Dismiss, and browser/profile fallback warnings.
- Deterministic link extraction for Google Meet, Zoom, Teams, Webex, and common conferencing links.
- Default eligibility filters from the product spec, plus top-to-bottom AND-only rules.
- Per-occurrence snooze/dismiss state with material-change fingerprints.
- One next-action reminder scheduler, wake/unlock grace behavior, Presentation-mode notifications, local 24-hour cache, and stale-cache status.
- Browser/profile resolution for System Default, Safari, Chrome, Arc, and Chromium-family profiles where local profile directories are discoverable.
- Google OAuth and Google Calendar REST client using desktop loopback + PKCE, narrow read-only scopes, Keychain token storage, calendar-list/event fetch, and normalized event mapping.
- Launch-at-login preference backed by macOS ServiceManagement when running as an app bundle.

Google OAuth requires a Google Desktop OAuth client. Installed private dogfood builds can include the client ID and desktop client secret in `Info.plist`; local development builds can provide them through `MEETING_SHIELD_GOOGLE_CLIENT_ID` / `MEETING_SHIELD_GOOGLE_CLIENT_SECRET` or `.local/google-oauth-client-id` / `.local/google-oauth-client-secret`. The app computes the loopback redirect URI during each connection attempt, so users do not type a redirect URI.

## Google Cloud Test App Setup

Use this for private dogfooding and live MVP validation:

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create or select a project.
2. Enable the Google Calendar API for that project.
3. Configure the OAuth consent screen in Testing mode and add the dogfood Google account as a test user.
4. Create an OAuth client with application type `Desktop app`.
5. Copy the desktop client ID and client secret into local-only configuration. Do not commit client secrets, access tokens, refresh tokens, exported API responses, attendee lists, or private meeting links.
6. For local app bundles, set `MEETING_SHIELD_GOOGLE_CLIENT_ID` and `MEETING_SHIELD_GOOGLE_CLIENT_SECRET` before running `./script/build_and_run.sh`, or put them in `.local/google-oauth-client-id` and `.local/google-oauth-client-secret`.
7. Launch the app, open Settings, and connect Google Calendar.

The connection flow follows [Google's installed desktop guidance](https://developers.google.com/identity/protocols/oauth2/native-app): open the system browser, listen briefly on `127.0.0.1` using a random available port, include a PKCE challenge, receive the authorization code on the local loopback callback, then exchange it for tokens.

## Build, Run, Test

```bash
./script/validate.sh
swift test
swift build
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

`./script/build_and_run.sh` stages the SwiftPM executable into `dist/MeetingShield.app` (via `./script/assemble_app.sh`) and launches that bundle. The Codex Run action is wired to the same script through `.codex/environments/environment.toml`.

There is no Xcode project in this MVP. Use SwiftPM commands unless an Xcode project is added later for signing, assets, notarization, or distribution packaging.

### Native runtime regression

The full gate builds, tests, assembles the app, runs entrypoint smoke, exercises five native Join/fallback scenarios, and checks drift. Tests and smoke use fresh isolated homes so default local stores do not change app data in the user's home. The native stage needs an interactive Mac with WindowServer and valid bundle identity. It shows synthetic windows for about 80 seconds, uses fresh isolated app homes, and records browser requests without opening them. It does not connect accounts, request notification permission, or replace the installed app.

To check an already assembled bundle, choose an output directory that does not exist:

```bash
./script/assert_runtime_fallback.sh --app-bundle dist/MeetingShield.app --output-dir .build/runtime-manual-001 --scenario all
```

Use the wrapper, not the internal app argument. It owns the child PID, validates binary identity, sets the isolated home, enforces deadlines, and retains evidence. Timeout, explicit close, reopen, dismiss and overlap cases must complete the real window/timer lifecycle and show a later native alert before exiting normally. Process loss, missing checkpoints and unavailable prerequisites fail the gate. Exit 78 means blocked environment or identity evidence, not a pass.

For native lifetime diagnosis, use `--scenario timeout --zombies` and a fresh output directory. Even a successful instrumented run exits 3 and is diagnostic-only; repeat normally for acceptance. Retained output uses synthetic data. These checks do not replace rendered-button, browser, account, wake or installed-app acceptance.

## Code Signing

Ad-hoc signatures change on every build, which resets Keychain ACLs (the stored OAuth tokens become unreadable) and notification permission on each reinstall. Create a stable self-signed identity once:

1. Keychain Access > Certificate Assistant > Create a Certificate...
2. Name: `MeetingShield Dev`, Identity Type: Self-Signed Root, Certificate Type: Code Signing.
3. Rebuild. `script/assemble_app.sh` picks the certificate up automatically (or set `MEETING_SHIELD_CODESIGN_IDENTITY` to use a different identity).

Without it, builds fall back to ad-hoc signing with a warning.

## Privacy Summary

- Google scopes are `calendar.events.readonly` and `calendar.calendarlist.readonly`, matching the narrow Calendar API read-only permissions needed for events and calendar-list selection.
- OAuth tokens are stored in Keychain.
- Event cache is local and strips descriptions after link extraction.
- Normal app code should not log tokens, meeting titles, descriptions, attendees, meeting links, or raw Google API bodies.
- Reminder state is scoped to its account and calendar. After an upgrade, old actions whose source cannot be proven may alert again; the app retains those old records for eight days without suppressing another meeting. Settings, cache format and raw Google event IDs remain unchanged.
- Newly emitted diagnostic records accept only known events, fields and bounded operational values. Unknown text is omitted or replaced by a fixed code before the same JSON payload goes to Unified Logging and local JSONL. Existing log history is not retroactively scrubbed and may contain earlier unsafe output. Audited direct Unified Logging calls use fixed text, counts or safe error/identifier helpers; new calls still require privacy review.
- Local diagnostics retain `diagnostics.jsonl` and `diagnostics.previous.jsonl`, each at most 256 KiB, with a 2 KiB limit per encoded record including its newline. Rotation happens before the next record would exceed the limit. These bounds cover app-controlled regular files after a successful write. Unsafe filesystem entries are preserved and further writes stop with a safe native error. Oversized old diagnostic files are discarded or replaced; settings, tokens, cache and reminder state are not affected. No cloud telemetry is added.
