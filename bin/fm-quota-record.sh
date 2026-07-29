#!/usr/bin/env bash
# fm-quota-record.sh - capture one provider quota record for a task lifecycle moment.
#
# Firstmate can say a night's work happened but not what it cost in subscription
# quota. This script is the capture half of that instrument: it appends exactly one
# JSON record per lifecycle phase to the task's durable quota ledger, so a spawn/close
# pair yields a computable delta. bin/fm-quota-delta.sh is the read half.
#
# Usage:
#   fm-quota-record.sh <task-id> <spawn|close> [--async]
#   fm-quota-record.sh --help
#
# LEDGER
#   data/<task-id>/quota.jsonl, one JSON object per line, appended never rewritten.
#   It lives under data/ (not state/) deliberately: bin/fm-teardown.sh clears
#   state/<id>.* at cleanup, and a cost record the captain reads in the morning must
#   outlive the task exactly like data/<id>/report.md does.
#
# RECORD SCHEMA  (schema: "fm-quota-record.v1")
#   task        task id
#   phase       spawn | close
#   at          capture time, ISO 8601 UTC
#   harness     )
#   model       ) verbatim from state/<task-id>.meta at capture time; null when the
#   effort      ) meta file is absent or omits the field. Never inferred.
#   kind        )
#   capture     ok        - the reader ran and returned usable JSON
#               disabled  - FM_QUOTA_DISABLE=1; no external call was made
#               unavailable - the reader or jq is not installed
#               timeout   - the reader exceeded FM_QUOTA_TIMEOUT and was killed
#               error     - the reader exited non-zero
#               unusable  - the reader returned output that is not usable JSON
#   reason      human-readable detail for every non-ok capture, else null
#   attribution which provider this spawn is scored against (see ATTRIBUTION)
#   tool        {name, schemaVersion, generatedAt} of the snapshot, else null
#   providers   condensed per-provider records, else NULL
#
#   providers is null when nothing was read and [] only when the reader genuinely
#   reported no providers. A missing record is therefore never confused with a zero.
#   Each provider keeps status, stale, refreshedAt and error from quota-axi's own
#   state block, so a stale number can never be read as a fresh one.
#
# ATTRIBUTION
#   attribution.basis records HOW the provider was decided, never a silent guess:
#     caller-declared  - FM_QUOTA_PROVIDER named it; firstmate resolved the route
#                        and is the only component authorized to do so.
#     harness-identity - the harness name is itself a quota-axi provider id
#                        (claude, codex, grok). This is a name identity between two
#                        surfaces, not a namespace mapping.
#     unresolved       - everything else, with attribution.provider null and a reason.
#   opencode, pi, pi-signed and kimi route by model, and .agents/skills/harness-adapters
#   requires provider identity to come from live discovery rather than a static
#   prefix table, so this script refuses to invent one. It records the unresolved
#   fact and keeps the full providers array, so the attribution can be settled later
#   from the record itself without a second capture.
#   attribution.scorable is true only when the attributed provider is present in the
#   snapshot AND reports at least one window. A provider that is present but signed
#   out (grok with status auth_required and no windows) records scorable false with
#   the reason, rather than omitting the field.
#
# NEVER BLOCKS THE CALLER
#   --async re-runs this script detached and returns immediately, so bin/fm-spawn.sh
#   never waits on a quota read. Even synchronously the reader is bounded by
#   FM_QUOTA_TIMEOUT and killed past it, so a hung reader cannot wedge a caller;
#   the ledger still gets its record, marked capture=timeout. This script exits 0 on
#   every capture outcome - a failed measurement must never fail a spawn or a
#   cleanup - and only argument errors exit non-zero.
#
# ENVIRONMENT
#   FM_QUOTA_TIMEOUT   seconds allowed for the reader (default 8)
#   FM_QUOTA_BIN       reader command (default quota-axi)
#   FM_QUOTA_PROVIDER  caller-declared provider attribution
#   FM_QUOTA_DISABLE   1 = record a disabled marker, make no external call
#   FM_QUOTA_SYNC      1 = run --async synchronously (deterministic tests)
#   FM_HOME / FM_STATE_OVERRIDE / FM_DATA_OVERRIDE   standard home resolution
#
# set -u, deliberately not set -e: a half-run recorder that leaves no record is
# worse than one that records its own failure, so every step handles its own status.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-quota-record.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

QUOTA_BIN=${FM_QUOTA_BIN:-quota-axi}
QUOTA_TIMEOUT=${FM_QUOTA_TIMEOUT:-8}

usage() {
  sed -n '2,75p' "$SELF" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

TASK=${1:-}
PHASE=${2:-}
ASYNC=0
[ "${3:-}" = "--async" ] && ASYNC=1

if [ -z "$TASK" ] || [ -z "$PHASE" ]; then
  echo "usage: fm-quota-record.sh <task-id> <spawn|close> [--async]" >&2
  exit 2
fi
case "$PHASE" in
  spawn|close) : ;;
  *)
    echo "fm-quota-record.sh: phase must be spawn or close, got '$PHASE'" >&2
    exit 2
    ;;
