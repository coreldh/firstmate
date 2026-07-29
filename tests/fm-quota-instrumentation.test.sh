#!/usr/bin/env bash
# Behavior tests for the task quota instrument: bin/fm-quota-record.sh (capture at
# spawn and at close) and bin/fm-quota-delta.sh (what the task cost).
#
# The point of the instrument is measurement discipline, so these cases pin the
# properties that make a recorded number trustworthy rather than merely present:
#   (a) record shape, and staleness recorded faithfully - "stale": false must stay
#       false, never collapse to unknown (the jq `//` alternative operator falls
#       through on false as well as null, which silently blurred exactly this field)
#   (b) a missing measurement is distinguishable from a zero: providers is null when
#       nothing was read, [] only when the reader genuinely reported none
#   (c) attribution states its basis and never guesses a model-routed provider
#   (d) every degradation - reader absent, non-zero, non-JSON, hung, disabled -
#       lands exactly one explicit record instead of silence
#   (e) --async returns immediately even against a hung reader, and the bounded read
#       kills the reader's whole process tree rather than orphaning its children
#   (f) the delta refuses to report a cost across a window reset, which is the normal
#       shape of an overnight run riding a reset
#   (g) end to end over the REAL bin/fm-spawn.sh and bin/fm-teardown.sh: a spawn
#       writes the spawn record, a cleanup writes the close record, and the pair is
#       readable as a cost
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECORD="$ROOT/bin/fm-quota-record.sh"
DELTA="$ROOT/bin/fm-quota-delta.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-instr)

command -v jq >/dev/null 2>&1 || { echo "ok - skipped: jq not installed"; exit 0; }

# A fake reader that serves whatever snapshot FM_FAKE_QUOTA_SNAPSHOT points at, so
# every number in these cases is fixed rather than whatever the host account happens
# to report today.
make_fake_quota() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_QUOTA_SNAPSHOT:-}" ] || { echo "no snapshot configured" >&2; exit 9; }
cat "$FM_FAKE_QUOTA_SNAPSHOT"
SH
  chmod +x "$fakebin/quota-axi"
}

# One provider fresh, one provider explicitly stale, one present but signed out with
# no windows. Mirrors the real quota-axi schemaVersion 2 shape.
write_snapshot() {  # <file> <claude-five-hour-used>
  local file=$1 used=$2 remaining=$((100 - $2))
  cat > "$file" <<JSON
{
  "generatedAt": "2026-07-29T00:00:00.000Z",
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "claude",
      "label": "Claude",
      "plan": "max",
      "windows": [
        {"id": "five_hour", "label": "session", "kind": "session",
         "percentUsed": $used, "percentRemaining": $remaining,
         "resetsAt": "2099-01-01T00:00:00.000Z"}
      ],
      "state": {"status": "fresh", "stale": false, "refreshedAt": "2026-07-29T00:00:00.000Z"}
    },
    {
      "provider": "cursor",
      "label": "Cursor",
      "plan": "Free",
      "windows": [
        {"id": "included_usage", "label": "included usage", "kind": "monthly",
         "percentUsed": 0, "percentRemaining": 100,
         "resetsAt": "2099-01-01T00:00:00.000Z"}
      ],
      "state": {"status": "stale", "stale": true, "refreshedAt": "2026-07-01T00:00:00.000Z",
                "error": "Cursor sign-in required"}
    },
    {
      "provider": "grok",
      "label": "Grok",
      "windows": [],
      "state": {"status": "auth_required", "stale": false, "error": "Grok sign-in required"}
    }
  ]
}
JSON
}

# A home with state/ and data/, plus a fake reader on PATH.
make_home() {  # <name> -> "<home>|<fakebin>"
  local name=$1 home fakebin
  home="$TMP_ROOT/$name/home"
  fakebin=$(fm_fakebin "$TMP_ROOT/$name/fake")
  mkdir -p "$home/state" "$home/data"
  make_fake_quota "$fakebin"
  printf '%s|%s\n' "$home" "$fakebin"
}

record() {  # <home> <fakebin> <id> <phase> [extra env assignments...]
  local home=$1 fakebin=$2 id=$3 phase=$4
  shift 4
  env "$@" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$fakebin:$PATH" "$RECORD" "$id" "$phase"
}

