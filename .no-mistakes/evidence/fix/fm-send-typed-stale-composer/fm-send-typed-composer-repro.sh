#!/usr/bin/env bash
set -u
ROOT=/Users/admin/.no-mistakes/worktrees/8054e8b95bcd/01M3AVVER279MGBE7EEZTPX2GD
. "$ROOT/tests/lib.sh"
case_root=$(fm_test_tmproot fm-send-composer-evidence)
mkdir -p "$case_root/home/state" "$case_root/fakebin"
fm_write_meta "$case_root/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
cat > "$case_root/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift 2;; -l) literal=1; shift;; *) break;; esac
    done
    if [ "$literal" = 1 ]; then printf '%s\n' "${1:-}" >> "$FM_SEND_LOG";
    else printf '%s\n' "${1:-}" >> "$FM_SEND_KEYS"; fi
    ;;
  display-message) printf '1\n';;
  capture-pane)
    if [ "${FM_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi;;
  list-windows) printf 'fm-t1\n';;
esac
SH
chmod +x "$case_root/fakebin/tmux"
cat > "$case_root/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$case_root/fakebin/sleep"
export PATH="$case_root/fakebin:$PATH" FM_ROOT_OVERRIDE="$case_root/home" FM_HOME="$case_root/home"
export FM_SEND_LOG="$case_root/typed.log" FM_SEND_KEYS="$case_root/keys.log" FM_SEND_SETTLE=0
for composer in pending empty; do
  : > "$FM_SEND_LOG"; : > "$FM_SEND_KEYS"
  export FM_COMPOSER="$composer"
  rc=0
  "$ROOT/bin/fm-send.sh" t1 /status > "$case_root/out" 2> "$case_root/err" || rc=$?
  printf 'composer=%s exit=%s\n' "$composer" "$rc"
  printf 'stderr: '; cat "$case_root/err"
  printf 'typed: '; if [ -s "$FM_SEND_LOG" ]; then cat "$FM_SEND_LOG"; else printf '(none)\n'; fi
  printf 'keys: '; if [ -s "$FM_SEND_KEYS" ]; then tr '\n' ' ' < "$FM_SEND_KEYS"; printf '\n'; else printf '(none)\n'; fi
  printf 'inbox records: '; find "$case_root/home/state" -path '*.inbox/*.msg' -type f | wc -l | tr -d ' '
done
