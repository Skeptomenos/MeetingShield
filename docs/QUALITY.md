# Quality Discipline

## No Slop

Do not ship rushed, pattern-matched, or unverified work. Meeting Shield is a reliability product: a small false confidence can become a missed meeting.

Quality means:

- The implemented behavior matches `_planning/product-spec.md`.
- The exact changed path has been exercised.
- Failure modes are handled deliberately, especially sleep/wake, stale cache, notification permissions, browser/profile launch, snooze, dismiss, and auth expiry.
- Privacy-sensitive data is not logged or retained casually.

## Always Works Protocol

Before claiming completion, answer yes to all applicable checks:

1. Did I build or test the changed code?
2. Did I trigger the exact feature I changed?
3. Did I observe the expected result myself through tests, logs, UI, or a manual run?
4. Did I check for errors, warnings, crashes, permission prompts, and stale state?
5. Would I trust this during a real meeting start?

If any answer is no, say exactly what was not verified and why.

## Required Verification By Change Type

| Change | Required verification |
| --- | --- |
| Calendar logic | Unit tests for eligible/ineligible events and edge cases. |
| Snooze/dismiss | Tests proving per-occurrence state and no snooze past `start - 10s`. |
| Link extraction | Tests for Meet, Zoom, Teams, Webex, generic links, malformed links, and no-link events. |
| Browser/profile launch | Resolver tests plus manual launch check where the browser exists locally. |
| Full-screen alert UI | Manual run that shows alert windows on available displays. |
| Menu/settings UI | Manual interaction with the changed controls. |
| Cache/recovery | Tests or controlled manual run for stale/offline/auth-expired behavior. |
| Security/privacy | Inspect logs/storage paths for tokens, event titles, descriptions, attendees, and links. |

## Reality Checks

- Do not write "should work" unless you also state what remains unverified.
- Do not rely on reading code as proof of UI behavior.
- Do not mark browser/profile behavior done without testing the actual launch command or API.
- Do not mark sleep/wake behavior done without either a manual wake test or a small injectable clock/system-event test around the recovery logic.
- Do not suppress full-screen alerts from weak heuristics; missed real meetings are worse than extra visible alerts.

## Error Handling Standard

Meeting Shield should fail visibly and recoverably:

- Calendar refresh failure keeps using the 24-hour cache and marks stale state.
- Auth expiry prompts re-auth without full-screen takeover.
- Missing browser profile asks the user when non-urgent, or opens the default profile with a warning when urgent.
- Disabled notification permission warns because Presentation mode depends on macOS notifications.
- Linkless events still alert and use `Open Event`.

## Logging Standard

Default logs may include operational state such as refresh success/failure, scheduler decisions, and anonymized counts.

Default logs must not include:

- OAuth tokens.
- Meeting titles.
- Event descriptions.
- Attendee names/emails.
- Meeting links.
- Raw calendar response bodies.

Use redacted IDs or compact fingerprints when debugging reminder state.
