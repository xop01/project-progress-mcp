#!/usr/bin/env node
/**
 * Exercise every project_progress MCP tool (success + key failure paths).
 * Usage: node scripts/full-tool-test.mjs [path-to-binary]
 */
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { execFileSync, spawn } from "node:child_process";

const binary = resolve(process.argv[2] ?? defaultBinaryPath());
const projectRoot = await mkdtemp(join(tmpdir(), "pp-mcp-full-"));
const child = spawn(binary, [], { stdio: ["pipe", "pipe", "pipe"] });

let nextId = 1;
let stdout = Buffer.alloc(0);
const pending = new Map();
const results = [];

child.stdout.on("data", (chunk) => {
  stdout = Buffer.concat([stdout, chunk]);
  drainMessages();
});
child.stderr.on("data", (chunk) => {
  process.stderr.write(chunk);
});
child.on("error", (err) => {
  for (const { reject } of pending.values()) reject(err);
  pending.clear();
});
child.on("exit", (code, signal) => {
  for (const { reject } of pending.values()) {
    reject(new Error(`server exited early code=${code} signal=${signal}`));
  }
  pending.clear();
});

function record(name, ok, detail = "") {
  results.push({ name, ok, detail });
  const mark = ok ? "PASS" : "FAIL";
  console.log(`${mark}  ${name}${detail ? ` — ${detail}` : ""}`);
}

async function expectOk(name, toolResult, check) {
  try {
    if (toolResult.isError) {
      record(name, false, `isError: ${toolResult.content?.[0]?.text ?? "?"}`);
      return null;
    }
    const json = assertJsonText(toolResult);
    if (check) check(json);
    record(name, true);
    return json;
  } catch (err) {
    record(name, false, err.message);
    return null;
  }
}

async function expectErr(name, toolResult, errorCode, messageIncludes) {
  try {
    assert(toolResult.isError, "expected isError");
    const json = assertJsonText(toolResult);
    assert(json.ok === false, "expected ok:false");
    if (errorCode) assert(json.error === errorCode, `expected error=${errorCode} got ${json.error}`);
    if (messageIncludes) {
      assert(
        typeof json.message === "string" && json.message.includes(messageIncludes),
        `message missing ${JSON.stringify(messageIncludes)}: ${json.message}`,
      );
    }
    record(name, true, `${json.error}: ${json.message ?? ""}`);
    return json;
  } catch (err) {
    record(name, false, err.message);
    return null;
  }
}

