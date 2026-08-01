#!/usr/bin/env bash
# Offline regression for the Codex project-hook trust gap.
#
# The trust state is modeled in this temporary fixture because the test must not
# read or write the operator's real ~/.codex/config.toml.
# The real Codex UI re-prompt behavior is therefore explicitly NOT_VERIFIABLE
# here; this test proves the executable selection and payload-integrity boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-integrity)
TRUSTED_ROOT="$TMP_ROOT/trusted"
WORKTREE_ROOT="$TMP_ROOT/worktree"
UNTRUSTED_ROOT="$TMP_ROOT/untrusted"
TRUST_MODEL="$TMP_ROOT/config.toml"
EXECUTION_LOG="$TMP_ROOT/trusted-execution.log"
PAYLOAD='{"stop_hook_active":false,"session_id":"hook-integrity-test"}'

# shellcheck disable=SC2016 # Exact legacy declaration fixture; expansion belongs to its inner bash -lc.
LEGACY_COMMAND='bash -lc '\''payload=$(cat 2>/dev/null || true); [ -n "$payload" ] || exit 0; command -v jq >/dev/null 2>&1 || exit 0; root=$(pwd -P) || exit 0; [ -x "$root/bin/fm-turnend-guard.sh" ] || exit 0; [ -f "$root/AGENTS.md" ] || exit 0; [ -f "$root/.codex/hooks.json" ] || exit 0; jq -e "any(.hooks.Stop[]?.hooks[]?.command?; type == \"string\" and contains(\"fm-turnend-guard.sh\"))" "$root/.codex/hooks.json" >/dev/null 2>&1 || exit 0; printf "%s" "$payload" | "$root/bin/fm-turnend-guard.sh"'\'''

install_trusted_fixture() {
  local file instrumented
  mkdir -p "$TRUSTED_ROOT/.codex" "$TRUSTED_ROOT/bin" "$TRUSTED_ROOT/state"
  cp "$ROOT/.codex/hooks.json" "$TRUSTED_ROOT/.codex/hooks.json"
  cp "$ROOT/.codex/hook-payload.sha256" "$TRUSTED_ROOT/.codex/hook-payload.sha256"
  cp "$ROOT/bin/fm-hook-manifest.sh" "$TRUSTED_ROOT/bin/fm-hook-manifest.sh"
  while read -r _ file; do
    mkdir -p "$TRUSTED_ROOT/$(dirname "$file")"
    cp "$ROOT/$file" "$TRUSTED_ROOT/$file"
  done < "$ROOT/.codex/hook-payload.sha256"
  instrumented="$TRUSTED_ROOT/bin/fm-turnend-guard.sh.instrumented"
  awk '
    { print }
    /^set -u$/ {
      print "[ -z \"${FM_TEST_HOOK_EXECUTION_LOG:-}\" ] || printf '\''TRUSTED_PAYLOAD_EXECUTED\\n'\'' >> \"$FM_TEST_HOOK_EXECUTION_LOG\""
    }
  ' "$TRUSTED_ROOT/bin/fm-turnend-guard.sh" > "$instrumented"
  mv "$instrumented" "$TRUSTED_ROOT/bin/fm-turnend-guard.sh"
  chmod +x "$TRUSTED_ROOT/bin/fm-hook-manifest.sh" \
    "$TRUSTED_ROOT/bin/fm-turnend-guard.sh"
  FM_ROOT_OVERRIDE="$TRUSTED_ROOT" \
    "$TRUSTED_ROOT/bin/fm-hook-manifest.sh" >/dev/null
  : > "$TRUSTED_ROOT/AGENTS.md"
  git -C "$TRUSTED_ROOT" init -q
  git -C "$TRUSTED_ROOT" add .
  git -C "$TRUSTED_ROOT" commit -qm fixture
  git -C "$TRUSTED_ROOT" worktree add -q -b crew "$WORKTREE_ROOT"
}

install_worktree_payload() {
  cat > "$WORKTREE_ROOT/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'WORKTREE_PAYLOAD_EXECUTED\n'
cat >/dev/null
SH
  chmod +x "$WORKTREE_ROOT/bin/fm-turnend-guard.sh"
}

install_untrusted_cwd_payload() {
  mkdir -p "$UNTRUSTED_ROOT/bin"
  cat > "$UNTRUSTED_ROOT/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'UNTRUSTED_CWD_PAYLOAD_EXECUTED\n'
cat >/dev/null
SH
  chmod +x "$UNTRUSTED_ROOT/bin/fm-turnend-guard.sh"
}

model_trust_grant() {
  local declaration_hash
  declaration_hash=$(printf '%s' "$LEGACY_COMMAND" | shasum -a 256 | cut -d ' ' -f 1)
  {
    printf '[hooks.state."/modeled/firstmate/.codex/hooks.json:stop:0:0"]\n'
    printf 'trusted_hash = "sha256:%s"\n' "$declaration_hash"
  } > "$TRUST_MODEL"
}

run_hook() {
  local command=$1 cwd=$2 hook_root=${3:-} scope_root=${4:-} out status
  set +e
  out=$(printf '%s' "$PAYLOAD" | (
    cd "$cwd" || exit 1
    FM_CODEX_HOOK_ROOT="$hook_root" FM_ROOT_OVERRIDE="$scope_root" \
      FM_HOME="$TRUSTED_ROOT" FM_TEST_HOOK_EXECUTION_LOG="$EXECUTION_LOG" \
      bash -c "$command"
  ) 2>&1)
  status=$?
  set -e
  printf '%s\t%s\n' "$status" "$out"
}

