#!/usr/bin/env bash
# Behavioral regressions for guarded captain-backlog churn closure.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHURN="${FM_CAPTAIN_CHURN_UNDER_TEST:-$ROOT/bin/fm-captain-churn.sh}"
DECISIONS="$ROOT/bin/fm-decision-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-churn)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local task_home="$TMP_ROOT/$1"
  mkdir -p "$task_home/data" "$task_home/state" "$task_home/config"
  cp "$ROOT/.tasks.toml" "$task_home/.tasks.toml"
  cat > "$task_home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$task_home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local task_home=$1
  shift
  (cd "$task_home" && tasks-axi "$@")
}

run_churn() {  # <home> <command args...>
  local task_home=$1
  shift
  PATH="$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$task_home" FM_DATA_OVERRIDE="$task_home/data" \
    FM_STATE_OVERRIDE="$task_home/state" "$CHURN" "$@"
}

run_decisions() {  # <home> <command args...>
  local task_home=$1
  shift
  PATH="$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$task_home" FM_DATA_OVERRIDE="$task_home/data" \
    FM_STATE_OVERRIDE="$task_home/state" "$DECISIONS" "$@"
}

write_origin_meta() {  # <home> <origin-id>
  local task_home=$1 origin=$2
  printf 'kind=scout\n' > "$task_home/state/$origin.meta"
}

assert_queued() {  # <home> <id> <message>
  local task_home=$1 id=$2 message=$3 show
  show=$(tasks_in "$task_home" show "$id" --full) || fail "$message: task is absent"
  assert_contains "$show" "state: queued" "$message"
}

assert_done() {  # <home> <id> <message>
  local task_home=$1 id=$2 message=$3 show
  show=$(tasks_in "$task_home" show "$id" --full) || fail "$message: task is absent"
  assert_contains "$show" "state: done" "$message"
}

test_plain_captain_rows_refuse_provenance_independent_close() {
  local task_home id rc
  task_home=$(make_home plain-captain)
  id=sample-clinical-safety
  tasks_in "$task_home" add "$id" "Choose whether sample distribution stays blocked" \
    --kind captain --repo sample >/dev/null || fail "could not create plain captain fixture"

  set +e
  run_churn "$task_home" close "$id" --class already-answered \
    --citation data/sample-ruling.md > "$task_home/out" 2> "$task_home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "plain kind-captain row bypassed the liveness refusal"
  assert_grep "REFUSED: backlog item $id carries a live captain choice" "$task_home/err" \
    "plain kind-captain refusal was not explicit"
  assert_queued "$task_home" "$id" "refused plain captain row was closed"
  pass "plain captain rows reach the provenance-independent liveness refusal"
}

test_self_certified_non_question_refuses() {
  local task_home id rc
  task_home=$(make_home self-certifying)
  id=sample-clinical-self-declared
  tasks_in "$task_home" add "$id" "Choose whether sample distribution stays blocked" \
    --kind captain --repo sample >/dev/null || fail "could not create self-certifying fixture"

  set +e
  run_churn "$task_home" close "$id" --class non-question \
    --subclass self-declared-disclosure > "$task_home/out" 2> "$task_home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "self-certified non-question closed a live captain row"
  assert_grep "REFUSED: backlog item $id carries a live captain choice" "$task_home/err" \
    "self-certifying prohibition did not fire"
  assert_queued "$task_home" "$id" "self-certified captain row was closed"
  pass "self-certified non-question input fires the liveness refusal"
}

