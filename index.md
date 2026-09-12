# Meeting Shield index

Reconciled: 2026-09-12. GitHub PRs and Linear were checked for the workstreams below. Both are in review and their implementation branches remain unmerged; this index does not claim their behavior is present on main.

## Continue work

| Workstream | Plan and checkout | Tracking |
| --- | --- | --- |
| Core reliability | `_planning/plans/2026-08-31-close-capability-and-reliability-gaps.md` on `apps/meeting-shield/DEV-151-core-reliability` | DEV-151; [PR #242](https://github.com/Skeptomenos/ai-dev/pull/242) |
| Native redesign | `_planning/plans/2026-09-07-native-redesign.md` on `apps/meeting-shield/DEV-172-native-redesign` | DEV-172; [PR #247](https://github.com/Skeptomenos/ai-dev/pull/247), stacked on #242 |

Locate these checkouts with `git worktree list`; the plans are absent from main until their branches are integrated. For work on either stream, read its plan in that checkout and follow its evidence links. Keep scope, decisions, open acceptance and next actions in that plan; findings and run records belong in its linked dated `_planning/` evidence files. Confirm current branch and tracker state before continuing. For a distinct workstream that needs a durable plan, use `_planning/plans/` and add its pointer here.

Private `_planning/` content is stripped from public splits. Obtain the applicable private plan before continuing its acceptance work; older plans do not substitute for it.

## Read by task

| Task | Source |
| --- | --- |
| Understand the product and setup | [README](README.md) |
| Change intended product behavior | [Product brief](_planning/product-brief.md), relevant [specification](_planning/product-spec.md) sections |
| Change architecture or macOS integration | Relevant sections of [technical constraints](docs/TECH.md) |
| Select behavioral verification | [Quality matrix and failure/privacy requirements](docs/QUALITY.md) |
| Run validation or build the app | [Project commands](AGENTS.md#commands) |
| Inspect catalog metadata | [App catalog](../index.md) |
| Investigate the original MVP | [MVP plan](_planning/plans/2026-05-22-build-meeting-shield-mvp.md) |
| Investigate the June review and its findings | [Review register](_planning/plans/2026-06-11-fix-review-findings-and-modularize.md) |
