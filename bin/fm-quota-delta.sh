#!/usr/bin/env bash
# fm-quota-delta.sh - read what a task cost in subscription quota.
#
# The read half of the quota instrument. bin/fm-quota-record.sh appends one record
# at spawn and one at close to data/<task-id>/quota.jsonl; this script pairs them and
# reports, per window, how much of which provider's quota the task consumed and how
# much was left. It only reads: it never captures, repairs, or rewrites a ledger.
#
# Usage:
#   fm-quota-delta.sh <task-id> [--all] [--json]
#   fm-quota-delta.sh --fleet [--json]
#   fm-quota-delta.sh --help
#
#   --all    report every provider in the snapshot, not only the attributed one
#   --json   emit the analysis object instead of the rendered report
#   --fleet  report every task under data/ that has a ledger, oldest spawn first
#
# WHAT THE NUMBERS MEAN
#   cost is percentUsed at close minus percentUsed at spawn, in percentage points of
#   that window. It is a measure of the window, not of the task alone: anything else
#   drawing on the same subscription during the task lands in the same number.
#
#   A window that rolled over mid-task has no meaningful arithmetic difference - usage
#   was zeroed partway - so it is reported as "window reset between captures" with no
#   cost figure rather than a plausible wrong one. This is the normal case for an
#   overnight run that rides a reset, so it is called out rather than averaged away.
#   Two independent tests detect it, neither comparing resetsAt strings (those jitter
#   between two reads of the same window, and rolling windows recompute them on every
#   read): usage fell between the captures, or the window current at spawn was due to
#   reset before the close capture ran. The second catches what the first cannot - a
#   window that reset and then climbed back past its spawn-time level.
#
#   A capture that did not return usable data yields no cost. This script never
#   substitutes a zero for a missing measurement, and never silently upgrades a
#   stale reading: a stale side is labelled STALE with its refreshedAt.
#
# EXIT
#   0 report produced (even when a cost was not computable - that IS the finding)
#   1 no ledger for the task, or nothing to report under --fleet
#   2 usage error or missing jq
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-quota-delta.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,40p' "$SELF" | sed 's/^# \{0,1\}//'
}

TASK=
FLEET=0
SHOW_ALL=0
AS_JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --fleet) FLEET=1 ;;
    --all) SHOW_ALL=1 ;;
    --json) AS_JSON=1 ;;
    -*) echo "fm-quota-delta.sh: unknown option '$1'" >&2; exit 2 ;;
    *)
      [ -z "$TASK" ] || { echo "fm-quota-delta.sh: one task id at a time" >&2; exit 2; }
      TASK=$1
      ;;
  esac
  shift
done

if [ "$FLEET" = 0 ] && [ -z "$TASK" ]; then
  echo "usage: fm-quota-delta.sh <task-id> [--all] [--json] | --fleet [--json]" >&2
  exit 2
fi
if [ "$FLEET" = 1 ] && [ -n "$TASK" ]; then
  echo "fm-quota-delta.sh: --fleet takes no task id" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "fm-quota-delta.sh: jq not found" >&2; exit 2; }

