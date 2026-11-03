import { expect, test } from "bun:test";
import { mkdir, utimes } from "node:fs/promises";
import { join } from "node:path";
import { paths, settings } from "./config";
import { draftSettled } from "./meetings";
import { type Failures, loadFailures } from "./state";

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

test("a retry that works clears the failure", async () => {
  const seen = new Set<string>();
  const failures: Failures = { [NOTE]: { attempts: 1, at: 0 } };
  const drafted: string[] = [];
  await draftSettled(seen, failures, async (name) => void drafted.push(name), async () => {});
  expect(drafted).toEqual([NOTE]);
  expect(failures).toEqual({});
  expect(seen.has(NOTE)).toBe(true);
});
