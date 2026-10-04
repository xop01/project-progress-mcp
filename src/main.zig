const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const c = @cImport({
    @cInclude("sqlite3.h");
});

const server_name = "project-progress-mcp";
const protocol_version = "2024-11-05";

/// Skip full-content hashing above this size; drift then uses size+mtime only.
const max_content_hash_bytes: u64 = 1 * 1024 * 1024;
/// Newline-delimited JSON is accumulated until this cap. The stdio reader
/// buffer is smaller than a real index payload, so lines cannot be taken in
/// one shot from that buffer.
const max_message_bytes: usize = 32 * 1024 * 1024;
const max_tracked_files: usize = 250_000;
const max_scan_depth: u32 = 64;
const max_retained_sessions: c_int = 40;

var temp_file_seq: u64 = 0;

var runtime_io: ?std.Io = null;
var runtime_environ_map: ?*const std.process.Environ.Map = null;

threadlocal var tool_error_buf: [1024]u8 = undefined;
threadlocal var tool_error_len: usize = 0;
threadlocal var current_tool_name: []const u8 = "";

const ToolError = error{
    Conflict,
    InvalidRequest,
    MissingArgument,
    Unauthorized,
    UnsafePath,
    Sqlite,
    Io,
};

fn clearToolError() void {
    tool_error_len = 0;
}

fn toolErrorDetail() []const u8 {
    return tool_error_buf[0..tool_error_len];
}

fn setToolErrorDetail(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&tool_error_buf, fmt, args) catch blk: {
        const fallback = "error detail truncated";
        @memcpy(tool_error_buf[0..fallback.len], fallback);
        break :blk tool_error_buf[0..fallback.len];
    };
    tool_error_len = msg.len;
}

fn toolFail(err: ToolError, comptime fmt: []const u8, args: anytype) ToolError {
    setToolErrorDetail(fmt, args);
    return err;
}

fn logToolError(io: std.Io, tool: []const u8, err_name: []const u8, detail: []const u8) void {
    var buf: [1400]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[project-progress-mcp] ERROR tool={s} code={s} {s}\n", .{ tool, err_name, detail }) catch return;
    std.Io.File.stderr().writeStreamingAll(io, line) catch {};
}

fn formatToolErrorJson(allocator: std.mem.Allocator, tool: []const u8, err_name: []const u8, detail: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"ok\":false,\"error\":");
    try std.json.Stringify.value(err_name, .{}, w);
    try w.writeAll(",\"tool\":");
    try std.json.Stringify.value(tool, .{}, w);
    try w.writeAll(",\"message\":");
    if (detail.len > 0) {
        try std.json.Stringify.value(detail, .{}, w);
    } else {
        try std.json.Stringify.value(err_name, .{}, w);
    }
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn normalizeToolName(name: []const u8) []const u8 {
    // Cursor exposes dotted MCP names with underscores; accept both forms.
    if (std.mem.eql(u8, name, "project_progress_instructions")) return "project_progress.instructions";
    if (std.mem.eql(u8, name, "project_progress_bootstrap")) return "project_progress.bootstrap";
    if (std.mem.eql(u8, name, "project_progress_session_check")) return "project_progress.session_check";
    if (std.mem.eql(u8, name, "project_progress_index")) return "project_progress.index";
    if (std.mem.eql(u8, name, "project_progress_register_docs")) return "project_progress.register_docs";
    if (std.mem.eql(u8, name, "project_progress_record_snapshot")) return "project_progress.record_snapshot";
    if (std.mem.eql(u8, name, "project_progress_context")) return "project_progress.context";
    return name;
}

pub fn main(init: std.process.Init) !void {
    runtime_io = init.io;
    runtime_environ_map = init.environ_map;
    const allocator = init.gpa;

    const io = init.io;
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader_file = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);

    while (true) {
        const message = readMessage(allocator, &stdin_reader_file.interface) catch |err| switch (err) {
            error.EndOfStream => break,
            error.MessageTooLarge => {
                writeJsonRpcError(io, null, -32600, "message exceeds 32MiB limit") catch break;
                continue;
            },
            error.InvalidHeader => {
                writeJsonRpcError(io, null, -32700, "invalid Content-Length header") catch break;
                continue;
            },
            else => {
                logToolError(io, "stdio", @errorName(err), "failed to read message");
                break;
            },
        };
        defer allocator.free(message);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{
            .duplicate_field_behavior = .use_last,
        }) catch |err| {
            try writeJsonRpcError(io, null, -32700, @errorName(err));
            continue;
        };
        defer parsed.deinit();

        try handleMessage(allocator, io, parsed.value);
    }
}

fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    // MCP stdio uses newline-delimited JSON. The server also accepts LSP-style
    // Content-Length framing. Lines are accumulated so a payload larger than
    // the stdio buffer (index markdown, document batches) does not kill the
    // process with StreamTooLong.
    const first_line_owned = try readNonEmptyLine(allocator, reader) orelse return error.EndOfStream;
    const first_trimmed = std.mem.trim(u8, first_line_owned, " \t\r");
    if (first_trimmed.len > 0 and (first_trimmed[0] == '{' or first_trimmed[0] == '[')) {
        return first_line_owned;
    }
    defer allocator.free(first_line_owned);

    var content_length: ?usize = null;
    if (std.ascii.startsWithIgnoreCase(first_trimmed, "Content-Length:")) {
        content_length = parseContentLength(first_trimmed) catch return error.FrameTooLarge;
    }
    while (true) {
        const line_owned = try readRawLine(allocator, reader) orelse return error.EndOfStream;
        defer allocator.free(line_owned);
        const line = std.mem.trim(u8, line_owned, " \t\r");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            content_length = parseContentLength(line) catch return error.FrameTooLarge;
        }
    }

    const len = content_length orelse return error.InvalidHeader;
    if (len > max_message_bytes) return error.FrameTooLarge;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    try reader.readSliceAll(body);
    return body;
}

fn parseContentLength(line: []const u8) !usize {
    const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
    return std.fmt.parseInt(usize, value, 10);
}

fn readNonEmptyLine(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    while (true) {
        const line = try readRawLine(allocator, reader) orelse return null;
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            allocator.free(line);
            continue;
        }
        return line;
    }
}

/// Read through the next newline. A line longer than `max_message_bytes` is
/// discarded through the newline so the stream stays aligned, then
/// `error.MessageTooLarge` is returned.
fn readRawLine(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    var too_long = false;
    var saw_any = false;
    while (true) {
        if (reader.buffered().len == 0) {
            reader.fill(1) catch |err| switch (err) {
                error.EndOfStream => {
                    if (!saw_any) return null;
                    if (too_long) return error.MessageTooLarge;
                    return try line.toOwnedSlice(allocator);
                },
                else => |read_err| return read_err,
            };
        }
        const buffered = reader.buffered();
        const newline = std.mem.indexOfScalar(u8, buffered, '\n');
        const take_len: usize = if (newline) |index| index else buffered.len;
        saw_any = true;
        if (!too_long) {
            if (line.items.len + take_len > max_message_bytes) {
                too_long = true;
                line.clearRetainingCapacity();
            } else if (take_len > 0) {
                try line.appendSlice(allocator, buffered[0..take_len]);
            }
        }
        if (newline) |index| {
            reader.toss(index + 1);
            if (too_long) return error.MessageTooLarge;
            return try line.toOwnedSlice(allocator);
        }
        reader.toss(buffered.len);
    }
}

fn handleMessage(allocator: std.mem.Allocator, io: std.Io, value: std.json.Value) !void {
    const obj = asObject(value) catch {
        try writeJsonRpcError(io, null, -32600, "request must be a JSON object");
        return;
    };
    const method_value = obj.get("method") orelse return;
    const method = getValueString(method_value) orelse {
        if (obj.get("id")) |request_id| try writeJsonRpcError(io, request_id, -32600, "method must be a string");
        return;
    };
    const id = obj.get("id");

    if (std.mem.eql(u8, method, "initialize")) {
        if (id) |request_id| {
            try writeResult(io, request_id,
                \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"project-progress-mcp","version":"0.2.0"}}
            );
        }
        return;
    }

    if (std.mem.eql(u8, method, "notifications/initialized") or
        std.mem.eql(u8, method, "notifications/cancelled") or
        std.mem.eql(u8, method, "notifications/progress"))
    {
        return;
    }

    if (std.mem.eql(u8, method, "ping")) {
        if (id) |request_id| try writeResult(io, request_id, "{}");
        return;
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        if (id) |request_id| {
            try writeResult(io, request_id, toolsListJson());
        }
        return;
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        if (id) |request_id| {
            const params = obj.get("params") orelse {
                try writeJsonRpcError(io, request_id, -32602, "missing params");
                return;
            };
            clearToolError();
            current_tool_name = "";
            const result = callTool(allocator, params) catch |err| {
                const tool = if (current_tool_name.len > 0) current_tool_name else "unknown";
                const detail = toolErrorDetail();
                const err_name = @errorName(err);
                logToolError(io, tool, err_name, detail);
                if (formatToolErrorJson(allocator, tool, err_name, detail)) |text| {
                    defer allocator.free(text);
                    try writeToolText(io, request_id, text, true);
                } else |_| {
                    try writeToolText(io, request_id, "{\"ok\":false,\"error\":\"Internal\",\"tool\":\"unknown\",\"message\":\"failed to format tool error\"}", true);
                }
                return;
            };
            defer allocator.free(result);
            try writeToolText(io, request_id, result, false);
        }
        return;
    }

    if (id) |request_id| {
        try writeJsonRpcError(io, request_id, -32601, "method not found");
    }
}

fn callTool(allocator: std.mem.Allocator, params: std.json.Value) ![]u8 {
    const params_obj = try asObject(params);
    const raw_name = getValueString(params_obj.get("name") orelse return toolFail(ToolError.MissingArgument, "missing tool name", .{})) orelse
        return toolFail(ToolError.MissingArgument, "tool name must be a string", .{});
    const name = normalizeToolName(raw_name);
    current_tool_name = name;

    if (std.mem.eql(u8, name, "project_progress.instructions")) {
        return allocator.dupe(u8, instructionsText());
    }

    const args = params_obj.get("arguments") orelse return toolFail(ToolError.MissingArgument, "missing arguments object", .{});

    if (std.mem.eql(u8, name, "project_progress.bootstrap")) {
        return bootstrap(allocator, args);
    }
    if (std.mem.eql(u8, name, "project_progress.session_check")) {
        return sessionCheck(allocator, args);
    }
    if (std.mem.eql(u8, name, "project_progress.index")) {
        return indexProgress(allocator, args);
    }
    if (std.mem.eql(u8, name, "project_progress.register_docs")) {
        return registerDocs(allocator, args);
    }
    if (std.mem.eql(u8, name, "project_progress.record_snapshot")) {
        return recordSnapshot(allocator, args);
    }
    if (std.mem.eql(u8, name, "project_progress.context")) {
        return context(allocator, args);
    }

    return toolFail(ToolError.InvalidRequest, "unknown tool name: {s}", .{raw_name});
}

