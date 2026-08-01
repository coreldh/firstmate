#!/usr/bin/env bash
# Prepare and execute the verified payload closure used by Codex project hooks.
#
# Usage:
#   fm-codex-hook-run.sh prepare <source-root> <stage-root>
#   fm-codex-hook-run.sh run <payload-root> <source-root> <manifest-sha256> <target>
#   fm-codex-hook-run.sh stage-run <source-root> <manifest-sha256> <target>
#
# `prepare` copies the manifest-declared regular-file closure into an existing,
# empty private directory, verifies the copied bytes, and removes write bits.
# `run` re-verifies a prepared closure and executes only a manifest member.
# `stage-run` is the manual-launch fallback: it prepares a private temporary
# closure, applies the reversible user-immutable flag when macOS provides it,
# and runs the target under a process sandbox that denies writes to that copy.
# Its exact cleanup is `chflags -R nouchg`, `chmod -R u+w`, then depth-first
# deletion of the private stage. The prepared-spawn lifecycle is owned by
# bin/fm-codex-hook-launch.sh instead.
set -u

fail() {
  printf 'firstmate Codex hook refused: %s\n' "$1" >&2
  exit 2
}

resolve_dir() {
  local dir=$1
  [ -d "$dir" ] || return 1
  (CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P)
}

valid_hash() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

valid_relative_file() {
  case "$1" in
    ''|/*|*..*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  case "/$1/" in
    *'/./'*|*'//'*) return 1 ;;
    *) return 0 ;;
  esac
}

path_has_symlink() {
  local root=$1 prefix='' part rest=$2
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) part=${rest%%/*}; rest=${rest#*/} ;;
      *) part=$rest; rest= ;;
    esac
    [ -n "$part" ] || return 0
    if [ -n "$prefix" ]; then
      prefix="$prefix/$part"
    else
      prefix=$part
    fi
    [ ! -L "$root/$prefix" ] || return 0
  done
  return 1
}

manifest_each() {
  local manifest=$1 callback=$2 line=0 raw expected file rest
  while IFS= read -r raw || [ -n "${raw:-}" ]; do
    line=$((line + 1))
    expected=${raw%% *}
    rest=${raw#"$expected"}
    case "$rest" in
      '  '*) file=${rest#'  '} ;;
      *) fail "trusted payload manifest line $line is malformed" ;;
    esac
    [ -n "$expected" ] && [ -n "$file" ] && [ "$raw" = "$expected  $file" ] \
      || fail "trusted payload manifest line $line is malformed"
    valid_hash "$expected" \
      || fail "trusted payload manifest line $line has an invalid digest"
    valid_relative_file "$file" \
      || fail "trusted payload manifest line $line has an unsafe path"
    "$callback" "$expected" "$file"
  done < "$manifest"
  [ "$line" -gt 0 ] || fail "trusted payload manifest is empty"
}

COPY_SOURCE=
COPY_STAGE=
COPY_SEEN='|'
copy_entry() {
  local _expected=$1 file=$2 destination
  case "$COPY_SEEN" in
    *"|$file|"*) fail "trusted payload manifest repeats $file" ;;
  esac
  COPY_SEEN="$COPY_SEEN$file|"
  if [ ! -f "$COPY_SOURCE/$file" ] || path_has_symlink "$COPY_SOURCE" "$file"; then
    fail "trusted payload entry is missing or unsafe: $file"
  fi
  destination="$COPY_STAGE/$file"
  /bin/mkdir -p -- "$(/usr/bin/dirname "$destination")" \
    || fail "trusted payload stage cannot create a destination directory"
  /bin/cp -p -- "$COPY_SOURCE/$file" "$destination" \
    || fail "trusted payload entry cannot be staged: $file"
  if [ ! -f "$COPY_SOURCE/$file" ] || path_has_symlink "$COPY_SOURCE" "$file"; then
    fail "trusted payload entry changed to an unsafe path: $file"
  fi
}

VERIFY_ROOT=
VERIFY_TARGET=
VERIFY_TARGET_FOUND=0
verify_entry() {
  local _expected=$1 file=$2
  if [ ! -f "$VERIFY_ROOT/$file" ] || path_has_symlink "$VERIFY_ROOT" "$file"; then
    fail "trusted payload entry is missing or unsafe: $file"
  fi
  [ "$file" != "$VERIFY_TARGET" ] || VERIFY_TARGET_FOUND=1
}

verify_payload() {
  local root=$1 expected_manifest=$2 manifest actual verify
  manifest="$root/.codex/hook-payload.sha256"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] \
    || fail "trusted payload manifest is missing or unsafe"
  valid_hash "$expected_manifest" || fail "trusted payload manifest pin is invalid"
  actual=$(/usr/bin/shasum -a 256 "$manifest" 2>/dev/null) \
    || fail "trusted payload manifest cannot be hashed"
  actual=${actual%% *}
  [ "$actual" = "$expected_manifest" ] \
    || fail "trusted payload manifest hash mismatch"
  VERIFY_ROOT=$root
  VERIFY_TARGET_FOUND=0
  manifest_each "$manifest" verify_entry
  verify=$(CDPATH='' cd -- "$root" && /usr/bin/shasum -a 256 -c -q --strict .codex/hook-payload.sha256 2>&1) \
    || fail "trusted payload hash mismatch: $verify"
}

