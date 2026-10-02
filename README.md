# project-progress-mcp

A Zig MCP server that lets coding agents persist project goals, progress notes,
documentation indexes, and session freshness checks without embedding an LLM.

The server is intentionally mechanical. Agents do the analysis, scanning,
summarizing, and planning. The MCP validates and stores the structured JSON they
provide, writes `project_progress.md`, and records SQLite metadata so future
sessions can detect drift.

Markdown and registered-document writes go through unique sibling temp files
before rename to reduce partial documentation writes. Leftover `*.tmp` artifacts
are ignored by snapshots and git.

SQLite connections use WAL mode, `synchronous=NORMAL`, and a short busy timeout
so concurrent agent sessions can wait through transient database locks.

## Build

Install Zig and a SQLite development package that provides `sqlite3.h` and a
linkable `sqlite3` library.

```powershell
zig build
```

On Windows, make sure `sqlite3.lib` and `sqlite3.dll` are available to the
compiler/runtime. If SQLite is not globally discoverable, pass explicit paths:

```powershell
zig build -Dsqlite_include=C:\sqlite\include -Dsqlite_lib_dir=C:\sqlite\lib
```

Alternatively, build against the SQLite amalgamation by providing `sqlite3.c`;
the directory containing that file must also contain `sqlite3.h`:

```powershell
zig build -Dsqlite_source=C:\sqlite-amalgamation\sqlite3.c
```

This repository has been verified on Windows with Zig 0.16.0 using
`-Dsqlite_source` and the official SQLite amalgamation.

## Smoke Test

Run static preflight checks that do not require Zig:

```powershell
node .\scripts\preflight.mjs
```

After building, run the stdio MCP smoke test:

```powershell
node .\scripts\smoke-test.mjs .\zig-out\bin\project-progress-mcp.exe
```

On non-Windows hosts, omit the `.exe` or pass the compiled binary path. The
smoke test creates a temporary project, calls the core MCP tools through
`Content-Length` framed JSON-RPC, checks index validation rejects bad payloads,
initializes a tiny git repository when git is available, and removes the
temporary project afterward.

## MCP transport

The server speaks JSON-RPC 2.0 over stdio using `Content-Length` framed MCP
messages.

