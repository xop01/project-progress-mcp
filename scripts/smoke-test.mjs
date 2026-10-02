#!/usr/bin/env node
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { execFileSync, spawn } from "node:child_process";

const binary = resolve(process.argv[2] ?? defaultBinaryPath());
const projectRoot = await mkdtemp(join(tmpdir(), "project-progress-mcp-"));
const child = spawn(binary, [], { stdio: ["pipe", "pipe", "pipe"] });

let nextId = 1;
let stdout = Buffer.alloc(0);
const pending = new Map();

child.stdout.on("data", (chunk) => {
  stdout = Buffer.concat([stdout, chunk]);
  drainMessages();
});

child.stderr.on("data", (chunk) => {
  process.stderr.write(chunk);
});

child.on("error", (err) => {
  for (const { reject } of pending.values()) {
    reject(err);
  }
  pending.clear();
});

child.on("exit", (code, signal) => {
  for (const { reject } of pending.values()) {
    reject(new Error(`server exited before response, code=${code}, signal=${signal}`));
  }
  pending.clear();
});

try {
  await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "project-progress-smoke", version: "0.1.0" },
  });

  const tools = await request("tools/list");
  assert(Array.isArray(tools.tools), "tools/list did not return tools");
  assert(
    tools.tools.some((tool) => tool.name === "project_progress.index"),
    "project_progress.index missing from tools/list",
  );

  const invalidBootstrap = await callTool("project_progress.bootstrap", {
    project_root: projectRoot,
    user_authorized: true,
    goal: "   ",
  });
  assert(invalidBootstrap.isError, "blank bootstrap goal was accepted");
  const invalidBootstrapJson = assertJsonText(invalidBootstrap);
  assert(invalidBootstrapJson.ok === false, "blank bootstrap error missing ok:false");
  assert(invalidBootstrapJson.error === "InvalidRequest", "blank bootstrap error missing error code");
  assert(
    typeof invalidBootstrapJson.message === "string" && invalidBootstrapJson.message.includes("goal"),
    "blank bootstrap error missing structured message",
  );

  const incompleteBootstrap = await callTool("project_progress.bootstrap", {
    project_root: projectRoot,
    user_authorized: true,
    goal: "Smoke-test project progress tracking",
    mvp: "Validate MCP protocol and storage path",
  });
  assert(incompleteBootstrap.isError, "bootstrap without completion criteria was accepted");

  const bootstrap = await callTool("project_progress.bootstrap", {
    project_root: projectRoot,
    user_authorized: true,
    goal: "Smoke-test project progress tracking",
    mvp: "Validate MCP protocol and storage path",
    completion_criteria: ["bootstrap", "index", "context", "snapshot"],
  });
  assert(!bootstrap.isError, "bootstrap failed");

  const gitInitialized = await tryInitGitRepo(projectRoot);
  await mkdir(join(projectRoot, ".zig-global-cache", "h"), { recursive: true });
  await writeFile(join(projectRoot, ".zig-global-cache", "h", "artifact.txt"), "cache\n", "utf8");
  await writeFile(join(projectRoot, "sqlite-download.html"), "<html></html>\n", "utf8");
  await mkdir(join(projectRoot, "sqlite-amalgamation-0000000"), { recursive: true });
  await writeFile(join(projectRoot, "sqlite-amalgamation-0000000", "sqlite3.c"), "/* local dependency */\n", "utf8");

  const sessionCheck = await callTool("project_progress.session_check", {
    project_root: projectRoot,
  });
  assert(!sessionCheck.isError, "session_check failed");
  const sessionCheckJson = assertJsonText(sessionCheck);
  assert(sessionCheckJson.mcp_store_initialized === true, "session_check did not see initialized store");
  assert(sessionCheckJson.action_required === "scan_project", "session_check should require an initial project scan");
  assert(sessionCheckJson.can_continue === false, "initial session_check should block unrelated work");
  assert(typeof sessionCheckJson.git.upstream === "string", "session_check git state missing upstream");
  assert(Number.isInteger(sessionCheckJson.git.ahead), "session_check git state missing ahead count");
  assert(Number.isInteger(sessionCheckJson.git.behind), "session_check git state missing behind count");
  if (gitInitialized) {
    assert(sessionCheckJson.git.is_repo === true, "session_check did not detect initialized git repo");
    assert(sessionCheckJson.git.head.length > 0, "session_check git repo missing HEAD");
  }
  assert(
    !sessionCheckJson.drift.some(isLocalBuildArtifact),
    "session_check drift included local build/dependency artifacts",
  );

  const index = await callTool("project_progress.index", {
    project_root: projectRoot,
    sections: [
      {
        section_id: "goal",
        heading: "Goal",
        level: 2,
        status: "current",
        summary: "Keep project progress available to future agents.",
        anchors: ["#goal"],
      },
    ],
    entries: [
      {
        entry_id: "smoke",
        title: "Smoke test",
        kind: "test",
        status: "done",
        priority: 1,
        summary: "Protocol smoke test exercised the core flow.",
      },
      {
        entry_id: "active-followup",
        title: "Active follow-up",
        kind: "task",
        status: "active",
        priority: 1,
        summary: "Current work should appear in the active queue.",
      },
      {
        entry_id: "blocked-followup",
        title: "Blocked follow-up",
        kind: "task",
        status: "blocked",
        priority: 2,
        summary: "Blocked work should appear in the blocked queue.",
      },
      {
        entry_id: "planned-followup",
        title: "Planned follow-up",
        kind: "task",
        status: "planned",
        priority: 3,
        summary: "Planned work should appear in the next queue.",
      },
    ],
  });
  assert(!index.isError, "index failed");
  const indexJson = assertJsonText(index);
  assert(indexJson.revision === 1, "index did not create progress revision 1");

  const staleIndex = await callTool("project_progress.index", {
    project_root: projectRoot,
    expected_revision: 0,
    sections: [
      {
        section_id: "goal",
        heading: "Stale",
        summary: "This must not overwrite a newer revision.",
      },
    ],
  });
  assert(staleIndex.isError, "stale expected_revision was accepted");

  const invalidIndex = await callTool("project_progress.index", {
    project_root: projectRoot,
    sections: [
      {
        section_id: "Bad Section",
        heading: "Bad",
        status: "unknown",
        summary: "This should be rejected.",
      },
    ],
  });
  assert(invalidIndex.isError, "invalid index payload was accepted");
  const invalidIndexJson = assertJsonText(invalidIndex);
  assert(invalidIndexJson.ok === false, "invalid index error missing ok:false");
  assert(invalidIndexJson.error === "InvalidRequest", "invalid index error missing error code");
  assert(
    typeof invalidIndexJson.message === "string" && invalidIndexJson.message.includes("section_id"),
    "invalid index error missing section_id detail",
  );
  assert(invalidIndexJson.tool === "project_progress.index", "invalid index error missing tool name");

  const staleConflictJson = assertJsonText(staleIndex);
  assert(staleConflictJson.error === "Conflict", "stale revision should return Conflict");
  assert(
    typeof staleConflictJson.message === "string" && staleConflictJson.message.includes("expected_revision"),
    "Conflict error missing expected vs actual detail",
  );

  const docs = await callTool("project_progress.register_docs", {
    project_root: projectRoot,
    documents: [
      {
        path: "docs/smoke.md",
        title: "Smoke",
        summary: "Registered by smoke test.",
        tags: ["test"],
        content: "# Smoke\n\nRegistered by the MCP smoke test.\n",
      },
    ],
  });
  assert(!docs.isError, "register_docs failed");

  const snapshot = await callTool("project_progress.record_snapshot", {
    project_root: projectRoot,
    notes: "Smoke test baseline",
  });
  assert(!snapshot.isError, "record_snapshot failed");

  await writeFile(join(projectRoot, "tracked.txt"), "changed\n", "utf8");
  await writeFile(join(projectRoot, "after-snapshot.txt"), "created after snapshot\n", "utf8");
  const driftCheck = await callTool("project_progress.session_check", {
    project_root: projectRoot,
  });
  assert(!driftCheck.isError, "drift session_check failed");
  const driftJson = assertJsonText(driftCheck);
  const newFileDrift = driftJson.drift.find((item) => item.path === "after-snapshot.txt");
  assert(newFileDrift, "session_check did not report new file drift");
  assert(newFileDrift.current?.size > 0, "new file drift missing current file state");
  assert(newFileDrift.snapshot === null, "new file drift should not have snapshot state");
  assert(newFileDrift.current?.content_hash?.length === 64, "new file drift missing content hash");
  const modifiedFileDrift = driftJson.drift.find((item) => item.path === "tracked.txt");
  assert(modifiedFileDrift?.current?.content_hash?.length === 64, "modified drift missing current content hash");
  assert(modifiedFileDrift?.snapshot?.content_hash?.length === 64, "modified drift missing snapshot content hash");
  assert(driftJson.action_required === "inspect_drift", "drift session_check should require inspection");
  assert(driftJson.can_continue === false, "drift session_check should block unrelated work");

  const context = await callTool("project_progress.context", {
    project_root: projectRoot,
  });
  assert(!context.isError, "context failed");
  const contextJson = assertJsonText(context);
  assert(contextJson.progress_index.length === 1, "context missing progress index");
  assert(
    contextJson.work_queue.active.some((item) => item.entry_id === "active-followup"),
    "context work_queue missing active item",
  );
  assert(
    contextJson.work_queue.blocked.some((item) => item.entry_id === "blocked-followup"),
    "context work_queue missing blocked item",
  );
  assert(
    contextJson.work_queue.next.some((item) => item.entry_id === "planned-followup"),
    "context work_queue missing planned next item",
  );
  assert(contextJson.documentation.length === 1, "context missing documentation");
  assert(contextJson.revision === 1, "context missing progress revision");
  assert(contextJson.markdown_consistency?.known === true, "context missing Markdown consistency record");
  assert(contextJson.markdown_consistency?.matches === true, "indexed Markdown consistency check failed");
  assert(contextJson.latest_check?.session_kind === "check", "context missing latest check");
  assert(
    contextJson.latest_check.drift_json?.file_drift?.some((item) => item.path === "after-snapshot.txt"),
    "context latest_check missing structured drift",
  );
  assert(contextJson.latest_snapshot?.session_kind === "snapshot", "context missing latest snapshot");
  assert(Array.isArray(contextJson.latest_snapshot.drift_json?.git_drift), "latest snapshot git drift should be an array");
  assert(Array.isArray(contextJson.latest_snapshot.drift_json?.file_drift), "latest snapshot file drift should be an array");

  // Large vendor/build trees must not be walked or hashed (large-tree timeout repro).
  await mkdir(join(projectRoot, "third_party", "llvm", "lib"), { recursive: true });
  await mkdir(join(projectRoot, "build", "obj"), { recursive: true });
  await writeFile(join(projectRoot, "third_party", "llvm", "lib", "LLVMCore.lib"), Buffer.alloc(2 * 1024 * 1024, 0x41));
  await writeFile(join(projectRoot, "build", "obj", "main.obj"), Buffer.alloc(512 * 1024, 0x42));
  await writeFile(join(projectRoot, "tracked-src.c"), "int main(void) { return 0; }\n", "utf8");
  const largeTreeCheck = await callTool("project_progress.session_check", {
    project_root: projectRoot,
  });
  assert(!largeTreeCheck.isError, "session_check failed after large vendor/build trees were added");
  const largeTreeJson = assertJsonText(largeTreeCheck);
  assert(
    !largeTreeJson.drift.some((item) => item.path.includes("third_party") || item.path.includes("build")),
    "session_check drift included vendor/build paths that should be skipped",
  );
  assert(
    largeTreeJson.drift.some((item) => item.path === "tracked-src.c"),
    "session_check should still see normal source files",
  );
  const largeSnapshot = await callTool("project_progress.record_snapshot", {
    project_root: projectRoot,
    notes: "After vendor/build ignore coverage",
  });
  assert(!largeSnapshot.isError, "record_snapshot failed with large vendor/build trees present");
  const largeSnapshotJson = assertJsonText(largeSnapshot);
  assert(largeSnapshotJson.files_recorded < 50, "record_snapshot hashed too many files despite ignore rules");

  const underscoreAlias = await callTool("project_progress_session_check", {
    project_root: projectRoot,
  });
  assert(!underscoreAlias.isError, "underscore tool name alias failed");

  console.log("project-progress-mcp smoke test passed");
} finally {
  child.stdin.end();
  child.kill();
  await rm(projectRoot, { recursive: true, force: true });
}

