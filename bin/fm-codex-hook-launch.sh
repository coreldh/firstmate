#!/usr/bin/env bash
# Launch a Codex worker with OS write denial around its trusted hook surface.
#
# Usage:
#   fm-codex-hook-launch.sh <source-root> <stage-parent> -- <codex> [args...]
#
# The source root remains the operational Firstmate root. Before Codex starts,
# this launcher copies the manifest-declared hook closure into a private stage.
# On macOS, the Codex process tree then runs under sandbox-exec with write access
# denied only to the source-root identity, its bin/.codex container identities,
# the exact manifest-declared files, hooks.json, and the complete staged copy.
# Unlisted files below the source root remain writable by that process.
#
# The sandbox is process-scoped and reverses when the child exits. The staged
# copy's read-only mode is reversed with `chmod -R u+w <stage>` before the exact
# private stage is deleted. No persistent filesystem flag or elevated privilege
# is used by this launcher.
set -u

fail() {
  printf 'firstmate Codex hook sandbox refused: %s\n' "$1" >&2
  exit 1
}

[ "$#" -ge 4 ] || fail "usage: fm-codex-hook-launch.sh <source-root> <stage-parent> -- <command> [args...]"
SOURCE_ROOT=$1
STAGE_PARENT=$2
shift 2
[ "$1" = -- ] || fail "missing -- before the Codex command"
shift
[ "$#" -gt 0 ] || fail "missing Codex command"

SOURCE_ROOT=$(CDPATH='' cd -- "$SOURCE_ROOT" 2>/dev/null && pwd -P) \
  || fail "trusted source root is unavailable"
STAGE_PARENT=$(CDPATH='' cd -- "$STAGE_PARENT" 2>/dev/null && pwd -P) \
  || fail "trusted stage parent is unavailable"
RUNNER="$SOURCE_ROOT/bin/fm-codex-hook-run.sh"
MANIFEST="$SOURCE_ROOT/.codex/hook-payload.sha256"
[ -x "$RUNNER" ] && [ ! -L "$RUNNER" ] || fail "trusted hook runner is missing or unsafe"
[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || fail "trusted hook manifest is missing or unsafe"

STAGE=$(/usr/bin/mktemp -d "$STAGE_PARENT/codex-hook-root.XXXXXX") \
  || fail "trusted hook stage cannot be created"
cleanup() {
  [ -d "$STAGE" ] || return 0
  /bin/chmod -R u+w "$STAGE" 2>/dev/null || true
  /usr/bin/find "$STAGE" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 129' HUP
trap 'cleanup; trap - EXIT; exit 130' INT
trap 'cleanup; trap - EXIT; exit 143' TERM

"$RUNNER" prepare "$SOURCE_ROOT" "$STAGE" \
  || fail "trusted hook payload could not be staged"

PROFILE='(version 1)(allow default)(deny file-write*'
PROFILE="$PROFILE (literal (param \"HOOK_ROOT\"))"
PROFILE="$PROFILE (literal (string-append (param \"HOOK_ROOT\") \"/bin\"))"
PROFILE="$PROFILE (literal (string-append (param \"HOOK_ROOT\") \"/.codex\"))"
PROFILE="$PROFILE (literal (string-append (param \"HOOK_ROOT\") \"/.codex/hooks.json\"))"
PROFILE="$PROFILE (literal (string-append (param \"HOOK_ROOT\") \"/.codex/hook-payload.sha256\"))"
while IFS= read -r raw || [ -n "${raw:-}" ]; do
  expected=${raw%% *}
  rest=${raw#"$expected"}
  case "$rest" in
    '  '*) file=${rest#'  '} ;;
    *) fail "staged hook manifest is malformed" ;;
  esac
  [ "${#expected}" -eq 64 ] && [ -n "$file" ] && [ "$raw" = "$expected  $file" ] \
    || fail "staged hook manifest is malformed"
  case "$expected" in *[!0-9a-f]*) fail "staged hook manifest digest is invalid" ;; esac
  case "$file" in ''|/*|*..*|*[!A-Za-z0-9._/-]*) fail "staged hook manifest path is unsafe" ;; esac
  case "/$file/" in *'/./'*|*'//'*) fail "staged hook manifest path is unsafe" ;; esac
  PROFILE="$PROFILE (literal (string-append (param \"HOOK_ROOT\") \"/$file\"))"
done < "$STAGE/.codex/hook-payload.sha256"
PROFILE="$PROFILE (literal (param \"HOOK_STAGE\")) (subpath (param \"HOOK_STAGE\")))"

set +e
if [ "$(uname -s 2>/dev/null || true)" = Darwin ] && [ -x /usr/bin/sandbox-exec ]; then
  FM_CODEX_HOOK_ROOT=$STAGE \
  FM_CODEX_HOOK_SOURCE_ROOT=$SOURCE_ROOT \
  FM_CODEX_HOOK_PREPARED=1 \
    /usr/bin/sandbox-exec -D "HOOK_ROOT=$SOURCE_ROOT" -D "HOOK_STAGE=$STAGE" \
      -p "$PROFILE" "$@"
  STATUS=$?
else
  printf 'firstmate Codex hook sandbox unavailable: running with anchored, verified payloads but without OS write denial\n' >&2
  FM_CODEX_HOOK_ROOT=$STAGE \
  FM_CODEX_HOOK_SOURCE_ROOT=$SOURCE_ROOT \
  FM_CODEX_HOOK_PREPARED=1 \
    "$@"
  STATUS=$?
fi
set -e

cleanup
trap - EXIT HUP INT TERM
[ ! -e "$STAGE" ] || fail "trusted hook stage cleanup failed after chmod reversal"
exit "$STATUS"