test_decision_shaped_rows_refuse_the_same_way() {
  local task_home id rc
  task_home=$(make_home decision-shaped)
  write_origin_meta "$task_home" sample-review
  id=$(run_decisions "$task_home" hold sample-review route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not create decision-shaped captain fixture"

  set +e
  run_churn "$task_home" close "$id" --class already-answered \
    --citation "data/sample-ruling.md" > "$task_home/out" 2> "$task_home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "machine-minted captain row bypassed the liveness refusal"
  assert_grep "REFUSED: backlog item $id carries a live captain choice" "$task_home/err" \
    "decision-shaped refusal was not explicit"
  assert_queued "$task_home" "$id" "refused decision-shaped row was closed"
  pass "plain and decision-shaped captain rows share one liveness refusal"
}

test_live_inventory_refuses_non_captain_pointer() {
  local task_home id rc
  task_home=$(make_home live-inventory)
  id=sample-review-decision-pointer
  tasks_in "$task_home" add "$id" "Pointer to the sample route decision" \
    --kind docs --repo sample >/dev/null || fail "could not create pointer fixture"
  printf 'kind=scout\n' > "$task_home/state/sample-review.meta"

  set +e
  run_churn "$task_home" close "$id" --class non-question --subclass pointer \
    > "$task_home/out" 2> "$task_home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "row bound to a live decision inventory was closed"
  assert_grep "REFUSED: backlog item $id is bound to live decision inventory sample-review" "$task_home/err" \
    "live-inventory refusal was not explicit"
  assert_queued "$task_home" "$id" "refused live-inventory row was closed"
  pass "live decision inventories still refuse non-captain pointer churn"
}

test_proof_bearing_duplicate_origin_closes() {
  local task_home retired survivor survivor_body
  task_home=$(make_home duplicate-close)
  write_origin_meta "$task_home" sample-review-r2
  write_origin_meta "$task_home" sample-review-r3
  retired=$(run_decisions "$task_home" hold sample-review-r2 route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not create retired duplicate fixture"
  survivor=$(run_decisions "$task_home" hold sample-review-r3 route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not create survivor fixture"
  survivor_body=$(printf 'Origin: sample-review-r3\nDecision key: route\nState: awaiting captain decision.\n\nAbsorbed duplicate origin: %s.\n' "$retired")
  tasks_in "$task_home" update "$survivor" --body "$survivor_body" --archive-body >/dev/null \
    || fail "could not add retired origin to survivor body"

  run_churn "$task_home" close "$retired" --class duplicate-origin --survivor "$survivor" \
    --decision-key route \
    > "$task_home/out" 2> "$task_home/err" \
    || fail "proof-bearing duplicate origin did not close: $(cat "$task_home/err")"
  assert_done "$task_home" "$retired" "duplicate origin remained open"
  assert_queued "$task_home" "$survivor" "duplicate close also closed the survivor"
  assert_grep "Duplicate origin of the live question carried by $survivor" \
    "$task_home/data/backlog.md" "duplicate close did not leave its survivor trace"
  pass "proof-bearing duplicate origin closes while its survivor stays open"
}

test_duplicate_without_survivor_trace_refuses() {
  local task_home retired survivor rc
  task_home=$(make_home duplicate-refuse)
  write_origin_meta "$task_home" sample-review-r4
  write_origin_meta "$task_home" sample-review-r5
  retired=$(run_decisions "$task_home" hold sample-review-r4 route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not create untraced duplicate fixture"
  survivor=$(run_decisions "$task_home" hold sample-review-r5 route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not create untraced survivor fixture"

  set +e
  run_churn "$task_home" close "$retired" --class duplicate-origin --survivor "$survivor" \
    --decision-key route \
    > "$task_home/out" 2> "$task_home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate closed before the survivor preserved its origin"
  assert_grep "REFUSED: survivor $survivor does not preserve retired origin $retired" "$task_home/err" \
    "missing survivor trace refusal was not explicit"
  assert_queued "$task_home" "$retired" "untraced duplicate was closed"
  assert_queued "$task_home" "$survivor" "untraced survivor was closed"
  pass "duplicate carve-out refuses until the survivor preserves the retired origin"
}

test_duplicate_with_different_key_refuses() {
  local task_home retired survivor survivor_body rc
  task_home=$(make_home duplicate-key-refuse)
  write_origin_meta "$task_home" sample-review-r6
  write_origin_meta "$task_home" sample-review-r7
  retired=$(run_decisions "$task_home" hold sample-review-r6 route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not create key-mismatch duplicate fixture"
  survivor=$(run_decisions "$task_home" hold sample-review-r7 access \
    --title "Choose the sample access" --reason "captain access choice pending" --repo sample) \
    || fail "could not create key-mismatch survivor fixture"
  survivor_body=$(printf 'Origin: sample-review-r7\nDecision key: access\nState: awaiting captain decision.\n\nAbsorbed duplicate origin: %s.\n' "$retired")
  tasks_in "$task_home" update "$survivor" --body "$survivor_body" --archive-body >/dev/null \
    || fail "could not add key-mismatched origin to survivor body"

  set +e
  run_churn "$task_home" close "$retired" --class duplicate-origin --survivor "$survivor" \
    --decision-key route > "$task_home/out" 2> "$task_home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "different decision keys were collapsed as duplicates"
  assert_grep "REFUSED: survivor $survivor does not carry decision key route" "$task_home/err" \
    "different-key refusal was not explicit"
  assert_queued "$task_home" "$retired" "different-key origin was closed"
  assert_queued "$task_home" "$survivor" "different-key survivor was closed"
  pass "duplicate carve-out refuses rows with different decision keys"
}

test_non_captain_pointer_closes() {
  local task_home id
  task_home=$(make_home pointer-close)
  id=sample-pointer
  tasks_in "$task_home" add "$id" "Pointer to the durable sample ruling" \
    --kind docs --repo sample >/dev/null || fail "could not create closable pointer fixture"

  run_churn "$task_home" close "$id" --class non-question --subclass pointer \
    > "$task_home/out" 2> "$task_home/err" \
    || fail "legitimate non-captain pointer did not close: $(cat "$task_home/err")"
  assert_done "$task_home" "$id" "legitimate non-captain pointer remained open"
  pass "legitimate non-captain pointer churn still closes"
}

case "${FM_CAPTAIN_CHURN_TEST_CASE:-all}" in
  n1)
    test_plain_captain_rows_refuse_provenance_independent_close
    ;;
  n2)
    test_proof_bearing_duplicate_origin_closes
    test_duplicate_without_survivor_trace_refuses
    test_duplicate_with_different_key_refuses
    ;;
  f2)
    test_self_certified_non_question_refuses
    ;;
  all)
    test_plain_captain_rows_refuse_provenance_independent_close
    test_self_certified_non_question_refuses
    test_decision_shaped_rows_refuse_the_same_way
    test_live_inventory_refuses_non_captain_pointer
    test_proof_bearing_duplicate_origin_closes
    test_duplicate_without_survivor_trace_refuses
    test_duplicate_with_different_key_refuses
    test_non_captain_pointer_closes
    ;;
  *)
    fail "unknown FM_CAPTAIN_CHURN_TEST_CASE: $FM_CAPTAIN_CHURN_TEST_CASE"
    ;;
esac