# Pair the last spawn record with the last close record and describe every window.
# A task promoted in place (fm-promote.sh) keeps its id and its original spawn
# record, so "last" is the right pick on both ends.
# shellcheck disable=SC2016  # single quotes are deliberate: jq expands its own $vars.
ANALYSIS_JQ='
def nz: if . == "" then null else . end;
def win($rec; $provider):
  [ ($rec.providers // [])[] | select(.provider == $provider) ] | first;
# quota-axi resetsAt carries sub-second precision and, for rolling windows, is
# recomputed as now+windowSeconds on every read, so two captures of the SAME window
# rarely produce an identical string. Comparing the strings would report every
# window as reset. Parse to epoch instead and use the two sound tests below.
def toEpoch:
  if type != "string" then null
  else
    (sub("\\.[0-9]+"; "")) as $s
    | (if ($s | test("\\+00:00$")) then ($s | sub("\\+00:00$"; "Z"))
       elif ($s | test("Z$")) then $s
       else null end) as $n
    | if $n == null then null else (try ($n | fromdateiso8601) catch null) end
  end;
(map(select(.phase == "spawn")) | last) as $spawn
| (map(select(.phase == "close")) | last) as $close
| (($spawn // $close) // {}) as $any
| (($close.attribution.provider) // ($spawn.attribution.provider)) as $prov
| {
    task: ($any.task // null),
    harness: ($any.harness // null),
    model: ($any.model // null),
    effort: ($any.effort // null),
    kind: ($any.kind // null),
    attribution: (($close.attribution) // ($spawn.attribution) // null),
    spawn: (if $spawn == null then null else {at: $spawn.at, capture: $spawn.capture, reason: $spawn.reason} end),
    close: (if $close == null then null else {at: $close.at, capture: $close.capture, reason: $close.reason} end),
    computable: ($spawn != null and $close != null and $spawn.capture == "ok" and $close.capture == "ok"),
    blocked_reason: (
      if $spawn == null then "no spawn record in the ledger"
      elif $close == null then "no close record: the task has not been cleaned up, or it ended outside cleanup"
      elif $spawn.capture != "ok" then "spawn capture \($spawn.capture): \($spawn.reason // "no detail")"
      elif $close.capture != "ok" then "close capture \($close.capture): \($close.reason // "no detail")"
      else null end
    ),
    providers: [
      ( [ (($spawn.providers // [])[].provider), (($close.providers // [])[].provider) ] | unique | .[] )
      as $p
      | (win($spawn; $p)) as $sp
      | (win($close; $p)) as $cp
      | {
          provider: $p,
          attributed: ($p == $prov),
          plan: (($cp.plan) // ($sp.plan) // null),
          spawn_status: ($sp.status // null),
          close_status: ($cp.status // null),
          spawn_stale: (if $sp == null then null elif ($sp | has("stale")) then $sp.stale else null end),
          close_stale: (if $cp == null then null elif ($cp | has("stale")) then $cp.stale else null end),
          spawn_refreshed_at: ($sp.refreshedAt // null),
          close_refreshed_at: ($cp.refreshedAt // null),
          error: (($cp.error) // ($sp.error) // null),
          windows: [
            ( [ (($sp.windows // [])[].id), (($cp.windows // [])[].id) ] | unique | .[] ) as $wid
            | (([ ($sp.windows // [])[] | select(.id == $wid) ] | first)) as $sw
            | (([ ($cp.windows // [])[] | select(.id == $wid) ] | first)) as $cw
            | ($sw.resetsAt | toEpoch) as $swReset
            | ($close.at | toEpoch) as $closeAt
            # Two independent, provider-agnostic reset tests, neither relying on
            # resetsAt stability. (1) usage fell: the counter was zeroed. (2) the
            # window current at spawn was due to reset before the close capture ran.
            # Test 2 catches the case test 1 cannot see - a window that reset and
            # then climbed back past its spawn-time level, which is exactly what an
            # overnight run riding a reset looks like.
            | (if $sw == null or $cw == null then false
               elif ($sw.percentUsed != null and $cw.percentUsed != null
                     and $cw.percentUsed < $sw.percentUsed) then true
               elif ($swReset != null and $closeAt != null and $swReset < $closeAt) then true
               else false end) as $resetCrossed
            | {
                id: $wid,
                label: (($cw.label) // ($sw.label) // null),
                kind: (($cw.kind) // ($sw.kind) // null),
                used_at_spawn: ($sw.percentUsed // null),
                used_at_close: ($cw.percentUsed // null),
                remaining_at_close: ($cw.percentRemaining // null),
                resets_at: (($cw.resetsAt) // ($sw.resetsAt) // null),
                reset_crossed: $resetCrossed,
                # Recorded so a reader can tell "checked, no reset" from "could not
                # check": an unparseable resetsAt leaves only the usage-decrease test.
                reset_check: (
                  if $sw == null or $cw == null then "not-applicable"
                  elif ($swReset != null and $closeAt != null) then "reset-time-and-usage"
                  else "usage-only" end
                ),
                cost_percent_points: (
                  if $sw == null or $cw == null then null
                  elif $resetCrossed then null
                  elif ($sw.percentUsed == null or $cw.percentUsed == null) then null
                  else ($cw.percentUsed - $sw.percentUsed) end
                ),
                note: (
                  if $sw == null then "absent at spawn"
                  elif $cw == null then "absent at close"
                  elif $resetCrossed then "window reset between captures - cost not measurable"
                  else null end
                )
              }
          ]
        }
    ]
  }
'

analyse() {  # <ledger> -> analysis JSON on stdout
  jq -s "$ANALYSIS_JQ" "$1"
}

render() {  # reads analysis JSON on stdin
  jq -r --argjson all "$SHOW_ALL" '
    def orNA: if . == null then "-" else (. | tostring) end;
    def signed: if . == null then "-" elif . >= 0 then "+\(.)" else "\(.)" end;
    def staleTag($stale; $at):
      if $stale == true then "STALE (refreshed \($at // "unknown"))"
      elif $stale == false then "fresh"
      else "unknown" end;
    "task \(.task // "?")  harness=\(.harness // "-") model=\(.model // "-") effort=\(.effort // "-") kind=\(.kind // "-")",
    "  spawn " + (if .spawn == null then "MISSING" else "\(.spawn.at)  capture=\(.spawn.capture)" + (if .spawn.reason then "  (\(.spawn.reason))" else "" end) end),
    "  close " + (if .close == null then "MISSING" else "\(.close.at)  capture=\(.close.capture)" + (if .close.reason then "  (\(.close.reason))" else "" end) end),
    "  attribution: " + (
      if .attribution == null then "none recorded"
      elif .attribution.provider == null then "UNRESOLVED (\(.attribution.basis)) - \(.attribution.reason // "no reason recorded")"
      else "provider \(.attribution.provider) via \(.attribution.basis)"
           + (if .attribution.scorable then "" else " - NOT SCORABLE: \(.attribution.reason // "no windows")" end)
      end),
    (if .computable then empty else "  cost: NOT COMPUTABLE - \(.blocked_reason)" end),
    (
      [ .providers[] | select($all == 1 or .attributed) ]
      | if length == 0 then "  (nothing attributed to score; re-run with --all to see every provider in the snapshot)" else
        .[] | . as $p |
        "",
        "  provider \(.provider)\(if .attributed then " [attributed]" else "" end) plan=\(.plan // "-")  spawn: \(staleTag(.spawn_stale; .spawn_refreshed_at))  close: \(staleTag(.close_stale; .close_refreshed_at))"
        + (if .error then "  error: \(.error)" else "" end),
        (if (.windows | length) == 0 then "    (no windows reported - nothing to score)" else
          "    " + ("window" | .[0:36] + (" " * (36 - (. | length))))
            + "used@spawn  used@close      cost   remain  resets",
          (.windows[] |
            "    "
            + ((.id + (if .label then " (" + .label + ")" else "" end)) as $n
               | if ($n | length) >= 36 then ($n[0:35] + " ") else ($n + (" " * (36 - ($n | length)))) end)
            + ((.used_at_spawn | orNA) as $s | (" " * (10 - ($s | length))) + $s)
            + ((.used_at_close | orNA) as $c | (" " * (12 - ($c | length))) + $c)
            + ((.cost_percent_points | signed) as $d | (" " * (10 - ($d | length))) + $d)
            + ((.remaining_at_close | orNA) as $r | (" " * (9 - ($r | length))) + $r)
            + "  " + (.resets_at // "-")
            + (if .note then "  [" + .note + "]" else "" end)
            # Staleness belongs next to the number it qualifies, not only in the
            # provider header: a reader scanning the cost column must not take a
            # figure derived from a cached reading for a fresh measurement.
            + (if $p.spawn_stale == true and $p.close_stale == true then "  [both readings stale]"
               elif $p.close_stale == true then "  [close reading stale]"
               elif $p.spawn_stale == true then "  [spawn reading stale]"
               else "" end))
        end)
        end
    )
  '
}

report_one() {  # <task-id> <ledger>
  local analysis
  analysis=$(analyse "$2") || return 1
  if [ "$AS_JSON" = 1 ]; then
    printf '%s\n' "$analysis"
  else
    printf '%s\n' "$analysis" | render
  fi
}

if [ "$FLEET" = 1 ]; then
  found=0
  # Oldest spawn first, so a morning read follows the night in order. The sort key
  # is the first record's own timestamp, not a directory mtime.
  ROWS=$(
    for ledger in "$DATA"/*/quota.jsonl; do
      [ -f "$ledger" ] || continue
      printf '%s\t%s\n' \
        "$(head -1 "$ledger" | jq -r '.at // "0"' 2>/dev/null || echo 0)" \
        "$ledger"
    done | LC_ALL=C sort
  )
  while IFS=$'\t' read -r _at ledger; do
    [ -n "${ledger:-}" ] || continue
    [ -f "$ledger" ] || continue
    id=$(basename "$(dirname "$ledger")")
    if [ "$found" = 1 ] && [ "$AS_JSON" != 1 ]; then
      echo
    fi
    found=1
    report_one "$id" "$ledger"
  done <<EOF
$ROWS
EOF
  [ "$found" = 1 ] || { echo "fm-quota-delta.sh: no quota ledgers under $DATA" >&2; exit 1; }
  exit 0
fi

LEDGER="$DATA/$TASK/quota.jsonl"
if [ ! -f "$LEDGER" ]; then
  echo "fm-quota-delta.sh: no quota ledger for task $TASK at $LEDGER" >&2
  exit 1
fi
report_one "$TASK" "$LEDGER"
exit 0
