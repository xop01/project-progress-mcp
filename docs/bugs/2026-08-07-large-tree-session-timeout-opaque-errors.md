# Bug report: session_check / snapshot timeouts and opaque failures under large trees

- **Status:** Fixed (2026-08-07)
- **Severity:** High (blocks agent closeout / progress persistence on real codebases)
- **Root cause (confirmed):** `scanDir` walked the entire tree and SHA-256-hashed every file; `shouldSkip` only ignored Zig/SQLite/git paths. After `third_party/llvm` (~GB) and `build/` appeared, `session_check` / `record_snapshot` exceeded the MCP client timeout. Opaque `InvalidRequest` was a separate bug: tool failures returned only `@errorName(err)`.
- **Component:** `project_progress.session_check`, `project_progress.record_snapshot`, tool error reporting
- **Date observed:** 2026-08-07
- **Host:** Windows, Cursor agent calling MCP server `user-project-progress`
- **Affected project:** `D:/path/to/large-project` (placeholder; real absolute roots must not be committed)
- **Server:** Zig `project-progress-mcp` (stdio, Content-Length framed JSON-RPC)
- **Reporter context:** Agent session on a large CMake/SDK tree; early MCP calls succeeded, late-session calls failed

---

## Summary

After a tracked project grew from a handful of markdown files into a full CMake tree with **`third_party/llvm` (~2 GB / thousands of files)** and a **`build/`** directory, MCP tools began failing with:

1. `MCP error -32001: Request timed out` (on `project_progress_session_check`)
2. `MCP error -32000: Connection closed` (on `project_progress_register_docs` with a multi-document payload)
3. Client-side `InvalidRequest` with **no field / path / reason** (on subsequent `project_progress_index` / `project_progress_record_snapshot`)

Early in the same session (docs-only tree, `file_count` ≈ 5–6), `session_check`, `register_docs`, `index`, and `record_snapshot` worked reliably.

The leading hypothesis is that **file scanning + full-content SHA-256 hashing does not exclude large generated/vendor trees**, so `session_check` / `record_snapshot` become arbitrarily slow (or OOM/crash the stdio process) once those trees appear. Separately, tool failures currently surface only `@errorName(err)` (e.g. bare `"InvalidRequest"`), which makes client-side diagnosis impossible.

---

## Environment / timeline

| Phase | Tree shape | MCP behavior |
|-------|------------|--------------|
| Start of session | ~5 tracked docs (`README.md`, `stack-research.md`, …) | `session_check` / `context` / `record_snapshot` OK; `file_count: 5` then `6` |
| Mid session | Added `code_style.md`; still tiny | `register_docs` + `index` (rev 7→8) + snapshot OK |
| Late session | Unpacked LLVM SDK under `third_party/llvm/…`, Z3 under `third_party/z3-…`, CMake `build/` with many binaries | `session_check` **timeout**; `register_docs` **connection closed**; later `index` / `record_snapshot` **InvalidRequest** |

Cursor server id: `user-project-progress`.  
Project root passed as: `D:/path/to/large-project`.

Agent chat reference: session that implemented the Windows scaffold / LLVM / opacity plan on that large tree.

---

## Exact client-visible errors

### 1) Timeout

```text
MCP error -32001: Request timed out
```

Observed calling:

- `project_progress.session_check` with `{ "project_root": "D:/path/to/large-project" }`

at the end of a long agent turn (after full tree existed).

### 2) Connection closed

```text
MCP error -32000: Connection closed
```

Observed calling:

- `project_progress.register_docs` with ~11 documents (research notes + `docs/build.md` + `code_style.md`)

immediately after / around the timed-out check. Likely the stdio MCP child had already hung or died; the client then reports connection closed.

### 3) Opaque InvalidRequest

```text
InvalidRequest
```

(Cursor/`CallMcpTool` surfaced this as a failed tool result / `InvalidRequest` with **no JSON body explaining which argument failed**.)

Observed on retry of:

- `project_progress.index` (`expected_revision: 8`, large `full_markdown` + many sections/entries)
- `project_progress.record_snapshot`

Also, when the server *does* return a tool error, `src/main.zig` currently formats only the Zig error name:

```zig
const result = callTool(allocator, params) catch |err| {
    const text = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
    // ...
    try writeToolText(io, request_id, text, true);
};
```

So agents see `"InvalidRequest"` / `"Conflict"` / `"Sqlite"` with **zero** actionable detail (which field, which path, which revision, which SQLite rc).

---

## Suspected root cause (code-backed)

### A. Full-tree walk + full-file hashing with a tiny skip list

`scanDir` recursively walks the project and, for every file, opens it and **hashes the entire contents**:

```983:1014:src/main.zig
fn scanDir(...) !void {
    // ...
    .file => {
        // open + stat + hashFile(entire contents)
    },
    .directory => {
        // recurse
    },
}
```