fn writeResult(io: std.Io, id: std.json.Value, result_json: []const u8) !void {
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    const w = &body.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.writeAll(",\"result\":");
    try w.writeAll(result_json);
    try w.writeAll("}");
    try writeFrame(io, body.writer.buffered());
}

fn writeToolText(io: std.Io, id: std.json.Value, text: []const u8, is_error: bool) !void {
    var escaped: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer escaped.deinit();
    try std.json.Stringify.value(text, .{}, &escaped.writer);

    var result: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer result.deinit();
    try result.writer.print("{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":{}}}", .{ escaped.writer.buffered(), is_error });
    try writeResult(io, id, result.writer.buffered());
}

fn writeJsonRpcError(io: std.Io, id: ?std.json.Value, code: i32, message: []const u8) !void {
    var escaped: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer escaped.deinit();
    try std.json.Stringify.value(message, .{}, &escaped.writer);

    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    const w = &body.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |request_id| {
        try std.json.Stringify.value(request_id, .{}, w);
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"error\":{{\"code\":{},\"message\":{s}}}}}", .{ code, escaped.writer.buffered() });
    try writeFrame(io, body.writer.buffered());
}

fn writeFrame(io: std.Io, body: []const u8) !void {
    // MCP stdio is newline-delimited JSON: emit compact JSON followed by a
    // single '\n'. Some internal payloads (e.g. the tools list) use Zig
    // multi-line string literals for readability, so strip any raw newlines
    // before framing. Real JSON string data escapes newlines as \\n, so this
    // only removes formatting whitespace.
    var frame: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer frame.deinit();
    for (body) |byte| {
        if (byte == '\n' or byte == '\r') continue;
        try frame.writer.writeByte(byte);
    }
    try frame.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, frame.writer.buffered());
}

fn toolsListJson() []const u8 {
    return
    \\{"tools":[
    \\{"name":"project_progress.instructions","description":"Return the required agent workflow and JSON schemas for this MCP.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"project_progress.bootstrap","description":"Initialize progress tracking after explicit user authorization and a supplied project goal, MVP, and completion criteria.","inputSchema":{"type":"object","required":["project_root","user_authorized","goal","mvp","completion_criteria"],"properties":{"project_root":{"type":"string"},"user_authorized":{"type":"boolean"},"goal":{"type":"string","minLength":1},"mvp":{"type":"string","minLength":1},"completion_criteria":{"type":"array","minItems":1,"items":{"type":"string","minLength":1}}}}},
    \\{"name":"project_progress.session_check","description":"Check project readiness, Git advancement, and content/mtime drift against the last saved snapshot.","inputSchema":{"type":"object","required":["project_root"],"properties":{"project_root":{"type":"string"}}}},
    \\{"name":"project_progress.index","description":"Persist the agent-supplied progress index and optionally replace project_progress.md. Use expected_revision to detect concurrent updates.","inputSchema":{"type":"object","required":["project_root","sections"],"properties":{"project_root":{"type":"string"},"expected_revision":{"type":"integer","minimum":0},"full_markdown":{"type":"string"},"sections":{"type":"array","items":{"type":"object","required":["section_id","heading","summary"],"properties":{"section_id":{"type":"string","pattern":"^[a-z0-9_-]+$"},"heading":{"type":"string"},"level":{"type":"integer","minimum":1,"maximum":6},"status":{"type":"string","enum":["current","planned","active","blocked","done","risk","reference"]},"summary":{"type":"string"},"anchors":{"type":"array","items":{"type":"string"}}}}},"entries":{"type":"array","items":{"type":"object","required":["title","status","summary"],"properties":{"entry_id":{"type":"string"},"title":{"type":"string"},"kind":{"type":"string"},"status":{"type":"string","enum":["planned","active","blocked","done","skipped","risk"]},"priority":{"type":"integer","minimum":1,"maximum":3},"summary":{"type":"string"},"details":{"type":"string"}}}}}}},
    \\{"name":"project_progress.register_docs","description":"Register documentation summaries and optionally write documentation files under the project root.","inputSchema":{"type":"object","required":["project_root","documents"],"properties":{"project_root":{"type":"string"},"documents":{"type":"array","items":{"type":"object","required":["path","title","summary"],"properties":{"path":{"type":"string"},"title":{"type":"string"},"summary":{"type":"string"},"tags":{"type":"array","items":{"type":"string"}},"content":{"type":"string"}}}}}}},
    \\{"name":"project_progress.record_snapshot","description":"Record current git state and file mtimes after the agent updates progress docs.","inputSchema":{"type":"object","required":["project_root"],"properties":{"project_root":{"type":"string"},"notes":{"type":"string"}}}},
    \\{"name":"project_progress.context","description":"Return saved goal, progress entries, docs, revision, consistency, and latest freshness data.","inputSchema":{"type":"object","required":["project_root"],"properties":{"project_root":{"type":"string"}}}}
    \\]}
    ;
}

fn instructionsText() []const u8 {
    return
    \\Project Progress MCP agent workflow:
    \\
    \\1. Before work, call project_progress.session_check with project_root. It must not initialize storage by itself.
    \\2. If the project is empty, call bootstrap only after the user explicitly authorizes this MCP and provides a goal/MVP/completion target.
    \\3. If the project is not empty and has no snapshot or MCP store, the agent scans the project manually, then calls index/register_docs/record_snapshot.
    \\4. If session_check returns action_required other than ready, follow that action. If it reports git_drift or file drift, inspect the changed state/files and update project_progress.md before coding.
    \\5. The MCP never calls an LLM. The agent supplies summaries, docs, statuses, and next actions as JSON.
    \\6. After completing meaningful work, update index/register_docs as needed, then call record_snapshot.
    \\
    \\Indexing contract:
    \\- sections are the current table of contents for project_progress.md and replace the previous section index.
    \\- section_id values must be stable lowercase identifiers such as goal, mvp, architecture, current-work, next, risks.
    \\- section status should be one of current, planned, active, blocked, done, risk, reference.
    \\- entries are concrete work records. Use status planned, active, blocked, done, skipped, or risk.
    \\- Use priority 1 for highest priority, 2 for normal, and 3 for later/nice-to-have.
    \\- Include enough summary/details for the next agent to continue without reading old chat.
    \\- The MCP stores what the agent provides; it does not verify that summaries match the code.
    \\- Pass context.revision as expected_revision to project_progress.index when updating an existing project. Once the stored revision is greater than zero, expected_revision is required. Retry after re-reading context if the MCP returns Conflict.
    \\
    \\project_progress.index arguments:
    \\{
    \\  "project_root": "absolute path",
    \\  "full_markdown": "optional complete project_progress.md content",
    \\  "sections": [
    \\    {"section_id":"goal","heading":"Goal","level":2,"status":"current","summary":"...","anchors":["#goal"]}
    \\  ],
    \\  "entries": [
    \\    {"entry_id":"bootstrap","title":"Implement bootstrap","kind":"feature","status":"done","priority":1,"summary":"...","details":"..."}
    \\  ]
    \\}
    \\Use entry_id for ongoing work items that should be updated in place. Omit entry_id for append-only history notes.
    \\
    \\project_progress.register_docs arguments:
    \\{
    \\  "project_root": "absolute path",
    \\  "documents": [
    \\    {"path":"docs/architecture.md","title":"Architecture","summary":"...","tags":["mcp","sqlite"],"content":"optional markdown"}
    \\  ]
    \\}
    \\
    \\After updating progress docs, call project_progress.record_snapshot.
    ;
}

const Db = struct {
    handle: *c.sqlite3,

    fn open(path: []const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        const zpath = try std.heap.page_allocator.dupeZ(u8, path);
        defer std.heap.page_allocator.free(zpath);
        const rc = c.sqlite3_open(zpath.ptr, &handle);
        if (rc != c.SQLITE_OK or handle == null) {
            const detail = if (handle) |opened| std.mem.span(c.sqlite3_errmsg(opened)) else "sqlite open failed";
            setToolErrorDetail("sqlite open failed: {s}", .{detail});
            if (handle) |opened| _ = c.sqlite3_close(opened);
            return ToolError.Sqlite;
        }
        if (c.sqlite3_busy_timeout(handle.?, 5000) != c.SQLITE_OK) {
            const detail = std.mem.span(c.sqlite3_errmsg(handle.?));
            setToolErrorDetail("sqlite busy timeout failed: {s}", .{detail});
            _ = c.sqlite3_close(handle.?);
            return ToolError.Sqlite;
        }
        return Db{ .handle = handle.? };
    }

    fn close(self: *Db) void {
        // Drop WAL/SHM sidecars so a later git status does not flap on files
        // that only exist while a connection is open.
        _ = c.sqlite3_wal_checkpoint_v2(self.handle, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        _ = c.sqlite3_close_v2(self.handle);
    }

    fn exec(self: *Db, sql: []const u8) !void {
        const zsql = try std.heap.page_allocator.dupeZ(u8, sql);
        defer std.heap.page_allocator.free(zsql);
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.handle, zsql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            return ToolError.Sqlite;
        }
    }

    fn prepare(self: *Db, sql: []const u8) !*c.sqlite3_stmt {
        const zsql = try std.heap.page_allocator.dupeZ(u8, sql);
        defer std.heap.page_allocator.free(zsql);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, zsql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            const detail = sqliteErrMsg(self);
            setToolErrorDetail("sqlite prepare failed: {s}", .{detail});
            if (stmt) |ready| _ = c.sqlite3_finalize(ready);
            return ToolError.Sqlite;
        }
        return stmt orelse toolFail(ToolError.Sqlite, "sqlite prepare returned no statement", .{});
    }
};

fn sqliteErrMsg(db: *Db) []const u8 {
    const msg = c.sqlite3_errmsg(db.handle);
    if (msg == null) return "sqlite error";
    return std.mem.span(msg);
}

fn execStep(db: *Db, stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return toolFail(ToolError.Sqlite, "sqlite step failed: {s}", .{sqliteErrMsg(db)});
    }
}

fn stepIsRow(db: *Db, stmt: *c.sqlite3_stmt) !bool {
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_ROW) return true;
    if (rc == c.SQLITE_DONE) return false;
    return toolFail(ToolError.Sqlite, "sqlite step failed: {s}", .{sqliteErrMsg(db)});
}

fn ensureProjectStore(allocator: std.mem.Allocator, project_root: []const u8) !Db {
    const io = std.Io.Threaded.global_single_threaded.io();
    const root_dir = try std.Io.Dir.openDirAbsolute(io, project_root, .{});
    defer root_dir.close(io);
    try root_dir.createDirPath(io, ".project-progress");

    const state_dir = try std.fs.path.join(allocator, &.{ project_root, ".project-progress" });
    defer allocator.free(state_dir);

    const db_path = try std.fs.path.join(allocator, &.{ state_dir, "progress.sqlite" });
    defer allocator.free(db_path);

    var db = try Db.open(db_path);
    errdefer db.close();
    try createSchema(&db);
    return db;
}

