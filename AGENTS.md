# Agent Instructions

This repository implements a Zig MCP server for project progress tracking. The
MCP is mechanical storage and documentation infrastructure; it does not contain
an LLM and does not scan or understand projects on its own.

## Required Workflow

1. Before work, call `project_progress.session_check` with the target
   `project_root`.
   Use `project_progress.context` afterward when you need the saved goal,
   progress index, docs, latest check drift, latest snapshot baseline, and
   active/blocked/next work queue.
2. If `mcp_store_initialized` is `false` and `project_empty` is `true`, call
   `project_progress.bootstrap` only after the user explicitly authorizes this
   MCP and supplies a nonblank project goal/MVP/completion criteria.
3. If the project is not empty and has no MCP store or snapshot, scan the project
   yourself, then call `project_progress.index`,
   `project_progress.register_docs` as needed, and
   `project_progress.record_snapshot`.
4. Follow `session_check.action_required`. If it is `inspect_drift`, inspect the
   changed state/files yourself and update `project_progress.md` through
   `project_progress.index` before continuing unrelated work. If it is
   `repair_consistency`, re-index the Markdown before continuing.
   Treat `git.ahead` and `git.behind` as local upstream metadata; fetch first if
   the user expects network-fresh remote state.
5. After updating progress documentation, call
   `project_progress.record_snapshot` so future sessions have a fresh baseline.

## JSON Contract

- Use `sections` in `project_progress.index` for the current shape of
  `project_progress.md`; the stored section index is replacement-based.
- Keep `section_id` values stable and lowercase, for example `goal`, `mvp`,
  `architecture`, `current-work`, `next`, `risks`.
- Use section statuses from `current`, `planned`, `active`, `blocked`, `done`,
  `risk`, or `reference`.
- Use `entry_id` for ongoing progress entries that should update in place.
  Omit `entry_id` for append-only history notes.
- Use entry statuses from `planned`, `active`, `blocked`, `done`, `skipped`, or
  `risk`, and priorities `1` high, `2` normal, `3` later.
- Include enough summary/details for the next agent to continue without reading
  old chat; the MCP stores agent-provided facts and does not verify them.
- When updating an existing project, pass `context.revision` as
  `expected_revision` to `project_progress.index`; re-read context if the MCP
  returns `Conflict`.
- Treat a false `markdown_consistency.matches` value as a documentation
  recovery task before unrelated work.
- Use arrays of strings for `completion_criteria`, section `anchors`, and
  document `tags`.
- Register documentation with safe relative paths only. Do not use absolute
  paths, drive prefixes, empty path segments, `.`, or `..`.

## Anonymity

- Do not commit host-local absolute paths, usernames, or machine folder layout
  (for example real `Users\<name>` roots or personal drive trees). Use
  placeholders such as `D:/path/to/project` in docs, examples, and comments.
- `scripts/preflight.mjs` rejects common machine-local path markers in tracked
  text files. Keep `.project-progress/`, `.zig-cache/`, and `zig-out/` ignored.

## Local Fixtures

- `.mcp.example.json` shows a stdio launch config.
- `examples/` contains tool argument examples.
