# Planning Discipline

## Before Coding

For non-trivial work, read:

1. `_planning/product-brief.md`
2. `_planning/product-spec.md`
3. `_planning/plans/2026-05-22-build-meeting-shield-mvp.md`
4. `docs/TECH.md`
5. `docs/QUALITY.md`

Then state the smallest plan that can complete the requested change.

## Plan Shape

Keep plans concise and concrete:

- Goal.
- Files likely to change.
- Validation commands/manual checks.
- Known unknowns.

Do not write a broad architecture essay when a three-step plan is enough.

## Living Plan Rules

Use `_planning/plans/2026-05-22-build-meeting-shield-mvp.md` for implementation work that touches multiple subsystems or spans sessions.

Update the plan when:

- A step is completed.
- A blocker is found.
- A non-obvious decision is made.
- Validation proves or disproves an assumption.
- Work stops mid-stream and another agent may continue.

Keep entries evidence-first. Paste command names and observed outcomes, not vibes.

## Branching

This project may be in a detached worktree. Before coding that will be committed or published:

- Follow the repo git workflow.
- Create or switch to a scoped branch.
- Update the implementation plan `Branch` field.

Do not mix unrelated cleanup with product implementation.

## Known Unknowns

Surface unresolved questions instead of guessing silently. Current expected implementation unknowns:

- The reliable profile discovery/launch mechanism for Chrome, Arc, and Chromium variants.
- Whether the primary build entrypoint should remain SwiftPM-first, Xcode-first, or both.
- Whether display mirroring should automatically enter Presentation mode after testing.
- Google OAuth client distribution path if the app becomes public.

Resolve these with local experiments, official docs, or small spikes before committing large dependent code.

## Stopping Rule

If a change cannot be verified, stop with:

- What changed.
- What was verified.
- What was not verified.
- Exact next action.

Do not hand off uncertain behavior as complete.