fn openProjectStoreIfExists(allocator: std.mem.Allocator, project_root: []const u8) !?Db {
    const db_path = try std.fs.path.join(allocator, &.{ project_root, ".project-progress", "progress.sqlite" });
    defer allocator.free(db_path);
    if (!fileExists(db_path)) return null;

    var db = try Db.open(db_path);
    errdefer db.close();
    try createSchema(&db);
    return db;
}

fn createSchema(db: *Db) !void {
    try db.exec(
        \\PRAGMA journal_mode=WAL;
        \\PRAGMA synchronous=NORMAL;
        \\CREATE TABLE IF NOT EXISTS metadata (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS project_goal (
        \\  id INTEGER PRIMARY KEY CHECK (id = 1),
        \\  goal TEXT NOT NULL,
        \\  mvp TEXT,
        \\  completion_json TEXT,
        \\  last_updated INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS progress_entries (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  entry_id TEXT,
        \\  title TEXT NOT NULL,
        \\  kind TEXT,
        \\  status TEXT NOT NULL,
        \\  priority INTEGER,
        \\  summary TEXT NOT NULL,
        \\  details TEXT,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS documentation (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  path TEXT UNIQUE NOT NULL,
        \\  title TEXT NOT NULL,
        \\  summary TEXT NOT NULL,
        \\  tags_json TEXT,
        \\  source_json TEXT,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS progress_index (
        \\  section_id TEXT PRIMARY KEY,
        \\  heading TEXT NOT NULL,
        \\  level INTEGER NOT NULL,
        \\  status TEXT,
        \\  summary TEXT NOT NULL,
        \\  anchors_json TEXT,
        \\  updated_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS file_snapshots (
        \\  path TEXT PRIMARY KEY,
        \\  size INTEGER NOT NULL,
        \\  mtime_ns INTEGER NOT NULL,
        \\  content_hash TEXT,
        \\  updated_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS sessions (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  session_kind TEXT NOT NULL DEFAULT 'snapshot',
        \\  started_at INTEGER NOT NULL,
        \\  git_head TEXT,
        \\  git_branch TEXT,
        \\  git_upstream TEXT,
        \\  git_ahead INTEGER,
        \\  git_behind INTEGER,
        \\  git_status TEXT,
        \\  drift_json TEXT,
        \\  notes TEXT
        \\);
    );
    try ensureColumn(db, "progress_entries", "entry_id", "TEXT");
    try ensureColumn(db, "sessions", "session_kind", "TEXT NOT NULL DEFAULT 'snapshot'");
    try ensureColumn(db, "sessions", "git_upstream", "TEXT");
    try ensureColumn(db, "sessions", "git_ahead", "INTEGER DEFAULT 0");
    try ensureColumn(db, "sessions", "git_behind", "INTEGER DEFAULT 0");
    try ensureColumn(db, "file_snapshots", "content_hash", "TEXT");
    try ensureEntryIdIndex(db);
}

fn ensureEntryIdIndex(db: *Db) !void {
    db.exec(
        \\CREATE UNIQUE INDEX IF NOT EXISTS idx_progress_entries_entry_id
        \\  ON progress_entries(entry_id);
    ) catch {
        // A previous process can leave duplicate entry_id rows, which makes
        // index creation fail and then every later open fail. Keep the newest
        // row for each id and retry. NULL entry_id history notes stay.
        try db.exec(
            \\DELETE FROM progress_entries
            \\WHERE entry_id IS NOT NULL
            \\  AND id NOT IN (
            \\    SELECT MAX(id) FROM progress_entries
            \\    WHERE entry_id IS NOT NULL
            \\    GROUP BY entry_id
            \\  );
        );
        try db.exec(
            \\CREATE UNIQUE INDEX IF NOT EXISTS idx_progress_entries_entry_id
            \\  ON progress_entries(entry_id);
        );
    };
}

fn ensureColumn(db: *Db, table: []const u8, column: []const u8, declaration: []const u8) !void {
    const pragma = try std.fmt.allocPrint(std.heap.page_allocator, "PRAGMA table_info({s})", .{table});
    defer std.heap.page_allocator.free(pragma);

    const stmt = try db.prepare(pragma);
    defer _ = c.sqlite3_finalize(stmt);
    while (try stepIsRow(db, stmt)) {
        if (std.mem.eql(u8, columnText(stmt, 1), column)) return;
    }

    const alter = try std.fmt.allocPrint(std.heap.page_allocator, "ALTER TABLE {s} ADD COLUMN {s} {s}", .{ table, column, declaration });
    defer std.heap.page_allocator.free(alter);
    try db.exec(alter);
}

fn getMetadata(db: *Db, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const stmt = try db.prepare("SELECT value FROM metadata WHERE key = ?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, key);
    if (!try stepIsRow(db, stmt)) return null;
    return try allocator.dupe(u8, columnText(stmt, 0));
}

fn setMetadata(db: *Db, key: []const u8, value: []const u8) !void {
    const stmt = try db.prepare("INSERT INTO metadata (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, key);
    try bindText(stmt, 2, value);
    _ = c.sqlite3_bind_int64(stmt, 3, nowUnixSeconds());
    try execStep(db, stmt);
}

fn getRevision(db: *Db, allocator: std.mem.Allocator) !i64 {
    const value = try getMetadata(db, allocator, "progress_revision");
    defer if (value) |text| allocator.free(text);
    if (value) |text| {
        return std.fmt.parseInt(i64, text, 10) catch {
            return toolFail(ToolError.Sqlite, "progress_revision is corrupt", .{});
        };
    }
    return 0;
}

fn hashBytes(contents: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(contents, &digest, .{});
    return encodeDigest(digest);
}

fn encodeDigest(digest: [Sha256.digest_length]u8) [Sha256.digest_length * 2]u8 {
    var encoded: [Sha256.digest_length * 2]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        encoded[index * 2] = hex[byte >> 4];
        encoded[index * 2 + 1] = hex[byte & 0x0f];
    }
    return encoded;
}

fn bootstrap(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const obj = try asObject(args);
    const project_root = getString(obj, "project_root") orelse return toolFail(ToolError.MissingArgument, "missing project_root", .{});
    const authorized = getBool(obj, "user_authorized") orelse false;
    if (!authorized) return toolFail(ToolError.Unauthorized, "user_authorized must be true", .{});
    const goal = getString(obj, "goal") orelse return toolFail(ToolError.MissingArgument, "missing goal", .{});
    if (isBlank(goal)) return toolFail(ToolError.InvalidRequest, "goal must be non-blank", .{});
    const mvp = getString(obj, "mvp") orelse return toolFail(ToolError.MissingArgument, "missing mvp", .{});
    if (isBlank(mvp)) return toolFail(ToolError.InvalidRequest, "mvp must be non-blank", .{});
    const completion_value = obj.get("completion_criteria") orelse return toolFail(ToolError.MissingArgument, "missing completion_criteria", .{});
    try requireNonEmptyStringArray(completion_value);
    const completion_json = try valueToJson(allocator, completion_value);
    defer allocator.free(completion_json);

    var db = try ensureProjectStore(allocator, project_root);
    defer db.close();

    const stmt = try db.prepare("INSERT OR REPLACE INTO project_goal (id, goal, mvp, completion_json, last_updated) VALUES (1, ?, ?, ?, ?)");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, goal);
    try bindText(stmt, 2, mvp);
    try bindText(stmt, 3, completion_json);
    _ = c.sqlite3_bind_int64(stmt, 4, nowUnixSeconds());
    try execStep(&db, stmt);

    if (!progressFileExists(allocator, project_root)) {
        const markdown = try renderInitialProgress(allocator, goal, mvp, completion_value);
        defer allocator.free(markdown);
        try writeProjectProgress(allocator, project_root, markdown);
    }

    return allocator.dupe(u8, "{\"ok\":true,\"next\":\"Agent should scan the project if non-empty, call project_progress.index/register_docs, then record_snapshot.\"}");
}

fn sessionCheck(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const obj = try asObject(args);
    const project_root = getString(obj, "project_root") orelse return toolFail(ToolError.MissingArgument, "missing project_root", .{});
    var db_opt = try openProjectStoreIfExists(allocator, project_root);
    defer if (db_opt) |*db| db.close();

    const git = try readGitState(allocator, project_root);
    defer git.deinit(allocator);
    const saved_git = if (db_opt) |*db| try loadLatestGitState(db, allocator) else null;
    defer if (saved_git) |state| state.deinit(allocator);

    var files: std.ArrayList(FileInfo) = .empty;
    defer {
        for (files.items) |item| allocator.free(item.path);
        files.deinit(allocator);
    }
    const scan = try scanFiles(allocator, project_root, &files);
    const snapshot_file_count = if (db_opt) |*db| try countFileSnapshots(db) else 0;
    const has_snapshot = if (db_opt) |*db| try hasSnapshotSession(db) else false;

    var current_paths = std.StringHashMap(void).init(allocator);
    defer current_paths.deinit();

    var drift: std.Io.Writer.Allocating = .init(allocator);
    defer drift.deinit();
    try drift.writer.writeAll("[");
    var first = true;
    for (files.items) |file| {
        try current_paths.put(file.path, {});
        if (!file.readable) continue;
        const current_hash = presentHash(&file.content_hash);
        if (db_opt) |*db| {
            const snap = try loadSnapshot(db, allocator, file.path);
            defer if (snap) |s| allocator.free(s.path);
            const changed = if (snap) |s| s.size != file.size or s.mtime_ns != file.mtime_ns or
                (hashIsPresent(s.content_hash) and !std.mem.eql(u8, &s.content_hash, &file.content_hash)) else true;
            if (changed) {
                if (snap) |s| {
                    try writeFileDriftItem(&drift.writer, &first, file.path, file.size, file.mtime_ns, current_hash, s.size, s.mtime_ns, presentHash(&s.content_hash), "modified_since_snapshot");
                } else {
                    try writeFileDriftItem(&drift.writer, &first, file.path, file.size, file.mtime_ns, current_hash, null, null, null, "not_in_snapshot");
                }
            }
        } else {
            try writeFileDriftItem(&drift.writer, &first, file.path, file.size, file.mtime_ns, current_hash, null, null, null, "no_mcp_snapshot");
        }
    }
    if (db_opt) |*db| {
        // A partial walk must not report unseen files as deleted.
        if (!scan.scan_incomplete) {
            try appendDeletedFileDrift(db, &current_paths, &drift.writer, &first);
        }
    }
    try drift.writer.writeAll("]");

    var git_drift: std.Io.Writer.Allocating = .init(allocator);
    defer git_drift.deinit();
    try writeGitDrift(saved_git, git, &git_drift.writer);

    if (db_opt) |*db| {
        var session_drift: std.Io.Writer.Allocating = .init(allocator);
        defer session_drift.deinit();
        try writeSessionDriftJson(&session_drift.writer, git_drift.writer.buffered(), drift.writer.buffered());
        try insertSession(db, "check", git, session_drift.writer.buffered(), "session_check");
        try pruneSessions(db, "check");
    }

    var consistency: ?MarkdownConsistency = null;
    defer if (consistency) |value| value.deinit(allocator);
    const revision = if (db_opt) |*db| blk: {
        consistency = try getMarkdownConsistency(allocator, db, project_root);
        break :blk try getRevision(db, allocator);
    } else 0;
    const has_git_drift = hasJsonItems(git_drift.writer.buffered());
    const has_file_drift = hasJsonItems(drift.writer.buffered());
    const action_required = if (db_opt == null and files.items.len == 0)
        "bootstrap_authorization"
    else if (db_opt == null)
        "scan_project"
    else if (!has_snapshot)
        "scan_project"
    else if (has_git_drift or has_file_drift)
        "inspect_drift"
    else if (consistency != null and consistency.?.matches != null and !consistency.?.matches.?)
        "repair_consistency"
    else
        "ready";
    const can_continue = std.mem.eql(u8, action_required, "ready");

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"ok\":true,\"git\":");
    try git.writeJson(w);
    try w.print(",\"mcp_store_initialized\":{},\"file_count\":{},\"project_empty\":{},\"snapshot_file_count\":{},\"has_snapshot\":{},\"revision\":{},\"scan_incomplete\":{},\"unreadable_files\":{},\"skipped_directories\":{}", .{ db_opt != null, files.items.len, files.items.len == 0, snapshot_file_count, has_snapshot, revision, scan.scan_incomplete, scan.unreadable_files, scan.skipped_directories });
    try w.writeAll(",\"last_saved_git\":");
    if (saved_git) |state| {
        try state.writeJson(w);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"git_drift\":");
    try w.writeAll(git_drift.writer.buffered());
    try w.writeAll(",\"drift\":");
    try w.writeAll(drift.writer.buffered());
    try w.writeAll(",\"markdown_consistency\":");
    if (consistency) |value| {
        try writeMarkdownConsistency(w, value);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"action_required\":");
    try std.json.Stringify.value(action_required, .{}, w);
    try w.print(",\"can_continue\":{},\"reason\":", .{can_continue});
    const reason = if (std.mem.eql(u8, action_required, "bootstrap_authorization"))
        "The project is empty and requires explicit user authorization plus bootstrap data."
    else if (std.mem.eql(u8, action_required, "scan_project"))
        "The agent must scan the project and initialize its progress index."
    else if (std.mem.eql(u8, action_required, "inspect_drift"))
        "The agent must inspect files or Git changes and update project progress."
    else if (std.mem.eql(u8, action_required, "repair_consistency"))
        "The indexed Markdown does not match the saved consistency record."
    else
        "No saved drift or consistency problem requires attention.";
    try std.json.Stringify.value(reason, .{}, w);
    try w.writeAll(",\"agent_instruction\":\"Follow action_required before unrelated work.\"}");
    return out.toOwnedSlice();
}

fn hasJsonItems(json: []const u8) bool {
    return json.len > 2;
}

fn indexProgress(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const obj = try asObject(args);
    const project_root = getString(obj, "project_root") orelse return toolFail(ToolError.MissingArgument, "missing project_root", .{});
    var db = try ensureProjectStore(allocator, project_root);
    defer db.close();

    const expected_revision = if (obj.get("expected_revision")) |value| getValueInteger(value) else null;
    if (obj.get("expected_revision") != null and expected_revision == null)
        return toolFail(ToolError.InvalidRequest, "expected_revision must be an integer", .{});
    if (expected_revision) |revision| if (revision < 0)
        return toolFail(ToolError.InvalidRequest, "expected_revision must be >= 0", .{});
    const full_markdown = getString(obj, "full_markdown");
    const sections = try asArray(obj.get("sections") orelse return toolFail(ToolError.MissingArgument, "missing sections", .{}));
    const entries_value = obj.get("entries");
    try validateIndexPayload(sections, entries_value);
    const initial_revision = try getRevision(&db, allocator);
    if (initial_revision > 0 and expected_revision == null)
        return toolFail(ToolError.Conflict, "expected_revision is required when progress_revision is {d}", .{initial_revision});
    if (expected_revision) |revision| if (revision != initial_revision)
        return toolFail(ToolError.Conflict, "expected_revision {d} != actual {d}", .{ revision, initial_revision });
    const rendered_markdown = if (full_markdown == null) try renderIndexedProgress(allocator, sections, entries_value) else null;
    defer if (rendered_markdown) |markdown| allocator.free(markdown);
    const markdown = if (full_markdown) |text| text else rendered_markdown.?;
    const markdown_hash = hashBytes(markdown);

    try db.exec("BEGIN IMMEDIATE");
    var transaction_open = true;
    errdefer if (transaction_open) db.exec("ROLLBACK") catch {};
    const progress_path = try projectProgressPath(allocator, project_root);
    defer allocator.free(progress_path);
    var previous_markdown: ?[]u8 = null;
    defer if (previous_markdown) |text| allocator.free(text);
    var markdown_written = false;
    errdefer if (markdown_written) restoreFile(progress_path, previous_markdown);
    const transaction_revision = try getRevision(&db, allocator);
    if (transaction_revision > 0 and expected_revision == null)
        return toolFail(ToolError.Conflict, "expected_revision is required when progress_revision is {d}", .{transaction_revision});
    if (expected_revision) |revision| if (revision != transaction_revision)
        return toolFail(ToolError.Conflict, "expected_revision {d} != actual {d}", .{ revision, transaction_revision });
    const next_revision = transaction_revision + 1;
    // Hold the SQLite write lock before touching Markdown so a stale agent
    // cannot overwrite a newer progress document before receiving Conflict.
    // If a later statement fails, restore the previous file before rollback.
    previous_markdown = try readOptionalFile(allocator, progress_path);
    try writeProjectProgress(allocator, project_root, markdown);
    markdown_written = true;
    const revision_text = try std.fmt.allocPrint(allocator, "{}", .{next_revision});
    defer allocator.free(revision_text);
    var markdown_hash_text: [Sha256.digest_length * 2]u8 = markdown_hash;
    try db.exec("DELETE FROM progress_index");
    for (sections.items) |section| {
        const section_obj = try asObject(section);
        const section_id = getString(section_obj, "section_id") orelse return ToolError.MissingArgument;
        if (!isStableId(section_id))
            return toolFail(ToolError.InvalidRequest, "section_id must match ^[a-z0-9_-]+$ (got {s})", .{section_id});
        const heading = getString(section_obj, "heading") orelse return ToolError.MissingArgument;
        const level = if (section_obj.get("level")) |level_value|
            getValueInteger(level_value) orelse return toolFail(ToolError.InvalidRequest, "section level must be an integer", .{})
        else
            2;
        if (level < 1 or level > 6)
            return toolFail(ToolError.InvalidRequest, "section level must be 1..6 (got {d})", .{level});
        const status = getString(section_obj, "status") orelse "current";
        if (!isAllowedSectionStatus(status))
            return toolFail(ToolError.InvalidRequest, "invalid section status: {s}", .{status});
        const summary = getString(section_obj, "summary") orelse return ToolError.MissingArgument;
        const anchors_json = try optionalStringArrayToJson(allocator, section_obj.get("anchors"));
        defer allocator.free(anchors_json);

        const stmt = try db.prepare("INSERT OR REPLACE INTO progress_index (section_id, heading, level, status, summary, anchors_json, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, section_id);
        try bindText(stmt, 2, heading);
        _ = c.sqlite3_bind_int64(stmt, 3, level);
        try bindText(stmt, 4, status);
        try bindText(stmt, 5, summary);
        try bindText(stmt, 6, anchors_json);
        _ = c.sqlite3_bind_int64(stmt, 7, nowUnixSeconds());
        try execStep(&db, stmt);
    }

    if (entries_value) |value| {
        const entries = try asArray(value);
        for (entries.items) |entry| {
            try insertProgressEntry(&db, entry);
        }
    }

    try setMetadata(&db, "progress_revision", revision_text);
    try setMetadata(&db, "progress_markdown_hash", &markdown_hash_text);

    try db.exec("COMMIT");
    transaction_open = false;
    markdown_written = false;

    return std.fmt.allocPrint(allocator, "{{\"ok\":true,\"revision\":{},\"next\":\"Call project_progress.record_snapshot after documentation is current.\"}}", .{next_revision});
}

fn registerDocs(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const obj = try asObject(args);
    const project_root = getString(obj, "project_root") orelse return toolFail(ToolError.MissingArgument, "missing project_root", .{});
    const documents = try asArray(obj.get("documents") orelse return toolFail(ToolError.MissingArgument, "missing documents", .{}));
    var db = try ensureProjectStore(allocator, project_root);
    defer db.close();

    try db.exec("BEGIN IMMEDIATE");
    var transaction_open = true;
    errdefer if (transaction_open) db.exec("ROLLBACK") catch {};

    const DocWrite = struct {
        path: []u8,
        previous: ?[]u8,
    };
    var doc_writes: std.ArrayList(DocWrite) = .empty;
    defer {
        for (doc_writes.items) |item| {
            allocator.free(item.path);
            if (item.previous) |text| allocator.free(text);
        }
        doc_writes.deinit(allocator);
    }
    var docs_written = false;
    errdefer if (!docs_written) {
        var index = doc_writes.items.len;
        while (index > 0) {
            index -= 1;
            restoreFile(doc_writes.items[index].path, doc_writes.items[index].previous);
        }
    };

    for (documents.items) |doc| {
        const doc_obj = try asObject(doc);
        const path = getString(doc_obj, "path") orelse return toolFail(ToolError.MissingArgument, "document missing path", .{});
        if (!isSafeRelativePath(path))
            return toolFail(ToolError.UnsafePath, "document path is not a safe relative path: {s}", .{path});
        const title = getString(doc_obj, "title") orelse return toolFail(ToolError.MissingArgument, "document missing title", .{});
        const summary = getString(doc_obj, "summary") orelse return toolFail(ToolError.MissingArgument, "document missing summary", .{});
        const tags_json = try optionalStringArrayToJson(allocator, doc_obj.get("tags"));
        defer allocator.free(tags_json);
        const source_json = try valueToJson(allocator, doc);
        defer allocator.free(source_json);

        const stmt = try db.prepare("INSERT INTO documentation (path, title, summary, tags_json, source_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(path) DO UPDATE SET title=excluded.title, summary=excluded.summary, tags_json=excluded.tags_json, source_json=excluded.source_json, updated_at=excluded.updated_at");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, path);
        try bindText(stmt, 2, title);
        try bindText(stmt, 3, summary);
        try bindText(stmt, 4, tags_json);
        try bindText(stmt, 5, source_json);
        _ = c.sqlite3_bind_int64(stmt, 6, nowUnixSeconds());
        _ = c.sqlite3_bind_int64(stmt, 7, nowUnixSeconds());
        try execStep(&db, stmt);
    }

    for (documents.items) |doc| {
        const doc_obj = try asObject(doc);
        const path = getString(doc_obj, "path") orelse return toolFail(ToolError.MissingArgument, "document missing path", .{});
        if (getString(doc_obj, "content")) |content| {
            const target = try std.fs.path.join(allocator, &.{ project_root, path });
            errdefer allocator.free(target);
            try verifyContainedWritePath(allocator, project_root, target);
            const previous = try readOptionalFile(allocator, target);
            errdefer if (previous) |text| allocator.free(text);
            const io = std.Io.Threaded.global_single_threaded.io();
            const root_dir = try std.Io.Dir.openDirAbsolute(io, project_root, .{});
            defer root_dir.close(io);
            if (relativeParentDir(path)) |dir| try root_dir.createDirPath(io, dir);
            try writeFileAbsolute(target, content);
            doc_writes.append(allocator, .{ .path = target, .previous = previous }) catch |err| {
                restoreFile(target, previous);
                return err;
            };
        }
    }

    try db.exec("COMMIT");
    transaction_open = false;
    docs_written = true;

    return allocator.dupe(u8, "{\"ok\":true}");
}

fn recordSnapshot(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const obj = try asObject(args);
    const project_root = getString(obj, "project_root") orelse return toolFail(ToolError.MissingArgument, "missing project_root", .{});
    const notes = getString(obj, "notes") orelse "";
    var db = try ensureProjectStore(allocator, project_root);
    defer db.close();

    var files: std.ArrayList(FileInfo) = .empty;
    defer {
        for (files.items) |item| allocator.free(item.path);
        files.deinit(allocator);
    }
    const scan = try scanFiles(allocator, project_root, &files);
    try db.exec("BEGIN IMMEDIATE");
    var transaction_open = true;
    errdefer if (transaction_open) db.exec("ROLLBACK") catch {};

    var preserved: std.ArrayList(FileInfo) = .empty;
    defer {
        for (preserved.items) |item| allocator.free(item.path);
        preserved.deinit(allocator);
    }
    // An incomplete walk must not drop snapshot rows for directories it could
    // not enter. A complete walk still keeps the previous row for a file that
    // exists but could not be read.
    if (!scan.scan_incomplete) {
        for (files.items) |file| {
            if (file.readable) continue;
            if (try loadSnapshot(&db, allocator, file.path)) |snap| {
                try preserved.append(allocator, snap);
            }
        }
        try db.exec("DELETE FROM file_snapshots");
    }
    var recorded: usize = 0;
    for (files.items) |file| {
        if (!file.readable) continue;
        try upsertSnapshot(&db, file);
        recorded += 1;
    }
    for (preserved.items) |file| {
        try upsertSnapshot(&db, file);
        recorded += 1;
    }

    const git = try readGitState(allocator, project_root);
    defer git.deinit(allocator);
    var snapshot_drift: std.Io.Writer.Allocating = .init(allocator);
    defer snapshot_drift.deinit();
    try writeSessionDriftJson(&snapshot_drift.writer, "[]", "[]");
    try insertSession(&db, "snapshot", git, snapshot_drift.writer.buffered(), notes);
    try pruneSessions(&db, "snapshot");
    try db.exec("COMMIT");
    transaction_open = false;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{{\"ok\":true,\"files_recorded\":{},\"unreadable_files\":{},\"scan_incomplete\":{},\"git\":", .{ recorded, scan.unreadable_files, scan.scan_incomplete });
    try git.writeJson(&out.writer);
    try out.writer.writeAll("}");
    return out.toOwnedSlice();
}

fn context(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const obj = try asObject(args);
    const project_root = getString(obj, "project_root") orelse return toolFail(ToolError.MissingArgument, "missing project_root", .{});
    const db_opt = try openProjectStoreIfExists(allocator, project_root);
    if (db_opt == null) {
        return allocator.dupe(u8, "{\"mcp_store_initialized\":false,\"revision\":0,\"goal\":null,\"progress_index\":[],\"progress_entries\":[],\"work_queue\":{\"active\":[],\"blocked\":[],\"next\":[]},\"documentation\":[],\"markdown_consistency\":null,\"latest_check\":null,\"latest_snapshot\":null,\"latest_sessions\":[]}");
    }
    var db = db_opt.?;
    defer db.close();
    const revision = try getRevision(&db, allocator);
    var consistency = try getMarkdownConsistency(allocator, &db, project_root);
    defer consistency.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{{\"mcp_store_initialized\":true,\"revision\":{},\"goal\":", .{revision});
    try appendSingleJsonObject(allocator, &db, &out.writer, "SELECT goal, mvp, completion_json, last_updated FROM project_goal WHERE id = 1");
    try out.writer.writeAll(",\"progress_index\":");
    try appendRowsJson(allocator, &db, &out.writer, "SELECT section_id, heading, level, status, summary, anchors_json, updated_at FROM progress_index ORDER BY level, section_id");
    try out.writer.writeAll(",\"progress_entries\":");
    try appendRowsJson(allocator, &db, &out.writer, "SELECT entry_id, title, kind, status, priority, summary, details, updated_at FROM progress_entries ORDER BY updated_at DESC, id DESC LIMIT 20");
    try out.writer.writeAll(",\"work_queue\":{\"active\":");
    try appendRowsJson(allocator, &db, &out.writer, "SELECT entry_id, title, kind, status, priority, summary, details, updated_at FROM progress_entries WHERE status = 'active' ORDER BY COALESCE(priority, 2), updated_at DESC, id DESC LIMIT 10");
    try out.writer.writeAll(",\"blocked\":");
    try appendRowsJson(allocator, &db, &out.writer, "SELECT entry_id, title, kind, status, priority, summary, details, updated_at FROM progress_entries WHERE status = 'blocked' ORDER BY COALESCE(priority, 2), updated_at DESC, id DESC LIMIT 10");
    try out.writer.writeAll(",\"next\":");
    try appendRowsJson(allocator, &db, &out.writer, "SELECT entry_id, title, kind, status, priority, summary, details, updated_at FROM progress_entries WHERE status = 'planned' ORDER BY COALESCE(priority, 2), updated_at DESC, id DESC LIMIT 10");
    try out.writer.writeAll("}");
    try out.writer.writeAll(",\"documentation\":");
    try appendRowsJson(allocator, &db, &out.writer, "SELECT path, title, summary, tags_json, source_json, updated_at FROM documentation ORDER BY updated_at DESC, id DESC LIMIT 50");
    try out.writer.writeAll(",\"markdown_consistency\":");
    try writeMarkdownConsistency(&out.writer, consistency);
    try out.writer.writeAll(",\"latest_check\":");
    try appendSingleJsonObject(allocator, &db, &out.writer, "SELECT session_kind, started_at, git_head, git_branch, git_upstream, git_ahead, git_behind, git_status, drift_json, notes FROM sessions WHERE session_kind = 'check' ORDER BY id DESC LIMIT 1");
    try out.writer.writeAll(",\"latest_snapshot\":");
    try appendSingleJsonObject(allocator, &db, &out.writer, "SELECT session_kind, started_at, git_head, git_branch, git_upstream, git_ahead, git_behind, git_status, drift_json, notes FROM sessions WHERE session_kind = 'snapshot' ORDER BY id DESC LIMIT 1");
    try out.writer.writeAll(",\"latest_sessions\":");
    try appendRowsJson(allocator, &db, &out.writer, "SELECT session_kind, started_at, git_head, git_branch, git_upstream, git_ahead, git_behind, git_status, drift_json, notes FROM sessions ORDER BY id DESC LIMIT 5");
    try out.writer.writeAll("}");
    return out.toOwnedSlice();
}

fn insertProgressEntry(db: *Db, entry: std.json.Value) !void {
    const obj = try asObject(entry);
    const entry_id = getString(obj, "entry_id");
    if (entry_id) |id| if (isBlank(id)) return toolFail(ToolError.InvalidRequest, "entry_id must be non-blank when provided", .{});
    const title = getString(obj, "title") orelse return toolFail(ToolError.MissingArgument, "entry missing title", .{});
    const kind = getString(obj, "kind") orelse "";
    const status = getString(obj, "status") orelse return ToolError.MissingArgument;
    if (!isAllowedEntryStatus(status))
        return toolFail(ToolError.InvalidRequest, "invalid entry status: {s}", .{status});
    const priority = if (obj.get("priority")) |value|
        getValueInteger(value) orelse return toolFail(ToolError.InvalidRequest, "entry priority must be an integer", .{})
    else
        2;
    if (priority < 1 or priority > 3)
        return toolFail(ToolError.InvalidRequest, "entry priority must be 1..3 (got {d})", .{priority});
    const summary = getString(obj, "summary") orelse return toolFail(ToolError.MissingArgument, "entry missing summary", .{});
    const details = getString(obj, "details") orelse "";
    const stmt = try db.prepare("INSERT INTO progress_entries (entry_id, title, kind, status, priority, summary, details, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(entry_id) DO UPDATE SET title=excluded.title, kind=excluded.kind, status=excluded.status, priority=excluded.priority, summary=excluded.summary, details=excluded.details, updated_at=excluded.updated_at");
    defer _ = c.sqlite3_finalize(stmt);
    try bindOptionalText(stmt, 1, entry_id);
    try bindText(stmt, 2, title);
    try bindText(stmt, 3, kind);
    try bindText(stmt, 4, status);
    _ = c.sqlite3_bind_int64(stmt, 5, priority);
    try bindText(stmt, 6, summary);
    try bindText(stmt, 7, details);
    _ = c.sqlite3_bind_int64(stmt, 8, nowUnixSeconds());
    _ = c.sqlite3_bind_int64(stmt, 9, nowUnixSeconds());
    try execStep(db, stmt);
}

fn validateIndexPayload(sections: std.json.Array, entries_value: ?std.json.Value) !void {
    for (sections.items) |section| {
        const obj = try asObject(section);
        const section_id = getString(obj, "section_id") orelse return ToolError.MissingArgument;
        if (!isStableId(section_id))
            return toolFail(ToolError.InvalidRequest, "section_id must match ^[a-z0-9_-]+$ (got {s})", .{section_id});
        _ = getString(obj, "heading") orelse return ToolError.MissingArgument;
        const level = if (obj.get("level")) |level_value|
            getValueInteger(level_value) orelse return toolFail(ToolError.InvalidRequest, "section level must be an integer", .{})
        else
            2;
        if (level < 1 or level > 6)
            return toolFail(ToolError.InvalidRequest, "section level must be 1..6 (got {d})", .{level});
        const status = getString(obj, "status") orelse "current";
        if (!isAllowedSectionStatus(status))
            return toolFail(ToolError.InvalidRequest, "invalid section status: {s}", .{status});
        _ = getString(obj, "summary") orelse return ToolError.MissingArgument;
    }

    if (entries_value) |value| {
        const entries = try asArray(value);
        for (entries.items) |entry| {
            const obj = try asObject(entry);
            if (getString(obj, "entry_id")) |entry_id| if (isBlank(entry_id))
                return toolFail(ToolError.InvalidRequest, "entry_id must be non-blank when provided", .{});
            _ = getString(obj, "title") orelse return ToolError.MissingArgument;
            const status = getString(obj, "status") orelse return ToolError.MissingArgument;
            if (!isAllowedEntryStatus(status))
                return toolFail(ToolError.InvalidRequest, "invalid entry status: {s}", .{status});
            const priority = if (obj.get("priority")) |priority_value|
                getValueInteger(priority_value) orelse return toolFail(ToolError.InvalidRequest, "entry priority must be an integer", .{})
            else
                2;
            if (priority < 1 or priority > 3)
                return toolFail(ToolError.InvalidRequest, "entry priority must be 1..3 (got {d})", .{priority});
            _ = getString(obj, "summary") orelse return ToolError.MissingArgument;
        }
    }
}

const FileInfo = struct {
    path: []u8,
    size: i64,
    mtime_ns: i64,
    content_hash: [Sha256.digest_length * 2]u8,
    readable: bool = true,
};

const ScanNotes = struct {
    unreadable_files: usize = 0,
    skipped_directories: usize = 0,
    scan_incomplete: bool = false,
};

const MarkdownConsistency = struct {
    current: ?[]u8,
    indexed: ?[]u8,
    matches: ?bool,

    fn deinit(self: MarkdownConsistency, allocator: std.mem.Allocator) void {
        if (self.current) |value| allocator.free(value);
        if (self.indexed) |value| allocator.free(value);
    }
};

fn readFileHashHex(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const digest = try hashFile(io, file);
    return try allocator.dupe(u8, &digest);
}

fn getMarkdownConsistency(allocator: std.mem.Allocator, db: *Db, project_root: []const u8) !MarkdownConsistency {
    const progress_path = try projectProgressPath(allocator, project_root);
    defer allocator.free(progress_path);
    const current = try readFileHashHex(allocator, progress_path);
    const indexed = try getMetadata(db, allocator, "progress_markdown_hash");
    const matches = if (current != null and indexed != null)
        std.mem.eql(u8, current.?, indexed.?)
    else if (indexed != null and current == null)
        false
    else
        null;
    return .{ .current = current, .indexed = indexed, .matches = matches };
}

fn writeMarkdownConsistency(writer: anytype, consistency: MarkdownConsistency) !void {
    try writer.writeAll("{\"known\":");
    try writer.print("{}", .{consistency.indexed != null});
    try writer.writeAll(",\"matches\":");
    if (consistency.matches) |matches| {
        try writer.print("{}", .{matches});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"current_hash\":");
    if (consistency.current) |hash| try std.json.Stringify.value(hash, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"indexed_hash\":");
    if (consistency.indexed) |hash| try std.json.Stringify.value(hash, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll("}");
}

fn scanFiles(allocator: std.mem.Allocator, root: []const u8, out: *std.ArrayList(FileInfo)) !ScanNotes {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var notes = ScanNotes{};
    try scanDir(allocator, root, "", dir, out, 0, &notes);
    return notes;
}

fn scanDir(allocator: std.mem.Allocator, root: []const u8, rel: []const u8, dir: std.Io.Dir, out: *std.ArrayList(FileInfo), depth: u32, notes: *ScanNotes) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch {
            notes.scan_incomplete = true;
            notes.skipped_directories += 1;
            return;
        } orelse break;
        if (shouldSkipName(entry.name)) continue;
        const rel_path = if (rel.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ rel, entry.name });
        errdefer allocator.free(rel_path);
        const abs_path = try std.fs.path.join(allocator, &.{ root, rel_path });
        defer allocator.free(abs_path);

        switch (entry.kind) {
            .file => {
                if (shouldSkipFileExtension(entry.name)) {
                    allocator.free(rel_path);
                    continue;
                }
                if (out.items.len >= max_tracked_files) {
                    allocator.free(rel_path);
                    return toolFail(ToolError.InvalidRequest, "file scan exceeded {d} tracked files", .{max_tracked_files});
                }
                const file = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch {
                    notes.unreadable_files += 1;
                    try appendUnreadable(allocator, out, rel_path);
                    continue;
                };
                defer file.close(io);
                const stat = file.stat(io) catch {
                    notes.unreadable_files += 1;
                    try appendUnreadable(allocator, out, rel_path);
                    continue;
                };
                var content_hash: [Sha256.digest_length * 2]u8 = undefined;
                @memset(&content_hash, 0);
                if (stat.size <= max_content_hash_bytes) {
                    content_hash = hashFile(io, file) catch {
                        notes.unreadable_files += 1;
                        try appendUnreadable(allocator, out, rel_path);
                        continue;
                    };
                }
                try out.append(allocator, .{
                    .path = rel_path,
                    .size = clampToI64(stat.size),
                    .mtime_ns = clampToI64(stat.mtime.nanoseconds),
                    .content_hash = content_hash,
                    .readable = true,
                });
            },
            .directory => {
                if (depth >= max_scan_depth) {
                    notes.scan_incomplete = true;
                    notes.skipped_directories += 1;
                    allocator.free(rel_path);
                    continue;
                }
                const child = std.Io.Dir.openDirAbsolute(io, abs_path, .{ .iterate = true }) catch {
                    notes.scan_incomplete = true;
                    notes.skipped_directories += 1;
                    allocator.free(rel_path);
                    continue;
                };
                defer child.close(io);
                try scanDir(allocator, root, rel_path, child, out, depth + 1, notes);
                allocator.free(rel_path);
            },
            else => allocator.free(rel_path),
        }
    }
}

fn appendUnreadable(allocator: std.mem.Allocator, out: *std.ArrayList(FileInfo), rel_path: []u8) !void {
    var content_hash: [Sha256.digest_length * 2]u8 = undefined;
    @memset(&content_hash, 0);
    try out.append(allocator, .{
        .path = rel_path,
        .size = 0,
        .mtime_ns = 0,
        .content_hash = content_hash,
        .readable = false,
    });
}

fn clampToI64(value: anytype) i64 {
    const signedness = @typeInfo(@TypeOf(value)).int.signedness;
    switch (signedness) {
        .signed => {
            const wide: i128 = value;
            if (wide > std.math.maxInt(i64)) return std.math.maxInt(i64);
            if (wide < std.math.minInt(i64)) return std.math.minInt(i64);
            return @intCast(wide);
        },
        .unsigned => {
            const max: u128 = @intCast(std.math.maxInt(i64));
            const wide: u128 = value;
            if (wide > max) return std.math.maxInt(i64);
            return @intCast(wide);
        },
    }
}

fn hashFile(io: std.Io, file: std.Io.File) ![Sha256.digest_length * 2]u8 {
    var hasher = Sha256.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var reader_buffer: [8 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const count = reader.interface.readSliceShort(&buffer) catch |err| return err;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        if (count < buffer.len) break;
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return encodeDigest(digest);
}

fn shouldSkipName(name: []const u8) bool {
    const exact = [_][]const u8{
        ".git",
        ".project-progress",
        ".zig-cache",
        ".zig-global-cache",
        "zig-out",
        "third_party",
        "external",
        "vendor",
        "vcpkg_installed",
        "node_modules",
        ".venv",
        "venv",
        "__pycache__",
        "build",
        "out",
        ".vs",
        "Debug",
        "Release",
        "x64",
        "Win32",
        "CMakeFiles",
        "sqlite-download.html",
    };
    for (exact) |item| {
        if (std.mem.eql(u8, name, item)) return true;
    }
    if (std.mem.startsWith(u8, name, "sqlite-amalgamation-")) return true;
    if (std.mem.startsWith(u8, name, "cmake-build-")) return true;
    if (std.mem.endsWith(u8, name, ".tmp")) return true;
    return false;
}

fn shouldSkipFileExtension(name: []const u8) bool {
    const exts = [_][]const u8{
        ".exe", ".dll", ".lib", ".a", ".pdb", ".obj", ".o",
        ".7z", ".zip", ".iso", ".so", ".dylib", ".wasm", ".bin", ".pak",
    };
    for (exts) |ext| {
        if (name.len >= ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;

    var start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/' or path[i] == '\\') {
            const segment = path[start..i];
            if (segment.len == 0) return false;
            if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
            if (segment[segment.len - 1] == '.' or segment[segment.len - 1] == ' ') return false;
            if (isWindowsDeviceSegment(segment)) return false;
            start = i + 1;
        }
    }
    return true;
}

fn isWindowsDeviceSegment(segment: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, segment, '.');
    const base = if (dot) |index| segment[0..index] else segment;
    if (base.len == 0) return false;
    const names = [_][]const u8{ "CON", "PRN", "AUX", "NUL" };
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    if (base.len == 4) {
        const prefix = base[0..3];
        const digit = base[3];
        if ((std.ascii.eqlIgnoreCase(prefix, "COM") or std.ascii.eqlIgnoreCase(prefix, "LPT")) and digit >= '1' and digit <= '9') {
            return true;
        }
    }
    return false;
}

fn verifyContainedWritePath(allocator: std.mem.Allocator, project_root: []const u8, target: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const root_real = std.Io.Dir.realPathFileAbsoluteAlloc(io, project_root, allocator) catch return ToolError.UnsafePath;
    defer allocator.free(root_real);

    var probe = try allocator.dupe(u8, target);
    defer allocator.free(probe);
    while (!pathExists(probe)) {
        const parent = std.fs.path.dirname(probe) orelse return ToolError.UnsafePath;
        if (std.mem.eql(u8, parent, probe)) return ToolError.UnsafePath;
        const next = try allocator.dupe(u8, parent);
        allocator.free(probe);
        probe = next;
    }

    const existing_real = std.Io.Dir.realPathFileAbsoluteAlloc(io, probe, allocator) catch return ToolError.UnsafePath;
    defer allocator.free(existing_real);
    const relative = try std.fs.path.relative(allocator, "", runtime_environ_map, root_real, existing_real);
    defer allocator.free(relative);
    if (std.fs.path.isAbsolute(relative) or std.mem.eql(u8, relative, "..") or
        std.mem.startsWith(u8, relative, "..\\") or std.mem.startsWith(u8, relative, "../"))
    {
        return ToolError.UnsafePath;
    }
}

fn relativeParentDir(path: []const u8) ?[]const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') {
            if (i == 0) return null;
            return path[0..i];
        }
    }
    return null;
}

const GitState = struct {
    is_repo: bool,
    head: []u8,
    branch: []u8,
    upstream: []u8,
    ahead: i64,
    behind: i64,
    status: []u8,

    fn deinit(self: GitState, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
        allocator.free(self.branch);
        allocator.free(self.upstream);
        allocator.free(self.status);
    }

    fn writeJson(self: GitState, writer: anytype) !void {
        try writer.print("{{\"is_repo\":{},\"head\":", .{self.is_repo});
        try std.json.Stringify.value(self.head, .{}, writer);
        try writer.writeAll(",\"branch\":");
        try std.json.Stringify.value(self.branch, .{}, writer);
        try writer.writeAll(",\"upstream\":");
        try std.json.Stringify.value(self.upstream, .{}, writer);
        try writer.print(",\"ahead\":{},\"behind\":{}", .{ self.ahead, self.behind });
        try writer.writeAll(",\"status\":");
        try std.json.Stringify.value(self.status, .{}, writer);
        try writer.writeAll("}");
    }
};

fn readGitState(allocator: std.mem.Allocator, root: []const u8) !GitState {
    const head_raw = runGit(allocator, root, &.{ "rev-parse", "HEAD" }) catch null;
    defer if (head_raw) |buf| allocator.free(buf);
    const branch_raw = runGit(allocator, root, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) catch null;
    defer if (branch_raw) |buf| allocator.free(buf);
    const upstream_raw = runGit(allocator, root, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }) catch null;
    defer if (upstream_raw) |buf| allocator.free(buf);
    const upstream_counts_raw = runGit(allocator, root, &.{ "rev-list", "--left-right", "--count", "HEAD...@{u}" }) catch null;
    defer if (upstream_counts_raw) |buf| allocator.free(buf);
    const status_raw = runGit(allocator, root, &.{ "status", "--short", "--branch" }) catch null;
    defer if (status_raw) |buf| allocator.free(buf);

    const head = if (head_raw) |buf| std.mem.trim(u8, buf, " \r\n") else "";
    const branch = if (branch_raw) |buf| std.mem.trim(u8, buf, " \r\n") else "";
    const upstream = if (upstream_raw) |buf| std.mem.trim(u8, buf, " \r\n") else "";
    const upstream_counts = if (upstream_counts_raw) |buf| blk: {
        break :blk parseAheadBehind(buf) catch AheadBehind{};
    } else AheadBehind{};
    const status = if (status_raw) |buf| std.mem.trim(u8, buf, " \r\n") else "";

    return .{
        .is_repo = head.len > 0,
        .head = try allocator.dupe(u8, head),
        .branch = try allocator.dupe(u8, branch),
        .upstream = try allocator.dupe(u8, upstream),
        .ahead = upstream_counts.ahead,
        .behind = upstream_counts.behind,
        .status = try allocator.dupe(u8, status),
    };
}

fn activeIo() std.Io {
    return runtime_io orelse std.Io.Threaded.global_single_threaded.io();
}

const AheadBehind = struct {
    ahead: i64 = 0,
    behind: i64 = 0,
};

fn parseAheadBehind(text: []const u8) !AheadBehind {
    var parts = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const ahead_text = parts.next() orelse return AheadBehind{};
    const behind_text = parts.next() orelse return AheadBehind{};
    return .{
        .ahead = try std.fmt.parseInt(i64, ahead_text, 10),
        .behind = try std.fmt.parseInt(i64, behind_text, 10),
    };
}

fn runGit(allocator: std.mem.Allocator, root: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    const git_exe = switch (@import("builtin").os.tag) {
        .windows => "git.exe",
        else => "git",
    };
    try argv.append(allocator, git_exe);
    try argv.append(allocator, "-C");
    try argv.append(allocator, root);
    for (args) |arg| try argv.append(allocator, arg);

    const io = activeIo();
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .expand_arg0 = .expand,
        .environ_map = runtime_environ_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return error.GitFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.GitFailed;
        },
    }
    return result.stdout;
}