`shouldSkip` only ignores a few names:

```1033:1042:src/main.zig
fn shouldSkip(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".project-progress") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, ".zig-global-cache") or
        std.mem.eql(u8, name, "zig-out") or
        // ...
        std.mem.endsWith(u8, name, ".tmp");
}
```

**Not skipped (but present in the large project after implementation):**

- `third_party/` (LLVM package alone: ~2000 files, ~2 GB)
- `build/` / `cmake-build-*/` / `.vs/`
- `*.exe`, `*.lib`, `*.pdb`, `*.7z`, `*.zip`
- general `.gitignore` patterns

`session_check` and `record_snapshot` both use this scan. After vendor/build trees appear, a single call can take far longer than the MCP client timeout while hashing gigabytes of binaries.

This matches the observed phase change: **works on a docs-only repo, fails after third_party/build land**.

### B. Opaque tool errors

Many validation sites `return ToolError.InvalidRequest` with no message payload (e.g. bad `expected_revision` type, bad `section_id`, bad status enum, bad path). The catch site collapses all of them to the string `InvalidRequest`. After a hung/dead process, the Cursor host may also surface a generic invalid request / connection error that is indistinguishable from a real validation failure.

### C. Possible secondary factors

- **Large JSON arguments** (`full_markdown` + many `entries` / `documents`) increase request size; if the server is already wedged hashing files, these fail as connection closed rather than a clean validation error.
- **Stale `expected_revision`** would correctly return `Conflict`, not `InvalidRequest` — so revision mismatch alone does not explain the opaque `InvalidRequest` unless the client never received a framed response.
- SQLite busy timeout is 5s; that is unlikely to be the primary issue versus multi-GB hashing.

---

## Reproduction steps

1. Bootstrap / use a small project (few markdown files). Confirm:

   ```text
   project_progress.session_check → can_continue / ready (or inspect_drift only)
   project_progress.record_snapshot → ok
   ```

2. Add a large unpacked vendor tree under the project root, e.g.:

   - `third_party/llvm/` with a full LLVM Windows SDK (~GB scale), **or**
   - any directory with thousands of files totaling hundreds of MB+

3. Optionally also add a CMake/`build/` output tree with many `.obj` / `.lib` / `.exe` files.

4. Call again:

   ```json
   { "project_root": "<that project>" }
   ```

   against `project_progress.session_check` and/or `project_progress.record_snapshot`.

5. **Expected (desired):** completes in seconds; ignores vendor/build; returns drift for source/docs only.  
   **Actual (observed):** client timeout and/or MCP stdio connection closed; subsequent tools fail opaquely.

Optional validation of opaque errors (independent of tree size):

1. Call `project_progress.index` with an illegal `section_id` (e.g. `"Bad Id"`) or invalid `status`.
2. Observe tool result text is exactly `InvalidRequest` with no field name.

---

## Impact

- Agents cannot reliably finish the required workflow (`register_docs` → `index` → `record_snapshot`) on projects that download SDKs or produce build artifacts in-tree.
- Progress store becomes stale relative to the real tree; next session may see massive drift or keep timing out.
- Debugging is blocked because failures lack structured detail and there is little/no stderr logging of scan progress or failure sites.

Workaround used in that session: write `project_progress.md` on disk manually and skip MCP closeout when the server was unhealthy.

---

## Proposed fixes

### 1) Ignore large / generated / vendor paths (must-have)

Extend skip rules (name and/or relative path prefix), at least:

- `third_party`, `external`, `vendor`, `vcpkg_installed`
- `build`, `out`, `cmake-build-*`, `.vs`, `Debug`, `Release`, `x64`, `Win32`
- `node_modules`, `.venv`, `__pycache__`
- common binary/archive suffixes when hashing is too expensive: `.exe`, `.dll`, `.lib`, `.a`, `.pdb`, `.7z`, `.zip`, `.obj`, `.o`, `.iso`

Prefer also honoring `.gitignore` / an optional `.project-progress-ignore` file so projects can declare local exclusions.

### 2) Do not full-hash huge files by default

- Cap hashed file size (e.g. skip or size+mtime-only above N MiB).
- Or hash only “doc-like” extensions for content hashes; use size+mtime for the rest.
- Log when a file is skipped for size.

### 3) Structured error responses + stderr logs (must-have for debuggability)

Replace bare `@errorName(err)` tool errors with JSON, e.g.:

```json
{
  "ok": false,
  "error": "InvalidRequest",
  "tool": "project_progress.index",
  "message": "section_id must match ^[a-z0-9_-]+$",
  "path": "sections[2].section_id",
  "details": { "value": "Bad Id", "revision": 8 }
}
```