# Raw + compact, so a string compares bare, and null / [] / false compare literally.
ledger_field() {  # <ledger> <line-number> <jq-filter>
  sed -n "$2p" "$1" | jq -c -r "$3"
}

# --- (a) record shape and staleness fidelity --------------------------------

test_record_shape_and_stale_fidelity() {
  local home fakebin ledger
  IFS='|' read -r home fakebin <<EOF
$(make_home shape)
EOF
  write_snapshot "$TMP_ROOT/shape/snap.json" 10
  fm_write_meta "$home/state/t.meta" harness=claude model=opus effort=high kind=ship
  record "$home" "$fakebin" t spawn FM_FAKE_QUOTA_SNAPSHOT="$TMP_ROOT/shape/snap.json" \
    || fail "recorder exited non-zero on the happy path"

  ledger="$home/data/t/quota.jsonl"
  assert_present "$ledger" "no ledger was written at data/<id>/quota.jsonl"
  [ "$(wc -l <"$ledger" | tr -d ' ')" = 1 ] || fail "expected exactly one record per capture"

  [ "$(ledger_field "$ledger" 1 '.schema')" = "fm-quota-record.v1" ] || fail "wrong schema tag"
  [ "$(ledger_field "$ledger" 1 '.phase')" = spawn ] || fail "phase not recorded"
  [ "$(ledger_field "$ledger" 1 '.harness')" = claude ] || fail "harness not read from meta"
  [ "$(ledger_field "$ledger" 1 '.model')" = opus ] || fail "model not read from meta"
  [ "$(ledger_field "$ledger" 1 '.effort')" = high ] || fail "effort not read from meta"
  [ "$(ledger_field "$ledger" 1 '.kind')" = ship ] || fail "kind not read from meta"
  [ "$(ledger_field "$ledger" 1 '.capture')" = ok ] || fail "capture should be ok"
  [ "$(ledger_field "$ledger" 1 '.tool.schemaVersion')" = 2 ] || fail "reader schemaVersion not preserved"

  # The regression this suite exists for: false must survive as false.
  [ "$(ledger_field "$ledger" 1 '.providers[]|select(.provider=="claude")|.stale')" = false ] \
    || fail "a provider reporting stale=false was not recorded as false"
  [ "$(ledger_field "$ledger" 1 '.providers[]|select(.provider=="cursor")|.stale')" = true ] \
    || fail "a stale provider was not recorded as stale"
  [ "$(ledger_field "$ledger" 1 '.providers[]|select(.provider=="cursor")|.refreshedAt')" \
      = "2026-07-01T00:00:00.000Z" ] || fail "refreshedAt was not preserved"
  [ "$(ledger_field "$ledger" 1 '.providers[]|select(.provider=="cursor")|.status')" = stale ] \
    || fail "provider status was not preserved"
  pass "spawn record carries the resolved profile, the snapshot, and faithful staleness"
}

# --- (b) missing is not zero ------------------------------------------------

test_missing_is_distinguishable_from_zero() {
  local home fakebin empty
  IFS='|' read -r home fakebin <<EOF
$(make_home nullness)
EOF
  fm_write_meta "$home/state/t.meta" harness=claude kind=ship

  # Nothing read at all -> null.
  record "$home" "$fakebin" t spawn FM_QUOTA_BIN=fm-quota-absent-reader >/dev/null 2>&1
  [ "$(ledger_field "$home/data/t/quota.jsonl" 1 '.providers')" = null ] \
    || fail "an unread snapshot must record providers null, not an empty array"

  # Reader genuinely reported no providers -> [].
  empty="$TMP_ROOT/nullness/empty.json"
  printf '%s\n' '{"schemaVersion":2,"providers":[]}' > "$empty"
  record "$home" "$fakebin" t close FM_FAKE_QUOTA_SNAPSHOT="$empty" >/dev/null 2>&1
  [ "$(ledger_field "$home/data/t/quota.jsonl" 2 '.providers')" = "[]" ] \
    || fail "a reader that reported no providers must record [], not null"
  pass "no measurement records null; an empty measurement records []"
}

