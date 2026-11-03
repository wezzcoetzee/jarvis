import { appendFile, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { paths } from "./config";
import type { Proposal } from "./extract";
import { readJson, writeAtomic } from "./files";

const seenPath = join(paths.state, "seen.json");
const eventsPath = join(paths.state, "events.jsonl");
// The Dock watches this folder and shows one prompt per file.
const pendingDir = join(paths.state, "pending");

/** Notes already handled, or null on first run. */
export async function loadSeen(): Promise<Set<string> | null> {
  const seen = await readJson<string[]>(seenPath);
  return seen ? new Set(seen) : null;
}

/** Atomic, so a crash mid-write can't leave a torn file that stops the watcher starting. */
export async function saveSeen(seen: Set<string>): Promise<void> {
  await mkdir(paths.state, { recursive: true });
  await writeAtomic(seenPath, JSON.stringify([...seen].sort(), null, 2));
}

/** Append-only raw log. The source for tuning which prompts get skipped. */
export async function logEvent(event: { type: string } & Record<string, unknown>): Promise<void> {
  await mkdir(paths.state, { recursive: true });
  await appendFile(eventsPath, `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`);
}

/** Recordings that failed to draft and will be tried again. Kept on disk, so a restart doesn't reset the count. */
export type Failures = Record<string, { attempts: number; at: number }>;

const failuresPath = join(paths.state, "failures.json");

export const loadFailures = async () => (await readJson<Failures>(failuresPath)) ?? {};

export async function saveFailures(failures: Failures): Promise<void> {
  await mkdir(paths.state, { recursive: true });
  await writeAtomic(failuresPath, JSON.stringify(failures, null, 2));
}

export type Pending = { noteName: string; meetingDate: string; proposal: Proposal };

const pendingPath = (noteName: string) => join(pendingDir, `${noteName}.json`);

export async function enqueue(pending: Pending): Promise<void> {
  await mkdir(pendingDir, { recursive: true });
  await writeAtomic(pendingPath(pending.noteName), JSON.stringify(pending, null, 2));
}

export const readPending = (noteName: string) => readJson<Pending>(pendingPath(noteName));

export async function removePending(noteName: string): Promise<void> {
  await rm(pendingPath(noteName), { force: true });
}