fn upsertSnapshot(db: *Db, file: FileInfo) !void {
    const stmt = try db.prepare("INSERT OR REPLACE INTO file_snapshots (path, size, mtime_ns, content_hash, updated_at) VALUES (?, ?, ?, ?, ?)");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, file.path);
    _ = c.sqlite3_bind_int64(stmt, 2, file.size);
    _ = c.sqlite3_bind_int64(stmt, 3, file.mtime_ns);
    if (hashIsPresent(file.content_hash)) {
        try bindText(stmt, 4, &file.content_hash);
    } else if (c.sqlite3_bind_null(stmt, 4) != c.SQLITE_OK) {
        return toolFail(ToolError.Sqlite, "sqlite bind failed: {s}", .{sqliteErrMsg(db)});
    }
    _ = c.sqlite3_bind_int64(stmt, 5, nowUnixSeconds());
    try execStep(db, stmt);
}

fn loadSnapshot(db: *Db, allocator: std.mem.Allocator, path: []const u8) !?FileInfo {
    const stmt = try db.prepare("SELECT path, size, mtime_ns, content_hash FROM file_snapshots WHERE path = ?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, path);
    if (!try stepIsRow(db, stmt)) return null;
    var content_hash: [Sha256.digest_length * 2]u8 = undefined;
    @memset(&content_hash, 0);
    const stored_hash = columnBlob(stmt, 3);
    if (stored_hash.len == content_hash.len) @memcpy(&content_hash, stored_hash);
    return .{
        .path = try allocator.dupe(u8, columnText(stmt, 0)),
        .size = c.sqlite3_column_int64(stmt, 1),
        .mtime_ns = c.sqlite3_column_int64(stmt, 2),
        .content_hash = content_hash,
        .readable = true,
    };
}

fn hashIsPresent(hash: [Sha256.digest_length * 2]u8) bool {
    return hash[0] != 0;
}

fn presentHash(hash: *const [Sha256.digest_length * 2]u8) ?[]const u8 {
    if (!hashIsPresent(hash.*)) return null;
    return hash;
}

fn appendDeletedFileDrift(db: *Db, current_paths: *std.StringHashMap(void), writer: anytype, first: *bool) !void {
    const stmt = try db.prepare("SELECT path, size, mtime_ns, content_hash FROM file_snapshots");
    defer _ = c.sqlite3_finalize(stmt);
    while (try stepIsRow(db, stmt)) {
        const path = columnText(stmt, 0);
        if (!current_paths.contains(path)) {
            const stored_hash = columnBlob(stmt, 3);
            const snapshot_hash = if (stored_hash.len == Sha256.digest_length * 2 and stored_hash[0] != 0) stored_hash else null;
            try writeFileDriftItem(writer, first, path, null, null, null, c.sqlite3_column_int64(stmt, 1), c.sqlite3_column_int64(stmt, 2), snapshot_hash, "deleted_since_snapshot");
        }
    }
}

fn countFileSnapshots(db: *Db) !i64 {
    const stmt = try db.prepare("SELECT COUNT(*) FROM file_snapshots");
    defer _ = c.sqlite3_finalize(stmt);
    if (!try stepIsRow(db, stmt)) return 0;
    return c.sqlite3_column_int64(stmt, 0);
}

fn hasSnapshotSession(db: *Db) !bool {
    const stmt = try db.prepare("SELECT 1 FROM sessions WHERE session_kind = 'snapshot' LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    return stepIsRow(db, stmt);
}

fn writeFileDriftItem(writer: anytype, first: *bool, path: []const u8, current_size: ?i64, current_mtime_ns: ?i64, current_hash: ?[]const u8, snapshot_size: ?i64, snapshot_mtime_ns: ?i64, snapshot_hash: ?[]const u8, reason: []const u8) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, writer);
    const fallback_size = if (current_size) |s| s else if (snapshot_size) |s| s else 0;
    const fallback_mtime_ns = if (current_mtime_ns) |m| m else if (snapshot_mtime_ns) |m| m else 0;
    try writer.print(",\"size\":{},\"mtime_ns\":{},\"reason\":", .{ fallback_size, fallback_mtime_ns });
    try std.json.Stringify.value(reason, .{}, writer);
    try writeFileState(writer, "current", current_size, current_mtime_ns, current_hash);
    try writeFileState(writer, "snapshot", snapshot_size, snapshot_mtime_ns, snapshot_hash);
    try writer.writeAll("}");
}