try {
  console.log(`binary: ${binary}`);
  console.log(`fixture: ${projectRoot}\n`);

  await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "project-progress-full-tool-test", version: "0.1.0" },
  });
  await request("notifications/initialized");

  // --- protocol ---
  const listed = await request("tools/list");
  const toolNames = (listed.tools ?? []).map((t) => t.name).sort();
  const expectedTools = [
    "project_progress.bootstrap",
    "project_progress.context",
    "project_progress.index",
    "project_progress.instructions",
    "project_progress.record_snapshot",
    "project_progress.register_docs",
    "project_progress.session_check",
  ];
  try {
    for (const name of expectedTools) {
      assert(toolNames.includes(name), `tools/list missing ${name}`);
    }
    record("tools/list (all 7 tools)", true, toolNames.join(", "));
  } catch (err) {
    record("tools/list (all 7 tools)", false, err.message);
  }

  // --- instructions (plain text, not JSON) ---
  {
    const res = await callTool("project_progress.instructions", {});
    try {
      assert(!res.isError, "instructions isError");
      const text = res.content?.[0]?.text ?? "";
      assert(text.includes("session_check") || text.includes("project_progress"), "instructions body empty/unexpected");
      record("project_progress.instructions", true, `${text.length} chars`);
    } catch (err) {
      record("project_progress.instructions", false, err.message);
    }
  }

  // --- session_check (empty / uninitialized) ---
  {
    const res = await callTool("project_progress.session_check", { project_root: projectRoot });
    await expectOk("project_progress.session_check (empty project)", res, (json) => {
      assert(json.ok === true, "ok");
      assert(json.mcp_store_initialized === false, "store should be uninitialized");
      assert(
        json.action_required === "bootstrap_authorization" || json.action_required === "scan_project",
        `unexpected action_required=${json.action_required}`,
      );
    });
  }

  // --- context (uninitialized) ---
  {
    const res = await callTool("project_progress.context", { project_root: projectRoot });
    await expectOk("project_progress.context (uninitialized)", res, (json) => {
      assert(json.mcp_store_initialized === false, "store");
      assert(json.revision === 0, "revision");
    });
  }

  // --- bootstrap failures ---
  await expectErr(
    "project_progress.bootstrap (blank goal → InvalidRequest)",
    await callTool("project_progress.bootstrap", {
      project_root: projectRoot,
      user_authorized: true,
      goal: "   ",
      mvp: "mvp",
      completion_criteria: ["a"],
    }),
    "InvalidRequest",
    "goal",
  );
  await expectErr(
    "project_progress.bootstrap (unauthorized)",
    await callTool("project_progress.bootstrap", {
      project_root: projectRoot,
      user_authorized: false,
      goal: "goal",
      mvp: "mvp",
      completion_criteria: ["a"],
    }),
    "Unauthorized",
  );

  // --- bootstrap success ---
  await expectOk(
    "project_progress.bootstrap",
    await callTool("project_progress.bootstrap", {
      project_root: projectRoot,
      user_authorized: true,
      goal: "Full tool-matrix coverage for project-progress MCP",
      mvp: "Every tool responds correctly on success and key failure paths",
      completion_criteria: ["instructions", "bootstrap", "session_check", "index", "register_docs", "record_snapshot", "context"],
    }),
    (json) => assert(json.ok === true, "ok"),
  );

  await tryInitGitRepo(projectRoot);
  await writeFile(join(projectRoot, "readme.md"), "# fixture\n", "utf8");

  // --- session_check after bootstrap ---
  await expectOk(
    "project_progress.session_check (after bootstrap)",
    await callTool("project_progress.session_check", { project_root: projectRoot }),
    (json) => {
      assert(json.mcp_store_initialized === true, "initialized");
      assert(json.action_required === "scan_project", `action=${json.action_required}`);
    },
  );

  // --- index failures ---
  await expectErr(
    "project_progress.index (bad section_id)",
    await callTool("project_progress.index", {
      project_root: projectRoot,
      sections: [{ section_id: "Bad Id", heading: "Bad", summary: "nope" }],
    }),
    "InvalidRequest",
    "section_id",
  );

  // --- index success ---
  const indexJson = await expectOk(
    "project_progress.index",
    await callTool("project_progress.index", {
      project_root: projectRoot,
      sections: [
        {
          section_id: "goal",
          heading: "Goal",
          level: 2,
          status: "current",
          summary: "Exercise every MCP tool.",
          anchors: ["#goal"],
        },
        {
          section_id: "current-work",
          heading: "Current Work",
          level: 2,
          status: "active",
          summary: "Full tool matrix test.",
        },
      ],
      entries: [
        {
          entry_id: "matrix-active",
          title: "Matrix active",
          kind: "test",
          status: "active",
          priority: 1,
          summary: "Active queue item",
        },
        {
          entry_id: "matrix-blocked",
          title: "Matrix blocked",
          kind: "test",
          status: "blocked",
          priority: 2,
          summary: "Blocked queue item",
        },
        {
          entry_id: "matrix-next",
          title: "Matrix next",
          kind: "test",
          status: "planned",
          priority: 3,
          summary: "Next queue item",
        },
      ],
      full_markdown: [
        "# Project Progress",
        "",
        "## Goal",
        "",
        "Exercise every MCP tool.",
        "",
        "## Current Work",
        "",
        "Full tool matrix test.",
        "",
      ].join("\n"),
    }),
    (json) => assert(json.revision === 1, `revision=${json.revision}`),
  );

  await expectErr(
    "project_progress.index (stale expected_revision → Conflict)",
    await callTool("project_progress.index", {
      project_root: projectRoot,
      expected_revision: 0,
      sections: [{ section_id: "goal", heading: "Stale", summary: "should fail" }],
    }),
    "Conflict",
    "expected_revision",
  );

  // --- register_docs failures / success ---
  await expectErr(
    "project_progress.register_docs (unsafe path)",
    await callTool("project_progress.register_docs", {
      project_root: projectRoot,
      documents: [{ path: "../escape.md", title: "Escape", summary: "bad" }],
    }),
    "UnsafePath",
  );

  await expectOk(
    "project_progress.register_docs",
    await callTool("project_progress.register_docs", {
      project_root: projectRoot,
      documents: [
        {
          path: "docs/matrix.md",
          title: "Matrix",
          summary: "Registered by full tool test.",
          tags: ["test", "matrix"],
          content: "# Matrix\n\nRegistered by full tool test.\n",
        },
        {
          path: "docs/notes.md",
          title: "Notes",
          summary: "Second doc without writing content again later.",
          tags: ["test"],
        },
      ],
    }),
    (json) => assert(json.ok === true, "ok"),
  );

  {
    const written = await readFile(join(projectRoot, "docs", "matrix.md"), "utf8");
    record(
      "project_progress.register_docs (wrote docs/matrix.md)",
      written.includes("Registered by full tool test"),
      written.includes("Registered by full tool test") ? "on disk" : "missing content",
    );
  }

  // --- record_snapshot ---
  await expectOk(
    "project_progress.record_snapshot",
    await callTool("project_progress.record_snapshot", {
      project_root: projectRoot,
      notes: "full-tool-test baseline",
    }),
    (json) => {
      assert(json.ok === true, "ok");
      assert(Number.isInteger(json.files_recorded), "files_recorded");
      assert(json.files_recorded >= 1, "expected tracked files");
    },
  );

  // --- session_check ready / drift ---
  await expectOk(
    "project_progress.session_check (ready after snapshot)",
    await callTool("project_progress.session_check", { project_root: projectRoot }),
    (json) => {
      assert(json.has_snapshot === true, "has_snapshot");
      // git may introduce mild drift depending on env; accept ready or inspect_drift
      assert(
        json.action_required === "ready" || json.action_required === "inspect_drift",
        `action=${json.action_required}`,
      );
    },
  );

  await writeFile(join(projectRoot, "drift.txt"), "changed\n", "utf8");
  await expectOk(
    "project_progress.session_check (file drift)",
    await callTool("project_progress.session_check", { project_root: projectRoot }),
    (json) => {
      assert(json.action_required === "inspect_drift", `action=${json.action_required}`);
      assert(json.drift.some((d) => d.path === "drift.txt"), "missing drift.txt");
    },
  );

  // --- context populated ---
  await expectOk(
    "project_progress.context",
    await callTool("project_progress.context", { project_root: projectRoot }),
    (json) => {
      assert(json.mcp_store_initialized === true, "initialized");
      assert(json.revision === (indexJson?.revision ?? 1), "revision");
      assert(json.goal && (json.goal.goal ?? json.goal).toString().includes("Full tool-matrix"), "goal present");
      assert(Array.isArray(json.progress_index) && json.progress_index.length >= 2, "sections");
      assert(json.work_queue?.active?.some((e) => e.entry_id === "matrix-active"), "active queue");
      assert(json.work_queue?.blocked?.some((e) => e.entry_id === "matrix-blocked"), "blocked queue");
      assert(json.work_queue?.next?.some((e) => e.entry_id === "matrix-next"), "next queue");
      assert(json.documentation?.some((d) => d.path === "docs/matrix.md"), "docs");
      assert(json.latest_snapshot?.session_kind === "snapshot", "latest_snapshot");
      assert(json.latest_check?.session_kind === "check", "latest_check");
    },
  );

  // --- underscore alias (Cursor naming) ---
  await expectOk(
    "project_progress_session_check (underscore alias)",
    await callTool("project_progress_session_check", { project_root: projectRoot }),
    (json) => assert(json.ok === true, "ok"),
  );
  {
    const res = await callTool("project_progress_instructions", {});
    try {
      assert(!res.isError, "alias instructions isError");
      record("project_progress_instructions (underscore alias)", true);
    } catch (err) {
      record("project_progress_instructions (underscore alias)", false, err.message);
    }
  }

  // --- index with expected_revision success ---
  await expectOk(
    "project_progress.index (expected_revision bump)",
    await callTool("project_progress.index", {
      project_root: projectRoot,
      expected_revision: 1,
      sections: [
        {
          section_id: "goal",
          heading: "Goal",
          status: "current",
          summary: "Updated after matrix coverage.",
        },
      ],
      entries: [
        {
          entry_id: "matrix-active",
          title: "Matrix active",
          status: "done",
          priority: 1,
          summary: "Completed matrix run.",
        },
      ],
    }),
    (json) => assert(json.revision === 2, `revision=${json.revision}`),
  );

  await expectOk(
    "project_progress.record_snapshot (after index bump)",
    await callTool("project_progress.record_snapshot", {
      project_root: projectRoot,
      notes: "post-index bump",
    }),
    (json) => assert(json.ok === true, "ok"),
  );

  // summary
  const failed = results.filter((r) => !r.ok);
  console.log("\n--- summary ---");
  console.log(`passed: ${results.length - failed.length}/${results.length}`);
  if (failed.length) {
    for (const f of failed) console.log(`  FAIL ${f.name}: ${f.detail}`);
    process.exitCode = 1;
  } else {
    console.log("all tool checks passed");
  }
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
  const message =
    method === "notifications/initialized"
      ? JSON.stringify({ jsonrpc: "2.0", method, params: params ?? {} })
      : JSON.stringify({ jsonrpc: "2.0", id, method, params });
  child.stdin.write(message + "\n");
  if (method.startsWith("notifications/")) return Promise.resolve(null);
  return new Promise((resolvePromise, reject) => {
    pending.set(id, { resolve: resolvePromise, reject });
    setTimeout(() => {
      if (pending.delete(id)) reject(new Error(`timed out waiting for ${method}`));
    }, 10000).unref();
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
    } catch {
      throw new Error(`invalid JSON line from server: ${line}`);
    }
    if (response.id === undefined || response.id === null) continue;
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

async function tryInitGitRepo(root) {
  try {
    execFileSync("git", ["--version"], { stdio: "ignore" });
    await writeFile(join(root, ".gitignore"), "docs/\n", "utf8");
    execFileSync("git", ["init"], { cwd: root, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "full@example.invalid"], { cwd: root, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Full Tool Test"], { cwd: root, stdio: "ignore" });
    execFileSync("git", ["add", ".gitignore", "readme.md"], { cwd: root, stdio: "ignore" });
    execFileSync("git", ["commit", "-m", "full tool fixture"], { cwd: root, stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
