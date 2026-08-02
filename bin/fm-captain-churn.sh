#!/usr/bin/env bash
# fm-captain-churn.sh - guarded closure for genuine captain-backlog churn.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This command is the required
# mutation path for captain-backlog churn so the policy has a behavioral input
# and cannot be satisfied by an agent's prose classification alone.
#
# Usage:
#   fm-captain-churn.sh close <id> --class already-answered \
#     --citation <durable-ruling-reference>
#   fm-captain-churn.sh close <id> --class non-question \
#     --subclass <pointer|self-declared-disclosure|ruling-record|aggregate-duplicate|overtaken-by-code> \
#     [--citation <shipped-commit>]
#   fm-captain-churn.sh close <id> --class duplicate-origin \
#     --survivor <id> --decision-key <key>
#
# Every target must be an open queued task. A kind-captain target is treated as
# a live captain choice regardless of whether tasks-axi hold or
# fm-decision-hold.sh minted it. A non-captain row bound to a live origin
# decision inventory is also refused. The sole kind-captain exception is a
# duplicate origin whose open kind-captain survivor has the same decision-key
# identity and already preserves the retired identity in its body. The command
# records the evidence in the close note and never prunes during the mutation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-churn: %s\n' "$*" >&2
  exit 1
}

refuse() {
  printf 'fm-captain-churn: REFUSED: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_backlog_backend_manual "$FM_HOME/config" \
    && fail "backlog backend is manual; refusing churn mutation without the guarded tasks-axi path"
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi "done" --help 2>&1 | grep -F -- '--no-prune' >/dev/null \
    || fail "tasks-axi does not expose non-pruning closure"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

require_open_task() {  # <id> [show-output]
  local id=$1 show=${2:-} state
  [ -n "$show" ] || show=$(task_show "$id") || fail "backlog item $id is absent"
  state=$(show_field "$show" state)
  [ "$state" = queued ] || refuse "backlog item $id is not open (state=$state)"
}

live_inventory_origin() {  # <id>
  local id=$1 origin
  case "$id" in
    *-decision-*) origin=${id%%-decision-*} ;;
    *) return 1 ;;
  esac
  [ -f "$STATE/$origin.meta" ] || return 1
  printf '%s\n' "$origin"
}

close_with_note() {  # <id> <note>
  tasks_axi "done" "$1" --note "$2" --no-prune >/dev/null \
    || fail "tasks-axi could not close $1"
}

close_duplicate() {  # <id> <show> <survivor> <decision-key>
  local id=$1 show=$2 survivor=$3 decision_key=$4 survivor_show kind survivor_kind survivor_body
  validate_slug survivor "$survivor"
  validate_slug decision-key "$decision_key"
  [ "$id" != "$survivor" ] || refuse "duplicate origin cannot survive itself"
  case "$id" in
    *-decision-"$decision_key") : ;;
    *) refuse "retired origin $id does not carry decision key $decision_key" ;;
  esac
  case "$survivor" in
    *-decision-"$decision_key") : ;;
    *) refuse "survivor $survivor does not carry decision key $decision_key" ;;
  esac

  survivor_show=$(task_show "$survivor") || refuse "survivor $survivor is absent"
  require_open_task "$survivor" "$survivor_show"
  kind=$(show_field "$show" kind)
  survivor_kind=$(show_field "$survivor_show" kind)
  [ "$kind" = captain ] || refuse "duplicate origin $id is not kind captain"
  [ "$survivor_kind" = captain ] || refuse "survivor $survivor is not kind captain"
  survivor_body=$(show_field "$survivor_show" body)
  case "$survivor_body" in
    *"Absorbed duplicate origin: $id."*) : ;;
    *) refuse "survivor $survivor does not preserve retired origin $id" ;;
  esac

  close_with_note "$id" \
    "Duplicate origin of the live question carried by $survivor. Its origin identity is preserved in that survivor's body. Decision key: $decision_key."
}

main() {
  local command=${1:-} id=${2:-} class='' subclass='' citation='' survivor='' decision_key=''
  local show kind inventory_origin note
  case "$command" in
    -h|--help) usage; exit 0 ;;
  esac
  [ "$command" = close ] || { usage >&2; exit 2; }
  validate_slug id "$id"
  shift 2

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --class) [ "$#" -ge 2 ] || fail "--class requires a value"; class=$2; shift 2 ;;
      --subclass) [ "$#" -ge 2 ] || fail "--subclass requires a value"; subclass=$2; shift 2 ;;
      --citation) [ "$#" -ge 2 ] || fail "--citation requires a value"; citation=$2; shift 2 ;;
      --survivor) [ "$#" -ge 2 ] || fail "--survivor requires a value"; survivor=$2; shift 2 ;;
      --decision-key) [ "$#" -ge 2 ] || fail "--decision-key requires a value"; decision_key=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown argument: $1" ;;
    esac
  done

  require_tasks_axi
  show=$(task_show "$id") || fail "backlog item $id is absent"
  require_open_task "$id" "$show"

  if [ "$class" = duplicate-origin ]; then
    [ -n "$survivor" ] || fail "duplicate-origin requires --survivor"
    [ -n "$decision_key" ] || fail "duplicate-origin requires --decision-key"
    close_duplicate "$id" "$show" "$survivor" "$decision_key"
    return 0
  fi

  kind=$(show_field "$show" kind)
  [ "$kind" != captain ] || refuse "backlog item $id carries a live captain choice"
  if inventory_origin=$(live_inventory_origin "$id"); then
    refuse "backlog item $id is bound to live decision inventory $inventory_origin"
  fi

  case "$class" in
    already-answered)
      validate_one_line citation "$citation"
      note="Already answered; durable captain ruling: $citation."
      ;;
    non-question)
      case "$subclass" in
        pointer|self-declared-disclosure|ruling-record|aggregate-duplicate) : ;;
        overtaken-by-code)
          validate_one_line citation "$citation"
          ;;
        *) fail "non-question requires a supported --subclass" ;;
      esac
      note="Not a question; classification: $subclass."
      [ -z "$citation" ] || note="$note Durable reference: $citation."
      ;;
    '') fail "--class is required" ;;
    *) fail "unsupported churn class: $class" ;;
  esac

  close_with_note "$id" "$note"
}

main "$@"
