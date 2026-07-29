#!/usr/bin/env bash
# Tests for bin/fm-hook-manifest.sh.
#
# The fixture copies the real hook declarations and covered payload inventory so
# every test exercises the production format without modifying the worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GENERATOR="$ROOT/bin/fm-hook-manifest.sh"
TMP_ROOT=$(fm_test_tmproot fm-hook-manifest-tests)

new_fixture() {
  local fixture="$TMP_ROOT/$1" payload
  mkdir -p "$fixture/bin" "$fixture/.codex"
  cp "$GENERATOR" "$fixture/bin/fm-hook-manifest.sh"
  cp "$ROOT/.codex/hook-payload.sha256" "$fixture/.codex/hook-payload.sha256"
  cp "$ROOT/.codex/hooks.json" "$fixture/.codex/hooks.json"
  while read -r _ payload; do
    mkdir -p "$fixture/$(dirname "$payload")"
    cp "$ROOT/$payload" "$fixture/$payload"
  done < "$ROOT/.codex/hook-payload.sha256"
  printf '%s\n' "$fixture"
}

run_generator() {
  local fixture=$1
  shift
  FM_ROOT_OVERRIDE="$fixture" "$GENERATOR" "$@"
}

file_inode() {
  local inode
  if inode=$(stat -f '%i' "$1" 2>/dev/null); then
    printf '%s\n' "$inode"
  else
    stat -c '%i' "$1"
  fi
}

assert_four_consistent_guards() {
  local fixture=$1 expected hashes count unique manifest_count
  manifest_count=$(wc -l < "$fixture/.codex/hook-payload.sha256" | tr -d '[:space:]')
  [ "$manifest_count" -eq 13 ] \
    || fail "generated manifest has $manifest_count payloads, expected 13"
  (
    cd "$fixture" \
      && shasum -a 256 -c -q --strict .codex/hook-payload.sha256
  ) || fail "generated manifest does not verify all covered payloads"
  expected=$(shasum -a 256 "$fixture/.codex/hook-payload.sha256")
  expected=${expected%% *}
  hashes=$(grep -Eo 'manifest_hash\\" = \\"[0-9a-f]{64}' "$fixture/.codex/hooks.json" \
    | sed 's/.*\\"//')
  count=$(printf '%s\n' "$hashes" | grep -c . || true)
  unique=$(printf '%s\n' "$hashes" | sort -u | grep -c . || true)
  [ "$count" -eq 4 ] || fail "hooks.json has $count manifest guards, expected 4"
  [ "$unique" -eq 1 ] || fail "hooks.json manifest guards are not identical"
  [ "$(printf '%s\n' "$hashes" | head -1)" = "$expected" ] \
    || fail "hooks.json guards do not pin the generated manifest"
}

test_check_detects_drift_without_writing() {
  local fixture before_manifest before_hooks out rc
  fixture=$(new_fixture drift)
  before_manifest=$(shasum -a 256 "$fixture/.codex/hook-payload.sha256")
  before_hooks=$(shasum -a 256 "$fixture/.codex/hooks.json")
  printf '\n# drift\n' >> "$fixture/bin/fm-harness.sh"

  set +e
  out=$(run_generator "$fixture" --check 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 1 ] || fail "--check returned $rc for drift, expected 1"
  assert_contains "$out" "hook manifest drift: .codex/hook-payload.sha256" \
    "--check reports manifest drift"
  assert_contains "$out" "hook manifest drift: .codex/hooks.json" \
    "--check reports hooks.json drift"
  [ "$(shasum -a 256 "$fixture/.codex/hook-payload.sha256")" = "$before_manifest" ] \
    || fail "--check rewrote the manifest"
  [ "$(shasum -a 256 "$fixture/.codex/hooks.json")" = "$before_hooks" ] \
    || fail "--check rewrote hooks.json"
  pass "drift is detected without tracked-file writes"
}