prepare_payload() {
  local source=$1 stage=$2 manifest verify
  source=$(resolve_dir "$source") || fail "configured trusted code root is unavailable"
  stage=$(resolve_dir "$stage") || fail "trusted payload stage is unavailable"
  [ -z "$(/usr/bin/find "$stage" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] \
    || fail "trusted payload stage is not empty"
  manifest="$source/.codex/hook-payload.sha256"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] \
    || fail "trusted payload manifest is missing or unsafe"
  /bin/mkdir -p -- "$stage/.codex" \
    || fail "trusted payload stage cannot create its manifest directory"
  /bin/cp -p -- "$manifest" "$stage/.codex/hook-payload.sha256" \
    || fail "trusted payload manifest cannot be staged"
  COPY_SOURCE=$source
  COPY_STAGE=$stage
  COPY_SEEN='|'
  manifest_each "$stage/.codex/hook-payload.sha256" copy_entry
  verify=$(CDPATH='' cd -- "$stage" && /usr/bin/shasum -a 256 -c -q --strict .codex/hook-payload.sha256 2>&1) \
    || fail "staged payload hash mismatch: $verify"
  /bin/chmod -R a-w "$stage" \
    || fail "trusted payload stage cannot be made read-only"
}

run_payload() {
  local payload_root=$1 source_root=$2 expected_manifest=$3 target=$4
  payload_root=$(resolve_dir "$payload_root") || fail "prepared trusted payload root is unavailable"
  source_root=$(resolve_dir "$source_root") || fail "configured trusted code root is unavailable"
  valid_relative_file "$target" || fail "trusted payload target is unsafe"
  VERIFY_TARGET=$target
  verify_payload "$payload_root" "$expected_manifest"
  [ "$VERIFY_TARGET_FOUND" -eq 1 ] \
    || fail "trusted payload target is not declared in the manifest"
  [ -x "$payload_root/$target" ] \
    || fail "trusted payload target is not executable: $target"
  FM_ROOT_OVERRIDE=$source_root exec "$payload_root/$target"
}

STAGE_RUN_ROOT=
STAGE_RUN_FLAGGED=0
cleanup_stage_run() {
  [ -n "$STAGE_RUN_ROOT" ] && [ -d "$STAGE_RUN_ROOT" ] || return 0
  if [ "$STAGE_RUN_FLAGGED" -eq 1 ]; then
    /usr/bin/chflags -R nouchg "$STAGE_RUN_ROOT" 2>/dev/null || true
  fi
  /bin/chmod -R u+w "$STAGE_RUN_ROOT" 2>/dev/null || true
  /usr/bin/find "$STAGE_RUN_ROOT" -depth -delete 2>/dev/null || true
}

stage_run_payload() {
  local source_root=$1 expected_manifest=$2 target=$3 status profile
  source_root=$(resolve_dir "$source_root") || fail "configured trusted code root is unavailable"
  STAGE_RUN_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/firstmate-codex-hook.XXXXXX") \
    || fail "trusted payload stage cannot be created"
  trap cleanup_stage_run EXIT
  trap 'cleanup_stage_run; trap - EXIT; exit 129' HUP
  trap 'cleanup_stage_run; trap - EXIT; exit 130' INT
  trap 'cleanup_stage_run; trap - EXIT; exit 143' TERM
  prepare_payload "$source_root" "$STAGE_RUN_ROOT"
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ] && [ -x /usr/bin/chflags ]; then
    /usr/bin/chflags -R uchg "$STAGE_RUN_ROOT" \
      || fail "trusted payload stage cannot be made user-immutable"
    STAGE_RUN_FLAGGED=1
  fi
  VERIFY_TARGET=$target
  verify_payload "$STAGE_RUN_ROOT" "$expected_manifest"
  [ "$VERIFY_TARGET_FOUND" -eq 1 ] \
    || fail "trusted payload target is not declared in the manifest"
  [ -x "$STAGE_RUN_ROOT/$target" ] \
    || fail "trusted payload target is not executable: $target"
  set +e
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ] && [ -x /usr/bin/sandbox-exec ]; then
    profile='(version 1)(allow default)(deny file-write* (literal (param "HOOK_STAGE")) (subpath (param "HOOK_STAGE")))'
    FM_ROOT_OVERRIDE=$source_root /usr/bin/sandbox-exec \
      -D "HOOK_STAGE=$STAGE_RUN_ROOT" -p "$profile" "$STAGE_RUN_ROOT/$target"
    status=$?
  else
    FM_ROOT_OVERRIDE=$source_root "$STAGE_RUN_ROOT/$target"
    status=$?
  fi
  set -e
  cleanup_stage_run
  trap - EXIT HUP INT TERM
  STAGE_RUN_ROOT=
  exit "$status"
}

[ "$#" -gt 0 ] || fail "missing hook-run operation"
operation=$1
shift
case "$operation" in
  prepare)
    [ "$#" -eq 2 ] || fail "prepare requires source-root and stage-root"
    prepare_payload "$1" "$2"
    ;;
  run)
    [ "$#" -eq 4 ] || fail "run requires payload-root, source-root, manifest pin, and target"
    run_payload "$1" "$2" "$3" "$4"
    ;;
  stage-run)
    [ "$#" -eq 3 ] || fail "stage-run requires source-root, manifest pin, and target"
    stage_run_payload "$1" "$2" "$3"
    ;;
  *) fail "unknown hook-run operation: $operation" ;;
esac
