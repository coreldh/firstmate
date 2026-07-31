# Canonical CAPTAIN-RESUME carrier

`$FM_HOME/CAPTAIN-RESUME.md` is Firstmate's one canonical local session-handoff file.
It is a durable snapshot for a cold restart, not a replacement for `bin/fm-session-start.sh`, live state reconciliation, or Bearings.

The internal `/stow` skill refreshes the carrier after every complete stow pass with `bin/fm-captain-resume.sh refresh --session-id <producing-session-id>`.
The producing session identity is mandatory and must come from the current harness session rather than an invented label.
A missing identity, failed Bearings snapshot, invalid JSON, or render failure keeps the prior canonical file unchanged and makes the stow result not reset-safe.

Each refresh contains these disk-derived fields:

- a UTC refresh timestamp and producing session identity;
- a SHA-256 of the fresh `fm-bearings.v1` evidence;
- every live task from the unbounded local Bearings projection;
- every pending captain decision from structured Captain's Call state;
- every current scout-report source path;
- pending durable wake-queue records and pending-reply filenames;
- every queued or blocked next step from the complete Bearings gate projection.

The refresh lifts the registered-secondmate count bound and refuses publication when Bearings reports any carrier-relevant upstream omission, including bounded child, decision, queued, registry, or unreadable-home state.
That refusal preserves the previous canonical carrier byte-for-byte rather than publishing a schema-valid partial reset surface.

The generator does not accept chat text for these sections.
Empty sections state that the corresponding durable source recorded nothing.

The command writes a temporary file in the effective `FM_HOME` and atomically replaces only the exact home-root `CAPTAIN-RESUME.md` after every source and render check succeeds.
It never discovers, moves, rewrites, or deletes another file named `CAPTAIN-RESUME`.
Older carriers under `data/`, task evidence directories, or other paths remain historical evidence.

The canonical file is local and gitignored.
Its content may include task titles, decision summaries, and local report paths, so it is not a public artifact and must not be committed automatically.

Executable coverage lives in `tests/fm-captain-resume.test.sh`.
The test proves the required fields, historical-file preservation, mandatory session identity, exact canonical target, and failure-preserves-previous behavior.
