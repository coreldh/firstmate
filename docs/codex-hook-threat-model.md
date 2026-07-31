# Codex project-hook architecture and threat model

This maintainer architecture record defines the trust boundary for Firstmate's Codex project hooks.
It is a design document only.
It does not authorize or perform changes to login profiles, filesystem permissions, operating-system configuration, credentials, or other host security state.

## Current architecture

`.codex/hooks.json` declares four shell entry points: `SessionStart`, two Bash `PreToolUse` checks, and `Stop`.
Each declaration launches `bash -lc`, reads the hook payload, resolves the current physical working directory, checks for the expected Firstmate files, and executes a script below that directory.
The scripts then load or execute further dependencies, usually relative to their own `SCRIPT_DIR`.
At baseline `3772964`, the declaration checks presence and identity by path but does not cryptographically bind the executable bytes.

The protected assets are supervision integrity, command-policy integrity, hook availability, and an operator-visible refusal when integrity cannot be established.
The hook is not an operating-system privilege boundary because the worker and the hook normally run as the same user.
The primary threat is a mistaken or over-eager same-account worker changing executable selection or trusted bytes, with a hostile same-account process as the stronger bounding case.

## Trust boundaries and attack paths

### Login-shell profile vector

`bash -lc` creates a login shell before the inline declaration can validate the checkout.
Login startup files and system profile hooks can therefore influence environment variables, shell behavior, and command resolution before the project hook's first check.
A scratch-home construction in the prior independent gate demonstrated that a writable login profile can inject `FM_ROOT_OVERRIDE` and redirect `bin/fm-cd-pretool-check.sh` to an unverified policy executable.
The construction did not touch the captain's real profile and does not prove that the real fleet is currently compromised.

The design implication is that an inline project declaration cannot authenticate its own execution environment.
Sanitizing selected variables inside the declaration reduces known paths but cannot make a login profile part of the verified project closure.

### Writable anchor

A manifest stored beside writable payloads detects a payload-only edit only while something outside that writable set pins the manifest digest.
Embedding the manifest digest in `.codex/hooks.json` makes Codex's separate trust decision on the declaration the load-bearing anchor.
If a same-account actor can change the payload, regenerate the manifest, and obtain or bypass trust for the changed declaration, the project-local chain no longer distinguishes authorized from unauthorized bytes.
Project-local hashes provide tamper evidence and maintenance drift detection, not immutability.

### Check-to-execution race

A shell sequence that hashes a pathname and later executes that pathname has a time-of-check-to-time-of-use window.
Another same-account writer can attempt to replace the verified file between those operations.
The prior gate did not win that race in twenty attempts, so exploitability in the fleet remains `NOT_VERIFIABLE`; the structural window still exists.
Symlink rejection and physical-root checks narrow replacement constructions but do not make a pathname-based check and execution atomic.

### Split-root dependency resolution

A verified entry point must resolve every executable and sourced dependency from the same verified root.
At baseline, `bin/fm-cd-pretool-check.sh` derives its policy path through `FM_ROOT_OVERRIDE`, while the other command-policy wrapper derives its policy from `SCRIPT_DIR`.
That second root lets an intact verified wrapper execute an unverified policy and must be eliminated in any payload-anchoring implementation.

## Target invariants

1. One external trust decision binds the hook declaration and the digest of the complete executable dependency closure.
2. Every dependency resolves beneath the same physical root whose bytes were verified.
3. Missing, duplicate, symlinked, non-regular, or digest-mismatched closure entries refuse before any project payload executes.
4. Positive tests prove both that the trusted guard executed and that the original hook payload reached it.
5. Integrity refusal is distinct from ordinary policy denial and from dependency unavailability.
6. Documentation never claims that project-local hashing removes the login-profile, writable-anchor, or check-to-execution residuals.

## Alternatives