fn writeFileState(writer: anytype, name: []const u8, size: ?i64, mtime_ns: ?i64, content_hash: ?[]const u8) !void {
    try writer.writeAll(",\"");
    try writer.writeAll(name);
    try writer.writeAll("\":");
    if (size) |s| {
        const m = mtime_ns orelse return ToolError.InvalidRequest;
        try writer.print("{{\"size\":{},\"mtime_ns\":{},\"content_hash\":", .{ s, m });
        if (content_hash) |hash| {
            try std.json.Stringify.value(hash, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
}

fn loadLatestGitState(db: *Db, allocator: std.mem.Allocator) !?GitState {
    const stmt = try db.prepare("SELECT git_head, git_branch, git_upstream, git_ahead, git_behind, git_status FROM sessions WHERE session_kind = 'snapshot' ORDER BY id DESC LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    if (!try stepIsRow(db, stmt)) return null;
    const head = columnText(stmt, 0);
    return .{
        .is_repo = head.len > 0,
        .head = try allocator.dupe(u8, head),
        .branch = try allocator.dupe(u8, columnText(stmt, 1)),
        .upstream = try allocator.dupe(u8, columnText(stmt, 2)),
        .ahead = c.sqlite3_column_int64(stmt, 3),
        .behind = c.sqlite3_column_int64(stmt, 4),
        .status = try allocator.dupe(u8, columnText(stmt, 5)),
    };
}

fn insertSession(db: *Db, kind: []const u8, git: GitState, drift_json: []const u8, notes: []const u8) !void {
    const stmt = try db.prepare("INSERT INTO sessions (session_kind, started_at, git_head, git_branch, git_upstream, git_ahead, git_behind, git_status, drift_json, notes) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, kind);
    _ = c.sqlite3_bind_int64(stmt, 2, nowUnixSeconds());
    try bindText(stmt, 3, git.head);
    try bindText(stmt, 4, git.branch);
    try bindText(stmt, 5, git.upstream);
    _ = c.sqlite3_bind_int64(stmt, 6, git.ahead);
    _ = c.sqlite3_bind_int64(stmt, 7, git.behind);
    try bindText(stmt, 8, git.status);
    try bindText(stmt, 9, drift_json);
    try bindText(stmt, 10, notes);
    try execStep(db, stmt);
}

fn pruneSessions(db: *Db, kind: []const u8) !void {
    const stmt = try db.prepare(
        \\DELETE FROM sessions
        \\WHERE session_kind = ?1
        \\  AND id NOT IN (
        \\    SELECT id FROM sessions WHERE session_kind = ?1 ORDER BY id DESC LIMIT ?
        \\  )
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, kind);
    _ = c.sqlite3_bind_int(stmt, 2, max_retained_sessions);
    try execStep(db, stmt);
}

fn writeGitDrift(saved: ?GitState, current: GitState, writer: anytype) !void {
    try writer.writeAll("[");
    if (saved) |state| {
        var first = true;
        if (!std.mem.eql(u8, state.head, current.head)) {
            try writeGitDriftItem(writer, &first, "head_changed", state.head, current.head);
        }
        if (!std.mem.eql(u8, state.branch, current.branch)) {
            try writeGitDriftItem(writer, &first, "branch_changed", state.branch, current.branch);
        }
        if (!std.mem.eql(u8, state.upstream, current.upstream)) {
            try writeGitDriftItem(writer, &first, "upstream_changed", state.upstream, current.upstream);
        }
        if (state.ahead != current.ahead) {
            try writeGitDriftIntItem(writer, &first, "ahead_changed", state.ahead, current.ahead);
        }
        if (state.behind != current.behind) {
            try writeGitDriftIntItem(writer, &first, "behind_changed", state.behind, current.behind);
        }
        if (!std.mem.eql(u8, state.status, current.status)) {
            try writeGitDriftItem(writer, &first, "status_changed", state.status, current.status);
        }
    } else {
        try writer.writeAll("{\"reason\":\"no_saved_git_snapshot\"}");
    }
    try writer.writeAll("]");
}

fn writeGitDriftItem(writer: anytype, first: *bool, reason: []const u8, saved: []const u8, current: []const u8) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writer.writeAll("{\"reason\":");
    try std.json.Stringify.value(reason, .{}, writer);
    try writer.writeAll(",\"saved\":");
    try std.json.Stringify.value(saved, .{}, writer);
    try writer.writeAll(",\"current\":");
    try std.json.Stringify.value(current, .{}, writer);
    try writer.writeAll("}");
}

fn writeGitDriftIntItem(writer: anytype, first: *bool, reason: []const u8, saved: i64, current: i64) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writer.writeAll("{\"reason\":");
    try std.json.Stringify.value(reason, .{}, writer);
    try writer.print(",\"saved\":{},\"current\":{}}}", .{ saved, current });
}

fn writeSessionDriftJson(writer: anytype, git_drift: []const u8, file_drift: []const u8) !void {
    try writer.writeAll("{\"git_drift\":");
    try writer.writeAll(git_drift);
    try writer.writeAll(",\"file_drift\":");
    try writer.writeAll(file_drift);
    try writer.writeAll("}");
}

fn appendSingleJsonObject(allocator: std.mem.Allocator, db: *Db, writer: anytype, sql: []const u8) !void {
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    if (!try stepIsRow(db, stmt)) {
        try writer.writeAll("null");
        return;
    }
    try appendCurrentRowJson(allocator, stmt, writer);
}

fn appendRowsJson(allocator: std.mem.Allocator, db: *Db, writer: anytype, sql: []const u8) !void {
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try writer.writeAll("[");
    var first = true;
    while (try stepIsRow(db, stmt)) {
        if (!first) try writer.writeAll(",");
        first = false;
        try appendCurrentRowJson(allocator, stmt, writer);
    }
    try writer.writeAll("]");
}

fn appendCurrentRowJson(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, writer: anytype) !void {
    try writer.writeAll("{");
    const count = c.sqlite3_column_count(stmt);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try writer.writeAll(",");
        const name = std.mem.span(c.sqlite3_column_name(stmt, i));
        try std.json.Stringify.value(name, .{}, writer);
        try writer.writeAll(":");
        switch (c.sqlite3_column_type(stmt, i)) {
            c.SQLITE_INTEGER => try writer.print("{}", .{c.sqlite3_column_int64(stmt, i)}),
            c.SQLITE_NULL => try writer.writeAll("null"),
            else => {
                const text = columnText(stmt, i);
                if (isJsonColumn(name)) {
                    try writeStoredJson(allocator, text, writer);
                } else {
                    try std.json.Stringify.value(text, .{}, writer);
                }
            },
        }
    }
    try writer.writeAll("}");
}

fn isJsonColumn(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_json");
}

fn writeStoredJson(allocator: std.mem.Allocator, text: []const u8, writer: anytype) !void {
    if (text.len == 0) {
        try writer.writeAll("null");
        return;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{
        .duplicate_field_behavior = .use_last,
    }) catch {
        try std.json.Stringify.value(text, .{}, writer);
        return;
    };
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

fn renderInitialProgress(allocator: std.mem.Allocator, goal: []const u8, mvp: []const u8, completion: ?std.json.Value) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(allocator);
    errdefer list.deinit();
    const w = &list.writer;
    try w.print("# Project Progress\n\n## Goal\n\n{s}\n\n## MVP\n\n{s}\n\n## Completion Criteria\n\n", .{ goal, if (mvp.len == 0) "TBD" else mvp });
    if (completion) |value| {
        switch (value) {
            .array => |items| for (items.items) |item| {
                switch (item) {
                    .string => |s| try w.print("- {s}\n", .{s}),
                    else => {},
                }
            },
            else => {},
        }
    }
    try w.writeAll("\n## Current State\n\n- Bootstrapped progress tracking.\n\n## Next Work\n\n- Agent should scan the project and register an initial index.\n\n## Change Log\n\n");
    return list.toOwnedSlice();
}

fn renderIndexedProgress(allocator: std.mem.Allocator, sections: std.json.Array, entries_value: ?std.json.Value) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(allocator);
    errdefer list.deinit();
    const w = &list.writer;

    try w.writeAll("# Project Progress\n\n");
    for (sections.items) |section| {
        const obj = try asObject(section);
        const heading = getString(obj, "heading") orelse return ToolError.MissingArgument;
        const summary = getString(obj, "summary") orelse return ToolError.MissingArgument;
        const status = getString(obj, "status") orelse "";
        var level = getInt(obj, "level") orelse 2;
        if (level < 2) level = 2;
        if (level > 6) level = 6;

        var i: i64 = 0;
        while (i < level) : (i += 1) {
            try w.writeByte('#');
        }
        try w.print(" {s}\n\n", .{heading});
        if (status.len > 0) {
            try w.print("Status: {s}\n\n", .{status});
        }
        try w.print("{s}\n\n", .{summary});
    }

    if (entries_value) |value| {
        const entries = try asArray(value);
        if (entries.items.len > 0) {
            try w.writeAll("## Progress Entries\n\n");
            for (entries.items) |entry| {
                const obj = try asObject(entry);
                const title = getString(obj, "title") orelse return ToolError.MissingArgument;
                const status = getString(obj, "status") orelse return ToolError.MissingArgument;
                const summary = getString(obj, "summary") orelse return ToolError.MissingArgument;
                try w.print("- [{s}] {s}: {s}\n", .{ status, title, summary });
            }
            try w.writeAll("\n");
        }
    }

    return list.toOwnedSlice();
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
    if (text.len > std.math.maxInt(c_int)) {
        return toolFail(ToolError.InvalidRequest, "value exceeds sqlite text limit", .{});
    }
    const ptr: [*c]const u8 = if (text.len == 0) "" else text.ptr;
    if (c.sqlite3_bind_text(stmt, index, ptr, @intCast(text.len), null) != c.SQLITE_OK) {
        return ToolError.Sqlite;
    }
}

fn bindOptionalText(stmt: *c.sqlite3_stmt, index: c_int, text: ?[]const u8) !void {
    if (text) |value| {
        try bindText(stmt, index, value);
    } else if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) {
        return ToolError.Sqlite;
    }
}