function defaultBinaryPath() {
  const exe = process.platform === "win32" ? "project-progress-mcp.exe" : "project-progress-mcp";
  return join("zig-out", "bin", exe);
}

function request(method, params) {
  const id = nextId++;
  const message = JSON.stringify({ jsonrpc: "2.0", id, method, params });
  child.stdin.write(message + "\n");
  return new Promise((resolvePromise, reject) => {
    pending.set(id, { resolve: resolvePromise, reject });
    setTimeout(() => {
      if (pending.delete(id)) {
        reject(new Error(`timed out waiting for ${method}`));
      }
    }, 5000).unref();
  });
}

async function callTool(name, args) {
  return await request("tools/call", { name, arguments: args });
}

function drainMessages() {
  while (true) {
    const newlineIdx = stdout.indexOf(0x0a);
    if (newlineIdx === -1) return;

    const line = stdout.subarray(0, newlineIdx).toString("utf8").trim();
    stdout = stdout.subarray(newlineIdx + 1);
    if (line.length === 0) continue;

    let response;
    try {
      response = JSON.parse(line);
    } catch (err) {
      throw new Error(`invalid JSON line from server: ${line}`);
    }
    const waiter = pending.get(response.id);
    if (!waiter) continue;
    pending.delete(response.id);
    if (response.error) waiter.reject(new Error(response.error.message));
    else waiter.resolve(response.result);
  }
}