| Alternative | Security effect | Operational impact | Reversibility and rollback | Required tests |
| --- | --- | --- | --- | --- |
| Project manifest pinned by Codex's declaration trust | Detects payload-only edits and closure drift; retains all three same-account residuals | Small declaration and test changes; declaration trust must be renewed when the closure changes | Revert `.codex/hooks.json`, the manifest, and the launcher changes together; then confirm the former trusted declaration is active | Payload swap, regenerated manifest, symlink and directory swap, root redirection, positive guard execution, payload forwarding, and live trust re-prompt |
| Non-login shell with a sanitized environment | Removes ordinary user login-profile execution and narrows environment injection | May change command lookup and portability; every required binary path must be explicit | Restore the prior command string; confirm all four hooks and supervision backstops still fire | Scratch-home profile injection, missing tool behavior, PATH replacement, and every supported Codex platform |
| Copy verified closure to a private per-session execution directory | Narrows mutation after verification when the directory is permission-protected and never reused | Adds session materialization, cleanup, and crash recovery | Disable materialization and fall back to the last trusted project declaration; retain the copy for diagnosis | Concurrent replacement stress, stale-copy refusal, crash recovery, and exact payload/exit-code parity |
| Descriptor-bound or compiled launcher outside the writable checkout | Can make verification and execution one operation and remove pathname substitution when its own binary is independently trusted | Highest maintenance and installation cost; platform-specific packaging | Keep the previous launcher installed until the new path passes live acceptance; rollback selects the prior declaration | Platform signing and update tests, descriptor execution tests, race stress, and live Codex trust acceptance |
| OS-managed immutable or separately owned hook directory | Removes same-account writable-anchor and payload-swap authority when ownership is genuinely separate | Requires explicit host administration and changes the fleet's installation model | Restore prior ownership and declaration only through an approved administrator rollback | Ownership/ACL verification, updater authorization, recovery access, and complete hook acceptance |

The least disruptive incremental design is the pinned project manifest, plus same-root dependency resolution and restored positive execution coverage.
It improves tamper evidence without pretending to remove the login-shell, writable-anchor, or race residuals.
Removing those residuals requires the non-login, descriptor-bound, or separately owned alternatives and a separate captain-approved host change.

## Migration, impact, and rollback plan

An implementation should first add red offline attack tests against the current declaration, then add the manifest and same-root resolution in one commit so no intermediate revision advertises an incomplete closure.
Landing changes the declaration bytes and can invalidate existing Codex trust records.
The operator must therefore plan an explicit trust re-acceptance and a post-acceptance supervision check rather than assuming the hooks remain enabled.

Rollback must revert the declaration, manifest, dependency-resolution change, and tests as one unit.
A rollback is complete only after `SessionStart`, both Bash checks, and `Stop` have executed their trusted positive controls and a real in-flight/no-watcher fixture still produces the blocking turn-end result.
Rollback never authorizes editing a login profile, weakening permissions, disabling a host control, or accepting an unverified declaration silently.

## Verification plan

Offline behavioral tests should cover these constructions under scratch roots and scratch `HOME` directories:

- swapped payload with the old digest;
- swapped payload plus a regenerated project manifest;
- payload symlink and symlinked `bin/` directory;
- redirected hook root and redirected nested policy root;
- login-profile injection of each root variable and a PATH shim;
- all four unmodified hooks as positive controls;
- distinctive trusted-guard execution and byte-for-byte payload forwarding;
- repeated concurrent replacement between check and execution, reported as stress evidence rather than proof of absence;
- manifest drift when any closure member changes;
- refusal before payload execution, with exit status and marker-file absence asserted.

A live Codex acceptance pass must separately verify the declaration trust prompt, the number of prompts, persisted activation, and turn-end supervision after restart.
Those live trust behaviors cannot be inferred from offline JSON or a modeled trust file.
Until they are observed on the installed Codex version, they remain `NOT_VERIFIABLE`.

## Current decision boundary

This architecture does not choose permanent acceptance of the same-account residuals.
It makes the incremental and hardened alternatives, their costs, and their rollback conditions explicit so the captain can commission a later implementation without conflating project tamper evidence with host isolation.