fn columnText(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, index);
    if (ptr == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

fn columnBlob(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const n = c.sqlite3_column_bytes(stmt, index);
    if (n <= 0) return "";
    const ptr = c.sqlite3_column_blob(stmt, index) orelse return "";
    return @as([*]const u8, @ptrCast(ptr))[0..@intCast(n)];
}

fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => toolFail(ToolError.InvalidRequest, "expected JSON object", .{}),
    };
}

fn asArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => toolFail(ToolError.InvalidRequest, "expected JSON array", .{}),
    };
}

fn getValueString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn getValueInteger(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| integerFromFloat(float),
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn integerFromFloat(float: f64) ?i64 {
    if (!std.math.isFinite(float)) return null;
    if (float < @as(f64, @floatFromInt(std.math.minInt(i64))) or float > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
    const as_int: i64 = @intFromFloat(float);
    if (@as(f64, @floatFromInt(as_int)) != float) return null;
    return as_int;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return getValueString(value);
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

fn isBlank(value: []const u8) bool {
    for (value) |ch| {
        switch (ch) {
            ' ', '\t', '\r', '\n' => {},
            else => return false,
        }
    }
    return true;
}

fn isStableId(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if ((ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == '-' or
            ch == '_')
        {
            continue;
        }
        return false;
    }
    return true;
}

fn isAllowedSectionStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "current") or
        std.mem.eql(u8, status, "planned") or
        std.mem.eql(u8, status, "active") or
        std.mem.eql(u8, status, "blocked") or
        std.mem.eql(u8, status, "done") or
        std.mem.eql(u8, status, "risk") or
        std.mem.eql(u8, status, "reference");
}

fn isAllowedEntryStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "planned") or
        std.mem.eql(u8, status, "active") or
        std.mem.eql(u8, status, "blocked") or
        std.mem.eql(u8, status, "done") or
        std.mem.eql(u8, status, "skipped") or
        std.mem.eql(u8, status, "risk");
}

