# Codex hook operating-system hardening verification

Audience: maintainer verification.

This record owns the active empirical evidence and residual verdicts for Firstmate's Codex hook anchor and payload boundary.
The current mechanism is owned by [`architecture.md`](../architecture.md#codex-hook-payload-boundary).
Task chronology and delivery evidence remain in the private task report.

## Measured platform

The implementation and every macOS mechanism below were measured on this machine on 2026-07-31.

```sh
$ sw_vers -productVersion
26.5.1
$ command -v sandbox-exec
/usr/bin/sandbox-exec
$ man sandbox-exec | col -b | sed -n '1,18p'
SANDBOX-EXEC(1)         General Commands Manual        SANDBOX-EXEC(1)

NAME
     sandbox-exec - execute within a sandbox (DEPRECATED)
```

The deprecated interface is therefore usable on the measured machine, but it is not a durable replacement for a privilege-separated anchor.

## Deterministic evidence command

The complete RED and GREEN evidence command is:

```sh
tests/fm-codex-hook-integrity.test.sh
```

Observed output:

```text
evidence before: status=0 worktree_payload=EXECUTED modeled_trust_file_unchanged=yes
evidence after-unanchored: status=2 worktree_payload=REFUSED refusal=firstmate Codex hook refused: staged payload hash mismatch: bin/fm-turnend-guard.sh: FAILED
evidence after-anchored: status=2 worktree_payload=REFUSED trusted_stop_guard=ACTIVE
evidence trust model: file_sha256=adac0482b6132259e35ade2d2c6be3b2cc8c50a4e7d429626521089a244bfe29 unchanged=yes
ok - Codex trusted-hook bypass executes before the fix and is refused after the fix
evidence prepared targets: SessionStart=EXECUTED watcher_PreToolUse=DENIED cd_PreToolUse=DENIED Stop=ACTIVE
ok - all four Codex declarations execute their prepared manifest-declared targets
evidence login RED: /bin/bash -lc sourced controlled .bash_profile=yes
evidence login GREEN: fixed hook sourced controlled .bash_profile=no
ok - Codex hooks enter bash without login or rc profile loading
evidence symlink: manifest_entry=bin/fm-spawn.sh same_bytes=yes result=REFUSED status=2
ok - Codex hook staging rejects a symlinked manifest entry even when its target bytes match
evidence user flags: chmod_write=1 chmod_same_owner_reversal=0 uchg_write=1 uchg_same_owner_reversal=0 schg_set=1
ok - owner mode bits and user flags are reversible by the same account; system immutable needs privilege
evidence sandbox: protected_write=DENIED stage_write=DENIED container_rename=DENIED unrelated_write=ALLOWED nested_escape=DENIED reversal_after_exit=VERIFIED
ok - macOS process sandbox protects only the Codex hook anchor and staged payload surface
evidence race RED: verified_path_then_executed_same_path=RACED_PAYLOAD_EXECUTED
evidence race GREEN: source_mutated_after_stage=yes executed_verified_stage=yes raced_source_executed=no reversal_chmod=VERIFIED
ok - Codex hooks execute the verified staged copy instead of the checked source path
NOT_VERIFIABLE: live Codex trust-dialog re-prompt count; this offline test models config.toml and never invokes Codex.
ok - Codex hook integrity and operating-system hardening regressions passed
```

The test creates every protected path and modeled trust file under its self-cleaning temporary root.
It does not read or write the real Codex trust store, the primary Firstmate checkout, the account login profile, or another lane's worktree.

## Residual verdicts

| Item | Verdict | Measured result |
| --- | --- | --- |
| 1. Same-account filesystem writability of the tracked code root | PARTIALLY CLOSED | The command above proves a Firstmate-launched Codex process cannot write the exact source anchor, manifest-declared payload, or prepared stage and cannot replace their container directories, while an unrelated file in the same tracked root and the whole root from an unsandboxed same-account process remain writable. |
| 2. Account owner or same-account malware can mutate an anchor | NOT CLOSED WITHOUT PRIVILEGE | The command above proves `chmod a-w` and `chflags uchg` both block an ordinary write but are reversed by the same owner with exit 0, while unprivileged `chflags schg` fails and no same-owner flag supplies an account-level boundary. |
| 3. Login profile runs before inline verification | CLOSED | The command above proves `/bin/bash -lc` sourced a controlled `.bash_profile`, while every fixed Codex declaration enters `/bin/bash --noprofile --norc` without sourcing it. |
| 4. Check-to-execution race in a writable unanchored tree | CLOSED | The command above deterministically observes a swapped path after the legacy digest check, then mutates the source after staging and observes only the verified staged guard without claiming protection against item 2's external same-account attacker. |

Item 1 is only partial because the operating-system denial is inherited by the launched Codex process tree, not by every process owned by the account.
The sandbox profile protects only the source-root identity, the `bin/` and `.codex/` container identities, `.codex/hooks.json`, `.codex/hook-payload.sha256`, each manifest-declared file, and the prepared stage.
The same command proves an unrelated file in the source root remains writable, so ordinary captain material is not blanket-protected.

## Reversal contract

The process sandbox has no persistent filesystem state.
Its exact reversal is termination of the sandboxed Codex child, exercised when the test child exits and the immediately following unsandboxed directory rename succeeds.

The prepared stage is made read-only before launch.
`bin/fm-codex-hook-launch.sh` actually runs this reversal before deleting that exact private stage:

```sh
chmod -R u+w "$STAGE"
find "$STAGE" -depth -delete
```

The manual-launch fallback additionally applies the user-immutable flag to its private stage.
`bin/fm-codex-hook-run.sh` actually runs this complete reversal on every exit path:

```sh
chflags -R nouchg "$STAGE_RUN_ROOT"
chmod -R u+w "$STAGE_RUN_ROOT"
find "$STAGE_RUN_ROOT" -depth -delete
```

The evidence command fails if either launcher leaves a stage behind or if the prepared-stage mode reversal cannot be demonstrated.

## Privileged plan for item 2

Closing item 2 requires a different security principal or a root-owned anchor, so it is not implemented under this unprivileged order.
A future captain-approved privileged change should use this sequence:

1. Create a dedicated versioned payload directory outside the account-owned repository, such as `/Library/Application Support/Firstmate/hook-payload/<manifest-sha256>/`.
2. Copy only `.codex/hook-payload.sha256` and its declared closure into the new directory through an audited administrator-owned installer.
3. Set every directory to `root:wheel` mode `0555`, every data file to `root:wheel` mode `0444`, and each executable to `root:wheel` mode `0555`.
4. Bind `FM_CODEX_HOOK_ROOT` to that exact version and remove the writable-tree fallback for Firstmate-launched sessions.
5. Update by creating a new versioned directory, verifying it before switching the binding, and retaining the prior version for rollback.
6. Reverse by switching the binding back to the prior version, stopping affected Codex processes, and then removing only the exact superseded version through the same administrator-owned installer.

That plan needs administrator authority and a separate review of installer ownership, atomic switch mechanics, rollback, and the security implications of the deprecated `sandbox-exec` layer.
It must not be approximated with owner-removable mode bits, ACLs, or `uchg`.
