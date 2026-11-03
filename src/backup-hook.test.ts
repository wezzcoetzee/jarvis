import { expect, test } from "bun:test";
import { mkdir, symlink } from "node:fs/promises";
import { join } from "node:path";
import { paths } from "./config";
import { readManifest } from "./runs";

const RUN = "hook-test";
await mkdir(join(paths.vault, "Private"), { recursive: true });
await mkdir(join(paths.vault, ".obsidian"), { recursive: true });
await Bun.write(join(paths.vault, "Daily.md"), "# Daily\n");
await symlink("/etc", join(paths.vault, "escape"));
await symlink("/tmp/jarvis-nowhere/x.md", join(paths.vault, "dangling.md"));
await mkdir(join(paths.vault, "Meetings"), { recursive: true });

/** Pipes one PreToolUse payload into `jarvis hook`, as Claude Code does. */
async function hook(tool: string, input: Record<string, string>) {
  const proc = Bun.spawn(["bun", join(import.meta.dir, "main.ts"), "hook"], {
    env: { ...process.env, JARVIS_RUN: RUN },
    stdin: new Response(JSON.stringify({ tool_name: tool, tool_input: input })),
    stderr: "pipe",
  });
  const [code, reason] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
  return { code, reason: reason.trim() };
}

test("reads and searches inside the vault are allowed", async () => {
  expect((await hook("Read", { file_path: "Daily.md" })).code).toBe(0);
  expect((await hook("Grep", { pattern: "x", path: "." })).code).toBe(0);
});

test("anything outside the vault is blocked, including through symlinks and ..", async () => {
  expect(await hook("Read", { file_path: "/etc/hosts" })).toMatchObject({ code: 2 });
  expect(await hook("Read", { file_path: "escape/hosts" })).toMatchObject({ code: 2 });
  expect(await hook("Read", { file_path: "../outside.md" })).toMatchObject({ code: 2 });
  expect(await hook("Glob", { pattern: "{/etc/*,x}" })).toMatchObject({ code: 2 });
  expect(await hook("Grep", { pattern: "x", path: "~" })).toMatchObject({ code: 2 });
});

test("a write through a symlink that points nowhere is blocked", async () => {
  expect((await hook("Write", { file_path: "dangling.md" })).reason).toContain("broken link");
});

test("recordings can't be written, so the watcher never reacts to Jarvis's own notes", async () => {
  expect((await hook("Write", { file_path: "Meetings/2026-11-03 0915 Zoom.md" })).code).toBe(2);
  expect((await hook("Write", { file_path: "Meetings/2026-11-03 - Retro - Shed.md" })).code).toBe(0);
});

test("private folders are blocked in any letter case", async () => {
  expect((await hook("Read", { file_path: "private/x.md" })).reason).toBe("Jarvis stays out of private notes.");
  expect((await hook("Grep", { pattern: "x", glob: "Private/**" })).code).toBe(2);
});

test("edits are limited to Markdown notes outside config folders and agent files", async () => {
  expect((await hook("Write", { file_path: ".obsidian/app.md" })).code).toBe(2);
  expect((await hook("Write", { file_path: "CLAUDE.md" })).code).toBe(2);
  expect((await hook("Write", { file_path: "notes.txt" })).code).toBe(2);
  expect((await hook("Edit", {})).code).toBe(2);
});

test("the first edit to a note backs it up for undo; new notes are recorded with no backup", async () => {
  expect((await hook("Edit", { file_path: "Daily.md" })).code).toBe(0);
  expect((await hook("Write", { file_path: "New.md" })).code).toBe(0);
  const entries = Object.values(await readManifest(RUN));
  const daily = entries.find((e) => e.path.endsWith("/Daily.md"));
  expect(entries.find((e) => e.path.endsWith("/New.md"))?.backup).toBeNull();
  expect(await Bun.file(daily!.backup!).text()).toBe("# Daily\n");
});