fn valueToJson(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(allocator);
    errdefer list.deinit();
    try std.json.Stringify.value(value, .{}, &list.writer);
    return list.toOwnedSlice();
}

fn optionalStringArrayToJson(allocator: std.mem.Allocator, value: ?std.json.Value) ![]u8 {
    if (value) |present| {
        try requireStringArray(present);
        return valueToJson(allocator, present);
    }
    return allocator.dupe(u8, "[]");
}

fn requireStringArray(value: std.json.Value) !void {
    const array = try asArray(value);
    for (array.items) |item| {
        switch (item) {
            .string => {},
            else => return toolFail(ToolError.InvalidRequest, "array items must be strings", .{}),
        }
    }
}

fn requireNonEmptyStringArray(value: std.json.Value) !void {
    const array = try asArray(value);
    if (array.items.len == 0)
        return toolFail(ToolError.InvalidRequest, "array must be non-empty", .{});
    for (array.items) |item| {
        switch (item) {
            .string => |text| if (isBlank(text))
                return toolFail(ToolError.InvalidRequest, "array strings must be non-blank", .{}),
            else => return toolFail(ToolError.InvalidRequest, "array items must be strings", .{}),
        }
    }
}

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn pathExists(path: []const u8) bool {
    if (fileExists(path)) return true;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn nowUnixSeconds() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.real.now(io).toSeconds();
}

