#!/usr/bin/env node
/**
 * Install a Cursor-friendly path to the compiled MCP binary.
 *
 * Cursor on Windows shell-splits `command` paths containing spaces (Cursor's
 * `command` field is treated as a shell string, so e.g.
 *   D:\path with spaces\...\project-progress-mcp.exe
 * fails with "'D:\path' is not recognized..."). To sidestep this without
 * copying the exe (copies end up under sandboxed %USERPROFILE%\.cursor\ ACLs
 * that block child-process stdio), we create an NTFS directory junction at a
 * no-space path on the same drive, pointing at `zig-out/bin`. The junction
 * requires no admin rights.
 *
 * Default link: <repo-drive>\pp-mcp -> <repo>/zig-out/bin
 * Override with --link=<dir>.
 */
import { execFileSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { dirname, join, resolve, parse as parsePath } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const binDir = join(repoRoot, "zig-out", "bin");
const binName = process.platform === "win32" ? "project-progress-mcp.exe" : "project-progress-mcp";
const binary = join(binDir, binName);

if (process.platform !== "win32") {
  console.log(`No install step required on ${process.platform}.\nPoint Cursor at: ${binary}`);
  process.exit(0);
}

if (!existsSync(binary)) {
  console.error(`missing build output: ${binary}\nRun: zig build`);
  process.exit(1);
}

const linkArg = process.argv.find((a) => a.startsWith("--link="));
const linkDir = linkArg
  ? resolve(linkArg.slice("--link=".length))
  : `${parsePath(repoRoot).root}pp-mcp`;

const repoDrive = parsePath(repoRoot).root.toUpperCase();
const linkDrive = parsePath(linkDir).root.toUpperCase();
if (repoDrive !== linkDrive) {
  console.error(
    `link dir ${linkDir} must be on the same drive as ${repoRoot} (junctions cannot cross volumes).\n` +
      `Pass --link=<no-space-path-on-${repoDrive}> to override.`,
  );
  process.exit(1);
}

if (linkDir.includes(" ")) {
  console.error(`link dir must not contain spaces (got: ${linkDir}).`);
  process.exit(1);
}

if (existsSync(linkDir)) {
  const st = statSync(linkDir);
  if (!st.isDirectory()) {
    console.error(`link path exists and is not a directory: ${linkDir}`);
    process.exit(1);
  }
  try {
    execFileSync("cmd", ["/c", "rmdir", linkDir], { stdio: "ignore" });
  } catch {
    // if rmdir fails (non-empty real dir), fall through and let mklink error out
  }
}

try {
  execFileSync("cmd", ["/c", "mklink", "/J", linkDir, binDir], { stdio: "pipe" });
} catch (err) {
  console.error(`mklink /J failed: ${err.message}`);
  console.error(`Try running as admin, or pick a different --link path.`);
  process.exit(1);
}

const installed = join(linkDir, binName);
if (!existsSync(installed)) {
  console.error(`junction created but ${installed} is not accessible.`);
  process.exit(1);
}

console.log(`installed: ${installed}`);
console.log(`Cursor mcp.json command should be:\n  ${installed.replace(/\\/g, "\\\\")}`);
