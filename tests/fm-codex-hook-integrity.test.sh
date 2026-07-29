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

TMP_ROOT=$(fm_test_tmproot fm-codex-hook-integrity)
TRUSTED_ROOT="$TMP_ROOT/trusted"
WORKTREE_ROOT="$TMP_ROOT/worktree"
TRUST_MODEL="$TMP_ROOT/config.toml"
PAYLOAD='{"stop_hook_active":false,"session_id":"hook-integrity-test"}'

# shellcheck disable=SC2016 # Exact legacy declaration fixture; expansion belongs to its inner bash -lc.
LEGACY_COMMAND='bash -lc '\''payload=$(cat 2>/dev/null || true); [ -n "$payload" ] || exit 0; command -v jq >/dev/null 2>&1 || exit 0; root=$(pwd -P) || exit 0; [ -x "$root/bin/fm-turnend-guard.sh" ] || exit 0; [ -f "$root/AGENTS.md" ] || exit 0; [ -f "$root/.codex/hooks.json" ] || exit 0; jq -e "any(.hooks.Stop[]?.hooks[]?.command?; type == \"string\" and contains(\"fm-turnend-guard.sh\"))" "$root/.codex/hooks.json" >/dev/null 2>&1 || exit 0; printf "%s" "$payload" | "$root/bin/fm-turnend-guard.sh"'\'''

install_trusted_fixture() {
  local file
  mkdir -p "$TRUSTED_ROOT/.codex" "$TRUSTED_ROOT/bin" "$TRUSTED_ROOT/state"
  cp "$ROOT/.codex/hooks.json" "$TRUSTED_ROOT/.codex/hooks.json"
  cp "$ROOT/.codex/hook-payload.sha256" "$TRUSTED_ROOT/.codex/hook-payload.sha256"
  while read -r _ file; do
    mkdir -p "$TRUSTED_ROOT/$(dirname "$file")"
    cp "$ROOT/$file" "$TRUSTED_ROOT/$file"
  done < "$ROOT/.codex/hook-payload.sha256"
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

model_trust_grant() {
  local declaration_hash
  declaration_hash=$(printf '%s' "$LEGACY_COMMAND" | shasum -a 256 | cut -d ' ' -f 1)
  {
    printf '[hooks.state."/modeled/firstmate/.codex/hooks.json:stop:0:0"]\n'
    printf 'trusted_hash = "sha256:%s"\n' "$declaration_hash"
  } > "$TRUST_MODEL"
}

run_hook() {
  local command=$1 root=$2 hook_root=${3:-} out status
  set +e
  if [ -n "$hook_root" ]; then
    out=$(printf '%s' "$PAYLOAD" \
      | FM_CODEX_HOOK_ROOT="$hook_root" FM_HOME="$TRUSTED_ROOT" \
        bash -c "$command" 2>&1)
  else
    out=$(printf '%s' "$PAYLOAD" | (cd "$root" && bash -c "$command") 2>&1)
  fi
  status=$?
  set -e
  printf '%s\t%s\n' "$status" "$out"
}

install_trusted_fixture
install_worktree_payload
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

FIXED_COMMAND=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$ROOT/.codex/hooks.json")
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

: > "$TRUSTED_ROOT/state/task.meta"
fixed_anchored_result=$(run_hook "$FIXED_COMMAND" "$WORKTREE_ROOT" "$TRUSTED_ROOT")
fixed_anchored_status=${fixed_anchored_result%%$'\t'*}
fixed_anchored_output=${fixed_anchored_result#*$'\t'}
[ "$fixed_anchored_status" -eq 2 ] \
  || fail "anchored fixed Stop hook did not execute the trusted guard's unhealthy-watcher refusal"
assert_contains "$fixed_anchored_output" "TURN WOULD END BLIND - SUPERVISION IS OFF" \
  "anchored fixed Stop hook did not keep the trusted turn-end guard active"
assert_not_contains "$fixed_anchored_output" "WORKTREE_PAYLOAD_EXECUTED" \
  "anchored fixed Stop hook executed the modified worktree payload"
printf 'evidence after-anchored: status=%s worktree_payload=REFUSED trusted_stop_guard=ACTIVE\n' \
  "$fixed_anchored_status"

trust_final=$(shasum -a 256 "$TRUST_MODEL" | cut -d ' ' -f 1)
[ "$trust_before" = "$trust_final" ] || fail "modeled trust grant changed during fixed-hook attempts"
printf 'evidence trust model: file_sha256=%s unchanged=yes\n' "$trust_final"
printf 'NOT_VERIFIABLE: live Codex trust-dialog re-prompt count; this offline test models config.toml and never invokes Codex.\n'
pass "Codex trusted-hook bypass executes before the fix and is refused after the fix"
