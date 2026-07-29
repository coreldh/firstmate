#!/usr/bin/env bash
# Regenerate the payload manifest trusted by Firstmate's Codex project hooks.
#
# The covered payload inventory is intentionally owned here rather than derived
# from the existing manifest: a truncated or tampered manifest must never become
# the source of truth for its own replacement. The command validates all covered
# files before staging either output, rewrites all four pinned manifest digests
# in hooks.json together, and atomically replaces each destination from a
# same-directory temporary file. A crash between the two replacements can only
# leave hooks failing closed on a manifest-digest mismatch.
#
# --check builds the same candidates without replacing tracked files. It exits
# 0 when both files are current, 1 for drift, and 2 for an unsafe or malformed
# input.
#
# Usage: fm-hook-manifest.sh [--check|--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CODEX_DIR="$FM_ROOT/.codex"
MANIFEST="$CODEX_DIR/hook-payload.sha256"
HOOKS="$CODEX_DIR/hooks.json"

PAYLOADS=(
  bin/fm-sessionstart-nudge.sh
  bin/fm-gate-refuse-lib.sh
  bin/fm-primary-scope-lib.sh
  bin/fm-operational-input.sh
  bin/fm-arm-pretool-check.sh
  bin/fm-arm-command-policy.mjs
  bin/fm-cd-pretool-check.sh
  bin/fm-cd-command-policy.mjs
  bin/fm-turnend-guard.sh
  bin/fm-supervision-lib.sh
  bin/fm-wake-lib.sh
  bin/fm-supervision-instructions.sh
  bin/fm-harness.sh
)

usage() {
  printf 'usage: fm-hook-manifest.sh [--check|--help]\n' >&2
}

fail() {
  printf 'fm-hook-manifest: refused: %s\n' "$1" >&2
  exit 2
}

check_only=0
case "${1:-}" in
  "")
    ;;
  --check)
    check_only=1
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 2; }

command -v shasum >/dev/null 2>&1 || fail "shasum is unavailable"
command -v awk >/dev/null 2>&1 || fail "awk is unavailable"
command -v cmp >/dev/null 2>&1 || fail "cmp is unavailable"

[ -d "$CODEX_DIR" ] && [ ! -L "$CODEX_DIR" ] \
  || fail ".codex is missing or is a symlink"
[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] \
  || fail ".codex/hook-payload.sha256 is missing or is a symlink"
[ -f "$HOOKS" ] && [ ! -L "$HOOKS" ] \
  || fail ".codex/hooks.json is missing or is a symlink"

for payload in "${PAYLOADS[@]}"; do
  [ -f "$FM_ROOT/$payload" ] && [ ! -L "$FM_ROOT/$payload" ] \
    || fail "$payload is missing or is a symlink"
done

manifest_tmp=""
hooks_tmp=""
cleanup() {
  [ -z "$manifest_tmp" ] || rm -f "$manifest_tmp"
  [ -z "$hooks_tmp" ] || rm -f "$hooks_tmp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

manifest_tmp=$(umask 077; mktemp "$CODEX_DIR/.hook-payload.sha256.XXXXXX") \
  || fail "cannot create the manifest candidate"
hooks_tmp=$(umask 077; mktemp "$CODEX_DIR/.hooks.json.XXXXXX") \
  || fail "cannot create the hooks candidate"

for payload in "${PAYLOADS[@]}"; do
  hash_line=$(shasum -a 256 "$FM_ROOT/$payload") \
    || fail "cannot hash $payload"
  hash=${hash_line%% *}
  case "$hash" in
    *[!0-9a-f]*|"") fail "shasum returned an invalid digest for $payload" ;;
  esac
  [ "${#hash}" -eq 64 ] \
    || fail "shasum returned an invalid digest for $payload"
  printf '%s  %s\n' "$hash" "$payload" >> "$manifest_tmp"
done

manifest_hash_line=$(shasum -a 256 "$manifest_tmp") \
  || fail "cannot hash the manifest candidate"
manifest_hash=${manifest_hash_line%% *}
case "$manifest_hash" in
  *[!0-9a-f]*|"") fail "shasum returned an invalid manifest digest" ;;
esac
[ "${#manifest_hash}" -eq 64 ] \
  || fail "shasum returned an invalid manifest digest"

# Update only the exact inline manifest-hash guards. The raw JSON representation
# contains escaped quotes, so the prefix below is matched without parsing or
# reformatting unrelated hooks.json content.
if ! awk -v digest="$manifest_hash" '
  BEGIN {
    prefix = "manifest_hash\\\" = \\\""
    matches = 0
    bad = 0
  }
  {
    rest = $0
    output = ""
    while ((position = index(rest, prefix)) != 0) {
      output = output substr(rest, 1, position + length(prefix) - 1)
      rest = substr(rest, position + length(prefix))
      old_digest = substr(rest, 1, 64)
      closing_quote = substr(rest, 65, 2)
      if (length(old_digest) != 64 \
          || old_digest !~ /^[0-9a-f]+$/ \
          || closing_quote != "\\\"") {
        bad = 1
        exit 2
      }
      output = output digest
      rest = substr(rest, 65)
      matches++
    }
    print output rest
  }
  END {
    if (bad || matches != 4) {
      exit 2
    }
  }
' "$HOOKS" > "$hooks_tmp"; then
  fail ".codex/hooks.json does not contain exactly four valid manifest hash guards"
fi

chmod 0644 "$manifest_tmp" "$hooks_tmp" \
  || fail "cannot set candidate permissions"

manifest_drift=0
hooks_drift=0
cmp -s "$manifest_tmp" "$MANIFEST" || manifest_drift=1
cmp -s "$hooks_tmp" "$HOOKS" || hooks_drift=1

if [ "$check_only" -eq 1 ]; then
  if [ "$manifest_drift" -eq 0 ] && [ "$hooks_drift" -eq 0 ]; then
    printf 'hook manifest: current\n'
    exit 0
  fi
  [ "$manifest_drift" -eq 0 ] \
    || printf 'hook manifest drift: .codex/hook-payload.sha256\n' >&2
  [ "$hooks_drift" -eq 0 ] \
    || printf 'hook manifest drift: .codex/hooks.json\n' >&2
  exit 1
fi

if [ "$manifest_drift" -eq 0 ] && [ "$hooks_drift" -eq 0 ]; then
  printf 'hook manifest: current\n'
  exit 0
fi

mv "$manifest_tmp" "$MANIFEST" \
  || fail "cannot replace .codex/hook-payload.sha256"
manifest_tmp=""
mv "$hooks_tmp" "$HOOKS" \
  || fail "cannot replace .codex/hooks.json"
hooks_tmp=""
printf 'hook manifest: updated\n'
