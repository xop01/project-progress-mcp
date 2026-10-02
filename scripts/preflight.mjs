#!/usr/bin/env node
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = new URL("..", import.meta.url);
const rootPath = fileURLToPath(root);

await checkNodeSyntax("scripts/smoke-test.mjs");
await checkNodeSyntax("scripts/install-cursor-mcp.mjs");
await checkJsonFile(".mcp.example.json");
await checkMcpExample();
await checkExamples();
await checkToolsListJson();
await checkContextContract();
await checkSqliteReliability();
await checkSessionDriftContract();
await checkScanExclusions();
await checkSourceFootguns();
await checkAnonymity();

console.log("project-progress-mcp preflight passed");

async function checkNodeSyntax(path) {
  const result = spawnSync(process.execPath, ["--check", path], {
    cwd: rootPath,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`${path} failed syntax check\n${result.stderr || result.stdout}`);
  }
}

async function checkExamples() {
  const examplesDir = join(rootPath, "examples");
  const files = (await readdir(examplesDir)).filter((name) => name.endsWith(".json"));
  assert(files.length > 0, "examples/ has no JSON fixtures");
  const required = [
    "bootstrap.json",
    "context.json",
    "index.json",
    "instructions.json",
    "record_snapshot.json",
    "register_docs.json",
    "session_check.json",
  ];
  const fileSet = new Set(files);
  for (const file of required) {
    assert(fileSet.has(file), `examples/ missing ${file}`);
  }
  for (const file of files) {
    await checkJsonFile(join("examples", file));
  }
}

async function checkJsonFile(path) {
  const text = await readFile(join(rootPath, path), "utf8");
  JSON.parse(text);
}

async function checkMcpExample() {
  const text = await readFile(join(rootPath, ".mcp.example.json"), "utf8");
  const parsed = JSON.parse(text);
  const servers = parsed.mcpServers ?? {};
  assert(servers["project-progress"], ".mcp.example.json missing project-progress server");
  assert(servers["project-progress-dev"], ".mcp.example.json missing project-progress-dev server");
  // Cursor on Windows shell-splits spaced `command` paths; the example must
  // point at the junctioned no-space path documented in the README.
  assert(
    /project-progress-mcp(\.exe)?$/.test(servers["project-progress"].command),
    "project-progress server should point at compiled binary",
  );
  assert(
    !/\s/.test(servers["project-progress"].command),
    "project-progress command path must not contain spaces (run scripts/install-cursor-mcp.mjs)",
  );
  assert(servers["project-progress-dev"].command === "zig", "project-progress-dev should use zig");
  assert(
    JSON.stringify(servers["project-progress-dev"].args) === JSON.stringify(["build", "run", "--"]),
    "project-progress-dev args should run the Zig dev server",
  );
}

async function checkToolsListJson() {
  const source = await readFile(join(rootPath, "src", "main.zig"), "utf8");
  const toolsJson = extractZigMultilineReturn(source, "toolsListJson");
  const parsed = JSON.parse(toolsJson);
  const tools = parsed.tools ?? [];
  const names = new Set(tools.map((tool) => tool.name));
  for (const name of [
    "project_progress.instructions",
    "project_progress.bootstrap",
    "project_progress.session_check",
    "project_progress.index",
    "project_progress.register_docs",
    "project_progress.record_snapshot",
    "project_progress.context",
  ]) {
    assert(names.has(name), `tools/list missing ${name}`);
  }

  const bootstrap = tools.find((tool) => tool.name === "project_progress.bootstrap");
  assert(bootstrap.inputSchema.required.includes("mvp"), "bootstrap mvp must be required");
  assert(
    bootstrap.inputSchema.required.includes("completion_criteria"),
    "bootstrap completion criteria must be required",
  );
  assert(
    bootstrap.inputSchema.properties.goal.minLength === 1,
    "bootstrap goal schema must reject empty strings",
  );
  assert(
    bootstrap.inputSchema.properties.mvp.minLength === 1,
    "bootstrap mvp schema must reject empty strings",
  );
  assert(
    bootstrap.inputSchema.properties.completion_criteria.minItems === 1,
    "bootstrap completion criteria schema must reject empty arrays",
  );

  const index = tools.find((tool) => tool.name === "project_progress.index");
  const section = index.inputSchema.properties.sections.items.properties;
  const entry = index.inputSchema.properties.entries.items.properties;
  assert(section.section_id.pattern === "^[a-z0-9_-]+$", "section_id pattern missing");
  assert(section.status.enum.includes("blocked"), "section status enum incomplete");
  assert(entry.status.enum.includes("skipped"), "entry status enum incomplete");
  assert(entry.priority.minimum === 1 && entry.priority.maximum === 3, "priority bounds missing");
  assert(index.inputSchema.properties.expected_revision.type === "integer", "index expected_revision missing");
  const sessionCheck = tools.find((tool) => tool.name === "project_progress.session_check");
  assert(sessionCheck.description.includes("content"), "session_check should describe content drift");
}

function extractZigMultilineReturn(source, functionName) {
  const start = source.indexOf(`fn ${functionName}()`);
  assert(start !== -1, `${functionName} not found`);
  const bodyStart = source.indexOf("{", start);
  const bodyEnd = source.indexOf("\n}", bodyStart);
  const body = source.slice(bodyStart, bodyEnd);
  const lines = [];
  for (const line of body.split(/\r?\n/)) {
    const match = /^\s*\\\\(.*)$/.exec(line);
    if (match) lines.push(match[1]);
  }
  assert(lines.length > 0, `${functionName} returned no multiline JSON`);
  return lines.join("\n");
}