# --- (c) attribution --------------------------------------------------------

test_attribution_states_its_basis() {
  local home fakebin snap ledger
  IFS='|' read -r home fakebin <<EOF
$(make_home attribution)
EOF
  snap="$TMP_ROOT/attribution/snap.json"
  write_snapshot "$snap" 20

  fm_write_meta "$home/state/direct.meta" harness=claude kind=ship
  record "$home" "$fakebin" direct spawn FM_FAKE_QUOTA_SNAPSHOT="$snap" >/dev/null
  ledger="$home/data/direct/quota.jsonl"
  [ "$(ledger_field "$ledger" 1 '.attribution.provider')" = claude ] || fail "claude was not attributed"
  [ "$(ledger_field "$ledger" 1 '.attribution.basis')" = harness-identity ] || fail "wrong basis for claude"
  [ "$(ledger_field "$ledger" 1 '.attribution.scorable')" = true ] || fail "claude should be scorable"

  # Present in the snapshot but signed out: recorded as not scorable WITH the reason,
  # never omitted and never silently treated as healthy.
  fm_write_meta "$home/state/signedout.meta" harness=grok kind=ship
  record "$home" "$fakebin" signedout spawn FM_FAKE_QUOTA_SNAPSHOT="$snap" >/dev/null
  ledger="$home/data/signedout/quota.jsonl"
  [ "$(ledger_field "$ledger" 1 '.attribution.provider')" = grok ] || fail "grok was not attributed"
  [ "$(ledger_field "$ledger" 1 '.attribution.scorable')" = false ] || fail "a windowless provider is not scorable"
  assert_contains "$(ledger_field "$ledger" 1 '.attribution.reason')" "no windows" \
    "an unscorable provider must record why"

  # Model-routed harness: unresolved by design, with the full snapshot still kept so
  # the attribution can be settled later without a second capture.
  fm_write_meta "$home/state/routed.meta" harness=opencode model=anthropic/some-model kind=ship
  record "$home" "$fakebin" routed spawn FM_FAKE_QUOTA_SNAPSHOT="$snap" >/dev/null
  ledger="$home/data/routed/quota.jsonl"
  [ "$(ledger_field "$ledger" 1 '.attribution.provider')" = null ] \
    || fail "a model-routed harness must not be attributed by guess"
  [ "$(ledger_field "$ledger" 1 '.attribution.basis')" = unresolved ] || fail "wrong basis for opencode"
  [ "$(ledger_field "$ledger" 1 '.providers|length')" = 3 ] \
    || fail "an unresolved attribution must still keep the full snapshot"

  # ...unless the caller, who resolved the route, declares it.
  record "$home" "$fakebin" routed close FM_FAKE_QUOTA_SNAPSHOT="$snap" FM_QUOTA_PROVIDER=claude >/dev/null
  [ "$(ledger_field "$ledger" 2 '.attribution.provider')" = claude ] || fail "declared provider was ignored"
  [ "$(ledger_field "$ledger" 2 '.attribution.basis')" = caller-declared ] || fail "wrong basis for a declared provider"
  pass "attribution records how the provider was decided and never guesses a model-routed one"
}

# --- (d) every degradation is explicit --------------------------------------

