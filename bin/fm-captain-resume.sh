#!/usr/bin/env bash
# fm-captain-resume.sh - atomically refresh the canonical Firstmate handoff carrier.
#
# Usage:
#   fm-captain-resume.sh refresh --session-id <producing-session-id>
#
# The only write target is <FM_HOME>/CAPTAIN-RESUME.md.
# Other files named CAPTAIN-RESUME remain historical and are never discovered,
# moved, rewritten, or deleted by this command.
#
# The carrier is derived from a fresh, complete local Bearings projection plus
# the durable wake queue and pending-reply filenames.
# It contains a timestamp, producing session identity, live tasks, pending
# decisions, source-report paths, pending notifications, and charted next steps.
# A missing session identity, invalid snapshot, or render failure preserves the
# previous carrier byte-for-byte.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME_INPUT="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_HOME=$(CDPATH='' cd -- "$FM_HOME_INPUT" 2>/dev/null && pwd -P) \
  || { printf 'fm-captain-resume: FM_HOME cannot be resolved: %s\n' "$FM_HOME_INPUT" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BEARINGS="${FM_CAPTAIN_RESUME_BEARINGS:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"
TARGET="$FM_HOME/CAPTAIN-RESUME.md"

usage() {
  cat <<'EOF'
usage: fm-captain-resume.sh refresh --session-id <producing-session-id>

Refresh only <FM_HOME>/CAPTAIN-RESUME.md from fresh local structured state.
EOF
}

fail() {
  printf 'fm-captain-resume: %s\n' "$*" >&2
  exit 1
}

validate_one_line() {
  [ -n "$1" ] || return 1
  case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac
}

[ "${1:-}" = refresh ] || { usage >&2; exit 2; }
shift
SESSION_ID=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session-id)
      [ "$#" -gt 1 ] || { printf 'fm-captain-resume: --session-id is required\n' >&2; exit 2; }
      SESSION_ID=$2
      shift 2
      ;;
    --session-id=*)
      SESSION_ID=${1#--session-id=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done
validate_one_line "$SESSION_ID" \
  || { printf 'fm-captain-resume: --session-id is required and must be one line\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -x "$BEARINGS" ] || fail "Bearings executable is unavailable: $BEARINGS"

NOW=${FM_CAPTAIN_RESUME_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
validate_one_line "$NOW" || fail "refresh timestamp must be one line"
SNAPSHOT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SNAPSHOT_SECONDMATES=0 \
  "$BEARINGS" --json --all-in-flight --all-decisions --all-secondmates --all-reports --all-queued) \
  || fail "fresh Bearings snapshot failed"
printf '%s\n' "$SNAPSHOT" | jq -e '
  .schema == "fm-bearings.v1"
    and (.in_flight | type == "array")
    and (.decisions_open | type == "array")
    and (.reports | type == "array")
    and (.gates | type == "array")
    and (.omitted | type == "array")
' >/dev/null 2>&1 || fail "fresh Bearings snapshot is invalid"
printf '%s\n' "$SNAPSHOT" | jq -e '
  [.omitted[] | select(.carrier_relevant == true)] | length == 0
' >/dev/null 2>&1 || fail "fresh Bearings snapshot is incomplete for the canonical carrier"

if command -v shasum >/dev/null 2>&1; then
  SNAPSHOT_SHA=$(printf '%s' "$SNAPSHOT" | shasum -a 256 | awk '{print $1}')
else
  SNAPSHOT_SHA=$(printf '%s' "$SNAPSHOT" | sha256sum | awk '{print $1}')
fi

render_json_section() {  # <jq-filter>
  local filter=$1 rendered
  rendered=$(printf '%s\n' "$SNAPSHOT" | jq -r "$filter") || return 1
  if [ -n "$rendered" ]; then
    printf '%s\n' "$rendered"
  else
    printf '%s\n' '- None recorded in the fresh structured snapshot.'
  fi
}

render_pending_notifications() {
  local found=0 file rel
  if [ -f "$STATE/.wake-queue" ]; then
    # shellcheck disable=SC2015 # awk exit 3 is the intentional no-record sentinel; other failures return.
    awk -F '\t' '
      NF >= 5 {
        payload = $5
        for (i = 6; i <= NF; i++) payload = payload " " $i
        gsub(/[[:cntrl:]]/, " ", payload)
        printf "- %s / %s / %s\n", $3, $4, payload
        found = 1
      }
      END { if (found) exit 0; exit 3 }
    ' "$STATE/.wake-queue" && found=1 || {
      status=$?
      [ "$status" -eq 3 ] || return "$status"
    }
  fi
  if [ -d "$STATE/pending-replies" ]; then
    for file in "$STATE/pending-replies"/*; do
      [ -f "$file" ] || continue
      rel=${file#"$FM_HOME/"}
      printf '%s\n' "- $rel"
      found=1
    done
  fi
  [ "$found" -eq 1 ] || printf '%s\n' '- None recorded in the durable notification surfaces.'
}

umask 077
TMP=$(mktemp "$FM_HOME/.CAPTAIN-RESUME.tmp.XXXXXX") || fail "could not allocate carrier temporary file"
trap 'rm -f "$TMP"' EXIT
if ! {
  printf '# CAPTAIN-RESUME\n\n'
  printf -- '- Refreshed: %s\n' "$NOW"
  printf -- '- Producing session: %s\n' "$SESSION_ID"
  # shellcheck disable=SC2016 # Backticks are literal Markdown, not shell interpolation.
  printf -- '- Evidence source: fresh local `fm-bearings.v1` plus durable notification files\n'
  printf -- '- Bearings SHA-256: %s\n' "$SNAPSHOT_SHA"
  printf '\n## Live tasks\n\n'
  render_json_section '.in_flight[] | "- \(.id) [\(.kind)/\(.state)]: \((.doing // "-") | gsub("[\\r\\n]"; " "))"'
  printf '\n## Pending decisions\n\n'
  render_json_section '.decisions_open[] | "- \(.id) [\(.owner)]: \((.summary // "-") | gsub("[\\r\\n]"; " "))"'
  printf '\n## Source reports\n\n'
  render_json_section '.reports[] | "- \(.id): \(.path)"'
  printf '\n## Pending notifications\n\n'
  render_pending_notifications
  printf '\n## Next steps\n\n'
  render_json_section '.gates[] | "- \(.id) [\(.owner)]: \(.title) (blocked by: \(.blocked_by); reason: \(.reason))"'
} > "$TMP"; then
  fail "could not render canonical carrier"
fi
mv "$TMP" "$TARGET" || fail "could not publish canonical carrier"
trap - EXIT
printf '%s\n' "$TARGET"