esac
# The id becomes a directory path under data/, so it is validated with the shared
# path-safety predicate rather than trusted from the caller or re-implemented here.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
fm_task_id_path_safe "$TASK" || {
  echo "fm-quota-record.sh: unsafe task id '$TASK'" >&2
  exit 2
}

# Detach and return immediately. The child runs the same code path with --async
# dropped, so there is exactly one capture implementation.
if [ "$ASYNC" = 1 ] && [ "${FM_QUOTA_SYNC:-0}" != 1 ]; then
  ( "$SELF" "$TASK" "$PHASE" </dev/null >/dev/null 2>&1 & )
  exit 0
fi

LEDGER_DIR="$DATA/$TASK"
LEDGER="$LEDGER_DIR/quota.jsonl"
AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META="$STATE/$TASK.meta"

meta_field() {  # <key> -> value, empty when meta or key is absent
  [ -f "$META" ] || return 0
  grep "^$1=" "$META" 2>/dev/null | head -1 | cut -d= -f2- || true
}

HARNESS=$(meta_field harness)
MODEL=$(meta_field model)
EFFORT=$(meta_field effort)
KIND=$(meta_field kind)

# Attribution decided before any read, so a failed read still records what the
# capture was meant to score.
ATTR_PROVIDER=${FM_QUOTA_PROVIDER:-}
ATTR_REASON=
if [ -n "$ATTR_PROVIDER" ]; then
  ATTR_BASIS=caller-declared
else
  case "$HARNESS" in
    claude|codex|grok)
      ATTR_PROVIDER=$HARNESS
      ATTR_BASIS=harness-identity
      ;;
    "")
      ATTR_BASIS=unresolved
      ATTR_REASON="no harness recorded for this task"
      ;;
    *)
      ATTR_BASIS=unresolved
      ATTR_REASON="harness $HARNESS routes by model; provider identity is discovery-time (harness-adapters), so it is not inferred here"
      ;;
  esac
fi

# Minimal, correct-by-construction record for the case where jq is unavailable and
# no JSON builder can be trusted. Values are restricted to a conservative character
# class first, so the emitted line is always valid JSON.
json_safe() {  # <string> -> sanitized scalar
  printf '%s' "$1" | tr -c 'A-Za-z0-9 ._:/+-' '?'
}

json_scalar_or_null() {  # <string> -> "quoted" or null
  if [ -z "$1" ]; then
    printf 'null'
  else
    printf '"%s"' "$(json_safe "$1")"
  fi
}

append_line() {  # <json-line>
  mkdir -p "$LEDGER_DIR" 2>/dev/null || {
    echo "fm-quota-record.sh: cannot create ledger directory $LEDGER_DIR" >&2
    return 1
  }
  printf '%s\n' "$1" >> "$LEDGER" || {
    echo "fm-quota-record.sh: cannot append to ledger $LEDGER" >&2
    return 1
  }
  return 0
}

emit_fallback() {  # <capture> <reason>
  local line
  line=$(printf '{"schema":"fm-quota-record.v1","task":%s,"phase":%s,"at":%s,"harness":%s,"model":%s,"effort":%s,"kind":%s,"capture":%s,"reason":%s,"attribution":{"provider":%s,"basis":%s,"scorable":false,"reason":%s},"tool":null,"providers":null}' \
    "$(json_scalar_or_null "$TASK")" \
    "$(json_scalar_or_null "$PHASE")" \
    "$(json_scalar_or_null "$AT")" \
    "$(json_scalar_or_null "$HARNESS")" \
    "$(json_scalar_or_null "$MODEL")" \
    "$(json_scalar_or_null "$EFFORT")" \
    "$(json_scalar_or_null "$KIND")" \
    "$(json_scalar_or_null "$1")" \
    "$(json_scalar_or_null "$2")" \
    "$(json_scalar_or_null "$ATTR_PROVIDER")" \
    "$(json_scalar_or_null "$ATTR_BASIS")" \
    "$(json_scalar_or_null "$ATTR_REASON")")
  append_line "$line"
}

