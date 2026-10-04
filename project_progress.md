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
- The seven project_progress tools are exposed over MCP stdio, and the server answers ping.
- Newline-delimited messages are read up to 32 MiB. A single oversized line no longer kills the process on the 8 KiB stdio buffer.
- SHA-256 content hashes are stored with file snapshots. Files larger than 1 MiB store a null hash and compare by size and mtime.
- Progress indexing requires expected_revision once the stored revision is greater than zero, and restores project_progress.md if the SQLite transaction rolls back.
- register_docs writes content before commit and restores those files if the transaction fails.
- session_check skips unreadable files, suppresses deletion drift when a directory walk is incomplete, and reports a missing progress file as a consistency mismatch.
- has_snapshot follows a recorded snapshot session, including a snapshot of zero files.
- Git baselines and recent sessions are ordered by session id.
- Cursor-style underscore tool names are accepted as aliases for the dotted MCP names.
- Repo docs/examples avoid host-local absolute paths; preflight rejects common machine-path leaks.

## Next Work

- Restart the connected Cursor MCP server so it loads the rebuilt binary. zig-out/bin/project-progress-mcp.exe may stay locked by the running process; the audit build is zig-out/audit/bin/project-progress-mcp.exe.
- Optional: honor .gitignore / .project-progress-ignore, add scan progress watchdog / soft deadline, incremental rehash.
- Consider optional lifecycle operations for decisions, risks, and project archival.

## Risks

- ChatGPT web requires a remotely reachable MCP endpoint; a local Windows stdio executable is available to desktop MCP clients only.
- The MCP stores agent-supplied facts and does not independently verify semantic claims.
- Until the Cursor MCP child is restarted, the live server may still be the pre-fix binary.
- Committed docs must stay free of host-local absolute paths; scripts/preflight.mjs enforces this.

## Completion Criteria

- The server exposes bootstrap, instructions, session check, indexing, documentation registration, snapshot recording, and context retrieval.
- Empty projects require explicit user authorization plus a goal, MVP, and completion criteria before bootstrap.
- Non-empty projects can be scanned by the agent and registered in SQLite.
- The server does not contain LLM calls or model-dependent behavior.
- The project builds on Windows with Zig and SQLite.
- Drift detection includes Git state, file metadata, and content hashes.
- Concurrent progress updates can be rejected using expected_revision.

## Change Log

- 2026-10-04: Stability pass for stdio framing, index/docs transactions, partial scans, snapshot identity, null hashes for large files, and ping.
- 2026-08-07: Fixed large-tree session_check/snapshot timeouts by expanding scan skips and capping content hashes; added structured tool errors and underscore tool-name aliases (see docs/bugs/2026-08-07-large-tree-session-timeout-opaque-errors.md).
- 2026-10-02: Scrubbed machine-local absolute paths from docs/comments, removed an accidental host PowerShell cache from the tree, and added a preflight anonymity guard.
- 2026-08-05: Added SHA-256 file snapshot hashes, progress revisions, structured session actions, Markdown consistency checks, and resolved-path containment checks.
- 2026-08-05: Added smoke coverage for same-size edits, stale revisions, session gating, hashes, and consistency metadata.
- 2026-08-05: Wired the compiled server into Cursor and Codex desktop MCP configurations.
