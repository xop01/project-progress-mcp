# Project Progress

## Goal

Build a Zig MCP server that agents can use to track project progress from start to finish without embedding an LLM. Agents perform project analysis and feed structured JSON into the MCP; the MCP persists it, writes documentation, indexes this file, and detects drift before future sessions.

## MVP

- Stdio MCP server written in Zig.
- SQLite persistence under .project-progress/progress.sqlite.
- Root project_progress.md managed from agent-supplied JSON.
- Agent instructions and schemas exposed as an MCP tool.
- Session checks for Git advancement, file metadata drift, and content-hash drift.
- Revision-aware progress updates and Markdown consistency checks.
- Snapshot recording after progress docs are updated.

## Architecture

The MCP is mechanical storage and documentation infrastructure. It speaks framed JSON-RPC over stdio, persists structured state in SQLite, writes the root progress document atomically, and leaves scanning, interpretation, and planning to the agent.

## Current State

- The Zig server builds and runs on Windows with SQLite amalgamation support.
- The seven project_progress tools are exposed over MCP stdio.
- SHA-256 content hashes are stored with file snapshots, catching same-size edits that mtime-only checks can miss.
- Progress indexing has a monotonic revision and rejects stale expected_revision updates with Conflict.
- session_check returns action_required and can_continue for bootstrap, scan, drift inspection, consistency repair, or ready states.
- Markdown consistency hashes detect disagreement between project_progress.md and SQLite metadata.
- Documentation writes reject lexical traversal and resolved paths that escape the project root.
- Cursor and Codex desktop configurations point to the compiled server.
- Scan/snapshot ignores vendor and build trees (`third_party`, `build`, binary extensions, etc.) and caps content hashing at 1 MiB so large SDK trees do not time out MCP calls.
- Tool failures return structured JSON (`ok`, `error`, `tool`, `message`) and log the same line to stderr.
- Cursor-style underscore tool names are accepted as aliases for the dotted MCP names.
- Repo docs/examples avoid host-local absolute paths; preflight rejects common machine-path leaks.

## Next Work

- Restart the connected Cursor MCP server and reinstall `zig-out/bin/project-progress-mcp.exe` (old process may lock the binary).
- Optional: honor `.gitignore` / `.project-progress-ignore`, add scan progress watchdog / soft deadline, incremental rehash.
- Consider optional lifecycle operations for decisions, risks, and project archival.

## Risks

- ChatGPT web requires a remotely reachable MCP endpoint; a local Windows stdio executable is available to desktop MCP clients only.
- The MCP stores agent-supplied facts and does not independently verify semantic claims.
- Until the Cursor MCP child is restarted, the live server may still be the pre-fix binary.
- Committed docs must stay free of host-local absolute paths; `scripts/preflight.mjs` enforces this.

## Completion Criteria

- The server exposes bootstrap, instructions, session check, indexing, documentation registration, snapshot recording, and context retrieval.
- Empty projects require explicit user authorization plus a goal, MVP, and completion criteria before bootstrap.
- Non-empty projects can be scanned by the agent and registered in SQLite.
- The server does not contain LLM calls or model-dependent behavior.
- The project builds on Windows with Zig and SQLite.
- Drift detection includes Git state, file metadata, and content hashes.
- Concurrent progress updates can be rejected using expected_revision.

## Change Log

- 2026-08-07: Fixed large-tree session_check/snapshot timeouts by expanding scan skips and capping content hashes; added structured tool errors and underscore tool-name aliases (see `docs/bugs/2026-08-07-large-tree-session-timeout-opaque-errors.md`).
- 2026-10-02: Scrubbed machine-local absolute paths from docs/comments, removed an accidental host PowerShell cache from the tree, and added a preflight anonymity guard.
- 2026-08-05: Added SHA-256 file snapshot hashes, progress revisions, structured session actions, Markdown consistency checks, and resolved-path containment checks.
- 2026-08-05: Added smoke coverage for same-size edits, stale revisions, session gating, hashes, and consistency metadata.
- 2026-08-05: Wired the compiled server into Cursor and Codex desktop MCP configurations.