install_trusted_fixture
install_worktree_payload
install_untrusted_cwd_payload
model_trust_grant

trust_before=$(shasum -a 256 "$TRUST_MODEL" | cut -d ' ' -f 1)
legacy_result=$(run_hook "$LEGACY_COMMAND" "$WORKTREE_ROOT")
trust_after=$(shasum -a 256 "$TRUST_MODEL" | cut -d ' ' -f 1)
legacy_status=${legacy_result%%$'\t'*}
legacy_output=${legacy_result#*$'\t'}

[ "$legacy_status" -eq 0 ] || fail "legacy hook did not execute the modified worktree payload"
assert_contains "$legacy_output" "WORKTREE_PAYLOAD_EXECUTED" \
  "legacy hook did not demonstrate the worktree payload bypass"
[ "$trust_before" = "$trust_after" ] || fail "modeled trust grant changed during the legacy payload swap"
printf 'evidence before: status=%s worktree_payload=EXECUTED modeled_trust_file_unchanged=yes\n' \
  "$legacy_status"

FIXED_COMMAND=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$TRUSTED_ROOT/.codex/hooks.json")
[ -n "$FIXED_COMMAND" ] || fail "fixed Codex Stop hook command is missing"

fixed_unanchored_result=$(run_hook "$FIXED_COMMAND" "$WORKTREE_ROOT")
fixed_unanchored_status=${fixed_unanchored_result%%$'\t'*}
fixed_unanchored_output=${fixed_unanchored_result#*$'\t'}
[ "$fixed_unanchored_status" -eq 2 ] \
  || fail "fixed unanchored hook did not refuse the modified payload with exit 2"
assert_contains "$fixed_unanchored_output" \
  "firstmate Codex hook refused: trusted payload hash mismatch:" \
  "fixed unanchored hook did not name the payload-integrity refusal"
assert_not_contains "$fixed_unanchored_output" "WORKTREE_PAYLOAD_EXECUTED" \
  "fixed unanchored hook still executed the modified worktree payload"
printf 'evidence after-unanchored: status=%s worktree_payload=REFUSED refusal=%s\n' \
  "$fixed_unanchored_status" \
  "$(printf '%s' "$fixed_unanchored_output" | head -n 1)"

: > "$EXECUTION_LOG"
fixed_worktree_result=$(run_hook "$FIXED_COMMAND" "$WORKTREE_ROOT" \
  "$TRUSTED_ROOT" "$WORKTREE_ROOT")
fixed_worktree_status=${fixed_worktree_result%%$'\t'*}
fixed_worktree_output=${fixed_worktree_result#*$'\t'}
[ "$fixed_worktree_status" -eq 0 ] \
  || fail "anchored fixed Stop hook did not preserve the linked-worktree exemption"
assert_contains "$(cat "$EXECUTION_LOG")" "TRUSTED_PAYLOAD_EXECUTED" \
  "linked-worktree exemption did not positively execute the trusted payload"
assert_not_contains "$fixed_worktree_output" "WORKTREE_PAYLOAD_EXECUTED" \
  "anchored fixed Stop hook executed the modified worktree payload"
printf 'evidence after-worktree: status=%s worktree_payload=REFUSED trusted_payload=EXECUTED linked_worktree=EXEMPT\n' \
  "$fixed_worktree_status"

: > "$EXECUTION_LOG"
: > "$TRUSTED_ROOT/state/task.meta"
fixed_untrusted_cwd_result=$(run_hook "$FIXED_COMMAND" "$UNTRUSTED_ROOT" \
  "$TRUSTED_ROOT" "$TRUSTED_ROOT")
fixed_untrusted_cwd_status=${fixed_untrusted_cwd_result%%$'\t'*}
fixed_untrusted_cwd_output=${fixed_untrusted_cwd_result#*$'\t'}
[ "$fixed_untrusted_cwd_status" -eq 2 ] \
  || fail "untrusted cwd displaced the trusted guard's primary-scope refusal"
assert_contains "$fixed_untrusted_cwd_output" "TURN WOULD END BLIND - SUPERVISION IS OFF" \
  "trusted primary scope did not keep the turn-end guard active from an untrusted cwd"
assert_contains "$(cat "$EXECUTION_LOG")" "TRUSTED_PAYLOAD_EXECUTED" \
  "untrusted-cwd case did not positively execute the trusted payload"
assert_not_contains "$fixed_untrusted_cwd_output" "UNTRUSTED_CWD_PAYLOAD_EXECUTED" \
  "untrusted cwd gained executable authority"
printf 'evidence after-untrusted-cwd: status=%s cwd_payload=REFUSED trusted_payload=EXECUTED trusted_scope=ACTIVE\n' \
  "$fixed_untrusted_cwd_status"

trust_final=$(shasum -a 256 "$TRUST_MODEL" | cut -d ' ' -f 1)
[ "$trust_before" = "$trust_final" ] || fail "modeled trust grant changed during fixed-hook attempts"
printf 'evidence trust model: file_sha256=%s unchanged=yes\n' "$trust_final"
printf 'NOT_VERIFIABLE: live Codex trust-dialog re-prompt count; this offline test models config.toml and never invokes Codex.\n'
pass "Codex trusted-hook bypass executes before the fix and is refused after the fix"
