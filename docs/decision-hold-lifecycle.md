# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For a live origin, it requires one exact `endpoint_task_id=` dispatch binding, obtains a fresh Bearings projection, and writes one atomic cleanup receipt per unresolved hold under `data/decision-hold-receipts/`.
The receipt records the origin, dispatch, hold, live backlog path, canonical object digest, and the digest of the Bearings snapshot observed by `complete`.
The stored Bearings digest is evidence of that completion-time snapshot; `verify` does not compare it with the fresh snapshot digest.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
An unresolved hold permits cleanup only while its receipt is intact, its task and dispatch links match, its nonzero object digest still identifies the unique backlog row, and a fresh Bearings snapshot still shows it.
The captain does not need to answer in the cleanup session because the unresolved hold remains the durable Captain's Call object after source cleanup.
Absent, duplicate, malformed, wrong-dispatch, zero-digest, missing-path, or Bearings-invisible evidence refuses without touching teardown's unlanded-work gates.
Receipt remediation never authorizes force or discard, and neither is a migration path for missing historical authority.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
It also retains the exact decision in a canonical non-symlink object and publishes a separate atomic resolution receipt bound to the originating task, original dispatch, unique live-or-archived row, decision digest, decision path, routed task identities, and row digest.
`verify-resolution` requires every routed task to remain a unique live-or-archived object.
An all-zero digest, missing object, changed dispatch, hand-written row, or historical row without the script-owned receipts fails closed.
Historical rows are not migrated implicitly because their producing dispatch and decision object cannot be reconstructed authoritatively from row prose alone.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Historical fail-closed remedy

The normative operator procedure is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md`.
Mechanically, an unresolved historical hold can reconstruct a missing cleanup receipt only by repeating `complete` with the full recorded inventory while the live origin still has one exact `endpoint_task_id=` and the hold remains open.
An origin with no exact dispatch binding remains intact and refused because the script cannot reconstruct that historical association from row prose.
A historical resolved row with no script-owned cleanup receipt or canonical decision object also remains intact and refused because no safe automatic migration is shipped.
When the cleanup receipt and canonical decision object both survive, an exact `resolve` retry may finish only the missing resolution receipt.
Every other historical case preserves the origin metadata and hold row for a later authority-bearing decision; cleanup does not proceed, and force or discard is not an operator remedy under this contract.

## Receipt trust boundary and held residuals

The receipt gate is same-account tamper evidence, not an operating-system authority boundary.
The following residuals are disclosed and remain `HELD`; this change neither accepts them nor designs them away.

- **R1 - same-account forgery:** an actor able to write both the backlog and receipt directory can recompute row digests and fabricate mutually consistent local files.
- **R2 - completion-time Bearings digest:** `bearings_sha256` records the snapshot used by `complete`, but `verify` checks only that a fresh Bearings projection still names the hold and does not compare the fresh digest with the stored value.
- **R3 - check-to-execution race:** `verify` checks the durable row digest before requesting fresh Bearings, so a concurrent same-account writer can change or remove the row between the check and later cleanup.

The R3 window is a time-of-check-to-time-of-use residual in the shipped receipt surface.
The independent CM31 gate demonstrated it deterministically by removing the hold during a delayed Bearings call and observing teardown proceed without the hold remaining.
That evidence does not authorize operating-system hardening, profile changes, permission changes, or acceptance of the residual.
`docs/codex-hook-threat-model.md` describes the related same-account and check-to-execution threat class for the separate Codex hook surface; it remains architecture only.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Dispatch-bound cleanup and trusted-resolution receipt verification date: 2026-07-31.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - historical open and binding-less refusals name only safe operator remedies
ok - absent, malformed, duplicate, wrong-origin, hand-written, and zero-digest resolution rows refuse

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```