test_every_degradation_records_itself() {
  local home fakebin ledger junk hang line n
  IFS='|' read -r home fakebin <<EOF
$(make_home degrade)
EOF
  fm_write_meta "$home/state/t.meta" harness=claude kind=ship
  ledger="$home/data/t/quota.jsonl"

  junk="$TMP_ROOT/degrade/junk"
  printf '#!/usr/bin/env bash\necho not-json\n' > "$junk"; chmod +x "$junk"
  hang="$TMP_ROOT/degrade/hang"
  printf '#!/usr/bin/env bash\nsleep 293\n' > "$hang"; chmod +x "$hang"

  record "$home" "$fakebin" t spawn FM_QUOTA_BIN=fm-quota-absent-reader >/dev/null 2>&1
  record "$home" "$fakebin" t close FM_FAKE_QUOTA_SNAPSHOT=/nonexistent/snapshot.json >/dev/null 2>&1
  record "$home" "$fakebin" t spawn FM_QUOTA_BIN="$junk" >/dev/null 2>&1
  record "$home" "$fakebin" t close FM_QUOTA_DISABLE=1 >/dev/null 2>&1
  record "$home" "$fakebin" t spawn FM_QUOTA_BIN="$hang" FM_QUOTA_TIMEOUT=1 >/dev/null 2>&1

  n=$(wc -l <"$ledger" | tr -d ' ')
  [ "$n" = 5 ] || fail "expected one record per capture attempt, got $n"
  for line in 1:unavailable 2:error 3:unusable 4:disabled 5:timeout; do
    [ "$(ledger_field "$ledger" "${line%%:*}" '.capture')" = "${line#*:}" ] \
      || fail "capture on ledger line ${line%%:*} should be ${line#*:}"
    [ "$(ledger_field "$ledger" "${line%%:*}" '.providers')" = null ] \
      || fail "a failed capture must record providers null"
    [ "$(ledger_field "$ledger" "${line%%:*}" '.reason')" != null ] \
      || fail "a failed capture must record a reason"
  done

  # The reader was still killed on time, and its children went with it: a hung
  # quota read must not leave work behind for the next hour.
  sleep 0.5
  [ "$(pgrep -f 'sleep 293' | wc -l | tr -d ' ')" = 0 ] \
    || fail "the timed-out reader orphaned a child process"
  pass "reader absent, failing, unparseable, disabled and hung each record one explicit outcome"
}

# --- (e) the capture never blocks its caller --------------------------------

test_async_returns_immediately() {
  local home fakebin hang elapsed
  IFS='|' read -r home fakebin <<EOF
$(make_home async)
EOF
  fm_write_meta "$home/state/t.meta" harness=claude kind=ship
  hang="$TMP_ROOT/async/hang"
  printf '#!/usr/bin/env bash\nsleep 291\n' > "$hang"; chmod +x "$hang"

  SECONDS=0
  env FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_QUOTA_BIN="$hang" FM_QUOTA_TIMEOUT=6 PATH="$fakebin:$PATH" \
    "$RECORD" t spawn --async >/dev/null 2>&1
  elapsed=$SECONDS
  [ "$elapsed" -le 2 ] || fail "--async waited ${elapsed}s on a hung reader; it must return at once"
  assert_absent "$home/data/t/quota.jsonl" "the async capture should still be in flight here"

  # It still lands, marked for what it was.
  sleep 8
  [ "$(ledger_field "$home/data/t/quota.jsonl" 1 '.capture')" = timeout ] \
    || fail "the detached capture did not record its own timeout"
  pass "--async returns immediately against a hung reader and still records the outcome"
}

# --- (f) the delta refuses to invent a cost ---------------------------------

# Ledger lines written by hand: this exercises the READER, so the inputs have to be
# exact rather than whatever a live capture happens to produce.
ledger_line() {  # <phase> <at> <used> <resetsAt> [capture] [stale]
  local phase=$1 at=$2 used=$3 resets=$4 capture=${5:-ok} stale=${6:-false} status=fresh
  [ "$stale" = true ] && status=stale
  if [ "$capture" != ok ]; then
    printf '{"schema":"fm-quota-record.v1","task":"t","phase":"%s","at":"%s","harness":"claude","model":null,"effort":null,"kind":"ship","capture":"%s","reason":"synthetic","attribution":{"provider":"claude","basis":"harness-identity","scorable":false,"reason":null},"tool":null,"providers":null}\n' \
      "$phase" "$at" "$capture"
    return
  fi
  printf '{"schema":"fm-quota-record.v1","task":"t","phase":"%s","at":"%s","harness":"claude","model":null,"effort":null,"kind":"ship","capture":"ok","reason":null,"attribution":{"provider":"claude","basis":"harness-identity","scorable":true,"reason":null},"tool":{"name":"quota-axi","schemaVersion":2,"generatedAt":"%s"},"providers":[{"provider":"claude","label":"Claude","plan":"max","status":"%s","stale":%s,"refreshedAt":"%s","error":null,"windows":[{"id":"five_hour","label":"session","kind":"session","percentUsed":%s,"percentRemaining":%s,"resetsAt":"%s"}]}]}\n' \
    "$phase" "$at" "$at" "$status" "$stale" "$at" "$used" "$((100 - used))" "$resets"
}