async function checkSourceFootguns() {
  const files = [
    "src/main.zig",
    "build.zig",
    "README.md",
    "project_progress.md",
    "AGENTS.md",
    "scripts/smoke-test.mjs",
  ];
  const patterns = [
    /project_pgoress/,
    /SQLITE_TRANSIENT/,
    /result\.term\.Exited/,
    /== \./,
    /!= \./,
    /Array\.init\(allocator\)/,
    /"\{s\}\.tmp"/,
  ];
  for (const file of files) {
    const text = await readFile(join(rootPath, file), "utf8");
    for (const pattern of patterns) {
      assert(!pattern.test(text), `${file} matched forbidden pattern ${pattern}`);
    }
  }
}

async function checkContextContract() {
  const source = await readFile(join(rootPath, "src", "main.zig"), "utf8");
  assert(source.includes("work_queue"), "context missing work_queue");
  assert(source.includes("active\\\":[],\\\"blocked\\\":[],\\\"next\\\":[]"), "uninitialized context missing empty work_queue");
  assert(source.includes(",\\\"work_queue\\\":{\\\"active\\\":"), "initialized context missing work_queue");
  assert(source.includes("WHERE status = 'active'"), "work_queue active query missing");
  assert(source.includes("WHERE status = 'blocked'"), "work_queue blocked query missing");
  assert(source.includes("WHERE status = 'planned'"), "work_queue next query missing");
}

async function checkSqliteReliability() {
  const source = await readFile(join(rootPath, "src", "main.zig"), "utf8");
  assert(source.includes("sqlite3_busy_timeout"), "SQLite busy timeout missing");
  assert(source.includes("PRAGMA journal_mode=WAL;"), "SQLite WAL pragma missing");
  assert(source.includes("PRAGMA synchronous=NORMAL;"), "SQLite synchronous pragma missing");
}

async function checkSessionDriftContract() {
  const source = await readFile(join(rootPath, "src", "main.zig"), "utf8");
  assert(source.includes("writeSessionDriftJson(&snapshot_drift.writer, \"[]\", \"[]\")"), "snapshot drift_json must use session drift object shape");
  assert(!source.includes("insertSession(&db, \"snapshot\", git, \"[]\""), "snapshot drift_json must not be a bare array");
  assert(source.includes("content_hash"), "file snapshots must include content hashes");
  assert(source.includes("action_required"), "session_check must return a structured action");
  assert(source.includes("progress_revision"), "progress revisions must be persisted");
  assert(source.includes("progress_markdown_hash"), "Markdown consistency hash must be persisted");
}

async function checkScanExclusions() {
  const source = await readFile(join(rootPath, "src", "main.zig"), "utf8");
  for (const name of [
    ".git",
    ".project-progress",
    ".zig-cache",
    ".zig-global-cache",
    "zig-out",
    "sqlite-download.html",
    "sqlite-amalgamation-",
    "third_party",
    "vendor",
    "build",
    "node_modules",
    "cmake-build-",
    "max_content_hash_bytes",
    "formatToolErrorJson",
  ]) {
    assert(source.includes(name), `scanner exclusion missing ${name}`);
  }
  assert(source.includes(".lib"), "binary extension skip list missing .lib");
  assert(source.includes(".pdb"), "binary extension skip list missing .pdb");
}

async function checkAnonymity() {
  // Keep committed docs/examples free of host-local absolute roots and usernames.
  // Needle fragments are joined at runtime so this file does not embed the markers.
  const textFiles = await listRepoTextFiles(rootPath);
  const forbidden = [
    { needle: ["FILES", "_WA"].join(""), label: "local workspace tag" },
    { needle: ["WinDbg", "\\Repos"].join(""), label: "local repos folder" },
    { re: /(?:^|[^\w])(?:C|D):\\Users\\[^\\\s"'`]+/i, label: "Users\\<name> path" },
    { re: /\/Users\/[^/\s"'`]+/i, label: "/Users/<name> path" },
    { re: /\/home\/[^/\s"'`]+/i, label: "/home/<name> path" },
    { re: /AppData\\(?:Local|Roaming)\\/i, label: "AppData path" },
  ];
  for (const rel of textFiles) {
    if (rel.replace(/\\/g, "/") === "scripts/preflight.mjs") continue;
    const text = await readFile(join(rootPath, rel), "utf8");
    for (const rule of forbidden) {
      const hit = rule.re ? rule.re.test(text) : text.toLowerCase().includes(rule.needle.toLowerCase());
      assert(!hit, `${rel} contains machine-local marker (${rule.label}); use placeholders like D:/path/to/project`);
    }
  }
}

async function listRepoTextFiles(dir, prefix = "") {
  const entries = await readdir(dir, { withFileTypes: true });
  const out = [];
  const skipDirs = new Set([
    ".git",
    ".zig-cache",
    ".zig-global-cache",
    "zig-out",
    ".project-progress",
    "node_modules",
    "Microsoft",
  ]);
  const textExt = new Set([".md", ".json", ".mjs", ".js", ".zig", ".txt", ".example"]);
  for (const entry of entries) {
    const name = entry.name;
    const rel = prefix ? `${prefix}/${name}` : name;
    if (entry.isDirectory()) {
      if (skipDirs.has(name)) continue;
      out.push(...(await listRepoTextFiles(join(dir, name), rel)));
      continue;
    }
    if (name === ".gitignore" || name === ".gitattributes" || name === "AGENTS.md") {
      out.push(rel);
      continue;
    }
    const dot = name.lastIndexOf(".");
    const ext = dot === -1 ? "" : name.slice(dot).toLowerCase();
    if (textExt.has(ext) || name.endsWith(".example.json")) out.push(rel);
  }
  return out;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
