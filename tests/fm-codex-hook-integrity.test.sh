#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2153
# Offline regression for the Codex project-hook payload and OS anchor boundary.
#
# The trust state is modeled in temporary fixtures because this suite must not
# read or write the operator's real ~/.codex/config.toml.
# Live trust-dialog behavior therefore remains explicitly NOT_VERIFIABLE here.
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-hook-integrity)
TRUSTED_ROOT="$TMP_ROOT/trusted"
WORKTREE_ROOT="$TMP_ROOT/worktree"
TRUST_MODEL="$TMP_ROOT/config.toml"
PAYLOAD='{"stop_hook_active":false,"session_id":"hook-integrity-test"}'

# shellcheck disable=SC2016 # Exact pre-fix declaration fixture.
LEGACY_COMMAND='bash -lc '\''payload=$(cat 2>/dev/null || true); [ -n "$payload" ] || exit 0; root=$(pwd -P) || exit 0; [ -x "$root/bin/fm-turnend-guard.sh" ] || exit 0; printf "%s" "$payload" | "$root/bin/fm-turnend-guard.sh"'\'''

manifest_file_from_line() {
  local line=$1
  printf '%s\n' "${line#*  }"
}

install_trusted_fixture() {
  local line file
  mkdir -p "$TRUSTED_ROOT/.codex" "$TRUSTED_ROOT/bin" "$TRUSTED_ROOT/state"
  cp -p "$ROOT/.codex/hooks.json" "$TRUSTED_ROOT/.codex/hooks.json"
  cp -p "$ROOT/.codex/hook-payload.sha256" "$TRUSTED_ROOT/.codex/hook-payload.sha256"
  while IFS= read -r line; do
    file=$(manifest_file_from_line "$line")
    mkdir -p "$TRUSTED_ROOT/$(dirname "$file")"
    cp -p "$ROOT/$file" "$TRUSTED_ROOT/$file"
  done < "$ROOT/.codex/hook-payload.sha256"
  : > "$TRUSTED_ROOT/AGENTS.md"
  git -C "$TRUSTED_ROOT" init -q
  git -C "$TRUSTED_ROOT" add .
  git -C "$TRUSTED_ROOT" \
    -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm fixture
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
  local command=$1 root=$2 hook_root=${3:-} out rc
  set +e
  if [ -n "$hook_root" ]; then
    out=$(printf '%s' "$PAYLOAD" \
      | TMPDIR="$TMP_ROOT" FM_CODEX_HOOK_ROOT="$hook_root" \
        FM_CODEX_HOOK_SOURCE_ROOT="$hook_root" FM_CODEX_HOOK_PREPARED=1 \
        FM_HOME="$TRUSTED_ROOT" bash -c "$command" 2>&1)
  else
    out=$(printf '%s' "$PAYLOAD" \
      | (cd "$root" && TMPDIR="$TMP_ROOT" FM_HOME="$TRUSTED_ROOT" bash -c "$command") 2>&1)
  fi
  rc=$?
  set -e
  printf '%s\t%s\n' "$rc" "$out"
}

