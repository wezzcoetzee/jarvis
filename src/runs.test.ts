import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { appendFile, mkdir, realpath, utimes } from "node:fs/promises";
import { join } from "node:path";
import { fold, paths, settings } from "./config";
import { backUp, prune, runDir, seal, undo } from "./runs";

test("undoing one of two runs that edited the same note keeps the other's work", async () => {
  const note = join(await realpath(paths.vault), "Shared.md");
  await Bun.write(note, "base\n");
  // Run A edits, then run B edits, then both end: A's end state already holds B's line.
  await backUp("run-a", fold(note), note);
  await appendFile(note, "from A\n");
  await Bun.sleep(2);
  await backUp("run-b", fold(note), note);
  await appendFile(note, "from B\n");
  await seal("run-a");
  await seal("run-b");

  expect(await undo("run-a")).toEqual({ restored: [], skipped: ["Shared.md"] });
  expect(await Bun.file(note).text()).toBe("base\nfrom A\nfrom B\n");
  expect(await undo("run-b")).toEqual({ restored: ["Shared.md"], skipped: [] });
  expect(await Bun.file(note).text()).toBe("base\nfrom A\n");
});

test("a note edited by hand after the run is left alone", async () => {
  const note = join(await realpath(paths.vault), "Mine.md");
  await Bun.write(note, "base\n");
  await backUp("run-c", fold(note), note);
  await appendFile(note, "from C\n");
  await seal("run-c");
  await appendFile(note, "typed by hand\n");
  expect((await undo("run-c")).skipped).toEqual(["Mine.md"]);
});

test("another run that touched the note but changed nothing doesn't block undo, nor does junk in runs/", async () => {
  const note = join(await realpath(paths.vault), "Solo.md");
  await Bun.write(note, "base\n");
  await backUp("run-d", fold(note), note);
  await appendFile(note, "from D\n");
  await seal("run-d");
  await Bun.sleep(2);
  await backUp("run-e", fold(note), note); // E's edit failed: nothing changed
  await seal("run-e");
  await Bun.write(join(paths.state, "runs/.DS_Store"), "");
  expect(await undo("run-d")).toEqual({ restored: ["Solo.md"], skipped: [] });
  expect(await Bun.file(note).text()).toBe("base\n");
});

test("runs older than a week are deleted, with their note copies; recent ones stay", async () => {
  await mkdir(runDir("run-old"), { recursive: true });
  await Bun.write(join(runDir("run-old"), "0.md"), "an old copy");
  const old = new Date(Date.now() - settings.keepRunsMs - 60_000);
  await utimes(runDir("run-old"), old, old);
  await mkdir(runDir("run-new"), { recursive: true });

  await prune();
  expect(existsSync(runDir("run-old"))).toBe(false);
  expect(existsSync(runDir("run-new"))).toBe(true);
});