# jq builds the ok-record from the raw snapshot so escaping and nesting are the
# JSON tool's problem, never this shell's.
emit_from_snapshot() {  # <snapshot-file>
  local line
  line=$(jq -c -S \
    --arg task "$TASK" --arg phase "$PHASE" --arg at "$AT" \
    --arg harness "$HARNESS" --arg model "$MODEL" --arg effort "$EFFORT" --arg kind "$KIND" \
    --arg tool "$QUOTA_BIN" \
    --arg attrProvider "$ATTR_PROVIDER" --arg attrBasis "$ATTR_BASIS" --arg attrReason "$ATTR_REASON" \
    '
    def nz: if . == "" then null else . end;
    (($attrProvider | nz)) as $ap
    | ([.providers[]? | select(.provider == $ap)] | first) as $apRec
    | ($apRec.windows // []) as $apWindows
    | {
        schema: "fm-quota-record.v1",
        task: $task,
        phase: $phase,
        at: $at,
        harness: ($harness | nz),
        model: ($model | nz),
        effort: ($effort | nz),
        kind: ($kind | nz),
        capture: "ok",
        reason: null,
        attribution: {
          provider: $ap,
          basis: $attrBasis,
          scorable: ($ap != null and $apRec != null and ($apWindows | length) > 0),
          reason: (
            if $ap == null then ($attrReason | nz)
            elif $apRec == null then "provider \($ap) is not present in this snapshot"
            elif ($apWindows | length) == 0 then "provider \($ap) reported no windows (status \($apRec.state.status // "unknown"))"
            else null end
          )
        },
        tool: {
          name: $tool,
          schemaVersion: (.schemaVersion // null),
          generatedAt: (.generatedAt // null)
        },
        providers: [
          .providers[]? | {
            provider: .provider,
            label: (.label // null),
            plan: (.plan // null),
            status: (.state.status // null),
            # `//` falls through on false as well as null, which would record a
            # provider that reported "stale": false as unknown. Staleness is the one
            # field this instrument must never blur, so read it by presence.
            stale: (if (.state | type) == "object" and (.state | has("stale")) then .state.stale else null end),
            refreshedAt: (.state.refreshedAt // null),
            error: (.state.error // null),
            windows: [
              .windows[]? | {
                id: .id,
                label: (.label // null),
                kind: (.kind // null),
                percentUsed: (.percentUsed // null),
                percentRemaining: (.percentRemaining // null),
                resetsAt: (.resetsAt // null)
              }
            ]
          }
        ]
      }' "$1" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  append_line "$line"
}

if [ "${FM_QUOTA_DISABLE:-0}" = 1 ]; then
  emit_fallback disabled "quota capture disabled by FM_QUOTA_DISABLE"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  emit_fallback unavailable "jq is not installed, so no quota snapshot can be parsed"
  exit 0
fi

if ! command -v "$QUOTA_BIN" >/dev/null 2>&1; then
  emit_fallback unavailable "$QUOTA_BIN is not installed"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota.XXXXXX") || {
  echo "fm-quota-record.sh: cannot create a temp dir" >&2
  exit 0
}
trap 'rm -rf "$TMP"' EXIT

# Bounded read. This is deliberately NOT bin/fm-watch.sh's run_check_process: that
# runner owns the watcher's process-group and exec-replacement contract for
# hash-validated custom checks, and widening it for an instrumenter would put a
# safety boundary at risk for no gain. This one only has to stop waiting.
#
# `set -m` is what makes the timeout complete rather than cosmetic: without job
# control the reader shares this shell's process group, so killing $QPID leaves its
# own children (a reader that shells out, an HTTP client mid-request) running
# forever. With job control the reader is its own group leader and `kill -- -$QPID`
# takes the whole tree. macOS has no setsid, and this is the portable equivalent.
#
# The whole bounded read runs inside one stderr-silenced group. Job control makes
# bash announce the killed job ("Terminated: 15") on the shell's own stderr, and a
# successful timeout is not something to shout at the caller about: the outcome is
# reported through the ledger record instead. The group runs in this shell, so
# `wait` still reaps and TIMED_OUT/QRC survive it.
TIMED_OUT=0
QRC=0
{
  set -m
  "$QUOTA_BIN" --json >"$TMP/out" 2>"$TMP/err" &
  QPID=$!
  set +m
  WAITED=0
  DEADLINE=$((QUOTA_TIMEOUT * 10))
  while kill -0 "$QPID" 2>/dev/null; do
    if [ "$WAITED" -ge "$DEADLINE" ]; then
      TIMED_OUT=1
      kill -TERM -- -"$QPID" 2>/dev/null || kill -TERM "$QPID" 2>/dev/null
      sleep 0.2
      kill -KILL -- -"$QPID" 2>/dev/null || kill -KILL "$QPID" 2>/dev/null
      break
    fi
    sleep 0.1
    WAITED=$((WAITED + 1))
  done
  wait "$QPID" || QRC=$?
} 2>/dev/null

if [ "$TIMED_OUT" = 1 ]; then
  emit_fallback timeout "$QUOTA_BIN did not finish within ${QUOTA_TIMEOUT}s and was killed"
  exit 0
fi
if [ "$QRC" != 0 ]; then
  emit_fallback error "$QUOTA_BIN exited $QRC: $(head -c 200 "$TMP/err" 2>/dev/null | tr '\n' ' ')"
  exit 0
fi
if ! jq -e 'type == "object"' "$TMP/out" >/dev/null 2>&1; then
  emit_fallback unusable "$QUOTA_BIN did not return a JSON object"
  exit 0
fi
if ! emit_from_snapshot "$TMP/out"; then
  emit_fallback unusable "$QUOTA_BIN returned JSON this schema could not condense"
  exit 0
fi
exit 0