On Windows, expose the binary via an NTFS junction so Cursor sees a no-space
path (Cursor shell-splits spaced `command` paths, and copying under
`%USERPROFILE%\.cursor\` triggers ACL/sandbox behavior that blocks stdio):

```powershell
zig build
node .\scripts\install-cursor-mcp.mjs           # creates <drive>\pp-mcp junction
# or pick your own no-space path on the same drive:
node .\scripts\install-cursor-mcp.mjs --link=D:\bin\pp-mcp
```

Then point Cursor at the junctioned executable (use the path the install script prints):

```json
{
  "type": "stdio",
  "command": "D:/pp-mcp/project-progress-mcp.exe"
}
```

The junction requires no admin rights; it lives on the same drive as the repo
and stays in sync with every `zig build` (no copies to keep fresh). See
`.mcp.example.json` for the full entry and a `zig build run` dev entry. Tool
argument examples live under `examples/`.

## Agent contract

The MCP does not scan code semantically and does not generate documentation.
Agents must:

1. Get user permission plus a full goal, MVP, and completion criteria before bootstrapping an empty project.
2. Scan non-empty projects themselves and submit structured summaries.
3. Keep `project_progress.md` current through `project_progress.index`.
4. Run `project_progress.session_check` before work.
5. If drift is reported, inspect the changed files and update progress records
   before continuing.
6. Run `project_progress.record_snapshot` after progress documentation is
   updated.

## Tools

`tools/list` exposes nested input schemas for sections, entries, and documents.

### `project_progress.instructions`

Returns the required JSON shapes and workflow.

### `project_progress.bootstrap`

Creates `.project-progress/progress.sqlite`, stores the user-approved goal, and
creates `project_progress.md` if missing. `user_authorized` must be true and
`goal`, `mvp`, and `completion_criteria` must be supplied and nonblank.

Required arguments:

```json
{
  "project_root": "D:/path/to/project",
  "user_authorized": true,
  "goal": "Full project goal",
  "mvp": "MVP description",
  "completion_criteria": ["criterion one", "criterion two"]
}
```

### `project_progress.session_check`

Compares current git state and file modification times against the last stored
snapshot. Returns `git_drift` plus files the agent must inspect if the project
moved since the last MCP save, including files deleted after the previous
snapshot. It also returns `project_empty`, `file_count`, `has_snapshot`, and
`snapshot_file_count` so the agent can choose bootstrap or scan flow.
Each file drift item includes legacy `size`/`mtime_ns` fields plus structured
`current` and `snapshot` file states so agents can distinguish new, modified,
and deleted files without an extra database read.
Git status is captured with branch information plus explicit `upstream`,
`ahead`, and `behind` fields from the local repository. The MCP does not fetch
from remotes; agents should fetch first if they need network-fresh remote state.
`session_check` is read-only with respect to MCP initialization; if no database
exists, it returns `mcp_store_initialized: false`.
It also returns a structured `action_required` value (`bootstrap_authorization`,
`scan_project`, `inspect_drift`, `repair_consistency`, or `ready`) and
`can_continue`, so an agent does not need to infer the session gate from prose.
File drift includes SHA-256 content hashes in addition to size and mtime. This
catches same-size edits and makes comparisons useful across filesystems with
different timestamp precision.
When a database exists, the check is recorded as a `check` session while git
comparisons still use the latest `snapshot` session as the saved baseline.

### `project_progress.index`

Stores the agent supplied progress index and optionally replaces the root
`project_progress.md`. If `full_markdown` is omitted, the MCP renders
`project_progress.md` from the supplied `sections` and `entries`. The stored
section index is replaced on each call so removed sections do not remain in
future context. Index replacement is transactional.

Entries may include `entry_id`. Entries with the same `entry_id` are updated in
place; entries without `entry_id` are appended as history notes.
The response contains a monotonically increasing `revision`. Pass the revision
returned by `context` as `expected_revision` when updating an existing project;
a stale agent receives `Conflict` instead of overwriting newer progress.
The MCP stores a hash of the root Markdown alongside the revision. `context`
and `session_check` expose `markdown_consistency` so an interrupted write or
database failure can be detected.
The MCP enforces stable lowercase section IDs, bounded status labels, and
priorities `1` high, `2` normal, `3` later so future agents can sort and update
work deterministically. `completion_criteria`, section `anchors`, and document
`tags` must be arrays of strings.

### `project_progress.register_docs`

Registers documentation files and summaries. When `content` is supplied, the MCP
writes the documentation file under the project root. Document paths must be
safe relative paths without absolute roots, drive prefixes, empty segments, `.`,
or `..`, and `tags` must be an array of strings. Documentation database
registration is transactional. Before writing content, the MCP resolves the
nearest existing parent and rejects symlink/junction paths that escape the
project root.

### `project_progress.record_snapshot`

Stores current git state and file mtimes after the agent has updated progress
documentation. The previous file snapshot is replaced so resolved deletions do
not keep reappearing as drift. Snapshot replacement is transactional.

### `project_progress.context`

Returns the saved goal, indexed `project_progress.md` sections, recent entries,
documentation records, and freshness metadata for the next agent session.
Stored `*_json` fields, including registered document `source_json`, are returned
as structured JSON values.
The response also includes `work_queue.active`, `work_queue.blocked`, and
`work_queue.next`, derived from progress entries with `active`, `blocked`, and
`planned` statuses ordered by priority.
Like `session_check`, this is read-only with respect to MCP initialization; if no
database exists, it returns empty collections with `mcp_store_initialized: false`.
The response promotes `latest_check` and `latest_snapshot` for quick resume
decisions, and also includes recent `latest_sessions` history. Session history
includes `session_kind` values such as `check` and `snapshot`.
Latest sessions include persisted git upstream/ahead/behind metadata.
The response includes the current progress `revision` and
`markdown_consistency` fields.
Session `drift_json` values use a consistent `{git_drift,file_drift}` shape for
both checks and snapshots.

## Bug reports

Open investigation notes live under `docs/bugs/`. See in particular
[docs/bugs/2026-08-07-large-tree-session-timeout-opaque-errors.md](docs/bugs/2026-08-07-large-tree-session-timeout-opaque-errors.md)
for timeouts / connection closes on large trees and opaque `InvalidRequest` tool errors.
