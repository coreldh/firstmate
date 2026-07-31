#!/usr/bin/env bash
# Executable contract for the canonical Firstmate CAPTAIN-RESUME carrier.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESUME="$ROOT/bin/fm-captain-resume.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-resume)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/historical" "$home/state/pending-replies" "$home/config" "$home/projects"
  home=$(CDPATH='' cd -- "$home" && pwd -P)
  printf 'historical root carrier\n' > "$home/data/CAPTAIN-RESUME.md"
  printf 'historical nested carrier\n' > "$home/data/historical/CAPTAIN-RESUME-old.md"
  printf 'legacy canonical content\n' > "$home/CAPTAIN-RESUME.md"
  printf '%s\n' "$home"
}

write_fake_bearings() {
  local path=$1
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "home": "synthetic/home",
  "generated": "2026-07-31T12:34:56Z",
  "prs": "not_requested",
  "in_flight": [
    {"id":"task-live","kind":"ship","state":"working","doing":"implementing the carrier"}
  ],
  "secondmates": [],
  "decisions_open": [
    {"id":"task-decision-route","key":"route","verb":"captain-hold","summary":"Choose route A or B","owner":"(main)"}
  ],
  "landed": [],
  "gates": [
    {"id":"task-next","title":"Run the independent gate","blocked_by":"task-live","reason":"dependency","owner":"(main)"}
  ],
  "reports": [
    {"id":"task-scout","path":"data/task-scout/report.md"}
  ],
  "recorded_prs": [],
  "omitted": []
}
JSON
EOF
  chmod +x "$path"
}

test_refresh_is_canonical_complete_and_non_destructive() {
  local home fake root_before nested_before out status
  home=$(make_home complete)
  fake="$home/fake-bearings"
  write_fake_bearings "$fake"
  printf '1700000000\t7\tsignal\ttask-live\tdone: validation ready\n' > "$home/state/.wake-queue"
  printf 'pending reply body\n' > "$home/state/pending-replies/corr-17"
  root_before=$(shasum -a 256 "$home/data/CAPTAIN-RESUME.md" | awk '{print $1}')
  nested_before=$(shasum -a 256 "$home/data/historical/CAPTAIN-RESUME-old.md" | awk '{print $1}')

  set +e
  FM_HOME="$home" FM_CAPTAIN_RESUME_BEARINGS="$fake" "$RESUME" refresh \
    >"$home/missing-session.out" 2>"$home/missing-session.err"
  status=$?
  set -e
  expect_code 2 "$status" "refresh without producing session identity must refuse"
  assert_grep "--session-id is required" "$home/missing-session.err" \
    "missing-session refusal did not name the required carrier field"
  assert_grep "legacy canonical content" "$home/CAPTAIN-RESUME.md" \
    "failed refresh overwrote the canonical carrier"

  out=$(FM_HOME="$home" FM_CAPTAIN_RESUME_BEARINGS="$fake" \
    FM_CAPTAIN_RESUME_NOW='2026-07-31T12:35:00Z' \
    "$RESUME" refresh --session-id 'codex:session-31') \
    || fail "canonical refresh failed"
  [ "$out" = "$home/CAPTAIN-RESUME.md" ] || fail "refresh did not return the canonical carrier path: $out"
  assert_grep "Refreshed: 2026-07-31T12:35:00Z" "$out" "carrier lost refresh timestamp"
  assert_grep "Producing session: codex:session-31" "$out" "carrier lost producing session identity"
  assert_grep "## Live tasks" "$out" "carrier lost live-task section"
  assert_grep "task-live" "$out" "carrier lost live task"
  assert_grep "## Pending decisions" "$out" "carrier lost pending-decision section"
  assert_grep "task-decision-route" "$out" "carrier lost pending decision"
  assert_grep "## Source reports" "$out" "carrier lost source-report section"
  assert_grep "data/task-scout/report.md" "$out" "carrier lost report path"
  assert_grep "## Pending notifications" "$out" "carrier lost pending-notification section"
  assert_grep "signal / task-live / done: validation ready" "$out" "carrier lost queued wake"
  assert_grep "pending-replies/corr-17" "$out" "carrier lost pending reply pointer"
  assert_grep "## Next steps" "$out" "carrier lost next-step section"
  assert_grep "task-next" "$out" "carrier lost charted next step"
  [ "$root_before" = "$(shasum -a 256 "$home/data/CAPTAIN-RESUME.md" | awk '{print $1}')" ] \
    || fail "refresh changed historical data/CAPTAIN-RESUME.md"
  [ "$nested_before" = "$(shasum -a 256 "$home/data/historical/CAPTAIN-RESUME-old.md" | awk '{print $1}')" ] \
    || fail "refresh changed nested historical CAPTAIN-RESUME"
  pass "canonical CAPTAIN-RESUME refresh is complete and preserves historical carriers"
}

test_failed_snapshot_preserves_previous_carrier() {
  local home fake before status
  home=$(make_home invalid-snapshot)
  fake="$home/fake-invalid-bearings"
  printf '#!/usr/bin/env bash\nprintf "not-json\\n"\n' > "$fake"
  chmod +x "$fake"
  before=$(shasum -a 256 "$home/CAPTAIN-RESUME.md" | awk '{print $1}')
  set +e
  FM_HOME="$home" FM_CAPTAIN_RESUME_BEARINGS="$fake" \
    "$RESUME" refresh --session-id 'codex:session-bad' >"$home/out" 2>"$home/err"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "invalid Bearings JSON unexpectedly refreshed carrier"
  [ "$before" = "$(shasum -a 256 "$home/CAPTAIN-RESUME.md" | awk '{print $1}')" ] \
    || fail "invalid snapshot damaged the previous canonical carrier"
  pass "failed CAPTAIN-RESUME refresh preserves the previous carrier"
}

test_truncated_snapshot_preserves_previous_carrier() {
  local home fake before status
  home=$(make_home truncated-snapshot)
  fake="$home/fake-truncated-bearings"
  write_fake_bearings "$fake"
  sed 's/"omitted": \[\]/"omitted": [{"surface":"secondmate sample active_children omitted: 1","reveal":"raise bound","carrier_relevant":true}]/' \
    "$fake" > "$fake.next"
  mv "$fake.next" "$fake"
  chmod +x "$fake"
  before=$(shasum -a 256 "$home/CAPTAIN-RESUME.md" | awk '{print $1}')
  set +e
  FM_HOME="$home" FM_CAPTAIN_RESUME_BEARINGS="$fake" \
    "$RESUME" refresh --session-id 'codex:session-truncated' >"$home/out" 2>"$home/err"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "truncated Bearings snapshot unexpectedly refreshed carrier"
  assert_grep "incomplete for the canonical carrier" "$home/err" \
    "truncated snapshot refusal did not identify incomplete carrier evidence"
  [ "$before" = "$(shasum -a 256 "$home/CAPTAIN-RESUME.md" | awk '{print $1}')" ] \
    || fail "truncated snapshot damaged the previous canonical carrier"
  pass "truncated CAPTAIN-RESUME evidence preserves the previous carrier"
}

test_refresh_is_canonical_complete_and_non_destructive
test_failed_snapshot_preserves_previous_carrier
test_truncated_snapshot_preserves_previous_carrier
