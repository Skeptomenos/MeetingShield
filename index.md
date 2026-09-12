# Meeting Shield index

Reconciled: 2026-09-12. GitHub PRs and Linear were checked for the workstreams below. Core reliability PR #242 merged at `77fcf7a3` and native redesign PR #247 merged at `e2ae2f1a` on September 12. Both are available on main. Code integration does not close broader installed-app acceptance or deferred work.

## Continue work

| Workstream | Plan and checkout | Tracking |
| --- | --- | --- |
| Core reliability | [Core plan](_planning/plans/2026-08-31-close-capability-and-reliability-gaps.md), available on main | DEV-151; [merged PR #242](https://github.com/Skeptomenos/ai-dev/pull/242) |
| Native redesign | [Redesign plan](_planning/plans/2026-09-07-native-redesign.md), available on main | DEV-172; [merged PR #247](https://github.com/Skeptomenos/ai-dev/pull/247), includes merged #242 |

Both plans are on main. Original worktrees remain available through `git worktree list`; verify their heads before reuse. For work on either stream, read its current plan and follow its evidence links. Keep scope, decisions, open acceptance and next actions in that plan; findings and run records belong in its linked dated `_planning/` evidence files. Confirm current branch and tracker state before continuing. For a distinct workstream that needs a durable plan, use `_planning/plans/` and add its pointer here.

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
| Inspect the latest controller lifecycle repair | [September 12 evidence and limits](_planning/2026-09-12-stale-preflight-repair.md) |
| Investigate the original MVP | [MVP plan](_planning/plans/2026-05-22-build-meeting-shield-mvp.md) |
| Investigate the June review and its findings | [Review register](_planning/plans/2026-06-11-fix-review-findings-and-modularize.md) |