fn nowUnixNanoseconds() i96 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.real.now(io).nanoseconds;
}

fn projectProgressPath(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ project_root, "project_progress.md" });
}

fn progressFileExists(allocator: std.mem.Allocator, project_root: []const u8) bool {
    const path = projectProgressPath(allocator, project_root) catch return false;
    defer allocator.free(path);
    return fileExists(path);
}

fn writeProjectProgress(allocator: std.mem.Allocator, project_root: []const u8, contents: []const u8) !void {
    const path = try projectProgressPath(allocator, project_root);
    defer allocator.free(path);
    try verifyContainedWritePath(allocator, project_root, path);
    try writeFileAbsolute(path, contents);
}

fn writeFileAbsolute(path: []const u8, contents: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    temp_file_seq += 1;
    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{d}.{d}.tmp", .{ path, nowUnixNanoseconds(), temp_file_seq });
    defer std.heap.page_allocator.free(tmp_path);
    errdefer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, contents);
        try file.sync(io);
    }

    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

fn readOptionalFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buffer: [16 * 1024]u8 = undefined;
    var reader_buffer: [8 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        if (list.items.len + count > max_message_bytes) {
            return toolFail(ToolError.InvalidRequest, "file exceeds size limit", .{});
        }
        try list.appendSlice(allocator, buffer[0..count]);
        if (count < buffer.len) break;
    }
    return try list.toOwnedSlice(allocator);
}

fn restoreFile(path: []const u8, previous: ?[]const u8) void {
    if (previous) |contents| {
        writeFileAbsolute(path, contents) catch {};
    } else {
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }
}