On every failure path that today returns `ToolError.InvalidRequest` / `Conflict` / `Sqlite`, attach:

- tool name
- human message
- JSON path / field name when validation fails
- SQLite `errmsg` / return code when `Sqlite`
- `expected_revision` vs actual on `Conflict`

Also write the same record to **stderr** (stdio MCP logging channel) with a timestamp and request id, e.g.:

```text
[project-progress-mcp] 2026-08-07T12:04:01Z ERROR tool=project_progress.session_check code=TimeoutRisk scanned=18422 hashed_bytes=2147483648 elapsed_ms=45012 last_path=third_party/llvm/.../LLVMCore.lib
```

### 4) Scan progress / watchdog logs

During `scanDir` / `record_snapshot`:

- Log every N files: `scanned`, `hashed_bytes`, `elapsed_ms`, `current_path`
- If elapsed exceeds a threshold (e.g. 10s), log a **warning** listing the heaviest directories
- Optional soft deadline: abort scan with a structured error `ScanTooLarge` advising ignore rules, instead of hanging until the client times out

### 5) Harden register_docs / index against dead connections

- Keep request handlers bounded; never start a multi-GB hash on the hot path without ignores
- Consider making snapshot capture incremental (only rehash paths that changed by mtime/size)

### 6) Tests to add

- Smoke fixture that creates a fake `third_party/big/` with many large files and asserts `session_check` / `record_snapshot` finish quickly and do not list those paths
- Unit test that invalid `section_id` returns structured error JSON containing the field path
- Unit test that `Conflict` includes expected vs actual revision

---

## Acceptance criteria for the fix

1. A project containing a multi-GB `third_party/` and a populated `build/` can call `session_check` and `record_snapshot` successfully within a few seconds (same order of magnitude as the docs-only case).
2. Tool failures return structured JSON (not only `InvalidRequest`) including tool name and field/path when applicable.
3. Stderr contains at least one log line per failed tool call with enough context to debug without attaching a debugger.
4. New smoke coverage in `scripts/smoke-test.mjs` (or Zig tests) locks the ignore + structured-error behavior.

---

## Related code pointers

| Area | Location |
|------|----------|
| Tool error collapse to name only | `src/main.zig` `tools/call` catch → `@errorName(err)` |
| Recursive scan + full hash | `src/main.zig` `scanDir`, `hashFile` |
| Skip list | `src/main.zig` `shouldSkip` |
| Session check uses scan | `sessionCheck` → file list / drift |
| Snapshot rewrite of all file rows | `recordSnapshot` → `DELETE FROM file_snapshots` then insert all scanned files |
| Many `return ToolError.InvalidRequest` without message | throughout `indexProgress`, validators, `writeFileState`, etc. |

---

## Appendix: successful vs failing call pattern (same session)

**Succeeded earlier:**

- `project_progress.session_check` (mtime-only README drift; then ready)
- `project_progress.register_docs` (2 docs)
- `project_progress.index` (`expected_revision: 7` → revision 8)
- `project_progress.record_snapshot`

**Failed after tree growth:**

- `project_progress.session_check` → timeout `-32001`
- `project_progress.register_docs` (11 docs) → connection closed `-32000`
- `project_progress.index` / `record_snapshot` retries → opaque `InvalidRequest`

---

## Suggested implementation order

1. Expand `shouldSkip` + add ignore-file support (stops the bleeding).
2. Cap / avoid full hashing of large binaries.
3. Structured tool errors + stderr logging.
4. Scan progress warnings / soft deadline.
5. Smoke tests for large-tree projects.

---

## Fix applied (2026-08-07)

Implemented in `src/main.zig` / `scripts/smoke-test.mjs` / `scripts/preflight.mjs`:

1. **Skip list expanded** — `third_party`, `vendor`, `external`, `build`, `out`, `node_modules`, `.vs`, `cmake-build-*`, `Debug`/`Release`/`x64`/`Win32`, `CMakeFiles`, plus common binary/archive extensions (`.lib`, `.exe`, `.pdb`, `.obj`, …).
2. **Hash size cap** — files larger than `max_content_hash_bytes` (1 MiB) are tracked with size+mtime only (empty content hash).
3. **Structured tool errors** — failures return JSON `{ok,error,tool,message}` and log the same line to stderr.
4. **Underscore tool-name aliases** — accepts Cursor-style `project_progress_session_check` names.
5. **Smoke coverage** — large fake `third_party/` + `build/` trees must not appear in drift; structured `InvalidRequest` / `Conflict` messages asserted.

**Follow-ups not done yet:** `.gitignore` / `.project-progress-ignore` parsing, scan progress watchdog / soft deadline, incremental rehash.

**Deploy note:** Restart the Cursor `user-project-progress` MCP server so it loads the rebuilt binary (`zig-out` install may be locked while the old process holds the exe).