delta_json() {  # <home> <id>
  env FM_DATA_OVERRIDE="$1/data" "$DELTA" "$2" --json
}

test_delta_reports_cost_and_refuses_across_a_reset() {
  local home out
  home="$TMP_ROOT/delta/home"
  mkdir -p "$home/data/plain" "$home/data/reset" "$home/data/openended"

  # Same window throughout: an ordinary, computable cost.
  {
    ledger_line spawn 2026-07-28T22:00:00Z 10 2099-01-01T00:00:00Z
    ledger_line close 2026-07-28T23:00:00Z 34 2099-01-01T00:00:00Z
  } > "$home/data/plain/quota.jsonl"
  out=$(delta_json "$home" plain)
  [ "$(printf '%s' "$out" | jq -r '.computable')" = true ] || fail "an ordinary pair should be computable"
  [ "$(printf '%s' "$out" | jq -r '.providers[0].windows[0].cost_percent_points')" = 24 ] \
    || fail "cost should be close minus spawn in percentage points"
  [ "$(printf '%s' "$out" | jq -r '.providers[0].windows[0].remaining_at_close')" = 66 ] \
    || fail "remaining at close should be reported"

  # The overnight case: the window the task started in was due to reset before the
  # close capture, so the arithmetic difference is not a cost.
  {
    ledger_line spawn 2026-07-28T22:00:00Z 80 2026-07-29T02:00:00Z
    ledger_line close 2026-07-29T06:00:00Z 90 2026-07-29T10:00:00Z
  } > "$home/data/reset/quota.jsonl"
  out=$(delta_json "$home" reset)
  [ "$(printf '%s' "$out" | jq -r '.providers[0].windows[0].reset_crossed')" = true ] \
    || fail "a window that reset between captures was not detected"
  [ "$(printf '%s' "$out" | jq -r '.providers[0].windows[0].cost_percent_points')" = null ] \
    || fail "no cost may be reported across a window reset"
  assert_contains "$(env FM_DATA_OVERRIDE="$home/data" "$DELTA" reset)" "window reset between captures" \
    "the rendered report must say why there is no cost"

  # Sub-second jitter in resetsAt between two reads of the SAME window must not be
  # mistaken for a reset.
  {
    ledger_line spawn 2026-07-28T22:00:00Z 10 "2026-07-29T07:29:59.146659+00:00"
    ledger_line close 2026-07-28T22:05:00Z 12 "2026-07-29T07:30:00.415204+00:00"
  } > "$home/data/openended/quota.jsonl"
  out=$(delta_json "$home" openended)
  [ "$(printf '%s' "$out" | jq -r '.providers[0].windows[0].reset_crossed')" = false ] \
    || fail "resetsAt jitter was misread as a window reset"
  [ "$(printf '%s' "$out" | jq -r '.providers[0].windows[0].cost_percent_points')" = 2 ] \
    || fail "cost across a jittering resetsAt was not computed"
  pass "delta reports a real cost and refuses to report one across a window reset"
}

