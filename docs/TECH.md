# Technical Constraints

## Architecture

Build Meeting Shield as a native macOS app with clear boundaries:

- SwiftUI for menu, settings, alert content, and normal app surfaces.
- AppKit for menu bar integration where needed, full-screen/topmost windows, notifications bridge points, activation policy, and system-level macOS behavior.
- Calendar providers behind a protocol; Google Calendar is the first implementation.
- Link extraction, eligibility, rules, scheduling, cache, and browser/profile resolution are testable services with no UI dependencies.
- UI observes app state; business logic must not live inside SwiftUI view bodies.

Prefer small types with explicit responsibilities over central manager objects that own everything.

### Module layout

- `Sources/MeetingShieldApp.swift` — `@main` + `AppDelegate` only.
- `Sources/Controllers/MeetingShieldController.swift` — published state + UI callback glue; delegates logic to services.
- `Sources/Services/RefreshCoordinator.swift` — refresh state machine: auth gating, protective fetch window, cache fallback, failure counting, re-entrancy coalescing.
- `Sources/Services/ReminderPipeline.swift` — pure events → due-reminders pipeline + `ReminderPresentationDecision`.
- `Sources/Services/GoogleOAuth/` — OAuth models, PKCE, loopback server, token client, credentials resolver.
- `Sources/Services/GoogleCalendar/` — provider actor, REST mapper, API DTOs.
- `Sources/Services/` — remaining injectable services (eligibility, scheduler, launcher, profiles, cache, state store, notification health, sound policy, timers, system events).
- `Sources/Views/` and `Sources/Views/Settings/` — SwiftUI surfaces and window controllers.

### Validation gate

`script/validate.sh` is the single definition of done: build → tests → smoke (assembled `dist/MeetingShield.app` runs `--smoke-test`) → drift checks. Run it before claiming any change complete; never substitute a subset.

## Swift And Concurrency

- Treat Swift 6 concurrency warnings as correctness issues.
- Keep UI mutations on the main actor.
- Keep network, cache, link extraction, and scheduler work off the main actor unless the API requires otherwise.
- Inject clocks, providers, launchers, and stores into services that need deterministic tests.
- Avoid unstructured background tasks that cannot be cancelled or observed.
- Do not block the main thread with calendar refresh, JSON parsing, browser discovery, or cache IO.

## Scheduling

Meeting Shield must be CPU and memory efficient:

- Use one lightweight next-action timer where possible.
- Do not poll the UI.
- Refresh Google Calendar every 60 seconds while awake, plus wake/unlock, network return, and settings changes.
- Schedule from cached normalized events so temporary network loss does not break alerts.
- Recompute reminders after refresh, wake, auth changes, and settings changes.

Snooze must never hide a reminder later than 10 seconds before event start.

## Calendar And Privacy

- Request read-only Google Calendar scopes only.
- Store OAuth tokens in Keychain only.
- Store local event cache with only alert/link/eligibility fields.
- Keep a 24-hour offline-protection cache plus selected visible window, capped at 7 days.
- Do not retain full descriptions after link extraction unless a specific feature requires it.
- Do not log meeting titles, descriptions, attendees, links, raw API bodies, or tokens by default.

Default eligibility:

- Include timed Google Calendar `default` events.
- Include accepted, tentative, and not-yet-answered events.
- Include meetings with and without links.
- Exclude cancelled, declined, all-day, free/available, focus time, out of office, working location, birthday, and from-Gmail events.

## Browser And Profile Launch

Resolution order:

1. Rule override.
2. Calendar default browser/profile.
3. Global default browser/profile.
4. System Default without profile selection.

Support Safari as browser-only. Support Chrome, Arc, and Chromium-based profile launching only where local testing proves the mechanism reliable.

If a selected profile cannot be launched:

- Non-urgent: ask the user to choose a profile or use the default profile.
- Urgent: open the browser default profile and show a visible warning in the fallback alert.

Never silently fail or silently open the wrong profile without telling the user.

## Full-Screen Alert

The alert is a reliability mechanism, not decoration:

- Show on every connected display.
- Stay visible until Join/Open, Snooze, or confirmed Dismiss.
- Do not switch Spaces in MVP.
- Do not block macOS security or permission prompts.
- `Join` or `Open Event` is primary.
- `Snooze` is large and safe.
- `Dismiss this event` is small and requires slide/hold confirmation.
- `Enter` activates Join/Open.
- `S` snoozes.
- `Esc` never dismisses.

After Join/Open, show the slim fallback alert for about 10 seconds with `Open again` and `Dismiss this event`.

## Presentation And Wake Behavior

During Presentation mode, use macOS notifications instead of full-screen alerts.

Reliable triggers:

- Explicit menu toggle.
- Settings default.
- Current meeting/session override.
- Display mirroring only if locally verified as reliable.

Do not rely on Google Meet, Zoom, or Teams screen-share detection for MVP.

On wake/unlock:

- Refresh calendar immediately.
- Use macOS notifications only for 60 seconds.
- Resume normal full-screen alerts after the grace period.

## Test Strategy

Use unit tests for deterministic services:

- Link extraction.
- Event normalization.
- Eligibility.
- Rule evaluation.
- Scheduler timing and snooze clamp.
- Reminder state and material-change fingerprints.
- Browser/profile resolution.
- Cache retention.

Use manual/macOS verification for system surfaces:

- Full-screen windows across available displays.
- Menu bar behavior.
- Notification permission behavior.
- Browser/profile launch.
- Wake/unlock behavior.

The minimum automated check before completion is `swift test` once `Package.swift` exists. If an Xcode project exists, also run the documented `xcodebuild` command when app integration changed.
