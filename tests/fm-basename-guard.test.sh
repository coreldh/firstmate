#!/usr/bin/env bash
# Repo guard: every basename call in bin/ ends its options before the operand.
#
# basename reads a leading-dash operand as an option cluster, so an unguarded
# call dies with "basename: illegal option -- /" instead of stripping the
# directory. A login shell records argv[0] with a leading dash ("-zsh",
# "-/bin/bash"), and any path or process comm can reach a call site the same way.
# The three harness ancestry walks are the paths where this actually fired; this
# guard keeps the rest of bin/ from growing a fourth.
#
# Satisfy it with either "basename -- <operand>" or ${var##*/}.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Print "<file>:<line>:<text>" for every basename COMMAND invocation in the
# named files that is not followed by the "--" end-of-options guard.
#
# Command position only: start of line or after ; & | ( ) { } or a backtick,
# which is what distinguishes a call from ${basename...}, "$basename", a
# local basename=... variable, and identifiers such as family_for_basename.
# Whole-line comments are skipped. bin/*.mjs is out of scope: it is JavaScript
# with its own basename() function, not a shell call.
unguarded_basename_sites() {
  perl -ne '
    next if /^\s*#/;
    while (/(?<![A-Za-z0-9_\$])(?<!\$\{)\bbasename\b(?=\s)/g) {
      my ($s, $e) = ($-[0], $+[0]);
      next unless substr($_, 0, $s) =~ /(^|[;&|(){}`])\s*$/;
      next if substr($_, $e) =~ /^\s+--(\s|$)/;
      print "$ARGV:$.:$_"; last;
    }
    close ARGV if eof;
  ' "$@"
}

# The guard is only worth anything if its detector still recognises the shape it
# is looking for. Without this, a detector that silently stopped matching would
# report a clean tree forever.
test_detector_catches_a_known_unguarded_call() {
  local dir hits
  dir=$(fm_test_tmproot fm-basename-guard)/detector
  mkdir -p "$dir"
  cat > "$dir/sample.sh" <<'SH'
#!/usr/bin/env bash
id=$(basename "$meta" .meta)
ok=$(basename -- "$meta" .meta)
also_ok=${meta##*/}
# basename "$commented_out"
name="$basename"
other=$(family_for_basename "$x")
SH
  hits=$(unguarded_basename_sites "$dir/sample.sh")
  # shellcheck disable=SC2016 # The literal source line is the expected value, not an expansion.
  assert_contains "$hits" 'id=$(basename "$meta" .meta)' \
    "detector missed a plainly unguarded basename call"
  [ "$(printf '%s\n' "$hits" | grep -c .)" = 1 ] || \
    fail "detector should flag exactly the one unguarded call, got: $hits"
  pass "basename guard: detector flags an unguarded call and nothing else"
}

test_no_unguarded_basename_in_bin() {
  local sites count
  sites=$(cd "$ROOT" && unguarded_basename_sites bin/*.sh bin/backends/*.sh)
  count=$(printf '%s' "$sites" | grep -c . || true)
  [ "$count" = 0 ] || fail "unguarded basename call(s) in bin/ - use 'basename --' or \${var##*/}:
$sites"
  pass "basename guard: no unguarded basename call in bin/"
}

test_detector_catches_a_known_unguarded_call
test_no_unguarded_basename_in_bin