test_application_layer() {
  local trust_before trust_after trust_final legacy_result legacy_status legacy_output
  local fixed_command fixed_result fixed_status fixed_output anchored_result anchored_status anchored_output

  install_trusted_fixture
  install_worktree_payload
  model_trust_grant

  trust_before=$(shasum -a 256 "$TRUST_MODEL" | cut -d ' ' -f 1)
  legacy_result=$(run_hook "$LEGACY_COMMAND" "$WORKTREE_ROOT")
  trust_after=$(shasum -a 256 "$TRUST_MODEL" | cut -d ' ' -f 1)
  legacy_status=${legacy_result%%$'\t'*}
  legacy_output=${legacy_result#*$'\t'}
  expect_code 0 "$legacy_status" "legacy hook should execute the modified worktree payload"
  assert_contains "$legacy_output" "WORKTREE_PAYLOAD_EXECUTED" \
    "legacy hook did not demonstrate the worktree payload bypass"
  [ "$trust_before" = "$trust_after" ] \
    || fail "modeled trust grant changed during the legacy payload swap"
  printf 'evidence before: status=%s worktree_payload=EXECUTED modeled_trust_file_unchanged=yes\n' \
    "$legacy_status"

  fixed_command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$ROOT/.codex/hooks.json")
  [ -n "$fixed_command" ] || fail "fixed Codex Stop hook command is missing"
  fixed_result=$(run_hook "$fixed_command" "$WORKTREE_ROOT")
  fixed_status=${fixed_result%%$'\t'*}
  fixed_output=${fixed_result#*$'\t'}
  expect_code 2 "$fixed_status" "fixed unanchored hook should refuse the modified payload"
  assert_contains "$fixed_output" "firstmate Codex hook refused: staged payload hash mismatch:" \
    "fixed unanchored hook did not name its staged payload-integrity refusal"
  assert_not_contains "$fixed_output" "WORKTREE_PAYLOAD_EXECUTED" \
    "fixed unanchored hook executed the modified worktree payload"
  printf 'evidence after-unanchored: status=%s worktree_payload=REFUSED refusal=%s\n' \
    "$fixed_status" "$(printf '%s' "$fixed_output" | head -n 1)"

  : > "$TRUSTED_ROOT/state/task.meta"
  anchored_result=$(run_hook "$fixed_command" "$WORKTREE_ROOT" "$TRUSTED_ROOT")
  anchored_status=${anchored_result%%$'\t'*}
  anchored_output=${anchored_result#*$'\t'}
  expect_code 2 "$anchored_status" \
    "anchored fixed Stop hook should execute the trusted guard's watcher refusal"
  assert_contains "$anchored_output" "TURN WOULD END BLIND - SUPERVISION IS OFF" \
    "anchored fixed Stop hook did not keep the trusted turn-end guard active"
  assert_not_contains "$anchored_output" "WORKTREE_PAYLOAD_EXECUTED" \
    "anchored fixed Stop hook executed the modified worktree payload"
  printf 'evidence after-anchored: status=%s worktree_payload=REFUSED trusted_stop_guard=ACTIVE\n' \
    "$anchored_status"

  trust_final=$(shasum -a 256 "$TRUST_MODEL" | cut -d ' ' -f 1)
  [ "$trust_before" = "$trust_final" ] \
    || fail "modeled trust grant changed during fixed-hook attempts"
  printf 'evidence trust model: file_sha256=%s unchanged=yes\n' "$trust_final"
  pass "Codex trusted-hook bypass executes before the fix and is refused after the fix"
}

test_all_hook_targets_execute_from_prepared_payload() {
  local command payload out rc

  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$ROOT/.codex/hooks.json")
  payload='{"cwd":"/modeled/session"}'
  set +e
  out=$(printf '%s' "$payload" \
    | TMPDIR="$TMP_ROOT" FM_CODEX_HOOK_ROOT="$TRUSTED_ROOT" \
      FM_CODEX_HOOK_SOURCE_ROOT="$TRUSTED_ROOT" FM_CODEX_HOOK_PREPARED=1 \
      FM_HOME="$TRUSTED_ROOT" bash -c "$command" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "prepared SessionStart hook should execute"
  assert_contains "$out" "FIRSTMATE_OP:" "prepared SessionStart hook did not emit the typed nudge"

  command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$ROOT/.codex/hooks.json")
  payload='{"tool_input":{"command":"bin/fm-watch-arm.sh &"}}'
  set +e
  out=$(printf '%s' "$payload" \
    | TMPDIR="$TMP_ROOT" FM_CODEX_HOOK_ROOT="$TRUSTED_ROOT" \
      FM_CODEX_HOOK_SOURCE_ROOT="$TRUSTED_ROOT" FM_CODEX_HOOK_PREPARED=1 \
      FM_HOME="$TRUSTED_ROOT" bash -c "$command" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "prepared watcher-arm PreToolUse hook should deny the unsafe command"
  assert_contains "$out" "watcher-background" \
    "prepared watcher-arm hook did not execute its staged policy"

  command=$(jq -r '.hooks.PreToolUse[0].hooks[1].command // empty' "$ROOT/.codex/hooks.json")
  payload='{"tool_input":{"command":"cd projects/foo"}}'
  set +e
  out=$(printf '%s' "$payload" \
    | TMPDIR="$TMP_ROOT" FM_CODEX_HOOK_ROOT="$TRUSTED_ROOT" \
      FM_CODEX_HOOK_SOURCE_ROOT="$TRUSTED_ROOT" FM_CODEX_HOOK_PREPARED=1 \
      FM_HOME="$TRUSTED_ROOT" bash -c "$command" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "prepared cd PreToolUse hook should deny the persistent change"
  assert_contains "$out" "persistent-cd" "prepared cd hook did not execute its staged policy"

  printf 'evidence prepared targets: SessionStart=EXECUTED watcher_PreToolUse=DENIED cd_PreToolUse=DENIED Stop=ACTIVE\n'
  pass "all four Codex declarations execute their prepared manifest-declared targets"
}

test_nonlogin_invocation() {
  local profile_home marker fixed_command
  profile_home="$TMP_ROOT/profile-home"
  marker="$TMP_ROOT/login-profile-sourced"
  mkdir -p "$profile_home"
  printf 'printf sourced > %q\n' "$marker" > "$profile_home/.bash_profile"

  HOME="$profile_home" /bin/bash -lc 'true'
  [ -f "$marker" ] || fail "RED: login bash did not source the controlled login profile"
  printf 'evidence login RED: /bin/bash -lc sourced controlled .bash_profile=yes\n'
  /bin/unlink "$marker"

  fixed_command=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$ROOT/.codex/hooks.json")
  [ -n "$fixed_command" ] || fail "fixed Codex SessionStart command is missing"
  printf '' | (cd "$TRUSTED_ROOT" && HOME="$profile_home" bash -c "$fixed_command")
  [ ! -e "$marker" ] || fail "fixed hook invocation still sourced the login profile"
  printf 'evidence login GREEN: fixed hook sourced controlled .bash_profile=no\n'
  pass "Codex hooks enter bash without login or rc profile loading"
}

test_symlinked_manifest_entry_is_refused() {
  local source stage out rc
  source="$TMP_ROOT/symlink-source"
  stage="$TMP_ROOT/symlink-stage"
  cp -R "$TRUSTED_ROOT" "$source"
  /bin/unlink "$source/bin/fm-spawn.sh"
  ln -s "$ROOT/bin/fm-spawn.sh" "$source/bin/fm-spawn.sh"
  mkdir -m 700 "$stage"
  set +e
  out=$("$ROOT/bin/fm-codex-hook-run.sh" prepare "$source" "$stage" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "symlinked manifest entry should be refused"
  assert_contains "$out" "trusted payload entry is missing or unsafe: bin/fm-spawn.sh" \
    "symlinked manifest entry refusal did not name the unsafe payload"
  printf 'evidence symlink: manifest_entry=bin/fm-spawn.sh same_bytes=yes result=REFUSED status=%s\n' "$rc"
  pass "Codex hook staging rejects a symlinked manifest entry even when its target bytes match"
}

test_owner_reversible_file_flags() {
  local probe chmod_block chmod_reverse uchg_block uchg_reverse schg_set
  [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/chflags ] \
    || { pass "macOS file-flag probe not applicable on this host"; return; }
  probe="$TMP_ROOT/owner-flag-probe"
  printf 'probe\n' > "$probe"

  chmod a-w "$probe"
  set +e
  printf 'blocked\n' 2>/dev/null >> "$probe"
  chmod_block=$?
  set -e
  chmod u+w "$probe"
  printf 'reversed\n' >> "$probe"
  chmod_reverse=$?

  /usr/bin/chflags uchg "$probe"
  set +e
  printf 'blocked\n' 2>/dev/null >> "$probe"
  uchg_block=$?
  set -e
  /usr/bin/chflags nouchg "$probe"
  printf 'reversed\n' >> "$probe"
  uchg_reverse=$?

  set +e
  /usr/bin/chflags schg "$probe" 2>/dev/null
  schg_set=$?
  set -e
  [ "$schg_set" -ne 0 ] || /usr/bin/chflags noschg "$probe"

  expect_code 1 "$chmod_block" "owner mode-bit write protection should block an ordinary write"
  expect_code 0 "$chmod_reverse" "the same owner should be able to reverse mode-bit protection"
  expect_code 1 "$uchg_block" "user-immutable flag should block an ordinary write"
  expect_code 0 "$uchg_reverse" "the same owner should be able to reverse user-immutable protection"
  [ "$schg_set" -ne 0 ] || fail "unprivileged process unexpectedly set the system-immutable flag"
  printf 'evidence user flags: chmod_write=%s chmod_same_owner_reversal=%s uchg_write=%s uchg_same_owner_reversal=%s schg_set=%s\n' \
    "$chmod_block" "$chmod_reverse" "$uchg_block" "$uchg_reverse" "$schg_set"
  pass "owner mode bits and user flags are reversible by the same account; system immutable needs privilege"
}

test_os_sandbox_scope_and_reversal() {
  local ordinary before after out rc reverse_rc stage_leaks
  [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sandbox-exec ] \
    || { pass "macOS process-sandbox probe not applicable on this host"; return; }
  ordinary="$TRUSTED_ROOT/ordinary-captain-file.txt"
  printf 'ordinary\n' > "$ordinary"
  before=$(shasum -a 256 "$TRUSTED_ROOT/.codex/hook-payload.sha256" | cut -d ' ' -f 1)

  set +e
  out=$(ORDINARY="$ordinary" "$TRUSTED_ROOT/bin/fm-codex-hook-launch.sh" \
    "$TRUSTED_ROOT" "$TMP_ROOT" -- /bin/bash --noprofile --norc -c '
      set +e
      printf attack >> "$FM_CODEX_HOOK_SOURCE_ROOT/.codex/hook-payload.sha256" 2>/dev/null
      protected_rc=$?
      printf stage-attack >> "$FM_CODEX_HOOK_ROOT/bin/fm-turnend-guard.sh" 2>/dev/null
      stage_rc=$?
      printf allowed >> "$ORDINARY"
      ordinary_rc=$?
      mv "$FM_CODEX_HOOK_SOURCE_ROOT/bin" "$FM_CODEX_HOOK_SOURCE_ROOT/bin-moved" 2>/dev/null
      rename_rc=$?
      /usr/bin/sandbox-exec -p "(version 1)(allow default)" /bin/sh -c \
        '\''printf nested-attack >> "$1"'\'' sh \
        "$FM_CODEX_HOOK_SOURCE_ROOT/.codex/hook-payload.sha256" 2>/dev/null
      nested_rc=$?
      printf "protected_rc=%s stage_rc=%s ordinary_rc=%s rename_rc=%s nested_rc=%s\n" \
        "$protected_rc" "$stage_rc" "$ordinary_rc" "$rename_rc" "$nested_rc"
    ' 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "sandboxed Codex child probe should finish"
  assert_contains "$out" "protected_rc=1" "sandbox did not deny source manifest writes"
  assert_contains "$out" "stage_rc=1" "sandbox did not deny prepared payload writes"
  assert_contains "$out" "ordinary_rc=0" "sandbox denied an unrelated file in the same root"
  assert_contains "$out" "rename_rc=1" "sandbox allowed replacement of the bin container"
  assert_contains "$out" "nested_rc=71" "sandboxed child unexpectedly applied a looser nested sandbox"
  after=$(shasum -a 256 "$TRUSTED_ROOT/.codex/hook-payload.sha256" | cut -d ' ' -f 1)
  [ "$before" = "$after" ] || fail "sandboxed child changed the protected manifest"
  assert_contains "$(cat "$ordinary")" "allowed" \
    "unrelated file did not receive the allowed write"
  stage_leaks=$(find "$TMP_ROOT" -maxdepth 1 -name 'codex-hook-root.*' | wc -l | tr -d ' ')
  [ "$stage_leaks" -eq 0 ] || fail "Codex sandbox launcher leaked a prepared stage"

  mv "$TRUSTED_ROOT/bin" "$TRUSTED_ROOT/bin-reversal-probe"
  reverse_rc=$?
  mv "$TRUSTED_ROOT/bin-reversal-probe" "$TRUSTED_ROOT/bin"
  expect_code 0 "$reverse_rc" "sandbox reversal should be complete after child exit"
  shasum -a 256 -c -q --strict "$TRUSTED_ROOT/.codex/hook-payload.sha256" \
    || fail "sandbox reversal probe changed the protected payload"
  printf 'evidence sandbox: protected_write=DENIED stage_write=DENIED container_rename=DENIED unrelated_write=ALLOWED nested_escape=DENIED reversal_after_exit=VERIFIED\n'
  pass "macOS process sandbox protects only the Codex hook anchor and staged payload surface"
}

test_check_to_execution_race() {
  local red_root red_script red_expected red_out red_pid green_source green_stage manifest_hash out rc
  red_root="$TMP_ROOT/race-red"
  mkdir -p "$red_root"
  red_script="$red_root/payload.sh"
  cat > "$red_script" <<'SH'
#!/usr/bin/env bash
printf 'ORIGINAL_PAYLOAD_EXECUTED\n'
SH
  chmod +x "$red_script"
  red_expected=$(shasum -a 256 "$red_script" | cut -d ' ' -f 1)
  (
    actual=$(shasum -a 256 "$red_script" | cut -d ' ' -f 1)
    [ "$actual" = "$red_expected" ] || exit 90
    : > "$red_root/verified"
    while [ ! -e "$red_root/continue" ]; do sleep 0.01; done
    "$red_script" > "$red_root/output"
  ) &
  red_pid=$!
  while [ ! -e "$red_root/verified" ]; do sleep 0.01; done
  cat > "$red_script" <<'SH'
#!/usr/bin/env bash
printf 'RACED_PAYLOAD_EXECUTED\n'
SH
  chmod +x "$red_script"
  : > "$red_root/continue"
  wait "$red_pid"
  red_out=$(cat "$red_root/output")
  assert_contains "$red_out" "RACED_PAYLOAD_EXECUTED" \
    "RED: verify-path-then-execute-path model did not reproduce the race"
  printf 'evidence race RED: verified_path_then_executed_same_path=RACED_PAYLOAD_EXECUTED\n'

  green_source="$TMP_ROOT/race-source"
  green_stage="$TMP_ROOT/race-stage"
  cp -R "$TRUSTED_ROOT" "$green_source"
  mkdir -m 700 "$green_stage"
  "$ROOT/bin/fm-codex-hook-run.sh" prepare "$green_source" "$green_stage"
  cat > "$green_source/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'RACED_SOURCE_PAYLOAD_EXECUTED\n'
SH
  chmod +x "$green_source/bin/fm-turnend-guard.sh"
  : > "$green_source/state/task.meta"
  manifest_hash=$(shasum -a 256 "$green_stage/.codex/hook-payload.sha256" | cut -d ' ' -f 1)
  set +e
  out=$(printf '%s' "$PAYLOAD" | FM_HOME="$green_source" \
    "$ROOT/bin/fm-codex-hook-run.sh" run "$green_stage" "$green_source" \
      "$manifest_hash" bin/fm-turnend-guard.sh 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "verified staged turn-end guard should retain its normal refusal"
  assert_contains "$out" "TURN WOULD END BLIND - SUPERVISION IS OFF" \
    "verified staged target did not execute the original trusted guard"
  assert_not_contains "$out" "RACED_SOURCE_PAYLOAD_EXECUTED" \
    "source-tree mutation changed the already verified staged execution"
  chmod -R u+w "$green_stage"
  printf 'evidence race GREEN: source_mutated_after_stage=yes executed_verified_stage=yes raced_source_executed=no reversal_chmod=VERIFIED\n'
  pass "Codex hooks execute the verified staged copy instead of the checked source path"
}

test_application_layer
test_all_hook_targets_execute_from_prepared_payload
test_nonlogin_invocation
test_symlinked_manifest_entry_is_refused
test_owner_reversible_file_flags
test_os_sandbox_scope_and_reversal
test_check_to_execution_race

printf 'NOT_VERIFIABLE: live Codex trust-dialog re-prompt count; this offline test models config.toml and never invokes Codex.\n'
pass "Codex hook integrity and operating-system hardening regressions passed"
