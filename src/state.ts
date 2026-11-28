import { appendFile, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { paths } from "./config";
import type { Proposal } from "./extract";
import { readJson, writeAtomic } from "./files";

const seenPath = join(paths.state, "seen.json");
const seenFolderPath = join(paths.state, "seen-folder.json");
const heartbeatPath = join(paths.state, "watch-heartbeat");
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

/** The meetings folder the seen list belongs to ("off" while meetings are off), or null if never saved. */
export async function loadSeenFolder(): Promise<string | null> {
  return readJson<string>(seenFolderPath);
}

export async function saveSeenFolder(folder: string): Promise<void> {
  await mkdir(paths.state, { recursive: true });
  await writeAtomic(seenFolderPath, JSON.stringify(folder));
}

/**
 * Touched by `watch` as it goes. A watcher that's alive but hasn't touched it for minutes is
 * stuck, usually on a macOS prompt about a cloud folder, and the Dock says so.
 */
export async function heartbeat(): Promise<void> {
  await Bun.write(heartbeatPath, "");
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

/**
 * A meeting prompt waiting in the Dock. `draftFailed` (read by the Dock, so its name is a
 * contract) marks one Claude couldn't draft: the proposal is empty and the person adds lines by
 * hand, or skips. It is left out when false.
 */
export type Pending = { noteName: string; meetingDate: string; proposal: Proposal; draftFailed?: true };

const pendingPath = (noteName: string) => join(pendingDir, `${noteName}.json`);

export async function enqueue(pending: Pending): Promise<void> {
  await mkdir(pendingDir, { recursive: true });
  await writeAtomic(pendingPath(pending.noteName), JSON.stringify(pending, null, 2));
}

export const readPending = (noteName: string) => readJson<Pending>(pendingPath(noteName));

export async function removePending(noteName: string): Promise<void> {
  await rm(pendingPath(noteName), { force: true });
}
