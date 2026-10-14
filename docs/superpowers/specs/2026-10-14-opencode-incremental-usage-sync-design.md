# Unified Agent Usage Index

## Intent

Pulse currently keeps separate JSON caches for OpenCode, Codex, and Claude Code. OpenCode may scan a large SQLite message history on each refresh; changed Codex/Claude transcripts can be reparsed in full. Replace those caches with one Pulse-owned SQLite usage index and follow CC Switch's source-specific sync patterns so unchanged sources and files are cheap to revisit.

## Goals

- Use one local SQLite database for all three agent usage caches and sync cursors.
- Avoid rereading unchanged OpenCode history and unchanged transcript files.
- Incrementally consume appended Claude Code JSONL bytes; use Codex's changed-file/line-cursor semantics because Codex token records are cumulative.
- Preserve existing `OpenCodeUsageSnapshot`, `OpenCodeDailyBucket`, `CodexUsageSnapshot`, `CodexDailyBucket`, `ClaudeCodeUsageSnapshot`, and `ClaudeCodeDailyBucket` semantics.
- Keep Pulse's cache separate from all agent source databases and transcripts.
- Recover from a missing, corrupt, stale-version, or incompatible cache by rebuilding derived state.
- Remove cached file/session contributions when their source files or sessions disappear.
- Preserve source independence and concurrent parsing; serialize only short writes to the shared cache database.

## Chosen Design

Pulse will keep one app-owned SQLite usage index under its Application Support directory. It will store source-specific file/database identities and cursors, session metadata, parser checkpoints needed for safe continuation, and per-source derived usage contributions. It will not copy transcript lines or raw message JSON. Claude cache entries retain only the user-visible session title metadata required by the existing snapshot behavior; the separate `lastPrompt` field is used while parsing but is not persisted. Existing JSON caches are disposable derived data; the first run after migration may rebuild them from the source files.

For OpenCode, Pulse compares nanosecond modification times for both `opencode.db` and its `-wal` file with the last successfully synced values. If neither is newer and the database identity, schema, and local calendar identity still match, it returns cached usage without querying source messages. When the source changes, it computes each session watermark as `max(session.time_updated, max(message.time_updated))`; only new or advanced sessions have assistant messages reread. Their cached contributions are replaced transactionally, and removed sessions are pruned.

For Claude Code, each JSONL file has a persisted byte cursor, complete-line boundary, and tail fingerprint. Appends are parsed from the last committed newline and merged into that file's cached usage accumulator. A detected truncate/rewrite resets and reparses that file, replacing its cached contribution. Incomplete trailing lines are left for the next refresh.

For Codex, unchanged JSONL files are skipped using file metadata. When a file changes, Pulse reparses that file from the beginning because Codex token-count records are cumulative and parser context depends on earlier events, then transactionally replaces that file's cached aggregate rather than adding its replayed events on top of the old aggregate. This per-file replacement makes a separate event-import line cursor unnecessary. If a file's identity changes or its size shrinks, its old aggregate is likewise replaced by the full replay. Pulse preserves transcript-authoritative token accounting and the union of valid Codex state databases for session metadata. Removed files are pruned.

OpenCode source reads use the read-only URI with `immutable=1` by default. If the WAL mtime is newer than the main DB, Pulse uses read-only `mode=ro` without `immutable=1` so SQLite can include committed WAL pages; it never writes or checkpoints OpenCode's database. Local day buckets are derived with the current calendar; a calendar/time-zone identity change rebuilds derived day buckets from source data. The shared cache supports concurrent source reads while serializing its brief SQLite write transactions.

## Correctness Boundary

OpenCode change detection follows CC Switch's DB/WAL mtime and session/message timestamp watermarks. It cannot detect an out-of-band edit that preserves both file mtimes and affected row timestamps. Claude's byte cursor assumes append-oriented JSONL; the tail fingerprint detects truncation and rewrites near the committed boundary, but not arbitrary in-place edits outside the fingerprint window. Codex reparses changed files, but a same-size in-place edit with unchanged file metadata is not detected. These limits match the source-specific incremental model; detecting arbitrary timestamp-preserving edits would require rereading or hashing source payloads.

## Non-Goals

- Modifying OpenCode, Codex, or Claude Code source data.
- Storing transcript lines, standalone prompt fields, or raw message JSON in Pulse's cache (aside from the visible session-title metadata described above).
- Changing the user-facing usage model, source selection, or refresh triggers.
- Adding dependencies; use system SQLite3.

## Verification

Tests will cover cache persistence/versioning, OpenCode DB/WAL fast paths and v1/v2 message watermarks, replacement/deletion of OpenCode session contributions, Claude append/incomplete-line/rewrite/truncation behavior, Codex unchanged-file skip and changed-file replay without duplicate events, source file deletion, calendar invalidation, and concurrent cache writes. Run source-specific tests and the full macOS test suite.