test_delta_names_a_missing_or_failed_capture() {
  local home out
  home="$TMP_ROOT/delta-missing/home"
  mkdir -p "$home/data/noclose" "$home/data/badspawn"

  ledger_line spawn 2026-07-28T22:00:00Z 10 2099-01-01T00:00:00Z > "$home/data/noclose/quota.jsonl"
  out=$(env FM_DATA_OVERRIDE="$home/data" "$DELTA" noclose)
  assert_contains "$out" "close MISSING" "a missing close must be named"
  assert_contains "$out" "NOT COMPUTABLE" "a missing close must not yield a cost"

  {
    ledger_line spawn 2026-07-28T22:00:00Z 0 2099-01-01T00:00:00Z timeout
    ledger_line close 2026-07-28T23:00:00Z 34 2099-01-01T00:00:00Z
  } > "$home/data/badspawn/quota.jsonl"
  out=$(env FM_DATA_OVERRIDE="$home/data" "$DELTA" badspawn)
  assert_contains "$out" "capture=timeout" "a failed capture must be shown"
  assert_contains "$out" "NOT COMPUTABLE" "a failed spawn capture must not yield a cost"

  env FM_DATA_OVERRIDE="$home/data" "$DELTA" never-existed >/dev/null 2>&1 \
    && fail "a task with no ledger should exit non-zero"

  # A cost derived from a cached reading must carry that fact on the row itself, not
  # only in the provider header a scanning reader can miss. This is the shape a real
  # close capture takes when the provider rate-limits the quota endpoint.
  mkdir -p "$home/data/stalelose"
  {
    ledger_line spawn 2026-07-28T22:00:00Z 16 2099-01-01T00:00:00Z ok false
    ledger_line close 2026-07-28T23:00:00Z 16 2099-01-01T00:00:00Z ok true
  } > "$home/data/stalelose/quota.jsonl"
  out=$(env FM_DATA_OVERRIDE="$home/data" "$DELTA" stalelose)
  assert_contains "$out" "close reading stale" "a stale close reading must be marked on the window row"
  [ "$(env FM_DATA_OVERRIDE="$home/data" "$DELTA" stalelose --json \
      | jq -r '.providers[0].close_stale')" = true ] || fail "close staleness lost in the analysis"
  pass "a missing or failed capture is reported as such, never as a zero cost"
}

# --- (g) end to end over the real spawn and teardown ------------------------

make_lifecycle_fakebin() {  # <dir> -> fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  make_fake_quota "$fakebin"
  printf '%s\n' "$fakebin"
}

test_spawn_and_teardown_capture_end_to_end() {
  local case_dir home proj wt fakebin id ledger out
  case_dir="$TMP_ROOT/lifecycle"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="quota-e2e-x1"
  fakebin=$(make_lifecycle_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  write_snapshot "$case_dir/spawn.json" 40
  write_snapshot "$case_dir/close.json" 57

  # FM_QUOTA_SYNC makes the spawn side's detached capture deterministic here; the
  # detach itself is covered by test_async_returns_immediately.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_QUOTA_SYNC=1 FM_FAKE_QUOTA_SNAPSHOT="$case_dir/spawn.json" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" claude >/dev/null 2>&1 \
    || fail "spawn failed"

  ledger="$home/data/$id/quota.jsonl"
  assert_present "$ledger" "the real spawn did not write a quota record"
  [ "$(ledger_field "$ledger" 1 '.phase')" = spawn ] || fail "spawn record has the wrong phase"
  [ "$(ledger_field "$ledger" 1 '.harness')" = claude ] || fail "spawn record lost the resolved harness"
  [ "$(ledger_field "$ledger" 1 '.providers[]|select(.provider=="claude")|.windows[0].percentUsed')" = 40 ] \
    || fail "spawn record did not capture the spawn-time reading"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_QUOTA_SNAPSHOT="$case_dir/close.json" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "teardown failed"

  # The ledger is under data/, so it must outlive the cleanup that clears state/.
  assert_absent "$home/state/$id.meta" "teardown did not clear the task state"
  assert_present "$ledger" "the quota ledger did not survive teardown"
  [ "$(ledger_field "$ledger" 2 '.phase')" = close ] || fail "teardown did not write a close record"
  [ "$(ledger_field "$ledger" 2 '.harness')" = claude ] \
    || fail "close record lost the harness (meta must be read before it is removed)"

  out=$(env FM_DATA_OVERRIDE="$home/data" "$DELTA" "$id" --json)
  [ "$(printf '%s' "$out" | jq -r '.computable')" = true ] || fail "the spawn/close pair is not computable"
  [ "$(printf '%s' "$out" | jq -r '.providers[]|select(.provider=="claude")|.windows[0].cost_percent_points')" = 17 ] \
    || fail "the cost of the real lifecycle was not 57-40 percentage points"
  pass "a real spawn and a real cleanup produce a readable cost"
}

test_record_shape_and_stale_fidelity
test_missing_is_distinguishable_from_zero
test_attribution_states_its_basis
test_every_degradation_records_itself
test_async_returns_immediately
test_delta_reports_cost_and_refuses_across_a_reset
test_delta_names_a_missing_or_failed_capture
test_spawn_and_teardown_capture_end_to_end
