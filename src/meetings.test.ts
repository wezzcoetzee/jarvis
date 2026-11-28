import { expect, test } from "bun:test";
import { mkdir, utimes } from "node:fs/promises";
import { join } from "node:path";
import { layout, paths, settings } from "./config";
import { draftSettled, findRecording, queueUndrafted } from "./meetings";
import { type Failures, enqueue, loadFailures, readPending, removePending } from "./state";

const NOTE = "2026-11-03 0915 Zoom.md";
await mkdir(paths.meetings, { recursive: true });
await Bun.write(join(paths.meetings, NOTE), "Me: I'll book the flights.");
const old = new Date(Date.now() - 60 * 60_000);
await utimes(join(paths.meetings, NOTE), old, old); // Settled long ago.

test("a recording that fails to draft is retried after a wait, then given up on", async () => {
  const seen = new Set<string>();
  const failures: Failures = {};
  const tries: string[] = [];
  const gaveUp: string[] = [];
  const failing = async (name: string) => {
    tries.push(name);
    throw new Error("offline");
  };
  const run = (now: number) => draftSettled(seen, failures, failing, async (name) => void gaveUp.push(name), now);

  const start = Date.now();
  await run(start);
  await run(start + 1_000); // Too soon: no second try yet.
  expect(tries).toHaveLength(1);
  expect(seen.has(NOTE)).toBe(false);
  expect((await loadFailures())[NOTE]?.attempts).toBe(1);

  await run(start + settings.retryMs);
  await run(start + 2 * settings.retryMs);
  expect(tries).toHaveLength(settings.draftAttempts);
  expect(gaveUp).toEqual([NOTE]);
  expect(seen.has(NOTE)).toBe(true);
  expect(await loadFailures()).toEqual({});
});

test("a recording given up on is queued with nothing proposed and marked draftFailed", async () => {
  const noteName = await queueUndrafted(join(paths.meetings, NOTE));
  expect(noteName).toBe("2026-11-03 0915 Zoom");
  expect(await readPending(noteName)).toEqual({
    noteName,
    meetingDate: "2026-11-03",
    proposal: { title: "Zoom", followUps: [], decisions: [] },
    draftFailed: true,
  });
  await removePending(noteName);

  // A prompt that drafted fine says nothing about it.
  await enqueue({ noteName: "ok", meetingDate: "2026-11-03", proposal: { title: "Ok", followUps: [], decisions: [] } });
  expect(await readPending("ok")).not.toHaveProperty("draftFailed");
  await removePending("ok");
});

test("a retry that works clears the failure", async () => {
  const seen = new Set<string>();
  const failures: Failures = { [NOTE]: { attempts: 1, at: 0 } };
  const drafted: string[] = [];
  await draftSettled(seen, failures, async (name) => void drafted.push(name), async () => {});
  expect(drafted).toEqual([NOTE]);
  expect(failures).toEqual({});
  expect(seen.has(NOTE)).toBe(true);
});

test("a note's name finds its recording in the meetings folder, with or without .md; a real path wins", async () => {
  const file = join(paths.meetings, NOTE);
  expect(await findRecording("2026-11-03 0915 Zoom")).toBe(file);
  expect(await findRecording(NOTE)).toBe(file);
  expect(await findRecording(file)).toBe(file);
  // A path that isn't there comes back as given, so the error names what was typed.
  expect(await findRecording("/nowhere/Nothing.md")).toBe("/nowhere/Nothing.md");
  // A name that isn't there says where it was looked for.
  await expect(findRecording("2026-01-01 0900 Nothing")).rejects.toMatchObject({
    message: `No recording called “2026-01-01 0900 Nothing” in ${layout.meetings}`,
    cause: "Use the name the Dock shows, or the note's path.",
  });
});