function assertJsonText(toolResult) {
  const text = toolResult.content?.[0]?.text;
  assert(typeof text === "string", "tool result did not contain text");
  return JSON.parse(text);
}

function isLocalBuildArtifact(item) {
  return (
    item.path.includes(".zig-global-cache") ||
    item.path === "sqlite-download.html" ||
    item.path.startsWith("sqlite-amalgamation-") ||
    item.path.includes("third_party") ||
    item.path.startsWith("build/") ||
    item.path.startsWith("build\\")
  );
}

async function tryInitGitRepo(root) {
  try {
    execFileSync("git", ["--version"], { stdio: "ignore" });
    await writeFile(
      join(root, ".gitignore"),
      ".zig-global-cache/\nsqlite-download.html\nsqlite-amalgamation-*/\n",
      "utf8",
    );
    await writeFile(join(root, "tracked.txt"), "tracked\n", "utf8");
    execFileSync("git", ["init"], { cwd: root, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "smoke@example.invalid"], { cwd: root, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Smoke Test"], { cwd: root, stdio: "ignore" });
    execFileSync("git", ["add", ".gitignore", "project_progress.md", "tracked.txt"], { cwd: root, stdio: "ignore" });
    execFileSync("git", ["commit", "-m", "initial smoke snapshot"], { cwd: root, stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