test_missing_payload_refuses_before_writing() {
  local fixture before_manifest before_hooks out rc
  fixture=$(new_fixture missing)
  before_manifest=$(shasum -a 256 "$fixture/.codex/hook-payload.sha256")
  before_hooks=$(shasum -a 256 "$fixture/.codex/hooks.json")
  rm "$fixture/bin/fm-harness.sh"

  set +e
  out=$(run_generator "$fixture" 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 2 ] || fail "missing payload returned $rc, expected 2"
  assert_contains "$out" "bin/fm-harness.sh is missing or is a symlink" \
    "missing covered payload is named"
  [ "$(shasum -a 256 "$fixture/.codex/hook-payload.sha256")" = "$before_manifest" ] \
    || fail "missing payload caused a partial manifest write"
  [ "$(shasum -a 256 "$fixture/.codex/hooks.json")" = "$before_hooks" ] \
    || fail "missing payload caused a partial hooks.json write"
  pass "missing covered payload refuses without a partial write"
}

test_symlink_payload_refuses_before_writing() {
  local fixture before_manifest before_hooks out rc
  fixture=$(new_fixture symlink)
  before_manifest=$(shasum -a 256 "$fixture/.codex/hook-payload.sha256")
  before_hooks=$(shasum -a 256 "$fixture/.codex/hooks.json")
  mv "$fixture/bin/fm-harness.sh" "$fixture/bin/real-harness.sh"
  ln -s real-harness.sh "$fixture/bin/fm-harness.sh"

  set +e
  out=$(run_generator "$fixture" 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 2 ] || fail "symlinked payload returned $rc, expected 2"
  assert_contains "$out" "bin/fm-harness.sh is missing or is a symlink" \
    "symlinked covered payload is named"
  [ "$(shasum -a 256 "$fixture/.codex/hook-payload.sha256")" = "$before_manifest" ] \
    || fail "symlinked payload caused a partial manifest write"
  [ "$(shasum -a 256 "$fixture/.codex/hooks.json")" = "$before_hooks" ] \
    || fail "symlinked payload caused a partial hooks.json write"
  pass "symlinked covered payload refuses without a partial write"
}

test_write_updates_four_guards_and_is_idempotent() {
  local fixture first_out manifest_inode hooks_inode manifest_hash hooks_hash second_out
  fixture=$(new_fixture write)
  printf '\n# legitimate update\n' >> "$fixture/bin/fm-harness.sh"

  first_out=$(run_generator "$fixture")
  assert_contains "$first_out" "hook manifest: updated" "write mode reports update"
  run_generator "$fixture" --check >/dev/null \
    || fail "generated files do not pass --check"
  assert_four_consistent_guards "$fixture"

  manifest_inode=$(file_inode "$fixture/.codex/hook-payload.sha256")
  hooks_inode=$(file_inode "$fixture/.codex/hooks.json")
  manifest_hash=$(shasum -a 256 "$fixture/.codex/hook-payload.sha256")
  hooks_hash=$(shasum -a 256 "$fixture/.codex/hooks.json")

  second_out=$(run_generator "$fixture")

  assert_contains "$second_out" "hook manifest: current" \
    "second write-mode run reports current"
  [ "$(file_inode "$fixture/.codex/hook-payload.sha256")" = "$manifest_inode" ] \
    || fail "idempotent run replaced the unchanged manifest"
  [ "$(file_inode "$fixture/.codex/hooks.json")" = "$hooks_inode" ] \
    || fail "idempotent run replaced unchanged hooks.json"
  [ "$(shasum -a 256 "$fixture/.codex/hook-payload.sha256")" = "$manifest_hash" ] \
    || fail "idempotent run changed the manifest bytes"
  [ "$(shasum -a 256 "$fixture/.codex/hooks.json")" = "$hooks_hash" ] \
    || fail "idempotent run changed hooks.json bytes"
  assert_four_consistent_guards "$fixture"
  pass "write mode updates all four guards and a second run changes nothing"
}

test_check_detects_drift_without_writing
test_missing_payload_refuses_before_writing
test_symlink_payload_refuses_before_writing
test_write_updates_four_guards_and_is_idempotent

echo "# all fm-hook-manifest tests passed"
